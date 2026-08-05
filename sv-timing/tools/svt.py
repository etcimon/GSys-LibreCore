#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# svt.py — PRIMARY cross-platform CLI for the sv-timing package.
# Prefer this over shell/PowerShell for all package automation (see AGENTS-toolchain.md).
#
#   python tools/svt.py setup
#   python tools/svt.py doctor
#   python tools/svt.py vendor-sv-parser
#   python tools/svt.py build | test | check | run | cargo | python | clean | env

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

# Allow `python tools/svt.py` without installing a package.
_TOOLS = Path(__file__).resolve().parent
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))

from env_common import (  # noqa: E402
    apply_env,
    cargo_bin,
    cargo_home,
    package_root,
    python_venv,
    rustup_home,
    tools_dir,
    venv_python,
)


def log(msg: str) -> None:
    print(f"[svt] {msg}")


def err(msg: str) -> None:
    print(f"[svt] ERROR: {msg}", file=sys.stderr)


def run(
    cmd: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess:
    log("+ " + " ".join(cmd))
    return subprocess.run(cmd, cwd=str(cwd) if cwd else None, env=env, check=check)


def find_host_python() -> str | None:
    # Prefer the interpreter running this script if it is usable.
    if sys.executable:
        return sys.executable
    for name in ("python3", "python"):
        p = shutil.which(name)
        if p:
            return p
    if platform.system() == "Windows":
        py = shutil.which("py")
        if py:
            try:
                out = subprocess.check_output(
                    [py, "-3", "-c", "import sys; print(sys.executable)"],
                    text=True,
                ).strip()
                if out:
                    return out
            except (subprocess.CalledProcessError, OSError):
                pass
    return None


def ensure_dirs(root: Path) -> None:
    for p in (tools_dir(root), rustup_home(root), cargo_home(root)):
        p.mkdir(parents=True, exist_ok=True)


def cargo_exe(root: Path) -> Path:
    name = "cargo.exe" if platform.system() == "Windows" else "cargo"
    return cargo_bin(root) / name


def rustc_exe(root: Path) -> Path:
    name = "rustc.exe" if platform.system() == "Windows" else "rustc"
    return cargo_bin(root) / name


def rustup_exe(root: Path) -> Path:
    name = "rustup.exe" if platform.system() == "Windows" else "rustup"
    return cargo_bin(root) / name


def need_cargo(root: Path) -> Path:
    c = cargo_exe(root)
    if not c.is_file():
        err(f"cargo not found at {c}; run: python tools/svt.py setup")
        sys.exit(1)
    return c


def install_rustup(root: Path, env: dict[str, str]) -> None:
    ensure_dirs(root)
    c = cargo_exe(root)
    r = rustc_exe(root)
    if c.is_file() and r.is_file():
        log(f"contained rustc already present: {subprocess.check_output([str(r), '--version'], text=True, env=env).strip()}")
        ru = rustup_exe(root)
        if ru.is_file():
            subprocess.run([str(ru), "show"], env=env, cwd=str(root), check=False)
            subprocess.run(
                [str(ru), "component", "add", "rustfmt", "clippy"],
                env=env,
                cwd=str(root),
                check=False,
            )
        return

    log(f"installing rustup into RUSTUP_HOME={env['RUSTUP_HOME']} CARGO_HOME={env['CARGO_HOME']}")
    system = platform.system()
    if system == "Windows":
        machine = platform.machine().lower()
        if machine in ("arm64", "aarch64"):
            triple = "aarch64-pc-windows-msvc"
        elif machine in ("amd64", "x86_64"):
            triple = "x86_64-pc-windows-msvc"
        else:
            triple = "i686-pc-windows-msvc"
        url = f"https://static.rust-lang.org/rustup/dist/{triple}/rustup-init.exe"
        init = Path(os.environ.get("TEMP", str(root / ".tools"))) / "rustup-init-sv-timing.exe"
        log(f"downloading {url}")
        urllib.request.urlretrieve(url, init)
        run(
            [str(init), "-y", "--no-modify-path", "--profile", "minimal", "--default-toolchain", "none"],
            env=env,
            check=True,
        )
    else:
        import tempfile

        url = "https://sh.rustup.rs"
        with tempfile.NamedTemporaryFile("wb", delete=False, suffix=".sh") as f:
            log(f"downloading {url}")
            with urllib.request.urlopen(url) as resp:
                f.write(resp.read())
            script = f.name
        os.chmod(script, os.stat(script).st_mode | stat.S_IXUSR)
        run(
            [
                "sh",
                script,
                "-y",
                "--no-modify-path",
                "--profile",
                "minimal",
                "--default-toolchain",
                "none",
            ],
            env=env,
            check=True,
        )
        try:
            os.unlink(script)
        except OSError:
            pass

    ru = rustup_exe(root)
    if not ru.is_file():
        err("rustup install failed")
        sys.exit(1)

    # Install toolchain from rust-toolchain.toml in package root
    run([str(ru), "toolchain", "install"], cwd=root, env=env, check=False)
    run([str(ru), "component", "add", "rustfmt", "clippy"], cwd=root, env=env, check=False)
    log(subprocess.check_output([str(rustc_exe(root)), "--version"], text=True, env=env).strip())
    log(subprocess.check_output([str(cargo_exe(root)), "--version"], text=True, env=env).strip())


def install_venv(root: Path) -> Path:
    ensure_dirs(root)
    vpy = venv_python(root)
    if vpy.is_file():
        log(f"python venv already present: {subprocess.check_output([str(vpy), '--version'], text=True).strip()}")
    else:
        host = find_host_python()
        if not host:
            err("no host Python 3 found; install Python 3 and re-run setup")
            sys.exit(1)
        venv_path = python_venv(root)
        log(f"creating venv at {venv_path} (base: {host})")
        run([host, "-m", "venv", str(venv_path)], check=True)
        if not vpy.is_file():
            # some platforms only create `python`
            alt = python_venv(root) / ("Scripts/python.exe" if platform.system() == "Windows" else "bin/python")
            if alt.is_file():
                vpy = alt
            else:
                err("venv creation failed")
                sys.exit(1)
    run([str(vpy), "-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel"], check=False)
    req = root / "requirements.txt"
    if req.is_file():
        lines = [
            ln.strip()
            for ln in req.read_text(encoding="utf-8").splitlines()
            if ln.strip() and not ln.strip().startswith("#")
        ]
        if lines:
            log("pip install -r requirements.txt")
            run([str(vpy), "-m", "pip", "install", "-r", str(req)], check=True)
        else:
            log("requirements.txt has no packages; skipping pip install")
    return vpy


def parser_vendored(root: Path) -> bool:
    return (root / "crates" / "sv-parser" / "sv-parser" / "Cargo.toml").is_file()


def cmd_vendor(root: Path, env: dict[str, str]) -> None:
    vpy = venv_python(root)
    py = str(vpy) if vpy.is_file() else (find_host_python() or sys.executable)
    script = root / "tools" / "refresh_sv_parser.py"
    run([py, str(script), "--root", str(root), "--force"], cwd=root, env=env, check=True)


def cmd_setup(root: Path, env: dict[str, str]) -> None:
    log("setup (contained env under .tools/)")
    install_rustup(root, env)
    install_venv(root)
    if not parser_vendored(root):
        log("sv-parser not vendored yet; running vendor-sv-parser")
        cmd_vendor(root, env)
    else:
        log("sv-parser already present under crates/sv-parser")
    log("setup complete")
    cmd_doctor(root, env)


def cmd_doctor(root: Path, env: dict[str, str]) -> None:
    log("doctor")
    print(f"  SV_TIMING_ROOT = {root}")
    print(f"  RUSTUP_HOME    = {env.get('RUSTUP_HOME')}")
    print(f"  CARGO_HOME     = {env.get('CARGO_HOME')}")
    c, r = cargo_exe(root), rustc_exe(root)
    if r.is_file():
        print(f"  rustc          = {subprocess.check_output([str(r), '--version'], text=True, env=env).strip()}")
    else:
        print("  rustc          = MISSING (run: python tools/svt.py setup)")
    if c.is_file():
        print(f"  cargo          = {subprocess.check_output([str(c), '--version'], text=True, env=env).strip()}")
    else:
        print("  cargo          = MISSING")
    vpy = venv_python(root)
    if vpy.is_file():
        print(f"  venv python    = {subprocess.check_output([str(vpy), '--version'], text=True).strip()} ({vpy})")
    else:
        print("  venv python    = MISSING (run: python tools/svt.py setup)")
    git = shutil.which("git")
    print(f"  git            = {subprocess.check_output(['git', '--version'], text=True).strip() if git else 'MISSING'}")
    stamp = root / "crates" / "sv-parser" / "VENDOR_STAMP"
    if stamp.is_file():
        print("  sv-parser      = vendored")
        for line in stamp.read_text(encoding="utf-8").splitlines():
            print(f"    {line}")
    else:
        print("  sv-parser      = NOT VENDORED (run: python tools/svt.py vendor-sv-parser)")
    print(f"  design         = {root / 'architecture' / 'DESIGN.md'}")
    print(f"  agents         = {root / 'AGENTS.md'}")


# First-party packages only (vendored sv-parser has its own tests; some are OS-string fragile).
FIRST_PARTY_PACKAGES = (
    "sv-timing-core",
    "sv-timing-cache",
    "sv-timing-transform",
    "sv-timing-emit",
    "sv-timing-cli",
)


def _pkg_args() -> list[str]:
    out: list[str] = []
    for p in FIRST_PARTY_PACKAGES:
        out.extend(["-p", p])
    return out


def cmd_build(root: Path, env: dict[str, str], rest: list[str]) -> None:
    c = need_cargo(root)
    # Default: first-party only; pass --workspace in rest to include everything.
    if rest and rest[0] == "--workspace":
        args = [str(c), "build", *rest]
    else:
        args = [str(c), "build", *_pkg_args(), *rest]
    run(args, cwd=root, env=env, check=True)


def cmd_test(root: Path, env: dict[str, str], rest: list[str]) -> None:
    c = need_cargo(root)
    if rest and rest[0] == "--workspace":
        run([str(c), "test", *rest], cwd=root, env=env, check=True)
    else:
        run([str(c), "test", *_pkg_args(), *rest], cwd=root, env=env, check=True)


def cmd_check(root: Path, env: dict[str, str], rest: list[str]) -> None:
    c = need_cargo(root)
    vpy = venv_python(root)
    py = str(vpy) if vpy.is_file() else (find_host_python() or sys.executable)
    run([py, str(root / "tools" / "check_independence.py")], cwd=root, env=env, check=True)
    run([str(c), "fmt", "--all", "--", "--check"], cwd=root, env=env, check=True)
    run(
        [str(c), "clippy", *_pkg_args(), "--all-targets", "--", "-D", "warnings"],
        cwd=root,
        env=env,
        check=True,
    )
    cmd_test(root, env, rest)


def cmd_run(root: Path, env: dict[str, str], rest: list[str]) -> None:
    c = need_cargo(root)
    if rest and rest[0] == "--":
        rest = rest[1:]
    run([str(c), "run", "-p", "sv-timing-cli", "--", *rest], cwd=root, env=env, check=True)


def cmd_clean(root: Path, env: dict[str, str], rest: list[str]) -> None:
    c = cargo_exe(root)
    if c.is_file():
        run([str(c), "clean"], cwd=root, env=env, check=False)
    for name in ("target", ".sv-timing-cache", ".sv-timing-out"):
        p = root / name
        if p.exists():
            shutil.rmtree(p, ignore_errors=True)
    if "--all" in rest:
        log("removing contained toolchain .tools/ (rustup, cargo, venv)")
        shutil.rmtree(tools_dir(root), ignore_errors=True)
    log("clean done")


def cmd_env(root: Path, env: dict[str, str]) -> None:
    if platform.system() == "Windows":
        print(f"$env:SV_TIMING_ROOT = '{root}'")
        print(f"$env:RUSTUP_HOME = '{env['RUSTUP_HOME']}'")
        print(f"$env:CARGO_HOME = '{env['CARGO_HOME']}'")
        print(f"$env:PATH = '{cargo_bin(root)};' + $env:PATH")
    else:
        print(f'export SV_TIMING_ROOT="{root}"')
        print(f'export RUSTUP_HOME="{env["RUSTUP_HOME"]}"')
        print(f'export CARGO_HOME="{env["CARGO_HOME"]}"')
        print(f'export PATH="{cargo_bin(root)}:$PATH"')


def cmd_verif_regress(root: Path, env: dict[str, str], rest: list[str]) -> None:
    """Run Python verif regress (analyze/correct/pyslang) under verif/regress."""
    script = root / "verif" / "regress" / "run_regress.py"
    if not script.is_file():
        err(f"missing {script}")
        sys.exit(1)
    need_cargo(root)
    cmd_build(root, env, [])
    # Ensure venv + pyslang
    vpy = install_venv(root)
    # Force pip install requirements (pyslang) if missing
    check = run(
        [str(vpy), "-c", "import pyslang"],
        cwd=root,
        env=env,
        check=False,
    )
    if check.returncode != 0:
        req = root / "requirements.txt"
        log("installing pyslang into venv for verif-regress")
        run([str(vpy), "-m", "pip", "install", "-r", str(req)], cwd=root, env=env, check=True)
    run([str(vpy), str(script), "--root", str(root), *rest], cwd=root, env=env, check=True)
    log("verif-regress OK")


def cmd_js_test(root: Path, env: dict[str, str], rest: list[str]) -> None:
    """Run TypeScript package tests under js/ (Bun)."""
    js_dir = root / "js"
    if not (js_dir / "package.json").is_file():
        err(f"missing TypeScript package at {js_dir}")
        sys.exit(1)
    bun = shutil.which("bun")
    if not bun:
        err("bun not found on PATH; install Bun (https://bun.sh) for js-test")
        sys.exit(1)
    # Ensure first-party CLI is built for connection tests
    need_cargo(root)
    cmd_build(root, env, [])
    log("bun install (devDependencies only) in js/")
    run([bun, "install"], cwd=js_dir, env=env, check=True)
    log("bun run typecheck")
    run([bun, "run", "typecheck"], cwd=js_dir, env=env, check=True)
    log("bun test")
    run([bun, "test", *rest], cwd=js_dir, env=env, check=True)
    log("js-test OK")


def cmd_flist(root: Path, env: dict[str, str], rest: list[str]) -> None:
    """Expand nested/env filelists into a portable `.f` for `sv-timing --files-from`.

    Thin wrapper around tools/flist_expand.py (project-independent; no monorepo deps).
    """
    script = root / "tools" / "flist_expand.py"
    if not script.is_file():
        err(f"missing {script}")
        sys.exit(1)
    # Prefer host python for a pure-stdlib tool (no venv required).
    py = sys.executable or find_host_python()
    if not py:
        err("no Python interpreter found for flist")
        sys.exit(1)
    if rest and rest[0] == "--selftest":
        run([py, str(script), "--selftest"], cwd=root, env=env, check=True)
        return
    run([py, str(script), *rest], cwd=root, env=env, check=True)


def cmd_monorepo_soak(root: Path, env: dict[str, str], rest: list[str]) -> None:
    """Opt-in structural FO4 soak on real monorepo SystemVerilog (package-first fixes).

    Does not use build-platform. See architecture/MONOREPO-SOAK.md.
    """
    script = root / "tools" / "monorepo_soak.py"
    if not script.is_file():
        err(f"missing {script}")
        sys.exit(1)
    py = sys.executable or find_host_python()
    if not py:
        err("no Python interpreter found for monorepo-soak")
        sys.exit(1)
    # Build CLI when actually analyzing (list-only skips cargo)
    if not any(a in ("--list", "-h", "--help") for a in rest):
        need_cargo(root)
        cmd_build(root, env, [])
    # Merge package cargo env for child
    child_env = dict(env)
    run([py, str(script), *rest], cwd=root, env=child_env, check=True)
    log("monorepo-soak OK")


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    root = package_root()
    env = apply_env(root)

    parser = argparse.ArgumentParser(
        prog="svt",
        description="sv-timing contained toolchain & package CLI (Python-first)",
    )
    parser.add_argument(
        "command",
        nargs="?",
        default="help",
        help="setup|doctor|vendor-sv-parser|build|test|check|run|flist|monorepo-soak|js-test|verif-regress|clean|env|cargo|python",
    )
    parser.add_argument("rest", nargs=argparse.REMAINDER, help="args passed to subcommand")
    args = parser.parse_args(argv)
    cmd = args.command.replace("_", "-")
    rest = list(args.rest)
    # argparse REMAINDER may keep a leading '--'
    if rest and rest[0] == "--":
        rest = rest[1:]

    try:
        if cmd in ("help", "-h", "--help"):
            parser.print_help()
            print(
                "\nDocs: AGENTS.md, AGENTS-toolchain.md, AGENTS-js.md, architecture/DESIGN.md, AGENTS-todo.md"
            )
            return 0
        if cmd == "setup":
            cmd_setup(root, env)
        elif cmd == "doctor":
            cmd_doctor(root, env)
        elif cmd in ("vendor-sv-parser", "vendor"):
            cmd_vendor(root, env)
        elif cmd == "build":
            cmd_build(root, env, rest)
        elif cmd == "test":
            cmd_test(root, env, rest)
        elif cmd == "check":
            cmd_check(root, env, rest)
        elif cmd == "run":
            cmd_run(root, env, rest)
        elif cmd in ("js-test", "ts-test"):
            cmd_js_test(root, env, rest)
        elif cmd in ("flist", "flist-expand", "expand-flist"):
            cmd_flist(root, env, rest)
        elif cmd in ("monorepo-soak", "soak", "host-soak"):
            cmd_monorepo_soak(root, env, rest)
        elif cmd in ("verif-regress", "regress"):
            cmd_verif_regress(root, env, rest)
        elif cmd == "clean":
            cmd_clean(root, env, rest)
        elif cmd == "env":
            cmd_env(root, env)
        elif cmd == "cargo":
            c = need_cargo(root)
            run([str(c), *rest], cwd=root, env=env, check=True)
        elif cmd in ("python", "py"):
            vpy = venv_python(root)
            if not vpy.is_file():
                err("venv missing; run: python tools/svt.py setup")
                return 1
            run([str(vpy), *rest], cwd=root, env=env, check=True)
        else:
            err(f"unknown command: {cmd}")
            parser.print_help()
            return 1
    except subprocess.CalledProcessError as e:
        return e.returncode or 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
