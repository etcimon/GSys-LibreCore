#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Per-submodule synthesis smoke for the uncore cluster, run in PARALLEL.
#
# Why this exists. The whole-cluster target (`g6lc_cluster_lint_top` on
# g6lc64_ooo_server) does not finish: cut at 900s, exit 137 at ~994s, exit 255 at
# 2412s. It is slow rather than broken, but "slow past every budget we are willing
# to spend" is indistinguishable from "no synthesis evidence" — and that is the
# state the uncore has actually been in.
#
# Two observations make this cheap:
#   * `hierarchy -top X` prunes the design to X's subtree, so synthesising each
#     major submodule separately is a small fraction of the flattened whole;
#   * yosys is single-threaded, so the ONLY way to use more than one of the
#     builder's 12 cores is to run several yosys processes at once. One cluster
#     target can never saturate the box; twelve submodule tops can.
#
# The parse cost is paid per invocation (each reads the full flist), so wall time
# is roughly one parse plus the largest submodule rather than the sum of all of
# them.
#
# This is a SMOKE, and the limits are worth stating plainly: it proves each
# submodule elaborates and synthesises to generic gates with no inferred latches.
# It does NOT prove the assembled cluster does, because cross-module elaboration
# is exactly what it skips — so it is a complement to the whole-cluster run, not a
# replacement for it. Area and timing numbers here mean nothing until the tag
# arrays move behind tc_sram (~3.4 Mbit of flops today).
#
# A second limit, learned the hard way here: a module whose ports are typed via
# `parameter type axi_req_t = logic` cannot be synthesised as top with the default
# parameter — member access on `logic` is invalid. Worse, if its generate branches
# collapse to a degenerate path instead of erroring, it "passes" having emitted
# ZERO cells. So `cells > 0` is part of the pass criterion, and such modules are
# reported as failures until they get a typed wrapper (the same device as
# `g6lc_cluster_lint_top`) rather than quietly counted as successes.

import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

#  Major uncore tops. Each must be a real module name in the cluster flist.
#  Typed wrappers where the bare module cannot be a synthesis top (see
#  verif/tb/g6lc_uncore_lint_tops.sv); bare names where it can.
TOPS = [
    "g6lc_coherence_hub_lint_top",
    "g6lc_inval_bus_lint_top",
    "g6lc_snoop_filter_lint_top",
    "g6lc_axi_2to1_mux_lint_top",
    "g6lc_l2_top_lint_top",
    "g6lc_l3_top_lint_top",
    "g6lc_server_prefetcher_lint_top",
    "g6lc_lr_sc_tracker",
    "g6lc_l1_inv_adapter",
    "g6lc_inval_retain",
]

#  BOTH manifests, in this order. corev_apu/Flist.cluster is an ADDITION to the
#  core one and says so in its own header ("it does not repeat what that manifest
#  already provides") -- it carries no config package, so feeding it alone fails
#  with "unknown class or package 'cva6_config_pkg'", which reads like a missing
#  dependency rather than a missing manifest.
FLISTS = ["core/Flist.cva6", "corev_apu/Flist.cluster"]
TARGET = os.environ.get("REVIEW_SYNTH_TARGET", "g6lc64_ooo_server")
#  Same value the Makefile and the verification gate use.
HPDCACHE_SUBPATH = "core/cache_subsystem/hpdcache"


