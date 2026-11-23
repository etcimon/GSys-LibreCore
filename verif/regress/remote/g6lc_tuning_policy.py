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


PASSES = ("packed-rows", "packed-mux-rows", "tiled-columns",
          "wrapped-columns", "packed-predicates")
DEFAULT_PASSES = ("packed-rows", "tiled-columns")
VLT_FLAGS = (
    "-fclock-skip-sink",
    "-fclock-skip",
    "-fdfg-peephole-pack-byte-plane",
    "-fdfg-peephole-pack-predicates",
    "-fdfg-peephole-pack-bitwise-mux",
    "-fdfg-peephole-guard-empty-mask",
    "-fdfg-peephole-fuse-transpose-reductions",
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


def _run_lua(prefix, command, plugin, rtl_sources=(), phase="overlay"):
    lua = lua_binary()
    if not lua:
        raise ValueError("explicit tuning plugin needs Lua 5.3 or 5.4 on the build host")
    runner = Path(__file__).with_name("g6lc_tuning_driver.lua")
    source = Path(plugin).read_bytes()
    # Keep even a large RTL file list out of argv. A blank line ends the list.
    payload = b"".join(n.encode() + b"\n" for n in rtl_sources) + b"\n" + source
    proc = subprocess.run([lua, "-E", str(runner), prefix, command, phase], input=payload,
                          capture_output=True, timeout=10)
    if proc.returncode:
        raise ValueError(f"Lua policy {Path(plugin).name}: {proc.stderr.decode(errors='replace').strip()}")
    version, *lines = proc.stdout.decode("ascii").splitlines()
    rules, vlt_flags, clock_skip = [], [], []
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
        else:
            if len(parts) != 3 or parts[2] not in PASSES:
                raise ValueError(f"empty or unsupported rule in Lua policy {Path(plugin).name}")
            rules.append(parts)
    if not rules and not vlt_flags and not clock_skip:
        raise ValueError(f"empty or unsupported rule in Lua policy {Path(plugin).name}")
    meta = dict(profile="lua", plugin=Path(plugin).name,
                pluginSha256=hashlib.sha256(source).hexdigest(), runtime=version)
    if vlt_flags:
        meta["vltFlags"] = vlt_flags
    if clock_skip:
        meta["clockSkip"] = clock_skip
    return rules, meta


def select_policy(prefix, command, plugin, rtl_sources=()):
    if plugin is None:
        if ("-DG6LC_HYP8_MC" not in command.split() or
                re.findall(r"(?:^| )--threads (\d+)(?= |$)", command) != ["2"]):
            raise ValueError("generated model is not the requested two-lane Hyp8 MC schedule")
        rules = [[prefix + "_g6lc_core" + suffix, "u_recover__DOT__", op]
                 for suffix in ("", "__pi[0-9]*") for op in DEFAULT_PASSES]
        return rules, {"profile": "packed-tiled"}
    return _run_lua(prefix, command, plugin, rtl_sources, phase="overlay")


def plan_verilator_flags(prefix, command, plugin, rtl_sources=()):
    """Pre-verilate policy query returning allowlisted Verilator optimization flags."""
    _, meta = _run_lua(prefix, command, plugin, rtl_sources, phase="vlt-flags")
    return meta.get("vltFlags", []), meta


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
