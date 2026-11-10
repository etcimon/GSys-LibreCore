# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""cpu-debug-queue regression: queued firmware transaction across debug entry.

Builds tb_g6lc_storamic_cpu_debug_queue (a thin self-terminating driver over
g6lc_storamic_cpu_debug_queue_interpreter and the shared
_g6lc_storamic_cpu_debug_netlist with Sdtrig=0), generates the halt debug
firmware via g6lc_cpu_debug_program, and checks CPU_DEBUG_QUEUE_PASS markers
for the HoldStage 1-3 queued-transaction matrix plus the Negative debug-origin
oracle and the LSU debug-ignore mutant.
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
    r"CPU_DEBUG_QUEUE_PASS origin=(\d+) delay=(\d+) priv=(\d+) stage=(\d+) "
    r"cycles=(\d+) writes=(\d+) reads=(\d+) dwrites=(\d+) dreads=(\d+) "
    r"csr=(\d+) seen=(\d+)")
FAIL_RE = re.compile(
    r"CPU_DEBUG_QUEUE_FAIL origin=(\d+) delay=(\d+) priv=(\d+) stage=(\d+) "
    r"reason=(\S+) cycles=(\d+) writes=(\d+) reads=(\d+) dwrites=(\d+) "
    r"dreads=(\d+) csr=(\d+) seen=(\d+)")
PLAN_REL = "cpu_origin_plan.json"
DRIVER_REL = "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_queue.sv"
INTERP_REL = "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_queue_interpreter.sv"
NETLIST_REL = "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_netlist.sv"
PROGRAM_REL = "verif/tb/storamic/g6lc_cpu_debug_program.py"
ENCODER_REL = "verif/tb/storamic/g6lc_cpu_origin_program.py"
VLT_REL = "verif/tb/storamic/origin_cache.vlt"
STUB_REL = "verif/tb/apu/g6lc_dram_peek64_stub.cpp"
LSU_REL = "core/load_store_unit.sv"
LSU_OLD = "ld_st_priv_lvl_i, ld_st_v_i, debug_mode_i);"
LSU_NEW = "ld_st_priv_lvl_i, ld_st_v_i, 1'b0);"
HOLD_CYCLES = 192
SIM_TIMEOUT = 300
BUILD_TIMEOUT = 2400
# Implemented HoldStage coverage: 1 unaccepted AW, 2 accepted AW/held W,
# 3 held B. HoldStage 4/5 (load AR / held R) are not yet implemented.
STAGES = (1, 2, 3)


def _sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _images(program, cache, priv):
    if priv not in cache:
        normal, debug = program.build_debug_program(priv)
        cache[priv] = {"normal": normal, "debug": debug,
                       "program_sha256": hashlib.sha256(normal).hexdigest(),
                       "debug_sha256": hashlib.sha256(debug).hexdigest()}
    return cache[priv]


def _case(origin, delay, priv, stage, negative=0, mutant=0):
    return {"origin": origin, "delay": delay, "priv": priv, "stage": stage,
            "negative": negative, "mutant": mutant}


def _case_list():
    cases = []
    # priv=M: stage x origin x delay positives.
    for stage in STAGES:
        for origin in (0, 1):
            for delay in (0, 16):
                cases.append(_case(origin, delay, 3, stage))
    # priv=M: Negative oracle on each stage at delay16, both origins.
    for stage in STAGES:
        for origin in (0, 1):
            cases.append(_case(origin, 16, 3, stage, negative=1))
    # priv=U/S coverage on stage 3, origin on, delay16.
    for priv in (0, 1):
        cases.append(_case(1, 16, priv, 3))
    # LSU debug-ignore mutant on stage 2 (priv=M, origin on, delay16).
    cases.append(_case(1, 16, 3, 2, mutant=1))
    return cases


