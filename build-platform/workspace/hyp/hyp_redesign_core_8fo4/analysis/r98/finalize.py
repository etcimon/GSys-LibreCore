# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Reassess captured integration evidence without rebuilding or rerunning it."""
import ast
import hashlib
import importlib.util
import json
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[5]


def read(path):
    return json.loads(path.read_text())


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


build_tag = "hyp8-r98-integration-final2"
smoke_tag = "hyp8-r98-smokes-final2"
build = ROOT / "remote-runs" / build_tag / "output"
smoke = ROOT / "remote-runs" / smoke_tag / "output"
closure = ROOT / "build-platform/workspace/build" / build_tag
manifest = read(closure / "manifest.json")
assert sha(closure / "manifest.json") == "226f960c85698a40e64cefc8923bb6b00dab59b5f1ff50e25157096da94301fa"
results = read(build / "results.json")
smokes = read(smoke / "smokes-results.json")
assert results["status"] == "build_complete" and results["build"]["rc"] == 0
assert results["build"]["runtimeDepChecked"]
assert results["sourceFiles"] == len(manifest["files"])
model_sha = sha(build / "model/Variane_testharness")
assert model_sha == results["build"]["modelSha256"] == smokes["modelSha256"]

core = "build-platform/workspace/hyp/hyp_redesign_core_8fo4/core/"
retained = [
    core + "csr_regfile.sv", core + "ooo/g6lc_lsq.sv",
    core + "ooo/g6lc_lsq_event.sv", core + "ooo/g6lc_flu_reserve.sv",
    "build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu/l2_cache/g6lc_l2_mshr.sv",
    "verif/regress/remote/hyp8/Flist.hyp8_mc_sim",
]
eol_equivalent = {}
for path in retained:
    if path.endswith("g6lc_lsq_event.sv"):
        norm = lambda p: p.read_bytes().replace(b"\r\n", b"\n")
        assert norm(ROOT / path) == norm(closure / path), path
        eol_equivalent[path] = dict(
            current_sha256=sha(ROOT / path),
            tested_sha256=manifest["files"][path],
            comparison="lf-normalized bytes")
        continue
    assert sha(ROOT / path) == manifest["files"][path] == sha(closure / path), path

expected_cycles = {
    "h34_shift_dep": 685, "h33_st_fwd": 1011, "hyp8_branch_cancel": 492,
    "hyp8_csr_flush_skip": 2364, "hyp8_amo_store_order": 2199,
    "hyp8_amo_ready_order": 1231, "hyp8_f14_store_offset": 671,
}
assert set(smokes["tests"]) == set(expected_cycles)
for name, cycles in expected_cycles.items():
    entry, inp = smokes["tests"][name], results["inputs"][name]
    assert entry["state"] == "pass" and entry["rc"] == 0 and entry["cycles"] == cycles
    assert inp["rc"] == 0
    assert sha(build / "inputs" / f"{name}.elf") == inp["elfSha256"] == entry["elfSha256"]
    assert inp["srcSha256"] == manifest["files"][inp["source"]]
    assert inp["tohostPlusarg"] in entry["argv"]
    assert "+max-cycles=400000" in entry["argv"]
    text = (smoke / entry["log"]).read_text()
    assert "*** SUCCESS ***" in text and "*** FAILED ***" not in text

runner = ROOT / "verif/regress/remote/run_hyp8_integration.py"
spec = importlib.util.spec_from_file_location("review_gate", runner)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
lint = {}
for name, entry in results["lint"].items():
    text = (build / entry["log"]).read_text()
    assert len(re.findall(r"%Error", text)) == entry["warnings"]["%Error"] == 0
    count = len(re.findall(r"%Warning-", text))
    assert count == sum(v for k, v in entry["warnings"].items() if k.startswith("%Warning-"))
    lint[name] = dict(entry, warningCount=count,
                      hardFailureOnReassessment=module.lint_failed(entry["rc"], entry["warnings"]))
assert not lint["scalar"]["hardFailureOnReassessment"]
assert not lint["smt2"]["hardFailureOnReassessment"]
assert lint["mc"]["hardFailureOnReassessment"]
assert module.lint_failed(1, {}) and module.lint_failed(0, {"%Error": 1})
for path in (runner, Path(__file__).resolve()):
    text = path.read_text()
    ast.parse(text)
    assert "SPDX-License-Identifier: MIT" in "\n".join(text.splitlines()[:10])

report = dict(
    originalRunnerStatus=results["status"],
    reviewedGate="unqualified: MC configuration assertion; lint diagnostics remain",
    scalarSmokesPassed=True, modelSha256=model_sha,
    inputManifestSha256=sha(closure / "manifest.json"),
    retainedSourceSha256={p: manifest["files"][p] for p in retained},
    lineEndingEquivalent=eol_equivalent,
    build=results["build"], lint=lint, tests=smokes["tests"],
    priorCycleReference="analysis/r90/remote-gate.md; counts only, not trace equivalence",
    currentRunnerSha256=sha(runner), graderControlsPassed=5,
    priorFocusedAuditSha256=sha(HERE / "audit.json"),
    rawReceiptSha256={build_tag: sha(build / "results.json"),
                     smoke_tag: sha(smoke / "smokes-results.json")},
    limitations="No clean aggregate, MC validity, complete SMT retirement, "
                "Linux/OpenSBI boot, synthesis/STA or eight-FO4 closure claim.",
)
with (HERE / "aggregate-review.json").open("w", encoding="utf-8") as output:
    json.dump(report, output, indent=2)
    output.write("\n")
print("R98_REVIEW_RECORDED: scalar smokes7/7, matching source/model/ELFs; aggregate unqualified")
