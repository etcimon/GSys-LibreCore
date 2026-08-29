#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# msvc_env.py — detect and import the Microsoft Visual C++ build environment.
#
# Mirrors the algorithm in build-platform/build.ps1 so a native Windows source
# build (for example dtc or spike) can run with cl.exe/link.exe. The package
# is independent; this file does not call build-platform, it only replicates
# the discovery rules.

from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path


def _program_files() -> tuple[Path, Path]:
    """Return (ProgramFiles, ProgramFiles(x86)) as Path objects."""
    pf = Path(os.environ.get("ProgramFiles", r"C:\Program Files"))
    pf86 = Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"))
    return pf, pf86


def find_vcvars() -> Path | None:
    """Find the best vcvars batch file for x64 (VS 2019-2026)."""
    if shutil.which("cl"):
        # If cl is already on PATH, the env is already imported in this process.
        return None

    pf, pf86 = _program_files()
    vcvars: Path | None = None

    # 1. Prefer vswhere.exe (VS 2017+ standard locator).
    vswhere_candidates = [
        pf86 / "Microsoft Visual Studio" / "Installer" / "vswhere.exe",
        pf / "Microsoft Visual Studio" / "Installer" / "vswhere.exe",
    ]
    vswhere = next((p for p in vswhere_candidates if p.is_file()), None)
    if vswhere:
        try:
            out = subprocess.run(
                [
                    str(vswhere),
                    "-latest",
                    "-products", "*",
                    "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
                    "-version", "[16.0,19.0)",
                    "-property", "installationPath",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            for line in out.stdout.splitlines():
                install = Path(line.strip())
                if not install.is_dir():
                    continue
                cand64 = install / "VC" / "Auxiliary" / "Build" / "vcvars64.bat"
                cand_all = install / "VC" / "Auxiliary" / "Build" / "vcvarsall.bat"
                if cand64.is_file():
                    vcvars = cand64
                    break
                if cand_all.is_file():
                    vcvars = cand_all
                    break
        except Exception:
            pass

    # 2. Fallback: walk year folders newest-first when vswhere is absent.
    if vcvars is None:
        for year in (2026, 2025, 2024, 2022, 2019):
            for root in (pf / "Microsoft Visual Studio", pf86 / "Microsoft Visual Studio"):
                if not root.is_dir():
                    continue
                for ed in ("Enterprise", "Professional", "Community", "BuildTools", "Preview"):
                    cand = root / str(year) / ed / "VC" / "Auxiliary" / "Build" / "vcvars64.bat"
                    if cand.is_file():
                        vcvars = cand
                        break
                if vcvars:
                    break
            if vcvars:
                break

    return vcvars


def import_msvc_environment() -> bool:
    """Import the MSVC x64 environment into the current process.

    Returns True when cl.exe is available afterwards (either already or after
    running the discovered vcvars script), False otherwise.
    """
    if shutil.which("cl"):
        return True

    vcvars = find_vcvars()
    if vcvars is None:
        return False

    if "vcvarsall" in vcvars.name.lower():
        cmdline = f'"{vcvars}" x64 >nul 2>&1 && set'
    else:
        cmdline = f'"{vcvars}" >nul 2>&1 && set'

    try:
        proc = subprocess.run(
            ["cmd.exe", "/c", cmdline],
            capture_output=True,
            text=True,
            check=False,
        )
    except Exception:
        return False

    for line in proc.stdout.splitlines():
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=(.*)$', line)
        if m:
            os.environ[m.group(1)] = m.group(2)

    return shutil.which("cl") is not None


def have_msvc() -> bool:
    """Return True if the MSVC compiler (cl.exe) is on PATH."""
    return shutil.which("cl") is not None
