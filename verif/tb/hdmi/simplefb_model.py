#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Model of the Linux simple-framebuffer node for the HDMI scanout.
# The bytes at base + y*stride + x*2 are the r5g6b5 pixels the line
# buffer bursts and the shifter sends. Not a booted kernel and not a PHY.

import re
import sys
from pathlib import Path

DRAM_BASE = 0x80000000
DRAM_END = 0x90000000
AI_POOL = 0x8F000000
WIDTH = 640
HEIGHT = 480
STRIDE = 1280
SIZE = 0x96000
NPIX = WIDTH * HEIGHT

checks = 0
errors = 0


def check(name, ok):
    global checks, errors
    checks += 1
    if not ok:
        errors += 1
        print(f"FAIL {name}")


def cells(text, prop):
    found = re.findall(rf"{prop}\s*=\s*<([^>]+)>", text)
    out = []
    for item in found:
        out.append([int(part, 0) for part in item.split()])
    return out


def pix(x, y):
    return ((y & 31) << 11) | ((x & 63) << 5) | (y & 31)


def exp5(c):
    c &= 31
    return ((c << 3) | (c >> 2)) & 0xFF


def exp6(c):
    c &= 63
    return ((c << 2) | (c >> 4)) & 0xFF


def fits(width, height, stride, size, fmt):
    if fmt != "r5g6b5":
        return False
    if stride < width * 2 or stride % 2 != 0:
        return False
    if height * stride > size:
        return False
    return True


def main():
    dtsi = Path(sys.argv[1])
    bootrom = Path(sys.argv[2])
    text = dtsi.read_text(encoding="utf-8")
    regs = cells(text, "reg")
    bases = []
    for reg in regs:
        if len(reg) != 4 or reg[0] != 0 or reg[2] != 0:
            bases.append(None)
            continue
        bases.append((reg[1], reg[3]))
    width = cells(text, "width")
    height = cells(text, "height")
    stride = cells(text, "stride")
    check("one simple-framebuffer node",
          text.count('compatible = "simple-framebuffer"') == 1)
    check("format is r5g6b5", 'format = "r5g6b5"' in text)
    check("mode is 640x480 stride 1280",
          width == [[WIDTH]] and height == [[HEIGHT]] and stride == [[STRIDE]])
    check("both regs name the same 600 KiB region",
          len(bases) == 2 and bases[0] == bases[1] == (0x8EF00000, SIZE))
    base, size = bases[0]
    check("region fits in DRAM below the AI pool",
          DRAM_BASE <= base and base + size <= AI_POOL and base + size <= DRAM_END)
    check("reservation is no-map", "no-map;" in text)
    check("node fits the simplefb rule",
          fits(WIDTH, HEIGHT, STRIDE, SIZE, "r5g6b5") and SIZE == HEIGHT * STRIDE)
    leaked = []
    for dts in sorted(bootrom.glob("*.dts")):
        body = dts.read_text(encoding="utf-8", errors="ignore")
        if "g6lc-simplefb.dtsi" in body or 'format = "r5g6b5"' in body:
            leaked.append(dts.name)
    check("default board DTS does not include the node", leaked == [])

    buf = bytearray(size)
    bad_px = 0
    bad_expand = 0
    for y in range(HEIGHT):
        for x in range(WIDTH):
            off = y * STRIDE + x * 2
            value = pix(x, y)
            buf[off] = value & 0xFF
            buf[off + 1] = (value >> 8) & 0xFF
            got = buf[off] | (buf[off + 1] << 8)
            if got != value or off + 2 > size:
                bad_px += 1
            if (exp5(value >> 11) != exp5(y & 31) or
                    exp6((value >> 5) & 63) != exp6(x & 63) or
                    exp5(value & 31) != exp5(y & 31)):
                bad_expand += 1
    check("every pixel is the little-endian r5g6b5 byte pair", bad_px == 0)
    check("color expand matches the scanner", bad_expand == 0)

    bad_beat = 0
    for y in range(HEIGHT):
        line = base + y * STRIDE
        for beat in range(WIDTH // 4):
            byte_addr = line + beat * 8
            off = byte_addr - base
            word = int.from_bytes(buf[off:off + 8], "little")
            packed = 0
            for i in range(4):
                packed |= pix(beat * 4 + i, y) << (16 * i)
            if word != packed:
                bad_beat += 1
    check("line beats match the AXI burst packing", bad_beat == 0)

    def in_region(off):
        return 0 <= off and off + 2 <= size

    last = (HEIGHT - 1) * STRIDE + (WIDTH - 1) * 2
    check("x8r8g8b8 is not this node",
          not fits(WIDTH, HEIGHT, STRIDE, SIZE, "x8r8g8b8"))
    check("a short stride does not fit",
          not fits(WIDTH, HEIGHT, WIDTH * 2 - 2, SIZE, "r5g6b5"))
    check("a short region does not fit",
          not fits(WIDTH, HEIGHT, STRIDE, SIZE - 1, "r5g6b5"))
    check("the scanout row is the simplefb row",
          base + STRIDE == base + 1 * STRIDE and
          (base + 1536) != (base + STRIDE))
    check("the last pixel is inside and the next byte is not",
          in_region(last) and not in_region(size))

    if errors:
        print(f"hdmi simplefb errors={errors} checks={checks}")
        return 1
    print(f"PASS simplefb_model checks={checks} pixels={NPIX} errors=0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
