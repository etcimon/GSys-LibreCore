#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""
Build a flat Verilator/lint flist with lean-emit (`*__svt.sv`) overlays.

Mirrors build-platform `applyEmitOverlay` (R8): basename match of live sources
against corrected emit entries. Emit always names `foo__svt.sv` even when the
live path is `foo.v`.

Usage:
  python3 verif/regress/mk-emit-overlay-flist.py \\
    --repo /path/to/cva6 \\
    --emit /path/to/corrected/svt_corrected.f \\
    --out /path/to/out.f \\
    [--primary core/Flist.cva6]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path


def expand(s: str, env: dict[str, str]) -> str:
    def repl(m: re.Match[str]) -> str:
        key = m.group(1)
        return env.get(key, m.group(0))

    return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", repl, s)


def flatten_flist(
    entry: Path, env: dict[str, str], cwd: Path
) -> tuple[list[str], list[str]]:
    files: list[str] = []
    incdirs: list[str] = []
    seen_files: set[str] = set()
    seen_inc: set[str] = set()
    visited: set[str] = set()

    def resolve_from(base: Path, p: str) -> Path:
        p = expand(p.strip(), env)
        path = Path(p)
        if path.is_absolute():
            return path
        return (base / path).resolve()

    def walk(flist_path: Path, resolve_dir: Path) -> None:
        key = str(flist_path.resolve())
        if key in visited:
            return
        visited.add(key)
        if not flist_path.is_file():
            raise FileNotFoundError(f"missing flist: {flist_path}")
        raw = flist_path.read_text(encoding="utf-8", errors="replace")
        for line in raw.splitlines():
            # Strip // comments; ignore full-line #
            text = re.sub(r"//.*$", "", line)
            text = expand(text, env).strip()
            if not text or text.startswith("#"):
                continue
            if text.startswith("+incdir+"):
                d = resolve_from(resolve_dir, text[len("+incdir+") :])
                ds = d.as_posix()
                if ds not in seen_inc:
                    seen_inc.add(ds)
                    incdirs.append(ds)
            elif text.startswith("-F ") or text.startswith("-f "):
                nested = text[3:].strip()
                # -F relative to including file dir; -f relative to cwd
                nested_path = resolve_from(
                    resolve_dir if text.startswith("-F ") else cwd, nested
                )
                walk(nested_path, nested_path.parent)
            elif text.startswith("+") or text.startswith("-"):
                continue
            else:
                f = resolve_from(resolve_dir, text)
                fs = f.as_posix()
                if fs not in seen_files:
                    seen_files.add(fs)
                    files.append(fs)

    entry_abs = entry if entry.is_absolute() else (cwd / entry).resolve()
    walk(entry_abs, entry_abs.parent)
    return files, incdirs


def load_edited_stems(emit_flist: Path) -> set[str] | None:
    """Return stems with edit_count>0 from sibling svt_emit_manifest.json, or None."""
    man = emit_flist.parent / "svt_emit_manifest.json"
    if not man.is_file():
        return None
    try:
        data = json.loads(man.read_text(encoding="utf-8"))
    except Exception:
        return None
    ents = data.get("entries") if isinstance(data, dict) else data
    if not isinstance(ents, list):
        return None
    stems: set[str] = set()
    for e in ents:
        if not isinstance(e, dict):
            continue
        if int(e.get("edit_count") or 0) <= 0:
            continue
        rel = e.get("emit_rel") or e.get("emit_path") or ""
        base = Path(str(rel).replace("\\", "/")).name
        m = re.match(r"^(.*)__svt\.(sv|v|svh)$", base, re.I)
        if m:
            stems.add(m.group(1).lower())
    return stems


