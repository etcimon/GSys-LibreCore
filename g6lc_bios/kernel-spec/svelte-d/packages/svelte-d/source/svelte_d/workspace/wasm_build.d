// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Wasm cell: per-.o src-d compile + relink inside svelte-engine-ws (G107).
// LTO configs and any objects-path failure fall back to whole-program dub.
// Never build the svelte-engine template. Default config is wasm-eh (application).
module svelte_d.workspace.wasm_build;

import std.algorithm : canFind, sort;
import std.conv : to;
import std.datetime.systime : SysTime;
import std.file : exists, copy, mkdirRecurse, writeText = write, timeLastModified, dirEntries, SpanMode, getcwd, readText, remove, isDir;
import std.path : buildPath, dirName, extension, baseName;
import std.process : execute, environment, Config;
import std.stdio : writeln, stderr;
import std.string : format, replace, splitLines, strip, indexOf, toLower;
import svelte_d.workspace.drop;
import svelte_d.workspace.wasm_objects;
import svelte_d.workspace.ldc : findLdc;

/// Same 1.43+ compiler as the host cell (`findLdc`).
string findWasmLdc(string riscvDev = null)
{
	return findLdc(riscvDev);
}

/// Binaryen ≥123 — first `wasm-opt` that parses LDC 1.43 `try_table`.
enum int minWasmOptVersion = 123;

int parseWasmOptVersion(string text)
{
	import std.regex : matchFirst, regex;

	if (!text.length)
		return 0;
	auto m = matchFirst(text, regex(`version[_\s]+(\d+)`, "i"));
	if (m.empty)
		return 0;
	try
		return m[1].to!int;
	catch (Exception)
		return 0;
}

bool isWasmOptNew(string bin)
{
	if (!bin.length || !exists(bin))
		return false;
	auto r = execute([bin, "--version"]);
	return parseWasmOptVersion(r.output) >= minWasmOptVersion;
}

private string wasmOptExeName()
{
	version (Windows)
		return "wasm-opt.exe";
	else
		return "wasm-opt";
}

private string whichFirst(string cmd)
{
	version (Windows)
		auto r = execute(["where", cmd]);
	else
		auto r = execute(["which", cmd]);
	if (r.status != 0)
		return "";
	foreach (line; splitLines(r.output))
	{
		auto s = line.strip;
		if (s.length && exists(s))
			return s;
	}
	return "";
}

private string toolchainHome()
{
	auto env = environment.get("SVELTE_D_TOOLCHAINS");
	if (env.length)
		return env;
	version (Windows)
	{
		auto up = environment.get("USERPROFILE");
		if (up.length)
			return buildPath(up, ".svelte-d", "toolchains");
	}
	auto home = environment.get("HOME");
	if (home.length)
		return buildPath(home, ".svelte-d", "toolchains");
	return "";
}

private int binaryenFolderVer(string name)
{
	import std.regex : matchFirst, regex;

	auto m = matchFirst(name, regex(`(\d+)`));
	if (m.empty)
		return 0;
	try
		return m[1].to!int;
	catch (Exception)
		return 0;
}

private string scanBinaryenDir(string root)
{
	if (!root.length || !exists(root) || !isDir(root))
		return "";
	auto exe = wasmOptExeName();
	string[] names;
	foreach (e; dirEntries(root, SpanMode.shallow))
	{
		if (!e.isDir)
			continue;
		auto n = baseName(e.name);
		if (!n.toLower.canFind("binaryen-version"))
			continue;
		names ~= e.name;
	}
	names.sort!((a, b) => binaryenFolderVer(baseName(a)) > binaryenFolderVer(baseName(b)));
	foreach (dir; names)
	{
		auto bin = buildPath(dir, "bin", exe);
		if (isWasmOptNew(bin))
			return bin;
	}
	return "";
}

private string binaryenBuildVariant()
{
	version (Windows)
		return "windows-x86_64";
	else version (OSX)
	{
		version (AArch64)
			return "darwin-arm64";
		else
			return "darwin-x86_64";
	}
	else version (AArch64)
		return "linux-aarch64";
	else
		return "linux-x86_64";
}

private string wasmOptInBuildRoot(string root)
{
	if (!root.length || !exists(root))
		return "";
	auto exe = wasmOptExeName();
	auto v = binaryenBuildVariant();
	foreach (rel; [buildPath(v, exe), exe, buildPath("bin", exe)])
	{
		auto cand = buildPath(root, rel);
		if (isWasmOptNew(cand))
			return cand;
	}
	return "";
}

