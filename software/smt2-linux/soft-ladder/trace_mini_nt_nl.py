#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""Proxy TRACE of mini_fdt_nt_osbi.elf on flavour B (linux-boot-scale S1).

Upload via testharness_proxy.py py:
  --data software/smt2-linux/soft-ladder/_mini_out/mini_fdt_nt_osbi.elf
  --data software/smt2-linux/soft-ladder/trace-s1-nt-nl.spec
  --tag s1-nt-nl-trace --pull

Classifies 2nd fdt_next_tag ld s3,24(sp) @0x12a66 against DRAM at
PA 0x80046ec8 (mini; peel alias is 0x80046e38). STQ/hold overlay vs D$:
  DRAM=lenp and s3=0x12b2a  → forward/hold of stale ra (D$ has younger store)
  DRAM=0x12b2a and s3=0x12b2a → younger c.sdsp never landed in DRAM
log hold (tag=hold) samples g1ao_hold_{v,hit,pa,data} at execute:
  HOLD LIVE STALE  → overlay sourced 0x12b2a
  HOLD DEAD        → L1/D$ sourced 0x12b2a (ACK-before-check)
Cap tohost=0 is not mini PASS.
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
        "tag=alias",
        "tag=s2slot",
        "tag=lenp",
        "tag=hold",
        "tag=sw",
        "tag=fail",
        "tag=wrack",
        "[hangpc]",
        "mepc=0x80012eb2",
        "mepc0=",
        "SUCCESS",
        "FAILED",
        "tohost",
    )
    lines = []
    for line in log_text.splitlines():
        if any(k in line for k in keys):
            lines.append(line)
    return "\n".join(lines) + ("\n" if lines else "")


def _gpr(line: str, xn: int) -> str | None:
    key = f" x{xn}="
    i = line.find(key)
    if i < 0:
        return None
    v = line[i + len(key) :].split()[0]
    return v


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


def _field(line: str, key: str) -> str | None:
    tok = f" {key}="
    i = line.find(tok)
    if i < 0:
        return None
    return line[i + len(tok) :].split()[0]


def _u64(s: str | None) -> int | None:
    if not s:
        return None
    try:
        return int(s, 16) if s.startswith("0x") or s.startswith("0X") else int(s, 0)
    except ValueError:
        return None


