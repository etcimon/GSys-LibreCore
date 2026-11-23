#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Paired original/packed build acceptance test for the 8-iteration MC writer ELF."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def neighbors():
    others = {}
    for p in Path("/proc").glob("[0-9]*/exe"):
        try:
            target = p.readlink()
        except OSError:
            continue
        if target.name == "Variane_testharness":
            others[p.parent.name] = str(target)
    return others


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for k in ("control", "candidate", "elf", "output"):
        parser.add_argument(k, type=Path)
    parser.add_argument("--cpus", default="2,4")
    parser.add_argument("--shared-host", action="store_true",
                        help="explicit loaded-host test; retain neighboring model PIDs in results")
    args = parser.parse_args()
    images = [p.resolve() for p in (args.control, args.candidate, args.elf)]
    ids = list(map(sha, images))
    if ids[0] not in {"5eaf04f7a70e4fe9e1dd51912112386835bf51858cc0aab0261f003e84718c0b",
                      "72ae9370aedb8c08f5fb1cdad6220f8435baaa1c067f153144410a7f82dc44f6"}:
        parser.error("unexpected MC baseline")
    if ids[2] != "3e6fc73f5a09696cd8a38d10ed76555fff55333a9ea00bc5f847a21c8b495882":
        parser.error("unexpected shared-line test ELF")
    out = args.output.resolve()
    out.mkdir()
    (out / "inputs.json").write_text(json.dumps(dict(zip(("A", "B", "elf"), ids)), indent=2))
    oracle = None
    for idx, side in enumerate("ABBAAB"):
        others = neighbors()
        if others and not args.shared_host:
            raise RuntimeError(f"MC host is busy: {others}")
        run = out / f"{idx}{side}"
        run.mkdir()
        metrics = run / "metrics.json"
        cmd = ["taskset", "-c", args.cpus, "perf", "stat", "-x,", "-o", "perf.csv",
               "-e", "instructions:u,cycles:u", "--", str(images[0] if side == "A" else images[1]),
               "+tohost_addr=0x80001000", "+debug_disable", "+quiet_axi", "+rvfi_cycle_stamp",
               "+max-cycles=12000", "+time_out=12000", str(images[2])]
        env = dict(os.environ, G6LC_METRICS_SIDECAR=str(metrics))
        with (run / "log").open("w") as stream:
            start = time.monotonic()
            subprocess.run(cmd, env=env, cwd=run, stdout=stream, stderr=subprocess.STDOUT,
                           timeout=150, check=True)
            elapsed = time.monotonic() - start
        log = (run / "log").read_text()
        traces = {p.name: sha(p) for p in run.glob("trace*.dasm") if p.stat().st_size}
        sidecar = json.loads(metrics.read_text())
        if ("*** SUCCESS *** (tohost = 0) after 4649 cycles" not in log
                or "all 4 core(s) retired instructions" not in log or len(traces) != 8
                or sidecar["cycles"] != 4649):
            raise RuntimeError(f"MC oracle failed: {run}")
        signature = (sha(metrics), traces)
        if oracle is None:
            oracle = signature
        elif signature != oracle:
            raise RuntimeError(f"retirement trace/sidecar mismatch: {run}")
        after = neighbors()
        row = {"side": side, "elapsed_s": elapsed, "sim_cycles_s": 4649 / elapsed,
               "neighbors_before": others, "neighbors_after": after, "argv": cmd,
               "sidecar": sidecar, "trace_sha256": traces}
        (run / "result.json").write_text(json.dumps(row, indent=2))
        print(idx, side, elapsed, row["sim_cycles_s"], str(run), flush=True)
        if after and not args.shared_host:
            raise RuntimeError(f"model overlap during timing: {run}")


if __name__ == "__main__":
    main()
