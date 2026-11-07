# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Collect full-configured CPU interpreter cases, never native qualification."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def collect(repo, directories, *, extra_mprv=False, model_receipts=()):
    workspace = (repo / "build-platform/workspace").resolve()
    common, cases, inputs, models, model_origins = None, {}, [], {}, {}
    scope = "extended-mprv-cpu-rtlil-interpreter" if extra_mprv else "full-configured-cpu-rtlil-interpreter"
    expected_writes, expected_reads = (7, 6) if extra_mprv else (5, 4)
    require(extra_mprv or not model_receipts, "external model receipts require extended MPRV mode")
    for directory in directories:
        directory = directory.resolve()
        require(directory.is_relative_to(workspace), "receipt outside workspace")
        path = directory / "result.json"
        data = json.loads(path.read_text())
        require(data["status"] == "pass", "unfinished or failed receipt")
        require(data["scope"] == scope and data.get("extra_mprv", False) == extra_mprv and
                data["integer_diagnostic"] is False and data["startup_cycles"] is None,
                "diagnostic profile is not configured CPU program evidence")
        if extra_mprv:
            require(data["expected_writes"] == expected_writes and
                    data["expected_reads"] == expected_reads and
                    set(data["program_coverage"]) ==
                    {"M", "S", "U", "MPRV/MPP=S", "MPRV/MPP=U", "MPRV/MPP=M"},
                    "extended firmware coverage/count mismatch")
        require(data["two_state_initialization"] is True, "unexpected interpreter initialization")
        require(sha256(directory / "program.hex") == data["program_sha256"], "program artifact mismatch")
        identity = {k: data[k] for k in
                    ("target", "sources", "program_sha256", "yosys_sha256", "two_state_initialization")}
        require(common is None or common == identity, "source/tool/program identity mismatch")
        common = identity
        source = (directory / "source").resolve()
        require(source.is_relative_to(workspace), "source closure outside workspace")
        for name, digest in data["sources"].items():
            file = (source / name.removeprefix("generated:")).resolve()
            require(file.is_relative_to(source) and sha256(file) == digest, "source artifact mismatch")
        profiles = {p["enabled"]: p["rtlil_sha256"] for p in data["profiles"]}
        for enabled, digest in profiles.items():
            require(sha256(directory / f"enabled{enabled}/cpu.il") == digest, "RTLIL artifact mismatch")
            require(enabled not in models or models[enabled] == digest, "CPU model changed between cases")
            models[enabled] = digest
            build = directory / f"enabled{enabled}/model.ys"
            if build.is_file():
                require(sha256(build) == data["scripts"][build.relative_to(directory).as_posix()],
                        "model build script mismatch")
                text = build.read_text()
                require("-GIntegerDiagnostic=0" in text and f"-GOriginEnabled={enabled}" in text,
                        "model was not built for the full configured profile")
                model_origins[enabled] = digest
        for result in data["results"]:
            label = result["case"]
            match = re.fullmatch(r"enabled([01])-delay(0|16)-negative([01])", label)
            require(match is not None and label not in cases, "unknown or duplicate case")
            enabled, delay, negative = map(int, match.groups())
            require(enabled in profiles and (delay == 16 or negative == 0), "case/profile mismatch")
            require(result["matched"] and result["startup_only"] is False, "unmatched or startup case")
            script = directory / (label + ".ys")
            require(sha256(script) == data["scripts"][script.name], "simulation script mismatch")
            require("-assert" in script.read_text(), "assertions not enabled")
            if extra_mprv:
                require("-GExtraMprv=1" in script.read_text(), "extended host checks not enabled")
            log = directory / (label + ".log")
            if negative:
                text = log.read_text()
                require(result["returncode"] != 0 and
                        "ERROR: Assertion g6lc_storamic_cpu_interpreter.cpu_origin_observer" in text,
                        "origin oracle did not reject at the observer")
            else:
                ports = result["ports"]
                require(result["returncode"] == 0 and ports["done"] == "1" and ports["failed"] == "0" and
                        int(ports["write_checks"], 2) == expected_writes and
                        int(ports["read_checks"], 2) == expected_reads,
                        "CPU software completion/probe checks missing")
            cases[label] = {"receipt": path.relative_to(repo).as_posix(),
                            "log_sha256": sha256(log), "script_sha256": sha256(script)}
        inputs.append({"receipt": path.relative_to(repo).as_posix(), "sha256": sha256(path)})
    expected = {f"enabled{e}-delay{d}-negative{n}"
                for e in (0, 1) for d, n in ((0, 0), (16, 0), (16, 1))}
    require(set(cases) == expected, "missing configured CPU execution cases")
    host = "verif/tb/storamic/tb_g6lc_storamic_cpu_interpreter.sv"
    cpu_sources = {k: v for k, v in common["sources"].items() if k != host}
    for directory in model_receipts:
        directory = directory.resolve()
        require(directory.is_relative_to(workspace), "model receipt outside workspace")
        path = directory / "result.json"
        data = json.loads(path.read_text())
        require(data["status"] == "pass" and data["integer_diagnostic"] is False and
                data["scope"] == "full-configured-cpu-rtlil-interpreter" and
                data["startup_cycles"] is None, "unqualified CPU model generation profile")
        require(data["target"] == common["target"] and data["yosys_sha256"] == common["yosys_sha256"] and
                {k: v for k, v in data["sources"].items() if k != host} == cpu_sources,
                "CPU model generation source/tool identity mismatch")
        source = (directory / "source").resolve()
        require(source.is_relative_to(workspace), "model source closure outside workspace")
        for name, digest in data["sources"].items():
            file = (source / name.removeprefix("generated:")).resolve()
            require(file.is_relative_to(source) and sha256(file) == digest, "model source artifact mismatch")
        for profile in data["profiles"]:
            enabled, digest = profile["enabled"], profile["rtlil_sha256"]
            require(models.get(enabled) == digest and
                    sha256(directory / f"enabled{enabled}/cpu.il") == digest, "model origin artifact mismatch")
            build = directory / f"enabled{enabled}/model.ys"
            require(sha256(build) == data["scripts"][build.relative_to(directory).as_posix()],
                    "model origin script mismatch")
            text = build.read_text()
            require("-GIntegerDiagnostic=0" in text and f"-GOriginEnabled={enabled}" in text,
                    "model origin was not the full configured profile")
            model_origins[enabled] = digest
        inputs.append({"model_receipt": path.relative_to(repo).as_posix(), "sha256": sha256(path)})
    require(model_origins == models, "missing configured model generation receipts")
    return {"status": "pass", "qualification": False,
            "scope": ("configured CPU extended MPRV provenance via two-state interpreter only" if extra_mprv
                      else "configured CPU instruction provenance via two-state interpreter only"),
            "extra_mprv": extra_mprv, "expected_writes": expected_writes, "expected_reads": expected_reads,
            "strict_rtl_compile_qualified": False, "debug_execution_qualified": False,
            "native_qualified": False, "identity": common, "models": models,
            "cases": cases, "inputs": inputs}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", type=Path, action="append", required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--extra-mprv", action="store_true")
    parser.add_argument("--model-receipt", type=Path, action="append", default=[])
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    output = args.output_root.resolve()
    require(output.is_relative_to(repo / "build-platform/workspace"), "output outside workspace")
    output.mkdir(exist_ok=False)
    report = {"status": "incomplete", "qualification": False}
    try:
        report = collect(repo, args.receipt, extra_mprv=args.extra_mprv, model_receipts=args.model_receipt)
        report["collector_sha256"] = sha256(Path(__file__).resolve())
    except (ValueError, KeyError, OSError) as error:
        report["error"] = str(error)
        raise
    finally:
        (output / "result.json").write_text(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
