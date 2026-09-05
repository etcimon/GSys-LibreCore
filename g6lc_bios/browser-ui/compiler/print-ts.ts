// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/**
 * lang=ts splice into src-ts jsExports / __svelteD.ts (svelte-d cross-calling).
 * Spec: kernel-spec/svelte-d/architecture/cross-calling.md
 */

import type { SvelteFile } from "./parse.ts";

export function printGeneratedTs(file: SvelteFile): string {
  const fetches = file.ops.filter((o) => o.kind === "fetch");
  const holycs = file.ops.filter((o) => o.kind === "holyc");
  const regs = file.ops.filter((o) => o.kind === "register");
  const lines: string[] = [];
  lines.push(`// Generated from ${file.rel} (lang=ts)`);
  lines.push(`import { ensureSvelteD } from "../libwasm.ts";`);
  lines.push("");
  lines.push(`export function fetchBios(url: string) { fetch(url); }`);
  lines.push(`export function holycEval(line: string) { return kernel.holyc(line); }`);
  lines.push(
    `export function registerEndpoint(path: string, method = "GET") { kernel.register(path, method); }`,
  );
  lines.push("");
  lines.push("const _reg = ensureSvelteD();");
  lines.push(`_reg.registerTs(${JSON.stringify(file.ident)}, "fetchBios", fetchBios);`);
  lines.push(`_reg.registerTs(${JSON.stringify(file.ident)}, "holycEval", holycEval);`);
  lines.push(
    `_reg.registerTs(${JSON.stringify(file.ident)}, "registerEndpoint", registerEndpoint);`,
  );
  if (fetches.length || holycs.length || regs.length) {
    lines.push("export function mount() {");
    for (const o of fetches) {
      if (o.kind === "fetch") lines.push(`  fetchBios(${JSON.stringify(o.url)});`);
    }
    for (const o of holycs) {
      if (o.kind === "holyc") lines.push(`  holycEval(${JSON.stringify(o.line)});`);
    }
    for (const o of regs) {
      if (o.kind === "register") {
        lines.push(`  registerEndpoint(${JSON.stringify(o.path)}, ${JSON.stringify(o.method)});`);
      }
    }
    lines.push("}");
  }
  lines.push("");
  return lines.join("\n");
}

export function printJsExports(files: SvelteFile[]): string {
  const lines: string[] = [];
  lines.push("// Generated jsExports — window.__svelteD.ts registry (svelte-d).");
  lines.push("declare const kernel: { holyc(line: string): string; register(path: string, method?: string): void };");
  lines.push("declare const window: { __svelteD?: SvelteDRegistry } & Record<string, unknown>;");
  lines.push("");
  lines.push("export type SvelteDFn = (...args: unknown[]) => unknown;");
  lines.push("export type SvelteDRegistry = {");
  lines.push("  ts: Record<string, Record<string, SvelteDFn>>;");
  lines.push("  d: Record<string, Record<string, SvelteDFn>>;");
  lines.push("  registerTs(mod: string, name: string, fn: SvelteDFn): void;");
  lines.push("};");
  lines.push("");
  lines.push("export function ensureSvelteD(): SvelteDRegistry {");
  lines.push("  const w = window as typeof window;");
  lines.push("  if (!w.__svelteD) {");
  lines.push("    const reg: SvelteDRegistry = {");
  lines.push("      ts: {},");
  lines.push("      d: {},");
  lines.push("      registerTs(mod, name, fn) {");
  lines.push("        if (!this.ts[mod]) this.ts[mod] = {};");
  lines.push("        this.ts[mod][name] = fn;");
  lines.push("      },");
  lines.push("    };");
  lines.push("    w.__svelteD = reg;");
  lines.push("  }");
  lines.push("  return w.__svelteD as SvelteDRegistry;");
  lines.push("}");
  lines.push("");
  lines.push("ensureSvelteD();");
  lines.push("");
  lines.push("export const jsExports = {");
  lines.push("  env: {");
  lines.push("    set_inner_text(_id: string, _val: string) {},");
  lines.push("    fetch(url: string) { return fetch(url); },");
  lines.push("    holycEval(line: string) { return kernel.holyc(line); },");
  lines.push("  },");
  lines.push("};");
  for (const f of files) {
    lines.push(`// module ${f.ident}`);
  }
  lines.push("");
  return lines.join("\n");
}

/** g6b-js AOT subset: innerText + fetch + kernel.holyc + kernel.register. */
export function printG6bJs(files: SvelteFile[]): string {
  const lines: string[] = [];
  const seenText = new Set<string>();
  const seenFetch = new Set<string>();
  const seenHolyc = new Set<string>();
  const seenReg = new Set<string>();
  for (const f of files) {
    for (const o of f.ops) {
      if (o.kind === "text") {
        if (!o.value) continue;
        const k = `${o.id}\0${o.value}`;
        if (seenText.has(k)) continue;
        seenText.add(k);
        lines.push(
          `document.getElementById(${JSON.stringify(o.id)}).innerText = ${JSON.stringify(o.value)};`,
        );
      } else if (o.kind === "visible") {
        lines.push(`document.getElementById(${JSON.stringify(o.id)}).hidden = ${!o.on};`);
      } else if (o.kind === "fetch") {
        if (seenFetch.has(o.url)) continue;
        seenFetch.add(o.url);
        lines.push(`fetch(${JSON.stringify(o.url)});`);
      } else if (o.kind === "holyc") {
        if (seenHolyc.has(o.line)) continue;
        seenHolyc.add(o.line);
        lines.push(`kernel.holyc(${JSON.stringify(o.line)});`);
      } else if (o.kind === "register") {
        const k = `${o.method} ${o.path}`;
        if (seenReg.has(k)) continue;
        seenReg.add(k);
        lines.push(`kernel.register(${JSON.stringify(o.path)}, ${JSON.stringify(o.method)});`);
      }
    }
  }
  lines.push("");
  return lines.join("\n");
}
