#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# env_common.py — contained-toolchain paths for the g6lc_qemu package.
#
# Everything the package installs lives under <package>/.tools/ so that no global
# state is touched (AGENTS.md, "Contained environment"). Nothing here knows about
# any host monorepo.

from __future__ import annotations

import os
import platform
from pathlib import Path

_WINDOWS = platform.system() == "Windows"
_EXE = ".exe" if _WINDOWS else ""


def package_root() -> Path:
    """The g6lc_qemu package root (parent of tools/)."""
    return Path(__file__).resolve().parent.parent


def tools_dir() -> Path:
    return package_root() / ".tools"


def rustup_home() -> Path:
    return tools_dir() / "rustup"


def cargo_home() -> Path:
    return tools_dir() / "cargo"


def cargo_bin() -> Path:
    return cargo_home() / "bin" / f"cargo{_EXE}"


def rustup_bin() -> Path:
    return cargo_home() / "bin" / f"rustup{_EXE}"


def python_venv() -> Path:
    return tools_dir() / "python-venv"


def venv_python() -> Path:
    if _WINDOWS:
        return python_venv() / "Scripts" / "python.exe"
    return python_venv() / "bin" / "python"


def out_dir() -> Path:
    return package_root() / "out"


def target_dir() -> Path:
    return package_root() / "target"


def riscv_toolchain_bin() -> Path | None:
    """The bin directory of the contained xPack RISC-V toolchain, if installed."""
    candidates = sorted(tools_dir().glob("xpack-riscv-none-elf-gcc-*"), reverse=True)
    for c in candidates:
        bin_dir = c / "bin"
        if bin_dir.is_dir():
            return bin_dir
    return None


def toolchain_channel() -> str:
    """Read the pinned channel out of rust-toolchain.toml without a TOML parser."""
    path = package_root() / "rust-toolchain.toml"
    if not path.is_file():
        return "stable"
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith("channel"):
            _, _, value = line.partition("=")
            return value.strip().strip('"').strip("'")
    return "stable"


def have_contained_toolchain() -> bool:
    """Whether `g6q setup` has installed a toolchain under .tools/."""
    return cargo_bin().is_file()


def contained_env(base: dict[str, str] | None = None) -> dict[str, str]:
    """Environment that ALWAYS points at the contained toolchain.

    This is what installation must use. `apply_env` deliberately leaves the environment
    alone when `.tools/` is absent so a developer with a system Rust can build without
    running `setup` first -- but that is precisely the state `setup` runs in, and using
    it there would install into the user's global `~/.rustup` and `~/.cargo` instead of
    into this package. Containment is the whole point of `setup`, so it gets its own,
    unconditional environment.
    """
    env = dict(base if base is not None else os.environ)
    env["RUSTUP_HOME"] = str(rustup_home())
    env["CARGO_HOME"] = str(cargo_home())
    bin_dir = str(cargo_home() / "bin")
    sep = os.pathsep
    existing = env.get("PATH", "")
    if bin_dir not in existing.split(sep):
        env["PATH"] = bin_dir + sep + existing
    env.setdefault("CARGO_TERM_COLOR", "never")
    return env


def host_tool_bin_dirs() -> list[Path]:
    """Bin directories of standalone host tools installed under .tools/.

    Scans .tools/ for tool installations that are not part of the Rust/xPack setup:
    Bootlin RISC-V toolchains, the QEMU Windows install tree, and dtc source builds.
    """
    dirs: list[Path] = []
    t = tools_dir()
    if not t.is_dir():
        return dirs
    for sub in t.iterdir():
        if not sub.is_dir():
            continue
        # Skip the Rust toolchain homes; those are prepended separately.
        if sub.name in ("rustup", "cargo", "python-venv"):
            continue
        # QEMU Windows installer drops executables in the root of .tools/qemu.
        if sub.name == "qemu":
            dirs.append(sub)
            continue
        # dtc source build leaves the binary in the source root.
        if sub.name == "dtc-src" and (
            (sub / "dtc").is_file() or (sub / "dtc.exe").is_file()
        ):
            dirs.append(sub)
            continue
        # Anything with a bin/ directory (xpack, Bootlin, etc.).
        bin_dir = sub / "bin"
        if bin_dir.is_dir() and any(bin_dir.iterdir()):
            dirs.append(bin_dir)
    return dirs


def apply_env(base: dict[str, str] | None = None) -> dict[str, str]:
    """Environment for spawning cargo/rustc and resolving host tools.

    When the contained toolchain exists, point `RUSTUP_HOME` / `CARGO_HOME` at it and
    prepend its bin directory. When it does not, **leave the caller's environment
    alone**: a developer with a system Rust, or with a toolchain contained elsewhere,
    must be able to run `check` without `setup` first. Forcing the contained paths
    unconditionally would break exactly that case, because the rustup proxy would then
    look for a toolchain in a directory that does not exist.
    """
    env = dict(base if base is not None else os.environ)
    if have_contained_toolchain():
        env["RUSTUP_HOME"] = str(rustup_home())
        env["CARGO_HOME"] = str(cargo_home())
        bin_dir = str(cargo_home() / "bin")
        sep = os.pathsep
        existing = env.get("PATH", "")
        if bin_dir not in existing.split(sep):
            env["PATH"] = bin_dir + sep + existing
    if (riscv_bin := riscv_toolchain_bin()) is not None:
        sep = os.pathsep
        existing = env.get("PATH", "")
        if str(riscv_bin) not in existing.split(sep):
            env["PATH"] = str(riscv_bin) + sep + existing
    if (v := python_venv()).is_dir():
        vbin = v / ("Scripts" if _WINDOWS else "bin")
        if vbin.is_dir():
            sep = os.pathsep
            existing = env.get("PATH", "")
            if str(vbin) not in existing.split(sep):
                env["PATH"] = str(vbin) + sep + existing
    for tool_bin in host_tool_bin_dirs():
        sep = os.pathsep
        existing = env.get("PATH", "")
        if str(tool_bin) not in existing.split(sep):
            env["PATH"] = str(tool_bin) + sep + existing
    # Deterministic output from the tools themselves.
    env.setdefault("CARGO_TERM_COLOR", "never")
    return env
