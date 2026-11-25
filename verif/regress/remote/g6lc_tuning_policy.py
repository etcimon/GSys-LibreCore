#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Model-specific policy. The overlay driver owns all rewrites and output paths."""
import argparse
from fnmatch import fnmatchcase
import hashlib
from pathlib import Path
import re
import shutil
import subprocess


PASSES = (
    "packed-rows",
    "packed-mux-rows",
    "tiled-columns",
    "wrapped-columns",
    "packed-predicates",
    "strided-bit-columns",
    "circular-age-compare",
    "scatter-eq-mask",
    "wide-mux-guard",
    "assert-guard-hoist",
    "assert-cone-gate",
)
DEFAULT_PASSES = ("packed-rows", "tiled-columns")
VLT_FLAGS = (
    "-fclock-skip-sink",
    "-fclock-skip",
    "-fdfg-peephole-pack-byte-plane",
    "-fdfg-peephole-pack-predicates",
    "-fdfg-peephole-pack-bitwise-mux",
    "-fdfg-peephole-guard-empty-mask",
    "-fdfg-peephole-fuse-transpose-reductions",
    "--dumpi-sentinel",
    "--no-assert",
    "--x-initial-fast",
    "--x-assign-fast",
    "--inline-mult-500",
    "--output-split-cfuncs-2000",
)
VLT_FLAG_EXPANSIONS = {
    "--dumpi-sentinel": ["--dumpi-sentinel", "1"],
    "--x-initial-fast": ["--x-initial", "fast"],
    "--x-assign-fast": ["--x-assign", "fast"],
    "--inline-mult-500": ["--inline-mult", "500"],
    "--output-split-cfuncs-2000": ["--output-split-cfuncs", "2000"],
}
SENTINEL_PROBE_OPS = (
    "bit_select_concat",
    "masked_transpose_reductions",
    "masked_reduction",
    "strided_column_tile",
    "one_word_pext",
    "byte_movemask",
    "circular_age_compare",
    "scatter_eq_mask",
    "wide_mux_guard",
)


def lua_binary():
    for name in ("lua5.4", "lua5.3", "lua"):
        if path := shutil.which(name):
            return path
    repo_root = Path(__file__).resolve().parents[3]
    for base in (Path("/opt/testharness/toolchains"),
                 repo_root / "build-platform/workspace/tooling"):
        if not base.is_dir():
            continue
        for cand_dir in sorted(base.glob("lua*"), reverse=True):
            for name in ("lua5.4", "lua5.3", "lua"):
                cand = cand_dir / "bin" / name
                if cand.is_file():
                    return str(cand)
    return None


