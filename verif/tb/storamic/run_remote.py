# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tarfile
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
    "cpu-origin-atomic", "cpu-pause", "origin-profile", "origin-queue",
    "cpu-strict-pins",
    "stq-commit-flush",
    "checkpoint-route",
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
    "fetch-queue-synth", "csr-scc", "core-scc", "checkpoint-route-formal",
    "axi-gate-formal", "native-c2", "native-c2-wide", "prim-aw",
})


# Build-closure pathspecs for the native-c2 source tar: everything
# ``make verilate target=cv64a6_imafdc_sv39`` plus the firmware tree needs.
# Explicit directory prefixes (never file globs) so untracked-but-unignored
# scratch trees elsewhere in the repo (remote-runs.drvfs-bak, .cache,
# node_modules, obj_dir, work-ver-*) cannot leak in; --exclude-standard drops
# gitignored build products while keeping new untracked source files.
_C2_TAR_DIRS = (
    "core", "corev_apu", "vendor", "common", "util", "config",
    "g6lc_storamic", "verif/tb/storamic", "verif/tb/core",
    "verif/tests/custom",
)
_C2_TAR_FILES = ("Makefile", "Flist.ariane", "verilator_config.vlt")
# Belt-and-suspenders: never tar generated/binary trees or formal/sim
# artifact dirs even though ``-co`` (no --exclude-standard) is required —
# needed sources such as ``core/fetch/*.sv`` are themselves gitignored, so
# exclude-standard would drop real build inputs. The explicit directory
# pathspecs above are what keep repo-wide scratch (remote-runs.drvfs-bak,
# .cache, node_modules) out.
_C2_TAR_SKIP_SUBSTR = ("/obj_dir/", "/node_modules/", "/.cache/",
                       "/__pycache__/", "/.venv/", "/work-ver",
                       "/formal/", "/formal_", "/engine_", "/sim_work",
                       "/csrc/", "/simv.daidir/")
_C2_TAR_SKIP_SUFFIX = (".o", ".a", ".so", ".d", ".elf", ".pyc",
                       ".tar", ".tar.gz", ".tgz", ".zip", ".bin",
                       ".vcd", ".fst", ".wlf", ".vpd", ".fsdb",
                       ".gcno", ".gcda", ".gcov")


def _ls_files(cwd, prefix, pathspecs=None):
    """Yield ``(repo_rel, abspath)`` for ``git ls-files -co`` under ``cwd``.

    ``prefix`` is the repo-relative path of ``cwd`` ("" for the superproject);
    ``pathspecs`` are interpreted relative to ``cwd``. ``-co`` without
    ``--exclude-standard`` keeps gitignored build inputs (e.g. ``core/fetch``)
    while dropping nothing tracked. Submodule *contents* are NOT returned —
    ``ls-files`` records only the gitlink — so callers recurse separately.
    """
    cmd = ["git", "-C", str(cwd), "ls-files", "-co", "-z"]
    if pathspecs:
        cmd += ["--"] + list(pathspecs)
    try:
        out = subprocess.check_output(cmd, text=False)
    except Exception:
        return
    base = Path(cwd)
    for raw in out.split(b"\0"):
        if not raw:
            continue
        rel = raw.decode("utf-8", "surrogateescape")
        yield (f"{prefix}/{rel}" if prefix else rel), base / rel


def _submodule_status(cwd):
    """Yield ``(path, initialized)`` for submodules directly under ``cwd``.

    ``git submodule status`` lines are ``<flag><sha> <path> (<describe>)``; a
    leading ``-`` marks *uninitialized* (no worktree, no files on disk), while
    ``' '/'+'/'U'`` all have a populated worktree. Unlike ``_ls_files`` this
    does NOT swallow git failures: a silent empty result here once produced a
    native-c2 source tar with zero submodule contents, which only failed deep
    inside the remote build on missing sources (``hpdcache.Flist``).
    """
    try:
        out = subprocess.check_output(
            ["git", "-C", str(cwd), "submodule", "status"], text=True)
    except Exception as exc:
        raise RuntimeError(
            f"git submodule status failed under {cwd}: {exc}") from exc
    for line in out.splitlines():
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) >= 2:
            yield parts[1], not line.startswith("-")


def _submodule_paths(cwd):
    """Repo-relative paths of *initialized* submodules directly under ``cwd``."""
    for path, init in _submodule_status(cwd):
        if init:
            yield path


