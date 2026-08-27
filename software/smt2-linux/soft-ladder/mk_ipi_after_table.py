#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Side ELF from pin-bc7ed11d (do not overwrite pin):

1. Lottery: if _boot_status already nonzero, skip amoswap and wait
   (avoids G1di 2→1). Cave in RX padding @0x8001d920.
2. IPI hart1 after cookie stores, in-line at the success-cave WFI
   (no jal to sbi_hart_hang — that redirect cancelled the cookie sw).
3. Nop generic_cold_boot_allowed's sw of 51b1c001 over [1000].
"""
from __future__ import annotations

import hashlib
import struct
import sys
from pathlib import Path

WANT_PIN = "bc7ed11dab17454fd147e4927ba07fef"
LOT = 0x8000002A
WAIT = 0x800002E8
CONT = 0x80000040
LOT_CAVE = 0x8001D920
# Success cave WFI @0xef98. Pin: sw babe @ef80, sw d000 @ef94, wfi, jal -4.
# Distant jal to 0xef4c cancelled those sws (tab3–5). Keep 4-byte aligned.
IPI_AT = 0x8000EF98
AMOSWAP = 0x0918282F  # amoswap.w a6, a7, (a6)
# generic_cold_boot_allowed stores 51b1c001 over [1000]; nop that sw.
COLD_SW = 0x800071F4


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


def auipc(rd: int, imm20: int) -> int:
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x17


def addi(rd: int, rs1: int, imm12: int) -> int:
    if imm12 < 0:
        imm12 = (1 << 12) + imm12
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x13


def addiw(rd: int, rs1: int, imm12: int) -> int:
    if imm12 < 0:
        imm12 = (1 << 12) + imm12
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (rd << 7) | 0x1B


def lwu(rd: int, rs1: int, imm12: int) -> int:
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (0x6 << 12) | (rd << 7) | 0x03


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


def beq(rs1: int, rs2: int, imm: int) -> int:
    if imm & 1:
        raise ValueError("beq odd")
    imm12 = (imm >> 12) & 1
    imm10_5 = (imm >> 5) & 0x3F
    imm4_1 = (imm >> 1) & 0xF
    imm11 = (imm >> 11) & 1
    return (
        (imm12 << 31)
        | (imm10_5 << 25)
        | (rs2 << 20)
        | (rs1 << 15)
        | (imm4_1 << 8)
        | (imm11 << 7)
        | 0x63
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
    A6, A7, T0, T3, A3, A4 = 16, 17, 5, 28, 13, 14

    struct.pack_into("<I", data, vf(segs, LOT), jal(0, LOT_CAVE - LOT))
    lc = LOT_CAVE
    lot = b""
    # auipc+addi (not lui 0x80040: RV64 sign-extends to 0xffffffff80040000)
    # pc=0x8001d920 + 0x22000 = 0x8003f920; +0x798 = 0x800400b8
    lot += struct.pack("<I", auipc(A6, 0x22))
    lot += struct.pack("<I", addi(A6, A6, 0x798))
    lot += struct.pack("<I", lwu(T3, A6, 0))
    lot += struct.pack("<I", beq(T3, 0, 8))
    lot += struct.pack("<I", jal(0, WAIT - (lc + 16)))
    lot += struct.pack("<H", c_li(A7, 1))
    lot += struct.pack("<I", AMOSWAP)
    lot += struct.pack("<I", beq(A6, 0, 8))
    lot += struct.pack("<I", jal(0, WAIT - (lc + 30)))
    lot += struct.pack("<I", addiw(T0, 0, 1))
    lot += struct.pack("<I", jal(0, CONT - (lc + 38)))
    if len(lot) != 42:
        print("ERROR: lot cave", len(lot))
        return 1
    data[vf(segs, LOT_CAVE) : vf(segs, LOT_CAVE) + 42] = lot

    # fence cookie sw → MSIP hart1 @0x02000004 → WFI (same drain as pin).
    # 24B overwrites the WFI loop + dead bytes after SUCCESS@ef70 (ends @efa0).
    ipi = b""
    ipi += struct.pack("<I", 0x0330000F)  # fence rw,rw
    ipi += struct.pack("<I", lui(A3, 0x2000))
    ipi += struct.pack("<I", addi(A4, 0, 1))
    ipi += struct.pack("<I", sw(A4, A3, 4))
    ipi += struct.pack("<I", 0x10500073)  # wfi
    ipi += struct.pack("<I", jal(0, -4))
    if len(ipi) != 24:
        print("ERROR: ipi inline", len(ipi))
        return 1
    data[vf(segs, IPI_AT) : vf(segs, IPI_AT) + 24] = ipi
    struct.pack_into("<I", data, vf(segs, COLD_SW), 0x00000013)  # nop

    dst.write_bytes(data)
    print("wrote", dst, hashlib.md5(data).hexdigest())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
