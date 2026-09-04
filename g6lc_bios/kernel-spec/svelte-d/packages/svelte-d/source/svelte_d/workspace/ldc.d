// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// One LDC 1.43+ for the svelte-d CLI, vibe.0 host, and wasm-eh cell.
// Wasm vs host stay different targets (cleared DFLAGS / separate dub graphs).
module svelte_d.workspace.ldc;

import std.algorithm : canFind;
import std.file : exists, dirEntries, SpanMode, isDir, getcwd;
import std.path : buildPath, dirName, baseName;
import std.process : execute, environment;
import std.string : toLower, strip, splitLines, replace;

bool isLdc143Text(string o)
{
	import std.regex : matchFirst, regex;
	import std.string : splitLines;

	if (!o.length)
		return false;
	// First identity line only — "built with LDC (1.42.0)" is the bootstrap.
	string first = o;
	foreach (line; splitLines(o))
	{
		if (canFind(line, "LDC - the LLVM D compiler"))
		{
			first = line;
			break;
		}
	}
	auto m = matchFirst(first, regex(`\(([^)]+)\)`));
	auto ver = m.empty ? first : m[1];
	if (matchFirst(ver, regex(`1\.(36|40|41|42)\.`)))
		return false;
	return !matchFirst(ver, regex(`1\.(43|44|45|46)`)).empty;
}

bool isLdc143(string bin)
{
	if (!bin.length || !exists(bin))
		return false;
	auto r = execute([bin, "--version"]);
	return isLdc143Text(r.output);
}

private string ldcExeName()
{
	version (Windows)
		return "ldc2.exe";
	else
		return "ldc2";
}

private string dubExeName()
{
	version (Windows)
		return "dub.exe";
	else
		return "dub";
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

private bool preferToolchainName(string name)
{
	auto n = name.toLower;
	return n.canFind("ldc2-1.43") || n.canFind("ldc2-1.44") || n.canFind("ldc2-1.45")
		|| n.canFind("ldc2-master") || n.canFind("ldc2-build");
}

private string scanToolchainDir(string root)
{
	if (!root.length || !exists(root) || !isDir(root))
		return "";
	auto exe = ldcExeName();
	foreach (e; dirEntries(root, SpanMode.shallow))
	{
		if (!e.isDir || !preferToolchainName(baseName(e.name)))
			continue;
		auto bin = buildPath(e.name, "bin", exe);
		if (isLdc143(bin))
			return bin;
	}
	return "";
}

private string[] pathSeeds(string start)
{
	import svelte_d.workspace.drop : findRiscvDev;

	string[] seeds;
	if (start.length)
		seeds ~= start;
	try
		seeds ~= findRiscvDev();
	catch (Exception)
	{
	}
	seeds ~= getcwd();
	return seeds;
}

/// LDC 1.43+ used for CLI, vibe.0, and wasm. Never returns 1.42.
string findLdc(string start = null)
{
	auto exe = ldcExeName();
	foreach (k; ["SVELTE_D_LDC", "LDC", "WASM_LDC", "SVELTE_D_WASM_LDC", "DC"])
	{
		auto v = environment.get(k);
		if (v.length && isLdc143(v))
			return v;
	}
	auto cached = scanToolchainDir(toolchainHome());
	if (cached.length)
		return cached;
	foreach (seed; pathSeeds(start))
	{
		if (!seed.length)
			continue;
		auto p = seed;
		foreach (_; 0 .. 10)
		{
			// Author-machine shortcuts. Consumers use ~/.svelte-d/toolchains or PATH.
			foreach (rel; [
				buildPath("riscv-compilers", "ldc2-build", "bin"),
				buildPath("ldc2-build", "bin")
			])
			{
				auto bin = buildPath(p, rel, exe);
				if (isLdc143(bin))
					return bin;
			}
			auto fromTc = scanToolchainDir(buildPath(p, "toolchains"));
			if (fromTc.length)
				return fromTc;
			auto parent = dirName(p);
			if (parent == p)
				break;
			p = parent;
		}
	}
	auto onPath = whichFirst("ldc2");
	if (isLdc143(onPath))
		return onPath;
	return "";
}

string findDub(string ldc = null)
{
	if (!ldc.length)
		ldc = findLdc();
	if (ldc.length)
	{
		auto cand = buildPath(dirName(ldc), dubExeName());
		if (exists(cand))
			return cand;
	}
	return whichFirst("dub");
}

private bool isVibe0Root(string p)
{
	return exists(buildPath(p, "source", "vibe", "http", "server.d"))
		|| exists(buildPath(p, "source", "vibe", "d.d"));
}

string findVibe0Checkout(string start = null)
{
	auto env = environment.get("VIBE0_ROOT");
	if (env.length && isVibe0Root(env))
		return env;
	foreach (seed; pathSeeds(start))
	{
		if (!seed.length)
			continue;
		auto p = seed;
		foreach (_; 0 .. 10)
		{
			// Optional author checkouts. Consumers use the DUB vibe-0 registry.
			foreach (cand; [buildPath(p, "vibe.0"), buildPath(p, "riscv-dev", "vibe.0")])
			{
				if (isVibe0Root(cand))
					return cand;
			}
			auto parent = dirName(p);
			if (parent == p)
				break;
			p = parent;
		}
	}
	return "";
}

private string findPkgDir(string pkgName, string start = null)
{
	foreach (seed; pathSeeds(start))
	{
		if (!seed.length)
			continue;
		auto p = seed;
		foreach (_; 0 .. 10)
		{
			foreach (cand; [buildPath(p, pkgName), buildPath(p, "riscv-dev", pkgName)])
			{
				if (exists(buildPath(cand, "dub.json")) || exists(buildPath(cand, "dub.sdl")))
					return cand;
			}
			auto parent = dirName(p);
			if (parent == p)
				break;
			p = parent;
		}
	}
	return "";
}

/// dub add-local vibe.0 + host graph when checkouts exist.
void ensureHostAddLocals(string start = null)
{
	import std.stdio : writeln;

	auto dub = findDub();
	if (!dub.length)
		return;
	static immutable string[2][] pkgs = [
		["memutils", "memutils"],
		["botan-math", "botan-math"],
		["libasync", "libasync"],
		["botan", "botan"],
		["libhttp2", "libhttp2"],
		["openssl", "openssl"],
		["vibe.0", "vibe-0"]
	];
	foreach (pkg; pkgs)
	{
		auto root = pkg[0] == "vibe.0" ? findVibe0Checkout(start) : findPkgDir(pkg[0], start);
		if (!root.length)
			continue;
		execute([dub, "remove-local", root]);
		auto r = execute([dub, "add-local", root]);
		if (r.status == 0)
			writeln("host: dub add-local ", root);
	}
}
