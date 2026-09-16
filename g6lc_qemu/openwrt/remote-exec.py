#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""Run one remote command through the existing testharness SSH transport."""
from __future__ import annotations

import argparse
import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load_proxy():
    root = HERE
    while root != root.parent:
        cand = root / "verif" / "regress" / "remote" / "testharness_proxy.py"
        if cand.is_file():
            spec = importlib.util.spec_from_file_location("th_proxy", cand)
            mod = importlib.util.module_from_spec(spec)
            assert spec.loader is not None
            spec.loader.exec_module(mod)
            return mod
        root = root.parent
    sys.exit("testharness_proxy.py not found walking up from " + str(HERE))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--host", default=None)
    ap.add_argument("--timeout", type=float, default=300.0)
    ap.add_argument("command", nargs=argparse.REMAINDER)
    args = ap.parse_args()
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    if not args.command:
        ap.error("missing remote command")

    mod = load_proxy()
    rem = mod.Remote(args.host or mod.HOST)
    rem.timeout = args.timeout
    try:
        rem.start_master()
        res = rem.run(" ".join(args.command), check=False, capture=True)
        sys.stdout.write(res.stdout or "")
        sys.stderr.write(res.stderr or "")
        return int(res.returncode)
    finally:
        rem.close()


if __name__ == "__main__":
    raise SystemExit(main())
