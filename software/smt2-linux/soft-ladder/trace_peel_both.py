#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""Proxy TRACE of fw_payload_peel_both.elf on flavour B (linux-boot-scale S1).

Upload via testharness_proxy.py py:
  --data software/smt2-linux/soft-ladder/build/fw_payload_peel_both.elf
  --data software/smt2-linux/soft-ladder/trace-s1-nt-alias.spec
  --tag s1-peel-trace --pull

Classifies 2nd fdt_next_tag c.sdsp s3 @0x129d8 vs ld s3,24(sp) @0x12a66.
Not a p<N> script; output is remote-runs/<tag>/output/.
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


def _extract(log_text: str) -> str:
    keys = (
        "[pin-exit]",
        "[cookie-exit]",
        "[trapdump]",
        "tag=sdsp",
        "tag=ntr loc=0x80012a66",
        "tag=ntr loc=0x80012a68",
        "tag=ntr loc=0x80012a72",
        "mepc=0x80012eb2",
        "SUCCESS",
        "tohost",
    )
    lines = []
    for line in log_text.splitlines():
        if any(k in line for k in keys):
            lines.append(line)
    return "\n".join(lines) + ("\n" if lines else "")


def main() -> int:
    run_dir = Path(os.environ.get("TH_RUN_DIR", "/tmp"))
    data_dir = Path(os.environ.get("TH_DATA_DIR", str(run_dir / "data")))
    out_dir = Path(os.environ.get("TH_OUT_DIR", "/tmp"))
    out_dir.mkdir(parents=True, exist_ok=True)

    elf = _find(data_dir, "fw_payload_peel_both.elf")
    spec = _find(data_dir, "trace-s1-nt-alias.spec")
    harness = os.environ.get(
        "TH_HARNESS",
        "/opt/testharness/work/work-ver-smt2-fw64-B/Variane_testharness",
    )
    time_out = os.environ.get("TH_TIME_OUT", "40000")
    tohost = os.environ.get("TH_TOHOST", "0x80041730")

    env = dict(os.environ)
    env["CVA6_TRACE"] = "1"
    env["CVA6_TRACE_FILE"] = str(spec)
    env["CVA6_SOAK_EXIT"] = "1"
    env["CVA6_TRAP_DUMP"] = "1"
    env["CVA6_PIN_MEPC"] = "0x80012eb2"
    env["CVA6_PIN_MCAUSE"] = "6"
    env["CVA6_WFI_EXIT"] = "0"
    env["CVA6_COOKIE_EXIT"] = "0"

    log_path = out_dir / "s1_peel_trace.log"
    classify_path = out_dir / "s1_peel_trace.classify.txt"

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
    classify = _extract(log_text)
    classify_path.write_text(
        f"rc={proc.returncode}\nelf={elf}\nspec={spec}\n"
        f"time_out={time_out} tohost={tohost}\n\n{classify}",
        encoding="utf-8",
    )
    print(f"rc={proc.returncode} log={log_path} classify={classify_path}")
    print(classify if classify else "(no classify hits)")
    tail = log_text[-3000:] if len(log_text) > 3000 else log_text
    print("--- log tail ---")
    print(tail)
    return 0 if proc.returncode == 0 else proc.returncode


if __name__ == "__main__":
    raise SystemExit(main())
