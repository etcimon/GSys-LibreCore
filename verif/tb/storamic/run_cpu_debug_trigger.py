# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""cpu-debug-trigger regression: real tdata-trigger debug entry.

Builds tb_g6lc_storamic_cpu_debug_trigger (a thin self-terminating driver
over g6lc_storamic_cpu_debug_trigger_interpreter and the shared
_g6lc_storamic_cpu_debug_netlist with Sdtrig=1), generates first-party RV64I
firmware via g6lc_cpu_debug_trigger_program, and checks
CPU_DEBUG_TRIGGER_PASS markers for the mcontrol6 exec/store/load matrix,
the SDTRIG=0 denial profile, and the program/LSU/firmware negatives.
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
    r"CPU_DEBUG_TRIGGER_PASS origin=(\d+) delay=(\d+) priv=(\d+) mech=(\d+) "
    r"cycles=(\d+) writes=(\d+) reads=(\d+) dwrites=(\d+) dreads=(\d+) "
    r"csr=(\d+) seen=(\d+) dpc=([0-9a-f]+) ac=(\d+) e2=(\d+) acnt=(\d+)")
FAIL_RE = re.compile(
    r"CPU_DEBUG_TRIGGER_FAIL origin=(\d+) delay=(\d+) priv=(\d+) mech=(\d+) "
    r"reason=(\S+) cycles=(\d+) writes=(\d+) reads=(\d+) dwrites=(\d+) "
    r"dreads=(\d+) csr=(\d+) seen=(\d+)")
PLAN_REL = "cpu_origin_plan.json"
DRIVER_REL = "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_trigger.sv"
INTERP_REL = "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_trigger_interpreter.sv"
NETLIST_REL = "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_netlist.sv"
PROGRAM_REL = "verif/tb/storamic/g6lc_cpu_debug_trigger_program.py"
ENCODER_REL = "verif/tb/storamic/g6lc_cpu_origin_program.py"
VLT_REL = "verif/tb/storamic/origin_cache.vlt"
STUB_REL = "verif/tb/apu/g6lc_dram_peek64_stub.cpp"
LSU_REL = "core/load_store_unit.sv"
LSU_OLD = "ld_st_priv_lvl_i, ld_st_v_i, debug_mode_i);"
LSU_NEW = "ld_st_priv_lvl_i, ld_st_v_i, 1'b0);"
# mcontrol6 tdata1 arm write: csrw tdata1, x28 = (0x7A1<<20)|(28<<15)|(1<<12)|0x73.
# It is the tdata1 write immediately followed by `addi x28, x10, 0x40` (the
# dpc=T setup); the second-entry disarm write is followed by csrw dpc,x10.
TDATA1_CSR_WORD = (0x7A1 << 20) | (28 << 15) | (1 << 12) | 0x73
DPC_T_SETUP_WORD = (0x40 << 20) | (10 << 15) | (28 << 7) | 0x13
SIM_TIMEOUT = 300
BUILD_TIMEOUT = 2400
# Per-mechanism expected probe counters: writes, reads, debug writes,
# debug reads, csr checks, and whether a debug entry is expected (seen).
MECHANISM_COUNTS = {
    3: (8, 4, 4, 2, 2, 1),   # exec: Probe+48 store always commits -> 8 writes
    4: (None, 4, 4, 2, 2, 1),  # store: Probe+48 write optional (7 or 8)
    5: (7, None, 4, 2, 2, 1),  # load: Probe+52 AR optional (4 or 5 reads)
    6: (4, 0, 0, 0, 0, 0),   # deny: illegal-instruction, no debug entry
}
MECHANISM_NAMES = {3: "exec", 4: "store", 5: "load", 6: "deny"}


def _sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _images(program, cache, priv, mechanism):
    key = (priv, mechanism)
    if key not in cache:
        if mechanism == 6:
            normal, debug = program.build_denial_program(priv)
        else:
            normal, debug = program.build_trigger_program(
                priv, MECHANISM_NAMES[mechanism])
        cache[key] = {"normal": normal, "debug": debug,
                      "program_sha256": hashlib.sha256(normal).hexdigest(),
                      "debug_sha256": hashlib.sha256(debug).hexdigest()}
    return cache[key]


def _case(origin, delay, priv, mechanism, negative=0, negative_firmware=0,
          mutant=0, program_mutant=0):
    return {"origin": origin, "delay": delay, "priv": priv,
            "mechanism": mechanism, "negative": negative,
            "negative_firmware": negative_firmware, "mutant": mutant,
            "program_mutant": program_mutant}


