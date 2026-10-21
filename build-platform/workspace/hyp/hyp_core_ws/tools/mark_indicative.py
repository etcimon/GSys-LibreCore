# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
"""Stamp every hand-written analysis/*.md with the indicative-status block for
the 8 FO4 / 5 GHz goal and generate analysis/coverage.md (redesign module ->
analysis section, fresh deciding value D from analysis/cut-ledger.md).

Idempotent: a file that already carries the status block is left alone.
"""
from pathlib import Path

WS = Path(__file__).resolve().parent.parent
AN = WS / "analysis"
MARK = "<!-- hyp8-status -->"

STATUS = f"""{MARK}
> **Status: indicative, subject to further information.** Goal: **8 FO4 per
> cycle (5 GHz nameplate at `fo4_ps = 20`, margin 0.2)**. Every FO4 figure,
> stage count and kernel size here is a hypothesis read from the original RTL,
> the prior boards and the sv-timing reports (`reports/board.md`,
> `cut_surface.md`, `bottlenecks.md`, `carry_over.md`, `propagation.md`,
> `refusals.md`); the fresh 8-FO4 board's deciding value `D` is in
> `analysis/cut-ledger.md` and `analysis/coverage.md`. The cut-minimization
> protocol (`analysis/cut_minimization.md`) takes precedence over any planned
> cut listed below. Nothing here has been linted, simulated or measured on a
> board; a rewritten file may follow this analysis, the emitted sv-timing file
> (as-is or adapted), or the original RTL, as `coverage.md` records.

"""

# redesign module -> (analysis file, section/anchor hint)
MAP = {
    "wt_dcache_wbuffer": ("wt_dcache_wbuffer.md", ""),
    "frontend": ("frontend.md", ""),
    "g6lc_rename": ("g6lc_rename.md", ""),
    "g6lc_iq": ("g6lc_iq.md", ""),
    "g6lc_lsq": ("g6lc_lsq.md", ""),
    "multiplier": ("execute.md", "multiplier"),
    "scoreboard": ("scoreboard.md", ""),
    "g6lc_ooo_dispatch": ("t1_rest.md", "g6lc_rob (49.2), g6lc_ooo_dispatch"),
    "fpnew_cast_multi": ("t1_rest.md", "fpu_wrap (T2) and fpnew_* (parameters)"),
    "fpnew_fma": ("t1_rest.md", "fpu_wrap (T2) and fpnew_* (parameters)"),
    "alu": ("execute.md", "alu"),
    "store_buffer": ("store_buffer.md", ""),
    "csr_regfile": ("csr_regfile.md", ""),
    "aes": ("t1_rest.md", "serdiv … aes"),
    "g6lc_loop_buffer": ("tier2_tier3.md", "g6lc_loop_buffer"),
    "g6lc_bp_ckpt": ("t1_rest.md", "g6lc_bp_ckpt"),
    "g6lc_rob": ("t1_rest.md", "g6lc_rob"),
    "branch_unit": ("execute.md", "branch_unit"),
    "issue_read_operands": ("execute.md", "issue_read_operands"),
    "g6lc_prf": ("tier2_tier3.md", "g6lc_prf"),
    "serdiv": ("t1_rest.md", "serdiv"),
    "decoder": ("t1_rest.md", "decode group"),
    "instr_queue": ("frontend.md", "instr_queue (elastic)"),
    "wt_dcache_mem": ("tier2_tier3.md", "wt_dcache_mem"),
    "store_unit": ("tier2_tier3.md", "load_store_unit, store_unit"),
    "wt_dcache_missunit": ("t1_rest.md", "wt_dcache_missunit"),
    "load_unit": ("t1_rest.md", "load_unit"),
    "perf_counters": ("coverage.md", "gap: perf_counters — counters/events split low/high with registered carry; event OR trees registered (value path, rank 4)"),
    "g6lc_regfile": ("tier2_tier3.md", "g6lc_regfile"),
    "g6lc_fifo_v3": ("tier2_tier3.md", "fifo_v3/g6lc_fifo_v3 → g6lc_hyp_fifo"),
    "g6lc_mmu": ("t1_rest.md", "g6lc_tlb … g6lc_mmu"),
    "g6lc_tlb": ("t1_rest.md", "g6lc_tlb"),
    "g6lc_bp_loop": ("tier2_tier3.md", "g6lc_bp_loop"),
    "g6lc_icache": ("t1_rest.md", "g6lc_icache"),
    "instr_realign": ("t1_rest.md", "decode group (instr_realign)"),
    "g6lc_core": ("coverage.md", "gap: g6lc_core top — wiring only; its own paths are glue muxes (RVFI/perf/debug fan-in) → register the observer fan-in (rank 4); threads HypCfg and the new seams"),
    "g6lc_memdep": ("tier2_tier3.md", "g6lc_memdep"),
    "fpu_wrap": ("t1_rest.md", "fpu_wrap"),
    "ex_stage": ("execute.md", "ex_stage"),
    "commit_stage": ("tier2_tier3.md", "commit_stage"),
    "g6lc_ptw": ("t1_rest.md", "g6lc_ptw"),
    "ras": ("tier2_tier3.md", "ras"),
    "g6lc_bp_statcor": ("tier2_tier3.md", "g6lc_bp_*"),
    "g6lc_bp_ittage": ("tier2_tier3.md", "g6lc_bp_*"),
    "lsu_bypass": ("tier2_tier3.md", "lsu_bypass"),
    "csr_buffer": ("tier2_tier3.md", "csr_buffer"),
    "wt_axi_adapter": ("tier2_tier3.md", "axi_adapter …"),
    "g6lc_bp_tage": ("tier2_tier3.md", "g6lc_bp_*"),
    "wt_dcache_ctrl": ("tier2_tier3.md", "wt_dcache_ctrl"),
    "mult": ("execute.md", "mult.sv owner table"),
    "g6lc_way_predictor": ("tier2_tier3.md", "g6lc_way_predictor"),
    "fpnew_noncomp": ("tier2_tier3.md", "fpnew_noncomp (parameters)"),
    "exp_backoff": ("tier2_tier3.md", "exp_backoff"),
    "compressed_decoder": ("t1_rest.md", "decode group"),
    "fpnew_opgroup_multifmt_slice": ("t1_rest.md", "fpnew_* (parameters)"),
    "g6lc_ftq": ("tier2_tier3.md", "g6lc_ftq"),
    "rr_arb_tree": ("tier2_tier3.md", "rr_arb_tree"),
    "pmp_entry": ("tier2_tier3.md", "pmp"),
    "fpnew_opgroup_fmt_slice": ("tier2_tier3.md", "fpnew_* (parameters)"),
    "pmp": ("tier2_tier3.md", "pmp"),
    "instr_scan": ("tier2_tier3.md", "instr_scan"),
    "fpnew_classifier": ("tier2_tier3.md", "fpnew_classifier"),
    "g6lc_bp_ghist": ("tier2_tier3.md", "g6lc_bp_*"),
    "raw_checker": ("tier2_tier3.md", "raw_checker"),
    "g6lc_shared_tlb": ("t1_rest.md", "g6lc_shared_tlb"),
    "axi_shim": ("tier2_tier3.md", "axi_shim"),
    "g6lc_rvfi_probes": ("tier2_tier3.md", "g6lc_rvfi_probes"),
    "id_stage": ("t1_rest.md", "decode group"),
    "fpnew_top": ("t1_rest.md", "fpnew_* (parameters)"),
    "g6lc_bp_tage_table": ("tier2_tier3.md", "g6lc_bp_*"),
    "g6lc_fdip": ("tier2_tier3.md", "g6lc_fdip"),
    "lfsr": ("coverage.md", "gap: lfsr — a T3 vendor cell; g6lc_hyp_lfsr with the feedback XOR tree registered once (rank 4)"),
    "pmp_data_if": ("tier2_tier3.md", "pmp"),
    "wt_dcache": ("coverage.md", "gap: wt_dcache wrapper — T3 at 9.2: the port muxing between ctrl/missunit/wbuffer; one registered boundary on the response mux (rank 2: the response is already registered in wt_dcache_mem)"),
    "lzc": ("tier2_tier3.md", "lzc/popcount"),
    "controller": ("coverage.md", "gap: controller — T3 at 8.5 (COPY→ADAPT in the plan): the flush/drain decision; counted drain for the deeper pipes, flush request registered from the commit bundle (rank 2)"),
}


