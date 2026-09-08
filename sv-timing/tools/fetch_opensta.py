#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Shallow-clone The-OpenROAD-Project/OpenSTA for host STA smoke.
# Never a crate / Cargo dependency (KD0). Soft-skip without git/network.

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

OPENSTA_URL = "https://github.com/The-OpenROAD-Project/OpenSTA.git"


def log(msg: str) -> None:
    print(f"[fetch-opensta] {msg}")


def err(msg: str) -> None:
    print(f"[fetch-opensta] ERROR: {msg}", file=sys.stderr)


def default_dest(package_root: Path) -> Path:
    env = os.environ.get("SVT_OPENSTA_DIR", "").strip()
    if env:
        return Path(env)
    # Host workspace when this package sits in a monorepo (optional).
    host_ws = package_root.parent / "build-platform" / "workspace" / "tooling" / "opensta"
    if (package_root.parent / "build-platform").is_dir():
        return host_ws
    return package_root / ".tools" / "opensta"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Clone OpenSTA for host STA (not an sv-timing crate dep)"
    )
    parser.add_argument(
        "--dest",
        type=Path,
        default=None,
        help="Clone directory (default: $SVT_OPENSTA_DIR or host workspace/tooling/opensta)",
    )
    parser.add_argument(
        "--url",
        default=OPENSTA_URL,
        help="Git remote (default: The-OpenROAD-Project/OpenSTA)",
    )
    args = parser.parse_args(argv)

    package_root = Path(__file__).resolve().parent.parent
    dest = (args.dest or default_dest(package_root)).resolve()

    git = shutil.which("git")
    if not git:
        err("git not on PATH — skip OpenSTA clone")
        return 0

    if (dest / ".git").is_dir() or (dest / "CMakeLists.txt").is_file():
        log(f"already present: {dest}")
        return 0

    dest.parent.mkdir(parents=True, exist_ok=True)
    log(f"cloning {args.url} → {dest} (depth=1)")
    r = subprocess.run(
        [git, "clone", "--depth", "1", args.url, str(dest)],
        check=False,
    )
    if r.returncode != 0:
        err(f"git clone failed rc={r.returncode} (network/auth); STA remains optional")
        return 0
    log("clone OK — build with CMake on the host; binary is usually `sta`")
    log("sv-timing crates do not link this tree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
