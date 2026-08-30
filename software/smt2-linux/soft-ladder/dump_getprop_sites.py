#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Compare getprop/by_offset/namelen first 16B on pin vs diag vs peel_gp."""
from pathlib import Path
import struct
import sys

SITES = {
    "by_offset": 0x80012E26,
    "prop_namelen": 0x80013622,
    "namelen": 0x800136F0,
    "namelen_": 0x80013040,
}


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


def main() -> int:
    build = Path(sys.argv[1] if len(sys.argv) > 1 else "software/smt2-linux/soft-ladder/build")
    names = [
        "fw_payload_diag.elf",
        "fw_payload_r3a_c15_plat_skip.pin-bc7ed11d.elf",
        "fw_payload_r3a_c15_plat_skip.held.elf",
        "fw_payload_peel_gp.elf",
        "fw_payload_peel_both.elf",
    ]
    for name in names:
        p = build / name
        print(f"=== {name} exists={p.is_file()} ===")
        if not p.is_file():
            continue
        data = p.read_bytes()
        segs = segs_of(data)
        for label, va in SITES.items():
            try:
                o = vf(segs, va)
            except ValueError as e:
                print(f"  {label} {va:#x} MISSING {e}")
                continue
            blob = data[o : o + 16]
            print(f"  {label} {va:#x} {blob.hex()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
