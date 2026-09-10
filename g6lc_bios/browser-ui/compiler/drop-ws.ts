// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/** Drop BIOS UI into svelte-engine-ws (svelte-d workspace dest). Never mutates kernel-spec. */

import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { catalogJson, marker } from "./constructs.ts";
import { findLibwasmCheckout } from "./ldc.ts";
import type { SvelteFile } from "./parse.ts";
import { printApp, printModule, structName, validateDProject } from "./print-d.ts";
import { printGeneratedTs, printJsExports } from "./print-ts.ts";
import { engineDubSdl } from "./wasm-cell.ts";

export type Dropped = {
  ws: string;
  files: string[];
};

export function dropWorkspace(root: string, files: SvelteFile[], libwasm = findLibwasmCheckout(root)): Dropped {
  validateDProject(files);
  const dSources = files.map((file) => structName(file) === "App" ? printApp(files) : printModule(file));
  const ws = join(root, "svelte-engine-ws");
  for (const rel of ["src-d", "src-d-views", "src-svelte", "src-ts/modules/generated"]) {
    rmSync(join(ws, rel), { recursive: true, force: true });
  }
  const written: string[] = [];
  const put = (rel: string, body: string) => {
    const p = join(ws, rel);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, body, "utf8");
    written.push(rel.replace(/\\/g, "/"));
  };

  put(
    "package.json",
    JSON.stringify(
      {
        name: "g6lc-bios-ui-ws",
        private: true,
        type: "module",
        description: "Dropped svelte-engine-ws for BIOS UI (dub+libwasm wasm-eh cell).",
      },
      null,
      2,
    ) + "\n",
  );
  put("dub.sdl", engineDubSdl(libwasm));
  put("src-d-views/home.dt", "p BIOS-UI\n");

  const ir: Record<string, unknown>[] = [];
  for (const [index, f] of files.entries()) {
    put(`src-svelte/${structName(f)}.svelte`, f.src.endsWith("\n") ? f.src : f.src + "\n");
    const d = dSources[index];
    put(`src-d/${structName(f).toLowerCase()}.d`, d.endsWith("\n") ? d : d + "\n");
    put(`src-ts/modules/generated/${f.ident}.ts`, printGeneratedTs(f));
    ir.push({
      ident: f.ident,
      rel: f.rel,
      tag: f.tag,
      langTs: f.langTs,
      ops: f.ops,
    });
  }

  put("src-ts/jsExports.ts", printJsExports(files));
  put(
    "src-ts/__svelteD.ts",
    `// window.__svelteD registry planted by jsExports.ensureSvelteD()\nexport { ensureSvelteD, jsExports } from "./jsExports.ts";\n`,
  );
  put(
    "src-ts/modules/libwasm.ts",
    `export { ensureSvelteD } from "../jsExports.ts";\n`,
  );
  put(
    "src-ts/kernel.ts",
    `// HolyC / kernel JS exports (copied into the dropped ws).
declare const kernel: { holyc(line: string): string; register(path: string, method?: string): void };
export function fetchBios(url: string): void { fetch(url); }
export function holycEval(line: string): string { return kernel.holyc(line); }
export function registerEndpoint(path: string, method = "GET"): void { kernel.register(path, method); }
export const jsExports = { env: { fetchBios, holycEval, registerEndpoint } };
`,
  );

  put(".svelte-d/ir/bios-ui.json", JSON.stringify({ files: ir }, null, 2) + "\n");
  put(
    ".svelte-d/manifest.json",
    JSON.stringify(
      {
        name: "bios-ui",
        workspace: "svelte-engine-ws",
        kit: false,
        wasm: "out/bios-ui.wasm",
        constructs: {
          live: ["NodeDef", "@prop", "@child", "@visible", "_start", "FileMgr", "Menu", "Store"],
          stub: ["{#each}", "{#await}", "Slot", "@callback"],
          refused: ["router", "$state", "sveltekit"],
        },
        markers: [
          marker("NodeDef"),
          marker("_start"),
          marker("FileMgr"),
          marker("Menu"),
          marker("Store"),
          marker("{#await}"),
          marker("sveltekit"),
        ],
      },
      null,
      2,
    ) + "\n",
  );
  put("catalog.json", catalogJson());

  return { ws, files: written };
}
