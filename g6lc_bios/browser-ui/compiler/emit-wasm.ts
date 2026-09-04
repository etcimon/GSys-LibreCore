// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/**
 * First-party WASM MVP encoder matching g6b-wasm.
 * Imports: env.set_inner_text(i32,i32,i32,i32), env.fetch(i32,i32).
 * Export: memory, _start.
 */

import type { FetchOp, SvelteFile, TextOp } from "./parse.ts";

export function emitWasm(files: SvelteFile[]): Uint8Array {
  const texts: TextOp[] = [];
  const fetches: FetchOp[] = [];
  const seenT = new Set<string>();
  const seenF = new Set<string>();
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
      }
    }
  }
  if (texts.length === 0) {
    texts.push({ kind: "text", id: "status", value: "UI-BOOT" });
  }
  return encode(texts, fetches);
}

function encode(texts: TextOp[], fetches: FetchOp[]): Uint8Array {
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
  if (mem.length < 64) {
    while (mem.length < 64) mem.push(0);
  }

  const out: number[] = [];
  out.push(0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00);

  const types: number[] = [];
  pushUleb(types, 3);
  types.push(0x60, 4, 0x7f, 0x7f, 0x7f, 0x7f, 0); // set_inner_text
  types.push(0x60, 2, 0x7f, 0x7f, 0); // fetch
  types.push(0x60, 0, 0); // _start
  section(out, 1, types);

  const imports: number[] = [];
  pushUleb(imports, 2);
  putName(imports, "env");
  putName(imports, "set_inner_text");
  imports.push(0x00);
  pushUleb(imports, 0);
  putName(imports, "env");
  putName(imports, "fetch");
  imports.push(0x00);
  pushUleb(imports, 1);
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
  pushUleb(exports, 2);
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
  for (const f of fetchSlots) {
    body.push(0x41);
    pushIleb(body, f.off);
    body.push(0x41);
    pushIleb(body, f.len);
    body.push(0x10);
    pushUleb(body, 1);
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
