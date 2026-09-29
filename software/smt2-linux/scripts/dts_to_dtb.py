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

# --- Hart-count contract (R11 / I25) ----------------------------------------
# OpenSBI's whole FDT walk has exactly one durable output: `platform.hart_count`,
# written once at platform/generic/platform.c:187 from a count of `cpu@` nodes
# under /cpus. `plat_hc` is therefore the single best observable of a correct
# walk -- and a DTS that advertises a different number of countable harts than
# the hardware actually has is only discovered at L6, when the wrong CPU takes
# an interrupt or a hart never leaves the HSM wait.
#
# The three conditions below are OpenSBI v1.5's, mirrored exactly
# (fw_platform_init, platform/generic/platform.c:172-184):
#   1. fdt_parse_hart_id() must succeed          -> the node needs a `reg`
#   2. hartid < SBI_HARTMASK_MAX_BITS            -> include/sbi/sbi_hartmask.h:23
#   3. fdt_node_is_enabled()                     -> lib/utils/fdt/fdt_helper.c:245
#      status absent, or beginning "okay" / "ok"
# Anything else is silently skipped by the firmware, not diagnosed.
SBI_HARTMASK_MAX_BITS = 128

# Which RTL config package owns each in-tree DTS. The pairing is the contract:
# the `cpu@` count a DTS advertises must equal NrCores x NrHarts of the package
# it is built for. An unmapped DTS is not guessed at -- the check reports that
# it was skipped and why, because a check that quietly compares against the
# wrong package is worse than no check.
DTS_CONFIG_PKG: dict[str, str] = {
    "ariane.dts": "cv64a6_imafdc_sv39_config_pkg.sv",
    "ariane-smt2.dts": "g6lc64_smt2_config_pkg.sv",
    "ariane-ooo-server.dts": "g6lc64_ooo_server_config_pkg.sv",
    "ariane-server-math-v.dts": "g6lc64_server_math_v_config_pkg.sv",
    "ariane-stream8.dts": "g6lc64_stream8_config_pkg.sv",
    "ariane-ai.dts": "g6lc64_ai_config_pkg.sv",
    "ariane-ooo-int2.dts": "g6lc64_ooo_int2_config_pkg.sv",
    "ariane-ooo-int2-l3.dts": "g6lc64_ooo_int2_l3_config_pkg.sv",
    "ariane-smt2-l3.dts": "g6lc64_smt2_l3_config_pkg.sv",
    "ariane-stream8-l3.dts": "g6lc64_stream8_l3_config_pkg.sv",
    "ariane-server-math-l3.dts": "g6lc64_server_math_l3_config_pkg.sv",
}

_CPU_NODE = re.compile(r"(?P<label>cpu@(?P<addr>[0-9a-fA-F]+))\s*\{")
_REG_PROP = re.compile(r"\breg\s*=\s*<\s*(?P<value>0x[0-9a-fA-F]+|\d+)\s*>")
_STATUS_PROP = re.compile(r'\bstatus\s*=\s*"(?P<value>[^"]*)"')
_CFG_FIELD = re.compile(
    r"^\s*(?P<name>NrCores|NrHarts)\s*:\s*unsigned'\(\s*(?P<value>\d+)\s*\)", re.M
)


