# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Batch eight-bit column fragments within an uninterrupted generated store run."""
from collections import defaultdict
import argparse
from pathlib import Path
import re

from g6lc_pack_generated_rows import ASSIGN, Expression, Unsupported, WORD


def fragments(m, widths):
    if int(m[4][:-1], 0) >= widths.get(m[3], 0):
        raise Unsupported
    e = Expression(m[5], widths)
    pieces = []
    field = None
    for byte in range(4):
        ix = []
        for b in range(8*byte, 8*byte+8):
            terms = e.terms(e.root, b)
            if len(terms) != 1 or len(terms[0]) != 1:
                raise Unsupported
            w, bit = divmod(terms[0][0], 32)
            r = re.fullmatch(WORD, e.words[w])
            if not r or r[1] == m[3] or (field is not None and r[1] != field):
                raise Unsupported
            field = r[1]
            ix.append(32*int(r[2][:-1], 0) + bit)
        step = ix[1]-ix[0]
        if step < 8 or step % 8 or ix != [ix[0]+i*step for i in range(8)]:
            raise Unsupported
        pieces.append(((field, ix[0]//8, step//8), ix[0]%8))
    return pieces


def lower_wrapped(source, header):
    widths = {k: int(w) for w, k in re.findall(r"VlWide<(\d+)>/\*[^*]*\*/\s+(\w+);", header)}
    chunks, run = [], []
    cursor = count = 0

    def flush():
        nonlocal cursor, count
        planes = defaultdict(set)
        for _, parts in run:
            for key, plane in parts:
                planes[key].add(plane)
        names = {}
        for m, parts in run:
            if not all(len(planes[key]) >= 4 for key, _ in parts):
                continue
            chunks.append(source[cursor:m.start()])
            if not names:
                chunks.append("    {\n")
            rhs = []
            for i, (key, plane) in enumerate(parts):
                field, start, stride = key
                if key not in names:
                    var = names[key] = f"__Vg6lcOctet{len(names)}"
                    chunks.append(f"    const uint64_t {var} = g6lc_column::octet<{start},"
                                  f"{stride}>(&vlSelf->{field}[0U]);\n")
                rhs.append(f"((uint32_t({names[key]} >> {8*plane}) & 255U) << {8*i})")
            chunks.append(f"    {m[2]} = " + " | ".join(rhs) + ";")
            cursor = m.end()
            count += 1
        if names:
            chunks.append("\n    }")
        run.clear()

    for m in ASSIGN.finditer(source):
        try:
            parts = fragments(m, widths)
        except (Unsupported, RecursionError):
            parts = None
        if run and (not parts or source[run[-1][0].end():m.start()].strip()
                    or parts[0][0][0] != run[-1][1][0][0][0]):
            flush()
        # Do not begin a batch inside an unbraced controlled statement.
        if parts and (run or source[max(0, m.start()-128):m.start()].rstrip()
                      .endswith((";", "{", "}", "// Body"))):
            run.append((m, parts))
    flush()
    if not count:
        return source, 0
    return '#include "g6lc_column_tile.h"\n' + "".join(chunks) + source[cursor:], count


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    for k in ("source", "class_header", "output"):
        ap.add_argument(k, type=Path)
    args = ap.parse_args()
    text, hits = lower_wrapped(args.source.read_text(), args.class_header.read_text())
    if hits:
        with args.output.open("x") as stream:
            stream.write(text)
    print(f"{hits} wrapped column words tiled")