def _c2_submodule_coverage(root):
    """Count ``(initialized, total)`` submodule paths under the tar dirs.

    Traversal mirrors ``_add_sub`` — same depth cap and ``vendor/`` nested
    skip — so only submodules the tar would actually pull are counted.
    ``total`` includes uninitialized (``-``) entries; ``initialized`` excludes
    them. ``total > 0`` with ``initialized == 0`` means the whole submodule
    closure was dropped (e.g. a fresh clone without ``--recursive``), which
    would ship a source tar with no submodule files and fail remotely on
    missing sources. Individual uninitialized submodules (e.g. the cvfpu
    ``tb/flexfloat`` testbench) are tolerated — the build closure does not
    require them.
    """
    init = total = 0

    def _walk(cwd, prefix, depth):
        nonlocal init, total
        for sp, ok in _submodule_status(cwd):
            rel = f"{prefix}/{sp}" if prefix else sp
            if not any(rel == d or rel.startswith(d + "/")
                       for d in _C2_TAR_DIRS):
                continue
            total += 1
            if not ok:
                continue
            init += 1
            if depth >= 4 or rel.startswith("vendor/"):
                continue
            _walk(Path(cwd) / sp, rel, depth + 1)

    _walk(Path(root), "", 0)
    return init, total


def _c2_tar_members(root):
    """Collect ``{repo_rel: abspath}`` for the native-c2 build closure.

    Superproject files come from ``git ls-files -co`` over the explicit
    ``_C2_TAR_DIRS``/``_C2_TAR_FILES`` pathspecs. Every initialized submodule
    whose path sits under a tar dir contributes its own ``ls-files`` set —
    ``git ls-files`` only records the gitlink, never the submodule's files, so
    without this the ariane build misses hpdcache/cvfpu/riscv-dbg/etc. Nested
    submodules are recursed (cvfpu's ``src/common_cells`` is required) except
    under ``vendor/`` where nested trees are toolchain/SDK bundles the
    Verilator build never reads.
    """
    members = {}
    for repo_rel, ap in _ls_files(root, "", _C2_TAR_DIRS + _C2_TAR_FILES):
        members[repo_rel] = ap

    def _add_sub(sub_path, depth):
        sub = root / sub_path
        if not sub.is_dir():
            return
        for repo_rel, ap in _ls_files(sub, sub_path):
            members[repo_rel] = ap
        # Recurse into this submodule's own submodules, but never descend into
        # vendor toolchain/SDK bundles (riscv-gnu-toolchain, newlib, verilator,
        # ... under vendor/ara) which are not part of the ariane build.
        if depth >= 4 or sub_path.startswith("vendor/"):
            return
        for nested in _submodule_paths(sub):
            _add_sub(f"{sub_path}/{nested}", depth + 1)

    for sp in _submodule_paths(root):
        if any(sp == d or sp.startswith(d + "/") for d in _C2_TAR_DIRS):
            _add_sub(sp, 0)
    return members


def _c2_source_tar(root, dest):
    """Freeze the build closure into a gzipped tar for the native-c2 stage.

    The member set (superproject + needed submodule contents) is collected by
    ``_c2_tar_members``; repo-relative arc names keep the on-disk layout
    identical to a checkout. Binary/artifact members are dropped by the
    ``_C2_TAR_SKIP_*`` filters. Returns the written Path.
    """
    root = Path(root)
    n_init, n_total = _c2_submodule_coverage(root)
    if n_total and not n_init:
        raise RuntimeError(
            "native-c2 source closure found submodules under the tar dirs "
            f"but none are initialized ({n_total} registered); run "
            "`git submodule update --init --recursive` and retry")
    members = _c2_tar_members(root)
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(dest, "w:gz", compresslevel=6) as tar:
        for rel in sorted(members):
            if any(s in ("/" + rel) for s in _C2_TAR_SKIP_SUBSTR):
                continue
            if rel.endswith(_C2_TAR_SKIP_SUFFIX):
                continue
            p = members[rel]
            if not p.is_file():
                continue
            try:
                data = p.read_bytes()
            except OSError:
                continue
            info = tarfile.TarInfo(rel)
            info.size = len(data)
            info.mtime = 0
            tar.addfile(info, io.BytesIO(data))
    return dest


def query_command(remote_root, run_id, pattern, tail=50, file_glob="*.log"):
    """Shell command grepping a previous remote run's logs.

    Searches both ``output/`` (pulled evidence: logs, json, summaries) and
    ``work/`` (kept-local bulky build products such as Verilator Mdirs) under
    ``<remote_root>/runs/<run_id>/``. ``work`` may not exist; ``find`` reports
    it on stderr which is suppressed, and ``xargs -r`` skips an empty list.
    """
    base = f"{remote_root}/runs/{run_id}"
    find = ("find output work -type f "
            f"-name {shlex.quote(file_glob)} 2>/dev/null")
    grep = f"xargs -r grep -HnE {shlex.quote(pattern)} 2>/dev/null"
    return (f"cd {shlex.quote(base)} && {find} | {grep} | tail -{int(tail)}")


