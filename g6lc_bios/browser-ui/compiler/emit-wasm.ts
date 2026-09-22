// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/**
 * First-party WASM MVP encoder matching g6b-wasm.
 * Imports: env.set_inner_text(i32,i32,i32,i32), env.fetch(i32,i32),
 * env.await() — a bounded nonblocking await-slot claim (WasmAwait on the
 * guest, the host's deferred-completion queue in the browser).
 * Export: memory, _start.
 */

import { parseMarkupTree, type FetchOp, type MarkupNode, type SvelteFile, type TextOp, type VisibleOp } from "./parse.ts";

export function emitWasm(files: SvelteFile[]): Uint8Array {
  const texts: TextOp[] = [];
  const fetches: FetchOp[] = [];
  const visible: VisibleOp[] = [];
  const seenT = new Set<string>();
  const seenF = new Set<string>();
  let awaits = 0;
  for (const f of files) {
    for (const o of f.ops) {
      if (o.kind === "text") {
        if (!o.value) continue;
        const k = `${o.id}\0${o.value}`;
        if (seenT.has(k)) continue;
        seenT.add(k);
        texts.push(o);
      } else if (o.kind === "fetch") {
        if (seenF.has(o.url)) continue;
        seenF.add(o.url);
        fetches.push(o);
      } else if (o.kind === "visible") {
        visible.push(o);
      } else if (o.kind === "await") {
        awaits++;
      }
    }
  }
  // The guest glyph face is a flat row table. `hidden` on a section does not
  // hide the text rows of its children, so those ids are hidden explicitly.
  // This list is wasm-only: stamping `hidden` onto the HTML would break row injection.
  for (const id of glyphHiddenTextIds(files, new Set(texts.map((op) => op.id)))) {
    const prior = visible.findIndex((op) => op.id === id);
    if (prior >= 0) visible.splice(prior, 1);
    visible.push({ kind: "visible", id, on: false });
  }
  if (texts.length === 0) {
    texts.push({ kind: "text", id: "status", value: "UI-BOOT" });
  }
  return encode(texts, fetches, visible, awaits);
}

function glyphHiddenTextIds(files: SvelteFile[], textIds: Set<string>): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  const walk = (node: MarkupNode | string, hidden: boolean) => {
    if (typeof node === "string") return;
    const now = hidden || Object.hasOwn(node.attrs, "hidden");
    const id = node.attrs.id;
    if (now && id && textIds.has(id) && !seen.has(id)) {
      seen.add(id);
      out.push(id);
    }
    for (const child of node.children) walk(child, now);
  };
  for (const file of files) {
    for (const root of parseMarkupTree(file.src)) walk(root, false);
  }
  return out;
}

