#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# g6q_remote.py — remote QEMU build + test proxy for g6lc_qemu.
#
# Mirrors the host monorepo's testharness_proxy.py layout for the QEMU build only:
#   default host  : ovh_calltorch  (env G6Q_REMOTE_HOST)
#   default root  : /opt/testharness/g6lc-qemu  (env G6Q_REMOTE_ROOT)
#
# The remote tree is laid out as:
#   <remote_root>/repo/qemu/    rsync'd QEMU source with emitted g6lc-*.c
#   <remote_root>/build/qemu/   meson/ninja build directory
#   <remote_root>/runs/<tag>/   per-test run logs
#   <remote_root>/cache/ccache/ persistent compiler cache
#
# Subcommands:
#   doctor    probe local ssh/rsync and remote toolchain availability
#   sync      rsync qemu/ source to the builder
#   configure run meson setup on the builder (incremental by default)
#   build     run ninja with ccache and thread saturation
#   pull      copy the built qemu-system-riscv64 back to the local tree
#   run       run an arbitrary command through the built qemu on the builder
#   test      smoke test (OpenSBI boot) or plugin/AI-tensor test proxy
#   clean     remove remote build/run directories
#
# Convenience:
#   python tools/g6q_remote.py remote-build --package E:\cva6
#     = install-qemu locally, sync, configure, build, pull, test --smoke
#
# This is a *build* proxy; it does not synthesize or simulate RTL/uncore.
# Those remain the responsibility of the host monorepo's testharness.

from __future__ import annotations

import argparse
import os
import shlex
import shutil
import socket
import subprocess
import sys
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator

_TOOLS = Path(__file__).resolve().parent
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))

from env_common import package_root

# --------------------------------------------------------------------------- defaults

DEFAULT_HOST = os.environ.get("G6Q_REMOTE_HOST", "ovh_calltorch")
DEFAULT_ROOT = os.environ.get("G6Q_REMOTE_ROOT", "/opt/testharness/g6lc-qemu")
_WINDOWS = os.name == "nt"

# Passphrase / password for the private key. Prefer G6Q_REMOTE_PASS; fall back
# to the first line of G6Q_REMOTE_CREDS (a file outside the repo, e.g.
# build-platform/.remote-ssh-creds). The value is only used at runtime and is
# never committed.
_REMOTE_PASS = os.environ.get("G6Q_REMOTE_PASS")
if not _REMOTE_PASS:
    _creds = os.environ.get("G6Q_REMOTE_CREDS")
    if _creds and Path(_creds).is_file():
        _REMOTE_PASS = Path(_creds).read_text().splitlines()[0].strip()

_REMOTE_KEY = os.environ.get("G6Q_REMOTE_KEY")

DEFAULT_SSH = shlex.split(os.environ.get("G6Q_SSH_BIN", "ssh"))
DEFAULT_RSYNC = shlex.split(os.environ.get("G6Q_RSYNC_BIN", "rsync"))

# On Windows the OpenSSH tools do not support SSH_ASKPASS scripts and rsync is
# rarely on PATH. Fall back to WSL ssh/rsync so a passphrase-protected key can
# be unlocked through an askpass helper. `conhost` is required because `wsl`
# needs a console handle when spawned from a non-interactive Python process.
if _WINDOWS and shutil.which("wsl") is not None:
    if _REMOTE_PASS or _REMOTE_KEY:
        if shutil.which("conhost") is not None:
            DEFAULT_SSH = ["conhost", "wsl", "ssh"]
        else:
            DEFAULT_SSH = ["wsl", "ssh"]
    if shutil.which(DEFAULT_RSYNC[0]) is None:
        if shutil.which("conhost") is not None:
            DEFAULT_RSYNC = ["conhost", "wsl", "rsync"]
        else:
            DEFAULT_RSYNC = ["wsl", "rsync"]


QEMU_TARGET = "riscv64-softmmu"
QEMU_BINARY = "qemu-system-riscv64"

# Directories inside DEFAULT_ROOT
REPO_DIR = "repo/qemu"
BUILD_DIR = "build/qemu"
RUNS_DIR = "runs"
CACHE_DIR = "cache/ccache"
PAYLOAD_DIR = "repo/payload"

# Sync exclude patterns (rsync --exclude)
SYNC_EXCLUDES = [
    ".git/",
    "build/",
    "*.o",
    "*.d",
    "*.log",
    "*.vcd",
    "*.fst",
    "__pycache__/",
    ".g6lc_qemu_install",
]