def _run_lua(prefix, command, plugin, rtl_sources=(), phase="overlay",
             markers=(), stats=None, sentinel_info=None):
    lua = lua_binary()
    if not lua:
        raise ValueError("explicit tuning plugin needs Lua 5.3 or 5.4 on the build host")
    runner = Path(__file__).with_name("g6lc_tuning_driver.lua")
    source = Path(plugin).read_bytes()
    header_lines = [n for n in rtl_sources]
    for m in sorted(set(markers)):
        header_lines.append(f"@marker\t{m}")
    for k, v in sorted((stats or {}).items()):
        header_lines.append(f"@stat\t{k}\t{v}")
    if sentinel_info:
        for op, cnt in sorted(sentinel_info.get("dfg", {}).items()):
            header_lines.append(f"@dfg\t{op}\t{cnt}")
        for k, v in sorted(sentinel_info.get("sched", {}).items()):
            header_lines.append(f"@sched\t{k}\t{v}")
    # Keep even a large RTL/metadata list out of argv. A blank line ends the header.
    payload = b"".join(ln.encode() + b"\n" for ln in header_lines) + b"\n" + source
    proc = subprocess.run([lua, "-E", str(runner), prefix, command, phase], input=payload,
                          capture_output=True, timeout=10)
    if proc.returncode:
        raise ValueError(f"Lua policy {Path(plugin).name}: {proc.stderr.decode(errors='replace').strip()}")
    version, *lines = proc.stdout.decode("ascii").splitlines()
    rules, vlt_flags, clock_skip, sentinel_probes = [], [], [], []
    for line in lines:
        parts = line.split("\t")
        if parts[0] == "@vlt_flag":
            if len(parts) != 2 or parts[1] not in VLT_FLAGS:
                raise ValueError(f"unsupported verilator flag in Lua policy {Path(plugin).name}")
            if parts[1] not in vlt_flags:
                vlt_flags.append(parts[1])
        elif parts[0] == "@clock_skip":
            if len(parts) != 3 or parts[1] not in ("sink", "causal") or parts[2] not in ("required", "opportunistic"):
                raise ValueError(f"unsupported clock-skip directive in Lua policy {Path(plugin).name}")
            clock_skip.append({"mode": parts[1], "policy": parts[2]})
        elif parts[0] == "@sentinel_probe":
            if len(parts) != 4 or parts[2] not in SENTINEL_PROBE_OPS:
                raise ValueError(f"unsupported sentinel probe in Lua policy {Path(plugin).name}")
            sentinel_probes.append({"name": parts[1], "op": parts[2], "targetGlob": parts[3]})
        else:
            if len(parts) != 3 or parts[2] not in PASSES:
                raise ValueError(f"empty or unsupported rule in Lua policy {Path(plugin).name}")
            rules.append(parts)
    if not rules and not vlt_flags and not clock_skip and not sentinel_probes:
        raise ValueError(f"empty or unsupported rule in Lua policy {Path(plugin).name}")
    meta = dict(profile="lua", plugin=Path(plugin).name,
                pluginSha256=hashlib.sha256(source).hexdigest(), runtime=version)
    if vlt_flags:
        meta["vltFlags"] = vlt_flags
    if clock_skip:
        meta["clockSkip"] = clock_skip
    if sentinel_probes:
        meta["sentinelProbes"] = sentinel_probes
    return rules, meta


def select_policy(prefix, command, plugin, rtl_sources=(), *,
                  markers=(), stats=None, sentinel_info=None):
    if plugin is None:
        if ("-DG6LC_HYP8_MC" not in command.split() or
                re.findall(r"(?:^| )--threads (\d+)(?= |$)", command) != ["2"]):
            raise ValueError("generated model is not the requested two-lane Hyp8 MC schedule")
        rules = [[prefix + "_g6lc_core" + suffix, "u_recover__DOT__", op]
                 for suffix in ("", "__pi[0-9]*") for op in DEFAULT_PASSES]
        return rules, {"profile": "packed-tiled"}
    return _run_lua(prefix, command, plugin, rtl_sources, phase="overlay",
                    markers=markers, stats=stats, sentinel_info=sentinel_info)


def expand_verilator_flags(flags):
    out = []
    for fl in flags:
        out.extend(VLT_FLAG_EXPANSIONS.get(fl, [fl]))
    return out


def plan_verilator_flags(prefix, command, plugin, rtl_sources=()):
    """Pre-verilate policy query returning allowlisted Verilator optimization flags."""
    _, meta = _run_lua(prefix, command, plugin, rtl_sources, phase="vlt-flags")
    return expand_verilator_flags(meta.get("vltFlags", [])), meta


def class_rules(rules, cls):
    return [(marker, op) for pattern, marker, op in rules if fnmatchcase(cls, pattern)]


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--plan-vlt-flags", action="store_true",
                    help="print space-separated Verilator flags declared by a Lua policy")
    ap.add_argument("--plugin", type=Path, required=True)
    ap.add_argument("--prefix", default="Vg6lc_testharness")
    ap.add_argument("--command", default="")
    ap.add_argument("--sources", nargs="*", default=[])
    args = ap.parse_args()
    if args.plan_vlt_flags:
        flags, _ = plan_verilator_flags(args.prefix, args.command, args.plugin, args.sources)
        print(" ".join(flags))
