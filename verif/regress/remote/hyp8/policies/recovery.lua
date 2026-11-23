-- Copyright 2026 Etienne Cimon
-- SPDX-License-Identifier: MIT
-- Explicit Lua equivalent of the measured two-lane MC recovery profile.
local cmd = " " .. model.command .. " "
assert(cmd:find(" -DG6LC_HYP8_MC ", 1, true) and cmd:find(" --threads 2 ", 1, true),
       "recovery profile requires the two-lane MC model")
for _, suffix in ipairs({"", "__pi[0-9]*"}) do
    local class = model.prefix .. "_g6lc_core" .. suffix
    select_rule(class, "u_recover__DOT__", "packed-rows")
    select_rule(class, "u_recover__DOT__", "tiled-columns")
end
