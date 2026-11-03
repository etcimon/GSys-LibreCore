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


def build_model(command, model, log_path, manifest):
    generation = list(command)
    generation[generation.index("--binary")] = "--cc"
    generation += ["--main", "--exe"]
    top = generation[generation.index("--top-module") + 1]
    compiler = manifest["compiler"]["paths"]
    runtime = manifest["runtime"]
    make = [
        compiler["make"], "-C", str(model), "-f", f"V{top}.mk",
        "-f", "identity.mk", "-j1",
        "VERILATOR_ROOT=" + runtime["root"],
        "CXX=" + compiler["g++"], "LINK=" + compiler["g++"], "OBJCACHE=",
        "AR=" + compiler["ar"], "PYTHON3=" + compiler["python3"],
    ]
    env = dict(os.environ)
    for key in ("MAKEFLAGS", "MFLAGS", "CXX", "CC", "CXXFLAGS", "CFLAGS",
                "CPPFLAGS", "LDFLAGS", "OBJCACHE", "VERILATOR_ROOT", "VPATH"):
        env.pop(key, None)
    log_path.with_suffix(".commands.json").write_text(json.dumps({
        "generate": generation, "compile": make,
    }, indent=2))
    with log_path.open("w") as log:
        subprocess.run(generation, env=env, stdout=log, stderr=subprocess.STDOUT,
                       check=True, timeout=180)
        # GCC's -MMD suppresses system dependencies even when -MD is also given.
        # Override only dependency selection in this owned build, not the runtime.
        (model / "identity.mk").write_text(
            "override VK_CPPFLAGS_ALWAYS := $(filter-out -MMD,$(VK_CPPFLAGS_ALWAYS)) -MD\n")
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
    if private_header not in dependencies or original_header in dependencies:
        raise RuntimeError("STORAMIC_COMPILED_RUNTIME_IDENTITY")
    executable = model / generation[generation.index("-o") + 1]
    generated = {p for p in model.iterdir() if p.is_file() and
                 p.suffix in {".cpp", ".h", ".mk", ".dat", ".d"}}
    record = {
        "commands": {"generate": generation, "compile": make},
        "files": file_identities(dependencies | generated | {executable}),
        "executable": str(executable), "private_runtime_verified": True,
    }
    (model / "build-identity.json").write_text(json.dumps(record, indent=2))
    return record


