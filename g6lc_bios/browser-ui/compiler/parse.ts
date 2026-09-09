// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/** First-party .svelte parse. Not svelte/compiler. Spec: kernel-spec/svelte-d Pegged. */

import { refuseKit } from "./constructs.ts";

export type Binding = { name: string; value: string; constantBoolean?: boolean };

export type TextOp = { kind: "text"; id: string; value: string };
export type FetchOp = { kind: "fetch"; url: string };
export type HolycOp = { kind: "holyc"; line: string };
export type RegisterOp = { kind: "register"; path: string; method: string };
export type VisibleOp = { kind: "visible"; id: string; on: boolean };
export type AwaitOp = { kind: "await" };
export type UiOp = TextOp | FetchOp | HolycOp | RegisterOp | VisibleOp | AwaitOp;

export type SvelteFile = {
  rel: string;
  ident: string;
  tag: string;
  langTs: boolean;
  lets: Binding[];
  ops: UiOp[];
  src: string;
};

export type MarkupNode = {
  tag: string;
  attrs: Record<string, string>;
  children: (MarkupNode | string)[];
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
  const markup = src.replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, "");
  ops.push(...parseMarkup(markup, lets));
  ops.push(...parseVisibility(markup, lets));
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
    const constantBoolean = val === "true" ? true : val === "false" ? false : undefined;
    if (val.startsWith('"') && val.endsWith('"') && val.length >= 2) {
      val = val.slice(1, -1);
    }
    out.push({ name: m[1], value: val, constantBoolean });
  }
  return out;
}

function parseCalls(body: string): UiOp[] {
  const ops: UiOp[] = [];
  const fetchRe = /(await\s+)?(?:fetchBios|fetch)\(\s*(["'])([^"']+)\2\s*\)/g;
  let m: RegExpExecArray | null;
  while ((m = fetchRe.exec(body))) {
    ops.push({ kind: "fetch", url: m[3] });
    // `await fetch(...)` → the request op plus a bounded await-slot claim
    // (`env.await`): the guest's nonblocking correlate of `await`.
    if (m[1] !== undefined) ops.push({ kind: "await" });
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
  const re = /\bid\s*=\s*(["'])(.*?)\1[^>]*>([^<]*)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(src))) {
    const id = m[2];
    const raw = m[3].replace(/\{(?:#if\s+[^}]+|:else|\/if)\}/g, "").trim();
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

function parseVisibility(src: string, lets: Binding[]): VisibleOp[] {
  const ops: VisibleOp[] = [];
  const stack: { on: boolean; alternate: boolean }[] = [];
  const re = /\{#if\s+([^}]+)\}|\{:else(?:\s+[^}]+)?\}|\{\/if\}|<[a-z][a-z0-9-]*\b([^>]*)>/gi;
  let match: RegExpExecArray | null;
  while ((match = re.exec(src))) {
    if (match[1] !== undefined) {
      if (stack.length >= 32) throw new Error("conditional nesting budget exceeded");
      const expr = match[1].trim();
      const negated = expr.startsWith("!");
      const name = negated ? expr.slice(1).trim() : expr;
      const value = name === "true" ? true : name === "false" ? false : lets.find((binding) => binding.name === name)?.constantBoolean;
      if (value === undefined) throw new Error("#if requires an initial boolean literal: " + expr);
      stack.push({ on: negated ? !value : value, alternate: false });
    } else if (match[0].startsWith("{:else")) {
      const top = stack.at(-1);
      if (!top || top.alternate || match[0] !== "{:else}") throw new Error("unsupported #if else branch");
      top.on = !top.on;
      top.alternate = true;
    } else if (match[0] === "{/if}") {
      if (!stack.pop()) throw new Error("unmatched /if");
    } else if (stack.length) {
      const id = match[2]?.match(/\bid\s*=\s*(["'])(.*?)\1/)?.[2];
      if (!id) throw new Error("bounded #if elements require an id");
      ops.push({ kind: "visible", id, on: stack.every((scope) => scope.on) });
    }
  }
  if (stack.length) throw new Error("unclosed #if");
  return ops;
}

function firstTag(src: string): string | undefined {
  const m = src.match(/<(section|div|p|nav|main|article|header|footer)\b/i);
  return m?.[1]?.toLowerCase();
}

function parseAttrs(raw: string): Record<string, string> {
  const attrs: Record<string, string> = {};
  for (const m of raw.matchAll(/\b((?:on:[a-z]+)|[a-z][a-z0-9-]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>"']+)))?/gi)) {
    const name = m[1].toLowerCase();
    const value = m[2] ?? m[3] ?? m[4] ?? "";
    attrs[name] = value;
  }
  return attrs;
}

const VOID_TAGS = new Set([
  "area", "base", "br", "col", "embed", "hr", "img", "input",
  "link", "meta", "param", "source", "track", "wbr",
]);

export function parseMarkupTree(src: string): MarkupNode[] {
  const markup = src.replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, "");
  const roots: MarkupNode[] = [];
  const stack: MarkupNode[] = [];
  const tokenRe = /(<(\/?)([a-z][a-z0-9-]*)\b([^>]*)>)|([^<]+)/gi;
  let m: RegExpExecArray | null;
  while ((m = tokenRe.exec(markup)) !== null) {
    if (m[1] !== undefined) {
      const closing = m[2] !== "";
      const tag = m[3].toLowerCase();
      const attrStr = m[4];
      if (closing) {
        if (stack.length === 0 || stack.at(-1)!.tag !== tag) throw new Error("unmatched markup tag: " + tag);
        const node = stack.pop()!;
        if (stack.length) stack.at(-1)!.children.push(node);
        else roots.push(node);
        continue;
      }
      const selfClosing = attrStr.trimEnd().endsWith("/") || VOID_TAGS.has(tag);
      const node: MarkupNode = { tag, attrs: parseAttrs(attrStr), children: [] };
      if (selfClosing) {
        if (stack.length) stack.at(-1)!.children.push(node);
        else roots.push(node);
      } else {
        stack.push(node);
      }
    } else {
      const text = m[5].replace(/\s+/g, " ").trim();
      if (text) {
        if (stack.length) stack.at(-1)!.children.push(text);
        else roots.push({ tag: "span", attrs: {}, children: [text] });
      }
    }
  }
  if (stack.length) throw new Error("unclosed markup tag");
  return roots;
}
