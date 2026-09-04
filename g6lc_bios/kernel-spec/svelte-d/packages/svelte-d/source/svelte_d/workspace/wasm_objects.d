// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Per-.o wasm (G107): ldc2 -c dirty src-d into .svelte-d/o/, then relink
// those objects with the libwasm .a set from dub describe.
// Timing: compile cone is one ldc2 -c of dirty + reverse-import dependents
// (not a new pipeline stage). Link is still whole-program wasm-ld of every
// .o plus the dep archives. LTO cells (ldc-1.36 full / ldc-1.42 thin) stay
// on dub — object reuse is not defined under -flto.
module svelte_d.workspace.wasm_objects;

import std.algorithm : canFind, startsWith, endsWith;
import std.array : join;
import std.ascii : isAlpha, isAlphaNum;
import std.conv : to;
import std.datetime.systime : SysTime;
import std.digest.sha : sha256Of, toHexString;
import std.file : exists, mkdirRecurse, writeText = write, timeLastModified,
	dirEntries, SpanMode, readText, remove, rmdirRecurse;
import std.json : JSONValue, parseJSON;
import std.path : buildPath, baseName, relativePath;
import std.process : execute, Config;
import std.stdio : writeln, stderr;
import std.string : format, replace, strip, splitLines, indexOf, toLower;

/// Bump when compile-flag filtering or object naming changes.
enum objectPin = "g107";

struct ObjRecipe
{
	string[] sources;
	string[] importPaths;
	string[] stringImportPaths;
	string[] versions;
	string[] compileFlags;
	string[] linkDflags;
	string[] lflags;
	string[] linkerFiles;
	string[] options;
	string targetWasm;
	string pinHash;
}

struct ObjResult
{
	bool attempted;
	bool ok;
	int status;
	int compiled;
	int cached;
	int objects;
	string reason;
}

bool objectsSupported(string config, const(string)[] dflags = null)
{
	auto c = config.toLower;
	if (c == "ldc-1.42" || c == "ldc-1.36")
		return false;
	foreach (f; dflags)
		if (f.startsWith("-flto"))
			return false;
	return true;
}

private bool isLinkOnlyFlag(string f)
{
	return f == "-link-internally" || f.startsWith("-defaultlib")
		|| f == "-disable-linker-strip-dead" || f.startsWith("-flto")
		|| f.startsWith("-L");
}

private string[] uniqueKeep(const(string)[] xs)
{
	bool[string] seen;
	string[] o;
	foreach (x; xs)
	{
		if (!x.length || x in seen)
			continue;
		seen[x] = true;
		o ~= x;
	}
	return o;
}

private string jstr(JSONValue v)
{
	try
		return v.str;
	catch (Exception)
		return "";
}

private string jfield(JSONValue obj, string key)
{
	try
	{
		auto p = key in obj;
		if (p is null)
			return "";
		return jstr(*p);
	}
	catch (Exception)
		return "";
}

private string[] jstrs(JSONValue obj, string key)
{
	string[] o;
	try
	{
		auto p = key in obj;
		if (p is null)
			return o;
		foreach (x; p.array)
		{
			auto s = jstr(x);
			if (s.length)
				o ~= s;
		}
	}
	catch (Exception)
	{
	}
	return o;
}

private string jsonFirstObject(string s)
{
	auto i = s.indexOf('{');
	if (i < 0)
		return "";
	return s[i .. $];
}

private string moduleNameOf(string src, string srcRoot)
{
	try
	{
		foreach (ln; readText(src).splitLines)
		{
			auto s = ln.strip;
			if (!s.length || s.startsWith("//") || s.startsWith("/*")
					|| s.startsWith("*") || s.startsWith("+"))
				continue;
			if (s.startsWith("module ") && s.endsWith(";"))
				return s["module ".length .. $ - 1].strip;
			break;
		}
	}
	catch (Exception)
	{
	}
	auto rel = src;
	try
		rel = relativePath(src, srcRoot);
	catch (Exception)
		rel = baseName(src);
	rel = rel.replace("\\", "/");
	if (rel.endsWith(".d"))
		rel = rel[0 .. $ - 2];
	return rel.replace("/", ".");
}

