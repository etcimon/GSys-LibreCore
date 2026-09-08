#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# refresh_sv_parser.py — Ensure crates/sv-parser is the etcimon/sv-parser
# submodule (branch from tools/sv-parser.rev). Stdlib + git only.
#
# Invoked by: python tools/svt.py vendor-sv-parser
# This is a *Rust* SystemVerilog parser (dalance/sv-parser fork). It is not
# Python, pyslang, or slang.

from __future__ import annotations

import argparse
import shutil
import subprocess
from pathlib import Path


UPSTREAM = "https://github.com/etcimon/sv-parser.git"
BASED_ON = "dalance/sv-parser v0.13.5"


def run(cmd: list[str], cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess:
    print(f"+ {' '.join(cmd)}")
    return subprocess.run(cmd, cwd=str(cwd) if cwd else None, check=check)


def read_rev(rev_file: Path) -> str:
    text = rev_file.read_text(encoding="utf-8").strip()
    if not text or text.startswith("#"):
        raise SystemExit(f"empty or invalid rev file: {rev_file}")
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


def is_git_checkout(path: Path) -> bool:
    git = path / ".git"
    return git.is_file() or git.is_dir()


def write_notice(pkg_root: Path, rev: str, head: str) -> None:
    notice = pkg_root / "LICENSE.NOTICE-sv-parser"
    notice.write_text(
        f"""# NOTICE — sv-parser submodule

This package uses a git submodule at `crates/sv-parser/` pointing at
[{UPSTREAM}]({UPSTREAM}) branch/pin `{rev}` (HEAD `{head}`).

That tree is a fork of [dalance/sv-parser](https://github.com/dalance/sv-parser)
({BASED_ON}). It is a **Rust** SystemVerilog parser (IEEE 1800 CST). It is
**not** a Python parser, pyslang, or slang.

Upstream (and this fork) is dual-licensed MIT OR Apache-2.0. See the LICENSE
files inside `crates/sv-parser/`. Do not re-license the parser tree.

GSys LibreCore extensions live on branch `g6lc` (see `crates/sv-parser/G6LC.md`).
Refresh with `python tools/svt.py vendor-sv-parser`.
""",
        encoding="utf-8",
    )


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Clone or update the etcimon/sv-parser submodule under crates/sv-parser"
    )
    ap.add_argument(
        "--root",
        type=Path,
        default=None,
        help="sv-timing package root (default: parent of tools/)",
    )
    ap.add_argument(
        "--rev",
        default=None,
        help="Override tools/sv-parser.rev (branch, tag, or commit)",
    )
    ap.add_argument(
        "--force",
        action="store_true",
        help="Replace a non-git crates/sv-parser tree with a fresh clone",
    )
    args = ap.parse_args()

    tools_dir = Path(__file__).resolve().parent
    pkg_root = (args.root or tools_dir.parent).resolve()
    rev_file = tools_dir / "sv-parser.rev"
    rev = args.rev or read_rev(rev_file)
    dest = pkg_root / "crates" / "sv-parser"
    git = which_git()

    dest.parent.mkdir(parents=True, exist_ok=True)

    if dest.exists() and not is_git_checkout(dest):
        if not args.force:
            raise SystemExit(
                f"{dest} exists but is not a git checkout; re-run with --force to replace"
            )
        print(f"{dest} is not a git checkout; replacing")
        shutil.rmtree(dest)

    if not dest.exists():
        run(
            [
                git,
                "clone",
                "--branch",
                rev,
                UPSTREAM,
                str(dest),
            ],
            check=True,
        )
    else:
        run([git, "fetch", "origin"], cwd=dest, check=True)
        # Prefer origin/<rev> when rev is a branch; fall back to the raw rev.
        probe = run(
            [git, "rev-parse", "--verify", f"origin/{rev}"],
            cwd=dest,
            check=False,
        )
        target = f"origin/{rev}" if probe.returncode == 0 else rev
        run([git, "checkout", "--detach", target], cwd=dest, check=False)
        # Stay on a named branch when possible (submodule branch = g6lc).
        run([git, "checkout", rev], cwd=dest, check=False)
        run([git, "merge", "--ff-only", target], cwd=dest, check=False)

    head = subprocess.check_output(
        [git, "rev-parse", "HEAD"], cwd=str(dest), text=True
    ).strip()
    print(f"sv-parser {rev} @ {head} ({UPSTREAM})")
    write_notice(pkg_root, rev, head)
    print(f"OK: sv-parser at {dest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
