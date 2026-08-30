#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""TRACE of mini_fdt_nt_osbi_h0 keep-class hang (linux-boot-scale S1).

  py …/trace_h0_hang.py --data …/mini_fdt_nt_osbi_h0.elf \
     --data …/trace-s1-h0-hang.spec --tag s1-h0-keep-hang-trace --pull
"""
from __future__ import annotations

import os
import subprocess
from collections import Counter
from pathlib import Path


def _find(data: Path, name: str) -> Path:
    direct = data / name
    if direct.is_file():
        return direct
    for p in data.rglob(name):
        if p.is_file():
            return p
    raise FileNotFoundError(f"{name} not under {data}")


def _t(line: str) -> int | None:
    i = line.find(" t=")
    if i < 0:
        return None
    try:
        return int(line[i + 3 :].split()[0])
    except ValueError:
        return None


def _loc(line: str) -> str | None:
    i = line.find(" loc=")
    if i < 0:
        return None
    return line[i + 5 :].split()[0]


def _classify(log_text: str) -> str:
    lines_out: list[str] = []
    hang = [ln for ln in log_text.splitlines() if "tag=hang" in ln]
    npc = [ln for ln in log_text.splitlines() if "tag=npc" in ln]
    ntr = [ln for ln in log_text.splitlines() if "tag=ntr" in ln]
    alias = [ln for ln in log_text.splitlines() if "tag=alias" in ln]
    pin = [ln for ln in log_text.splitlines() if "[pin-exit]" in ln]
    tohost = [ln for ln in log_text.splitlines() if "tohost" in ln and "***" in ln]
    lines_out.append(
        f"hang_commits={len(hang)} npc_hits={len(npc)} ntr_hits={len(ntr)} "
        f"alias_hits={len(alias)} pin={len(pin)}"
    )
    if tohost:
        lines_out.append(tohost[-1])
    pcs = [_loc(ln) for ln in hang if _loc(ln)]
    if pcs:
        cnt = Counter(pcs)
        lines_out.append("hang_pc_hist " + " ".join(f"{p}x{n}" for p, n in cnt.most_common(8)))
        lines_out.append(f"last_hang {hang[-1]}")
    else:
        lines_out.append("hang_commits=0 after t=38000 — pipeline stall (no retire)")
    if npc:
        lines_out.append(f"last_npc {npc[-1]}")
        npcs = [_loc(ln) for ln in npc if _loc(ln)]
        lines_out.append("npc_hist " + " ".join(f"{p}x{n}" for p, n in Counter(npcs).most_common(8)))
    else:
        lines_out.append("npc=none in hang window")
    if ntr:
        lines_out.append(f"last_ntr {ntr[-1]}")
    if alias:
        lines_out.append(f"last_alias {alias[-1]}")
    if hang:
        ts = [_t(ln) for ln in hang if _t(ln) is not None]
        if ts:
            lines_out.append(f"hang_t_range {min(ts)}..{max(ts)}")
    if npc and not hang:
        lines_out.append(
            "VERDICT: stall — npc moving or stuck, no commit after 38000"
        )
    elif hang and len(set(pcs)) <= 4:
        lines_out.append(
            f"VERDICT: spin/wait at {pcs[-1] if pcs else '?'} "
            f"({len(set(pcs))} unique commit PCs in hang window)"
        )
    elif hang:
        lines_out.append("VERDICT: still retiring diverse PCs in hang window — inspect hist")
    else:
        lines_out.append("VERDICT: no hang samples — spec/after/TB")
    return "\n".join(lines_out) + "\n"


def main() -> int:
    run_dir = Path(os.environ.get("TH_RUN_DIR", "/tmp"))
    data_dir = Path(os.environ.get("TH_DATA_DIR", str(run_dir / "data")))
    out_dir = Path(os.environ.get("TH_OUT_DIR", "/tmp"))
    out_dir.mkdir(parents=True, exist_ok=True)

    elf = _find(data_dir, "mini_fdt_nt_osbi_h0.elf")
    spec = _find(data_dir, "trace-s1-h0-hang.spec")
    harness = os.environ.get(
        "TH_HARNESS",
        "/opt/testharness/work/work-ver-smt2-fw64-B/Variane_testharness",
    )
    time_out = os.environ.get("TH_TIME_OUT", "40000")
    tohost = os.environ.get("TH_TOHOST", "0x80001000")

    env = dict(os.environ)
    env["CVA6_TRACE"] = "1"
    env["CVA6_TRACE_FILE"] = str(spec)
    env["CVA6_SOAK_EXIT"] = "1"
    env["CVA6_TRAP_DUMP"] = "1"
    env["CVA6_PIN_MEPC"] = "0x80012eb2"
    env["CVA6_PIN_MCAUSE"] = "6"
    env["CVA6_WFI_EXIT"] = "0"
    env["CVA6_COOKIE_EXIT"] = "0"
    env["CVA6_SOAK_POLL"] = "64"

    log_path = out_dir / "s1_h0_hang_trace.log"
    classify_path = out_dir / "s1_h0_hang_trace.classify.txt"

    proc = subprocess.run(
        [
            harness,
            f"+time_out={time_out}",
            f"+max-cycles={time_out}",
            "+debug_disable",
            "+quiet_axi",
            f"+tohost_addr={tohost}",
            str(elf),
        ],
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    log_text = proc.stdout or ""
    log_path.write_text(log_text, encoding="utf-8")
    verdict = _classify(log_text)
    classify_path.write_text(
        f"rc={proc.returncode}\nelf={elf}\nspec={spec}\n"
        f"time_out={time_out} soak_poll=64\n\n{verdict}\n",
        encoding="utf-8",
    )
    print(f"rc={proc.returncode} log={log_path} classify={classify_path}")
    print(verdict)
    tail = log_text[-2500:] if len(log_text) > 2500 else log_text
    print("--- log tail ---")
    print(tail)
    return 0 if proc.returncode == 0 else proc.returncode


if __name__ == "__main__":
    raise SystemExit(main())
