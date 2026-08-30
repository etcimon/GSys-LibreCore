#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""TRACE hold peel-printf near sbi_printf la console_out_lock."""
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


def _loc(line: str) -> str | None:
    i = line.find(" loc=")
    if i < 0:
        return None
    return line[i + 5 :].split()[0]


def main() -> int:
    data_dir = Path(os.environ.get("TH_DATA_DIR", "/tmp"))
    out_dir = Path(os.environ.get("TH_OUT_DIR", "/tmp"))
    out_dir.mkdir(parents=True, exist_ok=True)
    elf = _find(data_dir, os.environ.get("TH_ELF", "fw_payload_r3a_c15_plat_skip.held.peel-printf.elf"))
    spec = _find(data_dir, "trace-s2-hold-printf.spec")
    harness = os.environ.get(
        "TH_HARNESS",
        "/opt/testharness/work/work-ver-smt2-fw64-B/Variane_testharness",
    )
    time_out = os.environ.get("TH_TIME_OUT", "250000")
    env = dict(os.environ)
    env["CVA6_TRACE"] = "1"
    env["CVA6_TRACE_FILE"] = str(spec)
    env["CVA6_SOAK_EXIT"] = "1"
    env["CVA6_TRAP_DUMP"] = "1"
    env["CVA6_COOKIE_EXIT"] = "1"
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
    (out_dir / "s2_printf.log").write_text(text, encoding="utf-8")
    lines = [ln for ln in text.splitlines() if ln.startswith("[trace]")]

    def grab(tag: str) -> list[str]:
        return [ln for ln in lines if f" tag={tag} " in ln]

    hsm, prla, lock, prs, plbu = (
        grab("hsm"), grab("prla"), grab("lock"), grab("prs"), grab("plbu")
    )
    out = [
        f"rc={proc.returncode} plbu={len(plbu)} prs={len(prs)}",
        "plbu_hist " + " ".join(
            f"{k}x{v}" for k, v in Counter(_loc(ln) for ln in plbu if _loc(ln)).most_common(8)
        ),
    ]
    for label, rows in (("first_plbu", plbu[:12]), ("last_plbu", plbu[-4:])):
        if rows:
            out.append(label + " " + " || ".join(rows))
    hangpc = [ln for ln in text.splitlines() if ln.startswith("[hangpc]")]
    if hangpc:
        out.append("hangpc " + hangpc[-1])
    mem = [ln for ln in lines if " tag=" in ln and any(t in ln for t in ("pname", "tbuf"))]
    if mem:
        out.append("mem " + " | ".join(mem[:8]))
        out.append("mem_last " + " | ".join(mem[-4:]))
    cookie = [ln for ln in text.splitlines() if "51b1" in ln or "cookie" in ln][:8]
    out.append("cookie " + " | ".join(cookie))
    verdict = "\n".join(out) + "\n"
    (out_dir / "s2_printf.classify.txt").write_text(verdict, encoding="utf-8")
    print(verdict)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
