# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Firmware for real external-debug entry, CSR checks and architectural DRET."""
import argparse
import hashlib
import json
from pathlib import Path

from g6lc_cpu_origin_program import _Program

MECHANISMS = ("halt", "ebreak", "step")
MECHANISM_IDS = {"halt": 0, "ebreak": 1, "step": 2}
# Second-entry firmware target inside the normal ROM image (Boot+0x140).
FIRMWARE_TARGET = 0x140
DEBUG_TARGET = 0x80000000 + FIRMWARE_TARGET
EXPECTED_DPC = DEBUG_TARGET + 4
EXPECTED_CAUSES = {"halt": 3, "ebreak": 1, "step": 4}
# CSR encodings used by the mechanism images (funct3: 2=CSRRS, 3=CSRRC).
CSRR_DCSR_X28 = (0x7b0 << 20) | (2 << 12) | (28 << 7) | 0x73
CSRR_DPC_X28 = (0x7b1 << 20) | (2 << 12) | (28 << 7) | 0x73
ANDI_DCSR_1C3 = (0x1c3 << 20) | (28 << 15) | (7 << 12) | (28 << 7) | 0x13
CSRRS_DCSR_X7 = (0x7b0 << 20) | (2 << 12) | (7 << 15) | (0 << 7) | 0x73
CSRRC_DCSR_X7 = (0x7b0 << 20) | (3 << 12) | (7 << 15) | (0 << 7) | 0x73
DRET = 0x7b200073
EBREAK = 0x00100073


def image(program):
    return "".join(f"{word:08x}\n" for word in program.rom).encode("ascii")


def fail(program, address):
    program.cursor = address // 4
    program.emit(0x500002b7)
    program.addi(6, 0, 0x7f)
    program.store(36)
    program.emit(0x0000006f)


def _branch(funct3, rs1, rs2, offset):
    assert offset % 2 == 0 and -4096 <= offset < 4096
    return ((((offset >> 12) & 1) << 31) | (((offset >> 5) & 63) << 25) |
            (rs2 << 20) | (rs1 << 15) | (funct3 << 12) |
            (((offset >> 1) & 15) << 8) | (((offset >> 11) & 1) << 7) | 0x63)


def _branch_to(program, funct3, rs1, rs2, target):
    program.emit(_branch(funct3, rs1, rs2, target - program.cursor * 4))


def _arm_mask(mechanism, entry_privilege):
    # x7 receives the DCSR bit mask to set (first entry) and clear (second).
    if mechanism == "step":
        return (4 << 20) | (0 << 15) | (7 << 7) | 0x13      # addi x7, x0, 4 (step)
    if entry_privilege == 3:
        return (8 << 12) | (7 << 7) | 0x37                # lui x7, 8 -> 0x8000 ebreakm
    return (1 << 12) | (7 << 7) | 0x37                    # lui x7, 1 -> 0x1000 ebreaku


