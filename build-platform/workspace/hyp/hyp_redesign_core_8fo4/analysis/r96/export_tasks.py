# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Export the authored task cards against frozen reports; never recompute timing."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[5]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


def main():
    output = HERE / "tasks.json"
    if output.exists():
        raise RuntimeError("refusing to overwrite exported tasks")
    doc = HERE / "module-tasks.md"
    text = doc.read_text(encoding="utf-8")
    cones = read(HERE / "cones.json")
    prior = {t["module"]: t for t in read(HERE.parent / "r95/planned-workqueue.json")["tasks"]}
    captured = {t["module"]: t for t in cones["modules"]}
    reports = []
    verified = {}
    for path in sorted((HERE / "boards").glob("*.manifest.json")):
        manifest = read(path)
        assert manifest["returncode"] == 0
        for source, expected in manifest["sha256"].items():
            canonical = Path(source).resolve()
            if canonical not in verified:
                verified[canonical] = digest(canonical)
            if verified[canonical] != expected:
                raise RuntimeError(f"measurement input changed: {source}")
        board_path = path.with_name(path.name.replace(".manifest.json", ".json"))
        board = read(board_path)
        assert not board["skipped_files"]
        reports.append(dict(profile=manifest["group"],
                            manifest=path.relative_to(ROOT).as_posix(),
                            manifest_sha256=digest(path),
                            report_sha256=digest(board_path),
                            versions=board["versions"],
                            budget_fo4=board["budget_fo4"],
                            fo4_ps=board["fo4_ps"]))
    tasks = []
    for match in re.finditer(r"^## H96-(\w+)\n(.*?)(?=^## |\Z)", text, re.M | re.S):
        name, body = match.groups()
        cone = captured[name]
        state = re.search(r"^State: (.+)$", body, re.M).group(1)
        source = Path(cone["file"]).resolve()
        tasks.append(dict(id=f"H96-{name}", parent_task=prior[name]["id"],
                          module=name, source=source.relative_to(ROOT).as_posix(),
                          source_sha256=digest(source), state=state,
                          profile=cone["profile"],
                          raw_max_by_kind=cone["max_by_kind"],
                          evidence="analysis/r96/cones.json",
                          card_file=doc.relative_to(ROOT).as_posix(),
                          card_start_line=text.count("\n", 0, match.start()) + 1,
                          caller_candidates_at_r95=prior[name]["caller_candidates"],
                          caller_note="Lexical candidates, not elaboration. Current reviewed "
                                      "bindings and ownership limits are in the card."))
    assert {t["module"] for t in tasks} == set(captured)
    measurement_tasks = re.findall(r"^- \[ \] \*\*(M96-[A-Z-]+):", text, re.M)
    assert len(tasks) == 31 and len(measurement_tasks) == 6
    result = dict(schema="hyp8-r96-strategy-tasks.v1",
                  captured_utc=datetime.now(timezone.utc).isoformat(),
                  qualification="Structural screening and source-derived strategy tasks; "
                                "no implementation or physical timing acceptance.",
                  card_sha256=digest(doc), cones_sha256=digest(HERE / "cones.json"),
                  reports=reports, measurement_tasks=measurement_tasks,
                  module_tasks=tasks)
    with output.open("x", encoding="utf-8") as out:
        json.dump(result, out, indent=2)
        out.write("\n")
    print(f"Exported {len(tasks)} module tasks and {len(measurement_tasks)} measurement tasks; "
          f"{len(reports)} reports have matching inputs and zero skipped files.")


if __name__ == "__main__":
    main()
