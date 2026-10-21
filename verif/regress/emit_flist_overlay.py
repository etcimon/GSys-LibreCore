#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Flatten a CVA6 flist and replace sources with a corrected ``*__svt.sv`` emit.

The stock manifest includes other flists with ``-f``. Verilator would keep
reading the live files through those includes, so this writes one flat list:
``+incdir+`` and ``+define+`` stay, and a file whose basename matches an emit
(``alu.sv`` ↔ ``alu__svt.sv``, also ``.v`` / ``.svh``) is replaced by the
corrected path. Everything else stays as written, including ``${CVA6_REPO_DIR}``.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path


def expand(line: str) -> str:
    def sub(match: re.Match[str]) -> str:
        return os.environ.get(match.group(1), match.group(0))

    return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", sub, os.path.expandvars(line))


def emit_index(emit_flist: Path) -> dict[str, Path]:
    root = emit_flist.parent
    out: dict[str, Path] = {}
    for raw in emit_flist.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("//") or line.startswith("+"):
            continue
        path = Path(line)
        if not path.is_absolute():
            path = root / path
        name = path.name
        stem, sep, ext = name.rpartition("__svt.")
        if not sep:
            continue
        ext = ext.lower()
        if not path.is_file():
            print(f"emit-flist: missing {path}", file=sys.stderr)
            continue
        for live in (f"{stem}.{ext}", f"{stem}.sv", f"{stem}.v", f"{stem}.svh"):
            out[live.lower()] = path.resolve()
    return out


def rewrite(stock: Path, by_base: dict[str, Path], repo: Path) -> tuple[list[str], int, int]:
    lines: list[str] = []
    replaced = 0
    kept = 0
    seen: set[Path] = set()

    def walk(flist: Path) -> None:
        nonlocal replaced, kept
        flist = flist.resolve()
        if flist in seen:
            return
        seen.add(flist)
        for raw in flist.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or line.startswith("//") or line.startswith("/*"):
                continue
            expanded = expand(line)
            if expanded.startswith("+incdir+") or expanded.startswith("+define+"):
                lines.append(expanded)
                continue
            if expanded.startswith("-f ") or expanded.startswith("-F "):
                inc = expanded[2:].strip().strip('"')
                inc_path = Path(inc)
                if not inc_path.is_absolute():
                    inc_path = flist.parent / inc_path
                if not inc_path.is_file():
                    print(f"emit-flist: keep include (not found here): {line}", file=sys.stderr)
                    lines.append(line)
                    continue
                walk(inc_path)
                continue
            base = Path(expanded).name.lower()
            # The live testharness wrapper imports config_pkg::CBO_BLOCK_BYTES.
            # The corrected copy of config_pkg.sv predates that localparam, so
            # the live package stays with the current SoC.
            if base == "config_pkg.sv":
                lines.append(line)
                kept += 1
                continue
            hit = by_base.get(base)
            if hit is not None:
                lines.append(hit.as_posix())
                replaced += 1
            else:
                lines.append(line)
                kept += 1

    walk(stock)
    # Silence unused repo; callers pass it so ${CVA6_REPO_DIR} expands.
    _ = repo
    return lines, replaced, kept


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--stock", type=Path, required=True)
    p.add_argument("--emit", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    args = p.parse_args()
    repo = Path(os.environ.get("CVA6_REPO_DIR", Path.cwd()))
    os.environ["CVA6_REPO_DIR"] = str(repo)
    os.environ.setdefault(
        "HPDCACHE_DIR", str(repo / "core" / "cache_subsystem" / "hpdcache")
    )
    by_base = emit_index(args.emit.resolve())
    lines, replaced, kept = rewrite(args.stock.resolve(), by_base, repo)
    if replaced == 0:
        raise SystemExit("emit-flist: overlay replaced 0 files")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    header = (
        f"// emit overlay: replaced={replaced} live={kept} "
        f"emit={args.emit.resolve().as_posix()}\n"
    )
    args.out.write_text(header + "\n".join(lines) + "\n", encoding="utf-8")
    print(f"emit-flist: replaced={replaced} live={kept} out={args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
