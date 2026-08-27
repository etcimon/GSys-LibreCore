#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""TRACE stock v4 OpenSBI namelen ld ra on work-ver-server-math-v-B.

Proxy:
  py software/smt2-linux/soft-ladder/trace_s4_nl_ra.py
    --data build-platform/workspace/smt2-linux-v4/fw_payload_r3a_v4.elf
    --data software/smt2-linux/soft-ladder/trace-s4-nl-ra.spec
    --tag s4-nl-ra-trace --pull
    --env TH_HARNESS=/opt/testharness/work/work-ver-server-math-v-B/Variane_testharness
    --env TH_TIME_OUT=180000 --env TH_TOHOST=0x80041730
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
        "[hangpc]",
        "[hangpc1]",
        "[trapdump]",
        "[id_sb]",
        "[sb_mem]",
        "[sb_pc]",
        "[sb_iss]",
        "[kill]",
        "[fdtmem]",
        "tag=nl",
        "tag=fw",
        "tag=op",
        "tag=nt",
        "tag=st",
        "tag=stuck",
        "tag=raedge",
        "tag=opra",
        "tag=stk",
        "tag=lenp",
        "tag=compat",
        "tag=slc",
        "tag=strlen",
        "tag=memcmp",
        "tag=memchr",
        "tag=iaf0",
        "tag=hang",
        "tag=pin0",
        "tag=fwplat",
        "tag=jalr1",
        "tag=jalr2",
        "tag=match",
        "tag=fdtiaf",
        "tag=pinfdt",
        "tag=badva",
        "tag=cmtend",
        "tag=chkret",
        "tag=fail",
        "tag=cmtfail",
        "tag=plus16",
        "tag=ntpro",
        "tag=cmtpro",
        "tag=cmtchk",
        "tag=chk",
        "tag=raslot",
        "tag=gnepi",
        "fffffff5",
        "0xfffffff5",
        "tag=pro",
        "tag=chk",
        "tag=epi",
        "tag=subn",
        "tag=raslot",
        "tag=holdra",
        "0x800132e0",
        "0x80013374",
        "0x80013408",
        "tag=chk",
        "tag=ntepi",
        "tag=gnepi",
        "tag=gnpro",
        "tag=rasave",
        "tag=s3slot",
        "0x80012ad8",
        "0x80012ada",
        "0x80012aca",
        "0x80012ac0",
        "0x80012ad0",
        "tag=ntret",
        "tag=line0",
        "tag=aca",
        "tag=epi",
        "tag=cmt",
        "tag=spedge",
        "tag=cmtall",
        "tag=cmtepi",
        "tag=cmtpro",
        "tag=cmt16",
        "tag=cmtra",
        "tag=cmttail",
        "tag=nptail",
        "tag=pin0",
        "tag=ntpro",
        "tag=jalnt",
        "tag=gnjal",
        "tag=cmtjal",
        "tag=cmtnt",
        "tag=cmtgn",
        "tag=win",
        "[fetch_snap]",
        "[fetch_slot]",
        "leftover",
        "drop=",
        "k2=",
        "0x80012aca",
        "0x80013312",
        "tag=ad8",
        "0x80046e20",
        "0x80046e40",
        "0x80046e60",
        "0x80046e80",
        "0x80046f2c",
        "0x80013f06",
        "0x80014182",
        "0x8001e000",
        "0x800072e8",
        "0x8000732c",
        "0x8001370a",
        "0x80013974",
        "SUCCESS",
        "FAILED",
        "tohost",
        "coldboot_done",
    )
    lines = [ln for ln in log_text.splitlines() if any(k in ln for k in keys)]
    return "\n".join(lines[:600]) + ("\n" if lines else "")


def main() -> int:
    data_dir = Path(os.environ.get("TH_DATA_DIR", "/tmp"))
    out_dir = Path(os.environ.get("TH_OUT_DIR", "/tmp"))
    out_dir.mkdir(parents=True, exist_ok=True)
    elf = _find(data_dir, os.environ.get("TH_ELF", "fw_payload_r3a_v4.elf"))
    spec = _find(data_dir, os.environ.get("TH_SPEC", "trace-s4-nl-ra.spec"))
    harness = os.environ.get(
        "TH_HARNESS",
        "/opt/testharness/work/work-ver-server-math-v-B/Variane_testharness",
    )
    time_out = os.environ.get("TH_TIME_OUT", "180000")
    tohost = os.environ.get("TH_TOHOST", "0x80041730")
    env = dict(os.environ)
    env["CVA6_TRACE"] = "1"
    env["CVA6_TRACE_FILE"] = str(spec)
    env["CVA6_SOAK_EXIT"] = os.environ.get("CVA6_SOAK_EXIT", "1")
    env["CVA6_TRAP_DUMP"] = "1"
    if os.environ.get("CVA6_PIN_MEPC"):
        env["CVA6_PIN_MEPC"] = os.environ["CVA6_PIN_MEPC"]
        env["CVA6_PIN_MCAUSE"] = os.environ.get("CVA6_PIN_MCAUSE", "1")
    env["CVA6_WFI_EXIT"] = "0"
    env["CVA6_COOKIE_EXIT"] = "0"
    env.setdefault("CVA6_SOAK_POLL", "64")
    extra = [
        a.strip()
        for a in os.environ.get("TH_PLUSARGS", "").replace(",", " ").split()
        if a.strip()
    ]
    proc = subprocess.run(
        [
            harness,
            f"+time_out={time_out}",
            f"+max-cycles={time_out}",
            "+debug_disable",
            "+quiet_axi",
            f"+tohost_addr={tohost}",
            *extra,
            str(elf),
        ],
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    text = proc.stdout or ""
    (out_dir / "s4_nl_ra_trace.log").write_text(text, encoding="utf-8")
    classify = (
        f"rc={proc.returncode} elf={elf.name} to={time_out} tohost={tohost}\n"
        + _extract(text)
    )
    (out_dir / "s4_nl_ra_trace.classify.txt").write_text(
        classify, encoding="utf-8"
    )
    print(classify)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
