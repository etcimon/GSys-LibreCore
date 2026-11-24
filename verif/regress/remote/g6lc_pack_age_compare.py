#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Lower Verilator's inlined circular age comparisons (__Vfunc_ooo_age_older__*).

Performs three strictly semantics-preserving rewrites:
1. 64-way constant-index uvec mask collapse: consecutive runs of
   ooo_age_older(k, b, cp) updating bits k of a 64-bit destination mask
   collapse to a single 64-bit g6lc_age::mask64(b, cp) bitwise operation.
2. 64-way constant-index `if (... & Vfuncout) { dst = 1U; }` collapse:
   collapses to a single 64-bit `(mask & g6lc_age::mask64(b, cp) & range) != 0ULL`.
3. General scalar simplification + word-batched RMW coalescing: replaces
   every remaining 6-statement `(am < cm) == (bm < cm) ? (am < bm) : (bm < cm)`
   block with branchless `g6lc_age::older<MASK>(a, b, cp)`, and coalesces
   consecutive bit-inserts into the same `vlSelf->DST[W]` word.
"""
import argparse
from collections import Counter
from pathlib import Path
import re

NUM = r"(?:0x[\da-fA-F]+|[1-9]\d*|0)U"

# Match a full inlined __Vfunc_ooo_age_older__<ID> block (both constant-a and var-a forms).
AGE_BLOCK_CONST_A = re.compile(
    r"(?P<indent>[ \t]+)"
    r"(?P<p_cp>(?:vlSelf->)?)__Vfunc_ooo_age_older__(?P<id>\d+)__cp\s*=\s*\((?P<mask>" + NUM + r")\s*&\s*(?P<cp_expr>[^;]+)\);\s*"
    r"(?P<p_b>(?:vlSelf->)?)__Vfunc_ooo_age_older__(?P=id)__b\s*=\s*\((?P=mask)\s*&\s*(?P<b_expr>[^;]+)\);\s*"
    r"(?P<p_bm>(?:vlSelf->)?)__Vfunc_ooo_age_older__(?P=id)__bm\s*=\s*\((?P=mask)\s*&\s*(?P=p_b)__Vfunc_ooo_age_older__(?P=id)__b\);\s*"
    r"(?P<p_cm>(?:vlSelf->)?)__Vfunc_ooo_age_older__(?P=id)__cm\s*=\s*\((?P=mask)\s*&\s*(?P=p_cp)__Vfunc_ooo_age_older__(?P=id)__cp\);\s*"
    r"(?P<out_lhs>(?:vlSelf->)?__Vfunc_ooo_age_older__(?P=id)__Vfuncout)\s*=\s*"
    r"\(\(\((?P<a_const>" + NUM + r")\s*<\s*(?P=p_cm)__Vfunc_ooo_age_older__(?P=id)__cm\)\s*==\s*"
    r"\((?P=p_bm)__Vfunc_ooo_age_older__(?P=id)__bm\s*<\s*(?P=p_cm)__Vfunc_ooo_age_older__(?P=id)__cm\)\)\s*\?\s*"
    r"\((?P=a_const)\s*<\s*(?P=p_bm)__Vfunc_ooo_age_older__(?P=id)__bm\)\s*:\s*"
    r"\((?P=p_bm)__Vfunc_ooo_age_older__(?P=id)__bm\s*<\s*(?P=p_cm)__Vfunc_ooo_age_older__(?P=id)__cm\)\);",
    re.S,
)

AGE_BLOCK_VAR_A = re.compile(
    r"(?P<indent>[ \t]+)"
    r"(?P<p_cp>(?:vlSelf->)?)__Vfunc_ooo_age_older__(?P<id>\d+)__cp\s*=\s*\((?P<mask>" + NUM + r")\s*&\s*(?P<cp_expr>[^;]+)\);\s*"
    r"(?P<p_b>(?:vlSelf->)?)__Vfunc_ooo_age_older__(?P=id)__b\s*=\s*\((?P=mask)\s*&\s*(?P<b_expr>[^;]+)\);\s*"
    r"(?P<p_a>(?:vlSelf->)?)__Vfunc_ooo_age_older__(?P=id)__a\s*=\s*\((?P=mask)\s*&\s*(?P<a_expr>[^;]+)\);\s*"
    r"(?P<p_am>(?:vlSelf->)?)__Vfunc_ooo_age_older__(?P=id)__am\s*=\s*\((?P=mask)\s*&\s*(?P=p_a)__Vfunc_ooo_age_older__(?P=id)__a\);\s*"
    r"(?P<p_bm>(?:vlSelf->)?)__Vfunc_ooo_age_older__(?P=id)__bm\s*=\s*\((?P=mask)\s*&\s*(?P=p_b)__Vfunc_ooo_age_older__(?P=id)__b\);\s*"
    r"(?P<p_cm>(?:vlSelf->)?)__Vfunc_ooo_age_older__(?P=id)__cm\s*=\s*\((?P=mask)\s*&\s*(?P=p_cp)__Vfunc_ooo_age_older__(?P=id)__cp\);\s*"
    r"(?P<out_lhs>(?:vlSelf->)?__Vfunc_ooo_age_older__(?P=id)__Vfuncout)\s*=\s*"
    r"\(\(\((?P=p_am)__Vfunc_ooo_age_older__(?P=id)__am\s*<\s*(?P=p_cm)__Vfunc_ooo_age_older__(?P=id)__cm\)\s*==\s*"
    r"\((?P=p_bm)__Vfunc_ooo_age_older__(?P=id)__bm\s*<\s*(?P=p_cm)__Vfunc_ooo_age_older__(?P=id)__cm\)\)\s*\?\s*"
    r"\((?P=p_am)__Vfunc_ooo_age_older__(?P=id)__am\s*<\s*(?P=p_bm)__Vfunc_ooo_age_older__(?P=id)__bm\)\s*:\s*"
    r"\((?P=p_bm)__Vfunc_ooo_age_older__(?P=id)__bm\s*<\s*(?P=p_cm)__Vfunc_ooo_age_older__(?P=id)__cm\)\);",
    re.S,
)

# Match single-bit uvec update immediately following a scalarized const-a age call.
# Tolerates Verilator's multi-line whitespace formatting inside `(hoff)`.
UVEC_STEP = re.compile(
    r"(?P<indent>[ \t]+)"
    r"(?P<out>(?:vlSelf->)?__Vfunc_ooo_age_older__(?P<id>\d+)__Vfuncout)\s*=\s*"
    r"g6lc_age::older<0x3fU>\((?P<k>" + NUM + r"),\s*(?P<b>[^\n,]+),\s*(?P<cp>[^\n;]+)\);\s*"
    r"vlSelf->(?P<dst>\w+)\s*=\s*\(\((?P<clrmask>0x[\da-fA-F]+ULL)\s*&\s*vlSelf->(?P=dst)\)\s*\|\s*"
    r"\(\(QData\)\(\(IData\)\(\(\(\(IData\)\(\(?vlSelf->(?P<unres>\w+)(?:\s*>>\s*(?P<k2>" + NUM + r"))?\)?\)\s*&\s*"
    r"\(vlSelf->(?P<hart>\w+)\[\s*\(3U\s*&\s*\(\(\(IData\)\((?P<k3>" + NUM + r")\)\s*\+\s*(?P<hoff1>[^;\]]+?)\)\s*>>\s*5U\)\)\]\s*>>\s*"
    r"\(0x1fU\s*&\s*\(\(IData\)\((?P<k4>" + NUM + r")\)\s*\+\s*(?P<hoff2>[^;]+?)\)\)\)\)\s*&\s*\(IData\)\((?P=out)\)\)\)\)"
    r"(?:\s*<<\s*(?P<k5>" + NUM + r"))?\)\);",
    re.S,
)

# Match `if (... & __Vfuncout) { vlSelf->DST = 1U; }` immediately following scalarized const-a age call:
OU_STEP = re.compile(
    r"(?P<indent>[ \t]+)"
    r"(?P<out>(?:vlSelf->)?__Vfunc_ooo_age_older__(?P<id>\d+)__Vfuncout)\s*=\s*"
    r"g6lc_age::older<0x3fU>\((?P<k>" + NUM + r"),\s*(?P<b>[^\n,]+),\s*(?P<cp>[^\n;]+)\);\s*"
    r"if\s*\(\(\(\(IData\)\(\(?vlSelf->(?P<unres>\w+)(?:\s*>>\s*(?P<k2>" + NUM + r"))?\)?\)\s*&\s*"
    r"\(vlSelf->(?P<hart>\w+)\[\s*\(3U\s*&\s*\(\(\(IData\)\((?P<k3>" + NUM + r")\)\s*\+\s*(?P<hoff1>[^;\]]+?)\)\s*>>\s*5U\)\)\]\s*>>\s*"
    r"\(0x1fU\s*&\s*\(\(IData\)\((?P<k4>" + NUM + r")\)\s*\+\s*(?P<hoff2>[^;]+?)\)\)\)\)\s*&\s*\(IData\)\((?P=out)\)\)\)\s*\{\s*"
    r"vlSelf->(?P<dst>\w+)\s*=\s*1U;\s*\}",
    re.S,
)

# Match consecutive word bit-inserts (like vio_age_d[W]):
#   __Vfunc_ooo_age_older__<ID>__Vfuncout = g6lc_age::older<MASK>(A, B, CP);
#   vlSelf->DST[W] = ((CLRMASK & vlSelf->DST[W]) | ((IData)(OUT) << BIT));
WORD_BIT_STEP = re.compile(
    r"(?P<indent>[ \t]+)"
    r"(?P<out>(?:vlSelf->)?__Vfunc_ooo_age_older__(?P<id>\d+)__Vfuncout)\s*=\s*"
    r"(?P<call>g6lc_age::older<0x[\da-fA-F]+U>\([^\n;]+\));\s*"
    r"vlSelf->(?P<dst>\w+)\[(?P<widx>" + NUM + r")\]\s*=\s*\(\((?P<clrmask>0x[\da-fA-F]+U)\s*&\s*vlSelf->(?P=dst)\[(?P=widx)\]\)\s*\|\s*"
    r"(?:\(\(IData\)\((?P=out)\)\s*<<\s*(?P<bit>" + NUM + r")\)|\(IData\)\((?P=out)\))\);",
    re.S,
)


def _norm(expr):
    return re.sub(r"\s+", " ", expr.strip())


def _safe_temp_ids(source, matches):
    """Ensure local helper temps (__cp/__a/__b/__am/__bm/__cm) are never read outside their block.

    Ignores Verilator's `// Init` declarations (`CData ...;`) and zero-initializations (`... = 0;`).
    """
    # Strip declaration and `= 0;` lines from consideration so only real uses are counted.
    body_only = re.sub(
        r"^[ \t]*(?:CData/\*[^*]*\*/\s+|IData/\*[^*]*\*/\s+|)__Vfunc_ooo_age_older__\d+__(?:cp|a|b|am|bm|cm)(?:\s*=\s*0U?)?;\s*$",
        "",
        source,
        flags=re.M,
    )
    counts = Counter(re.findall(r"__Vfunc_ooo_age_older__(\d+)__(cp|a|b|am|bm|cm)\b", body_only))
    safe = set()
    for kind, m in matches:
        fid = m.group("id")
        if kind == "const":
            ok = (counts[(fid, "cp")] == 2 and counts[(fid, "b")] == 2
                  and counts[(fid, "bm")] == 4 and counts[(fid, "cm")] == 4
                  and counts[(fid, "a")] == 0 and counts[(fid, "am")] == 0)
        else:
            ok = (counts[(fid, "cp")] == 2 and counts[(fid, "b")] == 2
                  and counts[(fid, "a")] == 2 and counts[(fid, "am")] == 3
                  and counts[(fid, "bm")] == 4 and counts[(fid, "cm")] == 4)
        if ok:
            safe.add(fid)
    return safe


def _is_power_of_two_mask(mask_val):
    return mask_val > 0 and ((mask_val + 1) & mask_val) == 0


def _collapse_uvec_runs(source, out_uses):
    matches = list(UVEC_STEP.finditer(source))
    if not matches:
        return source, 0
    runs, run = [], []
    for m in matches:
        k = int(m.group("k")[:-1], 0)
        k2 = int(m.group("k2")[:-1], 0) if m.group("k2") else 0
        k3 = int(m.group("k3")[:-1], 0)
        k4 = int(m.group("k4")[:-1], 0)
        k5 = int(m.group("k5")[:-1], 0) if m.group("k5") else 0
        clr = int(m.group("clrmask")[:-3], 16)
        out_name = m.group("out")
        h1, h2 = _norm(m.group("hoff1")), _norm(m.group("hoff2"))
        # Require exact bit k consistency, identical hoff, local temp not reused outside this statement, and clean mask.
        valid = (
            0 <= k < 64 and k == k2 == k3 == k4 == k5
            and h1 == h2
            and clr == ((~ (1 << k)) & 0xffffffffffffffff)
            and not out_name.startswith("vlSelf->")
            and out_uses.get(out_name, 0) == 2
        )
        key = (m.group("dst"), m.group("unres"), m.group("hart"),
               h1, _norm(m.group("b")), _norm(m.group("cp"))) if valid else None
        if run and (not valid or key != run[-1][1] or k in {x[2] for x in run}
                    or source[run[-1][0].end():m.start()].strip()):
            runs.append(run)
            run = []
        if valid:
            run.append((m, key, k))
    if run:
        runs.append(run)

    pieces, cursor, collapsed = [], 0, 0
    for r in runs:
        if len(r) < 4:
            continue
        m0 = r[0][0]
        prefix = source[max(0, m0.start() - 128):m0.start()].rstrip()
        if not prefix.endswith((";", "{", "}", "// Body")):
            continue
        dst, unres, hart, hoff, b_expr, cp_expr = r[0][1]
        indent = m0.group("indent")
        run_mask = 0
        for _, _, k in r:
            run_mask |= (1 << k)
        # Note: hoff is either `(0x40U & (...))` or `((IData)(...) << 6U)`, always a multiple of 64 (0 or 64)
        # mapped into VlWide<4> st_hart_mask_o via `(3U & ((k + hoff) >> 5U))`:
        # word_base = (hoff >> 5U) & 2U (0 for hart 0, 2 for hart 1).
        pieces.append(source[cursor:m0.start()])
        block = [
            f"{indent}{{\n",
            f"{indent}    const uint32_t __Vg6lcHb = (3U & (static_cast<uint32_t>({hoff}) >> 5U));\n",
            f"{indent}    const uint64_t __Vg6lcHm = (static_cast<uint64_t>(vlSelf->{hart}[__Vg6lcHb + 1U]) << 32U) | vlSelf->{hart}[__Vg6lcHb];\n",
            f"{indent}    const uint64_t __Vg6lcVal = vlSelf->{unres} & __Vg6lcHm & g6lc_age::mask64({b_expr}, {cp_expr});\n",
        ]
        if run_mask == 0xffffffffffffffff:
            block.append(f"{indent}    vlSelf->{dst} = __Vg6lcVal;\n")
        else:
            block.append(
                f"{indent}    vlSelf->{dst} = (vlSelf->{dst} & 0x{(~run_mask) & 0xffffffffffffffff:016x}ULL) "
                f"| (__Vg6lcVal & 0x{run_mask:016x}ULL);\n"
            )
        block.append(f"{indent}}}")
        pieces.append("".join(block))
        cursor = r[-1][0].end()
        collapsed += len(r)
    if not collapsed:
        return source, 0
    return "".join(pieces) + source[cursor:], collapsed


def _collapse_ou_runs(source, out_uses):
    matches = list(OU_STEP.finditer(source))
    if not matches:
        return source, 0
    runs, run = [], []
    for m in matches:
        k = int(m.group("k")[:-1], 0)
        k2 = int(m.group("k2")[:-1], 0) if m.group("k2") else 0
        k3 = int(m.group("k3")[:-1], 0)
        k4 = int(m.group("k4")[:-1], 0)
        out_name = m.group("out")
        h1, h2 = _norm(m.group("hoff1")), _norm(m.group("hoff2"))
        valid = (
            0 <= k < 64 and k == k2 == k3 == k4
            and h1 == h2
            and not out_name.startswith("vlSelf->")
            and out_uses.get(out_name, 0) == 2
        )
        key = (m.group("dst"), m.group("unres"), m.group("hart"),
               h1, _norm(m.group("b")), _norm(m.group("cp"))) if valid else None
        if run and (not valid or key != run[-1][1] or k in {x[2] for x in run}
                    or source[run[-1][0].end():m.start()].strip()):
            runs.append(run)
            run = []
        if valid:
            run.append((m, key, k))
    if run:
        runs.append(run)

    pieces, cursor, collapsed = [], 0, 0
    for r in runs:
        if len(r) < 4:
            continue
        m0 = r[0][0]
        prefix = source[max(0, m0.start() - 128):m0.start()].rstrip()
        if not prefix.endswith((";", "{", "}", "// Body")):
            continue
        dst, unres, hart, hoff, b_expr, cp_expr = r[0][1]
        indent = m0.group("indent")
        run_mask = 0
        for _, _, k in r:
            run_mask |= (1 << k)
        pieces.append(source[cursor:m0.start()])
        mask_tail = "" if run_mask == 0xffffffffffffffff else f" & 0x{run_mask:016x}ULL"
        block = (
            f"{indent}{{\n"
            f"{indent}    const uint32_t __Vg6lcHb = (3U & (static_cast<uint32_t>({hoff}) >> 5U));\n"
            f"{indent}    const uint64_t __Vg6lcHm = (static_cast<uint64_t>(vlSelf->{hart}[__Vg6lcHb + 1U]) << 32U) | vlSelf->{hart}[__Vg6lcHb];\n"
            f"{indent}    if ((vlSelf->{unres} & __Vg6lcHm & g6lc_age::mask64({b_expr}, {cp_expr}){mask_tail}) != 0ULL) {{\n"
            f"{indent}        vlSelf->{dst} = 1U;\n"
            f"{indent}    }}\n"
            f"{indent}}}"
        )
        pieces.append(block)
        cursor = r[-1][0].end()
        collapsed += len(r)
    if not collapsed:
        return source, 0
    return "".join(pieces) + source[cursor:], collapsed


def _batch_word_bit_inserts(source, out_uses):
    """Coalesce consecutive single-bit RMWs into the same vlSelf->DST[W] word."""
    matches = list(WORD_BIT_STEP.finditer(source))
    if not matches:
        return source, 0
    runs, run = [], []
    for m in matches:
        bit = int(m.group("bit")[:-1], 0) if m.group("bit") else 0
        clr = int(m.group("clrmask")[:-1], 16)
        out_name = m.group("out")
        valid = (
            0 <= bit < 32
            and clr == ((~(1 << bit)) & 0xffffffff)
            and not out_name.startswith("vlSelf->")
            and out_uses.get(out_name, 0) == 2
        )
        key = (m.group("dst"), m.group("widx")) if valid else None
        if run and (not valid or key != run[-1][1] or bit in {x[2] for x in run}
                    or source[run[-1][0].end():m.start()].strip()):
            runs.append(run)
            run = []
        if valid:
            run.append((m, key, bit))
    if run:
        runs.append(run)

    pieces, cursor, batched = [], 0, 0
    for r in runs:
        if len(r) < 4:
            continue
        m0 = r[0][0]
        prefix = source[max(0, m0.start() - 128):m0.start()].rstrip()
        if not prefix.endswith((";", "{", "}", "// Body")):
            continue
        dst, widx = r[0][1]
        indent = m0.group("indent")
        # Refuse if any RHS call reads back vlSelf->dst
        if any(f"vlSelf->{dst}" in m.group("call") for m, _, _ in r):
            continue
        run_mask = 0
        for _, _, b in r:
            run_mask |= (1 << b)
        pieces.append(source[cursor:m0.start()])
        # Try AVX-512VL+BW 32-lane vector path when >= 16 bits in this word share mask 0x3fU and cp.
        call_re = re.compile(r"^g6lc_age::older<0x3fU>\(([^,]+),\s*([^,]+),\s*(.+)\)$")
        parsed_calls = [call_re.match(m.group("call")) for m, _, _ in r]
        if len(r) >= 16 and all(parsed_calls):
            cps = {_norm(pc.group(3)) for pc in parsed_calls}
            if len(cps) == 1:
                cp_expr = next(iter(cps))
                a_exprs = [_norm(pc.group(1)) for pc in parsed_calls]
                b_by_bit = {b: _norm(pc.group(2)) for (_, _, b), pc in zip(r, parsed_calls)}
                a_by_bit = {b: _norm(pc.group(1)) for (_, _, b), pc in zip(r, parsed_calls)}
                lines = [f"{indent}{{\n"]
                b_init = ", ".join(f"static_cast<uint8_t>({b_by_bit[i]})" if i in b_by_bit else "0U" for i in range(32))
                lines.append(f"{indent}    const uint8_t __Vg6lcB[32] = {{{b_init}}};\n")
                if len(set(a_exprs)) == 1:
                    lines.append(
                        f"{indent}    const uint32_t __Vg6lcVec = g6lc_age::older32_const_a<0x3fU>({a_exprs[0]}, __Vg6lcB, {cp_expr});\n"
                    )
                else:
                    a_init = ", ".join(f"static_cast<uint8_t>({a_by_bit[i]})" if i in a_by_bit else "0U" for i in range(32))
                    lines.append(f"{indent}    const uint8_t __Vg6lcA[32] = {{{a_init}}};\n")
                    lines.append(
                        f"{indent}    const uint32_t __Vg6lcVec = g6lc_age::older32_u8<0x3fU>(__Vg6lcA, __Vg6lcB, {cp_expr});\n"
                    )
                if run_mask == 0xffffffff:
                    lines.append(f"{indent}    vlSelf->{dst}[{widx}] = __Vg6lcVec;\n")
                else:
                    lines.append(
                        f"{indent}    vlSelf->{dst}[{widx}] = (vlSelf->{dst}[{widx}] & 0x{(~run_mask) & 0xffffffff:08x}U) "
                        f"| (__Vg6lcVec & 0x{run_mask:08x}U);\n"
                    )
                lines.append(f"{indent}}}")
                pieces.append("".join(lines))
                cursor = r[-1][0].end()
                batched += len(r)
                continue

        lines = [f"{indent}{{\n"]
        if run_mask == 0xffffffff:
            lines.append(f"{indent}    uint32_t __Vg6lcW = 0U;\n")
        else:
            lines.append(f"{indent}    uint32_t __Vg6lcW = vlSelf->{dst}[{widx}] & 0x{(~run_mask) & 0xffffffff:08x}U;\n")
        for m, _, b in r:
            call = m.group("call")
            if b == 0:
                lines.append(f"{indent}    __Vg6lcW |= static_cast<uint32_t>({call});\n")
            else:
                lines.append(f"{indent}    __Vg6lcW |= (static_cast<uint32_t>({call}) << {b}U);\n")
        lines.append(f"{indent}    vlSelf->{dst}[{widx}] = __Vg6lcW;\n")
        lines.append(f"{indent}}}")
        pieces.append("".join(lines))
        cursor = r[-1][0].end()
        batched += len(r)
    if not batched:
        return source, 0
    return "".join(pieces) + source[cursor:], batched


def lower_age_compare(source, header=None):
    if "__Vfunc_ooo_age_older__" not in source:
        return source, 0

    raw_matches = []
    for m in AGE_BLOCK_CONST_A.finditer(source):
        raw_matches.append(("const", m))
    for m in AGE_BLOCK_VAR_A.finditer(source):
        raw_matches.append(("var", m))
    if not raw_matches:
        return source, 0
    raw_matches.sort(key=lambda item: item[1].start())

    safe_ids = _safe_temp_ids(source, raw_matches)
    if not safe_ids:
        return source, 0

    pieces, cursor, scalar_hits = [], 0, 0
    for kind, m in raw_matches:
        if m.start() < cursor:
            continue
        fid = m.group("id")
        if fid not in safe_ids:
            continue
        mask_str = m.group("mask")
        mask_val = int(mask_str[:-1], 0)
        if not _is_power_of_two_mask(mask_val):
            continue
        indent = m.group("indent")
        out_lhs = m.group("out_lhs")
        cp_expr = _norm(m.group("cp_expr"))
        b_expr = _norm(m.group("b_expr"))
        a_expr = m.group("a_const") if kind == "const" else _norm(m.group("a_expr"))
        pieces.append(source[cursor:m.start()])
        pieces.append(f"{indent}{out_lhs} = g6lc_age::older<0x{mask_val:x}U>({a_expr}, {b_expr}, {cp_expr});")
        cursor = m.end()
        scalar_hits += 1

    if not scalar_hits:
        return source, 0

    cur = "".join(pieces) + source[cursor:]
    def count_out_uses(text):
        body = re.sub(
            r"^[ \t]*(?:CData/\*[^*]*\*/\s+|IData/\*[^*]*\*/\s+|)__Vfunc_ooo_age_older__\d+__Vfuncout(?:\s*=\s*0U?)?;\s*$",
            "",
            text,
            flags=re.M,
        )
        return Counter(re.findall(r"(?:vlSelf->)?__Vfunc_ooo_age_older__\d+__Vfuncout\b", body))

    # Count real body uses of each local __Vfunc_ooo_age_older__<id>__Vfuncout so we only fold single-use temps.
    cur, _ = _collapse_uvec_runs(cur, count_out_uses(cur))
    cur, _ = _collapse_ou_runs(cur, count_out_uses(cur))
    cur, _ = _batch_word_bit_inserts(cur, count_out_uses(cur))
    return '#include "g6lc_age_compare.h"\n' + cur, scalar_hits


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    for a in ("source", "output"):
        ap.add_argument(a, type=Path)
    args = ap.parse_args()
    out, hits = lower_age_compare(args.source.read_text())
    if hits:
        with args.output.open("x") as f:
            f.write(out)
    print(f"{hits} circular age comparisons lowered")