def main():
    repo = Path(os.environ.get("TH_REPO_DIR", Path.cwd())).resolve()
    out = Path(os.environ.get("TH_OUT_DIR", "/tmp/cluster-synth-review")).resolve()
    out.mkdir(parents=True, exist_ok=True)

    ys = os.environ.get("YOSYS", "/opt/testharness/toolchains/formal/bin/yosys")
    if not Path(ys).is_file():
        ys = "yosys"

    HPDCACHE = (repo / HPDCACHE_SUBPATH).as_posix()

    srcs = [repo / f for f in FLISTS]
    for s in srcs:
        if not s.is_file():
            raise SystemExit(f"missing {s}")

    #  Build a genuinely FLAT manifest: expand the three variables AND inline
    #  nested `-F`/`-f` includes recursively. Expanding only the top-level files is
    #  not enough, because core/Flist.cva6 pulls the vendored cache in through
    #  `-F ${HPDCACHE_DIR}/rtl/hpdcache.Flist`, and THAT file uses the same variable
    #  again. slang expands nothing itself, so the symptom was a second round of
    #  "'/rtl/src/hpdcache_pkg.sv': No such file" -- the empty prefix being the tell,
    #  one level deeper than the first time.
    def expand(text: str) -> str:
        return (text.replace("${CVA6_REPO_DIR}", str(repo))
                    .replace("${TARGET_CFG}", TARGET)
                    .replace("${HPDCACHE_DIR}", HPDCACHE))

    def flatten(path: Path, seen: set) -> list:
        key = str(path.resolve())
        if key in seen:          # a repeated include is not an error, just skip it
            return []
        seen.add(key)
        acc = []
        for raw in expand(path.read_text(encoding="utf-8")).splitlines():
            line = raw.strip()
            m = re.match(r"^-[Ff]\s+(\S+)$", line)
            if m:
                nested = Path(m.group(1))
                if not nested.is_absolute():
                    nested = path.parent / nested
                if not nested.is_file():
                    raise SystemExit(f"nested manifest not found: {nested} (from {path})")
                acc.extend(flatten(nested, seen))
            else:
                acc.append(raw)
        return acc

    flat = out / f"{TARGET}.f"
    body: list = []
    seen: set = set()
    for s in srcs:
        body.extend(flatten(s, seen))
    flat.write_text("\n".join(body) + "\n", encoding="utf-8")
    flist = flat

    jobs = min(len(TOPS), os.cpu_count() or 4)
    print(f"CLUSTER_SYNTH_PARALLEL jobs={jobs} tops={len(TOPS)} target={TARGET}")

    def run_top(top):
        log = out / f"{top}.log"
        script = "; ".join([
            #  Unquoted, as in the gate's remote route: slang does not strip quotes
            #  from a command-file argument.
            f"read_slang -f {flist} --top {top} --single-unit -DTARGET_CFG={TARGET}",
            f"hierarchy -check -top {top}",
            "proc",
            "opt -fast",
            #  Flatten before counting. `stat` reports a module's LOCAL cells, so a
            #  thin typed wrapper reports 0 while all its logic sits inside the
            #  instance -- which, with the cells>0 rule, turned four genuine passes
            #  into reported failures. That is the mirror image of the earlier
            #  vacuous pass: same metric, wrong in the other direction. The tell was
            #  the resource measurement (hub: 213 MB / 0.98 s, snoop filter
            #  171 MB / 0.68 s) against 64 MB / 0.12 s for a run that really did
            #  nothing. These modules are small, so flattening costs ~1 s.
            "flatten",
            "opt -fast",
            "check -assert",
            "stat",
        ])
        cmd = ["/usr/bin/time", "-f", "MEASURE maxrss_kb=%M elapsed_s=%e",
               "-o", str(out / f"{top}.measure"), ys, "-p", script]
        if not Path("/usr/bin/time").is_file():
            cmd = [ys, "-p", script]
        with log.open("w") as fh:
            rc = subprocess.run(cmd, stdout=fh, stderr=subprocess.STDOUT,
                                cwd=repo, timeout=3600).returncode
        text = log.read_text(errors="replace")
        measure = ""
        mf = out / f"{top}.measure"
        if mf.is_file():
            measure = mf.read_text(errors="replace").strip().replace("\n", " ")
        #  A latch here is a real finding: the uncore is meant to be flop-based, and
        #  an inferred latch is the classic way a "clean" smoke hides a design bug.
        latches = len(re.findall(r"\$_DLATCH|\\\$_DLATCH", text))
        cells = 0
        m = re.search(r"^\s+(\d+) cells\b", text, re.M)
        if m:
            cells = int(m.group(1))
        return {
            "top": top, "rc": rc, "cells": cells, "latches": latches,
            "measure": measure,
            "errors": len(re.findall(r"^ERROR|%Error", text, re.M)),
            #  cells > 0 is part of the pass, not decoration. Several tops exited 0
            #  having produced ZERO cells: with `parameter type axi_req_t = logic`
            #  defaults their generate branches collapse to the degenerate path, so
            #  "rc=0, no latches" was reporting success for a module that had not
            #  been synthesised at all. That is the vacuous pass this whole review
            #  keeps running into, reproduced in my own runner.
            "ok": rc == 0 and latches == 0 and cells > 0,
        }

    with ThreadPoolExecutor(max_workers=jobs) as pool:
        results = list(pool.map(run_top, TOPS))

    (out / "results.json").write_text(json.dumps(results, indent=2))
    for r in results:
        print(f"RESULT {r['top']} rc={r['rc']} cells={r['cells']} "
              f"latches={r['latches']} errors={r['errors']} {r['measure']}")

    bad = [r for r in results if not r["ok"]]
    print(f"CLUSTER SYNTH REVIEW ok={len(results) - len(bad)}/{len(results)}")
    if bad:
        print("FAILING: " + ", ".join(f"{r['top']}(rc={r['rc']},latches={r['latches']})"
                                      for r in bad))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
