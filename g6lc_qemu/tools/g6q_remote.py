#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# g6q_remote.py — remote QEMU build + test proxy for g6lc_qemu.
#
# Environment overrides (use these on a fresh host; the fallbacks are the original
# ovh_calltorch testharness layout):
#   G6Q_REMOTE_HOST        SSH host (default: ovh_calltorch)
#   G6Q_REMOTE_ROOT        Remote work root (default: /opt/testharness/g6lc-qemu)
#   G6Q_REMOTE_KEY         SSH private key path
#   G6Q_REMOTE_PASS        Passphrase for the key (preferred over G6Q_REMOTE_CREDS)
#   G6Q_REMOTE_CREDS       File whose first line is the passphrase
#   G6Q_REMOTE_XPACK_BIN   Remote xPack toolchain .../bin directory
#   G6Q_SSH_BIN            SSH command (default: ssh; supports wsl ssh)
#   G6Q_RSYNC_BIN          Rsync command (default: rsync; supports wsl rsync)
#   G6Q_SSH_CONTROL        Path to the SSH ControlMaster socket
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
#   python tools/g6q.py install-qemu --package E:\cva6 --target g6lc64_ai   (emit into qemu/)
#   python tools/g6q_remote.py remote-build --machine g6lc-g6lc64_ai --test --test-ai --controls
#     = sync (sentinel-verified), configure, build (artifact-verified), pull, test
#
# This is a *build* proxy; it does not synthesize or simulate RTL/uncore.
# Those remain the responsibility of the host monorepo's testharness.

from __future__ import annotations

import argparse
import json
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

from env_common import apply_env, out_dir, package_root, riscv_toolchain_bin
from platform_constants import host_tool, xpack_riscv

# remote/payload_flags is not a package dependency; it is loaded from the same tree.
if (package_root() / "tools" / "remote").is_dir():
    sys.path.insert(0, str(package_root() / "tools" / "remote"))
from payload_flags import compile_flags, generate_payload_lds

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


def _platform_remote_pass() -> str | None:
    cache = package_root().parent / "build-platform" / ".remote-ssh-creds"
    try:
        data = json.loads(cache.read_text(encoding="utf-8"))
        entry = (data.get("hosts") or {}).get(DEFAULT_HOST) or {}
        val = entry.get("passphrase")
        return val if isinstance(val, str) and val else None
    except (OSError, ValueError, AttributeError):
        return None


if not _REMOTE_PASS:
    _REMOTE_PASS = _platform_remote_pass()

_REMOTE_KEY = os.environ.get("G6Q_REMOTE_KEY")

DEFAULT_SSH = shlex.split(os.environ.get("G6Q_SSH_BIN", "ssh"))
DEFAULT_RSYNC = shlex.split(os.environ.get("G6Q_RSYNC_BIN", "rsync"))
_EXE = ".exe" if _WINDOWS else ""

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