def _case_list():
    cases = []
    # exec (mech 3): U and M x origins x delays.
    for priv in (0, 3):
        for origin in (0, 1):
            for delay in (0, 16):
                cases.append(_case(origin, delay, priv, 3))
    # store (mech 4) and load (mech 5): origin1 x U/M x delay16, plus
    # origin0 x M x delay0.
    for mechanism in (4, 5):
        for priv in (0, 3):
            cases.append(_case(1, 16, priv, mechanism))
        cases.append(_case(0, 0, 3, mechanism))
    # deny (mech 6, SDTRIG=0): M x origins, no delay.
    for origin in (0, 1):
        cases.append(_case(origin, 0, 3, 6))
    # Negatives.
    cases.append(_case(1, 0, 3, 3, program_mutant=1))   # NOP tdata1 arm
    cases.append(_case(1, 0, 3, 3, mutant=1))           # LSU ignores debug
    cases.append(_case(1, 0, 3, 4, negative_firmware=1))  # @48 expects 000
    return cases


def _arm_slot(debug_image):
    """Locate the tdata1 arm write (csrw tdata1,x28) in the debug image: it is
    the one immediately followed by the dpc=T setup `addi x28,x10,0x40`."""
    words = [int(word, 16) for word in debug_image.decode("ascii").split()]
    slots = [index for index in range(len(words) - 1)
             if words[index] == TDATA1_CSR_WORD and
             words[index + 1] == DPC_T_SETUP_WORD]
    if len(slots) != 1:
        raise RuntimeError(f"trigger program-mutant inventory {slots}")
    return words, slots[0]


