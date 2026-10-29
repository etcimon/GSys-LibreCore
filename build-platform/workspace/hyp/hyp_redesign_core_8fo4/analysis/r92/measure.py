# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""Matched delay-v49 AI execution boards; run with a source-phase label."""
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
    tag = f"r92-{phase}-d{stages}-r{ports}"
    pmap = HERE / f"params-d{stages}-r{ports}.json"
    params = json.loads((ANALYSIS / "r88-param-map.json").read_text())
    params.update(Dot4Stages=stages, NrRgprPorts=ports)
    pmap.write_text(json.dumps(params, indent=2) + "\n")
    report = TIMING / "boards" / f"{tag}.json"
    ir = report.with_suffix(".ir.json")
    command = [
        str(BIN), "analyze", "--files-from", str(FLIST),
        "--modules", "g6lc_ai_exec", "--target-mhz", "5000",
        "--fo4-ps", "20", "--budget-margin", "0.2",
        "--param-map", str(pmap), "--stages",
        "--json-out", str(report), "--ir-out", str(ir),
    ]
    source_hash = digest(RTL)
    with report.with_suffix(".log").open("w", encoding="utf-8") as log:
        log.write(json.dumps(command) + "\n")
        log.flush()
        run = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    manifest = {
        "phase": phase, "Dot4Stages": stages, "NrRgprPorts": ports,
        "argv": command, "returncode": run.returncode,
        "source_commit": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
        ).strip(),
        "sha256": {
            str(RTL.relative_to(ROOT)): source_hash,
            str(BIN.relative_to(ROOT)): digest(BIN),
            str(FLIST.relative_to(ROOT)): digest(FLIST),
            str(pmap.relative_to(ROOT)): digest(pmap),
        },
    }
    assert digest(RTL) == source_hash, "RTL changed during measurement"
    report.with_suffix(".manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n"
    )
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
