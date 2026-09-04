// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module svelte_d.workspace.drop;

import std.file;
import std.path;
import std.stdio : writeln, stderr;
import std.algorithm : canFind, startsWith;
import std.string : toLower, replace;
import svelte_d.workspace.config;

private bool isEngineRoot(string p)
{
	return exists(buildPath(p, "src-d", "app.d")) && exists(buildPath(p, "dub.sdl"));
}

/// svelte-d package root (exe next to svelte-engine/ or templates/engine).
bool isSvelteDPackage(string p)
{
	return exists(buildPath(p, "ts", "index.ts"))
		&& (isEngineRoot(buildPath(p, "svelte-engine"))
			|| isEngineRoot(buildPath(p, "templates", "engine")));
}

private string[] pathSeeds(string start)
{
	import std.file : thisExePath;

	string[] seeds;
	if (start.length)
		seeds ~= start;
	seeds ~= getcwd();
	try
	{
		auto exeDir = dirName(thisExePath);
		seeds ~= exeDir;
		seeds ~= dirName(exeDir);
	}
	catch (Exception)
	{
	}
	return seeds;
}

/// Packaged bootstrap: svelte-d/svelte-engine, else templates/engine.
string bundledTemplateDir()
{
	foreach (seed; pathSeeds(null))
	{
		foreach (rel; [
			buildNormalizedPath(seed, "svelte-engine"),
			buildNormalizedPath(seed, "..", "svelte-engine"),
			buildNormalizedPath(seed, "templates", "engine"),
			buildNormalizedPath(seed, "..", "templates", "engine")
		])
		{
			if (isEngineRoot(rel))
				return rel;
		}
	}
	return "";
}

private bool isEngineHost(string p)
{
	return exists(buildPath(p, "svelte-engine", "AGENTS.md"))
		|| isEngineRoot(buildPath(p, "svelte-engine"))
		|| isSvelteDPackage(p);
}

/// Directory that contains the drop-source engine (checkout, or this package).
string findRiscvDev(string start = null)
{
	foreach (seed; pathSeeds(start))
	{
		auto p = seed;
		foreach (_; 0 .. 10)
		{
			if (isEngineHost(p))
				return p;
			auto parent = dirName(p);
			if (parent == p)
				break;
			p = parent;
		}
	}
	auto bundled = bundledTemplateDir();
	if (bundled.length)
		return dirName(bundled);
	throw new Exception("cannot find svelte-engine (no svelte-engine/ above cwd or in the svelte-d package)");
}

/// Drop source: live svelte-engine checkout, else the copy packaged with svelte-d.
string templateDir(string riscvDev = null)
{
	if (!riscvDev.length)
		riscvDev = findRiscvDev();
	auto sub = buildPath(riscvDev, "svelte-engine");
	if (isEngineRoot(sub))
		return sub;
	auto bundled = bundledTemplateDir();
	if (bundled.length)
		return bundled;
	return sub;
}

string defaultWorkspaceDir(string riscvDev)
{
	auto fromCfg = resolveConfigWorkspace();
	if (fromCfg.length)
		return fromCfg;
	auto kit = findKitProjectRoot();
	if (kit.length)
		return buildPath(kit, "svelte-engine-ws");
	if (!riscvDev.length)
		riscvDev = findRiscvDev();
	auto here = buildPath(riscvDev, "svelte-engine-ws");
	if (exists(here))
		return here;
	// Installed package: project cwd, not node_modules/svelte-d.
	if (isSvelteDPackage(riscvDev))
	{
		auto cwd = getcwd();
		if (!isSvelteDPackage(cwd) && !isEngineRoot(cwd))
			return buildPath(cwd, "svelte-engine-ws");
		return here;
	}
	auto beside = buildPath(dirName(riscvDev), "svelte-engine-ws");
	if (exists(beside))
		return beside;
	return here;
}

private bool isLibwasmRoot(string p)
{
	return exists(buildPath(p, "source", "libwasm", "dom.d"));
}

/// True when p is a DUB fetch/cache tree (not a source checkout to add-local).
bool isLibwasmDubCache(string p)
{
	auto n = p.replace("\\", "/");
	return n.canFind("/.dub/packages/") || n.canFind("/dub/packages/");
}

