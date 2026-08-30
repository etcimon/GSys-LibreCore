#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""TRACE ipi-lot _start_warm / hart1 SP."""
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
    elf = _find(
        data_dir,
        os.environ.get("TH_ELF", "fw_payload_r3a_c15_plat_skip.ipi-tab.elf"),
    )
    spec = _find(data_dir, os.environ.get("TH_SPEC", "trace-s3-warm.spec"))
    harness = os.environ.get(
        "TH_HARNESS",
        "/opt/testharness/work/work-ver-smt2-fw64-B/Variane_testharness",
    )
    time_out = os.environ.get("TH_TIME_OUT", "200000")
    env = dict(os.environ)
    env["CVA6_TRACE"] = "1"
    env["CVA6_TRACE_FILE"] = str(spec)
    env["CVA6_SOAK_EXIT"] = "1"
    env["CVA6_TRAP_DUMP"] = "1"
    env["CVA6_COOKIE_EXIT"] = "0"
    env["CVA6_WFI_EXIT"] = "0"
    proc = subprocess.run(
        [
            harness,
            f"+time_out={time_out}",
            f"+max-cycles={time_out}",
            "+debug_disable",
            "+quiet_axi",
            "+tohost_addr=0x80041730",
            str(elf),
        ],
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    text = proc.stdout or ""
    (out_dir / "s3_warm.log").write_text(text, encoding="utf-8")
    lines = [ln for ln in text.splitlines() if ln.startswith("[trace]")]

    def grab(tag: str) -> list[str]:
        return [ln for ln in lines if f" tag={tag} " in ln]

    out = [f"rc={proc.returncode} traces={len(lines)}"]
    for tag in (
        "wait1",
        "w1",
        "w0",
        "hang1",
        "sp1",
        "hcnt",
        "hidtab",
        "lot0",
        "cave0",
        "wait0",
        "npccave",
    ):
        rows = grab(tag)
        out.append(f"{tag} n={len(rows)}")
        if rows:
            out.append("  first " + " || ".join(rows[:8]))
            if len(rows) > 8:
                out.append("  last " + " || ".join(rows[-4:]))
    hangpc = [ln for ln in text.splitlines() if ln.startswith("[hangpc]")]
    if hangpc:
        out.append("hangpc " + hangpc[-1])
    cookie = [ln for ln in text.splitlines() if "51b1" in ln or "cookie" in ln][:6]
    if cookie:
        out.append("cookie " + " | ".join(cookie))
    verdict = "\n".join(out) + "\n"
    (out_dir / "s3_warm.classify.txt").write_text(verdict, encoding="utf-8")
    print(verdict)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
