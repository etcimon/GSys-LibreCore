#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

SOURCES = (
    "core/include/config_pkg.sv",
    "core/cvfpu/src/fpnew_pkg.sv",
    "vendor/pulp-platform/common_cells/src/cf_math_pkg.sv",
    "corev_apu/instr_tracing/rv_tracer-main/rtl/lzc.sv",
    "core/cvfpu/src/fpnew_classifier.sv",
    "core/cvfpu/src/fpnew_rounding.sv",
    "core/cvfpu/src/fpnew_fma.sv",
    "corev_apu/ai_island/include/g6lc_ai_fp_pkg.sv",
    "corev_apu/ai_island/g6lc_ai_fp_mac.sv",
    "verif/tb/ai_island/tb_g6lc_ai_fp_mac.sv",
    "verif/tb/ai_island/fp_mac_main.cpp",
    "vendor/pulp-platform/common_cells/include/common_cells/registers.svh",
    "verilator_config.vlt",
    "Makefile",
)
VENDOR_SOURCES = frozenset((
    "core/cvfpu/src/fpnew_pkg.sv",
    "vendor/pulp-platform/common_cells/src/cf_math_pkg.sv",
    "corev_apu/instr_tracing/rv_tracer-main/rtl/lzc.sv",
    "core/cvfpu/src/fpnew_classifier.sv",
    "core/cvfpu/src/fpnew_rounding.sv",
    "core/cvfpu/src/fpnew_fma.sv",
    "vendor/pulp-platform/common_cells/include/common_cells/registers.svh",
))
BASELINE_FLAGS = ("-Wno-UNOPTFLAT", "-Wno-BLKANDNBLK")
TOP = "tb_g6lc_ai_fp_mac"
FATAL_WARNINGS = ("WIDTH", "ENUMVALUE", "IMPLICIT", "PINMISSING", "PINNOTFOUND",
                  "SELRANGE", "LATCH", "UNOPTFLAT", "MULTIDRIVEN")


def arguments():
    parser = argparse.ArgumentParser(description="Isolated exact scalar FP MUL then ADD; remote Verilator only")
    parser.add_argument("--seed", default=os.environ.get("AI_FP_MAC_SEED", "0x676c636670"))
    parser.add_argument("--pipelines", default=os.environ.get("AI_FP_MAC_PIPELINES", "1,2,3,5"))
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--synth-only", action="store_true")
    parser.add_argument("--yosys", help="existing local executable; requires --synth-only")
    parser.add_argument("--formal", choices=("widen", "all"), default="widen")
    args = parser.parse_args()
    if args.yosys and not args.synth_only:
        parser.error("--yosys requires --synth-only")
    if args.synth_only and args.dry_run:
        parser.error("--synth-only cannot be combined with --dry-run")
    args.seed = str(int(args.seed, 0))
    if not 0 <= int(args.seed) < 2**64:
        parser.error("seed must be unsigned 64-bit")
    args.pipelines = [int(item) for item in args.pipelines.split(",")]
    if not args.pipelines or any(item < 1 for item in args.pipelines):
        parser.error("pipeline registers must be >= 1")
    return args


def tag():
    return "ai-fp-mac-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:12]


def dispatch(args):
    root = Path(__file__).resolve().parents[2]
    proxy = root / "verif/regress/remote/testharness_proxy.py"
    files = [root / source for source in SOURCES]
    for path in [proxy, *files]:
        if not path.is_file():
            raise RuntimeError("required source missing: " + str(path))
    def proxy_path(path):
        if os.name != "nt":
            return str(path)
        if not path.drive or len(path.drive) != 2:
            raise RuntimeError("WSL dispatch requires drive-qualified paths")
        return "/mnt/" + path.drive[0].lower() + path.as_posix()[2:]
    name = tag()
    launcher = ["wsl.exe", "--exec", "python3"] if os.name == "nt" else [sys.executable]
    command = [*launcher, proxy_path(proxy), "py", proxy_path(Path(__file__).resolve()),
               "--tag", name, "--threads", "1", "--pull",
               "--env", "AI_FP_MAC_SEED=" + args.seed,
               "--env", "AI_FP_MAC_PIPELINES=" + ",".join(map(str, args.pipelines))]
    for path in files:
        command.extend(("--data", proxy_path(path)))
    print("PROXY_ONLY " + shlex.join(command), flush=True)
    print("PULL_OUTPUT " + str(root / "remote-runs" / name / "output"), flush=True)
    return 0 if args.dry_run else subprocess.run(command, cwd=root, check=False).returncode


