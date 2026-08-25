#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""Remote Verilator testharness proxy over SSH.

Runs LibreCore/CVA6 simulation on a remote builder (default host alias
``ovh_calltorch``) while keeping the *per-test* payload minimal: the RTL and
toolchains are synced/provisioned once, the harness is built once, and each
subsequent test uploads only its ELF.

Remote layout (default root ``/opt/testharness``)::

    /opt/testharness/
      toolchains/          provisioned once (verilator, riscv gcc, spike)
      repo/                rsync'd RTL + build sources
      work/                build workdir (verilator --Mdir libraries)
      runs/<tag>/          per-test ELF + logs
      cache/               downloads

Subcommands
-----------
  doctor    probe local + remote for required features
  setup     provision missing remote toolchains (apt or source build)
  sync      rsync the repo subset needed to verilate
  build     build a harness flavour remotely (B | legacy)
  run       upload one ELF and run it (minimal payload)
  soak      run the OpenSBI cookie soak remotely
  py        upload Python scripts and run them with a remote thread pool
  pull      copy remote logs back
  shell     interactive ssh into the remote workdir
  clean     remove remote work/run dirs

Speed notes
-----------
* A persistent SSH ControlMaster socket is opened for the whole invocation, so
  every remote step costs one round trip instead of a full handshake.
* ``sync`` uses rsync with a whitelist; ``run`` uploads only the ELF.
* Toolchain provisioning is idempotent and stamped, so re-running is a no-op.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import traceback
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path

# --------------------------------------------------------------------------
# defaults
# --------------------------------------------------------------------------

HOST = os.environ.get("TH_REMOTE_HOST", "ovh_calltorch")
REMOTE_ROOT = os.environ.get("TH_REMOTE_ROOT", "/opt/testharness")
DEFAULT_TARGET = os.environ.get("TH_TARGET", "g6lc64_smt2")
DEFAULT_SHELL_TIMEOUT = float(os.environ.get("TH_SHELL_TIMEOUT", "60"))

# Allow overriding the ssh/rsync binaries (e.g. Windows rsync not on PATH,
# or a WSL/cygwin ssh). The default is the unqualified command found by ssh.
SSH_BIN = shlex.split(os.environ.get("TH_SSH_BIN", "ssh"))
RSYNC_BIN = shlex.split(os.environ.get("TH_RSYNC_BIN", "rsync"))

# Pinned to match monorepo-soak/rebuild-baseline.sh so remote == local results.
VERILATOR_VERSION = os.environ.get("TH_VERILATOR_VERSION", "v5.008")
XPACK_GCC_VERSION = os.environ.get("TH_XPACK_GCC_VERSION", "14.2.0-3")
XPACK_URL = (
    "https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/"
    f"v{XPACK_GCC_VERSION}/xpack-riscv-none-elf-gcc-{XPACK_GCC_VERSION}-linux-x64.tar.gz"
)

# Only what verilate actually reads. Keeps the first sync small and every
# later sync near-instant.
SYNC_INCLUDE = [
    "core/",
    "corev_apu/",
    "common/",
    "vendor/",
    "config/",
    "verif/regress/",
    "verif/tests/",
    "verif/core-v-verif/lib/",
    "verif/tb/",
    "util/",
    "software/smt2-linux/soft-ladder/mk_plat_skip.py",
    "software/smt2-linux/soft-ladder/rebuild_held_from_pin.sh",
    "software/smt2-linux/soft-ladder/build/fw_payload_diag.elf",
    "software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.pin-bc7ed11d.elf",
    "Makefile",
    "verilator_config.vlt",
    "Flist.cva6",
]

SYNC_EXCLUDE = [
    ".git/",
    "work-ver*/",
    "*.o",
    "*.d",
    "*.vcd",
    "*.fst",
    "*.log",
    "__pycache__/",
    "*.elf",
    "build-platform/workspace/build/",
    "docs/",
    "specs/",
]

FLAVOURS = {
    # flavour -> (verilator library dir, uses stock flist)
    "B": ("work-ver-smt2-fw64-B", True),
    "legacy": ("work-ver-smt2-fw64-legacy", False),
}

_DEBUG: bool = False


def log(msg: str) -> None:
    print(f"[{datetime.now().strftime('%H:%M:%S.%f')[:-3]} th-proxy] {msg}", flush=True)


def debug(msg: str) -> None:
    if _DEBUG:
        print(f"[{datetime.now().strftime('%H:%M:%S.%f')[:-3]} th-proxy DBG] {msg}",
              flush=True)


def die(msg: str, code: int = 1) -> "NoReturn":  # type: ignore[valid-type]
    ts = datetime.now().strftime('%H:%M:%S.%f')[:-3]
    print(f"[{ts} th-proxy] ERROR: {msg}", file=sys.stderr, flush=True)
    if _DEBUG:
        traceback.print_exc()
    sys.exit(code)


# --------------------------------------------------------------------------
# ssh transport
# --------------------------------------------------------------------------


