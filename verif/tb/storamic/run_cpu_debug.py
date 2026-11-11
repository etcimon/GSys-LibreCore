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
# The committed interpreter forwards OriginEnabled to the netlist
# (tb_g6lc_storamic_cpu_debug_interpreter.sv), so a single-shot Verilator
# build runs every OriginEnabled=0 case with origin genuinely off; no remote
# patch is applied and interpreter_sha256 is the only interpreter identity.
SIM_TIMEOUT = 300
BUILD_TIMEOUT = 2400
CYCLE_LIMIT = 200000
MECHANISM_NAMES = {0: "halt", 1: "ebreak", 2: "step"}
# Expected probe counters per mechanism: writes, reads, debug writes,
# debug reads, csr checks (halt unchanged; ebreak/step add the Probe+48
# firmware store, the Probe+56 second-entry record and one csr check).
MECHANISM_COUNTS = {0: (6, 4, 3, 2, 2), 1: (8, 4, 4, 2, 3), 2: (8, 4, 4, 2, 3)}
# CSRRS x0,dcsr,x7 emitted once by the mechanism images to arm the
# mechanism; the program-level oracle NOPs exactly this word.
ARM_CSRRS_WORD = 0x7b03a073
NOP_WORD = 0x00000013
# cpu-debug-stq-mutant: review mutation in core/store_buffer.sv that drops
# the commit-queue push when commit_i coincides with flush_i — the exact
# defect the CPU49b assertion guards against.
STQ_DEFINE = "+define+G6LC_MUT_STQ_COMMIT_DROPPED_ON_FLUSH"
STQ_ASSERT_MSG = "a store retired with a flush did not reach the commit queue"


def _sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _images(program, cache, priv, mprv, mechanism):
    key = (priv, mprv, mechanism)
    if key not in cache:
        normal, debug = program.build_debug_program(
            priv, mprv, MECHANISM_NAMES[mechanism])
        cache[key] = {"normal": normal, "debug": debug,
                      "program_sha256": hashlib.sha256(normal).hexdigest(),
                      "debug_sha256": hashlib.sha256(debug).hexdigest()}
    return cache[key]


def _case(origin, delay, priv, mprv, mechanism=0, negative=0,
          negative_firmware=0, mutant=0, program_mutant=0):
    return {"origin": origin, "delay": delay, "priv": priv, "mprv": mprv,
            "mechanism": mechanism, "negative": negative,
            "negative_firmware": negative_firmware, "mutant": mutant,
            "program_mutant": program_mutant}


def _case_list():
    cases = []
    for origin in (0, 1):
        for delay in (0, 16):
            for priv, mprv in ((0, 0), (1, 0), (3, 0), (3, 1), (3, 2)):
                cases.append(_case(origin, delay, priv, mprv))
    for mprv in (0, 2):
        cases.append(_case(1, 0, 3, mprv, negative=1))
    for mprv in (0, 1, 2):
        cases.append(_case(1, 0, 3, mprv, mutant=1))
    # ebreak/step positives: U and M entries (mprv=0) x origins x delays.
    for mechanism in (1, 2):
        for priv in (0, 3):
            for origin in (0, 1):
                for delay in (0, 16):
                    cases.append(_case(origin, delay, priv, 0,
                                       mechanism=mechanism))
    # Mechanism negatives, M entry, origin enabled, no delay.
    for mechanism in (1, 2):
        cases.append(_case(1, 0, 3, 0, mechanism=mechanism, negative=1))
        cases.append(_case(1, 0, 3, 0, mechanism=mechanism,
                           negative_firmware=1))
        cases.append(_case(1, 0, 3, 0, mechanism=mechanism, mutant=1))
    # Program-level oracle: the step image with the arm CSRRS NOP'd never
    # re-enters debug after the Probe+48 store, so the run must reject.
    cases.append(_case(1, 0, 3, 0, mechanism=2, program_mutant=1))
    return cases


