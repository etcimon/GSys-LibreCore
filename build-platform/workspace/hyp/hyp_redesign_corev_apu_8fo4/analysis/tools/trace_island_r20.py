#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
"""Instrument the owned, stopped island model's failing legacy shadow only."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

work = Path("/opt/testharness/runs/ai-island-r39-final/gemm-work-output")
model = work / "island"
out = Path(os.environ["TH_OUT_DIR"])
header = (model / "Vtb_g6lc_ai_island_dma___024root.h").read_text()
names = (
    "r20_done_ref_q", "r20_done_new_q", "r20_load_checks", "state_q",
    "m_q", "n_q", "k_q", "k_bytes", "i_q", "j_q", "t_q",
    "load_a", "load_b", "load_done", "load_done_event", "load_complete_q",
    "load_all_issued_q", "load_ar_fire", "load_r_fire", "ar_inflight_q",
    "ar_inflight_d", "ar_i_q", "ar_j_q", "ar_plan_terminal_q",
    "receive_row", "receive_col", "receive_count", "receive_rem",
)
fields = {}
for name in names:
    matches = set(re.findall(r"\b(\w*__DOT__i_gemm__DOT__" + name + r")\b", header))
    if len(matches) == 1:
        fields[name] = matches.pop()
assert {"r20_done_ref_q", "r20_done_new_q"} <= fields.keys()
message = "r20 load completion diverged from r19"
sources = [(p, p.read_text()) for p in model.glob("*.cpp") if message in p.read_text()]
assert len(sources) == 1
path, text = sources[0]
index = text.index(message)
start = text.rfind("VL_WRITEF", 0, index)
assert 0 <= index - start < 1000
(out / "discovery.json").write_text(json.dumps({
    "fields": fields, "source": str(path), "assertion": text[start:index + 200],
    "beforeSha256": hashlib.sha256(path.read_bytes()).hexdigest(),
}, indent=2) + "\n")
backup = path.with_suffix(".cpp.before-r20-trace")
assert not backup.exists()
backup.write_bytes(path.read_bytes())
fmt = "R20_DIAG " + " ".join(name + "=%llu" for name in fields) + "\\n"
args = ", ".join("(unsigned long long)vlSelf->" + f for f in fields.values())
injection = f'std::fprintf(stderr, "{fmt}", {args});\n'
path.write_text("#include <cstdio>\n" + text[:start] + injection + text[start:])
command = ["make", "-C", str(model), "-f", "Vtb_g6lc_ai_island_dma.mk", "-j2",
           "OPT_FAST=-O0", "OPT_SLOW=-O0", "VERILATOR_ROOT=" + str(work / "runtime")]
with (out / "build.log").open("w") as log:
    subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True,
                   env=dict(os.environ, VPATH=str(work / "runtime/include")), timeout=300)
with (out / "counterexample.log").open("w") as log:
    result = subprocess.run([str(model / "gemm-test")], stdout=log,
                            stderr=subprocess.STDOUT, timeout=60)
trace = (out / "counterexample.log").read_text()
assert result.returncode != 0 and "R20_DIAG" in trace and message in trace
(out / "result.json").write_text(json.dumps({
    "status": "COUNTEREXAMPLE", "rc": result.returncode,
    "afterSha256": hashlib.sha256(path.read_bytes()).hexdigest(),
}, indent=2) + "\n")
print(trace)
