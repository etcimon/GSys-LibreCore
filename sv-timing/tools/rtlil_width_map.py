#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""Elaborated net widths from a Yosys RTLIL dump -> sv-timing `--width-map` JSON.

Width inference in `sv-timing-core::width` resolves what the source text can
prove: declarations, typedefs, parameters evaluated with the expression
parser, package constants and the host param-map. It cannot evaluate a
constant *function* (`localparam Slots = geo_pkg::geo(Cfg).slots`, a float
unit's `exp_bits(Format)`), so those widths stay at the reference width.
An elaborator can. This tool reads the RTLIL a `write_rtlil` dump produces
after `read_slang … ; hierarchy -top …` (the streamed `sta-rtl` recipe writes
exactly that as `wordlevel.il`) and emits:

    {"schema": "sv-timing-width-map.v1", "source": "...", "modules":
      {"instr_queue": {"slot_fifo": 8, "idx_is_q": 2, ...}, ...}}

RTLIL module names carry the slang specialization (`\\instr_queue$cva6.i_…`);
the map is keyed by the base module name and, when several specializations
disagree, keeps the **widest** net (the conservative direction: wider costs
more). Names are the RTLIL identifiers without the leading backslash; wires
whose name starts with `$` (internal) are skipped. Unpacked arrays are not
represented (yosys-slang lowers them to memories or flattened wires); the
consumer only uses a map entry for a signal its declaration shows as packed.

`--split-dir DIR` additionally writes every module of the dump as its own
RTLIL file `DIR/NNNN_<sanitized name>.il` (with the `autoidx` header), the
input of the streamed mapping's parallel phase B: one yosys process per
module, so the gate-level core never exists in one process and a slow ABC run
on one module neither blocks nor OOMs the rest. `DIR/modules.tsv` lists
`index<TAB>file<TAB>module` in dump order.

Usage: rtlil_width_map.py wordlevel.il [-o width-map.json] [--split-dir DIR]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

MODULE_RE = re.compile(r"^module\s+(\S+)\s*$")
WIRE_RE = re.compile(r"^\s+wire\s+(.*?)\\(\S+)\s*$")
WIDTH_RE = re.compile(r"\bwidth\s+(\d+)\b")


def base_module_name(rtlil_name: str) -> str:
    name = rtlil_name[1:] if rtlil_name.startswith("\\") else rtlil_name
    return name.split("$", 1)[0]


def parse_rtlil(lines) -> dict[str, dict[str, int]]:
    modules: dict[str, dict[str, int]] = {}
    current: dict[str, int] | None = None
    for raw in lines:
        line = raw.rstrip("\n")
        if line.startswith("module "):
            m = MODULE_RE.match(line)
            if not m:
                current = None
                continue
            base = base_module_name(m.group(1))
            current = modules.setdefault(base, {})
            continue
        if line == "end":
            current = None
            continue
        if current is None or not line.startswith("  wire"):
            continue
        m = WIRE_RE.match(line)
        if not m:
            continue
        attrs, name = m.group(1), m.group(2)
        if name.startswith("$"):
            continue
        w = WIDTH_RE.search(attrs)
        width = int(w.group(1)) if w else 1
        prev = current.get(name)
        if prev is None or width > prev:
            current[name] = width
    return modules


def sanitize_file_stem(rtlil_name: str, limit: int = 96) -> str:
    name = rtlil_name[1:] if rtlil_name.startswith("\\") else rtlil_name
    return re.sub(r"[^A-Za-z0-9_.-]", "_", name)[:limit]


def split_rtlil(lines, out_dir: Path) -> list[tuple[int, Path, str]]:
    """Write one file per `module … end` block (header lines such as
    `autoidx` are replicated into every file; attributes directly before a
    `module` line travel with it). Returns `(index, path, module name)`."""
    out_dir.mkdir(parents=True, exist_ok=True)
    header: list[str] = []
    pending_attrs: list[str] = []
    current: list[str] | None = None
    current_name = ""
    written: list[tuple[int, Path, str]] = []
    idx = 0

    def flush() -> None:
        nonlocal current, current_name, idx
        if current is None:
            return
        idx += 1
        path = out_dir / f"{idx:04d}_{sanitize_file_stem(current_name)}.il"
        with path.open("w", encoding="utf-8") as fh:
            fh.writelines(header)
            fh.writelines(current)
        written.append((idx, path, current_name))
        current = None
        current_name = ""

    for raw in lines:
        if current is None:
            if raw.startswith("module "):
                m = MODULE_RE.match(raw.rstrip("\n"))
                current_name = m.group(1) if m else raw.split()[1]
                current = pending_attrs + [raw]
                pending_attrs = []
            elif raw.startswith("attribute "):
                pending_attrs.append(raw)
            elif raw.strip() == "":
                pending_attrs = []
            else:
                header.extend(pending_attrs)
                pending_attrs = []
                header.append(raw)
            continue
        current.append(raw)
        if raw.rstrip("\n") == "end":
            flush()
    flush()
    with (out_dir / "modules.tsv").open("w", encoding="utf-8") as fh:
        for i, p, n in written:
            fh.write(f"{i}\t{p.name}\t{n}\n")
    return written


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("rtlil", type=Path, help="RTLIL dump (`write_rtlil`)")
    ap.add_argument("-o", "--out", type=Path, default=None, help="output JSON (default stdout)")
    ap.add_argument("--split-dir", type=Path, default=None, help="also write one RTLIL file per module here")
    args = ap.parse_args(argv)
    if args.split_dir is not None:
        with args.rtlil.open("r", encoding="utf-8", errors="replace") as fh:
            written = split_rtlil(fh, args.split_dir)
        sys.stderr.write(f"split {len(written)} modules into {args.split_dir}\n")
    with args.rtlil.open("r", encoding="utf-8", errors="replace") as fh:
        modules = parse_rtlil(fh)
    doc = {
        "schema": "sv-timing-width-map.v1",
        "source": str(args.rtlil),
        "module_count": len(modules),
        "net_count": sum(len(v) for v in modules.values()),
        "modules": modules,
    }
    text = json.dumps(doc, indent=1, sort_keys=True)
    if args.out:
        args.out.write_text(text + "\n", encoding="utf-8")
    else:
        sys.stdout.write(text + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
