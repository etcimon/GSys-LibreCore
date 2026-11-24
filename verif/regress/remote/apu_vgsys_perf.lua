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
--   => circular-age-compare is *not* emitted (no OoO age logic exists);
--      scatter-eq-mask maps to CAM tag compares (objmem ec_tag_q/dc_id_q,
--      objtab hit_slot), strided/tiled columns map to bit-sliced tables and
--      page walks, packed rows/predicates map to the wide shader/lane and
--      push-bus datapaths, wide-mux-guard maps to lane/blend conditionals.
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
-- pass itself only rewrites the exact patterns it recognises — so a broad
-- class glob plus a distinctive signal marker is safe.  has_source() gates on
-- the .sv basename actually being in this build's verFiles, so a bench that
-- omits a unit simply skips its rules.
-- ---------------------------------------------------------------------------
if model.phase == "overlay" then
    -- One glob covering every generated translation unit; the marker (not the
    -- glob) selects the hot logic, mirroring how hyp8 uses prefix_g6lc_core*.
    local cls = model.prefix .. "_*"

    -- Object table / directory cache: CAM tag compares.
    --   objmem: ec_tag_q[i] == eg_idx_q  and  dc_id_q[set][way] == ot_req_q.id
    --   objtab: hit_slot_q / walk_q / par_slot_q / alloc_bucket_q slot fields.
    -- scatter-eq-mask collapses the 64-way tag-equality OR-mask; the slot
    -- fields are bit-sliced -> strided-bit-columns; the live/walk bit vectors
    -- are packed rows.  Highest-confidence data-path rules in the APU.
    if model.has_source("g6lc_apu_objmem.sv") or model.has_source("g6lc_apu_objtab.sv") then
        select_rule(cls, "ec_tag_q",   "scatter-eq-mask")
        select_rule(cls, "dc_id_q",    "strided-bit-columns")
        select_rule(cls, "hit_slot_q", "strided-bit-columns")
        select_rule(cls, "walk_q",     "packed-rows")
        select_rule(cls, "keep_v_q",   "packed-predicates")
    end

    -- Rasterizer: 2048-bit primitive/shader push buses and scratch state.
    -- push_i / sh_push_o are the widest single assignments in the model ->
    -- packed-rows; the per-lane push_n_q popcounts and scratch_base index
    -- arithmetic are column/predicate shaped.
    if model.has_source("g6lc_apu_rast.sv") then
        select_rule(cls, "push_i",      "packed-rows")
        select_rule(cls, "sh_push",     "packed-rows")
        select_rule(cls, "push_n_q",    "packed-predicates")
        select_rule(cls, "scratch_base","tiled-columns")
        select_rule(cls, "sh_slot",     "strided-bit-columns")
    end

    -- Vertex front-end / shader wave: fpnew FPU pipes (i_fma/i_cvt/i_dsq/
    -- i_nc __PVT__), lane x compute-unit generate grid, inp_pipe_ready valid
    -- masks and lzc sel_nodes priority vectors.  These are the graphics FP
    -- hot path; packed-predicates eats the valid&~(broadcast&veto) masks and
    -- tiled/strided columns eat the lane-strided select vectors.
    if model.has_source("g6lc_apu_vnfront.sv") or model.has_source("g6lc_apu_vnpump.sv")
       or model.has_source("g6lc_apu_vnrep.sv") or model.has_source("g6lc_apu_vndec.sv") then
        select_rule(cls, "inp_pipe_ready", "packed-predicates")
        select_rule(cls, "sel_nodes",      "tiled-columns")
        select_rule(cls, "__PVT__",        "packed-rows")
        select_rule(cls, "g_lane__BRA__",  "wide-mux-guard")
    end

    -- Command processor / DMA / object pay: descriptor tag/index vectors and
    -- the doneq push/pop counters -> packed rows and bit columns.
    if model.has_source("g6lc_apu_cmdexec.sv") or model.has_source("g6lc_apu_cmdrec.sv")
       or model.has_source("g6lc_apu_doneq.sv") or model.has_source("g6lc_apu_dma_read.sv")
       or model.has_source("g6lc_apu_dma_write.sv") then
        select_rule(cls, "push_i",   "packed-rows")
        select_rule(cls, "push_n_o", "packed-predicates")
    end

    -- Page-table walker: PTE tag/permission bit fields walked per level ->
    -- strided bit columns and tiled columns.
    if model.has_source("g6lc_apu_vgpages.sv") then
        select_rule(cls, "pte",      "strided-bit-columns")
        select_rule(cls, "walk",     "tiled-columns")
    end

    -- tc_sram register files / FPnew leaf pipes present in every APU bench:
    -- wide storage arrays -> packed rows; the fpnew parameterised classes are
    -- matched by the __PVT__ marker above.
    if model.has_source("tc_sram.sv") then
        select_rule(cls, "q_din",    "packed-rows")
        select_rule(cls, "q_dout",   "packed-rows")
    end

    -- Assertion cones: universal to every --assert Verilator model.  KNOWN_
    -- MARKERS already carries both tokens so has_marker() is reliable here.
    -- assert-guard-hoist lifts the assertOn() check out of the match vector;
    -- bit-exact and ~free under a noassert build.  (assert-cone-gate is left
    -- out: it is experimental, needs the whole-class dead_vars precompute, and
    -- a 0-hit would sink the overlay — revisit once a real Mdir confirms it.)
    if model.has_marker("->assertOn()") or model.has_marker("VL_ONEHOT") then
        select_rule(cls, "->assertOn()", "assert-guard-hoist")
        select_rule(cls, "VL_ONEHOT",    "assert-guard-hoist")
    end

    -- Deliberately absent: circular-age-compare (hyp8 OoO __Vfunc_ooo_age_
    -- older__ only), and any hyp8 instance markers (u_recover__DOT__,
    -- i_sb_*, i_rob__DOT__, i_release__DOT__, i_vio_red__DOT__,
    -- i_stl_red__DOT__, i_sb_lifecycle__DOT__) — none exist in CVA6/Venus.
end