# --------------------------------------------------------------------------- logging


def log(msg: str) -> None:
    print(f"[g6q-remote] {msg}")


def err(msg: str) -> None:
    print(f"[g6q-remote] ERROR: {msg}", file=sys.stderr)


def _wsl_path(p: Path) -> str:
    """Convert an absolute Windows path to a WSL /mnt/<drive>/ path."""
    p = p.resolve()
    drive, rest = str(p).split(":", 1)
    return f"/mnt/{drive.lower()}{rest.replace(os.sep, '/')}"


_ASKPASS_SCRIPT: Path | None = None


def _askpass_script() -> str | None:
    """Write a temporary SSH_ASKPASS script that echoes G6Q_REMOTE_PASS."""
    global _ASKPASS_SCRIPT
    if _ASKPASS_SCRIPT is not None:
        return _ASKPASS_SCRIPT
    if not _REMOTE_PASS:
        return None
    if _WINDOWS or os.environ.get("G6Q_REMOTE_ASKPASS_INTERNAL"):
        # WSL cannot make scripts on /mnt/ executable, so keep the askpass helper
        # in the WSL internal filesystem where chmod 700 is honored.
        script = "/root/.g6q_remote_askpass.sh"
        body = "#!/bin/bash\\necho \"$G6Q_REMOTE_PASS\"\\n"
        if shutil.which("wsl") is not None:
            runner = ["wsl", "bash", "-c"]
        else:
            runner = ["bash", "-c"]
        subprocess.run(
            runner + [f"printf '{body}' > {script} && chmod 700 {script}"],
            check=False,
        )
    else:
        script = str(package_root() / "out" / ".g6q_remote_askpass.sh")
        Path(script).write_text(
            "#!/bin/bash\n"
            'echo "$G6Q_REMOTE_PASS"\n',
            encoding="utf-8",
            newline="\n",
        )
        Path(script).chmod(0o700)
    _ASKPASS_SCRIPT = script
    return _ASKPASS_SCRIPT


def _remote_env(env: dict[str, str] | None) -> dict[str, str]:
    """Inject SSH_ASKPASS when a remote passphrase is configured."""
    env = (env or {}).copy()
    if _REMOTE_PASS:
        script = _askpass_script()
        if script is not None:
            env["G6Q_REMOTE_PASS"] = _REMOTE_PASS
            env["SSH_ASKPASS"] = script
            env["SSH_ASKPASS_REQUIRE"] = "force"
            # WSL does not forward Windows environment variables unless named here.
            if _WINDOWS:
                env["WSLENV"] = "SSH_ASKPASS:SSH_ASKPASS_REQUIRE:G6Q_REMOTE_PASS"
    return env


def _prepare_wsl_key() -> str:
    """Copy the configured private key into the WSL filesystem with 600 perms."""
    dst = "/root/.ssh/g6q_remote_key"
    subprocess.run(
        ["wsl", "bash", "-c", f"mkdir -p /root/.ssh && cp {_wsl_path(Path(_REMOTE_KEY))} {dst} && chmod 600 {dst}"],
        check=False,
    )
    return dst


def _maybe_key_args() -> list[str]:
    """Return key and host-check options when G6Q_REMOTE_KEY is set."""
    if not _REMOTE_KEY:
        return []
    if _WINDOWS:
        key = _prepare_wsl_key()
    else:
        key = _REMOTE_KEY
    return ["-i", key, "-o", "StrictHostKeyChecking=no"]


def _run(
    cmd: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    check: bool = True,
    capture: bool = False,
) -> subprocess.CompletedProcess:
    log("+ " + " ".join(str(c) for c in cmd))
    env = _remote_env(env)
    return subprocess.run(
        [str(c) for c in cmd],
        cwd=str(cwd) if cwd else None,
        env=env,
        check=check,
        capture_output=capture,
        text=True,
    )


def _ssh_base(host: str, control: Path | None) -> list[str]:
    base = list(DEFAULT_SSH)
    if control is not None:
        base += [
            "-o",
            f"ControlPath={control}",
            "-o",
            "ControlMaster=auto",
            "-o",
            "ControlPersist=10m",
        ]
    base += _maybe_key_args()
    base += [host]
    return base


