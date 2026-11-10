# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Firmware for real tdata-trigger debug entry through the CPU.

Mechanisms (mcontrol6 type 6, action=1 debug mode), all reusing the
external-halt entry (cause 3) as a first entry that programs the trigger:
  exec  — execute-address match on the firmware target T (Probe+48 store)
  store — store-address match on Probe+48
  load  — load-address match on a firmware load of Probe+52
  deny  — SDTRIG=0 profile: csrr tselect must take illegal-instruction
          (mcause=2) with no trigger debug entry.

First entry checks DCSR/DPC like the halt image, writes tselect/tdata2/
tdata1 (dmode=1, action=1, m/s/u per entry privilege), presets x6=0x33 and
DRETs to T=Boot+0x140. The second entry must have dcsr.cause=2 (trigger);
the handler records DPC at Probe+56, clears tdata1's privilege bits,
sets DPC=Boot+0x100 and DRETs to the completion path.
"""
import argparse
import hashlib
import json
from pathlib import Path

from g6lc_cpu_debug_program import (
    _Program, _branch, _branch_to, image, fail,
    CSRR_DCSR_X28, CSRR_DPC_X28, ANDI_DCSR_1C3, CSRRC_DCSR_X7, DRET,
)

MECHANISMS = ("exec", "store", "load", "deny")
MECHANISM_IDS = {"exec": 3, "store": 4, "load": 5, "deny": 6}
FIRMWARE_TARGET = 0x140
DEBUG_TARGET = 0x80000000 + FIRMWARE_TARGET
T_PC = DEBUG_TARGET
T_STORE_VADDR = 0x50000030   # Probe+48
T_LOAD_VADDR = 0x50000034    # Probe+52
# mcontrol6 tdata1 layout (trigger_module.sv write path, XLEN64):
#   [63:60]=6 type, [59]=dmode, [25]=hit1, [22]=hit0, [21]=select,
#   [18:16]=size, [15:12]=action, [10:7]=match, [6]=m, [4]=s, [3]=u,
#   [2]=execute, [1]=store, [0]=load.
TDATA1_TYPE_DMODE = (6 << 60) | (1 << 59)
TDATA1_HIT0_ACTION = (1 << 22) | (1 << 12)
TRIG_PRIV_BIT = {0: 1 << 3, 3: 1 << 6}
TRIG_ACCESS_BIT = {"exec": 1 << 2, "store": 1 << 1, "load": 1 << 0}
TRIG_COMPARE = {"exec": T_PC, "store": T_STORE_VADDR, "load": T_LOAD_VADDR}
# CSR numbers (riscv_pkg.sv): tselect=0x7A0 tdata1=0x7A1 tdata2=0x7A2
#   mcause=0x342 mepc=0x341.
CSR_TSELECT = 0x7A0
CSR_TDATA1 = 0x7A1
CSR_TDATA2 = 0x7A2
CSR_MCAUSE = 0x342
CSR_MEPC = 0x341
# Expected AXI-visible counts for the interpreter pass marker.
COUNTS = {  # writes, reads, debug_writes, debug_reads, csr_checks
    "exec": (8, 4, 4, 2, 2), "store": (8, 4, 4, 2, 2), "load": (7, 4, 4, 2, 2),
    "deny": (4, 0, 0, 0, 0),
}


def _tdata1_low(mechanism, entry_privilege, disarm=False):
    """Low 23 bits of the mcontrol6 tdata1 value (everything below bit 23)."""
    value = TDATA1_HIT0_ACTION | TRIG_ACCESS_BIT[mechanism]
    if not disarm:
        value |= TRIG_PRIV_BIT[entry_privilege]
    return value


def _emit_lui_addi(program, rd, value):
    """Load a non-negative value < 2**31 into rd via lui+addi (mstatus pattern)."""
    assert 0 <= value < (1 << 31)
    high = (value + 0x800) >> 12
    low = value - (high << 12)
    program.emit((high << 12) | (rd << 7) | 0x37)          # lui rd, high
    program.addi(rd, rd, low)                              # addi rd, rd, low


def _emit_tdata1(program, rd, mechanism, entry_privilege, disarm=False):
    """Build the full 64-bit mcontrol6 tdata1 in rd (x28/x29 free to clobber
    x28 only; uses rd and rd+1)."""
    other = 29 if rd == 28 else 28
    program.addi(rd, 0, 6)                                 # x = 6
    program.emit((60 << 20) | (rd << 15) | (1 << 12) | (rd << 7) | 0x13)  # slli rd,rd,60
    # OR in dmode (bit 59): 1<<59 = add (6<<60) + (1<<59) is disjoint -> add.
    program.addi(other, 0, 1)
    program.emit((59 << 20) | (other << 15) | (1 << 12) | (other << 7) | 0x13)  # slli
    program.emit((other << 20) | (rd << 15) | (rd << 7) | 0x33)   # add rd, rd, other
    _emit_lui_addi(program, other, _tdata1_low(mechanism, entry_privilege, disarm))
    program.emit((other << 20) | (rd << 15) | (rd << 7) | 0x33)   # add rd, rd, other


def _emit_tdata2(program, mechanism):
    """Load the mcontrol6 compare value into x29 and write tdata2."""
    value = TRIG_COMPARE[mechanism]
    if value == T_PC:
        program.addi(29, 10, 0x40)      # x10 = Boot+0x100 -> +0x40 = T
    elif value == T_STORE_VADDR:
        program.emit((0x50000 << 12) | (29 << 7) | 0x37)   # lui x29, 0x50000
        program.addi(29, 29, 0x30)
    else:
        program.emit((0x50000 << 12) | (29 << 7) | 0x37)   # lui x29, 0x50000
        program.addi(29, 29, 0x34)
    program.csr(CSR_TDATA2, 29)


def build_trigger_program(entry_privilege=3, mechanism="exec"):
    """Return (normal, debug) images for one trigger mechanism.

    entry_privilege: 0 (U) or 3 (M); mechanism: exec/store/load.
    """
    if mechanism not in ("exec", "store", "load"):
        raise ValueError("mechanism must be exec, store or load")
    if entry_privilege not in (0, 3):
        raise ValueError("trigger entry privilege must be U or M")
    normal, debug = _Program(), _Program()
    # ---- normal (firmware) image: identical boot to the halt/ebreak image ----
    normal.address(28, 0x300)
    normal.csr(0x305, 28)              # mtvec = Boot+0x300
    if entry_privilege != 3:
        normal.addi(28, 0, -1)
        normal.emit((2 << 20) | (28 << 15) | (5 << 12) | (28 << 7) | 0x13)
        normal.csr(0x3b0, 28)          # all-address NAPOT RWX for S/U
        normal.addi(28, 0, 0x1f)
        normal.csr(0x3a0, 28)
    normal.address(10, 0x100)          # x10 = Boot+0x100 resume path
    normal.emit(0x500002b7)            # lui x5, 0x50000 -> Probe base
    if entry_privilege != 3:
        normal.address(28, 0x180)
        normal.csr(0x341, 28)          # mepc = Boot+0x180
        normal.mstatus(entry_privilege << 11)
        normal.emit(0x30200073)        # mret -> drop to entry privilege
        assert normal.cursor < 64
        normal.cursor = 0x180 // 4
    normal.addi(6, 0, 0x11)
    normal.store(0)                    # Probe+0 = 0x11 -> debug_req
    normal.emit(0x0000006f)            # spin until debug entry
    normal.cursor = 64
    normal.addi(6, 0, 0x11)
    normal.load_verify(0)
    normal.addi(6, 0, 0x22)
    normal.store(32)
    normal.load_verify(32)
    normal.addi(6, 0, 0x55)
    normal.store(40)
    normal.emit(0x0000006f)
    # Firmware target T at Boot+0x140.
    normal.cursor = FIRMWARE_TARGET // 4
    if mechanism == "load":
        normal.emit((52 << 20) | (5 << 15) | (2 << 12) | (6 << 7) | 0x03)  # lw x6,52(x5)
    else:
        normal.store(48)               # sw x6,48(x5); x6=0x33 preset by handler
    normal.emit(0x0000006f)            # T+4: hang if ever reached (must not)
    fail(normal, 0x300)

    # ---- debug image ----
    fail(debug, 0x300)
    debug.cursor = 0x800 // 4
    debug.emit(0x0400006f)             # halt entry -> handler at 0x840
    fail(debug, 0x808)                 # debug exception vector
    debug.cursor = 0x840 // 4
    # Dispatch on dcsr.cause|prv: cause 3 = first (external-halt) entry,
    # cause 2 = second (trigger) entry; anything else fails.
    debug.emit(CSRR_DCSR_X28)
    debug.emit(ANDI_DCSR_1C3)
    debug.addi(6, 0, 0xc0 | entry_privilege)
    beq_slot = debug.cursor
    debug.emit(0)                      # patched -> first-entry path
    debug.addi(6, 0, 0x80 | entry_privilege)   # cause=2 | saved priv
    _branch_to(debug, 1, 28, 6, 0x300) # cause mismatch -> fail
    # Second entry (trigger): record DPC, disarm tdata1, resume at 0x100.
    debug.emit(CSRR_DPC_X28)
    debug.addi(6, 28, 0)
    debug.store(56)                    # Probe+56 = dpc (low 32)
    _emit_tdata1(debug, 28, mechanism, entry_privilege, disarm=True)
    debug.csr(CSR_TDATA1, 28)          # clear privilege bits -> disabled
    debug.csr(0x7B1, 10)               # dpc = x10 = Boot+0x100
    debug.emit(DRET)
    # First entry: halt-image checks, then program the trigger and DRET to T.
    first_entry = debug.cursor * 4
    debug.rom[beq_slot] = _branch(0, 28, 6, first_entry - beq_slot * 4)
    debug.emit(CSRR_DCSR_X28)
    debug.addi(6, 28, 0)
    debug.store(8)
    debug.load_verify(8)
    debug.emit(ANDI_DCSR_1C3)
    debug.addi(6, 0, 0xc0 | entry_privilege)
    _branch_to(debug, 1, 28, 6, 0x300)
    debug.emit(CSRR_DPC_X28)
    debug.addi(6, 28, 0)
    debug.store(24)
    debug.addi(6, 0, 0x66)
    debug.store(16)
    debug.load_verify(16)
    # Program the trigger: tselect=0, tdata2=compare, tdata1=mcontrol6 arm.
    debug.csr(CSR_TSELECT, 0)          # csrw tselect, x0 -> select trigger 0
    _emit_tdata2(debug, mechanism)
    debug.csr(CSR_TDATA2, 29)          # csrw tdata2, x29
    _emit_tdata1(debug, 28, mechanism, entry_privilege)
    debug.csr(CSR_TDATA1, 28)          # csrw tdata1, x28 -> arm (flush)
    debug.addi(28, 10, 0x40)           # x28 = x10+0x40 = T
    debug.csr(0x7B1, 28)               # dpc = T
    debug.addi(6, 0, 0x33)             # value stored at Probe+48 by target
    debug.emit(DRET)
    return image(normal), image(debug)


def build_denial_program(entry_privilege=3):
    """SDTRIG=0 profile: M firmware executes csrr tselect which must raise
    illegal-instruction (mcause=2). A minimal trap handler records mcause at
    Probe+44, checks it is 2, bumps mepc and mrets back to completion."""
    if entry_privilege != 3:
        raise ValueError("denial profile is M-mode only")
    normal, debug = _Program(), _Program()
    normal.address(28, 0x300)
    normal.csr(0x305, 28)              # mtvec = Boot+0x300 real trap handler
    normal.address(10, 0x100)
    normal.emit(0x500002b7)            # lui x5, 0x50000 -> Probe
    normal.cursor = 0x100 // 4
    # csrr x6, tselect (0x7A0): CSRRS x6, tselect, x0 -> illegal when SDTRIG=0.
    normal.emit((CSR_TSELECT << 20) | (2 << 12) | (6 << 7) | 0x73)
    # ---- trap handler at 0x300 ----
    assert normal.cursor * 4 < 0x140
    normal.cursor = 0x300 // 4
    normal.emit((CSR_MCAUSE << 20) | (2 << 12) | (6 << 7) | 0x73)   # csrr x6,mcause
    normal.store(44)                   # Probe+44 = mcause (firmware origin)
    normal.addi(7, 0, 2)
    _branch_to(normal, 1, 6, 7, 0x2C0)  # bne x6,x7 -> fail stub if != 2
    normal.emit((CSR_MEPC << 20) | (2 << 12) | (7 << 7) | 0x73)     # csrr x7,mepc
    normal.addi(7, 7, 4)
    normal.csr(CSR_MEPC, 7)            # csrw mepc, x7
    normal.emit(0x30200073)            # mret -> mepc+4
    # fail stub at 0x2C0: Probe+36 = 0x7f then hang (reuse fail layout).
    fail(normal, 0x2C0)
    # ---- resume path at mepc+4 = 0x104 (csrr at 0x100) ----
    normal.cursor = 0x104 // 4
    normal.addi(6, 0, 0x22)
    normal.store(8)
    normal.addi(6, 0, 0x55)
    normal.store(32)
    normal.addi(6, 0, 0x77)
    normal.store(40)
    normal.emit(0x0000006f)
    # debug image is never fetched (debug_req never fires); keep it minimal.
    fail(debug, 0x300)
    debug.cursor = 0x800 // 4
    debug.emit(0x0400006f)
    fail(debug, 0x808)
    return image(normal), image(debug)


def program_metadata(entry_privilege, mechanism):
    if mechanism == "deny":
        normal, debug = build_denial_program(entry_privilege)
    else:
        normal, debug = build_trigger_program(entry_privilege, mechanism)
    counts = COUNTS[mechanism]
    return {
        "entry_privilege": entry_privilege, "mprv": 0,
        "mechanism": mechanism, "mechanism_id": MECHANISM_IDS[mechanism],
        "expected_writes": counts[0], "expected_reads": counts[1],
        "debug_writes": counts[2], "debug_reads": counts[3],
        "csr_checks": counts[4],
        "second_entry": None if mechanism == "deny" else {
            "firmware_target": f"0x{DEBUG_TARGET:08x}",
            "expected_cause": 2,
            "compare": f"0x{TRIG_COMPARE[mechanism]:08x}",
        },
        "program_sha256": hashlib.sha256(normal).hexdigest(),
        "debug_sha256": hashlib.sha256(debug).hexdigest(),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--entry-privilege", type=int, choices=(0, 3), default=3)
    parser.add_argument("--mechanism", choices=MECHANISMS, default="exec")
    args = parser.parse_args()
    out = args.output_root.resolve()
    repo = Path(__file__).resolve().parents[3]
    if not out.is_relative_to(repo / "build-platform/workspace"):
        parser.error("output must be contained in build-platform/workspace")
    if args.mechanism == "deny":
        normal, debug = build_denial_program(args.entry_privilege)
    else:
        normal, debug = build_trigger_program(args.entry_privilege, args.mechanism)
    out.mkdir(exist_ok=False)
    (out / "program.hex").write_bytes(normal)
    (out / "debug.hex").write_bytes(debug)
    report = {
        "status": "prepared", "qualification": False, "scope": "tdata trigger firmware only",
        "program_sha256": hashlib.sha256(normal).hexdigest(),
        "debug_sha256": hashlib.sha256(debug).hexdigest(),
        "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "halt_address": 0x800, "exception_address": 0x808, "resume_address": 0x80000100,
        "entry_privilege": args.entry_privilege,
    }
    report.update({k: v for k, v in program_metadata(
        args.entry_privilege, args.mechanism).items()
        if k not in ("entry_privilege", "program_sha256", "debug_sha256")})
    (out / "result.json").write_text(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
