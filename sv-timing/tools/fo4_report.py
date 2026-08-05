#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Summarize an `sv-timing analyze` JSON report into FO4 readings.

Turns a large analyze report into the three tables a designer actually reads:
frequency closure, the worst paths design-wide, and the worst modules. Pure
stdlib, no host coupling: it only consumes the documented JSON schema.

Usage:
    python tools/fo4_report.py REPORT.json [--top N] [--kind intoreg|intoout|...]
    python tools/fo4_report.py REPORT.json --module multiplier

Disclaimer: structural FO4 estimates, not STA sign-off.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any


def load(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def module_names(rep: dict[str, Any]) -> dict[int, str]:
    return {int(m["id"]): m.get("name", f"<id {m['id']}>") for m in rep.get("modules", [])}


def loc_str(path: dict[str, Any]) -> str:
    loc = path.get("primary_loc") or {}
    f = os.path.basename(str(loc.get("file", "?")))
    return f"{f}:{loc.get('start_line', '?')}"


def print_closure(rep: dict[str, Any]) -> None:
    fc = rep.get("frequency_closure") or {}
    tgt = fc.get("target_mhz")
    print("== frequency closure ==")
    print(f"  target            : {tgt} MHz  (budget {fc.get('budget_fo4', 0):.1f} FO4 "
          f"@ {rep.get('fo4_ps')} ps, margin {rep.get('budget_margin')})")
    print(f"  closes            : {fc.get('closes')}")
    print(f"  max frequency     : {fc.get('max_freq_mhz', 0):.1f} MHz "
          f"(worst path {fc.get('worst_path_fo4', 0):.1f} FO4)")
    print(f"  worst path        : #{fc.get('worst_path_id')} {fc.get('worst_path_kind')} "
          f"{fc.get('worst_startpoint')} -> {fc.get('worst_endpoint')}")
    print(f"  worst slack       : {fc.get('worst_slack_fo4', 0):.1f} FO4")
    print(f"  failing / reg2reg : {fc.get('failing_paths')} / {fc.get('reg_to_reg_paths')}")


def print_scope(rep: dict[str, Any]) -> None:
    files = rep.get("files") or []
    skipped = rep.get("skipped_files") or []
    print("== scope ==")
    print(f"  modules={len(rep.get('modules', []))} paths={len(rep.get('paths', []))} "
          f"opportunities={len(rep.get('opportunities', []))} files={len(files)}")
    if skipped:
        print(f"  skipped_files={len(skipped)} (reading covers the rest):")
        for s in skipped:
            print(f"    - {s.get('path')}")


def print_worst_paths(rep: dict[str, Any], names: dict[int, str], top: int,
                      kind: str | None, module: str | None) -> None:
    paths = rep.get("paths", [])
    if kind:
        paths = [p for p in paths if p.get("path_kind") == kind]
    if module:
        paths = [p for p in paths if names.get(int(p["module_id"]), "") == module]
    paths = sorted(paths, key=lambda p: -float(p.get("total_fo4", 0.0)))[:top]
    print(f"== worst {len(paths)} paths ==")
    print(f"  {'module':<26} {'FO4':>8} {'slack':>9} {'maxMHz':>8} {'nodes':>6} "
          f"{'kind':<9} location")
    for p in paths:
        print(f"  {names.get(int(p['module_id']), '?'):<26} "
              f"{float(p.get('total_fo4', 0)):>8.1f} "
              f"{float(p.get('slack_fo4', 0)):>9.1f} "
              f"{float(p.get('max_freq_mhz', 0)):>8.0f} "
              f"{int(p.get('node_count', 0)):>6} "
              f"{str(p.get('path_kind', '')):<9} {loc_str(p)}")


def print_worst_modules(rep: dict[str, Any], names: dict[int, str], top: int) -> None:
    agg: dict[int, dict[str, Any]] = {}
    for p in rep.get("paths", []):
        mid = int(p["module_id"])
        a = agg.setdefault(mid, {"max": 0.0, "mhz": 0.0, "n": 0, "fail": 0, "loc": ""})
        a["n"] += 1
        if not p.get("closes", True):
            a["fail"] += 1
        f = float(p.get("total_fo4", 0.0))
        if f > a["max"]:
            a["max"], a["mhz"], a["loc"] = f, float(p.get("max_freq_mhz", 0.0)), loc_str(p)
    rows = sorted(agg.items(), key=lambda kv: -kv[1]["max"])[:top]
    print(f"== worst {len(rows)} modules (by max path FO4) ==")
    print(f"  {'module':<26} {'maxFO4':>8} {'maxMHz':>8} {'paths':>6} {'failing':>8} location")
    for mid, a in rows:
        print(f"  {names.get(mid, '?'):<26} {a['max']:>8.1f} {a['mhz']:>8.0f} "
              f"{a['n']:>6} {a['fail']:>8} {a['loc']}")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Summarize sv-timing analyze JSON into FO4 readings.")
    ap.add_argument("report", help="analyze JSON produced by --json-out")
    ap.add_argument("--top", type=int, default=15, help="rows per table (default 15)")
    ap.add_argument("--kind", default=None, help="filter paths by path_kind")
    ap.add_argument("--module", default=None, help="only paths in this module")
    args = ap.parse_args(argv)

    try:
        rep = load(args.report)
    except (OSError, json.JSONDecodeError) as e:
        print(f"error: cannot read {args.report}: {e}", file=sys.stderr)
        return 2

    names = module_names(rep)
    print(rep.get("banner", "sv-timing"))
    print_scope(rep)
    print()
    print_closure(rep)
    print()
    print_worst_paths(rep, names, args.top, args.kind, args.module)
    print()
    print_worst_modules(rep, names, args.top)
    print()
    print(rep.get("disclaimer", "structural FO4 estimate; not STA sign-off"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