def run_query(args, root):
    """--query mode: grep/tail a previous remote run without launching stages."""
    if not args.grep:
        print("Incomplete: --query requires --grep REGEX")
        return 4
    sys.path.insert(0, str(root / "verif/regress/remote"))
    import testharness_proxy as gateway
    remote_cmd = query_command(gateway.REMOTE_ROOT, args.query,
                               args.grep, args.tail, args.query_glob)
    bun = shutil.which("bun")
    if bun is None:
        print("Incomplete: Bun is required for the configured remote gateway")
        return 4
    command = [
        bun, str(root / "build-platform/src/cli/index.ts"), "remote",
        "--timeout", str(args.timeout), "shell", "--", remote_cmd,
    ]
    return subprocess.call(command, cwd=root)


def _git_head(path):
    """Return `git rev-parse HEAD` for a repo/submodule path, or None."""
    try:
        return subprocess.check_output(
            ["git", "-C", str(path), "rev-parse", "HEAD"],
            text=True, stderr=subprocess.DEVNULL).strip() or None
    except Exception:
        return None


def load_tools_record(args, root):
    """Load the tools record. Returns (record|None, error|None, path|None).

    record is None when no record is configured or the file is absent (the
    legacy per-flag defaults then apply).  error is a string when a configured
    record exists but cannot be used.  path is the resolved record file so the
    caller can pin it into the source manifest.
    """
    record_path = getattr(args, "tools_record", None)
    if record_path == "none":
        return None, None, None
    if record_path is None:
        record_path = root / "verif/tb/storamic/storamic_tools.json"
    path = Path(record_path)
    if not path.is_file():
        return None, None, None
    try:
        record = json.loads(path.read_text())
    except Exception as exc:
        return None, f"tools record {path} is not valid JSON: {exc}", path
    if not isinstance(record, dict):
        return None, f"tools record {path} is not a JSON object", path
    return record, None, path


def apply_tools_record(args, record):
    """Fill unset tool selectors from the record; explicit args/env win."""
    verilator = record.get("verilator") or {}
    if args.verilator is None and verilator.get("verilator"):
        args.verilator = verilator["verilator"]
    if (args.runtime_json is None and args.runtime_record is None
            and verilator.get("runtime_json")):
        args.runtime_json = verilator["runtime_json"]
    if (args.runtime_header_sha256 is None
            and verilator.get("runtime_header_sha256")):
        args.runtime_header_sha256 = verilator["runtime_header_sha256"]
    yosys = record.get("yosys") or {}
    if args.yosys is None and yosys.get("path"):
        args.yosys = yosys["path"]
    if args.solver_bin is None and record.get("solver_bin"):
        args.solver_bin = record["solver_bin"]