def _rsync_base(host: str, control: Path | None) -> list[str]:
    base = list(DEFAULT_RSYNC)
    base += ["-az", "--delete"]
    if _REMOTE_KEY:
        ssh_cmd = " ".join(_maybe_key_args())
        base += ["-e", f"ssh {ssh_cmd}"]
    if control is not None:
        base += ["-e", f"ssh -o ControlPath={control} -o ControlMaster=auto -o ControlPersist=10m"]
    return base


@contextmanager
def _control_socket(host: str) -> Iterator[Path]:
    """Open a persistent SSH ControlMaster socket for the invocation."""
    if _WINDOWS:
        # Windows cannot use Unix-domain control sockets; fall back to per-call SSH.
        yield None
        return
    sock = Path(os.environ.get("G6Q_SSH_CONTROL", f"/tmp/g6q-remote-{os.getuid()}-{host}.sock"))
    if sock.parent and not sock.parent.exists():
        sock.parent.mkdir(parents=True, exist_ok=True)
    # Open the master connection in the background.
    cmd = _ssh_base(host, None) + ["-M", "-N", "-o", f"ControlPath={sock}"]
    env = _remote_env(None)
    proc = subprocess.Popen(
        [str(c) for c in cmd],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=env,
    )
    try:
        # Give the master a moment to establish.
        for _ in range(10):
            if sock.exists():
                break
            time.sleep(0.2)
        yield sock
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()


def _remote(host: str, sock: Path | None, cmd: list[str], check: bool = True, capture: bool = False) -> subprocess.CompletedProcess:
    ssh = _ssh_base(host, sock)
    return _run(ssh + cmd, check=check, capture=capture)


_BASE_PATH = "/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"
_TOOLCHAIN_PATH = "/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3/bin"


def _env(extra: str | None = None, append_path: bool = False, quote: bool = False) -> str:
    """Return a remote `export PATH=...; ` prefix with the standard discovery paths."""
    p = _BASE_PATH
    if extra:
        p += f":{extra}"
    if append_path:
        p += ":$PATH"
    if quote:
        return f'export PATH="{p}"; '
    return f"export PATH={p}; "


def _remote_mkdir(host: str, sock: Path | None, path: str) -> None:
    _remote(host, sock, ["mkdir", "-p", path])


def _rsync_to_remote(
    host: str,
    sock: Path | None,
    local: Path,
    remote_path: str,
    excludes: list[str] | None = None,
    dry_run: bool = False,
) -> None:
    base = _rsync_base(host, sock)
    if dry_run:
        base += ["--dry-run"]
    for e in excludes or []:
        base += ["--exclude", e]
    if _WINDOWS and DEFAULT_RSYNC[0] == "wsl":
        src = _wsl_path(local) + "/"
    else:
        src = str(local) + "/"
    base += [src, f"{host}:{remote_path}/"]
    _run(base)


def _rsync_from_remote(
    host: str,
    sock: Path | None,
    remote_path: str,
    local: Path,
    dry_run: bool = False,
) -> None:
    base = _rsync_base(host, sock)
    if dry_run:
        base += ["--dry-run"]
    local.parent.mkdir(parents=True, exist_ok=True)
    if _WINDOWS and DEFAULT_RSYNC[0] == "wsl":
        dst = _wsl_path(local)
    else:
        dst = str(local)
    base += [f"{host}:{remote_path}", dst]
    _run(base)


# --------------------------------------------------------------------------- subcommands


def cmd_doctor(args: argparse.Namespace) -> int:
    host = args.host
    root = args.root
    log(f"doctor: host={host} root={root}")

    if args.dry_run:
        log(f"dry-run: would probe {host} and check remote toolchain")
        return 0

    # Local checks
    if shutil.which(DEFAULT_SSH[0]) is None:
        err("ssh not found on PATH")
        return 1
    if shutil.which(DEFAULT_RSYNC[0]) is None:
        err("rsync not found on PATH")
        return 1

    with _control_socket(host) as sock:
        # Remote connectivity
        try:
            _remote(host, sock, ["uname", "-a"])
        except subprocess.CalledProcessError as e:
            err(f"cannot reach {host}: {e}")
            return 1

        # Remote toolchain probes
        for tool in ["python3", "ninja", "gcc", "g++", "ccache"]:
            res = _remote(host, sock, [f"{_env(append_path=True)}which {tool}"], check=False)
            status = "ok" if res.returncode == 0 else "MISSING"
            log(f"  remote {tool}: {status}")

        # Remote directories
        _remote_mkdir(host, sock, root)
        _remote_mkdir(host, sock, f"{root}/{CACHE_DIR}")
    return 0