function encode(texts: TextOp[], fetches: FetchOp[], visible: VisibleOp[], awaits: number): Uint8Array {
  type Slot = { off: number; len: number };
  const mem: number[] = [];
  const intern = (s: string): Slot => {
    const off = mem.length;
    for (let i = 0; i < s.length; i++) mem.push(s.charCodeAt(i) & 0xff);
    mem.push(0);
    while (mem.length % 4 !== 0) mem.push(0);
    return { off, len: s.length };
  };
  const textSlots = texts.map((t) => ({ id: intern(t.id), val: intern(t.value) }));
  const fetchSlots = fetches.map((f) => intern(f.url));
  const visibleSlots = visible.map((v) => ({ id: intern(v.id), on: v.on }));
  const hasVisibility = visibleSlots.length > 0;
  const hasAwait = awaits > 0;
  const importCount = 2 + (hasVisibility ? 1 : 0) + (hasAwait ? 1 : 0);
  const awaitIdx = importCount - 1;
  // env.await's ()->i32 type is appended after set_visible's entry.
  const awaitTypeIdx = 2 + (hasVisibility ? 1 : 0) + (hasAwait ? 1 : 0);
  if (mem.length < 64) {
    while (mem.length < 64) mem.push(0);
  }

  const out: number[] = [];
  out.push(0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00);

  const types: number[] = [];
  pushUleb(types, 3 + (hasVisibility ? 1 : 0) + (hasAwait ? 1 : 0));
  types.push(0x60, 4, 0x7f, 0x7f, 0x7f, 0x7f, 0); // set_inner_text
  types.push(0x60, 2, 0x7f, 0x7f, 0); // fetch
  types.push(0x60, 0, 0); // _start
  if (hasVisibility) types.push(0x60, 3, 0x7f, 0x7f, 0x7f, 0);
  if (hasAwait) types.push(0x60, 0, 1, 0x7f); // await: ()->i32
  section(out, 1, types);

  const imports: number[] = [];
  pushUleb(imports, importCount);
  putName(imports, "env");
  putName(imports, "set_inner_text");
  imports.push(0x00);
  pushUleb(imports, 0);
  putName(imports, "env");
  putName(imports, "fetch");
  imports.push(0x00);
  pushUleb(imports, 1);
  if (hasVisibility) {
    putName(imports, "env");
    putName(imports, "set_visible");
    imports.push(0x00);
    pushUleb(imports, 3);
  }
  if (hasAwait) {
    // env.await(): ()->i32 — the claimed slot (or -1 when the bounded
    // queue is full).
    putName(imports, "env");
    putName(imports, "await");
    imports.push(0x00);
    pushUleb(imports, awaitTypeIdx);
  }
  section(out, 2, imports);

  const funcs: number[] = [];
  pushUleb(funcs, 1);
  pushUleb(funcs, 2);
  section(out, 3, funcs);

  const memory: number[] = [];
  pushUleb(memory, 1);
  memory.push(0x00);
  pushUleb(memory, 1);
  section(out, 5, memory);

  const exports: number[] = [];
  pushUleb(exports, 2);
  putName(exports, "memory");
  exports.push(0x02);
  pushUleb(exports, 0);
  putName(exports, "_start");
  exports.push(0x00);
  pushUleb(exports, importCount);
  section(out, 7, exports);

  const body: number[] = [];
  pushUleb(body, 0);
  for (const t of textSlots) {
    body.push(0x41);
    pushIleb(body, t.id.off);
    body.push(0x41);
    pushIleb(body, t.id.len);
    body.push(0x41);
    pushIleb(body, t.val.off);
    body.push(0x41);
    pushIleb(body, t.val.len);
    body.push(0x10);
    pushUleb(body, 0);
  }
  for (const v of visibleSlots) {
    body.push(0x41);
    pushIleb(body, v.id.off);
    body.push(0x41);
    pushIleb(body, v.id.len);
    body.push(0x41);
    pushIleb(body, v.on ? 1 : 0);
    body.push(0x10);
    pushUleb(body, 2);
  }
  for (const f of fetchSlots) {
    body.push(0x41);
    pushIleb(body, f.off);
    body.push(0x41);
    pushIleb(body, f.len);
    body.push(0x10);
    pushUleb(body, 1);
  }
  // `await fetch(...)` ops: the request started above; `call env.await`
  // claims a bounded completion slot — it never blocks the caller. The
  // returned slot index is dropped (the completion arrives via the queue).
  for (let i = 0; i < awaits; i++) {
    body.push(0x10);
    pushUleb(body, awaitIdx);
    body.push(0x1a); // drop
  }
  body.push(0x0b);
  const code: number[] = [];
  pushUleb(code, 1);
  pushUleb(code, body.length);
  code.push(...body);
  section(out, 10, code);

  const data: number[] = [];
  pushUleb(data, 1);
  data.push(0x00);
  data.push(0x41);
  pushIleb(data, 0);
  data.push(0x0b);
  pushUleb(data, mem.length);
  data.push(...mem);
  section(out, 11, data);

  return Uint8Array.from(out);
}

function section(out: number[], id: number, payload: number[]) {
  out.push(id);
  pushUleb(out, payload.length);
  out.push(...payload);
}

function putName(out: number[], s: string) {
  pushUleb(out, s.length);
  for (let i = 0; i < s.length; i++) out.push(s.charCodeAt(i) & 0xff);
}

function pushUleb(out: number[], n: number) {
  let v = n >>> 0;
  while (v >= 0x80) {
    out.push((v & 0x7f) | 0x80);
    v >>>= 7;
  }
  out.push(v);
}

function pushIleb(out: number[], n: number) {
  let v = n | 0;
  for (;;) {
    const b = v & 0x7f;
    v >>= 7;
    const sign = (b & 0x40) !== 0;
    if ((v === 0 && !sign) || (v === -1 && sign)) {
      out.push(b);
      break;
    }
    out.push(b | 0x80);
  }
}
