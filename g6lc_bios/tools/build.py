#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
Top-level g6lc_bios build orchestrator.

Handles all major build types:
  build.py zealcli [--spec FIXTURE]   minimal g6b-zealcli VGA (cargo + ELF/smoke)
  build.py browser   [--spec FIXTURE] browser-ui (bun run build; first-party wasm lane)
  build.py libwasm   [--spec FIXTURE] browser-ui + optional LDC 1.43 libwasm cell
  build.py full      [--spec FIXTURE] zealcli + browser + libwasm
  build.py test      [--spec FIXTURE] [--fs KIND] [--libwasm] [--settle N]
                     [--keywords k1,k2,...] [--no-emit-fs] [--disk PATH]
  build.py check [--rust-only]        g6b.py check (independence + bun + cargo gates;
                                      --rust-only skips the browser-ui bun lane)
  build.py all                       alias for full

Auto-installs requirements as needed:
  - Rust toolchain (rustup/cargo) via build-platform fall-through if available
  - Bun (for browser-ui)
  - Pinned LDC 1.43.0-beta1          (compiles the optional libwasm cell)
  - Forked wasm-opt (Binaryen)       (asyncifies it; stock Binaryen cannot
                                      --asyncify the try_table LDC 1.43 emits)

Both toolchains land under browser-ui/toolchains/ and are resolved from there
in preference to anything ambient, because the cell's provenance hash covers
the tool binaries. wasm-opt is downloaded from the etcimon/binaryen svelte-d
fork's CI and, failing that, cmake-built from the svelte-d/binaryen submodule.

Fall-through to E:\\cva6\\build-platform: when build-platform is present and
the host lacks a required tool, this script delegates the install to:
  bun run src/cli/index.ts tools install <profile>
or prints the exact command if bun is not yet available.

Usage:
  python tools/build.py zealcli
  python tools/build.py browser
  python tools/build.py libwasm
  python tools/build.py full
  python tools/build.py test --spec fixtures/g6lc64-btrfs-test.json --fs btrfs
  python tools/build.py test --spec fixtures/g6lc64-btrfs-test.json --fs btrfs --libwasm
  python tools/build.py test --no-emit-fs --disk out/btrfs-key.img --keywords btrfs,STORE
  python tools/build.py check
  python tools/build.py zealcli --spec fixtures/g6lc64-zealcli.json
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

_TOOLS = Path(__file__).resolve().parent
_ROOT = _TOOLS.parent
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))

_BUILD_PLATFORM = _ROOT.parent / "build-platform"
_DEFAULT_SPEC = "fixtures/g6lc64-zealcli.json"
_BROWSER_UI = _ROOT / "browser-ui"


def log(msg: str) -> None:
    print(f"[build] {msg}")


def err(msg: str) -> None:
    print(f"[build] ERROR: {msg}", file=sys.stderr)


def have(bin_name: str) -> bool:
    return shutil.which(bin_name) is not None


def run(cmd: list[str], cwd: Path | None = None, env: dict | None = None) -> int:
    log("+ " + " ".join(cmd))
    return subprocess.run(cmd, cwd=str(cwd or _ROOT), env=env).returncode


def build_platform_cli() -> list[str] | None:
    """Return the build-platform CLI argv prefix, or None if unavailable."""
    bp = _BUILD_PLATFORM
    if not (bp / "src" / "cli" / "index.ts").is_file():
        return None
    bun = shutil.which("bun")
    if bun:
        return [bun, "run", str(bp / "src" / "cli" / "index.ts")]
    return None


def ensure_cargo() -> bool:
    if have("cargo"):
        return True
    log("cargo not found on PATH")
    cli = build_platform_cli()
    if cli:
        log("delegating to build-platform: tools install sim")
        rc = run(cli + ["tools", "install", "sim"])
        if rc == 0 and have("cargo"):
            return True
    err("cargo is required for zealcli/full builds; install Rust or run build-platform tools install sim")
    return False