def build_debug_program(entry_privilege=3, mprv=0, mechanism="halt"):
    """mprv: 0 none; 1 M firmware runs MPRV=1/MPP=U, dcsr.mprven=0;
    2 as 1 with the debugger setting dcsr.mprven=1 before its accesses.
    mechanism: halt (external debug_req only), ebreak or step. The latter
    two reuse the external-halt entry as a first debug entry, arm the
    mechanism, DRET to a firmware target, and verify the second entry."""
    if mechanism not in MECHANISMS:
        raise ValueError("mechanism must be halt, ebreak or step")
    if mechanism == "halt":
        if entry_privilege not in (0, 1, 3):
            raise ValueError("debug entry privilege must be U, S or M")
    else:
        if entry_privilege not in (0, 3):
            raise ValueError("ebreak/step entry privilege must be U or M")
        if mprv != 0:
            raise ValueError("ebreak/step requires mprv=0")
    if mprv not in (0, 1, 2) or (mprv and entry_privilege != 3):
        raise ValueError("MPRV variants require machine-mode entry")
    if mechanism != "halt":
        return _build_mechanism_program(entry_privilege, mechanism)
    normal, debug = _Program(), _Program()
    normal.address(28, 0x300)
    normal.csr(0x305, 28)
    if entry_privilege != 3 or mprv:
        normal.addi(28, 0, -1)
        normal.emit((2 << 20) | (28 << 15) | (5 << 12) | (28 << 7) | 0x13)
        normal.csr(0x3b0, 28)  # All-address NAPOT region, RWX for S/U.
        normal.addi(28, 0, 0x1f)
        normal.csr(0x3a0, 28)
    normal.address(10, 0x100)
    normal.emit(0x500002b7)
    if mprv:
        normal.mstatus(0x20000)  # MPRV=1, MPP=U; execution remains M.
    if entry_privilege != 3:
        normal.address(28, 0x180)
        normal.csr(0x341, 28)
        normal.mstatus(entry_privilege << 11)
        normal.emit(0x30200073)
        assert normal.cursor < 64
        normal.cursor = 0x180 // 4
    normal.addi(6, 0, 0x11)
    normal.store(0)
    normal.emit(0x0000006f)  # No path to completion without a debugger.
    normal.cursor = 64
    normal.addi(6, 0, 0x11)
    normal.load_verify(0)
    normal.addi(6, 0, 0x22)
    normal.store(32)
    normal.load_verify(32)
    normal.addi(6, 0, 0x55)
    normal.store(40)
    normal.emit(0x0000006f)
    fail(normal, 0x300)

    fail(debug, 0x300)
    debug.cursor = 0x800 // 4
    debug.emit(0x0400006f)  # Configured halt entry -> handler at 0x840.
    fail(debug, 0x808)     # Configured debug exception vector.
    debug.cursor = 0x840 // 4
    if mprv == 2:
        debug.emit((0x7b0 << 20) | (0x10 << 15) | (6 << 12) | 0x73)  # CSRRSI DCSR.mprven.
    debug.emit(CSRR_DCSR_X28)
    debug.addi(6, 28, 0)
    debug.store(8)
    debug.load_verify(8)
    debug.emit(ANDI_DCSR_1C3)
    debug.addi(6, 0, 0xc0 | entry_privilege)  # Request cause=3 and actual saved privilege.
    _branch_to(debug, 1, 28, 6, 0x300)
    debug.emit(CSRR_DPC_X28)
    debug.addi(6, 28, 0)
    debug.store(24)
    debug.addi(6, 0, 0x66)
    debug.store(16)
    debug.load_verify(16)
    debug.csr(0x7b1, 10)   # A debugger's architectural resume-PC update.
    debug.emit(DRET)
    return image(normal), image(debug)


def _build_mechanism_program(entry_privilege, mechanism):
    """ebreak/step image: the external-halt entry (cause 3) arms the
    mechanism and DRETs to firmware target T=Boot+0x140; the second entry
    (cause 1 ebreak / 4 step) validates DPC/cause in-program, records DCSR
    at Probe+56, clears the mechanism and DRETs to the 0x100 resume path."""
    cause = EXPECTED_CAUSES[mechanism]
    mask = _arm_mask(mechanism, entry_privilege)
    normal, debug = _Program(), _Program()
    # Boot and resume paths are identical to the halt image for the same
    # (entry_privilege, mprv=0); only the firmware target T is appended.
    normal.address(28, 0x300)
    normal.csr(0x305, 28)
    if entry_privilege != 3:
        normal.addi(28, 0, -1)
        normal.emit((2 << 20) | (28 << 15) | (5 << 12) | (28 << 7) | 0x13)
        normal.csr(0x3b0, 28)  # All-address NAPOT region, RWX for S/U.
        normal.addi(28, 0, 0x1f)
        normal.csr(0x3a0, 28)
    normal.address(10, 0x100)
    normal.emit(0x500002b7)
    if entry_privilege != 3:
        normal.address(28, 0x180)
        normal.csr(0x341, 28)
        normal.mstatus(entry_privilege << 11)
        normal.emit(0x30200073)
        assert normal.cursor < 64
        normal.cursor = 0x180 // 4
    normal.addi(6, 0, 0x11)
    normal.store(0)
    normal.emit(0x0000006f)  # No path to completion without a debugger.
    normal.cursor = 64
    normal.addi(6, 0, 0x11)
    normal.load_verify(0)
    normal.addi(6, 0, 0x22)
    normal.store(32)
    normal.load_verify(32)
    normal.addi(6, 0, 0x55)
    normal.store(40)
    normal.emit(0x0000006f)
    # Firmware target T: the store is the single stepped instruction for
    # step; for ebreak it runs first and the ebreak at T+4 traps. x6 is
    # preset to 0x33 and x5 to Probe by the debug handler / boot code.
    normal.cursor = FIRMWARE_TARGET // 4
    normal.store(48)
    normal.emit(EBREAK)
    fail(normal, 0x300)

    fail(debug, 0x300)
    debug.cursor = 0x800 // 4
    debug.emit(0x0400006f)  # Configured halt entry -> handler at 0x840.
    fail(debug, 0x808)     # Configured debug exception vector.
    debug.cursor = 0x840 // 4
    # Dispatch on dcsr.cause|prv: cause 3 is the external-halt first entry,
    # cause 1/4 is the mechanism second entry; anything else fails.
    debug.emit(CSRR_DCSR_X28)
    debug.emit(ANDI_DCSR_1C3)
    debug.addi(6, 0, 0xc0 | entry_privilege)
    beq_slot = debug.cursor
    debug.emit(0)  # patched below to BEQ x28,x6 -> first-entry path
    debug.addi(6, 0, (cause << 6) | entry_privilege)
    _branch_to(debug, 1, 28, 6, 0x300)  # cause mismatch -> fail
    # Second entry: verify DPC == T+4 and record DCSR at Probe+56.
    debug.emit(CSRR_DPC_X28)
    debug.emit((0x44 << 20) | (10 << 15) | (6 << 7) | 0x13)  # x6 = x10+0x44 = T+4
    _branch_to(debug, 1, 28, 6, 0x300)
    debug.emit(CSRR_DCSR_X28)
    debug.addi(6, 28, 0)
    debug.store(56)
    debug.emit(mask)
    debug.emit(CSRRC_DCSR_X7)   # clear step / ebreak*
    debug.csr(0x7b1, 10)        # dpc = x10 = 0x80000100 resume path
    debug.emit(DRET)
    # First entry: identical checks to the halt image, then arm the
    # mechanism and DRET to the firmware target T instead of 0x100.
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
    debug.emit(mask)
    debug.emit(CSRRS_DCSR_X7)   # arm step / ebreak*
    debug.emit((0x40 << 20) | (10 << 15) | (28 << 7) | 0x13)  # x28 = x10+0x40 = T
    debug.csr(0x7b1, 28)        # dpc = T
    debug.addi(6, 0, 0x33)      # value stored at Probe+48 by the target
    debug.emit(DRET)
    return image(normal), image(debug)


