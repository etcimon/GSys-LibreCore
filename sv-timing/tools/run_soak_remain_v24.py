#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Launch full_corev_apu soak into a fresh audit-remain-v36 dir."""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
PKG = TOOLS.parent
OUT = Path(r"E:\cva6\build-platform\workspace\build\sv-timing\audit-remain-v36")
LOG = Path(r"E:\cva6\build-platform\workspace\build\sv-timing\soak_remain_v36.log")

cargo_bin = Path.home() / ".cargo" / "bin"
env = os.environ.copy()
env["PATH"] = str(cargo_bin) + os.pathsep + env.get("PATH", "")
env["PYTHONUNBUFFERED"] = "1"

OUT.mkdir(parents=True, exist_ok=True)
cmd = [
    sys.executable,
    str(TOOLS / "monorepo_soak.py"),
    "--profile",
    "full_corev_apu",
    "--target-mhz",
    "4000",
    "--correct",
    "--emit",
    "--real-cut-feeds",
    "--allow-latency",
    "--opt-level",
    "3",
    "--opt-max-stages-per-region",
    "20",
    "--out-dir",
    str(OUT),
]
with LOG.open("w", encoding="utf-8") as f:
    f.write(f"cmd={' '.join(cmd)}\n")
    f.flush()
    proc = subprocess.run(cmd, cwd=str(PKG), env=env, stdout=f, stderr=subprocess.STDOUT)
sys.exit(proc.returncode)
