# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Collect the independent seven-write debug-issued response/DRET matrix."""
import argparse
import json
from pathlib import Path
import shlex

from collect_cpu_execution import require, sha256
from g6lc_cpu_debug_queue_trace import PROBES
from g6lc_cpu_debug_return_trace import analyze

SCOPE = "configured-cpu-debug-return-interpreter"
TOP = "g6lc_storamic_cpu_debug_return_interpreter"
HOST = "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_return_interpreter.sv"
WRAPPER = "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_netlist.sv"


def normalize(token):
    token = token.replace("\\", "/")
    if len(token) > 6 and token.startswith("/mnt/") and token[6] == "/":
        token = token[5].upper() + ":" + token[6:]
    if len(token) > 1 and token[1] == ":":
        token = token[0].upper() + token[1:]
    return token


def script_commands(directory, data):
    return [
        ["read_rtlil", str(directory / "cpu.il")],
        ["read_slang", "--top", TOP, f"-GOriginEnabled={data['enabled']}",
         f"-GResponseDelay={data['delay']}", f"-GNegative={int(data['negative'])}",
         f"-GEntryPrivilege={data['entry_privilege']}", f"-GHoldStage={data['stage']}",
         "-GHoldCycles=384", str(directory / "source" / HOST)],
        ["hierarchy", "-check", "-top", TOP], ["select", TOP], ["proc"], ["opt"],
        ["memory_collect"], ["opt"], ["select", "*"], ["flatten"], ["async2sync", "t:$check"],
        ["scc", "-expect", "0"], ["cd", TOP],
        *[["rename", "-output", name, alias] for name, alias in PROBES.items()],
        ["cd", ".."], ["rename", "-hide", "w:*"], ["write_rtlil", str(directory / "instrumented.il")],
        ["sim", "-clock", "clk", "-resetn", "rst_n", "-rstlen", "8", "-n", str(data["cycles"]),
         "-zinit", "-assert", "-vcd", str(directory / "execution.vcd")],
    ]
def validate_script(directory, data):
    commands = [shlex.split(c) for c in (directory / "execution.ys").read_text().split(";") if c.strip()]
    expected = script_commands(directory, data)
    require([[normalize(t) for t in c] for c in commands] ==
            [[normalize(t) for t in c] for c in expected], "noncanonical or non-read-only queue script")
    require(data["read_only_probes"] == PROBES, "unexpected queue observation mapping")


def validate_sources(directory, sources):
    for name, digest in sources.items():
        path = (directory / "source" / name.removeprefix("generated:")).resolve()
        require(path.is_relative_to(directory / "source") and sha256(path) == digest,
                "queued source artifact mismatch")


