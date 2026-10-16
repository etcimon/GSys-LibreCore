#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""Per-module area / depth delta between two streamed `sta-rtl` runs.

Each streamed run leaves `maplog/<idx>_<stem>.log` (yosys `stat -liberty`, one
`Chip area for module '<name>': <um2>` line per module) and, after
`openroad-module-board.tcl`, `module-board.tsv` (worst register-to-register
path per module in ns and cells, broadcast drivers excluded). This script joins
the two runs on the module name and prints, per module:

    module  area_a  area_b  d_area%  cells_a  cells_b  ns_a  ns_b

sorted by the largest area increase first (the performance/area question of
ALGORITHMS-EXPERTS A102: which rewrites paid area for depth, and whether the
depth they bought is on the board). Totals close the table. A study over a
mapped-but-unplaced netlist: no wires, no buffering; area is standard-cell
area from the liberty.

    sta_module_delta.py <run_a> <run_b> [--top N] [--min-area UM2]
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

AREA_RE = re.compile(r"Chip area for module '\\?([^']+)':\s+([0-9.]+)")


def areas(run: Path) -> dict[str, float]:
    out: dict[str, float] = {}
    for log in sorted((run / "maplog").glob("*.log")):
        text = log.read_text(encoding="utf-8", errors="replace")
        # the last `stat` of the log is the mapped one
        for m in AREA_RE.finditer(text):
            out[m.group(1)] = float(m.group(2))
    return out


def board(run: Path) -> dict[str, tuple[float | None, int | None]]:
    out: dict[str, tuple[float | None, int | None]] = {}
    tsv = run / "module-board.tsv"
    if not tsv.exists():
        return out
    for line in tsv.read_text(encoding="utf-8", errors="replace").splitlines()[1:]:
        f = line.split("\t")
        if len(f) < 5:
            continue
        name = f[0]
        ns = float(f[3]) if f[3] not in ("-", "") else None
        cells = int(f[4]) if f[4] not in ("-", "") else None
        out[name] = (ns, cells)
    return out


def base_name(name: str) -> str:
    """`frontend$cva6.i_frontend` -> `frontend$cva6.i_frontend` (the instance
    path makes the name unique across parameterisations; keep it)."""
    return name


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("run_a", type=Path, help="baseline run dir (live RTL)")
    ap.add_argument("run_b", type=Path, help="compared run dir (emitted RTL)")
    ap.add_argument("--top", type=int, default=25, help="rows to print (default 25)")
    ap.add_argument("--min-area", type=float, default=200.0, help="skip modules below this area in both runs")
    args = ap.parse_args(argv)
    a_area, b_area = areas(args.run_a), areas(args.run_b)
    a_board, b_board = board(args.run_a), board(args.run_b)
    rows = []
    for name in sorted(set(a_area) | set(b_area)):
        aa, bb = a_area.get(name), b_area.get(name)
        if aa is None or bb is None:
            continue
        if max(aa, bb) < args.min_area:
            continue
        d = (bb - aa) / aa * 100.0 if aa > 0 else 0.0
        na, ca = a_board.get(name, (None, None))
        nb, cb = b_board.get(name, (None, None))
        rows.append((name, aa, bb, d, ca, cb, na, nb))
    rows.sort(key=lambda r: -r[3])
    print("module\tarea_a_um2\tarea_b_um2\td_area_pct\tcells_a\tcells_b\tns_a\tns_b")
    for r in rows[: args.top]:
        name, aa, bb, d, ca, cb, na, nb = r
        print(
            f"{name}\t{aa:.0f}\t{bb:.0f}\t{d:+.1f}\t{ca if ca is not None else '-'}\t{cb if cb is not None else '-'}"
            f"\t{na if na is not None else '-'}\t{nb if nb is not None else '-'}"
        )
    ta, tb = sum(r[1] for r in rows), sum(r[2] for r in rows)
    print(f"TOTAL\t{ta:.0f}\t{tb:.0f}\t{(tb - ta) / ta * 100.0 if ta else 0.0:+.2f}\t-\t-\t-\t-")
    inc = [r for r in rows if r[3] > 0.5]
    dec = [r for r in rows if r[3] < -0.5]
    print(f"SUMMARY modules={len(rows)} area_up={len(inc)} area_down={len(dec)} total_delta_um2={tb - ta:+.0f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