private string[] localImports(string src)
{
	string[] o;
	try
	{
		foreach (ln; readText(src).splitLines)
		{
			auto s = ln.strip;
			if (s.startsWith("public "))
				s = s["public ".length .. $].strip;
			if (s.startsWith("static "))
				s = s["static ".length .. $].strip;
			if (!s.startsWith("import "))
				continue;
			s = s["import ".length .. $].strip;
			if (!s.length || s[0] == '(')
				continue;
			size_t i;
			if (!(isAlpha(s[0]) || s[0] == '_'))
				continue;
			i = 1;
			while (i < s.length && (isAlphaNum(s[i]) || s[i] == '_' || s[i] == '.'))
				i++;
			if (i)
				o ~= s[0 .. i];
		}
	}
	catch (Exception)
	{
	}
	return o;
}

private string recipeHash(string ldc, string config, const ObjRecipe rec)
{
	auto acc = objectPin ~ "\n" ~ ldc ~ "\n" ~ config ~ "\n"
		~ rec.compileFlags.join("\n") ~ "\n"
		~ rec.importPaths.join("\n") ~ "\n"
		~ rec.stringImportPaths.join("\n") ~ "\n"
		~ rec.versions.join("\n") ~ "\n"
		~ rec.linkerFiles.join("\n") ~ "\n"
		~ rec.options.join("\n");
	return toHexString(sha256Of(acc)).idup;
}

private bool loadRecipe(string ws, string ldc, string config,
	string[string] env, out ObjRecipe rec, out string reason)
{
	auto r = execute(
		["dub", "describe", "--arch=wasm32-unknown-wasi", "--compiler=" ~ ldc,
			"--config=" ~ config, "--build=release", "--skip-registry=all"],
		env, Config.none, ulong.max, ws
	);
	if (r.status != 0)
	{
		reason = "describe status=" ~ r.status.to!string;
		return false;
	}
	JSONValue root;
	try
		root = parseJSON(jsonFirstObject(r.output));
	catch (Exception e)
	{
		reason = "describe json: " ~ e.msg;
		return false;
	}
	auto rootName = jfield(root, "rootPackage");
	JSONValue bs;
	bool found;
	try
	{
		foreach (t; root["targets"].array)
		{
			if (jfield(t, "rootPackage") == rootName)
			{
				bs = t["buildSettings"];
				found = true;
				break;
			}
		}
	}
	catch (Exception e)
	{
		reason = "describe targets: " ~ e.msg;
		return false;
	}
	if (!found)
	{
		reason = "no target for " ~ rootName;
		return false;
	}
	rec.sources = uniqueKeep(jstrs(bs, "sourceFiles"));
	rec.importPaths = uniqueKeep(jstrs(bs, "importPaths"));
	rec.stringImportPaths = uniqueKeep(jstrs(bs, "stringImportPaths"));
	rec.versions = uniqueKeep(jstrs(bs, "versions"));
	rec.linkerFiles = uniqueKeep(jstrs(bs, "linkerFiles"));
	rec.options = uniqueKeep(jstrs(bs, "options"));
	rec.lflags = jstrs(bs, "lflags");
	auto rawFlags = jstrs(bs, "dflags");
	string[] cflags;
	string[] ldf;
	foreach (f; uniqueKeep(rawFlags))
	{
		if (f.startsWith("-mtriple") || f.startsWith("--mtriple"))
		{
			cflags ~= f;
			ldf ~= f;
			continue;
		}
		if (isLinkOnlyFlag(f))
			ldf ~= f;
		else
			cflags ~= f;
	}
	if (!ldf.canFind("-mtriple=wasm32-unknown-wasi")
			&& !ldf.canFind("--mtriple=wasm32-unknown-wasi"))
		ldf ~= "-mtriple=wasm32-unknown-wasi";
	if (rec.options.canFind("releaseMode") && !cflags.canFind("-release"))
		cflags ~= "-release";
	if (rec.options.canFind("inline") && !cflags.canFind("-enable-inlining"))
		cflags ~= "-enable-inlining";
	if (rec.options.canFind("optimize") && !cflags.canFind("-O3") && !cflags.canFind("-O"))
		cflags ~= "-O3";
	rec.compileFlags = cflags;
	if (!ldf.canFind("-link-internally"))
		ldf ~= "-link-internally";
	if (!ldf.canFind("-defaultlib="))
		ldf ~= "-defaultlib=";
	rec.linkDflags = uniqueKeep(ldf);
	auto tp = jfield(bs, "targetPath");
	auto tn = jfield(bs, "targetFileName");
	if (!tn.length)
	{
		auto n = jfield(bs, "targetName");
		tn = n.length ? n ~ ".wasm" : "svelte-engine-raw.wasm";
	}
	rec.targetWasm = tp.length ? buildPath(tp, tn)
		: buildPath(ws, "public", "svelte-engine-raw.wasm");
	auto srcRoot = buildPath(ws, "src-d");
	if (exists(srcRoot))
		rec.importPaths ~= srcRoot;
	rec.importPaths = uniqueKeep(rec.importPaths);
	rec.pinHash = recipeHash(ldc, config, rec);
	if (!rec.sources.length)
	{
		reason = "no sourceFiles";
		return false;
	}
	return true;
}

