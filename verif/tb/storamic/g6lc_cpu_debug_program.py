# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Firmware for real external-debug entry, CSR checks and architectural DRET."""
import argparse
import hashlib
import json
from pathlib import Path

from g6lc_cpu_origin_program import _Program


def image(program):
    return "".join(f"{word:08x}\n" for word in program.rom).encode("ascii")


def fail(program, address):
    program.cursor = address // 4
    program.emit(0x500002b7)
    program.addi(6, 0, 0x7f)
    program.store(36)
    program.emit(0x0000006f)


def build_debug_program(entry_privilege=3, mprv=0):
    """mprv: 0 none; 1 M firmware runs MPRV=1/MPP=U, dcsr.mprven=0;
    2 as 1 with the debugger setting dcsr.mprven=1 before its accesses."""
    if entry_privilege not in (0, 1, 3):
        raise ValueError("debug entry privilege must be U, S or M")
    if mprv not in (0, 1, 2) or (mprv and entry_privilege != 3):
        raise ValueError("MPRV variants require machine-mode entry")
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
    debug.emit((0x7b0 << 20) | (2 << 12) | (28 << 7) | 0x73)  # CSRR DCSR.
    debug.addi(6, 28, 0)
    debug.store(8)
    debug.load_verify(8)
    debug.emit((0x1c3 << 20) | (28 << 15) | (7 << 12) | (28 << 7) | 0x13)
    debug.addi(6, 0, 0xc0 | entry_privilege)  # Request cause=3 and actual saved privilege.
    offset = 0x300 - debug.cursor * 4
    debug.emit((((offset >> 12) & 1) << 31) | (((offset >> 5) & 63) << 25) |
               (6 << 20) | (28 << 15) | (1 << 12) | (((offset >> 1) & 15) << 8) |
               (((offset >> 11) & 1) << 7) | 0x63)
    debug.emit((0x7b1 << 20) | (2 << 12) | (28 << 7) | 0x73)  # CSRR DPC.
    debug.addi(6, 28, 0)
    debug.store(24)
    debug.addi(6, 0, 0x66)
    debug.store(16)
    debug.load_verify(16)
    debug.csr(0x7b1, 10)   # A debugger's architectural resume-PC update.
    debug.emit(0x7b200073)
    return image(normal), image(debug)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--entry-privilege", type=int, choices=(0, 1, 3), default=3)
    parser.add_argument("--mprv", type=int, choices=(0, 1, 2), default=0)
    args = parser.parse_args()
    if args.mprv and args.entry_privilege != 3:
        parser.error("--mprv requires --entry-privilege 3")
    out = args.output_root.resolve()
    repo = Path(__file__).resolve().parents[3]
    if not out.is_relative_to(repo / "build-platform/workspace"):
        parser.error("output must be contained in build-platform/workspace")
    normal, debug = build_debug_program(args.entry_privilege, args.mprv)
    out.mkdir(exist_ok=False)
    (out / "program.hex").write_bytes(normal)
    (out / "debug.hex").write_bytes(debug)
    report = {
        "status": "prepared", "qualification": False, "scope": "external debug firmware only",
        "program_sha256": hashlib.sha256(normal).hexdigest(),
        "debug_sha256": hashlib.sha256(debug).hexdigest(),
        "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "encoder_sha256": hashlib.sha256(Path(__file__).with_name("g6lc_cpu_origin_program.py").read_bytes()).hexdigest(),
        "expected_writes": 6, "expected_reads": 4, "debug_writes": 3, "debug_reads": 2,
        "halt_address": 0x800, "exception_address": 0x808, "resume_address": 0x80000100,
        "entry_privilege": args.entry_privilege, "mprv": args.mprv,
    }
    (out / "result.json").write_text(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
