# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Audit frozen r98 receipts and source identities; does not rerun workloads."""
import ast
import fnmatch
import hashlib
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[5]


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def receipt(tag, token, success=True):
    out = ROOT / "remote-runs" / tag / "output"
    results = read(out / "results.json")
    text = (out / "sim.log").read_text()
    assert token in text, tag
    assert (results[-1]["rc"] == 0) == success, tag
    assert bool(results[-1]["matched"]) == success, tag
    return dict(results=results, sources=read(out / "sources.json"),
                sim_sha256=sha(out / "sim.log"))


timing = {}
for name in ("lsq-v50", "pmp-raw-v50"):
    before = read(HERE / f"boards/{name}-before.manifest.json")
    after = read(HERE / f"boards/{name}-after.manifest.json")
    assert before["common_sha256"] == after["common_sha256"]
    for phase, manifest in (("before", before), ("after", after)):
        stem = HERE / f"boards/{name}-{phase}"
        summary = read(stem.with_suffix(".summary.json"))
        assert manifest["returncode"] == 0
        assert summary["versions"]["measurement"] == "delay-v50"
        assert summary["report_sha256"] == sha(stem.with_suffix(".json"))
        timing[f"{name}-{phase}"] = dict(summary=summary,
                                        source_sha256=manifest["source_sha256"])
    spec = read(HERE / f"{name}.spec.json")
    assert sha(ROOT / spec["source"]) == after["source_sha256"]

ir = read(HERE / "boards/lsq-v50-after.ir.json")
module = next(m for m in ir["modules"].values() if m["name"] == "g6lc_lsq")
pop = [n for n in module["nodes"].values() if "$countones" in (n.get("rhs") or "")]
assert {n["lhs"] for n in pop} == {"ld_free_o", "st_free_o"}
for node in pop:
    assert node["width"] == 4 and not node["width_defaulted"]
    assert abs(node["fo4_cost"] - 9.169925001442312) < 1e-9
    assert node["fans_in"]

functional = {}
lsq_tags = {
    "before": ("hyp8-r98-lsq-credit-before-c5b-lf",
               "hyp8-r98-lsq-credit-before-c5b-lf2"),
    "after": ("hyp8-r98-lsq-credit-after-c5-lf",
              "hyp8-r98-lsq-credit-after-c5-lf2"),
}
for phase, (full_tag, tag) in lsq_tags.items():
    data = receipt(tag, "HYP8_LSQ_CREDIT_PASS checked=252")
    assert data["results"][-1]["leafArgs"] == ["+credit_only"]
    assert data["sources"]["g6lc_lsq.sv"] == timing[f"lsq-v50-{phase}"]["source_sha256"]
    full_out = ROOT / "remote-runs" / full_tag / "output"
    full_results = read(full_out / "results.json")
    full_sources = read(full_out / "sources.json")
    raw = full_out / "sim.log"
    assert full_results[-1]["rc"] == 0 and full_results[-1]["leafArgs"] == []
    assert not full_results[-1]["matched"]  # no +credit_only: full token only
    assert "HYP8_LSQ_PASS checked=2826" in raw.read_text()
    assert "Verilog $finish" in raw.read_text()
    assert full_sources == data["sources"]
    data["full"] = dict(tag=full_tag, results=full_results,
                        raw_sim_sha256=sha(raw))
    functional[tag] = data
a = functional[lsq_tags["before"][1]]["sources"].copy()
b = functional[lsq_tags["after"][1]]["sources"].copy()
a.pop("g6lc_lsq.sv")
b.pop("g6lc_lsq.sv")
assert a == b

tag = "hyp8-r98-pmp-write-c2"
functional[tag] = receipt(tag, "HYP8_PMP_WRITE_PASS")
extraction = read(ROOT / "build-platform/workspace/build/hyp8-r98-pmp-write-c2/extraction.json")
assert extraction["candidate"]["source_sha256"] == timing["pmp-raw-v50-after"]["source_sha256"]
for name in ("candidate", "reference"):
    assert functional[tag]["sources"][f"g6lc_hyp8_pmp_bank_{name}.sv"] == extraction[name]["wrapper_sha256"]
