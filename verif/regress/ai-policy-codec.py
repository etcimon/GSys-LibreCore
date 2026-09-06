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


LEGACY_SOURCES = (
    "core/include/config_pkg.sv",
    "core/include/g6lc64_ai_config_pkg.sv",
    "corev_apu/ai_island/include/g6lc_ai_policy_pkg.sv",
    "corev_apu/ai_island/g6lc_ai_policy_codec.sv",
    "verif/tb/ai_island/tb_g6lc_ai_policy.sv",
    "verif/tb/ai_island/policy_main.cpp",
)
SOURCES = LEGACY_SOURCES + (
    "corev_apu/ai_island/g6lc_ai_policy_subcode.sv",
    "corev_apu/ai_island/g6lc_ai_policy_steer.sv",
    "verif/tb/ai_island/tb_g6lc_ai_policy_resource.sv",
    "verif/tb/ai_island/tb_g6lc_ai_policy_steer.sv",
    "verif/tb/ai_island/policy_efficiency.cpp",
)
TOP = "tb_g6lc_ai_policy"
DISABLED_TOP = "tb_g6lc_ai_policy_instance"
STEER_TOP = "tb_g6lc_ai_policy_steer"
STEER_SYNTH_TOP = "tb_g6lc_ai_policy_steer_on"
STEER_DISABLED_TOP = "tb_g6lc_ai_policy_steer_instance"


def legacy_files(files):
    names = {Path(source).name for source in LEGACY_SOURCES}
    return [path for path in files if path.name in names]


def sv_files(files):
    return [path for path in files if path.suffix == ".sv"]


TRACE_BITS = {0: 8, 1: 4, 3: 8, 4: 8, 5: 16, 6: 16, 7: 32}


def closed_json(text):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate JSON key: " + key)
            result[key] = value
        return result
    def constant(value):
        raise ValueError("nonfinite JSON number: " + value)
    return json.loads(text, object_pairs_hook=pairs, parse_constant=constant)


def validate_trace(trace):
    def require(ok, message):
        if not ok:
            raise ValueError("external policy trace: " + message)
    allowed = {"schema", "records", "source", "backend", "qemu_guest", "rtl_cycles",
               "learned_profiler"}
    require(type(trace) is dict and not set(trace) - allowed, "unknown top-level fields/object")
    require(trace.get("schema") == "g6lc.policy-workload.v1", "unsupported schema")
    require(trace.get("backend") == "b3-descriptor-executor", "unverified functional backend")
    for key in ("qemu_guest", "rtl_cycles"):
        require(trace.get(key) is False, key + " must be false")
    if "learned_profiler" in trace:
        require(trace["learned_profiler"] is False, "learned_profiler must be false")
    source = trace.get("source")
    require(type(source) is dict, "missing source profile")
    for key in ("target_id", "profile"):
        require(type(source.get(key)) is str and
                re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", source[key]) is not None,
                "invalid source " + key)
    records = trace.get("records")
    require(type(records) is list and 1 <= len(records) <= 256, "records must contain 1..256 jobs")
    fields = {"id", "m", "n", "k", "numfmt", "opcode_class", "native_sample_hex",
              "sample_valid", "exact_zero"}
    ids = set()
    for record in records:
        require(type(record) is dict and set(record) == fields, "record fields must be closed")
        ident = record["id"]
        require(type(ident) is str and 1 <= len(ident.encode("utf-8")) <= 256 and ident not in ids,
                "invalid/duplicate id")
        ids.add(ident)
        for key in ("m", "n", "k"):
            require(type(record[key]) is int and 1 <= record[key] <= 256,
                    key + " must be an integer in 1..256; no implicit tiling")
        fmt = record["numfmt"]
        require(type(fmt) is int and fmt in TRACE_BITS, "unsupported numfmt")
        require(type(record["opcode_class"]) is int and 0 <= record["opcode_class"] <= 3,
                "opcode_class must be an integer in 0..3 (semantic metadata)")
        require(type(record["sample_valid"]) is bool, "sample_valid must be boolean")
        require(record["exact_zero"] is False, "external samples are not an exact-zero proof")
        sample = record["native_sample_hex"]
        require(type(sample) is str and re.fullmatch(r"[0-9a-fA-F]*", sample) is not None,
                "invalid native sample hex")
        require(len(sample) == (2 * TRACE_BITS[fmt] if record["sample_valid"] else 0),
                "sample must contain exactly eight native elements when valid, otherwise empty")
        require(not record["sample_valid"] or record["m"] * record["k"] >= 8,
                "valid sample exceeds A geometry")
    return trace


