// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/** First-party .svelte parse. Not svelte/compiler. Spec: kernel-spec/svelte-d Pegged. */

import { refuseKit } from "./constructs.ts";

export type Binding = { name: string; value: string };

export type TextOp = { kind: "text"; id: string; value: string };
export type FetchOp = { kind: "fetch"; url: string };
export type HolycOp = { kind: "holyc"; line: string };
export type RegisterOp = { kind: "register"; path: string; method: string };
export type UiOp = TextOp | FetchOp | HolycOp | RegisterOp;

export type SvelteFile = {
  rel: string;
  ident: string;
  tag: string;
  langTs: boolean;
  lets: Binding[];
  ops: UiOp[];
  src: string;
};

export function identFromRel(rel: string): string {
  return rel
    .replace(/\\/g, "/")
    .replace(/^src\//, "")
    .replace(/[^A-Za-z0-9]+/g, "_")
    .replace(/^_|_$/g, "");
}

export function parseSvelte(rel: string, src: string): SvelteFile {
  const kit = refuseKit(src);
  if (kit) throw new Error(kit);
  const script = extractScript(src);
  const lets = parseLets(script.body);
  const ops: UiOp[] = [];
  ops.push(...parseCalls(script.body));
  ops.push(...parseMarkup(src, lets));
  const tag = firstTag(src) ?? "div";
  return {
    rel,
    ident: identFromRel(rel),
    tag,
    langTs: script.langTs,
    lets,
    ops,
    src,
  };
}

function extractScript(src: string): { body: string; langTs: boolean } {
  const m = src.match(/<script\b([^>]*)>([\s\S]*?)<\/script>/i);
  if (!m) return { body: "", langTs: false };
  const attrs = m[1] ?? "";
  const langTs = /lang\s*=\s*["']ts["']/i.test(attrs);
  return { body: m[2] ?? "", langTs };
}

function parseLets(body: string): Binding[] {
  const out: Binding[] = [];
  for (const line of body.split(/\r?\n/)) {
    const t = line.trim();
    const m = t.match(/^let\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?);?\s*$/);
    if (!m) continue;
    let val = m[2].trim().replace(/;$/, "");
    if (val.startsWith('"') && val.endsWith('"') && val.length >= 2) {
      val = val.slice(1, -1);
    }
    out.push({ name: m[1], value: val });
  }
  return out;
}

function parseCalls(body: string): UiOp[] {
  const ops: UiOp[] = [];
  const fetchRe = /(?:fetchBios|fetch)\(\s*(["'])([^"']+)\1\s*\)/g;
  let m: RegExpExecArray | null;
  while ((m = fetchRe.exec(body))) {
    ops.push({ kind: "fetch", url: m[2] });
  }
  const holycRe = /(?:holycEval|kernel\.holyc)\(\s*(["'])((?:\\.|[^\\'"])*)\1\s*\)/g;
  while ((m = holycRe.exec(body))) {
    ops.push({ kind: "holyc", line: unesc(m[2]) });
  }
  const regRe =
    /(?:registerEndpoint|kernel\.register)\(\s*(["'])([^"']+)\1(?:\s*,\s*(["'])([^"']+)\3)?\s*\)/g;
  while ((m = regRe.exec(body))) {
    ops.push({ kind: "register", path: m[2], method: m[4] ?? "GET" });
  }
  return ops;
}

function unesc(s: string): string {
  return s.replace(/\\n/g, "\n").replace(/\\t/g, "\t").replace(/\\"/g, '"').replace(/\\'/g, "'");
}

function parseMarkup(src: string, lets: Binding[]): TextOp[] {
  const ops: TextOp[] = [];
  const re = /id\s*=\s*"([^"]+)"[^>]*>([^<]*)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(src))) {
    const id = m[1];
    const raw = m[2].trim();
    ops.push({ kind: "text", id, value: interp(raw, lets) });
  }
  return ops;
}

function interp(text: string, lets: Binding[]): string {
  const t = text.trim();
  if (t.startsWith("{") && t.endsWith("}")) {
    const name = t.slice(1, -1).trim();
    const hit = lets.find((l) => l.name === name);
    if (hit) return hit.value;
  }
  return t;
}

function firstTag(src: string): string | undefined {
  const m = src.match(/<(section|div|p|nav|main|article|header|footer)\b/i);
  return m?.[1]?.toLowerCase();
}
