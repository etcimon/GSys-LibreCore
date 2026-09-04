// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Overlay a bun + svelte-kit project `src/` onto the dropped workspace.
// svelte-engine is an unpopulated runtime bootstrap; app Svelte compiles
// into svelte-engine-ws. Does not mutate the template.
//
// Also copies project-local TS/SCSS helpers and .svelte files imported
// from node_modules/<pkg> (grids/graphs) onto mapped dests. Does not
// merge package.json dependencies and does not invent a second stack.
module svelte_d.workspace.ingest;

import std.algorithm : canFind, startsWith, endsWith;
import std.file;
import std.json;
import std.path;
import std.string : replace, indexOf, strip;
import svelte_d.fallthrough;

/// Bun + SvelteKit project (`src/routes` or `src-svelte`) to ingest on compile.
string detectKitProject(string start = null)
{
	auto p = start.length ? start : getcwd();
	if (exists(buildPath(p, "src", "routes")) && isDir(buildPath(p, "src", "routes")))
		return p;
	if (exists(buildPath(p, "src-svelte")) && isDir(buildPath(p, "src-svelte")))
		return p;
	return "";
}

/// Project kit root: `src/` (SvelteKit) or `src-svelte/` (ws-shaped).
string projectKitRoot(string project)
{
	auto src = buildPath(project, "src");
	if (exists(src) && isDir(src))
		return src;
	auto alt = buildPath(project, "src-svelte");
	if (exists(alt) && isDir(alt))
		return alt;
	return "";
}

/// Copy project routes/lib/hooks into ws/src-svelte (overwrite those paths).
/// Engine goldens not named by the project stay (Panel, Combo, +page stub).
/// Then local TS/SCSS helpers and imported node_modules `.svelte`.
void ingestProject(string project, string ws)
{
	auto kit = projectKitRoot(project);
	if (!kit.length)
		throw new Exception("project has no src/ or src-svelte/: " ~ project);
	copyTree(buildPath(kit, "routes"), buildPath(ws, "src-svelte", "routes"));
	copyTree(buildPath(kit, "lib"), buildPath(ws, "src-svelte", "lib"));
	auto hooks = buildPath(kit, "hooks.server.d");
	if (exists(hooks) && isFile(hooks))
	{
		auto dest = buildPath(ws, "src-svelte", "hooks.server.d");
		mkdirRecurse(dirName(dest));
		copy(hooks, dest);
	}
	ingestLocalHelpers(project, kit, ws);
	ingestImportedSvelte(project, kit, ws);
	ingestPublicDir(project, ws);
}

/// Project `public/` → ws `public/` (vibe.0 serveStaticFiles). Does not delete wasm.
void ingestPublicDir(string project, string ws)
{
	auto from = buildPath(project, "public");
	if (!exists(from) || !isDir(from))
		return;
	auto to = buildPath(ws, "public");
	mkdirRecurse(to);
	foreach (e; dirEntries(from, SpanMode.breadth))
	{
		auto rel = relativePath(e.name, from);
		auto dest = buildPath(to, rel);
		auto b = baseName(e.name);
		if (b == "node_modules" || b == ".git")
			continue;
		if (e.isDir)
		{
			mkdirRecurse(dest);
			continue;
		}
		if (!e.isFile)
			continue;
		auto ext = extension(b);
		if (ext == ".wasm" || ext == ".exe" || ext == ".pdb")
			continue;
		mkdirRecurse(dirName(dest));
		copy(e.name, dest);
	}
}

