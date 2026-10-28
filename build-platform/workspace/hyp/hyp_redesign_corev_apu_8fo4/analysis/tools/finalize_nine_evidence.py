#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
"""Summarize frozen r31/r39 boards and capture the reviewed RTL source delta."""
import difflib
import hashlib
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[6]
HYP = ROOT / "build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4"
ANALYSIS = HYP / "analysis"
BOARDS = ROOT / "build-platform/workspace/build/sv-timing/hyp8-src/boards/ai-island"
BEFORE = BOARDS / "analyze-ai-hyp-r31-before.json"
AFTER = BOARDS / "analyze-ai-hyp-r39-owned-final.json"
MODULES = (
    "pe_dot_float_pipe", "policy_subcode", "gemm_seq", "pe_dot_float",
    "inval_queue", "gemm_fp32_norm", "pe_dot", "policy_codec", "desc_engine",
)


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def digest(data):
    return hashlib.sha256(data).hexdigest()


before, after = read_json(BEFORE), read_json(AFTER)
ir = read_json(AFTER.with_suffix(".ir.json"))
manifest = read_json(AFTER.with_suffix(".manifest.json"))
assert before["versions"] == after["versions"] == ir["versions"]
assert digest(AFTER.read_bytes()) == manifest["report_sha256"]
assert digest(AFTER.with_suffix(".ir.json").read_bytes()) == manifest["ir_sha256"]
measured_sources = {Path(p): h for p, h in manifest["source_sha256"].items()}
assert all(digest(p.read_bytes()) == h for p, h in measured_sources.items())
module_ids = [
    {m["name"]: m["id"] for m in board["modules"]} for board in (before, after)
]
ir_paths = {p["id"]: p for p in ir["paths"]}
rows = []
for task, suffix in enumerate(MODULES, 31):
    name = "g6lc_ai_" + suffix
    old, new = [
        sorted((p for p in board["paths"] if p["module_id"] == ids[name]),
               key=lambda p: p["total_fo4"], reverse=True)
        for board, ids in zip((before, after), module_ids)
    ]
    path = ir_paths[new[0]["path_id"]]
    mid = module_ids[1][name]
    assert path["module"] == mid and path["total_fo4"] == new[0]["total_fo4"]
    nodes = ir["modules"][str(mid)]["nodes"]
    rows.append({
        "task": task, "module": name,
        "before_max_fo4": old[0]["total_fo4"], "after_max_fo4": new[0]["total_fo4"],
        "before_over_8": sum(p["total_fo4"] > 8 for p in old), "before_paths": len(old),
        "after_over_8": sum(p["total_fo4"] > 8 for p in new), "after_paths": len(new),
        "callers": [i for i in after["instances"] if i["child_type"] == name],
        "after_paths_detail": new,
        "worst_path_nodes": [
            {k: nodes[str(n)][k] for k in ("lhs", "rhs", "width", "fo4_cost", "loc")}
            for n in path["nodes"]
        ],
    })
result = {
    "baseline_report": str(BEFORE), "final_report": str(AFTER),
    "baseline_sha256": digest(BEFORE.read_bytes()), "final_sha256": digest(AFTER.read_bytes()),
    "versions": after["versions"], "rows": rows,
    "limitations": [
        "Structural screening only; no physical STA closure.",
        "Atomic soft multi-cycle flags do not exempt paths.",
        "Generated carry-save and reduction levels are not fully composed by delay-v45; "
        "dot module maxima are local screening values, not complete operand-to-result arrivals.",
    ],
}
(ANALYSIS / "nine-module-r31-r39-results.json").write_text(
    json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")

zips = ANALYSIS / "tools/zips"
baseline_images = {}
with zipfile.ZipFile(zips / "r31-r39-rtl-evidence.zip") as archive:
    old_hashes = json.loads(archive.read("source-sha256.json"))
    for name, hashes in old_hashes.items():
        data = archive.read("before/" + name)
        assert digest(data) == hashes["before"]
        baseline_images[name] = data
with zipfile.ZipFile(zips / "island-top-pre-r39-ownership.zip") as archive:
    baseline_images["g6lc_ai_island_top.sv"] = archive.read("g6lc_ai_island_top.sv")
output = zips / "r31-r39-owned-rtl-evidence.zip"
assert not output.exists(), "do not overwrite a source snapshot"
hashes, diff = {}, []
with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED) as archive:
    for name, old in baseline_images.items():
        source = HYP / "corev_apu/ai_island" / name
        new = source.read_bytes()
        assert digest(new) == measured_sources[source]
        hashes[name] = {"before": digest(old), "after": digest(new)}
        archive.writestr("before/" + name, old)
        archive.writestr("after/" + name, new)
        diff.extend(difflib.unified_diff(
            old.decode("utf-8").splitlines(), new.decode("utf-8").splitlines(),
            fromfile="before/" + name, tofile="after/" + name, lineterm=""))
    archive.writestr("source-sha256.json", json.dumps(hashes, indent=2) + "\n")
(zips / "r31-r39-owned-rtl.diff").write_text(
    "\n".join(diff) + "\n", encoding="utf-8", newline="\n")
print("CAPTURE", output, "files", len(hashes), "sha256", digest(output.read_bytes()))
for row in rows:
    print(row["module"], row["before_max_fo4"], "->", row["after_max_fo4"],
          f'{row["after_over_8"]}/{row["after_paths"]}')
