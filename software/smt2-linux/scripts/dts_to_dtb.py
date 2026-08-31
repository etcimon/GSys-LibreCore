#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""
Compile ariane-smt2.dts (or any DTS path) to DTB.

Prefers system `dtc`. Fallback: PyPI `fdt` package (pip install fdt) so Windows
hosts can build OpenSBI without device-tree-compiler.

Product-closeout guard
----------------------
`/soc/smt-product-closeout` documents SMT product items that are still open
(see `architecture/multi-threading/smt2-product-closeout.md`). For the subset of
those items that correspond to a guest-visible ISA extension, this script proves
at *build* time that no `cpu@` node advertises the extension, and fails the DTB
build if one does.

This replaces the previous approach, which patched OpenSBI's
`platform/generic/platform.c` to rewrite the FDT at runtime. That was both dead
(the DTS never advertised the token it stripped) and harmful: the rewriter called
`sbi_malloc()` from `fw_platform_init()`, which runs before `sbi_heap_init()`, so
the heap free-list head was still zeroed BSS and the allocator dereferenced
NULL+0x18. The `cpu@` nodes are the contract; firmware stays stock.
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

# Closeout properties that gate a guest-visible ISA extension token. Only these
# are enforced against `riscv,isa` / `riscv,isa-extensions`; every other `smt,*`
# property in the node is documentation for the product checklist and is never
# consumed by firmware or by this script.
CLOSEOUT_ISA_TOKENS: dict[str, tuple[str, ...]] = {
    "zawrs": ("zawrs",),
}

_CLOSEOUT_NODE = re.compile(r"smt-product-closeout\s*\{(?P<body>[^{}]*)\}", re.S)
_SMT_PROP_ZERO = re.compile(r"smt,(?P<name>[A-Za-z0-9_-]+)\s*=\s*<\s*0(?:x0+)?\s*>")
_ISA_STRING = re.compile(r'riscv,isa\s*=\s*"(?P<value>[^"]*)"')
_ISA_EXTENSIONS = re.compile(r"riscv,isa-extensions\s*=\s*(?P<value>[^;]*);", re.S)
_QUOTED = re.compile(r'"([^"]*)"')


def strip_comments(text: str) -> str:
    """Remove C/C++ comments so property scans cannot match commented-out text."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//.*?$", "", text, flags=re.M)


def closeout_absent_tokens(text: str) -> set[str]:
    """ISA tokens the closeout node declares absent (`smt,<item> = <0>`)."""
    node = _CLOSEOUT_NODE.search(strip_comments(text))
    if not node:
        return set()
    absent: set[str] = set()
    for m in _SMT_PROP_ZERO.finditer(node.group("body")):
        absent.update(CLOSEOUT_ISA_TOKENS.get(m.group("name"), ()))
    return absent


def find_closeout_violations(text: str) -> list[tuple[str, str]]:
    """Return (property, token) pairs where a cpu@ advertises an absent token."""
    absent = closeout_absent_tokens(text)
    if not absent:
        return []

    clean = strip_comments(text)
    violations: list[tuple[str, str]] = []
    for m in _ISA_STRING.finditer(clean):
        # `riscv,isa` is underscore-separated: rv64imafdc_zba_..._zawrs
        for token in m.group("value").split("_")[1:]:
            if token in absent:
                violations.append(("riscv,isa", token))
    for m in _ISA_EXTENSIONS.finditer(clean):
        for token in _QUOTED.findall(m.group("value")):
            if token in absent:
                violations.append(("riscv,isa-extensions", token))
    # Deduplicate while keeping report order stable.
    seen: set[tuple[str, str]] = set()
    return [v for v in violations if not (v in seen or seen.add(v))]


def strip_closeout_tokens(text: str, absent: set[str]) -> str:
    """Remove absent tokens from every `riscv,isa` / `riscv,isa-extensions`."""

    def fix_isa(m: re.Match[str]) -> str:
        parts = m.group("value").split("_")
        kept = [parts[0]] + [t for t in parts[1:] if t not in absent]
        return f'riscv,isa = "{"_".join(kept)}"'

    def fix_extensions(m: re.Match[str]) -> str:
        kept = [t for t in _QUOTED.findall(m.group("value")) if t not in absent]
        if not kept:
            return ""
        rendered = ", ".join(f'"{t}"' for t in kept)
        return f"riscv,isa-extensions = {rendered};"

    text = _ISA_STRING.sub(fix_isa, text)
    return _ISA_EXTENSIONS.sub(fix_extensions, text)


def enforce_closeout(dts: Path, out: Path, *, strip: bool) -> Path:
    """Check (or strip) closeout tokens. Returns the DTS path to compile."""
    text = dts.read_text(encoding="utf-8")
    absent = closeout_absent_tokens(text)
    if not absent:
        return dts

    violations = find_closeout_violations(text)
    listed = ", ".join(sorted(absent))
    if not violations:
        print(f"[dts_to_dtb] closeout OK: no cpu@ advertises {listed}")
        return dts

    detail = "; ".join(f"{prop} advertises '{tok}'" for prop, tok in violations)
    if not strip:
        print(
            f"[dts_to_dtb] ERROR: {dts} declares {listed} absent in "
            f"/soc/smt-product-closeout but {detail}.\n"
            f"[dts_to_dtb] Fix the DTS (the cpu@ nodes are the contract), or pass "
            f"--strip-closeout to remove the token at build time.",
            file=sys.stderr,
        )
        raise SystemExit(3)

    stripped = out.parent / f"{out.stem}.closeout-stripped.dts"
    stripped.write_text(strip_closeout_tokens(text, absent), encoding="utf-8")
    print(f"[dts_to_dtb] stripped {listed} ({detail}) -> {stripped}")
    return stripped


def compile_with_dtc(dts: Path, out: Path) -> None:
    subprocess.check_call(["dtc", "-I", "dts", "-O", "dtb", "-o", str(out), str(dts)])
    print(f"[dts_to_dtb] dtc -> {out}")


def compile_with_fdt(dts: Path, out: Path) -> None:
    try:
        from fdt import parse_dts
    except ImportError as e:
        print("Need system dtc or: pip install fdt", file=sys.stderr)
        raise SystemExit(2) from e

    text = dts.read_text(encoding="utf-8")
    # Strip C/C++ comments and DTS labels (CPU0:) which confuse some parsers
    text = strip_comments(text)
    text = re.sub(r"^[ \t]*[A-Za-z_][A-Za-z0-9_]*:[ \t]*", "", text, flags=re.M)
    fdt_obj = parse_dts(text)
    raw = fdt_obj.to_dtb(version=17)
    out.write_bytes(raw)
    print(f"[dts_to_dtb] python-fdt -> {out} ({len(raw)} bytes)")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-i", "--input", type=Path, help="DTS path")
    ap.add_argument("-o", "--output", type=Path, required=True)
    ap.add_argument(
        "--strip-closeout",
        action="store_true",
        help="rewrite a temporary DTS without closed-out ISA tokens instead of failing",
    )
    ap.add_argument(
        "--no-closeout-check",
        action="store_true",
        help="skip the /soc/smt-product-closeout guard entirely",
    )
    args = ap.parse_args()
    repo = Path(__file__).resolve().parents[3]
    dts = args.input or (repo / "corev_apu" / "bootrom" / "ariane-smt2.dts")
    if not dts.is_file():
        print(f"missing {dts}", file=sys.stderr)
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if not args.no_closeout_check:
        dts = enforce_closeout(dts, args.output, strip=args.strip_closeout)
    if shutil.which("dtc"):
        compile_with_dtc(dts, args.output)
    else:
        compile_with_fdt(dts, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
