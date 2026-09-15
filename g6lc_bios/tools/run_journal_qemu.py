#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Build the journal BIOS, plant a G6BH window, QEMU-prove JrnLoad/JrnCommit.
# Missing QEMU is blocked, not PASS.

from __future__ import annotations

import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time

_TOOLS = Path(__file__).resolve().parent
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))

from env_common import cargo_bin, contained_env, package_root  # noqa: E402
from journal_disk import make_disk, verify_disk

ROOT = package_root()
SPEC = ROOT / "fixtures" / "g6lc64-journal.json"


def log(msg: str) -> None:
    print(f"[journal-qemu] {msg}", flush=True)


def cargo_run_elf(elf: Path) -> None:
    contained = cargo_bin()
    env = contained_env() if contained.is_file() else os.environ.copy()
    cmd = [str(contained) if contained.is_file() else (shutil.which("cargo") or "cargo")]
    argv = cmd + [
        "run",
        "-p",
        "g6b-cli",
        "--",
        "elf",
        "--spec",
        str(SPEC),
        "--out",
        str(elf),
    ]
    log("+ " + " ".join(argv))
    result = subprocess.run(argv, cwd=str(ROOT), env=env)
    if result.returncode:
        raise RuntimeError("g6b elf failed")


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


def run_qemu(elf: Path, disk: Path, out: Path) -> None:
    qemu = qemu_cmd()
    if qemu is None:
        raise RuntimeError("blocked: qemu-system-riscv64 not available")
    out.mkdir(parents=True, exist_ok=True)
    work = disk.with_name(disk.stem + ".live.img")
    shutil.copy2(disk, work)
    log_path = out / "journal.serial.log"
    qemu_log = out / "journal.qemu.log"
    if qemu[0].lower().endswith("wsl.exe") or qemu[0] == "wsl":
        script = to_wsl(_TOOLS / "qemu_journal.sh")
        inner = f"bash {script} {to_wsl(elf)} {to_wsl(work)} {to_wsl(out)} 30"
        argv = qemu + [inner]
        log("+ " + " ".join(argv))
        result = subprocess.run(argv, cwd=str(ROOT), timeout=90)
        if result.returncode:
            raise RuntimeError("qemu_journal.sh failed")
        after = out / f"{elf.stem}.disk.img"
        if not after.is_file():
            raise RuntimeError(f"qemu did not return a disk image at {after}")
        verify_disk(after)
        shutil.copy2(after, out / "journal.after.img")
        return
    ser = 2450
    argv = [
        qemu[0],
        "-M",
        "virt",
        "-m",
        "256",
        "-nographic",
        "-monitor",
        "none",
        "-global",
        "virtio-mmio.force-legacy=false",
        "-serial",
        f"tcp:127.0.0.1:{ser},server,nowait",
        "-device",
        "virtio-gpu-device",
        "-drive",
        f"file={work},format=raw,if=none,id=blk0",
        "-device",
        "virtio-blk-device,drive=blk0",
        "-kernel",
        str(elf),
    ]
    log("+ " + " ".join(argv))
    proc = subprocess.Popen(argv, cwd=str(ROOT), stdout=qemu_log.open("w"), stderr=subprocess.STDOUT)
    try:
        time.sleep(2)
        sock = socket.create_connection(("127.0.0.1", ser), timeout=10)
        sock.settimeout(20)
        time.sleep(6)
        sock.sendall(b"Jrn\n")
        time.sleep(8)
        try:
            text = sock.recv(65536).decode("utf-8", "replace")
        except OSError:
            text = ""
        sock.close()
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
    log_path.write_text(text, encoding="utf-8")
    if "JRN-LOAD-OK" not in text or "JRN-COMMIT-OK" not in text:
        raise RuntimeError("serial missing JRN markers:\n" + text[-2000:])
    verify_disk(work)
    shutil.copy2(work, out / "journal.after.img")


def main() -> int:
    out = ROOT / "out" / "journal"
    out.mkdir(parents=True, exist_ok=True)
    disk = out / "journal.img"
    elf = out / "g6lc_bios-journal.elf"
    try:
        make_disk(disk)
        verify_disk(disk)
        cargo_run_elf(elf)
        run_qemu(elf, disk, out)
        log("JRN-LOAD-OK JRN-COMMIT-OK disk CRC still G6BH")
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        log(f"FAIL: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
