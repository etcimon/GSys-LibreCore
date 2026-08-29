#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# tomlmini.py — minimal, dependency-free TOML reader for the platform-constants.toml
# file used by g6q.py. It supports the subset of TOML needed for that file:
# tables, dotted keys, strings, booleans, integers, and arrays of strings.

from __future__ import annotations

import ast
import re
from pathlib import Path


def _split_key(key: str) -> list[str]:
    parts: list[str] = []
    while key:
        m = re.match(r'^(?:"([^"]*)"|([^\.\s]+))(?:\.|$)', key)
        if not m:
            raise ValueError(f"bad key: {key!r}")
        parts.append(m.group(1) if m.group(1) is not None else m.group(2))
        key = key[m.end():]
    return parts


def _strip_comment(value: str) -> str:
    """Remove a trailing # comment that is not inside a string."""
    in_str: str | None = None
    i = 0
    while i < len(value):
        c = value[i]
        if in_str:
            if c == "\\" and i + 1 < len(value):
                i += 2
                continue
            if c == in_str:
                in_str = None
        elif c in ("'", '"'):
            in_str = c
        elif c == "#":
            return value[:i]
        i += 1
    return value


def _parse_string(s: str) -> tuple[str, str]:
    if s.startswith('"'):
        out: list[str] = []
        i = 1
        while i < len(s):
            c = s[i]
            if c == "\\" and i + 1 < len(s):
                n = s[i + 1]
                if n == "b":
                    out.append("\b")
                elif n == "t":
                    out.append("\t")
                elif n == "n":
                    out.append("\n")
                elif n == "f":
                    out.append("\f")
                elif n == "r":
                    out.append("\r")
                elif n == '"':
                    out.append('"')
                elif n == "\\":
                    out.append("\\")
                elif n in ("u", "U"):
                    width = 4 if n == "u" else 8
                    code = s[i + 2:i + 2 + width]
                    if len(code) < width:
                        raise ValueError("short unicode escape")
                    out.append(chr(int(code, 16)))
                    i += width
                else:
                    out.append(n)
                i += 2
            elif c == '"':
                i += 1
                break
            else:
                out.append(c)
                i += 1
        return "".join(out), s[i:]
    if s.startswith("'"):
        end = s.find("'", 1)
        if end < 0:
            raise ValueError("unterminated literal string")
        return s[1:end], s[end + 1:]
    raise ValueError(f"not a string: {s!r}")


def _balanced_value(s: str) -> str:
    """Return the full value token from the start of s, including quoted/structured forms."""
    s = s.lstrip()
    if not s:
        return ""
    if s.startswith('"') or s.startswith("'"):
        val, rest = _parse_string(s)
        return s[:len(s) - len(rest)]
    if s.startswith("["):
        depth = 0
        in_str: str | None = None
        i = 0
        while i < len(s):
            c = s[i]
            if in_str:
                if c == "\\":
                    i += 2
                    continue
                if c == in_str:
                    in_str = None
            elif c in ("'", '"'):
                in_str = c
            elif c == "[":
                depth += 1
            elif c == "]":
                depth -= 1
                if depth == 0:
                    i += 1
                    break
            i += 1
        return s[:i]
    if s.startswith("{"):
        depth = 0
        in_str: str | None = None
        i = 0
        while i < len(s):
            c = s[i]
            if in_str:
                if c == "\\":
                    i += 2
                    continue
                if c == in_str:
                    in_str = None
            elif c in ("'", '"'):
                in_str = c
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    i += 1
                    break
            i += 1
        return s[:i]
    # simple token: read until whitespace or comment
    m = re.match(r'^[^\s#]+', s)
    return m.group(0) if m else ""


def _toml_value_token(token: str) -> object:
    token = token.strip()
    if not token:
        raise ValueError("empty value")
    if token.startswith('"') or token.startswith("'"):
        val, _ = _parse_string(token)
        return val
    if token == "true":
        return True
    if token == "false":
        return False
    if token.startswith("["):
        lit = token.replace("true", "True").replace("false", "False")
        try:
            return ast.literal_eval(lit)
        except Exception as e:
            raise ValueError(f"bad array: {token!r}: {e}")
    if token.startswith("{"):
        # Convert top-level = to : so ast.literal_eval can read it.
        # This is intentionally simple and only used for small inline tables.
        lit = re.sub(r'(?<![\'"])=(?![=])', ':', token)
        lit = lit.replace("true", "True").replace("false", "False")
        try:
            return ast.literal_eval(lit)
        except Exception as e:
            raise ValueError(f"bad inline table: {token!r}: {e}")
    m = re.match(r'^([+-]?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)$', token)
    if m:
        num = m.group(1)
        if "." in num or "e" in num or "E" in num:
            return float(num)
        return int(num)
    raise ValueError(f"bad value: {token!r}")


def _value_is_complete(value: str) -> bool:
    """Return True when the balanced-value token covers the whole string."""
    token = _balanced_value(value)
    if not token:
        return False
    if token != value.strip():
        return False
    if token.startswith("[") and not token.endswith("]"):
        return False
    if token.startswith("{") and not token.endswith("}"):
        return False
    return True


def loads(text: str) -> dict:
    root: dict = {}
    table: list[str] = []
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        raw = lines[i]
        line = raw.strip()
        i += 1
        if not line or line.startswith("#"):
            continue
        m = re.match(r'^\[(.*?)\]\s*$', line)
        if m:
            table = _split_key(m.group(1))
            continue
        m = re.match(r'^([A-Za-z0-9_\-\."\']+)\s*=\s*(.*)$', line)
        if not m:
            raise ValueError(f"bad toml line: {raw!r}")
        key = _split_key(m.group(1).strip())
        value = _strip_comment(m.group(2).strip())

        # Multi-line arrays / inline tables: keep reading until the value is balanced.
        while value and (value.startswith("[") or value.startswith("{")) and not _value_is_complete(value):
            if i >= len(lines):
                raise ValueError(f"unterminated structured value: {raw!r}")
            extra = _strip_comment(lines[i].strip())
            i += 1
            value += " " + extra

        token = _balanced_value(value)
        if not token:
            raise ValueError(f"empty value in line: {raw!r}")
        parsed = _toml_value_token(token)
        target: dict = root
        for k in table + key[:-1]:
            target = target.setdefault(k, {})
        target[key[-1]] = parsed
    return root


def load(path: Path) -> dict:
    return loads(path.read_text(encoding="utf-8"))
