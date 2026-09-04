// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Reprint-skip: write dests only when bytes change so mtime stays put
// and opposite-cell rebuild can skip a clean wasm or host link.
module svelte_d.workspace.files;

enum DestCell
{
	meta,
	wasm,
	host
}

struct WriteStats
{
	size_t wrote;
	size_t skipped;
	size_t wasm;
	size_t host;
	size_t parsed;
	size_t hashSkip;
}

private WriteStats gStats;

void resetWriteStats()
{
	gStats = WriteStats.init;
}

WriteStats writeStats()
{
	return gStats;
}

/// Write `path` unless it already has exactly `content`. Returns true if written.
bool writeIfChanged(string path, const(char)[] content, DestCell cell = DestCell.meta)
{
	import std.file : exists, mkdirRecurse, readText, write;
	import std.path : dirName;

	auto dir = dirName(path);
	if (dir.length)
		mkdirRecurse(dir);
	if (exists(path))
	{
		try
		{
			if (readText(path) == content)
			{
				gStats.skipped++;
				return false;
			}
		}
		catch (Exception)
		{
		}
	}
	write(path, content);
	gStats.wrote++;
	if (cell == DestCell.wasm)
		gStats.wasm++;
	else if (cell == DestCell.host)
		gStats.host++;
	return true;
}

private string withoutMarked(string src, string begin, string end)
{
	import std.string : indexOf;

	auto b = src.indexOf(begin);
	auto e = src.indexOf(end);
	if (b < 0 || e < b)
		return src;
	auto stop = e + end.length;
	if (stop < src.length && src[stop] == '\n')
		stop++;
	return src[0 .. b] ~ src[stop .. $];
}

private string collapseNewlines(string s)
{
	string o;
	size_t i;
	while (i < s.length)
	{
		if (s[i] == '\n')
		{
			o ~= '\n';
			while (i < s.length && s[i] == '\n')
				i++;
		}
		else
			o ~= s[i++];
	}
	return o;
}

/// Compare printed dest to an existing assembled file, ignoring
/// `// svelte-d:begin-*` blocks (slot projection). Skip the write when
/// only those regions differ so attachD does not clobber assembleSlot.
bool writePrintedDest(string path, const(char)[] printed, DestCell cell = DestCell.wasm)
{
	import std.file : exists, readText;

	if (exists(path))
	{
		try
		{
			auto old = readText(path);
			auto a = collapseNewlines(withoutMarked(withoutMarked(old,
				"// svelte-d:begin-slot-import", "// svelte-d:end-slot-import"),
				"// svelte-d:begin-slot-pages", "// svelte-d:end-slot-pages"));
			auto b = collapseNewlines(withoutMarked(withoutMarked(printed.idup,
				"// svelte-d:begin-slot-import", "// svelte-d:end-slot-import"),
				"// svelte-d:begin-slot-pages", "// svelte-d:end-slot-pages"));
			if (a == b)
			{
				gStats.skipped++;
				return false;
			}
		}
		catch (Exception)
		{
		}
	}
	return writeIfChanged(path, printed, cell);
}

void noteParsed()
{
	gStats.parsed++;
}

void noteHashSkip()
{
	gStats.hashSkip++;
}

/// svelte-d → engine HMR socket (Vite plugin watches this file).
void writeHmrTick(string ws, string op = "reload")
{
	import std.datetime.systime : Clock;
	import std.path : buildPath;

	auto p = buildPath(ws, "public", "__svelte-d", "hmr-tick");
	auto t = Clock.currTime.toISOExtString;
	writeIfChanged(p, op ~ " " ~ t ~ "\n", DestCell.meta);
}

struct SrcHashEnt
{
	string hash;
	string dest;
}

SrcHashEnt[string] loadSrcHashes(string ws)
{
	import std.file : exists, readText;
	import std.path : buildPath;
	import std.string : splitLines, strip, indexOf;

	SrcHashEnt[string] m;
	auto p = buildPath(ws, ".svelte-d", "src-hash.txt");
	if (!exists(p))
		return m;
	try
	{
		foreach (ln; readText(p).splitLines)
		{
			auto s = ln.strip;
			if (!s.length || s[0] == '#')
				continue;
			auto t1 = s.indexOf('\t');
			if (t1 < 0)
				continue;
			auto t2 = s.indexOf('\t', t1 + 1);
			SrcHashEnt e;
			if (t2 < 0)
			{
				e.hash = s[t1 + 1 .. $];
				m[s[0 .. t1]] = e;
			}
			else
			{
				e.hash = s[t1 + 1 .. t2];
				e.dest = s[t2 + 1 .. $];
				m[s[0 .. t1]] = e;
			}
		}
	}
	catch (Exception)
	{
	}
	return m;
}

void saveSrcHashes(string ws, SrcHashEnt[string] m)
{
	import std.algorithm : sort;
	import std.array : appender;
	import std.path : buildPath;

	auto acc = appender!string();
	acc ~= "# svelte-d-src-hash/v1\n";
	string[] keys = m.keys;
	sort(keys);
	foreach (k; keys)
		acc ~= k ~ "\t" ~ m[k].hash ~ "\t" ~ m[k].dest ~ "\n";
	writeIfChanged(buildPath(ws, ".svelte-d", "src-hash.txt"), acc.data, DestCell.meta);
}

string shaFile(string path)
{
	import std.digest.sha : sha256Of, toHexString;
	import std.file : readText;

	try
		return toHexString(sha256Of(readText(path))).idup;
	catch (Exception)
		return "";
}
