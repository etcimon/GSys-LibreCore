#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Time three pinned Hyp8 executables on the same 64-iteration, four-writer guest."""
import argparse
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import time

from g6lc_mc_pack_ab import neighbors, sha


PINS = {"original": "5eaf04f7a70e4fe9e1dd51912112386835bf51858cc0aab0261f003e84718c0b",
        "tiled": "0a717957fba55e06a85cc8b6c51bec32f213023ffeb6817e05f61af311b7a727",
        "guarded": "7933a3a0c1ae23ea2a89d26c8f86654ed496a23ee82beffc7167fde95e9706ac",
        "guest": "304cf7492012b79e07ce3bf1a39874854ba57c3d2f16397b909f7871bd0a8a1a"}
ORDER = ["tiled", "guarded", "original", "guarded", "original", "tiled",
         "original", "tiled", "guarded"]


def guest_coverage(out):
    """Confirm both loop bodies really retired 64 times per writer on this pinned ELF."""
    result = {}
    for hart in (0, 2, 4, 6):
        text = (out/f"trace_rvfi_hart_{hart:02}.dasm").read_text()
        retired = [(int(pc, 16), int(insn, 16)) for pc, insn in re.findall(
            rf"^core\s+{hart}: 0x([0-9a-f]+) \(0x([0-9a-f]+)\).*? @\d+$", text, re.M)]
        slots = retired.count((0x80000140, 0x0064b023))
        amos = retired.count((0x800001e4, 0x0069b02f))
        if (slots, amos) != (64, 64):
            raise ValueError(f"guest loop coverage mismatch on hart {hart}: {slots}, {amos}")
        result[hart] = dict(retired=len(retired), slot_stores=slots, shared_amos=amos)
    return result


def trial(out, model, guest, env):
    out.mkdir()
    cmd = ["taskset", "-c", "2,4", "perf", "stat", "-x,", "-o", "perf.csv",
           "-e", "instructions:u,cycles:u", "--", str(model), "+tohost_addr=0x80001000",
           "+debug_disable", "+quiet_axi", "+rvfi_cycle_stamp", "+max-cycles=80000",
           "+time_out=80000", str(guest)]
    before = neighbors()
    with (out / "log").open("w") as log:
        start = time.monotonic()
        subprocess.run(cmd, cwd=out, env=dict(env, G6LC_METRICS_SIDECAR=str(out/"metrics.json")),
                       stdout=log, stderr=subprocess.STDOUT, timeout=1800, check=True)
        elapsed = time.monotonic() - start
    after = neighbors()
    log = (out/"log").read_text()
    success = re.findall(r"\*\*\* SUCCESS \*\*\* \(tohost = 0\) after (\d+) cycles", log)
    metrics = json.loads((out/"metrics.json").read_text())
    cycles = metrics["cycles"]
    if (success != [str(cycles)] or not 4649 < cycles < 80000 or
            "all 4 core(s) retired instructions" not in log or any(metrics["dropped"])):
        raise ValueError(f"invalid MC completion in {out}")
    traces = {p.name: sha(p) for p in out.glob("trace*.dasm") if p.stat().st_size}
    if set(traces) != {name for h in (0, 2, 4, 6)
                       for name in (f"trace_hart_{h}.dasm", f"trace_rvfi_hart_{h:02}.dasm")}:
        raise ValueError(f"invalid retirement artifacts in {out}")
    counters = {}
    for line in (out/"perf.csv").read_text().splitlines():
        cols = line.split(",")
        if len(cols) >= 5 and cols[2] in ("instructions:u", "cycles:u"):
            if float(cols[4]) < 99:
                raise ValueError("counter multiplexing below 99%")
            counters[cols[2]] = int(cols[0])
    if len(counters) != 2 or min(counters.values()) <= 0:
        raise ValueError("missing performance counters")
    return dict(cycles=cycles, elapsed_s=elapsed, sim_cycles_s=cycles/elapsed,
                counters=counters, neighbors_before=before, neighbors_after=after,
                sidecar_sha256=sha(out/"metrics.json"), trace_sha256=traces)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in (*PINS, "output"):
        ap.add_argument(name, type=Path)
    a = ap.parse_args()
    paths = {k: getattr(a, k).resolve() for k in PINS}
    if {k: sha(p) for k, p in paths.items()} != PINS:
        ap.error("input SHA-256 differs from the reviewed benchmark")
    out = a.output.resolve()
    out.mkdir()
    (out/"inputs.json").write_text(json.dumps(dict(pins=PINS, order=ORDER, cpus=[2, 4]), indent=2))
    rows, oracle = [], None
    for i, side in enumerate(ORDER):
        d = out/f"{i}-{side}"
        row = trial(d, paths[side], paths["guest"], dict(os.environ, LC_ALL="C"))
        sig = row["sidecar_sha256"], row["trace_sha256"]
        if oracle is None:
            (out/"guest-coverage.json").write_text(json.dumps(guest_coverage(d), indent=2))
        if oracle is not None and oracle != sig:
            raise ValueError(f"oracle mismatch in {d}; do not use timings")
        oracle = sig
        row.update(side=side, index=i)
        (d/"result.json").write_text(json.dumps(row, indent=2))
        rows.append(row)
        print(i, side, row["cycles"], round(row["sim_cycles_s"], 2), row["counters"],
              "other models", len(row["neighbors_before"]), len(row["neighbors_after"]), flush=True)
    blocks = [{r["side"]: r for r in rows[i:i+3]} for i in (0, 3, 6)]
    ratios = {f"{b}/{a}": [block[b]["sim_cycles_s"]/block[a]["sim_cycles_s"] for block in blocks]
              for a, b in (("original", "tiled"), ("tiled", "guarded"), ("original", "guarded"))}
    (out/"summary.json").write_text(json.dumps(dict(rows=rows, ratios=ratios,
        median_block_ratios={k: statistics.median(v) for k, v in ratios.items()}), indent=2))


if __name__ == "__main__":
    main()
