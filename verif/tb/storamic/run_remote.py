# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid


SIMULATION_STAGES = frozenset({
    "protocol", "config", "integration", "model", "region", "map", "discovery",
    "regs", "ctrl", "virtio", "vring", "vblk", "vdev", "vdma", "dstore",
    "checkpoint-ram", "checkpoint-ctrl", "checkpoint-record", "checkpoint-model",
    "checkpoint-service", "checkpoint-endpoint", "checkpoint-policy", "quiesce",
    "checkpoint-writer", "checkpoint-writer-reset", "vdma-ownership", "policy-writer",
    "commit-defaults", "load-translation", "fetch-queue", "cpu-origin",
    "cpu-debug", "cpu-debug-stq-mutant", "cpu-debug-trigger",
    "cpu-debug-return", "cpu-debug-queue", "cpu-origin-unsupported",
    "cpu-origin-atomic", "origin-profile", "origin-queue",
    "cpu-strict-pins",
    "stq-commit-flush",
})
ALLOWED_STAGES = SIMULATION_STAGES | frozenset({
    "synth", "formal", "model-synth", "model-formal", "map-synth", "map-formal",
    "discovery-synth", "discovery-formal", "regs-synth", "regs-formal", "ctrl-synth",
    "virtio-synth", "virtio-formal", "vring-synth", "vring-formal", "vblk-synth",
    "vdev-synth", "vblk-formal", "vblk-flush-formal", "checkpoint-synth",
    "checkpoint-formal", "checkpoint-record-synth", "checkpoint-record-formal",
    "checkpoint-codec-formal", "checkpoint-io-formal", "checkpoint-model-synth",
    "checkpoint-service-synth", "checkpoint-service-formal", "checkpoint-endpoint-synth",
    "checkpoint-endpoint-formal", "quiesce-formal",
    "checkpoint-policy-synth", "checkpoint-policy-formal",
    "checkpoint-writer-synth",
    "checkpoint-writer-formal",
    "vdma-ownership-formal",
    "policy-writer-synth",
    "policy-writer-formal",
    "commit-defaults-formal", "commit-defaults-synth", "load-translation-synth",
    "fetch-queue-synth", "csr-scc", "core-scc",
})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--stages", default="protocol,config,integration,synth,formal")
    runtime_group = parser.add_mutually_exclusive_group()
    runtime_group.add_argument("--runtime-json", default=os.environ.get("REVIEW_RUNTIME_JSON"),
                               help="Validated runtime record already on the remote host")
    runtime_group.add_argument("--runtime-record", type=Path,
                               help="Upload local runtime.json and sibling canaries.json")
    parser.add_argument("--runtime-header-sha256",
                        default=os.environ.get("STORAMIC_RUNTIME_HEADER_SHA256"))
    parser.add_argument("--verilator", default=None,
                        help="Remote Verilator binary path under the gateway root")
    parser.add_argument("--yosys", default=None,
                        help="Remote Yosys binary path under the gateway root")
    parser.add_argument("--solver-bin", default=None,
                        help="Remote directory prepended to PATH (e.g. yices bin)")
    parser.add_argument("--output-root", type=Path)
    parser.add_argument("--timeout", type=int, default=2400,
                        help="Remote harness timeout in seconds")
    parser.add_argument("--prepare-only", action="store_true",
                        help="Write source manifest and launch plan locally; never contact the host")
    args = parser.parse_args()
    stages = args.stages.split(",")
    if len(stages) != len(set(stages)) or not set(stages) <= ALLOWED_STAGES:
        parser.error("invalid or duplicate stages")
    root = Path(__file__).resolve().parents[3]
    needs_runtime = bool(set(stages) & SIMULATION_STAGES)
    blockers = []
    if needs_runtime:
        if not (args.runtime_json or args.runtime_record):
            blockers.append("provide --runtime-json or --runtime-record")
        if not args.runtime_header_sha256:
            blockers.append("provide --runtime-header-sha256")
    if args.runtime_header_sha256 and (
            len(args.runtime_header_sha256) != 64 or
            any(c not in "0123456789abcdef" for c in args.runtime_header_sha256)):
        parser.error("--runtime-header-sha256 must be a lowercase SHA-256 digest")
    if blockers and not args.prepare_only:
        print("Incomplete: " + "; ".join(blockers))
        return 4
    sys.path.insert(0, str(root / "verif/regress/remote"))
    import testharness_proxy as gateway
    tool_root = gateway.REMOTE_ROOT + "/"
    for opt, val in (("--verilator", args.verilator), ("--yosys", args.yosys),
                     ("--solver-bin", args.solver_bin)):
        if val is not None and (not val.startswith(tool_root) or "/../" in val + "/"):
            parser.error(f"{opt} must be an absolute path under {tool_root}")
    flist = root / "g6lc_storamic/Flist.storamic"
    prefix = "${CVA6_REPO_DIR}/"
    sources = []
    for line in flist.read_text().splitlines():
        if not line.startswith(prefix + "g6lc_storamic/rtl/"):
            raise RuntimeError(f"unexpected standalone source entry: {line}")
        path = root / line.removeprefix(prefix)
        if not path.resolve().is_relative_to((root / "g6lc_storamic/rtl").resolve()):
            raise RuntimeError("source escapes first-party closure")
        sources.append(path)
    sources.append(Path(__file__).with_name("tb_g6lc_storamic.sv"))
    sources += [root / path for path in [
        "g6lc_storamic/Flist.storamic",
        "corev_apu/storamic/Flist.storamic_soc",
        "verif/tb/storamic/run_remote.py",
        "verif/tb/storamic/run-remote.sh",
        "verif/regress/remote/testharness_proxy.py",
        "verif/tb/storamic/tb_g6lc_storamic_config.sv",
        "verif/tb/storamic/tb_g6lc_storamic_region.sv",
        "verif/tb/storamic/tb_g6lc_storamic_map.sv",
        "verif/tb/storamic/formal_g6lc_storamic_map.sv",
        "verif/tb/storamic/tb_g6lc_storamic_discovery.sv",
        "verif/tb/storamic/formal_g6lc_storamic_discovery.sv",
        "verif/tb/storamic/tb_g6lc_storamic_regs.sv",
        "verif/tb/storamic/formal_g6lc_storamic_regs.sv",
        "verif/tb/storamic/tb_g6lc_storamic_virtio_mmio.sv",
        "verif/tb/storamic/formal_g6lc_storamic_virtio_mmio.sv",
        "verif/tb/storamic/formal_g6lc_storamic_virtio_pause.sv",
        "verif/tb/storamic/tb_g6lc_storamic_virtio_ring.sv",
        "verif/tb/storamic/formal_g6lc_storamic_virtio_ring.sv",
        "verif/tb/storamic/tb_g6lc_storamic_virtio_blk.sv",
        "verif/tb/storamic/tb_g6lc_storamic_virtio_dev.sv",
        "verif/tb/storamic/tb_g6lc_storamic_dma_axi.sv",
        "verif/tb/storamic/tb_g6lc_storamic_dma_ownership.sv",
        "verif/tb/storamic/formal_g6lc_storamic_dma_ownership.sv",
        "verif/tb/storamic/formal_g6lc_storamic_virtio_blk.sv",
        "verif/tb/storamic/tb_g6lc_storamic_ctrl_bridge.sv",
        "verif/tb/storamic/tb_g6lc_storamic_soc.sv",
        "verif/tb/storamic/tb_g6lc_storamic_model.sv",
        "verif/tb/storamic/tb_g6lc_storamic_quiesce.sv",
        "verif/tb/storamic/tb_g6lc_storamic_durable_store.sv",
        "verif/tb/storamic/tb_g6lc_storamic_checkpoint_ram.sv",
        "verif/tb/storamic/tb_g6lc_storamic_checkpoint_ctrl.sv",
        "verif/tb/storamic/formal_g6lc_storamic_checkpoint_ctrl.sv",
        "verif/tb/storamic/tb_g6lc_storamic_checkpoint_codec.sv",
        "verif/tb/storamic/tb_g6lc_storamic_checkpoint_media.sv",
        "verif/tb/storamic/tb_g6lc_storamic_checkpoint_model.sv",
        "verif/tb/storamic/tb_g6lc_storamic_checkpoint_service.sv",
        "verif/tb/storamic/formal_g6lc_storamic_checkpoint_service.sv",
        "verif/tb/storamic/tb_g6lc_storamic_checkpoint_policy.sv",
        "verif/tb/storamic/formal_g6lc_storamic_checkpoint_policy.sv",
        "verif/tb/storamic/tb_g6lc_storamic_checkpoint_endpoint.sv",
        "verif/tb/storamic/tb_g6lc_storamic_checkpoint_writer.sv",
        "verif/tb/storamic/tb_g6lc_storamic_policy_writer.sv",
        "verif/tb/storamic/formal_g6lc_storamic_policy_writer.sv",
        "verif/tb/storamic/formal_g6lc_storamic_checkpoint_writer.sv",
        "verif/tb/storamic/formal_g6lc_storamic_checkpoint_endpoint.sv",
        "verif/tb/storamic/formal_g6lc_storamic_store_drain.sv",
        "verif/tb/storamic/tb_g6lc_storamic_store_guard.sv",
        "verif/tb/storamic/formal_g6lc_storamic_checkpoint_codec.sv",
        "verif/tb/storamic/formal_g6lc_storamic_checkpoint_io.sv",
        "verif/tb/storamic/g6lc_storamic_sram_model.sv",
        "verif/tb/storamic/formal_g6lc_storamic.sv",
        "verif/tb/storamic/formal_g6lc_storamic_model.sv",
        "verif/tb/storamic/formal_g6lc_storamic_quiesce.sv",
        "verif/regress/remote/yosys_bin.py",
        "core/include/config_pkg.sv",
        "core/include/build_config_pkg.sv",
        "corev_apu/include/g6lc_storamic_soc_cfg_pkg.sv",
        "corev_apu/storamic/g6lc_storamic_attach.sv",
        "corev_apu/storamic/g6lc_storamic_ctrl_bridge.sv",
        "corev_apu/storamic/g6lc_storamic_dma_axi.sv",
        "corev_apu/storamic/g6lc_storamic_durable_store.sv",
        "corev_apu/storamic/g6lc_storamic_model_store.sv",
        "corev_apu/storamic/g6lc_storamic_model_stick.sv",
        "corev_apu/storamic/g6lc_storamic_sim_mem.sv",
        "corev_apu/storamic/g6lc_storamic_checkpoint_model.sv",
        "corev_apu/storamic/g6lc_storamic_checkpoint_endpoint.sv",
        "corev_apu/storamic/g6lc_storamic_checkpoint_writer_model.sv",
        "corev_apu/storamic/g6lc_storamic_policy_writer_model.sv",
        "vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv",
        "common/local/util/tc_sram_wrapper.sv",
        "common/local/util/sram.sv",
        "corev_apu/include/g6lc_ai_island_cfg_pkg.sv",
        "corev_apu/src/g6lc_ai_dram_backend.sv",
        "corev_apu/src/g6lc_ai_dram_join.sv",
        "vendor/pulp-platform/axi/src/axi_pkg.sv",
        "vendor/pulp-platform/axi/src/axi_intf.sv",
        "vendor/pulp-platform/axi/src/axi_id_prepend.sv",
        "vendor/pulp-platform/axi/src/axi_mux.sv",
        "vendor/pulp-platform/axi/include/axi/assign.svh",
        "vendor/pulp-platform/axi/include/axi/typedef.svh",
        "vendor/pulp-platform/common_cells/include/common_cells/registers.svh",
        "vendor/pulp-platform/common_cells/src/cf_math_pkg.sv",
        "vendor/pulp-platform/common_cells/src/lzc.sv",
        "vendor/pulp-platform/common_cells/src/rr_arb_tree.sv",
        "vendor/pulp-platform/common_cells/src/fifo_v3.sv",
        "vendor/pulp-platform/common_cells/src/spill_register.sv",
        "vendor/pulp-platform/common_cells/src/spill_register_flushable.sv",
    ]]
    if set(stages) & {"commit-defaults", "commit-defaults-formal", "commit-defaults-synth",
                      "load-translation", "load-translation-synth"}:
        # Explicit RV64GC reference fixture, not a production target selection.
        sources += [root / path for path in [
            "core/include/cv64a6_imafdc_sv39_config_pkg.sv",
            "core/include/riscv_pkg.sv", "core/include/ariane_pkg.sv",
        ]]
    if set(stages) & {"commit-defaults", "commit-defaults-formal", "commit-defaults-synth"}:
        sources += [root / path for path in [
            "core/commit_stage.sv",
            "verif/tb/storamic/g6lc_commit_defaults_fixture.sv",
            "verif/tb/storamic/tb_g6lc_commit_defaults.sv",
            "verif/tb/storamic/formal_g6lc_commit_defaults.sv",
            "verif/tb/storamic/run_commit_defaults.py",
        ]]
    if set(stages) & {"load-translation", "load-translation-synth"}:
        sources += [root / path for path in [
            "core/load_unit.sv", "core/lsu_bypass.sv",
            "verif/tb/core/tb_g6lc_rtl_review.sv",
            "verif/tb/storamic/run_load_translation.py",
        ]]
    if set(stages) & {"fetch-queue", "fetch-queue-synth"}:
        sources += [p for p in [root / path for path in [
            "core/include/g6lc64_smt2_config_pkg.sv",
            "core/include/riscv_pkg.sv", "core/include/ariane_pkg.sv",
            "core/fetch_B/g6lc_fetch_pkg.sv", "core/cva6_fifo_v3.sv",
            "core/fetch_B/instr_queue.sv",
            "verif/tb/core/tb_g6lc_fetch_queue.sv",
            "verif/tb/storamic/run_fetch_queue.py",
        ]] if p not in sources]
    if set(stages) & {"cpu-origin", "cpu-origin-unsupported", "cpu-origin-atomic"}:
        cpu_plan = json.loads(
            (root / "verif/tb/storamic/cpu_origin_plan.json").read_text())
        cpu_closure = cpu_plan["files"] + cpu_plan.get("support_files", [])
        sources += [p for p in [root / rel for rel in cpu_closure]
                    if p not in sources]
        sources += [root / path for path in [
            "verif/tb/storamic/cpu_origin_plan.json",
            "verif/tb/storamic/tb_g6lc_storamic_cpu_origin.sv",
            "verif/tb/storamic/g6lc_cpu_origin_program.py",
            "verif/tb/storamic/origin_cache.vlt",
            "verif/tb/apu/g6lc_dram_peek64_stub.cpp",
            "verif/tb/storamic/run_cpu_origin.py",
        ]]
    if set(stages) & {"cpu-debug", "cpu-debug-stq-mutant"}:
        cpu_plan = json.loads(
            (root / "verif/tb/storamic/cpu_origin_plan.json").read_text())
        cpu_closure = cpu_plan["files"] + cpu_plan.get("support_files", [])
        sources += [p for p in [root / rel for rel in cpu_closure]
                    if p not in sources]
        sources += [p for p in [root / path for path in [
            "verif/tb/storamic/cpu_origin_plan.json",
            "verif/tb/storamic/tb_g6lc_storamic_cpu_debug.sv",
            "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_interpreter.sv",
            "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_netlist.sv",
            "verif/tb/storamic/g6lc_cpu_debug_program.py",
            "verif/tb/storamic/g6lc_cpu_origin_program.py",
            "verif/tb/storamic/origin_cache.vlt",
            "verif/tb/apu/g6lc_dram_peek64_stub.cpp",
            "verif/tb/storamic/run_cpu_origin.py",
            "verif/tb/storamic/run_cpu_debug.py",
        ]] if p not in sources]
    if set(stages) & {"cpu-debug-trigger"}:
        cpu_plan = json.loads(
            (root / "verif/tb/storamic/cpu_origin_plan.json").read_text())
        cpu_closure = cpu_plan["files"] + cpu_plan.get("support_files", [])
        sources += [p for p in [root / rel for rel in cpu_closure]
                    if p not in sources]
        sources += [p for p in [root / path for path in [
            "verif/tb/storamic/cpu_origin_plan.json",
            "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_trigger.sv",
            "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_trigger_interpreter.sv",
            "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_netlist.sv",
            "verif/tb/storamic/g6lc_cpu_debug_trigger_program.py",
            "verif/tb/storamic/g6lc_cpu_debug_program.py",
            "verif/tb/storamic/g6lc_cpu_origin_program.py",
            "verif/tb/storamic/origin_cache.vlt",
            "verif/tb/apu/g6lc_dram_peek64_stub.cpp",
            "verif/tb/storamic/run_cpu_origin.py",
            "verif/tb/storamic/run_cpu_debug_trigger.py",
        ]] if p not in sources]
    if set(stages) & {"cpu-debug-return"}:
        cpu_plan = json.loads(
            (root / "verif/tb/storamic/cpu_origin_plan.json").read_text())
        cpu_closure = cpu_plan["files"] + cpu_plan.get("support_files", [])
        sources += [p for p in [root / rel for rel in cpu_closure]
                    if p not in sources]
        sources += [p for p in [root / path for path in [
            "verif/tb/storamic/cpu_origin_plan.json",
            "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_return.sv",
            "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_return_interpreter.sv",
            "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_netlist.sv",
            "verif/tb/storamic/g6lc_cpu_debug_return_program.py",
            "verif/tb/storamic/g6lc_cpu_debug_program.py",
            "verif/tb/storamic/g6lc_cpu_origin_program.py",
            "verif/tb/storamic/origin_cache.vlt",
            "verif/tb/apu/g6lc_dram_peek64_stub.cpp",
            "verif/tb/storamic/run_cpu_origin.py",
            "verif/tb/storamic/run_cpu_debug_return.py",
        ]] if p not in sources]
    if set(stages) & {"cpu-debug-queue"}:
        cpu_plan = json.loads(
            (root / "verif/tb/storamic/cpu_origin_plan.json").read_text())
        cpu_closure = cpu_plan["files"] + cpu_plan.get("support_files", [])
        sources += [p for p in [root / rel for rel in cpu_closure]
                    if p not in sources]
        sources += [p for p in [root / path for path in [
            "verif/tb/storamic/cpu_origin_plan.json",
            "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_queue.sv",
            "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_queue_interpreter.sv",
            "verif/tb/storamic/tb_g6lc_storamic_cpu_debug_netlist.sv",
            "verif/tb/storamic/g6lc_cpu_debug_program.py",
            "verif/tb/storamic/g6lc_cpu_origin_program.py",
            "verif/tb/storamic/origin_cache.vlt",
            "verif/tb/apu/g6lc_dram_peek64_stub.cpp",
            "verif/tb/storamic/run_cpu_origin.py",
            "verif/tb/storamic/run_cpu_debug_queue.py",
        ]] if p not in sources]
    if set(stages) & {"origin-profile", "origin-queue"}:
        # Pull the cpu_origin_plan closure too: it carries every package/.svh
        # the component benches may transitively include. Dedup makes this free
        # when CPU stages are co-selected.
        cpu_plan = json.loads(
            (root / "verif/tb/storamic/cpu_origin_plan.json").read_text())
        cpu_closure = cpu_plan["files"] + cpu_plan.get("support_files", [])
        sources += [p for p in [root / rel for rel in cpu_closure]
                    if p not in sources]
        sources += [p for p in [root / path for path in [
            "core/include/g6lc64_ooo_config_pkg.sv",
            "verif/tb/storamic/tb_g6lc_storamic_origin_profile.sv",
            "verif/tb/storamic/tb_g6lc_storamic_origin_queue.sv",
            "verif/tb/storamic/run_origin_remote.py",
        ]] if p not in sources]
    if set(stages) & {"stq-commit-flush"}:
        sources += [p for p in [root / path for path in [
            "core/include/config_pkg.sv",
            "core/include/g6lc64_ooo_config_pkg.sv",
            "core/include/riscv_pkg.sv",
            "core/include/ariane_pkg.sv",
            "core/ooo/g6lc_ooo_pkg.sv",
            "core/store_buffer.sv",
            "verif/tb/core/tb_g6lc_stq_commit_flush.sv",
            "verif/tb/storamic/run_stq_commit_flush.py",
        ]] if p not in sources]
    if set(stages) & {"csr-scc"}:
        sources += [p for p in [root / path for path in [
            "core/csr_regfile.sv", "core/trigger_module.sv",
            "core/include/config_pkg.sv", "core/include/riscv_pkg.sv",
            "core/include/ariane_pkg.sv", "core/include/build_config_pkg.sv",
            "core/include/cv64a6_imafdc_sv39_config_pkg.sv",
            "core/include/triggers_pkg.sv", "core/include/rvfi_types.svh",
            "verif/tb/storamic/run_csr_scc.py",
        ]] if p not in sources]
    if set(stages) & {"cpu-strict-pins", "core-scc"}:
        cpu_plan = json.loads(
            (root / "verif/tb/storamic/cpu_origin_plan.json").read_text())
        cpu_closure = cpu_plan["files"] + cpu_plan.get("support_files", [])
        sources += [p for p in [root / rel for rel in cpu_closure]
                    if p not in sources]
        sources += [p for p in [root / path for path in [
            "verif/tb/storamic/cpu_origin_plan.json",
            "verif/tb/storamic/g6lc_core_scc_top.sv",
            "verif/tb/storamic/g6lc_strict_pins_canary.sv",
            "verif/tb/storamic/cpu_strict_fields.vlt",
            "verif/tb/storamic/cpu_strict_pins.json",
            "verif/tb/storamic/tb_g6lc_storamic_cpu_origin.sv",
            "verif/tb/storamic/run_cpu_strict_pins.py",
            "verif/tb/storamic/run_core_scc.py",
        ]] if p not in sources]
    if args.runtime_record:
        record = args.runtime_record.resolve()
        if record.name != "runtime.json":
            parser.error("--runtime-record must name runtime.json")
        sources += [record, record.with_name("canaries.json")]
    configs = []
    tracked = subprocess.check_output(
        ["git", "-C", str(root), "ls-files", "--", "core/include/*config_pkg.sv"],
        text=True).splitlines()
    for rel in tracked:
        path = root / rel
        if "config" in stages and path.is_file() and "cva6_user_cfg_t cva6_cfg" in path.read_text(encoding="utf-8"):
            configs.append(path.name)
            if path not in sources:
                sources.append(path)
    if len({path.name for path in sources}) != len(sources):
        raise RuntimeError("duplicate source basename")
    missing = [str(path) for path in sources if not path.is_file()]
    if missing:
        print("Incomplete: missing local source inputs:\n" + "\n".join(missing))
        return 4
    manifest = {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                for path in sources}
    tag = "storamic-" + uuid.uuid4().hex[:12]
    dest = (args.output_root or root / "remote-runs") / tag / "output"
    runner = Path(__file__).with_name("run_leaf.py")
    runner_sha = hashlib.sha256(runner.read_bytes()).hexdigest()
    if args.runtime_record:
        args.runtime_json = gateway.REMOTE_ROOT + "/runs/" + tag + "/data/runtime.json"
    bun = shutil.which("bun")
    if bun is None:
        print("Incomplete: Bun is required for the configured remote gateway")
        return 4
    # The source manifest travels as an uploaded file, not as --env text: with
    # the config sweep the inline JSON exceeded the Windows command-line limit
    # and the launch failed without creating a run.
    dest.parent.mkdir(parents=True, exist_ok=True)
    manifest_file = dest.parent / "storamic-run-manifest.json"
    manifest_file.write_text(json.dumps({
        "stages": stages,
        "sources": manifest,
        "source_paths": {
            path.name: (path.relative_to(root).as_posix() if path.is_relative_to(root)
                        else "external-input/" + path.name) for path in sources},
    }, separators=(",", ":")))
    # Large closures (cpu-origin: ~380 files) overflow the Windows command
    # line when every source is a --data argument; the proxy expands a
    # one-path-per-line list locally instead. Paths are repo-relative so the
    # WSL-side proxy resolves them from the repository root.
    def _listing(path):
        resolved = path.resolve()
        if resolved.is_relative_to(root.resolve()):
            return resolved.relative_to(root.resolve()).as_posix()
        posix = resolved.as_posix()
        return "/mnt/" + posix[0].lower() + posix[2:]
    data_list = dest.parent / "storamic-data-list.txt"
    seen = set()
    data_list.write_text("".join(
        _listing(path) + "\n" for path in sources
        if not (str(path) in seen or seen.add(str(path)))))
    command = [
        bun, str(root / "build-platform/src/cli/index.ts"), "remote",
        "--timeout", str(args.timeout), "py", "--", str(runner),
        "--tag", tag, "--pull", "--dest", str(dest),
        "--data", str(manifest_file),
        "--env", "STORAMIC_MANIFEST_FILE=" + manifest_file.name,
        "--env", "STORAMIC_RUNNER_SHA=" + runner_sha,
        "--env", "STORAMIC_TARGET_CONFIGS=" + ",".join(configs),
        "--env", "STORAMIC_STAGES=" + args.stages,
        "--env", "VERILATOR=" + (args.verilator or
            gateway.REMOTE_ROOT + "/toolchains/verilator-" +
            gateway.VERILATOR_VERSION + "/bin/verilator"),
    ]
    if args.verilator:
        command += ["--env", "VERILATOR_ROOT=" +
                    args.verilator.rsplit("/", 2)[0]]
    if args.yosys:
        command += ["--env", "YOSYS=" + args.yosys]
        path_dirs = [args.yosys.rsplit("/", 1)[0]]
        if args.solver_bin:
            path_dirs.insert(0, args.solver_bin)
        path_dirs += ["/usr/local/bin", "/usr/bin", "/bin"]
        command += ["--env", "PATH=" + ":".join(path_dirs)]
    elif args.solver_bin:
        command += ["--env", "PATH=" + args.solver_bin +
                    ":/usr/local/bin:/usr/bin:/bin"]
    command += ["--data-list", str(data_list)]
    if args.runtime_json:
        command += ["--env", "STORAMIC_RUNTIME_JSON=" + args.runtime_json]
    if args.runtime_header_sha256:
        command += ["--env", "STORAMIC_RUNTIME_HEADER_SHA256=" + args.runtime_header_sha256]
    # cpu-debug-trigger diagnostics: forward the optional trace/subset knobs so
    # a remote run can emit +trace handshakes and/or run a case subset. These are
    # runtime selectors only; they do not alter any hashed source identity.
    for knob in ("G6LC_TRIGGER_TRACE", "G6LC_TRIGGER_ONLY", "G6LC_ATOMIC_ONLY",
                 "G6LC_ATOMIC_TRACE", "G6LC_ATOMIC_SMT", "G6LC_QUEUE_ONLY"):
        value = os.environ.get(knob)
        if value:
            command += ["--env", knob + "=" + value]
    plan = {
        "status": "prepared", "qualification": False,
        "tag": tag, "stages": stages, "blockers": blockers,
        "runner_sha256": runner_sha,
        "manifest_sha256": hashlib.sha256(manifest_file.read_bytes()).hexdigest(),
        "manifest": str(manifest_file), "output": str(dest),
        "command": command,
        "runtime_validation": "performed by the remote leaf, not by preparation",
        "tools": {"verilator": args.verilator, "yosys": args.yosys,
                  "solver_bin": args.solver_bin},
    }
    plan_file = dest.parent / "launch-plan.json"
    plan_file.write_text(json.dumps(plan, indent=2))
    if args.prepare_only:
        print(f"Prepared locally (no remote launch): {plan_file}")
        if blockers:
            print("Launch blocked: " + "; ".join(blockers))
        return 0
    rc = subprocess.call(command, cwd=root)
    result = dest / "leaf-result.json"
    if not result.exists():
        print(f"Incomplete: no leaf-result.json in {dest}")
        return 4
    record = json.loads(result.read_text())
    current = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
    if (current != manifest or record.get("sources") != manifest or
            record.get("stages") != stages or
            hashlib.sha256(runner.read_bytes()).hexdigest() != runner_sha):
        print("Incomplete: local/remote source or selected-stage identity changed")
        return 4
    if record.get("status") == "pass" and rc == 0:
        print(f"Storamic selected stages passed: {result}")
        return 0
    if rc != 0 and record.get("status") == "pass":
        print("Incomplete: transport or artifact collection did not complete successfully")
        return 4
    return 1 if record.get("status") == "fail" else 4


if __name__ == "__main__":
    sys.exit(main())
