// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Lift author `import` lines out of <script lang="d"> / +page.server.d
// onto the printed module header. Wasm Phobos is the spa-phobos set
// (runtime-v1.43.0). Host third-party is the engine vibe.0 graph
// (helpers.connectDB / connectCache, botan, memutils, std).
module svelte_d.print.d_imports;

import std.algorithm : canFind, startsWith;
import std.array : appender;
import std.string : indexOf, strip;

enum ImportCell
{
	wasm,
	host
}

struct ImportLine
{
	string raw;
	string modName;
	string reason;
	bool keep;
}

struct PeeledImports
{
	ImportLine[] lines;
	string body;
}

/// Brace-depth scan: lift file-scope `import …;` (not local imports).
PeeledImports peelAuthorImports(string src, ImportCell cell)
{
	PeeledImports p;
	auto body = appender!string();
	int depth;
	size_t i;
	while (i <= src.length)
	{
		size_t j = i;
		while (j < src.length && src[j] != '\n')
			j++;
		auto line = src[i .. j];
		if (line.length && line[$ - 1] == '\r')
			line = line[0 .. $ - 1];
		auto t = line.strip;
		if (depth == 0 && isImportStmt(t))
		{
			auto im = classifyImport(t, cell);
			im.raw = line.strip;
			p.lines ~= im;
		}
		else
		{
			body ~= line;
			body ~= "\n";
		}
		foreach (c; line)
		{
			if (c == '{')
				depth++;
			else if (c == '}' && depth > 0)
				depth--;
		}
		if (j >= src.length)
			break;
		i = j + 1;
	}
	p.body = body.data;
	return p;
}

/// Module-header text: kept imports, then comments for rejected ones.
string emitImportBlock(const ref PeeledImports p)
{
	auto acc = appender!string();
	foreach (im; p.lines)
	{
		if (im.keep)
			acc ~= im.raw ~ "\n";
		else
			acc ~= "// svelte-d: rejected import " ~ im.modName ~ " — " ~ im.reason ~ "\n";
	}
	return acc.data;
}

bool hasKeptPrefix(const ref PeeledImports p, string pfx)
{
	foreach (im; p.lines)
		if (im.keep && (im.modName == pfx || im.modName.startsWith(pfx ~ ".")))
			return true;
	return false;
}

string[] rejectedMods(const ref PeeledImports p)
{
	string[] o;
	foreach (im; p.lines)
		if (!im.keep && im.modName.length)
			o ~= im.modName;
	return o;
}

string[] keptMods(const ref PeeledImports p)
{
	string[] o;
	foreach (im; p.lines)
		if (im.keep && im.modName.length)
			o ~= im.modName;
	return o;
}

bool isImportStmt(string t)
{
	if (!t.length || t[$ - 1] != ';')
		return false;
	if (t.startsWith("import ") || t.startsWith("public import ")
			|| t.startsWith("static import ") || t.startsWith("private import "))
		return true;
	return false;
}

private ImportLine classifyImport(string t, ImportCell cell)
{
	ImportLine im;
	im.modName = moduleOfImport(t);
	im.keep = true;
	if (!im.modName.length)
		return im;
	if (cell == ImportCell.wasm)
	{
		if (im.modName == "libwasm" || im.modName.startsWith("libwasm."))
			return im;
		if (im.modName == "jshost" || im.modName == "pglite" || im.modName == "probe"
				|| im.modName == "optional" || im.modName.startsWith("optional."))
			return im;
		if (im.modName.startsWith("kit.") || im.modName.startsWith("lib.")
				|| im.modName.startsWith("routes.") || im.modName.startsWith("svelte_engine."))
			return im;
		if (im.modName.startsWith("memutils."))
			return im;
		if (im.modName.startsWith("std."))
		{
			if (wasmPhobosOk(im.modName))
				return im;
			im.keep = false;
			im.reason = "not in wasm Phobos cell (kernel / POSIX omitted)";
			return im;
		}
		if (im.modName == "helpers" || im.modName == "vibe" || im.modName.startsWith("vibe.")
				|| im.modName.startsWith("botan.") || im.modName == "jobs"
				|| im.modName == "events" || im.modName == "geoip")
		{
			im.keep = false;
			im.reason = "host-cell package (use +page.server.d / helpers)";
			return im;
		}
		return im;
	}
	// host: vibe.0 graph. Same packages helpers public-imports for PG/Redis.
	if (im.modName == "libwasm" || im.modName.startsWith("libwasm."))
	{
		im.keep = false;
		im.reason = "wasm-cell package (not vibe.0)";
		return im;
	}
	return im;
}

private string moduleOfImport(string t)
{
	auto s = t.strip;
	if (s.startsWith("public "))
		s = s[7 .. $].strip;
	if (s.startsWith("private "))
		s = s[8 .. $].strip;
	if (s.startsWith("static "))
		s = s[7 .. $].strip;
	if (!s.startsWith("import "))
		return "";
	s = s[7 .. $].strip;
	if (s.length && s[$ - 1] == ';')
		s = s[0 .. $ - 1].strip;
	// `import alias = std.conv : to` or `import std.conv : to`
	auto eq = s.indexOf('=');
	if (eq > 0)
		s = s[eq + 1 .. $].strip;
	auto col = s.indexOf(':');
	if (col > 0)
		s = s[0 .. col].strip;
	auto comma = s.indexOf(',');
	if (comma > 0)
		s = s[0 .. comma].strip;
	return s;
}

/// spa-phobos / runtime-v1.43.0. File/socket/process/concurrency stay omitted.
bool wasmPhobosOk(string mod)
{
	if (!mod.startsWith("std."))
		return false;
	if (mod == "std.stdio" || mod.startsWith("std.stdio."))
		return false;
	if (mod == "std.file" || mod.startsWith("std.file."))
		return false;
	if (mod == "std.socket" || mod.startsWith("std.socket."))
		return false;
	if (mod == "std.concurrency" || mod.startsWith("std.concurrency."))
		return false;
	if (mod == "std.process" || mod.startsWith("std.process."))
		return false;
	if (mod == "std.net" || mod.startsWith("std.net."))
		return false;
	if (mod == "std.mmfile" || mod.startsWith("std.mmfile."))
		return false;
	if (mod == "std.parallelism" || mod.startsWith("std.parallelism."))
		return false;
	if (mod == "std.datetime" || (mod.startsWith("std.datetime.") && !mod.startsWith("std.datetime.date")))
		return false;
	return true;
}

bool looksLikePhobos(string dsrc)
{
	return canFind(dsrc, "import std.");
}
