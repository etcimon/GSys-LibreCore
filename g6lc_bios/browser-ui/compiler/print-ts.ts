// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/**
 * lang=ts splice into src-ts jsExports / __svelteD.ts (svelte-d cross-calling).
 * Spec: kernel-spec/svelte-d/architecture/cross-calling.md
 */

import type { PgliteOp, SvelteFile } from "./parse.ts";

export function printGeneratedTs(file: SvelteFile): string {
  const fetches = file.ops.filter((o) => o.kind === "fetch");
  const holycs = file.ops.filter((o) => o.kind === "holyc");
  const regs = file.ops.filter((o) => o.kind === "register");
  const pglites = file.ops.filter((o) => o.kind === "pglite");
  const lines: string[] = [];
  lines.push(`// Generated from ${file.rel} (lang=ts)`);
  lines.push(`import { ensureSvelteD } from "../libwasm.ts";`);
  lines.push("");
  lines.push(`export function fetchBios(url: string) { fetch(url); }`);
  lines.push(`export function holycEval(line: string) { return kernel.holyc(line); }`);
  lines.push(
    `export function registerEndpoint(path: string, method = "GET") { kernel.register(path, method); }`,
  );
  lines.push(`export function pgliteOpen(dataDir = "registry") { return pglite(dataDir); }`);
  lines.push("declare const pglite: (dataDir?: string) => {");
  lines.push("  exec(sql: string): Promise<unknown>;");
  lines.push("  query(sql: string, params?: string): Promise<unknown>;");
  lines.push("  queryAsync(sql: string, params?: string): Promise<unknown>;");
  lines.push("  stat(): Promise<{ ok?: boolean; live?: boolean; ready?: boolean }>;");
  lines.push("  waitReady(): unknown;");
  lines.push("  listen(channel: string): Promise<unknown>;");
  lines.push("  unlisten(channel?: string): Promise<unknown>;");
  lines.push("  begin(): Promise<unknown>;");
  lines.push("  commit(): Promise<unknown>;");
  lines.push("  rollback(): Promise<unknown>;");
  lines.push("  dump(): Promise<unknown>;");
  lines.push("  load(json: string): Promise<unknown>;");
  lines.push("  close(): Promise<unknown>;");
  lines.push("  exportUsb?(volume: string, rel?: string): Promise<unknown>;");
  lines.push("};");
  lines.push("");
  lines.push("const _reg = ensureSvelteD();");
  lines.push(`_reg.registerTs(${JSON.stringify(file.ident)}, "fetchBios", fetchBios);`);
  lines.push(`_reg.registerTs(${JSON.stringify(file.ident)}, "holycEval", holycEval);`);
  lines.push(
    `_reg.registerTs(${JSON.stringify(file.ident)}, "registerEndpoint", registerEndpoint);`,
  );
  if (fetches.length || holycs.length || regs.length || pglites.length) {
    lines.push(pglites.length ? "export async function mount() {" : "export function mount() {");
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
    if (pglites.length) {
      lines.push(...printTsPgliteMount(file));
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

/** g6b-js AOT subset: innerText + fetch + kernel.holyc + kernel.register.
 *  pglite stays out — g6b-js must not depend on g6b-pglite; LDC `_start`
 *  and lang=ts `mount()` run SQL. */
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

function printTsPgliteCall(op: PgliteOp): string | undefined {
  switch (op.method) {
    case "open":
      return undefined;
    case "exec":
      return `await db.exec(${JSON.stringify(op.arg1)})`;
    case "query":
    case "queryAsync":
      return `await db.query(${JSON.stringify(op.arg1)}, ${JSON.stringify(op.arg2 || "[]")})`;
    case "stat":
    case "waitReady":
      return "await db.stat()";
    case "listen":
      return `await db.listen(${JSON.stringify(op.arg1)})`;
    case "unlisten":
      return `await db.unlisten(${JSON.stringify(op.arg1 || "*")})`;
    case "begin":
      return "await db.begin()";
    case "commit":
      return "await db.commit()";
    case "rollback":
      return "await db.rollback()";
    case "dump":
      return "await db.dump()";
    case "load":
      return `await db.load(${JSON.stringify(op.arg1)})`;
    case "close":
      return "await db.close()";
    case "export":
      return op.arg2
        ? `await db.exportUsb(${JSON.stringify(op.arg1)}, ${JSON.stringify(op.arg2)})`
        : `await db.exportUsb(${JSON.stringify(op.arg1)})`;
    case "notifies":
      return "await db.notifies()";
  }
}

function printTsPgliteMount(file: SvelteFile): string[] {
  const pglites = file.ops.filter((o): o is PgliteOp => o.kind === "pglite");
  const open = [...pglites].reverse().find((o) => o.method === "open");
  const lines: string[] = [];
  lines.push(`  const db = pglite(${JSON.stringify(open?.arg1 || "registry")});`);
  for (const op of pglites) {
    const expr = printTsPgliteCall(op);
    if (!expr) continue;
    lines.push(op.bind ? `  const ${op.bind} = ${expr};` : `  ${expr};`);
  }
  for (const op of file.ops) {
    if (op.kind !== "text" || !op.bind) continue;
    const rhs = op.field
      ? `JSON.stringify(${op.bind} && ${op.bind}.${op.field})`
      : `JSON.stringify(${op.bind})`;
    lines.push(`  document.getElementById(${JSON.stringify(op.id)}).innerText = ${rhs};`);
  }
  return lines;
}