def _classify_verdict(extract: str) -> str:
    sdsp = [ln for ln in extract.splitlines() if "tag=sdsp" in ln]
    ntr66 = [ln for ln in extract.splitlines() if "tag=ntr loc=0x80012a66" in ln]
    ntr68 = [ln for ln in extract.splitlines() if "tag=ntr loc=0x80012a68" in ln]
    alias = [ln for ln in extract.splitlines() if "tag=alias" in ln]
    lines = [
        f"sdsp_hits={len(sdsp)} ntr66_hits={len(ntr66)} ntr68_hits={len(ntr68)} "
        f"alias_mem_hits={len(alias)}"
    ]
    if len(sdsp) >= 2:
        lines.append(f"2nd_sdsp {sdsp[1]}")
        lines.append(f"  s3={_gpr(sdsp[1], 19)} sp={_gpr(sdsp[1], 2)}")
    if ntr68:
        pick = ntr68[1] if len(ntr68) > 1 else ntr68[-1]
        lines.append(f"2nd_ld_s3_wb {pick}")
        s3 = _gpr(pick, 19)
        lines.append(f"  s3={s3} sp={_gpr(pick, 2)}")
    else:
        s3 = None
        pick = None
    dram = None
    if alias:
        # loc= on mem lines is the 8B LE DRAM value at PA 0x80046ec8.
        pick_a = alias[-1]
        ld_t = _t(pick) if pick else None
        if ld_t is not None:
            after = [ln for ln in alias if (_t(ln) or 0) >= ld_t]
            pick_a = after[0] if after else alias[-1]
        dram = _loc(pick_a)
        lines.append(f"alias_at_ld {pick_a}")
        lines.append(f"  dram_le={dram}")
        for ln in alias:
            tt = _t(ln)
            if tt is not None and 10200 <= tt <= 10640:
                lines.append(f"  window {ln}")
    s3n = None
    try:
        if s3:
            s3n = int(s3, 16)
    except ValueError:
        pass
    dramn = None
    try:
        if dram:
            dramn = int(dram, 16)
    except ValueError:
        pass
    poison = 0x80012B2A
    lenp = 0x80046F2C
    alias_pa = 0x80046EC8
    hold = [ln for ln in extract.splitlines() if "tag=hold" in ln]
    lines[0] += f" hold_hits={len(hold)}"
    ld_t = _t(pick) if pick else None
    hold_at_ld = None
    hold_hit_fire = [ln for ln in hold if " hit=1" in ln]
    if hold and ld_t is not None:
        before = [ln for ln in hold if (_t(ln) or 0) <= ld_t]
        hold_at_ld = before[-1] if before else hold[-1]
    elif hold:
        hold_at_ld = hold[-1]
    if hold_at_ld:
        lines.append(f"hold_at_ld {hold_at_ld}")
        lines.append(
            f"  v={_field(hold_at_ld, 'v')} hit={_field(hold_at_ld, 'hit')} "
            f"pa={_field(hold_at_ld, 'pa')} data={_field(hold_at_ld, 'data')} "
            f"be={_field(hold_at_ld, 'be')}"
        )
    if hold_hit_fire:
        lines.append(f"hold_hit_fires={len(hold_hit_fire)}")
        lines.append(f"  last {hold_hit_fire[-1]}")
        alias_hits = [
            ln
            for ln in hold_hit_fire
            if _u64(_field(ln, "pa")) == alias_pa
        ]
        if alias_hits:
            lines.append(f"  alias_hit {alias_hits[-1]}")
    hv = _field(hold_at_ld, "v") if hold_at_ld else None
    hh = _field(hold_at_ld, "hit") if hold_at_ld else None
    hdata = _u64(_field(hold_at_ld, "data")) if hold_at_ld else None
    hpa = _u64(_field(hold_at_ld, "pa")) if hold_at_ld else None
    if hold_at_ld is None:
        lines.append("HOLD: no sample (TB path missing or window empty)")
    elif hv == "1" and hpa == alias_pa and hdata == poison:
        if hh == "1":
            lines.append(
                "HOLD: LIVE STALE overlay at 2nd ld s3 "
                "(v=1 hit=1 pa=alias data=0x12b2a) — hold is the load source"
            )
        else:
            lines.append(
                "HOLD: LIVE STALE at 2nd ld s3 "
                "(v=1 pa=alias data=0x12b2a hit=0) — hold armed, overlay not this cycle"
            )
    elif hv == "1" and hpa == alias_pa and hdata == lenp:
        lines.append(
            "HOLD: LIVE YOUNG (data=lenp) — overlay has the younger store; "
            "poison is not hold"
        )
    elif hv == "0":
        lines.append(
            "HOLD: DEAD at 2nd ld s3 (v=0) — overlay did not source the load; "
            "poison is L1/D$ (ACK-before-check class)"
        )
    else:
        lines.append(
            f"HOLD: inspect v={hv} hit={hh} pa={hpa} data={hdata}"
        )
    if s3n == poison and dramn is not None:
        # DRAM dump is 8B at 0x80046ec8
        lo = dramn & 0xFFFFFFFFFFFFFFFF
        dram_young = (lo & 0xFFFFFFFFFFFFFFFF) == lenp or (
            lo & 0xFFFFFFFF
        ) == (lenp & 0xFFFFFFFF)
        dram_stale = (lo & 0xFFFFFFFF) == (poison & 0xFFFFFFFF) or lo == poison
        hold_dead = hv == "0"
        if dram_young and hold_dead:
            lines.append(
                "VERDICT: L1/D$ stale (ACK-before-check); DRAM has younger store "
                "(lenp); g1ao_hold dead — not an overlay class"
            )
        elif dram_young:
            lines.append(
                "VERDICT: STQ/hold overlay of stale 0x12b2a; DRAM has younger store (lenp)"
            )
        elif dram_stale:
            lines.append(
                "VERDICT: DRAM still 0x12b2a — younger c.sdsp never visible in MEM "
                "(cancel-drop or wrong PA); not a g1ao_hold-only class"
            )
        else:
            lines.append(f"VERDICT: s3=poison dram=0x{lo:x} — inspect dump")
    elif s3n == poison:
        lines.append("VERDICT: s3=poison, no alias DRAM sample (poll floor / timing)")
    elif s3n == lenp:
        lines.append("VERDICT: 2nd ld s3 got lenp — alias pin moved")
    else:
        lines.append("VERDICT: see extract (2nd ld s3 not poison/lenp or missing)")
    hang = [ln for ln in extract.splitlines() if "[hangpc]" in ln]
    if hang:
        lines.append(f"hangpc {hang[-1]}")
        lines.append(
            f"  mepc0={_field(hang[-1], 'mepc0')} mcause0={_field(hang[-1], 'mcause0')} "
            f"mtval0={_field(hang[-1], 'mtval0')} npc0={_field(hang[-1], 'npc0')}"
        )
    wrack = [ln for ln in extract.splitlines() if "tag=wrack" in ln]
    if wrack:
        n0 = sum(1 for ln in wrack if " ack=0" in ln)
        n1 = sum(1 for ln in wrack if " ack=1" in ln)
        lines.append(f"wrack_hits={len(wrack)} ack0={n0} ack1={n1}")
        for ln in wrack:
            d = _u64(_field(ln, "data"))
            if d in (poison, lenp):
                lines.append(
                    f"  alias_data t={_t(ln)} ack={_field(ln, 'ack')} "
                    f"req={_field(ln, 'req')} data={_field(ln, 'data')}"
                )
        if n0 == 0:
            lines.append("WRACK: no denied word-write in window — nackhit had nothing to arm")
        elif any(
            _u64(_field(ln, "data")) in (poison, lenp) and _field(ln, "ack") == "0"
            for ln in wrack
        ):
            lines.append("WRACK: alias data denied — nackhit should have armed")
        else:
            lines.append("WRACK: denies exist but not poison/lenp data")
    fail = [ln for ln in extract.splitlines() if "tag=fail" in ln]
    if fail:
        lines.append(f"fail_hits={len(fail)} last {fail[-1]}")
        lines.append(f"  a0={_gpr(fail[-1], 10)} loc={_loc(fail[-1])}")
    failed = [ln for ln in extract.splitlines() if "*** FAILED ***" in ln]
    if failed:
        lines.append(failed[-1])
        if "tohost = 12" in failed[-1]:
            mepc0 = _field(hang[-1], "mepc0") if hang else None
            if mepc0 and mepc0.lower() not in ("0x80012eb2", "80012eb2"):
                lines.append(
                    "TOHOST12: mini other-trap (write 25), not pin 12eb2 / not s3"
                )
            else:
                lines.append("TOHOST12: inspect hangpc vs pin 12eb2")
    return "\n".join(lines) + "\n"