def run(data, out, stages, manifest, builds, outcomes, verilator, build_model):
    if "cpu-debug-trigger" not in stages:
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
        "g6lc_cpu_debug_trigger_program", data / Path(PROGRAM_REL).name)
    program = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(program)
    from run_cpu_origin import _build_env, _model_identity
    env = _build_env(manifest)
    images = {}
    for case in _case_list():
        _images(program, images, case["priv"], case["mechanism"])
    manifest["cpu_debug_trigger"] = {
        "plan": PLAN_REL,
        "files": len(plan["files"]),
        "support_files": len(plan.get("support_files", [])),
        "driver_sha256": _sha(tree / DRIVER_REL),
        "interpreter_sha256": _sha(tree / INTERP_REL),
        "netlist_sha256": _sha(tree / NETLIST_REL),
        "program_runner_sha256": _sha(data / Path(PROGRAM_REL).name),
        "encoder_sha256": _sha(data / Path(ENCODER_REL).name),
        "sdtrig_parameter": "netlist Sdtrig=1 sets SDTRIG=1,Mcontrol6=1; "
                            "Sdtrig=0 preserves the default profile",
        "images": {f"{priv}-{MECHANISM_NAMES[mechanism]}": {
            "entry_privilege": priv, "mechanism": MECHANISM_NAMES[mechanism],
            "program_sha256": img["program_sha256"],
            "debug_sha256": img["debug_sha256"]}
            for (priv, mechanism), img in sorted(images.items())},
        "mutant": {"file": LSU_REL, "old": LSU_OLD, "new": LSU_NEW},
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))
    lsu_path = tree / LSU_REL
    lsu_pristine = lsu_path.read_bytes()

    def build_and_run(case):
        origin, delay = case["origin"], case["delay"]
        priv, mechanism = case["priv"], case["mechanism"]
        negative_firmware = case["negative_firmware"]
        mutant = case["mutant"]
        program_mutant = case["program_mutant"]
        sdtrig = 0 if mechanism == 6 else 1
        label = (f"cpu-dbgtrig-o{origin}-d{delay}-p{priv}-g{mechanism}"
                 f"-s{sdtrig}")
        if negative_firmware:
            label += "-fw"
        if mutant:
            label += "-x1"
        if program_mutant:
            label += "-pm"
        model = out / ("model-" + label)
        model.mkdir()
        img = _images(program, images, priv, mechanism)
        debug_image = img["debug"]
        patched_debug_sha = None
        if program_mutant:
            words, slot = _arm_slot(debug_image)
            words[slot] = 0x00000013  # NOP the tdata1 arm write
            debug_image = "".join(f"{word:08x}\n" for word in words).encode("ascii")
            patched_debug_sha = hashlib.sha256(debug_image).hexdigest()
        (model / "program.hex").write_bytes(img["normal"])
        (model / "debug.hex").write_bytes(debug_image)
        command = [str(verilator), "--binary", "--timing", "--assert",
                   "--threads", "1", "-Wno-fatal",
                   "--top-module", "tb_g6lc_storamic_cpu_debug_trigger",
                   f"-GOriginEnabled={origin}", f"-GResponseDelay={delay}",
                   f"-GNegative=0", f"-GSdtrig={sdtrig}",
                   f"-GEntryPrivilege={priv}", f"-GMechanism={mechanism}",
                   f"-GNegativeFirmware={int(negative_firmware)}",
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
                      {"cpu_debug_trigger": label, "mutant": mutant,
                       "seconds": seconds,
                       "log_sha256": _sha(out / (label + "-build.log"))})
        outcomes.append({"cpu_debug_trigger": label + "-build", "origin": origin,
                         "delay": delay, "priv": priv, "mechanism": mechanism,
                         "negative_firmware": negative_firmware,
                         "mutant": mutant, "program_mutant": program_mutant,
                         "sdtrig": sdtrig,
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
            "cpu_debug_trigger": label, "origin": origin, "delay": delay,
            "priv": priv, "mechanism": mechanism,
            "mechanism_name": MECHANISM_NAMES[mechanism],
            "negative_firmware": negative_firmware, "mutant": mutant,
            "program_mutant": program_mutant, "sdtrig": sdtrig, "rc": rc,
            "pass_marker": pass_match.group(0) if pass_match else None,
            "fail_marker": fail_match.group(0) if fail_match else None,
            "program_sha256": img["program_sha256"],
            "debug_sha256": (patched_debug_sha if patched_debug_sha
                             else img["debug_sha256"]),
            "log_sha256": _sha(out / (label + ".log")),
        }
        # Observed trigger timing for the report: recorded dpc, the cycle the
        # triggering access was accepted, the second-entry first-fetch cycle,
        # and the access count.
        if pass_match:
            record["observed"] = {
                "dpc": pass_match.group(12),
                "access_cycle": int(pass_match.group(13)),
                "entry2_cycle": int(pass_match.group(14)),
                "access_count": int(pass_match.group(15)),
            }
        if program_mutant:
            # The NOP'd tdata1 arm never fires the trigger: no second entry,
            # so the run must reject `failed` (interpreter deadline) and emit
            # no pass marker.
            ok = (rc != 0 and not pass_matches and
                  ((fail_match and fail_match.group(6) == "failed") or
                   (not fail_match and "TIMEOUT" in text)))
        elif mutant:
            ok = (rc != 0 and not pass_matches and len(fail_matches) == 1 and
                  fail_match and fail_match.group(6) == "debug-origin-failed")
        elif negative_firmware:
            ok = (rc != 0 and not pass_matches and len(fail_matches) == 1 and
                  fail_match and fail_match.group(6) == "failed")
        else:
            ew, er, dw, dr, csr, seen = MECHANISM_COUNTS[mechanism]
            ok = (rc == 0 and len(pass_matches) == 1 and pass_match and
                  not fail_matches and
                  int(pass_match.group(1)) == origin and
                  int(pass_match.group(2)) == delay and
                  int(pass_match.group(3)) == priv and
                  int(pass_match.group(4)) == mechanism and
                  (ew is None or int(pass_match.group(6)) == ew) and
                  (er is None or int(pass_match.group(7)) == er) and
                  int(pass_match.group(8)) == dw and
                  int(pass_match.group(9)) == dr and
                  int(pass_match.group(10)) == csr and
                  int(pass_match.group(11)) == seen)
        record["pass"] = bool(ok)
        outcomes.append(record)

    cases = _case_list()
    pristine_cases = [c for c in cases if not c["mutant"]]
    mutant_cases = [c for c in cases if c["mutant"]]
    for case in pristine_cases:
        build_and_run(case)
    if mutant_cases:
        lsu_text = lsu_pristine.decode("utf-8")
        if lsu_text.count(LSU_OLD) != 1:
            raise RuntimeError("CPU_DEBUG_TRIGGER_MUTATION_INVENTORY")
        lsu_path.write_text(lsu_text.replace(LSU_OLD, LSU_NEW))
        manifest["cpu_debug_trigger"]["mutant"].update({
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
    rejected = [record["cpu_debug_trigger"] for record in outcomes
                if record.get("pass") is False]
    if rejected:
        raise RuntimeError("cpu-debug-trigger verdicts failed: " +
                           ", ".join(rejected))