def program_metadata(entry_privilege, mprv, mechanism):
    normal, debug = build_debug_program(entry_privilege, mprv, mechanism)
    if mechanism == "halt":
        second = None
    else:
        second = {"firmware_target": f"0x{DEBUG_TARGET:08x}",
                  "expected_dpc": f"0x{EXPECTED_DPC:08x}",
                  "expected_cause": EXPECTED_CAUSES[mechanism]}
    counts = ((6, 4, 3, 2, 2) if mechanism == "halt" else (8, 4, 4, 2, 3))
    return {
        "entry_privilege": entry_privilege, "mprv": mprv,
        "mechanism": mechanism, "mechanism_id": MECHANISM_IDS[mechanism],
        "expected_writes": counts[0], "expected_reads": counts[1],
        "debug_writes": counts[2], "debug_reads": counts[3],
        "csr_checks": counts[4],
        "second_entry": second,
        "program_sha256": hashlib.sha256(normal).hexdigest(),
        "debug_sha256": hashlib.sha256(debug).hexdigest(),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--entry-privilege", type=int, choices=(0, 1, 3), default=3)
    parser.add_argument("--mprv", type=int, choices=(0, 1, 2), default=0)
    parser.add_argument("--mechanism", choices=MECHANISMS, default="halt")
    args = parser.parse_args()
    if args.mprv and args.entry_privilege != 3:
        parser.error("--mprv requires --entry-privilege 3")
    out = args.output_root.resolve()
    repo = Path(__file__).resolve().parents[3]
    if not out.is_relative_to(repo / "build-platform/workspace"):
        parser.error("output must be contained in build-platform/workspace")
    normal, debug = build_debug_program(args.entry_privilege, args.mprv, args.mechanism)
    out.mkdir(exist_ok=False)
    (out / "program.hex").write_bytes(normal)
    (out / "debug.hex").write_bytes(debug)
    report = {
        "status": "prepared", "qualification": False, "scope": "external debug firmware only",
        "program_sha256": hashlib.sha256(normal).hexdigest(),
        "debug_sha256": hashlib.sha256(debug).hexdigest(),
        "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "encoder_sha256": hashlib.sha256(Path(__file__).with_name("g6lc_cpu_origin_program.py").read_bytes()).hexdigest(),
        "halt_address": 0x800, "exception_address": 0x808, "resume_address": 0x80000100,
        "entry_privilege": args.entry_privilege, "mprv": args.mprv,
    }
    report.update({k: v for k, v in program_metadata(
        args.entry_privilege, args.mprv, args.mechanism).items()
        if k not in ("entry_privilege", "mprv", "program_sha256", "debug_sha256")})
    (out / "result.json").write_text(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