def main() -> int:
    run_dir = Path(os.environ.get("TH_RUN_DIR", "/tmp"))
    data_dir = Path(os.environ.get("TH_DATA_DIR", str(run_dir / "data")))
    out_dir = Path(os.environ.get("TH_OUT_DIR", "/tmp"))
    out_dir.mkdir(parents=True, exist_ok=True)

    elf = None
    for name in (
        "mini_fdt_nt_osbi_tight.elf",
        "mini_fdt_nt_osbi_h0.elf",
        "mini_fdt_nt_osbi.elf",
    ):
        try:
            elf = _find(data_dir, name)
            break
        except FileNotFoundError:
            pass
    if elf is None:
        raise FileNotFoundError("no mini_fdt_nt_osbi*.elf under data")
    spec = _find(data_dir, "trace-s1-nt-nl.spec")
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

    log_path = out_dir / "s1_nt_nl_trace.log"
    classify_path = out_dir / "s1_nt_nl_trace.classify.txt"

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
    extract = _extract(log_text)
    verdict = _classify_verdict(extract)
    classify_path.write_text(
        f"rc={proc.returncode}\nelf={elf}\nspec={spec}\n"
        f"time_out={time_out} tohost={tohost} soak_poll=64\n\n"
        f"{verdict}\n{extract}",
        encoding="utf-8",
    )
    print(f"rc={proc.returncode} log={log_path} classify={classify_path}")
    print(verdict)
    print(extract if extract else "(no classify hits)")
    tail = log_text[-3000:] if len(log_text) > 3000 else log_text
    print("--- log tail ---")
    print(tail)
    return 0 if proc.returncode == 0 else proc.returncode


if __name__ == "__main__":
    raise SystemExit(main())
