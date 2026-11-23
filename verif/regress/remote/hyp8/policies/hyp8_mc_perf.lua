-- Copyright 2026 Etienne Cimon
-- SPDX-License-Identifier: MIT
-- High-throughput Hyp8 MC policy (works for both g6lc64_hyp8_mc and
-- g6lc64_hyp8_mc_sleep, any thread count). Enables sink-domain clock-skip
-- opportunistically (covers BOOT_HOLD cores 1-3 and WFI sleep-gated cores)
-- plus packed masked rows, complemented-enable mux rows (t1_mk_s/t1_fmk_s),
-- and tiled columns.
select_clock_skip("sink", "opportunistic")
select_verilator_flag("-fdfg-peephole-pack-bitwise-mux")

if model.phase == "overlay" then
    for _, suffix in ipairs({"", "__pi[0-9]*"}) do
        local cls = model.prefix .. "_g6lc_core" .. suffix
        select_rule(cls, "u_recover__DOT__", "packed-rows")
        select_rule(cls, "u_recover__DOT__", "packed-mux-rows")
        select_rule(cls, "u_recover__DOT__", "tiled-columns")
    end
end
