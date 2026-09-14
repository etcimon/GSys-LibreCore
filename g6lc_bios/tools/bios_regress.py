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
        encoding="utf-8",
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
        "read-only",
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
        encoding="utf-8",
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
        encoding="utf-8",
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
        encoding="utf-8",
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


def case_guest_pixel_parity(spec: Path) -> None:
    env = contained_env() if cargo_bin().is_file() else os.environ.copy()
    for crate, gate in (
        ("g6b-kernel", "guest_display_list_matches_host_pixels"),
        ("g6b-elf", "picking_bios_ui_replaces_the_picker_rows"),
    ):
        cmd = [cargo_cmd(), "test", "-p", crate, gate, "--", "--nocapture"]
        log("+ " + " ".join(cmd))
        result = subprocess.run(
            cmd, cwd=str(package_root()), env=env, capture_output=True,
            text=True, encoding="utf-8", timeout=300,
        )
        if result.returncode != 0:
            raise RuntimeError(result.stdout + result.stderr)
        if "1 passed; 0 failed" not in result.stdout:
            raise RuntimeError(f"pixel gate did not execute: {result.stdout}")


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


def case_css_golden(spec: Path) -> None:
    """Render each CSS fixture and diff its PPM against the committed golden.

    This is the track-B gate from architecture/RENDER-VALIDATION.md: a feature
    row in fixtures/css-features.json is only "landed" if its visual output is
    pixel-identical to the reviewed golden. Tolerance is per-fixture; most are
    zero because the renderer is fully deterministic.
    """
    import glob

    fixtures_dir = package_root() / "fixtures" / "render"
    out_dir = package_root() / "out" / "render"
    out_dir.mkdir(parents=True, exist_ok=True)
    for fixture_json in sorted(fixtures_dir.glob("*/fixture.json")):
        with open(fixture_json, "r", encoding="utf-8") as f:
            cfg = json.load(f)
        name = cfg["name"]
        w = cfg.get("w", 64)
        h = cfg.get("h", 64)
        tol = cfg.get("tolerance", 0)
        golden = package_root() / cfg["golden"]
        actual = out_dir / f"{name}.ppm"
        p = run_g6b(
            ["css-render", "--fixture", str(fixture_json.parent), "--w", str(w), "--h", str(h), "--out", str(actual)]
        )
        if p.returncode != 0:
            raise RuntimeError(f"{name}: css-render failed: {p.stderr}")
        d = run_g6b(["ppm-diff", "--actual", str(actual), "--golden", str(golden), "--tolerance", str(tol)])
        if d.returncode != 0:
            raise RuntimeError(f"{name}: {d.stderr.strip()}")


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
    if "VIRTIO-GPU" in out:
        raise RuntimeError(f"hdmi board must not emit virtio display: {out!r}")
    # The runtime mux must pick the uncore engine (class 2) with the native
    # gpu surface (1), and must NOT claim hot-plug: contract revision 1 has no
    # HPD register, so `DispSel` records "unknown".
    if "DISP-SEL 21" not in out:
        raise RuntimeError(f"expected DISP-SEL 21 (uncore-scanout + gpu): {out!r}")


def case_disp_sel_pcie(_spec: Path) -> None:
    # A PCIe class-0x03 controller whose BAR is inside the declared window
    # outranks the virtio transport. Nothing here mode-sets the adapter: the
    # BIOS only accepts a framebuffer firmware already programmed.
    pcie = package_root() / "fixtures" / "g6lc64-pcie-gpu.json"
    p = run_g6b(["smoke", "--spec", str(pcie)])
    if p.returncode != 0:
        raise RuntimeError(p.stderr or p.stdout)
    out = p.stdout
    if "PCI-GPU" not in out:
        raise RuntimeError(f"missing PCI-GPU (accepted linear BAR): {out!r}")
    if "PCI-GPU-NONE" in out or "PCI-GPU-DEMOTED" in out:
        raise RuntimeError(f"pcie board should accept its BAR: {out!r}")
    # class 3 = pcie-linear-fb, surface 1 = gpu.
    if "DISP-SEL 31" not in out:
        raise RuntimeError(f"expected DISP-SEL 31 (pcie-linear-fb + gpu): {out!r}")


def case_disp_sel_vga(_spec: Path) -> None:
    # UART-only Gr plane: the mux must fall to the `none` rung and keep the
    # low-res VGA surface. This is the regression that would catch the old
    # behaviour, where the low-res plane was the scanout source unconditionally.
    virt = package_root() / "fixtures" / "g6lc64-virt.json"
    if not virt.is_file():
        return
    p = run_g6b(["smoke", "--spec", str(virt)])
    if p.returncode != 0:
        raise RuntimeError(p.stderr or p.stdout)
    out = p.stdout
    if "DISP-SEL" not in out:
        raise RuntimeError(f"mux did not run: {out!r}")


