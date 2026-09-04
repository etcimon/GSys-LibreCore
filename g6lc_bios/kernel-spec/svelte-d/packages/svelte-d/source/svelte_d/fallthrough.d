// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Guiding principle: Svelte / SvelteKit syntax in a svelte-d + bun project
// falls through to the corresponding libwasm / vibe.0 equivalent in a
// roughly equivalent structure inside svelte-engine-ws.
//
// The kit relative path is preserved. Only the cell prefix changes:
//   src/routes/+page.svelte  →  src-svelte/routes/+page.svelte   (source)
//                            →  src-d/routes/page.d              (libwasm)
//                            →  src-ts/modules/generated/…       (jsExports)
//   src/routes/+page.server.* → webserver/source/generated/…     (vibe.0)
module svelte_d.fallthrough;

import std.algorithm : startsWith;
import std.array : appender, replace;
import std.file : exists, write;
import std.path : baseName, dirName, extension, buildPath, relativePath, stripExtension;
import std.string : format, indexOf;
import std.uni : isAlphaNum;
import svelte_d.parse.kit_fs;

/// One kit source → its workspace destinations.
struct Fallthrough
{
	string kitRel; /// routes/+page.svelte  (no src/ or src-svelte/ prefix)
	string kind; /// page | layout | page_server | layout_server | endpoint | error | component | ext_component | ts_helper | style | d | hooks
	string cell; /// wasm | host | both
	string runtime; /// libwasm | libwasm+jsExports | vibe.0
	string srcSvelte; /// src-svelte/…
	string srcD; /// src-d/…  (libwasm IR; empty for host-only)
	string srcTs; /// src-ts/modules/generated/…  (lang=ts jsExports; empty if none)
	string host; /// webserver/source/generated/…  (vibe.0; empty for wasm-only)

	string toJson() const
	{
		return format(
			`{"kitRel":"%s","kind":"%s","cell":"%s","runtime":"%s","srcSvelte":"%s","srcD":"%s","srcTs":"%s","host":"%s"}`,
			esc(kitRel), esc(kind), esc(cell), esc(runtime),
			esc(srcSvelte), esc(srcD), esc(srcTs), esc(host)
		);
	}
}

