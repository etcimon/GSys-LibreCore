// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module svelte_d.capi;

import std.string : fromStringz;
import svelte_d.workspace.drop;
import svelte_d.parse.svelte;
import svelte_d.compile;

/// bun:ffi / D-link C ABI. 0 = ok, nonzero = fail.
/// Paths are UTF-8 C strings; null dest → default svelte-engine-ws.

extern (C) export int svelte_d_drop_ws(const(char)* destZ, int force)
{
	try
	{
		auto root = findRiscvDev();
		auto dest = (destZ && destZ[0])
			? fromStringz(destZ).idup
			: defaultWorkspaceDir(root);
		dropWorkspace(dest, templateDir(root), force != 0);
		return 0;
	}
	catch (Exception)
	{
		return 1;
	}
}

extern (C) export int svelte_d_compile(const(char)* wsZ)
{
	try
	{
		auto root = findRiscvDev();
		auto ws = (wsZ && wsZ[0]) ? fromStringz(wsZ).idup : defaultWorkspaceDir(root);
		return compileWorkspace(ws);
	}
	catch (Exception)
	{
		return 1;
	}
}

extern (C) export int svelte_d_parse_svelte(const(char)* pathZ)
{
	try
	{
		if (!pathZ || !pathZ[0])
			return 1;
		auto t = parseSvelteFile(fromStringz(pathZ).idup);
		if (!t.successful || !scriptsOk(t))
			return 2;
		return 0;
	}
	catch (Exception)
	{
		return 1;
	}
}

extern (C) export int svelte_d_version()
{
	return 1;
}
