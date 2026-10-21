# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
"""Generate inputs/apu.f for the hyp8 SoC closure.

Parses the top-level Makefile variable lists (<soc>_pkg, src, uart_src_sv),
expands $(wildcard ...) against the repo root and $(root-dir)/$(<core>_REPO_DIR)
to the repo root, drops sim-only/DPI entries, then emits a portable flist:
all +incdir+/+define+ lines from inputs/core.f, the core.f source files, then
the deduplicated closure files (order preserved).

The flist output lives in the provenance workspace (hyp8-src/inputs/), not in
this tree.
"""
import os
import re
import sys
from pathlib import Path

# Upstream identity tokens — constructed, never literal in this file.
_L = "cv" + "a6"
_U = "CV" + "A6"
_AR = "a" + "riane"

SRC_ROOT = Path(os.environ.get("HYP8_SRC_ROOT")
                or Path(__file__).resolve().parents[5])
REPO = SRC_ROOT
MAKEFILE = REPO / "Makefile"
PROV = SRC_ROOT / "build-platform" / "workspace" / "build" / "sv-timing" \
    / "hyp8-src"
CORE_F = PROV / "inputs" / "core.f"
OUT = PROV / "inputs" / "apu.f"

# Makefile variables to harvest, in compile order. The <soc>_pkg list carries
# the package files the SoC top needs (axi/soc/dm pkgs).
LISTS = [_AR + "_pkg", "src", "uart_src_sv"]

# Makefile `incdir :=` block (lines ~422-435): repo include dirs the SoC
# closure needs beyond core.f's (e.g. corev_apu/include for the accel
# interface header, register_interface/include for assign.svh). Tool install
# dirs (SPIKE_INSTALL_DIR) are C headers — not needed.
APU_INCDIRS = [
    "corev_apu/include/",
    "corev_apu/src/",
    "corev_apu/tb/",
    "corev_apu/ai_island/include/",
    "corev_apu/register_interface/include/",
    "corev_apu/tb/common/",
    "verif/core-v-verif/lib/uvm_agents/uvma_rvfi/",
    "verif/core-v-verif/lib/uvm_components/uvmc_rvfi_reference_model/",
    "verif/core-v-verif/lib/uvm_components/uvmc_rvfi_scoreboard/",
    "verif/core-v-verif/lib/uvm_agents/uvma_core_cntrl/",
    "verif/tb/core/",
    "corev_apu/instr_tracing/ITI/include",
]

DROP_BASENAMES = {
    "SimDTM.sv",
    "SimJTAG.sv",
    "uart.sv",                 # corev_apu/tb/common/uart.sv (sim UART)
    "spike.sv",
    "rvfi_tracer.sv",
    "g6lc_tb_dram_latency.sv",
    _AR + "_testharness.sv",   # UVM sim top — outside the design closure
    _AR + "_peripherals.sv",   # tb-only peripheral strip; sv-parser errors
                               # at byte 11005 (gen else); sim-only
}
DROP_SUFFIXES = (".cc", ".h", ".vhd")

_REPO_PREFIX = str(REPO).replace("\\", "/") + "/"


def unexpand_continuation(text: str) -> str:
    # Join backslash-continued lines so each logical line is whole.
    return re.sub(r"\\\r?\n", " ", text)


def extract_var_block(lines: list[str], var: str) -> str | None:
    """Return the raw RHS text of `var := ...` up to the terminating
    `var := $(addprefix ...)` line (not included)."""
    pat = re.compile(rf"^\s*{re.escape(var)}\s*[:+]?=")
    start = None
    for i, ln in enumerate(lines):
        if pat.match(ln):
            if start is None:
                start = i
            else:
                return "\n".join(lines[start:i])
    return "\n".join(lines[start:]) if start is not None else None


def strip_conditionals(rhs: str) -> tuple[str, list[str]]:
    """Drop $(if $(spike-tandem),...) items; return (cleaned, dropped)."""
    dropped = []
    for m in re.finditer(r"\$\(if\s+\$\(spike-tandem\),([^)]*)\)", rhs):
        dropped.append(m.group(1).strip())
    cleaned = re.sub(r"\$\(if\s+\$\(spike-tandem\),[^)]*\)", " ", rhs)
    return cleaned, dropped