def load_trace(path):
    path = Path(path)
    if path.stat().st_size > 4 * 1024 * 1024:
        raise ValueError("external policy trace exceeds 4 MiB")
    return validate_trace(closed_json(path.read_text(encoding="utf-8")))


def trace_tsv(trace):
    validate_trace(trace)
    source = trace["source"]
    lines = ["\t".join(("g6lc.policy-workload.tsv.v1", source["target_id"], source["profile"],
                         str(len(trace["records"]))))]
    for index, record in enumerate(trace["records"]):
        lines.append("\t".join(str(value) for value in (
            index, record["m"], record["n"], record["k"], record["numfmt"],
            record["opcode_class"], int(record["sample_valid"]), 0,
            record["native_sample_hex"].lower() or "-")))
    return "\n".join(lines) + "\n"


def arguments():
    parser = argparse.ArgumentParser(
        description="GSys LibreCore policy codec/steering: remote-proxy scoreboards, scheduling model and synthesis"
    )
    parser.add_argument("--seed", default=os.environ.get("AI_POLICY_SEED", "0x6c706f6c696379"))
    parser.add_argument("--synth", choices=("auto", "off", "required"),
                        default=os.environ.get("AI_POLICY_SYNTH", "auto"))
    parser.add_argument("--parameters", choices=("extremes", "default"),
                        default=os.environ.get("AI_POLICY_PARAMETERS", "extremes"),
                        help="default full suite followed by two focused extreme builds")
    parser.add_argument("--dry-run", action="store_true",
                        help="print the local proxy command without starting remote work")
    parser.add_argument("--synth-only", action="store_true",
                        help="opt in to local Yosys synthesis and bounded SAT; never run local Verilator")
    parser.add_argument("--yosys", metavar="PATH",
                        help="existing executable for --synth-only; no fallback or installation")
    parser.add_argument("--trace", type=Path,
                        help="replay a validated g6lc.policy-workload.v1 trace after default suites")
    args = parser.parse_args()
    if args.trace and (args.synth_only or os.environ.get("TH_DATA_DIR")):
        parser.error("--trace is local proxy-dispatch only and incompatible with --synth-only")
    if args.yosys and not args.synth_only:
        parser.error("--yosys requires --synth-only; normal verification is remote-proxy only")
    if args.synth_only:
        if args.dry_run or args.synth == "off":
            parser.error("--synth-only cannot be combined with --dry-run or --synth off")
        args.synth = "required"
    value = int(args.seed, 0)
    if not 0 <= value < 2**64:
        parser.error("seed must be an unsigned 64-bit integer")
    args.seed = str(value)
    return args


def unique_tag():
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return "ai-policy-codec-" + now + "-" + uuid.uuid4().hex[:12]


def dispatch(args):
    root = Path(__file__).resolve().parents[2]
    proxy = root / "verif/regress/remote/testharness_proxy.py"
    files = [root / source for source in SOURCES]
    for path in [proxy, *files]:
        if not path.is_file():
            raise RuntimeError("required input missing: " + str(path))
    tag = unique_tag()
    def proxy_path(path):
        if os.name != "nt":
            return str(path)
        if not path.drive or len(path.drive) != 2 or path.drive[1] != ":":
            raise RuntimeError("WSL proxy dispatch requires a drive-qualified input: " + str(path))
        return "/mnt/" + path.drive[0].lower() + path.as_posix()[2:]
    launcher = ["wsl.exe", "--exec", "python3"] if os.name == "nt" else [sys.executable]
    command = [*launcher, proxy_path(proxy), "py", proxy_path(Path(__file__).resolve()),
               "--tag", tag, "--threads", "1", "--pull",
               "--env", "AI_POLICY_SEED=" + args.seed,
               "--env", "AI_POLICY_SYNTH=" + args.synth,
               "--env", "AI_POLICY_PARAMETERS=" + args.parameters]
    if args.trace:
        trace = load_trace(args.trace)
        parent = root / "build-platform/workspace/build"
        if not parent.is_dir() or parent.resolve() != parent:
            raise RuntimeError("trace build parent must exist without symlink redirection")
        out = parent / tag
        out.mkdir()
        artifact = out / (tag + ".tsv")
        artifact.write_text(trace_tsv(trace), encoding="utf-8")
        (out / "trace.json").write_text(json.dumps(trace, indent=2) + "\n", encoding="utf-8")
        print("TRACE_ARTIFACT " + str(artifact), flush=True)
        command.extend(("--env", "AI_POLICY_TRACE=" + artifact.name))
        files.append(artifact)
    for path in files:
        command.extend(("--data", proxy_path(path)))
    print("PROXY_ONLY " + shlex.join(command), flush=True)
    print("PULL_OUTPUT " + str(root / "remote-runs" / tag / "output"), flush=True)
    if args.dry_run:
        return 0
    return subprocess.run(command, cwd=root, check=False).returncode


