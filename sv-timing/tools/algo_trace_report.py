#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Summarize a --trace-log JSONL file from sv-timing analyze/correct.

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path


def load_events(path: Path) -> list[dict]:
    evs: list[dict] = []
    with path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                evs.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return evs


def summarize(evs: list[dict]) -> dict:
    kinds = Counter(e.get("kind") for e in evs)
    applies = [e for e in evs if e.get("kind") == "apply"]
    refuses = [e for e in evs if e.get("kind") == "refuse"]
    edit_kinds = Counter(e.get("edit_kind") for e in applies if e.get("edit_kind"))
    refuse_class = Counter(e.get("class") for e in refuses if e.get("class"))
    apply_mod = Counter(e.get("module") for e in applies if e.get("module"))
    hottest_refuse = sorted(
        refuses, key=lambda e: float(e.get("fo4_before") or 0), reverse=True
    )[:8]
    measures = [e for e in evs if e.get("kind") == "measure"]
    last_m = measures[-1] if measures else {}
    first_m = measures[0] if measures else {}
    return {
        "events": len(evs),
        "kinds": dict(kinds),
        "applies": len(applies),
        "refuses": len(refuses),
        "edit_kinds": dict(edit_kinds),
        "refuse_by_class": dict(refuse_class),
        "apply_by_module_top": apply_mod.most_common(12),
        "primary_fo4_first": first_m.get("primary_fo4"),
        "primary_fo4_last": last_m.get("primary_fo4"),
        "worst_all_first": first_m.get("worst_all_fo4"),
        "worst_all_last": last_m.get("worst_all_fo4"),
        "hottest_refuses": [
            {
                "module": e.get("module"),
                "path_id": e.get("path_id"),
                "class": e.get("class"),
                "fo4": e.get("fo4_before"),
                "reloc": e.get("reloc"),
            }
            for e in hottest_refuse
        ],
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Summarize sv-timing --trace-log JSONL")
    ap.add_argument("trace", type=Path, help="algo-trace.jsonl")
    ap.add_argument("--json", action="store_true", help="print JSON summary")
    args = ap.parse_args()
    if not args.trace.is_file():
        print(f"missing {args.trace}")
        return 1
    s = summarize(load_events(args.trace))
    if args.json:
        print(json.dumps(s, indent=2))
        return 0
    print(f"events={s['events']} applies={s['applies']} refuses={s['refuses']}")
    print(f"kinds={s['kinds']}")
    print(f"edit_kinds={s['edit_kinds']}")
    print(f"primary_fo4 {s['primary_fo4_first']} -> {s['primary_fo4_last']}")
    print(f"worst_all {s['worst_all_first']} -> {s['worst_all_last']}")
    print(f"refuse_by_class={s['refuse_by_class']}")
    print("hottest refuses:")
    for r in s["hottest_refuses"]:
        print(f"  {r}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
