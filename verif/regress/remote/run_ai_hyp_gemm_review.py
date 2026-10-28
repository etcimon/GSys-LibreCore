#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Pinned hyp GEMM source closure and remote focused gates (no shared builds)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import subprocess
import sys
import zipfile

HYP = "build-platform/workspace/hyp/hyp_redesign_corev_apu_8fo4/corev_apu"
FIXED_HEADER_SHA = "dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def prepare(destination, baseline):
    root = Path(__file__).resolve().parents[3]
    variables = {
        "ROOT": root, "AI_RTL": root / HYP / "ai_island",
        "AI_INC": root / HYP / "include", "AI_SRC": root / HYP / "src",
        "AI_CVXIF": root / "core/cvxif_g6lc_ai",
        "CCELLS": root / "vendor/pulp-platform/common_cells",
        "AXI": root / "vendor/pulp-platform/axi",
    }
    includes = [variables["AXI"] / "include", variables["CCELLS"] / "include",
                root / "core/include", root / "corev_apu/include",
                variables["AI_INC"], variables["AI_RTL"] / "include"]
    files, suites = {}, {}
    for suite in ("backend", "stripe", "cluster", "wide", "island"):
        name = {"cluster": "cluster-dispatch", "island": "ai-island-dma"}.get(suite, "gemm-" + suite)
        script = root / "verif/tb/ai_island" / ("run-" + name + ".sh")
        names = []
        script_text = script.read_text(encoding="utf-8")
        # Island's optional-source discovery loop contains "$leaf.sv"; its
        # actual command is followed by the explicit supplemental leaves below.
        source_text = script_text.split("verilator --binary", 1)[1] if suite == "island" else script_text
        for raw in re.findall(r'"([^"\n]+\.sv)"', source_text):
            for key, value in variables.items():
                raw = raw.replace("$" + key, str(value))
            path = Path(raw)
            relative = path.relative_to(root).as_posix()
            if relative not in names:
                names.append(relative)
                files[relative] = path.read_bytes()
        for leaf in ("fp32_add", "span", "store_plan"):
            path = variables["AI_RTL"] / ("g6lc_ai_gemm_" + leaf + ".sv")
            relative = path.relative_to(root).as_posix()
            if relative not in names:
                names.append(relative)
                files[relative] = path.read_bytes()
        if suite == "island":
            for leaf in ("policy_topology", "policy_publish", "inval_queue"):
                path = variables["AI_RTL"] / ("g6lc_ai_" + leaf + ".sv")
                relative = path.relative_to(root).as_posix()
                if relative not in names:
                    names.append(relative)
                    files[relative] = path.read_bytes()
            driver = root / "verif/tb/ai_island/ai_island_dma_main.cpp"
            files[driver.relative_to(root).as_posix()] = driver.read_bytes()
        suites[suite] = names
        files[script.relative_to(root).as_posix()] = script.read_bytes()
    for directory in includes:
        for path in directory.rglob("*.svh"):
            files[path.relative_to(root).as_posix()] = path.read_bytes()
    repair = root / "verif/regress/remote/run_runtime_repair.py"
    files[repair.relative_to(root).as_posix()] = repair.read_bytes()
    if baseline:
        with zipfile.ZipFile(baseline) as archive:
            files[HYP + "/ai_island/g6lc_ai_gemm_seq.sv"] = archive.read("g6lc_ai_gemm_seq.sv")
    manifest = {"sha256": {name: sha(data) for name, data in files.items()},
                "suites": suites, "includes": [p.relative_to(root).as_posix() for p in includes],
                "baseline": bool(baseline)}
    with zipfile.ZipFile(destination, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("manifest.json", json.dumps(manifest, indent=2) + "\n")
        for name, data in files.items():
            archive.writestr(name, data)
    print("SNAPSHOT", destination, "files", len(files), "sha256", sha(Path(destination).read_bytes()))


def remote():
    import resource
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    out = Path(os.environ["TH_OUT_DIR"])
    work = Path(os.environ["TH_RUN_DIR"]) / ("gemm-work-" + out.name)
    work.mkdir()
    records = []

    def run(command, name, timeout=900, env=None):
        (out / (name + ".command.json")).write_text(json.dumps(command, indent=2) + "\n")
        with (out / (name + ".log")).open("w") as log:
            try:
                rc = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                                    timeout=timeout, env=env).returncode
            except subprocess.TimeoutExpired:
                rc = 124
        text = (out / (name + ".log")).read_text(errors="replace")
        print(name, "rc", rc, text[-1800:], flush=True)
        records.append({"name": name, "rc": rc})
        (out / "steps.json").write_text(json.dumps(records, indent=2) + "\n")
        return rc, text

    processes = subprocess.check_output(["ps", "-eo", "comm="], text=True).splitlines()
    workers = sum(p.strip() in {"cc1plus", "cc1", "verilator_bin"} for p in processes)
    cpus = len(os.sched_getaffinity(0))
    mem = int(re.search(r"MemAvailable:\s+(\d+)", Path("/proc/meminfo").read_text())[1]) * 1024
    capacity = {"cpus": cpus, "build_workers": workers, "available_memory": mem,
                "free_disk": shutil.disk_usage(work).free, "load": os.getloadavg()}
    (out / "capacity.json").write_text(json.dumps(capacity, indent=2) + "\n")
    if workers + 2 > cpus or mem < 4 * 1024**3 or capacity["free_disk"] < 2 * 1024**3:
        return 75
    archives = list(Path(os.environ["TH_DATA_DIR"]).glob("*.zip"))
    if len(archives) != 1:
        raise ValueError("one source archive required")
    source = work / "source"
    source.mkdir()
    with zipfile.ZipFile(archives[0]) as archive:
        manifest = json.loads(archive.read("manifest.json"))
        for name, digest in manifest["sha256"].items():
            path = source / name
            if not path.resolve().is_relative_to(source.resolve()):
                raise ValueError("unsafe snapshot path")
            data = archive.read(name)
            if sha(data) != digest:
                raise ValueError("source identity mismatch: " + name)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    (out / "input-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    verilator = os.environ["VERILATOR"]
    version = subprocess.check_output([verilator, "--version"], text=True).strip()
    if "Verilator 5.008" not in version:
        raise ValueError("qualified 5.008 tool required")
    details = subprocess.check_output([verilator, "-V"], text=True)
    original = Path(re.search(r"^\s*VERILATOR_ROOT\s*=\s*(\S+)", details, re.M)[1])
    runtime = work / "runtime"
    shutil.copytree(original, runtime)
    header = runtime / "include/verilated_funcs.h"
    original_sha = sha(header.read_bytes())
    text = header.read_text()
    if original_sha != FIXED_HEADER_SHA:
        for n in range(1, 9):
            old = f"    VL_C_END_(obits, VL_WORDS_I(lsb) + {n});"
            new = (f"    for (int i = VL_WORDS_I(lsb) + {n}; i < VL_WORDS_I(obits); ++i) obase[i] = 0;\n"
                   "    return o;")
            if text.count(old) != 1:
                raise ValueError("runtime repair source mismatch")
            text = text.replace(old, new)
        header.write_text(text)
    if sha(header.read_bytes()) != FIXED_HEADER_SHA:
        raise ValueError("private runtime does not match qualified header")
    identity = {"verilator": verilator, "version": version, "originalHeaderSha256": original_sha,
                "fixedHeaderSha256": FIXED_HEADER_SHA, "privateRoot": str(runtime),
                "runnerSha256": sha(Path(__file__).read_bytes())}
    (out / "runtime.json").write_text(json.dumps(identity, indent=2) + "\n")
    canary = work / "canary.cpp"
    canary.write_text(runpy.run_path(str(source / "verif/regress/remote/run_runtime_repair.py"))["CANARY"])
    for label, prefix, expected in [("original", original, int(original_sha != FIXED_HEADER_SHA)),
                                    ("fixed", runtime, 0)]:
        executable = work / ("canary-" + label)
        rc, _ = run(["g++", "-std=c++17", "-O2", "-I" + str(prefix / "include"),
                     str(canary), "-o", str(executable)], label + "-canary-build", 60)
        if rc:
            return rc
        rc, _ = run([str(executable)], label + "-canary", 30)
        if rc != expected:
            return 1
    configurations = {
        "backend0": ("backend", ["-GNCH=1", "-GDOT_PIPE_FLOAT=0", "-GDOT_PIPE_INT=0",
                                "-GOUT_COLS=4", "-GMAX_K=64", "-GMAX_N=64", "-GREUSE_EN=1"]),
        "backend2": ("backend", ["-GNCH=2", "-GDOT_PIPE_FLOAT=1", "-GDOT_PIPE_INT=1",
                                "-GOUT_COLS=4", "-GMAX_K=64", "-GMAX_N=64", "-GREUSE_EN=1"]),
        "stripe1": ("stripe", ["-GNCH=1"]),
        "stripe2": ("stripe", ["-GNCH=2"]),
        "cluster": ("cluster", []),
        "wide": ("wide", []),  # The existing bench instantiates both widths.
        "island": ("island", ["-GDMA_INVAL_EN=0"]),
        "island-inval": ("island", ["-GDMA_INVAL_EN=1"]),
        "island-int": ("island", ["-GISLAND_FP_EN=0", "-GDMA_INVAL_EN=0"]),
        "island-int-inval": ("island", ["-GISLAND_FP_EN=0", "-GDMA_INVAL_EN=1"]),
        "island-small": ("island", ["-GSMALL_GEOMETRY=1", "-GDMA_INVAL_EN=0"]),
        "island-small-inval": ("island", ["-GSMALL_GEOMETRY=1", "-GDMA_INVAL_EN=1"]),
    }
    results = []
    for config in os.environ.get("GEMM_REVIEW_CONFIGS", "backend0,backend2,stripe1,stripe2,cluster").split(","):
        suite, params = configurations[config]
        top = "tb_g6lc_ai_" + {"cluster": "cluster_dispatch", "island": "island_dma"}.get(
            suite, "gemm_" + suite)
        model = work / config
        main = [str(source / "verif/tb/ai_island/ai_island_dma_main.cpp")] if suite == "island" else ["--main"]
        split = ["--output-split", "15000", "--output-split-cfuncs", "200"] if suite == "island" else []
        command = [verilator, "--cc", "--exe", *main, *split, "--timing", "--assert",
                   "--threads", "1", "-fno-table", "-Wno-fatal", "-Wno-TIMESCALEMOD",
                   "-DG6LC_AI_HYP_R19", "-DG6LC_AI_HYP_R20_CHECK",
                   "--top-module", top, "--Mdir", str(model), "-o", "gemm-test", *params,
                   *["-I" + str(source / p) for p in manifest["includes"]],
                   *[str(source / p) for p in manifest["suites"][suite]]]
        rc, text = run(command, config + "-elaborate")
        if rc:
            return rc
        warnings = re.findall(r"^%Warning-([^:]+): (.+)$", text, re.M)
        (out / (config + "-warnings.json")).write_text(json.dumps(warnings, indent=2) + "\n")
        optimization = ["OPT_FAST=-O0", "OPT_SLOW=-O0"] if suite == "island" else []
        rc, _ = run(["make", "-C", str(model), "-f", "V" + top + ".mk", "-j2", *optimization,
                     "VERILATOR_ROOT=" + str(runtime)], config + "-build",
                    env=dict(os.environ, VPATH=str(runtime / "include")))
        if rc:
            return rc
        deps = "".join(p.read_text(errors="replace") for p in model.glob("*.d"))
        if str(runtime / "include/verilated_funcs.h") not in deps:
            raise ValueError("model did not use private runtime")
        binary = model / "gemm-test"
        cases = [""] if suite != "backend" else ["", "review_accumulate", "review_signed",
                                                "review_protocol", "review_slots", "review_fp32_add"]
        for case in cases:
            trace_args = ["+trace_load"] if config.startswith("island-small") else []
            rc, text = run([str(binary), *trace_args, *(["+" + case] if case else [])],
                           config + "-" + (case or "golden"), 300)
            if rc or "PASS" not in text or "FAIL" in text or "%Error" in text:
                return rc or 1
            if suite == "island":
                if "*** SUCCESS *** ai-island DMA" not in text:
                    raise ValueError("island DMA driver did not complete")
                if config.endswith("-inval") and "PASS DMA_INVAL_INTEGRATION" not in text:
                    raise ValueError("invalidation completion barrier was not checked")
            elif not manifest["baseline"] and not case == "review_fp32_add":
                if not re.search(r"\[r20\] operand_checks=[1-9]", text):
                    raise ValueError("operand comparison was not exercised")
                if not re.search(r"\[r20\] load_checks=[1-9]", text):
                    raise ValueError("completion comparison was not exercised")
            results.append({"config": config, "case": case or "golden", "passed": True,
                            "modelSha256": sha(binary.read_bytes())})
        if suite == "backend":
            rc, text = run([str(binary), "+oracle_negative"], config + "-negative", 300)
            if rc == 0 or "golden C exp=16,16" not in text:
                raise ValueError("GEMM negative oracle failed to detect corruption")
        (out / "results.json").write_text(json.dumps({"status": "INCOMPLETE", "cases": results,
            "scope": "selected hyp GEMM leaves; not aggregate or physical qualification"}, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    if "TH_DATA_DIR" in os.environ:
        result_path = Path(os.environ["TH_OUT_DIR"]) / "results.json"
        try:
            result = remote()
        except Exception as error:
            record = json.loads(result_path.read_text()) if result_path.exists() else {}
            record.update(status="INCOMPLETE", error=str(error))
            result_path.write_text(json.dumps(record, indent=2) + "\n")
            raise
        record = json.loads(result_path.read_text()) if result_path.exists() else {}
        record.update(status="PASS" if result == 0 else "FAIL", rc=result)
        result_path.write_text(json.dumps(record, indent=2) + "\n")
        sys.exit(result)
    parser = argparse.ArgumentParser()
    parser.add_argument("--prepare", required=True)
    parser.add_argument("--baseline")
    args = parser.parse_args()
    prepare(args.prepare, args.baseline)