def stamp(path: Path) -> bool:
    t = path.read_text(encoding="utf8")
    if MARK in t:
        return False
    lines = t.split("\n")
    if lines and lines[0].startswith("# "):
        new = lines[0] + "\n\n" + STATUS + "\n".join(lines[1:])
    else:
        new = STATUS + t
    path.write_text(new, encoding="utf8")
    return True


def main():
    stamped = []
    for p in sorted(AN.glob("*.md")):
        if p.name in ("cut-ledger.md", "cut-ledger.apu.md", "coverage.md"):
            continue
        if stamp(p):
            stamped.append(p.name)
    # coverage
    rows = {}
    for ln in (AN / "cut-ledger.md").read_text(encoding="utf8").splitlines():
        if not ln.startswith("|") or "---" in ln or "decision" in ln:
            continue
        c = [x.strip() for x in ln.strip().strip("|").split("|")]
        rows[c[0]] = c
    out = [
        "# coverage.md — redesign modules → analysis sections (fresh 8-FO4 board)",
        "",
        STATUS.rstrip(),
        "",
        "Provenance mode per rewritten file is decided in Phase 3 and recorded in "
        "`notes/decisions.md`: **AS-IS** (the emitted sv-timing file copied; closing "
        "modules), **ADAPTED** (the emitted file is the base, local edits for new "
        "latencies/seams — logic of the original RTL preserved verbatim where untouched), "
        "**REWRITTEN** (new file; the original RTL is the functional reference, the emit "
        "indicates where sv-timing found chains/refusals).",
        "",
        "| module | decision | D | basis | min_cuts_est | analysis | section / note |",
        "|---|---|---|---|---|---|---|",
    ]
    gaps = []
    for mod, c in rows.items():
        dec = c[1]
        if not dec.startswith("REDESIGN"):
            continue
        f, sec = MAP.get(mod, ("coverage.md", "GAP — no analysis yet"))
        if f == "coverage.md":
            gaps.append((mod, sec))
        out.append(f"| {mod} | {dec} | {c[2]} | {c[3]} | {c[4]} | {f} | {sec} |")
    out += ["", "## Gaps filled here (indicative one-liners)", ""]
    for mod, sec in gaps:
        out.append(f"- **{mod}**: {sec}")
    out += ["", f"- analysis files stamped this run: {', '.join(stamped) or '(none, already stamped)'}"]
    (AN / "coverage.md").write_text("\n".join(out) + "\n", encoding="utf8")
    print("stamped:", stamped)
    print("coverage rows:", sum(1 for c in rows.values() if c[1].startswith('REDESIGN')), "gaps:", len(gaps))


if __name__ == "__main__":
    main()


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
