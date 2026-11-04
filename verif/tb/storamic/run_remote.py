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
    parser.add_argument("--output-root", type=Path)
    args = parser.parse_args()
    stages = args.stages.split(",")
    if len(stages) != len(set(stages)) or not set(stages) <= {
        "protocol", "config", "integration", "model", "synth", "formal",
        "model-synth", "model-formal", "region", "map", "map-synth",
        "map-formal", "discovery", "discovery-synth", "discovery-formal",
        "regs", "regs-synth", "regs-formal", "ctrl", "ctrl-synth",
        "virtio", "virtio-synth", "virtio-formal",
        "vring", "vring-synth", "vring-formal", "vblk", "vblk-synth", "vdev", "vdev-synth", "vdma", "vblk-formal",
    }:
        parser.error("invalid or duplicate stages")
    root = Path(__file__).resolve().parents[3]
    if set(stages) & {"protocol", "config", "integration", "model", "region",
                      "map", "discovery", "regs", "ctrl", "virtio",
                      "vring", "vblk", "vdev", "vdma"}:
        if not (args.runtime_json or args.runtime_record) or not args.runtime_header_sha256:
            print("Incomplete: provide a validated runtime record and --runtime-header-sha256")
            return 4
    sys.path.insert(0, str(root / "verif/regress/remote"))
    import testharness_proxy as gateway
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
        "verif/tb/storamic/tb_g6lc_storamic_virtio_ring.sv",
        "verif/tb/storamic/formal_g6lc_storamic_virtio_ring.sv",
        "verif/tb/storamic/tb_g6lc_storamic_virtio_blk.sv",
        "verif/tb/storamic/tb_g6lc_storamic_virtio_dev.sv",
        "verif/tb/storamic/tb_g6lc_storamic_dma_axi.sv",
        "verif/tb/storamic/formal_g6lc_storamic_virtio_blk.sv",
        "verif/tb/storamic/tb_g6lc_storamic_ctrl_bridge.sv",
        "verif/tb/storamic/tb_g6lc_storamic_soc.sv",
        "verif/tb/storamic/tb_g6lc_storamic_model.sv",
        "verif/tb/storamic/g6lc_storamic_sram_model.sv",
        "verif/tb/storamic/formal_g6lc_storamic.sv",
        "verif/tb/storamic/formal_g6lc_storamic_model.sv",
        "verif/regress/remote/yosys_bin.py",
        "core/include/config_pkg.sv",
        "core/include/build_config_pkg.sv",
        "corev_apu/include/g6lc_storamic_soc_cfg_pkg.sv",
        "corev_apu/storamic/g6lc_storamic_attach.sv",
        "corev_apu/storamic/g6lc_storamic_ctrl_bridge.sv",
        "corev_apu/storamic/g6lc_storamic_dma_axi.sv",
        "corev_apu/storamic/g6lc_storamic_sim_mem.sv",
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
        if "config" in stages and path.is_file() and "cva6_user_cfg_t cva6_cfg" in path.read_text():
            configs.append(path.name)
            sources.append(path)
    if len({path.name for path in sources}) != len(sources):
        raise RuntimeError("duplicate source basename")
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
        "sources": manifest,
        "source_paths": {
            path.name: (path.relative_to(root).as_posix() if path.is_relative_to(root)
                        else "external-input/" + path.name) for path in sources},
    }, separators=(",", ":")))
    command = [
        bun, str(root / "build-platform/src/cli/index.ts"), "remote",
        "--timeout", "2400", "py", "--", str(runner),
        "--tag", tag, "--pull", "--dest", str(dest),
        "--data", str(manifest_file),
        "--env", "STORAMIC_MANIFEST_FILE=" + manifest_file.name,
        "--env", "STORAMIC_RUNNER_SHA=" + runner_sha,
        "--env", "STORAMIC_TARGET_CONFIGS=" + ",".join(configs),
        "--env", "STORAMIC_STAGES=" + args.stages,
        "--env", "VERILATOR=" + gateway.REMOTE_ROOT +
        "/toolchains/verilator-" + gateway.VERILATOR_VERSION + "/bin/verilator",
    ]
    for path in sources:
        command += ["--data", str(path)]
    if args.runtime_json:
        command += ["--env", "STORAMIC_RUNTIME_JSON=" + args.runtime_json]
    if args.runtime_header_sha256:
        command += ["--env", "STORAMIC_RUNTIME_HEADER_SHA256=" + args.runtime_header_sha256]
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