private string esc(string s)
{
	return s.replace(`\`, `/`).replace(`"`, `'`);
}

/// Kit folder `[slug]` / `[[lang]]` / `[...path]` → dest `_slug_` / `_lang_` / `_path_`.
/// Source `src-svelte` keeps the kit names; dests must be LDC-safe on Windows.
string sanitizeDestSeg(string s)
{
	if (s.length >= 5 && s[0] == '[' && s[1] == '[' && s[$ - 2] == ']' && s[$ - 1] == ']')
		return "_" ~ s[2 .. $ - 2] ~ "_";
	if (s.length >= 6 && s[0 .. 4] == "[..." && s[$ - 1] == ']')
		return "_" ~ s[4 .. $ - 1] ~ "_";
	if (s.length >= 3 && s[0] == '[' && s[$ - 1] == ']')
		return "_" ~ s[1 .. $ - 1] ~ "_";
	return s;
}

string sanitizeDestDir(string dir)
{
	auto s = dir.replace(`\`, `/`);
	string outp;
	size_t i;
	foreach (j, c; s)
	{
		if (c == '/')
		{
			auto part = sanitizeDestSeg(s[i .. j]);
			if (part.length)
			{
				if (outp.length)
					outp ~= "/";
				outp ~= part;
			}
			i = j + 1;
		}
	}
	auto last = sanitizeDestSeg(s[i .. $]);
	if (last.length)
	{
		if (outp.length)
			outp ~= "/";
		outp ~= last;
	}
	return outp;
}

private string posix(string a, string b = null, string c = null)
{
	string[] parts;
	if (a.length)
		parts ~= a.replace(`\`, `/`);
	if (b.length)
		parts ~= b.replace(`\`, `/`);
	if (c.length)
		parts ~= c.replace(`\`, `/`);
	string outp;
	foreach (p; parts)
	{
		if (!p.length)
			continue;
		if (outp.length && outp[$ - 1] != '/' && p[0] != '/')
			outp ~= "/";
		outp ~= p;
	}
	return outp;
}

/// Strip a leading src/ or src-svelte/ so both bun-project and ws paths map the same.
string normalizeKitRel(string p)
{
	auto s = p.replace(`\`, `/`);
	while (s.length && s[0] == '/')
		s = s[1 .. $];
	if (s.startsWith("src-svelte/"))
		s = s["src-svelte/".length .. $];
	else if (s.startsWith("src/"))
		s = s["src/".length .. $];
	else
	{
		// walkKit may hand a cwd-relative path that still contains src-svelte/.
		auto cut = s.indexOf("/src-svelte/");
		if (cut < 0)
			cut = s.indexOf("src-svelte/");
		if (cut >= 0)
		{
			auto from = s.indexOf("src-svelte/");
			s = s[from + "src-svelte/".length .. $];
		}
	}
	return s;
}

/// Same ident as the TS attach printer (routes/+page.svelte → routes__page_svelte).
string identFromRel(string rel)
{
	string s;
	foreach (c; rel)
	{
		if (isAlphaNum(c))
			s ~= c;
		else
			s ~= '_';
	}
	if (!s.length)
		s = "mod";
	if (s[0] >= '0' && s[0] <= '9')
		s = "m_" ~ s;
	return s;
}

private string dStem(string base)
{
	auto n = stripExtension(base);
	if (n.startsWith("+"))
		n = n[1 .. $];
	n = n.replace(".", "_");
	return n; // keep Svelte file case (ClickField.svelte → ClickField.d)
}

/// Map one kit-relative (or bun `src/…`) path onto svelte-engine-ws cells.
Fallthrough mapKitRel(string kitRel)
{
	auto rel = normalizeKitRel(kitRel);
	auto b = baseName(rel);
	auto dir = dirName(rel);
	if (dir == "." || dir == "")
		dir = "";
	dir = dir.replace(`\`, `/`);
	if (dir == ".")
		dir = "";
	// LDC 1.43 Windows globMatch asserts on `[` in argv. Dest dirs
	// cannot keep kit `[slug]` / `[[opt]]` / `[...rest]` segments.
	dir = sanitizeDestDir(dir);

	Fallthrough f;
	f.kitRel = rel;
	f.srcSvelte = posix("src-svelte", rel);

	if (b == "+page.svelte")
	{
		f.kind = "page";
		f.cell = "wasm";
		f.runtime = "libwasm+jsExports";
		f.srcD = posix("src-d", dir, "page.d");
		f.srcTs = posix("src-ts/modules/generated", identFromRel(rel) ~ ".ts");
		return f;
	}
	if (b == "+layout.svelte")
	{
		f.kind = "layout";
		f.cell = "wasm";
		f.runtime = "libwasm+jsExports";
		f.srcD = posix("src-d", dir, "layout.d");
		f.srcTs = posix("src-ts/modules/generated", identFromRel(rel) ~ ".ts");
		return f;
	}
	if (b == "+error.svelte")
	{
		f.kind = "error";
		f.cell = "wasm";
		f.runtime = "libwasm";
		f.srcD = posix("src-d", dir, "error.d");
		return f;
	}
	if (b.startsWith("+page.server."))
	{
		f.kind = "page_server";
		f.cell = "host";
		f.runtime = "vibe.0";
		f.host = posix("webserver/source/generated", dir, "page_server.d");
		return f;
	}
	if (b.startsWith("+layout.server."))
	{
		f.kind = "layout_server";
		f.cell = "host";
		f.runtime = "vibe.0";
		f.host = posix("webserver/source/generated", dir, "layout_server.d");
		return f;
	}
	if (b.startsWith("+server."))
	{
		f.kind = "endpoint";
		f.cell = "host";
		f.runtime = "vibe.0";
		f.host = posix("webserver/source/generated", dir, "server.d");
		return f;
	}
	if (b.startsWith("hooks.server."))
	{
		f.kind = "hooks";
		f.cell = "host";
		f.runtime = "vibe.0";
		f.host = "webserver/source/generated/hooks.d";
		return f;
	}
	if (extension(b) == ".svelte")
	{
		string pkg, rest;
		if (splitExtPackage(rel, pkg, rest))
		{
			f.kind = "ext_component";
			f.cell = "wasm";
			f.runtime = "libwasm+jsExports";
			f.srcSvelte = posix("src-svelte/ext", pkg, rest);
			auto restDir = dirName(rest);
			if (restDir == "." || restDir == "")
				restDir = "";
			f.srcD = posix(posix("src-d/ext", pkg), sanitizeDestDir(restDir), dStem(b) ~ ".d");
			f.srcTs = posix("src-ts/modules/generated", identFromRel("ext/" ~ pkg ~ "/" ~ rest) ~ ".ts");
			return f;
		}
		f.kind = "component";
		f.cell = "wasm";
		f.runtime = "libwasm+jsExports";
		f.srcD = posix("src-d", dir, dStem(b) ~ ".d");
		f.srcTs = posix("src-ts/modules/generated", identFromRel(rel) ~ ".ts");
		return f;
	}
	if (rel.replace(`\`, `/`).startsWith("public/"))
	{
		f.kind = "static";
		f.cell = "host";
		f.runtime = "vibe.0-static";
		f.srcSvelte = rel.replace(`\`, `/`);
		return f;
	}
	if (extension(b) == ".d")
	{
		f.kind = "d";
		f.cell = "wasm";
		f.runtime = "libwasm";
		f.srcD = posix("src-d", sanitizeDestDir(rel));
		return f;
	}
	if (extension(b) == ".ts" || extension(b) == ".js")
	{
		f.kind = "ts_helper";
		f.cell = "wasm";
		f.runtime = "src-ts";
		f.srcSvelte = "";
		f.srcTs = posix("src-ts/modules/helpers", sanitizeDestDir(rel));
		return f;
	}
	if (extension(b) == ".scss" || extension(b) == ".sass" || extension(b) == ".css")
	{
		f.kind = "style";
		f.cell = "wasm";
		f.runtime = "vite-css";
		f.srcSvelte = "";
		auto n = rel.replace(`\`, `/`);
		f.srcTs = n.startsWith("styles/") ? n : posix("styles", sanitizeDestDir(rel));
		return f;
	}
	f.kind = "unknown";
	f.cell = "wasm";
	return f;
}

/// `node_modules/svelte-grid/src/Grid.svelte` or `@scope/pkg/...`.
private bool splitExtPackage(string rel, out string pkg, out string rest)
{
	auto s = rel.replace(`\`, `/`);
	enum pfx = "node_modules/";
	if (!s.startsWith(pfx))
		return false;
	s = s[pfx.length .. $];
	if (!s.length)
		return false;
	if (s[0] == '@')
	{
		auto slash = s.indexOf('/');
		if (slash < 0)
			return false;
		auto slash2 = s.indexOf('/', slash + 1);
		if (slash2 < 0)
		{
			pkg = s;
			rest = "";
			return true;
		}
		pkg = s[0 .. slash2];
		rest = s[slash2 + 1 .. $];
		return true;
	}
	auto slash = s.indexOf('/');
	if (slash < 0)
	{
		pkg = s;
		rest = "";
		return true;
	}
	pkg = s[0 .. slash];
	rest = s[slash + 1 .. $];
	return true;
}

private struct KitSeg
{
	string text; /// URLRouter token (`shop`, `:lang`, `*`); empty = skip
	bool optional;
}

/// SvelteKit file path → full libwasm URLRouter pattern
/// (`[slug]` → `:slug`, `(groups)` stripped, `[[opt]]` kept as `:opt`).
string kitToPattern(string kitRel)
{
	auto ps = kitToPatterns(kitRel);
	return ps.length ? ps[$ - 1] : "";
}

/// Same path → every registration. `[[optional]]` expands to omit + include.
string[] kitToPatterns(string kitRel)
{
	auto rel = normalizeKitRel(kitRel);
	if (rel.startsWith("routes/"))
		rel = rel["routes/".length .. $];
	auto b = baseName(rel);
	if (b != "+page.svelte" && b != "+layout.svelte")
		return [];
	auto dir = dirName(rel).replace(`\`, `/`);
	if (dir == "." || dir == "")
		return ["/"];
	KitSeg[] parts;
	size_t i;
	foreach (j, c; dir)
	{
		if (c == '/')
		{
			auto s = kitSeg(dir[i .. j]);
			i = j + 1;
			if (s.text.length)
				parts ~= s;
		}
	}
	auto last = kitSeg(dir[i .. $]);
	if (last.text.length)
		parts ~= last;
	if (!parts.length)
		return ["/"];
	return expandOptional(parts);
}

private string[] expandOptional(KitSeg[] parts)
{
	string[] acc;
	void rec(size_t i, string[] cur)
	{
		if (i == parts.length)
		{
			acc ~= joinSegs(cur);
			return;
		}
		if (parts[i].optional)
		{
			rec(i + 1, cur);
			rec(i + 1, cur ~ parts[i].text);
		}
		else
			rec(i + 1, cur ~ parts[i].text);
	}
	rec(0, []);
	return acc;
}

private string joinSegs(string[] segs)
{
	if (!segs.length)
		return "/";
	string outp = "/";
	foreach (n, s; segs)
	{
		if (n)
			outp ~= "/";
		outp ~= s;
	}
	return outp;
}

private KitSeg kitSeg(string part)
{
	KitSeg s;
	if (!part.length || part == ".")
		return s;
	if (part[0] == '(' && part[$ - 1] == ')')
		return s;
	if (part.length >= 4 && part[0] == '[' && part[1] == '['
			&& part[$ - 1] == ']' && part[$ - 2] == ']')
	{
		s.text = ":" ~ part[2 .. $ - 2];
		s.optional = true;
		return s;
	}
	if (part.length >= 2 && part[0] == '[' && part[$ - 1] == ']')
	{
		auto inner = part[1 .. $ - 1];
		s.text = inner.startsWith("...") ? "*" : ":" ~ inner;
		return s;
	}
	s.text = part;
	return s;
}

Fallthrough[] mapWorkspace(string ws)
{
	auto acc = appender!(Fallthrough[]);
	auto srcSvelte = buildPath(ws, "src-svelte");
	if (!exists(srcSvelte))
		return acc.data;
	foreach (k; walkKit(srcSvelte))
	{
		auto rel = relativePath(k.path, srcSvelte).replace(`\`, `/`);
		acc ~= mapKitRel(rel);
	}
	return acc.data;
}

string fallthroughDocument(string ws, Fallthrough[] xs)
{
	auto acc = appender!string();
	acc ~= `{"schema":"svelte-d-fallthrough/v1",`;
	acc ~= `"principle":"kit-syntax-falls-through-to-equivalent-ws-structure",`;
	acc ~= `"workspace":"` ~ esc(ws) ~ `",`;
	acc ~= `"entries":[`;
	foreach (i, e; xs)
	{
		if (i)
			acc ~= ",";
		acc ~= e.toJson();
	}
	acc ~= "]}\n";
	return acc.data;
}

void writeFallthroughFile(string ws)
{
	import std.file : mkdirRecurse;

	auto xs = mapWorkspace(ws);
	auto dir = buildPath(ws, ".svelte-d");
	mkdirRecurse(dir);
	write(buildPath(dir, "fallthrough.json"), fallthroughDocument(ws, xs));
}
