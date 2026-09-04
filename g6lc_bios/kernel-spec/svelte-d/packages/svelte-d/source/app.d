// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module app;

import std.stdio;
import std.getopt;
import std.file : exists, getcwd;
import std.path : buildPath, extension;
import svelte_d.workspace.drop;
import svelte_d.parse.svelte;
import svelte_d.parse.dlang;
import svelte_d.parse.kit_fs;
import svelte_d.compile;
import svelte_d.fallthrough;
import svelte_d.bootstrap;
import svelte_d.lodash_api;
import svelte_d.print.kit_router;
import svelte_d.workspace.wasm_build;
import svelte_d.workspace.host_build;

/// Compile dest is always svelte-engine-ws, never the engine template.
string wsOrDefault(string ws, string root)
{
	return ws.length ? ws : defaultWorkspaceDir(root);
}

void usage()
{
	writeln("svelte-d — SvelteKit → libwasm / vibe.0 in svelte-engine-ws");
	writeln("  kit paths fall through to the same relative structure (src-svelte / src-d / src-ts / webserver)");
	writeln("  kit features are accommodated in svelte-engine / libwasm / vibe.0; compile integrates the engine");
	writeln("  svelte-d drop-ws [--dest DIR] [--force]");
	writeln("      dest default: svelte-d.config.ts/js workspace, else <project>/svelte-engine-ws");
	writeln("  svelte-d parse <file.svelte|+page.server.d>");
	writeln("  svelte-d scan [--ws DIR]");
	writeln("  svelte-d compile [--ws DIR] [--project DIR] [--only FILE]");
	writeln("      drop engine if needed; Pegged + libdparse → ws/.svelte-d/ir ; src-d stays libwasm IR");
	writeln("      --only FILE  reprint that kit source only (watch / HMR)");
	writeln("  svelte-d map <src/routes/+page.svelte>");
	writeln("  svelte-d map --ws DIR     # write ws/.svelte-d/fallthrough.json");
	writeln("  svelte-d bootstrap [--ws DIR]  # write/print engine-integration contract");
	writeln("  svelte-d lodash               # list libwasm.lodash methods");
	writeln("  svelte-d kit-routes [--ws DIR]");
	writeln("  svelte-d wasm [--ws DIR] [--debug|--release] [--probes] [--force]");
	writeln("      wasm cell; default --release (optimize + lflags -strip-all + wasm-opt -Oz). --debug keeps symbols.");
	writeln("  svelte-d host [--ws DIR] [--debug|--release]");
	writeln("      vibe.0 host; default --debug. --release is optimize + strip.");
	writeln("  svelte-d build [--ws DIR] [--project DIR]  # compile IR + wasm/host --release");
	writeln("  svelte-d setup                       # find LDC 1.43 + Binaryen ≥123 + vibe.0 + libwasm");
	writeln("  svelte-d version");
}