def collect(repo, directories, model_receipts):
    workspace = (repo / "build-platform/workspace").resolve()
    origins, common, firmware, cases = {}, None, {}, {}
    for directory in model_receipts:
        directory = directory.resolve()
        require(directory.is_relative_to(workspace), "model receipt outside workspace")
        data = json.loads((directory / "result.json").read_text())
        require(data["scope"] == "configured-cpu-external-debug-interpreter" and
                data["model_status"] == "pass" and data["integer_diagnostic"] is False,
                "missing genuine configured model generation")
        require(sha256(directory / "cpu.il") == data["model_sha256"], "generation model artifact mismatch")
        validate_sources(directory, data["cpu_sources"])
        # These are the original, executed generation stages, not a newly fabricated script.
        require(sha256(directory / "model.ys") == data["scripts"]["model.ys"], "generation script mismatch")
        tokens = shlex.split((directory / "model.ys").read_text().split(";", 1)[0])
        require("g6lc_storamic_cpu_debug_netlist" in tokens and "-DSYNTHESIS" in tokens and
                f"-GOriginEnabled={data['enabled']}" in tokens, "wrong CPU generation profile")
        require(data["enabled"] not in origins, "duplicate CPU generation profile")
        origins[data["enabled"]] = (sha256(directory / "result.json"), data)
    require(set(origins) == {0, 1}, "missing configured CPU generation receipts")
    for directory in directories:
        directory = directory.resolve()
        require(directory.is_relative_to(workspace), "queue receipt outside workspace")
        path = directory / "result.json"
        data = json.loads(path.read_text())
        require(data["status"] == "pass" and data["scope"] == SCOPE and
                data["target"] == "cv64a6_imafdc_sv39" and data["integer_diagnostic"] is False and
                data["two_state_initialization"] is True and data["model_status"] == "pass",
                "not complete configured queued-debug execution")
        key = (data["entry_privilege"], data["stage"], data["enabled"], data["delay"], data["negative"])
        require(key not in cases, "duplicate queued-debug case")
        p, stage, enabled, delay, negative = key
        require(data["hold_cycles"] == 384 and stage == 3, "wrong return hold interval")
        origin_sha, origin = origins[enabled]
        require(data["model_origin"]["sha256"] == origin_sha and data["model_sha256"] == origin["model_sha256"] and
                data["cpu_sources"] == origin["cpu_sources"] and data["yosys_sha256"] == origin["yosys_sha256"],
                "queued CPU/tool/generation identity mismatch")
        require(WRAPPER in data["cpu_sources"] and
                data["cpu_sources"] == {k: v for k, v in data["sources"].items() if k != HOST},
                "incomplete queued CPU source identity")
        identity = {name: data[name] for name in ("target", "sources", "cpu_sources", "yosys_sha256")}
        require(common is None or common == identity, "inconsistent queued source/tool identity")
        common = identity
        validate_sources(directory, data["sources"])
        for file, field in (("cpu.il", "model_sha256"), ("runner.py", "runner_sha256"),
                            ("instrumented.il", "instrumented_sha256"),
                            ("firmware.json", "firmware_receipt_sha256"),
                            ("program.hex", "program_sha256"), ("debug.hex", "debug_sha256")):
            require(sha256(directory / file) == data[field], "queued artifact identity mismatch")
        roms = data["program_sha256"], data["debug_sha256"]
        generation = json.loads((directory / "firmware.json").read_text())
        require(generation["scope"] == "seven-write debug return firmware only" and
                generation["entry_privilege"] == p and generation["expected_writes"] == 7 and
                generation["expected_reads"] == 4 and generation["debug_writes"] == 4 and
                generation["debug_reads"] == 2 and generation["held_debug_offset"] == 28 and
                (generation["program_sha256"], generation["debug_sha256"]) == roms,
                "wrong seven-write firmware generation profile")
        require(firmware.get(p, roms) == roms, "inconsistent queued firmware profile")
        firmware[p] = roms
        require(data["scripts"] == {"execution.ys": sha256(directory / "execution.ys")},
                "queued execution script digest mismatch")
        validate_script(directory, data)
        log = directory / "execution.log"
        if negative:
            require(data["returncode"] != 0 and f"ERROR: Assertion {TOP}.debug_origin_observer" in log.read_text(),
                    "queued origin oracle did not reject at named observer")
            temporal = None
        else:
            ports = data["ports"]
            require(data["returncode"] == 0 and all(ports[k] == "1" for k in
                    ("done", "debug_seen", "hold_started", "hold_finished")) and
                    ports["failed"] == ports["debug_origin_failed"] == "0" and
                    all(int(ports[k], 2) == v for k, v in
                        {"write_checks": 7, "read_checks": 4, "debug_writes": 4,
                         "debug_reads": 2, "csr_checks": 2}.items()), "incomplete queued debug program")
            wave = directory / "execution.vcd"
            require(sha256(wave) == data["vcd_sha256"], "queued observation digest mismatch")
            temporal = analyze(wave, enabled, p)
            require(temporal["classification"] == "crossed", "debug response did not cross actual DRET")
            if enabled:
                try:
                    analyze(wave, enabled, p, wrong_live_origin=True)
                except ValueError as error:
                    require("live-return oracle rejects" in str(error), "unrelated trace oracle rejection")
                else:
                    raise ValueError("false live-origin trace oracle did not reject")
        cases[key] = {"profile": list(key), "receipt_sha256": sha256(path),
                      "log_sha256": sha256(log), "temporal": temporal}
    expected = {(p, 3, e, d, False) for p in (0, 1, 3) for e in (0, 1) for d in (0, 16)}
    expected |= {(p, 3, e, 16, True) for p in (0, 1, 3) for e in (0, 1)}
    require(set(cases) == expected, "missing complete queued-debug matrix")
    return {"status": "pass", "qualification": False,
            "scope": "M/S/U seven-write debug-issued B response across DRET only",
            "native_qualified": False, "strict_compile_qualified": False,
            "queued_mode_transitions_qualified": False, "fpu_isa_qualified": False,
            "identity": common, "firmware": firmware, "cases": [cases[k] for k in sorted(cases)],
            "collector_sha256": sha256(Path(__file__)),
            "trace_checker_sha256": sha256(Path(__file__).with_name("g6lc_cpu_debug_return_trace.py")),
            "vcd_parser_sha256": sha256(Path(__file__).with_name("g6lc_cpu_debug_queue_trace.py")),
            "model_receipts": {e: h for e, (h, _) in origins.items()}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", action="append", required=True, type=Path)
    parser.add_argument("--model-receipt", action="append", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    out = args.output_root.resolve()
    require(out.is_relative_to(repo / "build-platform/workspace"), "output outside workspace")
    out.mkdir(exist_ok=False)
    try:
        report = collect(repo, args.receipt, args.model_receipt)
    except (ValueError, KeyError, OSError, TypeError) as error:
        report = {"status": "fail", "qualification": False, "error": str(error)}
    (out / "result.json").write_text(json.dumps(report, indent=2))
    raise SystemExit(0 if report["status"] == "pass" else 1)


if __name__ == "__main__":
    main()
