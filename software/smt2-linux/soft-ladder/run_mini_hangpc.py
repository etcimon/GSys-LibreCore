#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""Run a mini ELF with hangpc (CVA6_TRAP_DUMP). Cap tohost=0 is hang."""
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
    elf_name = os.environ.get("TH_ELF", "mini_ecall_list_walk.elf")
    elf = _find(data_dir, elf_name)
    harness = os.environ.get(
        "TH_HARNESS",
        "/opt/testharness/work/work-ver-smt2-fw64-B/Variane_testharness",
    )
    time_out = os.environ.get("TH_TIME_OUT", "40000")
    tohost = os.environ.get("TH_TOHOST", "0x80001000")
    env = dict(os.environ)
    env["CVA6_TRAP_DUMP"] = "1"
    env["CVA6_SOAK_EXIT"] = os.environ.get("CVA6_SOAK_EXIT", "1")
    env["CVA6_COOKIE_EXIT"] = os.environ.get("CVA6_COOKIE_EXIT", "0")
    env["CVA6_WFI_EXIT"] = os.environ.get("CVA6_WFI_EXIT", "0")
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
    (out_dir / "mini_hangpc.log").write_text(text, encoding="utf-8")
    keys = (
        "SUCCESS",
        "FAILED",
        "tohost",
        "[hangpc]",
        "[hangpc1]",
        "[fdtmem]",
        "[trapdump]",
        "rvfi",
        "Simulation terminated",
    )
    lines = [ln for ln in text.splitlines() if any(k in ln for k in keys)]
    verdict = f"rc={proc.returncode} elf={elf.name} to={time_out} tohost={tohost}\n"
    verdict += "\n".join(lines[:40]) + "\n"
    (out_dir / "mini_hangpc.classify.txt").write_text(verdict, encoding="utf-8")
    print(verdict)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
