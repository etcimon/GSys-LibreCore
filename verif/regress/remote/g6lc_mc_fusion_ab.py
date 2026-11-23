#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Build both fresh fuse61 generations and qualify against the long-writer oracle."""
import argparse
from concurrent.futures import ProcessPoolExecutor
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess

from g6lc_mc_long_writer import PINS, guest_coverage, trial
from g6lc_mc_pack_ab import sha
from g6lc_pack_columns import lower_columns
from g6lc_pack_generated_rows import lower


def prepare_cpp(args):
    src, dst, header = args
    before = src.read_text()
    if "u_recover__DOT__" in before:
        packed, rows = lower(before, header.read_text())
        cpp, cols = lower_columns(packed, header.read_text())
        if rows or cols:
            dst.write_text(cpp)
            return src.name, [rows, cols]
    dst.symlink_to(src)
    return None


def prepare(source, dest, rtl, jobs):
    dest.mkdir()
    header = source/"Vg6lc_testharness_g6lc_core__pi37.h"
    work = []
    for f in source.iterdir():
        if f.suffix not in (".cpp", ".h", ".mk", ".vlt"): continue
        if f.name.startswith(header.stem + "__") and f.suffix == ".cpp":
            work.append((f, dest/f.name, header))
        else:
            (dest/f.name).symlink_to(f)
    for name in ("corev_apu", "verif"):
        (dest/name).symlink_to(rtl/name, target_is_directory=True)
    shutil.copyfile(Path(__file__).with_name("g6lc_column_tile.h"), dest/"g6lc_column_tile.h")
    with ProcessPoolExecutor(max_workers=jobs) as pool:
        hits = dict(hit for hit in pool.map(prepare_cpp, sorted(work), chunksize=4) if hit)
    counts = list(map(sum, zip(*hits.values())))
    if len(counts) != 2 or not all(counts):
        raise ValueError(f"missing generated lowerings in {dest}: {counts}")
    (dest/"lowerings.json").write_text(json.dumps(hits, indent=2))
    print(dest.name, "lowered rows/columns", counts, flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ("elaborations", "rtl", "runtime", "guest", "reference", "output"):
        ap.add_argument(name, type=Path)
    ap.add_argument("-j", type=int, default=6)
    a = ap.parse_args()
    base, rtl, runtime, guest, ref, out = (p.resolve() for p in
        (a.elaborations, a.rtl, a.runtime, a.guest, a.reference, a.output))
    if not 1 <= a.j <= 12 or sha(guest) != PINS["guest"]:
        ap.error("unexpected guest or job count")
    archived = json.loads((ref/"result.json").read_text())
    traces = {p.name: sha(p) for p in ref.glob("trace*.dasm")}
    metrics = sha(ref/"metrics.json")
    if (traces != archived["trace_sha256"] or len(traces) != 8 or
            metrics != archived["sidecar_sha256"] or archived["cycles"] != 13431):
        ap.error("archived oracle does not match its manifest")
    guest_coverage(ref)
    out.mkdir()
    env = dict(os.environ, LC_ALL="C", CCACHE_DIR=str(out/"ccache"), CCACHE_MAXSIZE="3G")
    builds = {}
    for side, folder in (("A", "full-ctl"), ("B", "full-final")):
        src = base/folder
        stats = (src/"Vg6lc_testharness__stats.txt").read_text()
        matches = re.findall(r"DFG\s+pre inline fused transposes\s+(\d+)", stats)
        if matches != ([] if side == "A" else ["1"]):
            raise ValueError(f"unexpected {side} elaboration stats: {matches}")
        dest = out/side
        prepare(src, dest, rtl, a.j)
        cmd = ["make", "-f", "Vg6lc_testharness.mk", f"-j{a.j}", "OBJCACHE=ccache",
               "CXX=/usr/bin/g++-13", "CC=/usr/bin/gcc-13", "LINK=/usr/bin/g++-13",
               f"VERILATOR_ROOT={runtime}", "OPT_FAST=-O2", "OPT_SLOW=-O1", "OPT_GLOBAL=-O2"]
        with (dest/"build.log").open("w") as log:
            subprocess.run(cmd, cwd=dest, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        builds[side] = sha(dest/"Variane_testharness")
        print(side, "built", builds[side], flush=True)
    (out/"inputs.json").write_text(json.dumps(dict(builds=builds, guest=sha(guest),
        reference=str(ref), runtime=str(runtime), metrics=metrics, traces=traces), indent=2))
    rows = []
    for i, side in enumerate("ABBAAB"):
        d = out/f"{i}{side}"
        row = trial(d, out/side/"Variane_testharness", guest, env)
        if row["cycles"] != 13431 or row["sidecar_sha256"] != metrics or row["trace_sha256"] != traces:
            raise ValueError(f"{d}: archived MC oracle mismatch, discard timings")
        row.update(side=side, index=i)
        (d/"qualified.json").write_text(json.dumps(row, indent=2))
        rows.append(row)
        print(i, side, row["sim_cycles_s"], row["counters"], flush=True)
    pairs = [{r["side"]: r["sim_cycles_s"] for r in rows[i:i+2]} for i in (0, 2, 4)]
    ratios = [p["B"]/p["A"] for p in pairs]
    (out/"qualified.json").write_text(json.dumps(dict(rows=rows, ratios=ratios,
        median_ratio=statistics.median(ratios)), indent=2))


if __name__ == "__main__":
    main()
