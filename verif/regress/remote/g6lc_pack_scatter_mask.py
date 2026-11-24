#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Lower 64-bit scatter-OR equality bitmasks (e.g. i_stl_red.dwait_d) in Verilator C++.

Matches:
  vlSelf->DST = OR_{t=0..63} ( (OR_{s=0..N-1} (((vlSelf->MASK >> s) & 1) & (extract(vlSelf->EID, base+s*W, W) == t))) << t )
and replaces the ~950 KB expanded expression with a single call to
  g6lc_age::scatter_eq64<N, W, base, stride>(static_cast<uint32_t>(vlSelf->MASK), &vlSelf->EID[0U]);
"""
import argparse
from pathlib import Path
import re

NUM = r"(?:0x[\da-fA-F]+|[1-9]\d*|0)U"
SCALAR_ASSIGN = re.compile(rf"^(    )(vlSelf->(\w+))\s*=\s*([^;]+);", re.M)


def _peel_parens(s):
    s = s.strip()
    while s.startswith("(") and s.endswith(")"):
        d = 0
        wrap = True
        for i, ch in enumerate(s):
            if ch == "(":
                d += 1
            elif ch == ")":
                d -= 1
                if d == 0 and i != len(s) - 1:
                    wrap = False
                    break
        if not wrap:
            break
        s = s[1:-1].strip()
    return s


def _split_top_level(s, sep):
    out = []
    cur = s
    seplen = len(sep)
    while True:
        cur = _peel_parens(cur)
        d = 0
        pos = -1
        for i in range(len(cur) - seplen + 1):
            ch = cur[i]
            if ch == "(":
                d += 1
            elif ch == ")":
                d -= 1
            elif d == 0 and cur[i:i+seplen] == sep:
                # For '|' avoid matching '||'
                if sep == "|" and (
                    (i > 0 and cur[i-1] == "|") or (i + 1 < len(cur) and cur[i+1] == "|")
                ):
                    continue
                if sep == "&" and (
                    (i > 0 and cur[i-1] == "&") or (i + 1 < len(cur) and cur[i+1] == "&")
                ):
                    continue
                pos = i
                break
        if pos == -1:
            out.append(cur)
            break
        out.append(cur[:pos].strip())
        cur = cur[pos + seplen:].strip()
    return out


def _strip_casts(s):
    while True:
        s = _peel_parens(s)
        if s.startswith("(QData)"):
            s = s[7:].strip()
        elif s.startswith("(IData)"):
            s = s[7:].strip()
        else:
            return s


def _parse_eq_extract(expr, widths):
    """Parse Verilator's equality compare of a packed field slice against a constant `val`.

    Returns (val, arr_name, bit_pos, width) or None.
    """
    e = _strip_casts(expr)
    parts = _split_top_level(e, "==")
    if len(parts) != 2:
        return None
    lhs, rhs = _peel_parens(parts[0]), _peel_parens(parts[1])
    if not re.fullmatch(NUM, lhs):
        return None
    const_val = int(lhs[:-1], 0)
    r = _strip_casts(rhs)

    # Form 1: `(MASK & vlSelf->ARR[W])` where MASK = ((1<<width)-1) << sh
    m = re.fullmatch(rf"({NUM})\s*&\s*vlSelf->(\w+)\[({NUM})\]", r)
    if m:
        mask = int(m.group(1)[:-1], 0)
        arr = m.group(2)
        widx = int(m.group(3)[:-1], 0)
        if mask == 0 or widx >= widths.get(arr, 0):
            return None
        sh = (mask & -mask).bit_length() - 1
        unshifted = mask >> sh
        if (unshifted & (unshifted + 1)) != 0:
            return None
        width = unshifted.bit_length()
        if const_val & ~mask:
            return None
        return (const_val >> sh), arr, widx * 32 + sh, width

    # Form 2: `(vlSelf->ARR[W] >> SH)` (top bits of word: width = 32 - sh)
    m = re.fullmatch(rf"vlSelf->(\w+)\[({NUM})\]\s*>>\s*({NUM})", r)
    if m:
        arr = m.group(1)
        widx = int(m.group(2)[:-1], 0)
        sh = int(m.group(3)[:-1], 0)
        if widx >= widths.get(arr, 0) or not 0 < sh < 32:
            return None
        width = 32 - sh
        if const_val >= (1 << width):
            return None
        return const_val, arr, widx * 32 + sh, width

    # Form 3: `(MASK & (vlSelf->ARR[W] >> SH))`
    m = re.fullmatch(rf"({NUM})\s*&\s*\(\s*vlSelf->(\w+)\[({NUM})\]\s*>>\s*({NUM})\s*\)", r)
    if m:
        mask = int(m.group(1)[:-1], 0)
        arr = m.group(2)
        widx = int(m.group(3)[:-1], 0)
        sh = int(m.group(4)[:-1], 0)
        if mask == 0 or (mask & (mask + 1)) != 0 or widx >= widths.get(arr, 0) or sh >= 32:
            return None
        width = mask.bit_length()
        if sh + width > 32 or const_val >= (1 << width):
            return None
        return const_val, arr, widx * 32 + sh, width

    # Form 4: cross-word `(MASK & ((vlSelf->ARR[W+1] << LSH) | (vlSelf->ARR[W] >> RSH)))`
    m = re.fullmatch(
        rf"({NUM})\s*&\s*\(\s*\(\s*vlSelf->(\w+)\[({NUM})\]\s*<<\s*({NUM})\s*\)\s*\|\s*"
        rf"\(\s*vlSelf->(\w+)\[({NUM})\]\s*>>\s*({NUM})\s*\)\s*\)",
        r,
    )
    if m:
        mask = int(m.group(1)[:-1], 0)
        arr1, w1, lsh = m.group(2), int(m.group(3)[:-1], 0), int(m.group(4)[:-1], 0)
        arr0, w0, rsh = m.group(5), int(m.group(6)[:-1], 0), int(m.group(7)[:-1], 0)
        if arr1 != arr0 or w1 != w0 + 1 or lsh + rsh != 32:
            return None
        if mask == 0 or (mask & (mask + 1)) != 0 or w1 >= widths.get(arr0, 0):
            return None
        width = mask.bit_length()
        if rsh + width <= 32 or const_val >= (1 << width):
            return None
        return const_val, arr0, w0 * 32 + rsh, width

    return None


def _parse_mask_bit(expr):
    """Parse `(vlSelf->MASK >> S)` or `vlSelf->MASK` (bit 0). Returns (mask_var, s) or None."""
    e = _strip_casts(expr)
    m = re.fullmatch(rf"(?:\(IData\)\s*)?\(?\s*vlSelf->(\w+)\s*\)?\s*>>\s*({NUM})", e)
    if m:
        return m.group(1), int(m.group(2)[:-1], 0)
    m = re.fullmatch(rf"(?:\(IData\)\s*)?\(?\s*vlSelf->(\w+)\s*\)?", e)
    if m:
        return m.group(1), 0
    return None


def _parse_preshifted_slot(expr, expected_bit, widths):
    """Parse Verilator's pre-shifted lower-32-bit slot(s):
       (MASK & (((IData)(vlSelf->MASK) <<|>> D) & ((EQ) << T)))
       where MASK has LSB == T (Verilator emits cumulative top masks like 0xc0000000U
       when `EQ << T` is already single-bit at T).
    Returns (out_bit, [(mask_var, slot, (val, arr, bpos, w)), ...]) or None.
    """
    e = _strip_casts(expr)
    parts = _split_top_level(e, "&")
    if len(parts) < 2:
        return None
    p0 = _peel_parens(parts[0])
    if not re.fullmatch(NUM, p0):
        return None
    mv = int(p0[:-1], 0)
    if mv == 0:
        return None
    out_bit = (mv & -mv).bit_length() - 1
    if expected_bit is not None and out_bit != expected_bit:
        return None

    def parse_shifted_eq(x):
        x = _strip_casts(x)
        if out_bit == 0:
            return _parse_eq_extract(x, widths)
        d = 0
        sh_at = -1
        for i in range(len(x) - 1):
            if x[i] == "(":
                d += 1
            elif x[i] == ")":
                d -= 1
            elif d == 0 and x[i:i+2] == "<<":
                sh_at = i
                break
        if sh_at == -1:
            return None
        sh_s = x[sh_at+2:].strip()
        if not re.fullmatch(NUM, sh_s) or int(sh_s[:-1], 0) != out_bit:
            return None
        return _parse_eq_extract(x[:sh_at].strip(), widths)

    def parse_shifted_mask(x):
        x = _strip_casts(x)
        m = re.fullmatch(rf"(?:\(IData\)\s*)?\(?\s*vlSelf->(\w+)\s*\)?\s*(<<|>>)\s*({NUM})", x)
        if m:
            sh = int(m.group(3)[:-1], 0)
            slot = (out_bit - sh) if m.group(2) == "<<" else (out_bit + sh)
            return (m.group(1), slot) if slot >= 0 else None
        m = re.fullmatch(rf"(?:\(IData\)\s*)?\(?\s*vlSelf->(\w+)\s*\)?", x)
        if m:
            return (m.group(1), out_bit)
        return None

    if len(parts) == 3:
        ep = parse_shifted_eq(parts[2])
        mp = parse_shifted_mask(parts[1])
        if ep is None or mp is None:
            ep = parse_shifted_eq(parts[1])
            mp = parse_shifted_mask(parts[2])
        return (out_bit, [(mp[0], mp[1], ep)]) if (ep is not None and mp is not None) else None

    # The RHS under `mv & (...)` can be either a single pre-shifted slot or an OR of slots
    # (Verilator groups `((cand << d) & (eq << T)) | (((IData)(rest)) << T)`).
    out_slots = []
    for sub in _split_top_level(_strip_casts(parts[1]), "|"):
        sub_s = _strip_casts(sub)
        # Check for `(inner << out_bit)`
        d = 0
        sh_at = -1
        for i in range(len(sub_s) - 1):
            if sub_s[i] == "(":
                d += 1
            elif sub_s[i] == ")":
                d -= 1
            elif d == 0 and sub_s[i:i+2] == "<<":
                sh_at = i
                break
        if sh_at != -1:
            sh_str = sub_s[sh_at+2:].strip()
            if re.fullmatch(NUM, sh_str) and int(sh_str[:-1], 0) == out_bit:
                for it in _split_top_level(_strip_casts(sub_s[:sh_at]), "|"):
                    ap = _split_top_level(_strip_casts(it), "&")
                    if len(ap) != 2:
                        return None
                    mp = _parse_mask_bit(ap[0])
                    ep = _parse_eq_extract(ap[1], widths)
                    if mp is None or ep is None:
                        mp = _parse_mask_bit(ap[1])
                        ep = _parse_eq_extract(ap[0], widths)
                    if mp is None or ep is None:
                        return None
                    out_slots.append((mp[0], mp[1], ep))
                continue
        ap = _split_top_level(sub_s, "&")
        if len(ap) != 2:
            return None
        ep = parse_shifted_eq(ap[1])
        mp = parse_shifted_mask(ap[0])
        if ep is None or mp is None:
            ep = parse_shifted_eq(ap[0])
            mp = parse_shifted_mask(ap[1])
        if ep is None or mp is None:
            return None
        out_slots.append((mp[0], mp[1], ep))
    return (out_bit, out_slots) if out_slots else None


def parse_scatter_eq64(rhs, dst_name, widths, scalar_vars):
    if "==" not in rhs or len(rhs) < 20000:
        return None
    s = re.sub(r"\s+", " ", rhs.strip())
    raw_terms = _split_top_level(s, "|")

    # Collect per-output-bit slot dicts: bit_slots[out_bit][slot] = (mvar, arr, bpos, w)
    bit_slots = {}

    def record_slot(out_bit, mvar, slot, ep):
        val, arr, bpos, w = ep
        if val != out_bit or w != 6 or mvar == dst_name or arr == dst_name or mvar not in scalar_vars:
            return False
        d = bit_slots.setdefault(out_bit, {})
        if slot in d:
            return False
        d[slot] = (mvar, arr, bpos, w)
        return True

    def parse_grouped_low32(sub_expr):
        # Iteratively flatten nested parenthesized OR chains inside low-32 `(QData)((IData)(...))`.
        stack = list(reversed(_split_top_level(sub_expr, "|")))
        while stack:
            it = stack.pop()
            x = _peel_parens(it)
            # If x itself is a parenthesized OR of sub-items (e.g. `(slot15 | (slots14..0 << T))`), split it.
            sub_or = _split_top_level(x, "|")
            if len(sub_or) > 1:
                stack.extend(reversed(sub_or))
                continue
            # 1. Try pre-shifted slot(s)
            ps = _parse_preshifted_slot(x, None, widths)
            if ps is not None:
                ob, slist = ps
                if not 0 <= ob < 32:
                    return False
                for mv, sl, ep in slist:
                    if not record_slot(ob, mv, sl, ep):
                        return False
                continue
            # 2. Try shifted `body << t`
            d = 0
            sh_at = -1
            for i in range(len(x) - 1):
                if x[i] == "(":
                    d += 1
                elif x[i] == ")":
                    d -= 1
                elif d == 0 and x[i:i+2] == "<<":
                    sh_at = i
                    break
            if sh_at != -1:
                sh_s = x[sh_at+2:].strip()
                if not re.fullmatch(NUM, sh_s):
                    return False
                ob = int(sh_s[:-1], 0)
                if not 0 <= ob < 32:
                    return False
                body = _strip_casts(x[:sh_at].strip())
                for sub_it in _split_top_level(body, "|"):
                    ap = _split_top_level(_strip_casts(sub_it), "&")
                    if len(ap) != 2:
                        return False
                    mp = _parse_mask_bit(ap[0])
                    ep = _parse_eq_extract(ap[1], widths)
                    if mp is None or ep is None:
                        mp = _parse_mask_bit(ap[1])
                        ep = _parse_eq_extract(ap[0], widths)
                    if mp is None or ep is None or not record_slot(ob, mp[0], mp[1], ep):
                        return False
                continue
            # 3. Unshifted bit-0 slot: `((cand >> s) & eq)`
            ap = _split_top_level(_strip_casts(x), "&")
            if len(ap) != 2:
                return False
            mp = _parse_mask_bit(ap[0])
            ep = _parse_eq_extract(ap[1], widths)
            if mp is None or ep is None:
                mp = _parse_mask_bit(ap[1])
                ep = _parse_eq_extract(ap[0], widths)
            if mp is None or ep is None or not record_slot(0, mp[0], mp[1], ep):
                return False
        return True

    for term in raw_terms:
        x = _peel_parens(term)
        # Check for trailing `<< t` at top level
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
        if sh_at == -1 and len(raw_terms) == 33 and x.startswith("(QData)"):
            if not parse_grouped_low32(_strip_casts(x)):
                return None
            continue
        if sh_at != -1:
            body = x[:sh_at].strip()
            sh_s = x[sh_at+2:].strip()
            if not re.fullmatch(NUM, sh_s):
                return None
            out_bit = int(sh_s[:-1], 0)
        else:
            body = x
            out_bit = 0

        if not 0 <= out_bit < 64:
            return None
        body = _strip_casts(body)
        or_items = _split_top_level(body, "|")
        if not 4 <= len(or_items) <= 32:
            return None
        for item in or_items:
            ap = _split_top_level(_strip_casts(item), "&")
            if len(ap) != 2:
                return None
            mp = _parse_mask_bit(ap[0])
            ep = _parse_eq_extract(ap[1], widths)
            if mp is None or ep is None:
                mp = _parse_mask_bit(ap[1])
                ep = _parse_eq_extract(ap[0], widths)
            if mp is None or ep is None or not record_slot(out_bit, mp[0], mp[1], ep):
                return None

    if len(bit_slots) != 64:
        return None
    ref = bit_slots[0]
    if not 4 <= len(ref) <= 32 or any(bit_slots[b] != ref for b in range(64)):
        return None
    n_slots = len(ref)
    if set(ref.keys()) != set(range(n_slots)):
        return None
    mvars = {v[0] for v in ref.values()}
    earrs = {v[1] for v in ref.values()}
    ws = {v[3] for v in ref.values()}
    if len(mvars) != 1 or len(earrs) != 1 or len(ws) != 1:
        return None
    mask_var = next(iter(mvars))
    eid_arr = next(iter(earrs))
    width = next(iter(ws))
    base_bit = ref[0][2]
    stride = ref[1][2] - ref[0][2]
    if stride <= 0 or any(ref[s][2] != base_bit + s * stride for s in range(n_slots)):
        return None
    if (base_bit + (n_slots - 1) * stride + width) > widths[eid_arr] * 32:
        return None
    return mask_var, eid_arr, n_slots, width, base_bit, stride


def lower_scatter_mask(source, header):
    if "==" not in source:
        return source, 0
    widths = {k: int(w) for w, k in re.findall(r"VlWide<(\d+)>/\*[^*]*\*/\s+(\w+);", header)}
    scalar_vars = set(re.findall(r"\b[CSI]Data/\*[^*]*\*/\s+(\w+);", header))
    qdata_vars = set(re.findall(r"\bQData/\*[^*]*\*/\s+(\w+);", header))
    if not widths or not qdata_vars:
        return source, 0

    count = 0

    def repl(m):
        nonlocal count
        dst = m.group(3)
        if dst not in qdata_vars or len(m.group(4)) < 20000:
            return m.group(0)
        parsed = parse_scatter_eq64(m.group(4), dst, widths, scalar_vars)
        if parsed is None:
            return m.group(0)
        mvar, earr, n_slots, width, base_bit, stride = parsed
        count += 1
        return (
            f"{m.group(1)}{m.group(2)} = g6lc_age::scatter_eq64"
            f"<{n_slots}U, {width}U, {base_bit}U, {stride}U>"
            f"(static_cast<uint32_t>(vlSelf->{mvar}), &vlSelf->{earr}[0U]);"
        )

    out = SCALAR_ASSIGN.sub(repl, source)
    if not count:
        return source, 0
    return '#include "g6lc_age_compare.h"\n' + out, count


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    for a in ("source", "class_header", "output"):
        ap.add_argument(a, type=Path)
    args = ap.parse_args()
    out, hits = lower_scatter_mask(args.source.read_text(), args.class_header.read_text())
    if hits:
        with args.output.open("x") as f:
            f.write(out)
    print(f"{hits} scatter equality bitmasks lowered")
