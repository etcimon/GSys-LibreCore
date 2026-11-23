-- Copyright 2026 Etienne Cimon
-- SPDX-License-Identifier: MIT
-- Cfg-agnostic policy template: works for any LibreCore or third-party SV
-- design by inspecting recorded sources and build flags rather than pinning
-- a single target macro or thread count.
select_clock_skip("sink", "opportunistic")
select_verilator_flag("-fdfg-peephole-pack-bitwise-mux")

if model.phase == "overlay" then
    if model.has_source("g6lc_rename_recover.sv") then
        for _, suffix in ipairs({"", "__pi[0-9]*"}) do
            local cls = model.prefix .. "_g6lc_core" .. suffix
            select_rule(cls, "u_recover__DOT__", "packed-rows")
            select_rule(cls, "u_recover__DOT__", "packed-mux-rows")
            select_rule(cls, "u_recover__DOT__", "tiled-columns")
        end
    end
end
