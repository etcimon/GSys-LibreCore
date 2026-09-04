// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/** svelte-d fall-through compile: .svelte → svelte-engine-ws → WASM + JS exports. */

import { mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { catalogJson, refuseKit } from "./constructs.ts";
import { dropWorkspace } from "./drop-ws.ts";
import { emitWasm } from "./emit-wasm.ts";
import { resolveToolchain } from "./ldc.ts";
import { parseSvelte, type SvelteFile } from "./parse.ts";
import { printG6bJs } from "./print-ts.ts";
import { buildWasmCell, pinWasmLdc, type WasmCellResult } from "./wasm-cell.ts";

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

export function compileProject(root: string, opts: { dub?: boolean } = {}): CompileResult {
  const files = loadProject(join(root, "src"));
  const dropped = dropWorkspace(root, files);
  const wasm = emitWasm(files);
  const js = printG6bJs(files);
  const catalog = catalogJson();
  const tc = resolveToolchain(root);
  pinWasmLdc(dropped.ws, tc);
  const want_dub = opts.dub === true || process.env.G6B_DUB_WASM === "1";
  const cell: WasmCellResult = want_dub
    ? buildWasmCell(dropped.ws, tc)
    : {
        status: tc.ok ? 0 : 3,
        via: "skip",
        reason: tc.ok
          ? `pinned ${tc.versionLine || tc.ldc} (set G6B_DUB_WASM=1 to dub --arch=wasm32-unknown-wasi)`
          : "no LDC 1.43 (refusing 1.36/1.41/1.42)",
        raw: join(dropped.ws, "public", "bios-ui-raw.wasm"),
        ship: join(dropped.ws, "public", "bios-ui.wasm"),
        log: "",
      };
  return { files, wasm, js, catalog, wsFiles: dropped.files, cell };
}

export function writeOut(root: string, result: CompileResult): void {
  const out = join(root, "out");
  mkdirSync(out, { recursive: true });
  writeFileSync(join(out, "bios-ui.wasm"), result.wasm);
  writeFileSync(join(out, "bios-ui.js"), result.js);
  writeFileSync(join(out, "catalog.json"), result.catalog);
  writeFileSync(
    join(out, "index.html"),
    `<!DOCTYPE html>
<html><head><title>G6LC-BIOS</title></head>
<body>
<section id="bios-ui"><p id="status">boot</p></section>
<section id="usb-flash"><p id="usb-title"></p><p id="usb-list"></p></section>
<section id="filemgr"><p id="fm-tabs"></p><p id="fm-list"></p></section>
<section id="bios-menu"><p id="menu-title"></p></section>
<script src="./bios-ui.js"></script>
</body></html>
`,
  );
}
