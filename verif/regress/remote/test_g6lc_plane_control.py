#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Exercise the observer -> controls -> compiler stats -> model oracle path."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("compiler", type=Path)
    parser.add_argument("output", type=Path, help="fresh directory; retained for A/B timing")
    args = parser.parse_args()
    w = args.output.resolve()
    w.mkdir()
    scripts = Path(__file__).resolve().parent
    model = "Vg6lc_byte_plane"
    common = [str(args.compiler.resolve()), "--cc", "--exe", "--stats", "--top-module",
              model[1:], str(scripts / "g6lc_byte_plane.sv"), str(scripts / "g6lc_byte_plane.cpp")]
    checksums = []
    for tag, flags in (("off", ["--dumpi-sentinel", "1"]), ("on", ["-f", "control.f"])):
        out = w / tag
        subprocess.run([*common, "--Mdir", str(out), *flags], cwd=w, check=True)
        stats = (out / (model + "__stats.txt")).read_text()
        hits = sum(map(int, re.findall(r"packed byte planes\s+(\d+)", stats)))
        if hits != (8 if tag == "on" else 0):
            raise RuntimeError(f"{tag}: unexpected number of applied planes: {hits}")
        if tag == "off":
            indexer = [sys.executable, str(scripts / "g6lc_sentinel_index.py")]
            for snap in sorted(out.glob("*_sentinel_dfg.json")):
                report = json.loads(subprocess.check_output([*indexer, str(snap)]))
                if report["control"]["candidate_vertices"]:
                    subprocess.run([*indexer, str(snap), "--write-controls", str(w / "control.f")],
                                   check=True, stdout=subprocess.DEVNULL)
                    break
            else:
                raise RuntimeError("no actionable projection found")
        subprocess.run(["make", "-s", "-j2", "-f", model + ".mk", "OPT_FAST=-O3"],
                       cwd=out, check=True)
        output = subprocess.check_output([str(out / model)], text=True)
        checksums.append(output.split()[-1])
        print(f"{tag}: {hits} rewrites, {output.strip()}")
    if checksums[0] != checksums[1]:
        raise RuntimeError("timed workloads produced different checksums")


if __name__ == "__main__":
    main()