def run(data, out, stages, manifest, builds, outcomes, verilator, build_model):
    run_debug = "cpu-debug" in stages
    run_stq = "cpu-debug-stq-mutant" in stages
    if not (run_debug or run_stq):
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
        _images(program, images, case["priv"], case["mprv"],
                case["mechanism"])
    manifest["cpu_debug"] = {
        "plan": PLAN_REL,
        "files": len(plan["files"]),
        "support_files": len(plan.get("support_files", [])),
        "driver_sha256": _sha(tree / DRIVER_REL),
        "interpreter_sha256": _sha(tree / INTERP_REL),
        "netlist_sha256": _sha(tree / NETLIST_REL),
        "program_runner_sha256": _sha(data / Path(PROGRAM_REL).name),
        "encoder_sha256": _sha(data / Path(ENCODER_REL).name),
        "images": {f"{priv}-{mprv}-{MECHANISM_NAMES[mechanism]}": {
            "entry_privilege": priv, "mprv": mprv,
            "mechanism": MECHANISM_NAMES[mechanism],
            "program_sha256": img["program_sha256"],
            "debug_sha256": img["debug_sha256"]}
            for (priv, mprv, mechanism), img in sorted(images.items())},
        "mutant": {"file": LSU_REL, "old": LSU_OLD, "new": LSU_NEW},
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))
    lsu_path = tree / LSU_REL
    lsu_pristine = lsu_path.read_bytes()

    def build_and_run(case):
        origin, delay = case["origin"], case["delay"]
        priv, mprv = case["priv"], case["mprv"]
        mechanism = case["mechanism"]
        negative = case["negative"]
        negative_firmware = case["negative_firmware"]
        mutant = case["mutant"]
        program_mutant = case["program_mutant"]
        stq_mutant = case.get("stq", 0)
        label = (f"cpu-debug-o{origin}-d{delay}-p{priv}-m{mprv}"
                 f"-n{negative}-x{mutant}")
        if mechanism:
            label += f"-g{mechanism}"
        if negative_firmware:
            label += "-fw"
        if program_mutant:
            label += "-pm"
        if stq_mutant:
            label += "-stq"
        model = out / ("model-" + label)
        model.mkdir()
        img = _images(program, images, priv, mprv, mechanism)
        debug_image = img["debug"]
        patched_debug_sha = None
        if program_mutant:
            # Program-level oracle: NOP the single CSRRS that arms dcsr.step
            # so the CPU resumes at the firmware target without re-entering.
            words = [int(word, 16) for word in
                     debug_image.decode("ascii").split()]
            slots = [index for index, word in enumerate(words)
                     if word == ARM_CSRRS_WORD]
            if len(slots) != 1:
                raise RuntimeError(f"{label}: program-mutant inventory {slots}")
            words[slots[0]] = NOP_WORD
            debug_image = "".join(f"{word:08x}\n" for word in words).encode("ascii")
            patched_debug_sha = hashlib.sha256(debug_image).hexdigest()
        (model / "program.hex").write_bytes(img["normal"])
        (model / "debug.hex").write_bytes(debug_image)
        command = [str(verilator), "--binary", "--timing", "--assert",
                   "--threads", "1", "-Wno-fatal",
                   "--top-module", "tb_g6lc_storamic_cpu_debug",
                   f"-GOriginEnabled={origin}", f"-GResponseDelay={delay}",
                   f"-GNegative={negative}", f"-GEntryPrivilege={priv}",
                   f"-GMprv={mprv}", f"-GMechanism={mechanism}",
                   f"-GNegativeFirmware={int(negative_firmware)}",
                   "--Mdir", str(model), "-o", "test",
                   "--exe", str(data / Path(STUB_REL).name),
                   str(data / Path(VLT_REL).name),
                   *["-I" + str(tree / d) for d in plan["incdirs"]],
                   *plan["defines"],
                   *([STQ_DEFINE] if stq_mutant else []),
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
                      {"cpu_debug": label, "mutant": mutant,
                       "seconds": seconds,
                       "log_sha256": _sha(out / (label + "-build.log"))})
        outcomes.append({"cpu_debug": label + "-build", "origin": origin,
                         "delay": delay, "priv": priv, "mprv": mprv,
                         "mechanism": mechanism, "negative": negative,
                         "negative_firmware": negative_firmware,
                         "mutant": mutant, "program_mutant": program_mutant,
                         "stq_mutant": stq_mutant,
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
            "priv": priv, "mprv": mprv, "mechanism": mechanism,
            "mechanism_name": MECHANISM_NAMES[mechanism],
            "negative": negative, "negative_firmware": negative_firmware,
            "mutant": mutant, "program_mutant": program_mutant,
            "stq_mutant": stq_mutant, "rc": rc,
            "pass_marker": pass_match.group(0) if pass_match else None,
            "fail_marker": fail_match.group(0) if fail_match else None,
            "program_sha256": img["program_sha256"],
            "debug_sha256": (patched_debug_sha if patched_debug_sha
                             else img["debug_sha256"]),
            "log_sha256": _sha(out / (label + ".log")),
        }
        if negative or mutant:
            ok = (rc != 0 and not pass_matches and len(fail_matches) == 1 and
                  fail_match and fail_match.group(5) == "debug-origin-failed")
        elif negative_firmware:
            # The Probe+48 firmware store is expected with origin 000; an
            # enabled run sees the real origin and must fail, not origin-fail.
            ok = (rc != 0 and not pass_matches and len(fail_matches) == 1 and
                  fail_match and fail_match.group(5) == "failed")
        elif program_mutant:
            # The NOP'd step arm never re-enters debug: counts/deadline fail.
            ok = (rc != 0 and not pass_matches and
                  ((fail_match and fail_match.group(5) in ("failed", "timeout")) or
                   (not fail_match and "TIMEOUT" in text)))
        elif stq_mutant:
            # The commit-queue push is dropped on coincident commit+flush:
            # every step-on-store case must be rejected — by the
            # commit_and_flush_keeps_head assertion or by wrong memory/origin
            # evidence — and must never emit a pass marker.
            ok = (rc != 0 and not pass_matches and
                  (STQ_ASSERT_MSG in text or
                   (fail_match and fail_match.group(5) in
                    ("failed", "timeout", "debug-origin-failed")) or
                   (not fail_match and "TIMEOUT" in text)))
        else:
            ew, er, dw, dr, csr = MECHANISM_COUNTS[mechanism]
            ok = (rc == 0 and len(pass_matches) == 1 and pass_match and
                  not fail_matches and
                  int(pass_match.group(1)) == origin and
                  int(pass_match.group(2)) == delay and
                  int(pass_match.group(3)) == priv and
                  int(pass_match.group(4)) == mprv and
                  int(pass_match.group(6)) == ew and
                  int(pass_match.group(7)) == er and
                  int(pass_match.group(8)) == dw and
                  int(pass_match.group(9)) == dr and
                  int(pass_match.group(10)) == csr and
                  int(pass_match.group(11)) == 1)
        record["pass"] = bool(ok)
        outcomes.append(record)

    cases = _case_list() if run_debug else []
    # cpu-debug-stq-mutant: only the step-on-store positives exercise
    # coincident commit+flush; they carry the store_buffer review define.
    stq_cases = [dict(c, stq=1) for c in _case_list()
                 if c["mechanism"] == 2 and not c["negative"]
                 and not c["negative_firmware"] and not c["mutant"]
                 and not c["program_mutant"]] if run_stq else []
    pristine_cases = [c for c in cases if not c["mutant"]]
    mutant_cases = [c for c in cases if c["mutant"]]
    for case in pristine_cases:
        build_and_run(case)
    if mutant_cases:
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
            # Mutant builds recorded the mutated load_store_unit.sv hash in
            # their dependency identities; run_leaf re-verifies every
            # recorded input after the stage, so refresh those entries to
            # the restored bytes. The mutated hash stays recorded in
            # manifest.cpu_debug.mutant.
            for record in builds:
                if not record.get("mutant"):
                    continue
                exe = Path(record["executable"])
                record["files"] = _model_identity(exe.parent, exe,
                                                  manifest)["files"]
    for case in stq_cases:
        build_and_run(case)
    # Collect every case verdict before failing so a real-CPU deviation does
    # not hide the rest of the matrix; the stage still reports fail overall.
    rejected = [record["cpu_debug"] for record in outcomes
                if record.get("pass") is False]
    if rejected:
        raise RuntimeError("cpu-debug verdicts failed: " + ", ".join(rejected))
