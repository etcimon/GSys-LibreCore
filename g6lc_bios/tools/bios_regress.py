#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# bios-regress — host interface for rust-generated ZealOS:
#   fast HolyC init, DOM+JS UI boot, dual-band HolyC REPL, post-boot KVM verbs.

from __future__ import annotations

import argparse
from contextlib import contextmanager
import json
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
        "Setting Value Access",
        "Read-only",
        "WASM-INTERPRETER _start",
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
    if "BROWSER-ERROR" in out:
        raise RuntimeError("browser fell back after a runtime error")


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


@contextmanager
def _http_server(spec: Path):
    proc = subprocess.Popen(
        [str(g6b_bin()), "http-serve", "--spec", str(spec), "--port", "0"],
        cwd=str(package_root()),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        assert proc.stderr is not None
        line = proc.stderr.readline()
        if not line.startswith("HTTP-PORT "):
            raise RuntimeError(f"no HTTP-PORT: {line!r}")
        yield int(line.split()[-1])
    finally:
        proc.terminate()
        try:
            proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate(timeout=5)


def _socket_response(sock: socket.socket) -> bytes:
    deadline = time.monotonic() + 3
    response = bytearray()
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("HTTP response deadline exceeded")
        sock.settimeout(remaining)
        chunk = sock.recv(8192)
        if not chunk:
            return bytes(response)
        response.extend(chunk)
        if len(response) > 2 * 1024 * 1024:
            raise RuntimeError("HTTP response exceeds host regression limit")


def _http_response(sock: socket.socket) -> tuple[dict[str, str], bytes]:
    head, body = _socket_response(sock).split(b"\r\n\r\n", 1)
    lines = head.decode("ascii").split("\r\n")
    if lines[0] != "HTTP/1.1 200 OK":
        raise RuntimeError(f"HTTP status: {lines[0]}")
    headers = dict((k.lower(), v.strip()) for k, v in (s.split(":", 1) for s in lines[1:]))
    if int(headers["content-length"]) != len(body):
        raise RuntimeError("truncated HTTP body")
    return headers, body


def _http_get(port: int, path: str) -> tuple[dict[str, str], bytes]:
    with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
        sock.sendall(f"GET {path} HTTP/1.1\r\nHost: localhost\r\n\r\n".encode("ascii"))
        return _http_response(sock)


def case_http_fragmented_headers(spec: Path) -> None:
    with _http_server(spec) as port:
        with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
            sock.sendall(b"GET /bios/menu HTTP/1.1\r\nHost: local")
            sock.settimeout(0.1)
            try:
                early = sock.recv(1)
            except TimeoutError:
                pass
            else:
                raise RuntimeError(f"server closed/responded before header end: {early!r}")
            sock.sendall(b"host\r\nContent-Length: 4\r\n\r\nAB")
            try:
                early = sock.recv(1)
            except TimeoutError:
                pass
            else:
                raise RuntimeError(f"server closed/responded before body end: {early!r}")
            sock.sendall(b"CD")
            _, body = _http_response(sock)
            if not json.loads(body)["menus"]:
                raise RuntimeError("missing shared menus")


def case_http_idle_preconnection(spec: Path) -> None:
    with _http_server(spec) as port:
        with socket.create_connection(("127.0.0.1", port), timeout=3):
            _, body = _http_get(port, "/bios/menu")
            if not json.loads(body)["menus"]:
                raise RuntimeError("idle preconnection blocked shared menus")


def case_http_shared_ui(spec: Path) -> None:
    with _http_server(spec) as port:
        _, listing = _http_get(port, "/bios/www")
        root = json.loads(listing)["root"].rstrip("/")
        headers, page = _http_get(port, "/")
        if headers["content-type"].split(";")[0] != "text/html":
            raise RuntimeError("shared page is not HTML")
        if headers.get("connection") != "close":
            raise RuntimeError("one-request adapter must advertise Connection: close")
        _, index = _http_get(port, root + "/index.html")
        if index != page or b'id="menu-cpu"' not in page:
            raise RuntimeError("root and mounted page must share setup menus")
        headers, app = _http_get(port, root + "/app.js")
        if headers["content-type"].split(";")[0] != "application/javascript":
            raise RuntimeError("native app has incorrect MIME type")
        if b"createWasmHost" not in app or b"declare const kernel" in app:
            raise RuntimeError("served app is not the native browser adapter")
        headers, wasm = _http_get(port, root + "/ui.wasm")
        if headers["content-type"] != "application/wasm" or not wasm.startswith(b"\0asm\1\0\0\0"):
            raise RuntimeError("invalid browser WASM response")
        headers, body = _http_get(port, "/bios/menu")
        if headers["content-type"] != "application/json":
            raise RuntimeError("menu index has incorrect MIME type")
        for menu in json.loads(body)["menus"]:
            _, body = _http_get(port, "/bios/menu/" + menu["id"])
            detail = json.loads(body)
            if detail["id"] != menu["id"] or not detail["items"]:
                raise RuntimeError(f"missing menu detail: {menu['id']}")


def case_http_standalone_frames(spec: Path) -> None:
    path = b"/bios/menu"
    block = b"\x82\x04" + bytes([len(path)]) + path
    h2 = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" + len(block).to_bytes(3, "big")
    h2 += b"\x01\x05\0\0\0\x01" + block
    h1 = b"GET /bios/menu HTTP/1.1\r\nHost: localhost\r\n\r\n"
    with _http_server(spec) as port:
        for inner in (h1, h2):
            for wrapped in (False, True):
                request = (
                    b"\x17\x03\x03" + len(inner).to_bytes(2, "big") + inner
                    if wrapped else inner
                )
                with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
                    sock.sendall(request[:1])
                    time.sleep(0.02)
                    sock.sendall(request[1:])
                    response = _socket_response(sock)
                if wrapped:
                    if (
                        response[:3] != b"\x17\x03\x03"
                        or int.from_bytes(response[3:5], "big") != len(response) - 5
                    ):
                        raise RuntimeError("invalid standalone TLS application record")
                    response = response[5:]
                if b'"menus":[' not in response:
                    raise RuntimeError("standalone HTTP/TLS frame lost menu response")
        hello = b"\x03\x03" + bytes(32) + b"\0\0\x02\0\x3c\x01\0"
        handshake = b"\x01" + len(hello).to_bytes(3, "big") + hello
        record = b"\x16\x03\x03" + len(handshake).to_bytes(2, "big") + handshake
        with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
            sock.sendall(record[:6])
            time.sleep(0.02)
            sock.sendall(record[6:])
            response = _socket_response(sock)
        if (
            response[:3] != b"\x16\x03\x03"
            or int.from_bytes(response[3:5], "big") != len(response) - 5
            or response[5:6] != b"\x02"
        ):
            raise RuntimeError("standalone ClientHello lost ServerHello record")


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
    # proxy.gl → virgl GL device + EGL display; the 2D device is the
    # documented --no-gl fallback for hosts without a DRM render node.
    if "virtio-gpu-gl-device" not in qa.stdout and "virtio-gpu-device" not in qa.stdout:
        raise RuntimeError(f"missing virtio-gpu: {qa.stdout!r}")
    if "virtio-net" in qa.stdout:
        raise RuntimeError("gpu path must not add virtio-net")
    qa2 = run_g6b(["qemu-args", "--spec", str(spec), "--no-gl", "--vnc", "9"])
    if "virtio-gpu-device" not in qa2.stdout:
        raise RuntimeError(f"--no-gl must fall back to the 2D device: {qa2.stdout!r}")
    if "virtio-gpu-gl" in qa2.stdout or "-display egl-headless" in qa2.stdout:
        raise RuntimeError(f"--no-gl must drop the GL display/device: {qa2.stdout!r}")
    if "-vnc 127.0.0.1:9" not in qa2.stdout:
        raise RuntimeError(f"--vnc must emit the VNC frontend: {qa2.stdout!r}")
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


def case_disp_scan(_spec: Path) -> None:
    # Native uncore display engine — the `display`-class peripheral selects
    # the MMIO scanout contract (architecture/uncore/hdmi-display.md); no
    # virtio transport is emitted for it.
    hdmi = package_root() / "fixtures" / "g6lc64-hdmi.json"
    p = run_g6b(["smoke", "--spec", str(hdmi)])
    if p.returncode != 0:
        raise RuntimeError(p.stderr or p.stdout)
    out = p.stdout
    if "DISP-OK" not in out:
        raise RuntimeError(f"missing DISP-OK (display-engine commit): {out!r}")
    if "DISP-FAIL" in out:
        raise RuntimeError(f"display-engine commit failed: {out!r}")
    if "VIRTIO" in out:
        raise RuntimeError(f"hdmi board must not emit virtio display: {out!r}")


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
        ("http_fragmented_headers", case_http_fragmented_headers),
        ("http_idle_preconnection", case_http_idle_preconnection),
        ("http_shared_ui", case_http_shared_ui),
        ("http_standalone_frames", case_http_standalone_frames),
        ("dual_band_repl_postboot", case_dual_band_repl),
        ("loopback_mbox", case_loopback_mbox),
        ("boot_sideband", case_boot_sideband),
        ("elf_payload", case_elf_payload),
        ("elf_smoke", case_elf_smoke),
        ("gr_framebuffer", case_gr_framebuffer),
        ("disp_scan", case_disp_scan),
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
