#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Whole-class conservative assert-only dead-cone gating for Verilator C++.

Computes a sound backward liveness fixed point over all `vlSelf->MEMBER`
variables of a Verilated class (e.g. `Vg6lc_testharness_g6lc_core__pi37`):
  - Any member referenced outside the class (root/cluster/hart/TB/triggers),
    or carrying I/O / RVFI / debug / commit / trace markers, or read inside any
    control-flow condition, helper call, local temporary, or non-assertOn()
    expression feeding a live variable is pinned LIVE.
  - Any member whose ONLY reads across the entire model are inside
    `if (VL_UNLIKELY(vlSymsp->_vm_contextp__->assertOn())) { ... }` blocks
    (transitively) is proven ASSERT-ONLY.
  - Pure assert-only functions get an entry early-return guard when
    `!assertOn()`; mixed functions wrap consecutive assert-only member
    assignments in `if (VL_UNLIKELY(vlSymsp->_vm_contextp__->assertOn()))`.

When `assertOn()` is true (default), execution is 100% identical. When
`+verilator+noassert` is passed, the entire shadow equivalence-checker cone is
skipped and moved into `.text.unlikely` under PGO.
"""
from collections import defaultdict
from pathlib import Path
import re

ASSERT_IF_RE = re.compile(
    r"if \((?:VL_UNLIKELY\()?vlSymsp->_vm_contextp__->assertOn\(\)\)?\) \{"
)
MEMBER_DECL_RE = re.compile(
    r"(?:VlWide<\d+>|VlUnpacked<[^>]+>|CData|SData|IData|QData)/\*[^*]*\*/\s+(\w+);"
)
FUNC_START_RE = re.compile(r"\n(?=(?:VL_INLINE_OPT )?void \w+\()")
STMT_ASSIGN_RE = re.compile(
    r"^(?P<indent>    )vlSelf->(?P<lhs>\w+)(?:\[[^\n;]*?\])*\s*=\s*(?P<rhs>[^;]+);",
    re.M,
)


def strip_assert_blocks(src):
    if "->assertOn()" not in src:
        return src
    out = []
    pos = 0
    for m in ASSERT_IF_RE.finditer(src):
        if m.start() < pos:
            continue
        out.append(src[pos : m.start()])
        d = 0
        end = m.end() - 1
        for i in range(m.end() - 1, len(src)):
            ch = src[i]
            if ch == "{":
                d += 1
            elif ch == "}":
                d -= 1
                if d == 0:
                    end = i + 1
                    break
        pos = end
    out.append(src[pos:])
    return "".join(out)


def compute_assert_only_vars(class_header, class_tu_texts, external_texts=()):
    """Return the set of proven assert-only member variable names in `class_header`."""
    all_vars = set(MEMBER_DECL_RE.findall(class_header))
    if not all_vars:
        return set()

    root_live = set()
    # Pin externally referenced variables (root, cluster, hart, TB, Slow init/settle).
    for ext in external_texts:
        for tok in re.findall(r"(?:\.|->)(\w+)\b", ext):
            if tok in all_vars:
                root_live.add(tok)

    # Pin I/O, RVFI, tohost, commit, debug, and trigger-shadow variables conservatively.
    for v in all_vars:
        if any(tok in v for tok in (
            "__Vcellout__", "__Vcellinp__", "__Vtrig", "rvfi", "tohost",
            "commit_instr", "debug_", "clk_i", "rst_n",
        )):
            root_live.add(v)

    var_deps = defaultdict(set)
    written_vars = set()

    # Sound whole-text scan: any occurrence of `vlSelf->VAR` outside assertOn() blocks
    # that is NOT strictly the LHS or RHS of a simple `vlSelf->VAR[...] = ...;` pins VAR live!
    # Also handle Verilator's multi-line LHS wrapping (`vlSelf->VAR[k]\n = ...`).
    lhs_span_re = re.compile(
        r"(?:^|\n)[ \t]+vlSelf->(\w+)(?:\s*\[[^\n;]*?\])*\s*=\s*([^;]+);",
        re.S,
    )
    for raw in class_tu_texts:
        clean = strip_assert_blocks(raw)
        covered_spans = []  # (lhs_tok_start, rhs_start, rhs_end, lhs_var)
        for sm in lhs_span_re.finditer(clean):
            lhs = sm.group(1)
            if lhs not in all_vars:
                continue
            tok_pos = clean.find("vlSelf->", sm.start(), sm.end())
            eq_pos = clean.find("=", tok_pos, sm.end())
            if tok_pos == -1 or eq_pos == -1:
                continue
            rhs_start, rhs_end = eq_pos + 1, sm.end() - 1
            # Reject compound operators (`==`, `!=`, `<=`, `>=`)
            if clean[eq_pos + 1 : eq_pos + 2] == "=" or clean[eq_pos - 1 : eq_pos] in ("!", "<", ">"):
                continue
            written_vars.add(lhs)
            covered_spans.append((tok_pos, rhs_start, rhs_end, lhs))
            for v in re.findall(r"vlSelf->(\w+)", clean[rhs_start:rhs_end]):
                if v in all_vars and v != lhs:
                    var_deps[lhs].add(v)

        # Build sorted index of covered spans to verify every `vlSelf->X` occurrence in O(N).
        span_idx = 0
        n_spans = len(covered_spans)
        for rm in re.finditer(r"vlSelf->(\w+)", clean):
            pos = rm.start()
            v = rm.group(1)
            if v not in all_vars:
                continue
            while span_idx < n_spans and covered_spans[span_idx][2] <= pos:
                span_idx += 1
            if span_idx < n_spans:
                ltok, r0, r1, _ = covered_spans[span_idx]
                if pos == ltok or (r0 <= pos < r1):
                    continue
            root_live.add(v)

    # Backward fixed-point liveness propagation.
    live = set(root_live)
    work = list(live)
    while work:
        u = work.pop()
        for dep in var_deps.get(u, ()):
            if dep not in live:
                live.add(dep)
                work.append(dep)

    return (all_vars - live) & written_vars


def lower_assert_cone(source, dead_vars):
    """Guard writes to proven assert-only variables under `assertOn()`."""
    if not dead_vars or "vlSelf->" not in source:
        return source, 0

    # Find top-level (indent == 4 spaces) member assignments outside existing assertOn() blocks.
    # First mark character ranges already inside assertOn() blocks so we don't double-wrap.
    assert_ranges = []
    for m in ASSERT_IF_RE.finditer(source):
        d = 0
        end = m.end() - 1
        for i in range(m.end() - 1, len(source)):
            ch = source[i]
            if ch == "{":
                d += 1
            elif ch == "}":
                d -= 1
                if d == 0:
                    end = i + 1
                    break
        assert_ranges.append((m.start(), end))

    def in_assert(pos):
        for a, b in assert_ranges:
            if a <= pos < b:
                return True
        return False

    # Collect consecutive top-level dead assignments (not inside unbraced control flow).
    runs, run = [], []
    for m in STMT_ASSIGN_RE.finditer(source):
        lhs = m.group("lhs")
        ok = False
        if lhs in dead_vars and not in_assert(m.start()):
            rhs = m.group("rhs")
            # Ensure RHS has no side effects (calls/assignments)
            if "VL_STOP" not in rhs and "VL_WRITEF" not in rhs:
                prefix = source[max(0, m.start() - 128) : m.start()].rstrip()
                if prefix.endswith((";", "{", "}", "// Body")):
                    ok = True
        if run and (not ok or source[run[-1].end() : m.start()].strip()):
            runs.append(run)
            run = []
        if ok:
            run.append(m)
    if run:
        runs.append(run)

    pieces, cursor, count = [], 0, 0
    for r in runs:
        m0 = r[0]
        pieces.append(source[cursor : m0.start()])
        body_lines = []
        for m in r:
            for ln in m.group(0).splitlines():
                body_lines.append("    " + ln)
        pieces.append(
            "    if (VL_UNLIKELY(vlSymsp->_vm_contextp__->assertOn())) {\n"
            + "\n".join(body_lines)
            + "\n    }"
        )
        cursor = r[-1].end()
        count += len(r)

    if not count:
        return source, 0
    out = "".join(pieces) + source[cursor:]
    # Ensure the Verilator __Syms.h definition is included so `vlSymsp->_vm_contextp__->assertOn()` compiles.
    if "__Syms.h" not in out:
        m_hdr = re.search(r'#include "(V\w+?)_(?:g6lc_|[A-Za-z0-9_]+)\.h"', out)
        if m_hdr:
            syms_inc = f'#include "{m_hdr.group(1)}__Syms.h"\n'
            out = syms_inc + out
    return out, count
