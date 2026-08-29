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
import re
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
    contained_env,
    have_contained_toolchain,
    out_dir,
    package_root,
    rustup_home,
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
        check: bool = True, capture_output: bool = False, text: bool = False,
        **kwargs) -> subprocess.CompletedProcess:
    log("+ " + " ".join(str(c) for c in cmd))
    return subprocess.run([str(c) for c in cmd], cwd=str(cwd) if cwd else None,
                          env=env, check=check, capture_output=capture_output, text=text,
                          **kwargs)


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
    tools_dir().mkdir(parents=True, exist_ok=True)

    if have_contained_toolchain() and not args.force:
        log(f"contained cargo already present: {cargo_bin()}")
    else:
        channel = toolchain_channel()
        log(f"installing contained rustup + toolchain {channel} into {tools_dir()}")
        # Installation must be contained unconditionally; see env_common.contained_env.
        env = contained_env()
        # rustup-init takes ONE value per --component; a second bare word is parsed as a
        # positional and rejected.
        components = ["--component", "rustfmt", "--component", "clippy"]
        if _WINDOWS:
            init = tools_dir() / "rustup-init.exe"
            _download(_RUSTUP_WIN, init)
            run([init, "-y", "--no-modify-path", "--profile", "minimal",
                 "--default-toolchain", channel, *components], env=env)
        else:
            init = tools_dir() / "rustup-init.sh"
            _download(_RUSTUP_UNIX, init)
            init.chmod(init.stat().st_mode | stat.S_IEXEC)
            run(["sh", str(init), "-y", "--no-modify-path", "--profile", "minimal",
                 "--default-toolchain", channel, *components], env=env)

        if not have_contained_toolchain():
            err(f"setup finished but no cargo at {cargo_bin()}; refusing to claim success")
            return 1

    # Prove containment rather than assume it: a toolchain that silently landed in the
    # user's home directory would defeat the point of this command.
    log(f"RUSTUP_HOME = {rustup_home()}")
    log(f"CARGO_HOME  = {cargo_home()}")
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
        ("bridge selftest", lambda: _python([str(_TOOLS / "ai_tensor_bridge.py"), "selftest"])),
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


# ------------------------------------------------------------------ fetch-qemu ---

def _pins_qemu() -> tuple[str, str]:
    """Read the [qemu] url and ref from pins.toml without an external TOML parser."""
    path = package_root() / "pins.toml"
    if not path.is_file():
        raise RuntimeError("pins.toml not found")
    text = path.read_text(encoding="utf-8")
    in_qemu = False
    url: str | None = None
    ref: str | None = None
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            in_qemu = s[1:-1] == "qemu"
            continue
        if in_qemu and "=" in s:
            key, _, value = s.partition("=")
            key = key.strip()
            value = value.split("#", 1)[0].strip()
            value = value.strip('"').strip("'")
            if key == "url":
                url = value
            elif key == "ref":
                ref = value
    if not url or not ref:
        raise RuntimeError("pins.toml [qemu] section missing url or ref")
    return url, ref