def ensure_bun() -> bool:
    if have("bun"):
        return True
    log("bun not found on PATH")
    # build-platform's bootstrap wrappers install bun, but we can't run them
    # without bun. Print the instruction instead.
    bp = _BUILD_PLATFORM
    if bp.is_dir():
        err("bun is required for browser-ui builds; install bun or run build-platform/build.sh / build.ps1")
    else:
        err("bun is required for browser-ui builds; install bun from https://bun.sh")
    return False


def ensure_ldc() -> bool:
    """Ensure the pinned LDC 1.43.0-beta1 toolchain is installed for libwasm."""
    if not have("bun"):
        return False
    ui = _BROWSER_UI
    rc = run(["bun", "scripts/install-ldc.ts", "--check"], cwd=ui)
    if rc == 0:
        return True
    log("installing pinned LDC 1.43.0-beta1 toolchain...")
    return run(["bun", "scripts/install-ldc.ts"], cwd=ui) == 0


def ensure_wasm_opt() -> bool:
    """Ensure the *forked* wasm-opt is installed, the same way as LDC.

    The libwasm cell is asyncified, and stock Binaryen cannot `--asyncify` a
    module containing `try_table` — which is exactly what LDC 1.43 emits for
    wasm-eh. So `wasm-opt` is not an optional nicety for this lane, it is a
    toolchain on the same footing as the compiler, and it lives in
    `browser-ui/toolchains/binaryen-svelte-d/` next to `toolchains/ldc2-*`.

    Three escalating attempts, so a fresh clone needs no manual step:
      1. `--check`       — already resolvable and it really asyncifies try_table
      2. (default)       — download the fork's CI binary for this host variant
      3. `--from-source` — cmake the `svelte-d/binaryen` submodule

    Step 2 already falls back to step 3 internally when the source is present;
    the explicit third attempt covers the case where the download *succeeded*
    but produced something that failed verification and was removed.
    """
    if not have("bun"):
        return False
    ui = _BROWSER_UI
    if run(["bun", "scripts/install-wasm-opt.ts", "--check"], cwd=ui) == 0:
        return True
    log("installing forked wasm-opt (asyncify needs the svelte-d Binaryen fork)...")
    if run(["bun", "scripts/install-wasm-opt.ts"], cwd=ui) == 0:
        return True
    log("wasm-opt download unusable; building the svelte-d/binaryen submodule from source...")
    return run(["bun", "scripts/install-wasm-opt.ts", "--from-source"], cwd=ui) == 0


def build_zealcli(spec: str | None) -> int:
    """Minimal g6b-zealcli VGA: cargo build g6b-cli + smoke against a zealcli fixture."""
    if not ensure_cargo():
        return 1
    sp = spec or _DEFAULT_SPEC
    log(f"--- zealcli: cargo build g6b-cli ---")
    rc = run(["cargo", "build", "-p", "g6b-cli"])
    if rc != 0:
        return rc
    log(f"--- zealcli: smoke {sp} ---")
    return run(["cargo", "run", "-p", "g6b-cli", "--", "smoke", "--spec", sp])


def build_browser(spec: str | None, libwasm: bool = False) -> int:
    """Browser-ui: bun run build (first-party wasm lane). Optional libwasm cell."""
    if not ensure_bun():
        return 1
    ui = _BROWSER_UI
    if libwasm:
        # Both are hard requirements for the cell: LDC 1.43 compiles it and the
        # forked wasm-opt asyncifies it. Failing here beats failing inside dub
        # with an opaque asyncify error.
        if not ensure_ldc():
            return 1
        if not ensure_wasm_opt():
            err("libwasm: forked wasm-opt unavailable; the asyncify pass cannot run")
            return 1
        env = {**os.environ, "G6B_DUB_WASM": "1"}
        log("--- browser-ui: bun run build (with libwasm cell) ---")
        return run(["bun", "run", "build"], cwd=ui, env=env)
    log("--- browser-ui: bun run build ---")
    return run(["bun", "run", "build"], cwd=ui)