def run(command, log, cwd=None, env=None, required=True):
    command = [str(arg) for arg in command]
    print("RUN " + shlex.join(command), flush=True)
    start = time.monotonic()
    with log.open("w", encoding="utf-8") as output:
        output.write("COMMAND " + shlex.join(command) + "\n")
        output.flush()
        result = subprocess.run(command, cwd=cwd, env=env, stdout=output,
                                stderr=subprocess.STDOUT, check=False)
        output.write("\nRETURN_CODE " + str(result.returncode) +
                     " ELAPSED_SECONDS " + str(time.monotonic() - start) + "\n")
    text = log.read_text(encoding="utf-8", errors="replace")
    if result.returncode and required:
        print(text[-16000:], flush=True)
        raise RuntimeError("command failed rc=" + str(result.returncode) + "; log=" + str(log))
    return result.returncode, text


def executable(path):
    return bool(path) and os.access(path, os.X_OK) and Path(path).is_file()


def verilator(out):
    candidates = [shutil.which("verilator"),
                  "/opt/testharness/toolchains/verilator-v5.008/bin/verilator",
                  "/root/tools/verilator-v5.008/bin/verilator"]
    for index, candidate in enumerate(dict.fromkeys(candidates)):
        if not executable(candidate):
            continue
        rc, text = run([candidate, "--version"], out / ("verilator-version-" + str(index) + ".log"),
                       required=False)
        if rc == 0 and re.search(r"\bVerilator\s+5\.008\b", text):
            return candidate
    raise RuntimeError("Verilator 5.008 unavailable on remote host; no tools installed by this runner")


def yosys_environment(yosys):
    env = dict(os.environ)
    if os.name == "nt":
        binary_dir = Path(yosys).resolve().parent
        tool_root = binary_dir.parent
        env["PATH"] = os.pathsep.join((str(binary_dir), str(tool_root / "lib"),
                                       env.get("PATH", "")))
        env["YOSYSHQ_ROOT"] = tool_root.as_posix().rstrip("/") + "/"
    return env


def yosys_frontend(args, out):
    if args.yosys:
        explicit = Path(args.yosys).expanduser().resolve()
        if not executable(explicit):
            raise RuntimeError("--yosys is not an existing executable: " + str(explicit))
        candidates = [str(explicit)]
    else:
        candidates = [shutil.which("yosys"), "/root/tools/yosys/bin/yosys",
                      "/opt/testharness/toolchains/yosys/bin/yosys",
                      "/opt/testharness/repo/build-platform/workspace/tooling/formal/bin/yosys"]
        if os.name == "nt":
            candidates.append(str(Path(__file__).resolve().parents[2] /
                                  "build-platform/workspace/tooling/linux-eda-suite/bin/yosys.exe"))
    installed = list(dict.fromkeys(x for x in candidates if executable(x)))
    if not installed:
        return None, None, "Yosys unavailable on PATH and known toolchain locations"
    modules = [[]]
    if os.environ.get("YOSYS_SLANG_PLUGIN"):
        modules.append(["-m", os.environ["YOSYS_SLANG_PLUGIN"]])
    modules.append(["-m", "slang"])
    for tool_index, yosys in enumerate(installed):
        env = yosys_environment(yosys)
        if args.synth_only:
            env.update({name: str(out) for name in ("TMP", "TEMP", "TMPDIR")})
        for module_index, module in enumerate(modules):
            command = [yosys, *module, "-Q", "-T"]
            rc, text = run([*command, "-p", "help read_slang"],
                           out / ("yosys-probe-" + str(tool_index) + "-" +
                                  str(module_index) + ".log"),
                           cwd=out if args.synth_only else None, env=env, required=False)
            if rc == 0 and "No such command" not in text and "read_slang" in text:
                return command, env, ""
    return None, None, "Yosys read_slang unavailable (all existing tools and plugin probes failed)"


