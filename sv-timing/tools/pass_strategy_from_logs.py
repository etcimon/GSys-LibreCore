#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Re-derive PASS-STRATEGY P1–P9 counts from indicative soak logs.
#
#   python tools/pass_strategy_from_logs.py [analyze.json ...]
#
# Defaults:
#   E:/cva6/build-platform/workspace/build/sv-timing/audit-strict-v4/full_core/analyze.json
#   E:/cva6/build-platform/workspace/build/sv-timing/audit-strict-v4/full_corev_apu/analyze.json

from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path

DEFAULTS = [
    Path(r"E:/cva6/build-platform/workspace/build/sv-timing/audit-strict-v4/full_core/analyze.json"),
    Path(
        r"E:/cva6/build-platform/workspace/build/sv-timing/audit-strict-v4/full_corev_apu/analyze.json"
    ),
]

MMU_KW = ("cva6_ptw", "cva6_tlb", "cva6_shared_tlb", "cva6_mmu")


def _file(loc: dict | None) -> str:
    f = ((loc or {}).get("file") or "").replace("\\", "/")
    return f.split("/")[-1] if f else ""


def _blob(path: dict) -> str:
    loc = (path.get("primary_loc") or {}).get("file") or ""
    start = path.get("startpoint") or ""
    end = path.get("endpoint") or ""
    return (loc + " " + start + " " + end).replace("\\", "/").lower()


def summarize(label: str, data: dict) -> None:
    paths = list(data.get("paths") or [])
    banner = data.get("banner") or ""
    budget = data.get("budget_fo4")
    fail = [p for p in paths if float(p.get("slack_fo4") or 0) < 0]
    print(f"\n=== {label} paths={len(paths)} slack<0={len(fail)} budget={budget} ===")
    if banner:
        print("banner", banner)
    print("class", dict(Counter(p.get("path_class") for p in fail)))
    print("kind", dict(Counter(p.get("path_kind") for p in fail)))
    atom = [p for p in fail if p.get("path_class") == "atomic_over_budget"]
    n1 = [p for p in fail if int(p.get("node_count") or 0) <= 1]
    into = [p for p in fail if "into" in str(p.get("path_kind") or "").lower()]
    p4 = [p for p in atom if int(p.get("node_count") or 0) > 1]
    p3 = [p for p in fail if int(p.get("node_count") or 0) <= 1]
    p6 = [
        p
        for p in fail
        if int(p.get("node_count") or 0) > 1
        and budget is not None
        and float(budget) < float(p.get("total_fo4") or 0) < 2.0 * float(budget)
        and p.get("path_class") != "atomic_over_budget"
    ]
    print(f"P3 node_count<=1 n={len(p3)} sum={sum(float(p.get('total_fo4') or 0) for p in n1):.1f}")
    print(f"P4 atomic nodes>1 n={len(p4)}")
    print(f"P5 intoout n={len(into)} / {len(fail)}")
    print(f"P6 shallow n={len(p6)}")
    print(f"atomic n={len(atom)} sum={sum(float(p.get('total_fo4') or 0) for p in atom):.1f}")

    print("-- worst failing (top 12) --")
    for p in sorted(fail, key=lambda x: -float(x.get("total_fo4") or 0))[:12]:
        loc = p.get("primary_loc") or {}
        print(
            f"  {float(p.get('total_fo4') or 0):7.1f} {str(p.get('path_class')):22} "
            f"nodes={int(p.get('node_count') or 0):3} {str(p.get('path_kind')):10} "
            f"{_file(loc)}:{loc.get('start_line')}  {p.get('startpoint')}"
        )

    mmu = [p for p in fail if any(k in _blob(p) for k in MMU_KW)]
    mmu_atom = [p for p in mmu if p.get("path_class") == "atomic_over_budget"]
    print(f"-- MMU failing n={len(mmu)} atomic={len(mmu_atom)} --")
    for p in sorted(mmu_atom, key=lambda x: -float(x.get("total_fo4") or 0)):
        loc = p.get("primary_loc") or {}
        print(
            f"  {float(p.get('total_fo4') or 0):7.1f} nodes={int(p.get('node_count') or 0):3} "
            f"{_file(loc)}:{loc.get('start_line')}  {p.get('class_note')}"
        )

    print("-- atomic_over_budget --")
    for p in sorted(atom, key=lambda x: -float(p_fo4 := float(x.get("total_fo4") or 0)))[:20]:
        loc = p.get("primary_loc") or {}
        print(
            f"  {float(p.get('total_fo4') or 0):7.1f} nodes={int(p.get('node_count') or 0):3} "
            f"{_file(loc)}:{loc.get('start_line')}  {p.get('class_note')}"
        )


def main() -> int:
    files = [Path(a) for a in sys.argv[1:]] or DEFAULTS
    for f in files:
        if not f.is_file():
            print(f"MISSING {f}")
            continue
        print(f"LOG {f}")
        data = json.loads(f.read_text(encoding="utf-8"))
        summarize(f.parent.name, data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
