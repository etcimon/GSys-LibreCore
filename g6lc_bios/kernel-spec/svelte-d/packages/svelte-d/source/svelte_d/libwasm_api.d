// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Catalogs for libwasm.bindings, libwasm.types, and libwasm.router.
// svelte-d reads those sources as text; it does not link the wasm cell.
module svelte_d.libwasm_api;

import std.algorithm : canFind, sort, uniq;
import std.array : appender, array;
import std.file : dirEntries, exists, SpanMode;
import std.path : baseName, buildPath, stripExtension;
import svelte_d.lodash_api : looksLikeLodash;
import svelte_d.workspace.drop : findLibwasmRoot;

immutable string[] coreTypes = [
	"Handle", "Eval", "JsHandle", "JSON", "VarType",
	"entering", "leaving", "child", "prop", "callback"
];

immutable string[] routerNames = [
	"URLRouter", "RouterEvent", "registerRoutes", "setupRouter",
	"navigateTo", "setBasePath", "router", "Direction", "entering", "leaving"
];

immutable string[] coreBindings = [
	"Document", "Window", "Console", "Location", "History",
	"Fetch", "MouseEvent", "HTMLInputElement", "Request", "Response"
];

string bindingsDir(string riscvDev = null)
{
	return buildPath(findLibwasmRoot(riscvDev), "source", "libwasm", "bindings");
}

string[] loadBindingsCatalog(string riscvDev = null)
{
	auto acc = appender!(string[]);
	auto dir = bindingsDir(riscvDev);
	if (!exists(dir))
		return acc.data;
	foreach (e; dirEntries(dir, "*.d", SpanMode.shallow))
	{
		auto b = stripExtension(baseName(e.name));
		if (b != "package")
			acc ~= b;
	}
	auto u = acc.data.dup;
	sort(u);
	return u.uniq.array;
}

string[] typesUsed(string dsrc)
{
	auto acc = appender!(string[]);
	foreach (t; coreTypes)
		if (canFind(dsrc, t) && !canFind(acc.data, t))
			acc ~= t;
	return acc.data;
}

string[] bindingsUsed(string dsrc, string[] catalog)
{
	auto acc = appender!(string[]);
	foreach (b; catalog)
	{
		if (b.length < 3)
			continue;
		if ((canFind(dsrc, b) || canFind(dsrc, b.toLowerCall())) && !canFind(acc.data, b))
			acc ~= b;
	}
	if (canFind(dsrc, "document(") && !canFind(acc.data, "Document"))
		acc ~= "Document";
	if (canFind(dsrc, "window(") && !canFind(acc.data, "Window"))
		acc ~= "Window";
	if (canFind(dsrc, "console.") && !canFind(acc.data, "Console"))
		acc ~= "Console";
	return acc.data;
}

string[] routerUsed(string dsrc)
{
	auto acc = appender!(string[]);
	foreach (n; routerNames)
		if (canFind(dsrc, n) && !canFind(acc.data, n))
			acc ~= n;
	return acc.data;
}

bool looksLikeBindings(string dsrc)
{
	return canFind(dsrc, "document(") || canFind(dsrc, "window(") || canFind(dsrc, "console.")
		|| canFind(dsrc, "Document") || canFind(dsrc, "location()");
}

bool looksLikeRouter(string dsrc)
{
	return canFind(dsrc, "navigateTo") || canFind(dsrc, "URLRouter") || canFind(dsrc, "RouterEvent")
		|| canFind(dsrc, "registerRoutes") || canFind(dsrc, "@entering") || canFind(dsrc, "setBasePath");
}

bool looksLikeTypes(string dsrc)
{
	return canFind(dsrc, "Handle") || canFind(dsrc, "Eval(") || canFind(dsrc, "JsHandle")
		|| canFind(dsrc, "JSON") || canFind(dsrc, "VarType");
}

bool looksLikeLibwasm(string dsrc)
{
	return looksLikeLodash(dsrc) || looksLikeBindings(dsrc) || looksLikeRouter(dsrc)
		|| looksLikeTypes(dsrc) || canFind(dsrc, "mixin NodeDef") || canFind(dsrc, "mixin Spa");
}

private string toLowerCall(string s)
{
	if (!s.length)
		return s;
	char c = cast(char) s[0];
	if (c >= 'A' && c <= 'Z')
		c = cast(char)(c + 32);
	return [c].idup ~ s[1 .. $] ~ "(";
}