/// Standalone `.ts`/`.js` and `.scss`/`.css` under the project kit → mapped ws dests.
void ingestLocalHelpers(string project, string kit, string ws)
{
	if (!kit.length || !exists(kit))
		return;
	foreach (e; dirEntries(kit, SpanMode.depth))
	{
		if (!e.isFile)
			continue;
		auto b = baseName(e.name);
		if (b.startsWith("+page.server.") || b.startsWith("+layout.server.")
				|| b.startsWith("+server.") || b.startsWith("hooks.server."))
			continue;
		auto ext = extension(b);
		if (ext != ".ts" && ext != ".js" && ext != ".scss" && ext != ".sass" && ext != ".css")
			continue;
		auto rel = relativePath(e.name, kit).replace(`\`, `/`);
		auto m = mapKitRel(rel);
		if (!m.srcTs.length)
			continue;
		auto dest = buildPath(ws, m.srcTs);
		mkdirRecurse(dirName(dest));
		copy(e.name, dest);
	}
	auto styles = buildPath(project, "styles");
	if (exists(styles) && isDir(styles))
	{
		foreach (e; dirEntries(styles, SpanMode.depth))
		{
			if (!e.isFile)
				continue;
			auto ext = extension(e.name);
			if (ext != ".scss" && ext != ".sass" && ext != ".css")
				continue;
			auto rel = "styles/" ~ relativePath(e.name, styles).replace(`\`, `/`);
			auto m = mapKitRel(rel);
			if (!m.srcTs.length)
				continue;
			auto dest = buildPath(ws, m.srcTs);
			mkdirRecurse(dirName(dest));
			copy(e.name, dest);
		}
	}
}

/// `.svelte` imported from node_modules (not relative, not $app) → src-svelte/ext/.
void ingestImportedSvelte(string project, string kit, string ws)
{
	bool[string] seen;
	string[] queue;
	void consider(string path)
	{
		if (!path.length || !exists(path) || !isFile(path))
			return;
		auto n = path.replace(`\`, `/`);
		if (n in seen)
			return;
		seen[n] = true;
		foreach (spec; scanImportSpecs(readText(path)))
			queue ~= spec;
	}
	if (exists(kit))
	{
		foreach (e; dirEntries(kit, SpanMode.depth))
			if (e.isFile)
				consider(e.name);
	}
	auto srcSv = buildPath(ws, "src-svelte");
	if (exists(srcSv))
	{
		foreach (e; dirEntries(srcSv, SpanMode.depth))
			if (e.isFile)
				consider(e.name);
	}
	size_t guard;
	while (queue.length && guard < 64)
	{
		++guard;
		auto spec = queue[0];
		queue = queue[1 .. $];
		auto src = resolveSvelteSpec(project, spec);
		if (!src.length)
			continue;
		auto nmRel = nodeModulesRel(project, src);
		if (!nmRel.length)
			continue;
		auto m = mapKitRel(nmRel);
		if (!m.srcSvelte.length)
			continue;
		auto dest = buildPath(ws, m.srcSvelte);
		mkdirRecurse(dirName(dest));
		if (!exists(dest) || timeLastModified(src) > timeLastModified(dest))
			copy(src, dest);
		consider(src);
	}
}

/// `from 'pkg'` / `from "pkg/file.svelte"` / `import 'pkg'`. Skip relative and $app.
string[] scanImportSpecs(string src)
{
	string[] o;
	void take(string q)
	{
		size_t i;
		while (i < src.length)
		{
			auto j = indexOf(src, q, i);
			if (j < 0)
				break;
			auto start = j + q.length;
			auto end = indexOf(src, q[$ - 1], start);
			if (end < 0)
				break;
			auto spec = src[start .. end].strip;
			i = end + 1;
			if (!spec.length)
				continue;
			if (spec[0] == '.' || spec[0] == '/')
				continue;
			if (spec.startsWith("$app") || spec.startsWith("$env"))
				continue;
			if (spec == "svelte" || spec.startsWith("svelte/"))
				continue;
			if (spec == "libwasm" || spec.startsWith("libwasm."))
				continue;
			if (!canFind(o, spec))
				o ~= spec;
		}
	}
	take("from '");
	take("from \"");
	take("import '");
	take("import \"");
	return o;
}

/// Absolute path to a .svelte file for an import specifier, or "".
string resolveSvelteSpec(string project, string spec)
{
	if (!spec.length)
		return "";
	auto nm = buildPath(project, "node_modules");
	if (spec.endsWith(".svelte"))
	{
		auto direct = buildPath(nm, spec);
		if (exists(direct) && isFile(direct))
			return direct;
	}
	string pkg, rest;
	splitPkg(spec, pkg, rest);
	if (!pkg.length)
		return "";
	auto pkgDir = buildPath(nm, pkg);
	if (!exists(pkgDir))
		return "";
	if (rest.length)
	{
		auto sub = buildPath(pkgDir, rest);
		if (exists(sub) && isFile(sub) && extension(sub) == ".svelte")
			return sub;
		auto subSv = sub ~ ".svelte";
		if (exists(subSv) && isFile(subSv))
			return subSv;
	}
	auto entry = packageSvelteEntry(pkgDir);
	if (entry.length && exists(entry) && isFile(entry))
		return entry;
	return "";
}

private string packageSvelteEntry(string pkgDir)
{
	auto pj = buildPath(pkgDir, "package.json");
	if (!exists(pj))
	{
		auto grid = buildPath(pkgDir, "Grid.svelte");
		if (exists(grid))
			return grid;
		return "";
	}
	try
	{
		auto j = parseJSON(readText(pj));
		foreach (key; ["svelte", "module", "main"])
		{
			if (key in j && j[key].type == JSONType.string)
			{
				auto rel = j[key].str;
				if (rel.endsWith(".svelte"))
				{
					auto p = buildPath(pkgDir, rel);
					if (exists(p))
						return p;
				}
			}
		}
	}
	catch (Exception)
	{
	}
	return "";
}

private void splitPkg(string spec, out string pkg, out string rest)
{
	auto s = spec.replace(`\`, `/`);
	if (s.startsWith("@"))
	{
		auto slash = s.indexOf('/');
		if (slash < 0)
		{
			pkg = s;
			return;
		}
		auto slash2 = s.indexOf('/', slash + 1);
		if (slash2 < 0)
		{
			pkg = s;
			return;
		}
		pkg = s[0 .. slash2];
		rest = s[slash2 + 1 .. $];
		return;
	}
	auto slash = s.indexOf('/');
	if (slash < 0)
	{
		pkg = s;
		return;
	}
	pkg = s[0 .. slash];
	rest = s[slash + 1 .. $];
}

private string nodeModulesRel(string project, string absFile)
{
	auto nm = buildNormalizedPath(project, "node_modules");
	auto a = buildNormalizedPath(absFile);
	auto n = a.replace(`\`, `/`);
	auto p = nm.replace(`\`, `/`);
	if (!n.startsWith(p))
		return "";
	auto rest = n[p.length .. $];
	while (rest.length && (rest[0] == '/' || rest[0] == '\\'))
		rest = rest[1 .. $];
	if (!rest.length)
		return "";
	return "node_modules/" ~ rest;
}

private void copyTree(string from, string to)
{
	if (!exists(from) || !isDir(from))
		return;
	mkdirRecurse(to);
	foreach (e; dirEntries(from, SpanMode.breadth))
	{
		auto rel = relativePath(e.name, from);
		auto dest = buildPath(to, rel);
		if (e.isDir)
			mkdirRecurse(dest);
		else if (e.isFile)
		{
			mkdirRecurse(dirName(dest));
			copy(e.name, dest);
		}
	}
}