def cmd_fetch_qemu(args: argparse.Namespace) -> int:
    git = shutil.which("git")
    if not git:
        err("git not found on PATH; cannot fetch QEMU")
        return 1
    qemu_dir = package_root() / "qemu"
    url, ref = _pins_qemu()
    url = args.url or url
    ref = args.ref or ref
    log(f"QEMU source pin: {ref} from {url}")

    if args.dry_run:
        log("dry-run: would clone/fetch and check out:")
        log(f"  git clone --branch {ref}{' --depth 1' if not args.full else ''} {url} {qemu_dir}")
        if qemu_dir.joinpath(".git").is_dir():
            log(f"  (existing {qemu_dir} would be updated)")
        log(f"  git -C {qemu_dir} checkout -f {ref}")
        log(f"  write {qemu_dir / '.g6lc_qemu_pin'} with ref + url")
        return 0

    if qemu_dir.joinpath(".git").is_dir():
        log(f"fetching into existing {qemu_dir}")
        run([git, "-C", qemu_dir, "fetch", "origin", ref], check=False)
    else:
        qemu_dir.mkdir(parents=True, exist_ok=True)
        log(f"cloning {url} into {qemu_dir}")
        # Clone with the right ref checked out immediately; depth 1 keeps the
        # first fetch fast.  A later full fetch is one command away if needed.
        clone_args = [git, "clone", "--branch", ref]
        if not args.full:
            clone_args += ["--depth", "1"]
        clone_args += ["--", url, str(qemu_dir)]
        res = run(clone_args, check=False)
        if res.returncode != 0:
            err("clone failed; if the ref is not a tag, use --full or a full clone manually")
            return res.returncode

    # Make sure the requested ref is actually checked out.
    res = run([git, "-C", qemu_dir, "checkout", "-f", ref], check=False)
    if res.returncode != 0:
        err(f"could not check out {ref}")
        return res.returncode

    # Record the pin so the workspace can see which source revision is being used.
    (qemu_dir / ".g6lc_qemu_pin").write_text(f"{ref}\n{url}\n", encoding="utf-8")
    log(f"QEMU ready at {qemu_dir} on ref {ref}")
    return 0


# ------------------------------------------------------------------ build-qemu ---

def _which_or_none(name: str) -> str | None:
    found = shutil.which(name)
    return found


def cmd_build_qemu(args: argparse.Namespace) -> int:
    qemu_dir = package_root() / "qemu"
    if not qemu_dir.joinpath(".git").is_dir():
        err("qemu/ is not present; run `python tools/g6q.py fetch-qemu` first")
        return 1

    build_dir = qemu_dir / "build"
    if args.clean and build_dir.exists():
        if args.dry_run:
            log(f"dry-run: would remove {build_dir}")
        else:
            log(f"removing {build_dir}")
            shutil.rmtree(build_dir, ignore_errors=True)

    python = _which_or_none("python3") or _which_or_none("python") or "python"
    bash = _which_or_none("bash") or "bash"
    ninja = _which_or_none("ninja") or _which_or_none("ninja-build") or "ninja"

    configure = qemu_dir / "configure"
    configure_cmd: list[str]
    # Out-of-tree build: run from qemu/build with ../configure.
    configure_args = f"--target-list={args.target}"
    # VDUSE/vhost-user subprojects create symlinks in the build tree. On Windows
    # filesystems accessed through WSL these symlinks often fail, so disable them
    # by default; they are not needed for the riscv64-softmmu boot gate.
    configure_args += " --disable-libvduse --disable-vduse-blk-export"
    configure_args += " --disable-vhost-user --disable-vhost-user-blk-server"
    if args.debug:
        configure_args += " --enable-debug"
    if args.mingw:
        configure_args += " --cross-prefix= --enable-mingw-w64"
    if _WINDOWS:
        # WSL/Cygwin bash cannot directly consume a Windows absolute path; run
        # configure through bash from the build directory.
        configure_cmd = [bash, "-c", f"../configure {configure_args}"]
    else:
        configure_cmd = [str(configure), *configure_args.split()]

    if args.dry_run:
        log("dry-run: would configure and build:")
        log(f"  cd {build_dir}")
        log(f"  mkdir -p {build_dir}")
        log(f"  {' '.join(configure_cmd)}")
        log(f"  {ninja}")
        if not args.configure_only:
            log(f"  {ninja} -C {build_dir} contrib-plugins")
        return 0

    if python == "python":
        err("python not found on PATH; cannot configure QEMU")
        return 1
    if _WINDOWS and bash == "bash":
        err("bash not found on PATH; QEMU configure is a POSIX script")
        return 1
    if ninja == "ninja":
        err("ninja not found on PATH; cannot build QEMU")
        return 1

    build_dir.mkdir(parents=True, exist_ok=True)
    res = run(configure_cmd, cwd=build_dir, check=False)
    if res.returncode != 0:
        err("QEMU configure failed")
        return res.returncode

    if args.configure_only:
        log(f"QEMU configured in {build_dir}")
        return 0

    if _WINDOWS:
        build_cmd = [bash, "-c", "ninja"]
    else:
        build_cmd = [ninja]
    res = run(build_cmd, cwd=build_dir, check=False)
    if res.returncode != 0:
        err("QEMU build failed")
        return res.returncode

    log(f"QEMU built in {build_dir}")
    return 0


