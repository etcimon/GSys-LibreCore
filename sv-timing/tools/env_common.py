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


def force_utf8_stdio() -> None:
    """Make stdout/stderr carry UTF-8 regardless of the host console codepage.

    The reports here use `->` arrows and similar non-ASCII punctuation, and every file
    the tooling writes already pins `encoding="utf-8"`. Standard streams did not, so on
    a Windows console defaulting to cp1252 a completed run could still die with
    `UnicodeEncodeError: 'charmap' codec can't encode character '\\u2192'` while printing
    its own summary -- losing the result of work that had already succeeded.

    `errors="replace"` is a deliberate backstop: a report should degrade to a question
    mark, never abort the run that produced it.
    """
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is None:
            continue
        try:
            reconfigure(encoding="utf-8", errors="replace")
        except (OSError, ValueError):
            # A redirected or already-detached stream is not worth failing over.
            pass


def venv_python_works(root: Path | None = None) -> bool:
    """Whether the venv interpreter actually RUNS, not merely that the file exists.

    A venv records its base interpreter in `pyvenv.cfg` and, on Windows, its
    `python.exe` is a shim that needs that base install. Remove or upgrade the host
    Python and the shim stays on disk but dies with
    `No Python at '...\\Python39\\python.exe'`.

    Every call site used to gate on `Path.is_file()`, which is true for a dead shim, so
    the tool would pick it and fail with that message instead of saying the venv is
    stale. Checking liveness here keeps the distinction in one place.
    """
    import subprocess  # local: keeps module import cheap for callers that never probe

    vpy = venv_python(root)
    if not vpy.is_file():
        return False
    try:
        subprocess.run(
            [str(vpy), "-c", ""],
            check=True,
            capture_output=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return True


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