def cmd_sync(args: argparse.Namespace) -> int:
    host = args.host
    root = args.root
    qemu_src = package_root() / "qemu"
    if not qemu_src.is_dir():
        err("qemu/ is not present; run `python tools/g6q.py fetch-qemu` first")
        return 1
    remote_qemu = f"{root}/{REPO_DIR}"
    if args.dry_run:
        log(f"dry-run: would rsync {qemu_src} to {host}:{remote_qemu}")
        return 0
    _remote_mkdir(host, None, remote_qemu)
    with _control_socket(host) as sock:
        _rsync_to_remote(host, sock, qemu_src, remote_qemu, SYNC_EXCLUDES)
    log(f"synced qemu/ to {host}:{remote_qemu}")
    return 0


def _configure_args(args: argparse.Namespace) -> str:
    cfg = f"--target-list={args.target}"
    cfg += " --disable-libvduse --disable-vduse-blk-export"
    cfg += " --disable-vhost-user --disable-vhost-user-blk-server"
    cfg += " --enable-plugins"
    if args.debug:
        cfg += " --enable-debug"
    if args.trace:
        cfg += f" --enable-trace-backends={args.trace}"
    if args.extra:
        for e in args.extra:
            cfg += f" {e}"
    return cfg


def cmd_configure(args: argparse.Namespace) -> int:
    host = args.host
    root = args.root
    remote_qemu = f"{root}/{REPO_DIR}"
    remote_build = f"{root}/{BUILD_DIR}"
    cfg_args = _configure_args(args)
    cmd = f"cd {remote_build} && CC='ccache gcc' CXX='ccache g++' CCACHE_DIR={root}/{CACHE_DIR} {remote_qemu}/configure {cfg_args}"
    full = f"{_env()}{cmd}"
    log(f"configure: {full}")
    if args.dry_run:
        return 0
    _remote_mkdir(host, None, remote_build)
    with _control_socket(host) as sock:
        res = _remote(host, sock, [full], check=False)
    if res.returncode != 0:
        err("remote configure failed")
        return res.returncode
    log(f"configured in {host}:{remote_build}")
    return 0


def _nproc(host: str, sock: Path | None) -> int:
    try:
        res = _remote(host, sock, ["nproc"], capture=True)
        return int(res.stdout.strip())
    except Exception:
        return 1


def cmd_build(args: argparse.Namespace) -> int:
    host = args.host
    root = args.root
    remote_build = f"{root}/{BUILD_DIR}"
    with _control_socket(host) as sock:
        jobs = args.jobs or _nproc(host, sock)
        env = f"CCACHE_DIR={root}/{CACHE_DIR}"
        cmd = f"{_env()}{env} ninja -C {remote_build} -j{jobs}"
        log(f"build: {cmd}")
        if args.dry_run:
            return 0
        res = _remote(host, sock, [cmd], check=False)
    if res.returncode != 0:
        err("remote build failed")
        return res.returncode
    log(f"built in {host}:{remote_build}")
    return 0


def cmd_pull(args: argparse.Namespace) -> int:
    host = args.host
    root = args.root
    remote_bin = f"{root}/{BUILD_DIR}/{QEMU_BINARY}"
    local_bin = package_root() / "qemu" / "build" / QEMU_BINARY
    if args.dry_run:
        log(f"dry-run: would rsync {host}:{remote_bin} to {local_bin}")
        return 0
    local_bin.parent.mkdir(parents=True, exist_ok=True)
    if local_bin.exists():
        local_bin.unlink()
    with _control_socket(host) as sock:
        _rsync_from_remote(host, sock, remote_bin, local_bin)
    # rsync from a file path copies into the parent; fix the filename.
    pulled = local_bin.parent / QEMU_BINARY
    if pulled != local_bin and pulled.exists():
        pulled.rename(local_bin)
    pulled.chmod(pulled.stat().st_mode | 0o111)
    log(f"pulled {local_bin}")
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    host = args.host
    root = args.root
    remote_bin = f"{root}/{BUILD_DIR}/{QEMU_BINARY}"
    tag = args.tag or f"run-{int(time.time())}"
    runs = f"{root}/{RUNS_DIR}/{tag}"
    qemu_cmd = [remote_bin, *args.qemu_args]
    # Log stdout/stderr to a file in the runs dir.
    log_file = f"{runs}/run.log"
    cmd = " ".join(shlex.quote(str(a)) for a in qemu_cmd)
    full = f"{cmd} > {log_file} 2>&1; echo rc=$?"
    if args.dry_run:
        log(f"dry-run: would create {host}:{runs} and run {full}")
        return 0
    _remote_mkdir(host, None, runs)
    with _control_socket(host) as sock:
        res = _remote(host, sock, [full], check=False)
    log(f"run log at {host}:{log_file}")
    return res.returncode


