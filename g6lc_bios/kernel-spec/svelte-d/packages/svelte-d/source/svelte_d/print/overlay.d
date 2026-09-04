// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Compile/LDC diagnostics → public/__svelte-d/overlay (trace-only).
// Dest .d lines are rewritten onto orig .svelte via the debug map.
module svelte_d.print.overlay;

import std.array : appender;
import std.conv : to;
import std.file : mkdirRecurse, write;
import std.path : buildPath;
import std.string : replace;
import svelte_d.print.debug_map;

struct OverlayDiag
{
	string level = "error";
	string status;
	string source;
	string dest;
	string raw;

	this(string level_, string status_, string source_, string dest_, string raw_)
	{
		level = level_;
		status = status_;
		source = source_;
		dest = dest_;
		raw = raw_;
	}
}

/// Rewrite LDC `file.d(line,col)` and `file.d:line` onto orig .svelte.
string rewriteDestText(DebugEntry[] xs, string text)
{
	if (!text.length)
		return text;
	auto acc = appender!string();
	size_t i;
	while (i < text.length)
	{
		auto hit = findDestFrame(text, i);
		if (hit.start < 0)
		{
			acc ~= text[i .. $];
			break;
		}
		acc ~= text[i .. hit.start];
		auto slice = text[hit.start .. hit.end];
		acc ~= slice;
		auto e = lookupDest(xs, hit.file, hit.line);
		if (e.orig.length)
			acc ~= " [svelte " ~ e.orig ~ ":" ~ to!string(e.origLine) ~ " kind=" ~ e.kind ~ "]";
		i = hit.end;
	}
	return acc.data;
}

