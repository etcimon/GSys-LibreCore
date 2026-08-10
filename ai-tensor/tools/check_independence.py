#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Fail if ai-tensor crates depend on monorepo paths outside this package."""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN = re.compile(r"(build-platform|/corev_apu/|CVA6_REPO|monorepo-soak)", re.I)
PATH_DEP = re.compile(r'path\s*=\s*"([^"]+)"')


def main() -> int:
    bad: list[str] = []
    for p in (ROOT / "crates").rglob("Cargo.toml"):
        text = p.read_text(encoding="utf-8", errors="replace")
        for m in PATH_DEP.finditer(text):
            rel = m.group(1)
            if "cva6" in rel.replace("\\", "/").lower() and "ai-tensor" not in rel:
                bad.append(f"{p}: path={rel}")
        for i, line in enumerate(text.splitlines(), 1):
            if FORBIDDEN.search(line) and not line.strip().startswith("#"):
                bad.append(f"{p}:{i}: {line.strip()}")
    for p in (ROOT / "crates").rglob("*.rs"):
        text = p.read_text(encoding="utf-8", errors="replace")
        for i, line in enumerate(text.splitlines(), 1):
            s = line.strip()
            if s.startswith("//") or s.startswith("//!") or s.startswith("*"):
                continue
            if FORBIDDEN.search(line):
                bad.append(f"{p}:{i}: {s[:100]}")
    if bad:
        print("INDEPENDENCE FAIL:")
        for b in bad:
            print(" ", b)
        return 1
    print("independence: ok")
    return 0


if __name__ == "__main__":
    rc = main()
    # Optional C ABI lockstep (header vs Python constants)
    cabi = Path(__file__).resolve().parent / "check_c_abi.py"
    if cabi.is_file() and rc == 0:
        import subprocess

        r2 = subprocess.run([sys.executable, str(cabi)], cwd=str(ROOT))
        if r2.returncode != 0:
            sys.exit(r2.returncode)
    sys.exit(rc)
