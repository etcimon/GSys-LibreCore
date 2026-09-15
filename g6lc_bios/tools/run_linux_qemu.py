#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Plant a canary RISC-V Image on the journal disk and QEMU-prove UART `Lnx`.
# Missing QEMU is blocked, not PASS.

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys

_TOOLS = Path(__file__).resolve().parent
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))

from env_common import cargo_bin, contained_env, package_root  # noqa: E402
from journal_disk import make_disk, verify_disk

ROOT = package_root()
SPEC = ROOT / "fixtures" / "g6lc64-journal.json"


def log(msg: str) -> None:
    print(f"[linux-qemu] {msg}", flush=True)


def cargo(args: list[str]) -> None:
    contained = cargo_bin()
    env = contained_env() if contained.is_file() else os.environ.copy()
    cmd = [str(contained) if contained.is_file() else (shutil.which("cargo") or "cargo")]
    argv = cmd + ["run", "-p", "g6b-cli", "--"] + args
    log("+ " + " ".join(argv))
    result = subprocess.run(argv, cwd=str(ROOT), env=env)
    if result.returncode:
        raise RuntimeError(" ".join(args) + " failed")


def qemu_cmd() -> list[str] | None:
    exe = shutil.which("qemu-system-riscv64")
    if exe:
        return [exe]
    wsl = shutil.which("wsl")
    if not wsl:
        return None
    probe = subprocess.run(
        [wsl, "-e", "bash", "-lc", "command -v qemu-system-riscv64 || test -x /usr/bin/qemu-system-riscv64 && echo /usr/bin/qemu-system-riscv64"],
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    path = (probe.stdout or "").strip().splitlines()[-1] if probe.returncode == 0 else ""
    if not path:
        return None
    return [wsl, "-e", "bash", "-lc"]


def to_wsl(path: Path) -> str:
    s = str(path.resolve()).replace("\\", "/")
    if len(s) >= 2 and s[1] == ":":
        return f"/mnt/{s[0].lower()}{s[2:]}"
    return s


def main() -> int:
    out = ROOT / "out" / "linux"
    out.mkdir(parents=True, exist_ok=True)
    disk = out / "linux.img"
    elf = out / "g6lc_bios-linux.elf"
    try:
        make_disk(disk)
        cargo(["canary-disk", "--disk", str(disk)])
        cargo(["arm-disk", "--disk", str(disk)])
        cargo(["elf", "--spec", str(SPEC), "--out", str(elf)])
        qemu = qemu_cmd()
        if qemu is None:
            raise RuntimeError("blocked: qemu-system-riscv64 not available")
        work = disk.with_name(disk.stem + ".live.img")
        shutil.copy2(disk, work)
        if qemu[0].lower().endswith("wsl.exe") or qemu[0] == "wsl":
            inner = f"bash {to_wsl(_TOOLS / 'qemu_linux.sh')} {to_wsl(elf)} {to_wsl(work)} {to_wsl(out)} 40"
            argv = qemu + [inner]
            log("+ " + " ".join(argv))
            result = subprocess.run(argv, cwd=str(ROOT), timeout=120)
            if result.returncode:
                raise RuntimeError("qemu_linux.sh failed")
        else:
            raise RuntimeError("native qemu_linux path not wired; use WSL")
        verify_disk(disk)
        log("LINUX-ENTRY-OK (canary Image from disk; journal/firmware stubs intact)")
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        log(f"FAIL: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
