// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module svelte_d.compile;

import std.file;
import std.path;
import std.stdio;
import std.string : format, replace;
import std.array : join;
import std.digest.sha;
import std.conv : to;
import svelte_d.parse.kit_fs;
import svelte_d.parse.svelte;
import svelte_d.parse.dlang;
import svelte_d.workspace.drop;
import svelte_d.workspace.files;
import svelte_d.workspace.ingest;
import svelte_d.workspace.wasm_build;
import svelte_d.print.ts_attach;
import svelte_d.workspace.ws_deps;
import svelte_d.print.d_attach;
import svelte_d.print.kit_router;
import svelte_d.print.kit_env;
import svelte_d.print.debug_map;
import svelte_d.print.overlay;
import svelte_d.print.inspector;
import svelte_d.print.host_attach;
import svelte_d.fallthrough;
import svelte_d.bootstrap;
import svelte_d.lodash_api;

private bool matchesOnly(string rel, string[] only)
{
	import svelte_d.fallthrough : normalizeKitRel;
	import std.algorithm : endsWith, canFind;
	import std.path : baseName;

	if (!only.length)
		return true;
	auto n = normalizeKitRel(rel.replace(`\`, `/`));
	foreach (raw; only)
	{
		auto o = normalizeKitRel(raw.replace(`\`, `/`));
		if (!o.length)
			continue;
		if (n == o || n.endsWith(o) || o.endsWith(n) || baseName(n) == baseName(o))
			return true;
		if (canFind(n, o) || canFind(o, n))
			return true;
	}
	return false;
}

/// Walk src-svelte, Pegged-parse .svelte, libdparse D, write IR JSON.
/// `only` is a list of kit-relative dirty files (watch); empty = full walk.
int compileWorkspace(string ws, string project = null, string[] only = null)
{
	auto root = findRiscvDev();
	auto tpl = templateDir(root);
	if (!exists(ws))
		dropWorkspace(ws, tpl, false);
	pinWasmToolchain(ws);
	if (!project.length)
		project = detectKitProject();
	if (project.length)
		ingestProject(project, ws);
	auto srcSvelte = buildPath(ws, "src-svelte");
	auto srcD = buildPath(ws, "src-d");
	auto irDir = buildPath(ws, ".svelte-d", "ir");
	mkdirRecurse(irDir);
	resetWriteStats();

	size_t ok, fail;
	string[] lines;
	string[] allTs;
	string[] npmSpecs;
	string[] hangDests;
	HostAttach[] hostAtts;
	OverlayDiag[] diags;
	size_t lodashN, bindingsN, routerN, hostN, domN;
	string[] catalog;
	try
		catalog = loadLodashCatalog(root);
	catch (Exception e)
		writeln("lodash catalog: ", e.msg);
	auto prevHash = loadSrcHashes(ws);
	SrcHashEnt[string] nextHash;
	foreach (k, v; prevHash)
		nextHash[k] = v;
	foreach (k; walkKit(srcSvelte))
	{
		string status = "ok";
		string detail;
		auto rel = relativePath(k.path, srcSvelte).replace("\\", "/");
		if (!matchesOnly(rel, only))
			continue;
		enum printerPin = "g126";
		auto srcSha = printerPin ~ ":" ~ shaFile(k.path);
		if (k.path.extension == ".svelte")
		{
			auto prev = rel in prevHash;
			if (prev !is null && prev.hash == srcSha
					&& (prev.dest.length == 0 || exists(buildPath(ws, prev.dest))))
			{
				noteHashSkip();
				if (prev.dest.length >= 10 && prev.dest[0 .. 10] == "src-d/lib/")
					hangDests ~= prev.dest;
				nextHash[rel] = *prev;
				collectNpmFromSvelte(k.path, npmSpecs);
				ok++;
				continue;
			}
			noteParsed();
			auto t = parseSvelteFile(k.path);
			if (!t.successful)
			{
				status = "scan-fail";
				detail = t.fail;
				fail++;
				diags ~= OverlayDiag("error", status, relativePath(k.path, srcSvelte).replace("\\", "/"), "", t.fail);
			}
			else if (!scriptsOk(t))
			{
				status = "bad-script-lang";
				fail++;
				diags ~= OverlayDiag("error", status, relativePath(k.path, srcSvelte).replace("\\", "/"), "", "bad script lang");
			}
			else
			{
				ok++;
				allTs ~= attachTsModules(ws, rel, t, npmSpecs);
				if (t.hasLang("d"))
				{
					detail = "libwasm-d";
					foreach (att; attachDModules(ws, rel, t, catalog))
					{
						if (att.lodashMethods.length)
						{
							detail = "libwasm-lodash";
							lodashN++;
							auto lj = format(
								`{"schema":"svelte-d-ir/v1","kind":"LodashChain","source":"%s","dest":"%s","methods":"%s","cell":"wasm","ir":"libwasm-lodash"}` ~ "\n",
								rel, att.dest, att.lodashMethods.join(",")
							);
							std.file.write(buildPath(irDir, "lodash-" ~ att.dest.replace("/", "_").replace("\\", "_") ~ ".json"), lj);
						}
						if (att.bindings.length)
						{
							if (detail == "libwasm-d")
								detail = "libwasm-bindings";
							bindingsN++;
							auto bj = format(
								`{"schema":"svelte-d-ir/v1","kind":"BindingCall","source":"%s","dest":"%s","bindings":"%s","cell":"wasm","ir":"libwasm-bindings"}` ~ "\n",
								rel, att.dest, att.bindings.join(",")
							);
							std.file.write(buildPath(irDir, "bind-" ~ att.dest.replace("/", "_").replace("\\", "_") ~ ".json"), bj);
						}
						if (att.isDom)
						{
							detail = att.detail.length ? att.detail : "libwasm-dom";
							domN++;
							if (att.dest.length)
							{
								hangDests ~= att.dest;
								nextHash[rel] = SrcHashEnt(srcSha, att.dest);
							}
							auto dj = format(
								`{"schema":"svelte-d-ir/v1","kind":"Template","source":"%s","dest":"%s","udas":"%s","cell":"wasm","ir":"libwasm-dom","parse":"%s"}` ~ "\n",
								rel, att.dest, att.udas.join(","), att.parseKind.length ? att.parseKind : "scan-fail"
							);
							std.file.write(buildPath(irDir, "dom-" ~ att.dest.replace("/", "_").replace("\\", "_") ~ ".json"), dj);
						}
						if (att.router.length)
						{
							detail = "libwasm-router";
							routerN++;
							auto rj = format(
								`{"schema":"svelte-d-ir/v1","kind":"Route","source":"%s","dest":"%s","router":"%s","pattern":"%s","cell":"wasm","ir":"libwasm-router"}` ~ "\n",
								rel, att.dest, att.router.join(","), kitToPattern(rel)
							);
							std.file.write(buildPath(irDir, "route-" ~ att.dest.replace("/", "_").replace("\\", "_") ~ ".json"), rj);
						}
						if (att.rejectedImports.length)
							diags ~= OverlayDiag("warn", "rejected-import", rel, att.dest,
								att.rejectedImports.join(","));
						if (!att.ok)
						{
							status = "libdparse-fail";
							detail = att.detail;
							writeln("  libdparse printed D: ", att.detail);
							fail++;
							ok--;
							diags ~= OverlayDiag("error", status, rel, att.dest, att.detail);
						}
					}
				}
				if (t.hasLang("ts"))
					detail ~= (detail.length ? "+" : "") ~ "ts-jsExports";
				if (rel !in nextHash)
					nextHash[rel] = SrcHashEnt(srcSha, "");
			}
			if (!detail.length)
				detail = t.successful ? "Document" : "unsuccessful";
		}
		else if (k.path.extension == ".d")
		{
			string err;
			auto src = readText(k.path);
			if (!parseDFragment(src, k.path, err))
			{
				status = "libdparse-fail";
				detail = err;
				writeln("  libdparse: ", err);
				fail++;
				diags ~= OverlayDiag("error", status, relativePath(k.path, srcSvelte).replace("\\", "/"), "", err);
			}
			else
			{
				ok++;
				detail = k.kind == "page_server" || k.kind == "endpoint" || k.kind == "layout_server"
					? "vibe0-fallthrough" : "libwasm-passthrough";
				if (k.kind == "page_server" || k.kind == "endpoint" || k.kind == "layout_server" || k.kind == "hooks")
				{
					auto hrel = relativePath(k.path, srcSvelte).replace("\\", "/");
					auto hatt = attachHostFile(ws, hrel, k.path);
					if (hatt.dest.length)
					{
						hostN++;
						hostAtts ~= hatt;
						if (hatt.rejectedImports.length)
							diags ~= OverlayDiag("warn", "rejected-import", hrel, hatt.dest,
								hatt.rejectedImports.join(","));
						if (!hatt.ok)
						{
							status = "libdparse-fail";
							detail = hatt.detail;
							fail++;
							ok--;
							diags ~= OverlayDiag("error", status, hrel, hatt.dest, hatt.detail);
						}
					}
				}
			}
		}
		else if (k.kind == "page_server" || k.kind == "endpoint" || k.kind == "layout_server" || k.kind == "hooks")
		{
			ok++;
			detail = "vibe0-fallthrough";
		}
		auto hash = toHexString(sha256Of(rel ~ status ~ detail)).idup;
		auto json = format(
			`{"schema":"svelte-d-ir/v1","kind":"%s","source":"%s","status":"%s","detail":"%s","cell":"wasm","hash":"%s","ir":"libwasm-passthrough"}` ~ "\n",
			k.kind, rel, status, detail.replace(`"`, `'`), hash[0 .. 16]
		);
		auto outp = buildPath(irDir, hash[0 .. 16] ~ ".json");
		std.file.write(outp, json);
		lines ~= rel ~ "\t" ~ k.kind ~ "\t" ~ status;
		writeln(status, "\t", rel);
	}

	// Persistence IR: pglite.d is passthrough libwasm Lodash wrap.
	auto pglite = buildPath(srcD, "pglite.d");
	auto pgliteStatus = exists(pglite) ? "passthrough" : "missing";
	std.file.write(buildPath(irDir, "pglite.json"),
		`{"schema":"svelte-d-ir/v1","kind":"JsHostWrap","source":"src-d/pglite.d","status":"`
			~ pgliteStatus ~ `","ir":"libwasm-lodash","host":"window.pglite"}` ~ "\n");

	mkdirRecurse(buildPath(ws, ".svelte-d"));
	if (only.length)
	{
		auto libDir = buildPath(srcD, "lib");
		if (exists(libDir))
		{
			foreach (de; dirEntries(libDir, "*.d", SpanMode.shallow))
				hangDests ~= "src-d/lib/" ~ baseName(de.name);
		}
	}
	if (exists(srcSvelte))
	{
		foreach (de; dirEntries(srcSvelte, "*.svelte", SpanMode.depth))
			collectNpmFromSvelte(de.name, npmSpecs);
	}
	if (project.length)
	{
		auto depChanged = syncWsDependencies(project, ws, npmSpecs);
		if (depChanged || wsDepsMissing(ws, npmSpecs))
			installWsDeps(ws);
	}
	rewriteModulesIndex(ws, allTs);
	writeFallthroughFile(ws);
	writeBootstrapFile(ws, tpl);
	assembleAppChildren(ws, hangDests);
	assembleHostRoutes(ws, hostAtts);
	string krErr;
	auto kr = writeKitRouter(ws, krErr);
	if (kr.length)
	{
		auto krs = collectKitRoutes(srcSvelte);
		std.file.write(buildPath(irDir, "kit_router.json"),
			format(`{"schema":"svelte-d-ir/v1","kind":"Route","source":"src-d/kit_router.d","routes":%s,"ir":"libwasm-router"}` ~ "\n",
				krs.length.to!string));
		if (krErr.length)
		{
			writeln("  libdparse kit_router: ", krErr);
			fail++;
			diags ~= OverlayDiag("error", "libdparse-fail", "src-d/kit_router.d", "src-d/kit_router.d", krErr);
		}
		assembleKitOnApp(ws);
		assembleCompiledChrome(ws);
	}
	auto envErr = writeKitEnv(ws);
	if (envErr.length)
	{
		writeln("  libdparse kit env: ", envErr);
		fail++;
		diags ~= OverlayDiag("error", "libdparse-fail", "src-d/kit", "src-d/kit", envErr);
	}
	auto leak = checkPrivateLeak(ws);
	if (leak.length)
	{
		writeln("  ", leak);
		fail++;
		diags ~= OverlayDiag("error", "private-leak", "$env/static/private", "", leak);
	}
	std.file.write(buildPath(irDir, "kit_env.json"),
		`{"schema":"svelte-d-ir/v1","kind":"KitEnv","source":"src-d/kit","ir":"libwasm+vibe0-env"}` ~ "\n");
	writeDebugMap(ws);
	writeIrInspector(ws);
	writeOverlay(ws, fail, diags);
	if (verifyBootstrap(ws) != 0)
	{
		writeln("bootstrap surfaces missing in ", ws);
		foreach (m; missingSurfaces(ws))
		{
			writeln("  missing\t", m);
			diags ~= OverlayDiag("error", "bootstrap-missing", m, m, "missing surface " ~ m);
		}
		fail++;
		writeOverlay(ws, fail, diags);
	}
	auto man = format(
		`{"schema":"svelte-d-manifest/v1","workspace":"%s","ok":%s,"fail":%s,"pglite":"%s","srcD":"libwasm-ir","tsModules":%s,"lodash":%s,"bindings":%s,"router":%s,"host":%s,"dom":%s,"fallthrough":"kit-equivalent-ws","bootstrap":"svelte-engine","accommodate":"engine-libwasm-vibe0"}` ~ "\n",
		ws.replace("\\", "/"), ok.to!string, fail.to!string, pgliteStatus, allTs.length.to!string,
		lodashN.to!string, bindingsN.to!string, routerN.to!string, hostN.to!string, domN.to!string
	);
	std.file.write(buildPath(ws, ".svelte-d", "manifest.json"), man);
	saveSrcHashes(ws, nextHash);
	auto st = writeStats();
	std.file.write(buildPath(ws, ".svelte-d", "write.json"),
		format(`{"schema":"svelte-d-write/v1","wrote":%s,"skipped":%s,"wasm":%s,"host":%s,"parsed":%s,"hashSkip":%s}` ~ "\n",
			st.wrote.to!string, st.skipped.to!string, st.wasm.to!string, st.host.to!string,
			st.parsed.to!string, st.hashSkip.to!string));
	if (st.wasm > 0)
		writeHmrTick(ws, "reload");
	else if (st.wrote > 0)
		writeHmrTick(ws, "full-reload");
	writeln("manifest ", buildPath(ws, ".svelte-d", "manifest.json"), " ok=", ok, " fail=", fail,
		" ts=", allTs.length, " lodash=", lodashN, " bind=", bindingsN, " router=", routerN, " host=", hostN, " dom=", domN);
	writeln("write  wrote=", st.wrote, " skip=", st.skipped, " wasm=", st.wasm, " host=", st.host,
		" parsed=", st.parsed, " hashSkip=", st.hashSkip);
	return fail == 0 ? 0 : 2;
}
