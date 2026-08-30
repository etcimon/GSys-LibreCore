#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""Slice pin OpenSBI ELF into trampoline blobs for mini_fdt_nt_osbi.S.

Cave jal x0 (4B) is replaced with the deleted addi sp so the minis can
call namelen/by_offset. Nops left the matching addi +sp unmatched.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[5]
ELF = ROOT / "software/smt2-linux/soft-ladder/build/fw_payload_peel_both.elf"
OUT = Path(__file__).resolve().parent
LOAD_VA = 0x80000000
LOAD_OFF = 0x1000
NOP4 = bytes([0x01, 0x00, 0x01, 0x00])  # c.nop; c.nop (unused; cave is 4B jal x0)
# Cave replaced the function addi sp. Callable minis restore that 4B addi.
ADDI_SP_M48 = (0xFD010113).to_bytes(4, "little")
ADDI_SP_M144 = (0xF7010113).to_bytes(4, "little")


def va2off(va: int) -> int:
    return va - LOAD_VA + LOAD_OFF


def sl(data: bytes, name: str, lo: int, hi: int, head4: bytes | None = None) -> None:
    blob = bytearray(data[va2off(lo) : va2off(hi)])
    if head4 is not None:
        blob[0:4] = head4
    (OUT / name).write_bytes(blob)
    print(name, len(blob))


def main() -> None:
    data = ELF.read_bytes()
    sl(data, "offset_ptr.bin", 0x800128E8, 0x800129D4)
    sl(data, "next_tag.bin", 0x800129D4, 0x80012B0A)
    sl(data, "check_node.bin", 0x80012B0A, 0x80012B40)
    sl(data, "check_np.bin", 0x80012B0A, 0x80012B76)
    sl(data, "by_offset.bin", 0x80012E26, 0x80012EBA, head4=ADDI_SP_M48)
    sl(data, "namelen.bin", 0x80013040, 0x8001317C, head4=ADDI_SP_M144)
    sl(data, "jtab.bin", 0x800224C0, 0x800224C0 + 64)
    dtb_off = va2off(0x8001E000)
    tsz = int.from_bytes(data[dtb_off + 4 : dtb_off + 8], "big")
    (OUT / "dtb.bin").write_bytes(data[dtb_off : dtb_off + tsz])
    print("dtb.bin", tsz)
    # Directed cuts (ret after 2nd jal next_tag / before jal by_offset).
    namelen = (OUT / "namelen.bin").read_bytes()
    ret = (0x8082).to_bytes(2, "little")
    (OUT / "namelen_cut.bin").write_bytes(namelen[:0x42] + ret)
    print("namelen_cut.bin", 0x42 + 2)
    (OUT / "namelen_cut_bo.bin").write_bytes(namelen[:0x72] + ret)
    print("namelen_cut_bo.bin", 0x72 + 2)


if __name__ == "__main__":
    main()
