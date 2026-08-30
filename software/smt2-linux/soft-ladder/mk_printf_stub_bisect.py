#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""From peel-printf, apply SOFT_HART_INIT and/or SOFT_PLAT_OPS (hold stubs)."""
from __future__ import annotations

import hashlib
import struct
import sys
from pathlib import Path

HART = 0x8000CCCC
PLAT = (
    0x800017E0,
    0x800016A8,
    0x80001778,
    0x800017C2,
    0x80005424,
    0x80005492,
    0x800054AE,
    0x80005AD0,
    0x80005B70,
)


def segs_of(data: bytes):
    e_phoff = struct.unpack_from("<Q", data, 32)[0]
    e_phentsize = struct.unpack_from("<H", data, 54)[0]
    e_phnum = struct.unpack_from("<H", data, 56)[0]
    segs = []
    for i in range(e_phnum):
        o = e_phoff + i * e_phentsize
        if struct.unpack_from("<I", data, o)[0] != 1:
            continue
        p_offset, p_vaddr, _, p_filesz, _, _ = struct.unpack_from(
            "<QQQQQQ", data, o + 8
        )
        segs.append((p_offset, p_vaddr, p_filesz))
    return segs


def vf(segs, va):
    for off, v, fs in segs:
        if v <= va < v + fs:
            return off + (va - v)
    raise ValueError(hex(va))


def addi(rd, rs1, imm12):
    if imm12 < 0:
        imm12 = (1 << 12) + imm12
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13


def jalr(rd, rs1, imm12=0):
    if imm12 < 0:
        imm12 = (1 << 12) + imm12
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x67


def main() -> int:
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    hart = "--hart" in sys.argv
    plat = "--plat" in sys.argv
    data = bytearray(src.read_bytes())
    segs = segs_of(data)
    if hart:
        struct.pack_into("<I", data, vf(segs, HART), addi(10, 0, 0))
        struct.pack_into("<I", data, vf(segs, HART + 4), jalr(0, 1, 0))
    if plat:
        for va in PLAT:
            struct.pack_into("<H", data, vf(segs, va), 0x4501)
    dst.write_bytes(data)
    print(
        "wrote",
        dst,
        "hart",
        int(hart),
        "plat",
        int(plat),
        hashlib.md5(data).hexdigest(),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
