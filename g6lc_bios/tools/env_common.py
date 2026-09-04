#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Contained-toolchain paths for g6lc_bios. Nothing here knows the monorepo.

from __future__ import annotations

import os
import platform
from pathlib import Path

_WINDOWS = platform.system() == "Windows"
_EXE = ".exe" if _WINDOWS else ""


def package_root() -> Path:
    return Path(__file__).resolve().parent.parent


def tools_dir() -> Path:
    return package_root() / ".tools"


def cargo_home() -> Path:
    return tools_dir() / "cargo"


def cargo_bin() -> Path:
    return cargo_home() / "bin" / f"cargo{_EXE}"


def contained_env() -> dict[str, str]:
    env = os.environ.copy()
    env["CARGO_HOME"] = str(cargo_home())
    env["RUSTUP_HOME"] = str(tools_dir() / "rustup")
    bin_dir = str(cargo_home() / "bin")
    env["PATH"] = bin_dir + os.pathsep + env.get("PATH", "")
    return env
