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
    run_manifest = json.loads((data / os.environ["STORAMIC_MANIFEST_FILE"]).read_text())
    expected = run_manifest["sources"]
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
    if set(stages) & {"protocol", "config", "integration", "model", "region",
                      "map", "discovery", "regs", "ctrl", "virtio",
                      "vring", "vblk", "vdev", "vdma", "dstore"}:
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
            matched = (run.returncode != 0 and "STORAMIC_CORE_AXI_GEOMETRY" in run.stdout) if (
                name == "bad-geometry") else (
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
    if "dstore" in stages:
        command = [
            str(verilator), "--binary", "--timing", "--assert",
            "-j", "1", "--threads", "1", "-Wno-fatal",
            "-Werror-LATCH", "-Werror-UNOPTFLAT",
            "--top-module", "tb_g6lc_storamic_durable_store",
            "--Mdir", str(out / "dstore"), "-o", "dstore-test",
            *[str(data / p) for p in [
                "g6lc_storamic_pkg.sv", "tc_sram.sv",
                "tc_sram_wrapper.sv", "sram.sv",
                "g6lc_storamic_durable_store.sv", "g6lc_storamic_sim_mem.sv",
                "tb_g6lc_storamic_durable_store.sv",
            ]],
        ]
        builds.append(build_model(command, out / "dstore",
                                  out / "dstore-build.log", manifest))
        run = subprocess.run([str(out / "dstore/dstore-test")],
                             capture_output=True, text=True, timeout=120)
        text = run.stdout + run.stderr
        (out / "dstore-sim.log").write_text(text)
        if run.returncode != 0 or "DSTORE_PASS" not in text:
            raise RuntimeError(f"dstore: unexpected verdict: {text[-4000:]}")
        outcomes.append({"dstore": "tb", "pass": True})
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
                      "vblk-formal", "vblk-flush-formal"}:
        sys.path.insert(0, str(data))
        from yosys_bin import yosys_bin
        yosys = Path(yosys_bin())
        manifest["yosys"] = str(yosys)
        manifest["yosys_sha256"] = sha(yosys)
        (out / "manifest.json").write_text(json.dumps(manifest, indent=2))
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
                script = out / f"regs-formal-{name}.ys"
                script.write_text(
                    regs_prefix +
                    f"sat -seq {depth} -set-init-zero -set-assumes -set-at 1 rst_ni 0 " + goal +
                    f" -show-ports -dump_vcd {out}/regs-formal-{name}.vcd\n")
                with (out / f"regs-formal-{name}.log").open("w") as log:
                    subprocess.run([str(yosys), "-s", str(script)], stdout=log,
                                   stderr=subprocess.STDOUT, check=True, timeout=900)
                outcomes.append({"regs_formal": name, "depth": depth,
                                 "pass": True})
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
            # ST-011B: the sim model memory binding synthesizes clean.
            mem_sources = [data / name for name in [
                "g6lc_storamic_cfg_pkg.sv", "g6lc_storamic_pkg.sv",
                "g6lc_storamic_sim_mem.sv", "tc_sram.sv",
                "tc_sram_wrapper.sv", "sram.sv",
            ]]
            mem_script = out / "sim-mem-synth.ys"
            mem_script.write_text(
                "read_slang --std 1800-2017 --top g6lc_storamic_sim_mem " +
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