def yosys_quote(path):
    return '"' + Path(path).as_posix().replace("\\", "\\\\").replace('"', '\\"') + '"'


def synthesize(args, files, out, frontend=None):
    if args.synth == "off":
        print("SYNTH SKIP explicitly disabled", flush=True)
        return {"status": "SKIP", "reason": "explicitly disabled"}
    command, env, reason = frontend if frontend is not None else yosys_frontend(args, out)
    if command is None:
        if args.synth == "required":
            raise RuntimeError("required synthesis unavailable: " + reason)
        print("SYNTH SKIP " + reason, flush=True)
        return {"status": "SKIP", "reason": reason}
    results = {}
    if not args.synth_only:
        for path in files:
            shutil.copy2(path, out / path.name)
    for top in (TOP, DISABLED_TOP, STEER_SYNTH_TOP, STEER_DISABLED_TOP):
        netlist = out / (top + ".json")
        selected = legacy_files(files) if top in (TOP, DISABLED_TOP) else files
        sources = " ".join(path.name for path in sv_files(selected))
        script = ("read_slang --top " + top + " " + sources +
                  "; synth -top " + top + " -flatten; check -assert; " +
                  "write_json " + yosys_quote(netlist) + "; stat")
        run([*command, "-p", script], out / ("synth-" + top + ".log"),
            cwd=out, env=env)
        design = json.loads(netlist.read_text(encoding="utf-8"))
        module = design["modules"][top]
        cells = module.get("cells", {})
        latch_cells = {name: cell["type"] for name, cell in cells.items()
                       if "latch" in cell["type"].lower()}
        if latch_cells:
            raise RuntimeError(top + " contains latches: " + repr(latch_cells))
        if any(cell["type"] in design["modules"] for cell in cells.values()):
            raise RuntimeError(top + " not fully flattened; cannot establish latch/state result")
        sequential = sum("dff" in cell["type"].lower() for cell in cells.values())
        if top in (DISABLED_TOP, STEER_DISABLED_TOP):
            if cells:
                raise RuntimeError("compile-disabled codec retained cells: " + str(len(cells)))
            for name, port in module["ports"].items():
                if port["direction"] == "output" and any(bit not in ("0", "1") for bit in port["bits"]):
                    raise RuntimeError("compile-disabled output is not a known constant: " + name)
        elif not cells or not sequential:
            raise RuntimeError("enabled synthesis unexpectedly has no sequential implementation")
        results[top] = {"cells": len(cells), "sequential_cells": sequential, "latches": 0}
        print("SYNTH PASS " + top + " " + json.dumps(results[top]) +
              " (generic cells, not technology area or timing)", flush=True)
    return {"status": "PASS", "tops": results}