def _qemu_debug_flags(args: argparse.Namespace) -> str:
    flags = ""
    if getattr(args, "qemu_debug", None):
        flags += f" -d {shlex.quote(args.qemu_debug)}"
    if getattr(args, "qemu_log", None):
        flags += f" -D {shlex.quote(args.qemu_log)}"
    return flags


def cmd_test(args: argparse.Namespace) -> int:
    host = args.host
    root = args.root
    tag = args.tag or f"test-{int(time.time())}"
    runs = f"{root}/{RUNS_DIR}/{tag}"
    remote_bin = f"{root}/{BUILD_DIR}/{QEMU_BINARY}"
    machine = args.machine or "g6lc-unnamed"
    debug = _qemu_debug_flags(args)
    if args.ai_island and not getattr(args, "qemu_debug", None):
        debug = " -d unimp"
    if args.dry_run:
        log(f"dry-run: would create {host}:{runs} and run selected remote tests")
        return 0
    _remote_mkdir(host, None, runs)

    if args.smoke:
        timeout = args.timeout or 20
        log_file = f"{runs}/opensbi-smoke.log"
        cmd = (
            f"timeout {timeout} {remote_bin} -M {machine} -m 256 -nographic "
            f"{debug} -bios default > {log_file} 2>&1 || true"
        )
        with _control_socket(host) as sock:
            if args.dry_run:
                log(f"dry-run: {cmd}")
                return 0
            _remote(host, sock, [cmd])
            grep_cmd = (
                f'{_env(append_path=True, quote=True)}'
                f'grep -E "OpenSBI|Platform Name|Domain0 Next Address|Base ISA" {log_file}'
            )
            summary = _remote(host, sock, [grep_cmd], check=False, capture=True)
        log("OpenSBI smoke summary:")
        for line in summary.stdout.splitlines():
            log(f"  {line}")
        if "OpenSBI" not in summary.stdout:
            err("OpenSBI banner not found in smoke log")
            return 1
        log(f"smoke log at {host}:{log_file}")

    if args.plugin:
        # Build the plugin on the remote and run a short OpenSBI boot with it loaded.
        plugin_so = f"{root}/{BUILD_DIR}/contrib/plugins/lib{machine}.so"
        log_file = f"{runs}/plugin-smoke.log"
        plugin_arg = ""
        if args.plugin_trace:
            plugin_arg += f",trace={args.plugin_trace}"
        if args.plugin_tensor:
            plugin_arg += f",tensor={args.plugin_tensor}"
        build_cmd = (
            f"{_env(extra=_TOOLCHAIN_PATH, append_path=True)}"
            f"ninja -C {root}/{BUILD_DIR} contrib-plugins"
        )
        run_cmd = (
            f"{remote_bin} -M {machine} -m 256 -nographic {debug} "
            f"-bios default -plugin {plugin_so}{plugin_arg} > {log_file} 2>&1 & sleep 5; kill %1 2>/dev/null || true"
        )
        with _control_socket(host) as sock:
            if args.dry_run:
                log(f"dry-run: {build_cmd}; {run_cmd}")
                return 0
            _remote(host, sock, [build_cmd])
            if args.plugin_trace:
                _remote(host, sock, [f"mkdir -p $(dirname {shlex.quote(args.plugin_trace)})"])
            if args.plugin_tensor:
                _remote(host, sock, [f"mkdir -p $(dirname {shlex.quote(args.plugin_tensor)})"])
            _remote(host, sock, [run_cmd])
            grep_cmd = (
                f'{_env(append_path=True, quote=True)}'
                f'grep -E "g6lc|plugin" {log_file}'
            )
            summary = _remote(host, sock, [grep_cmd], check=False, capture=True)
        if summary.stdout:
            log("plugin smoke output:")
            for line in summary.stdout.splitlines()[:20]:
                log(f"  {line}")
        log(f"plugin smoke log at {host}:{log_file}")

    def _pull_tensor_artifact() -> None:
        if not args.plugin_tensor:
            return
        remote_tensor = args.plugin_tensor
        if not remote_tensor.startswith("/"):
            remote_tensor = f"{runs}/{remote_tensor}"
        local_tensor = package_root() / "out" / "remote_runs" / tag / "tensor.json"
        if args.dry_run:
            log(f"dry-run: would pull {host}:{remote_tensor} to {local_tensor}")
            return
        local_tensor.parent.mkdir(parents=True, exist_ok=True)
        with _control_socket(host) as sock:
            _rsync_from_remote(host, sock, remote_tensor, local_tensor)
        log(f"pulled tensor trace to {local_tensor}")

    def _pull_trace_artifact() -> None:
        if not args.plugin_trace:
            return
        remote_trace = args.plugin_trace
        if not remote_trace.startswith("/"):
            remote_trace = f"{runs}/{remote_trace}"
        local_trace = package_root() / "out" / "remote_runs" / tag / "trace.json"
        if args.dry_run:
            log(f"dry-run: would pull {host}:{remote_trace} to {local_trace}")
            return
        local_trace.parent.mkdir(parents=True, exist_ok=True)
        with _control_socket(host) as sock:
            _rsync_from_remote(host, sock, remote_trace, local_trace)
        log(f"pulled trace file to {local_trace}")

    if args.ai_island:
        ai_base = args.ai_base
        ai_len = args.ai_len
        uart_base = args.uart_base
        plugin_so = f"{root}/{BUILD_DIR}/contrib/plugins/lib{machine}.so"
        log_file = f"{runs}/ai-island-smoke.log"
        plugin_arg = ""
        if args.plugin_trace:
            plugin_arg += f",trace={args.plugin_trace}"
        if args.plugin_tensor:
            plugin_arg += f",tensor={args.plugin_tensor}"
        build_cmd = f"{_env()}ninja -C {root}/{BUILD_DIR} contrib-plugins"
        payload_src = f"{root}/{PAYLOAD_DIR}/ai_island_smoke.S"
        payload_lds = f"{root}/{PAYLOAD_DIR}/ai_island_smoke.lds"
        payload_elf = f"{runs}/ai_island_smoke.elf"

        with _control_socket(host) as sock:
            _remote_mkdir(host, sock, f"{root}/{PAYLOAD_DIR}")
            _rsync_to_remote(
                host,
                sock,
                package_root() / "tools" / "remote" / "payload",
                f"{root}/{PAYLOAD_DIR}",
            )
            cc_cmd = (
                f'{_env(extra=f"{_TOOLCHAIN_PATH}:/opt/testharness/toolchains/riscv-*/bin", append_path=True, quote=True)}'
                'for c in riscv-none-elf-gcc riscv64-unknown-elf-gcc riscv64-none-elf-gcc riscv64-linux-gnu-gcc; '
                'do command -v $c && exit 0; done; exit 1'
            )
            cc_res = _remote(host, sock, [cc_cmd], check=False, capture=True)
            if cc_res.returncode != 0 or not cc_res.stdout.strip():
                err("no RISC-V cross compiler found on the remote builder")
                return 1
            cc = cc_res.stdout.strip().splitlines()[0].strip()
            if args.dry_run:
                log(f"dry-run: {build_cmd}")
                log(f"dry-run: compile payload with {cc}")
                log(f"dry-run: run {machine} with payload and {plugin_so}")
                return 0
            _remote(host, sock, [build_cmd])
            compile_cmd = (
                f"{_env(extra=_TOOLCHAIN_PATH, append_path=True, quote=True)}"
                f"{cc} -march=rv64imac -mabi=lp64 -nostdlib "
                f"-DAI_BASE={ai_base} -DUART_BASE={uart_base} "
                f"-T {payload_lds} {payload_src} -o {payload_elf}"
            )
            _remote(host, sock, [compile_cmd])
            if args.plugin_trace:
                _remote(host, sock, [f"mkdir -p $(dirname {shlex.quote(args.plugin_trace)})"])
            if args.plugin_tensor:
                _remote(host, sock, [f"mkdir -p $(dirname {shlex.quote(args.plugin_tensor)})"])
            run_cmd = (
                f"{remote_bin} -M {machine} -m 256 -nographic {debug} "
                f"-bios none -kernel {payload_elf} -plugin {plugin_so}{plugin_arg} "
                f"> {log_file} 2>&1 & sleep 5; kill %1 2>/dev/null || true"
            )
            _remote(host, sock, [run_cmd])
            summary = _remote(host, sock, ["cat", log_file], check=False, capture=True)
        if summary.returncode == 0 and summary.stdout:
            log("AI-island smoke log:")
            for line in summary.stdout.splitlines()[:40]:
                log(f"  {line}")
        text = summary.stdout or ""
        ai_ok = summary.returncode == 0 and "AI_OK" in text
        ai_count = 0
        for line in text.splitlines():
            if "ai_island=" in line:
                try:
                    ai_count = max(ai_count, int(line.split("ai_island=")[1].split()[0]))
                except (ValueError, IndexError):
                    pass
            # The unimplemented-device log is a fallback when the plugin's
            # atexit summary is not flushed (QEMU is killed after the sleep).
            if "g6lc,ai-island:" in line and ("unimplemented device read" in line or "unimplemented device write" in line):
                ai_count += 1
        if ai_ok and ai_count > 0:
            log(f"AI-island smoke PASSED (ai_island_count={ai_count})")
            log(f"AI-island log at {host}:{log_file}")
            _pull_tensor_artifact()
            _pull_trace_artifact()
            return 0
        else:
            err(f"AI-island smoke FAILED: AI_OK={ai_ok}, ai_island_count={ai_count}")
            log(f"AI-island log at {host}:{log_file}")
            return 1

    _pull_tensor_artifact()
    return 0