int main(string[] args)
{
	if (args.length < 2)
	{
		usage();
		return 1;
	}
	auto cmd = args[1];
	try
	{
		if (cmd == "drop-ws")
		{
			string dest;
			bool force;
			getopt(args, "dest", &dest, "force", &force);
			auto root = findRiscvDev();
			if (dest.length == 0)
				dest = defaultWorkspaceDir(root);
			dropWorkspace(dest, templateDir(root), force);
			writeBootstrapFile(dest, templateDir(root));
			pinWasmToolchain(dest);
			return 0;
		}
		if (cmd == "parse")
		{
			if (args.length < 3)
			{
				stderr.writeln("parse needs a file");
				return 1;
			}
			auto file = args[2];
			auto ext = extension(file);
			if (ext == ".svelte")
			{
				auto t = parseSvelteFile(file);
				if (!t.successful)
				{
					stderr.writeln("scan failed: ", file, " ", t.fail);
					dumpTree(t);
					return 1;
				}
				if (!scriptsOk(t))
				{
					stderr.writeln("FAIL: scripts must be lang=d (libwasm) and/or lang=ts (src-ts/modules)  ", file);
					return 1;
				}
				if (t.peggedOk)
					writeln("Pegged OK  ", file, " ParseTree=", t.peggedName);
				else
					writeln("Pegged FAIL  ", file, " ", t.peggedFail, " (scan still ok)");
				dumpTree(t);
				{
					import svelte_d.parse.markup : parseMarkupEx;
					auto mp = parseMarkupEx(t.markup);
					writeln("markup-parse=", mp.kind, " reason=", mp.reason);
				}
				if (args.length > 3 && args[3] == "--dump-peg")
				{
					import svelte_d.grammar.sveltekit : SvelteKit;
					auto m = SvelteKit.MarkupDoc(t.markup);
					writeln("MarkupDoc successful=", m.successful, " children=", m.children.length);
					writeln(m.toString());
				}
				return 0;
			}
			if (ext == ".d")
			{
				import std.file : readText;

				dumpDOk(readText(file), file);
				return 0;
			}
			stderr.writeln("unknown extension ", ext);
			return 1;
		}
		if (cmd == "scan")
		{
			string ws;
			getopt(args, "ws", &ws);
			auto root = findRiscvDev();
			ws = wsOrDefault(ws, root);
			auto src = buildPath(ws, "src-svelte");
			foreach (k; walkKit(src))
				writeln(k.kind, "\t", k.path);
			return 0;
		}
		if (cmd == "compile")
		{
			string ws;
			string project;
			string[] only;
			getopt(args, "ws", &ws, "project", &project, "only", &only);
			auto root = findRiscvDev();
			ws = wsOrDefault(ws, root);
			return compileWorkspace(ws, project, only);
		}
		if (cmd == "map")
		{
			string ws;
			getopt(args, "ws", &ws);
			if (ws.length)
			{
				writeFallthroughFile(ws);
				writeln("fallthrough ", buildPath(ws, ".svelte-d", "fallthrough.json"));
				return 0;
			}
			if (args.length < 3)
			{
				stderr.writeln("map needs a kit path or --ws DIR");
				return 1;
			}
			writeln(mapKitRel(args[2]).toJson());
			return 0;
		}
		if (cmd == "bootstrap")
		{
			string ws;
			getopt(args, "ws", &ws);
			auto root = findRiscvDev();
			ws = wsOrDefault(ws, root);
			writeBootstrapFile(ws, templateDir(root));
			writeln(bootstrapDocument(ws, templateDir(root)));
			return verifyBootstrap(ws);
		}
		if (cmd == "kit-routes")
		{
			string ws;
			getopt(args, "ws", &ws);
			auto root = findRiscvDev();
			ws = wsOrDefault(ws, root);
			foreach (r; collectKitRoutes(buildPath(ws, "src-svelte")))
				writeln(r.pattern, "\t", r.kitRel, "\t", r.srcD);
			return 0;
		}
		if (cmd == "lodash")
		{
			auto cat = loadLodashCatalog();
			writeln("libwasm.lodash ", lodashSourcePath(), " methods=", cat.length);
			foreach (m; cat)
				writeln(m);
			return 0;
		}
		if (cmd == "wasm")
		{
			string ws;
			bool probes;
			bool force;
			bool dbg;
			bool rel;
			getopt(args, "ws", &ws, "probes", &probes, "force", &force,
				"debug", &dbg, "release", &rel);
			auto root = findRiscvDev();
			ws = wsOrDefault(ws, root);
			auto mode = (dbg && !rel) ? "debug" : "release";
			auto st = buildWasmCell(ws, "application", force, mode);
			if (st != 0)
				return st;
			if (probes)
				return runWasmProbes(ws);
			return 0;
		}
		if (cmd == "host")
		{
			string ws;
			bool dbg;
			bool rel;
			getopt(args, "ws", &ws, "debug", &dbg, "release", &rel);
			auto root = findRiscvDev();
			ws = wsOrDefault(ws, root);
			auto mode = rel ? "release" : "debug";
			return buildHostCell(ws, mode);
		}
		if (cmd == "build")
		{
			string ws;
			string project;
			getopt(args, "ws", &ws, "project", &project);
			auto root = findRiscvDev();
			ws = wsOrDefault(ws, root);
			auto st = compileWorkspace(ws, project);
			if (st != 0)
				return st;
			st = buildWasmCell(ws, "application", true, "release");
			if (st != 0)
				return st;
			return buildHostCell(ws, "release");
		}
		if (cmd == "setup")
		{
			import svelte_d.workspace.ldc;

			import svelte_d.workspace.wasm_build : findWasmOpt;

			auto ldc = findLdc();
			auto dub = findDub(ldc);
			auto wopt = findWasmOpt();
			string lw;
			try
				lw = findLibwasmRoot();
			catch (Exception)
				lw = findLibwasmCheckout();
			auto v0 = findVibe0Checkout();
			if (lw.length)
				ensureLibwasmAddLocal();
			ensureHostAddLocals();
			writeln("ldc\t", ldc.length ? ldc : "(missing — bunx svelte-d setup downloads 1.43)");
			writeln("dub\t", dub.length ? dub : "(missing)");
			writeln("wasm-opt\t", wopt.length ? wopt : "(missing — bunx svelte-d setup downloads fork wasm-opt)");
			writeln("libwasm\t", lw.length ? lw : "(dub fetch ~master on first wasm build)");
			writeln("vibe.0\t", v0.length ? v0 : "(dub registry vibe-0 on first host build)");
			return ldc.length && dub.length ? 0 : 3;
		}
		if (cmd == "version")
		{
			writeln("1");
			return 0;
		}
		usage();
		return 1;
	}
	catch (Exception e)
	{
		stderr.writeln(e.msg);
		return 1;
	}
}
