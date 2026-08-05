#!/usr/bin/env python3
"""Compare origin/master vs HEAD tracked blob sizes for constrained scopes.

Scopes used for the LibreCore provenance size claim:
  - RTL HDL under core/ + corev_apu/ (*.sv, *.svh, *.v, *.vh)
  - sv-timing/
  - build-platform/
  - docs/website/

Also reports full core/+corev_apu/ tree sizes for context.
"""
from __future__ import annotations

import subprocess
import sys


def blobs(ref: str) -> dict[str, tuple[str, int]]:
    out = subprocess.check_output(
        ["git", "ls-tree", "-r", "-l", ref], text=True, errors="replace"
    )
    m: dict[str, tuple[str, int]] = {}
    for line in out.splitlines():
        meta, path = line.split("\t", 1)
        fields = meta.split()
        if len(fields) < 4 or fields[1] != "blob" or fields[3] == "-":
            continue
        m[path] = (fields[2], int(fields[3]))
    return m


def is_rtl_sv(path: str) -> bool:
    if not (path.startswith("core/") or path.startswith("corev_apu/")):
        return False
    return path.endswith((".sv", ".svh", ".v", ".vh"))


def is_rtl_tree(path: str) -> bool:
    return path.startswith("core/") or path.startswith("corev_apu/")


def is_sv_timing(path: str) -> bool:
    return path.startswith("sv-timing/")


def is_build_platform(path: str) -> bool:
    return path.startswith("build-platform/")


def is_website(path: str) -> bool:
    return path.startswith("docs/website/")


def combined_claim(path: str) -> bool:
    return (
        is_rtl_sv(path)
        or is_sv_timing(path)
        or is_build_platform(path)
        or is_website(path)
    )


def filt(table: dict[str, tuple[str, int]], pred) -> dict[str, tuple[str, int]]:
    return {p: v for p, v in table.items() if pred(p)}


def report(name: str, b: dict[str, tuple[str, int]], c: dict[str, tuple[str, int]]) -> None:
    bt = sum(s for _, s in b.values())
    ct = sum(s for _, s in c.values())
    bp, cp = set(b), set(c)
    only_c = cp - bp
    common = bp & cp
    ident = {p for p in common if b[p][0] == c[p][0]}
    ident_b = sum(c[p][1] for p in ident)
    new_b = sum(c[p][1] for p in only_c)
    ratio = 100.0 * bt / ct if ct else float("nan")
    ident_ratio = 100.0 * ident_b / ct if ct else float("nan")
    growth = 100.0 * (ct - bt) / ct if ct else float("nan")
    print(name)
    print(
        f"  origin/master: {bt:12d} B ({bt/1024/1024:7.2f} MiB), {len(b):5d} files"
    )
    print(
        f"  HEAD:          {ct:12d} B ({ct/1024/1024:7.2f} MiB), {len(c):5d} files"
    )
    print(f"  origin/HEAD   = {ratio:6.2f}%")
    print(f"  (HEAD-origin)/HEAD = {growth:6.2f}%")
    print(
        f"  identical-path bytes/HEAD = {ident_ratio:6.2f}% "
        f"({len(ident)} files, {ident_b/1024/1024:.2f} MiB)"
    )
    print(
        f"  new-only-path bytes/HEAD  = {100.0*new_b/ct if ct else 0:6.2f}% "
        f"({len(only_c)} files, {new_b/1024/1024:.2f} MiB)"
    )
    print()


def main() -> int:
    base = blobs("origin/master")
    cur = blobs("HEAD")
    scopes = [
        ("RTL SV (core/ + corev_apu/ *.sv/*.svh/*.v/*.vh)", is_rtl_sv),
        ("RTL tree (core/ + corev_apu/ all tracked)", is_rtl_tree),
        ("sv-timing/", is_sv_timing),
        ("build-platform/", is_build_platform),
        ("docs/website/", is_website),
        (
            "CLAIM SCOPE: RTL SV + sv-timing + build-platform + docs/website",
            combined_claim,
        ),
    ]
    for name, pred in scopes:
        report(name, filt(base, pred), filt(cur, pred))
    return 0


if __name__ == "__main__":
    sys.exit(main())
