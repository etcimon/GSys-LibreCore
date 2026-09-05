// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { compileProject, WasmBuildError, writeOut } from "../compiler/index.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
try {
  const result = compileProject(root, { dub: process.env.G6B_DUB_WASM === "1", asyncify: process.env.G6B_WASM_ASYNCIFY === "1" });
  writeOut(root, result);
  console.log(
    `bios-ui: ${result.files.length} svelte → svelte-engine-ws (${result.wsFiles.length} files) → out/bios-ui.wasm ${result.wasm.length} bytes`,
  );
  if (result.cell) {
    console.log(`wasm-cell: via=${result.cell.via} status=${result.cell.status} artifact=${result.cell.artifact} ${result.cell.reason}`);
  }
} catch (error) {
  console.error(String(error));
  process.exitCode = error instanceof WasmBuildError ? error.cell.status || 1 : 1;
}
