# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""cpu-debug regression: real-core external-debug + MPRV corner.

Promoted from the cpu43/cpu45 leaf evidence. Reuses the frozen cpu-36 source
closure (cpu_origin_plan.json), builds tb_g6lc_storamic_cpu_debug (a thin
self-terminating driver over g6lc_storamic_cpu_debug_interpreter and
_g6lc_storamic_cpu_debug_netlist), generates first-party RV64I firmware via
g6lc_cpu_debug_program.build_debug_program, and checks CPU_DEBUG_PASS markers
for the EntryPrivilege/Mprv matrix plus Negative and load_store_unit mutants."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

PASS_RE = re.compile(
    r"CPU_DEBUG_PASS origin=(\d+) delay=(\d+) priv=(\d+) mprv=(\d+) "
    r"cycles=(\d+) writes=(\d+) reads=(\d+) dwrites=(\d+) dreads=(\d+) "
    r"csr=(\d+) seen=(\d+)")
FAIL_RE = re.compile(
    r"CPU_DEBUG_FAIL origin=(\d+) delay=(\d+) priv=(\d+) mprv=(\d+) "
    r"reason=(\S+) cycles=(\d+) writes=(\d+) reads=(\d+) dwrites=(\d+) "
    r"dreads=(\d+) csr=(\d+) seen=(\d+)")
PLAN_REL = "cpu_origin_plan.json"
DRIVER_REL = "verif/tb/storamic/tb_g6lc_storamic_cpu_debug.sv"
INTERP_REL = "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_interpreter.sv"
NETLIST_REL = "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_netlist.sv"
PROGRAM_REL = "verif/tb/storamic/g6lc_cpu_debug_program.py"
ENCODER_REL = "verif/tb/storamic/g6lc_cpu_origin_program.py"
VLT_REL = "verif/tb/storamic/origin_cache.vlt"
STUB_REL = "verif/tb/apu/g6lc_dram_peek64_stub.cpp"
LSU_REL = "core/load_store_unit.sv"
LSU_OLD = "ld_st_priv_lvl_i, ld_st_v_i, debug_mode_i);"
LSU_NEW = "ld_st_priv_lvl_i, ld_st_v_i, 1'b0);"
# The committed interpreter instantiates the netlist without forwarding
# OriginEnabled (tb_g6lc_storamic_cpu_debug_interpreter.sv:95); the prior
# Yosys flow parameterized cpu.il separately, but a single-shot Verilator
# build needs the forwarding or every OriginEnabled=0 case fails spuriously.
# Applied to the remote tree copy only; committed sources stay untouched and
# both hashes are recorded in the manifest.
INTERP_OLD = "g6lc_storamic_cpu_debug_netlist cpu ("
INTERP_NEW = ("g6lc_storamic_cpu_debug_netlist #(.OriginEnabled(OriginEnabled)) "
              "cpu (")
SIM_TIMEOUT = 300
BUILD_TIMEOUT = 2400
CYCLE_LIMIT = 200000


def _sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _images(program, cache, priv, mprv):
    key = (priv, mprv)
    if key not in cache:
        normal, debug = program.build_debug_program(priv, mprv)
        cache[key] = {"normal": normal, "debug": debug,
                      "program_sha256": hashlib.sha256(normal).hexdigest(),
                      "debug_sha256": hashlib.sha256(debug).hexdigest()}
    return cache[key]


def _case_list():
    cases = []
    for origin in (0, 1):
        for delay in (0, 16):
            for priv, mprv in ((0, 0), (1, 0), (3, 0), (3, 1), (3, 2)):
                cases.append({"origin": origin, "delay": delay, "priv": priv,
                              "mprv": mprv, "negative": 0, "mutant": 0})
    for mprv in (0, 2):
        cases.append({"origin": 1, "delay": 0, "priv": 3, "mprv": mprv,
                      "negative": 1, "mutant": 0})
    for mprv in (0, 1, 2):
        cases.append({"origin": 1, "delay": 0, "priv": 3, "mprv": mprv,
                      "negative": 0, "mutant": 1})
    return cases


