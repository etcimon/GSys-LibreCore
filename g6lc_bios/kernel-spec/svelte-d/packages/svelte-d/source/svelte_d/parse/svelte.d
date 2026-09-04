module svelte_d.parse.svelte;

import std.stdio : writeln, stderr;
import std.file : readText, exists;
import std.algorithm : canFind;
import std.string : strip, indexOf, toLower;
import std.array : appender;

struct ScriptBlock
{
	string lang; // "d" | "ts" | "js" | ""
	bool moduleContext;
	string head;
	string body;
}

struct SvelteScan
{
	bool successful;
	ScriptBlock[] scripts;
	string markup;
	string source; /// original file text (for debug-map orig lines)
	string fail;
	bool peggedOk;
	string peggedName;
	string peggedFail;

	bool hasLang(string lang) const
	{
		foreach (s; scripts)
			if (s.lang == lang)
				return true;
		return false;
	}
}

private string attrLang(string head)
{
	auto h = head.toLower;
	if (canFind(h, `lang="d"`) || canFind(h, "lang='d'"))
		return "d";
	if (canFind(h, `lang="ts"`) || canFind(h, "lang='ts'") || canFind(h, `lang="typescript"`))
		return "ts";
	if (canFind(h, `lang="js"`) || canFind(h, "lang='js'"))
		return "js";
	return ""; // default script = JS/TS for the IDE
}

private bool attrModule(string head)
{
	auto h = head.toLower;
	return canFind(h, `context="module"`) || canFind(h, "context='module'");
}

/// Extract every <script>…</script> (instance + module). Markup is the rest.
SvelteScan parseSvelteFile(string path)
{
	SvelteScan r;
	if (!exists(path))
	{
		r.fail = "missing " ~ path;
		return r;
	}
	auto src = readText(path);
	auto acc = appender!(ScriptBlock[]);
	string rest;
	size_t pos;
	auto low = src.toLower;
	while (pos < src.length)
	{
		auto i = indexOf(low, "<script", pos);
		if (i < 0)
		{
			rest ~= src[pos .. $];
			break;
		}
		rest ~= src[pos .. i];
		auto gt = indexOf(src, ">", i);
		if (gt < 0)
		{
			r.fail = "unterminated <script";
			return r;
		}
		auto end = indexOf(low, "</script>", gt);
		if (end < 0)
		{
			r.fail = "missing </script>";
			return r;
		}
		ScriptBlock b;
		b.head = src[i + 7 .. gt].strip;
		b.body = src[gt + 1 .. end];
		b.lang = attrLang(b.head);
		if (b.lang.length == 0)
			b.lang = "ts"; // nominal Svelte default — IDE / tsserver
		b.moduleContext = attrModule(b.head);
		acc ~= b;
		pos = end + 9;
	}
	r.scripts = acc.data;
	r.markup = rest;
	r.source = src;
	r.successful = true;
	try
	{
		import svelte_d.grammar.sveltekit : SvelteKit;
		auto p = SvelteKit.Document(src);
		r.peggedOk = p.successful;
		r.peggedName = p.name;
		if (!p.successful)
			r.peggedFail = p.failMsg.length ? p.failMsg : "SvelteKit Document failed";
	}
	catch (Exception e)
	{
		r.peggedOk = false;
		r.peggedFail = e.msg;
	}
	return r;
}

void dumpTree(SvelteScan t, int indent = 0)
{
	writeln("SvelteScan success=", t.successful, " scripts=", t.scripts.length,
		" pegged=", t.peggedOk, " ParseTree=", t.peggedName);
	if (t.fail.length)
		writeln("  fail: ", t.fail);
	if (t.peggedFail.length)
		writeln("  pegged: ", t.peggedFail);
	foreach (s; t.scripts)
	{
		writeln("  script lang=", s.lang, " module=", s.moduleContext, " head=", s.head);
		auto body = s.body.strip;
		if (body.length > 100)
			body = body[0 .. 97] ~ "...";
		if (body.length)
			writeln("    body: ", body);
	}
}

/// A file is compileable if every script is d or ts (js defaulted to ts).
bool scriptsOk(SvelteScan t)
{
	foreach (s; t.scripts)
		if (s.lang != "d" && s.lang != "ts")
			return false;
	return t.successful;
}
