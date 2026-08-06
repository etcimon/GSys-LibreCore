#!/usr/bin/env python3
import json
from pathlib import Path

base = Path(
    "/mnt/c/Users/etcim/.grok/worktrees/cva6/full-bringup-cleanup/"
    "build-platform/workspace/build/sv-timing/monorepo-soak/sparse_ex"
)
c = json.loads((base / "correct.json").read_text())
a = json.loads((base / "analyze.json").read_text())
print("post", json.dumps(c.get("post_closure"), indent=2))
print("edits:")
for e in c.get("edits") or []:
    print(" ", e.get("kind"), (e.get("rationale") or "")[:150])
budget = float(c.get("post_closure", {}).get("budget_fo4") or 16.0)
print("budget", budget)
exs = c.get("path_exceptions") or []
over = []
for e in exs:
    adj = float(e.get("adjusted_fo4") or 0)
    cls = str(e.get("path_class") or "").lower()
    if adj <= budget + 0.01:
        continue
    if "multi_cycle" in cls or "atomic" in cls:
        continue
    over.append(e)
over.sort(key=lambda e: -float(e.get("adjusted_fo4") or 0))
print("over-budget non-atomic:")
for e in over[:20]:
    print(
        " p=",
        e.get("path_id"),
        "class=",
        e.get("path_class"),
        "adj=",
        round(float(e.get("adjusted_fo4") or 0), 2),
        "ev=",
        (e.get("evidence") or "")[:100],
    )
