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
    if "cpu-origin" not in stages:
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
    for enabled in (0, 1):
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
