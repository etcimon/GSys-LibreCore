#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Experimental packed-row lowering for frozen Verilator C++ A/B builds.

Write a *new* TU only for supported assignments in a generated model. Parse
unsigned literals, wide word and unsigned port reads, casts, constant shifts, AND and OR.
Everything else is left untouched. Not a general-purpose C++ optimizer.
"""
import argparse
from collections import Counter, defaultdict
from pathlib import Path
import re


class Unsupported(Exception):
    pass


NUM = r"(?:0x[\da-fA-F]+|[1-9]\d*|0)U"
WORD = rf"vlSelf->(\w+)\[({NUM})\]"
TOKEN = re.compile(rf"{WORD}|vlSelf->(\w+)|\((?:I|Q)Data\)|{NUM}|<<|>>|[&|()]|\S")
ASSIGN = re.compile(rf"^(    )({WORD})\s*=\s*([^;]+);", re.M)
PREC = {"|": 1, "&": 2, "<<": 3, ">>": 3}


class Expression:
    def __init__(self, text, widths, *, predicates=False):
        self.widths = widths
        self.predicates = predicates
        self.words = []
        self.ids = {}
        self.tokens = iter(TOKEN.finditer(text))
        self.advance()
        self.root = self.parse(0)
        if self.cur is not None:
            raise Unsupported

    def advance(self):
        self.cur = next(self.tokens, None)

    def parse(self, prec):
        m = self.cur
        if m is None:
            raise Unsupported
        token = m[0]
        self.advance()
        if token == "(":
            node = self.parse(0)
            if self.cur is None or self.cur[0] != ")":
                raise Unsupported
            self.advance()
        elif token == "~" and self.predicates:
            sub = self.parse(4)
            node = ("~", sub, None, (1 << sub[4]) - 1, sub[4])
        elif token in ("(IData)", "(QData)"):
            sub = self.parse(4)
            width = 32 if token == "(IData)" else 64
            node = ("cast", sub, None, sub[3] & ((1 << width) - 1), width)
        elif m[1] or m[3]:
            if m[1] and int(m[2][:-1], 0) >= self.widths.get(m[1], 0):
                raise Unsupported
            if m[3] and self.widths.get(m[3]) not in ((-1, -2) if self.predicates else (-1,)):
                raise Unsupported
            if token not in self.ids:
                self.ids[token] = len(self.words)
                self.words.append(token)
            width = 64 if m[3] and self.widths[m[3]] == -2 else 32
            node = ("word", self.ids[token], None, (1 << width) - 1, width)
        elif re.fullmatch(NUM, token):
            val = int(token[:-1], 0)
            if val > 0xffffffff:
                raise Unsupported
            node = ("num", val, None, val, 32)
        else:
            raise Unsupported
        while self.cur is not None and PREC.get(self.cur[0], -1) >= prec:
            op = self.cur[0]
            self.advance()
            rhs = self.parse(PREC[op] + 1)
            width = node[4]
            if op in ("<<", ">>"):
                if rhs[0] != "num" or rhs[1] >= width:
                    raise Unsupported
                shift = rhs[1]
                mask = node[3] << shift if op == "<<" else node[3] >> shift
                rhs = shift
            else:
                width = max(width, rhs[4])
                mask = node[3] & rhs[3] if op == "&" else node[3] | rhs[3]
            node = (op, node, rhs, mask & ((1 << width) - 1), width)
        return node

    @staticmethod
    def terms(node, bit):
        """DNF for one demanded bit; prune known-zero subtrees before descent."""
        if bit < 0 or not (node[3] >> bit) & 1:
            return ()
        op, a, b = node[:3]
        sub = Expression.terms
        if op == "word":
            return ((32 * a + bit,),)
        if op == "num":
            return ((),)
        if op == "cast":
            return sub(a, bit)
        if op in ("<<", ">>"):
            return sub(a, bit - b if op == "<<" else bit + b)
        lhs, rhs = sub(a, bit), sub(b, bit)
        if op == "|":
            if len(lhs) + len(rhs) > 64:
                raise Unsupported
            return lhs + rhs
        if len(lhs) * len(rhs) > 64:
            raise Unsupported
        return tuple(x + y for x in lhs for y in rhs)

    def packed(self):
        # An orientation is (broadcast bit, data word, shift to output word).
        # Choose common orientations; neither commutativity nor grouping
        # changes which products contribute at each output bit.
        products = []
        counts = Counter()
        for i in range(32):
            for term in self.terms(self.root, i):
                if len(term) != 2:
                    raise Unsupported
                a, b = term
                opts = ((a, b // 32, i - b % 32), (b, a // 32, i - a % 32))
                counts.update(opts)
                products.append((i, opts))
        masks = defaultdict(int)
        for i, opts in products:
            masks[max(opts, key=counts.__getitem__)] |= 1 << i
        if len(products) < 32 or len(masks) * 4 > len(products):
            raise Unsupported
        out = []
        for (b, word, shift), mask in masks.items():
            enable = f"((0U - (({self.words[b // 32]} >> {b % 32}) & 1U)) & 0x{mask:x}U)"
            data = self.words[word]
            if shift:
                data = f"({data} {'<<' if shift > 0 else '>>'} {abs(shift)})"
            out.append(f"({enable} & {data})")
        return " | ".join(out)


def lower(source, header):
    widths = {k: int(w) for w, k in re.findall(r"VlWide<(\d+)>/\*[^*]*\*/\s+(\w+);", header)}
    for k, w in re.findall(r"VL_(?:IN|OUT|INOUT)W\((\w+),\d+,\d+,(\d+)\);", header):
        widths[k] = int(w)
    for k in re.findall(r"VL_(?:IN|OUT|INOUT)\((\w+),\d+,\d+\);", header):
        widths[k] = -1
    count = 0

    def assign(m):
        nonlocal count
        if int(m[4][:-1], 0) >= widths.get(m[3], 0) or len(m[5]) < 500:
            return m[0]
        try:
            rhs = Expression(m[5], widths).packed()
        except (Unsupported, RecursionError):
            return m[0]
        count += 1
        return f"{m[1]}{m[2]} = {rhs};"

    return ASSIGN.sub(assign, source), count


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ("source", "class_header", "output"):
        parser.add_argument(arg, type=Path)
    args = parser.parse_args()
    result, changes = lower(args.source.read_text(), args.class_header.read_text())
    if changes:
        with args.output.open("x") as stream:
            stream.write(result)
    print(f"{changes} word assignments packed")
