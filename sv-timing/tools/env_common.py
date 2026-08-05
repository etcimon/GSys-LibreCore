#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Shared path helpers for contained toolchain layout under sv-timing/.tools/

from __future__ import annotations

import os
import sys
from pathlib import Path


def package_root() -> Path:
    return Path(__file__).resolve().parent.parent


def tools_dir(root: Path | None = None) -> Path:
    return (root or package_root()) / ".tools"


def rustup_home(root: Path | None = None) -> Path:
    return tools_dir(root) / "rustup"


def cargo_home(root: Path | None = None) -> Path:
    return tools_dir(root) / "cargo"


def python_venv(root: Path | None = None) -> Path:
    return tools_dir(root) / "python-venv"


def venv_python(root: Path | None = None) -> Path:
    v = python_venv(root)
    if sys.platform == "win32":
        return v / "Scripts" / "python.exe"
    return v / "bin" / "python3"


def cargo_bin(root: Path | None = None) -> Path:
    return cargo_home(root) / "bin"


def apply_env(root: Path | None = None) -> dict[str, str]:
    """Return env dict with contained RUSTUP_HOME / CARGO_HOME and PATH prefix."""
    root = root or package_root()
    env = os.environ.copy()
    rh = str(rustup_home(root))
    ch = str(cargo_home(root))
    env["RUSTUP_HOME"] = rh
    env["CARGO_HOME"] = ch
    env["SV_TIMING_ROOT"] = str(root)
    # Prefer contained cargo/rustc
    path_prefix = str(cargo_bin(root))
    env["PATH"] = path_prefix + os.pathsep + env.get("PATH", "")
    return env
