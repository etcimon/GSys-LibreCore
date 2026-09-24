#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""smt_mixed_probe remote runner: execute one probe ELF on one model.

Runs ON the remote host via testharness_proxy 'py'. Env:
  SMP_MODEL    absolute path to Variane_testharness
  SMP_ELF      ELF filename inside $TH_DATA_DIR
               (built by verif/tests/custom/multicore/smt_mixed_probe_build.sh)
  SMP_CAP      cycle budget (default 4000000)
  SMP_WALL     wall seconds (default 900)
  SMP_FLOW     '1' -> +smt_flow_trace (default on)
  SMP_STATS    '1' -> +smt_mixed_stats (default on)
  SMP_DUP      '1' -> +smt_dup_trace (default off)
Writes results.json + trial/{run.log,retire_h1.txt,retire_h0.txt} under
$TH_OUT_DIR so --pull fetches them. results.json carries the architectural
readout (RES words, per-hart PRT words incl. mhpmcounter deltas, ping-pong
mismatch count, timer/TLB-witness counts) scraped from committed stores,
plus the [smt-mixed] stats lines.
"""
import json
import os
import re
import resource
import subprocess
from pathlib import Path

OUT = Path(os.environ["TH_OUT_DIR"])
DATA = Path(os.environ["TH_DATA_DIR"])
MODEL = os.environ["SMP_MODEL"]
ELF_NAME = os.environ["SMP_ELF"]
CAP = int(os.environ.get("SMP_CAP", "4000000"))
WALL = int(os.environ.get("SMP_WALL", "900"))

elf = DATA / ELF_NAME
syms = subprocess.check_output(["riscv-none-elf-nm", "-n", str(elf)], text=True)
(OUT / "probe.symbols").write_text(syms)
tohost = re.search(r"^([0-9a-fA-F]+)\s+\w\s+tohost$", syms, re.M).group(1)
res_addr = int(re.search(r"^([0-9a-fA-F]+)\s+\w\s+RES$", syms, re.M).group(1), 16)
prt_addr = int(re.search(r"^([0-9a-fA-F]+)\s+\w\s+PRT$", syms, re.M).group(1), 16)

resource.setrlimit(resource.RLIMIT_STACK,
                   (resource.RLIM_INFINITY, resource.RLIM_INFINITY))
trial = OUT / "trial"
trial.mkdir(exist_ok=True)

args = [MODEL, "--seed=1", f"+max-cycles={CAP}", f"+time_out={CAP}",
        "+debug_disable", "+quiet_axi", f"+tohost_addr=0x{tohost}"]
if os.environ.get("SMP_FLOW", "1") == "1":
    args.append("+smt_flow_trace")
if os.environ.get("SMP_STATS", "1") == "1":
    args.append("+smt_mixed_stats")
if os.environ.get("SMP_DUP", "0") == "1":
    args.append("+smt_dup_trace")
args.append(str(elf))

env = {k: v for k, v in os.environ.items()
       if not k.startswith(("CVA6_", "G6LC_", "SOFT_", "PEEL_"))}
env.update(CVA6_COOKIE_EXIT="0", CVA6_SOAK_EXIT="0", CVA6_WFI_EXIT="0",
           CVA6_TRAP_DUMP="1")

with open(trial / "run.log", "w") as log:
    try:
        rc = subprocess.run(
            ["timeout", "--signal=TERM", "--kill-after=15s", f"{WALL}s", *args],
            stdout=log, stderr=subprocess.STDOUT, cwd=str(trial), env=env,
            timeout=WALL + 60).returncode
    except subprocess.TimeoutExpired:
        rc = 124

text = (trial / "run.log").read_text(errors="replace")
rec = {"elf": ELF_NAME, "model": MODEL, "rc": rc,
       "cycleBudget": CAP, "command": args}
verdicts = re.findall(
    r"\*\*\* (SUCCESS|FAILED) \*\*\* \(tohost = (0x[0-9a-fA-F]+|[0-9]+)\)"
    r" after ([0-9]+) cycles", text)
if verdicts:
    rec.update(status=verdicts[0][0], tohostValue=verdicts[0][1],
               cycles=int(verdicts[0][2]))
rec["outcome"] = "pass" if rec.get("status") == "SUCCESS" and \
    rec.get("tohostValue") in ("0", "0x0", "0x1", "1") else \
    ("timeout" if rc in (124, -15, -9) or "Timed out" in text else "fail")
# Architectural readout: last committed store to each RES/PRT word.
stores = re.compile(
    r"\[smt-flow\] store_commit cycle=\d+ id=\d+ pa=([0-9a-fA-F]+) "
    r"data=([0-9a-fA-F]+) be=[0-9a-fA-F]+ valid=1")
seen = {}
for m in stores.finditer(text):
    pa = int(m.group(1), 16)
    if res_addr <= pa < res_addr + 32 or prt_addr <= pa < prt_addr + 128:
        seen[pa] = int(m.group(2), 16)
rec["resWords"] = {f"RES{i}": hex(seen[res_addr + 8 * i])
                   for i in range(4) if res_addr + 8 * i in seen}
PRT_NAMES = ["h1_csum", "h1_ret", "h1_act", "h1_cyc", "h0_ret", "h0_act",
             "h0_cyc", "h0_pp", "h0_tmr", "h0_tlb"]
rec["prtWords"] = {PRT_NAMES[i]: seen[prt_addr + 8 * i]
                   for i in range(10) if prt_addr + 8 * i in seen}
if prt_addr + 15 * 8 in seen:
    rec["prtWords"]["trap_mcause"] = seen[prt_addr + 15 * 8]
rec["mixedStats"] = [l for l in text.splitlines()
                     if l.startswith("[smt-mixed]")]
rec["errors"] = [l for l in text.splitlines()
                 if "%Error" in l or "Assertion" in l][:20]

retire = re.compile(
    r"\[smt-flow\] retire cycle=(\d+) port=(\d+) id=(\d+) gen=(\d+) "
    r"hart=(\d+) pc=([0-9a-fA-F]+) rd=(\d+) result=([0-9a-fA-F]+) "
    r"valid=(\w) drop=(\w) ex=(\w) replay=(\w)")
n = {"0": 0, "1": 0}
with open(trial / "retire_h1.txt", "w") as f1, \
        open(trial / "retire_h0.txt", "w") as f0:
    for m in retire.finditer(text):
        h = m.group(5)
        n[h] = n.get(h, 0) + 1
        (f1 if h == "1" else f0).write(
            f"{m.group(6)} rd={m.group(7)} res={m.group(8)} "
            f"v={m.group(9)} d={m.group(10)} e={m.group(11)} "
            f"r={m.group(12)} c={m.group(1)}\n")
rec["retireByHart"] = n
(OUT / "results.json").write_text(json.dumps(rec, indent=2))
print(json.dumps(rec, indent=2))
