// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Print <script lang="d"> into svelte-engine-ws/src-d at the fall-through
// path. Bodies that already use libwasm Lodash are kept; execute!T() stays
// the only way a chain becomes a D value.
module svelte_d.print.d_attach;

import std.algorithm : canFind, sort;
import std.array : join;
import std.file;
import std.path : buildPath, dirName, stripExtension;
import std.string : replace, strip, indexOf;
import svelte_d.parse.svelte;
import svelte_d.parse.dlang;
import svelte_d.fallthrough;
import svelte_d.lodash_api;
import svelte_d.libwasm_api;
import svelte_d.parse.markup;
import svelte_d.print.dom_print;
import svelte_d.print.d_imports;
import svelte_d.print.cross_call;
import svelte_d.workspace.files;
import std.path : baseName;

struct DAttach
{
	string dest; /// workspace-relative posix path
	string[] lodashMethods;
	string[] bindings;
	string[] types;
	string[] router;
	string[] udas;
	string[] authorImports;
	string[] rejectedImports;
	bool isDom;
	string detail;
	string parseKind;
	bool ok = true;
}

private string moduleFromDest(string dest)
{
	auto s = dest.replace(`\`, `/`);
	if (s.length >= 6 && s[0 .. 6] == "src-d/")
		s = s[6 .. $];
	s = stripExtension(s);
	string mod;
	foreach (part; splitSlash(s))
	{
		if (!part.length)
			continue;
		if (mod.length)
			mod ~= ".";
		mod ~= identPart(part);
	}
	return mod.length ? mod : "app";
}

private string[] splitSlash(string s)
{
	string[] outp;
	size_t i;
	foreach (j, c; s)
	{
		if (c == '/')
		{
			outp ~= s[i .. j];
			i = j + 1;
		}
	}
	outp ~= s[i .. $];
	return outp;
}

private string identPart(string part)
{
	string s;
	foreach (c; part)
	{
		if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_')
			s ~= c;
		else
			s ~= '_';
	}
	if (!s.length)
		s = "x";
	if (s[0] >= '0' && s[0] <= '9')
		s = "m_" ~ s;
	return s;
}

private string pascalIdent(string s)
{
	string o;
	bool up = true;
	foreach (c; s)
	{
		if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')))
		{
			up = true;
			continue;
		}
		if (up)
		{
			if (c >= 'a' && c <= 'z')
				o ~= cast(char)(c - 32);
			else
				o ~= c;
			up = false;
		}
		else
			o ~= c;
	}
	return o.length ? o : "Comp";
}

/// Golden template src-d files are passthrough IR. Do not overwrite them.
private bool isTemplatePassthrough(string dest)
{
	auto p = dest.replace(`\`, `/`);
	if (p == "src-d/app.d" || p == "src-d/dock.d" || p == "src-d/navbar.d"
		|| p == "src-d/pglite.d" || p == "src-d/jshost.d" || p == "src-d/probe.d")
		return true;
	return false;
}

DAttach[] attachDModules(string ws, string srcSvelteRel, SvelteScan scan, string[] catalog)
{
	DAttach[] outp;
	auto ft = mapKitRel(srcSvelteRel);
	if (!ft.srcD.length || isTemplatePassthrough(ft.srcD))
		return outp;
	enum tmpl = import("d-module.d.tmpl");
	string[] bodies;
	foreach (s; scan.scripts)
	{
		if (s.lang != "d")
			continue;
		auto b = s.body.strip;
		if (b.length)
			bodies ~= b;
	}
	auto dest = ft.srcD;
	auto abs = buildPath(ws, dest);
	mkdirRecurse(dirName(abs));

	auto destPosix = dest.replace(`\`, `/`);
	auto forceDom = canFind(destPosix, "/page.d") || canFind(destPosix, "/layout.d")
		|| canFind(destPosix, "/error.d");
	if ((markupIsInteractive(scan.markup) || forceDom) && !canFind(bodies.join("\n"), "mixin NodeDef"))
	{
		auto host = pascalIdent(stripExtension(baseName(srcSvelteRel)));
		auto dp = printDomComponent(dest, srcSvelteRel, host, scan, forceDom);
		if (dp.generated.length)
		{
			auto txt = takeGenerated(dp, moduleFromDest(dest));
			writePrintedDest(abs, txt, DestCell.wasm);
			DAttach a;
			a.dest = dest.replace(`\`, `/`);
			a.isDom = true;
			a.udas = dp.udas;
			a.authorImports = dp.authorImports;
			a.rejectedImports = dp.rejectedImports;
			a.parseKind = dp.parseKind;
			a.detail = dp.detail;
			string err;
			if (!parseDFragment(txt, abs, err))
			{
				a.ok = false;
				a.detail = err;
			}
			outp ~= a;
			return outp;
		}
	}

	if (!bodies.length)
		return outp;

	auto body = bodies.join("\n\n");
	// Window.location() returns Location, not Optional — `.front` does not compile.
	body = body.replace("location().front.", "location().");
	auto peeled = peelAuthorImports(body, ImportCell.wasm);
	if (!looksLikeLibwasm(body) && !looksLikePhobos(body) && !canFind(body, "module ")
			&& !peeled.lines.length)
		return outp;
	body = peeled.body;
	DExport[] liftedEx;
	body = peelExternCExports(body, liftedEx);
	auto xc = analyzeCrossCall(srcSvelteRel, scan);
	if (liftedEx.length)
		xc.dExports = liftedEx;
	auto extras = emitTsThunks(xc) ~ emitDExportWrappers(xc);
	if (xc.dExports.length && !canFind(body, "registerDExports_" ~ xc.ident))
		body ~= "\nvoid _svelte_d_reg() { registerDExports_" ~ xc.ident ~ "(); }\n";
	string txt;
	if (canFind(bodies.join("\n"), "module "))
		txt = bodies.join("\n\n") ~ extras;
	else
	{
		auto imp = (canFind(body, "import libwasm;") || canFind(body, "import libwasm.")
				|| hasKeptPrefix(peeled, "libwasm"))
			? "" : "import libwasm;\n";
		imp ~= emitImportBlock(peeled);
		txt = tmpl.replace("{{SOURCE}}", srcSvelteRel.replace(`\`, `/`))
			.replace("{{MODULE}}", moduleFromDest(dest))
			.replace("{{IMPORT}}", imp)
			.replace("{{BODY}}", extras ~ body);
	}
	writePrintedDest(abs, txt, DestCell.wasm);

	DAttach a;
	a.dest = dest.replace(`\`, `/`);
	a.lodashMethods = lodashMethodsUsed(body, catalog);
	string[] bcat;
	try
		bcat = loadBindingsCatalog();
	catch (Exception)
	{
	}
	a.bindings = bindingsUsed(body, bcat);
	a.types = typesUsed(body);
	a.router = routerUsed(body);
	a.authorImports = keptMods(peeled);
	a.rejectedImports = rejectedMods(peeled);
	string err;
	if (!parseDFragment(txt, abs, err))
	{
		a.ok = false;
		a.detail = err;
	}
	else if (a.lodashMethods.length)
		a.detail = "libwasm-lodash";
	else if (a.router.length)
		a.detail = "libwasm-router";
	else if (a.bindings.length)
		a.detail = "libwasm-bindings";
	else if (a.types.length)
		a.detail = "libwasm-types";
	else if (hasKeptPrefix(peeled, "std"))
		a.detail = "libwasm-phobos";
	else
		a.detail = "libwasm-d";
	outp ~= a;
	return outp;
}

/// Hang printed lib/ components as @child on golden App. Idempotent markers.
void assembleAppChildren(string ws, string[] dests)
{
	import std.algorithm : sort;
	auto path = buildPath(ws, "src-d", "app.d");
	if (!exists(path) || !dests.length)
		return;
	string[] uniq;
	foreach (d; dests)
	{
		auto p = d.replace(`\`, `/`);
		if (p.length < 10 || p[0 .. 10] != "src-d/lib/")
			continue;
		auto type = pascalIdent(stripExtension(baseName(p)));
		// Golden App already owns these @child fields (src-d/dock.d, navbar.d).
		if (type == "Dock" || type == "NavBar" || type == "Main" || type == "App")
			continue;
		bool seen;
		foreach (u; uniq)
			if (u == p)
				seen = true;
		if (!seen)
			uniq ~= p;
	}
	sort(uniq);
	if (!uniq.length)
		return;
	string imps;
	string fields;
	foreach (p; uniq)
	{
		auto type = pascalIdent(stripExtension(baseName(p)));
		auto abs = buildPath(ws, p);
		// Procedural lang=d modules (bindings / lodash / types) have no NodeDef
		// struct — hanging them as @child does not compile.
		if (!exists(abs) || !canFind(readText(abs), "struct " ~ type))
			continue;
		auto field = camelIdent(type);
		imps ~= "import " ~ moduleFromDest(p) ~ ";\n";
		fields ~= "  @child " ~ type ~ " " ~ field ~ ";\n";
	}
	auto src = readText(path);
	src = replaceMarked(src, "// svelte-d:begin-imports", "// svelte-d:end-imports",
		imps, "import jshost;");
	src = replaceMarked(src, "// svelte-d:begin-children", "// svelte-d:end-children",
		fields, "  @child Dock dock;");
	writeIfChanged(path, src, DestCell.wasm);
	assembleAwaitReady(ws, dests);
}

/// After render, Spa calls App.ready. Hook `{#await}` `.await` (fork
/// asyncify) or `.then` fallback, and `{#each}{#if alias.field}` sync
/// there so setVisible / unmount see live handles (onMount during
/// _start does not).
void assembleAwaitReady(string ws, string[] dests)
{
	auto path = buildPath(ws, "src-d", "app.d");
	if (!exists(path))
		return;
	string calls;
	auto libDir = buildPath(ws, "src-d", "lib");
	if (exists(libDir))
	{
		string[] libs;
		foreach (de; dirEntries(libDir, "*.d", SpanMode.shallow))
			libs ~= de.name;
		sort(libs);
		foreach (name; libs)
		{
			auto txt = readText(name);
			auto type = pascalIdent(stripExtension(baseName(name)));
			auto recv = camelIdent(type);
			if (canFind(txt, "void wireAwait"))
				calls ~= "    " ~ recv ~ ".wireAwait();\n";
			if (canFind(txt, "void wireEach"))
				calls ~= "    " ~ recv ~ ".wireEach();\n";
			auto reg = "registerDExports_" ~ identFromRel("lib/" ~ stripExtension(baseName(name)) ~ ".svelte");
			if (canFind(txt, "void " ~ reg))
				calls ~= "    " ~ reg ~ "();\n";
		}
	}
	if (!calls.length)
		return;
	enum begin = "// svelte-d:begin-ready";
	enum end = "// svelte-d:end-ready";
	auto block = "  " ~ begin ~ "\n"
		~ "  void ready() @trusted\n  {\n" ~ calls
		~ "    router().navigateTo(document().location().front.pathname());\n  }\n"
		~ "  " ~ end ~ "\n";
	auto src = readText(path);
	auto b = src.indexOf(begin);
	if (b >= 0)
	{
		auto lineStart = b;
		while (lineStart > 0 && src[lineStart - 1] != '\n')
			lineStart--;
		auto e = src.indexOf(end);
		if (e > b)
		{
			auto afterEnd = e + end.length;
			if (afterEnd < src.length && src[afterEnd] == '\n')
				afterEnd++;
			writeIfChanged(path, src[0 .. lineStart] ~ block ~ src[afterEnd .. $],
				DestCell.wasm);
			return;
		}
	}
	auto needle = "  mixin NodeDef!\"div\";";
	auto i = src.indexOf(needle);
	if (i < 0)
		return;
	auto insAt = i;
	while (insAt > 0 && (src[insAt - 1] == ' ' || src[insAt - 1] == '\t'))
		insAt--;
	writeIfChanged(path, src[0 .. insAt] ~ block ~ src[i .. $], DestCell.wasm);
}

/// Use printed Dock.svelte / NavBar.svelte / +page.svelte on App instead of
/// handwritten `import dock` / `import navbar` / `struct Main`. Idempotent.
void assembleCompiledChrome(string ws)
{
	auto path = buildPath(ws, "src-d", "app.d");
	if (!exists(path))
		return;
	auto src = readText(path);
	auto orig = src;
	if (exists(buildPath(ws, "src-d", "lib", "Dock.d")))
	{
		src = src.replace("import dock;\n", "import lib.Dock;\n");
		src = src.replace("import dock;", "import lib.Dock;");
	}
	if (exists(buildPath(ws, "src-d", "lib", "NavBar.d")))
	{
		src = src.replace("import navbar;\n", "import lib.NavBar;\n");
		src = src.replace("import navbar;", "import lib.NavBar;");
	}
	auto hasKit = exists(buildPath(ws, "src-d", "kit_router.d"));
	auto hasPage = exists(buildPath(ws, "src-d", "routes", "page.d"));
	if (hasKit && hasPage && canFind(src, "kitRoutes") && canFind(src, "content.show(name)"))
	{
		src = src.replace("content.show(name);", "kitRoutes.rootPage.show(name);");
		src = src.replace("  @child Main content;\n", "");
	}
	if (src != orig)
		writeIfChanged(path, src, DestCell.wasm);
}

private string camelIdent(string pascal)
{
	if (!pascal.length)
		return pascal;
	char f = pascal[0];
	if (f >= 'A' && f <= 'Z')
		f = cast(char)(f + 32);
	return cast(string)(f ~ pascal[1 .. $]);
}

private string replaceMarked(string src, string begin, string end, string inner, string afterAnchor)
{
	auto block = begin ~ "\n" ~ inner ~ end ~ "\n";
	auto b = src.indexOf(begin);
	auto e = src.indexOf(end);
	if (b >= 0 && e > b)
	{
		auto afterEnd = e + end.length;
		if (afterEnd < src.length && src[afterEnd] == '\n')
			afterEnd++;
		return src[0 .. b] ~ block ~ src[afterEnd .. $];
	}
	auto a = src.indexOf(afterAnchor);
	if (a < 0)
		return src ~ "\n" ~ block;
	auto ins = a + afterAnchor.length;
	return src[0 .. ins] ~ "\n" ~ block ~ src[ins .. $];
}
