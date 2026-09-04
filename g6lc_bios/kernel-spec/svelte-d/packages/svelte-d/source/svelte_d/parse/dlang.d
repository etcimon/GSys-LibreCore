module svelte_d.parse.dlang;

import dparse.lexer;
import dparse.parser;
import dparse.rollback_allocator;
import std.stdio : writeln, stderr;
import std.conv : to;

/// Parse a D fragment (script lang=d body, +page.server.d, or passthrough src-d).
/// Uses libdparse (Boost). serve-d is the IDE on top of this; do not link it.
bool parseDFragment(string source, string filename, out string error)
{
	auto cache = StringCache(StringCache.defaultBucketCount);
	LexerConfig cfg;
	cfg.fileName = filename;
	// Script fragments are not full modules — wrap so libdparse has a root.
	import std.algorithm : canFind;

	auto wrapped = source;
	if (!canFind(source, "module "))
		wrapped = "module svelte_d_script;\n" ~ source;
	auto tokens = getTokensForParser(cast(ubyte[]) wrapped, cfg, &cache);
	RollbackAllocator rba;
	void onMsg(string fn, size_t line, size_t col, string msg, bool)
	{
		error = fn ~ "(" ~ to!string(line) ~ "," ~ to!string(col) ~ "): " ~ msg;
	}
	auto mod = parseModule(tokens, filename, &rba, &onMsg);
	if (error.length)
		return false;
	if (mod is null)
	{
		error = filename ~ ": libdparse returned null module";
		return false;
	}
	return true;
}

void dumpDOk(string source, string filename)
{
	string err;
	if (parseDFragment(source, filename, err))
		writeln("libdparse OK  ", filename);
	else
		stderr.writeln("libdparse FAIL ", err);
}