def _matching_brace(text: str, open_idx: int) -> int:
    """Index just past the `}` matching the `{` at `open_idx`, or -1."""
    depth = 0
    for i in range(open_idx, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return i
    return -1


def _node_body(text: str, open_idx: int) -> str:
    """Body of the node whose `{` is at `open_idx`, with nested nodes removed.

    Nested nodes are stripped so a child (e.g. `interrupt-controller`) cannot
    contribute its own `status` or `reg` to the parent's property scan.
    """
    close = _matching_brace(text, open_idx)
    if close < 0:
        return ""
    body = text[open_idx + 1 : close]
    out, depth = [], 0
    for ch in body:
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth = max(0, depth - 1)
        elif depth == 0:
            out.append(ch)
    return "".join(out)


def count_opensbi_harts(text: str) -> tuple[int, list[str]]:
    """Count `cpu@` nodes OpenSBI would count. Returns (count, skip reasons)."""
    clean = strip_comments(text)
    counted, skipped = 0, []
    for m in _CPU_NODE.finditer(clean):
        body = _node_body(clean, clean.index("{", m.end() - 1))
        name = m.group("label")
        reg = _REG_PROP.search(body)
        if not reg:
            skipped.append(f"{name}: no parseable `reg` (fdt_parse_hart_id fails)")
            continue
        hartid = int(reg.group("value"), 0)
        if hartid >= SBI_HARTMASK_MAX_BITS:
            skipped.append(f"{name}: hartid {hartid} >= SBI_HARTMASK_MAX_BITS")
            continue
        status = _STATUS_PROP.search(body)
        if status and not status.group("value").startswith(("okay", "ok")):
            skipped.append(f"{name}: status = \"{status.group('value')}\" (not enabled)")
            continue
        counted += 1
    return counted, skipped


def config_sw_harts(pkg: Path) -> int | None:
    """S = NrCores x NrHarts from an RTL config package, or None."""
    try:
        fields = {
            m.group("name"): int(m.group("value"))
            for m in _CFG_FIELD.finditer(pkg.read_text(encoding="utf-8"))
        }
    except OSError:
        return None
    if "NrCores" not in fields or "NrHarts" not in fields:
        return None
    return fields["NrCores"] * fields["NrHarts"]


def enforce_hart_count(dts: Path, expect: int, origin: str) -> None:
    """Fail the DTB build when the DTS would give OpenSBI the wrong plat_hc."""
    counted, skipped = count_opensbi_harts(dts.read_text(encoding="utf-8"))
    for reason in skipped:
        print(f"[dts_to_dtb] cpu@ not counted by OpenSBI -- {reason}")
    if counted == expect:
        print(
            f"[dts_to_dtb] hart count OK: {counted} countable cpu@ node(s) "
            f"== {origin} (plat_hc will be {counted})"
        )
        return
    print(
        f"[dts_to_dtb] ERROR: {dts} gives OpenSBI {counted} countable cpu@ "
        f"node(s) but {origin} is {expect}.\n"
        f"[dts_to_dtb] platform.hart_count (plat_hc) is the FDT walk's only "
        f"durable output; a mismatch is not diagnosed by firmware and surfaces "
        f"as a hart that never leaves the HSM wait, or an interrupt delivered "
        f"to a context that does not exist.\n"
        f"[dts_to_dtb] Fix the DTS cpu@ nodes or the config package so the two "
        f"agree, or pass --no-hart-count-check to bypass.",
        file=sys.stderr,
    )
    raise SystemExit(4)


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


def sweep_hart_counts(repo: Path) -> int:
    """Check every mapped DTS against its package. Returns a process exit code.

    Standalone form of the R11 contract, so the pairing is verifiable without
    building a DTB (the per-build check only covers the one DTS being compiled).
    """
    bad = 0
    for dts_name, pkg_name in sorted(DTS_CONFIG_PKG.items()):
        dts = repo / "corev_apu" / "bootrom" / dts_name
        pkg = repo / "core" / "include" / pkg_name
        if not dts.is_file() or not pkg.is_file():
            print(f"[dts_to_dtb] SKIP {dts_name}: missing {dts if not dts.is_file() else pkg}")
            continue
        counted, _ = count_opensbi_harts(dts.read_text(encoding="utf-8"))
        expect = config_sw_harts(pkg)
        if expect is None:
            print(f"[dts_to_dtb] SKIP {dts_name}: no NrCores/NrHarts in {pkg_name}")
            continue
        if counted == expect:
            print(f"[dts_to_dtb] OK       {dts_name:26s} cpu@={counted} S={expect}")
        else:
            bad += 1
            print(
                f"[dts_to_dtb] MISMATCH {dts_name:26s} cpu@={counted} S={expect} "
                f"({pkg_name})"
            )
    if bad:
        print(
            f"[dts_to_dtb] {bad} DTS/config pair(s) disagree on the software hart "
            f"count. plat_hc is the FDT walk's only durable output (R11); a "
            f"mismatch is never diagnosed by firmware.",
            file=sys.stderr,
        )
    return 4 if bad else 0


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
    ap.add_argument(
        "--expect-harts",
        type=int,
        default=None,
        help="countable cpu@ nodes OpenSBI must find (default: NrCores*NrHarts "
        "from --config-pkg)",
    )
    ap.add_argument(
        "--config-pkg",
        type=Path,
        default=None,
        help="RTL config package to read NrCores/NrHarts from "
        "(default: core/include/g6lc64_smt2_config_pkg.sv)",
    )
    ap.add_argument(
        "--no-hart-count-check",
        action="store_true",
        help="skip the plat_hc / cpu@ count contract (R11)",
    )
    ap.add_argument(
        "--check-all-harts",
        action="store_true",
        help="sweep every DTS_CONFIG_PKG pair and exit non-zero on any mismatch "
        "(no DTB is produced)",
    )
    args = ap.parse_args()
    if args.check_all_harts:
        return sweep_hart_counts(Path(__file__).resolve().parents[3])
    repo = Path(__file__).resolve().parents[3]
    dts = args.input or (repo / "corev_apu" / "bootrom" / "ariane-smt2.dts")
    if not dts.is_file():
        print(f"missing {dts}", file=sys.stderr)
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if not args.no_closeout_check:
        dts = enforce_closeout(dts, args.output, strip=args.strip_closeout)
    if not args.no_hart_count_check:
        expect, origin = args.expect_harts, "--expect-harts"
        if expect is None:
            pkg = args.config_pkg
            if pkg is None:
                mapped = DTS_CONFIG_PKG.get(dts.name)
                pkg = repo / "core" / "include" / mapped if mapped else None
            if pkg is None:
                # Visible, not silent: an unstated expectation is an oracle that
                # cannot say FAIL, and guessing the package would be worse.
                print(
                    f"[dts_to_dtb] hart count check SKIPPED: {dts.name} is not in "
                    f"DTS_CONFIG_PKG (pass --expect-harts or --config-pkg, or add "
                    f"the mapping)"
                )
            else:
                expect = config_sw_harts(pkg)
                origin = f"NrCores*NrHarts from {pkg.name}"
                if expect is None:
                    print(
                        f"[dts_to_dtb] hart count check SKIPPED: could not read "
                        f"NrCores/NrHarts from {pkg}"
                    )
        if expect is not None:
            enforce_hart_count(dts, expect, origin)
    if shutil.which("dtc"):
        compile_with_dtc(dts, args.output)
    else:
        compile_with_fdt(dts, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
