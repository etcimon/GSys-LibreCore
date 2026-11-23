#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Smoke test a scratch verilator_bin; never builds or executes a full MC model."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from g6lc_sentinel_dataflow import dataflow_index
from g6lc_sentinel_index import schedule_input


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("compiler", type=Path)
    compiler = ap.parse_args().compiler.resolve()
    fixture = Path(__file__).with_name("g6lc_sentinel_fixture.sv").resolve()
    with tempfile.TemporaryDirectory() as scratch:
        for threads in (1, 2):
            generated = []
            for enabled in (False, True):
                out = Path(scratch) / f"t{threads}-{int(enabled)}"
                subprocess.run([str(compiler), "--cc", "--threads", str(threads), "--Mdir",
                                str(out), *(["--dumpi-sentinel", "1"] if enabled else []),
                                str(fixture)], check=True)
                generated.append({p.name: p.read_bytes() for p in out.iterdir()
                                  if p.suffix in (".cpp", ".h")})
                dumps = list(out.glob("*_sentinel_*.json"))
                if not enabled:
                    assert not dumps
                    continue
                schedules, regions = [], []
                for p in dumps:
                    raw = json.loads(p.read_text())
                    if raw["schema"] == "v3-sentinel-1":
                        schedules.append(schedule_input(raw))
                    else:
                        regions.extend(dataflow_index(raw)["regions"])
                assert bool(schedules) == (threads > 1)
                assert any(r.get("bit_indices") == list(range(7, 64, 8)) and
                           "one_word_pext" in r["probe_candidates"] for r in regions)
                assert any(r["operation"] == "masked_reduction" for r in regions)
            assert generated[0] and generated[0] == generated[1], "observer changed model"
            print(f"threads={threads}: DFG idioms verified; generated C++/headers identical")


if __name__ == "__main__":
    main()
