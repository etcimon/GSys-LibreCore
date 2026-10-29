# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
"""Freeze compact evidence from existing boards and logs; never rerun analysis."""
from pathlib import Path
import hashlib
import json
import re

HERE = Path(__file__).resolve().parent
BOARDS = HERE / "boards"


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    result = {"scope": "Module-local structural screening; see worklog.md",
              "measurements": [], "verification": []}
    for group, name in [("core", "mult_clmul"), ("l2", "g6lc_l2_wtrk"),
                        ("l3", "g6lc_l2_wtrk"), ("ai", "g6lc_ai_pe_dot_float_pipe")]:
        row = {"group": group, "module": name}
        for phase in ("before", "final"):
            stem = BOARDS / f"{phase}-{group}"
            report = json.loads(stem.with_suffix(".json").read_text())
            manifest = json.loads(stem.with_suffix(".manifest.json").read_text())
            assert manifest["returncode"] == 0 and not report["skipped_files"]
            assert report["versions"]["measurement"] == "delay-v49"
            module = next(m for m in report["modules"] if m["name"] == name)
            paths = [p for p in report["paths"] if p["module_id"] == module["id"]]
            ids = {p["path_id"] for p in paths}
            if phase == "final":
                for source, digest in manifest["sha256"].items():
                    assert sha(Path(source)) == digest, f"Measured input changed: {source}"
            row[phase] = {
                "banner": report["banner"], "versions": report["versions"],
                "budget_fo4": report["budget_fo4"], "fo4_ps": report["fo4_ps"],
                "max_fo4": max(p["total_fo4"] for p in paths),
                "report_sha256": sha(stem.with_suffix(".json")),
                "ir_sha256": sha(stem.with_suffix(".ir.json")),
                "manifest_sha256": sha(stem.with_suffix(".manifest.json")),
                "module": module, "paths": paths,
                "relocation_cards": [c for c in report["relocation_plan"]["cards"]
                                     if c["path_id"] in ids],
            }
        result["measurements"].append(row)
    for tag in ["clmul-cand", "clmul-head", "wtrk-d1", "wtrk-d3", "wtrk-d4",
                "wtrk-d8", "wtrk-head", "float-l1", "float-l3", "float-l16",
                "float-l64", "cache"]:
        p = HERE / "logs" / f"sim-{tag}.log"
        text = p.read_text()
        assert not re.search(r"(^|\s)FAIL|%Error|SKIP", text), tag
        successes = [s for s in text.splitlines()
                     if s.startswith("PASS ") or s == "[L2TB] RESULT pass"]
        assert successes, tag
        result["verification"].append({"tag": tag, "sha256": sha(p), "result": successes})
    negative = HERE / "logs/clmul-negative.log"
    assert "FAIL polynomial" in negative.read_text()
    result["negative_oracle_sha256"] = sha(negative)
    lint = HERE / "logs/float-l512-lint.status"
    assert lint.read_text().strip() == "PASS floatpipe Lanes=512 elaboration/lint"
    result["lint_512"] = {
        "status": lint.read_text().strip(),
        "build_log_sha256": sha(HERE / "logs/build-float-l512-lint.log"),
    }
    result["aggregate_exit"] = int((HERE / "logs/verify-full.status").read_text())
    (HERE / "evidence.json").write_text(json.dumps(result, indent=2) + "\n")
    (HERE / "logs/summary.txt").write_text(
        "\n".join(s for v in result["verification"] for s in v["result"]) +
        "\nPASS clmul negative control\n" + result["lint_512"]["status"] +
        "\nR94-LEAF-ALL-PASS\n"
        f"Aggregate verification exit: {result['aggregate_exit']}\n")
    print("Frozen four matched bindings and twelve positive runs; negative control detected.")


if __name__ == "__main__":
    main()
