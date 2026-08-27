#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""Run S1 next_tag minis on work-ver-server-math-v-B (HPDCACHE_WT I=2 N=2).

Proxy:
  py software/smt2-linux/soft-ladder/run_s4_v_minis.py
    --data software/smt2-linux/soft-ladder/_mini_out/mini_fdt_nt_stock.elf
    --data software/smt2-linux/soft-ladder/_mini_out/mini_stq_alias_jal.elf
    --data software/smt2-linux/soft-ladder/_mini_out/mini_fdt_nt_frame32.elf
    --data software/smt2-linux/soft-ladder/_mini_out/mini_fdt_nt_osbi.elf
    --tag s4-v-nt-minis --pull
    --env TH_HARNESS=/opt/testharness/work/work-ver-server-math-v-B/Variane_testharness
"""
from __future__ import annotations

import os
import subprocess
from pathlib import Path


def _find(data: Path, name: str) -> Path:
    direct = data / name
    if direct.is_file():
        return direct
    for p in data.rglob(name):
        if p.is_file():
            return p
    raise FileNotFoundError(f"{name} not under {data}")


def main() -> int:
    data_dir = Path(os.environ.get("TH_DATA_DIR", "/tmp"))
    out_dir = Path(os.environ.get("TH_OUT_DIR", "/tmp"))
    out_dir.mkdir(parents=True, exist_ok=True)
    harness = os.environ.get(
        "TH_HARNESS",
        "/opt/testharness/work/work-ver-server-math-v-B/Variane_testharness",
    )
    time_out = os.environ.get("TH_TIME_OUT", "40000")
    tohost = os.environ.get("TH_TOHOST", "0x80001000")
    names = os.environ.get(
        "TH_ELFS",
        "mini_fdt_nt_stock.elf,mini_stq_alias_jal.elf,"
        "mini_fdt_nt_frame32.elf,mini_fdt_nt_osbi.elf",
    ).split(",")
    env = dict(os.environ)
    env["CVA6_TRAP_DUMP"] = "1"
    env["CVA6_COOKIE_EXIT"] = "0"
    env["CVA6_WFI_EXIT"] = "0"
    env["CVA6_SOAK_EXIT"] = "0"
    lines = [f"harness={harness} to={time_out} tohost={tohost}"]
    for name in names:
        name = name.strip()
        if not name:
            continue
        elf = _find(data_dir, name)
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
        text = proc.stdout or ""
        (out_dir / f"{elf.stem}.log").write_text(text, encoding="utf-8")
        keys = ("SUCCESS", "FAILED", "tohost", "[hangpc]", "[trapdump]")
        hit = [ln for ln in text.splitlines() if any(k in ln for k in keys)]
        verdict = f"=== {elf.name} rc={proc.returncode} ==="
        lines.append(verdict)
        lines.extend(hit[:12])
        print(verdict)
        print("\n".join(hit[:12]))
    out = "\n".join(lines) + "\n"
    (out_dir / "s4_v_minis.classify.txt").write_text(out, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
