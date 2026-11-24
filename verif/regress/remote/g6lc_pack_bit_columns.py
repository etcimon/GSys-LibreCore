#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Batch arbitrary-bit-stride column transposes in generated Verilator C++.

Handles both uniform 64-entry bit-strided columns (e.g. mem_col with stride=522
bits, using g6lc_column::gather_bits64) and piecewise 8-entry octet-strided
columns (e.g. wrapped 40-bit age_col, using g6lc_column::octet_bits), including
Verilator's paired low/high 32-bit halves of 64-bit QData concatenations.
"""
import argparse
from collections import defaultdict
from pathlib import Path
import re

NUM = r"(?:0x[\da-fA-F]+|[1-9]\d*|0)U"
ASSIGN = re.compile(rf"^(    )(vlSelf->(\w+)\[({NUM})\])\s*=\s*([^;]+);", re.M)
BIT_TERM = re.compile(
    rf"\(1U\s*&\s*(?:\(\s*)?vlSelf->(\w+)\[({NUM})\](?:\s*>>\s*({NUM}))?\s*\)?\)"
)


def parse_bit_concat_word(rhs, dst_field, widths):
    """Strictly parse a 32- or 64-bit single-bit-concatenation word assignment.

    Returns (src_field, [bit_pos_for_out_bit_0 .. bit_pos_for_out_bit_31])
    or None if the RHS does not strictly match a pure bit-extraction concat.
    """
    if "vlSelf->" not in rhs or len(rhs) < 300:
        return None
    # Reject anything with conditionals, complement, non-concat ops, or calls.
    check_s = rhs.replace("vlSelf->", "")
    for bad in ("?", "~", "^", "+", "-", "*", "/", "==", "!=", "<=", ">=", "&&", "||", ","):
        if bad in check_s:
            return None

    # Normalize whitespace once for fast, strict structural parsing.
    s = re.sub(r"\s+", " ", rhs.strip())

    # Unwrap outer (IData)(...) and detect optional >> 0x20U (high 32-bit half).
    is_hi = False
    if s.startswith("(IData)(") and s.endswith(")"):
        inner = s[len("(IData)("):-1].strip()
        for suf in (">> 0x20U)", ">> 32U)", ">> 0x20U", ">> 32U"):
            if inner.endswith(suf):
                cand = inner[:-len(suf)].strip()
                if suf.endswith(")") and cand.startswith("("):
                    cand = cand[1:].strip()
                inner = cand
                is_hi = True
                break
    else:
        inner = s

    # Strip balanced outer parentheses.
    while inner.startswith("(") and inner.endswith(")"):
        depth = 0
        ok = True
        for i, ch in enumerate(inner):
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0 and i != len(inner) - 1:
                    ok = False
                    break
        if not ok:
            break
        inner = inner[1:-1].strip()

    # Split top-level OR chain, unwrapping Verilator's grouped lower-32-bit
    # `(QData)((IData)(bit31<<31 | ... | bit0))` term when present.
    def peel(x):
        x = x.strip()
        while x.startswith("(") and x.endswith(")"):
            d = 0
            wrap = True
            for i, ch in enumerate(x):
                if ch == "(":
                    d += 1
                elif ch == ")":
                    d -= 1
                    if d == 0 and i != len(x) - 1:
                        wrap = False
                        break
            if not wrap:
                break
            x = x[1:-1].strip()
        return x

    def split_or(expr):
        out = []
        cur = expr
        while True:
            cur = peel(cur)
            d = 0
            split_at = -1
            for i, ch in enumerate(cur):
                if ch == "(":
                    d += 1
                elif ch == ")":
                    d -= 1
                elif ch == "|" and d == 0:
                    split_at = i
                    break
            if split_at == -1:
                out.append(cur)
                break
            out.append(cur[:split_at].strip())
            cur = cur[split_at + 1:].strip()
        return out

    raw_terms = split_or(inner)
    if len(raw_terms) == 33:
        terms = []
        for t in raw_terms:
            pt = peel(t)
            if pt.startswith("(QData)"):
                d = 0
                has_top_sh = False
                for i in range(len(pt) - 1):
                    if pt[i] == "(":
                        d += 1
                    elif pt[i] == ")":
                        d -= 1
                    elif d == 0 and pt[i:i+2] == "<<":
                        has_top_sh = True
                        break
                if not has_top_sh:
                    sub = peel(pt[7:])
                    if sub.startswith("(IData)"):
                        sub = peel(sub[7:])
                    sub_terms = split_or(sub)
                    if len(sub_terms) == 32:
                        terms.extend(sub_terms)
                        continue
            terms.append(t)
    else:
        terms = raw_terms

    if len(terms) not in (32, 64):
        return None
    if is_hi and len(terms) != 64:
        return None

    # Parse each term: must extract 1 bit from vlSelf->SRC[w] into unique bit `out_bit`.
    # Supports both Verilator forms:
    #   Form A (bits 63..32 & bit 0): ((QData)((IData)((1U & (vlSelf->SRC[W] >> B))))) << OUT_BIT
    #   Form B (bits 31..1 inside grouped IData): ((1<<OUT_BIT) & (vlSelf->SRC[W] << LSH | >> RSH))
    src_field = None
    bit_map = {}
    for t in terms:
        x = peel(t)
        # Try Form B first:
        #   B1: `MASK & (vlSelf->SRC[W] <<|>> SH)` where MASK is single bit `1 << out_bit`
        #   B2: `vlSelf->SRC[W] << 0x1fU` (bit 0 -> bit 31, no mask needed)
        #   B3: `vlSelf->SRC[W] >> 0x1fU` (bit 31 -> bit 0, no mask needed)
        m_pre = re.fullmatch(
            rf"({NUM})\s*&\s*(?:\(\s*)?vlSelf->(\w+)\[({NUM})\](?:\s*(<<|>>)\s*({NUM}))?\s*\)?",
            x,
        )
        m_ext = None if m_pre else re.fullmatch(
            rf"vlSelf->(\w+)\[({NUM})\]\s*(<<|>>)\s*(0x1fU|31U)",
            x,
        )
        if m_pre or m_ext:
            if m_pre:
                mask_val = int(m_pre.group(1)[:-1], 0)
                if mask_val == 0 or (mask_val & (mask_val - 1)) != 0:
                    return None
                out_bit = mask_val.bit_length() - 1
                fld = m_pre.group(2)
                w_idx = int(m_pre.group(3)[:-1], 0)
                op_sh = m_pre.group(4)
                sh_val = int(m_pre.group(5)[:-1], 0) if m_pre.group(5) else 0
                b_sh = (out_bit - sh_val) if op_sh == "<<" else ((out_bit + sh_val) if op_sh == ">>" else out_bit)
            else:
                fld = m_ext.group(1)
                w_idx = int(m_ext.group(2)[:-1], 0)
                if m_ext.group(3) == "<<":
                    out_bit, b_sh = 31, 0
                else:
                    out_bit, b_sh = 0, 31
            if fld == dst_field or w_idx >= widths.get(fld, 0) or not 0 <= b_sh < 32:
                return None
            if out_bit >= len(terms) or out_bit in bit_map:
                return None
            if src_field is None:
                src_field = fld
            elif src_field != fld:
                return None
            bit_map[out_bit] = w_idx * 32 + b_sh
            continue

        # Form A: check for trailing `<< N` at top level
        d = 0
        sh_at = -1
        for i in range(len(x) - 1):
            ch = x[i]
            if ch == "(":
                d += 1
            elif ch == ")":
                d -= 1
            elif d == 0 and x[i:i+2] == "<<":
                sh_at = i
                break
        if sh_at != -1:
            lhs = x[:sh_at].strip()
            sh_str = x[sh_at+2:].strip()
            if not re.fullmatch(NUM, sh_str):
                return None
            out_bit = int(sh_str[:-1], 0)
        else:
            lhs = x
            out_bit = 0

        if out_bit < 0 or out_bit >= len(terms) or out_bit in bit_map:
            return None

        # Strip optional (QData) / (IData) casts and parens around bit extract
        while True:
            lhs = peel(lhs)
            if lhs.startswith("(QData)"):
                lhs = lhs[7:].strip()
            elif lhs.startswith("(IData)"):
                lhs = lhs[7:].strip()
            else:
                break

        # Must strictly match `1U & (vlSelf->SRC[W] >> S)`, `1U & vlSelf->SRC[W]`,
        # or `vlSelf->SRC[W] >> 0x1fU` (MSB extract where Verilator elides `1U &`).
        m = re.fullmatch(
            rf"1U\s*&\s*(?:\(\s*)?vlSelf->(\w+)\[({NUM})\](?:\s*>>\s*({NUM}))?\s*\)?",
            lhs,
        )
        m_msb = None if m else re.fullmatch(
            rf"vlSelf->(\w+)\[({NUM})\]\s*>>\s*(0x1fU|31U)",
            lhs,
        )
        if not m and not m_msb:
            return None
        if m:
            fld = m.group(1)
            w_idx = int(m.group(2)[:-1], 0)
            b_sh = int(m.group(3)[:-1], 0) if m.group(3) else 0
        else:
            fld = m_msb.group(1)
            w_idx = int(m_msb.group(2)[:-1], 0)
            b_sh = 31
        if fld == dst_field:
            return None
        if src_field is None:
            src_field = fld
        elif src_field != fld:
            return None
        if w_idx >= widths.get(fld, 0) or b_sh >= 32:
            return None
        bit_map[out_bit] = w_idx * 32 + b_sh

    if len(bit_map) != len(terms):
        return None
    full_bits = [bit_map[i] for i in range(len(terms))]
    # Extract the 32 bits actually written to vlSelf->DST[W]
    if is_hi:
        return src_field, full_bits[32:64], full_bits
    if len(full_bits) == 64:
        return src_field, full_bits[0:32], full_bits
    return src_field, full_bits, None


def classify_word(parsed, widths):
    """Classify parsed bit list as either full-64 uniform stride or 4x8-bit octet strides."""
    src_field, out32, full64 = parsed
    max_bits = widths[src_field] * 32

    # Check if full64 has a single positive constant bit stride across all 64 bits
    if full64 is not None:
        stride = full64[1] - full64[0]
        if stride > 0 and all(full64[i] == full64[0] + i * stride for i in range(64)):
            is_hi = (out32[0] == full64[32])
            return ("full64", src_field, full64[0], stride, is_hi, max_bits)

    # Check 4 octets of 8 bits each (handles wrapped 40-bit age_col, etc.)
    octets = []
    for byte in range(4):
        seg = out32[8 * byte : 8 * byte + 8]
        st = seg[1] - seg[0]
        if st <= 0 or any(seg[j] != seg[0] + j * st for j in range(8)):
            return None
        octets.append((seg[0], st))
    return ("octets", src_field, tuple(octets), max_bits)


def lower_bit_columns(source, header):
    widths = {k: int(w) for w, k in re.findall(r"VlWide<(\d+)>/\*[^*]*\*/\s+(\w+);", header)}
    for k, w in re.findall(r"VL_(?:IN|OUT|INOUT)W\((\w+),\d+,\d+,(\d+)\);", header):
        widths[k] = int(w)
    if not widths:
        return source, 0

    runs, run = [], []
    for m in ASSIGN.finditer(source):
        dst_fld = m.group(3)
        dst_w = int(m.group(4)[:-1], 0)
        info = None
        if dst_w < widths.get(dst_fld, 0) and len(m.group(5)) >= 300:
            prefix = source[max(0, m.start() - 128):m.start()].rstrip()
            if prefix.endswith((";", "{", "}", "// Body")):
                parsed = parse_bit_concat_word(m.group(5), dst_fld, widths)
                if parsed is not None:
                    info = classify_word(parsed, widths)
        if run and (info is None or info[0] != run[-1][1][0] or info[1] != run[-1][1][1]
                    or source[run[-1][0].end():m.start()].strip()):
            runs.append(run)
            run = []
        if info is not None:
            run.append((m, info))
    if run:
        runs.append(run)

    pieces, cursor, changed, tile_id = [], 0, 0, 0
    for run in runs:
        if not run:
            continue
        kind = run[0][1][0]
        src_field = run[0][1][1]

        if kind == "full64":
            # Prefer 32-column (4-byte) batched Tile64x4 when >= 16 bit planes land in a
            # 32-bit aligned window strictly in-bounds; fall back to 8-column Tile64 otherwise.
            planes32 = defaultdict(set)
            planes8 = defaultdict(set)
            for _, (_, _, start_bit, stride, is_hi, max_bits) in run:
                b32 = start_bit & ~31
                if b32 + 63 * stride + 31 < max_bits:
                    planes32[(b32, stride)].add(start_bit - b32)
                b8 = start_bit & ~7
                if b8 + 63 * stride + 7 < max_bits:
                    planes8[(b8, stride)].add(start_bit - b8)
            names = {}
            cached_cols = {}
            for m, (_, _, start_bit, stride, is_hi, max_bits) in run:
                b32 = start_bit & ~31
                b8 = start_bit & ~7
                use32 = (b32 + 63 * stride + 31 < max_bits and len(planes32[(b32, stride)]) >= 16)
                if use32:
                    key = ("x4", b32, stride)
                    sub_byte = (start_bit - b32) >> 3
                    plane = (start_bit - b32) & 7
                elif b8 + 63 * stride + 7 < max_bits and len(planes8[(b8, stride)]) >= 4:
                    key = ("x1", b8, stride)
                    sub_byte = -1
                    plane = start_bit - b8
                else:
                    continue
                pieces.append(source[cursor:m.start()])
                if not names:
                    pieces.append("    {\n")
                if key not in names:
                    tname = names[key] = f"__Vg6lcBitTile{tile_id}"
                    tile_id += 1
                    if use32:
                        pieces.append(
                            f"        const auto {tname} = g6lc_column::gather_bits64_x4<{b32}ULL, {stride}ULL>"
                            f"(&vlSelf->{src_field}[0U]);\n"
                        )
                    else:
                        pieces.append(
                            f"        const auto {tname} = g6lc_column::gather_bits64<{b8}ULL, {stride}ULL>"
                            f"(&vlSelf->{src_field}[0U]);\n"
                        )
                tname = names[key]
                ckey = (tname, sub_byte, plane)
                if ckey not in cached_cols:
                    cname = cached_cols[ckey] = f"{tname}_{max(0, sub_byte)}c{plane}"
                    tile_ref = f"{tname}.t[{sub_byte}]" if use32 else tname
                    pieces.append(f"        const uint64_t {cname} = g6lc_column::column64<{plane}>({tile_ref});\n")
                cname = cached_cols[ckey]
                val_expr = f"static_cast<uint32_t>({cname} >> 32U)" if is_hi else f"static_cast<uint32_t>({cname})"
                pieces.append(f"        {m.group(2)} = {val_expr};")
                cursor = m.end()
                changed += 1
            if names:
                pieces.append("\n    }")

        elif kind == "octets":
            # Group each 8-bit octet by (base_bit = start_bit & ~7, stride)
            planes = defaultdict(set)
            for _, (_, _, octets, max_bits) in run:
                for start_bit, stride in octets:
                    base = start_bit & ~7
                    if base + 7 * stride + 7 < max_bits:
                        planes[(base, stride)].add(start_bit - base)
            names = {}
            for m, (_, _, octets, max_bits) in run:
                keys = []
                ok = True
                for start_bit, stride in octets:
                    base = start_bit & ~7
                    key = (base, stride)
                    if base + 7 * stride + 7 >= max_bits or len(planes[key]) < 4:
                        ok = False
                        break
                    keys.append((key, start_bit - base))
                if not ok:
                    continue
                pieces.append(source[cursor:m.start()])
                if not names:
                    pieces.append("    {\n")
                rhs = []
                for idx, (key, plane) in enumerate(keys):
                    base, stride = key
                    if key not in names:
                        oname = names[key] = f"__Vg6lcBitOct{tile_id}"
                        tile_id += 1
                        pieces.append(
                            f"        const uint64_t {oname} = g6lc_column::octet_bits<{base}ULL, {stride}ULL>"
                            f"(&vlSelf->{src_field}[0U]);\n"
                        )
                    rhs.append(f"((static_cast<uint32_t>({names[key]} >> {8 * plane}U) & 255U) << {8 * idx}U)")
                pieces.append(f"        {m.group(2)} = " + " | ".join(rhs) + ";")
                cursor = m.end()
                changed += 1
            if names:
                pieces.append("\n    }")

    if not changed:
        return source, 0
    return '#include "g6lc_column_tile.h"\n' + "".join(pieces) + source[cursor:], changed


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    for a in ("source", "class_header", "output"):
        ap.add_argument(a, type=Path)
    args = ap.parse_args()
    out, hits = lower_bit_columns(args.source.read_text(), args.class_header.read_text())
    if hits:
        with args.output.open("x") as f:
            f.write(out)
    print(f"{hits} arbitrary-bit-stride column words tiled")
