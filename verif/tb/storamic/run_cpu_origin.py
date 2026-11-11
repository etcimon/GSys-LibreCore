# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""cpu-origin regression: real-core CSR/origin/protection stage.

Promoted from storamic-cpu43-333f05a1. Builds tb_g6lc_storamic_cpu_origin
against the frozen cpu-36 source closure (cpu_origin_plan.json), generates
the first-party RV64I program via g6lc_cpu_origin_program.build_program,
and checks CPU_ORIGIN_PASS markers (writes=5 reads=4) for OriginEnabled
{0,1} at delay 0/16 plus the aw-prot oracle-negative rejection."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import time

PASS_RE = re.compile(
    r"CPU_ORIGIN_PASS enabled=(\d+) integer=(\d+) delay=(\d+) cycles=(\d+) "
    r"writes=(\d+) reads=(\d+)")
ATOMIC_PASS_RE = re.compile(
    r"CPU_ORIGIN_PASS enabled=(\d+) integer=(\d+) delay=(\d+) cycles=(\d+) "
    r"writes=(\d+) reads=(\d+) awrites=(\d+) areads=(\d+)")
ATOMIC_ORD_W, ATOMIC_ORD_R, ATOMIC_WR, ATOMIC_RD = 11, 8, 6, 2
BENCH_REL = "verif/tb/storamic/tb_g6lc_storamic_cpu_origin.sv"


def _identities(paths):
    return {str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(paths)}


def _build_env(manifest):
    env = dict(os.environ)
    for key in ("MAKEFLAGS", "MFLAGS", "CXX", "CC", "CXXFLAGS", "CFLAGS",
                "CPPFLAGS", "LDFLAGS", "OBJCACHE", "VERILATOR_ROOT", "VPATH"):
        env.pop(key, None)
    runtime = manifest["runtime"]
    if runtime.get("kind") == "g6lc-fork-native":
        env["VERILATOR_ROOT"] = runtime["root"]
    return env


def _model_identity(model, executable, manifest):
    dependencies = set()
    for depfile in model.rglob("*.d"):
        for rule in depfile.read_text().replace("\\\n", "").splitlines():
            if ":" not in rule:
                continue
            for value in shlex.split(rule.split(":", 1)[1]):
                path = Path(value.replace("$$", "$"))
                dependencies.add((path if path.is_absolute()
                                  else model / path).resolve())
    private_header = Path(manifest["runtime"]["root"]) / "include/verilated_funcs.h"
    original_header = (Path(manifest["runtime"]["original_root"]) /
                       "include/verilated_funcs.h")
    if private_header not in dependencies or (
            original_header != private_header and
            original_header in dependencies):
        raise RuntimeError("STORAMIC_COMPILED_RUNTIME_IDENTITY")
    generated = {p for p in model.iterdir() if p.is_file() and
                 p.suffix in {".cpp", ".h", ".mk", ".dat", ".d"}}
    return {"files": _identities(dependencies | generated | {executable}),
            "executable": str(executable), "private_runtime_verified": True}


