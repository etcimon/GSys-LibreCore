#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# KD0: no crates.io deps, no path that escapes g6lc_bios/.

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from env_common import package_root  # noqa: E402

_DEP_SECTION = re.compile(r"^\s*\[.*dependencies\]\s*$")
_ANY_SECTION = re.compile(r"^\s*\[")
_PATH_DEP = re.compile(r'path\s*=\s*"([^"]+)"')
_WORKSPACE_DEP = re.compile(r"workspace\s*=\s*true")
_FORBIDDEN = [
    re.compile(r"g6lc_qemu"),
    re.compile(r"\bcorev_apu\b"),
    re.compile(r"\bcore/include\b"),
]

# External crates that are pinned in pins.toml and KD0-explicitly allowed.
_ALLOWED_EXTERNAL = {"fontdue"}

_SKIP = {".git", "target", ".tools", "out", "__pycache__", "kernel-spec", "pglite"}


def main() -> int:
    root = package_root()
    errors: list[str] = []
    inheritable: set[str] = set()
    ws = root / "Cargo.toml"
    in_deps = False
    for lineno, raw in enumerate(ws.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split("#", 1)[0]
        if _DEP_SECTION.match(line):
            in_deps = True
            continue
        if _ANY_SECTION.match(line):
            in_deps = False
        if not in_deps or "=" not in line:
            continue
        name, _, body = line.strip().partition("=")
        name = name.strip()
        if name in _ALLOWED_EXTERNAL:
            continue
        m = _PATH_DEP.search(body)
        if not m:
            errors.append(f"{ws}:{lineno}: workspace dep `{name}` is not an in-package path")
            continue
        dep = (root / m.group(1)).resolve()
        try:
            dep.relative_to(root.resolve())
        except ValueError:
            errors.append(f"{ws}:{lineno}: path dep `{name}` escapes the package")
            continue
        inheritable.add(name)

    for man in (root / "crates").glob("*/Cargo.toml"):
        in_deps = False
        for lineno, raw in enumerate(man.read_text(encoding="utf-8").splitlines(), 1):
            line = raw.split("#", 1)[0]
            if _DEP_SECTION.match(line):
                in_deps = True
                continue
            if _ANY_SECTION.match(line):
                in_deps = False
            if not in_deps or "=" not in line:
                continue
            name, _, body = line.strip().partition("=")
            name, body = name.strip(), body.strip()
            if _WORKSPACE_DEP.search(body):
                if name not in inheritable and name not in _ALLOWED_EXTERNAL:
                    errors.append(f"{man}:{lineno}: `{name}` not a workspace path dep")
                continue
            if name in _ALLOWED_EXTERNAL:
                continue
            m = _PATH_DEP.search(body)
            if not m:
                errors.append(f"{man}:{lineno}: `{name}` is not a path dependency (KD0)")
                continue
            dep = (man.parent / m.group(1)).resolve()
            try:
                dep.relative_to(root.resolve())
            except ValueError:
                errors.append(f"{man}:{lineno}: `{name}` escapes the package")

    crates = root / "crates"
    if crates.is_dir():
        for p in crates.rglob("*.rs"):
            if any(part in _SKIP for part in p.parts):
                continue
            text = p.read_text(encoding="utf-8", errors="replace")
            for pat in _FORBIDDEN:
                if pat.search(text):
                    errors.append(f"{p}: forbidden token {pat.pattern}")

    if errors:
        for e in errors:
            print(f"FAIL {e}", file=sys.stderr)
        return 1
    print("independence OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
