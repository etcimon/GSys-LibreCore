#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""OoO rename cover only. Not an L2/SMT/cluster gate.

Expects proxy `py --data core/ooo/formal --data core/ooo/g6lc_rename.sv`.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

data = Path(os.environ["TH_DATA_DIR"])
out = Path(os.environ["TH_OUT_DIR"])
formal_src = data / "formal"
rename_src = data / "g6lc_rename.sv"
if not formal_src.is_dir() or not rename_src.is_file():
    sys.exit(f"missing uploaded formal sources under {data}")

ooo = out / "ooo"
formal = ooo / "formal"
formal.mkdir(parents=True, exist_ok=True)
shutil.copy2(rename_src, ooo / "g6lc_rename.sv")
for path in formal_src.iterdir():
    if path.is_file():
        shutil.copy2(path, formal / path.name)

sby = formal / "g6lc_ooo_rename_cover.sby"
body = sby.read_text(encoding="utf-8")
# sby ERROR-kills the task if engine_0 is missing yices; testharness has z3 only.
body = body.replace("smtbmc --nopresat yices", "smtbmc --nopresat z3")
sby.write_text(body, encoding="utf-8")

env = dict(os.environ)
env["PATH"] = "/opt/testharness/toolchains/formal/bin:/usr/bin:/usr/local/bin:/bin"
proc = subprocess.run(
    ["sby", "-f", "g6lc_ooo_rename_cover.sby"],
    cwd=formal,
    env=env,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
)
(out / "sby.log").write_text(proc.stdout)
print(proc.stdout, end="")
sys.exit(proc.returncode)