def load_emit_map(
    emit_flist: Path, *, edited_only: bool = True
) -> dict[str, str]:
    """live basename (lower) -> absolute corrected path."""
    root = emit_flist.parent
    edited = load_edited_stems(emit_flist) if edited_only else None
    by_live: dict[str, str] = {}
    for raw in emit_flist.read_text(encoding="utf-8", errors="replace").splitlines():
        t = raw.strip()
        if not t or t.startswith("#") or t.startswith("//") or t.startswith("+"):
            continue
        p = Path(t)
        abs_p = p if p.is_absolute() else (root / p)
        if not abs_p.is_file():
            continue
        base = abs_p.name
        m = re.match(r"^(.*)__svt\.(sv|v|svh)$", base, re.I)
        if not m:
            continue
        stem, emit_ext = m.group(1), m.group(2).lower()
        if edited is not None and stem.lower() not in edited:
            continue
        pos = abs_p.resolve().as_posix()
        for ext in {emit_ext, "sv", "v", "svh"}:
            by_live[f"{stem}.{ext}".lower()] = pos
    return by_live


def apply_overlay(
    files: list[str], by_live: dict[str, str]
) -> tuple[list[str], int, list[str]]:
    out: list[str] = []
    replaced = 0
    replaced_bases: list[str] = []
    for f in files:
        b = Path(f).name.lower()
        rep = by_live.get(b)
        if rep:
            out.append(rep)
            replaced += 1
            replaced_bases.append(b)
        else:
            out.append(f)
    return out, replaced, replaced_bases


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo", required=True, help="CVA6 repo root")
    ap.add_argument("--emit", required=True, help="corrected/svt_corrected.f")
    ap.add_argument("--out", required=True, help="output flat flist path")
    ap.add_argument(
        "--primary",
        default="core/Flist.cva6",
        help="primary live flist (default core/Flist.cva6)",
    )
    ap.add_argument(
        "--all-emit",
        action="store_true",
        help="overlay every *__svt (default: only edit_count>0 from manifest)",
    )
    args = ap.parse_args()

    repo = Path(args.repo).resolve()
    emit = Path(args.emit).resolve()
    out = Path(args.out).resolve()
    if not emit.is_file():
        print(f"error: emit flist missing: {emit}", file=sys.stderr)
        return 2

    env = dict(os.environ)
    env.setdefault("CVA6_REPO_DIR", repo.as_posix())
    # Common substitutes used in Flist.cva6
    env.setdefault("HPDCACHE_DIR", (repo / "core/cache_subsystem/hpdcache").as_posix())

    primary = Path(args.primary)
    if not primary.is_absolute():
        primary = repo / primary

    files, incdirs = flatten_flist(primary, env, repo)
    edited_only = not args.all_emit
    by_live = load_emit_map(emit, edited_only=edited_only)
    files, replaced, replaced_bases = apply_overlay(files, by_live)

    out.parent.mkdir(parents=True, exist_ok=True)
    mode = "edited-only" if edited_only else "all-emit"
    lines = [
        f"// emit overlay flist — replaced={replaced} of {len(files)} mode={mode}",
        f"// emit={emit.as_posix()}",
        f"// primary={primary.as_posix()}",
    ]
    for d in incdirs:
        lines.append(f"+incdir+{d}")
    lines.extend(files)
    lines.append("")
    out.write_text("\n".join(lines), encoding="utf-8")
    # Basenames actually replaced (for Makefile emit_src_exclude)
    excl_path = out.with_suffix(out.suffix + ".exclude")
    # unique, preserve order
    seen: set[str] = set()
    excl_bases: list[str] = []
    for b in replaced_bases:
        if b not in seen:
            seen.add(b)
            excl_bases.append(b)
    excl_path.write_text(
        "\n".join(excl_bases) + ("\n" if excl_bases else ""), encoding="utf-8"
    )
    print(f"[mk-emit-overlay-flist] wrote {out}")
    print(
        f"  files={len(files)} replaced={replaced} "
        f"map_keys={len(by_live)} mode={mode}"
    )
    print(f"  exclude_list={excl_path} ({len(excl_bases)} basenames)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
