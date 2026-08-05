#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# refresh_sv_parser.py — Fetch a pinned dalance/sv-parser tree into crates/sv-parser
# and apply ordered patches from patches/sv-parser/. Stdlib only (no pip deps).
#
# Invoked by: ./svt.sh vendor-sv-parser | .\svt.ps1 vendor-sv-parser
# Expects: git on PATH; run from package root or pass --root.

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


UPSTREAM = "https://github.com/dalance/sv-parser.git"
DEFAULT_EXCLUDE = {
    ".git",
    ".github",
    "target",
}


def run(cmd: list[str], cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess:
    print(f"+ {' '.join(cmd)}")
    return subprocess.run(cmd, cwd=str(cwd) if cwd else None, check=check)


def read_rev(rev_file: Path) -> str:
    text = rev_file.read_text(encoding="utf-8").strip()
    if not text or text.startswith("#"):
        raise SystemExit(f"empty or invalid rev file: {rev_file}")
    # first non-empty non-comment line
    for line in text.splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            return line
    raise SystemExit(f"no rev found in {rev_file}")


def which_git() -> str:
    from shutil import which

    g = which("git")
    if not g:
        raise SystemExit("git not found on PATH; install Git and re-run")
    return g


def copy_tree(src: Path, dst: Path) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)

    def ignore(directory: str, names: list[str]) -> set[str]:
        return {n for n in names if n in DEFAULT_EXCLUDE}

    shutil.copytree(src, dst, ignore=ignore)


def apply_patches(pkg_root: Path, dest: Path) -> None:
    patch_dir = pkg_root / "patches" / "sv-parser"
    if not patch_dir.is_dir():
        print(f"no patch dir {patch_dir}; skipping patches")
        return
    patches = sorted(patch_dir.glob("*.patch"))
    if not patches:
        print("no *.patch files; skipping patches")
        return
    git = which_git()
    for p in patches:
        print(f"applying {p.name}")
        # Prefer git apply from dest so paths in patches are relative to tree root
        r = run([git, "apply", "--verbose", str(p)], cwd=dest, check=False)
        if r.returncode != 0:
            # fallback: patch -p1 if available
            patch_bin = shutil.which("patch")
            if not patch_bin:
                raise SystemExit(f"failed to apply {p} (git apply exit {r.returncode})")
            run([patch_bin, "-p1", "-i", str(p)], cwd=dest, check=True)


def write_notice(pkg_root: Path, rev: str) -> None:
    notice = pkg_root / "LICENSE.NOTICE-sv-parser"
    notice.write_text(
        f"""# NOTICE — vendored sv-parser

This package vendors [dalance/sv-parser]({UPSTREAM}) at pin `{rev}` under
`crates/sv-parser/`.

Upstream is dual-licensed MIT OR Apache-2.0. See the LICENSE files inside
`crates/sv-parser/` (and per-crate LICENSE-MIT / LICENSE-APACHE where present).

Do not re-license the vendored tree. Local patches live in `patches/sv-parser/`.
Refresh with `svt vendor-sv-parser` (see tools/vendor-sv-parser.md).
""",
        encoding="utf-8",
    )


def main() -> int:
    ap = argparse.ArgumentParser(description="Vendor dalance/sv-parser into crates/sv-parser")
    ap.add_argument(
        "--root",
        type=Path,
        default=None,
        help="sv-timing package root (default: parent of tools/)",
    )
    ap.add_argument(
        "--rev",
        default=None,
        help="Override tools/sv-parser.rev (tag or commit)",
    )
    ap.add_argument(
        "--force",
        action="store_true",
        help="Replace existing crates/sv-parser even if present",
    )
    args = ap.parse_args()

    tools_dir = Path(__file__).resolve().parent
    pkg_root = (args.root or tools_dir.parent).resolve()
    rev_file = tools_dir / "sv-parser.rev"
    rev = args.rev or read_rev(rev_file)
    dest = pkg_root / "crates" / "sv-parser"

    if dest.exists() and not args.force:
        # Allow re-run with --force; otherwise update in place via replace
        print(f"{dest} exists; replacing (--force not required for refresh)")
    git = which_git()

    with tempfile.TemporaryDirectory(prefix="sv-parser-vendor-") as tmp:
        tmp_path = Path(tmp)
        clone_dir = tmp_path / "sv-parser"
        run(
            [
                git,
                "clone",
                "--depth",
                "1",
                "--branch",
                rev,
                UPSTREAM,
                str(clone_dir),
            ],
            check=True,
        )
        # If rev is a full commit not a branch/tag, shallow branch clone may fail —
        # retry full fetch of that commit.
        if not clone_dir.exists():
            run([git, "clone", UPSTREAM, str(clone_dir)], check=True)
            run([git, "checkout", rev], cwd=clone_dir, check=True)

        # Record exact commit
        head = subprocess.check_output(
            [git, "rev-parse", "HEAD"], cwd=str(clone_dir), text=True
        ).strip()
        print(f"vendoring {rev} @ {head}")

        copy_tree(clone_dir, dest)
        # Drop nested .git if any slipped through
        nested_git = dest / ".git"
        if nested_git.exists():
            shutil.rmtree(nested_git)

        # Stamp
        stamp = dest / "VENDOR_STAMP"
        stamp.write_text(f"rev={rev}\ncommit={head}\nupstream={UPSTREAM}\n", encoding="utf-8")

    apply_patches(pkg_root, dest)
    write_notice(pkg_root, rev)
    print(f"OK: sv-parser vendored at {dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
