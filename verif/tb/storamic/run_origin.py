#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Frozen local provenance component checks. Never remote/native qualification."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", required=True)
    parser.add_argument("--profiles", default="profile,shim,queue,cache,adapter")
    args = parser.parse_args()
    selected = args.profiles.split(",")
    if len(set(selected)) != len(selected) or set(selected) - {"profile", "shim", "queue", "cache", "adapter"}:
        parser.error("unknown or duplicate profile")
    root = Path(__file__).resolve().parents[3]
    out = Path(args.output_root).resolve()
    workspace = root / "build-platform/workspace"
    if not out.is_relative_to(workspace.resolve()):
        parser.error("output must be contained in build-platform/workspace")
    out.mkdir(parents=True, exist_ok=False)
    source = out / "source"
    source.mkdir()
    common = [
        "core/include/config_pkg.sv", "core/include/g6lc64_ooo_config_pkg.sv",
        "core/include/riscv_pkg.sv", "core/include/ariane_pkg.sv",
    ]
    queue = ["core/ooo/g6lc_ooo_pkg.sv", "core/lsu_bypass.sv", "core/store_buffer.sv",
             "core/cva6_fifo_v3.sv", "core/amo_buffer.sv", "core/store_unit.sv",
             "verif/tb/storamic/tb_g6lc_storamic_origin_queue.sv"]
    adapter = [
        "core/include/build_config_pkg.sv", "core/include/wt_cache_pkg.sv",
        "vendor/pulp-platform/axi/src/axi_pkg.sv",
        "corev_apu/tb/ariane_axi_pkg.sv",
        "vendor/pulp-platform/common_cells/src/cf_math_pkg.sv",
        "vendor/pulp-platform/common_cells/src/lzc.sv",
        "vendor/pulp-platform/common_cells/src/rr_arb_tree.sv",
        "core/cva6_fifo_v3.sv",
        "core/axi_shim.sv", "core/cache_subsystem/wt_axi_adapter.sv",
        "verif/tb/uncore/tb_g6lc_wt_axi_attr.sv",
    ]
    shim = ["core/include/config_pkg.sv", "vendor/pulp-platform/axi/src/axi_pkg.sv",
            "core/axi_shim.sv", "verif/tb/storamic/tb_g6lc_storamic_origin_shim.sv"]
    profile = ["core/include/config_pkg.sv",
               "verif/tb/storamic/tb_g6lc_storamic_origin_profile.sv"]
    cache = [
        "verif/tb/storamic/origin_cache.vlt",
        "core/include/build_config_pkg.sv", "core/include/wt_cache_pkg.sv",
        "vendor/pulp-platform/common_cells/src/cf_math_pkg.sv",
        "vendor/pulp-platform/common_cells/src/lzc.sv",
        "vendor/pulp-platform/common_cells/src/rr_arb_tree.sv",
        "vendor/pulp-platform/common_cells/src/lfsr.sv",
        "vendor/pulp-platform/common_cells/src/exp_backoff.sv",
        "core/cva6_fifo_v3.sv",
        "vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv",
        "common/local/util/tc_sram_wrapper.sv", "common/local/util/sram.sv",
        "common/local/util/sram_cache.sv",
        "core/cache_subsystem/wt_dcache_mem.sv",
        "core/cache_subsystem/wt_dcache_ctrl.sv",
        "core/cache_subsystem/wt_dcache_wbuffer.sv",
        "core/cache_subsystem/wt_dcache_missunit.sv",
        "core/cache_subsystem/wt_dcache.sv",
        "verif/tb/storamic/tb_g6lc_storamic_origin_cache.sv",
    ]
    files = set(common + queue + cache + adapter + shim + profile + [
        "core/cva6.sv", "core/ex_stage.sv", "core/load_store_unit.sv",
        "core/cache_subsystem/wt_cache_subsystem.sv"])
    for folder in ("core/include", "core/ooo", "vendor/pulp-platform/axi/include",
                   "vendor/pulp-platform/common_cells/include"):
        files.update(p.relative_to(root).as_posix() for p in (root / folder).rglob("*.svh"))
    hashes = {}
    for name in sorted(files):
        dest = source / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / name, dest)
        hashes[name] = hashlib.sha256(dest.read_bytes()).hexdigest()
    types_source = (source / "core/cache_subsystem/wt_cache_subsystem.sv").read_text(encoding="utf-8")
    types = types_source.split("  // dcache interface", 1)[1].split(
        "  logic icache_adapter_data_req", 1)[0]
    header = source / "wt-types.svh"
    header.write_text(types_source.split("module wt_cache_subsystem", 1)[0] + types, encoding="utf-8")
    hashes["generated:wt-types.svh"] = hashlib.sha256(header.read_bytes()).hexdigest()
    cpu_source = (source / "core/cva6.sv").read_text(encoding="utf-8")
    cpu_types = cpu_source.split("module cva6", 1)[0]
    for name in ("dcache_req_i_t", "dcache_req_o_t"):
        match = re.search(r"localparam type " + name + r"\s*=\s*(struct packed\s*\{.*?\})",
                          cpu_source, re.DOTALL)
        if not match:
            raise RuntimeError("CPU cache type extraction: " + name)
        cpu_types += "\ntypedef " + match.group(1) + " " + name + ";\n"
    cpu_header = source / "cpu-dcache-types.svh"
    cpu_header.write_text(cpu_types, encoding="utf-8")
    hashes["generated:cpu-dcache-types.svh"] = hashlib.sha256(cpu_header.read_bytes()).hexdigest()
    verilator = Path(shutil.which("verilator") or parser.error("verilator unavailable")).resolve()
    if os.name == "posix":
        import resource
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    report = {"qualification": False, "origin": "local-component", "status": "incomplete",
              "sources": hashes, "results": [], "verilator": str(verilator),
              "verilator_sha256": hashlib.sha256(verilator.read_bytes()).hexdigest(),
              "verilator_version": subprocess.check_output([str(verilator), "--version"], text=True)}
    report["runner_sha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    binary = shutil.which("verilator_bin")
    if binary:
        report["verilator_bin_sha256"] = hashlib.sha256(Path(binary).read_bytes()).hexdigest()

    def save():
        (out / "result.json").write_text(json.dumps(report, indent=2), encoding="utf-8")

    def build(name, top, inputs, parameters=()):
        command = [str(verilator), "--binary", "--timing", "--assert", "-j", "2",
                   "-Wno-fatal", "-Werror-LATCH", "-Werror-UNOPTFLAT", "--top-module", top,
                   "--Mdir", str(out / name), "-o", "test"]
        for folder in ("", "core/include", "core/ooo", "vendor/pulp-platform/axi/include",
                       "vendor/pulp-platform/common_cells/include"):
            command.append("-I" + str(source / folder))
        command += list(parameters) + [str(source / p) for p in inputs]
        (out / f"{name}-command.json").write_text(json.dumps(command), encoding="utf-8")
        with (out / f"{name}-build.log").open("w") as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=300)
        return out / name / "test"

    def run(binary, label, marker, arguments=(), negative=False):
        result = subprocess.run([str(binary), *arguments], capture_output=True, text=True, timeout=30)
        text = result.stdout + result.stderr
        (out / f"{label}.log").write_text(text, encoding="utf-8")
        matched = (result.returncode != 0 and marker in text) if negative else (
            result.returncode == 0 and marker in text and "%Error" not in text)
        report["results"].append({"case": label, "rc": result.returncode, "matched": matched,
                                  "negative_oracle": negative})
        save()
        if not matched:
            raise RuntimeError(label)

    save()
    try:
        if "profile" in selected:
            binary = build("profile", "tb_g6lc_storamic_origin_profile", profile)
            run(binary, "profile", "ORIGIN_PROFILE_PASS")
            run(binary, "profile-negative", "negative-shared-writer", ["+oracle_negative"], True)
            run(binary, "profile-debug-negative", "negative-debug-authority", ["+oracle_debug"], True)
        if "shim" in selected:
            for enabled in (0, 1):
                name = f"shim-{enabled}"
                binary = build(name, "tb_g6lc_storamic_origin_shim", shim, [f"-GEnabled={enabled}"])
                run(binary, name, "ORIGIN_SHIM_PASS")
                run(binary, name + "-negative", "negative-oracle", ["+oracle_negative"], True)
        if "queue" in selected:
            binary = build("queue", "tb_g6lc_storamic_origin_queue", common + queue)
            run(binary, "queue", "ORIGIN_QUEUE_PASS")
            run(binary, "queue-negative", "negative-oracle", ["+oracle_negative"], True)
        if "cache" in selected:
            for enabled in (0, 1):
                name = f"cache-{enabled}"
                binary = build(name, "tb_g6lc_storamic_origin_cache", common + cache,
                               [f"-GEnabled={enabled}"])
                run(binary, name, "ORIGIN_CACHE_PASS")
                run(binary, name + "-negative", "ORIGIN_CACHE_FAIL origin",
                    ["+oracle_negative"], True)
        if "adapter" in selected:
            for origin in (0, 1):
                for alloc in (0, 1):
                    name = f"adapter-origin{origin}-alloc{alloc}"
                    binary = build(name, "tb_g6lc_wt_axi_attr", common + adapter,
                                   [f"-GORIGIN={origin}", f"-GALLOC={alloc}"])
                    for scenario in range(12):
                        label = name + f"-s{scenario}"
                        run(binary, label, "WT_ATTR_PASS", [f"+scenario={scenario}"])
                        run(binary, label + "-negative", "WT_ORIGIN_",
                            [f"+scenario={scenario}", "+oracle_origin"], True)
        report["status"] = "pass"
    except (subprocess.SubprocessError, RuntimeError) as error:
        report["status"] = "fail"
        report["error"] = str(error)
        raise
    finally:
        save()
    return 0


if __name__ == "__main__":
    sys.exit(main())
