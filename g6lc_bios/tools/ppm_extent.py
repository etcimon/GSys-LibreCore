#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Report the bounding box and colour census of non-background pixels in a P6 PPM.

Used to check the scanout geometry claim in architecture/DISPLAY.md: the BIOS
plane is supposed to be scaled and centred inside the scanout, so where the ink
actually lands is a measurement, not a matter of opinion.
"""
import sys
from pathlib import Path


def read_ppm(path):
    data = Path(path).read_bytes()
    fields, i = [], 0
    while len(fields) < 4:
        while i < len(data) and data[i : i + 1].isspace():
            i += 1
        if data[i : i + 1] == b"#":
            while i < len(data) and data[i] != 0x0A:
                i += 1
            continue
        j = i
        while j < len(data) and not data[j : j + 1].isspace():
            j += 1
        fields.append(data[i:j])
        i = j
    i += 1
    assert fields[0] == b"P6", fields[0]
    w, h = int(fields[1]), int(fields[2])
    return w, h, data[i : i + w * h * 3]


def main(argv):
    for path in argv:
        w, h, px = read_ppm(path)
        minx, miny, maxx, maxy = w, h, -1, -1
        colours = {}
        for y in range(h):
            row = y * w * 3
            for x in range(w):
                o = row + x * 3
                rgb = (px[o], px[o + 1], px[o + 2])
                if rgb == (0, 0, 0):
                    continue
                colours[rgb] = colours.get(rgb, 0) + 1
                if x < minx:
                    minx = x
                if x > maxx:
                    maxx = x
                if y < miny:
                    miny = y
                if y > maxy:
                    maxy = y
        top = sorted(colours.items(), key=lambda kv: -kv[1])[:6]
        name = Path(path).name
        if maxx < 0:
            print(f"{name}: {w}x{h} — entirely black")
            continue
        print(
            f"{name}: {w}x{h} ink bbox x={minx}..{maxx} y={miny}..{maxy} "
            f"({maxx - minx + 1}x{maxy - miny + 1}) distinct_colours={len(colours)}"
        )
        print("   top:", ", ".join(f"{c}x{n}" for c, n in top))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
