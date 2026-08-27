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


def apply_env(base: dict[str, str] | None = None) -> dict[str, str]:
    """Environment for spawning cargo/rustc.

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
    # Deterministic output from the tools themselves.
    env.setdefault("CARGO_TERM_COLOR", "never")
    return env
