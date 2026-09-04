// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { compileProject, writeOut } from "../compiler/index.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const result = compileProject(root, { dub: process.env.G6B_DUB_WASM === "1" });
writeOut(root, result);
console.log(
  `bios-ui: ${result.files.length} svelte → svelte-engine-ws (${result.wsFiles.length} files) → out/bios-ui.wasm ${result.wasm.length} bytes`,
);
if (result.cell) {
  console.log(`wasm-cell: via=${result.cell.via} status=${result.cell.status} ${result.cell.reason}`);
  if (result.cell.status === 3) {
    console.log("wasm-cell skipped: LDC 1.43 required (never PATH 1.41/1.42). Set SVELTE_D_LDC or riscv-compilers/ldc2-build.");
  }
}
