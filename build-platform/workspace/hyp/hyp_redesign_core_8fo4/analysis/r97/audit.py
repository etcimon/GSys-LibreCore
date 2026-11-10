# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Record final source, functional-receipt, syntax and scoped licensing checks."""
import ast
import fnmatch
import json
from pathlib import Path
import subprocess
from measure import HERE, ROOT, FLU, read, sha, write

inputs = read(HERE / "functional-inputs-final.json")
snapshot = Path(inputs["candidate-final"]["path"])
manifest = read(snapshot / "manifest.json")
rtl_rel = FLU.relative_to(ROOT).as_posix()
assert sha(FLU) == inputs["candidate-final"]["rtl_sha256"] == manifest["files"][rtl_rel]
assert sha(snapshot / "manifest.json") == inputs["candidate-final"]["manifest_sha256"]
for rel, digest in manifest["files"].items():
    assert sha(snapshot / rel) == digest, rel

functional = {}
for tag in ("hyp8-r97-flu-baseline-v1", "hyp8-r97-flu-candidate-v1", "hyp8-r97-issue-v1"):
    out = ROOT / "remote-runs" / tag / "output"
    results = read(out / "results.json")
    assert results[-1]["rc"] == 0 and results[-1]["matched"]
    sources = read(out / "sources.json")
    source_manifest = read(Path(inputs["baseline-verified"]["path"]) / "manifest.json") \
        if "baseline" in tag else manifest
    for name, digest in sources.items():
        matches = [p for p in source_manifest["files"] if Path(p).name == Path(name).name]
        assert len(matches) == 1, (name, matches)
        assert source_manifest["files"][matches[0]] == digest, (tag, name)
    if "issue" not in tag:
        assert results[0]["warningCensus"] == {}
        expected = inputs["baseline-verified" if "baseline" in tag else "candidate-final"]
        assert results[0]["sourceManifestSha256"] == expected["manifest_sha256"]
    functional[tag] = dict(results=results, sources_sha256=sha(out / "sources.json"),
                           sim_log_sha256=sha(out / "sim.log"))

timing = {}
for phase in ("before", "after"):
    for ports in (2, 8):
        stem = HERE / "boards" / f"bound-{phase}-p{ports}"
        receipt = read(stem.with_suffix(".manifest.json"))
        summary = read(stem.with_suffix(".summary.json"))
        assert receipt["returncode"] == 0
        assert sha(stem.with_suffix(".json")) == summary["report_sha256"]
        source = FLU if phase == "after" else HERE / "g6lc_flu_reserve.before.sv"
        assert sha(source) == receipt["source_sha256"]
        ir = read(stem.with_suffix(".ir.json"))
        module = next(m for m in ir["modules"].values() if m["name"] == "g6lc_flu_reserve")
        defaults = [n["lhs"] for n in module["nodes"].values() if n.get("width_defaulted")]
        if phase == "after":
            assert not defaults
        timing[stem.name] = dict(summary=summary, width_defaulted_nodes=defaults,
                                 source_sha256=receipt["source_sha256"])

rules = []
for line in (ROOT / ".licensing-tiers").read_text(encoding="utf-8").splitlines():
    parts = line.split()
    if len(parts) >= 2 and parts[0] in ("R", "T", "U", "P", "F"):
        rules.append((parts[0], parts[1]))
paths = [FLU, HERE / "g6lc_flu_reserve.before.sv",
         ROOT / "verif/tb/core/tb_g6lc_hyp8_control.sv",
         ROOT / "verif/regress/remote/run_hyp8_memory.py", *HERE.glob("*.py")]
licensing = {}
for path in paths:
    rel = path.relative_to(ROOT).as_posix()
    tier = [t for t, pattern in rules if fnmatch.fnmatchcase(rel, pattern)][-1]
    text = path.read_text(encoding="utf-8")
    expected = "CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial" if tier == "R" else "MIT"
    # Tooling contains the marker text in code, so inspect comment headers only.
    ids = [line.split("SPDX-License-Identifier:", 1)[1].strip()
           for line in text.splitlines()[:10] if "SPDX-License-Identifier:" in line]
    assert tier in ("R", "T") and ids == [expected] and "Etienne Cimon" in text[:600], rel
    if path.suffix == ".py":
        ast.parse(text, filename=rel)
    licensing[rel] = dict(tier=tier, license=expected, sha256=sha(path))

subprocess.run(["git", "-c", "core.whitespace=blank-at-eol,blank-at-eof,space-before-tab,cr-at-eol",
                "diff", "--check"], cwd=ROOT, check=True)
write(HERE / "audit.json", dict(functional=functional, timing=timing, licensing=licensing,
                                gate=read(HERE / "aggregate-verify.json"),
                                limitation="Structural screens only; see worklog for classifier/guard and gate limits."))
print("R97_AUDIT_PASS: source identities, focused results, bound reports, syntax, licensing and diff")
