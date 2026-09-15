#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Emit little-endian 32-bit $readmemh words from a firmware .bin."""
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write("usage: bin2hex.py in.bin out.hex\n")
        return 2
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    blob = src.read_bytes()
    pad = (-len(blob)) % 4
    blob += b"\x00" * pad
    lines = [f"// generated from {src.as_posix()}\n"]
    for i in range(0, len(blob), 4):
        word = int.from_bytes(blob[i : i + 4], "little")
        lines.append(f"{word:08x}\n")
    dst.write_text("".join(lines), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
