#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Convert a binary P6 PPM to PNG using only the standard library.

The BIOS raster lanes all emit P6 PPM (`g6b gr`, `g6b display-proxy`,
`g6b display-proxy-32`, `g6b css-render`). This is a viewing aid for those
artifacts; it is not part of any regression gate.

Usage: python tools/ppm2png.py IN.ppm OUT.png [--scale N]
"""

import struct
import sys
import zlib


def read_ppm(path):
    data = open(path, "rb").read()
    if not data.startswith(b"P6"):
        raise SystemExit(f"{path}: not a binary P6 PPM")
    fields, i = [], 2
    while len(fields) < 3:
        while i < len(data) and data[i : i + 1].isspace():
            i += 1
        if data[i : i + 1] == b"#":
            while i < len(data) and data[i] != 0x0A:
                i += 1
            continue
        j = i
        while j < len(data) and not data[j : j + 1].isspace():
            j += 1
        fields.append(int(data[i:j]))
        i = j
    i += 1  # single whitespace after maxval
    w, h, maxval = fields
    if maxval != 255:
        raise SystemExit(f"{path}: only maxval 255 is supported")
    px = data[i : i + w * h * 3]
    if len(px) != w * h * 3:
        raise SystemExit(f"{path}: truncated pixel data")
    return w, h, px


def write_png(path, w, h, px, scale=1):
    if scale > 1:
        rows = []
        for y in range(h):
            row = px[y * w * 3 : (y + 1) * w * 3]
            wide = b"".join(row[x * 3 : x * 3 + 3] * scale for x in range(w))
            rows.extend([wide] * scale)
        w, h = w * scale, h * scale
    else:
        rows = [px[y * w * 3 : (y + 1) * w * 3] for y in range(h)]
    raw = b"".join(b"\x00" + r for r in rows)

    def chunk(tag, body):
        return (
            struct.pack(">I", len(body))
            + tag
            + body
            + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)
        )

    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    out += chunk(b"IDAT", zlib.compress(raw, 9))
    out += chunk(b"IEND", b"")
    open(path, "wb").write(out)


def main(argv):
    if len(argv) < 3:
        raise SystemExit("usage: ppm2png.py IN.ppm OUT.png [--scale N]")
    scale = 1
    if "--scale" in argv:
        scale = int(argv[argv.index("--scale") + 1])
    w, h, px = read_ppm(argv[1])
    write_png(argv[2], w, h, px, scale)
    print(f"{argv[2]}: {w * scale}x{h * scale}")


if __name__ == "__main__":
    main(sys.argv)
