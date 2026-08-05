#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Project-independent EDA filelist expander → portable sv-timing `.f`.
#
# Expands env placeholders, nested -f/-F, +incdir+, +define+ into a flat
# portable list the Rust CLI understands. No monorepo/host package names.

"""Expand nested / env-bearing filelists into a portable sv-timing `.f`.

Supported (generic, not host-specific):
  - blank lines; `#` and `//` comments
  - source paths (relative to the listing file's directory)
  - `+incdir+path` (multiple dirs separated by `+`)
  - `+define+NAME` / `+define+NAME=VAL` (multiple via `+`)
  - nested `-f path` (resolve vs cwd) and `-F path` (resolve vs parent list)
  - env expansion: `${VAR}`, `$(VAR)`, `$VAR` from process env + `--set`

Not supported (host must pre-handle): Bender, FuseSoC, globs, `+libext+`.

Usage:
  python tools/flist_expand.py --in project.f --out portable.f
  python tools/flist_expand.py --in nested.f --set ROOT=/abs/path --out-dir out/
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

_ENV_BRACE = re.compile(r"\$\{(\w+)\}")
_ENV_PAREN = re.compile(r"\$\((\w+)\)")
_ENV_BARE = re.compile(r"\$(\w+)")


def expand_env(text: str, env: dict[str, str]) -> str:
    """Replace ${VAR}, $(VAR), $VAR using *env* (missing → empty string)."""

    def repl_brace(m: re.Match[str]) -> str:
        return env.get(m.group(1), "")

    def repl_paren(m: re.Match[str]) -> str:
        return env.get(m.group(1), "")

    def repl_bare(m: re.Match[str]) -> str:
        return env.get(m.group(1), "")

    s = _ENV_BRACE.sub(repl_brace, text)
    s = _ENV_PAREN.sub(repl_paren, s)
    s = _ENV_BARE.sub(repl_bare, s)
    return s


def _posix(p: Path | str) -> str:
    return str(p).replace("\\", "/")


def _is_abs(p: str) -> bool:
    if not p:
        return False
    # POSIX absolute or Windows drive letter
    if p.startswith("/") or p.startswith("\\"):
        return True
    if len(p) >= 2 and p[1] == ":" and p[0].isalpha():
        return True
    return Path(p).is_absolute()


def _resolve(base: Path, p: str) -> Path:
    p = p.strip().strip('"').strip("'")
    if not p:
        return base
    path = Path(p)
    if _is_abs(p):
        return path
    return (base / path).resolve()


def strip_comment(line: str) -> str:
    s = line
    if "//" in s:
        s = s[: s.index("//")]
    # whole-line style # comments; also strip trailing # (portable lists rarely use # in paths)
    if "#" in s:
        s = s[: s.index("#")]
    return s


class ExpandResult:
    __slots__ = ("files", "incdirs", "defines", "nested_lists")

    def __init__(self) -> None:
        self.files: list[Path] = []
        self.incdirs: list[Path] = []
        self.defines: list[tuple[str, str | None]] = []
        self.nested_lists: list[Path] = []

    def add_file(self, p: Path) -> None:
        key = _posix(p).lower() if os.name == "nt" else _posix(p)
        seen = {_posix(x).lower() if os.name == "nt" else _posix(x) for x in self.files}
        if key not in seen:
            self.files.append(p)

    def add_incdir(self, p: Path) -> None:
        key = _posix(p).lower() if os.name == "nt" else _posix(p)
        seen = {_posix(x).lower() if os.name == "nt" else _posix(x) for x in self.incdirs}
        if key not in seen:
            self.incdirs.append(p)

    def add_define(self, name: str, value: str | None) -> None:
        for n, v in self.defines:
            if n == name and v == value:
                return
        self.defines.append((name, value))


def expand_filelist(
    entry: Path | str,
    *,
    env: dict[str, str] | None = None,
    cwd: Path | str | None = None,
    max_depth: int = 32,
    strict: bool = True,
) -> ExpandResult:
    """Walk *entry* and return flattened files / incdirs / defines."""
    env_map = dict(os.environ)
    if env:
        env_map.update(env)
    cwd_p = Path(cwd).resolve() if cwd else Path.cwd().resolve()
    entry_p = Path(entry)
    if not _is_abs(str(entry_p)):
        entry_p = (cwd_p / entry_p).resolve()
    else:
        entry_p = entry_p.resolve()

    out = ExpandResult()
    visiting: set[str] = set()

    def walk(manifest: Path, base_for_rel: Path, depth: int) -> None:
        if depth > max_depth:
            raise RuntimeError(f"filelist nest depth exceeded (max {max_depth}) at {manifest}")
        key = _posix(manifest).lower() if os.name == "nt" else _posix(manifest)
        if key in visiting:
            raise RuntimeError(f"filelist cycle at {manifest}")
        if not manifest.is_file():
            if strict:
                raise FileNotFoundError(f"manifest not found: {manifest}")
            return
        visiting.add(key)
        out.nested_lists.append(manifest)
        text = manifest.read_text(encoding="utf-8", errors="replace")
        list_dir = manifest.parent

        for raw in text.splitlines():
            line = expand_env(strip_comment(raw), env_map).strip()
            if not line:
                continue
            if line.startswith("+incdir+"):
                rest = line[len("+incdir+") :]
                for part in rest.split("+"):
                    part = part.strip()
                    if part:
                        out.add_incdir(_resolve(list_dir, part))
                continue
            if line.startswith("+define+"):
                rest = line[len("+define+") :]
                for part in rest.split("+"):
                    part = part.strip()
                    if not part:
                        continue
                    if "=" in part:
                        n, v = part.split("=", 1)
                        out.add_define(n, v)
                    else:
                        out.add_define(part, None)
                continue
            # Nested -f / -F (space or tab; optional no-space form)
            nested_path: str | None = None
            nest_vs_list_dir = True
            if line.startswith("-F ") or line.startswith("-F\t"):
                nested_path = line[3:].strip()
                nest_vs_list_dir = True
            elif line.startswith("-f ") or line.startswith("-f\t"):
                nested_path = line[3:].strip()
                nest_vs_list_dir = False
            elif line.startswith("-F") and len(line) > 2 and line[2] not in "- \t":
                nested_path = line[2:].strip()
                nest_vs_list_dir = True
            elif line.startswith("-f") and len(line) > 2 and line[2] not in "- \t":
                nested_path = line[2:].strip()
                nest_vs_list_dir = False
            if nested_path is not None:
                base = list_dir if nest_vs_list_dir else cwd_p
                nested = _resolve(base, nested_path)
                walk(nested, base, depth + 1)
                continue
            # Skip other +/- flags (+libext+, -sv, ...)
            if line.startswith("+") or (line.startswith("-") and not line.startswith("-f") and not line.startswith("-F")):
                continue
            out.add_file(_resolve(list_dir, line))

        visiting.discard(key)

    walk(entry_p, cwd_p, 0)
    return out


def write_portable_f(
    out_path: Path | str,
    result: ExpandResult,
    *,
    rel_base: Path | str | None = None,
    header: str = "",
    absolute: bool = False,
) -> Path:
    """Write a portable `.f` (incdirs + defines + files) for sv-timing CLI."""
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    base = Path(rel_base).resolve() if rel_base else out_path.parent.resolve()

    def display(p: Path) -> str:
        if absolute:
            return _posix(p.resolve())
        try:
            rel = os.path.relpath(str(p.resolve()), str(base))
            return _posix(rel)
        except ValueError:
            # different drives on Windows
            return _posix(p.resolve())

    lines: list[str] = [
        "# sv-timing portable filelist — generated by tools/flist_expand.py",
        "# Host may review; paths are for --files-from consumption.",
    ]
    if header:
        for h in header.splitlines():
            lines.append(f"# {h}")
    for d in result.incdirs:
        lines.append(f"+incdir+{display(d)}")
    for name, val in result.defines:
        if val is None:
            lines.append(f"+define+{name}")
        else:
            lines.append(f"+define+{name}={val}")
    for f in result.files:
        lines.append(display(f))
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return out_path


def parse_set_kv(items: list[str]) -> dict[str, str]:
    out: dict[str, str] = {}
    for it in items:
        if "=" not in it:
            raise SystemExit(f"--set expects KEY=VAL, got: {it}")
        k, v = it.split("=", 1)
        out[k] = v
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="flist_expand",
        description="Expand nested/env filelists into a portable sv-timing .f",
    )
    ap.add_argument("--in", dest="infile", required=True, help="Input filelist path")
    ap.add_argument("--out", dest="outfile", help="Output portable .f path")
    ap.add_argument(
        "--out-dir",
        dest="outdir",
        help="If set without --out, write $OUTDIR/svt_portable.f",
    )
    ap.add_argument(
        "--set",
        action="append",
        default=[],
        metavar="KEY=VAL",
        help="Extra env binding for ${KEY} expansion (repeatable)",
    )
    ap.add_argument(
        "--cwd",
        default=None,
        help="Working directory for -f resolution (default: process cwd)",
    )
    ap.add_argument(
        "--absolute",
        action="store_true",
        help="Write absolute paths in the portable list",
    )
    ap.add_argument(
        "--rel-base",
        default=None,
        help="Base directory for relative paths in output (default: out parent)",
    )
    ap.add_argument(
        "--json-summary",
        action="store_true",
        help="Print file/incdir/define counts as JSON on stdout",
    )
    ap.add_argument(
        "--max-depth",
        type=int,
        default=32,
        help="Max nested -f/-F depth (default 32)",
    )
    args = ap.parse_args(argv)

    env_extra = parse_set_kv(args.set)
    result = expand_filelist(
        args.infile,
        env=env_extra,
        cwd=args.cwd,
        max_depth=args.max_depth,
    )

    out: Path | None = None
    if args.outfile:
        out = Path(args.outfile)
    elif args.outdir:
        out = Path(args.outdir) / "svt_portable.f"
    else:
        # Default next to input
        inp = Path(args.infile)
        out = inp.with_name(inp.stem + "_portable.f")

    write_portable_f(
        out,
        result,
        rel_base=args.rel_base,
        absolute=args.absolute,
        header=f"source={args.infile}",
    )

    if args.json_summary:
        import json

        print(
            json.dumps(
                {
                    "out": _posix(out.resolve()),
                    "files": len(result.files),
                    "incdirs": len(result.incdirs),
                    "defines": len(result.defines),
                    "nested_lists": len(result.nested_lists),
                }
            )
        )
    else:
        print(
            f"[flist_expand] wrote {out} "
            f"({len(result.files)} files, {len(result.incdirs)} incdirs, "
            f"{len(result.defines)} defines)",
            file=sys.stderr,
        )
    return 0


def _selftest() -> int:
    """Minimal in-process smoke test (no pytest required)."""
    import tempfile

    td = Path(tempfile.mkdtemp(prefix="svt_flist_"))
    try:
        leaf = td / "leaf.f"
        top = td / "top.f"
        a = td / "a.sv"
        sub = td / "sub"
        sub.mkdir()
        b = sub / "b.sv"
        a.write_text("module a; endmodule\n", encoding="utf-8")
        b.write_text("module b; endmodule\n", encoding="utf-8")
        leaf.write_text("b.sv\n+define+FROM_LEAF=1\n", encoding="utf-8")
        top.write_text(
            "\n".join(
                [
                    "# top",
                    "+incdir+sub",
                    "+define+TOP",
                    "a.sv",
                    "-F leaf.f",
                    "",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        r = expand_filelist(top, cwd=td)
        assert len(r.files) == 2, r.files
        assert any(p.name == "a.sv" for p in r.files)
        assert any(p.name == "b.sv" for p in r.files)
        assert any(p.name == "sub" for p in r.incdirs)
        assert ("TOP", None) in r.defines
        assert ("FROM_LEAF", "1") in r.defines

        # env expansion
        env_list = td / "env.f"
        env_list.write_text("${SVT_FLIST_ROOT}/a.sv\n", encoding="utf-8")
        r2 = expand_filelist(env_list, env={"SVT_FLIST_ROOT": str(td)}, cwd=td)
        assert len(r2.files) == 1
        assert r2.files[0].resolve() == a.resolve()

        out = td / "portable.f"
        write_portable_f(out, r, absolute=True)
        text = out.read_text(encoding="utf-8")
        assert "+incdir+" in text
        assert "a.sv" in text or "a.sv".replace("\\", "/") in text.replace("\\", "/")
        print("flist_expand selftest OK")
        return 0
    finally:
        import shutil

        shutil.rmtree(td, ignore_errors=True)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        sys.exit(_selftest())
    sys.exit(main())
