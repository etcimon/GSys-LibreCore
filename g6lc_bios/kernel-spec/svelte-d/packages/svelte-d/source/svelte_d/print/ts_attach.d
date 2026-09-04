module svelte_d.print.ts_attach;

import std.file;
import std.path;
import std.string : replace, strip, indexOf;
import std.array : appender;
import std.conv : to;
import std.algorithm : sort, canFind;
import svelte_d.parse.svelte;
import svelte_d.fallthrough : identFromRel;
import svelte_d.workspace.files;
import svelte_d.print.cross_call;

/// Write each lang=ts script into src-ts/modules/generated (libwasm jsExports template).
/// Every exported function is registered on `window.__svelteD.ts[ident]` even
/// when no lang=d block calls it. Multiple tags get distinct mangled idents.
/// `npmOut` collects bare import specs for dest package.json fall-through.
string[] attachTsModules(string ws, string srcSvelteRel, SvelteScan scan, ref string[] npmOut)
{
	string[] idents;
	auto genDir = buildPath(ws, "src-ts", "modules", "generated");
	mkdirRecurse(genDir);
	size_t nInst, nMod;
	enum pkgTmpl = import("js-module.ts.tmpl");
	foreach (s; scan.scripts)
	{
		if (s.lang != "ts")
			continue;
		string id;
		if (s.moduleContext)
		{
			++nMod;
			id = identFromRel(srcSvelteRel) ~ "_mod" ~ (nMod > 1 ? to!string(nMod) : "");
		}
		else
		{
			++nInst;
			id = identFromRel(srcSvelteRel) ~ (nInst > 1 ? to!string(nInst) : "");
		}
		auto body = rewriteTsImports(s.body.strip, srcSvelteRel, npmOut);
		auto exps = parseTsExports(body);
		auto outTxt = pkgTmpl.replace("{{SOURCE}}", srcSvelteRel)
			.replace("{{BODY}}", body)
			.replace("{{WRAP}}", emitTsTrailer(id, exps, body));
		writeIfChanged(buildPath(genDir, id ~ ".ts"), outTxt, DestCell.meta);
		idents ~= id;
	}
	return idents;
}

/// Hash-skip path: still collect npm specs so dest package.json stays complete.
void collectNpmFromSvelte(string sveltePath, ref string[] npmOut)
{
	if (!exists(sveltePath))
		return;
	auto t = parseSvelteFile(sveltePath);
	if (!t.successful)
		return;
	foreach (s; t.scripts)
	{
		if (s.lang != "ts")
			continue;
		foreach (im; parseTsImports(s.body))
			if (im.spec.length && !canFind(npmOut, im.spec)
					&& im.spec[0] != '.' && im.spec[0] != '/' && im.spec[0] != '$')
				npmOut ~= im.spec;
	}
}

void rewriteModulesIndex(string ws, string[] generatedIdents)
{
	enum idxTmpl = import("modules-index.ts.tmpl");
	bool[string] seen;
	foreach (id; generatedIdents)
		if (id.length)
			seen[id] = true;
	auto genDir = buildPath(ws, "src-ts", "modules", "generated");
	if (exists(genDir))
	{
		foreach (de; dirEntries(genDir, "*.ts", SpanMode.shallow))
		{
			auto id = stripExtension(baseName(de.name));
			if (id.length)
				seen[id] = true;
		}
	}
	string[] ids = seen.keys;
	sort(ids);
	auto imports = appender!string();
	auto list = appender!string();
	foreach (id; ids)
	{
		imports ~= "import * as " ~ id ~ " from './generated/" ~ id ~ ".ts';\n";
		list ~= ", " ~ id;
	}
	auto txt = idxTmpl.replace("{{IMPORTS}}", imports.data).replace("{{MODULE_LIST}}", list.data);
	writeIfChanged(buildPath(ws, "src-ts", "modules", "index.ts"), txt, DestCell.meta);
}
