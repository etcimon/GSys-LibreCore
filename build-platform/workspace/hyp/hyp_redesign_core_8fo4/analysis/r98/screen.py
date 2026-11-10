# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Matched source-pinned screens; bindings are explicitly authored in each spec."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[5]


def read(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write(path, value):
    with Path(path).open("x", encoding="utf-8") as out:
        json.dump(value, out, indent=2)
        out.write("\n")


def run(name, phase):
    assert phase in ("before", "after")
    spec = read(HERE / f"{name}.spec.json")
    template = HERE.parent / spec.get("template", "r96/boards/current-core-all.manifest.json")
    target = ROOT / spec["source"]
    baseline = HERE / spec.get("baseline", f"{name}.before.sv")
    original = read(template)
    command = original["argv"].copy()
    oldlist = Path(command[command.index("--files-from") + 1])
    oldmap = Path(command[command.index("--param-map") + 1])
    pmap = HERE / f"{name}.params.json"
    if phase == "before":
        if "baseline" in spec:
            assert sha(baseline) == spec["baseline_sha256"]
        else:
            with baseline.open("xb") as out:
                out.write((ROOT / spec["baseline_source"] if "baseline_source" in spec else target).read_bytes())
        params = read(oldmap)
        params.update(spec["overrides"])
        write(pmap, params)
    source = baseline if phase == "before" else target
    stem = HERE / "boards" / f"{name}-{phase}"
    flist = HERE / f"{name}-{phase}.f"
    lines = []
    replaced = 0
    for line in oldlist.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#") or line.startswith("+define+"):
            lines.append(line)
        elif line.startswith("+incdir+"):
            lines.append("+incdir+" + (oldlist.parent / line[8:]).resolve().as_posix())
        elif line.startswith("+"):
            raise ValueError(line)
        else:
            path = (oldlist.parent / line).resolve()
            if path == target.resolve():
                path = source
                replaced += 1
            lines.append(path.as_posix())
    assert replaced == 1
    with flist.open("x", encoding="utf-8") as out:
        out.write("\n".join(lines) + "\n")
    command[command.index("--files-from") + 1] = str(flist)
    command[command.index("--param-map") + 1] = str(pmap)
    command[command.index("--modules") + 1] = spec["module"]
    for flag, suffix in (("--json-out", ".json"), ("--ir-out", ".ir.json")):
        command[command.index(flag) + 1] = str(stem.with_suffix(suffix))
    excluded = {target.resolve(), oldlist.resolve(), oldmap.resolve()}
    common = {p: sha(p) for p in original["sha256"] if Path(p).resolve() not in excluded}
    common[pmap.as_posix()] = sha(pmap)
    common[(HERE / f"{name}.spec.json").as_posix()] = sha(HERE / f"{name}.spec.json")
    if phase == "after":
        assert common == read(HERE / f"boards/{name}-before.manifest.json")["common_sha256"]
    inputs = {**common, source.as_posix(): sha(source), flist.as_posix(): sha(flist)}
    with stem.with_suffix(".log").open("x", encoding="utf-8") as out:
        out.write(json.dumps(command) + "\n")
        out.flush()
        proc = subprocess.run(command, cwd=ROOT, stdout=out, stderr=subprocess.STDOUT,
                              env=dict(os.environ, RUST_MIN_STACK="16777216"))
    assert all(sha(p) == digest for p, digest in inputs.items())
    write(stem.with_suffix(".manifest.json"),
          dict(argv=command, sha256=inputs, common_sha256=common, source_sha256=sha(source),
               returncode=proc.returncode, script_sha256=sha(__file__)))
    assert proc.returncode == 0
    board = read(stem.with_suffix(".json"))
    expected_versions = read(str(template).replace(".manifest.json", ".json"))["versions"].copy()
    if "measurement_version" in spec:
        expected_versions["measurement"] = spec["measurement_version"]
    assert board["versions"] == expected_versions
    if phase == "after":
        assert board["versions"] == read(HERE / f"boards/{name}-before.summary.json")["versions"]
    assert not board["skipped_files"]
    module = next(m for m in board["modules"] if m["name"] == spec["module"])
    paths = [p for p in board["paths"] if p["module_id"] == module["id"]]
    best = {}
    for p in paths:
        if p["path_kind"] not in best or p["total_fo4"] > best[p["path_kind"]]["total_fo4"]:
            best[p["path_kind"]] = p
    result = dict(maximum=max(p["total_fo4"] for p in paths), max_by_kind=best,
                  versions=board["versions"], fo4_ps=board["fo4_ps"],
                  budget_fo4=board["budget_fo4"], report_sha256=sha(stem.with_suffix(".json")))
    write(stem.with_suffix(".summary.json"), result)
    print(name, phase, {k: p["total_fo4"] for k, p in best.items()}, flush=True)


if __name__ == "__main__":
    run(sys.argv[1], sys.argv[2])