def cmd_clean(args: argparse.Namespace) -> int:
    host = args.host
    root = args.root
    what = []
    if args.build:
        what.append(f"{root}/{BUILD_DIR}")
    if args.runs:
        what.append(f"{root}/{RUNS_DIR}")
    if not what:
        what = [f"{root}/{BUILD_DIR}", f"{root}/{RUNS_DIR}"]
    if args.dry_run:
        log(f"dry-run: would rm -rf on {host}: {', '.join(what)}")
        return 0
    with _control_socket(host) as sock:
        for p in what:
            _remote(host, sock, ["rm", "-rf", p])
    log(f"cleaned {', '.join(what)} on {host}")
    return 0


def cmd_remote_build(args: argparse.Namespace) -> int:
    """Convenience: sync, configure, build, pull, (optionally) test."""
    log("remote-build: sync")
    rc = cmd_sync(args)
    if rc != 0:
        return rc
    log("remote-build: configure")
    rc = cmd_configure(args)
    if rc != 0:
        return rc
    log("remote-build: build")
    rc = cmd_build(args)
    if rc != 0:
        return rc
    if not args.no_pull:
        log("remote-build: pull")
        rc = cmd_pull(args)
        if rc != 0:
            return rc
    if args.test or args.test_plugin or args.test_ai:
        log("remote-build: test")
        test_args = argparse.Namespace(
            host=args.host,
            root=args.root,
            smoke=args.test,
            plugin=args.test_plugin,
            ai_island=args.test_ai,
            machine=args.machine,
            ai_base=args.ai_base,
            ai_len=args.ai_len,
            uart_base=args.uart_base,
            tag=args.tag,
            dry_run=args.dry_run,
            timeout=args.timeout,
            qemu_debug=args.qemu_debug,
            qemu_log=args.qemu_log,
            plugin_trace=args.plugin_trace,
            plugin_tensor=args.plugin_tensor,
        )
        rc = cmd_test(test_args)
        if rc != 0:
            return rc
    return 0


