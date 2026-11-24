-- Copyright 2026 Etienne Cimon
-- SPDX-License-Identifier: MIT
-- Only the driver has I/O. Plugins declare a bounded plan once per build.
assert(_VERSION == "Lua 5.3" or _VERSION == "Lua 5.4", "expected Lua 5.3 or 5.4")
local count = 0
local vlt_flag_count = 0
local probe_count = 0
local valid_passes = {
    ["packed-rows"] = true,
    ["packed-mux-rows"] = true,
    ["tiled-columns"] = true,
    ["wrapped-columns"] = true,
    ["packed-predicates"] = true,
    ["strided-bit-columns"] = true,
    ["circular-age-compare"] = true,
    ["scatter-eq-mask"] = true,
    ["wide-mux-guard"] = true,
    ["assert-guard-hoist"] = true,
    ["assert-cone-gate"] = true,
}
local valid_vlt_flags = {
    ["-fclock-skip-sink"] = true,
    ["-fclock-skip"] = true,
    ["-fdfg-peephole-pack-byte-plane"] = true,
    ["-fdfg-peephole-pack-predicates"] = true,
    ["-fdfg-peephole-pack-bitwise-mux"] = true,
    ["-fdfg-peephole-guard-empty-mask"] = true,
    ["-fdfg-peephole-fuse-transpose-reductions"] = true,
    ["--dumpi-sentinel"] = true,
    ["--no-assert"] = true,
}
local valid_probe_ops = {
    ["bit_select_concat"] = true,
    ["masked_transpose_reductions"] = true,
    ["masked_reduction"] = true,
    ["strided_column_tile"] = true,
    ["one_word_pext"] = true,
    ["byte_movemask"] = true,
    ["circular_age_compare"] = true,
    ["scatter_eq_mask"] = true,
    ["wide_mux_guard"] = true,
}
local function select_rule(class_glob, marker, pass)
    assert(type(class_glob) == "string" and #class_glob > 0 and #class_glob <= 256
           and not class_glob:find("[^%w_*?%[%]%-]"), "invalid generated class glob")
    assert(type(marker) == "string" and #marker <= 256
           and not marker:find("[^ -~]"), "expected printable ASCII source marker")
    assert(valid_passes[pass], "unknown checked transform")
    count = count + 1
    assert(count <= 128, "too many rules")
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
local function select_sentinel_probe(name, op, target_glob)
    target_glob = target_glob or "*"
    assert(type(name) == "string" and #name > 0 and #name <= 128
           and not name:find("[^%w_%-]"), "invalid sentinel probe name")
    assert(type(op) == "string" and valid_probe_ops[op], "unknown sentinel probe op")
    assert(type(target_glob) == "string" and #target_glob > 0 and #target_glob <= 256
           and not target_glob:find("[^ -~]"), "invalid sentinel probe target glob")
    probe_count = probe_count + 1
    assert(probe_count <= 32, "too many sentinel probes")
    io.write("@sentinel_probe\t", name, "\t", op, "\t", target_glob, "\n")
end

local sources = {}
local markers = {}
local stats = {}
local sentinel_dfg = {}
local sentinel_sched = {has = false, tasks = 0, edges = 0, lanes = 0}
local sentinel_has_dfg = false

for line in io.lines() do
    if line == "" then break end
    if line:sub(1, 1) == "@" then
        local kind, k, v = line:match("^@([%w_]+)\t([^\t]+)\t?(.*)$")
        if kind == "marker" then
            markers[k] = true
        elseif kind == "stat" then
            stats[k] = tonumber(v) or 0
        elseif kind == "dfg" then
            sentinel_has_dfg = true
            sentinel_dfg[k] = tonumber(v) or 0
        elseif kind == "sched" then
            sentinel_sched.has = true
            sentinel_sched[k] = tonumber(v) or 0
        end
    else
        sources[line] = true
    end
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
local env = {
    model = {
        prefix = arg[1],
        command = arg[2],
        phase = phase,
        has_source = function(name) return sources[name] == true end,
        has_marker = function(name) return markers[name] == true end,
        stat = function(name) return stats[name] end,
        has_define = has_define,
        has_flag = has_flag,
        threads = threads,
    },
    sentinel = {
        has_dfg = function() return sentinel_has_dfg end,
        dfg_count = function(op) return sentinel_dfg[op] or 0 end,
        has_sched = function() return sentinel_sched.has end,
        sched_tasks = function() return sentinel_sched.tasks or 0 end,
        sched_edges = function() return sentinel_sched.edges or 0 end,
        sched_lanes = function() return sentinel_sched.lanes or 0 end,
    },
    select_rule = select_rule,
    select_verilator_flag = select_verilator_flag,
    select_clock_skip = select_clock_skip,
    select_sentinel_probe = select_sentinel_probe,
    assert = assert, ipairs = ipairs, pairs = pairs, string = string, tonumber = tonumber,
}
local policy = assert(load(io.read("*a"), "model policy", "t", env))
io.write(_VERSION, "\n")
policy()
