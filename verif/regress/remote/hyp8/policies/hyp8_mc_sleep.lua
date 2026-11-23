-- Copyright 2026 Etienne Cimon
-- SPDX-License-Identifier: MIT
-- Sleep-gated MC policy: enables MT-safe sink-domain clock-skip deferral
-- (so sleeping cores skip their global-clock-tainted backend comb logic),
-- DFG bitwise-mux packing, and checked row/mux/column C++ overlays.
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
    end
end