# --------------------------------------------------------------------------- argparse


def _add_common(p: argparse.ArgumentParser) -> None:
    p.add_argument("--host", default=DEFAULT_HOST, help="remote SSH host (default: ovh_calltorch)")
    p.add_argument("--root", default=DEFAULT_ROOT, help="remote work root (default: /opt/testharness/g6lc-qemu)")
    p.add_argument("--dry-run", action="store_true", help="print what would be run")


def _add_build_opts(p: argparse.ArgumentParser) -> None:
    p.add_argument("--target", default=QEMU_TARGET, help="QEMU target list")
    p.add_argument("--debug", action="store_true", help="pass --enable-debug to configure")
    p.add_argument("--trace", default=None, help="enable trace backend (e.g. log)")
    p.add_argument("--extra", action="append", default=None, help="extra configure flags")
    p.add_argument("-j", "--jobs", type=int, default=None, help="ninja parallelism")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="g6q_remote.py",
        description="Remote QEMU build and test proxy for g6lc_qemu.",
    )
    ap.add_argument("--host", default=DEFAULT_HOST, help="default remote SSH host")
    ap.add_argument("--root", default=DEFAULT_ROOT, help="default remote work root")

    sub = ap.add_subparsers(dest="verb", required=True)

    p = sub.add_parser("doctor", help="probe local and remote toolchain")
    _add_common(p)
    p.set_defaults(fn=cmd_doctor)

    p = sub.add_parser("sync", help="rsync qemu/ source to the remote builder")
    _add_common(p)
    p.set_defaults(fn=cmd_sync)

    p = sub.add_parser("configure", help="run meson setup on the remote builder")
    _add_common(p)
    _add_build_opts(p)
    p.set_defaults(fn=cmd_configure)

    p = sub.add_parser("build", help="run ninja on the remote builder")
    _add_common(p)
    _add_build_opts(p)
    p.set_defaults(fn=cmd_build)

    p = sub.add_parser("pull", help="copy the built qemu-system-riscv64 back")
    _add_common(p)
    p.set_defaults(fn=cmd_pull)

    p = sub.add_parser("run", help="run a command through the remote qemu binary")
    _add_common(p)
    p.add_argument("--tag", default=None, help="run tag (defaults to timestamp)")
    p.add_argument("qemu_args", nargs=argparse.REMAINDER, help="arguments passed to qemu-system-riscv64")
    p.set_defaults(fn=cmd_run)

    p = sub.add_parser("test", help="remote smoke/plugin/AI-tensor tests")
    _add_common(p)
    p.add_argument("--smoke", action="store_true", help="run OpenSBI smoke test")
    p.add_argument("--plugin", action="store_true", help="run generated plugin smoke test")
    p.add_argument("--ai-island", action="store_true", help="run AI-island smoke test")
    p.add_argument("--machine", default=None, help="g6lc machine name (default: g6lc-unnamed)")
    p.add_argument("--ai-base", default="0x40000000", help="AI-island MMIO base")
    p.add_argument("--ai-len", default="0x1000", help="AI-island MMIO length")
    p.add_argument("--uart-base", default="0x10000000", help="UART MMIO base")
    p.add_argument("--tag", default=None, help="test tag")
    p.add_argument("--timeout", type=int, default=None, help="smoke timeout in seconds")
    p.add_argument("--qemu-debug", default=None, help="QEMU -d categories")
    p.add_argument("--qemu-log", default=None, help="QEMU -D log file")
    p.add_argument("--plugin-trace", default=None, help="plugin trace=PATH argument")
    p.add_argument("--plugin-tensor", default=None, help="plugin tensor=PATH argument; pulled back as a local tensor.json artifact")
    p.set_defaults(fn=cmd_test)

    p = sub.add_parser("clean", help="remove remote build/run directories")
    _add_common(p)
    p.add_argument("--build", action="store_true", help="clean build dir")
    p.add_argument("--runs", action="store_true", help="clean runs dir")
    p.set_defaults(fn=cmd_clean)

    p = sub.add_parser(
        "remote-build",
        help="convenience: sync, configure, build, pull, and optional smoke test",
    )
    _add_common(p)
    _add_build_opts(p)
    p.add_argument("--no-pull", action="store_true", help="skip pulling the binary back")
    p.add_argument("--test", action="store_true", help="run OpenSBI smoke after build")
    p.add_argument("--test-plugin", action="store_true", help="also run plugin smoke")
    p.add_argument("--test-ai", action="store_true", help="also run AI-island smoke")
    p.add_argument("--machine", default=None, help="g6lc machine name for tests (default: g6lc-unnamed)")
    p.add_argument("--ai-base", default="0x40000000", help="AI-island MMIO base")
    p.add_argument("--ai-len", default="0x1000", help="AI-island MMIO length")
    p.add_argument("--uart-base", default="0x10000000", help="UART MMIO base")
    p.add_argument("--tag", default=None, help="test tag")
    p.add_argument("--timeout", type=int, default=None, help="smoke timeout")
    p.add_argument("--qemu-debug", default=None, help="QEMU -d categories")
    p.add_argument("--qemu-log", default=None, help="QEMU -D log file")
    p.add_argument("--plugin-trace", default=None, help="plugin trace=PATH argument")
    p.add_argument("--plugin-tensor", default=None, help="plugin tensor=PATH argument; pulled back as a local tensor.json artifact")
    p.set_defaults(fn=cmd_remote_build)

    args = ap.parse_args(argv)
    return int(args.fn(args))


if __name__ == "__main__":
    sys.exit(main())
