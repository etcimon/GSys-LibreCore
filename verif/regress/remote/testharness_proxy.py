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
  di        compile and run the directed mini suite remotely in parallel
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
import concurrent.futures
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
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
    # Provisioning scripts the remote runs on itself. `install-formal.sh` builds
    # the bounded-formal toolchain (Yosys >= v0.67 with the integrated slang
    # frontend, plus SymbiYosys) on the builder, so `verify --formal
    # --formal-remote` can put the solver work on the machine with the cores.
    "build-platform/scripts/",
    "software/smt2-linux/soft-ladder/mk_plat_skip.py",
    "software/smt2-linux/soft-ladder/rebuild_held_from_pin.sh",
    "software/smt2-linux/soft-ladder/build/fw_payload_diag.elf",
    "software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.pin-bc7ed11d.elf",
    "software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.elf",
    "software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.default-green.elf",
    "software/smt2-linux/soft-ladder/build/fw_payload_peel_both.elf",
    "software/smt2-linux/soft-ladder/build/fw_payload_r3a_c15_plat_skip.held.elf",
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

# g6lc64_ai Variane libraries (I3 S4 / CLASS1). Not SMT2 B/legacy.
# Built by verif/regress/ai-matrix-build-harness.sh via proxy `build ai-dt`
# (also ai-d1/2/4/8 CLASS1 LiteDRAM and ai-sc2/4/8 class-0 SRAM stripe).
AI_FLAVOURS = {
    "ai": {
        "verlib": "work-ver-ai",
        "target": "g6lc64_ai",
        "defines": "",
    },
    "ai-dt": {
        "verlib": "work-ver-ai-dt",
        "target": "g6lc64_ai",
        "defines": "G6LC_AI_DRAM_TIMING",
    },
    "ai-d1": {
        "verlib": "work-ver-ai-d1",
        "target": "g6lc64_ai",
        "defines": "G6LC_AI_DRAM_CLASS1",
    },
    "ai-d2": {
        "verlib": "work-ver-ai-d2",
        "target": "g6lc64_ai",
        "defines": "G6LC_AI_DRAM_CHANS_2",
    },
    "ai-d4": {
        "verlib": "work-ver-ai-d4",
        "target": "g6lc64_ai",
        "defines": "G6LC_AI_DRAM_CHANS_4",
    },
    "ai-d8": {
        "verlib": "work-ver-ai-d8",
        "target": "g6lc64_ai",
        "defines": "G6LC_AI_DRAM_CHANS_8",
    },
    "ai-sc2": {
        "verlib": "work-ver-ai-sc2",
        "target": "g6lc64_ai",
        "defines": "G6LC_AI_DRAM_SIM_CHANS_2",
    },
    "ai-sc4": {
        "verlib": "work-ver-ai-sc4",
        "target": "g6lc64_ai",
        "defines": "G6LC_AI_DRAM_SIM_CHANS_4",
    },
    "ai-sc8": {
        "verlib": "work-ver-ai-sc8",
        "target": "g6lc64_ai",
        "defines": "G6LC_AI_DRAM_SIM_CHANS_8",
    },
}

# Default directed mini suite from verif/regress/soft-ladder-di-regress.sh.
# Keep in sync with that script; override with --tests.
DEFAULT_DI_TESTS = [
    "mini_amoadd_w_spin",
    "mini_csr_expected_trap",
    "mini_csr_pmp_probe",
    "mini_dual_cmv_s3",
    "mini_fdt_lenp_sw",
    "mini_fdt_s2_nest",
    "mini_fdt_check_prop_nest",
    "mini_fdt_next_tag_lbu",
    "mini_fdt_a0_is_fdt",
    "mini_stq_flush_fwd",
    "mini_fdt_namelen_walk",
    "mini_fdt_nt_frame32",
    "mini_fdt_nt_stock",
    "mini_fdt_nt_cpus",
    "mini_stq_alias_jal",
    "mini_fdt_nt_osbi",
]

# H3 "Oracle Validity First" controls (architecture/AGENTS-g6lc-opensbi-dev-
# heuristics.md s5 M1). These are a preflight GATE, never suite members: the
# positive control must PASS and the negative control must FAIL, otherwise the
# classifier cannot say both words and no verdict from the run is a measurement.
# On 2026-08-31 the DI classifier read "*** SUCCESS *** (tohost = 0)" as a pass;
# the negative control is what makes that class of defect visible.
ORACLE_POSITIVE = "mini_must_pass"
ORACLE_NEGATIVE = "mini_must_fail"
ORACLE_CONTROLS = (ORACLE_POSITIVE, ORACLE_NEGATIVE)

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

    def _passphrase_from_platform_cache(self) -> str | None:
        """Last resort: the build-platform credential cache, keyed by host alias.

        `build-platform/src/cli/commands/remote.ts` prompts once and caches the
        passphrase in `build-platform/.remote-ssh-creds` (untracked, 0600), then
        injects it as TH_SSH_PASSPHRASE when *it* drives this proxy. A script run
        directly -- ai-dual-core-excl.sh and every other sibling in
        verif/regress/remote/ -- never sees that injection, so on a host set up
        through the build-platform the standalone scripts could not authenticate
        at all and each needed its own shim to re-extract the value.

        Reading the same file here removes that asymmetry. It is not a new secret
        location: the file is already untracked, already 0600, and already holds
        exactly this value.
        """
        path = repo_root() / "build-platform" / ".remote-ssh-creds"
        try:
            if not path.is_file():
                return None
            cache = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        entry = (cache.get("hosts") or {}).get(self.host)
        if not isinstance(entry, dict):
            return None
        val = entry.get("passphrase")
        if isinstance(val, str) and val:
            if self.verbose:
                log(f"passphrase from {path} (host {self.host})")
            return val
        return None

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
        return self._passphrase_from_platform_cache()

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
                except (ImportError, AttributeError, OSError):
                    try:
                        proc.wait(timeout=1.0)
                    except subprocess.TimeoutExpired:
                        pass
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


def flavour_names() -> list[str]:
    return sorted(set(FLAVOURS) | set(AI_FLAVOURS))


def flavour_info(flavour: str) -> tuple[str, bool]:
    if flavour in FLAVOURS:
        return FLAVOURS[flavour]
    if flavour in AI_FLAVOURS:
        return (AI_FLAVOURS[flavour]["verlib"], True)
    die(f"unknown flavour '{flavour}' (choose: {', '.join(flavour_names())})")
    raise AssertionError


def env_prefix() -> str:
    return f"set -a; . {REMOTE_ROOT}/env.sh; set +a;"


