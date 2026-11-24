-- Copyright 2026 Etienne Cimon
-- SPDX-License-Identifier: MIT
-- Sleep-gated MC policy: enables MT-safe sink-domain clock-skip deferral
-- (so sleeping cores skip their global-clock-tainted backend comb logic),
-- DFG bitwise-mux packing, and checked Lua-driven C++/SIMD overlays.
-- Flexible across thread counts and both g6lc64_hyp8_mc_sleep / g6lc64_hyp8_mc.
if model.has_define("G6LC_HYP8_MC_SLEEP") then
    select_clock_skip("sink", "required")
else
    select_clock_skip("sink", "opportunistic")
end
select_verilator_flag("-fdfg-peephole-pack-bitwise-mux")

if model.phase == "overlay" then
    for _, suffix in ipairs({"", "__pi[0-9]*"}) do
        local cls = model.prefix .. "_g6lc_core" .. suffix
        select_rule(cls, "u_recover__DOT__", "packed-rows")
        select_rule(cls, "u_recover__DOT__", "packed-mux-rows")
        select_rule(cls, "u_recover__DOT__", "tiled-columns")
        if model.has_marker("i_release__DOT__t1_alloc_older") then
            select_rule(cls, "i_release__DOT__t1_alloc_older", "packed-rows")
        end
        if model.has_marker("i_sb_commit_bundle__DOT__mem_col") then
            select_rule(cls, "i_sb_commit_bundle__DOT__mem_col", "strided-bit-columns")
        end
        if model.has_marker("i_vio_red__DOT__age_col") then
            select_rule(cls, "i_vio_red__DOT__age_col", "strided-bit-columns")
        end
        if model.has_marker("__Vfunc_ooo_age_older__") then
            select_rule(cls, "__Vfunc_ooo_age_older__", "circular-age-compare")
        end
        if model.has_marker("i_stl_red__DOT__dwait_d") then
            select_rule(cls, "i_stl_red__DOT__dwait_d", "scatter-eq-mask")
        end
        if model.has_marker("i_rob__DOT__rob_d") then
            select_rule(cls, "i_rob__DOT__rob_d", "wide-mux-guard")
        end
        if model.has_marker("i_sb_lifecycle__DOT__mem_n") then
            select_rule(cls, "i_sb_lifecycle__DOT__mem_n", "wide-mux-guard")
        end
    end
end
