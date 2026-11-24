#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Hoist shared scalar conditions across wide masked ternary word runs.

Targets Verilator's word-split wide muxes such as:
  vlSelf->DST[k] = (CONST[k] & (COND ? A_k : B_k));
for contiguous runs of >= 8 words with identical pure scalar COND (disjoint from
DST), emitting:
  if (COND) {
      vlSelf->DST[k] = (CONST[k] & A_k); ...
  } else {
      vlSelf->DST[k] = (CONST[k] & B_k); ...
  }
On the common untouched path (e.g. !flush_ctrl_id && !do_alloc in rob_d, or
a_sel == 0 in mem_n), GCC emits tight contiguous masked copies/SIMD loops
instead of evaluating conditional moves on every word.
"""
import argparse
from pathlib import Path
import re

NUM = r"(?:0x[\da-fA-F]+|[1-9]\d*|0)U"
ASSIGN = re.compile(rf"^(    )(vlSelf->(\w+)\[({NUM})\])\s*=\s*([^;]+);", re.M)
PURE_COND_RE = re.compile(
    r"^[\s()!~&|^=<>0-9a-fA-FxXuUlL]*(?:(?:IData|QData|CData|SData|vlSelf->\w+(?:\[(?:0x[\da-fA-F]+|\d+)U\])?)[\s()!~&|^=<>0-9a-fA-FxXuUlL]*)+$"
)


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


def _split_ternary(s):
    """Split top-level `cond ? t_expr : f_expr`."""
    s = _peel_parens(s)
    d = 0
    q_pos = -1
    for i, ch in enumerate(s):
        if ch == "(":
            d += 1
        elif ch == ")":
            d -= 1
        elif ch == "?" and d == 0:
            q_pos = i
            break
    if q_pos == -1:
        return None
    # Match ':' at the same ternary nesting level
    d = 0
    tern = 0
    c_pos = -1
    for i in range(q_pos + 1, len(s)):
        ch = s[i]
        if ch == "(":
            d += 1
        elif ch == ")":
            d -= 1
        elif d == 0:
            if ch == "?":
                tern += 1
            elif ch == ":":
                if tern == 0:
                    c_pos = i
                    break
                tern -= 1
    if c_pos == -1:
        return None
    return s[:q_pos].strip(), s[q_pos + 1:c_pos].strip(), s[c_pos + 1:].strip()


def _parse_masked_ternary(rhs, dst_field):
    """Parse `(PREFIX & (COND ? A : B))` or `(COND ? A : B)`."""
    if "?" not in rhs or ":" not in rhs:
        return None
    s = re.sub(r"\s+", " ", rhs.strip())
    s = _peel_parens(s)
    prefix = None
    # Check for outer `CONST_MASK & (COND ? A : B)`
    d = 0
    amp_pos = -1
    for i, ch in enumerate(s):
        if ch == "(":
            d += 1
        elif ch == ")":
            d -= 1
        elif ch == "&" and d == 0:
            if (i > 0 and s[i-1] == "&") or (i + 1 < len(s) and s[i+1] == "&"):
                continue
            amp_pos = i
            break
    if amp_pos != -1:
        lhs = s[:amp_pos].strip()
        rest = s[amp_pos + 1:].strip()
        if "?" not in lhs and (
            "__ConstPool__" in lhs or re.fullmatch(NUM, lhs) or re.fullmatch(rf"\w+\[{NUM}\]", lhs)
        ):
            prefix = lhs
            s = rest

    sp = _split_ternary(s)
    if sp is None:
        return None
    cond, t_expr, f_expr = sp
    if not cond or len(cond) > 220 or f"vlSelf->{dst_field}" in cond:
        return None
    # Ensure condition is a pure expression (no calls, no side effects, no assignments)
    if any(bad in cond for bad in (";", ",", "=", "++", "--")):
        # Allow == and !=, reject bare =
        cleaned = cond.replace("==", "").replace("!=", "").replace("<=", "").replace(">=", "")
        if any(bad in cleaned for bad in (";", ",", "=", "++", "--")):
            return None
    if not PURE_COND_RE.fullmatch(cond):
        return None
    return prefix, cond, t_expr, f_expr


def _format_branch_assign(indent, lhs, prefix, expr):
    if prefix is not None:
        return f"{indent}{lhs} = ({prefix} & ({expr}));\n"
    return f"{indent}{lhs} = ({expr});\n"


def _emit_hoisted(run, indent):
    """Emit hoisted if/else (recursively hoisting a second-level common condition in else)."""
    cond = run[0][1][1]
    t_lines = []
    f_items = []
    for m, (prefix, _, t_expr, f_expr) in run:
        lhs = m.group(2)
        t_lines.append(_format_branch_assign(indent + "    ", lhs, prefix, t_expr))
        f_items.append((m, prefix, f_expr))

    # Check if ALL f_items share a common nested ternary condition (e.g. rob_d: flush ? ... : (do_alloc ? ... : rob_q))
    nested = []
    nested_cond = None
    all_nested = True
    for m, prefix, f_expr in f_items:
        p2 = _parse_masked_ternary(f_expr, m.group(3))
        if p2 is None or p2[0] is not None:
            all_nested = False
            break
        if nested_cond is None:
            nested_cond = p2[1]
        elif p2[1] != nested_cond:
            all_nested = False
            break
        nested.append((m, (prefix, p2[1], p2[2], p2[3])))

    out = [f"{indent}if ({cond}) {{\n"]
    out.extend(t_lines)
    if all_nested and nested_cond is not None:
        out.append(f"{indent}}} else if ({nested_cond}) {{\n")
        for m, (prefix, _, t2, _) in nested:
            out.append(_format_branch_assign(indent + "    ", m.group(2), prefix, t2))
        out.append(f"{indent}}} else {{\n")
        for m, (prefix, _, _, f2) in nested:
            out.append(_format_branch_assign(indent + "    ", m.group(2), prefix, f2))
        out.append(f"{indent}}}")
    else:
        out.append(f"{indent}}} else {{\n")
        for m, prefix, f_expr in f_items:
            out.append(_format_branch_assign(indent + "    ", m.group(2), prefix, f_expr))
        out.append(f"{indent}}}")
    return "".join(out)


def lower_wide_mux(source, header=None):
    if "?" not in source:
        return source, 0
    widths = {}
    if header:
        widths = {k: int(w) for w, k in re.findall(r"VlWide<(\d+)>/\*[^*]*\*/\s+(\w+);", header)}

    runs, run = [], []
    for m in ASSIGN.finditer(source):
        dst_fld = m.group(3)
        dst_w = int(m.group(4)[:-1], 0)
        info = None
        if (not widths or dst_w < widths.get(dst_fld, 0)):
            prefix_ctx = source[max(0, m.start() - 128):m.start()].rstrip()
            if prefix_ctx.endswith((";", "{", "}", "// Body")):
                info = _parse_masked_ternary(m.group(5), dst_fld)
        if run and (info is None or m.group(3) != run[-1][0].group(3)
                    or info[1] != run[-1][1][1]
                    or source[run[-1][0].end():m.start()].strip()):
            runs.append(run)
            run = []
        if info is not None:
            run.append((m, info))
    if run:
        runs.append(run)

    pieces, cursor, changed = [], 0, 0
    for r in runs:
        if len(r) < 8:
            continue
        # Ensure none of the branch expressions read back vlSelf->dst_fld (conservative anti-aliasing)
        dst_fld = r[0][0].group(3)
        if any(f"vlSelf->{dst_fld}" in item[1][2] or f"vlSelf->{dst_fld}" in item[1][3] for item in r):
            continue
        m0 = r[0][0]
        pieces.append(source[cursor:m0.start()])
        pieces.append(_emit_hoisted(r, m0.group(1)))
        cursor = r[-1][0].end()
        changed += len(r)
    if not changed:
        return source, 0
    return "".join(pieces) + source[cursor:], changed


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    for a in ("source", "class_header", "output"):
        ap.add_argument(a, type=Path)
    args = ap.parse_args()
    out, hits = lower_wide_mux(args.source.read_text(), args.class_header.read_text())
    if hits:
        with args.output.open("x") as f:
            f.write(out)
    print(f"{hits} wide masked mux words hoisted")
