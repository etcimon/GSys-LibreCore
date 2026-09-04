// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Project-level svelte-d.config.ts / .js / .json. Dest default is the
// consuming project's top-level ./svelte-engine-ws — never the template.
module svelte_d.workspace.config;

import std.file : exists, getcwd, readText, isDir;
import std.path : buildPath, dirName, baseName, isAbsolute, buildNormalizedPath, absolutePath;
import std.regex : matchFirst, regex;
import std.string : toLower;

struct SvelteDConfig
{
	string workspace; /// as written in the file (relative or absolute)
	string dir; /// directory that contains the config file
	string path; /// config file path
	bool found;
}

private enum string[] configNames = [
	"svelte-d.config.ts",
	"svelte-d.config.js",
	"svelte-d.config.mjs",
	"svelte-d.config.cjs",
	"svelte-d.config.json"
];

private bool skipWalkDir(string name)
{
	auto b = baseName(name).toLower;
	return b == "node_modules" || b == ".git" || b == "svelte-engine-ws";
}

/// Walk up from `start` for svelte-d.config.ts/js/json.
string findSvelteDConfigFile(string start = null)
{
	auto p = start.length ? start : getcwd();
	foreach (_; 0 .. 12)
	{
		if (!skipWalkDir(p))
		{
			foreach (name; configNames)
			{
				auto cand = buildPath(p, name);
				if (exists(cand))
					return cand;
			}
		}
		auto parent = dirName(p);
		if (parent == p)
			break;
		p = parent;
	}
	return "";
}

/// Extract workspace / workspaceDir from config source without executing it.
string parseWorkspaceField(string text)
{
	auto rx = regex(`["']?workspace(?:Dir)?["']?\s*[:=]\s*["']([^"']+)["']`);
	auto m = matchFirst(text, rx);
	if (m.empty)
		return "";
	return m[1].idup;
}

SvelteDConfig loadSvelteDConfig(string start = null)
{
	SvelteDConfig c;
	c.path = findSvelteDConfigFile(start);
	if (!c.path.length)
		return c;
	c.found = true;
	c.dir = dirName(c.path);
	try
		c.workspace = parseWorkspaceField(readText(c.path));
	catch (Exception)
	{
	}
	return c;
}

/// Absolute dest from config, or empty.
string resolveConfigWorkspace(string start = null)
{
	auto c = loadSvelteDConfig(start);
	if (!c.found || !c.workspace.length)
		return "";
	if (isAbsolute(c.workspace))
		return buildNormalizedPath(c.workspace);
	return buildNormalizedPath(absolutePath(buildPath(c.dir, c.workspace)));
}

/// Walk up for a bun + SvelteKit project (src/routes), skipping engine trees.
string findKitProjectRoot(string start = null)
{
	auto p = start.length ? start : getcwd();
	foreach (_; 0 .. 12)
	{
		auto b = baseName(p).toLower;
		if (b != "node_modules" && b != "svelte-engine" && b != "svelte-engine-ws")
		{
			auto routes = buildPath(p, "src", "routes");
			auto alt = buildPath(p, "src-svelte");
			if ((exists(routes) && isDir(routes)) || (exists(alt) && isDir(alt)))
			{
				// Engine template itself has src-svelte — not a consumer project.
				if (!(exists(buildPath(p, "src-d", "app.d")) && exists(buildPath(p, "dub.sdl"))))
					return p;
			}
		}
		auto parent = dirName(p);
		if (parent == p)
			break;
		p = parent;
	}
	return "";
}