functional["hyp8-r98-pmp-write-neg-c1"] = receipt(
    "hyp8-r98-pmp-write-neg-c1", "PMP_WRITE_FAIL bank_miter", False)

for phase in ("before", "after"):
    tag = "hyp8-r98-mshr-before-c2b" if phase == "before" else "hyp8-r98-mshr-after-c2"
    functional[tag] = receipt(tag, "HYP8_MSHR_PASS")
    source = HERE / ("mshr-l2-v50.before.sv" if phase == "before" else "mshr-per-entry.rejected.sv")
    assert sha(source) == functional[tag]["sources"]["g6lc_l2_mshr.sv"]
functional["hyp8-r98-mshr-neg-c2"] = receipt("hyp8-r98-mshr-neg-c2", "FAIL mem_q", False)
mshr = ROOT / "build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/l2_cache/g6lc_l2_mshr.sv"
assert sha(mshr) == sha(HERE / "mshr-l2-v50.before.sv")
for name in ("mshr-l2-v50", "mshr-l3-v50"):
    assert sha(HERE / "mshr-per-entry.rejected.sv") == read(
        HERE / f"boards/{name}-after.manifest.json")["source_sha256"]

rules = []
for line in (ROOT / ".licensing-tiers").read_text().splitlines():
    parts = line.split()
    if len(parts) >= 2 and parts[0] in ("R", "T", "U", "F", "P"):
        rules.append((parts[0], parts[1]))
paths = [ROOT / read(HERE / f"{n}.spec.json")["source"] for n in ("lsq-v50", "pmp-raw-v50")]
paths += [
    ROOT / "build-platform/workspace/hyp/hyp_redesign_core_8fo4/core/ooo/g6lc_lsq_event.sv",
    ROOT / "verif/tb/core/tb_g6lc_hyp8_control.sv", ROOT / "verif/tb/l2/tb_g6lc_l2_units.sv",
    *[ROOT / f"verif/regress/remote/{n}.py" for n in
      ("run_hyp8_memory", "run_hyp8_integration", "run_hyp8_smokes")],
    ROOT / "verif/regress/remote/hyp8/build_closure.py",
    *[ROOT / f"verif/tests/custom/hyp8_{n}.S" for n in ("h34_shift_dep", "h33_st_fwd")],
    ROOT / "sv-timing/fixtures/countones_intrinsic.sv",
    *[ROOT / f"sv-timing/crates/sv-timing-core/src/{n}.rs" for n in ("expr", "measure", "width", "version")],
    *HERE.glob("*.py"), *HERE.glob("*.sv"),
]
licensing = {}
for path in paths:
    rel = path.relative_to(ROOT).as_posix()
    tier = [t for t, pattern in rules if fnmatch.fnmatchcase(rel, pattern)][-1]
    text = path.read_text(encoding="utf-8")
    expected = "CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial" if tier == "R" else "MIT"
    header = "\n".join(text.splitlines()[:60])
    ids = [line.split("SPDX-License-Identifier:", 1)[1].strip()
           for line in header.splitlines() if "SPDX-License-Identifier:" in line]
    assert tier in ("R", "T") and ids == [expected] and "Etienne Cimon" in header, (rel, tier, ids)
    if path.suffix == ".py":
        ast.parse(text, filename=rel)
    licensing[rel] = dict(tier=tier, license=expected, sha256=sha(path))

subprocess.run(["git", "-c", "core.whitespace=blank-at-eol,blank-at-eof,space-before-tab,cr-at-eol",
                "diff", "--check", "--", *[p.relative_to(ROOT).as_posix() for p in paths]],
               cwd=ROOT, check=True)
with (HERE / "audit.json").open("w", encoding="utf-8") as out:
    json.dump(dict(timing=timing, functional=functional, licensing=licensing,
                   limitations="Focused checks/structural screens; MSHR timing rejected. "
                   "Aggregate gate recorded separately. No boot, STA or 8-FO4 closure."), out, indent=2)
    out.write("\n")
print("R98_AUDIT_PASS source identities, retained timing, focused receipts, syntax, licensing, scoped diff")
