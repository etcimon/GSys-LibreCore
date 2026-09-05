// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/** svelte-d fall-through compile: .svelte → svelte-engine-ws → WASM + JS exports. */

import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { catalogJson, refuseKit } from "./constructs.ts";
import { dropWorkspace } from "./drop-ws.ts";
import { emitWasm } from "./emit-wasm.ts";
import { resolveToolchain } from "./ldc.ts";
import { parseSvelte, type SvelteFile } from "./parse.ts";
import { printG6bJs } from "./print-ts.ts";
import { buildWasmCell, cachedWasmCell, checkCellArtifact, pinWasmLdc, sha256, type WasmCellResult } from "./wasm-cell.ts";

export { catalogJson, LIVE, marker, REFUSED, refuseKit, STUB } from "./constructs.ts";
export { emitWasm } from "./emit-wasm.ts";
export { parseSvelte } from "./parse.ts";

export type CompileResult = {
  files: SvelteFile[];
  wasm: Uint8Array;
  js: string;
  catalog: string;
  wsFiles: string[];
  cell?: WasmCellResult;
};

export function loadProject(srcDir: string): SvelteFile[] {
  const names = readdirSync(srcDir).filter((n) => n.endsWith(".svelte")).sort();
  const files: SvelteFile[] = [];
  for (const n of names) {
    const rel = `src/${n}`;
    const src = readFileSync(join(srcDir, n), "utf8");
    const kit = refuseKit(src);
    if (kit) throw new Error(`${rel}: ${kit}`);
    files.push(parseSvelte(rel, src));
  }
  if (files.length === 0) throw new Error("no .svelte sources");
  return files;
}

export class WasmBuildError extends Error {
  constructor(public cell: WasmCellResult) {
    super(`requested LDC build failed: ${cell.reason}\n${cell.log}`);
    this.name = "WasmBuildError";
  }
}

export function compileProject(root: string, opts: { dub?: boolean; asyncify?: boolean } = {}): CompileResult {
  const want_dub = opts.dub ?? (process.env.G6B_DUB_WASM === "1");
  const want_asyncify = opts.asyncify === true || process.env.G6B_WASM_ASYNCIFY === "1";
  if ((want_dub || want_asyncify) && existsSync(join(root, "out"))) {
    writeFileSync(join(root, "out", "bios-ui-libwasm.wasm"), new Uint8Array(0));
    writeFileSync(join(root, "out", "bios-ui-libwasm.json"), JSON.stringify({ schema: "g6lc-libwasm-status/v1", available: false, status: "unavailable", reason: "requested rebuild has not completed successfully" }, null, 2) + "\n");
    rmSync(join(root, "out", "build.json"), { force: true });
  }
  if (want_asyncify && !want_dub) throw new Error("Asyncify with wasm EH is unverified; nonblocking await transformation is unavailable");
  const files = loadProject(join(root, "src"));
  const tc = resolveToolchain(root);
  const dropped = dropWorkspace(root, files, tc.libwasm);
  const wasm = emitWasm(files);
  const js = printG6bJs(files);
  const catalog = catalogJson();
  pinWasmLdc(dropped.ws, tc);
  const cell = want_dub
    ? buildWasmCell(dropped.ws, tc, { asyncify: opts.asyncify })
    : cachedWasmCell(dropped.ws, tc);
  if (want_dub && cell.status !== 0) throw new WasmBuildError(cell);
  return { files, wasm, js, catalog, wsFiles: dropped.files, cell };
}