# ----------------------------------------------------------------- install-qemu ---

def _find_target_id(out_dir: Path) -> str | None:
    for d in out_dir.iterdir():
        if d.is_dir() and (d / "build").is_dir():
            wiring = list((d / "build").glob("build-wiring-*.txt"))
            if wiring:
                return d.name
    return None


def _wiring_sections(text: str) -> dict[str, str]:
    """Parse build-wiring-*.txt into {target_file: append_block}."""
    sections: dict[str, list[str]] = {}
    current: str | None = None
    header = re.compile(r"#\s*\d+\.\s*Append to\s+([^\s(]+(?:/[^\s(]+)*)")
    for line in text.splitlines():
        m = header.match(line)
        if m:
            current = m.group(1).strip()
            sections[current] = []
        elif current is not None:
            if line.startswith("#"):
                # Next prose section (e.g. "# 5. Plugin build wiring").
                m2 = header.match(line)
                if m2:
                    current = m2.group(1).strip()
                    sections[current] = []
                else:
                    current = None
            else:
                sections[current].append(line)
    return {p: "\n".join(lines).strip() for p, lines in sections.items() if lines}


def _add_contrib_plugin(qemu_dir: Path, target_id: str, suffix: str = "") -> None:
    """Ensure the generated plugin is listed in contrib/plugins/meson.build."""
    path = qemu_dir / "contrib" / "plugins" / "meson.build"
    if not path.is_file():
        return
    text = path.read_text(encoding="utf-8")
    # The emitted plugin file uses the C-sanitised target id (e.g. 'ai-soc' -> 'ai_soc').
    safe_id = target_id.replace('-', '_').replace('.', '_')
    name = f"g6lc-{safe_id}{suffix}"
    if name in text:
        log(f"already present in {path}: {name}")
        return
    # Insert before the 'if get_option('plugins')' block so the list is grown
    # before the foreach loop consumes it.
    marker = "if get_option('plugins')"
    if marker in text:
        before, sep, after = text.partition(marker)
        text = before + f"contrib_plugins += '{name}'\n\n" + sep + after
    else:
        text = text.rstrip() + f"\n\ncontrib_plugins += '{name}'\n"
    with path.open("w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    log(f"added {name} to {path}")


def _is_repo_root(pkg: Path) -> bool:
    return (pkg / "core" / "include").is_dir() or (pkg / "core").is_dir()


def _find_one(pkg: Path, pattern: str) -> Path | None:
    found = sorted(pkg.glob(pattern))
    found = [p for p in found if not p.name.lower().startswith("manifest-nested")]
    return found[0] if found else None


def _gen_command(
    gen_bin: Path,
    pkg: Path,
    target: str | None,
    dts_overlay: str | None,
    machine: str | None = None,
    virtio_mmio: str | None = None,
) -> list[str]:
    if _is_repo_root(pkg):
        cmd = [str(gen_bin), "gen", "--emit", "qemu", "--repo-root", str(pkg)]
        if target:
            cmd.extend(["--target", target])
        if dts_overlay:
            cmd.extend(["--dts-overlay", dts_overlay])
        if machine:
            cmd.extend(["--machine", machine])
        if virtio_mmio:
            cmd.extend(["--virtio-mmio", virtio_mmio])
        return cmd

    cfg = _find_one(pkg, "*_config_pkg.sv")
    if not cfg:
        raise ValueError(f"no *_config_pkg.sv in {pkg}")
    flist = _find_one(pkg, "*.f")
    if not flist:
        raise ValueError(f"no flist in {pkg}")
    dts = _find_one(pkg, "*.dts")
    if not dts:
        raise ValueError(f"no .dts in {pkg}")
    resolved_target = target or cfg.stem.removesuffix("_config_pkg").removesuffix("_cfg_pkg")
    cmd = [
        str(gen_bin),
        "gen",
        "--emit",
        "qemu",
        "--config-pkg",
        str(cfg),
        "--flist",
        str(flist),
        "--dts",
        str(dts),
        "--target",
        resolved_target,
    ]
    if dts_overlay:
        cmd.extend(["--dts-overlay", dts_overlay])
    if machine:
        cmd.extend(["--machine", machine])
    if virtio_mmio:
        cmd.extend(["--virtio-mmio", virtio_mmio])
    return cmd


def cmd_install_qemu(args: argparse.Namespace) -> int:
    qemu_dir = package_root() / "qemu"
    if not qemu_dir.joinpath(".git").is_dir():
        err("qemu/ is not present; run `python tools/g6q.py fetch-qemu` first")
        return 1

    pkg = Path(args.package)
    if not pkg.is_dir():
        err(f"package is not a directory: {pkg}")
        return 1
    pkg = pkg.resolve()

    out_dir = package_root() / "out" / "emit"
    if out_dir.exists():
        shutil.rmtree(out_dir, ignore_errors=True)

    # Build the generator and emit B1/B2 sources.
    if not args.dry_run:
        res = _cargo(["build", "-p", "g6q-cli"])
        if res != 0:
            return res

    try:
        gen_cmd = _gen_command(
            package_root() / "target" / "debug" / "g6lc-qemu",
            pkg,
            args.target,
            args.dts_overlay,
            args.machine,
            args.virtio_mmio,
        )
    except ValueError as e:
        err(str(e))
        return 1

    if args.dry_run:
        log(f"dry-run: would run: {' '.join(gen_cmd)}")
        log("dry-run: would copy generated sources from out/emit/<target>/ to qemu/")
        log("dry-run: would append build-wiring fragments to qemu/hw/riscv/Kconfig, default-configs, meson.build")
        log("dry-run: plugin wiring requires manual edit of qemu/contrib/plugins/meson.build")
        return 0

    gen_bin = package_root() / "target" / "debug" / "g6lc-qemu"
    res = run(gen_cmd, check=False, capture_output=True, text=True)
    if res.returncode != 0:
        err(f"generation failed: {res.stderr}")
        return res.returncode

    target_id = _find_target_id(out_dir)
    if not target_id:
        err("could not find an emitted target under out/emit/")
        return 1
    emit_dir = out_dir / target_id

    # Copy generated source/headers into the QEMU tree.
    source_map = {
        emit_dir / "contrib/plugins": qemu_dir / "contrib/plugins",
        emit_dir / "hw/riscv": qemu_dir / "hw/riscv",
        emit_dir / "target/riscv": qemu_dir / "target/riscv",
    }
    for src_dir, dst_dir in source_map.items():
        if not src_dir.is_dir():
            continue
        dst_dir.mkdir(parents=True, exist_ok=True)
        for f in src_dir.iterdir():
            if f.is_file():
                if args.dry_run:
                    log(f"dry-run: would copy {f} -> {dst_dir / f.name}")
                else:
                    shutil.copy2(f, dst_dir / f.name)
                    log(f"copied {dst_dir / f.name}")

    # Apply build-wiring appends.
    wiring_files = list((emit_dir / "build").glob("build-wiring-*.txt"))
    if not wiring_files:
        if not args.dry_run:
            err("no build-wiring file found")
            return 1
        log("dry-run: no build-wiring file to parse")
        return 0
    wiring_text = wiring_files[0].read_text(encoding="utf-8")
    for rel_path, block in _wiring_sections(wiring_text).items():
        target_path = qemu_dir / rel_path
        if not target_path.is_file():
            err(f"QEMU file not found: {target_path}")
            continue
        if args.dry_run:
            log(f"dry-run: would append to {target_path}:\n{block}")
            continue
        existing = target_path.read_text(encoding="utf-8")
        if block in existing:
            log(f"already present in {target_path}: {block.splitlines()[0]}")
        else:
            with target_path.open("a", encoding="utf-8", newline="\n") as f:
                if existing and not existing.endswith("\n"):
                    f.write("\n")
                f.write("\n" + block + "\n")
            log(f"appended to {target_path}")

    if not args.dry_run:
        _add_contrib_plugin(qemu_dir, target_id)
        _add_contrib_plugin(qemu_dir, target_id, suffix="-pmu")
        with (qemu_dir / ".g6lc_qemu_install").open(
                "w", encoding="utf-8", newline="\n") as f:
            f.write(f"target: {target_id}\npackage: {args.package}\n")
        log(f"installed g6lc machine ({target_id}) into {qemu_dir}")
    return 0


# ----------------------------------------------------------------------- clean ---

def cmd_remote(args: argparse.Namespace) -> int:
    remote = package_root() / "tools" / "g6q_remote.py"
    rest = list(getattr(args, "rest", None) or [])
    if rest and rest[0] == "--":
        rest = rest[1:]
    cmd = [sys.executable, str(remote), *rest]
    return subprocess.run(cmd).returncode


def cmd_remote_build(args: argparse.Namespace) -> int:
    remote = package_root() / "tools" / "g6q_remote.py"
    rest = list(getattr(args, "rest", None) or [])
    if rest and rest[0] == "--":
        rest = rest[1:]
    cmd = [sys.executable, str(remote), "remote-build", *rest]
    return subprocess.run(cmd).returncode


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

    p = sub.add_parser("fetch-qemu", help="fetch the pinned QEMU source into qemu/")
    p.add_argument("--url", default=None, help="override the QEMU git URL from pins.toml")
    p.add_argument("--ref", default=None, help="override the QEMU ref from pins.toml")
    p.add_argument("--full", action="store_true", help="full clone instead of a shallow one")
    p.add_argument("--dry-run", action="store_true", help="print what would be run and exit")
    p.set_defaults(fn=cmd_fetch_qemu)

    p = sub.add_parser("build-qemu", help="configure and build the fetched QEMU source")
    p.add_argument("--target", default="riscv64-softmmu",
                   help="QEMU target list (default: riscv64-softmmu)")
    p.add_argument("--debug", action="store_true", help="pass --enable-debug to configure")
    p.add_argument("--mingw", action="store_true", help="hint a MinGW cross build")
    p.add_argument("--configure-only", action="store_true", help="configure, do not build")
    p.add_argument("--clean", action="store_true", help="remove the build directory first")
    p.add_argument("--dry-run", action="store_true",
                   help="print the configure/build commands and exit")
    p.set_defaults(fn=cmd_build_qemu)

    p = sub.add_parser("install-qemu", help="install generated B1/B2 sources into qemu/")
    p.add_argument("--package", default="fixtures/mini",
                   help="package directory to generate from (default: fixtures/mini)")
    p.add_argument("--target", default=None,
                   help="override the emitted target id")
    p.add_argument("--machine", default=None,
                   help="machine profile: g6lc-soc (default) or g6lc-virt")
    p.add_argument("--virtio-mmio", default=None,
                   help="number of virtio-mmio transports (g6lc-virt defaults to 8)")
    p.add_argument("--dts-overlay", default=None,
                   help="overlay .dts to apply before generation")
    p.add_argument("--dry-run", action="store_true",
                   help="print what would be copied/appended and exit")
    p.set_defaults(fn=cmd_install_qemu)

    p = sub.add_parser("remote", help="remote QEMU build/test proxy (forward to tools/g6q_remote.py)")
    p.add_argument("rest", nargs=argparse.REMAINDER)
    p.set_defaults(fn=cmd_remote)

    p = sub.add_parser("remote-build", help="convenience: sync, configure, build, pull, and optional smoke test on the remote builder")
    p.add_argument("rest", nargs=argparse.REMAINDER)
    p.set_defaults(fn=cmd_remote_build)

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
