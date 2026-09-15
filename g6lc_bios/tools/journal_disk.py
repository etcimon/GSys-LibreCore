#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Plant a fail-closed G6BH journal at the BIOS virtio-blk window (LBA 8).
# CRC32C matches crates/g6b-bootctl. This is not a Linux image and not A/B firmware.

from __future__ import annotations

import argparse
from pathlib import Path

SLOT = 4096
WINDOW = 2 * SLOT
OFFSET = 8 * 512  # BLK_JRN_LBA
FW_A = 24 * 512
FW_B = 32 * 512
DISK = 1024 * 1024


def crc32c(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ (0x82F63B78 & - (crc & 1))
    return (~crc) & 0xFFFFFFFF


def initial_record() -> bytes:
    buf = bytearray(SLOT)
    buf[0:4] = b"G6BH"
    buf[4:6] = (1).to_bytes(2, "little")
    buf[6:8] = SLOT.to_bytes(2, "little")
    buf[8:16] = (1).to_bytes(8, "little")
    buf[16] = 1  # Domain::Linux
    buf[17] = 0  # Phase::Idle
    buf[18] = 1  # Reason::Provisioning
    crc = crc32c(bytes(buf[:-4]))
    buf[-4:] = crc.to_bytes(4, "little")
    return bytes(buf)


def make_disk(path: Path) -> None:
    data = bytearray(DISK)
    data[446 + 4] = 0xEE
    data[510] = 0x55
    data[511] = 0xAA
    data[512:520] = b"EFI PART"
    rec = initial_record()
    data[OFFSET : OFFSET + SLOT] = rec
    data[FW_A : FW_A + 4] = b"G6FA"
    data[FW_B : FW_B + 4] = b"G6FB"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def verify_disk(path: Path) -> None:
    data = path.read_bytes()
    rec = data[OFFSET : OFFSET + SLOT]
    if rec[:4] != b"G6BH":
        raise ValueError("journal magic missing")
    if crc32c(rec[:-4]) != int.from_bytes(rec[-4:], "little"):
        raise ValueError("journal CRC mismatch")
    if rec[16] != 1 or rec[18] != 1:
        raise ValueError("journal is not a fail-closed Linux/Provisioning record")
    if data[510:512] != b"\x55\xaa":
        raise ValueError("protective MBR damaged")
    if data[FW_A : FW_A + 4] != b"G6FA" or data[FW_B : FW_B + 4] != b"G6FB":
        raise ValueError("firmware A/B stubs were overwritten")


def main() -> int:
    p = argparse.ArgumentParser(description="Create or verify a BIOS G6BH journal disk")
    p.add_argument("image", type=Path)
    p.add_argument("--verify", action="store_true")
    args = p.parse_args()
    try:
        if args.verify:
            verify_disk(args.image)
            print(f"[journal-disk] OK {args.image}")
        else:
            make_disk(args.image)
            verify_disk(args.image)
            print(f"[journal-disk] wrote {args.image}")
        return 0
    except (OSError, ValueError) as error:
        print(f"[journal-disk] FAIL: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
