#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Build the labelled callee ELF, compose it into the BIOS, and optionally
# prove NATIVE-SERVICE-OK and NATIVE-POLL-OK under QEMU. Missing QEMU is blocked, not PASS.

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

_TOOLS = Path(__file__).resolve().parent
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))

from env_common import cargo_bin, contained_env, package_root  # noqa: E402
from guest_native import build as build_native

ROOT = package_root()
SPEC = ROOT / "fixtures" / "g6lc64-native-services.json"
LOAD = 0x84000000


def log(msg: str) -> None:
    print(f"[native-service] {msg}", flush=True)


def cargo() -> list[str]:
    contained = cargo_bin()
    env = contained_env() if contained.is_file() else os.environ.copy()
    cmd = [str(contained) if contained.is_file() else (shutil.which("cargo") or "cargo")]
    return cmd, env


def compose(manifest: Path, out_elf: Path) -> None:
    cmd, env = cargo()
    argv = cmd + [
        "run",
        "-p",
        "g6b-cli",
        "--",
        "elf",
        "--spec",
        str(SPEC),
        "--native-manifest",
        str(manifest),
        "--out",
        str(out_elf),
    ]
    log("+ " + " ".join(argv))
    result = subprocess.run(argv, cwd=str(ROOT), env=env)
    if result.returncode:
        raise RuntimeError("g6b elf --native-manifest failed")


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


def to_wsl_path(path: Path) -> str:
    s = str(path.resolve()).replace("\\", "/")
    if len(s) >= 2 and s[1] == ":":
        return f"/mnt/{s[0].lower()}{s[2:]}"
    return s


def run_qemu(elf: Path, out: Path) -> str:
    out.mkdir(parents=True, exist_ok=True)
    qemu = qemu_cmd()
    if qemu is None:
        return "blocked: qemu-system-riscv64 not available"
    log_path = out / "native-service.serial.log"
    qemu_log = out / "native-service.qemu.log"
    if qemu[0].lower().endswith("wsl.exe") or qemu[0] == "wsl":
        wsl_elf = to_wsl_path(elf)
        wsl_log = to_wsl_path(log_path)
        wsl_qlog = to_wsl_path(qemu_log)
        inner = (
            f'timeout --foreground 20 qemu-system-riscv64 -M virt -m 256 -nographic '
            f'-monitor none -serial file:{wsl_log} -kernel {wsl_elf} '
            f'> {wsl_qlog} 2>&1 || true'
        )
        argv = qemu + [inner]
    else:
        argv = [
            qemu[0],
            "-M",
            "virt",
            "-m",
            "256",
            "-nographic",
            "-monitor",
            "none",
            "-serial",
            f"file:{log_path}",
            "-kernel",
            str(elf),
        ]
    log("+ " + " ".join(argv))
    subprocess.run(argv, cwd=str(ROOT), timeout=40)
    text = log_path.read_text(encoding="utf-8", errors="replace") if log_path.is_file() else ""
    if "NATIVE-SERVICE-FAIL" in text:
        raise RuntimeError("QEMU serial contains NATIVE-SERVICE-FAIL")
    if "NATIVE-SERVICE-OK" not in text:
        raise RuntimeError("QEMU serial missing NATIVE-SERVICE-OK:\n" + text[-2000:])
    if "NATIVE-POLL-OK" not in text:
        raise RuntimeError("QEMU serial missing NATIVE-POLL-OK:\n" + text[-2000:])
    if "NATIVE-BOOT-HOLD" not in text:
        raise RuntimeError("QEMU serial missing NATIVE-BOOT-HOLD:\n" + text[-2000:])
    return "NATIVE-SERVICE-OK NATIVE-POLL-OK NATIVE-BOOT-HOLD"


def main() -> int:
    parser = argparse.ArgumentParser(description="Build, compose, and optionally QEMU-prove the native service callee")
    parser.add_argument("--out", type=Path, default=ROOT / "out" / "native")
    parser.add_argument("--skip-qemu", action="store_true")
    args = parser.parse_args()
    try:
        manifest = build_native(args.out.resolve(), LOAD)
        log(f"wrote {manifest}")
        report = json.loads(manifest.read_text(encoding="utf-8"))
        if report.get("role") != "native-service-callee-not-bootable-firmware":
            raise RuntimeError("manifest role is not the service callee label")
        elf = args.out / "g6lc_bios-native.elf"
        compose(manifest, elf)
        log(f"composed {elf}")
        if args.skip_qemu:
            log("QEMU skipped")
            return 0
        status = run_qemu(elf, args.out)
        log(status)
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        log(f"FAIL: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