/// Binaryen ≥123 `wasm-opt`. Prefers the etcimon Flatten-try_table fork.
string findWasmOpt(string start = null)
{
	foreach (k; ["SVELTE_D_WASM_OPT", "WASM_OPT"])
	{
		auto v = environment.get(k);
		if (v.length && isWasmOptNew(v))
			return v;
	}
	auto envBuild = environment.get("SVELTE_D_BINARYEN_BUILD");
	auto fromEnv = wasmOptInBuildRoot(envBuild);
	if (fromEnv.length)
		return fromEnv;
	auto forked = buildPath(toolchainHome(), "binaryen-svelte-d", "bin", wasmOptExeName());
	if (isWasmOptNew(forked))
		return forked;
	auto cached = scanBinaryenDir(toolchainHome());
	if (cached.length)
		return cached;
	string[] seeds;
	if (start.length)
		seeds ~= start;
	try
	{
		import svelte_d.workspace.drop : findRiscvDev;

		seeds ~= findRiscvDev();
	}
	catch (Exception)
	{
	}
	seeds ~= getcwd();
	foreach (seed; seeds)
	{
		if (!seed.length)
			continue;
		auto p = seed;
		foreach (_; 0 .. 10)
		{
			auto fromBuild = wasmOptInBuildRoot(buildPath(p, "binaryen-build"));
			if (fromBuild.length)
				return fromBuild;
			auto fromTc = scanBinaryenDir(buildPath(p, "toolchains"));
			if (fromTc.length)
				return fromTc;
			auto parent = dirName(p);
			if (parent == p)
				break;
			p = parent;
		}
	}
	auto onPath = whichFirst("wasm-opt");
	if (isWasmOptNew(onPath))
		return onPath;
	return "";
}

SysTime newestWasmInput(string ws)
{
	SysTime newest = SysTime.min;
	auto pin = buildPath(ws, "dub.sdl");
	if (exists(pin))
		newest = timeLastModified(pin);
	auto srcD = buildPath(ws, "src-d");
	if (exists(srcD))
	{
		foreach (e; dirEntries(srcD, SpanMode.depth))
		{
			if (e.isDir)
				continue;
			if (e.name.extension != ".d")
				continue;
			auto t = e.timeLastModified;
			if (t > newest)
				newest = t;
		}
	}
	return newest;
}

bool wasmArtifactStale(string ws)
{
	auto ship = buildPath(ws, "public", "svelte-engine.wasm");
	auto raw = buildPath(ws, "public", "svelte-engine-raw.wasm");
	string art;
	if (exists(ship))
		art = ship;
	else if (exists(raw))
		art = raw;
	else
		return true;
	return newestWasmInput(ws) > timeLastModified(art);
}

/// Prefer the live checkout over `dub fetch` of github.com/etcimon/libwasm master.
void ensureLibwasmAddLocal()
{
	auto root = findLibwasmCheckout();
	if (!root.length)
		return;
	execute(["dub", "remove-local", root], null, Config.none);
	auto r = execute(["dub", "add-local", root, "~master"], null, Config.none);
	if (r.status == 0)
		writeln("wasm: dub add-local ", root, " ~master");
	else
		stderr.writeln("wasm: add-local failed: ", r.output);
}