def _di_max_workers(rem: Remote, verlib: str, requested: int, n_tests: int) -> int:
    """Compute DI worker count so each running test can saturate the remote
    host while the next test starts as soon as a worker frees up.

    The build script pins Verilator vthreads to nproc, so one Variane_testharness
    already uses all cores. Running more than one in parallel oversubscribes and
    slows every test. We therefore run one test at a time unless the remote has
    many more cores than the compiled vthreads count.
    """
    # Probe the host and, if the build recorded its vthreads, use that.
    nproc = 0
    try:
        nproc_txt = rem.out("command -v nproc >/dev/null && nproc || echo 0").strip()
        nproc = int(nproc_txt) if nproc_txt.isdigit() else 0
    except Exception:
        pass
    vthreads = 0
    vthreads_file = f"{REMOTE_ROOT}/work/{verlib}/.vthreads"
    try:
        vthreads_txt = rem.out(f"cat {shlex.quote(vthreads_file)} 2>/dev/null || echo 0").strip()
        vthreads = int(vthreads_txt) if vthreads_txt.isdigit() else 0
    except Exception:
        pass
    if vthreads <= 0:
        # Fall back to nproc; the build uses vthreads=nproc by default.
        vthreads = nproc if nproc > 0 else 12
    if nproc <= 0:
        nproc = vthreads
    # Number of harnesses that can run without oversubscribing.
    workers = max(1, nproc // vthreads)
    # Respect the user's cap and never exceed the number of tests.
    workers = min(workers, requested, n_tests)
    log(f"di workers: {workers} (nproc={nproc} vthreads={vthreads} requested={requested})")
    return workers


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
    log("--- AI testharness (g6lc64_ai; optional) ---")
    for flav, meta in AI_FLAVOURS.items():
        p = f"{REMOTE_ROOT}/work/{meta['verlib']}/Variane_testharness"
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
        "verif/regress/ai-matrix-build-harness.sh",
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


# --------------------------------------------------------------------------
# build manifest (build-platform strict qualification)
# --------------------------------------------------------------------------
#
# The manifest binds a remote harness binary to the exact host source/config
# state it was built from. `build --manifest-out PATH` writes it; the
# build-platform then re-hashes the listed local files and refuses to qualify
# a run whose tree has drifted since the build.
#
# Canonical digests must match digestJson() in build-platform/src/tests/
# runner.ts: JSON.stringify of sorted entries / sorted object keys with no
# spaces == json.dumps(..., sort_keys=True, separators=(",", ":")).


def _manifest_sources(root: Path) -> dict[str, str]:
    """sha256 of every build input, keyed by repo-relative POSIX path.

    Same input set as build_cache_key: seed files plus tracked (or scanned)
    RTL/TB sources under the synced trees.
    """
    exts = {".sv", ".v", ".vlt", ".svh", ".vh", ".cc", ".cpp", ".h", ".hpp"}
    patterns = ["core/**", "corev_apu/**", "common/**", "vendor/**", "verif/tb/**"]
    files: set[Path] = set()
    for rel in (
        "Makefile",
        "verilator_config.vlt",
        "verif/regress/soft-ladder-build-harness.sh",
        "verif/regress/ai-matrix-build-harness.sh",
        "core/Flist.cva6",
        "core/Flist.fetch_B",
        "core/Flist.smt_legacy",
    ):
        p = root / rel
        if p.is_file():
            files.add(p)
    tracked = _git_tracked_files(root, patterns)
    if tracked:
        files.update(f for f in tracked if f.suffix in exts)
    else:
        for pat in patterns:
            d = root / pat.rstrip("/**")
            if d.is_dir():
                files.update(
                    f for f in d.rglob("*")
                    if f.is_file() and f.suffix in exts
                    and not any(
                        part in {".git", "__pycache__"}
                        or str(part).startswith("work-ver")
                        or f.name.endswith((".o", ".d", ".log", ".vcd", ".fst"))
                        for part in f.parts
                    )
                )
    out = {}
    for f in files:
        try:
            out[f.relative_to(root).as_posix()] = hashlib.sha256(
                f.read_bytes()
            ).hexdigest()
        except OSError:
            continue
    return dict(sorted(out.items()))


def _canon_sha256(value) -> str:
    """sha256 of the canonical JSON form (sorted keys, no spaces)."""
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def write_build_manifest(rem: Remote, root: Path, args, verlib: str) -> None:
    """Write a schema-1 build manifest to a repo-relative --manifest-out path."""
    rel = args.manifest_out.replace("\\", "/")
    if (
        not rel
        or rel.startswith("/")
        or ":" in rel
        or any(part == ".." for part in rel.split("/"))
    ):
        die(f"--manifest-out must be a repository-relative path, got '{args.manifest_out}'")
    harness = f"{REMOTE_ROOT}/work/{verlib}/Variane_testharness"
    exe_sha = rem.out(
        f"sha256sum {shlex.quote(harness)} | awk '{{print $1}}'"
    ).strip()
    if not re.fullmatch(r"[0-9a-f]{64}", exe_sha):
        die(f"could not hash remote harness {harness} (got '{exe_sha}')")
    sources = _manifest_sources(root)
    configuration = {
        "flavour": args.flavour,
        "target": args.target,
        "verlib": verlib,
        "defines": AI_FLAVOURS.get(args.flavour, {}).get("defines", ""),
        "jobs": str(args.jobs or ("1" if args.flavour in AI_FLAVOURS else "nproc")),
        "vthreads": str(getattr(args, "vthreads", None) or ("nproc" if args.flavour in AI_FLAVOURS else "harness")),
    }
    for kv in getattr(args, "env", None) or []:
        key, _, value = kv.partition("=")
        if key in ("SOFT_LADDER_ISOLATED", "SOFT_LADDER_OVERLAY"):
            configuration[key] = value
    manifest = {
        "schemaVersion": 1,
        "target": args.target,
        "top": "ariane_testharness",
        "execution": "remote-proxy",
        "sources": sources,
        "sourceSha256": _canon_sha256([[k, v] for k, v in sources.items()]),
        "configuration": configuration,
        "configSha256": _canon_sha256(configuration),
        "executableSha256": exe_sha,
    }
    dest = root / rel
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    log(f"build manifest -> {dest} (exe sha256 {exe_sha[:16]}…, {len(sources)} sources)")


def _expect_exe(rem: Remote, harness: str, want: str) -> None:
    """Refuse to run when the remote binary is not the manifested artifact."""
    if not re.fullmatch(r"[0-9a-f]{64}", want):
        die(f"--expect-exe-sha256 needs a lowercase sha256, got '{want}'")
    got = rem.out(f"sha256sum {shlex.quote(harness)} | awk '{{print $1}}'").strip()
    if got != want:
        die(f"remote harness digest mismatch: {harness} is {got[:16]}…, "
            f"manifest expects {want[:16]}… — rebuild or point at the right flavour")


def cmd_build(rem: Remote, args) -> int:
    rem.start_master()
    ai_meta = AI_FLAVOURS.get(args.flavour)
    verlib, _stock = flavour_info(args.flavour)
    if args.verlib:
        verlib = args.verlib
    prod_mdirs = {
        "work-ver-smt2-fw64", "work-ver-smt2-fw64-B",
        "work-ver-stream8", "work-ver-smt2",
    }
    isolated = any(
        kv.partition("=")[0] == "SOFT_LADDER_ISOLATED" and kv.partition("=")[2] == "1"
        for kv in (getattr(args, "env", None) or [])
    )
    if isolated and Path(verlib).name in prod_mdirs:
        die(f"isolated candidate must not reuse production Mdir {Path(verlib).name}")
    if ai_meta and args.target == DEFAULT_TARGET:
        args.target = ai_meta["target"]

    if args.sync:
        rc = cmd_sync(rem, argparse.Namespace(full=False))
        if rc != 0:
            return rc

    if rem.check(f"test -f {REMOTE_ROOT}/env.sh", quiet=True) != 0:
        die(f"remote env.sh missing; run '{sys.argv[0]} setup {args.host}' first")

    if ai_meta:
        _no_overlap_guard(rem, f"build {args.flavour}")

    # AI C++ compile (make -j / cc1plus) OOMs at -j2 on 30 Gi. Keep jobs=1.
    # Model --threads (vthreads) defaults to remote nproc in the harness so
    # one Variane_testharness saturates the host at run. Override:
    #   --jobs N                 C++ make -j (still capped unless ALLOW_HIGH_JOBS)
    #   --vthreads N             verilator --threads (default nproc)
    jobs = args.jobs or ("1" if ai_meta else "$(nproc)")
    clean = "1" if args.clean else "0"
    root = repo_root()
    verlib_dir = f"{REMOTE_ROOT}/work/{verlib}"

    if ai_meta:
        env_vars = [
            f"AI_MATRIX_VERLIB={shlex.quote(verlib_dir)}",
            f"AI_MATRIX_TARGET={shlex.quote(args.target)}",
            f"AI_MATRIX_DEFINES={shlex.quote(ai_meta['defines'])}",
            f"AI_MATRIX_BUILD_JOBS={shlex.quote(jobs)}",
            f"AI_MATRIX_BUILD_CLEAN={shlex.quote(clean)}",
            f"AI_MATRIX_FLAVOUR={shlex.quote(args.flavour)}",
            "VLT_HOME=\"$VLT_HOME\"",
        ]
        vthreads = getattr(args, "vthreads", None)
        if vthreads is not None:
            env_vars.append(
                f"AI_MATRIX_VERILATOR_THREADS={shlex.quote(str(vthreads))}"
            )
    else:
        env_vars = [
            f"SOFT_LADDER_VERLIB={shlex.quote(verlib_dir)}",
            f"SOFT_LADDER_BUILD_TARGET={shlex.quote(args.target)}",
            f"SOFT_LADDER_BUILD_JOBS={shlex.quote(jobs)}",
            f"SOFT_LADDER_BUILD_CLEAN={shlex.quote(clean)}",
            "VLT_HOME=\"$VLT_HOME\"",
        ]
    for kv in args.env:
        env_vars.append(shlex.quote(kv))

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

    if ai_meta:
        build_sh = "verif/regress/ai-matrix-build-harness.sh"
    else:
        build_sh = "verif/regress/soft-ladder-build-harness.sh"
    script = (
        f"{env_prefix()} cd {REMOTE_ROOT}/repo && "
        f"mkdir -p {REMOTE_ROOT}/work && "
        + " ".join(env_vars)
        + f" bash {build_sh} {shlex.quote(args.flavour)}"
    )
    vth = getattr(args, "vthreads", None)
    vth_s = str(vth) if vth is not None else ("nproc" if ai_meta else "harness")
    log(
        f"building flavour={args.flavour} verlib={verlib} target={args.target} "
        f"jobs={jobs} vthreads={vth_s}"
    )
    rem.dbg(f"build script: {script[:240]}...")
    t0 = time.time()
    rc = rem.run(script, check=False).returncode
    log(f"build {'OK' if rc == 0 else 'FAILED'} in {time.time() - t0:.1f}s")

    if rc == 0:
        # Record nproc and the actual vthreads used by the build so the DI
        # worker pool can be sized to saturate the host without oversubscribing.
        rem.run(
            f"command -v nproc >/dev/null 2>/dev/null && nproc > {shlex.quote(verlib_dir + '/.nproc')} || true",
            check=False,
        )
        rem.run(
            f"grep -m1 'vthreads=' {shlex.quote(verlib_dir + '/build.log')} | "
            f"sed 's/.*vthreads=//' | head -1 > {shlex.quote(verlib_dir + '/.vthreads')} 2>/dev/null || true",
            check=False,
        )

    if rc == 0 and args.manifest_out:
        write_build_manifest(rem, root, args, verlib)

    if rc == 0 and args.output_cache and cache_dir:
        rem.run(
            f"mkdir -p {shlex.quote(f'{REMOTE_ROOT}/cache/builds')} && "
            f"rm -rf {shlex.quote(cache_dir)} && "
            f"cp -a {shlex.quote(verlib_dir)} {shlex.quote(cache_dir)}"
        )
        log(f"output cache archived to {cache_dir}")

    return rc


def _kill_stranded_harnesses(rem: Remote) -> None:
    """Pre-flight cleanup: terminate any Variane_testharness left by a
    previous hung or aborted session before starting a new one. This is a
    best-effort defence against multiple heavy Verilator processes stacking up
    on the remote builder."""
    # Match the harness binary path only. `pkill -f Variane_testharness` also
    # hits `g++ -c …/Variane_testharness_*.cpp` during a rebuild (SIGTERM on
    # cc1plus, 15-min "Terminated" make). Slash + (space or EOL) excludes those.
    rc = rem.run("pkill -f '[/]Variane_testharness( |$)' || true", check=False).returncode
    if rc == 0:
        log("pre-flight pkill: no stray Variane_testharness processes")
    else:
        log(f"pre-flight pkill returned rc={rc} (may be normal if none found)")


def _no_overlap_guard(rem: Remote, command: str = "") -> None:
    """Refuse to start a new testharness workload if another one is already
    running on the remote host. Prevents the parallel-simulation flakiness that
    happens when heavy Verilator processes or soft-ladder scripts overlap.

    The check uses a regex class on the first character so the pgrep command
    line does not match itself."""
    procs = rem.out(
        "pgrep -a -f '[/]Variane_testharness( |$)|[s]oft-ladder' || true"
    ).strip()
    if procs:
        # Filter out the pgrep line itself (it contains the pattern as a string).
        lines = [ln for ln in procs.splitlines() if "pgrep -a -f" not in ln]
        if lines:
            log("overlap guard: existing testharness/soft-ladder processes found:")
            for ln in lines:
                log(f"  {ln}")
            if command:
                die(f"refusing to start '{command}' while another workload is running")
            die("refusing to start another workload while a testharness is running")


def cmd_run(rem: Remote, args) -> int:
    rem.start_master()
    _kill_stranded_harnesses(rem)
    _no_overlap_guard(rem, "run")
    verlib, _ = flavour_info(args.flavour)
    if args.verlib:
        verlib = args.verlib
    harness = f"{REMOTE_ROOT}/work/{verlib}/Variane_testharness"

    if rem.check(f"test -x {harness}", quiet=True) != 0:
        die(f"no remote harness for flavour '{args.flavour}': {harness}\n"
            f"       build it first:  {sys.argv[0]} build {args.flavour}")

    if getattr(args, "expect_exe_sha256", None):
        _expect_exe(rem, harness, args.expect_exe_sha256)

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

    def _tohost_addr(e: Path) -> str:
        for nm in (
            os.environ.get("CROSS_COMPILE", "") + "nm",
            "riscv-none-elf-nm",
            "riscv64-unknown-elf-nm",
            "nm",
        ):
            if not nm:
                continue
            try:
                proc = subprocess.run(
                    [shutil.which(nm) or nm, str(e)],
                    check=False, capture_output=True, text=True,
                )
                for line in proc.stdout.splitlines():
                    m = re.match(r"^([0-9a-fA-F]+)\s+\S\s+tohost\s*$", line)
                    if m:
                        return f"+tohost_addr=0x{m.group(1)} "
            except Exception:
                continue
        return ""

    tohost_arg = _tohost_addr(elf)
    if not tohost_arg:
        log(f"WARNING: no tohost symbol for {elf}; relying on harness default")
    plusargs = " ".join(shlex.quote(a) for a in args.plusarg)
    env_vars = " ".join(shlex.quote(kv) for kv in args.env)
    if env_vars:
        env_vars = f"export {env_vars}; "
    logfile = f"{rundir}/run-{args.flavour}.log"
    # g6lc64_ai at -O0: Verilator combo eval of dual-core scoreboard + 256 Mi
    # SRAM blew the default 8 Mi stack (SIGSEGV at ~2.6k cycles, guard page
    # in ProcMaps). Soft-ladder B/legacy stay well under 8 Mi.
    run_id = getattr(args, "run_id", None)
    stamp = (
        f"printf '%s\\n' {shlex.quote(run_id)} > {shlex.quote(rundir)}/run-id && "
        if run_id else ""
    )
    script = (
        f"{env_prefix()} {env_vars}cd {rundir} && ulimit -s unlimited && "
        f"{stamp}"
        f"{shlex.quote(harness)} +time_out={args.time_out} "
        f"+max-cycles={args.time_out} +debug_disable +quiet_axi "
        f"{tohost_arg}{plusargs} {shlex.quote(remote_elf)} > {shlex.quote(logfile)} 2>&1; "
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
    _kill_stranded_harnesses(rem)
    _no_overlap_guard(rem, "soak")
    verlib, _ = flavour_info(args.flavour)
    if args.verlib:
        verlib = args.verlib
    harness = f"{REMOTE_ROOT}/work/{verlib}/Variane_testharness"
    if getattr(args, "expect_exe_sha256", None):
        _expect_exe(rem, harness, args.expect_exe_sha256)
    env = [f"SOFT_LADDER_FETCH={args.flavour}",
           f"SOFT_LADDER_HARNESS={REMOTE_ROOT}/work/{verlib}"]
    if args.skip_build:
        env.append("SOFT_LADDER_SKIP_BUILD=1")
    else:
        env.append("SOFT_LADDER_SKIP_BUILD=0")
    if args.hold:
        env.append("SOFT_LADDER_HOLD=1")
    tag = getattr(args, "tag", None)
    if getattr(args, "run_id", None) or args.pull or tag:
        tag = tag or f"soak-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
        rundir = f"{REMOTE_ROOT}/runs/{tag}"
        env.append(f"SOFT_LADDER_OSBI_OUT={rundir}")
    if getattr(args, "run_id", None):
        env.append(f"G6LC_RUN_ID={args.run_id}")
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
    if args.pull:
        dest = repo_root() / "remote-runs" / tag
        rem.pull(f"{rundir}/", dest)
        log(f"pulled logs -> {dest}")
    return rc


def cmd_di(rem: Remote, args) -> int:
    """Compile the directed mini (DI) suite locally and run it on the remote
    harness consecutively. Each test gets its own remote log; logs can be pulled
    back with --pull.

    This mirrors verif/regress/soft-ladder-di-regress.sh, but keeps exactly one
    Variane_testharness running at a time. Verilator already pins vthreads to the
    remote host's nproc, so a single harness saturates the machine; running more
    in parallel oversubscribes cores and makes tests flaky.

    H3 (Oracle Validity First): the two oracle controls run before the suite.
    mini_must_pass must PASS and mini_must_fail must FAIL; if either verdict is
    wrong the suite is not run and this returns non-zero, because the verdicts
    it would produce are not measurements. Bypass with --no-oracle-check.
    """
    rem.start_master()
    _kill_stranded_harnesses(rem)
    _no_overlap_guard(rem, "di")
    root = repo_root()
    verlib, _ = flavour_info(args.flavour)
    if args.verlib:
        verlib = args.verlib
    harness = f"{REMOTE_ROOT}/work/{verlib}/Variane_testharness"

    if rem.check(f"test -x {shlex.quote(harness)}", quiet=True) != 0:
        die(f"no remote harness '{harness}'; build first: {sys.argv[0]} build {args.flavour}")

    tests = [t for t in (args.tests if args.tests else DEFAULT_DI_TESTS)
             if t not in ORACLE_CONTROLS]
    if not tests:
        die("no tests selected")

    # H3 preflight: the two oracle controls are compiled and uploaded with the
    # suite but are NOT suite members -- they run first, are reported
    # separately, and never enter the pass/fail counts.
    oracle_check = not getattr(args, "no_oracle_check", False)
    controls = list(ORACLE_CONTROLS) if oracle_check else []
    compile_list = controls + tests

    # Build all minis locally using the existing shell script in compile-only mode.
    out = Path(args.out) if args.out else Path(tempfile.mkdtemp(prefix="th-di-"))
    out.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["SOFT_LADDER_COMPILE_ONLY"] = "1"
    env["SOFT_LADDER_OUT"] = str(out)
    env["SOFT_LADDER_TESTS"] = " ".join(compile_list)
    script = f"cd {shlex.quote(str(root))} && bash verif/regress/soft-ladder-di-regress.sh"
    log(f"compiling {len(compile_list)} DI tests -> {out}")
    t0 = time.time()
    proc = subprocess.run(script, shell=True, env=env, check=False,
                          capture_output=True, text=True)
    if _DEBUG and proc.stdout:
        debug(proc.stdout[-2000:])
    if proc.returncode != 0:
        if proc.stdout:
            log(proc.stdout[-2000:])
        if proc.stderr:
            log(proc.stderr[-2000:])
        die("DI compile failed")
    log(f"compile finished in {time.time()-t0:.1f}s")

    # Map each test to its compiled ELF.
    elfs = {}
    missing = []
    for t in compile_list:
        e = out / f"{t}.elf"
        if e.is_file():
            elfs[t] = e
        else:
            missing.append(t)
    if missing:
        if any(t in ORACLE_CONTROLS for t in missing):
            log("[di] ORACLE INVALID - an oracle control did not build: "
                f"{[t for t in missing if t in ORACLE_CONTROLS]}")
            log("[di] the toolchain or linker script cannot even produce the "
                "controls, so no verdict from this suite would be a measurement")
        die(f"compiled ELF missing for: {missing}")

    # Upload all ELFs before the thread pool starts (minimises rsync overlap).
    tag = args.tag or f"di-{datetime.now().strftime('%Y%m%d-%H%M%S')}"
    rundir = f"{REMOTE_ROOT}/runs/{tag}"
    rem.run(f"mkdir -p {shlex.quote(rundir)}")
    log(f"uploading {len(elfs)} ELFs -> {rundir}")
    t0 = time.time()
    for t, e in elfs.items():
        rem.push(e, f"{rundir}/{t}.elf")
    log(f"upload finished in {time.time()-t0:.1f}s")

    plusargs = " ".join(shlex.quote(a) for a in args.plusarg)
    tail = args.tail
    log_lock = threading.Lock()

    def th_log(msg: str) -> None:
        with log_lock:
            log(msg)

    def tohost_addr(elf: Path) -> str:
        for nm in (
            os.environ.get("CROSS_COMPILE", "") + "nm",
            "riscv-none-elf-nm",
            "riscv64-unknown-elf-nm",
            "nm",
        ):
            if not nm:
                continue
            try:
                proc = subprocess.run(
                    [shutil.which(nm) or nm, str(elf)],
                    check=False, capture_output=True, text=True,
                )
                for line in proc.stdout.splitlines():
                    m = re.match(r"^([0-9a-fA-F]+)\s+\S\s+tohost\s*$", line)
                    if m:
                        return m.group(1)
            except Exception:
                continue
        return ""

    def run_one(test: str, elf: Path) -> tuple[str, bool, str, float]:
        remote_elf = f"{rundir}/{test}.elf"
        logfile = f"{rundir}/{test}.log"
        th = tohost_addr(elf)
        if not th:
            th_log(f"[di] WARNING {test}: no tohost symbol; using 0")
            tohost_arg = ""
        else:
            tohost_arg = f"+tohost_addr=0x{th} "
        th_log(f"[di] start {test} tohost=0x{th}")
        t0_run = time.time()
        script = (
            f"{env_prefix()} cd {shlex.quote(rundir)} && "
            f"{shlex.quote(harness)} +time_out={args.time_out} "
            f"+max-cycles={args.time_out} +debug_disable +quiet_axi "
            f"{tohost_arg}{plusargs} {shlex.quote(remote_elf)} > {shlex.quote(logfile)} 2>&1; "
            f"rc=$?; echo \"rc=$rc\"; "
            # Classify on the REMOTE, against the whole log, and echo one verdict
            # line. Classifying locally from `tail -n N` silently under-reports:
            # the rvfi_tracer termination notice is printed at the moment of
            # termination and is then buried by trailing probe output, so it falls
            # outside the tail window and a genuine PASS reads as a timeout. That
            # cost a 1/16 report where the logs said 4/18.
            f"L={shlex.quote(logfile)}; T=0; "
            f"grep -q 'rvfi_tracer.* Simulation terminated' \"$L\" && T=1; "
            f"if grep -q '\\*\\*\\* FAILED \\*\\*\\*' \"$L\"; then echo 'verdict=FAIL reason=exit-code'; "
            f"elif grep -q '\\*\\*\\* SUCCESS \\*\\*\\*' \"$L\"; then "
            f"  if [ \"$T\" = 1 ]; then echo 'verdict=PASS reason=terminated'; "
            f"  else echo 'verdict=FAIL reason=timeout'; fi; "
            f"else echo 'verdict=FAIL reason=no-output'; fi; "
            f"tail -n {tail} \"$L\""
        )
        proc = rem.run(script, check=False, capture=True)
        out_text = proc.stdout
        # The remote script always echoes "rc=N" before the tail.
        match = re.search(r"^rc=(\d+)", out_text, re.MULTILINE)
        rc = int(match.group(1)) if match else proc.returncode
        # Pass/fail classification. The obvious rules are all wrong and two have
        # already shipped; see soft-ladder-di-regress.sh for the same reasoning.
        #
        # The harness prints dtm->exit_code(), NOT the raw tohost word. HTIF uses
        # tohost bit0 as "done" with bits[31:1] as the exit code, so a test that
        # writes tohost=1 prints "(tohost = 0)" and one that writes tohost=3
        # prints "(tohost = 1)". A "tohost == 1 means pass" rule matches the
        # FAILING run and misses the passing one. Measured 2026-08-31:
        #   mini_must_pass -> *** SUCCESS *** (tohost = 0) after 318 cycles
        #   mini_must_fail -> *** FAILED ***  (tohost = 1) after 318 cycles
        #
        # "SUCCESS" alone is also insufficient -- which is what motivated the
        # inverted rule: on a timeout no exit code is set, so exit_code()==0 and
        # the harness prints the SAME success line. Pass and timeout are
        # indistinguishable in that string.
        #
        # The discriminator is the rvfi_tracer notice, which only appears when the
        # tohost write is actually observed (rvfi_tracer.sv: mem_paddr ==
        # TOHOST_ADDR && mem_wdata[0]). Verified present for both controls at 318
        # cycles and absent under a 300-cycle cap. A pass needs BOTH.
        # Parse the remote verdict line. A MISSING verdict is a failure, never a
        # pass: if the classifier did not run we know nothing, and defaulting to
        # pass is how a silent oracle turns into a green report.
        vm = re.search(r"^verdict=(PASS|FAIL) reason=(\S+)", out_text, re.MULTILINE)
        if vm:
            passed = vm.group(1) == "PASS"
            why = vm.group(2)
        else:
            passed = False
            why = "no-verdict"
        tohost_match = re.search(r"\(tohost = (?:0x)?([0-9a-fA-F]+)\)", out_text)
        tohost = int(tohost_match.group(1), 16) if tohost_match else -1
        if not passed:
            th_log(f"[di]   {test}: not a pass ({why})")
        th_log(f"[di] {'PASS' if passed else 'FAIL'} {test} rc={rc} tohost={tohost} in {time.time()-t0_run:.1f}s")
        if args.pull:
            dest = repo_root() / "remote-runs" / tag / f"{test}.log"
            dest.parent.mkdir(parents=True, exist_ok=True)
            try:
                rem.pull(logfile, dest)
            except Exception as exc:
                th_log(f"[di] pull {test} failed: {exc}")
        return (test, passed, out_text, time.time() - t0_run)

    # --- H3 oracle preflight ------------------------------------------------
    # Run the two controls FIRST, through the same run_one() path as the suite,
    # one at a time (no overlap). mini_must_pass must PASS and mini_must_fail
    # must FAIL. If either is wrong the suite is not run at all: its results
    # would not be measurements. --no-oracle-check bypasses this for debugging.
    if oracle_check:
        th_log("[di] oracle preflight (H3): "
               f"{ORACLE_POSITIVE} must PASS, {ORACLE_NEGATIVE} must FAIL")
        verdicts: dict[str, tuple[bool, str]] = {}
        for ctl, want_pass in ((ORACLE_POSITIVE, True), (ORACLE_NEGATIVE, False)):
            _, passed, ctl_out, _ = run_one(ctl, elfs[ctl])
            verdicts[ctl] = (passed, ctl_out)
            th_log(f"[di] control {ctl}: got {'PASS' if passed else 'FAIL'}, "
                   f"expected {'PASS' if want_pass else 'FAIL'}")
        pos_ok = verdicts[ORACLE_POSITIVE][0] is True
        neg_ok = verdicts[ORACLE_NEGATIVE][0] is False
        if not (pos_ok and neg_ok):
            log("-" * 60)
            log("[di] ORACLE INVALID - H3 'Oracle Validity First' precondition "
                "is not met")
            if not pos_ok:
                log(f"[di]   positive control {ORACLE_POSITIVE} did not PASS: the "
                    "oracle cannot say PASS.")
                log("[di]   The harness, toolchain or link is broken and every "
                    "verdict in this run would be void.")
                for line in verdicts[ORACLE_POSITIVE][1].splitlines()[-10:]:
                    log(f"         {line}")
            if not neg_ok:
                log(f"[di]   negative control {ORACLE_NEGATIVE} was reported as "
                    "PASS: the oracle cannot say FAIL.")
                log("[di]   The classifier is pass-biased - this is the "
                    "2026-08-31 defect class ('*** SUCCESS *** (tohost = 0)' "
                    "read as a pass) - and every recorded PASS is void.")
                for line in verdicts[ORACLE_NEGATIVE][1].splitlines()[-10:]:
                    log(f"         {line}")
            log(f"[di] suite NOT run ({len(tests)} tests skipped). Fix the "
                "oracle, or re-run with --no-oracle-check to bypass.")
            log("-" * 60)
            return 2
        th_log("[di] oracle preflight OK: the classifier can say both PASS and FAIL")
    else:
        log("[di] oracle preflight DISABLED (--no-oracle-check) - H3 unmet")

    t0_all = time.time()
    # DI is intentionally single-threaded on the remote: one Variane_testharness
    # with vthreads=nproc already saturates the builder; overlapping harnesses
    # oversubscribe and cause flaky fails (e.g. mini_fdt_lenp_sw).
    max_workers = 1
    log(f"di workers: {max_workers} (consecutive mode)")
    results: dict[str, tuple[str, bool, str, float]] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as ex:
        # Controls are a gate, not suite members: never submitted here.
        futures = {ex.submit(run_one, t, elfs[t]): t for t in tests}
        for fut in concurrent.futures.as_completed(futures):
            test = futures[fut]
            try:
                results[test] = fut.result()
            except Exception as exc:
                th_log(f"[di] ERROR {test}: {exc}")
                results[test] = (test, False, str(exc), 0.0)

    wall = time.time() - t0_all
    pass_n = sum(1 for _, p, _, _ in results.values() if p)
    fail_n = len(results) - pass_n

    log("-" * 60)
    for t in tests:
        _, p, out_text, dt = results.get(t, (t, False, "", 0.0))
        status = "PASS" if p else "FAIL"
        log(f"[di] {status:4} {t:32} {dt:6.1f}s")
        if not p and out_text:
            tail_lines = out_text.splitlines()[-5:]
            for line in tail_lines:
                log(f"       {line}")
    log("-" * 60)
    log(f"DI summary: pass={pass_n} fail={fail_n} tests={len(tests)} wall={wall:.1f}s")
    if args.pull:
        log(f"pulled logs -> {repo_root() / 'remote-runs' / tag}")
    return 0 if fail_n == 0 else 1


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


def l2_leaf_sources(snapshot: Path, extra: list[str] | None = None) -> dict[str, str]:
    root = snapshot.resolve(strict=True)
    paths = [
        "vendor/pulp-platform/axi/src/axi_pkg.sv",
        "vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv",
        *[f"corev_apu/l2_cache/g6lc_l2_{name}.sv" for name in ("pkg", "tag", "data", "mshr", "top")],
        "verif/tb/l2/tb_g6lc_l2.sv", "verif/tb/l2/tb_g6lc_l2.vlt", "verif/tb/l2/run-l2-tb.sh",
    ]
    paths += list(extra or [])
    result = {}
    for path in paths:
        source = (root / path).resolve(strict=True)
        if not source.is_relative_to(root) or not source.is_file():
            raise ValueError(f"invalid L2 snapshot input: {path}")
        result[path] = hashlib.sha256(source.read_bytes()).hexdigest()
    return result


def l2_leaf_passed(text: str, rc: int, ways: int, rr_en: int) -> bool:
    if ways not in (2, 4, 8) or rr_en not in (0, 1):
        return False
    policies = re.findall(r"^\[L2TB\] policy checks lookups=(\d+) installs=(\d+) evictions=(\d+) victim_mask=([0-9a-fA-F]+)$", text, re.M)
    if len(policies) != 1:
        return False
    lookups, installs, evictions = map(int, policies[0][:3])
    return (rc == 0 and lookups >= installs >= evictions >= (ways if rr_en else 1)
            and int(policies[0][3], 16) == ((1 << ways) - 1 if rr_en else 1)
            and text.splitlines().count("[L2TB] RESULT pass") == 1
            and not re.search(r"FAIL|%Error|%Fatal", text)
            and all(f"[L2TB] ATOP mode={mode} forwarded=1" in text for mode in range(3))
            and "[L2TB] AMO arith add=1 swap=1 cas_hit=1 cas_miss=1 lrsc_ok=1 lrsc_fail=1" in text
            and all(f"phase={phase}" in text for phase in ("replacement_hole", "bypass_backpressure", "short_last_fill_guard")))


def l2_units_passed(text: str, rc: int) -> bool:
    return (
        rc == 0
        and text.splitlines().count("[L2UNIT] RESULT pass") == 1
        and "[L2UNIT] mshr_full=1 merge=1 merge_full=1 waiter=1 bank_conflict=1 bank_ok=1" in text
        and not re.search(r"FAIL|%Error|%Fatal", text)
    )


def l2_synth_passed(text: str, rc: int, rr_en: int) -> bool:
    if rr_en not in (0, 1):
        return False
    mem = 2 + rr_en
    # Yosys logs mention $dlatch in the select command; the runner already
    # asserted no latches and the expected $mem_v2 count before printing PASS.
    return rc == 0 and f"[l2-tb] SYNTH PASS rr={rr_en} mem={mem}" in text


def cmd_l2_leaf(rem: Remote, args) -> int:
    root = Path(args.snapshot).resolve()
    mode = getattr(args, "mode", "sim")
    extra = ["verif/tb/l2/tb_g6lc_l2_units.sv"] if mode == "units" else []
    sources = l2_leaf_sources(root, extra)
    if args.mem_latency < 0 or args.stall_every < 0 or args.stall_every == 1:
        die("invalid L2 memory latency/stall period")
    tag = f"l2-leaf-{datetime.now().strftime('%Y%m%dT%H%M%S')}-{os.urandom(6).hex()}"
    rundir = f"{REMOTE_ROOT}/runs/{tag}"
    source_dir = f"{rundir}/source"
    dest = repo_root() / "remote-runs" / tag
    dest.mkdir(parents=True, exist_ok=False)
    rem.start_master()
    rem.run(f"ls -d {shlex.quote(REMOTE_ROOT + '/runs')} && mkdir {shlex.quote(rundir)}")
    parents = sorted({f"{source_dir}/{Path(path).parent.as_posix()}" for path in sources})
    rem.run("mkdir -p " + " ".join(map(shlex.quote, [*parents, f"{rundir}/output"])))
    for path in sources:
        rem.push(root / path, f"{source_dir}/{path}")
    checksums = "".join(f"{digest}  {path}\n" for path, digest in sources.items())
    rem.run(f"cd {shlex.quote(source_dir)} && printf %s {shlex.quote(checksums)} | sha256sum -c -")
    verilator = f"{REMOTE_ROOT}/toolchains/verilator-{VERILATOR_VERSION}/bin/verilator"
    env = {
        "VERILATOR": verilator, "L2TB_OUT": f"{rundir}/output", "L2TB_RR_EN": str(args.rr_en),
        "L2TB_SET_ASSOC": str(args.ways), "L2TB_MEM_LATENCY": str(args.mem_latency),
        "L2TB_STALL_EVERY": str(args.stall_every), "L2TB_MODE": mode,
        "L2TB_BYTE_SIZE": "4096", "L2TB_SEED": str(0x600df00d), "L2TB_EXTRA": "",
    }
    if mode == "synth":
        env["YOSYS"] = f"{REMOTE_ROOT}/toolchains/formal/bin/yosys"
    command = " ".join(shlex.quote(f"{key}={value}") for key, value in env.items())
    plus = "+bypass-backpressure +atop-drain +amo-arith " if mode == "sim" else ""
    log(f"isolated L2 leaf mode={mode} -> {rundir}; no shared repo sync or cleanup")
    rc = rem.run(
        f"{env_prefix()} cd {shlex.quote(source_dir)} && env {command} bash verif/tb/l2/run-l2-tb.sh "
        f"{plus}> {shlex.quote(rundir + '/driver.log')} 2>&1",
        check=False, timeout=args.timeout or 900, heartbeat=True,
    ).returncode
    rem.pull(f"{rundir}/driver.log", dest)
    rem.pull(f"{rundir}/output/", dest / "output")
    log_name = "synth.log" if mode == "synth" else "sim.log"
    logs = list((dest / "output").glob(f"run-*/{log_name}"))
    text = logs[0].read_text(errors="replace") if len(logs) == 1 else ""
    if mode == "units":
        passed = l2_units_passed(text, rc)
        kind = "rtl-leaf-units"
    elif mode == "synth":
        passed = l2_synth_passed(text + "\n" + (dest / "driver.log").read_text(errors="replace"), rc, args.rr_en)
        kind = "rtl-leaf-synth"
    else:
        passed = l2_leaf_passed(text, rc, args.ways, args.rr_en)
        kind = "rtl-leaf-diagnostic"
    record = {
        "kind": kind, "execution": "remote-proxy", "runId": tag,
        "status": "pass" if passed else "fail", "sources": sources, "configuration": env,
        "remoteReturnCode": rc, "strictQualification": False,
    }
    (dest / "leaf-result.json").write_text(json.dumps(record, indent=2) + "\n")
    log(f"L2 leaf {mode} {'PASS' if passed else 'FAIL'}: pulled diagnostics in {dest}; not core/SMT qualification")
    return 0 if passed else 1


def l2_equiv_passed(text: str, rc: int, negative: bool) -> bool:
    if negative:
        return rc != 0 and ("unproven" in text.lower() or "ERROR" in text or "Assert" in text)
    return (
        rc == 0
        and "[l2-tb] EQUIVALENCE PASS" in text
        and "LADDER FAIL" not in text
        and "timeout: failed" not in text.lower()
        and "ERROR: " not in text
    )


def cmd_l2_equiv(rem: Remote, args) -> int:
    root = Path(args.snapshot).resolve()
    sources = l2_leaf_sources(root)
    if args.byte_size < 256 or args.byte_size.bit_count() != 1:
        die("L2 equivalence byte size must be a power of two >= 256")
    tag = f"l2-equiv-{datetime.now().strftime('%Y%m%dT%H%M%S')}-{os.urandom(6).hex()}"
    rundir = f"{REMOTE_ROOT}/runs/{tag}"
    source_dir = f"{rundir}/source"
    dest = repo_root() / "remote-runs" / tag
    dest.mkdir(parents=True, exist_ok=False)
    rem.start_master()
    rem.run(f"ls -d {shlex.quote(REMOTE_ROOT + '/runs')} && mkdir {shlex.quote(rundir)}")
    parents = sorted({f"{source_dir}/{Path(path).parent.as_posix()}" for path in sources})
    rem.run("mkdir -p " + " ".join(map(shlex.quote, [*parents, f"{rundir}/output"])))
    for path in sources:
        rem.push(root / path, f"{source_dir}/{path}")
    blob = "5be075b1a01ff754da384c3dd129fd58c33733fa"
    legacy = subprocess.check_output(["git", "-C", str(repo_root()), "cat-file", "blob", blob])
    rem.run(f"mkdir -p {shlex.quote(source_dir + '/equiv-ref')}")
    tmp = dest / "legacy.original.sv"
    tmp.write_bytes(legacy)
    rem.push(tmp, f"{source_dir}/equiv-ref/legacy.original.sv")
    checksums = "".join(f"{digest}  {path}\n" for path, digest in sources.items())
    rem.run(f"cd {shlex.quote(source_dir)} && printf %s {shlex.quote(checksums)} | sha256sum -c -")
    mem = "" if args.mem == "auto" else args.mem
    formal_bin = f"{REMOTE_ROOT}/toolchains/formal/bin"
    env = {
        "L2TB_OUT": f"{rundir}/output", "L2TB_MODE": "equiv",
        "L2TB_BYTE_SIZE": str(args.byte_size), "L2TB_SET_ASSOC": str(args.ways),
        "L2TB_EQ_MEM": mem, "L2TB_EQ_NEGATIVE": "1" if args.negative else "0",
        "L2TB_EQ_LADDER": "1" if args.ladder else "0",
        "L2TB_EQ_BASE_FILE": f"{source_dir}/equiv-ref/legacy.original.sv",
        "L2TB_EQ_TIMEOUT": str(args.timeout or (120 if mem == "map" or args.byte_size <= 512 else 300)),
        "YOSYS": f"{formal_bin}/yosys",
    }
    command = " ".join(shlex.quote(f"{key}={value}") for key, value in env.items() if value != "")
    log(f"isolated L2 equiv -> {rundir}; no shared repo sync or cleanup")
    rc = rem.run(
        f"{env_prefix()} cd {shlex.quote(source_dir)} && env {command} bash verif/tb/l2/run-l2-tb.sh "
        f"> {shlex.quote(rundir + '/driver.log')} 2>&1",
        check=False, timeout=args.timeout or 1800, heartbeat=True,
    ).returncode
    rem.pull(f"{rundir}/driver.log", dest)
    rem.pull(f"{rundir}/output/", dest / "output")
    logs = list((dest / "output").glob("run-*/equiv.log")) + [dest / "driver.log"]
    text = ""
    for path in logs:
        if path.is_file():
            text += path.read_text(errors="replace") + "\n"
    passed = l2_equiv_passed(text, rc, args.negative)
    record = {
        "kind": "rtl-leaf-equivalence", "execution": "remote-proxy", "runId": tag,
        "status": "pass" if passed else "fail", "sources": sources, "configuration": env,
        "remoteReturnCode": rc, "strictQualification": False,
    }
    (dest / "leaf-result.json").write_text(json.dumps(record, indent=2) + "\n")
    log(f"L2 equiv {'PASS' if passed else 'FAIL'}: pulled diagnostics in {dest}; not production-geometry sign-off")
    return 0 if passed else 1


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
        #
        # Shell is the back-door used by helper scripts to launch the DI suite;
        # apply the same overlap guard so two consecutive shell invocations do not
        # both start heavy Variane/soft-ladder workloads.
        if re.search(r"Variane_testharness|soft-ladder", args.command):
            _kill_stranded_harnesses(rem)
            _no_overlap_guard(rem, f"shell ({args.command[:60]}...)")
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
    sp.add_argument("flavour", choices=flavour_names())
    sp.add_argument("--target", default=DEFAULT_TARGET)
    sp.add_argument("--verlib", default=None)
    sp.add_argument("--jobs", default=None,
                    help="C++ make -j. AI default 1 (cc1plus OOM at -j2 on 30Gi).")
    sp.add_argument("--vthreads", default=None, type=int,
                    help="Verilator --threads for the model (AI default: remote nproc). "
                         "One Variane_testharness then saturates the host. "
                         "Does not raise C++ make -j.")
    sp.add_argument("--clean", action="store_true",
                    help="wipe the flavour Mdir and rebuild from scratch")
    sp.add_argument("--cache", default=True, action=argparse.BooleanOptionalAction,
                    help="use ccache and mold if available (default: --cache)")
    sp.add_argument("--no-sync", dest="sync", action="store_false", default=True,
                    help="skip repo sync before build")
    sp.add_argument("--output-cache", default=False, action="store_true",
                    help="seed from and archive the full Mdir in a content-keyed cache")
    sp.add_argument("--env", action="append", default=[],
                    help="extra KEY=VALUE env var for the build (repeatable)")
    sp.add_argument("--manifest-out", default=None,
                    help="write a schema-1 build manifest to this repo-relative "
                         "path after a successful build (strict qualification)")
    sp.set_defaults(fn=cmd_build)

    sp = sub.add_parser("run", help="upload one ELF and run it (minimal payload)")
    sp.add_argument("elf")
    sp.add_argument("--flavour", choices=flavour_names(), default="B")
    sp.add_argument("--verlib", default=None)
    sp.add_argument("--tag", default=None, help="run dir name (default <elf>-<sha>)")
    sp.add_argument("--time-out", dest="time_out", default="400000")
    sp.add_argument("--plusarg", action="append", default=[],
                    help="extra +plusarg (repeatable)")
    sp.add_argument("--tail", type=int, default=30)
    sp.add_argument("--env", action="append", default=[],
                    help="extra KEY=VALUE for the harness environment (repeatable)")
    sp.add_argument("--run-id", default=None,
                    help="stamp this run id into <rundir>/run-id (pulled with --pull)")
    sp.add_argument("--expect-exe-sha256", default=None,
                    help="refuse to run unless the remote harness sha256 matches")
    sp.add_argument("--pull", action="store_true", help="copy logs back when done")
    sp.set_defaults(fn=cmd_run)

    sp = sub.add_parser("soak", help="run the OpenSBI cookie soak remotely")
    sp.add_argument("--flavour", choices=flavour_names(), default="B")
    sp.add_argument("--verlib", default=None,
                    help="override the Verilator work directory name")
    sp.add_argument("--skip-build", action="store_true",
                    help="reuse an already built ELF")
    sp.add_argument("--hold", action="store_true",
                    help="use the held (SOFT_HART_INIT) ELF")
    sp.add_argument("--env", action="append", default=[],
                    help="extra KEY=VALUE for the soak (repeatable)")
    sp.add_argument("--run-id", default=None,
                    help="stamp this run id into the soak out dir (G6LC_RUN_ID)")
    sp.add_argument("--expect-exe-sha256", default=None,
                    help="refuse to run unless the remote harness sha256 matches")
    sp.add_argument("--tag", default=None,
                    help="remote run dir name under runs/ (default soak-<timestamp>)")
    sp.add_argument("--pull", action="store_true",
                    help="pull the soak out dir back to remote-runs/<tag>/")
    sp.set_defaults(fn=cmd_soak)

    sp = sub.add_parser("di", help="run the directed mini (DI) suite remotely in parallel")
    sp.add_argument("--flavour", choices=flavour_names(), default="B")
    sp.add_argument("--verlib", default=None)
    sp.add_argument("--tests", nargs="+", default=None,
                    help="mini test names (space separated; default: DEFAULT_DI_TESTS)")
    sp.add_argument("--time-out", dest="time_out", default="400000",
                    help="per-test +time_out/+max-cycles (default 400000)")
    sp.add_argument("--threads", type=int, default=1,
                    help="kept for compatibility; DI now runs one Variane at a time")
    sp.add_argument("--plusarg", action="append", default=[],
                    help="extra +plusarg for every test (repeatable)")
    sp.add_argument("--tail", type=int, default=30,
                    help="tail lines of each remote log in the summary (default 30)")
    sp.add_argument("--pull", action="store_true",
                    help="copy each test log back when done")
    sp.add_argument("--tag", default=None,
                    help="remote run dir name (default di-<timestamp>)")
    sp.add_argument("--out", default=None,
                    help="local dir for compiled ELFs (default: temp)")
    sp.add_argument("--no-oracle-check", action="store_true",
                    help=f"skip the H3 oracle preflight ({ORACLE_POSITIVE} must "
                         f"pass / {ORACLE_NEGATIVE} must fail); debugging only")
    sp.set_defaults(fn=cmd_di)

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

    sp = sub.add_parser("l2-leaf", help="run a copied L2 snapshot without shared repo sync or cleanup")
    sp.add_argument("snapshot", help="source/ directory from an isolated L2 leaf diagnostic")
    sp.add_argument("--rr-en", type=int, choices=[0, 1], default=0)
    sp.add_argument("--ways", type=int, choices=[2, 4, 8], default=4)
    sp.add_argument("--mem-latency", type=int, default=6)
    sp.add_argument("--stall-every", type=int, default=0)
    sp.add_argument("--mode", choices=["sim", "units", "synth"], default="sim")
    sp.set_defaults(fn=cmd_l2_leaf)

    sp = sub.add_parser("l2-equiv", help="RR-off equivalence of a copied L2 snapshot (no shared sync)")
    sp.add_argument("snapshot", help="repository root or isolated L2 snapshot")
    sp.add_argument("--byte-size", type=int, default=4096)
    sp.add_argument("--ways", type=int, choices=[2, 4, 8], default=4)
    sp.add_argument("--mem", choices=["map", "collect", "bbox", "auto"], default="auto")
    sp.add_argument("--negative", action="store_true")
    sp.add_argument("--ladder", action="store_true")
    sp.set_defaults(fn=cmd_l2_equiv)

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
