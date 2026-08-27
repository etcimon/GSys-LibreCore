#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# g6q.py — PRIMARY cross-platform CLI for the g6lc_qemu package.
# Prefer this over shell/PowerShell for all package automation (AGENTS.md section 4).
#
#   python tools/g6q.py setup     # contained rustup/cargo under .tools/
#   python tools/g6q.py doctor    # host probe
#   python tools/g6q.py build | test | check | run | cargo | flist | clean | env
#
# GREEN COMMAND: `python tools/g6q.py check`

from __future__ import annotations

import argparse
import os
import platform
import shutil
import stat
import subprocess
import sys
import urllib.request
from pathlib import Path

_TOOLS = Path(__file__).resolve().parent
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))

from env_common import (  # noqa: E402
    apply_env,
    cargo_bin,
    cargo_home,
    out_dir,
    package_root,
    rustup_bin,
    target_dir,
    toolchain_channel,
    tools_dir,
)

_WINDOWS = platform.system() == "Windows"


def log(msg: str) -> None:
    print(f"[g6q] {msg}")


def err(msg: str) -> None:
    print(f"[g6q] ERROR: {msg}", file=sys.stderr)


def run(cmd: list[str], *, cwd: Path | None = None, env: dict[str, str] | None = None,
        check: bool = True) -> subprocess.CompletedProcess:
    log("+ " + " ".join(str(c) for c in cmd))
    return subprocess.run([str(c) for c in cmd], cwd=str(cwd) if cwd else None,
                          env=env, check=check)


def resolve_cargo() -> str | None:
    """Contained cargo first, then PATH. Returns None when neither exists."""
    if cargo_bin().is_file():
        return str(cargo_bin())
    found = shutil.which("cargo")
    return found


def require_cargo() -> str:
    c = resolve_cargo()
    if not c:
        err("no cargo found. Run `python tools/g6q.py setup` to install a contained "
            "toolchain, or put cargo on PATH.")
        raise SystemExit(2)
    return c


# ----------------------------------------------------------------------- setup ---

_RUSTUP_UNIX = "https://sh.rustup.rs"
_RUSTUP_WIN = "https://win.rustup.rs/x86_64"


def cmd_setup(args: argparse.Namespace) -> int:
    root = package_root()
    tools_dir().mkdir(parents=True, exist_ok=True)

    if cargo_bin().is_file() and not args.force:
        log(f"contained cargo already present: {cargo_bin()}")
    else:
        channel = toolchain_channel()
        log(f"installing contained rustup + toolchain {channel} into {tools_dir()}")
        env = apply_env()
        if _WINDOWS:
            init = tools_dir() / "rustup-init.exe"
            _download(_RUSTUP_WIN, init)
            run([init, "-y", "--no-modify-path", "--profile", "minimal",
                 "--default-toolchain", channel, "--component", "rustfmt", "clippy"],
                env=env)
        else:
            init = tools_dir() / "rustup-init.sh"
            _download(_RUSTUP_UNIX, init)
            init.chmod(init.stat().st_mode | stat.S_IEXEC)
            run(["sh", str(init), "-y", "--no-modify-path", "--profile", "minimal",
                 "--default-toolchain", channel, "--component", "rustfmt", "clippy"],
                env=env)

    log("setup complete; next: python tools/g6q.py check")
    return 0


def _download(url: str, dest: Path) -> None:
    log(f"downloading {url} -> {dest}")
    with urllib.request.urlopen(url) as resp, open(dest, "wb") as fh:  # noqa: S310
        shutil.copyfileobj(resp, fh)


# ---------------------------------------------------------------------- doctor ---

def cmd_doctor(args: argparse.Namespace) -> int:
    root = package_root()
    rows: list[tuple[str, str, str]] = []

    def probe(name: str, exe: str | None, version_args: list[str] | None = None,
              note: str = "") -> None:
        if not exe:
            rows.append((name, "MISSING", note))
            return
        ver = ""
        if version_args:
            try:
                out = subprocess.run([exe, *version_args], capture_output=True,
                                     text=True, timeout=20)
                ver = (out.stdout or out.stderr).strip().splitlines()[0][:60]
            except Exception:  # noqa: BLE001 - a probe must never raise
                ver = "(version probe failed)"
        rows.append((name, "ok", ver or exe))

    probe("python", sys.executable, ["--version"])
    probe("cargo", resolve_cargo(), ["--version"],
          note="run `g6q setup` for a contained toolchain")
    probe("git", shutil.which("git"), ["--version"])
    # Optional, only needed by later stages.
    probe("qemu-system-riscv64", shutil.which("qemu-system-riscv64"), ["--version"],
          note="optional until the QEMU backend lands")
    probe("dtc", shutil.which("dtc"), ["--version"],
          note="optional; device trees can be emitted as source")
    probe("spike", shutil.which("spike"), None,
          note="optional; only for tandem against a reference ISS")

    width = max(len(r[0]) for r in rows)
    print(f"[g6q] package root: {root}")
    for name, state, extra in rows:
        flag = "  " if state == "ok" else "! "
        print(f"{flag}{name.ljust(width)}  {state:<8} {extra}")

    missing_required = [r for r in rows if r[1] != "ok" and r[0] in ("python", "cargo")]
    if missing_required:
        err("required tooling missing; run `python tools/g6q.py setup`")
        return 1
    return 0


