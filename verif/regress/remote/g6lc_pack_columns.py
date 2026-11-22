#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Batch regular column projections in frozen, generated Verilator C++."""
import argparse
from collections import defaultdict
from pathlib import Path
import re

from g6lc_pack_generated_rows import ASSIGN, WORD, Expression, Unsupported


def projection(m, widths):
    if int(m[4][:-1], 0) >= widths.get(m[3], 0):
        raise Unsupported
    expr = Expression(m[5], widths)
    field = None
    bits = []
    for i in range(32):
        terms = expr.terms(expr.root, i)
        if len(terms) != 1 or len(terms[0]) != 1:
            raise Unsupported
        word, bit = divmod(terms[0][0], 32)
        read = re.fullmatch(WORD, expr.words[word])
        if not read or read[1] == m[3] or (field is not None and field != read[1]):
            raise Unsupported
        field = read[1]
        bits.append(32 * int(read[2][:-1], 0) + bit)
    stride = bits[1] - bits[0]
    if (stride <= 0 or stride % 8 or bits[-1] // 8 > 0x7fffffff
            or any(b != bits[0] + i * stride for i, b in enumerate(bits))):
        raise Unsupported
    return field, bits[0] // 8, stride // 8, bits[0] % 8


def lower_columns(source, header):
    widths = {k: int(w) for w, k in re.findall(r"VlWide<(\d+)>/\*[^*]*\*/\s+(\w+);", header)}
    runs, run = [], []
    for m in ASSIGN.finditer(source):
        try:
            # A declaration cannot replace an unbraced conditional statement.
            prefix = source[max(0, m.start() - 128):m.start()].rstrip()
            if not prefix.endswith((";", "{", "}", "// Body")):
                raise Unsupported
            proj = projection(m, widths)
        except (Unsupported, RecursionError):
            proj = None
        # No speculation across control flow, unknown statements, or a change
        # of source field. Every store in a run is disjoint from its input.
        if run and (not proj or proj[0] != run[-1][1][0]
                    or source[run[-1][0].end():m.start()].strip()):
            runs.append(run)
            run = []
        if proj:
            run.append((m, proj))
    runs.append(run)
    pieces, cursor, changed, tile = [], 0, 0, 0
    for run in runs:
        planes = defaultdict(set)
        for _, (field, start, stride, bit) in run:
            planes[field, start, stride].add(bit)
        names = {}
        for m, (field, start, stride, bit) in run:
            key = field, start, stride
            if len(planes[key]) < 4:
                continue
            pieces.append(source[cursor:m.start()])
            if not names:
                pieces.append("    {\n")
            if key not in names:
                name = names[key] = f"__Vg6lcTile{tile}"
                tile += 1
                pieces.append(f"        const auto {name} = g6lc_column::gather<{start}, {stride}>"
                              f"(&vlSelf->{field}[0U]);\n")
            pieces.append(f"        {m[2]} = g6lc_column::column<{bit}>({names[key]});")
            cursor = m.end()
            changed += 1
        if names:
            pieces.append("\n    }")
    if not changed:
        return source, 0
    return '#include "g6lc_column_tile.h"\n' + "".join(pieces) + source[cursor:], changed


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ("source", "class_header", "output"):
        parser.add_argument(arg, type=Path)
    args = parser.parse_args()
    result, changes = lower_columns(args.source.read_text(), args.class_header.read_text())
    if changes:
        with args.output.open("x") as stream:
            stream.write(result)
    print(f"{changes} word projections tiled")