void writeOverlay(string ws, size_t fail, OverlayDiag[] diags)
{
	auto map = collectDebugMap(ws);
	bool hasEach;
	foreach (e; map)
		if (e.kind == "each")
		{
			hasEach = true;
			break;
		}
	if (hasEach)
		diags ~= OverlayDiag("info", "hmr-each", "", "",
			"{#each} List/HTMLArray items serialize in dumpApp/loadApp as :l:N:[{item}...] (libwasm hmr.d)");
	auto acc = appender!string();
	acc ~= `{"schema":"svelte-d-overlay/v1",`;
	acc ~= `"principle":"D-IR-is-correctness-surface; overlay-is-trace-only",`;
	acc ~= `"ok":` ~ (fail == 0 ? "true" : "false") ~ `,`;
	acc ~= `"fail":` ~ to!string(fail) ~ `,`;
	acc ~= `"diagnostics":[`;
	foreach (i, d; diags)
	{
		if (i)
			acc ~= ",";
		auto rewritten = rewriteDestText(map, d.raw);
		if (rewritten == d.raw && d.source.length && !containsSvelteTag(rewritten))
			rewritten = d.raw ~ " [svelte " ~ d.source.replace(`\`, `/`) ~ "]";
		acc ~= `{"level":"` ~ esc(d.level.length ? d.level : "error")
			~ `","status":"` ~ esc(d.status)
			~ `","source":"` ~ esc(d.source)
			~ `","dest":"` ~ esc(d.dest)
			~ `","raw":"` ~ esc(d.raw)
			~ `","rewritten":"` ~ esc(rewritten) ~ `"}`;
	}
	acc ~= "]}\n";
	auto dir = buildPath(ws, ".svelte-d");
	mkdirRecurse(dir);
	write(buildPath(dir, "overlay.json"), acc.data);
	auto pub = buildPath(ws, "public", "__svelte-d");
	mkdirRecurse(pub);
	write(buildPath(pub, "overlay.json"), acc.data);
	auto pageDir = buildPath(pub, "overlay");
	mkdirRecurse(pageDir);
	auto html = overlayHtml();
	write(buildPath(pageDir, "index.html"), html);
	// Exact file so Vite does not SPA-fallback `/__svelte-d/overlay.html`.
	write(buildPath(pub, "overlay.html"), html);
}

private bool containsSvelteTag(string s)
{
	return s.length >= 9 && (indexOfTag(s) >= 0);
}

private int indexOfTag(string s)
{
	enum needle = "[svelte ";
	foreach (i; 0 .. s.length)
		if (i + needle.length <= s.length && s[i .. i + needle.length] == needle)
			return cast(int) i;
	return -1;
}

private struct FrameHit
{
	int start = -1;
	size_t end;
	string file;
	int line;
}

private FrameHit findDestFrame(string text, size_t from)
{
	FrameHit miss;
	foreach (i; from .. text.length)
	{
		if (i + 2 >= text.length || text[i] != '.' || text[i + 1] != 'd')
			continue;
		if (i + 2 < text.length && isIdentChar(text[i + 2]))
			continue;
		auto fileEnd = i + 2;
		auto fileStart = startOfPath(text, i);
		if (fileStart < 0)
			continue;
		auto file = text[fileStart .. fileEnd].replace(`\`, `/`);
		if (!looksLikeDest(file))
			continue;
		size_t p = fileEnd;
		int line;
		size_t end;
		if (p < text.length && text[p] == ':')
		{
			auto n = parseUint(text, p + 1);
			if (n.ok)
			{
				line = n.v;
				end = n.next;
			}
		}
		else if (p < text.length && text[p] == '(')
		{
			auto n = parseUint(text, p + 1);
			if (n.ok)
			{
				line = n.v;
				end = n.next;
				if (end < text.length && text[end] == ',')
				{
					auto c = parseUint(text, end + 1);
					if (c.ok)
						end = c.next;
				}
				if (end < text.length && text[end] == ')')
					end++;
			}
		}
		if (line <= 0)
			continue;
		FrameHit h;
		h.start = cast(int) fileStart;
		h.end = end ? end : fileEnd;
		h.file = file;
		h.line = line;
		return h;
	}
	return miss;
}

private struct ParsedUint
{
	bool ok;
	int v;
	size_t next;
}

private ParsedUint parseUint(string s, size_t i)
{
	ParsedUint r;
	r.next = i;
	if (i >= s.length || s[i] < '0' || s[i] > '9')
		return r;
	int n;
	while (i < s.length && s[i] >= '0' && s[i] <= '9')
	{
		n = n * 10 + (s[i] - '0');
		i++;
	}
	r.ok = true;
	r.v = n;
	r.next = i;
	return r;
}

private ptrdiff_t startOfPath(string text, size_t dotD)
{
	auto i = dotD;
	while (i > 0)
	{
		auto c = text[i - 1];
		if (isIdentChar(c) || c == '/' || c == '\\' || c == '.' || c == '[' || c == ']' || c == '-')
			i--;
		else
			break;
	}
	return i;
}

private bool isIdentChar(char c)
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

private bool looksLikeDest(string file)
{
	if (file.length < 3)
		return false;
	if (file[$ - 2 .. $] != ".d")
		return false;
	return true;
}

private DebugEntry lookupDest(DebugEntry[] xs, string destHint, int line)
{
	DebugEntry best;
	auto hint = destHint.replace(`\`, `/`);
	foreach (e; xs)
	{
		auto d = e.dest.replace(`\`, `/`);
		if (!(d == hint || endsWithPath(d, hint)))
			continue;
		if (e.destLine > line)
			continue;
		if (!best.orig.length || e.destLine > best.destLine)
			best = e;
	}
	return best;
}

private bool endsWithPath(string d, string hint)
{
	if (d.length >= hint.length && d[$ - hint.length .. $] == hint)
	{
		if (d.length == hint.length)
			return true;
		auto c = d[d.length - hint.length - 1];
		return c == '/' || c == '\\';
	}
	return false;
}

private string esc(string s)
{
	return s.replace(`\`, `/`).replace(`"`, `'`).replace("\n", " ").replace("\r", "");
}

private string overlayHtml()
{
	return `<!doctype html>
<meta charset="utf-8">
<title>svelte-d overlay</title>
<style>
  body { font: 14px/1.4 ui-sans-serif, system-ui, sans-serif; margin: 1.5rem; background: #111; color: #eee; }
  h1 { font-size: 1.1rem; }
  .ok { color: #7dcea0; }
  .fail { color: #f1948a; }
  pre { white-space: pre-wrap; background: #1c1c1c; padding: 1rem; }
</style>
<h1>svelte-d overlay</h1>
<p id="status">loading…</p>
<pre id="diags"></pre>
<script>
fetch('/__svelte-d/overlay.json').then(function (r) { return r.json(); }).then(function (j) {
  var el = document.getElementById('status');
  el.textContent = (j.ok ? 'compile clean' : ('compile fail=' + j.fail)) + ' · ' + (j.schema || '');
  el.className = j.ok ? 'ok' : 'fail';
  var lines = (j.diagnostics || []).map(function (d) {
    return (d.level || 'error') + ' ' + (d.status || '') + '\n' + (d.rewritten || d.raw || '');
  });
  document.getElementById('diags').textContent = lines.join('\n\n') || '(no diagnostics)';
}).catch(function (e) {
  document.getElementById('status').textContent = String(e);
  document.getElementById('status').className = 'fail';
});
</script>
`;
}
