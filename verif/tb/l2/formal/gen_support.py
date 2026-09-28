#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Generate formal support files for the g6lc_l2 bounded proofs:
#   types.sv            — g6lc_l2_tb_pkg extracted from tb_g6lc_l2.sv
#                         (same extraction the composed lanes run)
#   mut/g6lc_l2_top.sv  — FORMAL_MUT_P3: the posted-write S_BYPASS_B guard
#                         dropped, so the posted path falls into the wait
#                         state and P3 must fail.
# Usage: python3 gen_support.py   (idempotent; writes into the cwd layout
# the .sby files expect — run from anywhere, outputs land next to it).

import os
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
MARKER = 'corev_apu/l2_cache/g6lc_l2_top.sv'
REPO = None
for cand in (Path.cwd(), *Path.cwd().parents,
             HERE, *HERE.parents):
    if (cand / MARKER).exists():
        REPO = cand
        break
assert REPO is not None, 'run inside the cva6 tree'

# --- types.sv: extract the bench package ----------------------------------
tb = (REPO / 'verif/tb/l2/tb_g6lc_l2.sv').read_text()
types = re.findall(r'package g6lc_l2_tb_pkg;.*?endpackage', tb, re.S)
assert len(types) == 1, 'g6lc_l2_tb_pkg extraction changed'
(HERE / 'types.sv').write_text(types[0] + '\n')

# --- mut/g6lc_l2_top.sv: drop the posted S_BYPASS_B guard ------------------
top = (REPO / 'corev_apu/l2_cache/g6lc_l2_top.sv').read_text()
OLD = ("          state_d = (POSTED_WRITES && wr_posted_q) ? S_IDLE : "
       "S_BYPASS_B;")
NEW = "          state_d = S_BYPASS_B;"
assert top.count(OLD) == 1, 'P3 mutation site changed'
(HERE / 'mut').mkdir(exist_ok=True)
(HERE / 'mut/g6lc_l2_top.sv').write_text(top.replace(OLD, NEW))
print('gen_support: types.sv + mut/g6lc_l2_top.sv')
