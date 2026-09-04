#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# bios-regress — host interface for rust-generated ZealOS:
#   fast HolyC init, DOM+JS UI boot, dual-band HolyC REPL, post-boot KVM verbs.

from __future__ import annotations

import argparse
import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

_TOOLS = Path(__file__).resolve().parent
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))

from env_common import cargo_bin, contained_env, package_root  # noqa: E402

_EXE = ".exe" if sys.platform.startswith("win") else ""


def log(msg: str) -> None:
    print(f"[bios-regress] {msg}")


def err(msg: str) -> None:
    print(f"[bios-regress] FAIL: {msg}", file=sys.stderr)


def cargo_cmd() -> str:
    contained = cargo_bin()
    if contained.is_file():
        return str(contained)
    found = shutil.which("cargo")
    return found or "cargo"


def g6b_bin() -> Path:
    return package_root() / "target" / "debug" / f"g6b{_EXE}"


def ensure_built() -> int:
    env = contained_env() if cargo_bin().is_file() else os.environ.copy()
    cmd = [cargo_cmd(), "build", "-p", "g6b-cli"]
    log("+ " + " ".join(cmd))
    return subprocess.run(cmd, cwd=str(package_root()), env=env).returncode


def run_g6b(argv: list[str], timeout: float = 60.0) -> subprocess.CompletedProcess[str]:
    cmd = [str(g6b_bin()), *argv]
    log("+ " + " ".join(cmd))
    return subprocess.run(
        cmd,
        cwd=str(package_root()),
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def case_holyc_fast_init(spec: Path) -> None:
    p = run_g6b(["holyc-eval", "--spec", str(spec)])
    if p.returncode != 0:
        raise RuntimeError(p.stderr)
    out = p.stdout
    for m in ("G6LC-BIOS", "HOLYC-READY", "UI-BOOT"):
        if m not in out:
            raise RuntimeError(f"holyc-eval missing {m}: {out!r}")


def case_dom_js_ui_boot(spec: Path) -> None:
    p = run_g6b(["boot", "--spec", str(spec)])
    if p.returncode != 0:
        raise RuntimeError(p.stderr)
    out = p.stdout
    for m in (
        "G6LC-BIOS",
        "HOLYC-READY",
        "UI-BOOT",
        "opp: idle",
        "PROXY-INIT",
        "GL-ADAPTER",
        "TLS-READY",
        "WASM-JIT",
        "SVELTE-LIVE",
        "TLS-RSA",
        "TLS-ECDSA",
        "adapter-ports",
        "HTTP-READY",
        "HTTP/1.1",
        "JS-FETCH",
        "PROFILE-full",
        "FLASH-READY",
        "SETTINGS-READY",
        "HTTPS-SERVE",
        "USB-FAT32",
        "USB-FILES fat32/ntfs/ext4",
        "SVELTE-LIVE FileMgr",
        "HOLYC-UI",
        "MENU-cpu",
        "UNCORE-PLIC",
        "CPU-SMT",
        "TIMER-READY",
        "FILES-SERVE",
        "FILES-HTML",
        "FILES-JS",
        "FILES-WASM",
        "HTTPS-FILES",
    ):
        if m not in out:
            raise RuntimeError(f"boot missing {m}: {out!r}")
    if "getElementById" in out:
        raise RuntimeError("script source leaked onto UART viewport")


def case_qemu_dual_band_args(spec: Path) -> None:
    p = run_g6b(["qemu-args", "--spec", str(spec)])
    if p.returncode != 0:
        raise RuntimeError(p.stderr)
    out = p.stdout
    if "-nographic" not in out:
        raise RuntimeError(out)
    if "-smp 2" not in out:
        raise RuntimeError(f"virt fixture must -smp 2: {out!r}")
    if "tcp:127.0.0.1:2222,server,nowait" not in out:
        raise RuntimeError(f"missing ssh-like serial: {out!r}")
    if "-netdev" in out or "virtio-net" in out:
        raise RuntimeError(f"BIOS qemu-args must not steal a NIC: {out!r}")


def _read_until(sock: socket.socket, needle: bytes, timeout: float) -> bytes:
    sock.settimeout(timeout)
    buf = b""
    deadline = time.time() + timeout
    while needle not in buf:
        if time.time() > deadline:
            raise TimeoutError(f"timeout waiting for {needle!r}, got {buf!r}")
        chunk = sock.recv(256)
        if not chunk:
            break
        buf += chunk
    return buf


def case_dual_band_repl(spec: Path) -> None:
    proc = subprocess.Popen(
        [str(g6b_bin()), "holyc-serve", "--spec", str(spec), "--port", "0", "--once"],
        cwd=str(package_root()),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    port = None
    assert proc.stderr is not None
    deadline = time.time() + 20
    buf = ""
    while time.time() < deadline and port is None:
        line = proc.stderr.readline()
        if not line:
            if proc.poll() is not None:
                break
            time.sleep(0.05)
            continue
        buf += line
        if "HOLYC-PORT" in line:
            port = int(line.split()[-1])
            break
    if port is None:
        proc.kill()
        raise RuntimeError(f"no HOLYC-PORT (stderr={buf!r} rc={proc.poll()})")
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=5) as s:
            greet = _read_until(s, b"HOLYC-REPL", 5)
            if b"G6LC-BIOS" not in greet:
                raise RuntimeError(f"bad banner {greet!r}")
            s.sendall(b'Print("PING");\n')
            reply = _read_until(s, b"PING", 5)
            if b"PING" not in reply:
                raise RuntimeError(f"no PING in {reply!r}")
            s.sendall(b"LinuxHandoff();\n")
            live = _read_until(s, b"POSTBOOT-LIVE", 5)
            if b"POSTBOOT-LIVE" not in live:
                raise RuntimeError(f"no POSTBOOT-LIVE in {live!r}")
            s.sendall(b'ViewSection("config");\n')
            view = _read_until(s, b"VIEW", 5)
            if b"VIEW config" not in view:
                raise RuntimeError(f"view failed {view!r}")
            s.sendall(b'WriteSection("config");\n')
            locked = _read_until(s, b"IMMUTABLE-DISABLED", 5)
            if b"IMMUTABLE-DISABLED" not in locked:
                raise RuntimeError(f"immutable write not disabled {locked!r}")
            s.sendall(b"Reboot();\n")
            pwr = _read_until(s, b"POWER-REBOOT", 5)
            if b"POWER-REBOOT" not in pwr:
                raise RuntimeError(f"reboot failed {pwr!r}")
            s.sendall(b"Exit;\n")
    finally:
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


def case_loopback_mbox(spec: Path) -> None:
    proc = subprocess.Popen(
        [str(g6b_bin()), "loopback", "--spec", str(spec), "--port", "0", "--once"],
        cwd=str(package_root()),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    port = None
    assert proc.stderr is not None
    deadline = time.time() + 20
    buf = ""
    while time.time() < deadline and port is None:
        line = proc.stderr.readline()
        if not line:
            if proc.poll() is not None:
                break
            time.sleep(0.05)
            continue
        buf += line
        if "LOOPBACK-PORT" in line or "HOLYC-PORT" in line:
            port = int(line.split()[-1])
            break
    if port is None:
        proc.kill()
        raise RuntimeError(f"no LOOPBACK-PORT (stderr={buf!r} rc={proc.poll()})")
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=5) as s:
            greet = _read_until(s, b"LOOPBACK-MBOX", 5)
            if b"not_netdev=1" not in greet:
                raise RuntimeError(f"loopback must declare not_netdev: {greet!r}")
            s.sendall(b"LinuxHandoff();\n")
            live = _read_until(s, b"NET-DELEGATE", 5)
            if b"POSTBOOT-LIVE" not in live or b"LOOPBACK-MBOX" not in live:
                raise RuntimeError(f"delegate/mbox missing {live!r}")
            if b"SSH-HOLYC" not in live:
                raise RuntimeError(f"ssh-holyc kvm face missing {live!r}")
            s.sendall(b'ViewSection("config");\n')
            view = _read_until(s, b"VIEW config", 5)
            if b"VIEW config" not in view:
                raise RuntimeError(f"view failed {view!r}")
            s.sendall(b"Exit;\n")
    finally:
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


def case_elf_payload(spec: Path) -> None:
    out = package_root() / "out" / "g6lc_bios.elf"
    p = run_g6b(["elf", "--spec", str(spec), "--out", str(out)])
    if p.returncode != 0:
        raise RuntimeError(p.stderr)
    data = out.read_bytes()
    if data[:4] != b"\x7fELF":
        raise RuntimeError("not ELF")
    machine = int.from_bytes(data[18:20], "little")
    if machine != 0xF3:
        raise RuntimeError(f"e_machine {machine:#x} not RISC-V")
    if b"G6LC-BIOS" not in data or b"HOLYC-READY" not in data:
        raise RuntimeError("payload missing boot markers")
    if b"KSTART-XLEN" not in data or b"KSTART-STVEC" not in data:
        raise RuntimeError("payload missing KStart RISC-V stage markers")
    if b"KSTART-TIMER" not in data:
        raise RuntimeError("payload missing KStart timer marker")
    if b"KSTART-PLIC" not in data:
        raise RuntimeError("virt fixture missing KStart PLIC marker")
    if b"KSTART-HSM" not in data:
        raise RuntimeError("virt fixture missing KStart HSM marker")
    if b"KSTART-MBOX" not in data:
        raise RuntimeError("virt fixture missing KStart mailbox marker")
    if b"KSTART-UART-IRQ" not in data:
        raise RuntimeError("payload missing KStart UART irq marker")
    if b"KSTART-UART-LINE" not in data:
        raise RuntimeError("payload missing KStart UART line marker")
    if b"KSTART-UART-CMD" not in data:
        raise RuntimeError("payload missing KStart UART cmd marker")
    if b"KSTART-UART-VIEWSEC" not in data:
        raise RuntimeError("payload missing KStart UART ViewSection marker")
    if b"KSTART-UART-UI" not in data:
        raise RuntimeError("payload missing KStart UART Ui marker")
    if b"KSTART-UART-FILE" not in data:
        raise RuntimeError("payload missing KStart UART File marker")
    if b"KSTART-UART-GET" not in data:
        raise RuntimeError("payload missing KStart UART Get marker")
    if b"KSTART-GR" not in data:
        raise RuntimeError("virt fixture missing KStart GrInit marker")
    if b"KSTART-GR-PLANE" not in data:
        raise RuntimeError("virt fixture missing KStart Gr plane marker")
    if b"KSTART-GR-FONT" not in data:
        raise RuntimeError("virt fixture missing KStart Gr font marker")
    if b"KSTART-PROXY" not in data:
        raise RuntimeError("virt fixture missing KStart display-proxy marker")
    if b"KSTART-PROXY-SCALE" not in data:
        raise RuntimeError("virt fixture missing KStart ProxyScale marker")
    if b"KSTART-UI" not in data:
        raise RuntimeError("virt fixture missing KStart UiInit marker")
    if b"KSTART-FILE" not in data:
        raise RuntimeError("virt fixture missing KStart FileServe marker")
    if b"KSTART-GET" not in data:
        raise RuntimeError("virt fixture missing KStart GetFile marker")
    if b"KSTART-WASM-JIT" not in data:
        raise RuntimeError("virt fixture missing KStart WasmJit marker")
    if b"\0asm" not in data:
        raise RuntimeError("virt fixture missing embedded bios-ui.wasm")
    if b"KSTART-STACKS-2" not in data:
        raise RuntimeError("virt fixture missing per-hart stack marker")
    if b"ISEL-SCALAR" not in data:
        raise RuntimeError("virt fixture must ISel scalar (v not live)")
    ehsize = 64 if data[4] == 2 else 52
    if data[4] == 2:
        filesz = int.from_bytes(data[ehsize + 32 : ehsize + 40], "little")
        memsz = int.from_bytes(data[ehsize + 40 : ehsize + 48], "little")
    else:
        filesz = int.from_bytes(data[ehsize + 16 : ehsize + 20], "little")
        memsz = int.from_bytes(data[ehsize + 20 : ehsize + 24], "little")
    if memsz < filesz + 2 * 0x8000:
        raise RuntimeError(f"p_memsz {memsz} too small for 2 hart stacks (filesz={filesz})")
    # 640×480×4bpp plane + 64-byte GR16 header + UART line + G6UI header after stacks
    if memsz < filesz + 2 * 0x8000 + 64 + (640 * 480) // 2 + 132 + 32:
        raise RuntimeError(
            f"p_memsz {memsz} too small for GR plane + UART line + G6UI (filesz={filesz})"
        )


def case_elf_smoke(spec: Path) -> None:
    p = run_g6b(["smoke", "--spec", str(spec)])
    if p.returncode != 0:
        raise RuntimeError(p.stderr or p.stdout)
    out = p.stdout
    for m in (
        "KSTART-SATP-BARE",
        "KSTART-UART0",
        "KSTART-UART0-8N1",
        "KSTART-TIMER",
        "KSTART-STACKS-2",
        "KSTART-UI",
        "KSTART-FILE",
        "KSTART-GET",
        "KSTART-PROXY-SCALE",
        "FILE",
        "GET /ui/ui.wasm",
        "/ui/ui.wasm",
        "G6LC-BIOS",
        "KMAIN",
    ):
        if m not in out:
            raise RuntimeError(f"smoke missing {m}: {out!r}")
    if "CR3" in out or "EFER" in out:
        raise RuntimeError(f"x86 needle in smoke console: {out!r}")


def case_gr_framebuffer(spec: Path) -> None:
    p = run_g6b(["boot", "--spec", str(spec)])
    if p.returncode != 0:
        raise RuntimeError(p.stderr)
    if "GR-INIT 640x480x16" not in p.stdout:
        raise RuntimeError(f"missing GR-INIT: {p.stdout!r}")
    qa = run_g6b(["qemu-args", "--spec", str(spec)])
    if "virtio-gpu-device" not in qa.stdout:
        raise RuntimeError(f"missing virtio-gpu: {qa.stdout!r}")
    if "virtio-net" in qa.stdout:
        raise RuntimeError("gpu path must not add virtio-net")
    ppm_path = package_root() / "out" / "setup.ppm"
    g = run_g6b(["gr", "--spec", str(spec), "--out", str(ppm_path)])
    if g.returncode != 0:
        raise RuntimeError(g.stderr)
    data = ppm_path.read_bytes()
    if not data.startswith(b"P6\n640 480\n255\n"):
        raise RuntimeError(f"bad ppm header {data[:32]!r}")
    proxy_path = package_root() / "out" / "proxy.ppm"
    px = run_g6b(["display-proxy", "--spec", str(spec), "--out", str(proxy_path)])
    if px.returncode != 0:
        raise RuntimeError(px.stderr)
    pdata = proxy_path.read_bytes()
    if not pdata.startswith(b"P6\n1920 1080\n255\n"):
        raise RuntimeError(f"bad proxy ppm header {pdata[:32]!r}")
    if "PROXY-INIT" not in p.stdout:
        raise RuntimeError(f"missing PROXY-INIT: {p.stdout!r}")
    if "TIMER-READY" not in p.stdout:
        raise RuntimeError(f"missing TIMER-READY: {p.stdout!r}")


def case_boot_sideband(spec: Path) -> None:
    p = run_g6b(["boot", "--spec", str(spec)])
    if p.returncode != 0:
        raise RuntimeError(p.stderr)
    out = p.stdout
    if "loopback mbox" not in out:
        raise RuntimeError(f"missing loopback: {out!r}")
    if "net-expose until-delegate" not in out:
        raise RuntimeError(f"missing nic until-delegate: {out!r}")
    if "ssh-holyc" not in out:
        raise RuntimeError(f"missing ssh-holyc kvm face: {out!r}")


def main() -> int:
    ap = argparse.ArgumentParser(prog="bios-regress")
    ap.add_argument("--spec")
    args = ap.parse_args()
    spec = Path(args.spec) if args.spec else package_root() / "fixtures" / "g6lc64-virt.json"
    if ensure_built() != 0:
        err("cargo build -p g6b-cli")
        return 1
    if not g6b_bin().is_file():
        err(f"missing {g6b_bin()}")
        return 1
    cases = [
        ("holyc_fast_init", case_holyc_fast_init),
        ("dom_js_ui_boot", case_dom_js_ui_boot),
        ("qemu_dual_band_args", case_qemu_dual_band_args),
        ("dual_band_repl_postboot", case_dual_band_repl),
        ("loopback_mbox", case_loopback_mbox),
        ("boot_sideband", case_boot_sideband),
        ("elf_payload", case_elf_payload),
        ("elf_smoke", case_elf_smoke),
        ("gr_framebuffer", case_gr_framebuffer),
    ]
    failed = []
    for name, fn in cases:
        log(f"--- {name} ---")
        try:
            fn(spec)
            log(f"PASS {name}")
        except Exception as e:  # noqa: BLE001 — surface the case error
            err(f"{name}: {e}")
            failed.append(name)
    if failed:
        err("FAILED: " + ", ".join(failed))
        return 1
    log("bios-regress OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
