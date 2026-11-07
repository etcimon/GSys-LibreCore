# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT

import hashlib
import json
import os
from pathlib import Path
import resource
import shlex
import shutil
import subprocess
import sys
import time


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def file_identities(paths):
    return {str(path.resolve()): sha(path) for path in sorted(paths)}


def runtime_identity(out):
    record_path = Path(os.environ["STORAMIC_RUNTIME_JSON"])
    record = json.loads(record_path.read_text())
    runtime = Path(record["privateRoot"]).resolve()
    original = Path(record["originalRoot"]).resolve()
    expected = os.environ["STORAMIC_RUNTIME_HEADER_SHA256"]
    header = runtime / "include/verilated_funcs.h"
    if record.get("kind") == "g6lc-fork-native":
        # A current fork can already have correct assertion semantics. Require
        # actual positive/negative execution instead of inventing a failed
        # "original" runtime or pretending it needed the legacy private patch.
        compiler = Path(os.environ["VERILATOR"]).resolve().with_name("verilator_bin")
        canary_path = record_path.with_name("canaries.json")
        canaries = json.loads(canary_path.read_text())
        runtime_files = {p.relative_to(runtime).as_posix(): sha(p)
                         for folder in ("include", "bin")
                         for p in (runtime / folder).rglob("*") if p.is_file()}
        if (len(expected) != 64 or sha(header) != expected or
                record["fixedHeaderSha256"] != expected or
                record["runtimeFiles"] != runtime_files or
                record["compilerSha256"] != sha(compiler) or
                [(item["tag"], item["rc"]) for item in canaries] !=
                [("assertion-positive", 0), ("assertion-negative", 1)] or
                "STORAMIC_RUNTIME_PASS" not in canaries[0]["text"] or
                "STORAMIC_RUNTIME_NEGATIVE" not in canaries[1]["text"]):
            raise RuntimeError("STORAMIC_FORK_RUNTIME_IDENTITY")
        artifacts = {Path(path): digest for item in canaries for path, digest in item["artifacts"].items()}
        if not artifacts or any(not path.is_file() or sha(path) != digest
                                for path, digest in artifacts.items()):
            raise RuntimeError("STORAMIC_FORK_RUNTIME_CANARY_ARTIFACTS")
        provenance = Path(record["provenance"])
        if sha(provenance) != record["provenanceSha256"]:
            raise RuntimeError("STORAMIC_FORK_RUNTIME_PROVENANCE")
        identity = {
            "kind": record["kind"], "root": str(runtime), "original_root": str(original),
            "files": file_identities([record_path, canary_path, provenance, *artifacts,
                                     *[runtime / name for name in runtime_files]]),
            "header_sha256": expected, "canary_evidence": canaries,
            "compiler_sha256": sha(compiler),
            "verilator_options": record.get("verilatorOptions", []),
            "simulator_pgo": record.get("simulatorPgo", False),
        }
        (out / "runtime-identity.json").write_text(json.dumps(identity, indent=2))
        return identity
    if (runtime == original or len(expected) != 64 or
            record["fixedHeaderSha256"] != expected or sha(header) != expected):
        raise RuntimeError("STORAMIC_RUNTIME_IDENTITY")
    canary_path = record_path.with_name("canaries.json")
    canaries = json.loads(canary_path.read_text())
    if [(item["tag"], item["rc"]) for item in canaries] != [("original", 1), ("fixed", 0)]:
        raise RuntimeError("STORAMIC_RUNTIME_CANARY_IDENTITY")
    inputs = [record_path, canary_path, *[
        p for p in (runtime / "include").rglob("*") if p.is_file()
    ], runtime / "bin/verilator_includer"]
    identity = {
        "root": str(runtime), "original_root": str(original),
        "files": file_identities(inputs), "header_sha256": expected,
        "canary_evidence": canaries,
    }
    (out / "runtime-identity.json").write_text(json.dumps(identity, indent=2))
    return identity


def compiler_identity():
    paths = {}
    for name in ("g++", "make", "ar", "python3"):
        resolved = shutil.which(name)
        if resolved is None:
            raise FileNotFoundError(name)
        paths[name] = Path(resolved).resolve()
    for name in ("cc1plus", "as", "collect2", "ld"):
        value = subprocess.check_output(
            [str(paths["g++"]), "-print-prog-name=" + name], text=True).strip()
        resolved = value if Path(value).is_absolute() else shutil.which(value)
        if resolved is None:
            raise FileNotFoundError(value)
        paths[name] = Path(resolved).resolve()
    return {
        "paths": {name: str(path) for name, path in paths.items()},
        "files": file_identities(paths.values()),
        "version": subprocess.check_output(
            [str(paths["g++"]), "--version"], text=True).strip(),
    }


def build_environment(runtime):
    env = dict(os.environ)
    for key in ("MAKEFLAGS", "MFLAGS", "CXX", "CC", "CXXFLAGS", "CFLAGS",
                "CPPFLAGS", "LDFLAGS", "OBJCACHE", "VERILATOR_ROOT", "VPATH"):
        env.pop(key, None)
    if runtime.get("kind") == "g6lc-fork-native":
        env["VERILATOR_ROOT"] = runtime["root"]
    return env


def build_model(command, model, log_path, manifest, *, pgo_compile_timeout=300):
    if type(pgo_compile_timeout) is not int or pgo_compile_timeout < 1:
        raise ValueError("STORAMIC_PGO_COMPILE_BUDGET")
    generation = list(command)
    generation[generation.index("--binary")] = "--cc"
    generation += ["--main", "--exe"]
    top = generation[generation.index("--top-module") + 1]
    compiler = manifest["compiler"]["paths"]
    runtime = manifest["runtime"]
    unroll = runtime.get("verilator_options", [])
    if unroll:
        if (len(unroll) != 4 or unroll[::2] != ["--unroll-count", "--unroll-stmts"] or
                any(not value.isdecimal() or int(value) < 1 for value in unroll[1::2])):
            raise RuntimeError("STORAMIC_UNROLL_OPTIONS")
        generation += unroll
    make = [
        compiler["make"], "-C", str(model), "-f", f"V{top}.mk",
        "-f", "identity.mk", "-j1",
        "VERILATOR_ROOT=" + runtime["root"],
        "CXX=" + compiler["g++"], "LINK=" + compiler["g++"], "OBJCACHE=",
        "AR=" + compiler["ar"], "PYTHON3=" + compiler["python3"],
    ]
    env = build_environment(runtime)
    log_path.with_suffix(".commands.json").write_text(json.dumps({
        "generate": generation, "compile": make,
        "pgo_compile_budget_seconds": pgo_compile_timeout if runtime.get("simulator_pgo", False) else None,
    }, indent=2))
    executable = model / generation[generation.index("-o") + 1]
    pgo = None
    with log_path.open("w") as log:
        subprocess.run(generation, env=env, stdout=log, stderr=subprocess.STDOUT,
                       check=True, timeout=180)
        # GCC's -MMD suppresses system dependencies even when -MD is also given.
        # Override only dependency selection in this owned build, not the runtime.
        (model / "identity.mk").write_text(
            "override VK_CPPFLAGS_ALWAYS := $(filter-out -MMD,$(VK_CPPFLAGS_ALWAYS)) -MD\n")
        if runtime.get("simulator_pgo", False):
            profiles = model / "pgo"
            profiles.mkdir(exist_ok=False)
            optimization = "-O2 -funroll-loops"
            instrument = optimization + f" -fprofile-generate={profiles} -fprofile-update=atomic"
            training_make = make + [f"{key}={instrument}" for key in
                                    ("OPT_FAST", "OPT_SLOW", "OPT_GLOBAL")] + ["LDFLAGS=-fprofile-generate"]
            subprocess.run(training_make, env=env, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=pgo_compile_timeout)
            started = time.monotonic()
            training = subprocess.run([str(executable)], env=env, capture_output=True,
                                      text=True, timeout=180)
            (profiles / "training.log").write_text(training.stdout + training.stderr)
            shutil.copy2(executable, profiles / "training-executable")
            samples = list(profiles.rglob("*.gcda"))
            pgo = {
                "training_returncode": training.returncode,
                "training_seconds": time.monotonic() - started,
                "training_command": training_make,
                "profile_files": file_identities(samples),
                "training_executable_sha256": sha(profiles / "training-executable"),
                "qualification": False,
                "compile_budget_seconds": pgo_compile_timeout,
            }
            # All removed files are generated by this invocation in its owned
            # model directory, never repository/shared build outputs.
            for path in model.iterdir():
                if path.is_file() and (path.suffix in {".o", ".a", ".d"} or path == executable):
                    path.unlink()
            if samples:
                use = optimization + f" -fprofile-use={profiles} -fprofile-correction -Werror=coverage-mismatch"
                final_make = make + [f"{key}={use}" for key in ("OPT_FAST", "OPT_SLOW", "OPT_GLOBAL")]
                pgo["mode"] = "profile-use"
            else:
                # Deliberately illegal configurations can abort before gcov
                # flushes. They still get a fresh uninstrumented binary and
                # must reject at the caller's exact named oracle.
                final_make = make
                pgo["mode"] = "not-applied-no-profile"
            pgo["final_command"] = final_make
            subprocess.run(final_make, env=env, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=pgo_compile_timeout)
        else:
            subprocess.run(make, env=env, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=180)
    dependencies = set()
    for depfile in model.rglob("*.d"):
        for rule in depfile.read_text().replace("\\\n", "").splitlines():
            if ":" not in rule:
                continue
            for value in shlex.split(rule.split(":", 1)[1]):
                path = Path(value.replace("$$", "$"))
                dependencies.add((path if path.is_absolute() else model / path).resolve())
    private_header = Path(runtime["root"]) / "include/verilated_funcs.h"
    original_header = Path(runtime["original_root"]) / "include/verilated_funcs.h"
    if private_header not in dependencies or (
            original_header != private_header and original_header in dependencies):
        raise RuntimeError("STORAMIC_COMPILED_RUNTIME_IDENTITY")
    generated = {p for p in model.iterdir() if p.is_file() and
                 p.suffix in {".cpp", ".h", ".mk", ".dat", ".d"}}
    record = {
        "commands": {"generate": generation, "compile": make},
        "files": file_identities(dependencies | generated | {executable}),
        "executable": str(executable), "private_runtime_verified": True,
        "simulator_pgo": pgo,
    }
    (model / "build-identity.json").write_text(json.dumps(record, indent=2))
    return record


def run_smt(prefix, top, tag, depth, out, yosys, manifest, induction=False, cover=False):
    tools = [Path(shutil.which(name) or "") for name in ("yosys-smtbmc", "yices-smt2")]
    if any(not path.is_file() for path in tools):
        raise FileNotFoundError("checkpoint formal requires yosys-smtbmc and yices-smt2")
    smtbmc, solver = tools
    dependencies = list((smtbmc.resolve().parent.parent / "share/yosys/python3").glob("*.py"))
    files = file_identities([*tools, *dependencies, Path(sys.executable)])
    if "formal_tools" in manifest and files != manifest["formal_tools"]["files"]:
        raise RuntimeError("STORAMIC_FORMAL_TOOL_IDENTITY_CHANGED")
    manifest["formal_tools"] = {
        "files": files, "engine": "yosys-smtbmc/yices",
        "solver_version": subprocess.check_output([str(solver), "--version"], text=True).strip(),
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))
    script = out / f"{tag}.ys"
    smt = out / f"{tag}.smt2"
    script.write_text(prefix + f"write_smt2 -wires {smt}\n")
    with (out / f"{tag}-build.log").open("w") as log:
        subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                       stderr=subprocess.STDOUT, check=True, timeout=180)
    command = [str(smtbmc), "-s", "yices", "-t", str(depth or 1), "--presat", "-m", top]
    if induction:
        command += ["-i"]
    if cover:
        command += ["-c"]
    if depth and not induction:
        constraints = out / f"{tag}.smtc"
        constraints.write_text("initial\nassume (= [rst_ni] false)\n")
        command += ["--smtc", str(constraints)]
    command += ["--dump-vcd", str(out / f"{tag}.vcd"), str(smt)]
    (out / f"{tag}-command.json").write_text(json.dumps(command))
    env = dict(os.environ)
    env["PATH"] = str(solver.parent) + os.pathsep + env.get("PATH", "")
    with (out / f"{tag}.log").open("w") as log:
        return subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                              env=env, timeout=300)


