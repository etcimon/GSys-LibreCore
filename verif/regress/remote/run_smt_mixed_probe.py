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
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path


def probe_outcome(rec):
    if rec.get("errors"):
        return "fail"
    if rec.get("rc") in (124, -15, -9) or rec.get("cycles", 0) >= rec["cycleBudget"]:
        return "timeout"
    if rec.get("rc") != 0 or rec.get("verdictCount") != 1 or \
            rec.get("status") != "SUCCESS" or \
            rec.get("tohostValue") not in ("0", "0x0", "0x1", "1"):
        return "fail"
    required = ("RES1",) if rec.get("solo") else ("RES0", "RES1")
    words, payload = rec.get("resWords", {}), rec.get("prtWords", {})
    if any(words.get(key) not in (None, "0x1") for key in required):
        return "fail"
    if payload.get("h1_csum") not in (None, 3287142068561700632):
        return "fail"
    if not rec.get("solo") and any(payload.get(key) not in (None, 0)
                                   for key in ("h0_pp", "h0_tlb")):
        return "fail"
    fields = ("h1_csum",) if rec.get("solo") else ("h1_csum", "h0_pp", "h0_tlb")
    if any(key not in words for key in required) or any(key not in payload for key in fields):
        return "incomplete"
    return "pass"


def verdict_self_test():
    good = {"status": "SUCCESS", "tohostValue": "0", "rc": 0,
            "cycles": 100, "cycleBudget": 1000, "verdictCount": 1,
            "solo": False, "resWords": {"RES0": "0x1", "RES1": "0x1"},
            "prtWords": {"h1_csum": 3287142068561700632, "h0_pp": 0, "h0_tlb": 0},
            "errors": []}
    cases = [(good, "pass"), ({**good, "cycles": 1000}, "timeout"),
             ({**good, "rc": 124}, "timeout"),
             ({**good, "errors": ["Assertion failed"]}, "fail"),
             ({**good, "resWords": {"RES0": "0x9", "RES1": "0x1"}}, "fail"),
             ({**good, "resWords": {}}, "incomplete"),
             ({**good, "prtWords": {"h1_csum": 1}}, "fail"),
             ({**good, "verdictCount": 2}, "fail"),
             ({**good, "solo": True, "resWords": {"RES1": "0x1"}}, "pass")]
    for number, (record, expected) in enumerate(cases):
        actual = probe_outcome(record)
        assert actual == expected, (number, actual, expected)
    print(f"PROBE_VERDICT_PASS cases={len(cases)}")


if "--self-test" in sys.argv:
    verdict_self_test()
    raise SystemExit(0)

import resource

OUT = Path(os.environ["TH_OUT_DIR"])
REASSESS = os.environ.get("SMP_REASSESS_DIR")
frozen = json.loads((Path(REASSESS) / "results.json").read_text()) if REASSESS else None
DATA = Path(REASSESS).parent / "data" if REASSESS else Path(os.environ["TH_DATA_DIR"])
MODEL = frozen["model"] if frozen else os.environ["SMP_MODEL"]
ELF_NAME = frozen["elf"] if frozen else os.environ["SMP_ELF"]
CAP = frozen["cycleBudget"] if frozen else int(os.environ.get("SMP_CAP", "4000000"))
WALL = int(os.environ.get("SMP_WALL", "900"))

elf = DATA / ELF_NAME
syms = subprocess.check_output(["riscv-none-elf-nm", "-n", str(elf)], text=True)
(OUT / "probe.symbols").write_text(syms)
tohost = re.search(r"^([0-9a-fA-F]+)\s+\w\s+tohost$", syms, re.M).group(1)
res_addr = int(re.search(r"^([0-9a-fA-F]+)\s+\w\s+RES$", syms, re.M).group(1), 16)
prt_addr = int(re.search(r"^([0-9a-fA-F]+)\s+\w\s+PRT$", syms, re.M).group(1), 16)
solo_addr = int(re.search(r"^([0-9a-fA-F]+)\s+\w\s+probe_solo$", syms, re.M).group(1), 16)
mode_dump = subprocess.check_output([
    "riscv-none-elf-objdump", "-s", f"--start-address={solo_addr}",
    f"--stop-address={solo_addr + 8}", str(elf)], text=True)
mode_words = re.search(rf"^\s*{solo_addr:x}\s+([0-9a-fA-F]{{8}})\s+([0-9a-fA-F]{{8}})",
                       mode_dump, re.M)
assert mode_words, "missing probe_solo data"
solo = int.from_bytes(bytes.fromhex(mode_words[1] + mode_words[2]), "little")
assert solo in (0, 1), "invalid probe_solo mode"

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

if frozen:
    rc = frozen["rc"]
    log_path = Path(REASSESS) / "trial" / "run.log"
    args = frozen["command"]
else:
    log_path = trial / "run.log"
    with log_path.open("w") as log:
        try:
            rc = subprocess.run(
                ["timeout", "--signal=TERM", "--kill-after=15s", f"{WALL}s", *args],
                stdout=log, stderr=subprocess.STDOUT, cwd=str(trial), env=env,
                timeout=WALL + 60).returncode
        except subprocess.TimeoutExpired:
            rc = 124

raw_log = log_path.read_bytes()
text = raw_log.decode(errors="replace")
rec = {"elf": ELF_NAME, "model": MODEL, "rc": rc,
       "cycleBudget": CAP, "command": args,
       "reassessedFrom": REASSESS, "logSha256": hashlib.sha256(raw_log).hexdigest(),
       "elfSha256": hashlib.sha256(elf.read_bytes()).hexdigest()}
verdicts = re.findall(
    r"\*\*\* (SUCCESS|FAILED) \*\*\* \(tohost = (0x[0-9a-fA-F]+|[0-9]+)\)"
    r" after ([0-9]+) cycles", text)
if verdicts:
    rec.update(status=verdicts[0][0], tohostValue=verdicts[0][1],
               cycles=int(verdicts[0][2]))
rec.update(verdictCount=len(verdicts), solo=bool(solo), verdictVersion=2)
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
rec["outcome"] = probe_outcome(rec)
(OUT / "results.json").write_text(json.dumps(rec, indent=2))
print(json.dumps(rec, indent=2))
