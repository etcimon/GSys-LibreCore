# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Collect a frozen single-privilege external-debug matrix, not native qualification."""
import argparse
import json
from pathlib import Path
import shlex

from collect_cpu_execution import require, sha256


SCOPE = "configured-cpu-external-debug-interpreter"
HOST = "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_interpreter.sv"
WRAPPER = "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_netlist.sv"
PACKAGE = "core/fetch_B/g6lc_fetch_pkg.sv"
PROOF_TOP = "verif/tb/storamic/tb_g6lc_debug_redirect_priority.sv"


def collect(repo, directories, priority_proof, *, model_receipts=(), entry_privilege=3):
    require(entry_privilege in (0, 1, 3), "unsupported debug entry privilege")
    workspace = (repo / "build-platform/workspace").resolve()
    common, cases, models, origins, inputs = None, {}, {}, {}, []
    for directory in directories:
        directory = directory.resolve()
        require(directory.is_relative_to(workspace), "execution receipt outside workspace")
        path = directory / "result.json"
        data = json.loads(path.read_text())
        require(sha256(directory / "runner.py") == data["runner_sha256"], "execution runner identity mismatch")
        require(data["status"] == "pass" and data["scope"] == SCOPE and
                data["integer_diagnostic"] is False and data["two_state_initialization"] is True,
                "not configured full-CPU debug execution evidence")
        require(data.get("entry_privilege", 3) == entry_privilege, "debug entry privilege mismatch")
        identity = {key: data[key] for key in
                    ("target", "sources", "cpu_sources", "yosys_sha256", "program_sha256", "debug_sha256")}
        require(common is None or common == identity, "inconsistent source/tool/firmware identities")
        common = identity
        require(data["target"] == "cv64a6_imafdc_sv39" and WRAPPER in data["cpu_sources"] and
                data["cpu_sources"] == {k: v for k, v in data["sources"].items() if k != HOST},
                "incomplete CPU source identity")
        source = (directory / "source").resolve()
        require(source.is_relative_to(workspace), "source closure outside workspace")
        for name, digest in data["sources"].items():
            file = (source / name.removeprefix("generated:")).resolve()
            require(file.is_relative_to(source) and sha256(file) == digest, "source artifact mismatch")
        for name, key in (("program.hex", "program_sha256"), ("debug.hex", "debug_sha256")):
            require(sha256(directory / name) == data[key], "firmware artifact mismatch")
        for name, digest in data["scripts"].items():
            file = (directory / name).resolve()
            require(file.is_relative_to(directory) and sha256(file) == digest, "script artifact mismatch")
        enabled, delay, negative = data["enabled"], data["delay"], data["negative"]
        key = enabled, delay, negative
        require(key not in cases, "duplicate debug case")
        model = data["model_sha256"]
        require(data["model_status"] == "pass" and sha256(directory / "cpu.il") == model and
                models.get(enabled, model) == model, "CPU model artifact/profile mismatch")
        models[enabled] = model
        build = directory / "model.ys"
        if build.exists():
            require("model.ys" in data["scripts"], "unrecorded model generation script")
            tokens = shlex.split(build.read_text().split(";", 1)[0])
            require("g6lc_storamic_cpu_debug_netlist" in tokens and
                    f"-GOriginEnabled={enabled}" in tokens and "-DSYNTHESIS" in tokens,
                    "wrong CPU model generation profile")
            origins[enabled] = model
        execution = directory / "execution.ys"
        require("execution.ys" in data["scripts"], "missing execution script identity")
        tokens = shlex.split(execution.read_text().replace(";", " ; "))
        require("-assert" in tokens and "-zinit" in tokens and
                f"-GOriginEnabled={enabled}" in tokens and f"-GResponseDelay={delay}" in tokens and
                f"-GNegative={int(negative)}" in tokens, "missing debug host/assertion mode")
        privilege_flags = [token for token in tokens if token.startswith("-GEntryPrivilege=")]
        require(privilege_flags == [f"-GEntryPrivilege={entry_privilege}"] or
                (entry_privilege == 3 and not privilege_flags), "wrong debug host entry privilege")
        log = directory / "execution.log"
        if negative:
            require(data["returncode"] != 0 and
                    "ERROR: Assertion g6lc_storamic_cpu_debug_interpreter.debug_origin_observer" in log.read_text(),
                    "wrong debug-origin oracle did not reject")
        else:
            ports = data["ports"]
            require(data["returncode"] == 0 and ports["done"] == "1" and ports["failed"] == "0" and
                    ports["debug_origin_failed"] == "0" and ports["debug_seen"] == "1" and
                    all(int(ports[name], 2) == count for name, count in
                        {"write_checks": 6, "read_checks": 4, "debug_writes": 3,
                         "debug_reads": 2, "csr_checks": 2}.items()),
                    "incomplete debug round trip or probe checks")
        cases[key] = {"enabled": enabled, "delay": delay, "negative": negative,
                      "receipt_sha256": sha256(path), "log_sha256": sha256(log)}
        inputs.append({"receipt": path.relative_to(repo).as_posix(), "sha256": sha256(path)})
    expected = {(e, d, False) for e in (0, 1) for d in (0, 16)} | {(e, 16, True) for e in (0, 1)}
    require(set(cases) == expected, "missing debug execution cases")
    for directory in model_receipts:
        directory = directory.resolve()
        require(directory.is_relative_to(workspace), "model generation receipt outside workspace")
        path = directory / "result.json"
        data = json.loads(path.read_text())
        require(data["scope"] == SCOPE and data["model_status"] == "pass" and
                data["integer_diagnostic"] is False and data["target"] == common["target"] and
                data["cpu_sources"] == common["cpu_sources"] and
                data["yosys_sha256"] == common["yosys_sha256"], "CPU model generation identity mismatch")
        source = (directory / "source").resolve()
        require(source.is_relative_to(workspace), "model source closure outside workspace")
        for name, digest in data["cpu_sources"].items():
            file = (source / name.removeprefix("generated:")).resolve()
            require(file.is_relative_to(source) and sha256(file) == digest, "model source artifact mismatch")
        enabled, model = data["enabled"], data["model_sha256"]
        require(models.get(enabled) == model and sha256(directory / "cpu.il") == model,
                "model origin artifact mismatch")
        script = directory / "model.ys"
        require(sha256(script) == data["scripts"]["model.ys"], "model origin script mismatch")
        tokens = shlex.split(script.read_text().split(";", 1)[0])
        require("g6lc_storamic_cpu_debug_netlist" in tokens and
                f"-GOriginEnabled={enabled}" in tokens and "-DSYNTHESIS" in tokens,
                "wrong configured model origin profile")
        origins[enabled] = model
        inputs.append({"model_receipt": path.relative_to(repo).as_posix(), "sha256": sha256(path)})
    require(models == origins, "missing configured debug model generation receipts")
    priority_proof = priority_proof.resolve()
    require(priority_proof.is_relative_to(workspace), "priority proof outside workspace")
    path = priority_proof / "result.json"
    proof = json.loads(path.read_text())
    require(proof["status"] == "pass" and proof["yosys_sha256"] == common["yosys_sha256"] and
            proof["scope"] == "unrestricted two-state combinatorial redirect priority only" and
            len(proof["cases"]) == 2, "missing unrestricted priority proof")
    for case in proof["cases"]:
        candidate = case["candidate"]
        directory = priority_proof / ("candidate" if candidate else "baseline")
        require(case["matched"] is True and
                sha256(directory / "source" / PACKAGE) == case["pkg_sha256"] and
                sha256(directory / "source" / PROOF_TOP) == case["top_sha256"] and
                sha256(directory / "proof.ys") == case["script_sha256"] and
                sha256(directory / "proof.log") == case["log_sha256"], "priority proof artifact mismatch")
        if candidate:
            require(case["returncode"] == 0 and
                    case["pkg_sha256"] == common["cpu_sources"][PACKAGE], "priority proof source mismatch")
        else:
            require(case["returncode"] != 0, "old priority did not reject")
    require({case["candidate"] for case in proof["cases"]} == {False, True}, "incomplete priority proof")
    name = {0: "U", 1: "S", 3: "M"}[entry_privilege]
    return {"status": "pass", "qualification": False, "scope": f"{name}-mode external debug round trip only",
            "executed_debug_entry_privileges": [entry_privilege],
            "two_state_initialization": True, "native_qualified": False,
            "strict_rtl_compile_qualified": False, "queued_mode_transitions_qualified": False,
            "debug_other_privileges_qualified": False, "fpu_isa_qualified": False,
            "identity": common, "cases": [cases[key] for key in sorted(cases)],
            "inputs": inputs, "priority_proof_sha256": sha256(path),
            "collector_sha256": sha256(Path(__file__))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", required=True, action="append", type=Path)
    parser.add_argument("--priority-proof", required=True, type=Path)
    parser.add_argument("--model-receipt", action="append", type=Path, default=[])
    parser.add_argument("--entry-privilege", type=int, choices=(0, 1, 3), default=3)
    parser.add_argument("--output-root", required=True, type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    out = args.output_root.resolve()
    require(out.is_relative_to(repo / "build-platform/workspace"), "output outside workspace")
    out.mkdir(exist_ok=False)
    try:
        report = collect(repo, args.receipt, args.priority_proof, model_receipts=args.model_receipt,
                         entry_privilege=args.entry_privilege)
    except (ValueError, KeyError, TypeError, OSError) as error:
        report = {"status": "fail", "qualification": False, "error": str(error)}
    (out / "result.json").write_text(json.dumps(report, indent=2))
    raise SystemExit(0 if report["status"] == "pass" else 1)


if __name__ == "__main__":
    main()