def bounded_formal(files, out, frontend, top=TOP):
    command, env, _ = frontend
    rc, text = run([*command, "-p", "help sat"], out / "yosys-sat-probe.log",
                   cwd=out, env=env, required=False)
    if rc or "No such command" in text or any(
            flag not in text for flag in ("-seq", "-set-init-zero", "-prove-asserts",
                                         "-set-assumes", "-verify", "-falsify")):
        reason = "Yosys built-in bounded SAT controls unavailable"
        print("FORMAL SKIP " + reason, flush=True)
        return {"status": "SKIP", "reason": reason}
    suffix = "" if top == TOP else "-steer"
    selected = legacy_files(files) if top == TOP else files
    netlist = out / ("formal-design" + suffix + ".json")
    sat = "sat -seq 12 -set-init-zero -set-assumes"
    script = ("read_slang -DFORMAL --top " + top + " " +
              " ".join(p.name for p in sv_files(selected)) +
              "; prep -top " + top + " -flatten; async2sync; opt; check -assert; " +
              "write_json " + yosys_quote(netlist) + "; " + sat + " -prove-asserts -verify")
    _, text = run([*command, "-p", script], out / ("formal-bounded-12" + suffix + ".log"),
                  cwd=out, env=env)
    if "SAT proof finished - no model found: SUCCESS!" not in text:
        raise RuntimeError("bounded SAT exited without an unambiguous proof success")
    design = json.loads(netlist.read_text(encoding="utf-8"))
    assertions = sum(cell["type"] == "$assert" or
                     (cell["type"] == "$check" and cell["parameters"].get("FLAVOR") == "assert")
                     for cell in design["modules"][top].get("cells", {}).values())
    if not assertions:
        raise RuntimeError("bounded formal design retained no assertions")
    witnesses = {}
    signals = ["work_valid_o", "commit_o", "hold_o", "warm_valid_o",
               "residual_skip_o", "predict_hit_o", "predict_miss_o"]
    if top == STEER_SYNTH_TOP:
        signals.append("topology_o[21]")
    for signal in signals:
        label = re.sub(r"[^A-Za-z0-9_-]", "_", signal) + suffix
        script = ("read_json " + yosys_quote(netlist) + "; " + sat +
                  " -prove " + signal + " 0 -falsify -show-inputs -show-outputs -dump_vcd " +
                  yosys_quote(out / ("reachable-" + label + ".vcd")))
        _, text = run([*command, "-p", script], out / ("reachable-" + label + ".log"),
                      cwd=out, env=env)
        if "SAT proof finished - model found: FAIL!" not in text:
            raise RuntimeError("SAT did not produce a reachability witness for " + signal)
        witnesses[signal] = "REACHABLE"
    result = {"status": "PASS", "top": top, "cycles": 12, "assertions": assertions,
              "scope": "bounded safety, not induction; initial reset then arbitrary inputs; "
                       "async2sync clock-step model; default parameters",
              "initial_state": "sat -set-init-zero; first sampled rst_ni assumed low",
              "witnesses": witnesses}
    print("FORMAL PASS " + json.dumps(result), flush=True)
    return result