def build_full(spec: str | None) -> int:
    """Full: zealcli + browser + libwasm cell."""
    rc = build_zealcli(spec)
    if rc != 0:
        return rc
    rc = build_browser(spec, libwasm=True)
    if rc != 0:
        return rc
    log("full build OK")
    return 0


def cmd_check(rest: list[str]) -> int:
    """Delegate to g6b.py check (independence + bun + cargo gates).

    Flags (e.g. ``--rust-only``) are forwarded unchanged.
    """
    return run([sys.executable, str(_TOOLS / "g6b.py"), "check", *rest])


def _win_to_wsl(path: str) -> str:
    """Convert a Windows path to a WSL path (e.g. E:\\foo → /mnt/e/foo)."""
    p = Path(path).resolve()
    drive = p.drive[0].lower()  # e.g. 'e'
    return f"/mnt/{drive}{p.as_posix()[2:]}"


# The filesystems `g6b vfs emit-fs` has a fixture for. Keep in step with
# `g6b_vfs::FIXTURE_KINDS` — `every_fixture_kind_probes_and_mounts_as_itself`
# is the Rust-side guard that each one still mounts.
FS_KINDS = ("fat32", "ext4", "ntfs", "btrfs")

# Per-filesystem *write* capability, because it is not uniform and a matrix
# that asserted one outcome for all four would be asserting something false.
# See architecture/g6b-vfs.md "Editing: the filesystem's terms".
#
#   rw       - creates, grows: a store export lands as a new file
#   guarded  - in-place + tail growth, refusals are named (ext4)
#   bounded  - resident $DATA in place only, `can_grow: false`, no new files:
#              a store export is expected to be *refused*, and that refusal is
#              the pass condition (NTFS)
FS_WRITE = {
    "fat32": "rw",
    "ext4": "guarded",
    "btrfs": "rw",
    "ntfs": "bounded",
}


def _emit_fs_fixture(fs: str, out_path: Path) -> int:
    """Emit a hand-laid filesystem fixture image to out_path."""
    g6b_bin = str(_ROOT / "target" / "debug" / ("g6b.exe" if os.name == "nt" else "g6b"))
    if fs not in FS_KINDS:
        err(f"emit-fs: unsupported filesystem `{fs}` (available: {'|'.join(FS_KINDS)})")
        return 2
    return run([g6b_bin, "vfs", "emit-fs", "--fs", fs, "--out", str(out_path)])