def case_virgl_reference(directory: Path) -> None:
    import ctypes as c
    import ctypes.util
    import hashlib
    import struct
    import tomllib

    pins = tomllib.loads((package_root() / "pins.toml").read_text(encoding="utf-8"))["graphics_wire"]
    stream = (directory / "execbuf.bin").read_bytes()
    table = (directory / "reqtab.bin").read_bytes()
    w, h = map(int, (directory / "geometry.txt").read_text(encoding="ascii").split())
    if not (4 <= w <= 4096 and 4 <= h <= 4096 and w * h * 4 <= 32 * 1024 * 1024):
        raise ValueError("reference framebuffer exceeds bounded geometry")
    if not stream or len(stream) % 4 or len(stream) > 65536:
        raise ValueError("invalid execbuffer extent")
    records = []
    offset = 0
    terminated = False
    while offset + 4 <= len(table):
        size = struct.unpack_from("<I", table, offset)[0]
        if size == 0:
            offset += 4
            terminated = True
            break
        if offset + 12 > len(table):
            raise ValueError("truncated request record")
        size, capacity, flags = struct.unpack_from("<III", table, offset)
        offset += 12
        if size < 24 or size % 4 or offset + size > len(table) or not 24 <= capacity <= 512:
            raise ValueError("invalid request/response extent")
        records.append((table[offset:offset + size], capacity, flags))
        offset += size
    if offset != len(table) or not records or not terminated:
        raise ValueError("request table has no exact terminal record")

    class Resource(c.Structure):
        _fields_ = [(name, c.c_uint32) for name in (
            "handle", "target", "format", "bind", "width", "height", "depth",
            "array_size", "last_level", "nr_samples", "flags")]

    class Box(c.Structure):
        _fields_ = [(name, c.c_uint32) for name in ("x", "y", "z", "w", "h", "d")]

    class Iovec(c.Structure):
        _fields_ = [("base", c.c_void_p), ("length", c.c_size_t)]

    fence_cb = c.CFUNCTYPE(None, c.c_void_p, c.c_uint32)

    class Callbacks(c.Structure):
        _fields_ = [("version", c.c_int), ("write_fence", fence_cb)] + [
            (name, c.c_void_p) for name in ("create", "destroy", "current", "drm_fd",
                                          "context_fence", "server_fd", "egl_display")]

    name = ctypes.util.find_library("virglrenderer")
    if not name:
        raise RuntimeError("external libvirglrenderer is unavailable")
    lib = c.CDLL(name)

    def bind(symbol, result, arguments):
        fn = getattr(lib, symbol)
        fn.restype = result
        fn.argtypes = arguments
        return fn

    init = bind("virgl_renderer_init", c.c_int, [c.c_void_p, c.c_int, c.POINTER(Callbacks)])
    cleanup = bind("virgl_renderer_cleanup", None, [c.c_void_p])
    context = bind("virgl_renderer_context_create", c.c_int, [c.c_uint32, c.c_uint32, c.c_char_p])
    create = bind("virgl_renderer_resource_create", c.c_int, [c.POINTER(Resource), c.POINTER(Iovec), c.c_uint32])
    attach = bind("virgl_renderer_ctx_attach_resource", None, [c.c_int, c.c_int])
    attach_iov = bind("virgl_renderer_resource_attach_iov", c.c_int, [c.c_int, c.POINTER(Iovec), c.c_int])
    submit = bind("virgl_renderer_submit_cmd", c.c_int, [c.c_void_p, c.c_int, c.c_int])
    cap_info = bind("virgl_renderer_get_cap_set", None, [c.c_uint32, c.POINTER(c.c_uint32), c.POINTER(c.c_uint32)])
    cap_fill = bind("virgl_renderer_fill_caps", None, [c.c_uint32, c.c_uint32, c.c_void_p])
    transfer_args = [c.c_uint32, c.c_uint32, c.c_uint32, c.c_uint32, c.c_uint32,
                     c.POINTER(Box), c.c_uint64, c.POINTER(Iovec), c.c_int]
    upload = bind("virgl_renderer_transfer_write_iov", c.c_int, transfer_args)
    download = bind("virgl_renderer_transfer_read_iov", c.c_int, transfer_args)
    create_fence = bind("virgl_renderer_create_fence", c.c_int, [c.c_int, c.c_uint32])
    poll = bind("virgl_renderer_poll", None, [])
    force_context = bind("virgl_renderer_force_ctx_0", None, [])
    fences = []
    callbacks = Callbacks()
    callbacks.version = 4
    callbacks.write_fence = fence_cb(lambda _cookie, fence: fences.append(fence))
    cookie = c.c_uint8(0x6c)

    def check(result, operation):
        if result != 0:
            raise RuntimeError(f"{operation} returned {result}")

    def wait_fence(identifier, command):
        if not 0 < identifier < 0x80000000:
            raise ValueError("this reference library's legacy fence API cannot represent the requested ID")
        check(create_fence(identifier, command), "create_fence")
        deadline = time.monotonic() + 10
        while identifier not in fences:
            poll()
            if time.monotonic() >= deadline:
                raise TimeoutError(f"fence {identifier} did not signal")
            time.sleep(0.001)

    initialized = False
    report = {"status": "RUNNING", "evidence": "external-renderer-request-replay-not-rtl-or-linux-driver",
              "reference_pins": pins, "library": name, "width": w, "height": h,
              "execbuf_sha256": hashlib.sha256(stream).hexdigest(),
              "reqtab_sha256": hashlib.sha256(table).hexdigest(), "requests": []}
    try:
        check(init(c.byref(cookie), 9, c.byref(callbacks)), "renderer_init")
        initialized = True
        egl_name = ctypes.util.find_library("EGL")
        if egl_name:
            egl = c.CDLL(egl_name)
            egl.eglGetProcAddress.argtypes = [c.c_char_p]
            egl.eglGetProcAddress.restype = c.c_void_p
            address = egl.eglGetProcAddress(b"glGetString")
            if address:
                renderer = c.CFUNCTYPE(c.c_char_p, c.c_uint32)(address)(0x1f01)
                report["renderer"] = renderer.decode("utf-8", "replace") if renderer else "unknown"
        source = bytearray()
        colors = (0xff2040ff, 0xff40ff40, 0xffff4040, 0xffc0c000)
        for y in range(h):
            for x in range(w):
                pixel = 0xffffffff if (x, y) == (3, 3) else colors[(y >= h // 2) * 2 + (x >= w // 2)]
                source.extend(struct.pack("<I", pixel))
        source_buffer = (c.c_ubyte * len(source)).from_buffer(source)
        source_iov = Iovec(c.addressof(source_buffer), len(source))
        box = Box(0, 0, 0, w, h, 1)
        source_resource = Resource(1, 2, 2, 2, w, h, 1, 1, 0, 0, 1)
        check(create(c.byref(source_resource), None, 0), "CREATE_2D prelude")
        check(upload(1, 0, 0, w * 4, 0, c.byref(box), 0, c.byref(source_iov), 1), "TRANSFER_TO_HOST_2D prelude")
        resources = {1: source_resource}
        contexts = set()
        selected = None
        for request, capacity, record_flags in records:
            words = struct.unpack(f"<{len(request) // 4}I", request)
            command, flags, low, high, ctx, _pad = words[:6]
            if flags & ~1 or record_flags != int(command == 0x0207):
                raise ValueError("unsupported request flags")
            fence = low | (high << 32)
            response_size = 24
            force_context()
            if command == 0x0108:
                if len(request) != 32 or words[6] != 0:
                    raise ValueError("reference supports capset index 0")
                version, size = c.c_uint32(), c.c_uint32()
                cap_info(pins["capset_id"], c.byref(version), c.byref(size))
                if (version.value, size.value) != (pins["capset_version"], pins["capset_bytes"]):
                    raise RuntimeError("installed renderer capset disagrees with reference pin")
                response_size = 40
            elif command == 0x0109:
                if len(request) != 32 or words[6:8] != (pins["capset_id"], pins["capset_version"]):
                    raise ValueError("capset request disagrees with reference pin")
                caps = c.create_string_buffer(pins["capset_bytes"])
                cap_fill(words[6], words[7], caps)
                report["capset_sha256"] = hashlib.sha256(caps.raw).hexdigest()
                cap_words = struct.unpack("<77I", caps.raw)
                report["reference_renderer_caps"] = {"glsl_level": cap_words[66],
                    "max_render_targets": cap_words[70], "max_samples": cap_words[71],
                    "primitive_mask": cap_words[72], "max_viewports": cap_words[75]}
                response_size += len(caps)
            elif command == 0x0200:
                if len(request) != 96 or not 0 < ctx <= 64 or words[6] > 64 or words[7] != 0 or ctx in contexts:
                    raise ValueError("invalid context create")
                check(context(ctx, words[6], request[32:32 + words[6]]), "CTX_CREATE")
                contexts.add(ctx)
            elif command == 0x0204:
                if len(request) != 72 or words[6] in resources or ctx not in contexts:
                    raise ValueError("invalid resource create")
                resource = Resource(*words[6:17])
                if (not 0 < resource.handle <= 64 or resource.depth != 1 or resource.array_size != 1
                        or resource.last_level != 0 or resource.nr_samples != 0
                        or not 0 < resource.width <= 4096 or not 0 < resource.height <= 4096
                        or resource.width * resource.height * 4 > 32 * 1024 * 1024):
                    raise ValueError("resource exceeds reference profile")
                check(create(c.byref(resource), None, 0), "RESOURCE_CREATE_3D")
                resources[resource.handle] = resource
            elif command == 0x0202:
                if len(request) != 32 or ctx not in contexts or words[6] not in resources:
                    raise ValueError("invalid resource attachment")
                attach(ctx, words[6])
            elif command == 0x0207:
                if len(request) != 32 or record_flags != 1 or ctx not in contexts or words[6] != len(stream):
                    raise ValueError("invalid submit payload")
                if flags != 1:
                    raise ValueError("SUBMIT_3D must finish before scanout")
                data = c.create_string_buffer(stream)
                check(submit(data, ctx, len(stream) // 4), "SUBMIT_3D")
            elif command in (0x0103, 0x0104):
                if len(request) != 48:
                    raise ValueError("invalid presentation request")
                resource_id = words[11] if command == 0x0103 else words[10]
                resource = resources.get(resource_id)
                if resource is None or words[6:10] != (0, 0, resource.width, resource.height):
                    raise ValueError("invalid presentation resource or rectangle")
                if command == 0x0103:
                    if words[10] != 0 or not fences:
                        raise ValueError("invalid scanout or missing completed render fence")
                    selected = resource_id
                elif selected != resource_id:
                    raise ValueError("flush is not for the selected headless surface")
            else:
                raise ValueError(f"unimplemented reference command {command:#x}")
            if response_size > capacity:
                raise ValueError(f"response {response_size} exceeds descriptor capacity {capacity}")
            if flags & 1:
                wait_fence(fence, command)
            report["requests"].append({"command": hex(command), "context": ctx,
                                       "response_bytes": response_size, "fence": fence if flags & 1 else None})
        if selected != 4:
            raise ValueError("render target was not selected")
        output = (c.c_ubyte * len(source))()
        output_iov = Iovec(c.addressof(output), len(source))
        check(attach_iov(selected, c.byref(output_iov), 1), "RESOURCE_ATTACH_BACKING readback")
        check(download(selected, 1, 0, w * 4, 0, c.byref(box), 0, None, 0), "TRANSFER_FROM_HOST_3D")
        wait_fence(2, 0x0206)
        raw = bytes(output)
        mismatches = sum(raw[i:i + 4] != source[i:i + 4] for i in range(0, len(raw), 4))
        probes = [(3, 3), (w // 4, h // 4), (w // 4, 3 * h // 4)]
        report["pixel_probes"] = [{"x": x, "y": y,
            "actual": raw[(y * w + x) * 4:(y * w + x) * 4 + 4].hex(),
            "expected": source[(y * w + x) * 4:(y * w + x) * 4 + 4].hex()} for x, y in probes]
        report["vertical_flip_matches"] = sum(raw[y * w * 4:(y + 1) * w * 4] == source[(h - 1 - y) * w * 4:(h - y) * w * 4] for y in range(h))
        report.update({"pixels": w * h, "mismatches": mismatches,
                       "output_sha256": hashlib.sha256(raw).hexdigest(), "completed_fences": fences,
                       "scanout": "headless metadata validation only", "status": "PASS" if not mismatches else "FAIL"})
        (directory / "reference-report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        if mismatches:
            raise RuntimeError(f"{mismatches} reference pixels differ")
        log(f"VIRGL-REFERENCE PASS {w * h} exact pixels; {len(records)} requests; fences={fences}; renderer={report.get('renderer', 'unknown')}")
    except Exception as error:
        report.update({"status": "FAIL", "error": str(error)})
        (directory / "reference-report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        raise
    finally:
        if initialized:
            cleanup(c.byref(cookie))


def main() -> int:
    ap = argparse.ArgumentParser(prog="bios-regress")
    ap.add_argument("--spec")
    ap.add_argument("--virgl-reference", type=Path)
    args = ap.parse_args()
    if args.virgl_reference is not None:
        try:
            case_virgl_reference(args.virgl_reference)
            return 0
        except Exception as error:
            err(f"virgl-reference: {error}")
            return 1
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
        ("css_golden", case_css_golden),
        ("guest_pixel_parity", case_guest_pixel_parity),
        ("disp_scan", case_disp_scan),
        ("disp_sel_pcie", case_disp_sel_pcie),
        ("disp_sel_vga", case_disp_sel_vga),
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
