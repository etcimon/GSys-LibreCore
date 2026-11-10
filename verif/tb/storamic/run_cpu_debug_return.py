# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""cpu-debug-return regression: seven-write debug-issued response across DRET.

Builds tb_g6lc_storamic_cpu_debug_return (a thin self-terminating driver over
g6lc_storamic_cpu_debug_return_interpreter and the shared
_g6lc_storamic_cpu_debug_netlist with Sdtrig=0), generates the independent
seven-write debug-return firmware via g6lc_cpu_debug_return_program, and
checks CPU_DEBUG_RETURN_PASS markers for the M/S/U x origin x delay matrix
plus the Negative debug-origin oracle.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

PASS_RE = re.compile(
    r"CPU_DEBUG_RETURN_PASS origin=(\d+) delay=(\d+) priv=(\d+) "
    r"cycles=(\d+) writes=(\d+) reads=(\d+) dwrites=(\d+) dreads=(\d+) "
    r"csr=(\d+) seen=(\d+)")
FAIL_RE = re.compile(
    r"CPU_DEBUG_RETURN_FAIL origin=(\d+) delay=(\d+) priv=(\d+) "
    r"reason=(\S+) cycles=(\d+) writes=(\d+) reads=(\d+) dwrites=(\d+) "
    r"dreads=(\d+) csr=(\d+) seen=(\d+)")
PLAN_REL = "cpu_origin_plan.json"
DRIVER_REL = "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_return.sv"
INTERP_REL = "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_return_interpreter.sv"
NETLIST_REL = "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_netlist.sv"
PROGRAM_REL = "verif/tb/storamic/g6lc_cpu_debug_return_program.py"
BASE_PROGRAM_REL = "verif/tb/storamic/g6lc_cpu_debug_program.py"
ENCODER_REL = "verif/tb/storamic/g6lc_cpu_origin_program.py"
VLT_REL = "verif/tb/storamic/origin_cache.vlt"
STUB_REL = "verif/tb/apu/g6lc_dram_peek64_stub.cpp"
SIM_TIMEOUT = 300
BUILD_TIMEOUT = 2400
PRIVILEGES = (0, 1, 3)  # U, S, M


def _sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _images(program, cache, priv):
    if priv not in cache:
        normal, debug = program.build_return_program(priv)
        cache[priv] = {"normal": normal, "debug": debug,
                       "program_sha256": hashlib.sha256(normal).hexdigest(),
                       "debug_sha256": hashlib.sha256(debug).hexdigest()}
    return cache[priv]


def _case(origin, delay, priv, negative=0):
    return {"origin": origin, "delay": delay, "priv": priv,
            "negative": negative}


def _case_list():
    cases = []
    for priv in PRIVILEGES:
        for origin in (0, 1):
            for delay in (0, 16):
                cases.append(_case(origin, delay, priv))
    for priv in PRIVILEGES:
        for origin in (0, 1):
            cases.append(_case(origin, 16, priv, negative=1))
    return cases


