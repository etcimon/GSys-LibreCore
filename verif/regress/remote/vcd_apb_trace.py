#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Stream a (possibly huge) Verilator VCD and print a compact timeline of a few signals.

    python3 vcd_apb_trace.py trace.vcd 'ai_psel$' 'ai_penable$' ... [--after T] [--before T]

Signal selectors are regexes on the full hierarchical name. Only value changes of the
selected signals are printed, one line per timestamp, so a multi-GB SoC VCD reduces to the
handful of APB / completion-FIFO lines a protocol question needs. No third-party parser.
"""
import argparse
import re
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("vcd")
    ap.add_argument("patterns", nargs="+")
    ap.add_argument("--after", type=int, default=0)
    ap.add_argument("--before", type=int, default=1 << 62)
    ap.add_argument("--only-when", default=None,
                    help="regex on a signal name; print a timestamp only if that signal changed")
    args = ap.parse_args()
    pats = [re.compile(p) for p in args.patterns]
    only = re.compile(args.only_when) if args.only_when else None
    scope = []
    codes = {}   # id code -> short name
    with open(args.vcd, "r", errors="replace") as f:
        for line in f:
            line = line.lstrip()          # Verilator indents the header by depth
            if line.startswith("$scope"):
                scope.append(line.split()[2])
            elif line.startswith("$upscope"):
                scope.pop()
            elif line.startswith("$var"):
                parts = line.split()
                code, name = parts[3], parts[4]
                full = ".".join(scope + [name])
                if any(p.search(full) for p in pats):
                    codes[code] = full
            elif line.startswith("$enddefinitions"):
                break
        if not codes:
            print("no signal matched", file=sys.stderr)
            return 1
        for c, n in sorted(codes.items(), key=lambda kv: kv[1]):
            print(f"# {n}", file=sys.stderr)
        t = 0
        pending = {}
        cur = {}

        def flush():
            if pending and args.after <= t <= args.before:
                if only is None or any(only.search(codes[c]) for c in pending):
                    cur.update(pending)
                    print(f"{t:>12} " + " ".join(f"{codes[c].rsplit('.', 1)[-1]}={v}" for c, v in
                                                 sorted(pending.items(), key=lambda kv: codes[kv[0]])))
                else:
                    cur.update(pending)
            else:
                cur.update(pending)
            pending.clear()

        for line in f:
            if not line:
                continue
            ch = line[0]
            if ch == "#":
                flush()
                t = int(line[1:])
                if t > args.before:
                    break
            elif ch in "01xz":
                code = line[1:].strip()
                if code in codes:
                    pending[code] = ch
            elif ch in "bB":
                val, code = line[1:].split()
                if code in codes:
                    try:
                        pending[code] = hex(int(val, 2))
                    except ValueError:
                        pending[code] = val
        flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
