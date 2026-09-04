// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Derived debug map: printed D comments → .svelte-d/debug-map.json.
// The D IR is the correctness surface; this file is trace-only.
module svelte_d.print.debug_map;

import std.array : Appender, appender;
import std.file : dirEntries, exists, mkdirRecurse, readText, SpanMode, write;
import std.path : buildPath, extension, relativePath;
import std.string : indexOf, strip, startsWith, replace;

struct DebugEntry
{
	string dest;
	int destLine;
	string orig;
	int origLine;
	string kind;
	string name;
}

/// Scan printed .d files for `//# svelte-d-ir` comments.
DebugEntry[] collectDebugMap(string ws)
{
	auto acc = appender!(DebugEntry[]);
	void walk(string root)
	{
		auto abs = buildPath(ws, root);
		if (!exists(abs))
			return;
		foreach (e; dirEntries(abs, SpanMode.depth))
		{
			if (!e.isFile || extension(e.name) != ".d")
				continue;
			auto dest = relativePath(e.name, ws).replace(`\`, `/`);
			auto txt = readText(e.name);
			int line = 1;
			size_t i;
			foreach (j, c; txt)
			{
				if (c == '\n')
				{
					parseLine(txt[i .. j], dest, line, acc);
					line++;
					i = j + 1;
				}
			}
			if (i <= txt.length)
				parseLine(txt[i .. $], dest, line, acc);
		}
	}
	walk("src-d");
	walk("webserver/source/generated");
	return acc.data;
}

void writeDebugMap(string ws)
{
	auto xs = collectDebugMap(ws);
	auto dir = buildPath(ws, ".svelte-d");
	mkdirRecurse(dir);
	auto acc = appender!string();
	acc ~= `{"schema":"svelte-d-debug-map/v1",`;
	acc ~= `"principle":"D-IR-is-correctness-surface; map-is-trace-only",`;
	acc ~= `"entries":[`;
	foreach (i, e; xs)
	{
		if (i)
			acc ~= ",";
		acc ~= `{"dest":"` ~ esc(e.dest) ~ `","destLine":` ~ intStr(e.destLine)
			~ `,"orig":"` ~ esc(e.orig) ~ `","origLine":` ~ intStr(e.origLine)
			~ `,"kind":"` ~ esc(e.kind) ~ `","name":"` ~ esc(e.name) ~ `"}`;
	}
	acc ~= "]}\n";
	write(buildPath(dir, "debug-map.json"), acc.data);
	auto pub = buildPath(ws, "public", "__svelte-d");
	mkdirRecurse(pub);
	write(buildPath(pub, "debug-map.json"), acc.data);
}

private void parseLine(string ln, string dest, int destLine, ref Appender!(DebugEntry[]) acc)
{
	auto t = ln.strip;
	enum pfx = "//# svelte-d-ir ";
	if (!t.startsWith(pfx))
		return;
	auto rest = t[pfx.length .. $];
	DebugEntry e;
	e.dest = dest;
	e.destLine = destLine;
	e.kind = "file";
	foreach (part; splitSpace(rest))
	{
		auto eq = part.indexOf('=');
		if (eq <= 0)
			continue;
		auto k = part[0 .. eq];
		auto v = part[eq + 1 .. $];
		if (k == "orig")
		{
			auto c = v.lastIndexOf(':');
			if (c > 0)
			{
				e.orig = v[0 .. c];
				e.origLine = atoi(v[c + 1 .. $]);
			}
			else
				e.orig = v;
		}
		else if (k == "kind")
			e.kind = v;
		else if (k == "name")
			e.name = v;
	}
	if (e.orig.length)
		acc ~= e;
}

private int lastIndexOf(string s, char c)
{
	foreach_reverse (i, ch; s)
		if (ch == c)
			return cast(int) i;
	return -1;
}

private string[] splitSpace(string s)
{
	string[] o;
	size_t i;
	foreach (j, c; s)
	{
		if (c == ' ' || c == '\t')
		{
			if (j > i)
				o ~= s[i .. j];
			i = j + 1;
		}
	}
	if (i < s.length)
		o ~= s[i .. $];
	return o;
}

private int atoi(string s)
{
	int n;
	foreach (c; s)
	{
		if (c < '0' || c > '9')
			break;
		n = n * 10 + (c - '0');
	}
	return n;
}

private string intStr(int n)
{
	import std.conv : to;
	return to!string(n);
}

private string esc(string s)
{
	return s.replace(`\`, `/`).replace(`"`, `'`);
}
