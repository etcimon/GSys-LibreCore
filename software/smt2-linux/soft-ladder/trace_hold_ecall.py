#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""TRACE hold ELF near sbi_ecall_register_extension @8d98."""
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
    elf = _find(data_dir, "fw_payload_r3a_c15_plat_skip.held.elf")
    spec = _find(data_dir, "trace-s1-hold-ecall.spec")
    harness = os.environ.get(
        "TH_HARNESS",
        "/opt/testharness/work/work-ver-smt2-fw64-B/Variane_testharness",
    )
    time_out = os.environ.get("TH_TIME_OUT", "2000000")
    env = dict(os.environ)
    env["CVA6_TRACE"] = "1"
    env["CVA6_TRACE_FILE"] = str(spec)
    env["CVA6_SOAK_EXIT"] = "1"
    env["CVA6_TRAP_DUMP"] = "1"
    env["CVA6_COOKIE_EXIT"] = "1"
    env["CVA6_WFI_EXIT"] = "0"
    env["CVA6_SOAK_POLL"] = "64"
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
    (out_dir / "s1_hold_ecall.log").write_text(text, encoding="utf-8")
    lines = [ln for ln in text.splitlines() if ln.startswith("[trace]")]
    def grab(tag: str) -> list[str]:
        return [ln for ln in lines if f" tag={tag} " in ln]

    enter = grab("enter")
    headld = grab("headld")
    nxld = grab("nxld")
    ins = grab("ins")
    late = grab("late")
    succ = grab("succ")
    out = [
        f"rc={proc.returncode} enter={len(enter)} headld={len(headld)} nxld={len(nxld)} ins={len(ins)} late={len(late)} succ={len(succ)}",
        "enter_hist " + " ".join(f"{k}x{v}" for k, v in Counter(_loc(ln) for ln in enter if _loc(ln)).most_common(8)),
        "headld_hist " + " ".join(f"{k}x{v}" for k, v in Counter(_loc(ln) for ln in headld if _loc(ln)).most_common(8)),
        "nxld_hist " + " ".join(f"{k}x{v}" for k, v in Counter(_loc(ln) for ln in nxld if _loc(ln)).most_common(8)),
    ]
    for label, rows in (
        ("first_enter", enter[:4]),
        ("first_headld", headld[:6]),
        ("first_nxld", nxld[:8]),
        ("first_ins", ins[:4]),
        ("last_headld", headld[-2:]),
        ("last_nxld", nxld[-4:]),
        ("late", late[:8]),
    ):
        if rows:
            out.append(label + " " + " || ".join(rows))
    hangpc = [ln for ln in text.splitlines() if ln.startswith("[hangpc]")]
    if hangpc:
        out.append("hangpc " + hangpc[-1])
    mem = [ln for ln in lines if " tag=" in ln and any(t in ln for t in ("listnext", "timenext", "rfnnext", "latehead", "latenode"))]
    if mem:
        out.append("mem " + " | ".join(mem[:12]))
        out.append("mem_last " + " | ".join(mem[-6:]))
    cookie = [ln for ln in text.splitlines() if "51b1" in ln or "CLASSIFY" in ln or "cookie" in ln][:12]
    out.append("cookie " + " | ".join(cookie))
    verdict = "\n".join(out) + "\n"
    (out_dir / "s1_hold_ecall.classify.txt").write_text(verdict, encoding="utf-8")
    print(verdict)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
