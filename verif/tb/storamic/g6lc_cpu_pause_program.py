# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Generate first-party RV64IMACZicsr pause-drain firmware; no assembler or simulator.

Store/load-heavy self-checking program for the cpu-pause stage. Runs entirely in
M-mode on the flat Boot ROM + Data window, exercises byte/half/word/dword stores
with architectural readback, AMO and LR/SC pairs, and nested function calls, then
ends by storing a completion magic the bench recognises. Deterministic: the same
input always yields the same final memory image, which the never-paused reference
run must reproduce byte-for-byte.
"""
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

    def _i(self, imm, rs1, f3, rd, op):
        self.emit(((imm & 0xfff) << 20) | (rs1 << 15) | (f3 << 12) |
                  (rd << 7) | op)

    def _s(self, imm, rs2, rs1, f3, op):
        self.emit((((imm >> 5) & 0x7f) << 25) | (rs2 << 20) | (rs1 << 15) |
                  (f3 << 12) | ((imm & 0x1f) << 7) | op)

    def _r(self, f7, rs2, rs1, f3, rd, op):
        self.emit(((f7 & 0x7f) << 25) | (rs2 << 20) | (rs1 << 15) |
                  (f3 << 12) | (rd << 7) | op)

    def addi(self, rd, rs, imm):
        assert -2048 <= imm < 2048
        self._i(imm, rs, 0, rd, 0x13)

    def andi(self, rd, rs, imm):
        assert -2048 <= imm < 2048
        self._i(imm, rs, 7, rd, 0x13)

    def ori(self, rd, rs, imm):
        assert -2048 <= imm < 2048
        self._i(imm, rs, 6, rd, 0x13)

    def slli(self, rd, rs, sh):
        self.emit(((sh & 0x3f) << 20) | (rs << 15) | (1 << 12) |
                  (rd << 7) | 0x13)

    def srli(self, rd, rs, sh):
        self.emit(((sh & 0x3f) << 20) | (rs << 15) | (5 << 12) |
                  (rd << 7) | 0x13)

    def add(self, rd, rs1, rs2):
        self._r(0, rs2, rs1, 0, rd, 0x33)

    def xor(self, rd, rs1, rs2):
        self._r(0, rs2, rs1, 4, rd, 0x33)

    def divu(self, rd, rs1, rs2):
        # M-extension unsigned divide: serial divider (~div_shift iterations,
        # operand-count dependent, no early-out for these operands) -> a
        # deterministic long-latency instruction that parks at the commit head.
        self._r(1, rs2, rs1, 5, rd, 0x33)

    def csr(self, number, rs):
        self.emit((number << 20) | (rs << 15) | (1 << 12) | 0x73)

    def address(self, rd, target):
        here = self.cursor * 4
        self.emit((rd << 7) | 0x17)
        self.addi(rd, rd, target - here)

    def lui(self, rd, imm20):
        self.emit(((imm20 & 0xfffff) << 12) | (rd << 7) | 0x37)

    # ---- stores (S-type) ----
    def sb(self, rs2, imm, rs1):
        self._s(imm, rs2, rs1, 0, 0x23)

    def sh(self, rs2, imm, rs1):
        self._s(imm, rs2, rs1, 1, 0x23)

    def sw(self, rs2, imm, rs1):
        self._s(imm, rs2, rs1, 2, 0x23)

    def sd(self, rs2, imm, rs1):
        self._s(imm, rs2, rs1, 3, 0x23)

    # ---- loads (I-type) ----
    def lh(self, rd, imm, rs1):
        self._i(imm, rs1, 1, rd, 0x03)

    def lw(self, rd, imm, rs1):
        self._i(imm, rs1, 2, rd, 0x03)

    def ld(self, rd, imm, rs1):
        self._i(imm, rs1, 3, rd, 0x03)

    def lbu(self, rd, imm, rs1):
        self._i(imm, rs1, 4, rd, 0x03)

    def lhu(self, rd, imm, rs1):
        self._i(imm, rs1, 5, rd, 0x03)

    def li(self, rd, value):
        assert -2048 <= value < 2048
        self.addi(rd, 0, value)

    def amo(self, funct5, funct3, rd, rs1, rs2):
        self.emit((funct5 << 27) | (rs2 << 20) | (rs1 << 15) |
                  (funct3 << 12) | (rd << 7) | 0x2f)

    def lr(self, rd, rs1, funct3):
        self.emit((2 << 27) | (rs1 << 15) | (funct3 << 12) |
                  (rd << 7) | 0x2f)

    def sc(self, funct3, rd, rs1, rs2):
        self.emit((3 << 27) | (rs2 << 20) | (rs1 << 15) |
                  (funct3 << 12) | (rd << 7) | 0x2f)

    def _branch(self, f3, rs1, rs2, target):
        imm = target - self.cursor * 4
        assert imm % 2 == 0 and -4096 <= imm < 4096
        self.emit((((imm >> 12) & 1) << 31) | (((imm >> 5) & 63) << 25) |
                  (rs2 << 20) | (rs1 << 15) | (f3 << 12) |
                  (((imm >> 1) & 15) << 8) | (((imm >> 11) & 1) << 7) | 0x63)

    def bne(self, rs1, rs2, target):
        self._branch(1, rs1, rs2, target)

    def blt(self, rs1, rs2, target):
        self._branch(4, rs1, rs2, target)

    def jal(self, rd, target):
        imm = target - self.cursor * 4
        assert imm % 2 == 0 and -1048576 <= imm < 1048576
        self.emit((((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3ff) << 21) |
                  (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xff) << 12) |
                  (rd << 7) | 0x6f)

    def jal_placeholder(self, rd):
        """Emit jal rd,+0 and return its word index for later patching."""
        idx = self.cursor
        self.emit((rd << 7) | 0x6f)
        return idx

    def patch_jal(self, idx, target_off):
        imm = target_off - idx * 4
        assert imm % 2 == 0 and -1048576 <= imm < 1048576
        self.rom[idx] = ((((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3ff) << 21) |
                         (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xff) << 12) |
                         (1 << 7) | 0x6f) & 0xffffffff

    def jalr(self, rd, rs1, imm=0):
        self._i(imm, rs1, 0, rd, 0x67)

    def jal_self(self):
        self.emit(0x0000006f)


# Register plan (single-level calls; subroutines preserve x5/x6/x2):
#   x5 = Data base, x6 = loop counter i, x2 = bound, x9 = rotating offset,
#   x7/x8/x10/x11/x12 = scratch, x1 = ra.
DATA_BASE = 0x5000_0000
DONE_OFF = 0x780          # completion store -> Data+0x780 (bench PASS)
TRAPD_OFF = 0x7F8         # trap store     -> Data+0x7F8 (bench FAIL)
CODE_TRAP = 0x300         # image byte offset of the trap stub
ITER = 220                # loop iterations -> thousands of committed stores
# Dedicated 48-byte store-burst area: above _work_sub's rotating slots
# (max ~0x5F0) and below DONE(0x780)/TRAPD(0x7F8). 12 back-to-back stores per
# iteration saturate the store_buffer commit queue (DEPTH_COMMIT=4) so several
# committed stores sit without AW-valid -> exposes the drained_o
# no_st_pending_commit term (mutant k1) under bus back-pressure.
BURST_OFF = 0x600


def _burst_values(p):
    """x20..x23 = i + {0x101,0x202,0x303,0x404}: deterministic, <2^16 so the
    narrow readback loads (lbu/lhu/lw) compare equal to the source register."""
    p.addi(20, 6, 0x101)
    p.addi(21, 6, 0x202)
    p.addi(22, 6, 0x303)
    p.addi(23, 6, 0x404)


def _burst(p):
    """>=12 back-to-back mixed-width stores to distinct burst lanes; no
    intervening loads/branches. Values derive from the loop counter x6=i."""
    p.addi(8, 5, BURST_OFF)            # x8 = Data + burst base
    _burst_values(p)
    p.sd(20, 0x00, 8)
    p.sw(21, 0x08, 8)
    p.sh(22, 0x0C, 8)
    p.sb(23, 0x0E, 8)
    p.sd(21, 0x10, 8)
    p.sw(22, 0x18, 8)
    p.sh(23, 0x1C, 8)
    p.sb(20, 0x1E, 8)
    p.sd(22, 0x20, 8)
    p.sw(23, 0x28, 8)
    p.sh(20, 0x2C, 8)
    p.sb(21, 0x2E, 8)
    p.jalr(0, 1, 0)                    # ret


def _burst_verify(p):
    """Readback of every burst lane after the intervening work; x24=loaded,
    x25=masked expected for the byte lanes. Traps on any mismatch."""
    p.addi(8, 5, BURST_OFF)
    _burst_values(p)
    p.ld(24, 0x00, 8);  p.bne(24, 20, CODE_TRAP)              # sd x20
    p.lw(24, 0x08, 8);  p.bne(24, 21, CODE_TRAP)              # sw x21
    p.lhu(24, 0x0C, 8); p.bne(24, 22, CODE_TRAP)              # sh x22
    p.lbu(24, 0x0E, 8); p.andi(25, 23, 0xff); p.bne(24, 25, CODE_TRAP)  # sb x23
    p.ld(24, 0x10, 8);  p.bne(24, 21, CODE_TRAP)              # sd x21
    p.lw(24, 0x18, 8);  p.bne(24, 22, CODE_TRAP)              # sw x22
    p.lhu(24, 0x1C, 8); p.bne(24, 23, CODE_TRAP)              # sh x23
    p.lbu(24, 0x1E, 8); p.andi(25, 20, 0xff); p.bne(24, 25, CODE_TRAP)  # sb x20
    p.ld(24, 0x20, 8);  p.bne(24, 22, CODE_TRAP)              # sd x22
    p.lw(24, 0x28, 8);  p.bne(24, 23, CODE_TRAP)              # sw x23
    p.lhu(24, 0x2C, 8); p.bne(24, 20, CODE_TRAP)              # sh x20
    p.lbu(24, 0x2E, 8); p.andi(25, 21, 0xff); p.bne(24, 25, CODE_TRAP)  # sb x21
    p.jalr(0, 1, 0)                    # ret


def _work_sub(p):
    """Subroutine: store/readback + AMO + LR/SC at Data offset x9; ret via ra.

    x9 = byte offset into the Data window. x8 = Data + x9. Returns the index of
    the jal it emits to _leaf (for the caller to patch)."""
    p.addi(13, 1, 0)                # save caller ra across nested _leaf call
    p.add(8, 5, 9)                  # x8 = Data + off
    p.addi(7, 6, 0x55)
    p.xor(7, 7, 6)
    p.slli(7, 7, 3)                 # x7 = ((i+0x55)^i)<<3
    p.sb(7, 0, 8)
    p.lbu(10, 0, 8)
    p.andi(11, 7, 0xff)
    p.bne(10, 11, CODE_TRAP)
    p.sh(7, 2, 8)
    p.lhu(10, 2, 8)
    p.slli(11, 7, 48)               # x11 = x7 << 48
    p.srli(11, 11, 48)              # x11 = x7 & 0xffff
    p.bne(10, 11, CODE_TRAP)
    p.sw(7, 4, 8)
    p.lw(10, 4, 8)
    p.bne(10, 7, CODE_TRAP)
    p.sd(7, 8, 8)
    p.ld(10, 8, 8)
    p.bne(10, 7, CODE_TRAP)
    # amoswap.d @ +16 : init 0x55, swap 0xa5, expect old=0x55 then mem=0xa5
    p.li(7, 0x55)
    p.sd(7, 16, 8)
    p.li(7, 0xa5)
    p.addi(12, 8, 16)
    p.amo(1, 3, 9, 12, 7)
    p.li(10, 0x55)
    p.bne(9, 10, CODE_TRAP)
    p.ld(10, 16, 8)
    p.li(11, 0xa5)
    p.bne(10, 11, CODE_TRAP)
    # amoadd.w @ +24 : init 0x33, add 0x11, expect old=0x33
    p.li(7, 0x33)
    p.sw(7, 24, 8)
    p.li(7, 0x11)
    p.addi(12, 8, 24)
    p.amo(0, 2, 9, 12, 7)
    p.li(10, 0x33)
    p.bne(9, 10, CODE_TRAP)
    # lr.d + sc.d @ +32 : init 0x77, lr->0x77, sc 0x99 -> x11==0
    p.li(7, 0x77)
    p.sd(7, 32, 8)
    p.addi(12, 8, 32)
    p.lr(9, 12, 3)
    p.li(10, 0x77)
    p.bne(9, 10, CODE_TRAP)
    p.li(7, 0x99)
    p.sc(3, 11, 12, 7)
    p.bne(11, 0, CODE_TRAP)
    # depth-2 nested call to _leaf
    leaf_jal = p.jal_placeholder(1)
    p.addi(1, 13, 0)                # _leaf returns here; restore main-loop ra
    p.jalr(0, 1, 0)                 # ret to main-loop caller
    return leaf_jal


def _leaf(p):
    p.li(7, 0x6b)
    p.sd(7, 0x218, 5)               # Data+0x218 = 0x6b
    p.jalr(0, 1, 0)                 # ret


def build_program():
    p = _Program()
    # ---- M-mode prologue (same CSR/PMP setup as the proven cpu-origin) ----
    p.address(28, CODE_TRAP)        # mtvec -> trap stub at image 0x300
    p.csr(0x305, 28)
    p.addi(28, 0, -1)
    p.emit((2 << 20) | (28 << 15) | (5 << 12) | (28 << 7) | 0x13)
    p.csr(0x3b0, 28)                # pmpaddr0 = all addresses
    p.addi(28, 0, 0x1f)
    p.csr(0x3a0, 28)                # pmpcfg0  = RWX region 0
    p.lui(5, DATA_BASE >> 12)       # x5 = Data base
    p.li(2, ITER)                   # x2 = bound
    p.li(6, 0)                      # x6 = i = 0
    # ---- main loop ----
    loop_head = p.cursor * 4          # byte offset (branch targets are bytes)
    p.andi(9, 6, 0x1f)              # x9 = i & 31
    p.slli(10, 9, 5)
    p.slli(11, 9, 4)
    p.add(9, 10, 11)                # x9 = (i&31)*48  (0..1488)
    burst_call = p.jal_placeholder(1)   # -> _burst (12 committed stores)
    sub_call = p.jal_placeholder(1)     # -> _work_sub (the "other work")
    verify_call = p.jal_placeholder(1)  # -> _burst_verify (readback checks)
    p.addi(6, 6, 1)
    p.blt(6, 2, loop_head)
    # ---- completion ----
    p.li(7, 0x5a)
    p.sd(7, DONE_OFF, 5)            # Data+0x780 = 0x5a -> bench PASS
    p.jal_self()
    # ---- subroutines (emitted after main; all code must stay < CODE_TRAP) ----
    burst_off = p.cursor * 4
    _burst(p)
    burstv_off = p.cursor * 4
    _burst_verify(p)
    sub_off = p.cursor * 4
    leaf_jal = _work_sub(p)
    leaf_off = p.cursor * 4
    _leaf(p)
    p.patch_jal(burst_call, burst_off)    # main jal -> _burst
    p.patch_jal(sub_call, sub_off)        # main jal -> _work_sub
    p.patch_jal(verify_call, burstv_off)  # main jal -> _burst_verify
    p.patch_jal(leaf_jal, leaf_off)       # _work_sub jal -> _leaf
    assert p.cursor * 4 <= CODE_TRAP, "code overlaps trap stub"
    # ---- trap stub at image CODE_TRAP ----
    p.cursor = CODE_TRAP // 4
    p.lui(5, DATA_BASE >> 12)
    p.li(7, 0x7f)
    p.sd(7, TRAPD_OFF, 5)           # Data+0x7F8 = 0x7f -> bench FAIL
    p.jal_self()
    return "".join(f"{word:08x}\n" for word in p.rom).encode("ascii")


# ---- pause-independent load_unit WAIT_PAGE_OFFSET regression -------------
# The cpu-pause store->load defect (non-cacheable narrow store still
# speculative while a wider load of the same lane issues to the D$) is a
# latent core bug, not pause-specific: ANY slow older instruction parked at
# the commit head holds the store speculative long enough. This directed
# program reproduces it with +nopause: a ~61-iteration serial `divu` is the
# commit-head blocker, immediately followed by a narrow store to the
# non-cacheable Data window and a wider/equal load of the same lane. On the
# fixed RTL the load waits in WAIT_PAGE_OFFSET until the store drains and
# reads the store value; on the pre-fix RTL it re-issues to the D$ after one
# cycle and reads the stale (still-zero) bytes -> self-check traps.
#
# Register plan: x5 = Data base, x20/x21 = divu operands, x22 = divu result
# (unused, only there to occupy the commit head), x23 = store value / expected
# load, x24 = loaded value. Every slot starts zeroed, the store covers the low
# bytes and the wider load's uncovered high bytes stay zero, so the correct
# loaded value always equals the store value x23 (all chosen widths avoid
# sign-extension surprises: only lbu/lhu/lwu-free unsigned-equivalent loads are
# used where the covered byte count leaves the sign bit clear).
DIRECTED_SLOTS = (0x100, 0x108, 0x110, 0x118, 0x120, 0x128)


def _directed_case(p, off, store_m, load_m):
    """One hazard case at Data+off. x23 must already hold the store value."""
    p.divu(22, 20, 21)                    # ~61-iter divide -> commit head
    getattr(p, store_m)(23, off, 5)       # narrow store -> non-cacheable Data
    getattr(p, load_m)(24, off, 5)        # wider/equal load, same lane
    p.bne(24, 23, CODE_TRAP)              # stale read -> trap


def build_directed_program():
    p = _Program()
    # ---- M-mode prologue (identical to build_program) ----
    p.address(28, CODE_TRAP)
    p.csr(0x305, 28)
    p.addi(28, 0, -1)
    p.emit((2 << 20) | (28 << 15) | (5 << 12) | (28 << 7) | 0x13)
    p.csr(0x3b0, 28)
    p.addi(28, 0, 0x1f)
    p.csr(0x3a0, 28)
    p.lui(5, DATA_BASE >> 12)             # x5 = Data base
    # divu operands: 0xFFFF...F / 7 -> div_shift=61, no early-out, ~61 iters.
    p.li(20, -1)
    p.li(21, 7)
    # ---- hazard cases: narrow store -> wider load, several alignments ----
    p.li(23, 0x0A5);  _directed_case(p, DIRECTED_SLOTS[0], "sb", "lhu")
    p.li(23, 0x03C);  _directed_case(p, DIRECTED_SLOTS[1], "sb", "lw")
    p.li(23, 0x077);  _directed_case(p, DIRECTED_SLOTS[2], "sb", "ld")
    p.li(23, 0x7FF);  _directed_case(p, DIRECTED_SLOTS[3], "sh", "ld")
    p.lui(23, 0x12345); p.addi(23, 23, 0x678)   # x23 = 0x12345678
    _directed_case(p, DIRECTED_SLOTS[4], "sw", "ld")
    p.li(23, 0x5AA);  _directed_case(p, DIRECTED_SLOTS[5], "sh", "lw")
    # ---- completion ----
    p.li(7, 0x5a)
    p.sd(7, DONE_OFF, 5)                  # Data+0x780 = 0x5a -> bench PASS
    p.jal_self()
    assert p.cursor * 4 <= CODE_TRAP, "directed code overlaps trap stub"
    # ---- trap stub at image CODE_TRAP ----
    p.cursor = CODE_TRAP // 4
    p.lui(5, DATA_BASE >> 12)
    p.li(7, 0x7f)
    p.sd(7, TRAPD_OFF, 5)                 # Data+0x7F8 = 0x7f -> bench FAIL
    p.jal_self()
    return "".join(f"{word:08x}\n" for word in p.rom).encode("ascii")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", required=True, type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    out = args.output_root.resolve()
    if not out.is_relative_to(repo / "build-platform/workspace"):
        parser.error("output must be contained in build-platform/workspace")
    image = build_program()
    out.mkdir(exist_ok=False)
    (out / "program.hex").write_bytes(image)
    report = {
        "status": "prepared", "qualification": False,
        "scope": "cpu-pause store/load/AMO/SC/call firmware only",
        "iterations": ITER, "done_off": DONE_OFF, "trapd_off": TRAPD_OFF,
        "code_trap": CODE_TRAP, "data_base": DATA_BASE,
        "program_sha256": hashlib.sha256(image).hexdigest(),
        "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    }
    (out / "result.json").write_text(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