def local_synthesis(args):
    root = Path(__file__).resolve().parents[2]
    parent = root / "build-platform/workspace/build"
    if not parent.is_dir() or parent.resolve() != parent:
        raise RuntimeError("local synthesis build parent must exist without symlink redirection")
    out = parent / unique_tag()
    out.mkdir()
    files = sv_files([root / source for source in SOURCES])
    report = {"status": "RUNNING", "mode": "local-synthesis-only", "output": str(out),
              "scope": "isolated codec/steering; generic synthesis and bounded safety, not sign-off"}
    start = time.monotonic()
    print("LOCAL_SYNTH_ONLY " + str(out), flush=True)
    try:
        for path in files:
            if not path.is_file():
                raise RuntimeError("required input missing: " + str(path))
        report["sha256"] = {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                            for path in [Path(__file__).resolve(), *files]}
        frontend = yosys_frontend(args, out)
        if frontend[0] is None:
            raise RuntimeError("required synthesis unavailable: " + frontend[2])
        report["yosys"] = frontend[0]
        report["yosys_environment"] = {name: frontend[1].get(name) for name in
                                       ("PATH", "YOSYSHQ_ROOT", "TMP", "TEMP", "TMPDIR")}
        run([frontend[0][0], "-V"], out / "yosys-version.log", cwd=out, env=frontend[1])
        snapshots = []
        for path in files:
            shutil.copy2(path, out / path.name)
            snapshots.append(Path(path.name))
        report["synthesis"] = synthesize(args, snapshots, out, frontend)
        report["formal"] = bounded_formal(snapshots, out, frontend)
        report["steering_formal"] = bounded_formal(snapshots, out, frontend, STEER_SYNTH_TOP)
        report["status"] = "PASS"
    except Exception as error:
        report["status"] = "FAIL"
        report["error"] = str(error)
        raise
    finally:
        report["elapsed_seconds"] = time.monotonic() - start
        (out / "results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print("RESULTS " + str(out / "results.json"), flush=True)
        print("PRESERVED_BUILD " + str(out), flush=True)
    return 0


def efficiency_report(text, read_bytes, min_gain):
    tags = {"WORKLOAD_FORMAT", "STATE", "CODE_SHARE", "STATIC_ORACLE", "STATIC_AFFINITY",
            "STATE_AGGREGATE_RAW_MODEL", "FORMAT_AGGREGATE_RAW_MODEL",
            "FORMAT_SHARE_RAW_MODEL", "BALANCED_MIX", "SWITCH_TAX_SENSITIVITY",
            "EXTERNAL_POLICY_REPLAY"}
    records = []
    for line in text.splitlines():
        fields = line.split()
        if not fields or fields[0] not in tags:
            continue
        record = {"type": fields[0]}
        for field in fields[1:]:
            key, sep, value = field.partition("=")
            if not sep:
                continue
            try:
                record[key] = json.loads(value)
            except json.JSONDecodeError:
                record[key] = value
        records.append(record)
    pairs = [record for record in records if record["type"] == "WORKLOAD_FORMAT"]
    if min_gain == 2 and len(pairs) != 28:
        raise RuntimeError("efficiency report must include all 28 workload/format pairs")
    return {"scope": "RTL-validated scheduling model; not production speed or floating-point arithmetic",
            "sram_read_bytes_per_cycle": read_bytes, "min_gain_16ths": min_gain,
            "records": records}


def remote(args):
    if args.dry_run:
        raise RuntimeError("--dry-run is a local proxy-dispatch option")
    data = Path(os.environ["TH_DATA_DIR"]).resolve()
    parent = Path(os.environ["TH_OUT_DIR"]).resolve()
    if not data.is_dir() or not parent.is_dir():
        raise RuntimeError("proxy TH_DATA_DIR and TH_OUT_DIR must already exist")
    out = Path(tempfile.mkdtemp(prefix="policy-results-", dir=parent))
    work = Path(tempfile.mkdtemp(prefix="g6lc-policy-build-"))
    files = [data / Path(source).name for source in SOURCES]
    report = {"status": "RUNNING", "seed": args.seed, "output": str(out), "work": str(work),
              "scope": "isolated codec/steering; validated scheduling model, not production speed"}
    start = time.monotonic()
    try:
        for path in files:
            if not path.is_file():
                raise RuntimeError("uploaded input missing: " + str(path))
        report["sha256"] = {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                            for path in [Path(__file__).resolve(), *files]}
        trace_path = None
        if os.environ.get("AI_POLICY_TRACE"):
            name = os.environ["AI_POLICY_TRACE"]
            if Path(name).name != name or not re.fullmatch(r"[A-Za-z0-9_.-]+\.tsv", name):
                raise RuntimeError("AI_POLICY_TRACE must be an uploaded TSV basename")
            trace_path = (data / name).resolve()
            if trace_path.parent != data or not trace_path.is_file():
                raise RuntimeError("uploaded trace must be contained in TH_DATA_DIR")
            report["sha256"][name] = hashlib.sha256(trace_path.read_bytes()).hexdigest()
            report["external_trace"] = str(trace_path)
            shutil.copy2(trace_path, out / name)
        tool = verilator(out)
        sv = sv_files(files)
        legacy = legacy_files(files)
        legacy_sv = sv_files(legacy)
        fatal_warnings = ("WIDTH", "ENUMVALUE", "IMPLICIT", "PINMISSING", "SELRANGE",
                          "LATCH", "UNOPTFLAT", "MULTIDRIVEN")
        common = [tool, "--assert", "-Wall", "-Wno-fatal",
                  *("-Werror-" + warning for warning in fatal_warnings)]
        for top in (TOP, DISABLED_TOP, STEER_TOP, STEER_SYNTH_TOP, STEER_DISABLED_TOP):
            selected = legacy_sv if top in (TOP, DISABLED_TOP) else sv
            run([*common, "--lint-only", "--top-module", top,
                 "--Mdir", work / ("lint-" + top), *selected], out / ("lint-" + top + ".log"))
        report["lint"] = "PASS"
        variants = [("default", 3, 4, 2, 4)]
        if args.parameters == "extremes":
            variants.extend((("minimum", 1, 1, 0, 1), ("maximum", 15, 15, 15, 8)))
        report["variants"] = {}
        for name, hold, dwell, cooldown, banks in variants:
            params = ["-GHoldWork=" + str(hold), "-GDwellWork=" + str(dwell),
                      "-GCooldownWork=" + str(cooldown), "-GBankBits=" + str(banks)]
            cflags = ("-std=c++17 -O2 -Wall -Wextra -Werror " +
                      "-DAI_POLICY_HOLD=" + str(hold) + " -DAI_POLICY_DWELL=" + str(dwell) +
                      " -DAI_POLICY_COOLDOWN=" + str(cooldown) +
                      " -DAI_POLICY_BANK_BITS=" + str(banks))
            variant = out / name
            variant.mkdir()
            mdir = work / ("obj-" + name)
            report["variants"][name] = {"hold": hold, "dwell": dwell, "cooldown": cooldown,
                                        "bank_bits": banks, "status": "RUNNING"}
            run([*common, *params, "--cc", "--exe", "--build", "-j", "2", "--top-module", TOP,
                 "--Mdir", mdir, "-CFLAGS", cflags, *legacy], variant / "build.log", cwd=work)
            env = dict(os.environ, AI_POLICY_SEED=args.seed)
            _, text = run([mdir / ("V" + TOP)], variant / "simulation.log", cwd=work, env=env)
            print(text, flush=True)
            if "AI_POLICY_CODEC PASS" not in text or "AI_POLICY_CODEC FAIL" in text:
                raise RuntimeError(name + " exited without an unambiguous scoreboard PASS")
            report["variants"][name]["status"] = "PASS"
        report["simulation"] = "PASS"
        report["steering"] = {}
        steering_variants = [("sram128", 128, 2), ("sram512", 512, 2)]
        if args.parameters == "extremes":
            steering_variants.append(("min_gain12", 128, 12))
        for name, read_bytes, min_gain in steering_variants:
            variant = out / ("steering-" + name)
            variant.mkdir()
            mdir = work / ("obj-steering-" + name)
            params = ["-GReadBytesPerCycle=" + str(read_bytes), "-GMinGain16ths=" + str(min_gain)]
            cflags = ("-std=c++17 -O2 -Wall -Wextra -Werror -DAI_POLICY_READ_BYTES=" + str(read_bytes) +
                      " -DAI_POLICY_MIN_GAIN=" + str(min_gain))
            report["steering"][name] = {"read_bytes_per_cycle": read_bytes,
                                         "min_gain_16ths": min_gain, "status": "RUNNING"}
            run([*common, *params, "--cc", "--exe", "--build", "-j", "2", "--top-module", STEER_TOP,
                 "--Mdir", mdir, "-CFLAGS", cflags, *sv, data / "policy_efficiency.cpp"],
                variant / "build.log", cwd=work)
            env = dict(os.environ, AI_POLICY_SEED=args.seed)
            if trace_path is not None:
                env["AI_POLICY_TRACE"] = str(trace_path)
            _, text = run([mdir / ("V" + STEER_TOP)], variant / "simulation.log", cwd=work, env=env)
            print(text, flush=True)
            if "AI_POLICY_STEER PASS" not in text or "AI_POLICY_STEER FAIL" in text:
                raise RuntimeError(name + " exited without an unambiguous steering PASS")
            metrics = efficiency_report(text, read_bytes, min_gain)
            if trace_path is not None and not any(
                    record["type"] == "EXTERNAL_POLICY_REPLAY" and record.get("format") == "ALL"
                    for record in metrics["records"]):
                raise RuntimeError("steering exited without external replay summary")
            (variant / "efficiency.json").write_text(
                json.dumps(metrics, indent=2, allow_nan=False) + "\n", encoding="utf-8")
            report["steering"][name]["status"] = "PASS"
        frontend = yosys_frontend(args, out) if args.synth != "off" else (None, None, "explicitly disabled")
        report["synthesis"] = synthesize(args, sv, out, frontend)
        if frontend[0] is not None:
            report["formal"] = bounded_formal(sv, out, frontend)
            report["steering_formal"] = bounded_formal(sv, out, frontend, STEER_SYNTH_TOP)
        else:
            report["formal"] = report["steering_formal"] = {"status": "SKIP", "reason": frontend[2]}
        report["status"] = "PASS"
    except Exception as error:
        report["status"] = "FAIL"
        report["error"] = str(error)
        raise
    finally:
        report["elapsed_seconds"] = time.monotonic() - start
        (out / "results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print("RESULTS " + str(out / "results.json"), flush=True)
        print("PRESERVED_BUILD " + str(work), flush=True)
    return 0


def main():
    args = arguments()
    if bool(os.environ.get("TH_DATA_DIR")) != bool(os.environ.get("TH_OUT_DIR")):
        raise RuntimeError("both proxy TH_DATA_DIR and TH_OUT_DIR must be set, or neither")
    if args.synth_only:
        if os.environ.get("TH_DATA_DIR"):
            raise RuntimeError("--synth-only is local-only and cannot run inside the remote proxy")
        return local_synthesis(args)
    if os.environ.get("TH_DATA_DIR"):
        return remote(args)
    return dispatch(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print("AI_POLICY_RUNNER FAIL " + str(error), file=sys.stderr)
        sys.exit(1)