def run(data, out, stages, manifest, builds, outcomes, verilator, build_model):
    if "cpu-debug-return" not in stages:
        return
    plan = json.loads((data / PLAN_REL).read_text())
    tree = out / "cpu-src"
    closure = plan["files"] + plan.get("support_files", [])
    bench_files = [DRIVER_REL, INTERP_REL, NETLIST_REL]
    for rel in closure + bench_files:
        dst = tree / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(data / Path(rel).name, dst)
    sys.path.insert(0, str(data))
    spec = importlib.util.spec_from_file_location(
        "g6lc_cpu_debug_return_program", data / Path(PROGRAM_REL).name)
    program = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(program)
    from run_cpu_origin import _build_env, _model_identity
    env = _build_env(manifest)
    images = {}
    for case in _case_list():
        _images(program, images, case["priv"])
    manifest["cpu_debug_return"] = {
        "plan": PLAN_REL,
        "files": len(plan["files"]),
        "support_files": len(plan.get("support_files", [])),
        "driver_sha256": _sha(tree / DRIVER_REL),
        "interpreter_sha256": _sha(tree / INTERP_REL),
        "netlist_sha256": _sha(tree / NETLIST_REL),
        "program_runner_sha256": _sha(data / Path(PROGRAM_REL).name),
        "base_program_sha256": _sha(data / Path(BASE_PROGRAM_REL).name),
        "encoder_sha256": _sha(data / Path(ENCODER_REL).name),
        "hold_stage": 3, "hold_cycles": 384,
        "images": {str(priv): {
            "entry_privilege": priv,
            "program_sha256": img["program_sha256"],
            "debug_sha256": img["debug_sha256"]}
            for priv, img in sorted(images.items())},
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))

    def build_and_run(case):
        origin, delay, priv = case["origin"], case["delay"], case["priv"]
        negative = case["negative"]
        label = f"cpu-dbgret-o{origin}-d{delay}-p{priv}"
        if negative:
            label += "-n"
        model = out / ("model-" + label)
        model.mkdir()
        img = _images(program, images, priv)
        (model / "program.hex").write_bytes(img["normal"])
        (model / "debug.hex").write_bytes(img["debug"])
        command = [str(verilator), "--binary", "--timing", "--assert",
                   "--threads", "1", "-Wno-fatal",
                   "--top-module", "tb_g6lc_storamic_cpu_debug_return",
                   f"-GOriginEnabled={origin}", f"-GResponseDelay={delay}",
                   f"-GNegative={int(negative)}",
                   f"-GEntryPrivilege={priv}",
                   "--Mdir", str(model), "-o", "test",
                   "--exe", str(data / Path(STUB_REL).name),
                   str(data / Path(VLT_REL).name),
                   *["-I" + str(tree / d) for d in plan["incdirs"]],
                   *plan["defines"],
                   *[str(tree / f) for f in plan["files"]],
                   str(tree / DRIVER_REL), str(tree / INTERP_REL),
                   str(tree / NETLIST_REL)]
        command += manifest["runtime"].get("verilator_options", [])
        (out / (label + "-command.json")).write_text(json.dumps(command))
        started = time.monotonic()
        with (out / (label + "-build.log")).open("w") as log:
            try:
                subprocess.run(command, env=env, cwd=model, stdout=log,
                               stderr=subprocess.STDOUT, check=True,
                               timeout=BUILD_TIMEOUT)
            except (subprocess.SubprocessError, subprocess.TimeoutExpired) as e:
                raise RuntimeError(f"{label}: build failed: {e}")
        seconds = round(time.monotonic() - started, 1)
        executable = model / "test"
        builds.append(_model_identity(model, executable, manifest) |
                      {"cpu_debug_return": label, "mutant": 0,
                       "seconds": seconds,
                       "log_sha256": _sha(out / (label + "-build.log"))})
        outcomes.append({"cpu_debug_return": label + "-build", "origin": origin,
                         "delay": delay, "priv": priv, "negative": negative,
                         "seconds": seconds, "executable": str(executable),
                         "pass": True})
        try:
            result = subprocess.run([str(executable)], env=env, cwd=model,
                                    capture_output=True, text=True,
                                    timeout=SIM_TIMEOUT)
            text = result.stdout + result.stderr
            rc = result.returncode
        except subprocess.TimeoutExpired:
            text, rc = "TIMEOUT", None
        (out / (label + ".log")).write_text(text)
        pass_matches = PASS_RE.findall(text)
        fail_matches = FAIL_RE.findall(text)
        pass_match = PASS_RE.search(text)
        fail_match = FAIL_RE.search(text)
        record = {
            "cpu_debug_return": label, "origin": origin, "delay": delay,
            "priv": priv, "negative": negative, "rc": rc,
            "pass_marker": pass_match.group(0) if pass_match else None,
            "fail_marker": fail_match.group(0) if fail_match else None,
            "program_sha256": img["program_sha256"],
            "debug_sha256": img["debug_sha256"],
            "log_sha256": _sha(out / (label + ".log")),
        }
        if negative:
            # Negative=1 forces a wrong debug-origin expectation on Probe+28:
            # must reject debug-origin-failed and emit no pass marker.
            ok = (rc != 0 and not pass_matches and len(fail_matches) == 1 and
                  fail_match and fail_match.group(4) == "debug-origin-failed")
        else:
            ok = (rc == 0 and len(pass_matches) == 1 and pass_match and
                  not fail_matches and
                  int(pass_match.group(1)) == origin and
                  int(pass_match.group(2)) == delay and
                  int(pass_match.group(3)) == priv and
                  int(pass_match.group(5)) == 7 and   # writes
                  int(pass_match.group(6)) == 4 and   # reads
                  int(pass_match.group(7)) == 4 and   # debug writes
                  int(pass_match.group(8)) == 2 and   # debug reads
                  int(pass_match.group(9)) == 2 and   # csr
                  int(pass_match.group(10)) == 1)     # debug seen
        record["pass"] = bool(ok)
        outcomes.append(record)

    for case in _case_list():
        build_and_run(case)
    rejected = [record["cpu_debug_return"] for record in outcomes
                if record.get("pass") is False]
    if rejected:
        raise RuntimeError("cpu-debug-return verdicts failed: " +
                           ", ".join(rejected))