def main():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    data = Path(os.environ["TH_DATA_DIR"])
    out = Path(os.environ["TH_OUT_DIR"])
    run_manifest = json.loads((data / os.environ["STORAMIC_MANIFEST_FILE"]).read_text())
    expected = run_manifest["sources"]
    actual = {name: sha(data / name) for name in expected}
    if actual != expected or sha(Path(__file__)) != os.environ["STORAMIC_RUNNER_SHA"]:
        raise RuntimeError("STORAMIC_SOURCE_IDENTITY")
    stages = os.environ["STORAMIC_STAGES"].split(",")
    sys.path.insert(0, str(data))
    from run_remote import ALLOWED_STAGES, SIMULATION_STAGES
    if len(stages) != len(set(stages)) or not set(stages) <= ALLOWED_STAGES:
        raise RuntimeError("STORAMIC_STAGE_IDENTITY")
    if "stages" in run_manifest and stages != run_manifest["stages"]:
        raise RuntimeError("STORAMIC_STAGE_IDENTITY")
    manifest = {
        "sources": actual, "runner": sha(Path(__file__)),
        "qualification": False,
        "source_paths": run_manifest["source_paths"],
        "stages": stages,
        "resources": {
            "compiler_jobs": 1, "model_threads": 1,
            "cpu_affinity": sorted(os.sched_getaffinity(0)),
            "load_average": os.getloadavg(),
            "free_disk_bytes": shutil.disk_usage(out).free,
            "memory": [line for line in Path("/proc/meminfo").read_text().splitlines()
                       if line.startswith(("MemTotal:", "MemAvailable:"))],
        },
    }
    builds = []
    verilator = None
    if set(stages) & SIMULATION_STAGES:
        verilator = Path(os.environ.get("VERILATOR") or shutil.which("verilator") or "")
        if not verilator.is_file():
            raise FileNotFoundError("Verilator unavailable")
        manifest.update({
            "verilator": str(verilator.resolve()), "verilator_sha256": sha(verilator),
            "version": subprocess.check_output([str(verilator), "--version"], text=True).strip(),
            "verilator_bin_sha256": sha(verilator.with_name("verilator_bin")),
        })
        manifest["runtime"] = runtime_identity(out)
        manifest["compiler"] = compiler_identity()
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))
    source_names = [
        "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
        "g6lc_storamic_pad_pkg.sv", "g6lc_storamic_axi_refuse.sv",
        "g6lc_storamic_region_pkg.sv",
        "g6lc_storamic_axi_memory.sv", "g6lc_storamic_regs.sv",
        "g6lc_storamic_top.sv", "tb_g6lc_storamic.sv",
    ]
    sources = [str(data / name) for name in source_names]
    outcomes = []
    if set(stages) & {"commit-defaults", "commit-defaults-formal", "commit-defaults-synth"}:
        from run_commit_defaults import run as run_commit_defaults
        run_commit_defaults(data, out, stages, manifest, builds, outcomes, verilator, build_model)
    config_failures = []
    profiles = [
        ("one", ["-GMaxSticks=1"], None),
        ("two", ["-GMaxSticks=2"], None),
        ("three", ["-GMaxSticks=3"], None),
        ("four", ["-GMaxSticks=4"], None),
        ("eight", ["-GMaxSticks=8"], None),
        ("off", ["-GEnable=0", "-GSkeleton=0"], None),
        ("zero", ["-GMaxSticks=0"], "STORAMIC_CONFIG_ILLEGAL"),
        ("overflow", ["-GMaxSticks=9"], "STORAMIC_CONFIG_ILLEGAL"),
        ("capability", ["-GRequestedCaps=1"], "STORAMIC_CONFIG_ILLEGAL"),
        ("not-skeleton", ["-GSkeleton=0"], "STORAMIC_CONFIG_ILLEGAL"),
    ]
    for name, flags, error in profiles if "protocol" in stages else []:
        model = out / name
        command = [
            str(verilator), "--binary", "--timing", "--assert", "-j", "1",
            "--threads", "1", "-Wno-fatal", "-Werror-LATCH", "-Werror-UNOPTFLAT",
            "--top-module", "tb_g6lc_storamic", "--Mdir", str(model),
            "-o", "storamic-test", *flags, *sources,
        ]
        (out / f"{name}-command.json").write_text(json.dumps(command))
        builds.append(build_model(command, model, out / f"{name}-build.log", manifest))
        run = subprocess.run([str(model / "storamic-test")], capture_output=True,
                             text=True, timeout=30)
        text = run.stdout + run.stderr
        (out / f"{name}-sim.log").write_text(text)
        matched = (run.returncode != 0 and error in text) if error else (
            run.returncode == 0 and text.count("STORAMIC_FOUNDATION_PASS") == 1)
        if not matched:
            raise RuntimeError(f"{name}: unexpected verdict: {text[-4000:]}")
        outcomes.append({"profile": name, "expected_error": error, "pass": True})
        if name == "three":
            negative = subprocess.run(
                [str(model / "storamic-test"), "+oracle_negative"],
                capture_output=True, text=True, timeout=30)
            text = negative.stdout + negative.stderr
            (out / "oracle-negative.log").write_text(text)
            if negative.returncode == 0 or "STORAMIC_ORACLE_NEGATIVE" not in text:
                raise RuntimeError("negative oracle failed to reject")
    if "config" in stages:
        for config in os.environ["STORAMIC_TARGET_CONFIGS"].split(","):
            command = [
                str(verilator), "--lint-only", "--assert", "-Wno-fatal",
                "--top-module", "tb_g6lc_storamic_config",
                *[str(data / name) for name in [
                    "config_pkg.sv", config, "build_config_pkg.sv",
                    "g6lc_storamic_cfg_pkg.sv", "tb_g6lc_storamic_config.sv",
                ]],
            ]
            with (out / f"config-{config}.log").open("w") as log:
                lint = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                                      timeout=60)
            outcomes.append({"config": config, "pass": lint.returncode == 0})
            if lint.returncode:
                config_failures.append(config)
        (out / "config-results.json").write_text(json.dumps(outcomes, indent=2))
        for name, defines in [
            ("default", []), ("enabled", ["-DG6LC_STORAMIC"]),
            ("bad-geometry", ["-DG6LC_STORAMIC", "-GBadGeometry=1"]),
            ("bad-checkpoint", ["-GBadCheckpoint=1"]),
        ]:
            command = [
                str(verilator), "--binary", "--assert", "-j", "1", "-Wno-fatal",
                "--top-module", "tb_g6lc_storamic_config",
                "--Mdir", str(out / f"config-{name}"), "-o", "config-test", *defines,
                *[str(data / p) for p in [
                    "config_pkg.sv", "g6lc64_smt2_config_pkg.sv", "build_config_pkg.sv",
                    "g6lc_storamic_cfg_pkg.sv", "tb_g6lc_storamic_config.sv",
                ]],
            ]
            builds.append(build_model(command, out / f"config-{name}",
                                      out / f"config-{name}-build.log", manifest))
            run = subprocess.run([str(out / f"config-{name}/config-test")],
                                 capture_output=True, text=True, timeout=30)
            (out / f"config-{name}.log").write_text(run.stdout + run.stderr)
            error = {"bad-geometry": "STORAMIC_CORE_AXI_GEOMETRY",
                     "bad-checkpoint": "STORAMIC_CHECKPOINT_PRIMARY_REQUIRED"}.get(name)
            matched = (run.returncode != 0 and error in run.stdout + run.stderr) if error else (
                run.returncode == 0 and "STORAMIC_CORE_CONFIG_PASS" in run.stdout)
            if not matched:
                raise RuntimeError(f"configuration propagation failed: {name}")
    if "region" in stages:
        command = [
            str(verilator), "--binary", "--timing", "--assert", "-j", "1",
            "--threads", "1", "-Wno-fatal", "-Werror-LATCH", "-Werror-UNOPTFLAT",
            "--top-module", "tb_g6lc_storamic_region",
            "--Mdir", str(out / "region"), "-o", "region-test",
            *[str(data / p) for p in [
                "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_region_pkg.sv",
                "tb_g6lc_storamic_region.sv",
            ]],
        ]
        builds.append(build_model(command, out / "region",
                                  out / "region-build.log", manifest))
        run = subprocess.run([str(out / "region/region-test")],
                             capture_output=True, text=True, timeout=30)
        text = run.stdout + run.stderr
        (out / "region-sim.log").write_text(text)
        if run.returncode != 0 or "STORAMIC_REGION_PASS" not in text:
            raise RuntimeError(f"region: unexpected verdict: {text[-4000:]}")
        negative = subprocess.run(
            [str(out / "region/region-test"), "+oracle_negative"],
            capture_output=True, text=True, timeout=30)
        text = negative.stdout + negative.stderr
        (out / "region-oracle-negative.log").write_text(text)
        if negative.returncode == 0 or "STORAMIC_REGION_ORACLE_NEGATIVE" not in text:
            raise RuntimeError("region negative oracle failed to reject")
        outcomes.append({"region": "bench", "pass": True,
                         "negative_oracle": True})
    if "map" in stages:
        for name, flags in [
            ("map-one", ["-GSlots=1"]), ("map-two", ["-GSlots=2"]),
            ("map-three", ["-GSlots=3"]), ("map-four", ["-GSlots=4"]),
            ("map-eight", ["-GSlots=8"]),
            ("map-one-wide", ["-GSlots=1", "-GDataWidth=512"]),
            ("map-three-wide", ["-GSlots=3", "-GDataWidth=512"]),
            ("map-eight-wide", ["-GSlots=8", "-GDataWidth=512"]),
            ("map-rt", ["-GSlots=3", "-GBootMapEn=0"]),
        ]:
            command = [
                str(verilator), "--binary", "--timing", "--assert", "-j", "1",
                "--threads", "1", "-Wno-fatal", "-Werror-LATCH",
                "-Werror-UNOPTFLAT", "--top-module", "tb_g6lc_storamic_map",
                "--Mdir", str(out / name), "-o", "map-test", *flags,
                *[str(data / p) for p in [
                    "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
                    "g6lc_storamic_pad_pkg.sv", "g6lc_storamic_axi_refuse.sv",
                    "g6lc_storamic_region_pkg.sv", "g6lc_storamic_axi_memory.sv",
                    "g6lc_storamic_slot_mux.sv", "g6lc_storamic_regs.sv", "g6lc_storamic_top.sv",
                    "g6lc_storamic_sram_model.sv",
                    "tb_g6lc_storamic_map.sv",
                ]],
            ]
            builds.append(build_model(command, out / name,
                                      out / f"{name}-build.log", manifest))
            run = subprocess.run([str(out / f"{name}/map-test")],
                                 capture_output=True, text=True, timeout=60)
            text = run.stdout + run.stderr
            (out / f"{name}-sim.log").write_text(text)
            if run.returncode != 0 or "STORAMIC_MAP_PASS" not in text:
                raise RuntimeError(f"{name}: unexpected verdict: {text[-4000:]}")
            outcomes.append({"map": name, "pass": True})
        # Illegal map (backing alias via -DSTORAMIC_MAP_ILLEGAL) must hit the
        # frontend's elaboration-time geometry fatal, not simulate at all.
        command = [
            str(verilator), "--binary", "--timing", "--assert", "-j", "1",
            "--threads", "1", "-Wno-fatal", "-Werror-LATCH",
            "-Werror-UNOPTFLAT", "--top-module", "tb_g6lc_storamic_map",
            "--Mdir", str(out / "map-illegal"), "-o", "map-test",
            "-DSTORAMIC_MAP_ILLEGAL",
            *[str(data / p) for p in [
                "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
                "g6lc_storamic_pad_pkg.sv", "g6lc_storamic_axi_refuse.sv",
                "g6lc_storamic_region_pkg.sv", "g6lc_storamic_axi_memory.sv",
                "g6lc_storamic_slot_mux.sv", "g6lc_storamic_regs.sv", "g6lc_storamic_top.sv",
                "g6lc_storamic_sram_model.sv",
                "tb_g6lc_storamic_map.sv",
            ]],
        ]
        builds.append(build_model(command, out / "map-illegal",
                                  out / "map-illegal-build.log", manifest))
        run = subprocess.run([str(out / "map-illegal/map-test")],
                             capture_output=True, text=True, timeout=60)
        text = run.stdout + run.stderr
        (out / "map-illegal-sim.log").write_text(text)
        if run.returncode == 0 or "STORAMIC_MODEL_CONFIG_ILLEGAL" not in text:
            raise RuntimeError(f"map-illegal: unexpected verdict: {text[-2000:]}")
        outcomes.append({"map": "map-illegal", "expect_illegal": True})
        negative = subprocess.run(
            [str(out / "map-two/map-test"), "+oracle_negative"],
            capture_output=True, text=True, timeout=60)
        text = negative.stdout + negative.stderr
        (out / "map-oracle-negative.log").write_text(text)
        if negative.returncode == 0 or "STORAMIC_MAP_ORACLE_NEGATIVE" not in text:
            raise RuntimeError("map negative oracle failed to reject")
        outcomes.append({"map_negative_oracle": True})
    if "discovery" in stages:
        command = [
            str(verilator), "--binary", "--timing", "--assert",
            "-j", "1", "--threads", "1", "-Wno-fatal",
            "-Werror-LATCH", "-Werror-UNOPTFLAT",
            "--top-module", "tb_g6lc_storamic_discovery",
            "--Mdir", str(out / "discovery"), "-o", "discovery-test",
            *[str(data / p) for p in [
                "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
                "g6lc_storamic_region_pkg.sv",
                "g6lc_storamic_discovery_pkg.sv", "g6lc_storamic_sync.sv",
                "g6lc_storamic_discovery.sv", "g6lc_storamic_discovery_set.sv",
                "tb_g6lc_storamic_discovery.sv",
            ]],
        ]
        builds.append(build_model(command, out / "discovery",
                                  out / "discovery-build.log", manifest))
        run = subprocess.run([str(out / "discovery/discovery-test")],
                             capture_output=True, text=True, timeout=120)
        text = run.stdout + run.stderr
        (out / "discovery-sim.log").write_text(text)
        if run.returncode != 0 or "STORAMIC_DISCOVERY_PASS" not in text:
            raise RuntimeError(f"discovery: unexpected verdict: {text[-4000:]}")
        outcomes.append({"discovery": "tb", "pass": True})
        negative = subprocess.run(
            [str(out / "discovery/discovery-test"), "+oracle_negative"],
            capture_output=True, text=True, timeout=60)
        text = negative.stdout + negative.stderr
        (out / "discovery-oracle-negative.log").write_text(text)
        if (negative.returncode == 0 or
                "STORAMIC_DISCOVERY_ORACLE_NEGATIVE" not in text):
            raise RuntimeError("discovery negative oracle failed to reject")
        outcomes.append({"discovery_negative_oracle": True})
    if "regs" in stages:
        command = [
            str(verilator), "--binary", "--timing", "--assert",
            "-j", "1", "--threads", "1", "-Wno-fatal",
            "-Werror-LATCH", "-Werror-UNOPTFLAT",
            "--top-module", "tb_g6lc_storamic_regs",
            "--Mdir", str(out / "regs"), "-o", "regs-test",
            *[str(data / p) for p in [
                "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
                "g6lc_storamic_pad_pkg.sv", "g6lc_storamic_region_pkg.sv",
                "g6lc_storamic_axi_refuse.sv", "g6lc_storamic_axi_memory.sv",
                "g6lc_storamic_regs.sv", "g6lc_storamic_top.sv",
                "tb_g6lc_storamic_regs.sv",
            ]],
        ]
        builds.append(build_model(command, out / "regs",
                                  out / "regs-build.log", manifest))
        run = subprocess.run([str(out / "regs/regs-test")],
                             capture_output=True, text=True, timeout=120)
        text = run.stdout + run.stderr
        (out / "regs-sim.log").write_text(text)
        if run.returncode != 0 or "STORAMIC_REGS_PASS" not in text:
            raise RuntimeError(f"regs: unexpected verdict: {text[-4000:]}")
        outcomes.append({"regs": "tb", "pass": True})
        negative = subprocess.run(
            [str(out / "regs/regs-test"), "+oracle_negative"],
            capture_output=True, text=True, timeout=60)
        text = negative.stdout + negative.stderr
        (out / "regs-oracle-negative.log").write_text(text)
        if (negative.returncode == 0 or
                "STORAMIC_REGS_ORACLE_NEGATIVE" not in text):
            raise RuntimeError("regs negative oracle failed to reject")
        outcomes.append({"regs_negative_oracle": True})
    if "virtio" in stages:
        command = [
            str(verilator), "--binary", "--timing", "--assert",
            "-j", "1", "--threads", "1", "-Wno-fatal",
            "-Werror-LATCH", "-Werror-UNOPTFLAT",
            "--top-module", "tb_g6lc_storamic_virtio_mmio",
            "--Mdir", str(out / "virtio"), "-o", "virtio-test",
            *[str(data / p) for p in [
                "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
                "g6lc_storamic_region_pkg.sv",
                "g6lc_storamic_virtio_mmio.sv",
                "tb_g6lc_storamic_virtio_mmio.sv",
            ]],
        ]
        builds.append(build_model(command, out / "virtio",
                                  out / "virtio-build.log", manifest))
        run = subprocess.run([str(out / "virtio/virtio-test")],
                             capture_output=True, text=True, timeout=180)
        text = run.stdout + run.stderr
        (out / "virtio-sim.log").write_text(text)
        if run.returncode != 0 or "VIRTIO_PASS" not in text:
            raise RuntimeError(f"virtio: unexpected verdict: {text[-4000:]}")
        outcomes.append({"virtio": "tb", "pass": True})
        negative = subprocess.run(
            [str(out / "virtio/virtio-test"), "+oracle_negative"],
            capture_output=True, text=True, timeout=60)
        text = negative.stdout + negative.stderr
        (out / "virtio-oracle-negative.log").write_text(text)
        if "VIRTIO_PASS" in text or negative.returncode == 0:
            raise RuntimeError("virtio: negative oracle accepted")
        outcomes.append({"virtio_negative_oracle": True})
    if "vring" in stages:
        command = [
            str(verilator), "--binary", "--timing", "--assert",
            "-j", "1", "--threads", "1", "-Wno-fatal",
            "-Werror-LATCH", "-Werror-UNOPTFLAT",
            "--top-module", "tb_g6lc_storamic_virtio_ring",
            "--Mdir", str(out / "vring"), "-o", "vring-test",
            *[str(data / p) for p in [
                "g6lc_storamic_virtio_ring.sv", "tb_g6lc_storamic_virtio_ring.sv",
            ]],
        ]
        builds.append(build_model(command, out / "vring",
                                  out / "vring-build.log", manifest))
        run = subprocess.run([str(out / "vring/vring-test")],
                             capture_output=True, text=True, timeout=300)
        text = run.stdout + run.stderr
        (out / "vring-sim.log").write_text(text)
        if run.returncode != 0 or "VRING_PASS" not in text:
            raise RuntimeError(f"vring: unexpected verdict: {text[-4000:]}")
        outcomes.append({"vring": "tb", "pass": True})
        negative = subprocess.run(
            [str(out / "vring/vring-test"), "+oracle_negative"],
            capture_output=True, text=True, timeout=120)
        text = negative.stdout + negative.stderr
        (out / "vring-oracle-negative.log").write_text(text)
        if "VRING_PASS" in text or negative.returncode == 0:
            raise RuntimeError("vring: negative oracle accepted")
        outcomes.append({"vring_negative_oracle": True})
    if "vblk" in stages:
        command = [
            str(verilator), "--binary", "--timing", "--assert",
            "-j", "1", "--threads", "1", "-Wno-fatal",
            "-Werror-LATCH", "-Werror-UNOPTFLAT",
            "--top-module", "tb_g6lc_storamic_virtio_blk",
            "--Mdir", str(out / "vblk"), "-o", "vblk-test",
            *[str(data / p) for p in [
                "g6lc_storamic_virtio_blk.sv", "tb_g6lc_storamic_virtio_blk.sv",
            ]],
        ]
        builds.append(build_model(command, out / "vblk",
                                  out / "vblk-build.log", manifest))
        run = subprocess.run([str(out / "vblk/vblk-test")],
                             capture_output=True, text=True, timeout=300)
        text = run.stdout + run.stderr
        (out / "vblk-sim.log").write_text(text)
        if run.returncode != 0 or "VBLK_PASS" not in text:
            raise RuntimeError(f"vblk: unexpected verdict: {text[-4000:]}")
        outcomes.append({"vblk": "tb", "pass": True})
        negative = subprocess.run(
            [str(out / "vblk/vblk-test"), "+oracle_negative"],
            capture_output=True, text=True, timeout=120)
        text = negative.stdout + negative.stderr
        (out / "vblk-oracle-negative.log").write_text(text)
        if "VBLK_PASS" in text or negative.returncode == 0:
            raise RuntimeError("vblk: negative oracle accepted")
        outcomes.append({"vblk_negative_oracle": True})
    if "vdev" in stages:
        command = [
            str(verilator), "--binary", "--timing", "--assert",
            "-j", "1", "--threads", "1", "-Wno-fatal",
            "-Werror-LATCH", "-Werror-UNOPTFLAT",
            "--top-module", "tb_g6lc_storamic_virtio_dev",
            "--Mdir", str(out / "vdev"), "-o", "vdev-test",
            *[str(data / p) for p in [
                "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
                "g6lc_storamic_virtio_mmio.sv", "g6lc_storamic_virtio_ring.sv",
                "g6lc_storamic_virtio_blk.sv", "g6lc_storamic_virtio_dev.sv",
                "tb_g6lc_storamic_virtio_dev.sv",
            ]],
        ]
        builds.append(build_model(command, out / "vdev",
                                  out / "vdev-build.log", manifest))
        run = subprocess.run([str(out / "vdev/vdev-test")],
                             capture_output=True, text=True, timeout=600)
        text = run.stdout + run.stderr
        (out / "vdev-sim.log").write_text(text)
        if run.returncode != 0 or "VDEV_PASS" not in text:
            raise RuntimeError(f"vdev: unexpected verdict: {text[-4000:]}")
        outcomes.append({"vdev": "tb", "pass": True})
        negative = subprocess.run(
            [str(out / "vdev/vdev-test"), "+oracle_negative"],
            capture_output=True, text=True, timeout=300)
        text = negative.stdout + negative.stderr
        (out / "vdev-oracle-negative.log").write_text(text)
        if "VDEV_PASS" in text or negative.returncode == 0:
            raise RuntimeError("vdev: negative oracle accepted")
        outcomes.append({"vdev_negative_oracle": True})
    if "quiesce" in stages:
        model = out / "quiesce"
        command = [
            str(verilator), "--binary", "--timing", "--assert",
            "-j", "1", "--threads", "1", "-Wno-fatal",
            "-Werror-LATCH", "-Werror-UNOPTFLAT", "-Werror-PINMISSING",
            "--top-module", "tb_g6lc_storamic_quiesce",
            "--Mdir", str(model), "-o", "quiesce-test",
            *[str(data / p) for p in [
                "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
                "g6lc_storamic_region_pkg.sv", "g6lc_storamic_axi_memory.sv",
                "g6lc_storamic_sram_model.sv", "tb_g6lc_storamic_quiesce.sv",
            ]],
        ]
        builds.append(build_model(command, model, out / "quiesce-build.log", manifest))
        executable = str(model / "quiesce-test")
        run = subprocess.run([executable], capture_output=True, text=True, timeout=120)
        text = run.stdout + run.stderr
        (out / "quiesce-sim.log").write_text(text)
        if run.returncode != 0 or "QUIESCE_PASS" not in text:
            raise RuntimeError(f"quiesce: unexpected verdict: {text[-4000:]}")
        negative = subprocess.run([executable, "+oracle_negative"],
                                  capture_output=True, text=True, timeout=120)
        text = negative.stdout + negative.stderr
        (out / "quiesce-negative.log").write_text(text)
        if (negative.returncode == 0 or "QUIESCE_PASS" in text or
                "QUIESCE_CHECK_FAIL negative oracle" not in text):
            raise RuntimeError("quiesce: negative oracle did not reject as expected")
        outcomes.append({"quiesce": "tb", "negative_oracle": True, "pass": True})
    if "dstore" in stages:
        for delay in (0, 1, 4, 16):
            name = f"dstore-rsp{delay}"
            command = [
                str(verilator), "--binary", "--timing", "--assert",
                "-j", "1", "--threads", "1", "-Wno-fatal",
                "-Werror-LATCH", "-Werror-UNOPTFLAT",
                f"-GStoreRspCycles={delay}",
                "--top-module", "tb_g6lc_storamic_durable_store",
                "--Mdir", str(out / name), "-o", "dstore-test",
                *[str(data / p) for p in [
                    "g6lc_storamic_pkg.sv", "tc_sram.sv",
                    "tc_sram_wrapper.sv", "sram.sv",
                    "g6lc_storamic_durable_store.sv", "g6lc_storamic_sim_mem.sv",
                    "tb_g6lc_storamic_durable_store.sv",
                ]],
            ]
            builds.append(build_model(command, out / name,
                                      out / f"{name}-build.log", manifest))
            executable = str(out / name / "dstore-test")
            run = subprocess.run([executable], capture_output=True, text=True, timeout=120)
            text = run.stdout + run.stderr
            (out / f"{name}-sim.log").write_text(text)
            if run.returncode != 0 or "DSTORE_PASS" not in text:
                raise RuntimeError(f"{name}: unexpected verdict: {text[-4000:]}")
            negative = subprocess.run([executable, "+oracle_negative"],
                                      capture_output=True, text=True, timeout=120)
            text = negative.stdout + negative.stderr
            (out / f"{name}-negative.log").write_text(text)
            if (negative.returncode == 0 or "DSTORE_PASS" in text or
                    "DSTORE_CHECK_FAIL negative oracle" not in text):
                raise RuntimeError(f"{name}: negative oracle did not reject as expected")
            outcomes.append({"dstore": "tb", "rsp_cycles": delay,
                             "negative_oracle": True, "pass": True})
    if set(stages) & {"checkpoint-record", "checkpoint-model", "checkpoint-service", "checkpoint-endpoint",
                      "checkpoint-policy", "checkpoint-writer", "checkpoint-writer-reset",
                      "policy-writer"}:
        record_inputs = [
            "g6lc_storamic_pkg.sv", "g6lc_storamic_checkpoint_pkg.sv",
            "g6lc_storamic_checkpoint_io.sv", "g6lc_storamic_checkpoint_media.sv",
            "g6lc_storamic_sim_mem.sv", "g6lc_storamic_durable_store.sv",
            "tc_sram.sv", "tc_sram_wrapper.sv", "sram.sv",
            "tb_g6lc_storamic_checkpoint_media.sv",
        ]
        record_cases = [
            ("checkpoint-codec", "tb_g6lc_storamic_checkpoint_codec", [],
             ["g6lc_storamic_checkpoint_pkg.sv", "tb_g6lc_storamic_checkpoint_codec.sv"],
             "CHECKPOINT_CODEC_PASS", "CHECKPOINT_CODEC_FAIL negative-oracle"),
            ("store-guard", "tb_g6lc_storamic_store_guard", [],
             ["g6lc_storamic_store_guard.sv", "tb_g6lc_storamic_store_guard.sv"],
             "STORE_GUARD_PASS", "STORE_GUARD_FAIL negative-oracle"),
        ]
        if "checkpoint-record" not in stages:
            record_cases = []
        for delay in (0, 1, 4, 16) if "checkpoint-record" in stages else ():
            record_cases.append((
                f"checkpoint-media-rsp{delay}", "tb_g6lc_storamic_checkpoint_media",
                [f"-GRspCycles={delay}"], record_inputs,
                "CHECKPOINT_MEDIA_PASS", "CHECKPOINT_MEDIA_FAIL negative-oracle"))
        if set(stages) & {"checkpoint-model", "checkpoint-endpoint", "checkpoint-writer",
                          "checkpoint-writer-reset", "policy-writer"}:
            model_inputs = [
                "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
                "g6lc_storamic_checkpoint_pkg.sv", "g6lc_storamic_region_pkg.sv",
                "g6lc_storamic_axi_memory.sv", "g6lc_storamic_checkpoint_ctrl.sv",
                "g6lc_storamic_checkpoint_io.sv", "g6lc_storamic_checkpoint_media.sv",
                "g6lc_storamic_store_guard.sv", "g6lc_storamic_sim_mem.sv",
                "g6lc_storamic_durable_store.sv", "g6lc_storamic_checkpoint_model.sv",
                "tc_sram.sv", "tc_sram_wrapper.sv", "sram.sv",
                "tb_g6lc_storamic_checkpoint_model.sv",
            ]
            for delay in (0, 4, 16) if "checkpoint-model" in stages else ():
                record_cases.append((
                    f"checkpoint-model-rsp{delay}", "tb_g6lc_storamic_checkpoint_model",
                    [f"-GRspCycles={delay}"], model_inputs,
                    "CHECKPOINT_MODEL_PASS", "CHECKPOINT_MODEL_FAIL negative-oracle"))
            if set(stages) & {"checkpoint-writer", "checkpoint-writer-reset", "policy-writer"}:
                writer_inputs = model_inputs[:-1] + [
                    "g6lc_storamic_axi_refuse.sv", "g6lc_storamic_checkpoint_service.sv",
                    "g6lc_storamic_checkpoint_endpoint.sv", "g6lc_storamic_dma_axi.sv",
                    "g6lc_storamic_virtio_mmio.sv", "g6lc_storamic_virtio_ring.sv",
                    "g6lc_storamic_virtio_blk.sv", "g6lc_storamic_virtio_dev.sv",
                    "g6lc_storamic_checkpoint_writer_model.sv",
                    "tb_g6lc_storamic_checkpoint_writer.sv"]
                writer_cases = []
                if "checkpoint-writer" in stages:
                    writer_cases += [(f"checkpoint-writer-rsp{delay}", [f"-GRspCycles={delay}"])
                                     for delay in (0, 4, 16)]
                    writer_cases += [
                        ("checkpoint-writer-early-upstream", ["-GEarlyUpstreamAck=1"]),
                        ("checkpoint-writer-short-deadline",
                         ["-GTimeoutCycles=8192", "-GExpectTimeout=1", "-GRspCycles=0"]),
                        ("checkpoint-writer-disabled", ["-GEnabled=0"]),
                    ]
                if "checkpoint-writer-reset" in stages:
                    writer_cases += [(f"checkpoint-writer-reset-rsp{delay}",
                                      ["-GResetDuringSave=1", f"-GRspCycles={delay}"])
                                     for delay in (0, 4, 16)]
                for name, params in writer_cases:
                    record_cases.append((
                        name, "tb_g6lc_storamic_checkpoint_writer", params, writer_inputs,
                        "CHECKPOINT_WRITER_PASS", "CHECKPOINT_WRITER_FAIL negative-oracle"))
                if "policy-writer" in stages:
                    inputs = writer_inputs[:-1] + [
                        "g6lc_storamic_checkpoint_policy.sv",
                        "g6lc_storamic_policy_writer_model.sv", "tb_g6lc_storamic_policy_writer.sv"]
                    for label, flags in [
                        ("rsp0", ["-GRspCycles=0"]), ("rsp4", ["-GRspCycles=4"]),
                        ("rsp16", ["-GRspCycles=16"]), ("off", ["-GEnabled=0"]),
                        ("active-loss-reset", ["-GLossWithDriver=1", "-GRspCycles=4"]),
                    ]:
                        record_cases.append((
                            f"policy-writer-{label}", "tb_g6lc_storamic_policy_writer", flags, inputs,
                            "POLICY_WRITER_PASS", "POLICY_WRITER_FAIL negative-oracle"))
            if "checkpoint-endpoint" in stages:
                endpoint_inputs = model_inputs[:-1] + [
                    "g6lc_storamic_axi_refuse.sv", "g6lc_storamic_checkpoint_service.sv",
                    "g6lc_storamic_checkpoint_endpoint.sv",
                    "tb_g6lc_storamic_checkpoint_endpoint.sv"]
                for delay in (0, 4, 16):
                    record_cases.append((
                        f"checkpoint-endpoint-rsp{delay}", "tb_g6lc_storamic_checkpoint_endpoint",
                        [f"-GRspCycles={delay}"], endpoint_inputs,
                        "CHECKPOINT_ENDPOINT_PASS", "CHECKPOINT_ENDPOINT_FAIL negative-oracle"))
                record_cases.append((
                    "checkpoint-endpoint-disabled", "tb_g6lc_storamic_checkpoint_endpoint",
                    ["-GEnabled=0"], endpoint_inputs,
                    "CHECKPOINT_ENDPOINT_PASS", "CHECKPOINT_ENDPOINT_FAIL negative-oracle"))
                record_cases.append((
                    "checkpoint-endpoint-bad-layout", "tb_g6lc_storamic_checkpoint_endpoint",
                    ["-GRawFlashBytes=256"], endpoint_inputs,
                    "STORAMIC_CHECKPOINT_ENDPOINT_CONFIG", None))
        if "checkpoint-service" in stages:
            record_cases.append((
                "checkpoint-service", "tb_g6lc_storamic_checkpoint_service", [],
                ["g6lc_storamic_pkg.sv", "g6lc_storamic_checkpoint_service.sv",
                 "tb_g6lc_storamic_checkpoint_service.sv"],
                "CHECKPOINT_SERVICE_PASS", "CHECKPOINT_SERVICE_FAIL negative-oracle"))
        if "checkpoint-policy" in stages:
            record_cases.append((
                "checkpoint-policy", "tb_g6lc_storamic_checkpoint_policy", [],
                ["g6lc_storamic_pkg.sv", "g6lc_storamic_checkpoint_service.sv",
                 "g6lc_storamic_checkpoint_policy.sv", "tb_g6lc_storamic_checkpoint_policy.sv"],
                "CHECKPOINT_POLICY_PASS", "CHECKPOINT_POLICY_FAIL negative-oracle"))
        for name, top, flags, inputs, token, negative_token in record_cases:
            model = out / name
            command = [
                str(verilator), "--binary", "--timing", "--assert", "-j", "1", "--threads", "1",
                "-Wno-fatal", "-Werror-LATCH", "-Werror-UNOPTFLAT", "-Werror-PINMISSING",
                "--top-module", top, "--Mdir", str(model), "-o", "test", *flags,
                *[str(data / item) for item in inputs],
            ]
            builds.append(build_model(command, model, out / f"{name}-build.log", manifest))
            run = subprocess.run([str(model / "test")], capture_output=True, text=True, timeout=180)
            text = run.stdout + run.stderr
            (out / f"{name}-sim.log").write_text(text)
            if negative_token is None:
                if run.returncode == 0 or token not in text:
                    raise RuntimeError(f"{name}: illegal configuration did not reject")
                outcomes.append({"checkpoint_config_rejected": name, "pass": True})
                continue
            if run.returncode != 0 or text.count(token) != 1:
                raise RuntimeError(f"{name}: unexpected verdict: {text[-4000:]}")
            checks = int(next(line for line in text.splitlines() if token in line)
                         .split("checks=")[1].split()[0])
            negative = subprocess.run([str(model / "test"), "+oracle_negative"],
                                      capture_output=True, text=True, timeout=180)
            text = negative.stdout + negative.stderr
            (out / f"{name}-negative.log").write_text(text)
            if negative.returncode == 0 or token in text or negative_token not in text:
                raise RuntimeError(f"{name}: negative oracle did not reject")
            outcomes.append({"checkpoint_record": name, "checks": checks,
                             "negative_oracle": True, "pass": True})
    if "checkpoint-ram" in stages:
        for delay in (0, 1, 4, 16):
            name = f"checkpoint-ram-rsp{delay}"
            model = out / name
            command = [
                str(verilator), "--binary", "--timing", "--assert",
                "-j", "1", "--threads", "1", "-Wno-fatal",
                "-Werror-LATCH", "-Werror-UNOPTFLAT", "-Werror-PINMISSING",
                f"-GRspCycles={delay}", "--top-module", "tb_g6lc_storamic_checkpoint_ram",
                "--Mdir", str(model), "-o", "checkpoint-test",
                *[str(data / p) for p in [
                    "g6lc_storamic_pkg.sv", "tc_sram.sv", "tc_sram_wrapper.sv", "sram.sv",
                    "g6lc_storamic_sim_mem.sv", "tb_g6lc_storamic_checkpoint_ram.sv",
                ]],
            ]
            builds.append(build_model(command, model, out / f"{name}-build.log", manifest))
            executable = str(model / "checkpoint-test")
            run = subprocess.run([executable], capture_output=True, text=True, timeout=120)
            text = run.stdout + run.stderr
            (out / f"{name}-sim.log").write_text(text)
            if run.returncode != 0 or "CHECKPOINT_RAM_PASS" not in text:
                raise RuntimeError(f"{name}: unexpected verdict: {text[-4000:]}")
            negative = subprocess.run([executable, "+oracle_negative"],
                                      capture_output=True, text=True, timeout=120)
            text = negative.stdout + negative.stderr
            (out / f"{name}-negative.log").write_text(text)
            if (negative.returncode == 0 or "CHECKPOINT_RAM_PASS" in text or
                    "CHECKPOINT_RAM_FAIL negative-oracle" not in text):
                raise RuntimeError(f"{name}: negative oracle did not reject as expected")
            outcomes.append({"checkpoint-ram": "tb", "rsp_cycles": delay,
                             "negative_oracle": True, "pass": True})
    if "checkpoint-ctrl" in stages:
        for delay in (0, 4, 16):
            name = f"checkpoint-ctrl-rsp{delay}"
            model = out / name
            command = [
                str(verilator), "--binary", "--timing", "--assert",
                "-j", "1", "--threads", "1", "-Wno-fatal",
                "-Werror-LATCH", "-Werror-UNOPTFLAT", "-Werror-PINMISSING",
                f"-GRamRspCycles={delay}", f"-GFlashRspCycles={delay}",
                "--top-module", "tb_g6lc_storamic_checkpoint_ctrl",
                "--Mdir", str(model), "-o", "checkpoint-test",
                *[str(data / p) for p in [
                    "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
                    "g6lc_storamic_region_pkg.sv", "g6lc_storamic_axi_memory.sv",
                    "g6lc_storamic_checkpoint_ctrl.sv", "tc_sram.sv", "tc_sram_wrapper.sv",
                    "sram.sv", "g6lc_storamic_sim_mem.sv", "g6lc_storamic_durable_store.sv",
                    "tb_g6lc_storamic_checkpoint_ctrl.sv",
                ]],
            ]
            builds.append(build_model(command, model, out / f"{name}-build.log", manifest))
            executable = str(model / "checkpoint-test")
            run = subprocess.run([executable], capture_output=True, text=True, timeout=120)
            text = run.stdout + run.stderr
            (out / f"{name}-sim.log").write_text(text)
            if run.returncode != 0 or "CHECKPOINT_CTRL_PASS" not in text:
                raise RuntimeError(f"{name}: unexpected verdict: {text[-4000:]}")
            negative = subprocess.run([executable, "+oracle_negative"],
                                      capture_output=True, text=True, timeout=120)
            text = negative.stdout + negative.stderr
            (out / f"{name}-negative.log").write_text(text)
            if (negative.returncode == 0 or "CHECKPOINT_CTRL_PASS" in text or
                    "CHECKPOINT_CTRL_FAIL negative-oracle" not in text):
                raise RuntimeError(f"{name}: negative oracle did not reject as expected")
            outcomes.append({"checkpoint_ctrl": "tb", "rsp_cycles": delay,
                             "negative_oracle": True, "pass": True})
    if "vdma" in stages:
        # vdma-inval: InvalEn=1, every Storamic write invalidates its block
        # through the cluster CMO port before completing.
        for name, flags in [("vdma", []), ("vdma-inval", ["-GInvalEn=1"])]:
            command = [
                str(verilator), "--binary", "--timing", "--assert",
                "-j", "1", "--threads", "1", "-Wno-fatal",
                "-Werror-LATCH", "-Werror-UNOPTFLAT", *flags,
                "--top-module", "tb_g6lc_storamic_dma_axi",
                "--Mdir", str(out / name), "-o", "vdma-test",
                *[str(data / p) for p in [
                    "g6lc_storamic_dma_axi.sv", "tb_g6lc_storamic_dma_axi.sv",
                ]],
            ]
            builds.append(build_model(command, out / name,
                                      out / f"{name}-build.log", manifest))
            run = subprocess.run([str(out / name / "vdma-test")],
                                 capture_output=True, text=True, timeout=300)
            text = run.stdout + run.stderr
            (out / f"{name}-sim.log").write_text(text)
            if run.returncode != 0 or "VDMA_PASS" not in text:
                raise RuntimeError(f"{name}: unexpected verdict: {text[-4000:]}")
            outcomes.append({"vdma": name, "pass": True})
            negative = subprocess.run(
                [str(out / name / "vdma-test"), "+oracle_negative"],
                capture_output=True, text=True, timeout=120)
            text = negative.stdout + negative.stderr
            (out / f"{name}-oracle-negative.log").write_text(text)
            if "VDMA_PASS" in text or negative.returncode == 0:
                raise RuntimeError(f"{name}: negative oracle accepted")
            outcomes.append({"vdma_negative_oracle": name})
    if "vdma-ownership" in stages:
        top = "tb_g6lc_storamic_dma_ownership"
        failures = []
        for case in range(7):
            model = out / f"vdma-ownership-{case}"
            command = [
                str(verilator), "--binary", "--timing", "--assert",
                "-j", "1", "--threads", "1", "-Wno-fatal",
                "-Werror-LATCH", "-Werror-UNOPTFLAT", "--top-module", top,
                f"-GCase={case}", "--Mdir", str(model), "-o", "ownership-test",
                *[str(data / name) for name in [
                    "g6lc_storamic_pkg.sv", "g6lc_storamic_dma_axi.sv",
                    "tb_g6lc_storamic_dma_ownership.sv"]],
            ]
            builds.append(build_model(command, model, out / f"ownership-{case}-build.log", manifest))
            for negative in (False, True):
                run = subprocess.run(
                    [str(model / "ownership-test"), *(["+oracle_negative"] if negative else [])],
                    capture_output=True, text=True, timeout=120)
                text = run.stdout + run.stderr
                kind = "negative" if negative else "sim"
                (out / f"ownership-{case}-{kind}.log").write_text(text)
                if negative:
                    if run.returncode == 0 or "DMA_OWNERSHIP_FAIL negative-oracle" not in text:
                        failures.append(f"case{case}: negative oracle did not reject")
                elif run.returncode != 0 or "DMA_OWNERSHIP_PASS" not in text:
                    failures.append(f"case{case}: {text[-2000:]}")
                    break
                outcomes.append({"vdma_ownership": case, "negative": negative, "pass": True})
        if failures:
            raise RuntimeError("DMA ownership failures: " + "\n".join(failures))
    if "ctrl" in stages:
        # ctrl-stall holds the AXI-Lite W channel off after each AW so the
        # bridge must track the two handshakes independently.
        for name, flags in [("ctrl", []), ("ctrl-stall", ["-GStallW=1"]),
                            ("ctrl-ioonly", ["-GCtrlPageEn=0"])]:
            command = [
                str(verilator), "--binary", "--timing", "--assert",
                "-j", "1", "--threads", "1", "-Wno-fatal",
                "-Werror-LATCH", "-Werror-UNOPTFLAT",
                "--top-module", "tb_g6lc_storamic_ctrl_bridge",
                "--Mdir", str(out / name), "-o", "ctrl-test", *flags,
                *[str(data / p) for p in [
                    "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
                    "g6lc_storamic_region_pkg.sv", "g6lc_storamic_regs.sv",
                    "g6lc_storamic_virtio_mmio.sv",
                    "g6lc_storamic_ctrl_bridge.sv",
                    "tb_g6lc_storamic_ctrl_bridge.sv",
                ]],
            ]
            builds.append(build_model(command, out / name,
                                      out / f"{name}-build.log", manifest))
            run = subprocess.run([str(out / f"{name}/ctrl-test")],
                                 capture_output=True, text=True, timeout=120)
            text = run.stdout + run.stderr
            (out / f"{name}-sim.log").write_text(text)
            if run.returncode != 0 or "STORAMIC_CTRL_PASS" not in text:
                raise RuntimeError(f"{name}: unexpected verdict: {text[-4000:]}")
            outcomes.append({"ctrl": name, "pass": True})
        negative = subprocess.run(
            [str(out / "ctrl/ctrl-test"), "+oracle_negative"],
            capture_output=True, text=True, timeout=60)
        text = negative.stdout + negative.stderr
        (out / "ctrl-oracle-negative.log").write_text(text)
        if "STORAMIC_CTRL_PASS" in text or negative.returncode == 0:
            raise RuntimeError("ctrl: negative oracle accepted")
    if "model" in stages:
        model_inputs = [
            *source_names[:-1],
            "g6lc_storamic_sram_model.sv", "tb_g6lc_storamic_model.sv",
        ]
        model_cases = [
            ("narrow", [], None),
            ("wide", ["-GDataWidth=512", "-GIdWidth=9"], None),
            ("byte", ["-GDataWidth=8", "-GIdWidth=1"], None),
            ("high", ["-GBaseAddr=64'hffffffffffffe000"], None),
            ("sequence", ["-GSeqWidth=2", "-GSequenceTest=1"], None),
            ("geometry", ["-GBadGeometry=1"], "STORAMIC_MODEL_CONFIG_ILLEGAL"),
            ("id", ["-GIdWidth=17"], "STORAMIC_MODEL_CONFIG_ILLEGAL"),
            ("sequence-width", ["-GSeqWidth=0"], "STORAMIC_MODEL_CONFIG_ILLEGAL"),
            ("width", ["-GDataWidth=24"], "STORAMIC_MODEL_CONFIG_ILLEGAL"),
            ("alignment", ["-GBaseAddr=64'h80000001"], "STORAMIC_MODEL_CONFIG_ILLEGAL"),
        ]
        top_cases = [
            ("top-narrow", [], None),
            ("top-wide", ["-GDataWidth=512", "-GIdWidth=9"], None),
            ("top-maximum", ["-GDataWidth=1024", "-GIdWidth=16"], None),
            ("top-byte", ["-GDataWidth=8", "-GIdWidth=1"], None),
            ("top-high", ["-GBaseAddr=64'hffffffffffffe000"], None),
            ("top-sequence", ["-GSeqWidth=2", "-GSequenceTest=1"], None),
            ("top-unknown", ["-GTopProfile=3"], "STORAMIC_CONFIG_ILLEGAL"),
            ("top-disabled", ["-GTopEnable=0"], "STORAMIC_CONFIG_ILLEGAL"),
            ("top-slots", ["-GTopSticks=2"], "STORAMIC_CONFIG_ILLEGAL"),
            ("top-caps", ["-GTopRequestedCaps=1"], "STORAMIC_CONFIG_ILLEGAL"),
            ("top-geometry", ["-GBadGeometry=1"], "STORAMIC_CONFIG_ILLEGAL"),
            ("top-overflow", ["-GBaseAddr=64'hfffffffffffff000"], "STORAMIC_CONFIG_ILLEGAL"),
            ("top-id", ["-GIdWidth=17"], "STORAMIC_MODEL_CONFIG_ILLEGAL"),
            ("top-width", ["-GDataWidth=24"], "STORAMIC_MODEL_CONFIG_ILLEGAL"),
            ("top-sequence-width", ["-GSeqWidth=0"], "STORAMIC_MODEL_CONFIG_ILLEGAL"),
            ("top-alignment", ["-GBaseAddr=64'h80000001"], "STORAMIC_MODEL_CONFIG_ILLEGAL"),
        ]
        model_cases += [(name, ["-GUseTopProfile=1", *flags], error)
                        for name, flags, error in top_cases]
        for name, flags, error in model_cases:
            model = out / f"model-{name}"
            command = [
                str(verilator), "--binary", "--timing", "--assert", "-j", "1",
                "-Wno-fatal", "-Werror-LATCH", "-Werror-UNOPTFLAT",
                "--top-module", "tb_g6lc_storamic_model", "--Mdir", str(model),
                "-o", "model-test", *flags, *[str(data / p) for p in model_inputs],
            ]
            builds.append(build_model(command, model, out / f"model-{name}-build.log", manifest,
                                      pgo_compile_timeout=1800 if name == "top-maximum" else 300))
            run = subprocess.run([str(model / "model-test")], capture_output=True,
                                 text=True, timeout=60)
            text = run.stdout + run.stderr
            (out / f"model-{name}.log").write_text(text)
            token = ("STORAMIC_MODEL_SEQUENCE_PASS" if "-GSequenceTest=1" in flags
                     else "STORAMIC_MODEL_PASS")
            matched = (run.returncode != 0 and error in text) if error else (
                run.returncode == 0 and text.count(token) == 1)
            outcomes.append({"model": name, "expected_error": error, "pass": matched})
            (out / "stage-results.json").write_text(json.dumps(outcomes, indent=2))
            if not matched:
                raise RuntimeError(f"unexpected model verdict: {name}: {text[-4000:]}")
        for name in ("narrow", "top-narrow"):
            run = subprocess.run([str(out / f"model-{name}/model-test"), "+MODEL_CORRUPT"],
                                 capture_output=True, text=True, timeout=60)
            text = run.stdout + run.stderr
            (out / f"model-{name}-oracle-negative.log").write_text(text)
            if run.returncode == 0 or "STORAMIC_MODEL_READ" not in text:
                raise RuntimeError(f"STORAMIC_MODEL_ORACLE_INEFFECTIVE: {name}")
            outcomes.append({"model_negative_oracle": True, "binding": name})
    if "integration" in stages or "synth" in stages:
        include = out / "include/axi"
        include.mkdir(parents=True)
        shutil.copyfile(data / "assign.svh", include / "assign.svh")
        shutil.copyfile(data / "typedef.svh", include / "typedef.svh")
        common = include.parent / "common_cells"
        common.mkdir()
        shutil.copyfile(data / "registers.svh", common / "registers.svh")
    if "integration" in stages:
        inputs = [
            "axi_pkg.sv", "axi_intf.sv", "cf_math_pkg.sv",
            "lzc.sv", "rr_arb_tree.sv", "fifo_v3.sv",
            "spill_register_flushable.sv", "spill_register.sv",
            "axi_id_prepend.sv", "axi_mux.sv", *source_names[:-1],
            "g6lc_storamic_soc_cfg_pkg.sv", "g6lc_storamic_attach.sv",
            "g6lc_storamic_sim_mem.sv", "tc_sram.sv",
            "tc_sram_wrapper.sv", "sram.sv",
            "g6lc_ai_island_cfg_pkg.sv", "g6lc_ai_dram_backend.sv",
            "g6lc_ai_dram_join.sv",
            "tb_g6lc_storamic_soc.sv",
        ]
        cases = [
            ("narrow", ["-DG6LC_STORAMIC_SKELETON"], None),
            ("wide", ["-DG6LC_STORAMIC_SKELETON", "-GDataWidth=512", "-GIdWidth=9"], None),
            ("joined-cluster", ["-DG6LC_STORAMIC_SKELETON", "-GJoined=1"], None),
            ("joined-island", ["-DG6LC_STORAMIC_SKELETON", "-GJoined=1", "-GSource=1"], None),
            ("joined-wide", ["-DG6LC_STORAMIC_SKELETON", "-GJoined=1", "-GDataWidth=512"], None),
            ("joined-island-wide", ["-DG6LC_STORAMIC_SKELETON", "-GJoined=1",
                                    "-GSource=1", "-GDataWidth=512"], None),
            ("old-readiness", ["-DG6LC_STORAMIC_SKELETON", "-GJoined=1", "-GLegacyGate=1"],
             "STORAMIC_SOC_TIMEOUT"),
            ("ddr", ["-DG6LC_STORAMIC_SKELETON", "-GDramClass=1"], "STORAMIC_BACKEND_CONFLICT"),
            ("lpddr", ["-DG6LC_STORAMIC_SKELETON", "-GDramClass=2"], "STORAMIC_BACKEND_CONFLICT"),
            ("stripe", ["-DG6LC_STORAMIC_SKELETON", "-GNrChannels=2"], "STORAMIC_BACKEND_CONFLICT"),
            ("define", ["-DG6LC_STORAMIC_SKELETON", "-DG6LC_AI_DRAM_CLASS1"], "STORAMIC_BACKEND_CONFLICT"),
            ("profile", [], "STORAMIC_CONFIG_ILLEGAL"),
            ("width", ["-DG6LC_STORAMIC_SKELETON", "-GDataWidth=24"], "STORAMIC_WIDTH_ILLEGAL"),
            ("address-shape", ["-DG6LC_STORAMIC_SKELETON", "-GBackendAddrWidth=32"],
             "STORAMIC_INTERFACE_SHAPE"),
            ("model", ["-DG6LC_STORAMIC_MODEL", "-GModel=1"], None),
            ("checkpoint-unbound", ["-DG6LC_STORAMIC_MODEL", "-GModel=1",
                                    "-GCheckpointRequested=1"],
             "STORAMIC_CHECKPOINT_NATIVE_BINDING_REQUIRED"),
            ("model-conflict", ["-DG6LC_STORAMIC_MODEL", "-DG6LC_STORAMIC_SKELETON",
                                "-GModel=1"], "STORAMIC_PROFILE_CONFLICT"),
        ]
        for name, flags, error in cases:
            model = out / f"soc-{name}"
            command = [
                str(verilator), "--binary", "--timing", "--assert", "-j", "1",
                "-Wno-fatal", "-Werror-LATCH", "-Werror-UNOPTFLAT",
                "--top-module", "tb_g6lc_storamic_soc", "-I" + str(include.parent),
                "--Mdir", str(model), "-o", "soc-test",
                *flags, *[str(data / p) for p in inputs],
            ]
            builds.append(build_model(command, model, out / f"soc-{name}-build.log", manifest))
            run = subprocess.run([str(model / "soc-test")], capture_output=True,
                                 text=True, timeout=30)
            text = run.stdout + run.stderr
            (out / f"soc-{name}.log").write_text(text)
            matched = (run.returncode != 0 and error in text) if error else (
                run.returncode == 0 and "STORAMIC_SOC_PASS" in text)
            if not matched:
                raise RuntimeError(f"unexpected integration verdict: {name}")
            outcomes.append({"integration": name, "expected_error": error, "pass": True})
        # ST-011B model negative oracle: corrupting one expected byte must fail.
        negative = subprocess.run(
            [str(out / "soc-model/soc-test"), "+oracle_negative"],
            capture_output=True, text=True, timeout=30)
        text = negative.stdout + negative.stderr
        (out / "soc-model-oracle-negative.log").write_text(text)
        if "STORAMIC_SOC_PASS" in text or negative.returncode == 0:
            raise RuntimeError("integration model: negative oracle accepted")
    if set(stages) & {"synth", "formal", "model-synth", "model-formal", "map-synth",
                      "map-formal", "discovery-synth", "discovery-formal",
                      "regs-synth", "regs-formal", "ctrl-synth",
                      "virtio-synth", "virtio-formal", "vring-synth",
                      "vring-formal", "vblk-synth", "vdev-synth",
                      "vblk-formal", "vblk-flush-formal", "quiesce-formal",
                      "checkpoint-synth", "checkpoint-formal",
                      "checkpoint-record-synth", "checkpoint-record-formal", "checkpoint-model-synth",
                      "checkpoint-service-synth", "checkpoint-service-formal",
                      "checkpoint-endpoint-synth", "checkpoint-endpoint-formal",
                      "checkpoint-codec-formal", "checkpoint-io-formal",
                      "checkpoint-policy-synth", "checkpoint-policy-formal",
                      "checkpoint-writer-synth", "checkpoint-writer-formal",
                      "vdma-ownership-formal", "policy-writer-synth", "policy-writer-formal"}:
        sys.path.insert(0, str(data))
        from yosys_bin import yosys_bin
        yosys = Path(yosys_bin())
        manifest["yosys"] = str(yosys)
        manifest["yosys_sha256"] = sha(yosys)
        (out / "manifest.json").write_text(json.dumps(manifest, indent=2))
        if "checkpoint-policy-synth" in stages:
            for enabled in (0, 1):
                tag = f"checkpoint-policy-synth-{enabled}"
                script = out / f"{tag}.ys"
                script.write_text(
                    f"read_slang --top g6lc_storamic_checkpoint_policy -GEnable={enabled} " +
                    str(data / "g6lc_storamic_checkpoint_policy.sv") +
                    "\nhierarchy -check\nproc\nflatten\nopt -full\ncheck -assert\nscc -expect 0\nstat\n" +
                    f"write_json {out}/{tag}.json\n")
                with (out / f"{tag}.log").open("w") as log:
                    subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                                   stderr=subprocess.STDOUT, check=True, timeout=180)
                module = json.loads((out / f"{tag}.json").read_text())["modules"][
                    "g6lc_storamic_checkpoint_policy"]
                cells = module["cells"]
                if (bool(cells) != bool(enabled) or module.get("memories") or
                        any("latch" in cell["type"].lower() for cell in cells.values())):
                    raise RuntimeError(f"{tag}: inactive state, latch or memory")
                outcomes.append({"checkpoint_policy_synth": tag, "cells": len(cells), "pass": True})
        if "checkpoint-policy-formal" in stages:
            top = "formal_g6lc_storamic_checkpoint_policy"
            for enabled, bad, cover in ((1, 0, False), (0, 0, False), (1, 0, True), (1, 1, False)):
                tag = f"checkpoint-policy-formal-{enabled}-bad{bad}-cover{int(cover)}"
                prefix = (f"read_slang --top {top} -DSYNTHESIS -GEnabled={enabled} " +
                          f"-GOracleNegative={bad} " +
                          str(data / "g6lc_storamic_checkpoint_policy.sv") + " " +
                          str(data / f"{top}.sv") +
                          "\nprep -top " + top + "\nasync2sync\nflatten\nopt\ndffunmap\nopt_clean\n")
                result = run_smt(prefix, top, tag, 24, out, yosys, manifest, cover=cover)
                text = (out / f"{tag}.log").read_text()
                if (bad and (result.returncode == 0 or "Status: FAILED" not in text)) or (
                        not bad and (result.returncode != 0 or "Status: PASSED" not in text)):
                    raise RuntimeError(f"{tag}: unexpected formal verdict")
                outcomes.append({"checkpoint_policy_formal": tag, "depth": 24, "pass": True})
        memory_sources = [data / "g6lc_storamic_cfg_pkg.sv",
                          data / "g6lc_storamic_pkg.sv",
                          data / "g6lc_storamic_region_pkg.sv",
                          data / "g6lc_storamic_axi_memory.sv"]
        if "model-synth" in stages:
            model_synthesis = [
                ("model-synth", "g6lc_storamic_axi_memory", memory_sources),
                ("model-top-synth", "g6lc_storamic_model_synth",
                 [*[data / name for name in source_names[:-1]],
                  data / "tb_g6lc_storamic_model.sv"]),
            ]
            for name, top, synthesis_sources in model_synthesis:
                script = out / f"{name}.ys"
                script.write_text(
                    f"read_slang --std 1800-2017 --top {top} -DSYNTHESIS " +
                    " ".join(map(str, synthesis_sources)) +
                    "\nhierarchy -check\nproc\nflatten\nopt\ncheck -assert\nscc -expect 0\nstat\n" +
                    f"write_json {out}/{name}.json\n")
                with (out / f"{name}.log").open("w") as log:
                    subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                                   stderr=subprocess.STDOUT, check=True, timeout=300)
                memory_cells = json.loads((out / f"{name}.json").read_text())["modules"][top]["cells"]
                if not memory_cells or any("latch" in cell["type"].lower()
                                           for cell in memory_cells.values()):
                    raise RuntimeError(f"empty synthesized model or latch: {top}")
                outcomes.append({"model_synth": top, "cells": len(memory_cells),
                                 "latches": 0, "scc": 0})
        if "map-synth" in stages:
            map_sources = [data / name for name in [
                "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
                "g6lc_storamic_pad_pkg.sv", "g6lc_storamic_axi_refuse.sv",
                "g6lc_storamic_region_pkg.sv", "g6lc_storamic_axi_memory.sv",
                "g6lc_storamic_slot_mux.sv", "g6lc_storamic_regs.sv", "g6lc_storamic_top.sv",
                "tb_g6lc_storamic_map.sv",
            ]]
            script = out / "map-synth.ys"
            script.write_text(
                "read_slang --std 1800-2017 --top g6lc_storamic_map_synth " +
                "-DSYNTHESIS " + " ".join(map(str, map_sources)) +
                "\nhierarchy -check\nproc\nflatten\nopt\ncheck -assert\nscc -expect 0\nstat\n" +
                f"write_json {out}/map-synth.json\n")
            with (out / "map-synth.log").open("w") as log:
                subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                               stderr=subprocess.STDOUT, check=True, timeout=300)
            map_cells = json.loads((out / "map-synth.json").read_text())[
                "modules"]["g6lc_storamic_map_synth"]["cells"]
            if not map_cells or any("latch" in cell["type"].lower()
                                    for cell in map_cells.values()):
                raise RuntimeError("empty synthesized map frontend or latch")
            outcomes.append({"map_synth": "g6lc_storamic_map_synth",
                             "cells": len(map_cells), "latches": 0, "scc": 0})
        if "discovery-synth" in stages:
            disc_sources = [data / name for name in [
                "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
                "g6lc_storamic_region_pkg.sv", "g6lc_storamic_discovery_pkg.sv",
                "g6lc_storamic_sync.sv", "g6lc_storamic_discovery.sv",
                "g6lc_storamic_discovery_set.sv", "tb_g6lc_storamic_discovery.sv",
            ]]
            script = out / "discovery-synth.ys"
            script.write_text(
                "read_slang --std 1800-2017 --top g6lc_storamic_discovery_synth " +
                "-DSYNTHESIS " + " ".join(map(str, disc_sources)) +
                "\nhierarchy -check\nproc\nflatten\nopt\ncheck -assert\nscc -expect 0\nstat\n" +
                f"write_json {out}/discovery-synth.json\n")
            with (out / "discovery-synth.log").open("w") as log:
                subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                               stderr=subprocess.STDOUT, check=True, timeout=300)
            cells = json.loads((out / "discovery-synth.json").read_text())[
                "modules"]["g6lc_storamic_discovery_synth"]["cells"]
            if not cells or any("latch" in cell["type"].lower()
                                for cell in cells.values()):
                raise RuntimeError("empty synthesized discovery set or latch")
            outcomes.append({"discovery_synth_cells": len(cells),
                             "latches": 0, "scc": 0})
        if "regs-synth" in stages:
            regs_sources = [data / name for name in [
                "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
                "g6lc_storamic_region_pkg.sv", "g6lc_storamic_regs.sv",
                "tb_g6lc_storamic_regs.sv",
            ]]
            script = out / "regs-synth.ys"
            script.write_text(
                "read_slang --std 1800-2017 --top g6lc_storamic_regs_synth " +
                "-DSYNTHESIS " + " ".join(map(str, regs_sources)) +
                "\nhierarchy -check\nproc\nflatten\nopt\ncheck -assert\nscc -expect 0\nstat\n" +
                f"write_json {out}/regs-synth.json\n")
            with (out / "regs-synth.log").open("w") as log:
                subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                               stderr=subprocess.STDOUT, check=True, timeout=300)
            cells = json.loads((out / "regs-synth.json").read_text())[
                "modules"]["g6lc_storamic_regs_synth"]["cells"]
            if not cells or any("latch" in cell["type"].lower()
                                for cell in cells.values()):
                raise RuntimeError("empty synthesized regs or latch")
            outcomes.append({"regs_synth_cells": len(cells),
                             "latches": 0, "scc": 0})
        if "ctrl-synth" in stages:
            ctrl_sources = [data / name for name in [
                "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
                "g6lc_storamic_region_pkg.sv", "g6lc_storamic_regs.sv",
                "g6lc_storamic_ctrl_bridge.sv", "tb_g6lc_storamic_ctrl_bridge.sv",
            ]]
            script = out / "ctrl-synth.ys"
            script.write_text(
                "read_slang --std 1800-2017 --top g6lc_storamic_ctrl_bridge_synth " +
                "-DSYNTHESIS " + " ".join(map(str, ctrl_sources)) +
                "\nhierarchy -check\nproc\nflatten\nopt\ncheck -assert\nscc -expect 0\nstat\n" +
                f"write_json {out}/ctrl-synth.json\n")
            with (out / "ctrl-synth.log").open("w") as log:
                subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                               stderr=subprocess.STDOUT, check=True, timeout=300)
            cells = json.loads((out / "ctrl-synth.json").read_text())[
                "modules"]["g6lc_storamic_ctrl_bridge_synth"]["cells"]
            if not cells or any("latch" in cell["type"].lower()
                                for cell in cells.values()):
                raise RuntimeError("empty synthesized bridge or latch")
            outcomes.append({"ctrl_synth_cells": len(cells),
                             "latches": 0, "scc": 0})
            # ST-037C: the CtrlPageEn=0 (IO-only) variant must also synth
            # clean — no latches, no combinational loops.
            io_script = out / "ctrl-synth-io.ys"
            io_script.write_text(
                "read_slang --std 1800-2017 "
                "--top g6lc_storamic_ctrl_bridge_io_synth " +
                "-DSYNTHESIS " + " ".join(map(str, ctrl_sources)) +
                "\nhierarchy -check\nproc\nflatten\nopt\ncheck -assert\n"
                "scc -expect 0\nstat\n" +
                f"write_json {out}/ctrl-synth-io.json\n")
            with (out / "ctrl-synth-io.log").open("w") as log:
                subprocess.run([str(yosys), "-s", str(io_script)], stdout=log,
                               stderr=subprocess.STDOUT, check=True,
                               timeout=300)
            io_cells = json.loads((out / "ctrl-synth-io.json").read_text())[
                "modules"]["g6lc_storamic_ctrl_bridge_io_synth"]["cells"]
            if not io_cells or any("latch" in cell["type"].lower()
                                   for cell in io_cells.values()):
                raise RuntimeError("empty synthesized io bridge or latch")
            outcomes.append({"ctrl_io_synth_cells": len(io_cells),
                             "latches": 0, "scc": 0})
        if "vdev-synth" in stages:
            vd_sources = [data / name for name in [
                "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
                "g6lc_storamic_virtio_mmio.sv", "g6lc_storamic_virtio_ring.sv",
                "g6lc_storamic_virtio_blk.sv", "g6lc_storamic_virtio_dev.sv",
                "tb_g6lc_storamic_virtio_dev.sv",
            ]]
            script = out / "vdev-synth.ys"
            script.write_text(
                "read_slang --std 1800-2017 --top g6lc_storamic_virtio_dev_synth " +
                "-DSYNTHESIS " + " ".join(map(str, vd_sources)) +
                "\nhierarchy -check\nproc\nflatten\nopt\ncheck -assert\nscc -expect 0\nstat\n" +
                f"write_json {out}/vdev-synth.json\n")
            with (out / "vdev-synth.log").open("w") as log:
                subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                               stderr=subprocess.STDOUT, check=True, timeout=600)
            cells = json.loads((out / "vdev-synth.json").read_text())[
                "modules"]["g6lc_storamic_virtio_dev_synth"]["cells"]
            if not cells or any("latch" in cell["type"].lower()
                                for cell in cells.values()):
                raise RuntimeError("empty synthesized device or latch")
            outcomes.append({"vdev_synth_cells": len(cells), "latches": 0, "scc": 0})
        if "vblk-formal" in stages:
            vb_inputs = [data / "g6lc_storamic_virtio_blk.sv",
                         data / "formal_g6lc_storamic_virtio_blk.sv"]
            vb_prefix = (
                "read_slang --std 1800-2017 --top formal_g6lc_storamic_virtio_blk " +
                "-DFORMAL " + " ".join(map(str, vb_inputs)) +
                "\nprep -top formal_g6lc_storamic_virtio_blk\nasync2sync\n" +
                "chformal -lower\nflatten\nopt -full\ndffunmap\nopt_clean -purge\n")
            for name, goal, depth in [
                ("safety", "-prove-asserts -verify -show-public", 14),
                ("status-cover", "-prove cover_status_o 0 -falsify", 14),
                ("rsp-cover", "-prove cover_rsp_o 0 -falsify", 16),
            ]:
                script = out / f"vblk-formal-{name}.ys"
                script.write_text(
                    vb_prefix +
                    f"sat -seq {depth} -set-init-zero -set-assumes -set-at 1 rst_ni 0 " + goal +
                    f" -show-ports -dump_vcd {out}/vblk-formal-{name}.vcd\n")
                with (out / f"vblk-formal-{name}.log").open("w") as log:
                    subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                                   stderr=subprocess.STDOUT, check=True, timeout=1800)
                outcomes.append({"vblk_formal": name, "depth": depth, "pass": True})
        if "vblk-flush-formal" in stages:
            # ST-037D: same wrapper with FlushEn=1; free flush ack/err
            # environment under the assume (response only while requested).
            # Initialize independently when this stage is selected alone.
            vb_inputs = [data / "g6lc_storamic_virtio_blk.sv",
                         data / "formal_g6lc_storamic_virtio_blk.sv"]
            vf_prefix = (
                "read_slang --std 1800-2017 --top "
                "formal_g6lc_storamic_virtio_blk_flush -DFORMAL " +
                " ".join(map(str, vb_inputs)) +
                "\nprep -top formal_g6lc_storamic_virtio_blk_flush\n" +
                "async2sync\nchformal -lower\nflatten\nopt -full\n" +
                "dffunmap\nopt_clean -purge\n")
            for name, goal, depth in [
                ("safety", "-prove-asserts -verify -show-public", 14),
                ("flush-cover", "-prove cover_flush_o 0 -falsify", 16),
            ]:
                script = out / f"vblk-flush-formal-{name}.ys"
                script.write_text(
                    vf_prefix +
                    f"sat -seq {depth} -set-init-zero -set-assumes -set-at 1 rst_ni 0 " + goal +
                    f" -show-ports -dump_vcd {out}/vblk-flush-formal-{name}.vcd\n")
                with (out / f"vblk-flush-formal-{name}.log").open("w") as log:
                    subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                                   stderr=subprocess.STDOUT, check=True, timeout=1800)
                outcomes.append({"vblk_flush_formal": name, "depth": depth, "pass": True})
        if "vblk-synth" in stages:
            vb_sources = [data / "g6lc_storamic_virtio_blk.sv",
                          data / "tb_g6lc_storamic_virtio_blk.sv"]
            script = out / "vblk-synth.ys"
            script.write_text(
                "read_slang --std 1800-2017 --top g6lc_storamic_virtio_blk_synth " +
                "-DSYNTHESIS " + " ".join(map(str, vb_sources)) +
                "\nhierarchy -check\nproc\nflatten\nopt\ncheck -assert\nscc -expect 0\nstat\n" +
                f"write_json {out}/vblk-synth.json\n")
            with (out / "vblk-synth.log").open("w") as log:
                subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                               stderr=subprocess.STDOUT, check=True, timeout=300)
            cells = json.loads((out / "vblk-synth.json").read_text())[
                "modules"]["g6lc_storamic_virtio_blk_synth"]["cells"]
            if not cells or any("latch" in cell["type"].lower()
                                for cell in cells.values()):
                raise RuntimeError("empty synthesized blk or latch")
            outcomes.append({"vblk_synth_cells": len(cells), "latches": 0, "scc": 0})
        if "vring-synth" in stages:
            vr_sources = [data / "g6lc_storamic_virtio_ring.sv",
                          data / "tb_g6lc_storamic_virtio_ring.sv"]
            script = out / "vring-synth.ys"
            script.write_text(
                "read_slang --std 1800-2017 --top g6lc_storamic_virtio_ring_synth " +
                "-DSYNTHESIS " + " ".join(map(str, vr_sources)) +
                "\nhierarchy -check\nproc\nflatten\nopt\ncheck -assert\nscc -expect 0\nstat\n" +
                f"write_json {out}/vring-synth.json\n")
            with (out / "vring-synth.log").open("w") as log:
                subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                               stderr=subprocess.STDOUT, check=True, timeout=300)
            cells = json.loads((out / "vring-synth.json").read_text())[
                "modules"]["g6lc_storamic_virtio_ring_synth"]["cells"]
            if not cells or any("latch" in cell["type"].lower()
                                for cell in cells.values()):
                raise RuntimeError("empty synthesized ring or latch")
            outcomes.append({"vring_synth_cells": len(cells), "latches": 0, "scc": 0})
        if "vring-formal" in stages:
            vr_inputs = [data / "g6lc_storamic_virtio_ring.sv",
                         data / "formal_g6lc_storamic_virtio_ring.sv"]
            vr_prefix = (
                "read_slang --std 1800-2017 --top formal_g6lc_storamic_virtio_ring " +
                "-DFORMAL " + " ".join(map(str, vr_inputs)) +
                "\nprep -top formal_g6lc_storamic_virtio_ring\nasync2sync\n" +
                "chformal -lower\nflatten\nopt -full\ndffunmap\nopt_clean -purge\n")
            for name, goal, depth in [
                ("safety", "-prove-asserts -verify -show-public", 12),
                ("done-cover", "-prove cover_done_o 0 -falsify", 22),
                ("fault-cover", "-prove cover_fault_o 0 -falsify", 12),
                ("resetwalk-cover", "-prove cover_reset_walk_o 0 -falsify", 12),
            ]:
                script = out / f"vring-formal-{name}.ys"
                script.write_text(
                    vr_prefix +
                    f"sat -seq {depth} -set-init-zero -set-assumes -set-at 1 rst_ni 0 " + goal +
                    f" -show-ports -dump_vcd {out}/vring-formal-{name}.vcd\n")
                with (out / f"vring-formal-{name}.log").open("w") as log:
                    subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                                   stderr=subprocess.STDOUT, check=True, timeout=1200)
                outcomes.append({"vring_formal": name, "depth": depth, "pass": True})
        if "virtio-synth" in stages:
            virtio_sources = [data / name for name in [
                "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
                "g6lc_storamic_region_pkg.sv",
                "g6lc_storamic_virtio_mmio.sv",
                "tb_g6lc_storamic_virtio_mmio.sv",
            ]]
            script = out / "virtio-synth.ys"
            script.write_text(
                "read_slang --std 1800-2017 --top g6lc_storamic_virtio_mmio_synth " +
                "-DSYNTHESIS " + " ".join(map(str, virtio_sources)) +
                "\nhierarchy -check\nproc\nflatten\nopt\ncheck -assert\nscc -expect 0\nstat\n" +
                f"write_json {out}/virtio-synth.json\n")
            with (out / "virtio-synth.log").open("w") as log:
                subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                               stderr=subprocess.STDOUT, check=True, timeout=300)
            cells = json.loads((out / "virtio-synth.json").read_text())[
                "modules"]["g6lc_storamic_virtio_mmio_synth"]["cells"]
            if not cells or any("latch" in cell["type"].lower()
                                for cell in cells.values()):
                raise RuntimeError("empty synthesized virtio or latch")
            outcomes.append({"virtio_synth_cells": len(cells),
                             "latches": 0, "scc": 0})
        if "virtio-formal" in stages:
            vformal_inputs = [data / name for name in [
                "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
                "g6lc_storamic_region_pkg.sv",
                "g6lc_storamic_virtio_mmio.sv",
                "formal_g6lc_storamic_virtio_mmio.sv",
            ]]
            vprefix = (
                "read_slang --std 1800-2017 --top formal_g6lc_storamic_virtio_mmio " +
                "-DFORMAL " + " ".join(map(str, vformal_inputs)) +
                "\nprep -top formal_g6lc_storamic_virtio_mmio\nasync2sync\n" +
                "chformal -lower\nflatten\nopt -full\ndffunmap\nopt_clean -purge\n")
            for name, goal, depth in [
                ("safety", "-prove-asserts -verify -show-public", 12),
                ("dok-cover", "-prove cover_dok_o 0 -falsify", 20),
                ("notify-cover", "-prove cover_notify_o 0 -falsify", 24),
                ("reset-cover", "-prove cover_reset_o 0 -falsify", 20),
            ]:
                script = out / f"virtio-formal-{name}.ys"
                script.write_text(
                    vprefix +
                    f"sat -seq {depth} -set-init-zero -set-assumes -set-at 1 rst_ni 0 " + goal +
                    f" -show-ports -dump_vcd {out}/virtio-formal-{name}.vcd\n")

                with (out / f"virtio-formal-{name}.log").open("w") as log:
                    subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                                   stderr=subprocess.STDOUT, check=True, timeout=900)
                outcomes.append({"virtio_formal": name, "depth": depth,
                                 "pass": True})
            pause_inputs = vformal_inputs[:-1] + [
                data / "formal_g6lc_storamic_virtio_pause.sv"]
            pause_prefix = (
                "read_slang --std 1800-2017 --top formal_g6lc_storamic_virtio_pause ")
            for name, goal, negative in [
                ("safety", "-prove-asserts -verify", False),
                ("aw-cover", "-prove cover_aw_o 0 -falsify", False),
                ("w-cover", "-prove cover_w_o 0 -falsify", False),
                ("b-cover", "-prove cover_b_o 0 -falsify", False),
                ("r-cover", "-prove cover_r_o 0 -falsify", False),
                ("drained-cover", "-prove cover_drained_o 0 -falsify", False),
                ("negative", "-prove-asserts -falsify", True),
            ]:
                tag = f"virtio-pause-{name}"
                script = out / f"{tag}.ys"
                script.write_text(
                    pause_prefix + f"-DFORMAL -G OracleNegative={int(negative)} " +
                    " ".join(map(str, pause_inputs)) + "\n" +
                    "prep -top formal_g6lc_storamic_virtio_pause\nasync2sync\n"
                    "chformal -lower\nflatten\nopt -full\ndffunmap\nopt_clean -purge\n" +
                    f"sat -seq 12 -set-init-zero -set-at 1 rst_ni 0 {goal} " +
                    f"-show-ports -dump_vcd {out}/{tag}.vcd\n")
                with (out / f"{tag}.log").open("w") as log:
                    subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                                   stderr=subprocess.STDOUT, check=True, timeout=900)
                outcomes.append({"virtio_pause_formal": name, "depth": 12,
                                 "negative_oracle": negative, "pass": True})
        if "map-formal" in stages:
            map_formal_inputs = [data / name for name in [
                "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
                "g6lc_storamic_pad_pkg.sv", "g6lc_storamic_axi_refuse.sv",
                "g6lc_storamic_region_pkg.sv", "g6lc_storamic_axi_memory.sv",
                "g6lc_storamic_regs.sv",
                "g6lc_storamic_top.sv", "formal_g6lc_storamic_map.sv",
            ]]
            map_formal_prefix = (
                "read_slang --std 1800-2017 --top formal_g6lc_storamic_map " +
                "-DFORMAL " + " ".join(map(str, map_formal_inputs)) +
                "\nprep -top formal_g6lc_storamic_map\nasync2sync\nchformal -lower\nflatten\n" +
                "opt -full\ndffunmap\nopt_clean -purge\n")
            map_formal_checks = [
                ("safety", "-prove-asserts -verify"),
                ("w0-cover", "-prove cover_w0_o 0 -falsify"),
                ("r1-cover", "-prove cover_r1_o 0 -falsify"),
                ("awref-cover", "-prove cover_awref_o 0 -falsify"),
                ("arref-cover", "-prove cover_arref_o 0 -falsify"),
            ]
            for name, goal in map_formal_checks:
                script = out / f"map-formal-{name}.ys"
                script.write_text(
                    map_formal_prefix +
                    "sat -seq 12 -set-init-zero -set-assumes -set-at 1 rst_ni 0 " + goal +
                    f" -show-ports -dump_vcd {out}/map-formal-{name}.vcd\n")
                with (out / f"map-formal-{name}.log").open("w") as log:
                    subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                                   stderr=subprocess.STDOUT, check=True, timeout=600)
                outcomes.append({"map_formal": name, "depth": 12, "pass": True})
        if "discovery-formal" in stages:
            disc_formal_inputs = [data / name for name in [
                "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
                "g6lc_storamic_region_pkg.sv", "g6lc_storamic_discovery_pkg.sv",
                "g6lc_storamic_sync.sv", "g6lc_storamic_discovery.sv",
                "formal_g6lc_storamic_discovery.sv",
            ]]
            disc_prefix = (
                "read_slang --std 1800-2017 --top formal_g6lc_storamic_discovery " +
                "-DFORMAL " + " ".join(map(str, disc_formal_inputs)) +
                "\nprep -top formal_g6lc_storamic_discovery\nasync2sync\n" +
                "chformal -lower\nflatten\nopt -full\ndffunmap\nopt_clean -purge\n")
            for name, goal in [
                ("safety", "-prove-asserts -verify"),
                ("ready-cover", "-prove cover_ready_o 0 -falsify"),
                ("cksum-cover", "-prove cover_cksum_o 0 -falsify"),
                ("quiesced-cover", "-prove cover_quiesced_o 0 -falsify"),
            ]:
                script = out / f"discovery-formal-{name}.ys"
                script.write_text(
                    disc_prefix +
                    "sat -seq 32 -set-init-zero -set-assumes -set-at 1 rst_ni 0 " + goal +
                    f" -show-ports -dump_vcd {out}/discovery-formal-{name}.vcd\n")
                with (out / f"discovery-formal-{name}.log").open("w") as log:
                    subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                                   stderr=subprocess.STDOUT, check=True, timeout=600)
                outcomes.append({"discovery_formal": name, "depth": 32,
                                 "pass": True})
        if "regs-formal" in stages:
            regs_formal_inputs = [data / name for name in [
                "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
                "g6lc_storamic_region_pkg.sv", "g6lc_storamic_regs.sv",
                "formal_g6lc_storamic_regs.sv",
            ]]
            regs_prefix = (
                "read_slang --std 1800-2017 --top formal_g6lc_storamic_regs " +
                "-DFORMAL " + " ".join(map(str, regs_formal_inputs)) +
                "\nprep -top formal_g6lc_storamic_regs\nasync2sync\n" +
                "chformal -lower\nflatten\nopt -full\ndffunmap\nopt_clean -purge\n")
            # All goals share the exact same lowered design. Preserve it once
            # instead of repeating the expensive preparation for each query.
            prepared = out / "regs-formal-prepared.il"
            prepare_script = out / "regs-formal-prepare.ys"
            prepare_script.write_text(regs_prefix + f"write_rtlil {prepared}\n")
            started = time.monotonic()
            with (out / "regs-formal-prepare.log").open("w") as log:
                subprocess.run([str(yosys), "-s", str(prepare_script)], stdout=log,
                               stderr=subprocess.STDOUT, check=True, timeout=900)
            prepared_sha = sha(prepared)
            manifest["regs_formal_prepared"] = {
                "file": str(prepared), "sha256": prepared_sha,
                "script_sha256": sha(prepare_script),
                "seconds": time.monotonic() - started,
            }
            (out / "manifest.json").write_text(json.dumps(manifest, indent=2))
            # A successful runtime commit needs two staged writes, the commit
            # write and the sequential validator, so its witness needs depth 16.
            for name, goal, depth in [
                ("safety", "-prove-asserts -verify", 12),
                ("slverr-cover", "-prove cover_slverr_o 0 -falsify", 12),
                ("irqen-cover", "-prove cover_irqen_o 0 -falsify", 12),
                ("drain-cover", "-prove cover_drain_o 0 -falsify", 12),
                ("commitok-cover", "-prove cover_commit_ok_o 0 -falsify", 16),
                ("commitfail-cover", "-prove cover_commit_fail_o 0 -falsify", 12),
            ]:
                if sha(prepared) != prepared_sha:
                    raise RuntimeError("STORAMIC_REGS_FORMAL_MODEL_IDENTITY")
                script = out / f"regs-formal-{name}.ys"
                script.write_text(
                    f"read_rtlil {prepared}\n" +
                    f"sat -seq {depth} -set-init-zero -set-assumes -set-at 1 rst_ni 0 " + goal +
                    f" -show-ports -dump_vcd {out}/regs-formal-{name}.vcd\n")
                with (out / f"regs-formal-{name}.log").open("w") as log:
                    subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                                   stderr=subprocess.STDOUT, check=True, timeout=900)
                if sha(prepared) != prepared_sha:
                    raise RuntimeError("STORAMIC_REGS_FORMAL_MODEL_IDENTITY")
                outcomes.append({"regs_formal": name, "depth": depth,
                                 "pass": True})
        if set(stages) & {"checkpoint-record-synth", "checkpoint-service-synth"}:
            record_synth_cases = [
                ("g6lc_storamic_checkpoint_media", [
                    "g6lc_storamic_pkg.sv", "g6lc_storamic_checkpoint_pkg.sv",
                    "g6lc_storamic_checkpoint_io.sv", "g6lc_storamic_checkpoint_media.sv"]),
                ("g6lc_storamic_checkpoint_io", [
                    "g6lc_storamic_pkg.sv", "g6lc_storamic_checkpoint_io.sv"]),
                ("g6lc_storamic_store_guard", ["g6lc_storamic_store_guard.sv"]),
            ] if "checkpoint-record-synth" in stages else []
            if "checkpoint-service-synth" in stages:
                record_synth_cases.append(("g6lc_storamic_checkpoint_service", [
                    "g6lc_storamic_pkg.sv", "g6lc_storamic_checkpoint_service.sv"]))
            for top, inputs in record_synth_cases:
                script = out / f"{top}-synth.ys"
                script.write_text(
                    f"read_slang --top {top} " + " ".join(str(data / item) for item in inputs) +
                    "\nhierarchy -check\nproc\nflatten\nopt -full\ncheck -assert\nscc -expect 0\nstat\n" +
                    f"write_json {out}/{top}-synth.json\n")
                with (out / f"{top}-synth.log").open("w") as log:
                    subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                                   stderr=subprocess.STDOUT, check=True, timeout=180)
                cells = json.loads((out / f"{top}-synth.json").read_text())["modules"][top]["cells"]
                if not cells or any("latch" in cell["type"].lower() for cell in cells.values()):
                    raise RuntimeError(f"{top}: empty synthesis or latch")
                outcomes.append({"checkpoint_record_synth": top, "cells": len(cells),
                                 "latches": 0, "scc": 0, "pass": True})
        if set(stages) & {"checkpoint-record-formal", "checkpoint-codec-formal",
                          "checkpoint-io-formal", "checkpoint-service-formal"}:
            for kind, top, inputs, checks in [
                ("codec", "formal_g6lc_storamic_checkpoint_codec",
                 ["g6lc_storamic_checkpoint_pkg.sv", "formal_g6lc_storamic_checkpoint_codec.sv"],
                 [("safety", "-prove-asserts -verify", 0, False),
                  ("negative", "-prove-asserts -verify", 0, True)]),
                ("io", "formal_g6lc_storamic_checkpoint_io",
                 ["g6lc_storamic_pkg.sv", "g6lc_storamic_checkpoint_io.sv",
                  "formal_g6lc_storamic_checkpoint_io.sv"],
                 [("transport-safety", "-prove-asserts -verify", 24, False),
                  ("nonce-base", "-prove-asserts -verify", 8, False),
                  ("nonce-induction", "-prove-asserts -verify", 8, False),
                  ("response-cover", "-prove cover_response_o 0 -falsify", 12, False),
                  ("stale-cover", "-prove cover_stale_o 0 -falsify", 12, False),
                  ("exhausted-cover", "-prove cover_exhausted_o 0 -falsify", 24, False),
                  ("renew-cover", "-prove cover_renew_o 0 -falsify", 28, False),
                  ("negative", "-prove-asserts -verify", 12, True),
                  ("nonce-negative", "-prove-asserts -verify", 8, True)]),
                ("service", "formal_g6lc_storamic_checkpoint_service",
                 ["g6lc_storamic_pkg.sv", "g6lc_storamic_checkpoint_service.sv",
                  "formal_g6lc_storamic_checkpoint_service.sv"],
                 [("safety", "-prove-asserts -verify", 16, False),
                  ("command-cover", "-prove cover_command_o 0 -falsify", 10, False),
                  ("revoked-cover", "-prove cover_revoked_o 0 -falsify", 12, False),
                  ("ack-cover", "-prove cover_ack_o 0 -falsify", 10, False),
                  ("negative", "-prove-asserts -verify", 10, True)]),
            ]:
                if "checkpoint-record-formal" not in stages and f"checkpoint-{kind}-formal" not in stages:
                    continue
                for name, goal, depth, bad in checks:
                    prefix = (
                        f"read_slang --top {top} -DFORMAL " +
                        ("-G OracleNegative=1 " if bad else "") +
                        (f"-G PropertyGroup={2 if name.startswith('nonce-') else 1} "
                         if kind == "io" and (name.startswith("nonce-") or
                                              name == "transport-safety") else "") +
                        " ".join(str(data / item) for item in inputs) +
                        f"\nprep -top {top}\nasync2sync\nchformal -lower\nflatten\n" +
                        "opt -full\ndffunmap\nopt_clean -purge\n")
                    tag = f"checkpoint-record-{kind}-{name}"
                    script = out / f"{tag}.ys"
                    sequence = (f"-seq {depth} -set-init-zero -set-assumes -set-at 1 rst_ni 0 "
                                if depth else "")
                    log_path = out / f"{tag}.log"
                    smt_check = kind == "codec" or name in (
                        "safety", "negative", "transport-safety",
                        "nonce-base", "nonce-induction", "nonce-negative")
                    induction = name == "nonce-induction"
                    if smt_check:
                        run = run_smt(prefix, top, tag, depth, out, yosys, manifest,
                                      induction=induction)
                    else:
                        script.write_text(prefix + "chformal -cover -remove\n" +
                                          f"sat {sequence}{goal} -show-ports " +
                                          f"-dump_vcd {out}/{tag}.vcd\n")
                        with log_path.open("w") as log:
                            run = subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                                                 stderr=subprocess.STDOUT, timeout=300)
                    text = log_path.read_text()
                    if bad:
                        token = "Status: FAILED" if smt_check else "model found: FAIL"
                        if run.returncode == 0 or token not in text:
                            raise RuntimeError(f"{tag}: negative oracle did not reject")
                    elif run.returncode != 0 or (smt_check and "Status: PASSED" not in text):
                        raise RuntimeError(f"{tag}: formal failed")
                    outcomes.append({"checkpoint_record_formal": kind, "check": name,
                                     "engine": "smtbmc/yices" if smt_check else "yosys-sat",
                                     "mode": "temporal-induction" if induction else "bounded",
                                     "depth": depth, "negative_oracle": bad, "pass": True})
                    # Preserve selected-check evidence on a later timeout. The
                    # final leaf verdict still fails/remains incomplete.
                    (out / "stage-progress.json").write_text(json.dumps(outcomes, indent=2))
        if set(stages) & {"checkpoint-model-synth", "checkpoint-endpoint-synth",
                          "checkpoint-endpoint-formal", "checkpoint-writer-synth",
                          "checkpoint-writer-formal", "policy-writer-synth", "policy-writer-formal"}:
            model_inputs = [data / name for name in [
                "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
                "g6lc_storamic_checkpoint_pkg.sv", "g6lc_storamic_region_pkg.sv",
                "g6lc_storamic_checkpoint_ctrl.sv", "g6lc_storamic_checkpoint_io.sv",
                "g6lc_storamic_checkpoint_media.sv", "g6lc_storamic_store_guard.sv",
                "g6lc_storamic_sim_mem.sv", "g6lc_storamic_durable_store.sv",
                "g6lc_storamic_checkpoint_model.sv",
                "tc_sram.sv", "tc_sram_wrapper.sv", "sram.sv",
            ]]
            synth_cases = []
            if "checkpoint-model-synth" in stages:
                synth_cases.append(("checkpoint-model-synth", "g6lc_storamic_checkpoint_model",
                                    "", model_inputs, True))
            if set(stages) & {"checkpoint-endpoint-synth", "checkpoint-endpoint-formal",
                              "checkpoint-writer-synth", "checkpoint-writer-formal",
                              "policy-writer-synth", "policy-writer-formal"}:
                endpoint_inputs = model_inputs + [data / n for n in [
                    "g6lc_storamic_axi_memory.sv", "g6lc_storamic_axi_refuse.sv",
                    "g6lc_storamic_checkpoint_service.sv", "g6lc_storamic_checkpoint_endpoint.sv"]]
                # Packed storamic_cfg_t: enable/profile/sticks/caps/base/bytes.
                cfg = (1 << 194) | (2 << 192) | (1 << 160) | (0x80000000 << 64) | 64
                synth_cases += ([
                    ("checkpoint-endpoint-off", "g6lc_storamic_checkpoint_endpoint",
                     "", endpoint_inputs, False),
                    ("checkpoint-endpoint-on", "g6lc_storamic_checkpoint_endpoint",
                     f"-G Cfg=195'h{cfg:x} ", endpoint_inputs, True),
                    ("checkpoint-endpoint-bad-layout", "g6lc_storamic_checkpoint_endpoint",
                     f"-G Cfg=195'h{cfg:x} -G RawFlashBytes=256 ", endpoint_inputs, False)]
                    if "checkpoint-endpoint-synth" in stages else [])
                if set(stages) & {"checkpoint-writer-synth", "checkpoint-writer-formal",
                                  "policy-writer-synth", "policy-writer-formal"}:
                    writer_inputs = endpoint_inputs + [data / n for n in [
                        "g6lc_storamic_dma_axi.sv", "g6lc_storamic_virtio_mmio.sv",
                        "g6lc_storamic_virtio_ring.sv", "g6lc_storamic_virtio_blk.sv",
                        "g6lc_storamic_virtio_dev.sv",
                        "g6lc_storamic_checkpoint_writer_model.sv"]]
                    writer_cfg = (cfg & ~((1 << 64) - 1)) | 1024
                    if set(stages) & {"policy-writer-synth", "policy-writer-formal"}:
                        policy_inputs = writer_inputs + [data / n for n in [
                            "g6lc_storamic_checkpoint_policy.sv", "g6lc_storamic_policy_writer_model.sv"]]
                        for label, params, memories in ([
                            ("off", "", False), ("on", f"-G Cfg=195'h{writer_cfg:x} ", True),
                            ("bad-layout", f"-G Cfg=195'h{writer_cfg:x} -G RawFlashBytes=256 ", False),
                        ] if "policy-writer-synth" in stages else []):
                            synth_cases.append((
                                f"policy-writer-{label}", "g6lc_storamic_policy_writer_model",
                                params, policy_inputs, memories))
                        if "policy-writer-formal" in stages:
                            top = "formal_g6lc_storamic_policy_writer"
                            inputs = policy_inputs + [data / f"{top}.sv"]
                            for label, invalid, negative, goal in [
                                ("off-safety", 0, 0, "-prove-asserts -verify"),
                                ("illegal-safety", 1, 0, "-prove-asserts -verify"),
                                ("read-cover", 0, 0, "-prove cover_read_o 0 -falsify"),
                                ("held-cover", 0, 0, "-prove cover_held_o 0 -falsify"),
                                ("negative", 0, 1, "-prove-asserts -falsify"),
                            ]:
                                tag = f"policy-writer-{label}"
                                script = out / f"{tag}.ys"
                                script.write_text(
                                    f"read_slang --top {top} -DFORMAL -GInvalid={invalid} " +
                                    f"-GOracleNegative={negative} " + " ".join(map(str, inputs)) +
                                    f"\nprep -top {top}\nasync2sync\nchformal -lower\nflatten\n" +
                                    "opt -full\ndffunmap\nopt_clean -purge\n" +
                                    f"sat -seq 12 -set-init-zero -set-at 1 rst_ni 0 {goal} " +
                                    f"-show-ports -dump_vcd {out}/{tag}.vcd\n")
                                with (out / f"{tag}.log").open("w") as log:
                                    subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                                                   stderr=subprocess.STDOUT, check=True, timeout=900)
                                outcomes.append({"policy_writer_formal": label, "depth": 12,
                                                 "negative_oracle": bool(negative), "pass": True})
                    for label, params, memories in ([
                        ("off", "", False),
                        ("on", f"-G Cfg=195'h{writer_cfg:x} ", True),
                        ("bad-layout", f"-G Cfg=195'h{writer_cfg:x} -G RawFlashBytes=256 ", False),
                    ] if "checkpoint-writer-synth" in stages else []):
                        synth_cases.append((
                            f"checkpoint-writer-{label}", "g6lc_storamic_checkpoint_writer_model",
                            params, writer_inputs, memories))
                    if "checkpoint-writer-formal" in stages:
                        top = "formal_g6lc_storamic_checkpoint_writer"
                        inputs = writer_inputs + [data / f"{top}.sv"]
                        for label, invalid, negative, goal in [
                            ("off-safety", 0, 0, "-prove-asserts -verify"),
                            ("illegal-safety", 1, 0, "-prove-asserts -verify"),
                            ("read-cover", 0, 0, "-prove cover_read_o 0 -falsify"),
                            ("held-cover", 0, 0, "-prove cover_held_o 0 -falsify"),
                            ("negative", 0, 1, "-prove-asserts -falsify"),
                        ]:
                            tag = f"checkpoint-writer-{label}"
                            script = out / f"{tag}.ys"
                            script.write_text(
                                f"read_slang --top {top} -DFORMAL -GInvalid={invalid} " +
                                f"-GOracleNegative={negative} " + " ".join(map(str, inputs)) +
                                f"\nprep -top {top}\nasync2sync\nchformal -lower\nflatten\n" +
                                "opt -full\ndffunmap\nopt_clean -purge\n" +
                                f"sat -seq 12 -set-init-zero -set-at 1 rst_ni 0 {goal} " +
                                f"-show-ports -dump_vcd {out}/{tag}.vcd\n")
                            with (out / f"{tag}.log").open("w") as log:
                                subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                                               stderr=subprocess.STDOUT, check=True, timeout=900)
                            outcomes.append({"checkpoint_writer_formal": label, "depth": 12,
                                             "negative_oracle": bool(negative), "pass": True})
            for name, top, params, inputs, memories_expected in synth_cases:
                script = out / f"{name}.ys"
                script.write_text(
                    f"read_slang --top {top} {params}" + " ".join(map(str, inputs)) +
                    "\nhierarchy -check\nproc\nflatten\nopt -full\ncheck -assert\nscc -expect 0\nstat\n" +
                    f"write_json {out}/{name}.json\n")
                with (out / f"{name}.log").open("w") as log:
                    subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                                   stderr=subprocess.STDOUT, check=True, timeout=180)
                module = json.loads((out / f"{name}.json").read_text())["modules"][top]
                cells = module["cells"]
                if not cells or any("latch" in cell["type"].lower() for cell in cells.values()):
                    raise RuntimeError(f"{name}: empty synthesis or latch")
                if bool(module.get("memories")) != memories_expected:
                    raise RuntimeError(f"{name}: SRAM model boundary does not match configuration")
                outcomes.append({"checkpoint_model_synth": name, "cells": len(cells),
                                 "checkpoint_model_synth_cells": len(cells),
                                 "latches": 0, "scc": 0,
                                 "model_memories": len(module.get("memories", {}))})
            if "checkpoint-endpoint-formal" in stages:
                top = "formal_g6lc_storamic_checkpoint_endpoint"
                inputs = endpoint_inputs + [data / f"{top}.sv"]
                for invalid in (False, True):
                    for bad in (False, True):
                        tag = f"checkpoint-endpoint-{'illegal' if invalid else 'off'}-{'negative' if bad else 'safety'}"
                        depth = 4 if bad else 12
                        prefix = (
                            f"read_slang --top {top} -DFORMAL -G BadLayout={int(invalid)} " +
                            f"-G OracleNegative={int(bad)} " + " ".join(map(str, inputs)) +
                            f"\nprep -top {top}\nasync2sync\nchformal -lower\nflatten\n" +
                            "opt -full\ndffunmap\nopt_clean -purge\n")
                        run = run_smt(prefix, top, tag, depth, out, yosys, manifest)
                        text = (out / f"{tag}.log").read_text()
                        if bad:
                            if run.returncode == 0 or "Status: FAILED" not in text:
                                raise RuntimeError(f"{tag}: negative oracle did not reject")
                        elif run.returncode != 0 or "Status: PASSED" not in text:
                            raise RuntimeError(f"{tag}: formal failed")
                        outcomes.append({"checkpoint_endpoint_formal": tag, "depth": depth,
                                         "negative_oracle": bad, "pass": True})
                top = "formal_g6lc_storamic_store_drain"
                inputs = endpoint_inputs + [data / f"{top}.sv"]
                for name, depth, bad, cover in [
                    ("safety", 16, False, False), ("covers", 16, False, True),
                    ("negative", 8, True, False),
                ]:
                    tag = "checkpoint-store-drain-" + name
                    prefix = (
                        f"read_slang --top {top} -DFORMAL -G OracleNegative={int(bad)} " +
                        " ".join(map(str, inputs)) +
                        f"\nprep -top {top}\nasync2sync\nchformal -lower\nflatten\n" +
                        "opt -full\ndffunmap\nopt_clean -purge\n")
                    run = run_smt(prefix, top, tag, depth, out, yosys, manifest, cover=cover)
                    text = (out / f"{tag}.log").read_text()
                    if bad:
                        if run.returncode == 0 or "Status: FAILED" not in text:
                            raise RuntimeError(f"{tag}: negative oracle did not reject")
                    elif run.returncode != 0 or "Status: PASSED" not in text:
                        raise RuntimeError(f"{tag}: formal failed")
                    outcomes.append({"checkpoint_store_drain_formal": tag, "depth": depth,
                                     "negative_oracle": bad, "cover": cover, "pass": True})
        if "checkpoint-synth" in stages:
            cp_inputs = [data / "g6lc_storamic_pkg.sv", data / "g6lc_storamic_checkpoint_ctrl.sv"]
            script = out / "checkpoint-synth.ys"
            script.write_text(
                "read_slang --top g6lc_storamic_checkpoint_ctrl " +
                " ".join(map(str, cp_inputs)) +
                "\nhierarchy -check\nproc\nflatten\nopt\ncheck -assert\nscc -expect 0\nstat\n" +
                f"write_json {out}/checkpoint-synth.json\n")
            with (out / "checkpoint-synth.log").open("w") as log:
                subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                               stderr=subprocess.STDOUT, check=True, timeout=180)
            cells = json.loads((out / "checkpoint-synth.json").read_text())[
                "modules"]["g6lc_storamic_checkpoint_ctrl"]["cells"]
            if not cells or any("latch" in cell["type"].lower() for cell in cells.values()):
                raise RuntimeError("empty checkpoint controller or latch")
            outcomes.append({"checkpoint_synth_cells": len(cells), "latches": 0, "scc": 0})
        if "checkpoint-formal" in stages:
            cp_inputs = [data / name for name in [
                "g6lc_storamic_pkg.sv", "g6lc_storamic_checkpoint_ctrl.sv",
                "formal_g6lc_storamic_checkpoint_ctrl.sv",
            ]]
            for name, goal, depth, bad in [
                ("safety", "-prove-asserts -verify", 16, False),
                ("save-cover", "-prove cover_save_o 0 -falsify", 20, False),
                ("restore-cover", "-prove cover_restore_o 0 -falsify", 32, False),
                ("error-cover", "-prove cover_error_o 0 -falsify", 12, False),
                ("negative", "-prove-asserts -verify", 16, True),
            ]:
                prefix = (
                    "read_slang --top formal_g6lc_storamic_checkpoint_ctrl -DFORMAL " +
                    ("-G OracleNegative=1 " if bad else "") +
                    " ".join(map(str, cp_inputs)) +
                    "\nprep -top formal_g6lc_storamic_checkpoint_ctrl\nasync2sync\n" +
                    "chformal -lower\nflatten\nopt -full\ndffunmap\nopt_clean -purge\n")
                script = out / f"checkpoint-formal-{name}.ys"
                script.write_text(
                    prefix + f"sat -seq {depth} -set-init-zero -set-assumes " +
                    f"-set-at 1 rst_ni 0 {goal} -show-ports " +
                    f"-dump_vcd {out}/checkpoint-formal-{name}.vcd\n")
                log_path = out / f"checkpoint-formal-{name}.log"
                with log_path.open("w") as log:
                    run = subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                                         stderr=subprocess.STDOUT, timeout=300)
                if bad:
                    if run.returncode == 0 or "model found: FAIL" not in log_path.read_text():
                        raise RuntimeError("checkpoint formal negative oracle did not reject")
                elif run.returncode != 0:
                    raise RuntimeError(f"checkpoint formal {name} failed")
                outcomes.append({"checkpoint_formal": name, "depth": depth,
                                 "negative_oracle": bad, "pass": True})
        if "vdma-ownership-formal" in stages:
            top = "formal_g6lc_storamic_dma_ownership"
            inputs = [data / name for name in [
                "g6lc_storamic_pkg.sv", "g6lc_storamic_dma_axi.sv",
                "formal_g6lc_storamic_dma_ownership.sv"]]
            for name, goal, depth, bad in [
                ("safety", "-prove-asserts -verify", 16, False),
                ("offered-w", "-prove cover_offered_w_o 0 -falsify", 8, False),
                ("held-aw", "-prove cover_held_aw_o 0 -falsify", 8, False),
                ("held-r", "-prove cover_held_r_o 0 -falsify", 8, False),
                ("drain", "-prove cover_drain_o 0 -falsify", 14, False),
                ("negative", "-prove-asserts -verify", 12, True),
            ]:
                prefix = (
                    f"read_slang --top {top} -DFORMAL " +
                    ("-G OracleNegative=1 " if bad else "") +
                    " ".join(map(str, inputs)) +
                    f"\nprep -top {top}\nasync2sync\nchformal -lower\nflatten\n" +
                    "opt -full\ndffunmap\nopt_clean -purge\n")
                script = out / f"vdma-ownership-{name}.ys"
                script.write_text(
                    prefix + f"sat -seq {depth} -set-init-zero -set-assumes " +
                    f"-set-at 1 rst_ni 0 {goal} -show-ports " +
                    f"-dump_vcd {out}/vdma-ownership-{name}.vcd\n")
                log_path = out / f"vdma-ownership-{name}.log"
                with log_path.open("w") as log:
                    result = subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                                            stderr=subprocess.STDOUT, timeout=300)
                if bad:
                    if result.returncode == 0 or "model found: FAIL" not in log_path.read_text():
                        raise RuntimeError("DMA ownership formal oracle did not reject")
                elif result.returncode != 0:
                    raise RuntimeError(f"DMA ownership formal {name} failed")
                outcomes.append({"vdma_ownership_formal": name, "depth": depth,
                                 "negative_oracle": bad, "pass": True})
        if "quiesce-formal" in stages:
            formal_inputs = [*memory_sources, data / "formal_g6lc_storamic_quiesce.sv"]
            prefix = (
                "read_slang --std 1800-2017 --top formal_g6lc_storamic_quiesce -DFORMAL " +
                " ".join(map(str, formal_inputs)) +
                "\nprep -top formal_g6lc_storamic_quiesce\nasync2sync\nchformal -lower\n" +
                "flatten\nopt -full\ndffunmap\nopt_clean -purge\n")
            for name, goal in [
                ("safety", "-prove-asserts -verify"),
                ("write-cover", "-prove cover_write_drain_o 0 -falsify"),
                ("read-cover", "-prove cover_read_drain_o 0 -falsify"),
            ]:
                script = out / f"quiesce-formal-{name}.ys"
                script.write_text(
                    prefix + "sat -seq 12 -set-init-zero -set-assumes " +
                    f"-set-at 1 rst_ni 0 {goal} -show-ports\n")
                with (out / f"quiesce-formal-{name}.log").open("w") as log:
                    subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                                   stderr=subprocess.STDOUT, check=True, timeout=300)
                outcomes.append({"quiesce_formal": name, "depth": 12, "pass": True})
        if "model-formal" in stages:
            formal_inputs = [*memory_sources, data / "formal_g6lc_storamic_model.sv"]
            formal_prefix = (
                "read_slang --std 1800-2017 --top formal_g6lc_storamic_model -DFORMAL " +
                " ".join(map(str, formal_inputs)) +
                "\nprep -top formal_g6lc_storamic_model\nasync2sync\nchformal -lower\nflatten\n" +
                "opt -full\ndffunmap\nopt_clean -purge\n")
            # Safety needs no eventual-grant/completion assumptions. Reachability
            # is a separate falsification of 'the exercised-path flag is always 0'.
            formal_checks = [
                ("safety", "-prove-asserts -verify"),
                ("rw-cover", "-prove cover_rw_o 0 -falsify"),
                ("stale-cover", "-prove cover_stale_o 0 -falsify"),
            ]
            for name, goal in formal_checks:
                script = out / f"model-formal-{name}.ys"
                script.write_text(
                    formal_prefix +
                    "sat -seq 12 -set-init-zero -set-assumes -set-at 1 rst_ni 0 " + goal +
                    f" -show-ports -dump_vcd {out}/model-formal-{name}.vcd\n")
                with (out / f"model-formal-{name}.log").open("w") as log:
                    subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                                   stderr=subprocess.STDOUT, check=True, timeout=600)
                outcomes.append({"model_formal": name, "depth": 12, "pass": True})
        if "synth" in stages:
            script = out / "synth.ys"
            script.write_text(
                "read_slang --std 1800-2017 --top g6lc_storamic_top " +
                " ".join(sources[:-1]) +
                "\nhierarchy -check\nproc\nflatten\nopt\ncheck -assert\nscc -expect 0\nstat\n" +
                f"write_json {out}/synth.json\n")
            with (out / "synth.log").open("w") as log:
                subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                               stderr=subprocess.STDOUT, check=True, timeout=180)
            cells = json.loads((out / "synth.json").read_text())["modules"]["g6lc_storamic_top"]["cells"]
            if not cells or any("latch" in cell["type"].lower() for cell in cells.values()):
                raise RuntimeError("empty synthesized frontend or latch")
            outcomes.append({"synth_cells": len(cells), "latches": 0, "scc": 0})
            native_sources = [data / name for name in [
                "axi_pkg.sv", "axi_intf.sv", "g6lc_ai_island_cfg_pkg.sv",
                "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
                "g6lc_storamic_pad_pkg.sv", "g6lc_storamic_soc_cfg_pkg.sv",
                "g6lc_storamic_axi_refuse.sv", "g6lc_storamic_region_pkg.sv",
                "g6lc_storamic_axi_memory.sv",
                "g6lc_storamic_regs.sv", "g6lc_storamic_top.sv",
                "g6lc_storamic_attach.sv", "tb_g6lc_storamic_soc.sv",
            ]]
            native_script = out / "native-synth.ys"
            native_script.write_text(
                "read_slang --std 1800-2017 --top g6lc_storamic_soc_synth " +
                "-DSYNTHESIS -DG6LC_STORAMIC_SKELETON -I" + str(include.parent) + " " +
                " ".join(map(str, native_sources)) +
                "\nhierarchy -check\nproc\nflatten\nopt\ncheck -assert\nscc -expect 0\nstat\n" +
                f"write_json {out}/native-synth.json\n")
            with (out / "native-synth.log").open("w") as log:
                subprocess.run([str(yosys), "-s", str(native_script)], stdout=log,
                               stderr=subprocess.STDOUT, check=True, timeout=180)
            native_cells = json.loads((out / "native-synth.json").read_text())["modules"][
                "g6lc_storamic_soc_synth"]["cells"]
            if not native_cells or any("latch" in cell["type"].lower()
                                       for cell in native_cells.values()):
                raise RuntimeError("empty synthesized native frontend or latch")
            outcomes.append({"native_synth_cells": len(native_cells), "latches": 0, "scc": 0})
            refused_script = out / "native-checkpoint-refusal.ys"
            refused_script.write_text(
                "read_slang --std 1800-2017 --top g6lc_storamic_soc_synth " +
                "-G CheckpointRequested=1 -DSYNTHESIS -DG6LC_STORAMIC_SKELETON -I" +
                str(include.parent) + " " + " ".join(map(str, native_sources)) +
                "\nhierarchy -check\nproc\nflatten\nopt\ncheck -assert\nscc -expect 0\nstat\n" +
                f"write_json {out}/native-checkpoint-refusal.json\n")
            with (out / "native-checkpoint-refusal.log").open("w") as log:
                subprocess.run([str(yosys), "-s", str(refused_script)], stdout=log,
                               stderr=subprocess.STDOUT, check=True, timeout=180)
            refused = json.loads((out / "native-checkpoint-refusal.json").read_text())[
                "modules"]["g6lc_storamic_soc_synth"]
            if not refused["cells"] or refused.get("memories") or any(
                    "latch" in c["type"].lower() for c in refused["cells"].values()):
                raise RuntimeError("native checkpoint refusal retained memory/latch or was empty")
            outcomes.append({"native_checkpoint_refusal_cells": len(refused["cells"]),
                             "model_memories": 0, "latches": 0, "scc": 0})
            # ST-011B: the sim model memory binding synthesizes clean.
            mem_sources = [data / name for name in [
                "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
                "g6lc_storamic_sim_mem.sv", "tc_sram.sv",
                "tc_sram_wrapper.sv", "sram.sv",
            ]]
            mem_script = out / "sim-mem-synth.ys"
            mem_script.write_text(
                "read_slang --std 1800-2017 --unroll-limit=65536 --top g6lc_storamic_sim_mem " +
                "-DSYNTHESIS " + " ".join(map(str, mem_sources)) +
                "\nhierarchy -check\nproc\nflatten\nopt\ncheck -assert\nscc -expect 0\nstat\n" +
                f"write_json {out}/sim-mem-synth.json\n")
            with (out / "sim-mem-synth.log").open("w") as log:
                subprocess.run([str(yosys), "-s", str(mem_script)], stdout=log,
                               stderr=subprocess.STDOUT, check=True, timeout=180)
            mem_cells = json.loads((out / "sim-mem-synth.json").read_text())[
                "modules"]["g6lc_storamic_sim_mem"]["cells"]
            if not mem_cells or any("latch" in cell["type"].lower()
                                    for cell in mem_cells.values()):
                raise RuntimeError("empty synthesized sim_mem or latch")
            outcomes.append({"sim_mem_synth_cells": len(mem_cells),
                             "latches": 0, "scc": 0})
        if "formal" in stages:
            script = out / "formal.ys"
            formal_sources = [data / "g6lc_storamic_pkg.sv",
                              data / "g6lc_storamic_axi_refuse.sv",
                              data / "formal_g6lc_storamic.sv"]
            script.write_text(
                "read_slang --std 1800-2017 --top formal_g6lc_storamic -DFORMAL " +
                " ".join(map(str, formal_sources)) +
                "\nprep -top formal_g6lc_storamic\nasync2sync\nchformal -lower\nflatten\n" +
                "opt -full\ndffunmap\nopt_clean -purge\n" +
                "sat -seq 12 -set-init-zero -set-assumes -set-at 1 rst_ni 0 -prove-asserts -verify\n")
            with (out / "formal.log").open("w") as log:
                subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                               stderr=subprocess.STDOUT, check=True, timeout=180)
            outcomes.append({"formal_depth": 12, "property": "response stability and refusal"})
    if {name: sha(data / name) for name in expected} != actual:
        raise RuntimeError("STORAMIC_SOURCE_CHANGED")
    identities = [build["files"] for build in builds]
    for kind in ("runtime", "compiler", "formal_tools"):
        if kind in manifest:
            identities.append(manifest[kind]["files"])
    for identity in identities:
        if file_identities([Path(path) for path in identity]) != identity:
            raise RuntimeError("STORAMIC_BUILD_INPUT_IDENTITY_CHANGED")
    if (sha(Path(__file__)) != manifest["runner"] or
            (verilator is not None and (
                sha(verilator) != manifest["verilator_sha256"] or
                sha(verilator.with_name("verilator_bin")) != manifest["verilator_bin_sha256"])) or
            ("yosys" in manifest and sha(Path(manifest["yosys"])) != manifest["yosys_sha256"])):
        raise RuntimeError("STORAMIC_TOOL_IDENTITY_CHANGED")
    (out / "stage-results.json").write_text(json.dumps(outcomes, indent=2))
    if not outcomes:
        raise RuntimeError("STORAMIC_NO_SELECTED_STAGES_EXECUTED")
    if config_failures:
        raise RuntimeError("configuration sweep failures: " + ", ".join(config_failures))
    (out / "leaf-result.json").write_text(json.dumps({
        "status": "pass", "stages": stages, "profiles": outcomes,
        "sources": actual, "qualification": False,
    }, indent=2))
    print("STORAMIC_REMOTE_SELECTED_STAGES_PASS")


def _manifest_sources():
    try:
        return json.loads((Path(os.environ["TH_DATA_DIR"]) /
                           os.environ["STORAMIC_MANIFEST_FILE"]).read_text())["sources"]
    except Exception:
        return {}


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        status = "fail" if isinstance(error, (subprocess.CalledProcessError, RuntimeError)) else "incomplete"
        if "IDENTITY" in str(error) or "SOURCE_CHANGED" in str(error):
            status = "incomplete"
        Path(os.environ["TH_OUT_DIR"], "leaf-result.json").write_text(json.dumps({
            "status": status, "error": str(error),
            "sources": _manifest_sources(),
            "stages": os.environ.get("STORAMIC_STAGES", "").split(","),
            "qualification": False,
        }, indent=2))
        raise
