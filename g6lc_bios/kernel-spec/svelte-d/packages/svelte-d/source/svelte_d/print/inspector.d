// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Read-only IR inspector: lists debug-map entries. Does not execute IR.
module svelte_d.print.inspector;

import std.algorithm : sort;
import std.array : appender;
import std.conv : to;
import std.file : mkdirRecurse, write;
import std.path : buildPath;
import std.string : replace;
import svelte_d.print.debug_map;

void writeIrInspector(string ws)
{
	auto xs = collectDebugMap(ws);
	int[string] kinds;
	bool[string] destSeen;
	string[] dests;
	foreach (e; xs)
	{
		auto k = e.kind.length ? e.kind : "unknown";
		kinds[k] = (k in kinds) ? kinds[k] + 1 : 1;
		auto d = e.dest.replace(`\`, `/`);
		if (d.length && d !in destSeen)
		{
			destSeen[d] = true;
			dests ~= d;
		}
	}
	sort(dests);
	auto acc = appender!string();
	acc ~= `{"schema":"svelte-d-ir-inspector/v1",`;
	acc ~= `"principle":"D-IR-is-correctness-surface; inspector-is-read-only",`;
	acc ~= `"entries":` ~ to!string(xs.length) ~ `,`;
	acc ~= `"kinds":{`;
	bool firstK = true;
	foreach (k, n; kinds)
	{
		if (!firstK)
			acc ~= ",";
		firstK = false;
		acc ~= `"` ~ esc(k) ~ `":` ~ to!string(n);
	}
	acc ~= `},"dests":[`;
	foreach (i, d; dests)
	{
		if (i)
			acc ~= ",";
		acc ~= `"` ~ esc(d) ~ `"`;
	}
	acc ~= "]}\n";
	auto dir = buildPath(ws, ".svelte-d");
	mkdirRecurse(dir);
	write(buildPath(dir, "ir.json"), acc.data);
	auto pub = buildPath(ws, "public", "__svelte-d");
	mkdirRecurse(pub);
	write(buildPath(pub, "ir.json"), acc.data);
	auto pageDir = buildPath(pub, "ir");
	mkdirRecurse(pageDir);
	auto html = inspectorHtml();
	write(buildPath(pageDir, "index.html"), html);
	write(buildPath(pub, "ir.html"), html);
}

private string esc(string s)
{
	return s.replace(`\`, `/`).replace(`"`, `'`);
}

private string inspectorHtml()
{
	return `<!doctype html>
<meta charset="utf-8">
<title>svelte-d IR inspector</title>
<style>
  body { font: 14px/1.4 ui-sans-serif, system-ui, sans-serif; margin: 1.5rem; background: #111; color: #eee; }
  h1 { font-size: 1.1rem; }
  a { color: #7fb3d5; }
  input { width: 100%; max-width: 40rem; background: #1c1c1c; color: #eee; border: 1px solid #333; padding: .4rem .6rem; }
  table { border-collapse: collapse; width: 100%; margin-top: 1rem; font-size: 12px; }
  th, td { text-align: left; padding: .25rem .4rem; border-bottom: 1px solid #222; vertical-align: top; }
  .muted { color: #888; }
  code { font: 12px/1.3 ui-monospace, monospace; }
</style>
<h1>svelte-d IR inspector</h1>
<p class="muted">Read-only. Lists printed D IR → orig .svelte. Does not execute compile! / remount / wasm.</p>
<p><a href="/__svelte-d/overlay.html">overlay</a> · <a href="/__svelte-d/debug-map.json">debug-map.json</a> · <a href="/__svelte-d/wasm-names.json">wasm-names.json</a></p>
<p id="status">loading…</p>
<p><input id="q" placeholder="filter dest / orig / kind / name" autocomplete="off"></p>
<table>
  <thead><tr><th>kind</th><th>dest</th><th>orig</th><th>name</th></tr></thead>
  <tbody id="rows"></tbody>
</table>
<script>
var all = [];
function rowHtml(e) {
  return '<tr><td>' + esc(e.kind || '') + '</td><td><code>' + esc(e.dest || '') + ':' + (e.destLine || '') +
    '</code></td><td><code>' + esc(e.orig || '') + ':' + (e.origLine || '') + '</code></td><td>' + esc(e.name || '') + '</td></tr>';
}
function esc(s) {
  return String(s).replace(/[&<>"]/g, function (c) {
    return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c];
  });
}
function render() {
  var q = (document.getElementById('q').value || '').toLowerCase();
  var hit = all.filter(function (e) {
    if (!q) return true;
    return [e.dest, e.orig, e.kind, e.name].join(' ').toLowerCase().indexOf(q) >= 0;
  });
  document.getElementById('rows').innerHTML = hit.map(rowHtml).join('');
}
Promise.all([
  fetch('/__svelte-d/ir.json').then(function (r) { return r.json(); }),
  fetch('/__svelte-d/debug-map.json').then(function (r) { return r.json(); })
]).then(function (pair) {
  var ir = pair[0];
  var map = pair[1];
  all = Array.isArray(map.entries) ? map.entries : [];
  var kinds = ir.kinds || {};
  var kindTxt = Object.keys(kinds).sort().map(function (k) { return k + '=' + kinds[k]; }).join(' ');
  document.getElementById('status').textContent =
    'ir inspector · ' + all.length + ' entries · ' + kindTxt + ' · ' + (ir.schema || '');
  render();
}).catch(function (e) {
  document.getElementById('status').textContent = String(e);
});
document.getElementById('q').addEventListener('input', render);
</script>
`;
}