/// Record LDC 1.43 and point ws vite `dub --compiler=` at it. Never writes 1.42.
void pinWasmToolchain(string ws)
{
	auto ldc = findWasmLdc();
	mkdirRecurse(buildPath(ws, ".svelte-d"));
	auto posix = ldc.replace(`\`, `/`);
	writeText(buildPath(ws, ".svelte-d", "wasm-ldc.json"),
		format(`{"schema":"svelte-d-wasm-ldc/v1","ldc":"%s","cell":"wasm-eh","ok":%s}` ~ "\n",
			posix, ldc.length ? "true" : "false"));
	if (!ldc.length)
	{
		writeln("wasm-ldc: missing (run bunx svelte-d setup; needs LDC 1.43)");
		return;
	}
	writeln("wasm-ldc: ", ldc);
	auto vite = buildPath(ws, "vite.config.js");
	if (!exists(vite))
		return;
	auto src = readText(vite);
	enum key = "--compiler=";
	auto i = src.indexOf(key);
	if (i < 0)
		return;
	auto j = i + key.length;
	if (j < src.length && (src[j] == '\'' || src[j] == '"'))
		++j;
	auto end = j;
	while (end < src.length && src[end] != ' ' && src[end] != '\'' && src[end] != '"' && src[end] != '\n')
		++end;
	auto next = src[0 .. i] ~ key ~ posix ~ src[end .. $];
	if (next != src)
		writeText(vite, next);
}

/// 0 = built or skipped (fresh), 2 = dub/IR failed, 3 = wasm LDC missing.
/// `buildType` is DUB's debug (symbols) or release (optimize + lflags -strip-all).
int buildWasmCell(string ws, string config = "application", bool force = false,
	string buildType = "release")
{
	if (!exists(buildPath(ws, "dub.sdl")))
	{
		stderr.writeln("wasm: no dub.sdl in ", ws, " (drop-ws first)");
		return 2;
	}
	if (buildType != "debug" && buildType != "release")
		buildType = "release";
	ensureLibwasmAddLocal();
	pinWasmToolchain(ws);
	auto ldc = findWasmLdc();
	if (!ldc.length)
	{
		writeln("wasm: skip — no LDC 1.43 (bunx svelte-d setup; set SVELTE_D_LDC)");
		return 3;
	}
	auto publicDir = buildPath(ws, "public");
	mkdirRecurse(publicDir);
	if (!force && !wasmArtifactStale(ws) && lastWasmBuildType(ws) == buildType)
	{
		writeln("wasm skip  dests unchanged (link not needed)");
		writeWasmJson(ws, ldc, config, true, true, 0, "skip", 0, 0, 0, "");
		return 0;
	}
	rememberWasmBuildType(ws, buildType);
	auto env = environment.toAA();
	env.remove("DFLAGS");
	env.remove("DC");
	env.remove("DMD");
	if (buildType == "release" && objectsSupported(config))
	{
		try
		{
			auto obj = tryBuildObjects(ws, ldc, config, env);
			if (obj.ok)
			{
				auto opt = shipAndOptimize(publicDir, config, buildType);
				writeWasmJson(ws, ldc, config, true, false, 0, "objects",
					obj.compiled, obj.cached, obj.objects, opt);
				auto raw = buildPath(publicDir, "svelte-engine-raw.wasm");
				auto ship = buildPath(publicDir, "svelte-engine.wasm");
				writeln("wasm ok  objects  compiled=", obj.compiled, " cached=", obj.cached,
					"  ", exists(ship) ? ship : raw);
				return 0;
			}
			if (obj.attempted)
				writeln("wasm: objects fallback — ", obj.reason);
		}
		catch (Exception e)
		{
			writeln("wasm: objects fallback — ", e.msg);
		}
	}
	auto r = execute(
		["dub", "build", "--arch=wasm32-unknown-wasi", "--compiler=" ~ ldc,
			"--config=" ~ config, "--build=" ~ buildType],
		env, Config.none, ulong.max, ws
	);
	writeln(r.output);
	auto opt = shipAndOptimize(publicDir, config, buildType);
	auto raw = buildPath(publicDir, "svelte-engine-raw.wasm");
	auto ship = buildPath(publicDir, "svelte-engine.wasm");
	auto ok = r.status == 0 && (exists(ship) || exists(raw));
	writeWasmJson(ws, ldc, config, ok, false, r.status, "dub", 0, 0, 0, opt);
	if (!ok)
	{
		stderr.writeln("wasm: dub failed status=", r.status);
		return 2;
	}
	writeln("wasm ok  dub  ", exists(ship) ? ship : raw);
	return 0;
}

private string lastWasmBuildType(string ws)
{
	auto p = buildPath(ws, ".svelte-d", "wasm-build.txt");
	if (!exists(p))
		return "";
	try
		return readText(p).strip;
	catch (Exception)
		return "";
}

private void rememberWasmBuildType(string ws, string buildType)
{
	mkdirRecurse(buildPath(ws, ".svelte-d"));
	writeText(buildPath(ws, ".svelte-d", "wasm-build.txt"), buildType ~ "\n");
}

private void shipRawWasm(string publicDir)
{
	auto raw = buildPath(publicDir, "svelte-engine-raw.wasm");
	auto ship = buildPath(publicDir, "svelte-engine.wasm");
	if (exists(raw))
		copy(raw, ship);
}

private bool isForkedWasmOptPath(string bin)
{
	auto n = bin.replace(`\`, `/`).toLower;
	return n.canFind("binaryen-svelte-d") || n.canFind("binaryen-build")
		|| n.canFind("/binaryen/bin/") || n.canFind("/binaryen/build/");
}

/// Official wasm-eh post-link. Binaryen ≥123 parses `try_table`.
/// The etcimon/binaryen fork (branch svelte-d) also `--asyncify`s it so
/// EH probes and throwBoundary stay live on the ship module.
/// Stock 123/132 still Flatten-crash; those stay `-Oz` only.
private string shipAndOptimize(string publicDir, string config, string buildType)
{
	shipRawWasm(publicDir);
	auto raw = buildPath(publicDir, "svelte-engine-raw.wasm");
	auto ship = buildPath(publicDir, "svelte-engine.wasm");
	if (!exists(raw) && !exists(ship))
		return "missing";
	auto eh = config == "application" || config == "ldc-master";
	if (!eh)
		return "asyncify-cell";
	auto wasmOpt = findWasmOpt();
	if (!wasmOpt.length)
	{
		writeln("wasm-opt: skip — no Binaryen ≥123 (bunx svelte-d setup; set SVELTE_D_WASM_OPT)");
		return "missing-opt";
	}
	auto src = exists(raw) ? raw : ship;
	auto forceAy = environment.get("SVELTE_D_WASM_ASYNCIFY");
	auto wantAy = forceAy != "0" && (isForkedWasmOptPath(wasmOpt) || forceAy == "1");
	auto asyncified = false;
	if (wantAy)
	{
		auto ay = ship ~ ".ay.tmp";
		auto ar = execute([
			wasmOpt, "--enable-exception-handling", "--enable-bulk-memory",
			"--enable-bulk-memory-opt", "--enable-reference-types",
			"--enable-multivalue", "--enable-nontrapping-float-to-int",
			"--enable-sign-ext", "--asyncify", "--optimize-level=0",
			"--pass-arg=asyncify-imports@env.libwasm_await__void", src, "-o", ay
		]);
		if (ar.status == 0 && exists(ay))
		{
			src = ay;
			asyncified = true;
		}
		else
		{
			stderr.writeln("wasm-opt: asyncify skipped — ", ar.output);
			if (exists(ay))
			{
				try
					remove(ay);
				catch (Exception)
				{
				}
			}
		}
	}
	auto tmp = ship ~ ".opt.tmp";
	string[] args;
	if (buildType == "debug")
		args = [wasmOpt, "-g", "-O0"];
	else
		args = [wasmOpt, "-Oz", "--converge", "--strip-debug", "--strip-dwarf", "--strip-producers"];
	args ~= [
		"--enable-exception-handling", "--enable-bulk-memory",
		"--enable-bulk-memory-opt", "--enable-reference-types",
		"--enable-multivalue", "--enable-nontrapping-float-to-int",
		"--enable-sign-ext", src, "-o", tmp
	];
	auto r = execute(args);
	if (r.status != 0 || !exists(tmp))
	{
		stderr.writeln("wasm-opt: failed — keeping raw. ", r.output);
		if (exists(tmp))
		{
			try
				remove(tmp);
			catch (Exception)
			{
			}
		}
		return "failed";
	}
	copy(tmp, ship);
	try
		remove(tmp);
	catch (Exception)
	{
	}
	if (src.canFind(".ay.tmp"))
	{
		try
			remove(src);
		catch (Exception)
		{
		}
	}
	auto tag = buildType == "debug" ? "-g -O0" : "-Oz --converge --strip-*";
	writeln("wasm-opt: ", tag, " + wasm-eh", asyncified ? " + asyncify" : "",
		"  ", exists(raw) ? raw : ship, " -> ", ship);
	return tag;
}

private void writeWasmJson(string ws, string ldc, string config, bool ok,
	bool skipped, int status, string mode, int compiled, int cached, int objects,
	string opt = "")
{
	auto publicDir = buildPath(ws, "public");
	mkdirRecurse(buildPath(ws, ".svelte-d"));
	writeText(buildPath(ws, ".svelte-d", "wasm.json"),
		format(`{"schema":"svelte-d-wasm/v1","ok":%s,"status":%s,"skipped":%s,"mode":"%s","compiled":%s,"cached":%s,"objects":%s,"compiler":"%s","config":"%s","opt":"%s","raw":%s,"ship":%s}` ~ "\n",
			ok ? "true" : "false", status.to!string, skipped ? "true" : "false", mode,
			compiled.to!string, cached.to!string, objects.to!string,
			ldc.replace("\\", "/"), config, opt.replace(`"`, `'`),
			exists(buildPath(publicDir, "svelte-engine-raw.wasm")) ? "true" : "false",
			exists(buildPath(publicDir, "svelte-engine.wasm")) ? "true" : "false"));
}

int runWasmProbes(string ws)
{
	auto probe = buildPath(ws, "run-probes.mjs");
	if (!exists(probe))
	{
		stderr.writeln("wasm: no run-probes.mjs in ", ws);
		return 2;
	}
	auto r = execute(["node", "run-probes.mjs"], null, Config.none, ulong.max, ws);
	writeln(r.output);
	return r.status == 0 ? 0 : 2;
}