def run(data, out, stages, manifest, builds, outcomes, verilator, build_model):
    if not ({"cpu-origin", "cpu-origin-unsupported", "cpu-origin-atomic"}
            & set(stages)):
        return
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    plan = json.loads((data / "cpu_origin_plan.json").read_text())
    # data/ uploads are flat by basename; rebuild the repo-relative tree so
    # -I include dirs and `include "axi/typedef.svh"` resolve as committed.
    tree = out / "cpu-src"
    closure = plan["files"] + plan.get("support_files", [])
    for rel in closure + [BENCH_REL]:
        dst = tree / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(data / Path(rel).name, dst)
    spec = importlib.util.spec_from_file_location(
        "g6lc_cpu_origin_program", data / "g6lc_cpu_origin_program.py")
    program = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(program)
    rom = out / "program.hex"
    rom.write_bytes(program.build_program(False))
    manifest["cpu_origin"] = {
        "plan": "cpu_origin_plan.json",
        "files": len(plan["files"]),
        "support_files": len(plan.get("support_files", [])),
        "program_sha256": sha(rom),
        "bench_sha256": sha(tree / BENCH_REL),
    }
    env = _build_env(manifest)
    for enabled in ((0, 1) if "cpu-origin" in stages else ()):
        label = f"cpu-origin-enabled{enabled}"
        model = out / ("model-" + label)
        model.mkdir()
        command = [str(verilator), "--binary", "--timing", "--assert",
                   "--threads", "1", "-Wno-fatal",
                   "--top-module", "tb_g6lc_storamic_cpu_origin",
                   f"-GOriginEnabled={enabled}", "-GIntegerDiagnostic=0",
                   "--Mdir", str(model), "-o", "test",
                   "--exe", str(data / "g6lc_dram_peek64_stub.cpp"),
                   str(data / "origin_cache.vlt"),
                   *["-I" + str(tree / d) for d in plan["incdirs"]],
                   *plan["defines"],
                   *[str(tree / f) for f in plan["files"]],
                   str(tree / BENCH_REL)]
        command += manifest["runtime"].get("verilator_options", [])
        (out / (label + "-command.json")).write_text(json.dumps(command))
        started = time.monotonic()
        with (out / (label + "-build.log")).open("w") as log:
            try:
                subprocess.run(command, env=env, cwd=model, stdout=log,
                               stderr=subprocess.STDOUT, check=True,
                               timeout=2400)
            except (subprocess.SubprocessError, subprocess.TimeoutExpired) as e:
                raise RuntimeError(f"{label}: build failed: {e}")
        seconds = round(time.monotonic() - started, 1)
        executable = model / "test"
        builds.append(_model_identity(model, executable, manifest) |
                      {"cpu_origin": label, "seconds": seconds,
                       "log_sha256": sha(out / (label + "-build.log"))})
        outcomes.append({"cpu_origin": label + "-build", "origin": enabled,
                         "seconds": seconds,
                         "executable": str(executable), "pass": True})
        for delay, bad in ((0, False), (16, False), (16, True)):
            case = f"{label}-delay{delay}-bad{int(bad)}"
            args = [str(executable), f"+rom={rom}", f"+delay={delay}"]
            if bad:
                args.append("+oracle_negative")
            try:
                result = subprocess.run(args, env=env, cwd=model,
                                        capture_output=True, text=True,
                                        timeout=300)
                text = result.stdout + result.stderr
                rc = result.returncode
            except subprocess.TimeoutExpired:
                text, rc = "TIMEOUT", None
            (out / (case + ".log")).write_text(text)
            pass_matches = PASS_RE.findall(text)
            pass_match = PASS_RE.search(text)
            if bad:
                ok = (rc != 0 and "CPU_ORIGIN_FAIL aw-prot" in text
                      and not pass_matches)
            else:
                ok = (rc == 0 and len(pass_matches) == 1 and pass_match and
                      int(pass_match.group(5)) == 5 and
                      int(pass_match.group(6)) == 4)
            outcomes.append({
                "cpu_origin": case, "origin": enabled, "delay": delay,
                "oracle_negative": bad, "rc": rc,
                "pass_marker": pass_match.group(0) if pass_match else None,
                "writes": int(pass_match.group(5)) if pass_match else None,
                "reads": int(pass_match.group(6)) if pass_match else None,
                "log_sha256": sha(out / (case + ".log")), "pass": bool(ok)})
            if not ok:
                raise RuntimeError(f"{case}: verdict rc={rc}")
    if "cpu-origin-unsupported" in stages:
        # cpu-origin-unsupported is a best-effort variant: an RVH=1
        # elaboration/runtime failure is reported as evidence (manifest +
        # pass=False outcome) rather than crashing sibling stages.
        label = "cpu-origin-unsupported"
        model = out / ("model-" + label)
        model.mkdir()
        command = [str(verilator), "--binary", "--timing", "--assert",
                   "--threads", "1", "-Wno-fatal",
                   "--top-module", "tb_g6lc_storamic_cpu_origin",
                   "-GOriginEnabled=1", "-GUnsupportedProfile=1",
                   "-GIntegerDiagnostic=0",
                   "--Mdir", str(model), "-o", "test",
                   "--exe", str(data / "g6lc_dram_peek64_stub.cpp"),
                   str(data / "origin_cache.vlt"),
                   *["-I" + str(tree / d) for d in plan["incdirs"]],
                   *plan["defines"],
                   *[str(tree / f) for f in plan["files"]],
                   str(tree / BENCH_REL)]
        command += manifest["runtime"].get("verilator_options", [])
        (out / (label + "-command.json")).write_text(json.dumps(command))
        unsupported_error = None
        started = time.monotonic()
        try:
            with (out / (label + "-build.log")).open("w") as log:
                subprocess.run(command, env=env, cwd=model, stdout=log,
                               stderr=subprocess.STDOUT, check=True,
                               timeout=2400)
        except (subprocess.SubprocessError, subprocess.TimeoutExpired) as e:
            unsupported_error = f"{label}: build failed: {e}"
        seconds = round(time.monotonic() - started, 1)
        manifest["cpu_origin_unsupported"] = {
            "bench_parameters": {"OriginEnabled": 1, "UnsupportedProfile": 1,
                                 "IntegerDiagnostic": 0},
            "effective_config": {"RVH": 1, "StoramicEn": 1, "StoramicIoEn": 1,
                                 "StoramicCheckpointEn": 1, "NrHarts": 1,
                                 "g6lc_storamic_origin_supported": False},
            "oracle": "writes=5 reads=4 and every data AW/AR prot==000",
            "negative": "+expect_supported must reject aw-prot/ar-prot",
        }
        if unsupported_error is None:
            executable = model / "test"
            builds.append(_model_identity(model, executable, manifest) |
                          {"cpu_origin": label, "seconds": seconds,
                           "log_sha256": sha(out / (label + "-build.log"))})
            outcomes.append({"cpu_origin": label + "-build",
                             "origin": "unsupported", "seconds": seconds,
                             "executable": str(executable), "pass": True})
            case_failures = []
            for delay in (0, 16):
                case = f"{label}-delay{delay}"
                args = [str(executable), f"+rom={rom}", f"+delay={delay}"]
                try:
                    result = subprocess.run(args, env=env, cwd=model,
                                            capture_output=True, text=True,
                                            timeout=300)
                    text = result.stdout + result.stderr
                    rc = result.returncode
                except subprocess.TimeoutExpired:
                    text, rc = "TIMEOUT", None
                (out / (case + ".log")).write_text(text)
                pass_match = PASS_RE.search(text)
                ok = (rc == 0 and pass_match and
                      int(pass_match.group(5)) == 5 and
                      int(pass_match.group(6)) == 4)
                outcomes.append({
                    "cpu_origin": case, "origin": "unsupported",
                    "delay": delay, "oracle_negative": False, "rc": rc,
                    "pass_marker": pass_match.group(0) if pass_match else None,
                    "writes": (int(pass_match.group(5))
                               if pass_match else None),
                    "reads": (int(pass_match.group(6))
                              if pass_match else None),
                    "log_sha256": sha(out / (case + ".log")),
                    "pass": bool(ok)})
                if not ok:
                    case_failures.append(case)
            case = f"{label}-expect-supported"
            args = [str(executable), f"+rom={rom}", "+delay=0",
                    "+expect_supported"]
            try:
                result = subprocess.run(args, env=env, cwd=model,
                                        capture_output=True, text=True,
                                        timeout=300)
                text = result.stdout + result.stderr
                rc = result.returncode
            except subprocess.TimeoutExpired:
                text, rc = "TIMEOUT", None
            (out / (case + ".log")).write_text(text)
            named = "aw-prot" in text or "ar-prot" in text
            ok = (rc != 0 and "CPU_ORIGIN_FAIL" in text and named)
            outcomes.append({
                "cpu_origin": case, "origin": "unsupported",
                "oracle_negative": True, "rc": rc,
                "reason": ("aw-prot" if "aw-prot" in text else
                           "ar-prot" if "ar-prot" in text else None),
                "log_sha256": sha(out / (case + ".log")), "pass": bool(ok)})
            if not ok:
                case_failures.append(case)
            if case_failures:
                unsupported_error = ("cpu-origin-unsupported case failures: " +
                                     ", ".join(case_failures))
        if unsupported_error is not None:
            manifest["cpu_origin_unsupported"]["error"] = unsupported_error
            outcomes.append({"cpu_origin": label, "origin": "unsupported",
                             "pass": False, "error": unsupported_error})
    if "cpu-origin-atomic" in stages:
        # cpu-origin-atomic: AMO/LR/SC on dedicated Probe slots in M and U.
        # The core emits AXI4 ATOP writes (old value on R) for AMO and AXI
        # exclusive AR(lock)/AW(lock) for LR/SC; every atomic access must carry
        # prot==000 while ordinary accesses keep M(001)/U(010) origin.
        atomic_rom = out / "program-atomic.hex"
        atomic_rom.write_bytes(program.build_atomic_program())
        manifest["cpu_origin_atomic"] = {
            "program_sha256": sha(atomic_rom),
            "oracle": "atomic AW/AR prot==000; ordinary M=001 U=010; "
                      "writes=11 reads=8 awrites=6 areads=2",
            "negative": "+expect_atomic_origin must reject atomic-aw/ar-prot",
            "axi_model": "ATOP RMW old-on-R + B; LR AR.lock->R; SC AW.lock->B.exokay",
        }

        def _atomic_build(label, origin_enabled):
            model = out / ("model-" + label)
            model.mkdir()
            command = [str(verilator), "--binary", "--timing", "--assert",
                       "--threads", "1", "-Wno-fatal",
                       "--top-module", "tb_g6lc_storamic_cpu_origin",
                       f"-GOriginEnabled={origin_enabled}",
                       "-GUnsupportedProfile=0", "-GAtomicProfile=1",
                       "-GIntegerDiagnostic=0",
                       "--Mdir", str(model), "-o", "test",
                       "--exe", str(data / "g6lc_dram_peek64_stub.cpp"),
                       str(data / "origin_cache.vlt"),
                       *["-I" + str(tree / d) for d in plan["incdirs"]],
                       *plan["defines"],
                       *[str(tree / f) for f in plan["files"]],
                       str(tree / BENCH_REL)]
            command += manifest["runtime"].get("verilator_options", [])
            (out / (label + "-command.json")).write_text(json.dumps(command))
            started = time.monotonic()
            with (out / (label + "-build.log")).open("w") as log:
                subprocess.run(command, env=env, cwd=model, stdout=log,
                               stderr=subprocess.STDOUT, check=True,
                               timeout=2400)
            seconds = round(time.monotonic() - started, 1)
            executable = model / "test"
            builds.append(_model_identity(model, executable, manifest) |
                          {"cpu_origin": label, "seconds": seconds,
                           "log_sha256": sha(out / (label + "-build.log"))})
            outcomes.append({"cpu_origin": label + "-build",
                             "origin": "atomic", "seconds": seconds,
                             "executable": str(executable), "pass": True})
            return executable

        def _atomic_run(executable, case, args, expect):
            try:
                result = subprocess.run(args, env=env, cwd=executable.parent,
                                        capture_output=True, text=True,
                                        timeout=300)
                text = result.stdout + result.stderr
                rc = result.returncode
            except subprocess.TimeoutExpired:
                text, rc = "TIMEOUT", None
            (out / (case + ".log")).write_text(text)
            m = ATOMIC_PASS_RE.search(text)
            ok = expect(text, rc, m)
            outcomes.append({
                "cpu_origin": case, "origin": "atomic", "rc": rc,
                "pass_marker": m.group(0) if m else None,
                "writes": int(m.group(5)) if m else None,
                "reads": int(m.group(6)) if m else None,
                "awrites": int(m.group(7)) if m else None,
                "areads": int(m.group(8)) if m else None,
                "log_sha256": sha(out / (case + ".log")), "pass": bool(ok)})
            return ok

        # origin-on atomic build: M+U positive at delay 0/16 + named negative.
        # G6LC_ATOMIC_ONLY=smoke runs only the origin-on delay0 positive (one
        # build + one sim) as a traced subset before the full stage.
        atomic_only = os.environ.get("G6LC_ATOMIC_ONLY")
        atomic_trace = ["+trace"] if os.environ.get("G6LC_ATOMIC_TRACE") else []
        atomic_smt = ["+smt_stats"] if os.environ.get("G6LC_ATOMIC_SMT") else []
        atomic_exe = _atomic_build("cpu-origin-atomic", 1)
        atomic_failures = []
        delay_cases = (0,) if atomic_only == "smoke" else (0, 16)
        for delay in delay_cases:
            case = f"cpu-origin-atomic-delay{delay}"
            ok = _atomic_run(
                atomic_exe, case,
                [str(atomic_exe), f"+rom={atomic_rom}", f"+delay={delay}"]
                + atomic_trace + atomic_smt,
                lambda t, rc, m: (rc == 0 and m and
                                  int(m.group(5)) == ATOMIC_ORD_W and
                                  int(m.group(6)) == ATOMIC_ORD_R and
                                  int(m.group(7)) == ATOMIC_WR and
                                  int(m.group(8)) == ATOMIC_RD))
            if not ok:
                atomic_failures.append(case)
        if atomic_only != "smoke":
            case = "cpu-origin-atomic-expect-atomic-origin"
            ok = _atomic_run(
                atomic_exe, case,
                [str(atomic_exe), f"+rom={atomic_rom}", "+delay=0",
                 "+expect_atomic_origin"],
                lambda t, rc, m: (rc != 0 and "CPU_ORIGIN_FAIL" in t and
                                  ("atomic-aw-prot" in t or "atomic-ar-prot" in t)
                                  and not ATOMIC_PASS_RE.findall(t)))
            if not ok:
                atomic_failures.append(case)
            # origin-off atomic build: every access (ordinary + atomic) prot==000.
            atomic_off_exe = _atomic_build("cpu-origin-atomic-off", 0)
            case = "cpu-origin-atomic-off-delay0"
            ok = _atomic_run(
                atomic_off_exe, case,
                [str(atomic_off_exe), f"+rom={atomic_rom}", "+delay=0"],
                lambda t, rc, m: (rc == 0 and m and
                                  int(m.group(5)) == ATOMIC_ORD_W and
                                  int(m.group(6)) == ATOMIC_ORD_R and
                                  int(m.group(7)) == ATOMIC_WR and
                                  int(m.group(8)) == ATOMIC_RD))
            if not ok:
                atomic_failures.append(case)
        if atomic_failures:
            manifest["cpu_origin_atomic"]["error"] = (
                "cpu-origin-atomic case failures: " + ", ".join(atomic_failures))
            outcomes.append({"cpu_origin": "cpu-origin-atomic",
                             "origin": "atomic", "pass": False,
                             "error": manifest["cpu_origin_atomic"]["error"]})