/// Walk for a source checkout if one happens to exist. Consumers use DUB fetch.
string findLibwasmCheckout(string riscvDev = null)
{
	import std.process : environment;

	auto env = environment.get("LIBWASM_ROOT");
	if (env.length && isLibwasmRoot(env) && !isLibwasmDubCache(env))
		return env;
	if (!riscvDev.length)
	{
		try
			riscvDev = findRiscvDev();
		catch (Exception)
			riscvDev = getcwd();
	}
	string[] seeds = [riscvDev, dirName(riscvDev), getcwd()];
	foreach (seed; seeds)
	{
		if (!seed.length)
			continue;
		auto p = seed;
		foreach (_; 0 .. 10)
		{
			foreach (cand; [buildPath(p, "libwasm"), buildPath(p, "riscv-compilers", "libwasm")])
			{
				if (isLibwasmRoot(cand) && !isLibwasmDubCache(cand))
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

private string findLibwasmInDubCache()
{
	import std.process : environment;

	string[] homes;
	auto dubHome = environment.get("DUB_HOME");
	if (dubHome.length)
		homes ~= dubHome;
	auto la = environment.get("LOCALAPPDATA");
	if (la.length)
		homes ~= buildPath(la, "dub");
	auto up = environment.get("USERPROFILE");
	if (up.length)
		homes ~= buildPath(up, ".dub");
	auto home = environment.get("HOME");
	if (home.length)
		homes ~= buildPath(home, ".dub");
	foreach (h; homes)
	{
		auto pkgs = buildPath(h, "packages");
		if (!exists(pkgs))
			continue;
		foreach (rel; [
			buildPath("libwasm", "~master", "libwasm"),
			buildPath("libwasm", "master", "libwasm"),
			buildPath("libwasm", "0.10.0", "libwasm")
		])
		{
			auto cand = buildPath(pkgs, rel);
			if (isLibwasmRoot(cand))
				return cand;
		}
		auto lw = buildPath(pkgs, "libwasm");
		if (exists(lw) && isDir(lw))
		{
			foreach (e; dirEntries(lw, SpanMode.shallow))
			{
				if (!e.isDir)
					continue;
				if (isLibwasmRoot(e.name))
					return e.name;
				auto inner = buildPath(e.name, "libwasm");
				if (isLibwasmRoot(inner))
					return inner;
			}
		}
	}
	return "";
}

/// libwasm: checkout (add-local), else the fetched DUB copy of master.
string findLibwasmRoot(string riscvDev = null)
{
	import std.process : environment;

	auto env = environment.get("LIBWASM_ROOT");
	if (env.length && isLibwasmRoot(env))
		return env;
	auto checkout = findLibwasmCheckout(riscvDev);
	if (checkout.length)
		return checkout;
	auto cached = findLibwasmInDubCache();
	if (cached.length)
		return cached;
	throw new Exception("cannot find libwasm (source/libwasm/dom.d; set LIBWASM_ROOT or dub fetch)");
}

private bool skipName(string name)
{
	auto b = baseName(name).toLower;
	if (b == ".dub" || b == "node_modules" || b == ".svelte-d" || b == ".git"
			|| b == "prisma" || b == "integrations" || b == "3dify.json" || b == "comfyapi.d"
			|| b == "workflow_api.json" || b == "generatesourcemap.py"
			|| b == "capacitor.config.json")
		return true;
	if (b.endsWith(".exe") || b.endsWith(".pdb") || b.endsWith(".obj") || b.endsWith(".lib")
			|| b.endsWith(".wasm"))
		return true;
	return false;
}

private bool endsWith(string s, string tail)
{
	return s.length >= tail.length && s[$ - tail.length .. $] == tail;
}

/// Overlay the bootstrap template onto dest. Never deletes dest, never
/// rmdirRecurse's the workspace, and never removes files the user added.
/// `--force` overwrites template-owned files; without it, existing dest
/// files are kept (first drop still fills missing ones).
void dropWorkspace(string dest, string srcTemplate, bool force)
{
	if (!exists(srcTemplate) || !isDir(srcTemplate))
		throw new Exception("template missing: " ~ srcTemplate);
	mkdirRecurse(dest);
	size_t n;
	foreach (e; dirEntries(srcTemplate, SpanMode.breadth))
	{
		auto rel = relativePath(e.name, srcTemplate);
		auto parts = pathSplitter(rel);
		bool skip;
		foreach (part; parts)
		{
			if (skipName(part))
			{
				skip = true;
				break;
			}
		}
		if (skip)
			continue;
		auto outp = buildPath(dest, rel);
		if (e.isDir)
			mkdirRecurse(outp);
		else
		{
			if (exists(outp) && !force)
				continue;
			mkdirRecurse(dirName(outp));
			try
			{
				copy(e.name, outp);
				++n;
			}
			catch (Exception ex)
			{
				stderr.writeln("drop: skip locked ", outp, " (", ex.msg, ")");
			}
		}
	}
	if (force)
	{
		auto hashes = buildPath(dest, ".svelte-d", "src-hash.txt");
		if (exists(hashes))
		{
			try
				remove(hashes);
			catch (Exception)
			{
			}
		}
	}
	writeln("dropped ", srcTemplate, " -> ", dest, " (overlay ", n, " files)");
}
