#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Fails if first-party crates reference monorepo host symbols (KD0).

from __future__ import annotations

import re
import sys
from pathlib import Path

# Forbidden as real monorepo coupling identifiers in first-party *code*
# (not documentation comments). Vendored crates/sv-parser is out of scope.
FORBIDDEN = re.compile(
    r"\b(ariane_pkg|CVA6Cfg|HPDCACHE_DIR|Flist\.cva6|edaEnv|corev_apu)\b"
    r"|\bbuild_platform\b"  # snake_case import style
    r"|from\s+[\"']build-platform"
    r"|require\([\"']build-platform",
    re.IGNORECASE,
)

# This checker itself and pure docs may mention names — skip those paths.
SKIP_NAMES = {"check_independence.py"}


def iter_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for crate in (root / "crates").glob("sv-timing-*"):
        if not crate.is_dir():
            continue
        files.extend(crate.rglob("*.rs"))
        files.extend(crate.rglob("Cargo.toml"))
    js = root / "js"
    if js.is_dir():
        files.extend(js.rglob("*.ts"))
    tools = root / "tools"
    if tools.is_dir():
        for p in tools.glob("*.py"):
            if p.name not in SKIP_NAMES:
                files.append(p)
    return files


def is_comment_or_doc(line: str, path: Path) -> bool:
    s = line.strip()
    if path.suffix == ".rs":
        return s.startswith("//") or s.startswith("///") or s.startswith("//!") or s.startswith("*")
    if path.suffix == ".py":
        return s.startswith("#")
    if path.suffix in (".ts", ".js"):
        return s.startswith("//") or s.startswith("*")
    return False


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    bad: list[str] = []
    for path in iter_files(root):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        for i, line in enumerate(text.splitlines(), 1):
            if is_comment_or_doc(line, path):
                continue
            # Allow fixture path strings (e.g. fixtures/issue_style/ariane_pkg.sv)
            # — the forbidden tokens appear only as sample RTL names under fixtures/.
            if "fixtures/" in line.replace("\\", "/") or "fixture(" in line:
                continue
            if FORBIDDEN.search(line):
                rel = path.relative_to(root)
                bad.append(f"{rel}:{i}: {line.strip()}")
    if bad:
        print("independence check FAILED — monorepo symbols in first-party code:")
        for b in bad:
            print(f"  {b}")
        return 1
    print("independence check OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