def run(data, out, stages, manifest, builds, outcomes, verilator, build_model):
    if "cpu-debug-queue" not in stages:
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
        "g6lc_cpu_debug_program", data / Path(PROGRAM_REL).name)
    program = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(program)
    from run_cpu_origin import _build_env, _model_identity
    env = _build_env(manifest)
    images = {}
    for case in _case_list():
        _images(program, images, case["priv"])
    manifest["cpu_debug_queue"] = {
        "plan": PLAN_REL,
        "files": len(plan["files"]),
        "support_files": len(plan.get("support_files", [])),
        "driver_sha256": _sha(tree / DRIVER_REL),
        "interpreter_sha256": _sha(tree / INTERP_REL),
        "netlist_sha256": _sha(tree / NETLIST_REL),
        "program_runner_sha256": _sha(data / Path(PROGRAM_REL).name),
        "encoder_sha256": _sha(data / Path(ENCODER_REL).name),
        "hold_cycles": HOLD_CYCLES,
        "hold_stages": list(STAGES),
        "hold_stages_pending": [4, 5],
        "images": {str(priv): {
            "entry_privilege": priv,
            "program_sha256": img["program_sha256"],
            "debug_sha256": img["debug_sha256"]}
            for priv, img in sorted(images.items())},
        "mutant": {"file": LSU_REL, "old": LSU_OLD, "new": LSU_NEW},
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))
    lsu_path = tree / LSU_REL
    lsu_pristine = lsu_path.read_bytes()

    def build_and_run(case):
        origin, delay, priv, stage = (case["origin"], case["delay"],
                                      case["priv"], case["stage"])
        negative = case["negative"]
        mutant = case["mutant"]
        label = f"cpu-dbgq-o{origin}-d{delay}-p{priv}-s{stage}"
        if negative:
            label += "-n"
        if mutant:
            label += "-x1"
        model = out / ("model-" + label)
        model.mkdir()
        img = _images(program, images, priv)
        (model / "program.hex").write_bytes(img["normal"])
        (model / "debug.hex").write_bytes(img["debug"])
        command = [str(verilator), "--binary", "--timing", "--assert",
                   "--threads", "1", "-Wno-fatal",
                   "--top-module", "tb_g6lc_storamic_cpu_debug_queue",
                   f"-GOriginEnabled={origin}", f"-GResponseDelay={delay}",
                   f"-GNegative={int(negative)}",
                   f"-GEntryPrivilege={priv}", f"-GHoldStage={stage}",
                   f"-GHoldCycles={HOLD_CYCLES}",
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
                      {"cpu_debug_queue": label, "mutant": mutant,
                       "seconds": seconds,
                       "log_sha256": _sha(out / (label + "-build.log"))})
        outcomes.append({"cpu_debug_queue": label + "-build", "origin": origin,
                         "delay": delay, "priv": priv, "stage": stage,
                         "negative": negative, "mutant": mutant,
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
            "cpu_debug_queue": label, "origin": origin, "delay": delay,
            "priv": priv, "stage": stage, "negative": negative,
            "mutant": mutant, "rc": rc,
            "pass_marker": pass_match.group(0) if pass_match else None,
            "fail_marker": fail_match.group(0) if fail_match else None,
            "program_sha256": img["program_sha256"],
            "debug_sha256": img["debug_sha256"],
            "log_sha256": _sha(out / (label + ".log")),
        }
        if mutant:
            # LSU ignores debug_mode: debugger accesses carry the firmware
            # origin -> debug-origin-failed, no pass marker.
            ok = (rc != 0 and not pass_matches and len(fail_matches) == 1 and
                  fail_match and fail_match.group(6) == "debug-origin-failed")
        elif negative:
            # Negative=1 forces a wrong debug-origin expectation on Probe+8:
            # must reject debug-origin-failed and emit no pass marker.
            ok = (rc != 0 and not pass_matches and len(fail_matches) == 1 and
                  fail_match and fail_match.group(6) == "debug-origin-failed")
        else:
            ok = (rc == 0 and len(pass_matches) == 1 and pass_match and
                  not fail_matches and
                  int(pass_match.group(1)) == origin and
                  int(pass_match.group(2)) == delay and
                  int(pass_match.group(3)) == priv and
                  int(pass_match.group(4)) == stage and
                  int(pass_match.group(6)) == 6 and   # writes
                  int(pass_match.group(7)) == 4 and   # reads
                  int(pass_match.group(8)) == 3 and   # debug writes
                  int(pass_match.group(9)) == 2 and   # debug reads
                  int(pass_match.group(10)) == 2 and  # csr
                  int(pass_match.group(11)) == 1)     # debug seen
        record["pass"] = bool(ok)
        outcomes.append(record)

    pristine_cases = [c for c in _case_list() if not c["mutant"]]
    mutant_cases = [c for c in _case_list() if c["mutant"]]
    for case in pristine_cases:
        build_and_run(case)
    if mutant_cases:
        lsu_text = lsu_pristine.decode("utf-8")
        if lsu_text.count(LSU_OLD) != 1:
            raise RuntimeError("CPU_DEBUG_QUEUE_MUTATION_INVENTORY")
        lsu_path.write_text(lsu_text.replace(LSU_OLD, LSU_NEW))
        manifest["cpu_debug_queue"]["mutant"].update({
            "applied_sha256": _sha(lsu_path)})
        (out / "manifest.json").write_text(json.dumps(manifest, indent=2))
        try:
            for case in mutant_cases:
                build_and_run(case)
        finally:
            lsu_path.write_bytes(lsu_pristine)
            for record in builds:
                if not record.get("mutant"):
                    continue
                exe = Path(record["executable"])
                record["files"] = _model_identity(exe.parent, exe,
                                                  manifest)["files"]
    rejected = [record["cpu_debug_queue"] for record in outcomes
                if record.get("pass") is False]
    if rejected:
        raise RuntimeError("cpu-debug-queue verdicts failed: " +
                           ", ".join(rejected))