def main():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    data = Path(os.environ["TH_DATA_DIR"])
    out = Path(os.environ["TH_OUT_DIR"])
    expected = json.loads(os.environ["STORAMIC_SOURCES"])
    actual = {name: sha(data / name) for name in expected}
    if actual != expected or sha(Path(__file__)) != os.environ["STORAMIC_RUNNER_SHA"]:
        raise RuntimeError("STORAMIC_SOURCE_IDENTITY")
    stages = os.environ["STORAMIC_STAGES"].split(",")
    verilator = Path(os.environ.get("VERILATOR") or shutil.which("verilator") or "")
    if not verilator.is_file():
        raise FileNotFoundError("Verilator unavailable")
    manifest = {
        "sources": actual, "runner": sha(Path(__file__)),
        "verilator": str(verilator.resolve()), "verilator_sha256": sha(verilator),
        "version": subprocess.check_output([str(verilator), "--version"], text=True).strip(),
        "verilator_bin_sha256": sha(verilator.with_name("verilator_bin")),
        "qualification": False,
        "source_paths": json.loads(os.environ["STORAMIC_SOURCE_PATHS"]),
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
    if set(stages) & {"protocol", "config", "integration", "model"}:
        manifest["runtime"] = runtime_identity(out)
        manifest["compiler"] = compiler_identity()
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))
    source_names = [
        "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
        "g6lc_storamic_pad_pkg.sv", "g6lc_storamic_axi_refuse.sv",
        "g6lc_storamic_axi_memory.sv", "g6lc_storamic_top.sv", "tb_g6lc_storamic.sv",
    ]
    sources = [str(data / name) for name in source_names]
    outcomes = []
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
                    "tb_g6lc_storamic_config.sv",
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
        ]:
            command = [
                str(verilator), "--binary", "--assert", "-j", "1", "-Wno-fatal",
                "--top-module", "tb_g6lc_storamic_config",
                "--Mdir", str(out / f"config-{name}"), "-o", "config-test", *defines,
                *[str(data / p) for p in [
                    "config_pkg.sv", "g6lc64_smt2_config_pkg.sv", "build_config_pkg.sv",
                    "tb_g6lc_storamic_config.sv",
                ]],
            ]
            builds.append(build_model(command, out / f"config-{name}",
                                      out / f"config-{name}-build.log", manifest))
            run = subprocess.run([str(out / f"config-{name}/config-test")],
                                 capture_output=True, text=True, timeout=30)
            (out / f"config-{name}.log").write_text(run.stdout + run.stderr)
            matched = (run.returncode != 0 and "STORAMIC_CORE_AXI_GEOMETRY" in run.stdout) if (
                name == "bad-geometry") else (
                run.returncode == 0 and "STORAMIC_CORE_CONFIG_PASS" in run.stdout)
            if not matched:
                raise RuntimeError(f"configuration propagation failed: {name}")
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
            builds.append(build_model(command, model, out / f"model-{name}-build.log", manifest))
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
    if set(stages) & {"synth", "formal", "model-synth", "model-formal"}:
        sys.path.insert(0, str(data))
        from yosys_bin import yosys_bin
        yosys = Path(yosys_bin())
        manifest["yosys"] = str(yosys)
        manifest["yosys_sha256"] = sha(yosys)
        (out / "manifest.json").write_text(json.dumps(manifest, indent=2))
        memory_sources = [data / "g6lc_storamic_pkg.sv",
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
                    "sat -seq 12 -set-init-zero -set-at 1 rst_ni 0 " + goal +
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
                "g6lc_storamic_axi_refuse.sv", "g6lc_storamic_axi_memory.sv",
                "g6lc_storamic_top.sv",
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
                "sat -seq 12 -set-init-zero -set-at 1 rst_ni 0 -prove-asserts -verify\n")
            with (out / "formal.log").open("w") as log:
                subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                               stderr=subprocess.STDOUT, check=True, timeout=180)
            outcomes.append({"formal_depth": 12, "property": "response stability and refusal"})
    if {name: sha(data / name) for name in expected} != actual:
        raise RuntimeError("STORAMIC_SOURCE_CHANGED")
    identities = [build["files"] for build in builds]
    for kind in ("runtime", "compiler"):
        if kind in manifest:
            identities.append(manifest[kind]["files"])
    for identity in identities:
        if file_identities([Path(path) for path in identity]) != identity:
            raise RuntimeError("STORAMIC_BUILD_INPUT_IDENTITY_CHANGED")
    if (sha(Path(__file__)) != manifest["runner"] or
            sha(verilator) != manifest["verilator_sha256"] or
            sha(verilator.with_name("verilator_bin")) != manifest["verilator_bin_sha256"] or
            ("yosys" in manifest and sha(Path(manifest["yosys"])) != manifest["yosys_sha256"])):
        raise RuntimeError("STORAMIC_TOOL_IDENTITY_CHANGED")
    (out / "stage-results.json").write_text(json.dumps(outcomes, indent=2))
    if config_failures:
        raise RuntimeError("configuration sweep failures: " + ", ".join(config_failures))
    (out / "leaf-result.json").write_text(json.dumps({
        "status": "pass", "stages": stages, "profiles": outcomes,
        "sources": actual, "qualification": False,
    }, indent=2))
    print("STORAMIC_REMOTE_SELECTED_STAGES_PASS")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        status = "fail" if isinstance(error, (subprocess.CalledProcessError, RuntimeError)) else "incomplete"
        if "IDENTITY" in str(error) or "SOURCE_CHANGED" in str(error):
            status = "incomplete"
        Path(os.environ["TH_OUT_DIR"], "leaf-result.json").write_text(json.dumps({
            "status": status, "error": str(error),
            "sources": json.loads(os.environ.get("STORAMIC_SOURCES", "{}")),
            "stages": os.environ.get("STORAMIC_STAGES", "").split(","),
            "qualification": False,
        }, indent=2))
        raise
