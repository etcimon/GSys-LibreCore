// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Host cell: dub build inside svelte-engine-ws/webserver (vibe.0).
// Never build the svelte-engine template. Same LDC 1.43 as the wasm cell.
module svelte_d.workspace.host_build;

import std.conv : to;
import std.file : exists, mkdirRecurse, writeText = write;
import std.path : buildPath;
import std.process : execute, environment, Config;
import std.stdio : writeln, stderr;
import std.string : format, replace;
import svelte_d.workspace.ldc : findLdc, ensureHostAddLocals;

/// Host-cell LDC — same 1.43+ binary as wasm (`findLdc`).
string findHostLdc(string riscvDev = null)
{
	return findLdc(riscvDev);
}

/// 0 = built, 2 = dub failed, 3 = host LDC missing.
/// `buildType` is debug (default, symbols) or release (optimize + strip).
int buildHostCell(string ws, string buildType = "debug")
{
	auto dir = buildPath(ws, "webserver");
	if (!exists(buildPath(dir, "dub.sdl")))
	{
		stderr.writeln("host: no webserver/dub.sdl in ", ws, " (drop-ws first)");
		return 2;
	}
	auto ldc = findHostLdc();
	if (!ldc.length)
	{
		writeln("host: skip — no LDC 1.43 (bunx svelte-d setup; set SVELTE_D_LDC)");
		return 3;
	}
	ensureHostAddLocals();
	mkdirRecurse(buildPath(ws, ".svelte-d"));
	auto env = environment.toAA();
	env.remove("DFLAGS");
	env.remove("DC");
	env.remove("DMD");
	if (buildType != "debug" && buildType != "release")
		buildType = "debug";
	auto r = execute(
		["dub", "build", "--compiler=" ~ ldc, "--build=" ~ buildType],
		env, Config.none, ulong.max, dir
	);
	writeln(r.output);
	auto exeWin = buildPath(dir, "svelte-engine-server.exe");
	auto exePosix = buildPath(dir, "svelte-engine-server");
	auto exe = exists(exeWin) ? exeWin : exePosix;
	auto ok = r.status == 0 && exists(exe);
	writeText(buildPath(ws, ".svelte-d", "host.json"),
		format(`{"schema":"svelte-d-host/v1","ok":%s,"status":%s,"compiler":"%s","exe":%s}` ~ "\n",
			ok ? "true" : "false", r.status.to!string, ldc.replace("\\", "/"),
			exists(exe) ? "true" : "false"));
	if (!ok)
	{
		stderr.writeln("host: dub failed status=", r.status);
		return 2;
	}
	writeln("host ok  ", exe);
	return 0;
}