export function writeOut(root: string, result: CompileResult): void {
  if (result.cell?.requested && result.cell.status !== 0) throw new WasmBuildError(result.cell);
  const html = projectHtml(result.files);
  const css = projectCss(result.files);
  const adapter = readFileSync(join(root, "src", "kernel.ts"), "utf8");
  const worker = readFileSync(join(root, "src", "worker.ts"), "utf8");
  let cell = result.cell;
  if (cell?.artifact === "fresh") {
    const verified = cachedWasmCell(join(root, "svelte-engine-ws"), resolveToolchain(root));
    if (verified.artifact !== "fresh" || verified.provenance?.sha256 !== cell.provenance?.sha256) {
      if (cell.requested) throw new WasmBuildError({ ...cell, status: 2, reason: "artifact changed before publication", log: verified.reason });
      cell = { ...verified, artifact: "stale" };
    }
  }
  let optional = new Uint8Array(0);
  if (cell?.artifact === "fresh" && cell.provenance) {
    optional = readFileSync(cell.ship);
    checkCellArtifact(optional, cell.provenance, cell.provenance.inputs);
  }
  result.cell = cell;
  const out = join(root, "out");
  mkdirSync(out, { recursive: true });
  rmSync(join(out, "build.json"), { force: true });
  writeFileSync(join(out, "bios-ui.wasm"), result.wasm);
  writeFileSync(join(out, "bios-ui.js"), result.js);
  writeFileSync(join(out, "catalog.json"), result.catalog);
  writeFileSync(join(out, "index.html"), html);
  writeFileSync(join(out, "bios-ui.css"), css);
  writeFileSync(join(out, "kernel.js"), adapter);
  writeFileSync(join(out, "worker.js"), worker);
  // Second lane: the LDC/libwasm wasm-eh cell. Kept across non-dub builds so
  // the shipped artifact stays reproducible; created empty when absent so
  // `include_bytes!` always resolves.
  writeFileSync(join(out, "bios-ui-libwasm.wasm"), optional);
  writeFileSync(join(out, "bios-ui-libwasm.json"), JSON.stringify({
    schema: "g6lc-libwasm-status/v1", available: optional.length > 0,
    status: cell?.artifact ?? "unavailable", reason: cell?.reason ?? "LDC build not requested",
    scope: "component-shell preview and particle state; not full Svelte CSS/reactivity/tree or async await",
    provenance: optional.length ? cell?.provenance : null,
  }, null, 2) + "\n");
  writeFileSync(join(out, "build.json"), JSON.stringify({
    schema: "g6lc-browser-products/v1",
    files: { "bios-ui.wasm": sha256(result.wasm), "bios-ui.js": sha256(result.js), "kernel.js": sha256(adapter), "worker.js": sha256(worker), "bios-ui.css": sha256(css), "index.html": sha256(html), "bios-ui-libwasm.wasm": sha256(optional) },
    libwasmAvailable: optional.length > 0,
  }, null, 2) + "\n");
}

export function projectCss(files: SvelteFile[]): string {
  return files.flatMap((file) => [...file.src.matchAll(/<style\s*>([\s\S]*?)<\/style>/gi)].map((match) => match[1].trim())).join("\n") + "\n";
}

export function projectHtml(files: SvelteFile[]): string {
  const visible = new Map<string, boolean>();
  for (const file of files) for (const op of file.ops) {
    if (op.kind === "visible") visible.set(op.id, op.on);
  }
  const escape = (value: string) => value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  const attrs = (id: string) => `id="${escape(id)}"${visible.get(id) === false ? " hidden" : ""}`;
  const seen = new Set<string>();
  const nodes = files.map((file) => {
    const texts = file.ops.filter((op) => op.kind === "text");
    for (const text of texts) {
      if (seen.has(text.id)) throw new Error("duplicate compile-product DOM id: " + text.id);
      seen.add(text.id);
    }
    type PreviewNode = { tag: string; id: string; value: string; children: PreviewNode[] };
    const roots: PreviewNode[] = [];
    const stack: { tag: string; children: PreviewNode[] }[] = [{ tag: "", children: roots }];
    const values = new Map(texts.map((text) => [text.id, text.value]));
    const found = new Set<string>();
    const safeTags = new Set(["section", "div", "nav", "main", "article", "header", "footer", "p", "span", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "code", "ul", "ol", "li", "table", "thead", "tbody", "tfoot", "tr", "th", "td"]);
    const voidTags = new Set(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]);
    const markup = file.src.replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, "").replace(/<!--[\s\S]*?-->/g, "");
    for (const match of markup.matchAll(/<(\/?)([a-z][a-z0-9-]*)\b([^>]*)>/gi)) {
      const tag = match[2].toLowerCase();
      if (match[1]) {
        if (stack.length === 1 || stack.at(-1)!.tag !== tag) throw new Error("unmatched preview tag: " + tag);
        stack.pop();
        continue;
      }
      let children = stack.at(-1)!.children;
      const id = match[3].match(/\bid\s*=\s*(["'])(.*?)\1/)?.[2];
      if (id !== undefined && values.has(id)) {
        const node: PreviewNode = { tag: safeTags.has(tag) ? tag : "div", id, value: values.get(id)!, children: [] };
        children.push(node);
        children = node.children;
        found.add(id);
      }
      if (!voidTags.has(tag) && !match[3].trimEnd().endsWith("/")) stack.push({ tag, children });
    }
    if (stack.length !== 1 || texts.some((text) => !found.has(text.id))) throw new Error("incomplete preview markup: " + file.rel);
    const render = (node: PreviewNode): string => `<${node.tag} ${attrs(node.id)}>${escape(node.value)}${node.children.length ? "\n" + node.children.map(render).join("\n") + "\n" : ""}</${node.tag}>`;
    return roots.map(render).join("\n");
  });
  return `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>G6LC-BIOS</title>
<style>body{font:16px "Courier New",monospace;background:#0000aa;color:#c8c8c8;margin:0;padding:1ch}h1{background:#00aaaa;color:#fff;text-align:center;margin:0}section,nav{border:1px solid #00aaaa;padding:0 1ch;margin:1ch 0}[hidden]{display:none!important}</style></head>
<body><h1>G6LC-BIOS</h1>
<p>Static compile-product preview. The served setup menus are generated from BoardSpec.</p>
${nodes.join("\n")}
</body></html>
`;
}
