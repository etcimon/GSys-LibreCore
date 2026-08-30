#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""TRACE mini_fdt_nt_osbi_tightbo.elf hang (by_offset after software-correct)."""
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
    tok = line[i + 5 :].split()[0]
    return tok


def _classify(text: str) -> str:
    lines = [ln for ln in text.splitlines() if ln.startswith("[trace]")]
    hang = [ln for ln in lines if " tag=hang " in ln]
    npc = [ln for ln in lines if " tag=npc " in ln]
    byoff = [ln for ln in lines if " tag=byoff " in ln]
    jalbo = [ln for ln in lines if " tag=jalbo " in ln]
    hist = Counter()
    for ln in hang:
        loc = _loc(ln)
        if loc:
            hist[loc] += 1
    npc_hist = Counter()
    for ln in npc:
        loc = _loc(ln)
        if loc:
            npc_hist[loc] += 1
    out = [
        f"hang_commits={len(hang)} npc_hits={len(npc)} byoff_hits={len(byoff)} jalbo_hits={len(jalbo)}",
    ]
    if hist:
        top = " ".join(f"{k}x{v}" for k, v in hist.most_common(8))
        out.append(f"hang_pc_hist {top}")
        out.append(f"last_hang {hang[-1]}")
    if npc_hist:
        top = " ".join(f"{k}x{v}" for k, v in npc_hist.most_common(8))
        out.append(f"npc_hist {top}")
        out.append(f"last_npc {npc[-1]}")
    if byoff:
        out.append(f"last_byoff {byoff[-1]}")
        out.append(f"first_byoff {byoff[0]}")
    if jalbo:
        out.append(f"last_jalbo {jalbo[-1]}")
    if hang:
        ts = [_t(ln) for ln in hang if _t(ln) is not None]
        if ts:
            out.append(f"hang_t_range {min(ts)}..{max(ts)}")
    return "\n".join(out) + "\n"


def main() -> int:
    run_dir = Path(os.environ.get("TH_RUN_DIR", "/tmp"))
    data_dir = Path(os.environ.get("TH_DATA_DIR", str(run_dir / "data")))
    out_dir = Path(os.environ.get("TH_OUT_DIR", "/tmp"))
    out_dir.mkdir(parents=True, exist_ok=True)
    elf = _find(data_dir, "mini_fdt_nt_osbi_tightbo.elf")
    spec = _find(data_dir, "trace-s1-tightbo.spec")
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
    env["CVA6_WFI_EXIT"] = "0"
    env["CVA6_COOKIE_EXIT"] = "0"
    env["CVA6_SOAK_POLL"] = "64"
    log_path = out_dir / "s1_tightbo_trace.log"
    classify_path = out_dir / "s1_tightbo_trace.classify.txt"
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
        f"rc={proc.returncode}\nelf={elf}\nspec={spec}\n\n{verdict}\n",
        encoding="utf-8",
    )
    print(f"rc={proc.returncode}")
    print(verdict)
    print(log_text[-2000:] if len(log_text) > 2000 else log_text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
