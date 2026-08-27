#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Side ELF: after OpenSBI lottery win, IPI hart1 while _boot_status==1.

Do NOT overwrite pin-bc7ed11d. Cave overwrites sbi_hart_hang @0xef4c
(18B) then jal back to relocate c.slli @0x40.
"""
from __future__ import annotations

import hashlib
import struct
import sys
from pathlib import Path

WANT_PIN = "bc7ed11dab17454fd147e4927ba07fef"
LOT_WIN = 0x8000003C  # addiw t0,zero,1 after amoswap bne
CAVE = 0x8000EF4C  # sbi_hart_hang
CONT = 0x80000040  # c.slli t0,31


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


def jal(rd: int, imm: int) -> int:
    if imm & 1:
        raise ValueError("jal odd")
    imm20 = (imm >> 20) & 1
    imm10_1 = (imm >> 1) & 0x3FF
    imm11 = (imm >> 11) & 1
    imm19_12 = (imm >> 12) & 0xFF
    return (
        (imm20 << 31)
        | (imm19_12 << 12)
        | (imm11 << 20)
        | (imm10_1 << 21)
        | (rd << 7)
        | 0x6F
    )


def lui(rd: int, imm20: int) -> int:
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x37


def addi(rd: int, rs1: int, imm12: int) -> int:
    if imm12 < 0:
        imm12 = (1 << 12) + imm12
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13


def addiw(rd: int, rs1: int, imm12: int) -> int:
    if imm12 < 0:
        imm12 = (1 << 12) + imm12
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x1B


def sw(rs2: int, rs1: int, imm12: int) -> int:
    if imm12 < 0:
        imm12 = (1 << 12) + imm12
    imm = imm12 & 0xFFF
    return (
        ((imm >> 5) << 25)
        | (rs2 << 20)
        | (rs1 << 15)
        | (0x2 << 12)
        | ((imm & 0x1F) << 7)
        | 0x23
    )


def c_li(rd: int, imm6: int) -> int:
    if imm6 < 0:
        imm6 = (1 << 6) + imm6
    return (
        (0b010 << 13)
        | ((imm6 >> 5) << 12)
        | (rd << 7)
        | ((imm6 & 0x1F) << 2)
        | 0b01
    )


def main() -> int:
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    data = bytearray(src.read_bytes())
    got = hashlib.md5(data).hexdigest()
    if got != WANT_PIN:
        print("ERROR: pin md5", got, "!=", WANT_PIN)
        return 1
    segs = segs_of(data)
    # 0x3c addiw t0,zero,1 -> jal x0, cave
    jimm = CAVE - LOT_WIN
    struct.pack_into("<I", data, vf(segs, LOT_WIN), jal(0, jimm))
    # cave 18B: lui a3,0x2000; c.li a4,1; sw a4,4(a3); addiw t0,0,1; jal 0x40
    A3, A4, T0 = 13, 14, 5
    cave = b""
    cave += struct.pack("<I", lui(A3, 0x2000))
    cave += struct.pack("<H", c_li(A4, 1))
    cave += struct.pack("<I", sw(A4, A3, 4))
    cave += struct.pack("<I", addiw(T0, 0, 1))
    cave += struct.pack("<I", jal(0, CONT - (CAVE + 14)))
    if len(cave) != 18:
        print("ERROR: cave len", len(cave))
        return 1
    off = vf(segs, CAVE)
    data[off : off + 18] = cave
    dst.write_bytes(data)
    print("wrote", dst, hashlib.md5(data).hexdigest(), "jal", hex(jimm))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