def _run_qemu(
    elf_path: Path,
    disk_path: Path,
    serial_log: Path,
    qemu_log: Path,
    settle: int,
    readonly: bool = False,
    keys: str | None = None,
    key_delay: float = 0.5,
) -> int:
    """Run QEMU with the ELF kernel + a virtio-blk disk, capture serial output.

    If `keys` is provided, sends each character as a `sendkey` command through
    the QEMU monitor after the initial settle period, then waits an additional
    `settle` seconds for the response. Uses TCP sockets for serial + monitor
    (same pattern as qemu_zealcli.sh).
    """
    import socket
    import time

    out_dir = serial_log.parent
    out_dir.mkdir(parents=True, exist_ok=True)
    ro = "on" if readonly else "off"

    # Use TCP sockets for serial + monitor so we can send keystrokes.
    ser_port = 23000 + (hash(str(elf_path)) % 1000)
    mon_port = ser_port + 1

    if os.name == "nt":
        wsl_elf = _win_to_wsl(str(elf_path))
        wsl_disk = _win_to_wsl(str(disk_path))
        qemu_cmd = [
            "wsl", "qemu-system-riscv64",
            "-machine", "virt", "-cpu", "rv64", "-m", "512", "-nographic", "-smp", "1",
            "-global", "virtio-mmio.force-legacy=false",
            "-serial", f"tcp:127.0.0.1:{ser_port},server",
            "-monitor", f"tcp:127.0.0.1:{mon_port},server,nowait",
            "-device", "virtio-gpu-device",
            "-device", "virtio-keyboard-device",
            "-drive", f"file={wsl_disk},format=raw,if=none,id=blk0,readonly={ro}",
            "-device", "virtio-blk-device,drive=blk0",
            "-kernel", wsl_elf,
        ]
    else:
        qemu_cmd = [
            "qemu-system-riscv64",
            "-machine", "virt", "-cpu", "rv64", "-m", "512", "-nographic", "-smp", "1",
            "-global", "virtio-mmio.force-legacy=false",
            "-serial", f"tcp:127.0.0.1:{ser_port},server",
            "-monitor", f"tcp:127.0.0.1:{mon_port},server,nowait",
            "-device", "virtio-gpu-device",
            "-device", "virtio-keyboard-device",
            "-drive", f"file={disk_path},format=raw,if=none,id=blk0,readonly={ro}",
            "-device", "virtio-blk-device,drive=blk0",
            "-kernel", str(elf_path),
        ]
    log("+ " + " ".join(qemu_cmd))
    import subprocess as sp_mod
    proc = sp_mod.Popen(qemu_cmd, stdout=open(qemu_log, "w"), stderr=sp_mod.STDOUT)

    # Connect to the serial TCP server (QEMU listens, we connect).
    ser_sock = None
    mon_sock = None
    for _ in range(20):
        try:
            ser_sock = socket.create_connection(("127.0.0.1", ser_port), timeout=2)
            break
        except OSError:
            time.sleep(0.5)
    if ser_sock is None:
        proc.kill()
        proc.wait()
        return 1
    ser_sock.settimeout(1.0)

    # Collect serial output in a background thread.
    serial_buf: list[bytes] = []
    def _read_serial():
        while True:
            try:
                data = ser_sock.recv(4096)
                if not data:
                    break
                serial_buf.append(data)
            except OSError:
                break
    import threading
    reader = threading.Thread(target=_read_serial, daemon=True)
    reader.start()

    # Connect to the monitor for sendkey commands.
    if keys:
        for _ in range(20):
            try:
                mon_sock = socket.create_connection(("127.0.0.1", mon_port), timeout=2)
                break
            except OSError:
                time.sleep(0.5)
        if mon_sock is None:
            log("monitor: could not connect; keystrokes skipped")

    # Wait for the BIOS to boot.
    time.sleep(settle)

    # Send keystrokes through the serial port (UART) and the QEMU monitor.
    # The BIOS reads from both the UART and the virtio-keyboard device.
    # Sending text to the serial port works for CLI input (same as
    # qemu_zealcli.sh's `printf 'help\n' >&3`).
    if keys:
        log(f"--- test: sending keystrokes: {keys!r} ---")
        # Parse key tokens: {esc}, {ret}, {spc}, {tab}, {bs}, {up}, {down},
        # {left}, {right}, {del}, {home}, {end} are special keys; everything
        # else is typed character-by-character.
        import re as re_mod
        key_tokens = re_mod.findall(r"\{(\w+)\}|(.)", keys)

        # First send via the serial port (UART) for immediate CLI input.
        ser_text = ""
        for special, ch in key_tokens:
            if special:
                if special in ("ret", "enter"):
                    ser_text += "\n"
                elif special in ("esc", "escape"):
                    ser_text += "\x1b"
                elif special == "spc":
                    ser_text += " "
                elif special == "tab":
                    ser_text += "\t"
                elif special == "bs":
                    ser_text += "\b"
                else:
                    ser_text += "\n"  # fallback for unknown special keys
            elif ch:
                ser_text += ch
        try:
            ser_sock.sendall(ser_text.encode())
        except OSError:
            pass

        # Also send via the QEMU monitor's sendkey for the virtio-keyboard path.
        if mon_sock:
            mon_sock.settimeout(2.0)
            # Drain the monitor banner.
            try:
                mon_sock.recv(4096)
            except OSError:
                pass
            for special, ch in key_tokens:
                if special:
                    cmd = f"sendkey {special}\n".encode()
                elif ch == "\n":
                    cmd = b"sendkey ret\n"
                elif ch == "\r":
                    continue  # skip CR
                elif ch == " ":
                    cmd = b"sendkey spc\n"
                elif ch == "\x1b":
                    cmd = b"sendkey esc\n"
                elif ch == "\t":
                    cmd = b"sendkey tab\n"
                elif ch == "\b":
                    cmd = b"sendkey backspace\n"
                else:
                    cmd = f"sendkey {ch}\n".encode()
                try:
                    mon_sock.sendall(cmd)
                    try:
                        mon_sock.recv(4096)
                    except OSError:
                        pass
                except OSError:
                    break
                time.sleep(key_delay)

        # Wait for the BIOS to process the keystrokes.
        time.sleep(settle)

    # Kill QEMU and collect the serial output.
    proc.kill()
    proc.wait()
    if ser_sock:
        ser_sock.close()
    if mon_sock:
        mon_sock.close()
    reader.join(timeout=2)

    # Write the serial buffer to the log file.
    serial_log.write_bytes(b"".join(serial_buf))
    return 0 if serial_log.is_file() and serial_log.stat().st_size > 0 else 1


