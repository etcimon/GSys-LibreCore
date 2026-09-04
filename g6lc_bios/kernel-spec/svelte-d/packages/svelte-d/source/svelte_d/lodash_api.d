// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Catalog of libwasm.lodash methods (from libwasm/source/libwasm/lodash.d).
// svelte-d does not link libwasm; it reads the source as text so lang=d
// Lodash IR stays in line with that API.
module svelte_d.lodash_api;

import std.algorithm : canFind, sort, uniq;
import std.array : appender, array;
import std.file : readText;
import std.path : buildPath;
import std.uni : isAlphaNum;
import svelte_d.workspace.drop : findLibwasmRoot;

string lodashSourcePath(string riscvDev = null)
{
	return buildPath(findLibwasmRoot(riscvDev), "source", "libwasm", "lodash.d");
}

/// Method names on `struct Lodash` plus `execute` (the only way a chain becomes a D value).
string[] scanLodashCatalog(string src)
{
	auto acc = appender!(string[]);
	enum p = "auto ref ";
	size_t i;
	while (i < src.length)
	{
		auto j = findFrom(src, p, i);
		if (j < 0)
			break;
		j += p.length;
		size_t k = j;
		while (k < src.length && (isAlphaNum(src[k]) || src[k] == '_'))
			k++;
		if (k > j && k < src.length && src[k] == '(')
		{
			auto name = src[j .. k];
			if (name != "initialize" && name != "this")
				acc ~= name;
		}
		i = k + 1;
	}
	if (canFind(src, "execute(") && !canFind(acc.data, "execute"))
		acc ~= "execute";
	auto u = acc.data.dup;
	sort(u);
	return u.uniq.array;
}

string[] loadLodashCatalog(string riscvDev = null)
{
	return scanLodashCatalog(readText(lodashSourcePath(riscvDev)));
}

/// Intersect `.name(` call sites in D source with the libwasm catalog.
string[] lodashMethodsUsed(string dsrc, string[] catalog)
{
	auto acc = appender!(string[]);
	size_t i;
	while (i + 1 < dsrc.length)
	{
		if (dsrc[i] != '.')
		{
			i++;
			continue;
		}
		size_t j = i + 1;
		if (j >= dsrc.length || !(isAlphaNum(dsrc[j]) || dsrc[j] == '_'))
		{
			i++;
			continue;
		}
		size_t k = j;
		while (k < dsrc.length && (isAlphaNum(dsrc[k]) || dsrc[k] == '_'))
			k++;
		if (k < dsrc.length && (dsrc[k] == '(' || dsrc[k] == '!'))
		{
			auto name = dsrc[j .. k];
			if (canFind(catalog, name) && !canFind(acc.data, name))
				acc ~= name;
		}
		i = k;
	}
	if (canFind(dsrc, "Lodash(") && !canFind(acc.data, "Lodash"))
		acc ~= "Lodash";
	return acc.data;
}

bool looksLikeLodash(string dsrc)
{
	return canFind(dsrc, "Lodash") || canFind(dsrc, "execute!") || canFind(dsrc, "defaultTo")
		|| canFind(dsrc, "VarType.");
}

private ptrdiff_t findFrom(string s, string sub, size_t start)
{
	import std.string : indexOf;

	auto n = indexOf(s[start .. $], sub);
	return n < 0 ? -1 : cast(ptrdiff_t) start + n;
}
