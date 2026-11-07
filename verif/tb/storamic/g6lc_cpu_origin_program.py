# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Generate first-party RV64I provenance firmware; no assembler or simulator."""
import argparse
import hashlib
import json
from pathlib import Path


class _Program:
    def __init__(self):
        self.rom = [0x00000013] * 1024
        self.cursor = 0

    def emit(self, word):
        self.rom[self.cursor] = word & 0xffffffff
        self.cursor += 1

    def addi(self, rd, rs, imm):
        assert -2048 <= imm < 2048
        self.emit(((imm & 0xfff) << 20) | (rs << 15) | (rd << 7) | 0x13)

    def csr(self, number, rs):
        self.emit((number << 20) | (rs << 15) | (1 << 12) | 0x73)

    def address(self, rd, target):
        here = self.cursor * 4
        self.emit((rd << 7) | 0x17)
        self.addi(rd, rd, target - here)

    def store(self, offset):
        self.emit(((offset >> 5) << 25) | (6 << 20) | (5 << 15) | (2 << 12) |
                  ((offset & 31) << 7) | 0x23)

    def load_verify(self, offset):
        self.emit((offset << 20) | (5 << 15) | (2 << 12) | (7 << 7) | 0x03)
        imm = 0x300 - self.cursor * 4
        assert imm % 2 == 0 and -4096 <= imm < 4096
        self.emit((((imm >> 12) & 1) << 31) | (((imm >> 5) & 63) << 25) |
                  (6 << 20) | (7 << 15) | (1 << 12) | (((imm >> 1) & 15) << 8) |
                  (((imm >> 11) & 1) << 7) | 0x63)
        self.emit(0x0ff0000f)

    def mstatus(self, value):
        high = (value + 0x800) >> 12
        low = value - (high << 12)
        self.emit((high << 12) | (28 << 7) | 0x37)
        self.addi(28, 28, low)
        self.csr(0x300, 28)


def build_program(extra_mprv=False):
    p = _Program()
    p.address(28, 0x300)
    p.csr(0x305, 28)
    p.addi(28, 0, -1)
    p.emit((2 << 20) | (28 << 15) | (5 << 12) | (28 << 7) | 0x13)
    p.csr(0x3b0, 28)
    p.addi(28, 0, 0x1f)
    p.csr(0x3a0, 28)
    p.emit(0x500002b7)
    p.addi(6, 0, 0x11)
    p.store(0)
    p.load_verify(0)
    p.mstatus(0x20800)  # MPRV, MPP=S; instruction execution remains M.
    p.addi(6, 0, 0x44)
    p.store(24)
    p.load_verify(24)
    if extra_mprv:
        for status, offset, value in ((0x20000, 40, 0x66), (0x21800, 48, 0x77)):
            p.mstatus(status)
            p.addi(6, 0, value)
            p.store(offset)
            p.load_verify(offset)
    p.csr(0x300, 0)
    p.address(28, 0x100)
    p.csr(0x341, 28)
    p.mstatus(0x800)
    p.emit(0x30200073)
    assert p.cursor < 64, "machine program overlaps supervisor entry"
    p.cursor = 64
    p.addi(6, 0, 0x22)
    p.store(8)
    p.load_verify(8)
    p.address(28, 0x200)
    p.csr(0x141, 28)
    p.csr(0x100, 0)
    p.emit(0x10200073)
    assert p.cursor < 128
    p.cursor = 128
    p.addi(6, 0, 0x33)
    p.store(16)
    p.load_verify(16)
    p.addi(6, 0, 0x55)
    p.store(32)
    p.emit(0x0000006f)
    p.cursor = 192
    p.emit(0x500002b7)
    p.addi(6, 0, 0x7f)
    p.store(36)
    p.emit(0x0000006f)
    return "".join(f"{word:08x}\n" for word in p.rom).encode("ascii")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--extra-mprv", action="store_true")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    out = args.output_root.resolve()
    if not out.is_relative_to(repo / "build-platform/workspace"):
        parser.error("output must be contained in build-platform/workspace")
    image = build_program(args.extra_mprv)
    out.mkdir(exist_ok=False)
    (out / "program.hex").write_bytes(image)
    report = {
        "status": "prepared", "qualification": False, "scope": "CPU origin firmware only",
        "extra_mprv": args.extra_mprv, "expected_writes": 7 if args.extra_mprv else 5,
        "expected_reads": 6 if args.extra_mprv else 4,
        "coverage": ["M", "S", "U", "MPRV/MPP=S"] +
                    (["MPRV/MPP=U", "MPRV/MPP=M"] if args.extra_mprv else []),
        "program_sha256": hashlib.sha256(image).hexdigest(),
        "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    }
    (out / "result.json").write_text(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
