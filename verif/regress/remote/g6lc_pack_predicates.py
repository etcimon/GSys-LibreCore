# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Replay-only lowering of parallel valid & ~(broadcast & veto) bit predicates."""
from collections import defaultdict
from pathlib import Path
import argparse
import re

from g6lc_pack_generated_rows import ASSIGN, Expression, Unsupported


def bit_expr(node, bit):
    if bit < 0 or not (node[3] >> bit) & 1:
        return 0
    op, a, b = node[:3]
    if op == "num":
        return 1
    if op == "word":
        return ("read", a, bit)
    if op == "~":
        x = bit_expr(a, bit)
        return 1-x if isinstance(x, int) else ("not", x)
    if op in ("cast", "<<", ">>"):
        return bit_expr(a, bit if op == "cast" else (bit-b if op == "<<" else bit+b))
    x, y = bit_expr(a, bit), bit_expr(b, bit)
    if op == "&":
        return 0 if not x or not y else y if x == 1 else x if y == 1 else ("and", x, y)
    if op == "|":
        return 1 if x == 1 or y == 1 else y if not x else x if not y else ("or", x, y)
    raise Unsupported


def word(expr):
    def isop(t, op):
        return isinstance(t, tuple) and t[0] == op

    groups = defaultdict(int)
    # Try both orientations of the inner AND; require one common broadcast
    # per group and both remaining inputs to advance with the result bits.
    lanes = {}
    for i in range(32):
        t = bit_expr(expr.root, i)
        if t == 0:
            continue
        if not isop(t, "and"):
            raise Unsupported
        valid, neg = t[1:]
        if isop(valid, "not"):
            valid, neg = neg, valid
        if not (isop(valid, "read") and isop(neg, "not") and isop(neg[1], "and")):
            raise Unsupported
        x, y = neg[1][1:]
        if not (isop(x, "read") and isop(y, "read")):
            raise Unsupported
        lanes[i] = [(en[1:], (veto[1], i-veto[2]), (valid[1], i-valid[2]))
                    for en, veto in ((x, y), (y, x))]
    counts = defaultdict(int)
    for opts in lanes.values():
        for key in set(opts):
            counts[key] += 1
    for i, opts in lanes.items():
        groups[max(opts, key=counts.__getitem__)] |= 1 << i
    if not groups or len(groups)*8 > len(lanes):
        raise Unsupported

    def align(term):
        k, shift = term
        value = f"uint64_t({expr.words[k]})"
        if shift:
            value = f"({value} {'<<' if shift > 0 else '>>'} {abs(shift)})"
        return f"uint32_t({value})"
    parts = []
    for ((en, bit), veto, valid), mask in groups.items():
        broad = f"(0U - uint32_t((uint64_t({expr.words[en]}) >> {bit}) & 1U))"
        parts.append(f"(0x{mask:x}U & {align(valid)} & ~({broad} & {align(veto)}))")
    return " | ".join(parts)


def lower(source, header):
    widths = {k: int(w) for w, k in re.findall(r"VlWide<(\d+)>/\*[^*]*\*/\s+(\w+);", header)}
    small = set()
    for typ, name in re.findall(r"\b([CSIQ]Data)/\*[^*]*\*/\s+(\w+);", header):
        widths[name] = -2 if typ == "QData" else -1
        if typ in ("CData", "SData"):
            small.add(name)
    count = 0

    def rewrite(m):
        nonlocal count
        if "~" not in m[5] or int(m[4][:-1], 0) >= widths.get(m[3], 0):
            return m[0]
        # Small scalar arithmetic otherwise undergoes signed int promotion
        # (notably arithmetic right shift after a complement).
        for read in re.finditer(r"vlSelf->(\w+)", m[5]):
            if read[1] in small and not (
                    re.search(r"\([IQ]Data\)\s*\(\s*$", m[5][max(0, read.start()-48):read.start()])
                    and re.match(r"\s*\)", m[5][read.end():read.end()+48])):
                return m[0]
        try:
            replacement = word(Expression(m[5], widths, predicates=True))
        except (Unsupported, RecursionError):
            return m[0]
        count += 1
        return f"{m[1]}{m[2]} = {replacement};"
    return ASSIGN.sub(rewrite, source), count


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    for k in ("source", "class_header", "output"):
        ap.add_argument(k, type=Path)
    args = ap.parse_args()
    text, hits = lower(args.source.read_text(), args.class_header.read_text())
    if hits:
        with args.output.open("x") as stream:
            stream.write(text)
    print(f"{hits} predicate words packed")
