#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""Insert fence rw,rw after namelen.bin's five mid-saves (VA 0x80013074).

One-shot, *not* in the FDT_PROP loop at 0x80013076. In-loop fence at
0x8001307e (before 2nd jal next_tag) hung @40000 (b1-nt-nl-h0-fence).

Test-trampoline only (mini_fdt_nt_osbi*). Does not peel OpenSBI source.
Directed evidence: five mid-saves + fence PASS (b1-nt-five-fence).
"""
from __future__ import annotations

import os
from pathlib import Path

HERE = Path(__file__).resolve().parent
BIN = HERE / "namelen.bin"
BASE = 0x80013040
# After sds11,40(sp); before c.li s4,3. Loop head stays after the fence.
INSERT_VA = 0x80013074
# Default: fence rw,rw. NAMELEN_INSERT=nop4 inserts addi x0,x0,0 (reloc control).
# Stock-blob fence hangs (b1-nt-nl-h0-fence / fence2). Do not leave namelen.bin patched.
if os.environ.get("NAMELEN_INSERT", "fence") == "nop4":
    FENCE_RW = (0x00000013).to_bytes(4, "little")  # addi x0,x0,0
else:
    FENCE_RW = (0x0330000F).to_bytes(4, "little")  # fence rw,rw


def is_c(hw: int) -> bool:
    return (hw & 0x3) != 0x3


def decode_c_j(hw: int, pc: int) -> int | None:
    if (hw & 0xE003) != 0xA001:
        return None
    # imm[11|4|9:8|10|6|7|3:1|5]
    b11 = (hw >> 12) & 1
    b4 = (hw >> 11) & 1
    b9_8 = (hw >> 9) & 3
    b10 = (hw >> 8) & 1
    b6 = (hw >> 7) & 1
    b7 = (hw >> 6) & 1
    b3_1 = (hw >> 3) & 7
    b5 = (hw >> 2) & 1
    imm = (
        (b11 << 11)
        | (b10 << 10)
        | (b9_8 << 8)
        | (b7 << 7)
        | (b6 << 6)
        | (b5 << 5)
        | (b4 << 4)
        | (b3_1 << 1)
    )
    if b11:
        imm -= 1 << 12
    return pc + imm


def encode_c_j(pc: int, target: int) -> int:
    imm = target - pc
    if imm & 1:
        raise ValueError(f"c.j odd {hex(pc)}->{hex(target)}")
    if not -2048 <= imm <= 2046:
        raise ValueError(f"c.j range {hex(pc)}->{hex(target)}")
    u = imm & 0xFFF
    hw = 0xA001
    hw |= ((u >> 11) & 1) << 12
    hw |= ((u >> 4) & 1) << 11
    hw |= ((u >> 8) & 3) << 9
    hw |= ((u >> 10) & 1) << 8
    hw |= ((u >> 6) & 1) << 7
    hw |= ((u >> 7) & 1) << 6
    hw |= ((u >> 1) & 7) << 3
    hw |= ((u >> 5) & 1) << 2
    return hw


def decode_c_b(hw: int, pc: int) -> int | None:
    # C.BEQZ 110, C.BNEZ 111
    op = hw & 0xE003
    if op not in (0xC001, 0xE001):
        return None
    b8 = (hw >> 12) & 1
    b4_3 = (hw >> 10) & 3
    b7_6 = (hw >> 5) & 3
    b2_1 = (hw >> 3) & 3
    b5 = (hw >> 2) & 1
    imm = (b8 << 8) | (b7_6 << 6) | (b5 << 5) | (b4_3 << 3) | (b2_1 << 1)
    if b8:
        imm -= 1 << 9
    return pc + imm


def encode_c_b(hw: int, pc: int, target: int) -> int:
    imm = target - pc
    if imm & 1:
        raise ValueError("c.b odd")
    if not -256 <= imm <= 254:
        raise ValueError(f"c.b range {hex(pc)}->{hex(target)}")
    u = imm & 0x1FF
    out = hw & 0xE383  # keep opcode + rs1'
    out |= ((u >> 8) & 1) << 12
    out |= ((u >> 3) & 3) << 10
    out |= ((u >> 6) & 3) << 5
    out |= ((u >> 1) & 3) << 3
    out |= ((u >> 5) & 1) << 2
    return out


def decode_jal(w: int, pc: int) -> int | None:
    if (w & 0x7F) != 0x6F:
        return None
    imm = (
        ((w >> 31) & 1) << 20
        | ((w >> 21) & 0x3FF) << 1
        | ((w >> 20) & 1) << 11
        | ((w >> 12) & 0xFF) << 12
    )
    if imm & (1 << 20):
        imm -= 1 << 21
    return pc + imm


def encode_jal(rd: int, pc: int, target: int) -> int:
    imm = target - pc
    if imm & 1:
        raise ValueError("jal odd")
    if not -0x100000 <= imm <= 0xFFFFE:
        raise ValueError(f"jal range {hex(pc)}->{hex(target)}")
    u = imm & 0x1FFFFF
    return (
        ((u >> 20) & 1) << 31
        | ((u >> 1) & 0x3FF) << 21
        | ((u >> 11) & 1) << 20
        | ((u >> 12) & 0xFF) << 12
        | (rd << 7)
        | 0x6F
    )


def decode_b(w: int, pc: int) -> int | None:
    if (w & 0x7F) != 0x63:
        return None
    imm = (
        ((w >> 31) & 1) << 12
        | ((w >> 25) & 0x3F) << 5
        | ((w >> 8) & 0xF) << 1
        | ((w >> 7) & 1) << 11
    )
    if imm & (1 << 12):
        imm -= 1 << 13
    return pc + imm


def encode_b(w: int, pc: int, target: int) -> int:
    imm = target - pc
    if imm & 1:
        raise ValueError("b odd")
    if not -4096 <= imm <= 4094:
        raise ValueError(f"b range {hex(pc)}->{hex(target)}")
    u = imm & 0x1FFF
    rs2 = (w >> 20) & 0x1F
    rs1 = (w >> 15) & 0x1F
    f3 = (w >> 12) & 7
    return (
        ((u >> 12) & 1) << 31
        | ((u >> 5) & 0x3F) << 25
        | (rs2 << 20)
        | (rs1 << 15)
        | (f3 << 12)
        | ((u >> 1) & 0xF) << 8
        | ((u >> 11) & 1) << 7
        | 0x63
    )


def insns(blob: bytes, base: int) -> list[tuple[int, bytes]]:
    out = []
    i = 0
    while i < len(blob):
        hw = int.from_bytes(blob[i : i + 2], "little")
        if is_c(hw):
            out.append((base + i, blob[i : i + 2]))
            i += 2
        else:
            if i + 4 > len(blob):
                out.append((base + i, blob[i:]))
                break
            out.append((base + i, blob[i : i + 4]))
            i += 4
    return out


def adj(va: int, insert: int) -> int:
    return va + 4 if va >= insert else va


def patch(blob: bytearray) -> bytearray:
    insert_off = INSERT_VA - BASE
    items = insns(bytes(blob), BASE)
    new = bytearray()
    inserted = False
    for pc, raw in items:
        if not inserted and pc == INSERT_VA:
            new += FENCE_RW
            inserted = True
        npc = adj(pc, INSERT_VA)
        if len(raw) == 2:
            hw = int.from_bytes(raw, "little")
            t = decode_c_j(hw, pc)
            if t is not None:
                hw = encode_c_j(npc, adj(t, INSERT_VA))
                raw = hw.to_bytes(2, "little")
            else:
                t = decode_c_b(hw, pc)
                if t is not None:
                    hw = encode_c_b(hw, npc, adj(t, INSERT_VA))
                    raw = hw.to_bytes(2, "little")
        elif len(raw) == 4:
            w = int.from_bytes(raw, "little")
            t = decode_jal(w, pc)
            if t is not None:
                rd = (w >> 7) & 0x1F
                w = encode_jal(rd, npc, adj(t, INSERT_VA))
                raw = w.to_bytes(4, "little")
            else:
                t = decode_b(w, pc)
                if t is not None:
                    w = encode_b(w, npc, adj(t, INSERT_VA))
                    raw = w.to_bytes(4, "little")
        new += raw
    if not inserted:
        raise SystemExit(f"insert VA {hex(INSERT_VA)} not found")
    return new


def main() -> None:
    orig = bytearray(BIN.read_bytes())
    bak = HERE / "namelen.bin.pre-fence"
    if not bak.is_file():
        bak.write_bytes(orig)
    out = patch(orig)
    BIN.write_bytes(out)
    print(f"wrote {BIN} {len(orig)} -> {len(out)} (+{len(out)-len(orig)})")


if __name__ == "__main__":
    main()