# ------------------------------------------------------------- build/test/check ---

def _cargo(args_list: list[str], *, check: bool = True) -> int:
    cargo = require_cargo()
    res = run([cargo, *args_list], cwd=package_root(), env=apply_env(), check=False)
    if check and res.returncode != 0:
        raise SystemExit(res.returncode)
    return res.returncode


def cmd_build(args: argparse.Namespace) -> int:
    extra = ["--release"] if args.release else []
    return _cargo(["build", "--workspace", *extra])


def cmd_test(args: argparse.Namespace) -> int:
    return _cargo(["test", "--workspace"])


def cmd_check(args: argparse.Namespace) -> int:
    """The green command."""
    steps: list[tuple[str, callable]] = [
        ("independence", lambda: _python([str(_TOOLS / "check_independence.py")])),
        ("flist selftest", lambda: _python([str(_TOOLS / "flist_expand.py"), "--selftest"])),
        ("fmt", lambda: _cargo(["fmt", "--all", "--check"], check=False)),
        ("clippy", lambda: _cargo(
            ["clippy", "--workspace", "--all-targets", "--", "-D", "warnings"], check=False)),
        ("test", lambda: _cargo(["test", "--workspace"], check=False)),
    ]
    failed: list[str] = []
    for name, fn in steps:
        log(f"--- {name} ---")
        rc = fn()
        if rc != 0:
            failed.append(name)
            if not args.keep_going:
                break
    if failed:
        err(f"check FAILED: {', '.join(failed)}")
        return 1
    log("check OK")
    return 0


def _python(argv: list[str]) -> int:
    res = run([sys.executable, *argv], cwd=package_root(), check=False)
    return res.returncode


# ------------------------------------------------------------------ run / cargo ---

def cmd_run(args: argparse.Namespace) -> int:
    return _cargo(["run", "-p", "g6q-cli", "--", *args.rest])


def cmd_cargo(args: argparse.Namespace) -> int:
    return _cargo(list(args.rest))


def cmd_flist(args: argparse.Namespace) -> int:
    return _python([str(_TOOLS / "flist_expand.py"), *args.rest])


def cmd_env(args: argparse.Namespace) -> int:
    env = apply_env()
    for key in ("RUSTUP_HOME", "CARGO_HOME", "PATH"):
        print(f"{key}={env.get(key, '')}")
    print(f"PACKAGE_ROOT={package_root()}")
    print(f"TOOLCHAIN={toolchain_channel()}")
    print(f"CARGO={resolve_cargo() or '(none)'}")
    return 0


# ----------------------------------------------------------------------- clean ---

def cmd_clean(args: argparse.Namespace) -> int:
    victims = [target_dir(), out_dir()]
    if args.all:
        victims.append(tools_dir())
    for v in victims:
        if v.exists():
            log(f"removing {v}")
            shutil.rmtree(v, ignore_errors=True)
        else:
            log(f"absent    {v}")
    if args.all:
        log("removed .tools/ — run `python tools/g6q.py setup` before building again")
    return 0


# ------------------------------------------------------------------------- main ---

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="g6q", description="g6lc_qemu package automation (primary entry point).")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("setup", help="install a contained rustup/cargo under .tools/")
    p.add_argument("--force", action="store_true")
    p.set_defaults(fn=cmd_setup)

    p = sub.add_parser("doctor", help="probe host tooling")
    p.set_defaults(fn=cmd_doctor)

    p = sub.add_parser("build", help="cargo build --workspace")
    p.add_argument("--release", action="store_true")
    p.set_defaults(fn=cmd_build)

    p = sub.add_parser("test", help="cargo test --workspace")
    p.set_defaults(fn=cmd_test)

    p = sub.add_parser("check", help="GREEN: independence + fmt + clippy + test")
    p.add_argument("--keep-going", "-k", action="store_true",
                   help="run every step even after a failure")
    p.set_defaults(fn=cmd_check)

    p = sub.add_parser("run", help="cargo run -p g6q-cli -- ...")
    p.add_argument("rest", nargs=argparse.REMAINDER)
    p.set_defaults(fn=cmd_run)

    p = sub.add_parser("cargo", help="raw cargo with the contained toolchain")
    p.add_argument("rest", nargs=argparse.REMAINDER)
    p.set_defaults(fn=cmd_cargo)

    p = sub.add_parser("flist", help="generic filelist expander")
    p.add_argument("rest", nargs=argparse.REMAINDER)
    p.set_defaults(fn=cmd_flist)

    p = sub.add_parser("env", help="print the contained-toolchain environment")
    p.set_defaults(fn=cmd_env)

    p = sub.add_parser("clean", help="remove target/ and out/")
    p.add_argument("--all", action="store_true", help="also remove .tools/")
    p.set_defaults(fn=cmd_clean)

    args = ap.parse_args(argv)
    # `run`/`cargo`/`flist` accept a leading `--`; argparse leaves it in REMAINDER.
    rest = getattr(args, "rest", None)
    if rest and rest and rest[0] == "--":
        args.rest = rest[1:]
    try:
        return int(args.fn(args) or 0)
    except SystemExit as exc:
        return int(exc.code or 0)
    except KeyboardInterrupt:
        err("interrupted")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
