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
    scope: "component-shell preview and particle state; Asyncify build path landed; not full Svelte CSS/reactivity/tree or D await/catch host driver",
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
  const textOps = new Map<string, string>();
  const seen = new Set<string>();
  for (const file of files) for (const op of file.ops) {
    if (op.kind === "visible") {
      if (visible.has(op.id)) throw new Error("duplicate compile-product visibility id: " + op.id);
      visible.set(op.id, op.on);
    }
    if (op.kind === "text") {
      if (seen.has(op.id)) throw new Error("duplicate compile-product DOM id: " + op.id);
      seen.add(op.id);
      textOps.set(op.id, op.value);
    }
  }

  const escape = (value: string) => value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  const safeTags = new Set(["section", "div", "nav", "main", "article", "header", "footer", "p", "span", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "code", "ul", "ol", "li", "table", "thead", "tbody", "tfoot", "tr", "th", "td", "a", "button", "canvas", "template"]);
  const voidTags = new Set(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]);

  const stripSvelte = (src: string) =>
    src
      .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, "")
      .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, "")
      .replace(/<!--[\s\S]*?-->/g, "")
      .replace(/{#if\s+[^}]+}|{:else[^}]*}|{\/if}/g, "");

  const parseAttrs = (raw: string): Map<string, string> => {
    const attrs = new Map<string, string>();
    for (const m of raw.matchAll(/\b([a-z][a-z0-9-]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>"']+)))?/gi)) {
      const name = m[1].toLowerCase();
      const value = m[2] ?? m[3] ?? m[4] ?? "";
      attrs.set(name, value);
    }
    return attrs;
  };

  type PreviewNode = { tag: string; attrs: Map<string, string>; children: (PreviewNode | string)[] };

  const renderAttrs = (attrs: Map<string, string>): string => {
    const out: string[] = [];
    for (const [name, value] of attrs) {
      if (value === "") out.push(name);
      else out.push(`${name}="${escape(value)}"`);
    }
    return out.length ? " " + out.join(" ") : "";
  };

  const render = (node: PreviewNode, parentHidden: boolean): string => {
    const id = node.attrs.get("id");
    let hidden = parentHidden;
    if (id && visible.has(id) && !visible.get(id)) {
      hidden = true;
    }
    if (hidden && !node.attrs.has("hidden")) node.attrs.set("hidden", "");
    if (!hidden && node.attrs.has("hidden")) node.attrs.delete("hidden");

    if (id && textOps.has(id) && node.children.every((c) => typeof c === "string")) {
      // Text op replaces the leaf text of this element; do not keep nested tags.
      node.children = [textOps.get(id)!];
    }

    if (voidTags.has(node.tag)) {
      return `<${node.tag}${renderAttrs(node.attrs)}>`;
    }
    const body = node.children.map((c) => typeof c === "string" ? escape(c) : render(c, hidden)).join("");
    const hasBlockChildren = node.children.some((c) => typeof c !== "string");
    return hasBlockChildren
      ? `<${node.tag}${renderAttrs(node.attrs)}>\n${body}\n</${node.tag}>`
      : `<${node.tag}${renderAttrs(node.attrs)}>${body}</${node.tag}>`;
  };

  const out: string[] = [];
  for (const file of files) {
    const markup = stripSvelte(file.src);
    const roots: PreviewNode[] = [];
    const stack: PreviewNode[] = [];
    const tokenRe = /(<(\/?)([a-z][a-z0-9-]*)\b([^>]*)>)|([^<]+)/gi;
    let m: RegExpExecArray | null;
    while ((m = tokenRe.exec(markup)) !== null) {
      if (m[1] !== undefined) {
        const closing = m[2] !== "";
        const tag = m[3].toLowerCase();
        const attrStr = m[4];
        if (closing) {
          if (stack.length === 0 || stack.at(-1)!.tag !== tag) throw new Error("unmatched preview tag: " + tag);
          stack.pop();
          continue;
        }
        const attrs = parseAttrs(attrStr);
        const safeTag = safeTags.has(tag) ? tag : "div";
        const selfClosing = m[4].trimEnd().endsWith("/") || voidTags.has(tag);
        const node: PreviewNode = { tag: safeTag, attrs, children: [] };
        if (stack.length) stack.at(-1)!.children.push(node);
        else roots.push(node);
        if (!selfClosing) stack.push(node);
      } else {
        const text = m[5].replace(/\s+/g, " ").trim();
        if (text) {
          if (stack.length) stack.at(-1)!.children.push(text);
          else roots.push({ tag: "span", attrs: new Map(), children: [text] });
        }
      }
    }
    if (stack.length) throw new Error("unclosed preview tag in " + file.rel);
    for (const root of roots) out.push(render(root, false));
  }
  return out.join("\n");
}
