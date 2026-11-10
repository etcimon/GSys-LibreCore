# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Matched FLU screens; ports8 is a leaf scaling binding, not full-system qualification."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[5]
FLU = HERE.parent.parent / "core/ooo/g6lc_flu_reserve.sv"
TEMPLATE = HERE.parent / "r96/boards/current-core-all.manifest.json"


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def write(path, data):
    with Path(path).open("x", encoding="utf-8") as out:
        json.dump(data, out, indent=2)
        out.write("\n")


def run(phase, name, ports):
    original = read(TEMPLATE)
    command = original["argv"].copy()
    oldmap = Path(command[command.index("--param-map") + 1])
    pmap = HERE / f"params-{name}.json"
    if phase == "before":
        params = read(oldmap)
        params["G6LCCfg.NrIssuePorts"] = ports
        write(pmap, params)
    command[command.index("--param-map") + 1] = str(pmap)
    command[command.index("--modules") + 1] = "g6lc_flu_reserve"
    stem = HERE / "boards" / f"{phase}-{name}"
    if stem.with_suffix(".json").exists():
        raise RuntimeError("refusing evidence overwrite")
    for flag, suffix in (("--json-out", ".json"), ("--ir-out", ".ir.json")):
        command[command.index(flag) + 1] = str(stem.with_suffix(suffix))
    inputs = [Path(p) for p in original["sha256"]
              if Path(p).resolve() != oldmap.resolve()] + [pmap]
    hashes = {p.as_posix(): sha(p) for p in inputs}
    if phase == "after":
        before = read(HERE / f"boards/before-{name}.manifest.json")
        changed = [p for p, h in hashes.items() if h != before["sha256"][p]]
        assert {Path(p).resolve() for p in changed} == {FLU.resolve()}, changed
    else:
        changed = []
    with stem.with_suffix(".log").open("x", encoding="utf-8") as log:
        log.write(json.dumps(command) + "\n")
        log.flush()
        proc = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                              env=dict(os.environ, RUST_MIN_STACK="16777216"))
    assert all(sha(p) == h for p, h in hashes.items()), "inputs changed during run"
    manifest = dict(phase=phase, binding=name, argv=command, sha256=hashes,
                    changed_inputs=changed, returncode=proc.returncode,
                    source_sha256=sha(FLU), template_sha256=sha(TEMPLATE))
    write(stem.with_suffix(".manifest.json"), manifest)
    assert proc.returncode == 0
    board = read(stem.with_suffix(".json"))
    template_board = read(TEMPLATE.with_name("current-core-all.json"))
    assert board["versions"] == template_board["versions"] and not board["skipped_files"]
    module = next(m for m in board["modules"] if m["name"] == "g6lc_flu_reserve")
    paths = [p for p in board["paths"] if p["module_id"] == module["id"]]
    by_kind = {}
    for path in paths:
        kind = path["path_kind"]
        if kind not in by_kind or path["total_fo4"] > by_kind[kind]["total_fo4"]:
            by_kind[kind] = path
    result = dict(versions=board["versions"], budget_fo4=board["budget_fo4"],
                  fo4_ps=board["fo4_ps"], max_by_kind=by_kind,
                  maximum=max(p["total_fo4"] for p in paths),
                  report_sha256=sha(stem.with_suffix(".json")),
                  ir_sha256=sha(stem.with_suffix(".ir.json")))
    write(stem.with_suffix(".summary.json"), result)
    print(phase, name, result["maximum"],
          {k: p["total_fo4"] for k, p in by_kind.items()}, flush=True)


if __name__ == "__main__":
    phase = sys.argv[1]
    assert phase in ("before", "after")
    (HERE / "boards").mkdir(exist_ok=True)
    if phase == "before":
        with (HERE / "g6lc_flu_reserve.before.sv").open("xb") as out:
            out.write(FLU.read_bytes())
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(run, phase, name, ports)
                   for name, ports in (("scalar", 2), ("ports8", 8))]
        for future in futures:
            future.result()