def run(command, log, cwd, env=None, timeout=900, expect_failure=False):
    command = list(map(str, command))
    print("RUN " + shlex.join(command), flush=True)
    with log.open("w", encoding="utf-8") as output:
        output.write("COMMAND " + shlex.join(command) + "\n")
        output.flush()
        result = subprocess.run(command, cwd=cwd, env=env, stdout=output,
                                stderr=subprocess.STDOUT, check=False, timeout=timeout)
        output.write("\nRETURN_CODE " + str(result.returncode) + "\n")
    text = log.read_text(encoding="utf-8", errors="replace")
    if expect_failure is not None and bool(result.returncode) != expect_failure:
        print(text[-20000:], flush=True)
        raise RuntimeError("unexpected command rc=" + str(result.returncode) + "; log=" + str(log))
    return text


def staged_source(source):
    path = Path(source)
    if source.startswith(("core/cvfpu/", "vendor/", "corev_apu/instr_tracing/")):
        return path
    return Path(path.name)


def stage(files, out):
    snapshots = out / "sources"
    snapshots.mkdir()
    for source, path in zip(SOURCES, files):
        target = snapshots / staged_source(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        if target.read_bytes() != path.read_bytes():
            raise RuntimeError("snapshot differs from input: " + source)
    return snapshots


def negative_width_control(common, snapshots, out):
    negative = snapshots / "width_negative.sv"
    negative.write_text("// SPDX-License-Identifier: MIT\n"
                        "// Copyright (c) 2026 Etienne Cimon\n"
                        "module width_negative(input logic [7:0] a_i, output logic [3:0] y_o);\n"
                        "  assign y_o = a_i;\nendmodule\n", encoding="utf-8")
    text = run([*common, "--lint-only", "--top-module", "width_negative", negative],
               out / "lint-width-negative.log", snapshots, expect_failure=True)
    errors = re.findall(r"%Error-([A-Z0-9_]+):", text)
    if not errors or any(error not in ("WIDTH", "WIDTHTRUNC", "WIDTHEXPAND") for error in errors):
        raise RuntimeError("negative control did not fail exclusively on WIDTH; policy/parser failure is not a pass")
    if not re.search(r"%Error-(?:WIDTH|WIDTHTRUNC|WIDTHEXPAND):[^\n]*width_negative\.sv", text):
        raise RuntimeError("negative control did not identify the unwaived first-party source")
    print("LINT_NEGATIVE PASS firstparty_width_is_fatal", flush=True)
    return {"status": "PASS", "expected_failure": "WIDTH", "source": negative.name,
            "sha256": hashlib.sha256(negative.read_bytes()).hexdigest()}


def existing_makefile_baseline(snapshots):
    makefile = snapshots / "Makefile"
    lines = makefile.read_text(encoding="utf-8").splitlines()
    locations = {}
    for flag in BASELINE_FLAGS:
        matches = [index + 1 for index, line in enumerate(lines)
                   if re.fullmatch(r"\s*" + re.escape(flag) + r"\s*\\?\s*", line)]
        if not matches:
            raise RuntimeError("existing Makefile does not declare baseline flag: " + flag)
        locations[flag] = matches
    return {"sha256": hashlib.sha256(makefile.read_bytes()).hexdigest(), "locations": locations}


def audit_strict_lint(text, snapshots):
    codes = re.findall(r"^RETURN_CODE (-?\d+)$", text, re.MULTILINE)
    if len(codes) != 1:
        raise RuntimeError("strict lint log lacks a unique return code")
    code = int(codes[0])
    allowed = {(snapshots / staged_source(source)).resolve(): source for source in VENDOR_SOURCES}
    diagnostics = []
    summaries = []
    for line in text.splitlines():
        if not line.startswith("%Error"):
            continue
        summary = re.fullmatch(r"%Error: Exiting due to (\d+) error\(s\)", line)
        if summary:
            summaries.append(int(summary[1]))
            continue
        match = re.match(r"%Error-([A-Z0-9_]+): (.+?):(\d+):(\d+): (.*)$", line)
        if not match:
            raise RuntimeError("unlocated or unrecognized strict lint error: " + line)
        category, filename, row, column, message = match.groups()
        if category not in ("BLKANDNBLK", "UNOPTFLAT"):
            raise RuntimeError("unauthorized strict lint category: " + line)
        path = Path(filename)
        if not path.is_absolute():
            path = snapshots / path
        source = allowed.get(path.resolve())
        if source is None:
            raise RuntimeError("strict lint error outside vendor manifest: " + line)
        diagnostics.append({"category": category, "source": source, "line": int(row),
                            "column": int(column), "message": message})
    if code == 0:
        if diagnostics or summaries:
            raise RuntimeError("strict lint success contradicts error diagnostics")
        return {"status": "clean", "diagnostics": []}
    if code != 1 or not diagnostics or summaries != [len(diagnostics)]:
        raise RuntimeError("strict lint failure was not exclusively the enumerated vendor baseline")
    print("LINT_AUDIT existing-vendor-baseline " + json.dumps(diagnostics), flush=True)
    return {"status": "existing-vendor-baseline", "diagnostics": diagnostics}


def negative_audit_controls(common, snapshots, out):
    controls = (
        ("blocked_negative", "BLKANDNBLK",
         "input logic clk_i, input logic a_i, output logic [1:0] q_o",
         "assign q_o[0] = a_i; always_ff @(posedge clk_i) q_o[1] <= q_o[0];"),
        ("loop_negative", "UNOPTFLAT", "input logic a_i, output logic [1:0] q_o",
         "assign q_o = {q_o[0], a_i ^ q_o[1]};"),
    )
    results = {}
    for name, category, ports, body in controls:
        source = snapshots / (name + ".sv")
        source.write_text("// SPDX-License-Identifier: MIT\n// Copyright (c) 2026 Etienne Cimon\n"
                          "module " + name + "(" + ports + ");\n" + body + "\nendmodule\n", encoding="utf-8")
        text = run([*common, "--lint-only", "--top-module", name, source],
                   out / ("lint-" + name + ".log"), snapshots, expect_failure=True)
        if "%Error-" + category + ":" not in text:
            raise RuntimeError("negative audit control did not exercise " + category)
        try:
            audit_strict_lint(text, snapshots)
        except RuntimeError as error:
            if "outside vendor manifest:" not in str(error):
                raise
            results[name] = {"status": "PASS", "rejected": category, "reason": str(error),
                             "sha256": hashlib.sha256(source.read_bytes()).hexdigest()}
        else:
            raise RuntimeError("auditor incorrectly accepted first-party " + category)
    print("LINT_AUDIT_NEGATIVE PASS firstparty_baseline_categories_rejected", flush=True)
    return results


def remote(args):
    data = Path(os.environ["TH_DATA_DIR"]).resolve()
    parent = Path(os.environ["TH_OUT_DIR"]).resolve()
    if not data.is_dir() or not parent.is_dir():
        raise RuntimeError("remote proxy data/output parents must exist")
    out = Path(tempfile.mkdtemp(prefix="fp-mac-results-", dir=parent))
    work = Path(tempfile.mkdtemp(prefix="g6lc-fp-mac-build-"))
    files = [data / Path(source).name for source in SOURCES]
    report = {"status": "RUNNING", "scope": "scalar primitive only; no GEMM/top integration or vector throughput",
              "seed": args.seed, "output": str(out), "work": str(work)}
    start = time.monotonic()
    try:
        report["sha256"] = {source: hashlib.sha256(path.read_bytes()).hexdigest()
                            for source, path in zip(SOURCES, files)}
        report["runner_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        report["lint_policy_sha256"] = report["sha256"]["verilator_config.vlt"]
        report["staging"] = {source: staged_source(source).as_posix() for source in SOURCES}
        snapshots = stage(files, out)
        report["makefile_baseline"] = existing_makefile_baseline(snapshots)
        tool = Path("/opt/testharness/toolchains/verilator-v5.008/bin/verilator")
        version = run([tool, "--version"], out / "verilator-version.log", snapshots)
        if not re.search(r"\bVerilator\s+5\.008\b", version):
            raise RuntimeError("remote Verilator 5.008 required; no fallback/install")
        sv = ["./" + staged_source(source).as_posix() for source in SOURCES if source.endswith(".sv")]
        common = [tool, "--assert", "-Wall", "-Wno-fatal",
                  *("-Werror-" + warning for warning in FATAL_WARNINGS), "-I" + str(snapshots),
                  "-I" + str(snapshots / "vendor/pulp-platform/common_cells/include"),
                  snapshots / "verilator_config.vlt"]
        report["negative_width_control"] = negative_width_control(common, snapshots, out)
        report["negative_audit_controls"] = negative_audit_controls(common, snapshots, out)
        report["variants"] = {}
        for pipeline in args.pipelines:
            label = "pipe-" + str(pipeline)
            mdir = work / label
            report["variants"][label] = {"status": "RUNNING"}
            text = run([*common, "--lint-only", "--top-module", TOP,
                        "-GFpPipeRegs=" + str(pipeline), *sv], out / ("lint-" + label + ".log"),
                       snapshots, expect_failure=None)
            audit = audit_strict_lint(text, snapshots)
            report["variants"][label]["strict_lint"] = audit
            for source in SOURCES:
                if hashlib.sha256((snapshots / staged_source(source)).read_bytes()).hexdigest() != report["sha256"][source]:
                    raise RuntimeError("audited snapshot mutated before code generation: " + source)
            baseline = list(BASELINE_FLAGS) if audit["status"] == "existing-vendor-baseline" else []
            run([*common, *baseline, "--cc", "--exe", "--build", "-j", "2", "--top-module", TOP,
                 "--Mdir", mdir, "-GFpPipeRegs=" + str(pipeline),
                 "-CFLAGS", "-std=c++17 -O2 -ffp-contract=off -fno-fast-math -frounding-math",
                 *sv, snapshots / "fp_mac_main.cpp"], out / ("build-" + label + ".log"), snapshots)
            text = run([mdir / ("V" + TOP), args.seed, pipeline], out / ("simulation-" + label + ".log"), snapshots)
            if "PASS fp_mac " not in text or "SCALAR_TIMING " not in text:
                raise RuntimeError("simulation missing mandatory math/timing pass markers")
            lines = [line for line in text.splitlines() if line.startswith(("PASS fp_mac ", "SCALAR_TIMING ", "FORMAT_PASS "))]
            print("\n".join(lines), flush=True)
            report["variants"][label].update(status="PASS", records=lines, codegen_baseline_flags=baseline)
        text = run([*common, "--lint-only", "--top-module", "g6lc_ai_fp_mac", *sv],
                   out / "lint-disabled.log", snapshots, expect_failure=None)
        report["disabled_lint"] = audit_strict_lint(text, snapshots)
        report["status"] = "PASS"
    except Exception as error:
        report.update(status="FAIL", error=str(error))
        raise
    finally:
        report["elapsed_seconds"] = time.monotonic() - start
        (out / "results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print("RESULTS " + str(out / "results.json"), flush=True)
    return 0


def local_synthesis(args):
    root = Path(__file__).resolve().parents[2]
    parent = root / "build-platform/workspace/build"
    if not parent.is_dir() or parent.resolve() != parent:
        raise RuntimeError("local build parent must exist without symlink redirection")
    out = parent / tag()
    out.mkdir()
    files = [root / source for source in SOURCES]
    report = {"status": "RUNNING", "mode": "local Yosys only", "output": str(out),
              "scope": "generic scalar synthesis and bounded properties, not STA/DFT/full FP proof"}
    print("LOCAL_SYNTH_ONLY " + str(out), flush=True)
    start = time.monotonic()
    try:
        report["sha256"] = {source: hashlib.sha256(path.read_bytes()).hexdigest()
                            for source, path in zip(SOURCES, files)}
        report["runner_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        report["lint_policy_sha256"] = report["sha256"]["verilator_config.vlt"]
        report["staging"] = {source: staged_source(source).as_posix() for source in SOURCES}
        snapshots = stage(files, out)
        tool = Path(args.yosys).resolve() if args.yosys else root / "build-platform/workspace/tooling/linux-eda-suite/bin/yosys.exe"
        if not tool.is_file():
            raise RuntimeError("existing Yosys executable required; no installation/fallback")
        env = dict(os.environ)
        if os.name == "nt":
            env["PATH"] = os.pathsep.join((str(tool.parent), str(tool.parent.parent / "lib"), env.get("PATH", "")))
            env["YOSYSHQ_ROOT"] = tool.parent.parent.as_posix().rstrip("/") + "/"
        env.update({key: str(out) for key in ("TMP", "TEMP", "TMPDIR")})
        report["yosys"] = str(tool)
        report["yosys_environment"] = {key: env.get(key) for key in ("PATH", "YOSYSHQ_ROOT", "TMP", "TEMP", "TMPDIR")}
        run([tool, "-V"], out / "yosys-version.log", snapshots, env)
        probe = run([tool, "-Q", "-T", "-p", "help read_slang"], out / "slang-probe.log", snapshots, env)
        if "No such command" in probe:
            raise RuntimeError("Yosys read_slang is required")
        sv = " ".join(staged_source(source).as_posix() for source in SOURCES if source.endswith(".sv"))
        report["synthesis"] = {}
        for top in (TOP, "g6lc_ai_fp_mac"):
            script = ("read_slang --top " + top + " -I. -Ivendor/pulp-platform/common_cells/include " + sv +
                      "; synth -top " + top + " -flatten; check -assert; write_json ../" + top + ".json; stat")
            run([tool, "-Q", "-T", "-p", script], out / ("synth-" + top + ".log"), snapshots, env)
            design = json.loads((out / (top + ".json")).read_text(encoding="utf-8"))
            module = design["modules"][top]
            cells = module.get("cells", {})
            if any("latch" in cell["type"].lower() for cell in cells.values()):
                raise RuntimeError("synthesis inferred a latch")
            if any(cell["type"] in design["modules"] for cell in cells.values()):
                raise RuntimeError("synthesis did not fully flatten")
            sequential = sum("dff" in cell["type"].lower() for cell in cells.values())
            if top == "g6lc_ai_fp_mac":
                if cells or any(bit != "0" for port in module["ports"].values()
                                if port["direction"] == "output" for bit in port["bits"]):
                    raise RuntimeError("compile-disabled leaf is not zero cells and zero outputs")
            elif not sequential:
                raise RuntimeError("enabled implementation lacks state")
            result = {"cells": len(cells), "sequential_cells": sequential, "latches": 0}
            report["synthesis"][top] = result
            print("SYNTH PASS " + top + " " + json.dumps(result), flush=True)
        formal_top = "tb_g6lc_ai_fp_widen_formal"
        script = ("read_slang -DFORMAL --top " + formal_top + " -I. -Ivendor/pulp-platform/common_cells/include " + sv +
                  "; prep -top " + formal_top + " -flatten; opt; chformal -lower; check -assert; "
                  "write_json ../formal-widen.json; sat -prove-asserts -verify")
        text = run([tool, "-Q", "-T", "-p", script], out / "formal-widen.log", snapshots, env)
        if "SAT proof finished - no model found: SUCCESS!" not in text:
            raise RuntimeError("widen proof did not complete")
        design = json.loads((out / "formal-widen.json").read_text(encoding="utf-8"))
        assertions = sum(cell["type"] == "$assert" or
                         (cell["type"] == "$check" and cell["parameters"].get("FLAVOR") == "assert")
                         for cell in design["modules"][formal_top]["cells"].values())
        if not assertions:
            raise RuntimeError("formal widening proof retained no assertions")
        report["formal_widen"] = {"status": "PASS", "assertions": assertions,
            "scope": "arbitrary raw bits: passthrough, zeros, NaN/sNaN, E4M3 max, narrow subnormal classification; not full arithmetic proof"}
        if args.formal == "all":
            script = ("read_slang -DFORMAL --top " + TOP + " -I. -Ivendor/pulp-platform/common_cells/include " + sv +
                      "; prep -top " + TOP + " -flatten; async2sync; opt; chformal -lower; check -assert; "
                      "write_json ../formal-control.json; "
                      "sat -seq 12 -set-init-zero -set-assumes -prove-asserts -verify")
            text = run([tool, "-Q", "-T", "-p", script], out / "formal-control-12.log", snapshots, env, timeout=900)
            if "SAT proof finished - no model found: SUCCESS!" not in text:
                raise RuntimeError("bounded control proof did not complete")
            design = json.loads((out / "formal-control.json").read_text(encoding="utf-8"))
            assertions = sum(cell["type"] == "$assert" for cell in design["modules"][TOP]["cells"].values())
            if not assertions:
                raise RuntimeError("bounded control proof retained no assertions")
            witnesses = {}
            for name, fmt, signal in (("float_response", 7, "result_valid_o"), ("integer_error", 0, "error_o")):
                script = ("read_json ../formal-control.json; "
                          "sat -seq 12 -set-init-zero -set-assumes -set numfmt_i " + str(fmt) +
                          " -prove " + signal + " 0 -falsify -show-inputs -show-outputs -dump_vcd ../reachable-" + name + ".vcd")
                text = run([tool, "-Q", "-T", "-p", script], out / ("reachable-" + name + ".log"), snapshots, env)
                if "SAT proof finished - model found: FAIL!" not in text:
                    raise RuntimeError("missing nonvacuity witness: " + name)
                witnesses[name] = "REACHABLE"
            report["formal_control"] = {"status": "PASS", "cycles": 12, "assertions": assertions,
                "witnesses": witnesses,
                "scope": "arbitrary inputs after initial reset, clock-step async2sync, full vendor datapath; bounded control only"}
        else:
            report["formal_control"] = {"status": "NOT_RUN", "reason": "opt in with --formal all; full vendor multiplier can be expensive"}
        report["status"] = "PASS"
    except Exception as error:
        report.update(status="FAIL", error=str(error))
        raise
    finally:
        report["elapsed_seconds"] = time.monotonic() - start
        (out / "results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print("RESULTS " + str(out / "results.json"), flush=True)
    return 0


if __name__ == "__main__":
    try:
        args = arguments()
        if args.synth_only:
            sys.exit(local_synthesis(args))
        if os.environ.get("TH_DATA_DIR") and os.environ.get("TH_OUT_DIR"):
            sys.exit(remote(args))
        sys.exit(dispatch(args))
    except Exception as error:
        print("FAIL ai-fp-mac: " + str(error), file=sys.stderr, flush=True)
        sys.exit(1)