class Remote:
    """SSH/rsync transport with a persistent control socket."""

    def __init__(self, host: str, verbose: bool = False, debug_mode: bool = False):
        self.host = host
        self.verbose = verbose
        self._debug = debug_mode
        self.timeout: float = 0.0
        self._ctl_dir = tempfile.mkdtemp(prefix="th-proxy-ssh-")
        self.ctl_path = os.path.join(self._ctl_dir, "cm-%r@%h:%p")
        log(f"transport init host={host} control_dir={self._ctl_dir}")
        self.ssh_config = self._resolve_ssh_config()
        self.identity = self._resolve_identity()
        debug(f"resolved ssh_config={self.ssh_config} identity={self.identity}")
        self._master: subprocess.Popen | None = None
        self._agent_owned = False
        self._unlock_key()

    @contextmanager
    def _time(self, name: str):
        t0 = time.time()
        self.dbg(f"start {name}")
        try:
            yield
        finally:
            self.dbg(f"end {name} ({time.time() - t0:.3f}s)")

    def dbg(self, msg: str) -> None:
        if self._debug or self.verbose:
            debug(msg)

    def vlog(self, msg: str) -> None:
        if self.verbose:
            log(msg)

    # -- config discovery ---------------------------------------------------

    @staticmethod
    def _win_ssh_dirs() -> list[Path]:
        out: list[Path] = []
        for user in ("etcim", "etcimon"):
            out.append(Path(f"/mnt/c/Users/{user}/.ssh"))
        return out

    def _resolve_ssh_config(self) -> Path | None:
        env = os.environ.get("TH_SSH_CONFIG")
        if env:
            p = Path(env)
            return p if p.is_file() else None
        home_cfg = Path.home() / ".ssh" / "config"
        if home_cfg.is_file() and self.host in home_cfg.read_text(errors="ignore"):
            return home_cfg
        for d in self._win_ssh_dirs():
            cfg = d / "config"
            if cfg.is_file() and self.host in cfg.read_text(errors="ignore"):
                return cfg
        return None

    def _resolve_identity(self) -> Path | None:
        """Return a key path with perms ssh will accept.

        Keys living on /mnt/c are world-readable, which OpenSSH rejects. Copy
        them into the WSL home once, with 0600.
        """
        env = os.environ.get("TH_SSH_KEY") or os.environ.get("TH_SSH_IDENTITY")
        candidates: list[Path] = []
        if env:
            candidates.append(Path(env))
        candidates.append(Path.home() / ".ssh" / "id_ed25519")
        for d in self._win_ssh_dirs():
            candidates.append(d / "id_ed25519")

        for cand in candidates:
            if not cand.is_file():
                debug(f"identity candidate missing: {cand}")
                continue
            if str(cand).startswith("/mnt/"):
                local = Path.home() / ".ssh" / cand.name
                local.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                if not local.is_file() or local.read_bytes() != cand.read_bytes():
                    local.write_bytes(cand.read_bytes())
                    log(f"copied key {cand} -> {local} (0600)")
                local.chmod(0o600)
                return local
            try:
                if cand.stat().st_mode & 0o077:
                    cand.chmod(0o600)
            except PermissionError:
                pass
            return cand
        log("WARNING: no ssh identity found; will rely on ssh-agent or password auth")
        return None

    # -- passphrase / agent -------------------------------------------------

    @staticmethod
    def passphrase_files() -> list[Path]:
        """Untracked locations searched for the key passphrase.

        The passphrase is deliberately NOT stored in the repository. Order is
        most-specific first; the first readable file wins.
        """
        env = os.environ.get("TH_SSH_PASSPHRASE_FILE")
        out = [Path(env)] if env else []
        out += [
            Path.home() / ".config" / "librecore" / "th-remote.pass",
            Path.home() / ".ssh" / "th-remote.pass",
        ]
        return out

    def _passphrase(self) -> str | None:
        val = os.environ.get("TH_SSH_PASSPHRASE")
        if val:
            return val
        for f in self.passphrase_files():
            try:
                if f.is_file():
                    txt = f.read_text(encoding="utf-8").strip()
                    if txt:
                        if self.verbose:
                            log(f"passphrase from {f}")
                        return txt
            except OSError:
                continue
        return None

    def _key_is_encrypted(self) -> bool:
        if not self.identity:
            return False
        self.dbg(f"checking whether {self.identity} is passphrase-protected")
        try:
            # Empty passphrase succeeds only on an unencrypted key.
            r = subprocess.run(
                ["ssh-keygen", "-y", "-P", "", "-f", str(self.identity)],
                capture_output=True, check=False,
            )
            encrypted = r.returncode != 0
            self.dbg(f"key encrypted={encrypted}")
            return encrypted
        except FileNotFoundError:
            return False

    def _agent_has_key(self) -> bool:
        if not self.identity:
            return False
        pub = Path(str(self.identity) + ".pub")
        if not pub.is_file():
            return False
        want = pub.read_text(errors="ignore").split()
        if len(want) < 2:
            return False
        listed = subprocess.run(["ssh-add", "-L"], capture_output=True,
                                text=True, check=False).stdout
        return want[1] in listed

    def _unlock_key(self) -> None:
        """Load an encrypted key into ssh-agent once.

        This is both the secure and the *fast* path: the key material is
        decrypted a single time, then ControlMaster reuses one authenticated
        channel for every later command.
        """
        if not self.identity or not self._key_is_encrypted():
            self.dbg("no unlock needed")
            return
        if os.environ.get("SSH_AUTH_SOCK") and self._agent_has_key():
            self.dbg("key already present in ssh-agent")
            log("key already loaded in ssh-agent")
            return

        phrase = self._passphrase()
        if phrase is None:
            log("key is passphrase-protected and no passphrase source found; "
                "ssh will prompt interactively")
            log("  set TH_SSH_PASSPHRASE, or write it to "
                f"{self.passphrase_files()[-2]}")
            return

        if not os.environ.get("SSH_AUTH_SOCK"):
            out = subprocess.run(["ssh-agent", "-s"], capture_output=True,
                                 text=True, check=False).stdout
            for line in out.splitlines():
                if line.startswith(("SSH_AUTH_SOCK=", "SSH_AGENT_PID=")):
                    k, _, v = line.partition("=")
                    os.environ[k] = v.split(";")[0]
            self._agent_owned = True
            if self.verbose:
                log(f"started ssh-agent pid={os.environ.get('SSH_AGENT_PID')}")

        # Feed the passphrase via SSH_ASKPASS; never place it on a command line
        # (argv is world-readable through /proc).
        askdir = tempfile.mkdtemp(prefix="th-proxy-ap-")
        try:
            ask = Path(askdir) / "askpass"
            ask.write_text("#!/bin/sh\ncat \"$TH_PASS_FILE\"\n", encoding="utf-8")
            ask.chmod(0o700)
            pf = Path(askdir) / "p"
            pf.write_text(phrase + "\n", encoding="utf-8")
            pf.chmod(0o600)
            env = dict(os.environ)
            env.update({
                "SSH_ASKPASS": str(ask),
                "SSH_ASKPASS_REQUIRE": "force",
                "TH_PASS_FILE": str(pf),
                "DISPLAY": env.get("DISPLAY", ":0"),
            })
            r = subprocess.run(["ssh-add", str(self.identity)], env=env,
                               stdin=subprocess.DEVNULL,
                               capture_output=True, text=True, check=False)
            if r.returncode == 0:
                log("ssh key unlocked into agent (subsequent commands are keyless)")
            else:
                log(f"ssh-add failed: {(r.stderr or '').strip()}")
        finally:
            shutil.rmtree(askdir, ignore_errors=True)

    # -- ssh plumbing -------------------------------------------------------

    def base_opts(self) -> list[str]:
        opts = [
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=30",
            "-o", f"ControlPath={self.ctl_path}",
        ]
        if self.ssh_config:
            opts += ["-F", str(self.ssh_config)]
        if self.identity:
            opts += ["-i", str(self.identity), "-o", "IdentitiesOnly=yes"]
        return opts

    def start_master(self) -> None:
        if self._master is not None:
            self.dbg("ControlMaster already running")
            return
        cmd = [*SSH_BIN, *self.base_opts(), "-M", "-N", "-o", "ControlPersist=300", self.host]
        self.vlog("ssh master: " + " ".join(shlex.quote(c) for c in cmd))
        self._master = subprocess.Popen(
            cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE
        )
        # Wait for the socket to appear so the first real command reuses it.
        for i in range(50):
            if self.check("true", quiet=True) == 0:
                self.dbg(f"ControlMaster ready after {i*0.2:.1f}s")
                return
            if self._master.poll() is not None:
                err = (self._master.stderr.read() or b"").decode(errors="replace")
                die(f"cannot open ssh session to {self.host}\n{err.strip()}")
            time.sleep(0.2)
        die("ControlMaster did not become ready within 10s")

    def close(self) -> None:
        if self._master is not None:
            self.dbg("closing ControlMaster")
            subprocess.run(
                [*SSH_BIN, *self.base_opts(), "-O", "exit", self.host],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
            )
            self._master = None
        shutil.rmtree(self._ctl_dir, ignore_errors=True)
        # Only tear down an agent we started ourselves; never a user's agent.
        if self._agent_owned and os.environ.get("SSH_AGENT_PID"):
            self.dbg(f"killing owned ssh-agent pid={os.environ.get('SSH_AGENT_PID')}")
            subprocess.run(["ssh-agent", "-k"], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, check=False)
            self._agent_owned = False
        self.dbg("transport closed")

    # -- command execution --------------------------------------------------

    def run(self, script: str, check: bool = True, capture: bool = False,
            tty: bool = False, heartbeat: bool = True,
            timeout: float | None = None) -> subprocess.CompletedProcess:
        if timeout is None:
            timeout = self.timeout
        cmd = [*SSH_BIN, *self.base_opts()]
        if tty:
            cmd.append("-t")
        else:
            # No pty: force it off and detach remote stdin so the remote command
            # cannot steal the caller's terminal (which left the local shell on a
            # bare prompt with the output half-drawn).
            cmd += ["-T", "-n"]
        # Pass the whole bash -lc invocation as a single ssh command so spaces
        # in the script are preserved by the remote shell.
        cmd += [self.host, f"bash -lc {shlex.quote(script)}"]
        self.vlog(f"remote$ {script}")
        if timeout > 0:
            self.vlog(f"timeout={timeout:.0f}s")
        t0 = time.time()
        if not capture:
            proc = subprocess.Popen(
                cmd,
                text=True,
                stdin=None if tty else subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            saw_output = False
            last_char = "\n"
            last_out = time.time()
            timed_out = False
            while True:
                ready = False
                try:
                    import select
                    ready = select.select([proc.stdout], [], [], 1.0)[0] != []
                except (ImportError, AttributeError):
                    proc.wait(timeout=1.0)
                    ready = False
                if ready:
                    line = proc.stdout.readline()
                    if line:
                        sys.stdout.write(line)
                        sys.stdout.flush()
                        saw_output = True
                        last_char = line[-1]
                        last_out = time.time()
                if proc.poll() is not None:
                    # drain any remaining output
                    for line in proc.stdout:
                        sys.stdout.write(line)
                        sys.stdout.flush()
                        saw_output = True
                        last_char = line[-1]
                    # Always leave the caller's terminal at column 0 so the next
                    # prompt does not overwrite the last line of output.
                    if saw_output and last_char != "\n":
                        sys.stdout.write("\n")
                        sys.stdout.flush()
                    break
                elapsed = time.time() - t0
                if timeout > 0 and elapsed > timeout:
                    log(f"remote command timed out after {elapsed:.0f}s; killing")
                    proc.terminate()
                    try:
                        proc.wait(timeout=5.0)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
                    timed_out = True
                    break
                if heartbeat and time.time() - last_out > 30.0:
                    log(f"still running... {elapsed:.0f}s elapsed")
                    last_out = time.time()
            proc = subprocess.CompletedProcess(cmd, -1 if timed_out else proc.returncode, stdout="", stderr="")
        else:
            try:
                proc = subprocess.run(
                    cmd,
                    text=True,
                    stdin=None if tty else subprocess.DEVNULL,
                    capture_output=True,
                    timeout=timeout if timeout > 0 else None,
                )
            except subprocess.TimeoutExpired as e:
                log(f"remote command timed out after {timeout:.0f}s")
                proc = subprocess.CompletedProcess(cmd, -1, stdout=e.stdout or "", stderr=e.stderr or "")
        self.dbg(f"remote rc={proc.returncode} in {time.time()-t0:.3f}s")
        if check and proc.returncode != 0:
            detail = (proc.stderr or "").strip() if capture else ""
            die(f"remote command failed (rc={proc.returncode})\n{detail}")
        return proc

    def check(self, script: str, quiet: bool = False) -> int:
        cmd = [*SSH_BIN, *self.base_opts(), self.host, f"bash -lc {shlex.quote(script)}"]
        kw = dict(stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) if quiet else {}
        if not quiet:
            self.dbg(f"check$ {script}")
        t0 = time.time()
        rc = subprocess.run(cmd, check=False, **kw).returncode  # type: ignore[arg-type]
        self.dbg(f"check rc={rc} in {time.time()-t0:.3f}s")
        return rc

    def out(self, script: str) -> str:
        self.dbg(f"out$ {script}")
        return self.run(script, check=False, capture=True).stdout.strip()

    def rsync(self, src: str, dst: str, extra: list[str] | None = None) -> None:
        ssh_cmd = "ssh " + " ".join(shlex.quote(o) for o in self.base_opts())
        cmd = [*RSYNC_BIN, "-az", "--delete-delay", "-e", ssh_cmd]
        cmd += extra or []
        cmd += [src, dst]
        self.vlog("rsync " + " ".join(shlex.quote(c) for c in cmd))
        t0 = time.time()
        proc = subprocess.run(cmd, check=False)
        self.dbg(f"rsync rc={proc.returncode} in {time.time()-t0:.3f}s")
        if proc.returncode != 0:
            die(f"rsync failed (rc={proc.returncode})")

    def push(self, local: Path, remote_path: str) -> None:
        ssh_cmd = "ssh " + " ".join(shlex.quote(o) for o in self.base_opts())
        log(f"push {local} ({local.stat().st_size} bytes) -> {self.host}:{remote_path}")
        t0 = time.time()
        subprocess.run(
            [*RSYNC_BIN, "-az", "-e", ssh_cmd, str(local), f"{self.host}:{remote_path}"],
            check=True,
        )
        log(f"push done in {time.time()-t0:.3f}s")

    def pull(self, remote_path: str, local: Path) -> None:
        local.mkdir(parents=True, exist_ok=True)
        ssh_cmd = "ssh " + " ".join(shlex.quote(o) for o in self.base_opts())
        log(f"pull {self.host}:{remote_path} -> {local}")
        t0 = time.time()
        proc = subprocess.run(
            [*RSYNC_BIN, "-az", "-e", ssh_cmd, f"{self.host}:{remote_path}", str(local)],
            check=False,
        )
        log(f"pull rc={proc.returncode} in {time.time()-t0:.3f}s")


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------


def repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def flavour_info(flavour: str) -> tuple[str, bool]:
    if flavour not in FLAVOURS:
        die(f"unknown flavour '{flavour}' (choose: {', '.join(FLAVOURS)})")
    return FLAVOURS[flavour]


def env_prefix() -> str:
    return f"set -a; . {REMOTE_ROOT}/env.sh; set +a;"


def file_tag(path: Path) -> str:
    h = hashlib.sha256(path.read_bytes()).hexdigest()[:12]
    return f"{path.stem}-{h}"


# --------------------------------------------------------------------------
# subcommands
# --------------------------------------------------------------------------


def cmd_doctor(rem: Remote, args) -> int:
    log(f"host          : {rem.host}")
    log(f"ssh config    : {rem.ssh_config or '(none found)'}")
    log(f"identity      : {rem.identity or '(agent/default)'}")
    for name, bin_list in (("ssh", SSH_BIN), ("rsync", RSYNC_BIN), ("python3", ["python3"])):
        p = shutil.which(bin_list[0])
        log(f"local {name:<9}: {p or 'MISSING'}")
        if not p:
            die(f"local '{name}' is required")

    rem.start_master()
    log("ssh           : connected")
    log("remote uname  : " + rem.out("uname -srm"))
    log("remote distro : " + rem.out(
        ". /etc/os-release 2>/dev/null && echo \"$PRETTY_NAME\" || echo unknown"))
    log("remote cores  : " + rem.out("nproc"))
    log("remote mem    : " + rem.out("free -h 2>/dev/null | awk '/Mem:/{print $2}'"))
    log("remote disk   : " + rem.out(
        f"df -h {shlex.quote(os.path.dirname(REMOTE_ROOT) or '/')} | awk 'NR==2{{print $4\" free\"}}'"))

    sudo = "yes" if rem.check("sudo -n true", quiet=True) == 0 else "no (or password-gated)"
    log(f"remote sudo   : {sudo}")

    writable = rem.check(
        f"test -w {shlex.quote(REMOTE_ROOT)} || "
        f"(mkdir -p {shlex.quote(REMOTE_ROOT)} 2>/dev/null)", quiet=True) == 0
    log(f"remote root   : {REMOTE_ROOT} "
        f"{'writable' if writable else 'NOT writable without sudo'}")

    log("--- remote features ---")
    for tool, probe in (
        ("g++", "g++ --version | head -1"),
        ("make", "make --version | head -1"),
        ("git", "git --version"),
        ("python3", "python3 --version"),
        ("curl", "curl --version | head -1"),
        ("verilator", f"{REMOTE_ROOT}/toolchains/verilator-{VERILATOR_VERSION}/bin/verilator --version"),
        ("riscv-gcc", f"{REMOTE_ROOT}/toolchains/xpack-riscv-none-elf-gcc-{XPACK_GCC_VERSION}/bin/riscv-none-elf-gcc --version | head -1"),
        ("spike", f"ls {REMOTE_ROOT}/toolchains/spike/lib/libfesvr.* 2>/dev/null | head -1"),
    ):
        val = rem.out(f"{probe} 2>/dev/null")
        log(f"  {tool:<10}: {val if val else 'MISSING'}")

    log("--- built harnesses ---")
    for flav, (verlib, _) in FLAVOURS.items():
        p = f"{REMOTE_ROOT}/work/{verlib}/Variane_testharness"
        val = rem.out(f"test -x {p} && stat -c '%y (%s bytes)' {p} || echo -")
        log(f"  {flav:<10}: {val}")
    return 0


def cmd_setup(rem: Remote, args) -> int:
    rem.start_master()
    root = repo_root()

    # Bootstrap dirs with sudo if needed, before anything is copied in.
    rem.run(
        f"test -d {shlex.quote(REMOTE_ROOT)} || "
        f"(mkdir -p {shlex.quote(REMOTE_ROOT)} 2>/dev/null || "
        f"(sudo -n mkdir -p {shlex.quote(REMOTE_ROOT)} && "
        f"sudo -n chown -R $(id -u):$(id -g) {shlex.quote(REMOTE_ROOT)}))"
    )

    prov = root / "verif" / "regress" / "remote" / "provision.sh"
    if not prov.is_file():
        die(f"missing {prov}")
    rem.push(prov, f"{REMOTE_ROOT}/provision.sh")

    # Ship the locally built spike so the remote does not have to build it.
    local_spike = root / "build-platform" / "workspace" / "tooling" / "spike"
    if local_spike.is_dir() and not args.no_spike_upload:
        log("uploading prebuilt spike (avoids a remote source build)")
        rem.run(f"mkdir -p {REMOTE_ROOT}/toolchains")
        rem.rsync(f"{local_spike}/", f"{rem.host}:{REMOTE_ROOT}/toolchains/spike/")

    env = (
        f"TH_ROOT={shlex.quote(REMOTE_ROOT)} "
        f"TH_VERILATOR_VERSION={shlex.quote(VERILATOR_VERSION)} "
        f"TH_XPACK_GCC_VERSION={shlex.quote(XPACK_GCC_VERSION)} "
        f"TH_XPACK_URL={shlex.quote(XPACK_URL)} "
        f"TH_BUILD_JOBS=8"
    )
    rem.run(f"chmod +x {REMOTE_ROOT}/provision.sh && {env} bash {REMOTE_ROOT}/provision.sh")
    if rem.check(f"test -f {REMOTE_ROOT}/env.sh", quiet=True) != 0:
        die("provision did not create env.sh")
    log("provision complete; env.sh ready")
    return 0


def cmd_sync(rem: Remote, args) -> int:
    rem.start_master()
    root = repo_root()
    rem.run(f"mkdir -p {REMOTE_ROOT}/repo")

    filters: list[str] = []
    if not args.full:
        # Whitelist mode: include the listed trees first, then apply excludes,
        # then drop everything else. Order matters: a file in software/.../build/
        # must match its include before the generic *.elf exclude rejects it.
        for inc in SYNC_INCLUDE:
            if inc.endswith("/"):
                # include the dir and everything under it
                parts = inc.rstrip("/").split("/")
                acc = ""
                for p in parts:
                    acc = f"{acc}/{p}" if acc else p
                    filters += ["--include", f"/{acc}/"]
                filters += ["--include", f"/{inc}***"]
            else:
                # include a specific file; include each parent directory too
                # so rsync will descend to it even with a final --exclude *.
                parts = inc.split("/")
                acc = ""
                for p in parts[:-1]:
                    acc = f"{acc}/{p}" if acc else p
                    filters += ["--include", f"/{acc}/"]
                filters += ["--include", f"/{inc}"]
        for pat in SYNC_EXCLUDE:
            filters += ["--exclude", pat]
        filters += ["--exclude", "*"]

    log(f"syncing repo subset -> {rem.host}:{REMOTE_ROOT}/repo")
    t0 = time.time()
    rem.rsync(f"{root}/", f"{rem.host}:{REMOTE_ROOT}/repo/", filters)
    log(f"sync done in {time.time() - t0:.1f}s")
    return 0


def _git_tracked_files(root: Path, patterns: list[str]) -> list[Path]:
    """Return tracked files under ``patterns`` (git ls-files), or [] if git fails."""
    try:
        proc = subprocess.run(
            ["git", "-C", str(root), "ls-files", "-z", *patterns],
            capture_output=True,
            text=False,
            check=False,
        )
        if proc.returncode != 0:
            return []
        files = [root / p.decode() for p in proc.stdout.split(b"\0") if p]
        return files
    except FileNotFoundError:
        return []


def build_cache_key(root: Path, flavour: str, target: str) -> str:
    """Content hash of the build inputs for a (flavour, target) pair.

    Includes the top-level build scripts / flists and all RTL/TB sources.
    Over-approximates the actual Verilator input set so the cache is safe.
    """
    h = hashlib.sha256()
    h.update(f"flavour={flavour}\ntarget={target}\n".encode())

    seed_files = [
        "Makefile",
        "verilator_config.vlt",
        "verif/regress/soft-ladder-build-harness.sh",
        "core/Flist.cva6",
        "core/Flist.fetch_B",
        "core/Flist.smt_legacy",
    ]
    for rel in seed_files:
        p = root / rel
        if p.is_file():
            h.update(f"\nfile:{rel}\n".encode())
            h.update(p.read_bytes())

    exts = {".sv", ".v", ".vlt", ".svh", ".vh", ".cc", ".cpp", ".h", ".hpp"}
    patterns = ["core/**", "corev_apu/**", "common/**", "vendor/**", "verif/tb/**"]
    files = _git_tracked_files(root, patterns)

    if not files:
        # Fallback when git is not on PATH or the tree is not a git repo.
        files = []
        for pat in patterns:
            d = root / pat.rstrip("/**")
            if d.is_dir():
                files.extend(d.rglob("*"))
        files = [
            f for f in files
            if f.is_file() and f.suffix in exts
            and not any(
                part in {".git", "__pycache__"}
                or str(part).startswith("work-ver")
                or f.name.endswith((".o", ".d", ".log", ".vcd", ".fst"))
                for part in f.parts
            )
        ]

    for f in sorted(set(files)):
        if not f.is_file():
            continue
        h.update(f"\n{str(f.relative_to(root))}\n".encode())
        h.update(f.read_bytes())

    return h.hexdigest()[:24]


def cmd_build(rem: Remote, args) -> int:
    rem.start_master()
    verlib, _stock = flavour_info(args.flavour)
    if args.verlib:
        verlib = args.verlib

    if args.sync:
        rc = cmd_sync(rem, argparse.Namespace(full=False))
        if rc != 0:
            return rc

    if rem.check(f"test -f {REMOTE_ROOT}/env.sh", quiet=True) != 0:
        die(f"remote env.sh missing; run '{sys.argv[0]} setup {args.host}' first")

    jobs = args.jobs or "$(nproc)"
    clean = "1" if args.clean else "0"
    root = repo_root()
    verlib_dir = f"{REMOTE_ROOT}/work/{verlib}"

    env_vars = [
        f"SOFT_LADDER_VERLIB={shlex.quote(verlib_dir)}",
        f"SOFT_LADDER_BUILD_TARGET={shlex.quote(args.target)}",
        f"SOFT_LADDER_BUILD_JOBS={shlex.quote(jobs)}",
        f"SOFT_LADDER_BUILD_CLEAN={shlex.quote(clean)}",
        "VLT_HOME=\"$VLT_HOME\"",
    ]

    if args.cache:
        # Auto-detect and enable ccache/mold on the remote.
        if rem.check("command -v ccache >/dev/null 2>&1", quiet=True) == 0:
            ccache_dir = f"{REMOTE_ROOT}/cache/ccache"
            rem.run(f"mkdir -p {shlex.quote(ccache_dir)}")
            env_vars += [
                "SOFT_LADDER_BUILD_OBJCACHE=ccache",
                f"SOFT_LADDER_BUILD_CCACHE_DIR={shlex.quote(ccache_dir)}",
            ]
            log("ccache enabled")
        else:
            log("ccache not available on remote")

        if rem.check("command -v mold >/dev/null 2>&1", quiet=True) == 0:
            env_vars += ["SOFT_LADDER_BUILD_LINKER=mold"]
            log("mold linker enabled")
        else:
            log("mold not available on remote (using system linker)")

    cache_key = None
    cache_dir = None
    if args.output_cache:
        cache_key = build_cache_key(root, args.flavour, args.target)
        cache_dir = f"{REMOTE_ROOT}/cache/builds/{cache_key}"
        if rem.check(
            f"test -x {shlex.quote(cache_dir)}/Variane_testharness",
            quiet=True,
        ) == 0:
            log(f"output cache hit for key {cache_key}; seeding from {cache_dir}")
            env_vars.append(f"SOFT_LADDER_BUILD_SEED={shlex.quote(cache_dir)}")
        else:
            log(f"output cache miss for key {cache_key}")

    script = (
        f"{env_prefix()} cd {REMOTE_ROOT}/repo && "
        f"mkdir -p {REMOTE_ROOT}/work && "
        + " ".join(env_vars)
        + f" bash verif/regress/soft-ladder-build-harness.sh {shlex.quote(args.flavour)}"
    )
    log(f"building flavour={args.flavour} verlib={verlib} target={args.target} jobs={jobs}")
    rem.dbg(f"build script: {script[:240]}...")
    t0 = time.time()
    rc = rem.run(script, check=False).returncode
    log(f"build {'OK' if rc == 0 else 'FAILED'} in {time.time() - t0:.1f}s")

    if rc == 0 and args.output_cache and cache_dir:
        rem.run(
            f"mkdir -p {shlex.quote(f'{REMOTE_ROOT}/cache/builds')} && "
            f"rm -rf {shlex.quote(cache_dir)} && "
            f"cp -a {shlex.quote(verlib_dir)} {shlex.quote(cache_dir)}"
        )
        log(f"output cache archived to {cache_dir}")

    return rc


def cmd_run(rem: Remote, args) -> int:
    rem.start_master()
    verlib, _ = flavour_info(args.flavour)
    if args.verlib:
        verlib = args.verlib
    harness = f"{REMOTE_ROOT}/work/{verlib}/Variane_testharness"

    if rem.check(f"test -x {harness}", quiet=True) != 0:
        die(f"no remote harness for flavour '{args.flavour}': {harness}\n"
            f"       build it first:  {sys.argv[0]} build {args.flavour}")

    elf = Path(args.elf).resolve()
    if not elf.is_file():
        die(f"no such ELF: {elf}")

    tag = args.tag or file_tag(elf)
    rundir = f"{REMOTE_ROOT}/runs/{tag}"
    # Minimal per-test payload: content-addressed, so a repeat run uploads 0 bytes.
    rem.run(f"mkdir -p {rundir}")
    rem.dbg(f"run tag={tag} rundir={rundir}")
    remote_elf = f"{rundir}/{elf.name}"
    log(f"uploading {elf.name} ({elf.stat().st_size} bytes) -> {rundir}")
    rem.push(elf, remote_elf)

    plusargs = " ".join(shlex.quote(a) for a in args.plusarg)
    logfile = f"{rundir}/run-{args.flavour}.log"
    script = (
        f"{env_prefix()} cd {rundir} && "
        f"{shlex.quote(harness)} +time_out={args.time_out} "
        f"+max-cycles={args.time_out} +debug_disable +quiet_axi "
        f"{plusargs} {shlex.quote(remote_elf)} > {shlex.quote(logfile)} 2>&1; "
        f"echo \"rc=$?\"; tail -n {args.tail} {shlex.quote(logfile)}"
    )
    rem.dbg(f"run script: {script[:200]}...")
    t0 = time.time()
    rc = rem.run(script, check=False).returncode
    log(f"run finished in {time.time() - t0:.1f}s (remote log: {logfile})")
    if args.pull:
        dest = repo_root() / "remote-runs" / tag
        rem.pull(f"{rundir}/", dest)
        log(f"pulled logs -> {dest}")
    return rc


def cmd_soak(rem: Remote, args) -> int:
    rem.start_master()
    verlib, _ = flavour_info(args.flavour)
    env = [f"SOFT_LADDER_FETCH={args.flavour}",
           f"SOFT_LADDER_HARNESS={REMOTE_ROOT}/work/{verlib}"]
    if args.skip_build:
        env.append("SOFT_LADDER_SKIP_BUILD=1")
    else:
        env.append("SOFT_LADDER_SKIP_BUILD=0")
    if args.hold:
        env.append("SOFT_LADDER_HOLD=1")
    for kv in args.env:
        env.append(kv)
    script = (
        f"{env_prefix()} cd {REMOTE_ROOT}/repo && "
        + " ".join(shlex.quote(e) if "=" not in e else e for e in env)
        + " bash verif/regress/soft-ladder-opensbi-soak.sh"
    )
    log(f"soak flavour={args.flavour} harness={verlib} skip_build={args.skip_build} hold={args.hold}")
    rem.dbg(f"soak script: {script[:200]}...")
    t0 = time.time()
    rc = rem.run(script, check=False).returncode
    log(f"soak finished rc={rc} in {time.time()-t0:.1f}s")
    return rc


def cmd_pull(rem: Remote, args) -> int:
    rem.start_master()
    dest = Path(args.dest) if args.dest else repo_root() / "remote-runs"
    src = f"{REMOTE_ROOT}/runs/"
    log(f"pulling {rem.host}:{src} -> {dest}")
    rem.pull(src, dest)
    return 0


def _shell_command(args) -> str | None:
    """Resolve the one-shot remote command from --cmd-file or positional tokens.

    Passing a remote pipeline as one quoted string means three nested quoting
    layers (local shell -> optional 'bash -c' wrapper -> remote 'bash -lc'); an
    unbalanced quote leaves the *caller's* shell at a continuation prompt with
    nothing sent. --cmd-file removes the nesting entirely, and multi-token
    positionals let simple commands be passed unquoted.
    """
    if getattr(args, "cmd_file", None):
        if args.cmd_file == "-":
            return sys.stdin.read().strip() or None
        p = Path(args.cmd_file)
        if not p.is_file():
            die(f"--cmd-file not found: {p}")
        return p.read_text(encoding="utf-8").strip() or None
    tokens = args.command or []
    if isinstance(tokens, str):
        tokens = [tokens]
    if not tokens:
        return None
    command = " ".join(tokens)
    # Catch an unbalanced quote locally rather than shipping a script that the
    # remote bash cannot parse.
    try:
        shlex.split(command)
    except ValueError as exc:
        die(f"unparsable remote command ({exc}); use --cmd-file to avoid quoting: {command}")
    return command


def cmd_shell(rem: Remote, args) -> int:
    args.command = _shell_command(args)
    rem.start_master()
    if args.command:
        # One-shot shell queries get a safety net so a typo or hung remote
        # command cannot block the proxy indefinitely. Use --timeout 0 to
        # disable, or pass a larger value for long commands.
        # No TTY by default: a pty made the remote command share the caller's
        # terminal, so the output came back interleaved with a fresh prompt
        # instead of as a plain captured result. Pass --tty when the remote
        # command must die with the SSH session (SIGHUP on disconnect).
        timeout = args.timeout if args.timeout > 0 else DEFAULT_SHELL_TIMEOUT
        return rem.run(f"cd {REMOTE_ROOT} && {args.command}",
                       check=False, timeout=timeout,
                       heartbeat=not args.no_hang, tty=args.tty).returncode
    return rem.run(
        f"cd {REMOTE_ROOT} && exec bash -l", check=False, tty=True,
        heartbeat=not args.no_hang
    ).returncode


def cmd_clean(rem: Remote, args) -> int:
    rem.start_master()
    targets = []
    if args.what in ("runs", "all"):
        targets.append(f"{REMOTE_ROOT}/runs")
    if args.what in ("work", "all"):
        targets.append(f"{REMOTE_ROOT}/work")
    if args.what == "everything":
        targets = [REMOTE_ROOT]
    if not targets:
        die("nothing selected")
    log("removing: " + ", ".join(targets))
    rem.run("rm -rf " + " ".join(shlex.quote(t) for t in targets))
    return 0


def _build_py_runner(tag: str) -> str:
    """Return a self-contained remote runner that executes every .py in
    scripts/ via a concurrent.futures thread pool."""
    return r'''#!/usr/bin/env python3
import concurrent.futures
import json
import os
import subprocess
import sys
import time
from pathlib import Path

run_dir = Path(__file__).resolve().parent
scripts_dir = run_dir / "scripts"
data_dir = run_dir / "data"
out_dir = run_dir / "output"
out_dir.mkdir(parents=True, exist_ok=True)

threads = int(os.environ.get("TH_PROXY_THREADS", "1"))
tag = os.environ.get("TH_PROXY_TAG", "py-runner")


def run_one(script: Path) -> dict:
    log_path = out_dir / f"{script.stem}.log"
    t0 = time.time()
    env = dict(os.environ)
    env["TH_SCRIPT"] = str(script)
    env["TH_SCRIPT_NAME"] = script.stem
    env["TH_DATA_DIR"] = str(data_dir)
    env["TH_OUT_DIR"] = str(out_dir)
    env["TH_RUN_DIR"] = str(run_dir)
    env["TH_PROXY_TAG"] = tag
    proc = subprocess.run(
        [sys.executable, "-u", str(script)],
        cwd=run_dir,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    log_path.write_text(proc.stdout)
    return {"script": script.name, "rc": proc.returncode, "time": time.time() - t0}


script_files = sorted(
    p for p in scripts_dir.iterdir()
    if p.suffix == ".py" and p.name != "__th_py_runner__.py"
)
summary = {
    "tag": tag,
    "threads": threads,
    "start": time.strftime("%Y-%m-%dT%H:%M:%S"),
    "scripts": [s.name for s in script_files],
}
t0_all = time.time()
with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, threads)) as ex:
    results = list(ex.map(run_one, script_files))
summary["results"] = results
summary["wall"] = time.time() - t0_all
summary["max_rc"] = max((r["rc"] for r in results), default=0)
(out_dir / "summary.json").write_text(json.dumps(summary, indent=2))
summary_lines = [
    f"tag={tag} threads={threads} scripts={len(script_files)} "
    f"wall={summary['wall']:.1f}s max_rc={summary['max_rc']}",
]
summary_lines += [f"{r['rc']:3d} {r['time']:.1f}s {r['script']}" for r in results]
(out_dir / "summary.txt").write_text("\n".join(summary_lines) + "\n")
sys.exit(summary["max_rc"])
'''


def cmd_py(rem: Remote, args) -> int:
    """Upload one or more local Python scripts and run them remotely with a
    multi-threaded worker pool.

    Each script is executed in its own remote ``python3`` process; a local
    (remote) ``concurrent.futures.ThreadPoolExecutor`` dispatches up to
    ``--threads`` workers. Output is collected in ``output/<stem>.log`` and
    ``output/summary.json``. With ``--pull`` the entire output directory is
    copied back to ``remote-runs/<tag>/output/``.
    """
    rem.start_master()

    scripts = [Path(s).resolve() for s in args.script]
    for s in scripts:
        if not s.is_file():
            die(f"no such script: {s}")
        if s.suffix != ".py":
            die(f"not a Python file: {s}")

    if args.threads < 1:
        die("--threads must be >= 1")

    if args.tag:
        tag = args.tag
    else:
        h = hashlib.sha256()
        h.update(f"threads={args.threads}".encode())
        for s in sorted(scripts):
            h.update(s.read_bytes())
        tag = f"{scripts[0].stem}-{h.hexdigest()[:12]}"
    rundir = f"{REMOTE_ROOT}/runs/{tag}"

    data_files = [Path(d).resolve() for d in (args.data or [])]
    for d in data_files:
        if not d.exists():
            die(f"no such data path: {d}")

    rem.run(
        f"mkdir -p {shlex.quote(rundir)}/scripts "
        f"{shlex.quote(rundir)}/data "
        f"{shlex.quote(rundir)}/output"
    )
    for s in scripts:
        rem.push(s, f"{rundir}/scripts/{s.name}")

    for d in data_files:
        if d.is_dir():
            rem.rsync(f"{d}/", f"{rem.host}:{rundir}/data/{d.name}/")
        else:
            rem.push(d, f"{rundir}/data/{d.name}")

    runner = _build_py_runner(tag)
    fd, runner_local = tempfile.mkstemp(
        suffix=".py",
        prefix=f"th-py-runner-{tag}-",
        dir=str(repo_root()),
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(runner)
        rem.push(Path(runner_local), f"{rundir}/__th_py_runner__.py")
    finally:
        try:
            os.unlink(runner_local)
        except OSError:
            pass

    env_pieces = [shlex.quote(kv) for kv in (args.env or [])]
    env_prefix = " ".join(env_pieces)

    log(f"py: running {len(scripts)} script(s) with {args.threads} thread(s) -> {rundir}")
    t0 = time.time()
    script = (
        f"cd {shlex.quote(rundir)} && "
        f"TH_PROXY_THREADS={shlex.quote(str(args.threads))} "
        f"TH_PROXY_TAG={shlex.quote(tag)} "
        f"{env_prefix} "
        f"python3 -u __th_py_runner__.py"
    )
    rc = rem.run(script, check=False).returncode
    log(f"py finished rc={rc} in {time.time()-t0:.1f}s")

    if args.pull:
        dest = repo_root() / "remote-runs" / tag / "output"
        rem.pull(f"{rundir}/output/", dest)
        log(f"pulled output -> {dest}")
    return rc


# --------------------------------------------------------------------------
# cli
# --------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="testharness_proxy.py",
        description="Run the CVA6/LibreCore Verilator testharness on a remote host.",
    )
    p.add_argument("--host", default=HOST, help=f"ssh host alias (default {HOST})")
    p.add_argument("--timeout", type=float, default=0,
                   help="remote command timeout in seconds, 0 = no timeout (default: 0)")
    p.add_argument("-v", "--verbose", action="store_true",
                   help="verbose progress and command echo")
    p.add_argument("-d", "--debug", action="store_true",
                   help="extra debug timing and internal state (implies -v)")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("doctor", help="probe local + remote capabilities")
    sp.set_defaults(fn=cmd_doctor)

    sp = sub.add_parser("setup", help="provision missing remote toolchains")
    sp.add_argument("--no-spike-upload", action="store_true",
                    help="force a remote spike source build instead of uploading")
    sp.set_defaults(fn=cmd_setup)

    sp = sub.add_parser("sync", help="rsync the repo subset needed to verilate")
    sp.add_argument("--full", action="store_true", help="sync the whole tree")
    sp.set_defaults(fn=cmd_sync)

    sp = sub.add_parser("build", help="build a harness flavour remotely")
    sp.add_argument("flavour", choices=sorted(FLAVOURS))
    sp.add_argument("--target", default=DEFAULT_TARGET)
    sp.add_argument("--verlib", default=None)
    sp.add_argument("--jobs", default=None)
    sp.add_argument("--clean", action="store_true",
                    help="wipe the flavour Mdir and rebuild from scratch")
    sp.add_argument("--cache", default=True, action=argparse.BooleanOptionalAction,
                    help="use ccache and mold if available (default: --cache)")
    sp.add_argument("--no-sync", dest="sync", action="store_false", default=True,
                    help="skip repo sync before build")
    sp.add_argument("--output-cache", default=False, action="store_true",
                    help="seed from and archive the full Mdir in a content-keyed cache")
    sp.set_defaults(fn=cmd_build)

    sp = sub.add_parser("run", help="upload one ELF and run it (minimal payload)")
    sp.add_argument("elf")
    sp.add_argument("--flavour", choices=sorted(FLAVOURS), default="B")
    sp.add_argument("--verlib", default=None)
    sp.add_argument("--tag", default=None, help="run dir name (default <elf>-<sha>)")
    sp.add_argument("--time-out", dest="time_out", default="400000")
    sp.add_argument("--plusarg", action="append", default=[],
                    help="extra +plusarg (repeatable)")
    sp.add_argument("--tail", type=int, default=30)
    sp.add_argument("--pull", action="store_true", help="copy logs back when done")
    sp.set_defaults(fn=cmd_run)

    sp = sub.add_parser("soak", help="run the OpenSBI cookie soak remotely")
    sp.add_argument("--flavour", choices=sorted(FLAVOURS), default="B")
    sp.add_argument("--skip-build", action="store_true",
                    help="reuse an already built ELF")
    sp.add_argument("--hold", action="store_true",
                    help="use the held (SOFT_HART_INIT) ELF")
    sp.add_argument("--env", action="append", default=[],
                    help="extra KEY=VALUE for the soak (repeatable)")
    sp.set_defaults(fn=cmd_soak)

    sp = sub.add_parser("py", help="upload Python scripts and run them remotely (thread pool)")
    sp.add_argument("script", nargs="+", help="local Python script(s) to execute")
    sp.add_argument("--tag", default=None, help="run dir name (default <first>-<hash>)")
    sp.add_argument("--threads", type=int, default=1,
                    help="number of worker threads for the remote pool (default 1)")
    sp.add_argument("--data", action="append", default=[],
                    help="data file or directory to upload (repeatable)")
    sp.add_argument("--env", action="append", default=[],
                    help="KEY=VALUE env var for the scripts (repeatable)")
    sp.add_argument("--pull", action="store_true",
                    help="copy output/ back when done")
    sp.set_defaults(fn=cmd_py)

    sp = sub.add_parser("pull", help="copy remote run logs back")
    sp.add_argument("--dest", default=None)
    sp.set_defaults(fn=cmd_pull)

    sp = sub.add_parser("shell", help="interactive ssh into the remote root, or run one command")
    sp.add_argument("command", default=None, nargs="*",
                    help="remote command tokens, joined with spaces; put them "
                         "after '--' if any start with a dash "
                         "(default: interactive shell)")
    sp.add_argument("--cmd-file", default=None, metavar="PATH",
                    help="read the remote command from PATH ('-' for stdin); "
                         "avoids nested shell quoting for pipelines")
    sp.add_argument("--no-hang", action="store_true",
                    help="suppress 'still running...' heartbeat messages")
    sp.add_argument("--tty", action="store_true",
                    help="allocate a remote TTY (kills the remote command on disconnect)")
    sp.set_defaults(fn=cmd_shell)

    sp = sub.add_parser("clean", help="remove remote work/run dirs")
    sp.add_argument("what", choices=["runs", "work", "all", "everything"],
                    default="runs", nargs="?")
    sp.set_defaults(fn=cmd_clean)

    return p


def main(argv: list[str] | None = None) -> int:
    global _DEBUG
    args = build_parser().parse_args(argv)
    _DEBUG = args.debug
    verbose = args.verbose or args.debug
    rem = Remote(args.host, verbose=verbose, debug_mode=args.debug)
    rem.timeout = args.timeout
    try:
        t0 = time.time()
        rc = args.fn(rem, args)
        log(f"command completed rc={rc} in {time.time()-t0:.1f}s")
        return rc
    finally:
        rem.close()


if __name__ == "__main__":
    sys.exit(main())