private string objDirOf(string ws)
{
	return buildPath(ws, ".svelte-d", "o");
}

private string objPathOf(string odir, string modName)
{
	return buildPath(odir, modName ~ ".o");
}

private string readPinHash(string odir)
{
	auto p = buildPath(odir, "pin.json");
	if (!exists(p))
		return "";
	try
	{
		auto j = parseJSON(readText(p));
		return jstr(j["hash"]);
	}
	catch (Exception)
		return "";
}

private void writePin(string odir, string ldc, string config, string hash, int nobj)
{
	writeText(buildPath(odir, "pin.json"),
		format(`{"schema":"svelte-d-o/v1","pin":"%s","hash":"%s","compiler":"%s","config":"%s","objects":%s}` ~ "\n",
			objectPin, hash, ldc.replace("\\", "/"), config, nobj.to!string));
}

private void wipeObjects(string odir)
{
	if (!exists(odir))
		return;
	foreach (e; dirEntries(odir, "*.o", SpanMode.shallow))
	{
		try
			remove(e.name);
		catch (Exception)
		{
		}
	}
	auto cache = buildPath(odir, "ldc");
	if (exists(cache))
	{
		try
			rmdirRecurse(cache);
		catch (Exception)
		{
		}
	}
}

/// Compile dirty src-d to .svelte-d/o/ and relink with libwasm archives.
/// On any failure `ok` is false and `reason` says why the caller should dub.
ObjResult tryBuildObjects(string ws, string ldc, string config, string[string] env)
{
	ObjResult res;
	res.attempted = true;
	if (!objectsSupported(config))
	{
		res.reason = "LTO/config " ~ config;
		return res;
	}
	ObjRecipe rec;
	if (!loadRecipe(ws, ldc, config, env, rec, res.reason))
		return res;
	if (!objectsSupported(config, rec.compileFlags ~ rec.linkDflags))
	{
		res.reason = "LTO flags";
		return res;
	}
	foreach (lib; rec.linkerFiles)
	{
		if (!exists(lib))
		{
			res.reason = "missing lib " ~ baseName(lib);
			return res;
		}
	}
	auto odir = objDirOf(ws);
	mkdirRecurse(odir);
	auto srcRoot = buildPath(ws, "src-d");
	auto oldPin = readPinHash(odir);
	if (oldPin.length && oldPin != rec.pinHash)
		wipeObjects(odir);

	string[string] modOf;
	string[][string] importers;
	foreach (src; rec.sources)
	{
		auto m = moduleNameOf(src, srcRoot);
		modOf[src] = m;
		foreach (imp; localImports(src))
			importers[imp] ~= src;
	}

	bool[string] dirty;
	foreach (src; rec.sources)
	{
		auto obj = objPathOf(odir, modOf[src]);
		if (!exists(obj))
		{
			dirty[src] = true;
			continue;
		}
		try
		{
			if (timeLastModified(src) > timeLastModified(obj))
				dirty[src] = true;
		}
		catch (Exception)
			dirty[src] = true;
	}
	string[] queue;
	foreach (s, _; dirty)
		queue ~= s;
	size_t qi;
	while (qi < queue.length)
	{
		auto m = modOf.get(queue[qi++], "");
		if (!m.length)
			continue;
		auto deps = importers.get(m, null);
		foreach (d; deps)
		{
			if (d in dirty)
				continue;
			dirty[d] = true;
			queue ~= d;
		}
	}

	bool[string] keep;
	foreach (src; rec.sources)
		keep[objPathOf(odir, modOf[src])] = true;
	if (exists(odir))
	{
		foreach (e; dirEntries(odir, "*.o", SpanMode.shallow))
		{
			if (e.name in keep)
				continue;
			try
				remove(e.name);
			catch (Exception)
			{
			}
		}
	}

	res.compiled = cast(int) dirty.length;
	res.objects = cast(int) rec.sources.length;
	res.cached = res.objects - res.compiled;

	if (dirty.length)
	{
		// All src-d files must be on the command line so module names that
		// do not match the directory (svelte_engine.kit_router, routes._app_)
		// still resolve. LDC --cache skips codegen for unchanged modules.
		string[] cmd = [ldc, "-c", "-od=" ~ odir, "-oq",
			"--cache=" ~ buildPath(odir, "ldc")];
		cmd ~= rec.compileFlags;
		foreach (p; rec.importPaths)
			cmd ~= "-I=" ~ p;
		foreach (p; rec.stringImportPaths)
			cmd ~= "-J=" ~ p;
		foreach (v; rec.versions)
			cmd ~= "-d-version=" ~ v;
		cmd ~= rec.sources;
		writeln("wasm objects  compile ", res.compiled, " / ", res.objects);
		auto cr = execute(cmd, env, Config.none, ulong.max, ws);
		if (cr.output.length)
			writeln(cr.output);
		if (cr.status != 0)
		{
			res.status = cr.status;
			res.reason = "ldc2 -c status=" ~ cr.status.to!string;
			return res;
		}
		foreach (src, _; dirty)
		{
			if (exists(objPathOf(odir, modOf[src])))
				continue;
			res.reason = "missing object " ~ modOf[src];
			return res;
		}
	}

	string[] lcmd = [ldc, "-of=" ~ rec.targetWasm];
	lcmd ~= rec.linkDflags;
	foreach (lf; uniqueKeep(rec.lflags))
	{
		if (lf.startsWith("-L"))
			lcmd ~= lf;
		else
			lcmd ~= "-L" ~ lf;
	}
	foreach (src; rec.sources)
	{
		auto obj = objPathOf(odir, modOf[src]);
		if (!exists(obj))
		{
			res.reason = "link missing " ~ modOf[src];
			return res;
		}
		lcmd ~= obj;
	}
	// .a is not an LDC input extension; hand archives to wasm-ld.
	foreach (lib; rec.linkerFiles)
		lcmd ~= "-L" ~ lib;
	writePin(odir, ldc, config, rec.pinHash, res.objects);
	writeln("wasm objects  link ", res.objects, " .o + ", rec.linkerFiles.length, " .a");
	auto lr = execute(lcmd, env, Config.none, ulong.max, ws);
	if (lr.output.length)
		writeln(lr.output);
	if (lr.status != 0 || !exists(rec.targetWasm))
	{
		res.status = lr.status;
		res.reason = "link status=" ~ lr.status.to!string;
		return res;
	}
	writePin(odir, ldc, config, rec.pinHash, res.objects);
	res.ok = true;
	res.status = 0;
	return res;
}
