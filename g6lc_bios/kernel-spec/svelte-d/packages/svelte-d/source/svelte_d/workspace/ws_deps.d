// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// lang=ts import specifiers from the kit project fall through onto
// svelte-engine-ws/package.json (the project's declared range) and
// dest node_modules/<pkg> (a copy of the project's install).
// bun install runs when the dest graph is missing a declared dep.
module svelte_d.workspace.ws_deps;

import std.algorithm : canFind, startsWith;
import std.file;
import std.json;
import std.path;
import std.process : Config, execute;
import std.stdio : writeln;
import std.string : indexOf, replace, strip;
import svelte_d.workspace.files;

/// Bare npm name from `lodash/fp` or `@scope/pkg/sub`.
string npmPackageName(string spec)
{
	auto s = spec.strip;
	if (!s.length || s[0] == '.' || s[0] == '/' || s[0] == '$')
		return "";
	if (s.startsWith("svelte/") || s == "svelte")
		return "";
	if (s[0] == '@')
	{
		auto sl = indexOf(s, '/', 1);
		if (sl < 0)
			return s;
		auto sl2 = indexOf(s, '/', sl + 1);
		return sl2 < 0 ? s : s[0 .. sl2];
	}
	auto sl = indexOf(s, '/');
	return sl < 0 ? s : s[0 .. sl];
}

bool isNpmSpec(string spec)
{
	return npmPackageName(spec).length > 0;
}

/// Project-declared range, or the version from the project's installed copy.
string lookupProjectDep(string project, string ws, string pkg)
{
	if (!pkg.length)
		return "";
	foreach (key; ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"])
	{
		auto v = jsonDep(buildPath(project, "package.json"), key, pkg);
		if (v.length)
			return v;
	}
	auto installed = buildPath(project, "node_modules", pkg, "package.json");
	if (exists(installed))
	{
		auto v = jsonDep(installed, "version", "");
		if (v.length)
			return v;
		try
		{
			auto j = parseJSON(readText(installed));
			if (j.type == JSONType.object && "version" in j && j["version"].type == JSONType.string)
				return j["version"].str;
		}
		catch (Exception)
		{
		}
	}
	return "";
}

/// Copy the project's installed package into dest node_modules (same files Vite will resolve).
bool linkProjectPackage(string project, string ws, string pkg)
{
	auto src = buildPath(project, "node_modules", pkg);
	if (!exists(src) || !isDir(src))
		return false;
	auto dest = buildPath(ws, "node_modules", pkg);
	try
	{
		copyDir(src, dest);
		return exists(buildPath(dest, "package.json"));
	}
	catch (Exception e)
	{
		writeln("ws link ", pkg, ": ", e.msg);
		return false;
	}
}

/// Merge `specs` into dest package.json. Returns true if the file changed.
bool syncWsDependencies(string project, string ws, string[] specs)
{
	string[string] want;
	foreach (s; specs)
	{
		auto pkg = npmPackageName(s);
		if (!pkg.length || pkg in want)
			continue;
		auto ver = lookupProjectDep(project, ws, pkg);
		if (!ver.length)
			continue;
		want[pkg] = ver;
		if (!pkg.startsWith("@types/"))
		{
			auto typ = "@types/" ~ pkg;
			auto tv = lookupProjectDep(project, ws, typ);
			if (tv.length)
				want[typ] = tv;
		}
	}
	if (!want.length)
		return false;
	auto pj = buildPath(ws, "package.json");
	if (!exists(pj))
		return false;
	JSONValue j;
	try
		j = parseJSON(readText(pj));
	catch (Exception)
		return false;
	if (j.type != JSONType.object)
		return false;
	if ("dependencies" !in j || j["dependencies"].type != JSONType.object)
		j["dependencies"] = JSONValue((JSONValue[string]).init);
	bool changed;
	foreach (pkg, ver; want)
	{
		if (pkg in j["dependencies"].object
				&& j["dependencies"][pkg].type == JSONType.string
				&& j["dependencies"][pkg].str == ver)
			continue;
		j["dependencies"][pkg] = JSONValue(ver);
		changed = true;
	}
	if (changed)
		writeIfChanged(pj, (j.toPrettyString ~ "\n").replace(`\/`, `/`), DestCell.meta);
	foreach (pkg, ver; want)
		linkProjectPackage(project, ws, pkg);
	return changed;
}

bool wsDepsMissing(string ws, string[] specs)
{
	foreach (s; specs)
	{
		auto pkg = npmPackageName(s);
		if (!pkg.length)
			continue;
		if (!exists(buildPath(ws, "node_modules", pkg, "package.json")))
			return true;
	}
	return false;
}

/// `bun install` in dest so Vite can resolve the fallen-through packages.
int installWsDeps(string ws)
{
	if (!exists(ws) || !isDir(ws))
		return 1;
	try
	{
		auto r = execute(["bun", "install"], null, Config.none, size_t.max, ws);
		writeln("ws bun install: ", r.status == 0 ? "ok" : "fail", " (", r.output.length, " B)");
		if (r.status != 0 && r.output.length)
			writeln(r.output);
		return r.status;
	}
	catch (Exception e)
	{
		writeln("ws bun install: ", e.msg);
		return 1;
	}
}

private string jsonDep(string pj, string key, string pkg)
{
	if (!exists(pj))
		return "";
	JSONValue j;
	try
		j = parseJSON(readText(pj));
	catch (Exception)
		return "";
	if (j.type != JSONType.object || key !in j || j[key].type != JSONType.object)
		return "";
	if (pkg !in j[key].object || j[key][pkg].type != JSONType.string)
		return "";
	return j[key][pkg].str;
}

private void copyDir(string from, string to)
{
	mkdirRecurse(to);
	foreach (e; dirEntries(from, SpanMode.breadth))
	{
		auto rel = relativePath(e.name, from);
		auto outp = buildPath(to, rel);
		if (e.isDir)
			mkdirRecurse(outp);
		else if (e.isFile)
		{
			mkdirRecurse(dirName(outp));
			copy(e.name, outp);
		}
	}
}
