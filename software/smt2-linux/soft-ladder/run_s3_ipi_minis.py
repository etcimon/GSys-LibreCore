#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Compile and run SL-C IPI vs no-IPI hart1 SP minis."""
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
    repo = Path(os.environ.get("TH_REPO", "/opt/testharness/repo"))
    gcc = os.environ.get(
        "TH_GCC",
        "/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-gcc",
    )
    nm = str(Path(gcc).with_name("riscv-none-elf-nm"))
    harness = os.environ.get(
        "TH_HARNESS",
        "/opt/testharness/work/work-ver-smt2-fw64-B/Variane_testharness",
    )
    ld = repo / "verif/tests/custom/common/link_verilator.ld"
    common = repo / "verif/tests/custom/common"
    env_inc = repo / "verif/tests/custom/env"
    time_out = os.environ.get("TH_TIME_OUT", "80000")
    env = dict(os.environ)
    env["CVA6_TRAP_DUMP"] = "1"
    env["CVA6_SOAK_EXIT"] = "1"
    env["CVA6_COOKIE_EXIT"] = "0"
    env["CVA6_WFI_EXIT"] = "0"

    names = (
        "mini_ipi_hart1_sp.S",
        "mini_wfi_noipi_hart1.S",
    )
    lines: list[str] = []
    for src_name in names:
        src = _find(data_dir, src_name)
        stem = src.stem
        elf = out_dir / f"{stem}.elf"
        subprocess.run(
            [
                gcc,
                "-static",
                "-mcmodel=medany",
                "-fvisibility=hidden",
                "-nostdlib",
                "-nostartfiles",
                f"-I{env_inc}",
                f"-I{common}",
                str(src),
                "-T",
                str(ld),
                "-o",
                str(elf),
                "-march=rv64imafdc_zicsr_zifencei",
                "-mabi=lp64d",
            ],
            check=True,
        )
        nm_out = subprocess.check_output([nm, str(elf)], text=True)
        tohost = "0x80001000"
        for ln in nm_out.splitlines():
            parts = ln.split()
            if len(parts) >= 3 and parts[-1] == "tohost":
                tohost = "0x" + parts[0]
                break
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
        (out_dir / f"{stem}.log").write_text(text, encoding="utf-8")
        keys = (
            "SUCCESS",
            "FAILED",
            "tohost",
            "[hangpc]",
            "[trapdump]",
            "rvfi",
            "Simulation terminated",
        )
        hit = [ln for ln in text.splitlines() if any(k in ln for k in keys)]
        block = (
            f"=== {stem} rc={proc.returncode} tohost={tohost} to={time_out}\n"
            + "\n".join(hit[:24])
        )
        lines.append(block)
        print(block)

    (out_dir / "s3_ipi.classify.txt").write_text("\n\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
