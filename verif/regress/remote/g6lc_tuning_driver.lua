-- Copyright 2026 Etienne Cimon
-- SPDX-License-Identifier: MIT
-- Only the driver has I/O. Plugins declare a bounded plan once per build.
assert(_VERSION == "Lua 5.3" or _VERSION == "Lua 5.4", "expected Lua 5.3 or 5.4")
local count = 0
local vlt_flag_count = 0
local valid_passes = {
    ["packed-rows"] = true,
    ["packed-mux-rows"] = true,
    ["tiled-columns"] = true,
    ["wrapped-columns"] = true,
    ["packed-predicates"] = true,
}
local valid_vlt_flags = {
    ["-fclock-skip-sink"] = true,
    ["-fclock-skip"] = true,
    ["-fdfg-peephole-pack-byte-plane"] = true,
    ["-fdfg-peephole-pack-predicates"] = true,
    ["-fdfg-peephole-pack-bitwise-mux"] = true,
    ["-fdfg-peephole-guard-empty-mask"] = true,
    ["-fdfg-peephole-fuse-transpose-reductions"] = true,
}
local function select_rule(class_glob, marker, pass)
    assert(type(class_glob) == "string" and #class_glob > 0 and #class_glob <= 256
           and not class_glob:find("[^%w_*?%[%]%-]"), "invalid generated class glob")
    assert(type(marker) == "string" and #marker <= 256
           and not marker:find("[^ -~]"), "expected printable ASCII source marker")
    assert(valid_passes[pass], "unknown checked transform")
    count = count + 1
    assert(count <= 64, "too many rules")
    io.write(class_glob, "\t", marker, "\t", pass, "\n")
end
local function select_verilator_flag(flag)
    assert(type(flag) == "string" and valid_vlt_flags[flag], "unknown verilator optimization flag")
    vlt_flag_count = vlt_flag_count + 1
    assert(vlt_flag_count <= 16, "too many verilator flags")
    io.write("@vlt_flag\t", flag, "\n")
end
local function select_clock_skip(mode, policy)
    mode = mode or "sink"
    policy = policy or "opportunistic"
    assert(mode == "sink" or mode == "causal" or mode == "auto", "unknown clock-skip mode")
    assert(policy == "required" or policy == "opportunistic", "unknown clock-skip policy")
    local resolved = mode == "auto" and "sink" or mode
    local flag = resolved == "sink" and "-fclock-skip-sink" or "-fclock-skip"
    select_verilator_flag(flag)
    io.write("@clock_skip\t", resolved, "\t", policy, "\n")
end
local sources = {}
for name in io.lines() do
    if name == "" then break end
    sources[name] = true
end
local cmd_padded = " " .. (arg[2] or "") .. " "
local phase = arg[3] or "overlay"
local function has_flag(tok)
    assert(type(tok) == "string" and #tok > 0, "expected non-empty flag")
    return cmd_padded:find(" " .. tok .. " ", 1, true) ~= nil
end
local function has_define(name)
    assert(type(name) == "string" and #name > 0 and not name:find("[^%w_]"), "invalid define name")
    return cmd_padded:find(" -D" .. name .. " ", 1, true) ~= nil
        or cmd_padded:find(" -D" .. name .. "=", 1, true) ~= nil
        or cmd_padded:find(" +define+" .. name .. " ", 1, true) ~= nil
        or cmd_padded:find(" +define+" .. name .. "=", 1, true) ~= nil
end
local function threads()
    local n = cmd_padded:match(" %-%-threads (%d+) ")
    return n and tonumber(n) or 1
end
local env = {model = {prefix = arg[1], command = arg[2], phase = phase,
                      has_source = function(name) return sources[name] == true end,
                      has_define = has_define,
                      has_flag = has_flag,
                      threads = threads},
             select_rule = select_rule,
             select_verilator_flag = select_verilator_flag,
             select_clock_skip = select_clock_skip,
             assert = assert, ipairs = ipairs, string = string, tonumber = tonumber}
local policy = assert(load(io.read("*a"), "model policy", "t", env))
io.write(_VERSION, "\n")
policy()
