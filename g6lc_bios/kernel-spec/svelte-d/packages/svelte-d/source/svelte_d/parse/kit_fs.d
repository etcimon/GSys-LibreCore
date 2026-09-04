// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module svelte_d.parse.kit_fs;

import std.file;
import std.path;
import std.algorithm : startsWith;
import std.array : appender;

struct KitFile
{
	string path;
	string kind; // page | layout | error | page_server | layout_server | endpoint | component | d | hooks
}

/// Walk src-svelte/ the way SvelteKit walks src/routes, plus src-svelte/lib.
/// Filenames stay kit-shaped; fall-through (svelte_d.fallthrough) prefixes the cell.
KitFile[] walkKit(string srcSvelte)
{
	auto acc = appender!(KitFile[]);
	if (!exists(srcSvelte))
		return acc.data;
	foreach (e; dirEntries(srcSvelte, SpanMode.depth))
	{
		if (!e.isFile)
			continue;
		auto b = baseName(e.name);
		KitFile k;
		k.path = e.name;
		if (b == "+page.svelte")
			k.kind = "page";
		else if (b == "+layout.svelte")
			k.kind = "layout";
		else if (b == "+error.svelte")
			k.kind = "error";
		else if (b.startsWith("+page.server."))
			k.kind = "page_server";
		else if (b.startsWith("+layout.server."))
			k.kind = "layout_server";
		else if (b.startsWith("+server."))
			k.kind = "endpoint";
		else if (b.startsWith("hooks.server."))
			k.kind = "hooks";
		else if (extension(b) == ".svelte")
			k.kind = "component";
		else if (extension(b) == ".d")
			k.kind = "d";
		else
			continue;
		acc ~= k;
	}
	return acc.data;
}