def verify_tool_heads(root, record):
    """Refuse when a recorded tool commit != the current submodule HEAD."""
    for sub, expected in (
        ("tools/verilator", (record.get("verilator") or {}).get("head")),
        ("tools/yosys", (record.get("yosys") or {}).get("head")),
    ):
        if not expected:
            continue
        actual = _git_head(root / sub)
        if actual != expected:
            return (f"{sub} HEAD {actual or '<unresolved>'} != tools record "
                    f"{expected}; rebuild or re-pin storamic_tools.json")
    return None


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
    parser.add_argument("--tools-record", default=None,
                        help="Tools record JSON supplying default tool paths "
                             "(default: verif/tb/storamic/storamic_tools.json; "
                             "pass 'none' to disable)")
    parser.add_argument("--output-root", type=Path)
    parser.add_argument("--timeout", type=int, default=2400,
                        help="Remote harness timeout in seconds")
    parser.add_argument("--prepare-only", action="store_true",
                        help="Write source manifest and launch plan locally; never contact the host")
    parser.add_argument("--query", metavar="RUN_ID", default=None,
                        help="grep/tail a previous remote run's logs (output/ and work/) "
                             "instead of launching stages; pair with --grep")
    parser.add_argument("--grep", metavar="REGEX", default=None,
                        help="regular expression to search for in --query mode")
    parser.add_argument("--tail", type=int, default=50,
                        help="maximum matching lines returned in --query mode")
    parser.add_argument("--file", dest="query_glob", default="*.log",
                        help="file glob to search in --query mode (default: *.log)")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    if args.query:
        return run_query(args, root)
    toolrec, record_error, toolrec_path = load_tools_record(args, root)
    if record_error:
        print("Incomplete: " + record_error)
        return 4
    if toolrec:
        apply_tools_record(args, toolrec)
        head_error = verify_tool_heads(root, toolrec)
        if head_error:
            print("Incomplete: " + head_error)
            return 4
    stages = args.stages.split(",")
    if len(stages) != len(set(stages)) or not set(stages) <= ALLOWED_STAGES:
        parser.error("invalid or duplicate stages")
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
    if set(stages) & {"cpu-pause"}:
        cpu_plan = json.loads(
            (root / "verif/tb/storamic/cpu_origin_plan.json").read_text())
        cpu_closure = cpu_plan["files"] + cpu_plan.get("support_files", [])
        sources += [p for p in [root / rel for rel in cpu_closure]
                    if p not in sources]
        sources += [p for p in [root / path for path in [
            "verif/tb/storamic/cpu_origin_plan.json",
            "verif/tb/storamic/tb_g6lc_storamic_cpu_pause.sv",
            "verif/tb/storamic/g6lc_cpu_pause_program.py",
            "verif/tb/storamic/origin_cache.vlt",
            "verif/tb/apu/g6lc_dram_peek64_stub.cpp",
            "verif/tb/storamic/run_cpu_pause.py",
            "core/cva6_rvfi.sv",
            "corev_apu/storamic/g6lc_storamic_axi_gate.sv",
            "corev_apu/storamic/g6lc_storamic_cpu_pause.sv",
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
    if set(stages) & {"checkpoint-route", "checkpoint-route-formal"}:
        from run_checkpoint_route import FILES as ROUTE_FILES
        sources += [p for p in [root / rel for rel in ROUTE_FILES]
                    if p not in sources]
        sources += [p for p in [root / path for path in [
            "verif/tb/storamic/run_checkpoint_route.py",
            "verif/tb/storamic/route_native_unoptflat_pins.json",
        ]] if p not in sources]
    if set(stages) & {"axi-gate-formal"}:
        from run_axi_gate_formal import FILES as AXI_GATE_FILES
        sources += [p for p in [root / rel for rel in AXI_GATE_FILES]
                    if p not in sources]
        sources += [p for p in [root / path for path in [
            "verif/tb/storamic/run_axi_gate_formal.py",
        ]] if p not in sources]
    if set(stages) & {"native-c2", "native-c2-wide", "prim-aw"}:
        # native-c2 builds the full ariane_testharness from a frozen snapshot of
        # the working tree, uploaded as one gzipped tar and sha256-pinned in the
        # manifest (the leaf re-hashes data/cva6-src-c2.tar.gz before extract).
        # This is not the leaf's curated component set; it is the ~30 MB closure
        # run_native_c2.py needs to run `make verilate` for ariane_testharness.
        # Write under gitignored tmp/ (a real repo dir): remote-runs is a
        # symlink that resolves outside /mnt/<drive> in WSL, which would make
        # _listing() emit an unresolvable upload path for the tar.
        # Per-process subdirectory: _c2_source_tar rebuilds unconditionally and
        # gzip embeds a timestamp, so two concurrent c2 stages writing the same
        # tmp/cva6-src-c2.tar.gz would race between manifest-hash and push and
        # trip STORAMIC_SOURCE_IDENTITY on the remote leaf. The basename must
        # stay cva6-src-c2.tar.gz (run_native_c2.SRC_TAR_NAME).
        c2_tar = _c2_source_tar(
            root, root / "tmp" / f"c2-{os.getpid()}" / "cva6-src-c2.tar.gz")
        sources += [p for p in [root / path for path in [
            "verif/tb/storamic/run_native_c2.py",
            "verif/tb/storamic/g6lc_storamic_c2_monitor.sv",
            "verif/tests/custom/storamic/storamic_c2.c",
            "verif/tests/custom/storamic/storamic_virtio_blk.c",
            "corev_apu/storamic/g6lc_storamic_checkpoint_route.sv",
            "corev_apu/tb/ariane_testharness.sv",
            "corev_apu/tb/g6lc_tb.cpp",
        ]] if p not in sources]
        if c2_tar.is_file() and c2_tar not in sources:
            sources.append(c2_tar)
    if args.runtime_record:
        record = args.runtime_record.resolve()
        if record.name != "runtime.json":
            parser.error("--runtime-record must name runtime.json")
        sources += [record, record.with_name("canaries.json")]
    if toolrec_path is not None:
        toolrec_path = Path(toolrec_path)
        if toolrec_path.is_file() and toolrec_path not in sources:
            sources.append(toolrec_path)
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
        "--tag", tag, "--pull", "--pull-exclude-build", "--dest", str(dest),
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
    if toolrec:
        toolrec_yosys = toolrec.get("yosys") or {}
        # Pin the expected binary sha only when the selected Yosys is the
        # recorded one; an explicit --yosys override opts out of that identity.
        if (toolrec_yosys.get("sha256")
                and args.yosys == toolrec_yosys.get("path")):
            command += ["--env",
                        "STORAMIC_EXPECT_YOSYS_SHA256=" + toolrec_yosys["sha256"]]
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