def _scan_serial_log(serial_log: Path, keywords: list[str]) -> tuple[list[str], dict[str, bool]]:
    """Scan a serial log for keyword markers. Returns (matching_lines, keyword→found).

    The BIOS payload writes each character twice (SBI putchar *and* the UART0
    THR), so the log is de-doubled before scanning — same as qemu_zealcli.sh.
    """
    if not serial_log.is_file():
        return [], {kw: False for kw in keywords}
    raw = serial_log.read_text(encoding="utf-8", errors="replace")
    # De-double: collapse each pair of identical chars into one.
    import re
    text = re.sub(r"(.)\1", r"\1", raw)
    markers = []
    found = {kw: False for kw in keywords}
    for line in text.splitlines():
        for kw in keywords:
            if kw.lower() in line.lower():
                markers.append(line.strip())
                found[kw] = True
                break
    return markers, found


def cmd_test(rest: list[str]) -> int:
    """Generic test command with parameters.

    Usage:
      build.py test --spec FIXTURE [--fs KIND] [--libwasm] [--settle N] [--readonly]
                    [--keywords kw1,kw2,...] [--no-emit-fs] [--disk PATH]
                    [--keys TEXT] [--key-delay SECONDS]

    Parameters:
      --spec FIXTURE      BoardSpec JSON (default: fixtures/g6lc64-zealcli.json)
      --fs KIND           Filesystem fixture: fat32|ext4|ntfs|btrfs (default: btrfs)
      --libwasm           Also build the LDC 1.43 libwasm cell
      --settle N          QEMU settle seconds (default: 10)
      --readonly          Attach the disk read-only
      --keywords k1,k2    Comma-separated markers to scan for in serial log
                          (default: the selected --fs plus the store/UI markers)
      --no-emit-fs        Skip emitting the filesystem fixture (use --disk PATH instead)
      --disk PATH         Use an existing disk image instead of emitting one
      --keys TEXT         Keystrokes to send via QEMU monitor after boot (e.g. "drv{ret}")
      --key-delay SECONDS Delay between keystrokes (default: 0.5)

    Write capability is per-filesystem and the defaults reflect it rather than
    asserting one outcome for all four (see FS_WRITE / architecture/g6b-vfs.md):
    fat32 and btrfs create files, ext4 is guarded, and NTFS writes only resident
    $DATA in place — on NTFS a store export is expected to be refused.
    """
    spec = _flag_value(rest, "--spec") or "fixtures/g6lc64-zealcli.json"
    fs = (_flag_value(rest, "--fs") or "btrfs").lower()
    if fs not in FS_KINDS:
        err(f"test: --fs `{fs}` unknown (available: {'|'.join(FS_KINDS)})")
        return 2
    libwasm = "--libwasm" in rest
    settle = int(_flag_value(rest, "--settle") or os.environ.get("SETTLE", "10"))
    readonly = "--readonly" in rest
    # The fs name itself is a marker: the guest prints the volume kind it
    # selected, so scanning for it proves the *guest* saw this filesystem and
    # not merely that the host wrote the image.
    default_keywords = f"{fs},Store,USB-FILES,SVELTE-LIVE,JS-FETCH,ZEALCLI,KSTART,G6LC-BIOS"
    keywords_str = _flag_value(rest, "--keywords") or default_keywords
    keywords = [k.strip() for k in keywords_str.split(",") if k.strip()]
    no_emit_fs = "--no-emit-fs" in rest
    disk_path = _flag_value(rest, "--disk")
    keys = _flag_value(rest, "--keys")
    key_delay = float(_flag_value(rest, "--key-delay") or "0.5")

    # 1. Build browser-ui (first-party wasm lane, optional libwasm cell).
    rc = build_browser(spec, libwasm=libwasm)
    if rc != 0:
        return rc
    # 2. Build the BIOS ELF.
    log(f"--- test: building ELF ({spec}) ---")
    rc = run([sys.executable, str(_TOOLS / "g6b.py"), "elf", "--spec", spec, "--out", "out/g6lc_bios.elf"])
    if rc != 0:
        return rc
    # 3. Emit or locate the filesystem fixture.
    if not no_emit_fs:
        log(f"--- test: emitting {fs} fixture (write capability: {FS_WRITE[fs]}) ---")
        disk_path = str(_ROOT / "out" / f"{fs}-key.img")
        rc = _emit_fs_fixture(fs, Path(disk_path))
        if rc != 0:
            return rc
        # Verify the fixture scans correctly.
        g6b_bin = str(_ROOT / "target" / "debug" / ("g6b.exe" if os.name == "nt" else "g6b"))
        rc = run([g6b_bin, "vfs", "scan", "--disk", disk_path])
        if rc != 0:
            return rc
    elif not disk_path:
        err("test: --no-emit-fs requires --disk PATH")
        return 2
    # 4. Run QEMU.
    log("--- test: QEMU boot ---")
    out_dir = _ROOT / "out" / f"{fs}-qemu"
    elf_path = _ROOT / "out" / "g6lc_bios.elf"
    serial_log = out_dir / "serial.log"
    qemu_log = out_dir / "qemu.log"
    rc = _run_qemu(elf_path, Path(disk_path), serial_log, qemu_log, settle, readonly=readonly, keys=keys, key_delay=key_delay)
    if rc != 0:
        err(f"test: QEMU did not produce a serial log at {serial_log}")
        return 1
    # 5. Scan the serial log for markers.
    log(f"--- test: serial log markers ({', '.join(keywords)}) ---")
    markers, found = _scan_serial_log(serial_log, keywords)
    for m in markers[:40]:
        print(f"  {m}")
    all_found = True
    for kw in keywords:
        if found[kw]:
            log(f"  {kw}-OK")
        else:
            log(f"  {kw}-MISS")
            all_found = False
    log(f"full serial log: {serial_log}")
    log(f"qemu log: {qemu_log}")
    return 0 if all_found else 1


def _flag_value(args: list[str], flag: str) -> str | None:
    """Extract --flag value from an argv list."""
    for i, a in enumerate(args):
        if a == flag and i + 1 < len(args):
            return args[i + 1]
        if a.startswith(f"{flag}="):
            return a[len(flag) + 1:]
    return None


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    cmd = args[0]
    rest = args[1:]
    spec = None
    for i, a in enumerate(rest):
        if a == "--spec" and i + 1 < len(rest):
            spec = rest[i + 1]
    if cmd == "zealcli":
        return build_zealcli(spec)
    if cmd == "browser":
        return build_browser(spec, libwasm=False)
    if cmd == "libwasm":
        return build_browser(spec, libwasm=True)
    if cmd == "full" or cmd == "all":
        return build_full(spec)
    if cmd == "test":
        return cmd_test(rest)
    if cmd == "native":
        from guest_native import main as native_main
        return native_main(rest)
    if cmd == "check":
        return cmd_check(rest)
    err(f"unknown command: {cmd}")
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
