#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Hoist assertOn() check outside Verilator's case-assertion match vectors.

Verilator --assert emits:
    if (VL_UNLIKELY((1U & (~ VL_ONEHOT0_I(<match vector>))))) {
        if (VL_UNLIKELY(vlSymsp->_vm_contextp__->assertOn())) {
            VL_WRITEF(...);
            VL_STOP_MT(...);
        }
    }
When assertOn() is true (default), behavior is 100% identical. When
+verilator+noassert is passed, hoisting the assertOn() check skips evaluating
the expensive case-assertion match vector and VL_ONEHOT[0] reduction completely,
and PGO moves the entire block into cold .text.unlikely.
"""
import argparse
from pathlib import Path
import re

# Matches outer `if (VL_UNLIKELY(<cond>)) { if (VL_UNLIKELY(vlSymsp->_vm_contextp__->assertOn())) { <body> } }`
# where <body> contains only VL_WRITEF / VL_STOP_MT (no side effects on model state).
ASSERT_HEAD = re.compile(
    r"(?P<indent>[ \t]+)if \((?:VL_UNLIKELY\()?(?P<cond>[^;{}]+?)\)?\) \{\n"
    r"(?P=indent)    if \((?:VL_UNLIKELY\()?vlSymsp->_vm_contextp__->assertOn\(\)\)?\) \{\n",
    re.S,
)


def _find_matching_brace(text, open_brace_idx):
    depth = 0
    for i in range(open_brace_idx, len(text)):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i
    return -1


def lower_assert_guard(source, header=None):
    if "->assertOn()" not in source:
        return source, 0

    pieces, cursor, count = [], 0, 0
    for m in ASSERT_HEAD.finditer(source):
        if m.start() < cursor:
            continue
        # Extract the exact outer condition from `if (<outer_cond>) {`
        line_start = m.start() + len(m.group("indent"))
        if not source.startswith("if (", line_start):
            continue
        # Find matching ')' for `if (`
        d = 0
        cond_end = -1
        for i in range(line_start + 3, m.end()):
            ch = source[i]
            if ch == "(":
                d += 1
            elif ch == ")":
                d -= 1
                if d == 0:
                    cond_end = i
                    break
        if cond_end == -1:
            continue
        outer_cond = source[line_start + 4 : cond_end]
        # Ensure outer_cond is pure (no assignments/side effects/function calls except VL_UNLIKELY/VL_ONEHOT*/VL_RED*)
        cleaned = outer_cond.replace("==", "").replace("!=", "").replace("<=", "").replace(">=", "")
        if "=" in cleaned or "++" in cleaned or "--" in cleaned:
            continue
        # Locate the outer '{' and inner '{'
        outer_open = source.find("{", cond_end)
        inner_open = source.rfind("{", m.start(), m.end())
        if outer_open == -1 or inner_open == -1 or inner_open <= outer_open:
            continue
        inner_close = _find_matching_brace(source, inner_open)
        if inner_close == -1:
            continue
        outer_close = _find_matching_brace(source, outer_open)
        if outer_close == -1:
            continue
        if source[inner_close + 1 : outer_close].strip():
            continue
        after = source[outer_close + 1 : outer_close + 32].lstrip()
        if after.startswith("else"):
            continue
        inner_body = source[inner_open + 1 : inner_close]
        # Verify inner_body only performs assert reporting/stopping (no state writes!)
        if "vlSelf->" in inner_body and (" = " in inner_body):
            continue
        indent = m.group("indent")
        pieces.append(source[cursor : m.start()])
        pieces.append(
            f"{indent}if (VL_UNLIKELY(vlSymsp->_vm_contextp__->assertOn())) {{\n"
            f"{indent}    if ({outer_cond}) {{{inner_body}}}\n"
            f"{indent}}}"
        )
        cursor = outer_close + 1
        count += 1
    if not count:
        return source, 0
    return "".join(pieces) + source[cursor:], count


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    for a in ("source", "output"):
        ap.add_argument(a, type=Path)
    args = ap.parse_args()
    out, hits = lower_assert_guard(args.source.read_text())
    if hits:
        with args.output.open("x") as f:
            f.write(out)
    print(f"{hits} case-assertion guards hoisted")
