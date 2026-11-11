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
        self._emitted = set()

    def emit(self, word):
        word &= 0xffffffff
        if self.cursor in self._emitted:
            assert self.rom[self.cursor] == 0x00000013, \
                f"program word {self.cursor} (byte {self.cursor * 4:#x}) " \
                "overwrites previously emitted code"
        self.rom[self.cursor] = word
        self._emitted.add(self.cursor)
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

    def sw(self, rs2, imm, rs1):
        assert -2048 <= imm < 2048
        self.emit(((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (2 << 12) |
                  ((imm & 31) << 7) | 0x23)

    def sd(self, rs2, imm, rs1):
        assert -2048 <= imm < 2048
        self.emit(((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (3 << 12) |
                  ((imm & 31) << 7) | 0x23)

    def load(self, rd, imm, rs1, funct3):
        assert -2048 <= imm < 2048
        self.emit(((imm & 0xfff) << 20) | (rs1 << 15) | (funct3 << 12) |
                  (rd << 7) | 0x03)

    def lw(self, rd, imm, rs1):
        self.load(rd, imm, rs1, 2)

    def ld(self, rd, imm, rs1):
        self.load(rd, imm, rs1, 3)

    def li(self, rd, value):
        assert -2048 <= value < 2048
        self.emit(((value & 0xfff) << 20) | (rd << 7) | 0x13)

    def amo(self, funct5, funct3, rd, rs1, rs2):
        # RV64A atomic: no immediate; rs1 holds the full byte address.
        self.emit((funct5 << 27) | (rs2 << 20) | (rs1 << 15) |
                  (funct3 << 12) | (rd << 7) | 0x2f)

    def bne(self, rs1, rs2, target):
        imm = target - self.cursor * 4
        assert imm % 2 == 0 and -4096 <= imm < 4096
        self.emit((((imm >> 12) & 1) << 31) | (((imm >> 5) & 63) << 25) |
                  (rs2 << 20) | (rs1 << 15) | (1 << 12) |
                  (((imm >> 1) & 15) << 8) | (((imm >> 11) & 1) << 7) | 0x63)

    def check_eq(self, rd, rs):
        self.bne(rd, rs, 0x300)

    def jal_self(self):
        self.emit(0x0000006f)

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


# cpu-origin-atomic: dedicated Probe slots for the AMO/LR/SC qualification.
# M runs the full sequence at slots 0..40 then mret->U; U repeats it at slots
# 64..104 and ends with the completion store. Every AMO/LR/SC result is checked
# architecturally; any mismatch branches to the shared 0x300 trap store.
ATOMIC_U_ENTRY = 0x100          # image byte offset of the U section (word 64)
ATOMIC_S_ENTRY = 0xe0           # image byte offset of the S pass-through (word 56)
ATOMIC_DONE = 120               # completion store offset (Probe+120)
ATOMIC_TRAP = 36                # trap store offset (Probe+36), as cpu-origin


def _atomic_sequence(p, base):
    """Emit one privilege's ordinary+atomic sequence at Probe+base slots.

    Every verification load reads a slot last written by an AMO/SC (which never
    store-forward) or by an early ordinary store that has long drained, so no
    load ever targets a just-stored address: that keeps the AXI read count
    deterministic and avoids a store-forward/store-drain race in the LSU."""
    # ordinary store early (slot+0); verified by the late load below
    p.li(6, 0x101)
    p.sd(6, base + 0, 5)
    # amoswap.d: init old, swap new, check old returned + memory updated
    p.li(6, 0x111)
    p.sd(6, base + 8, 5)
    p.li(6, 0x222)
    p.addi(8, 5, base + 8)
    p.amo(1, 3, 9, 8, 6)          # amoswap.d x9,x6,(x8)
    p.li(10, 0x111)
    p.check_eq(9, 10)
    p.ld(7, base + 8, 5)             # AXI read: post-atomic value 0x222
    p.li(10, 0x222)
    p.check_eq(7, 10)
    # amoadd.w: init old32, add, check old returned + memory updated
    p.li(6, 0x44)
    p.sw(6, base + 16, 5)
    p.li(6, 0x33)
    p.addi(8, 5, base + 16)
    p.amo(0, 2, 9, 8, 6)          # amoadd.w x9,x6,(x8)
    p.li(10, 0x44)
    p.check_eq(9, 10)
    p.lw(7, base + 16, 5)            # AXI read: post-atomic value 0x77
    p.li(10, 0x77)
    p.check_eq(7, 10)
    # lr.d + sc.d: init old, lr returns old, sc stores new returns 0
    p.li(6, 0x55)
    p.sd(6, base + 24, 5)
    p.addi(8, 5, base + 24)
    p.amo(2, 3, 9, 8, 0)          # lr.d x9,(x8)
    p.li(10, 0x55)
    p.check_eq(9, 10)
    p.li(6, 0x66)
    p.addi(8, 5, base + 24)
    p.amo(3, 3, 11, 8, 6)         # sc.d x11,x6,(x8): x11==0 on success
    p.bne(11, 0, 0x300)
    p.ld(7, base + 24, 5)            # AXI read: post-sc value 0x66
    p.li(10, 0x66)
    p.check_eq(7, 10)
    # ordinary sd bookend (write-only on AXI)
    p.li(6, 0x77)
    p.sd(6, base + 40, 5)
    # ordinary ld verifying the early store (drained => deterministic AXI read)
    p.ld(7, base + 0, 5)
    p.li(10, 0x101)
    p.check_eq(7, 10)


def build_atomic_program():
    p = _Program()
    # ---- M section ----
    p.address(28, 0x300)
    p.csr(0x305, 28)               # mtvec = trap/fail stub
    # Environment prologue identical to cpu-origin build_program: a custom CSR
    # write plus a PMP region granting full RWX so S/U-mode fetch+data are
    # permitted. Without it the post-return lower-privilege fetch stalls.
    p.addi(28, 0, -1)
    p.emit((2 << 20) | (28 << 15) | (5 << 12) | (28 << 7) | 0x13)
    p.csr(0x3b0, 28)               # pmpaddr0 = all addresses
    p.addi(28, 0, 0x1f)
    p.csr(0x3a0, 28)               # pmpcfg0  = RWX region 0
    p.emit(0x500002b7)              # lui x5,0x50000 -> Probe
    _atomic_sequence(p, 0)
    # descend M -> S -> U stepwise (the proven cpu-origin path). A direct
    # M->U mret was observed to stall commit in this fixture; route through an
    # S pass-through stub instead.
    p.address(28, ATOMIC_S_ENTRY)
    p.csr(0x341, 28)               # mepc = S pass-through
    p.mstatus(0x800)               # MPP=S
    p.emit(0x30200073)             # mret -> S
    assert p.cursor < 64, "machine atomic program overlaps U entry"
    # S pass-through: sepc=U entry, sstatus=0, sret -> U
    p.cursor = ATOMIC_S_ENTRY // 4
    p.address(28, ATOMIC_U_ENTRY)
    p.csr(0x141, 28)               # sepc
    p.csr(0x100, 0)                # sstatus = 0
    p.emit(0x10200073)             # sret -> U
    # ---- U section ----
    p.cursor = 64
    p.emit(0x500002b7)              # lui x5,0x50000 -> Probe (re-assert)
    _atomic_sequence(p, 64)
    # completion: ordinary sd magic -> Probe+ATOMIC_DONE triggers PASS
    p.li(6, 0x5a)
    p.sd(6, ATOMIC_DONE, 5)
    p.jal_self()
    # ---- trap/fail stub at image offset 0x300 ----
    p.cursor = 0x300 // 4
    p.emit(0x500002b7)              # lui x5,0x50000
    p.li(6, 0x7f)
    p.sd(6, ATOMIC_TRAP, 5)         # sd -> Probe+36 trap store
    p.jal_self()
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
