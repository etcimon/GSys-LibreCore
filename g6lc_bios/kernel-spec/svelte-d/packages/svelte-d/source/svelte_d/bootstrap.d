// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Guiding development principle: Svelte / SvelteKit features and further
// development are accommodated by changes in svelte-engine / libwasm / vibe.0.
// An updated svelte-engine is integrated as svelte-engine-ws at compile time
// in the D IR format that engine already builds.
module svelte_d.bootstrap;

import std.array : appender, replace;
import std.digest.sha;
import std.file : exists, mkdirRecurse, read, write;
import std.path : buildPath;
import std.string : format;

struct Surface
{
	string path;
	string role;
	string runtime;
}

struct Accommodate
{
	string feature;
	string land;
	string runtime;
	string ws;
}

/// Required engine surfaces that compile-time bootstrap must present.
immutable Surface[] requiredSurfaces = [
	Surface("src-d/app.d", "libwasm-root", "libwasm"),
	Surface("src-d/pglite.d", "persistence", "libwasm"),
	Surface("src-d/dock.d", "dynamic-ui", "libwasm"),
	Surface("src-ts/modules/index.ts", "jsExports", "libwasm"),
	Surface("src-ts/modules/libwasm.ts", "wasm-glue", "libwasm"),
	Surface("src-svelte/routes/+page.svelte", "kit-source", "source"),
	Surface("webserver/source/app.d", "vibe0-host", "vibe.0"),
	Surface("webserver/dub.sdl", "host-cell", "vibe.0"),
	Surface("dub.sdl", "wasm-cell", "libwasm"),
];

/// Where a kit capability is allowed to grow. svelte-d only prints these shapes.
immutable Accommodate[] accommodateTable = [
	Accommodate("markup/elements/components", "svelte-engine/src-d", "libwasm", "src-d"),
	Accommodate("script lang=d", "svelte-engine/src-d", "libwasm", "src-d"),
	Accommodate("script lang=ts / jsExports", "svelte-engine/src-ts", "libwasm", "src-ts/modules"),
	Accommodate("this.update / dynamic UI", "svelte-engine/src-d", "libwasm", "src-d"),
	Accommodate("routes +page/+layout", "svelte-engine/src-svelte", "libwasm", "src-svelte + src-d"),
	Accommodate("+page.server / +server / load / actions", "svelte-engine/webserver", "vibe.0", "webserver"),
	Accommodate("persistence / PgLite", "svelte-engine/src-d/pglite.d", "libwasm", "src-d/pglite.d"),
	Accommodate("Lodash chains / execute!T", "svelte-engine/src-d + libwasm.lodash", "libwasm", "src-d"),
	Accommodate("bindings Document/Window/console", "svelte-engine/src-d + libwasm.bindings", "libwasm", "src-d"),
	Accommodate("types Handle/Eval/JSON/VarType", "svelte-engine/src-d + libwasm.types", "libwasm", "src-d"),
	Accommodate("kit routes / URLRouter", "svelte-engine + libwasm.router", "libwasm", "src-d/kit_router.d"),
	Accommodate("$app / $env static", "svelte-engine/.env + generated kit enums", "libwasm+vibe.0", "src-d/kit + webserver/source/generated/kit"),
	Accommodate("kit admin PG/Redis/JSON", "svelte-engine/webserver helpers connectDB/connectCache", "vibe.0", "webserver + routes/admin"),
	Accommodate("NodeDef / NamedNode / @prop / @callback / compile!", "svelte-engine/src-d + libwasm.dom", "libwasm", "src-d"),
	Accommodate("{#each} list events / HTMLArray / inject!", "svelte-engine/src-d + libwasm.array", "libwasm", "src-d"),
	Accommodate("HMR dumpApp/loadApp", "svelte-engine + libwasm", "libwasm", "src-ts + src-d"),
	Accommodate("new kit syntax", "update svelte-engine; titled libwasm or vibe.0 seam if needed", "engine-first", "svelte-engine-ws"),
];

private string esc(string s)
{
	return s.replace(`\`, `/`).replace(`"`, `'`);
}

private string shortHash(string path)
{
	if (!exists(path))
		return "";
	auto h = toHexString(sha256Of(cast(ubyte[]) read(path))).idup;
	return h.length >= 16 ? h[0 .. 16] : h;
}

string[] missingSurfaces(string root)
{
	auto acc = appender!(string[]);
	foreach (s; requiredSurfaces)
		if (!exists(buildPath(root, s.path)))
			acc ~= s.path;
	return acc.data;
}

string bootstrapDocument(string ws, string srcTemplate)
{
	auto acc = appender!string();
	acc ~= `{"schema":"svelte-d-bootstrap/v1",`;
	acc ~= `"principle":"kit-features-accommodated-by-engine-libwasm-vibe0",`;
	acc ~= `"integratedAt":"compile-time",`;
	acc ~= `"irFormat":"libwasm-d+vibe.0-d",`;
	acc ~= `"template":"` ~ esc(srcTemplate) ~ `",`;
	acc ~= `"workspace":"` ~ esc(ws) ~ `",`;
	acc ~= `"surfaces":[`;
	foreach (i, s; requiredSurfaces)
	{
		if (i)
			acc ~= ",";
		auto present = exists(buildPath(ws, s.path)) ? "true" : "false";
		acc ~= format(`{"path":"%s","role":"%s","runtime":"%s","present":%s}`,
			esc(s.path), esc(s.role), esc(s.runtime), present);
	}
	acc ~= `],"accommodate":[`;
	foreach (i, a; accommodateTable)
	{
		if (i)
			acc ~= ",";
		acc ~= format(`{"feature":"%s","land":"%s","runtime":"%s","ws":"%s"}`,
			esc(a.feature), esc(a.land), esc(a.runtime), esc(a.ws));
	}
	acc ~= `],"templateFiles":[`;
	string[] keys = [
		"AGENTS.md", "src-d/app.d", "src-d/pglite.d", "src-d/dock.d",
		"webserver/source/app.d", "dub.sdl", "src-svelte/routes/+page.svelte"
	];
	foreach (i, rel; keys)
	{
		if (i)
			acc ~= ",";
		acc ~= format(`{"path":"%s","hash":"%s"}`, esc(rel), shortHash(buildPath(srcTemplate, rel)));
	}
	acc ~= "]}\n";
	return acc.data;
}

void writeBootstrapFile(string ws, string srcTemplate)
{
	import std.path : absolutePath;

	// Never mutate the golden svelte-engine template.
	if (absolutePath(ws) == absolutePath(srcTemplate))
		return;
	mkdirRecurse(buildPath(ws, ".svelte-d"));
	write(buildPath(ws, ".svelte-d", "bootstrap.json"), bootstrapDocument(ws, srcTemplate));
}

/// 0 = all required surfaces present in ws; 1 = some missing.
int verifyBootstrap(string ws)
{
	auto miss = missingSurfaces(ws);
	return miss.length == 0 ? 0 : 1;
}
