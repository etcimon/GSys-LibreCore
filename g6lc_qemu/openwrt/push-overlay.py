#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""Rsync this overlay dir to ovh_calltorch via testharness_proxy SSH (key unlock)."""
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
# testharness_proxy.py lives in the LibreCore tree: <root>/verif/regress/remote/
root = HERE
th_path = None
while root != root.parent:
    cand = root / "verif" / "regress" / "remote" / "testharness_proxy.py"
    if cand.is_file():
        th_path = cand
        break
    root = root.parent
if th_path is None:
    sys.exit("testharness_proxy.py not found walking up from " + str(HERE))

spec = importlib.util.spec_from_file_location("th_proxy", th_path)
mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(mod)

rem = mod.Remote(mod.HOST)
rem.timeout = 90.0
try:
    rem.start_master()
    rem.run("mkdir -p /opt/testharness/cache/openwrt-overlay")
    rem.rsync(
        f"{HERE}/",
        f"{rem.host}:/opt/testharness/cache/openwrt-overlay/",
        extra=[
            "--exclude", "remote-kconfig-fail.txt",
            "--exclude", "__pycache__",
        ],
    )
    print(rem.out("ls -l /opt/testharness/cache/openwrt-overlay"))
    print("PUSH_OVERLAY_OK")
finally:
    rem.close()