# Files whose bytes must agree on both sides after `sync`. The generated machines are
# wired through exactly these, so a sync that did not carry a freshly installed machine
# cannot pass the check. Exit codes are transport (a `conhost wsl ...` wrapper returns
# conhost's status, not the child's); the artifact is the verdict.
SYNC_SENTINELS = (
    "hw/riscv/meson.build",
    "target/riscv/meson.build",
    "configs/targets/riscv64-softmmu.mak",
    "target/riscv/translate.c",
)

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
    timeout: float | None = None,
) -> subprocess.CompletedProcess:
    log("+ " + " ".join(str(c) for c in cmd))
    env = _remote_env(env)
    try:
        return subprocess.run(
            [str(c) for c in cmd],
            cwd=str(cwd) if cwd else None,
            env=env,
            check=check,
            capture_output=capture,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        # A hung remote step must fail the pass rather than block it forever. The
        # returned object keeps the caller's `res.returncode` contract.
        err(f"timed out after {timeout}s: {' '.join(str(c) for c in cmd)}")
        return subprocess.CompletedProcess(
            cmd,
            124,
            (exc.stdout or "") if capture else None,
            (exc.stderr or "") if capture else None,
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
    """Open a persistent SSH ControlMaster socket for the invocation.

    If a valid socket already exists, reuse it.  Otherwise start a new master
    and fail loudly if it cannot establish the socket.
    """
    if _WINDOWS:
        # Windows cannot use Unix-domain control sockets; fall back to per-call SSH.
        yield None
        return
    sock = Path(os.environ.get("G6Q_SSH_CONTROL", f"/tmp/g6q-remote-{os.getuid()}-{host}.sock"))
    if sock.parent and not sock.parent.exists():
        sock.parent.mkdir(parents=True, exist_ok=True)
    master: subprocess.Popen | None = None
    if sock.exists():
        # A socket left by a crashed run is not a usable master: every command through it
        # hangs or fails with a stale-connection error that reads like an auth problem.
        check = _run(
            [str(c) for c in _ssh_base(host, None)]
            + ["-O", "check", "-o", f"ControlPath={sock}"],
            capture=True,
            check=False,
            timeout=10,
        )
        if check.returncode == 0:
            log(f"reusing control socket {sock}")
            try:
                yield sock
            finally:
                # Existing master keeps running; we did not start this one.
                pass
            return
        log(f"removing stale control socket {sock}")
        sock.unlink(missing_ok=True)
    # Open the master connection in the background.
    cmd = _ssh_base(host, None) + ["-M", "-N", "-o", f"ControlPath={sock}"]
    env = _remote_env(None)
    master = subprocess.Popen(
        [str(c) for c in cmd],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=env,
    )
    try:
        # Give the master a moment to establish (5 s is generous for a LAN hop).
        for _ in range(25):
            if sock.exists() and master.poll() is None:
                break
            time.sleep(0.2)
        if not sock.exists() or master.poll() is not None:
            if master.poll() is None:
                master.terminate()
                try:
                    master.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    master.kill()
            err(f"SSH ControlMaster to {host} failed to create {sock}")
            raise RuntimeError(f"SSH ControlMaster to {host} failed")
        log(f"opened control socket {sock}")
        yield sock
    finally:
        if master is not None and master.poll() is None:
            master.terminate()
            try:
                master.wait(timeout=5)
            except subprocess.TimeoutExpired:
                master.kill()


def _remote(
    host: str,
    sock: Path | None,
    cmd: list[str],
    check: bool = True,
    capture: bool = False,
    timeout: float | None = None,
) -> subprocess.CompletedProcess:
    ssh = _ssh_base(host, sock)
    return _run(ssh + cmd, check=check, capture=capture, timeout=timeout)


def _step_timeout(args: argparse.Namespace, default: float) -> float:
    """Wall-clock ceiling for one remote step, in seconds.

    Every remote step gets a ceiling because the alternative is a pass that neither
    succeeds nor fails: `configure`, `ninja` and a QEMU run can all block indefinitely on
    a wedged builder, and an SSH session that never returns looks identical to a slow one.
    `--step-timeout 0` disables the ceiling for a deliberately long soak.
    """
    override = getattr(args, "step_timeout", None)
    if override is None:
        return default
    return None if override <= 0 else float(override)


# Link flags every in-guest payload is built with, regardless of toolchain.
#
# `-static -no-pie --build-id=none` are load-bearing, not hygiene: a Linux-targeting cross
# compiler (riscv64-linux-gnu-gcc) otherwise emits a dynamic executable whose program
# headers cannot fit in front of .text at DRAM base, so the linker places the LOAD segment
# one page *below* it. QEMU then loads nothing and the reset vector jumps into unmapped
# memory — the payload hangs with no output. A bare-metal toolchain hides the problem, so
# the failure only appears when the builder's toolchain changes.
PAYLOAD_LINK_FLAGS = [
    "-nostdlib",
    "-nostartfiles",
    "-static",
    "-no-pie",
    "-Wl,--build-id=none",
]

_BASE_PATH = "/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"


def _xpack_remote_bin_dir() -> str:
    """Remote xPack toolchain bin directory.

    Environment override `G6Q_REMOTE_XPACK_BIN` wins; otherwise derive from
    `platform-constants.toml`.
    """
    override = os.environ.get("G6Q_REMOTE_XPACK_BIN")
    if override:
        return override
    ref = xpack_riscv()["ref"]
    return f"/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-{ref}/bin"


# Prefixes used by the contained xPack toolchain and common system packages.
_RISCV_CC_PREFIXES = ["riscv-none-elf-", "riscv64-unknown-elf-", "riscv64-none-elf-", "riscv64-linux-gnu-"]


def _local_riscv_cc() -> str | None:
    """Find a RISC-V cross-compiler in the contained toolchain or on PATH."""
    bin_dir = riscv_toolchain_bin()
    candidates: list[Path] = []
    if bin_dir is not None:
        candidates.extend(
            bin_dir / f"{prefix}gcc{_EXE}" for prefix in _RISCV_CC_PREFIXES
        )
    for cc in candidates:
        if cc.is_file():
            return str(cc)
    path = apply_env().get("PATH", os.environ.get("PATH", ""))
    for prefix in _RISCV_CC_PREFIXES:
        cc = shutil.which(f"{prefix}gcc", path=path)
        if cc:
            return cc
    return None


def _compile_payload_local(payload_stem: str, payload_extra: list[str], local_elf: Path, payload_lds: Path) -> int:
    """Compile the AI-tensor smoke payload locally using the contained toolchain."""
    cc = _local_riscv_cc()
    if not cc:
        err("no local RISC-V cross-toolchain found; run `python tools/g6q.py setup-riscv`")
        return 1
    payload_dir = package_root() / "tools" / "remote" / "payload"
    payload_src = payload_dir / f"{payload_stem}.S"
    cmd = [
        cc,
        "-march=rv64imac",
        "-mabi=lp64",
        *PAYLOAD_LINK_FLAGS,
        *payload_extra,
        "-T",
        str(payload_lds),
        str(payload_src),
        "-o",
        str(local_elf),
    ]
    log(f"local payload compile: {local_elf}")
    return subprocess.run(cmd, check=False).returncode


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


def _remote_mkdir(host: str, sock: Path | None, path: str, timeout: float | None = None) -> None:
    res = _remote(host, sock, ["mkdir", "-p", path], check=False, timeout=timeout)
    if res.returncode != 0:
        raise RuntimeError(f"mkdir {path} on {host} failed (rc={res.returncode})")



def _rsync_to_remote(
    host: str,
    sock: Path | None,
    local: Path,
    remote_path: str,
    excludes: list[str] | None = None,
    dry_run: bool = False,
    timeout: float | None = None,
) -> None:
    base = _rsync_base(host, sock)
    if dry_run:
        base += ["--dry-run"]
    for e in excludes or []:
        base += ["--exclude", e]
    if _WINDOWS and "wsl" in DEFAULT_RSYNC[:2]:
        src = _wsl_path(local)
    else:
        src = str(local)
    if local.is_dir():
        src += "/"
        remote_path += "/"
    base += [src, f"{host}:{remote_path}"]
    res = _run(base, check=False, timeout=timeout)
    if res.returncode != 0:
        raise RuntimeError(f"rsync to {host}:{remote_path} failed (rc={res.returncode})")


def _rsync_from_remote(
    host: str,
    sock: Path | None,
    remote_path: str,
    local: Path,
    dry_run: bool = False,
    timeout: float | None = None,
) -> None:
    base = _rsync_base(host, sock)
    if dry_run:
        base += ["--dry-run"]
    local.parent.mkdir(parents=True, exist_ok=True)
    if _WINDOWS and "wsl" in DEFAULT_RSYNC[:2]:
        dst = _wsl_path(local)
    else:
        dst = str(local)
    base += [f"{host}:{remote_path}", dst]
    res = _run(base, check=False, timeout=timeout)
    if res.returncode != 0:
        raise RuntimeError(f"rsync from {host}:{remote_path} failed (rc={res.returncode})")


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
        res = _remote(host, sock, ["uname", "-a"], check=False, timeout=_step_timeout(args, 60))
        if res.returncode != 0:
            err(f"cannot reach {host}: rc={res.returncode}")
            return 1

        # Remote toolchain probes
        for tool in ["python3", "ninja", "gcc", "g++", "ccache"]:
            res = _remote(host, sock, [f"{_env(append_path=True)}which {tool}"], check=False, timeout=_step_timeout(args, 30))
            status = "ok" if res.returncode == 0 else "MISSING"
            log(f"  remote {tool}: {status}")

        # Remote RISC-V cross-compiler probes (xpack, then common system packages)
        for prefix in _RISCV_CC_PREFIXES:
            res = _remote(
                host,
                sock,
                [
                    f"{_env(extra=_xpack_remote_bin_dir(), append_path=True)}"
                    f"which {prefix}gcc"
                ],
                check=False,
                timeout=_step_timeout(args, 30),
            )
            status = "ok" if res.returncode == 0 else "MISSING"
            log(f"  remote {prefix}gcc: {status}")

        # Remote directories
        _remote_mkdir(host, sock, root)
        _remote_mkdir(host, sock, f"{root}/{CACHE_DIR}")

        if getattr(args, "gl", False):
            res = _remote(
                host,
                sock,
                [
                    f"{_env(append_path=True)}"
                    "pkg-config --modversion epoxy virglrenderer gbm libdrm pixman-1"
                ],
                check=False,
                capture=True,
                timeout=_step_timeout(args, 30),
            )
            if res.returncode != 0:
                err("remote GL deps MISSING (need epoxy, virglrenderer, gbm, libdrm, pixman)")
                return 1
            for name, version in zip(
                ["epoxy", "virglrenderer", "gbm", "libdrm", "pixman"],
                res.stdout.splitlines(),
            ):
                log(f"  remote {name}: {version}")
            res = _remote(
                host,
                sock,
                ["ls -l /dev/dri 2>/dev/null || true"],
                check=False,
                capture=True,
                timeout=_step_timeout(args, 30),
            )
            if "renderD" not in res.stdout:
                log("  remote DRM render node: absent (use egl-headless/surfaceless)")
            else:
                log("  remote DRM render node: present")
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
    _remote_mkdir(host, None, remote_qemu, timeout=_step_timeout(args, 60))
    with _control_socket(host) as sock:
        _rsync_to_remote(host, sock, qemu_src, remote_qemu, SYNC_EXCLUDES, timeout=_step_timeout(args, 1800))
        if getattr(args, "gl", False):
            _repair_vhost_user_symlinks(host, sock, remote_qemu, _step_timeout(args, 60))
        mismatch = _sync_mismatch(host, sock, qemu_src, remote_qemu, _step_timeout(args, 60))
    if mismatch:
        err("sync did not land: " + "; ".join(mismatch))
        return 1
    log(f"synced qemu/ to {host}:{remote_qemu} (sentinels verified: {len(SYNC_SENTINELS)})")
    return 0


def _sync_mismatch(host: str, sock: Path | None, local_root: Path, remote_root: str, timeout: float | None) -> list[str]:
    """Positive evidence that the sync landed: sha256 of the sentinel files must agree.

    An empty or unparsable remote answer is a mismatch, never a pass (H3: absence is not
    success).
    """
    import hashlib

    want: dict[str, str] = {}
    for rel in SYNC_SENTINELS:
        path = local_root / rel
        if path.is_file():
            want[rel] = hashlib.sha256(path.read_bytes()).hexdigest()
    if not want:
        return ["no local sentinel file exists"]
    cmd = "cd " + shlex.quote(remote_root) + " && sha256sum " + " ".join(shlex.quote(r) for r in want)
    res = _remote(host, sock, [cmd], check=False, capture=True, timeout=timeout)
    got: dict[str, str] = {}
    for line in (res.stdout or "").splitlines():
        parts = line.split()
        if len(parts) == 2:
            got[parts[1].lstrip("*")] = parts[0]
    problems = []
    for rel, digest in want.items():
        if got.get(rel) != digest:
            problems.append(f"{rel}: remote {got.get(rel, 'absent')[:12]} != local {digest[:12]}")
    return problems


def _configure_args(args: argparse.Namespace, remote_qemu: str) -> str:
    cfg = f"--target-list={args.target}"
    cfg += " --disable-libvduse --disable-vduse-blk-export"
    if getattr(args, "gl", False):
        cfg += " --enable-vhost-user"
    else:
        cfg += " --disable-vhost-user"
    cfg += " --disable-vhost-user-blk-server --enable-plugins"
    if getattr(args, "gl", False):
        cfg += " --enable-opengl --enable-virglrenderer"
        cfg += f" --extra-cflags=-I{remote_qemu}/include"
    if args.debug:
        cfg += " --enable-debug"
    if args.trace:
        cfg += f" --enable-trace-backends={args.trace}"
    if args.extra:
        for e in args.extra:
            cfg += f" {e}"
    return cfg


def _repair_vhost_user_symlinks(host: str, sock: Path | None, remote_qemu: str, timeout: float | None) -> None:
    """Restore symlinks lost when a Windows checkout is rsynced as text files."""
    cmd = (
        f"cd {remote_qemu}/subprojects/libvhost-user && "
        "rm -f include/atomic.h include/compiler.h standard-headers/linux && "
        "ln -s ../../../include/qemu/atomic.h include/atomic.h && "
        "ln -s ../../../include/qemu/compiler.h include/compiler.h && "
        "ln -s ../../../include/standard-headers/linux standard-headers/linux"
    )
    res = _remote(host, sock, [cmd], check=False, timeout=timeout)
    if res.returncode != 0:
        raise RuntimeError(f"repairing vhost-user symlinks on {host} failed (rc={res.returncode})")


def cmd_configure(args: argparse.Namespace) -> int:
    host = args.host
    root = args.root
    remote_qemu = f"{root}/{REPO_DIR}"
    remote_build = f"{root}/{BUILD_DIR}"
    cfg_args = _configure_args(args, remote_qemu)
    cmd = f"cd {remote_build} && CC='ccache gcc' CXX='ccache g++' CCACHE_DIR={root}/{CACHE_DIR} {remote_qemu}/configure {cfg_args}"
    full = f"{_env()}{cmd}"
    log(f"configure: {full}")
    if args.dry_run:
        return 0
    _remote_mkdir(host, None, remote_build)
    with _control_socket(host) as sock:
        if getattr(args, "gl", False):
            _repair_vhost_user_symlinks(host, sock, remote_qemu, _step_timeout(args, 60))
        res = _remote(host, sock, [full], check=False, timeout=_step_timeout(args, 1800))
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
        stamp = _remote(host, sock, ["date", "+%s"], check=False, capture=True, timeout=_step_timeout(args, 30))
        started = int((stamp.stdout or "0").strip() or "0")
        res = _remote(host, sock, [cmd], check=False, timeout=_step_timeout(args, 7200))
        if res.returncode != 0:
            err("remote build failed")
            return res.returncode
        # Artifact check: the linked binary exists, was touched at or after the build
        # started (ninja may legitimately be a no-op on an already-built tree, so only
        # require it when the sync carried changes), and knows the requested machine.
        binary = f"{remote_build}/{QEMU_BINARY}"
        probe = _remote(host, sock, [f"stat -c %Y {shlex.quote(binary)} && {shlex.quote(binary)} -M help"],
                        check=False, capture=True, timeout=_step_timeout(args, 60))
        lines = (probe.stdout or "").splitlines()
        if probe.returncode != 0 or not lines:
            err(f"build produced no verifiable binary at {host}:{binary}")
            return 1
        try:
            mtime = int(lines[0].strip())
        except ValueError:
            err(f"cannot read the binary's mtime ({lines[0]!r})")
            return 1
        machine = getattr(args, "machine", None)
        if machine and not any(l.split() and l.split()[0] == machine for l in lines[1:]):
            err(f"built binary does not list machine {machine!r} (-M help)")
            return 1
        if started and mtime < started - 5 and getattr(args, "expect_relink", False):
            err(f"binary mtime {mtime} predates the build start {started}: nothing was relinked")
            return 1
    log(f"built in {host}:{remote_build} (binary mtime {mtime}{', machine ' + machine if machine else ''})")
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
    # Keep the previous binary until the new one has arrived: deleting first turns a
    # transport failure into "no local emulator at all".
    staging = local_bin.with_suffix(local_bin.suffix + ".incoming")
    staging.unlink(missing_ok=True)
    with _control_socket(host) as sock:
        _rsync_from_remote(host, sock, remote_bin, staging, timeout=_step_timeout(args, 180))
    if not staging.is_file():
        err(f"pull produced no file at {staging}; remote binary missing or rsync failed")
        return 1
    staging.chmod(staging.stat().st_mode | 0o111)
    staging.replace(local_bin)
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
        res = _remote(host, sock, [full], check=False, timeout=_step_timeout(args, 900))
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
    if getattr(args, "queue", False) and not args.ai_island:
        err("--queue requires --ai-island")
        return 1
    if args.dry_run:
        log(f"dry-run: would create {host}:{runs} and run selected remote tests")
        return 0
    _remote_mkdir(host, None, runs, timeout=_step_timeout(args, 60))

    if args.ai_island and not args.plugin_tensor:
        args.plugin_tensor = "tensor.json"

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
            _remote(host, sock, [cmd], timeout=_step_timeout(args, timeout + 30))
            grep_cmd = (
                f'{_env(append_path=True, quote=True)}'
                f'grep -E "OpenSBI|Platform Name|Domain0 Next Address|Base ISA" {log_file}'
            )
            summary = _remote(host, sock, [grep_cmd], check=False, capture=True, timeout=_step_timeout(args, 60))
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
            f"{_env(extra=_xpack_remote_bin_dir(), append_path=True)}"
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
            _remote(host, sock, [build_cmd], timeout=_step_timeout(args, 600))
            if args.plugin_trace:
                _remote(host, sock, [f"mkdir -p $(dirname {shlex.quote(args.plugin_trace)})"], timeout=_step_timeout(args, 30))
            if args.plugin_tensor:
                _remote(host, sock, [f"mkdir -p $(dirname {shlex.quote(args.plugin_tensor)})"], timeout=_step_timeout(args, 30))
            _remote(host, sock, [run_cmd], timeout=_step_timeout(args, 60))
            grep_cmd = (
                f'{_env(append_path=True, quote=True)}'
                f'grep -E "g6lc|plugin" {log_file}'
            )
            summary = _remote(host, sock, [grep_cmd], check=False, capture=True, timeout=_step_timeout(args, 60))
        if summary.stdout:
            log("plugin smoke output:")
            for line in summary.stdout.splitlines()[:20]:
                log(f"  {line}")
        log(f"plugin smoke log at {host}:{log_file}")

    def _pull_tensor_artifact() -> Path | None:
        if not args.plugin_tensor:
            return None
        remote_tensor = args.plugin_tensor
        if not remote_tensor.startswith("/"):
            remote_tensor = f"{runs}/{remote_tensor}"
        local_tensor = package_root() / "out" / "remote_runs" / tag / "tensor.json"
        if args.dry_run:
            log(f"dry-run: would pull {host}:{remote_tensor} to {local_tensor}")
            return None
        local_tensor.parent.mkdir(parents=True, exist_ok=True)
        with _control_socket(host) as sock:
            _rsync_from_remote(host, sock, remote_tensor, local_tensor, timeout=_step_timeout(args, 120))
        log(f"pulled tensor trace to {local_tensor}")
        return local_tensor

    def _report_tops(local_tensor: Path | None) -> None:
        if not local_tensor or not args.model:
            return
        try:
            res = _run(
                [
                    sys.executable,
                    str(package_root() / "tools" / "ai_tensor_bridge.py"),
                    "results",
                    "--tops",
                    "--model",
                    args.model,
                    str(local_tensor),
                ],
                check=False,
            )
            if res.returncode != 0:
                err(f"TOPS report failed: {res.stderr or res.stdout}")
        except Exception as exc:
            err(f"cannot report TOPS: {exc}")

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
            _rsync_from_remote(host, sock, remote_trace, local_trace, timeout=_step_timeout(args, 120))
        log(f"pulled trace file to {local_trace}")

    if args.ai_island:
        if getattr(args, "queue", False):
            payload_stem = "ai_island_queue_smoke"
        else:
            payload_stem = "ai_island_smoke"
        ai_base = args.ai_base
        ai_len = args.ai_len
        uart_base = args.uart_base
        payload_extra: list[str] = []
        if not args.model:
            err("--ai-island requires --model to derive the payload and TOPS report")
            return 1
        try:
            import json
            with open(args.model, "r", encoding="utf-8") as f:
                model = json.load(f)
            payload_extra = compile_flags(
                model,
                ai_m=args.ai_m,
                ai_n=args.ai_n,
                ai_k=args.ai_k,
                done_ptr=args.ai_done_ptr,
            )
        except (OSError, json.JSONDecodeError, ValueError) as exc:
            err(f"cannot derive payload flags from {args.model}: {exc}")
            return 1
        plugin_so = f"{root}/{BUILD_DIR}/contrib/plugins/lib{machine}.so"
        log_file = f"{runs}/{payload_stem.replace('_', '-')}.log"
        plugin_arg = ""
        if args.plugin_trace:
            plugin_arg += f",trace={args.plugin_trace}"
        if args.plugin_tensor:
            plugin_arg += f",tensor={args.plugin_tensor}"
        build_cmd = f"{_env()}ninja -C {root}/{BUILD_DIR} contrib-plugins"
        payload_src = f"{root}/{PAYLOAD_DIR}/{payload_stem}.S"
        payload_lds = f"{root}/{PAYLOAD_DIR}/ai_island_smoke.lds"
        payload_elf = f"{runs}/{payload_stem}.elf"
        local_lds = out_dir() / "ai_island_smoke.lds"
        generate_payload_lds(model, local_lds)

        with _control_socket(host) as sock:
            _remote_mkdir(host, sock, f"{root}/{PAYLOAD_DIR}", timeout=_step_timeout(args, 60))
            _rsync_to_remote(
                host,
                sock,
                package_root() / "tools" / "remote" / "payload",
                f"{root}/{PAYLOAD_DIR}",
                timeout=_step_timeout(args, 120),
            )
            _rsync_to_remote(
                host,
                sock,
                local_lds,
                payload_lds,
                timeout=_step_timeout(args, 120),
            )

            use_local_cc = getattr(args, "local_riscv", False)
            if not use_local_cc:
                cc_cmd = (
                    f'{_env(extra=f"{_xpack_remote_bin_dir()}:/opt/testharness/toolchains/riscv-*/bin", append_path=True, quote=True)}'
                    'for c in riscv-none-elf-gcc riscv64-unknown-elf-gcc riscv64-none-elf-gcc riscv64-linux-gnu-gcc; '
                    'do command -v $c && exit 0; done; exit 1'
                )
                cc_res = _remote(host, sock, [cc_cmd], check=False, capture=True, timeout=_step_timeout(args, 60))
                use_local_cc = cc_res.returncode != 0 or not cc_res.stdout.strip()

            if args.dry_run:
                log(f"dry-run: {build_cmd}")
                log(f"dry-run: compile payload {'locally' if use_local_cc else 'on remote'}")
                log(f"dry-run: run {machine} with payload and {plugin_so}")
                return 0

            _remote(host, sock, [build_cmd], timeout=_step_timeout(args, 600))

            if use_local_cc:
                local_elf = out_dir() / f"{payload_stem}.elf"
                if _compile_payload_local(payload_stem, payload_extra, local_elf, local_lds) != 0:
                    err("local payload compile failed")
                    return 1
                _rsync_to_remote(host, sock, local_elf, payload_elf, timeout=_step_timeout(args, 120))
            else:
                cc = cc_res.stdout.strip().splitlines()[0].strip()
                compile_cmd = (
                    f"{_env(extra=_xpack_remote_bin_dir(), append_path=True, quote=True)}"
                    f"{cc} -march=rv64imac -mabi=lp64 "
                    f"{' '.join(PAYLOAD_LINK_FLAGS)} "
                    f"{' '.join(payload_extra)} "
                    f"-T {payload_lds} {payload_src} -o {payload_elf}"
                )
                _remote(host, sock, [compile_cmd], timeout=_step_timeout(args, 120))
            if args.plugin_trace:
                _remote(host, sock, [f"mkdir -p $(dirname {shlex.quote(args.plugin_trace)})"], timeout=_step_timeout(args, 30))
            if args.plugin_tensor:
                _remote(host, sock, [f"mkdir -p $(dirname {shlex.quote(args.plugin_tensor)})"], timeout=_step_timeout(args, 30))
            run_cmd = (
                f"{remote_bin} -M {machine} -m 256 -nographic {debug} "
                f"-bios none -kernel {payload_elf} -plugin {plugin_so}{plugin_arg} "
                f"> {log_file} 2>&1 & sleep 5; kill %1 2>/dev/null || true"
            )
            _remote(host, sock, [run_cmd], timeout=_step_timeout(args, 60))
            summary = _remote(host, sock, ["cat", log_file], check=False, capture=True, timeout=_step_timeout(args, 30))
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
            if ("g6lc,ai-island:" in line or "g6lc,ai-matrix:" in line) and ("unimplemented device read" in line or "unimplemented device write" in line):
                ai_count += 1
        smoke_name = payload_stem.replace('_', '-')
        if getattr(args, "controls", False):
            # Negative control: same payload, forced to print AI_NG before any island
            # traffic. The oracle must say FAILED here or every PASS above is
            # meaningless (H3 / RT-H1).
            neg_elf = f"{runs}/{payload_stem}_neg.elf"
            neg_log = f"{runs}/{payload_stem.replace('_', '-')}-neg.log"
            with _control_socket(host) as sock2:
                if use_local_cc:
                    local_neg = out_dir() / f"{payload_stem}_neg.elf"
                    if _compile_payload_local(payload_stem, payload_extra + ["-DAI_FORCE_FAIL=1"], local_neg, local_lds) != 0:
                        err("negative-control payload compile failed")
                        return 1
                    _rsync_to_remote(host, sock2, local_neg, neg_elf, timeout=_step_timeout(args, 120))
                else:
                    _remote(host, sock2, [compile_cmd.replace(f"-o {payload_elf}", f"-DAI_FORCE_FAIL=1 -o {neg_elf}")],
                            timeout=_step_timeout(args, 120))
                _remote(host, sock2, [run_cmd.replace(payload_elf, neg_elf).replace(log_file, neg_log)],
                        timeout=_step_timeout(args, 60))
                neg = _remote(host, sock2, ["cat", neg_log], check=False, capture=True, timeout=_step_timeout(args, 30))
            neg_text = neg.stdout or ""
            if "AI_OK" in neg_text or "AI_NG" not in neg_text:
                err(f"{smoke_name} NEGATIVE CONTROL did not fail as required (AI_NG present={('AI_NG' in neg_text)}, "
                    f"AI_OK present={('AI_OK' in neg_text)}); the oracle cannot say FAIL -- no PASS is valid")
                return 1
            log(f"{smoke_name} negative control FAILED as required (oracle can say FAIL)")
        if ai_ok and (getattr(args, "queue", False) or ai_count > 0):
            if getattr(args, "queue", False):
                log(f"{smoke_name} PASSED")
            else:
                log(f"{smoke_name} PASSED (ai_island_count={ai_count})")
            log(f"AI-island log at {host}:{log_file}")
            local_tensor = _pull_tensor_artifact()
            _report_tops(local_tensor)
            _pull_trace_artifact()
            return 0
        else:
            err(f"{smoke_name} FAILED: AI_OK={ai_ok}, ai_island_count={ai_count}")
            log(f"AI-island log at {host}:{log_file}")
            return 1

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
            _remote(host, sock, ["rm", "-rf", p], timeout=_step_timeout(args, 120))
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
            controls=getattr(args, "controls", False),
            plugin=args.test_plugin,
            ai_island=args.test_ai,
            machine=args.machine,
            model=args.model,
            ai_base=args.ai_base,
            ai_len=args.ai_len,
            ai_done_ptr=args.ai_done_ptr,
            ai_m=args.ai_m,
            ai_n=args.ai_n,
            ai_k=args.ai_k,
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
    p.add_argument(
        "--step-timeout",
        type=int,
        default=None,
        help="wall-clock ceiling per remote step in seconds (0 disables; default per step)",
    )


def _add_build_opts(p: argparse.ArgumentParser) -> None:
    p.add_argument("--target", default=QEMU_TARGET, help="QEMU target list")
    p.add_argument("--gl", action="store_true", help="enable OpenGL and virglrenderer")
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
    p.add_argument("--gl", action="store_true", help="also probe OpenGL/virgl build dependencies")
    p.set_defaults(fn=cmd_doctor)

    p = sub.add_parser("sync", help="rsync qemu/ source to the remote builder")
    _add_common(p)
    p.add_argument("--gl", action="store_true", help="prepare OpenGL/virgl remote sources")
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
    p.add_argument("--queue", action="store_true", help="use the queue-instruction smoke payload (requires --ai-island)")
    p.add_argument("--machine", default=None, help="g6lc machine name (default: g6lc-unnamed)")
    p.add_argument("--model", default=None, help="ingested TargetModel JSON to derive payload flags")
    p.add_argument("--ai-base", default="0x40000000", help="AI-island MMIO base")
    p.add_argument("--ai-len", default="0x1000", help="AI-island MMIO length")
    p.add_argument("--ai-done-ptr", default=None, type=int, help="completion word pointer")
    p.add_argument("--ai-m", default=1, type=int, help="GEMM m dimension for the smoke")
    p.add_argument("--ai-n", default=1, type=int, help="GEMM n dimension for the smoke")
    p.add_argument("--ai-k", default=1, type=int, help="GEMM k dimension for the smoke")
    p.add_argument("--uart-base", default="0x10000000", help="UART MMIO base")
    p.add_argument("--controls", action="store_true",
                   help="also run the negative control (payload forced to AI_NG must be classified FAILED)")
    p.add_argument("--local-riscv", action="store_true", help="compile the RISC-V payload locally with the contained toolchain")
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
    p.add_argument("--expect-relink", action="store_true",
                   help="fail the build step if the binary was not relinked after the build started")
    p.add_argument("--test", action="store_true", help="run OpenSBI smoke after build")
    p.add_argument("--test-plugin", action="store_true", help="also run plugin smoke")
    p.add_argument("--test-ai", action="store_true", help="also run AI-island smoke")
    p.add_argument("--machine", default=None, help="g6lc machine name for tests (default: g6lc-unnamed)")
    p.add_argument("--model", default=None, help="ingested TargetModel JSON to derive payload flags")
    p.add_argument("--ai-base", default="0x40000000", help="AI-island MMIO base")
    p.add_argument("--ai-len", default="0x1000", help="AI-island MMIO length")
    p.add_argument("--ai-done-ptr", default=None, type=int, help="completion word pointer")
    p.add_argument("--ai-m", default=1, type=int, help="GEMM m dimension for the smoke")
    p.add_argument("--ai-n", default=1, type=int, help="GEMM n dimension for the smoke")
    p.add_argument("--ai-k", default=1, type=int, help="GEMM k dimension for the smoke")
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
