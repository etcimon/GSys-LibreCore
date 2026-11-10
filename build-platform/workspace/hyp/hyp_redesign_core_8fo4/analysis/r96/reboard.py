# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Replay recorded structural bindings against current source, without changing calibration."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[5]
ANALYSIS = HERE.parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def replay(record):
    previous = ROOT / record["manifest"]
    old = json.loads(previous.read_text(encoding="utf-8"))
    group = old["group"]
    stem = HERE / "boards" / ("current-" + group)
    if stem.with_suffix(".json").exists():
        raise RuntimeError("refusing to overwrite evidence")
    hashes = {name: sha(Path(name)) for name in old["sha256"]}
    command = old["argv"].copy()
    for flag, suffix in (("--json-out", ".json"), ("--ir-out", ".ir.json")):
        command[command.index(flag) + 1] = str(stem.with_suffix(suffix))
    with stem.with_suffix(".log").open("x", encoding="utf-8") as log:
        log.write(json.dumps(command) + "\n")
        log.flush()
        result = subprocess.run(command, cwd=ROOT, stdout=log,
                                stderr=subprocess.STDOUT,
                                env=dict(os.environ, RUST_MIN_STACK="16777216"))
    if any(sha(Path(name)) != expected for name, expected in hashes.items()):
        raise RuntimeError("input changed during measurement")
    manifest = dict(group=group, phase="r96-current", argv=command,
                    returncode=result.returncode, sha256=hashes,
                    previous_manifest=record["manifest"],
                    previous_manifest_sha256=sha(previous),
                    changed_inputs=[n for n, h in hashes.items()
                                    if h != old["sha256"][n]])
    stem.with_suffix(".manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    if result.returncode:
        raise RuntimeError(f"{group}: analyzer failed")
    board = json.loads(stem.with_suffix(".json").read_text(encoding="utf-8"))
    if board["versions"] != record["versions"] or board["skipped_files"]:
        raise RuntimeError(f"{group}: instrument mismatch or skipped source")
    modules = {m["id"]: m["name"] for m in board["modules"]}
    peaks = {}
    for path in board["paths"]:
        name = modules[path["module_id"]]
        if name not in peaks or path["total_fo4"] > peaks[name]["total_fo4"]:
            peaks[name] = path
    peaks = dict(sorted(peaks.items(), key=lambda p: -p[1]["total_fo4"]))
    stem.with_suffix(".peaks.json").write_text(json.dumps(peaks, indent=2), encoding="utf-8")
    print(group, [(name, round(p["total_fo4"], 2))
                  for name, p in list(peaks.items())[:8]], flush=True)


if __name__ == "__main__":
    (HERE / "boards").mkdir(exist_ok=True)
    queue = json.loads((ANALYSIS / "r95/planned-workqueue.json").read_text(encoding="utf-8"))
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(replay, r) for r in queue["reports"]]
        for future in futures:
            future.result()