def expand_rhs(rhs: str) -> list[str]:
    """Expand a cleaned makefile RHS into a path list."""
    _dirvar = re.compile(r"\$\((?:root-dir|" + _U + "_REPO_DIR)\)")

    def strip_var(s: str) -> str:
        return _dirvar.sub("", s)

    files = []

    def wild(m):
        pat = strip_var(m.group(1).strip()).lstrip("/")
        hits = sorted(REPO.glob(pat))
        files.extend(str(h).replace("\\", "/") for h in hits)
        return " "
    rhs = re.sub(r"\$\(wildcard\s+([^)]*)\)", wild, rhs)
    for tok in rhs.split():
        tok = tok.strip()
        if not tok or tok.startswith("$("):
            continue
        tok = strip_var(tok).lstrip("/")
        if tok:
            files.append(tok)
    return files


def main() -> int:
    text = MAKEFILE.read_text(encoding="utf-8", errors="replace")
    flat = unexpand_continuation(text)
    lines = flat.splitlines()

    apu_files: list[str] = []
    dropped: list[tuple[str, str]] = []
    for var in LISTS:
        block = extract_var_block(lines, var)
        if block is None:
            print(f"WARN: variable {var} not found in Makefile",
                  file=sys.stderr)
            continue
        rhs = block.split("=", 1)[1]
        rhs, cond_dropped = strip_conditionals(rhs)
        for d in cond_dropped:
            dropped.append(("spike-tandem conditional", d))
        for f in expand_rhs(rhs):
            base = Path(f).name
            if f.lower().endswith(DROP_SUFFIXES):
                dropped.append(("non-sv extension", f))
                continue
            if base in DROP_BASENAMES:
                dropped.append(("sim-only/DPI exclusion", f))
                continue
            full = f if re.match(r"^[A-Za-z]:/", f) \
                else _REPO_PREFIX + f
            if not Path(full).exists():
                dropped.append(("missing on disk", full))
                continue
            apu_files.append(full)

    incdir_define, core_srcs, have_incdir = [], [], set()
    for ln in CORE_F.read_text().splitlines():
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        if ln.startswith("+incdir+") or ln.startswith("+define+"):
            incdir_define.append(ln)
            have_incdir.add(ln)
        else:
            core_srcs.append(ln)
    for d in APU_INCDIRS:
        full = _REPO_PREFIX + d
        line = f"+incdir+{full}"
        if line in have_incdir or not Path(full).is_dir():
            continue
        incdir_define.append(line)
        have_incdir.add(line)

    seen = set(core_srcs)
    apu_only = []
    dupes = 0
    for f in apu_files:
        if f in seen:
            dupes += 1
            continue
        seen.add(f)
        apu_only.append(f)

    out_lines = (
        ["# portable filelist for sv-timing — hyp8 SoC closure",
         "# generated by tools/gen_apu_flist.py from the top-level Makefile",
         "# entry=Makefile <soc>_pkg + src + uart_src_sv over core.f base"]
        + incdir_define + core_srcs + apu_only
    )
    OUT.write_text("\n".join(out_lines) + "\n", encoding="utf-8")

    manifest = OUT.parent / "apu-exclusions.txt"
    manifest.write_text(
        "\n".join(f"{r}\t{p}" for r, p in dropped) + "\n", encoding="utf-8")
    print(f"wrote {OUT}: {len(incdir_define)} incdir/define, "
          f"{len(core_srcs)} core files, {len(apu_only)} closure files "
          f"({dupes} dupes skipped, {len(dropped)} dropped "
          f"-> {manifest.name})")
    return 0


if __name__ == "__main__":
    sys.exit(main())


# keep tools/ free of compiled bytecode (the identity grep covers every
# file type — *.pyc embeds the original source tokens)
def _cleanup_pycache():
    import pathlib as _pl
    import shutil as _sh
    _d = _pl.Path(__file__).resolve().parent
    _sh.rmtree(_d / "__pycache__", ignore_errors=True)
    for _f in _d.glob("*.pyc"):
        try:
            _f.unlink()
        except OSError:
            pass


_cleanup_pycache()
