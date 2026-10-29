# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""Measure r93 candidates against the frozen r92 instrument and bindings."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import subprocess


HERE = Path(__file__).resolve().parent
ANALYSIS = HERE.parent
ROOT = HERE.parents[5]
TIMING = ANALYSIS / "timing"
BIN = ROOT / "sv-timing/target/release/sv-timing.exe"
FLIST = TIMING / "hyp8-core.f"
RTL = ANALYSIS.parent / "core/cvxif_g6lc_ai/g6lc_ai_exec.sv"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def measure(phase, stages, ports):
    tag = f"r93-{phase}-d{stages}-r{ports}"
    report = TIMING / "boards" / f"{tag}.json"
    if report.exists() or report.with_suffix(".log").exists():
        raise RuntimeError(f"{tag} already exists; use a new phase label")
    pmap = HERE / f"params-d{stages}-r{ports}.json"
    params = json.loads((ANALYSIS / "r88-param-map.json").read_text())
    params.update(Dot4Stages=stages, NrRgprPorts=ports)
    pmap.write_text(json.dumps(params, indent=2) + "\n")
    baseline = json.loads(
        (TIMING / "boards" / f"r92-final-d{stages}-r{ports}.manifest.json").read_text()
    )
    for path in (BIN, FLIST):
        assert digest(path) == baseline["sha256"][str(path.relative_to(ROOT))]
    old_map = ANALYSIS / "r92" / pmap.name
    assert digest(pmap) == baseline["sha256"][str(old_map.relative_to(ROOT))]
    command = [
        str(BIN), "analyze", "--files-from", str(FLIST),
        "--modules", "g6lc_ai_exec", "--target-mhz", "5000",
        "--fo4-ps", "20", "--budget-margin", "0.2",
        "--param-map", str(pmap), "--stages",
        "--json-out", str(report), "--ir-out", str(report.with_suffix(".ir.json")),
    ]
    hashes = {str(p.relative_to(ROOT)): digest(p) for p in (RTL, BIN, FLIST, pmap)}
    with report.with_suffix(".log").open("w", encoding="utf-8") as log:
        log.write(json.dumps(command) + "\n")
        log.flush()
        run = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    assert all(digest(ROOT / path) == value for path, value in hashes.items())
    manifest = {
        "phase": phase, "Dot4Stages": stages, "NrRgprPorts": ports,
        "argv": command, "returncode": run.returncode,
        "baseline": f"r92-final-d{stages}-r{ports}",
        "source_commit": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
        ).strip(),
        "sha256": hashes,
    }
    report.with_suffix(".manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    if run.returncode:
        raise RuntimeError(f"{tag}: analyzer exit {run.returncode}; see log")
    return tag


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase")
    args = parser.parse_args()
    if not args.phase.replace("-", "").isalnum():
        parser.error("phase must contain only letters, digits and hyphens")
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        jobs = [
            pool.submit(measure, args.phase, stages, ports)
            for stages in (1, 2) for ports in (2, 3)
        ]
        for job in jobs:
            print(job.result(), flush=True)