def run(data, out, stages, manifest, builds, outcomes, verilator, build_model):
    if "cpu-debug" not in stages:
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
        _images(program, images, case["priv"], case["mprv"])
    manifest["cpu_debug"] = {
        "plan": PLAN_REL,
        "files": len(plan["files"]),
        "support_files": len(plan.get("support_files", [])),
        "driver_sha256": _sha(tree / DRIVER_REL),
        "interpreter_sha256": _sha(tree / INTERP_REL),
        "netlist_sha256": _sha(tree / NETLIST_REL),
        "program_runner_sha256": _sha(data / Path(PROGRAM_REL).name),
        "encoder_sha256": _sha(data / Path(ENCODER_REL).name),
        "images": {f"{priv}-{mprv}": {
            "entry_privilege": priv, "mprv": mprv,
            "program_sha256": img["program_sha256"],
            "debug_sha256": img["debug_sha256"]}
            for (priv, mprv), img in sorted(images.items())},
        "mutant": {"file": LSU_REL, "old": LSU_OLD, "new": LSU_NEW},
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))
    interp_path = tree / INTERP_REL
    interp_text = interp_path.read_text(encoding="utf-8")
    if interp_text.count(INTERP_OLD) != 1:
        raise RuntimeError("CPU_DEBUG_INTERPRETER_PATCH_INVENTORY")
    interp_path.write_text(
        interp_text.replace(INTERP_OLD, INTERP_NEW), encoding="utf-8")
    manifest["cpu_debug"]["interpreter_patched_sha256"] = _sha(interp_path)
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))
    lsu_path = tree / LSU_REL
    lsu_pristine = lsu_path.read_bytes()

    def build_and_run(case):
        origin, delay, priv, mprv = (case["origin"], case["delay"],
                                     case["priv"], case["mprv"])
        negative, mutant = case["negative"], case["mutant"]
        label = (f"cpu-debug-o{origin}-d{delay}-p{priv}-m{mprv}"
                 f"-n{negative}-x{mutant}")
        model = out / ("model-" + label)
        model.mkdir()
        img = _images(program, images, priv, mprv)
        (model / "program.hex").write_bytes(img["normal"])
        (model / "debug.hex").write_bytes(img["debug"])
        command = [str(verilator), "--binary", "--timing", "--assert",
                   "--threads", "1", "-Wno-fatal",
                   "--top-module", "tb_g6lc_storamic_cpu_debug",
                   f"-GOriginEnabled={origin}", f"-GResponseDelay={delay}",
                   f"-GNegative={negative}", f"-GEntryPrivilege={priv}",
                   f"-GMprv={mprv}",
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
                      {"cpu_debug": label, "seconds": seconds,
                       "log_sha256": _sha(out / (label + "-build.log"))})
        outcomes.append({"cpu_debug": label + "-build", "origin": origin,
                         "delay": delay, "priv": priv, "mprv": mprv,
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
            "cpu_debug": label, "origin": origin, "delay": delay,
            "priv": priv, "mprv": mprv, "negative": negative,
            "mutant": mutant, "rc": rc,
            "pass_marker": pass_match.group(0) if pass_match else None,
            "fail_marker": fail_match.group(0) if fail_match else None,
            "program_sha256": img["program_sha256"],
            "debug_sha256": img["debug_sha256"],
            "log_sha256": _sha(out / (label + ".log")),
        }
        if negative or mutant:
            ok = (rc != 0 and not pass_matches and len(fail_matches) == 1 and
                  fail_match and fail_match.group(5) == "debug-origin-failed")
        else:
            ok = (rc == 0 and len(pass_matches) == 1 and pass_match and
                  not fail_matches and
                  int(pass_match.group(1)) == origin and
                  int(pass_match.group(2)) == delay and
                  int(pass_match.group(3)) == priv and
                  int(pass_match.group(4)) == mprv and
                  int(pass_match.group(6)) == 6 and
                  int(pass_match.group(7)) == 4 and
                  int(pass_match.group(8)) == 3 and
                  int(pass_match.group(9)) == 2 and
                  int(pass_match.group(10)) == 2 and
                  int(pass_match.group(11)) == 1)
        record["pass"] = bool(ok)
        outcomes.append(record)
        if not ok:
            raise RuntimeError(f"{label}: verdict rc={rc}")

    cases = _case_list()
    pristine_cases = [c for c in cases if not c["mutant"]]
    mutant_cases = [c for c in cases if c["mutant"]]
    for case in pristine_cases:
        build_and_run(case)
    lsu_text = lsu_pristine.decode("utf-8")
    if lsu_text.count(LSU_OLD) != 1:
        raise RuntimeError("CPU_DEBUG_MUTATION_INVENTORY")
    lsu_path.write_text(lsu_text.replace(LSU_OLD, LSU_NEW))
    manifest["cpu_debug"]["mutant"].update({
        "applied_sha256": _sha(lsu_path)})
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))
    try:
        for case in mutant_cases:
            build_and_run(case)
    finally:
        lsu_path.write_bytes(lsu_pristine)
        # Mutant builds recorded the mutated load_store_unit.sv hash in their
        # dependency identities; run_leaf re-verifies every recorded input
        # after the stage, so refresh those entries to the restored bytes.
        # The mutated hash stays recorded in manifest.cpu_debug.mutant.
        for record in builds:
            if not record.get("cpu_debug", "").endswith("-x1"):
                continue
            exe = Path(record["executable"])
            record["files"] = _model_identity(exe.parent, exe, manifest)["files"]
