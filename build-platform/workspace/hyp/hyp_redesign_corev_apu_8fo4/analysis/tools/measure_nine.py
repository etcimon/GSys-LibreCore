#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
"""Matched structural measurements of the r31-r39 hyp AI island changes."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[6]
BASE = ROOT / "build-platform/workspace/build/sv-timing/hyp8-src"
ANALYZER = BASE / "inputs/r20-sv-timing.exe"
EXPECTED_ANALYZER = "6d3a2792857543be946a0d5c407a13a6574191d0d5b1b21f26e8c9b86ea21bc4"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    label = sys.argv[1]
    if not label.replace("-", "").isalnum():
        raise ValueError("label must contain only letters, numbers and hyphens")
    assert sha(ANALYZER) == EXPECTED_ANALYZER, "frozen analyzer identity changed"
    stem = BASE / "boards/ai-island" / ("analyze-ai-hyp-" + label)
    assert not stem.with_suffix(".json").exists(), "do not overwrite evidence"
    flist = BASE / "inputs/ai-island-hyp.f"
    param_map = BASE / "inputs/apu-compile/param-map.json"
    sources = [Path(line.strip()) for line in flist.read_text().splitlines()
               if line.strip() and not line.lstrip().startswith(("#", "+"))]
    hashes = {str(p): sha(p) for p in sources}
    command = [
        str(ANALYZER), "analyze", "--files-from", str(flist),
        "--param-map", str(param_map), "--assume-xlen", "64",
        "--package-mode", "packages", "--all-modules", "--stages",
        "--target-mhz", "5000", "--fo4-ps", "20", "--budget-margin", "0.2",
        "--json-out", str(stem.with_suffix(".json")),
        "--ir-out", str(stem.with_suffix(".ir.json")),
    ]
    with stem.with_suffix(".log").open("w", encoding="utf-8") as log:
        subprocess.run(command, cwd=BASE, env=dict(os.environ, RUST_MIN_STACK="16777216"),
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    assert all(sha(Path(p)) == h for p, h in hashes.items()), "source changed during measurement"
    board = json.loads(stem.with_suffix(".json").read_text(encoding="utf-8"))
    assert board["versions"]["measurement"] == "delay-v45"
    modules = {m["id"]: m["name"] for m in board["modules"]}
    metrics = {}
    for mid, name in modules.items():
        paths = [p for p in board["paths"] if p["module_id"] == mid]
        if not paths:
            continue
        ordered = sorted(paths, key=lambda p: p["total_fo4"], reverse=True)
        metrics[name] = {
            "max_fo4": ordered[0]["total_fo4"],
            "paths": len(paths),
            "over_8": sum(p["total_fo4"] > 8.0 for p in paths),
            "flagged_multi_cycle": sum(bool(p.get("multi_cycle")) for p in paths),
            "worst_paths": ordered[:5],
        }
    manifest = {
        "command": command, "versions": board["versions"],
        "analyzer_sha256": sha(ANALYZER), "source_sha256": hashes,
        "filelist_sha256": sha(flist), "param_map_sha256": sha(param_map),
        "report_sha256": sha(stem.with_suffix(".json")),
        "ir_sha256": sha(stem.with_suffix(".ir.json")),
        "skipped_files": board.get("skipped_files"),
        "module_metrics": metrics,
        "scope": "All module-local paths, including atomic operators flagged soft multi_cycle by the analyzer. Such flags do not establish legal timing exceptions. Structural screening, not STA or connected caller arrival.",
    }
    stem.with_suffix(".manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    for name, row in sorted(metrics.items(), key=lambda kv: kv[1]["max_fo4"], reverse=True)[:15]:
        print(f"{name}: {row['max_fo4']:.2f} FO4; {row['over_8']}/{row['paths']} over 8")
    print(stem.with_suffix(".manifest.json"))


if __name__ == "__main__":
    main()
