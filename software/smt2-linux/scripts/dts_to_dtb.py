#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""
Compile ariane-smt2.dts (or any DTS path) to DTB.

Prefers system `dtc`. Fallback: PyPI `fdt` package (pip install fdt) so Windows
hosts can build OpenSBI without device-tree-compiler.
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path


def compile_with_dtc(dts: Path, out: Path) -> None:
    subprocess.check_call(["dtc", "-I", "dts", "-O", "dtb", "-o", str(out), str(dts)])
    print(f"[dts_to_dtb] dtc -> {out}")


def compile_with_fdt(dts: Path, out: Path) -> None:
    try:
        from fdt import parse_dts
    except ImportError as e:
        print("Need system dtc or: pip install fdt", file=sys.stderr)
        raise SystemExit(2) from e

    text = dts.read_text(encoding="utf-8")
    # Strip C/C++ comments and DTS labels (CPU0:) which confuse some parsers
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//.*?$", "", text, flags=re.M)
    text = re.sub(r"^[ \t]*[A-Za-z_][A-Za-z0-9_]*:[ \t]*", "", text, flags=re.M)
    fdt_obj = parse_dts(text)
    raw = fdt_obj.to_dtb(version=17)
    out.write_bytes(raw)
    print(f"[dts_to_dtb] python-fdt -> {out} ({len(raw)} bytes)")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-i", "--input", type=Path, help="DTS path")
    ap.add_argument("-o", "--output", type=Path, required=True)
    args = ap.parse_args()
    repo = Path(__file__).resolve().parents[3]
    dts = args.input or (repo / "corev_apu" / "bootrom" / "ariane-smt2.dts")
    if not dts.is_file():
        print(f"missing {dts}", file=sys.stderr)
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if shutil.which("dtc"):
        compile_with_dtc(dts, args.output)
    else:
        compile_with_fdt(dts, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
