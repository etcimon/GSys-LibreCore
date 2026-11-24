-- Copyright 2026 Etienne Cimon
-- SPDX-License-Identifier: MIT
-- Comprehensive Lua-driven Sentinel/DFG & clock-skip policy for Hyp8 MC builds
-- (g6lc64_hyp8_mc and g6lc64_hyp8_mc_sleep, any thread count).
--
-- Pre-verilate phase declares Verilator flags (sink-domain clock-skip,
-- bitwise-mux DFG peephole, sentinel DFG observer).
-- Overlay phase inspects model markers & sentinel DFG counts and dispatches
-- only checked, bit-exact SIMD/algebraic lowering passes whose target markers
-- are present in the generated TUs.

if model.has_define("G6LC_HYP8_MC_SLEEP") then
    select_clock_skip("sink", "required")
else
    select_clock_skip("sink", "opportunistic")
end
select_verilator_flag("-fdfg-peephole-pack-bitwise-mux")

-- Model-specific sentinel DFG probes (recorded in manifest.json).
select_sentinel_probe("strided_columns", "strided_column_tile", "*g6lc_core*")
select_sentinel_probe("age_compares", "circular_age_compare", "*g6lc_core*")
select_sentinel_probe("scatter_masks", "scatter_eq_mask", "*g6lc_core*")
select_sentinel_probe("wide_muxes", "wide_mux_guard", "*g6lc_core*")

if model.phase == "overlay" then
    for _, suffix in ipairs({"", "__pi[0-9]*"}) do
        local cls = model.prefix .. "_g6lc_core" .. suffix

        -- Rename/recovery masked rows, complemented-enable mux rows, and tiled columns
        if model.has_marker("u_recover__DOT__") then
            select_rule(cls, "u_recover__DOT__", "packed-rows")
            select_rule(cls, "u_recover__DOT__", "packed-mux-rows")
            select_rule(cls, "u_recover__DOT__", "tiled-columns")
        end

        -- LSQ release masked rows (t1_alloc_older)
        if model.has_marker("i_release__DOT__t1_alloc_older") then
            select_rule(cls, "i_release__DOT__t1_alloc_older", "packed-rows")
        end

        -- Arbitrary-bit-stride column transposes (mem_col stride=522, age_col stride=40, gen_gm.col)
        if model.has_marker("i_sb_commit_bundle__DOT__mem_col") then
            select_rule(cls, "i_sb_commit_bundle__DOT__mem_col", "strided-bit-columns")
        end
        if model.has_marker("i_vio_red__DOT__age_col") then
            select_rule(cls, "i_vio_red__DOT__age_col", "strided-bit-columns")
        end
        if model.has_marker("gen_gm__BRA__") then
            select_rule(cls, "gen_gm__BRA__", "strided-bit-columns")
        end

        -- Circular age comparisons (vio_age_d, gen_unres_e.uvec, unnamedblk12.ou, colder/solder)
        if model.has_marker("__Vfunc_ooo_age_older__") then
            select_rule(cls, "__Vfunc_ooo_age_older__", "circular-age-compare")
        end

        -- 64-bit scatter-OR equality bitmasks (i_stl_red.dwait_d)
        if model.has_marker("i_stl_red__DOT__dwait_d") then
            select_rule(cls, "i_stl_red__DOT__dwait_d", "scatter-eq-mask")
        end

        -- Wide masked ternary condition hoisting (i_rob.rob_d, i_sb_lifecycle.mem_n)
        if model.has_marker("i_rob__DOT__rob_d") then
            select_rule(cls, "i_rob__DOT__rob_d", "wide-mux-guard")
        end
        if model.has_marker("i_sb_lifecycle__DOT__mem_n") then
            select_rule(cls, "i_sb_lifecycle__DOT__mem_n", "wide-mux-guard")
        end

        -- Hoist assertOn() outside pure assertion condition checks
        -- (100% identical when assertions are on; zero cost under +verilator+noassert).
        if model.has_marker("->assertOn()") then
            select_rule(cls, "->assertOn()", "assert-guard-hoist")
        elseif model.has_marker("VL_ONEHOT") then
            select_rule(cls, "VL_ONEHOT", "assert-guard-hoist")
        end
    end
end
