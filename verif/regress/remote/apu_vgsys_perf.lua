-- Copyright 2026 Etienne Cimon
-- SPDX-License-Identifier: MIT
--
-- LibreCore APU / CVA6 + Venus Verilator tuning policy ("this sv build":
-- tb_g6lc_apu_* system benches — vgsys, vgtop, shwave, vnfront — and the
-- core//corev_apu RTL they elaborate).
--
-- Driven by the tracedb hot-path methodology (verif/regress/remote/hyp8/
-- tracedb: pc_sample + census ingest -> sqlite -> query).  The hyp8 database
-- is guest-PC focused and hyp8-only today; the *simulation-level* hot paths
-- that a Verilator .lua can act on are the generated-C++ structures the
-- g6lc_pack_* overlay passes rewrite, so this policy targets the RTL units
-- the APU/CVA6 profile actually exercises, gated by has_source()/has_marker()
-- and by the apply-time `marker in source` check in g6lc_hyp8_tuning.py.
--
-- RTL differences vs hyp8 that drive the rule selection:
--   hyp8  = OoO core: rename/recover (u_recover), ROB age (__Vfunc_ooo_age_
--           older__), LSQ release/commit-bundle columns, store->load fwd.
--   here  = CVA6 in-order core (scoreboard/decoder/execute/LSU/commit) +
--           Venus APU graphics (objtab/objmem CAM, rast wide push buses,
--           vnfront fpnew shader FPU, tc_sram register files, vgpages).
--   => circular-age-compare is *not* emitted (no OoO age logic exists).  The
--      other SIMD passes were *candidate*-mapped to CAM tag compares (objmem
--      ec_tag_q/dc_id_q, objtab hit_slot), rast push buses, fpnew lanes and
--      page walks -- but see the measured note below: none of them actually
--      match APU generated C++, so none are emitted.
--
-- Measured on the real tb_g6lc_apu_vgsys Mdir (131 DepSet TUs): every packed/
-- SIMD lowering pass reports 0 hits even with the marker gate removed -- the
-- g6lc_pack_* row/column/predicate/scatter/wmux transforms parse hyp8's OoO
-- codegen idioms (u_recover, ROB age, LSQ commit columns), which CVA6+Venus
-- does not emit.  Requesting them trips prepare()'s all-or-nothing
-- UnsupportedLayout and skips the whole overlay, so they are NOT selected
-- here.  The one checked transform that does match APU codegen is
-- assert-guard-hoist (948 hits): it lifts the assertOn() check out of the
-- VL_ONEHOT case-match vector -- bit-exact, and it skips the expensive match
-- eval entirely under +verilator+noassert / cold PGO.
--
-- Verilator performance references (tools/verilator/docs/guide/simulating.rst,
-- "Benchmarking & Optimization"): -O3 --x-assign fast --x-initial fast
-- --noassert for max throughput; OPT_FAST/OPT_SLOW/OPT_GLOBAL for the C++
-- tier (already emitted by apu_vlt_policy.py perf_flags); --prof-cfuncs +
-- gprof / --prof-exec + verilator_gantt for hot-path profiling; PGO; and
-- fixing UNOPTFLAT warnings (one user saw 60%).  This file only selects the
-- *g6lc overlay* surface (clock-skip, DFG peepholes, sentinel probes, and the
-- checked C++/SIMD lowering rules); the plain-Verilator flags live in
-- apu_vlt_policy.py.

-- ---------------------------------------------------------------------------
-- Pre-verilate / flag phase: safe on every g6lc-capable toolchain.  The fork
-- gates these by capability downstream; stock Verilator ignores nothing here
-- because select_verilator_flag is allowlisted and each flag is a no-op where
-- the pass is absent.
-- ---------------------------------------------------------------------------

-- Sink-domain clock-skip: lets idle/clock-gated APU banks (sram, queues)
-- skip their eval when no sink is active.  Opportunistic (not "required")
-- because the APU is not sleep-gated the way hyp8_mc_sleep is; a required
-- policy would hard-fail on a model that legitimately matches 0 groups.
select_clock_skip("sink", "opportunistic")

-- DFG peepholes that pack wide bit-vector ops into word/SWAR form.  These are
-- the same opt-in passes the hyp8 stack enables; on the APU's wide push buses
-- (rast [2047:0]), CAM tag vectors and fpnew lanes they are the highest-value
-- frontend transforms.  pack-bitwise-mux is the one hyp8 measured most.
select_verilator_flag("-fdfg-peephole-pack-bitwise-mux")
select_verilator_flag("-fdfg-peephole-pack-predicates")
select_verilator_flag("-fdfg-peephole-pack-byte-plane")
select_verilator_flag("-fdfg-peephole-guard-empty-mask")
select_verilator_flag("-fdfg-peephole-fuse-transpose-reductions")

-- NOTE: --no-assert is deliberately NOT selected.  The APU benches run with
-- --assert for correctness (it is what catches binding/provenance bugs); the
-- assert-* overlay rules below already strip the *dead* assertion cones while
-- keeping live checks.  For a pure-throughput profile build, add
-- select_verilator_flag("--no-assert") — it lands after --assert on the
-- command line and wins, per the docs' best-performance recipe.

-- ---------------------------------------------------------------------------
-- Sentinel probes: measure the DFG opportunities on this exact model so the
-- overlay counts in manifest.json can be sanity-checked against expectation.
-- targetGlob "*" matches every generated module (the probes are cheap and the
-- counts feed summary.sentinelProbeCounts).
-- ---------------------------------------------------------------------------
select_sentinel_probe("packed_rows",       "bit_select_concat",          "*")
select_sentinel_probe("tiled_columns",     "strided_column_tile",        "*")
select_sentinel_probe("scatter_masks",     "scatter_eq_mask",            "*")
select_sentinel_probe("wide_muxes",        "wide_mux_guard",             "*")
select_sentinel_probe("masked_transposes", "masked_transpose_reductions","*")
select_sentinel_probe("masked_reductions", "masked_reduction",           "*")

-- ---------------------------------------------------------------------------
-- Overlay phase: emit checked select_rule() lowering requests.  Each rule is
-- (class_glob, marker, pass); g6lc_hyp8_tuning.prepare() only applies a pass
-- to a TU when `marker` is a substring of that TU's generated .cpp, and the
-- pass itself only rewrites the exact patterns it recognises.  Because
-- prepare() is all-or-nothing (one 0-hit op -> UnsupportedLayout -> whole
-- overlay skipped), only transforms *measured* to hit on APU codegen are
-- requested; speculative signal-name markers are not worth the risk.
-- ---------------------------------------------------------------------------
if model.phase == "overlay" then
    -- Broad glob over every generated TU; the marker (not the glob) selects
    -- the transformable code, mirroring how hyp8 uses prefix_g6lc_core*.
    local cls = model.prefix .. "_*"

    -- assert-guard-hoist is the only checked transform measured to fire on
    -- APU codegen (see header note).  lower_assert_guard itself requires the
    -- literal "->assertOn()" substring, so that is the precise per-TU gate;
    -- "VL_ONEHOT" is emitted too so a TU that reaches the match vector via a
    -- differently-spelled assert still gets selected (the op dedups to one).
    -- KNOWN_MARKERS carries both tokens, so has_marker() is reliable.
    if model.has_marker("->assertOn()") or model.has_marker("VL_ONEHOT") then
        select_rule(cls, "->assertOn()", "assert-guard-hoist")
        select_rule(cls, "VL_ONEHOT",    "assert-guard-hoist")
    end

    -- Deliberately absent: every packed/SIMD pass (packed-rows, packed-mux-
    -- rows, packed-predicates, tiled-columns, wrapped-columns, strided-bit-
    -- columns, circular-age-compare, scatter-eq-mask, wide-mux-guard) and
    -- assert-cone-gate.  Measured 0 hits on the vgsys Mdir (see header); they
    -- parse hyp8 OoO idioms CVA6/Venus does not generate, and a single 0-hit
    -- op fails prepare()'s all-or-nothing check.  Revisit only with a fresh
    -- per-op hit measurement on a target Mdir that shows nonzero totals.
end
