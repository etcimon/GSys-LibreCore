// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from "bun:test";
import { dirname, join } from "node:path";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { catalogJson, marker, refuseKit } from "./constructs.ts";
import { compileProject, loadProject, projectHtml } from "./index.ts";
import { emitWasm } from "./emit-wasm.ts";
import { printG6bJs, printGeneratedTs } from "./print-ts.ts";
import { createWasmHost, createBrowserApp, createLibwasmHost, createParticleBackground, createRenderInspector, createBrowserContext, createPgliteWasm } from "../src/kernel.ts";
import { isLdc143Text, resolveToolchain } from "./ldc.ts";
import { parseSvelte } from "./parse.ts";
import { printApp } from "./print-d.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

class TestNode {
  private text = "";
  parentNode: TestNode | null = null;
  tagName = "DIV";
  get textContent(): string { return this.text + this.children.map((c) => c.textContent).join(""); }
  set textContent(value: string) { this.replaceChildren(); this.text = value; }
  get childNodes() { return this.children; }
  contains(node: TestNode): boolean { return this === node || this.children.some((c) => c.contains(node)); }
  appendChild(node: TestNode) { return this.insertBefore(node, null); }
  insertBefore(node: TestNode, sibling: TestNode | null) {
    if (node === sibling) return node;
    if (node.contains(this) || (sibling && sibling.parentNode !== this)) throw new Error("invalid hierarchy");
    node.remove();
    this.children.splice(sibling ? this.children.indexOf(sibling) : this.children.length, 0, node);
    node.parentNode = this;
    return node;
  }
  remove() {
    if (this.parentNode) this.parentNode.children.splice(this.parentNode.children.indexOf(this), 1);
    this.parentNode = null;
  }
  replaceChildren(...nodes: TestNode[]) {
    for (const child of this.children) child.parentNode = null;
    this.children = [];
    this.text = "";
    for (const child of nodes) this.appendChild(child);
  }
  hidden = false;
  attrs = new Map<string, string>();
  children: TestNode[] = [];
  listeners = new Map<string, Function>();
  constructor(public id: string, attrs: Record<string, string> = {}) {
    for (const [key, value] of Object.entries(attrs)) this.attrs.set(key, value);
  }
  getAttribute(key: string) { return this.attrs.get(key) ?? null; }
  setAttribute(key: string, value: string) { this.attrs.set(key, value); }
  removeAttribute(key: string) { this.attrs.delete(key); }
  classList = {
    list: new Set<string>(),
    add: (c: string) => { this.classList.list.add(c); },
    remove: (c: string) => { this.classList.list.delete(c); },
    toggle: (c: string) => {
      if (this.classList.list.has(c)) { this.classList.list.delete(c); return false; }
      this.classList.list.add(c); return true;
    },
    contains: (c: string) => this.classList.list.has(c),
  };
  addEventListener(key: string, callback: Function) { this.listeners.set(key, callback); }
  removeEventListener(key: string, callback: Function) { if (this.listeners.get(key) === callback) this.listeners.delete(key); }
  querySelectorAll(selector: string) {
    return this.children.filter((n) => n.attrs.has(selector.slice(1, -1)));
  }
}

function testDocument(nodes: TestNode[]) {
  return {
    createElement: (tag: string) => { const node = new TestNode(""); node.tagName = tag.toUpperCase(); return node; },
    getElementById: (id: string) => nodes.find((n) => n.id === id) ?? null,
    querySelectorAll: (selector: string) => nodes.filter((n) => n.attrs.has(selector.slice(1, -1))),
  };
}

describe("browser DOM and import ABI", () => {
  test("served adapter is native JavaScript without TypeScript or an injected kernel", () => {
    const adapter = readFileSync(join(root, "src/kernel.ts"), "utf8");
    expect(() => new Function(adapter.replace(/^export /gm, ""))()).not.toThrow();
    expect(adapter).not.toContain("declare const kernel");
  });

  test("generated HTML includes every compiled text target and never loads host AOT", () => {
    const files = loadProject(join(root, "src"));
    const html = projectHtml(files);
    for (const file of files) for (const op of file.ops) {
      if (op.kind === "text") expect(html).toContain(`id="${op.id}"`);
    }
    expect(html).not.toContain('src="./bios-ui.js"');
    expect(html).not.toContain("kernel.holyc");
    expect(html).toContain('<main id="bios-ui"');
    expect(html).toContain('id="status"');
    expect(html).toContain('<nav id="bios-menu"');
    expect(html).toContain('id="menu-title"');
    const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]);
    expect(new Set(ids).size).toBe(ids.length);
    expect(() => projectHtml([files[0], files[0]])).toThrow(/duplicate/);
  });

  test("bounded constant visibility lowers to hidden rather than deleting text", () => {
    const file = parseSvelte("src/Hidden.svelte", '<script>let show = false;</script>{#if show}<p id="kept">retained</p>{/if}');
    expect(file.ops).toContainEqual({ kind: "visible", id: "kept", on: false });
    expect(printG6bJs([file])).toContain('document.getElementById("kept").hidden = true;');
    expect(projectHtml([file])).toContain('id="kept" hidden');
    expect(() => parseSvelte("src/Bad.svelte", '{#if unknown}<p id="x">x</p>{/if}')).toThrow();
  });

  test("emitted WASM executes if/else visibility with text and fetch imports intact", async () => {
    for (const show of [false, true]) {
      const file = parseSvelte("src/Conditional.svelte", `<script>
let show = ${show};
fetchBios("/bios/menu/cpu");
</script><section id="conditional">{#if show}<p id="yes">retained yes</p>{:else}<p id="no">retained no</p>{/if}</section>`);
      const yes = new TestNode("yes");
      const no = new TestNode("no");
      yes.hidden = show;
      no.hidden = !show;
      const reads: string[] = [];
      const host = createWasmHost(testDocument([yes, no]), new Set(["/bios/menu/cpu"]), async (url: string) => { reads.push(url); });
      const bytes = emitWasm([file]);
      expect(WebAssembly.validate(bytes)).toBe(true);
      const { instance } = await WebAssembly.instantiate(bytes, host.imports);
      host.bind(instance.exports.memory);
      (instance.exports._start as Function)();
      expect(yes.hidden).toBe(!show);
      expect(no.hidden).toBe(show);
      expect(yes.textContent).toBe("retained yes");
      expect(no.textContent).toBe("retained no");
      expect(reads).toEqual([]);
      await host.drain();
      expect(reads).toEqual(["/bios/menu/cpu"]);
      const html = projectHtml([file]);
      expect(html).toContain('<section id="conditional">');
      expect(html).toContain(`id="${show ? "no" : "yes"}" hidden`);
      host.rollback();
      expect(yes.hidden).toBe(show);
      expect(no.hidden).toBe(!show);
    }
  });

  test("conditional sibling containers remain siblings in the static preview", () => {
    const file = parseSvelte("src/Siblings.svelte", '{#if false}<section id="first"><p id="first-text">first</p></section>{:else}<section id="second"><p id="second-text">second</p></section>{/if}');
    const html = projectHtml([file]);
    expect(html).toContain('<section id="first" hidden>\n<p id="first-text" hidden>first</p>\n</section>\n<section id="second">');
    expect(html).toContain('<p id="second-text">second</p>\n</section>');
  });

  test("native start menu CPU works with the browser fetch proxy disabled", async () => {
    const ui = new TestNode("bios-ui", { "data-start-menu": "cpu" });
    const status = new TestNode("status");
    const main = new TestNode("menu-main", { "data-menu": "main" });
    const cpu = new TestNode("menu-cpu", { "data-menu": "cpu" });
    const link = new TestNode("cpu-link", { "data-menu-link": "cpu" });
    const reads: string[] = [];
    const app = createBrowserApp(testDocument([ui, status, main, cpu, link]), async (url: string) => { reads.push(url); throw new Error("proxy disabled"); });
    await app.start();
    expect(main.hidden).toBe(true);
    expect(cpu.hidden).toBe(false);
    expect(link.getAttribute("aria-current")).toBe("page");
    expect(status.textContent).toContain("Static view");
    await app.navigate("main");
    await app.refresh();
    expect(reads).toEqual([]);
  });

  test("BIOS keyboard navigation wraps without intercepting editing or issuing writes", async () => {
    const ui = new TestNode("bios-ui", { "data-start-menu": "cpu" });
    const main = new TestNode("menu-main", { "data-menu": "main" });
    const cpu = new TestNode("menu-cpu", { "data-menu": "cpu" });
    const reads: string[] = [];
    const app = createBrowserApp(testDocument([ui, main, cpu]), async (url: string) => { reads.push(url); throw new Error("disabled"); });
    await app.start();
    for (const [key, expected] of [["ArrowLeft", main], ["ArrowLeft", cpu], ["Home", main], ["End", cpu], ["ArrowRight", main]] as const) {
      let handled = false;
      await app.handleKey({ key, preventDefault() { handled = true; } });
      expect(handled).toBe(true);
      expect(expected.hidden).toBe(false);
    }
    const preventDefault = () => { throw new Error("must not intercept"); };
    await app.handleKey({ key: "ArrowRight", target: { tagName: "INPUT" }, preventDefault });
    await app.handleKey({ key: "ArrowRight", ctrlKey: true, preventDefault });
    await app.handleKey({ key: "F10", repeat: true, preventDefault });
    await app.handleKey({ key: "Delete", preventDefault });
    await app.handleKey({ key: "F10", preventDefault() {} });
    expect(reads).toEqual([]);
    expect(ui.listeners.has("keydown")).toBe(true);
  });

  test("WASM URLs cannot normalize to remote origins or traversal", async () => {
    for (const url of ["//remote/ui.wasm", "/\\\\remote/ui.wasm", "/ui/../ui.wasm", "/ui/%2e%2e/ui.wasm", "https://remote/ui.wasm"]) {
      const ui = new TestNode("bios-ui", { "data-wasm-url": url });
      const status = new TestNode("status");
      let reads = 0;
      await createBrowserApp(testDocument([ui, status]), async () => { reads++; throw new Error("should not fetch"); }).start();
      expect(reads).toBe(0);
      expect(status.textContent).toContain("local");
    }
  });

  test("emitted module fetches only allowed menu endpoints and preserves static chrome", async () => {
    const files = loadProject(join(root, "src"));
    const nodes = new Map<string, TestNode>();
    for (const file of files) for (const op of file.ops) {
      if (op.kind === "text") nodes.set(op.id, new TestNode(op.id));
    }
    nodes.get("bios-ui")!.setAttribute("data-wasm-url", "/custom/ui.wasm");
    const status = nodes.get("status")!;
    const reads: string[] = [];
    const app = createBrowserApp(testDocument([...nodes.values()]), async (url: string) => {
      reads.push(url);
      if (url === "/custom/ui.wasm") return { ok: true, arrayBuffer: async () => emitWasm(files) };
      return { ok: true, json: async () => ({ ok: true }) };
    });
    await app.start();
    expect(status.textContent).not.toContain("failed");
    expect(new Set(reads)).toContain("/custom/ui.wasm");
  });

  test("native module calls _start with real pointer imports and drains asynchronous reads", async () => {
    const status = new TestNode("status");
    const doc = testDocument([status]);
    const reads: string[] = [];
    const host = createWasmHost(doc, new Set(["/bios/menu/cpu"]), async (url: string) => {
      await Promise.resolve();
      reads.push(url);
    });
    const file = parseSvelte("src/Test.svelte", '<script>fetchBios("/bios/menu/cpu");fetchBios("/bios/files/ntfs");</script><p id="status">UI-BOOT</p>');
    const { instance } = await WebAssembly.instantiate(emitWasm([file]), host.imports);
    host.bind(instance.exports.memory);
    (instance.exports._start as Function)();
    expect(reads).toEqual([]);
    await host.drain();
    expect(status.textContent).toBe("UI-BOOT");
    expect(reads).toEqual(["/bios/menu/cpu"]);
  });

  test("all import functions check memory and preserve visible text", async () => {
    const text = new TestNode("x");
    text.textContent = "original";
    const logged: string[] = [];
    const host = createWasmHost(testDocument([text]), new Set(["/bios/menu/cpu"]), async () => {}, (message: string) => logged.push(message));
    const memory = new WebAssembly.Memory({ initial: 1 });
    host.bind(memory);
    const bytes = new TextEncoder().encode("xhello/bios/menu/cpu");
    new Uint8Array(memory.buffer).set(bytes);
    const env = host.imports.env;
    expect(env.set_inner_text(0, 1, 1, 5)).toBeUndefined();
    expect(env.console_log(1, 5)).toBeUndefined();
    expect(env.set_visible(0, 1, 0)).toBeUndefined();
    expect(env.fetch(6, 14)).toBeUndefined();
    expect(env.Object_Call_string__Handle(6, 14)).toBeUndefined();
    await host.drain();
    expect(text.textContent).toBe("hello");
    expect(text.hidden).toBe(true);
    env.set_visible(0, 1, 1);
    expect(text.textContent).toBe("hello");
    expect(text.hidden).toBe(false);
    expect(() => env.set_inner_text(-1, 2, 1, 5)).toThrow(/bounds/);
    expect(() => env.fetch(65530, 10)).toThrow(/bounds/);
    host.rollback();
    expect(text.textContent).toBe("original");
    expect(text.hidden).toBe(false);
    expect(logged).toEqual(["hello"]);
    text.setAttribute("data-preserve", "true");
    env.set_inner_text(0, 1, 1, 5);
    expect(text.textContent).toBe("original");
  });

  test("env.catch reports rejection without consuming it and throw handles negative slot", async () => {
    const text = new TestNode("x");
    text.textContent = "original";
    const host = createWasmHost(testDocument([text]), new Set(), async () => {});
    const memory = new WebAssembly.Memory({ initial: 1 });
    host.bind(memory);
    new Uint8Array(memory.buffer).set(new TextEncoder().encode("x"));
    const env = host.imports.env;
    expect(env.catch(0)).toBe(0);
    expect(env.catch(-1)).toBe(0);
    expect(env.catch(5)).toBe(0);
    const s0 = env.await();
    const s1 = env.await();
    expect(s0).toBe(0);
    expect(s1).toBe(1);
    expect(env.catch(0)).toBe(0);
    env.throw(-1); // reject newest pending (slot 1)
    expect(env.catch(1)).toBe(1);
    expect(env.catch(1)).toBe(1); // non-destructive query
    env.throw(0); // reject slot 0 as well
    expect(env.catch(0)).toBe(1);
    expect(env.catch(1)).toBe(1);
    // set_visible with catch result: 1 -> visible
    env.set_visible(0, 1, env.catch(0));
    expect(text.hidden).toBe(false);
    // A new await reuses slot 0 and resets its rejected state
    const s2 = env.await();
    expect(s2).toBe(0);
    expect(env.catch(0)).toBe(0);
    // Out-of-range and idle slots stay 0
    expect(env.catch(2)).toBe(0);
    expect(env.catch(3)).toBe(0);
    expect(env.catch(4)).toBe(0);
  });

  test("native menu navigation refreshes values and flags without mutation routes", async () => {
    const ui = new TestNode("bios-ui");
    const status = new TestNode("status");
    const main = new TestNode("menu-main", { "data-menu": "main", "data-fetch": "/bios/menu/main" });
    const cpu = new TestNode("menu-cpu", { "data-menu": "cpu", "data-fetch": "/bios/menu/cpu" });
    const link = new TestNode("cpu-link", { "data-menu-link": "cpu" });
    const value = new TestNode("row-cpu-xlen");
    const flag = new TestNode("access-cpu-xlen");
    const row = new TestNode("", { "data-item": "xlen" });
    cpu.children.push(row);
    const doc = testDocument([ui, status, main, cpu, link, value, flag]);
    const urls: string[] = [];
    const app = createBrowserApp(doc, async (url: string) => {
      urls.push(url);
      const id = url.split("/").at(-1);
      return { ok: true, json: async () => ({ id, title: id, items: id === "cpu" ? [{ id: "xlen", label: "XLEN", value: "64", writable: false }] : [] }) };
    });
    await app.start();
    await link.listeners.get("click")!({ preventDefault() {} });
    expect(main.hidden).toBe(true);
    expect(cpu.hidden).toBe(false);
    expect(value.textContent).toBe("64");
    expect(flag.textContent).toBe("Read-only");
    expect(urls.every((url) => url.startsWith("/bios/menu/"))).toBe(true);
  });

  test("WASM failures restore the static view and report errors", async () => {
    const ui = new TestNode("bios-ui", { "data-wasm-url": "/custom/ui.wasm" });
    const status = new TestNode("status");
    const main = new TestNode("menu-main", { "data-menu": "main" });
    const cpu = new TestNode("menu-cpu", { "data-menu": "cpu" });
    const doc = testDocument([ui, status, main, cpu]);
    const app = createBrowserApp(doc, async () => ({ ok: true, arrayBuffer: async () => new ArrayBuffer(0) }));
    await app.start();
    expect(status.textContent).toContain("Static view");
    expect(status.textContent).toContain("WASM");
    expect(cpu.hidden).toBe(false);
  });
});

describe("libwasm DOM kernel", () => {
  function fixture() {
    const mount = new TestNode("libwasm-root");
    const original = new TestNode("original");
    original.textContent = "static fallback";
    mount.appendChild(original);
    const doc = testDocument([mount]);
    const host = createLibwasmHost(doc, mount);
    const memory = new WebAssembly.Memory({ initial: 32, maximum: 256 });
    host.bind(memory);
    let offset = 0;
    const string = (value: string): [number, number] => {
      const bytes = new TextEncoder().encode(value);
      const ptr = offset;
      offset += bytes.length;
      new Uint8Array(memory.buffer).set(bytes, ptr);
      return [bytes.length, ptr];
    };
    return { host, memory, mount, original, doc, string, env: host.imports.env };
  }

  test("object handles are refcounted and released slots are reused", () => {
    const { env, string } = fixture();
    // JsHandle copy/destruct semantics: a copy is the same handle, and the
    // object survives until the matching number of releases.
    const h = env.libwasm_add__object();
    expect(h).toBeGreaterThanOrEqual(0x100000);
    expect(env.libwasm_copyObjectRef(h)).toBe(h);
    env.libwasm_removeObject(h);
    expect(env.libwasm_copyObjectRef(h)).toBe(h); // still live after one release
    env.libwasm_removeObject(h);
    env.libwasm_removeObject(h); // last reference releases
    expect(env.libwasm_add__object()).toBe(h); // slot reused, not leaked

    // Roots are identity under copy and are not stored in the table.
    for (const root of [1, 2]) expect(env.libwasm_copyObjectRef(root)).toBe(root);
    const s = env.libwasm_add__string(...string("menu"));
    expect(s).not.toBe(h);
    env.libwasm_get__string(64, s);
  });

  // Every lifetime violation is a trap, and a trap aborts the whole staged
  // transaction — so each case needs its own fixture.
  test.each([
    ["double free", (env: any, h: number) => { env.libwasm_removeObject(h); env.libwasm_removeObject(h); }, /freed handle/],
    ["copy after free", (env: any, h: number) => { env.libwasm_removeObject(h); env.libwasm_copyObjectRef(h); }, /freed handle/],
    ["read after free", (env: any, h: number) => { env.libwasm_removeObject(h); env.libwasm_get__string(64, h); }, /freed handle/],
    ["free the DOM root", (env: any) => env.libwasm_removeObject(1), /protected root/],
    ["free the scope root", (env: any) => env.libwasm_removeObject(2), /protected root/],
    ["free a never-allocated handle", (env: any) => env.libwasm_removeObject(0x100000 + 50), /freed handle/],
  ])("object lifetime violation fails closed: %s", (_name, act, message) => {
    const { host, env } = fixture();
    expect(() => act(env, env.libwasm_add__object())).toThrow(message);
    // The transaction is poisoned, so nothing can be committed afterwards.
    expect(() => host.commit()).toThrow(/transaction is failed/);
  });

  test("the object table is bounded and a release makes room", () => {
    const { env } = fixture();
    const live: number[] = [];
    for (let i = 0; i < 4096; i++) live.push(env.libwasm_add__object());
    expect(() => env.libwasm_add__object()).toThrow(/budget exceeded/);

    const fresh = fixture().env;
    const first = fresh.libwasm_add__object();
    for (let i = 1; i < 4096; i++) fresh.libwasm_add__object();
    fresh.libwasm_removeObject(first);
    expect(fresh.libwasm_add__object()).toBe(first);
  });

  test("scalar box/unbox round-trips preserve width and sign", () => {
    const { env, memory } = fixture();

    // i64: a value outside the i32 range must not truncate.
    const long = 8_589_934_592n;
    const hLong = env.libwasm_add__long(long);
    expect(env.libwasm_get__long(hLong)).toBe(long);

    // u64: 2^64 - 1 survives as an unsigned 64-bit value.
    const ulong = (1n << 64n) - 1n;
    const hUlong = env.libwasm_add__ulong(ulong);
    expect(env.libwasm_get__ulong(hUlong)).toBe(ulong);

    // f64: -0.5 must stay a distinct f64, not collapse to 0.
    const hDouble = env.libwasm_add__double(-0.5);
    expect(env.libwasm_get__double(hDouble)).toBe(-0.5);

    // f32: sign and exponent fit in 32 bits.
    const hFloat = env.libwasm_add__float(Math.fround(1.5));
    expect(env.libwasm_get__float(hFloat)).toBe(Math.fround(1.5));

    // i32 round-trip with sign extension (i32::MAX -> u32::MAX when read back
    // through get__uint is the same bit pattern, i.e. -1).
    const hInt = env.libwasm_add__int(-1);
    expect(env.libwasm_get__int(hInt)).toBe(-1);
    const hUint = env.libwasm_add__uint(0xffffffff);
    expect(env.libwasm_get__uint(hUint)).toBe(0xffffffff);

    // bool, byte, and the narrow signed/unsigned widths.
    const hBool = env.libwasm_add__bool(1);
    expect(env.libwasm_get__bool(hBool)).toBe(1);
    const hByte = env.libwasm_add__byte(-128);
    expect(env.libwasm_get__byte(hByte)).toBe(-128);
    const hUbyte = env.libwasm_add__ubyte(255);
    expect(env.libwasm_get__ubyte(hUbyte)).toBe(255);
    const hShort = env.libwasm_add__short(-32768);
    expect(env.libwasm_get__short(hShort)).toBe(-32768);
    const hUshort = env.libwasm_add__ushort(65535);
    expect(env.libwasm_get__ushort(hUshort)).toBe(65535);

    // int[] / uint[] arrays are stored as vectors and count as distinct objects.
    const i32s = new Int32Array(memory.buffer, 256, 3);
    i32s.set([1, 2, 3]);
    const hInts = env.libwasm_add__ints(3, 256);
    expect(typeof hInts).toBe("number");
    const u32s = new Uint32Array(memory.buffer, 256, 3);
    u32s.set([4, 5, 6]);
    const hUints = env.libwasm_add__uints(3, 256);
    expect(typeof hUints).toBe("number");
  });

  test("typed object getter/call dispatch fail-closed and box results", () => {
    const { env, string, memory } = fixture();

    // A boxed string is an object-like receiver for property/method access.
    const s = env.libwasm_add__string(...string("hello"));
    const [mLen, mPtr] = string("concat");
    const [argLen, argPtr] = string(" world");
    const h = env.Object_Call_string__Handle(s, mLen, mPtr, argLen, argPtr);

    // The result is a new boxed string.
    env.libwasm_get__string(512, h);
    const u32 = new Uint32Array(memory.buffer);
    const [len, ptr] = [u32[128], u32[129]];
    const result = new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len));
    expect(result).toBe("hello world");

    // Numeric and string getters work on the boxed result.
    const [lLen, lPtr] = string("length");
    expect(env.Object_Getter__uint(h, lLen, lPtr)).toBe(11);
    env.Object_Getter__string(512, h, lLen, lPtr);
    expect(new TextDecoder().decode(new Uint8Array(memory.buffer, u32[129], u32[128]))).toBe("11");

  });

  test("typed object getter/call fail-closed on unknown property, method and handle", () => {
    const { env, string } = fixture();
    const s = env.libwasm_add__string(...string("hello"));
    const [pLen, pPtr] = string("nope");
    expect(() => env.Object_Getter__uint(s, pLen, pPtr)).toThrow(/no property/);

    const f2 = fixture();
    const s2 = f2.env.libwasm_add__string(...f2.string("hello"));
    expect(() => f2.env.Object_Call_string__Handle(s2, ...f2.string("nope"), ...f2.string("x"))).toThrow(/no method/);

    const f3 = fixture();
    const [lLen, lPtr] = f3.string("length");
    expect(() => f3.env.Object_Getter__uint(0, lLen, lPtr)).toThrow(/unknown/);
  });

  test("Optional!T getters and calls write sret and treat null/missing as None", () => {
    const { env, string, memory } = fixture();
    const s = env.libwasm_add__string(...string("hello"));
    let u8 = new Uint8Array(memory.buffer);
    let u32 = new Uint32Array(memory.buffer);

    // OptionalUint present property: value 5, defined 1.
    const [pLen, pPtr] = string("length");
    env.Object_Getter__OptionalUint(256, s, pLen, pPtr);
    u32 = new Uint32Array(memory.buffer);
    u8 = new Uint8Array(memory.buffer);
    expect(u32[64]).toBe(5);
    expect(u8[260]).toBe(1);

    // OptionalUint missing property: value 0, defined 0.
    const [nLen, nPtr] = string("nope");
    env.Object_Getter__OptionalUint(264, s, nLen, nPtr);
    u32 = new Uint32Array(memory.buffer);
    u8 = new Uint8Array(memory.buffer);
    expect(u32[66]).toBe(0);
    expect(u8[268]).toBe(0);

    // OptionalString present property: "5", defined 1.
    env.Object_Getter__OptionalString(272, s, pLen, pPtr);
    u32 = new Uint32Array(memory.buffer);
    u8 = new Uint8Array(memory.buffer);
    const [len, ptr] = [u32[68], u32[69]];
    expect(len).toBe(1);
    expect(u8[280]).toBe(1);
    expect(new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len))).toBe("5");

    // OptionalHandle call: s.toString() -> boxed "hello".
    const [mLen, mPtr] = string("toString");
    env.Object_Call_string__OptionalHandle(288, s, mLen, mPtr, ...string(""));
    u32 = new Uint32Array(memory.buffer);
    u8 = new Uint8Array(memory.buffer);
    const handle = u32[72];
    expect(handle).toBeGreaterThanOrEqual(0x100000);
    expect(u8[292]).toBe(1);
    env.libwasm_get__string(512, handle);
    const out = new Uint32Array(memory.buffer);
    expect(new TextDecoder().decode(new Uint8Array(memory.buffer, out[129], out[128]))).toBe("hello");

    // OptionalString call: s.toString() -> "hello".
    env.Object_Call_string__OptionalString(296, s, mLen, mPtr, ...string(""));
    u32 = new Uint32Array(memory.buffer);
    u8 = new Uint8Array(memory.buffer);
    const [sLen, sPtr] = [u32[74], u32[75]];
    expect(u8[304]).toBe(1);
    expect(new TextDecoder().decode(new Uint8Array(memory.buffer, sPtr, sLen))).toBe("hello");
  });

  test("JSON and vararg calls parse, stringify and dispatch Optional!T / SumType", () => {
    const { env, memory, string } = fixture();

    // JSON_parse_string + JSON_stringify round-trip.
    const [jLen, jPtr] = string(`{"items":[1,2]}`);
    const h = env.JSON_parse_string(jLen, jPtr);
    const raw = 1024;
    env.JSON_stringify(raw, h);
    const u32 = new Uint32Array(memory.buffer);
    const jsonOut = new TextDecoder().decode(new Uint8Array(memory.buffer, u32[raw / 4 + 1], u32[raw / 4]));
    expect(jsonOut).toBe(`{"items":[1,2]}`);

    // Object_VarArgCall__int: "hello".indexOf("lo") -> 3.
    const s = env.libwasm_add__string(...string("hello"));
    const [m1, p1] = string("indexOf");
    const [d1, dp1] = string("string");
    const [a1, ap1] = string(`["lo"]`);
    expect(env.Object_VarArgCall__int(s, m1, p1, d1, dp1, a1, ap1)).toBe(3);

    // Object_VarArgCall__string: "hello".concat(" world") -> "hello world".
    const [m2, p2] = string("concat");
    const [d2, dp2] = string("string");
    const [a2, ap2] = string(`[" world"]`);
    const out = 1024;
    env.Object_VarArgCall__string(out, s, m2, p2, d2, dp2, a2, ap2);
    const u2 = new Uint32Array(memory.buffer);
    const str = new TextDecoder().decode(new Uint8Array(memory.buffer, u2[out / 4 + 1], u2[out / 4]));
    expect(str).toBe("hello world");

    // Optional!string: "hello".concat(" BIOS") with defined=true.
    const [m3, p3] = string("concat");
    const [d3, dp3] = string("Optional!string");
    const [a3, ap3] = string(`[true," BIOS"]`);
    const out2 = 1040;
    env.Object_VarArgCall__string(out2, s, m3, p3, d3, dp3, a3, ap3);
    const u3 = new Uint32Array(memory.buffer);
    const str2 = new TextDecoder().decode(new Uint8Array(memory.buffer, u3[out2 / 4 + 1], u3[out2 / 4]));
    expect(str2).toBe("hello BIOS");

    // SumType!(string,Handle): string wins.
    const [m4, p4] = string("concat");
    const [d4, dp4] = string("SumType!(string,Handle)");
    const [a4, ap4] = string(`[0,"-",0]`);
    const out3 = 1056;
    env.Object_VarArgCall__string(out3, s, m4, p4, d4, dp4, a4, ap4);
    const u4 = new Uint32Array(memory.buffer);
    const str3 = new TextDecoder().decode(new Uint8Array(memory.buffer, u4[out3 / 4 + 1], u4[out3 / 4]));
    expect(str3).toBe("hello-");

    // Fail-closed on unknown descriptor.
    const [d5, dp5] = string("unknown");
    const [a5, ap5] = string(`[1]`);
    expect(() => env.Object_VarArgCall__int(s, m1, p1, d5, dp5, a5, ap5)).toThrow(/unsupported/);
  });

  test("lodash chains execute over the command buffer without host eval", () => {
    const { env, string, memory } = fixture();
    const chain = (init: number, src: string) => {
      const [cLen, cOff] = string(src);
      env.ldexec_Handle__string(4096, init, cLen, cOff, 0, 0, 0, 0);
      // Re-take the view: writeString may grow memory, detaching the old buffer.
      const out = new Uint32Array(memory.buffer);
      const [len, ptr] = [out[1024], out[1025]];
      return new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len));
    };
    // `libwasm_add__object` is an identity with no properties until B63, and
    // both backends must agree it stringifies as "[object Object]".
    const obj = env.libwasm_add__object();
    expect(chain(obj, '[{"func":"toString","params":[]}]')).toBe("[object Object]");

    const [sLen, sOff] = string("  BIOS  ");
    const s = env.libwasm_add__string(sLen, sOff);
    expect(chain(s, '[{"func":"trim","params":[]},{"func":"toLower","params":[]},{"func":"capitalize","params":[]}]')).toBe("Bios");
    expect(chain(s, '[{"func":"trim","params":[]},{"func":"size","params":[]}]')).toBe("4");

    // A numeric seed goes through the i64 init operand and the i64 result.
    const [nLen, nOff] = string('[{"func":"toNumber","params":[]}]');
    expect(env.ldexec_long__long(7n, nLen, nOff, 0, 0, 0, 0)).toBe(7n);
    expect(env.ldexec_long__double(7n, nLen, nOff, 0, 0, 0, 0)).toBe(7);
  });

  test("lodash refuses host eval but dispatches the generated iteratee into the guest", () => {
    const boilerplate = "(o,i)=>{let hndl=ao(o);return !!sifg(cbPtr)(cbCtx,BigInt(i),hndl);}";

    // Arbitrary JS in an `=(...)` parameter is refused by name.
    for (const hostile of ["=(()=>fetch('http://evil/'))()", "=window.location", "=alert(1);"]) {
      const { env, string } = fixture();
      const [cLen, cOff] = string(JSON.stringify([{ func: "filter", params: [hostile] }]));
      expect(() => env.ldexec_Handle__Handle(0, cLen, cOff, 0, 0, 0, 0)).toThrow(/refuses host eval/);
    }

    // The generated boilerplate is recognised, and with no instance bound
    // there is no table to call, so the chain fails closed rather than
    // silently dropping the predicate.
    const { env, string } = fixture();
    const [cLen, cOff] = string(JSON.stringify([
      { local: "cb", value: "=" + boilerplate },
      { func: "filter", params: ["=cb"] },
    ]));
    expect(() => env.ldexec_Handle__Handle(0, cLen, cOff, 7, 9, 0, 0)).toThrow(/needs a guest iteratee/);
  });

  test("stages D length-pointer strings and restores original node identity on rollback", () => {
    const { host, env, mount, original, string } = fixture();
    const section = env.createElement(82);
    const text = env.createElement(69);
    env.setProperty(text, ...string("innerText"), ...string("BIOS α"));
    env.appendChild(section, text);
    env.appendChild(1, section);
    expect(mount.childNodes).toEqual([original]);
    host.commit();
    expect(mount.textContent).toBe("BIOS α");
    expect(mount.children[0].tagName).toBe("SECTION");
    expect(host.nodeCount()).toBe(2);
    host.rollback();
    expect(mount.childNodes).toEqual([original]);
    expect(mount.textContent).toBe("static fallback");
  });

  test("reparent, insertBefore and unmount preserve handle identity", () => {
    const { host, env, mount, string } = fixture();
    const a = env.createElement(26);
    const b = env.createElement(26);
    const c = env.createElement(69);
    env.setProperty(c, ...string("textContent"), ...string("moved"));
    env.appendChild(1, a);
    env.appendChild(1, b);
    env.appendChild(a, c);
    env.insertBefore(1, c, b);
    env.unmount(c);
    env.appendChild(b, c);
    host.commit();
    expect(mount.children[0].children.length).toBe(0);
    expect(mount.children[1].textContent).toBe("moved");
  });

  test("rejects active elements, unknown handles, root moves, cycles and dangerous properties", () => {
    for (const tag of [81, 88, 47, 30, 64, 56, 60, -1, 108, NaN, 1.5]) {
      const { env } = fixture();
      expect(() => env.createElement(tag)).toThrow();
    }
    for (const property of ["innerHTML", "outerHTML", "src", "onclick", "__proto__", "constructor", "style"]) {
      const { env, string, host, mount, original } = fixture();
      const h = env.createElement(26);
      expect(() => env.setProperty(h, ...string(property), ...string("bad"))).toThrow();
      expect(() => host.commit()).toThrow();
      host.rollback();
      expect(mount.childNodes).toEqual([original]);
    }
    for (const operation of [
      (env: any, a: number, b: number) => env.appendChild(a, 1),
      (env: any, a: number, b: number) => env.appendChild(b, a),
      (env: any, a: number, b: number) => env.appendChild(a, 4000),
      (env: any, a: number, b: number) => env.insertBefore(a, b, 1),
    ]) {
      const { env } = fixture();
      const a = env.createElement(26), b = env.createElement(26);
      env.appendChild(a, b);
      expect(() => operation(env, a, b)).toThrow();
    }
  });

  test("WebIDL fetch TypeError and DOM throws are JS-catchable as WebAssembly.Exception", () => {
    // libwasm/webidl/definitions/{DOMException,Node,Document,Request,Fetch}.webidl
    // + bindings. JS TypeError/DOMException at the import boundary become
    // WebAssembly.Exception on env.__cpp_exception so wasm try can catch them.
    const { env, string } = fixture();
    const a = env.createElement(26);
    const b = env.createElement(26);
    env.appendChild(a, b);
    try {
      env.appendChild(b, a);
      throw new Error("expected HierarchyRequestError");
    } catch (e) {
      expect(e).toBeInstanceOf(WebAssembly.Exception);
      expect((e as WebAssembly.Exception).getArg(env.__cpp_exception, 0)).toBe(3);
    }
    try {
      env.createCustomElement(...string("<>"));
      throw new Error("expected InvalidCharacterError");
    } catch (e) {
      expect(e).toBeInstanceOf(WebAssembly.Exception);
      expect((e as WebAssembly.Exception).getArg(env.__cpp_exception, 0)).toBe(5);
    }
    try {
      const [len, ptr] = string(":");
      env.fetch(ptr, len);
      throw new Error("expected Request TypeError");
    } catch (e) {
      expect(e).toBeInstanceOf(WebAssembly.Exception);
      expect((e as WebAssembly.Exception).getArg(env.__cpp_exception, 0)).toBe(0);
    }
  });

  test("validates UTF-8, finite integer pointers, call budgets, and grown memory views", () => {
    for (const pair of [[1, -1], [-1, 0], [1, NaN], [NaN, 0], [1, 0.5], [2, 2097151]]) {
      const { env, string } = fixture();
      const h = env.createElement(26);
      expect(() => env.setProperty(h, ...string("innerText"), pair[0], pair[1])).toThrow();
    }
    const bad = fixture();
    new Uint8Array(bad.memory.buffer)[1000] = 255;
    expect(() => bad.env.setProperty(bad.env.createElement(26), ...bad.string("innerText"), 1, 1000)).toThrow();
    const f = fixture();
    f.memory.grow(1);
    const h = f.env.createElement(26);
    f.env.setProperty(h, ...f.string("innerText"), ...f.string("after grow"));
    f.env.appendChild(1, h);
    f.host.commit();
    expect(f.mount.textContent).toBe("after grow");
    const budget = fixture();
    const child = budget.env.createElement(26);
    expect(() => { for (let i = 0; i < 20000; i++) budget.env.appendChild(1, child); }).toThrow(/budget/);
    expect(() => budget.host.commit()).toThrow();
  });

  test("executes the shipped LDC cell through the actual host when available", async () => {
    const bytes = readFileSync(join(root, "out/bios-ui-libwasm.wasm"));
    if (!bytes.length) {
      expect(process.env.G6B_DUB_WASM).not.toBe("1");
      return;
    }
    // Scope check: the shipped cell is the static App.svelte chrome rendered
    // through the LDC/libwasm lane plus the kernel boundary. It mounts one
    // <main> and drives the BIOS endpoint / HolyC imports, and it now builds
    // the static setup tree (banner, tabs, section/table shells) below it.
    const imported = WebAssembly.Module.imports(new WebAssembly.Module(bytes)).map((i) => i.name).sort();
    expect(imported).toContain("createElement");
    for (const name of ["fetch", "holyc", "register_endpoint"]) expect(imported).toContain(name);
    const { host, mount, original } = fixture();
    const { instance } = await WebAssembly.instantiate(bytes, host.imports);
    host.bind(instance.exports.memory);
    // Reaching the end of _start means every /bios/ URL and HTTP method the
    // cell passed survived the host's fail-closed validation.
    (instance.exports._start as Function)((instance.exports.__heap_base as WebAssembly.Global).value);
    // nodeCount() excludes the staging root; the static tree now contains the
    // full App.svelte chrome (banner, nav, sections, tables) not just a shell.
    expect(host.nodeCount()).toBeGreaterThanOrEqual(80);
    host.commit();
    expect(mount.children.map((c: any) => c.tagName)).toEqual(["MAIN"]);
    // The static fallback is replaced only on a successful commit.
    expect(mount.childNodes).not.toContain(original);
    host.rollback();
    expect(mount.childNodes).toEqual([original]);
    expect(mount.textContent).toBe("static fallback");
  });

  test("asyncified LDC cell fetches BoardSpec rows and populates table bodies", async () => {
    const bytes = readFileSync(join(root, "out/bios-ui-libwasm.wasm"));
    if (!bytes.length) {
      expect(process.env.G6B_DUB_WASM).not.toBe("1");
      return;
    }
    const mount = new TestNode("libwasm-root");
    const doc = testDocument([mount]);
    const rows = [{ id: "x", label: "TestLabel", value: "TestValue", writable: true }];
    const fetchFn = async (url: string) => {
      if (!/^\/bios\//.test(url)) throw new Error("unexpected fetch: " + url);
      return { ok: true, text: async () => JSON.stringify(rows) };
    };
    const host = createLibwasmHost(doc, mount, WebAssembly, { asyncify: true, fetchFn });
    const { instance } = await WebAssembly.instantiate(bytes, host.imports);
    host.bind(instance.exports.memory);
    const heap = (instance.exports.__heap_base as WebAssembly.Global).value;
    await host.start(instance, heap);
    host.commit();
    // The static tree plus at least one menu row should contain the mock values.
    expect(host.nodeCount()).toBeGreaterThan(82);
    expect(mount.textContent).toContain("TestLabel");
    expect(mount.textContent).toContain("TestValue");
    expect(mount.textContent).toContain("RW");
  });

  test("optional LDC startup proceeds while an MVP kernel read is pending", async () => {
    const ui = new TestNode("bios-ui", { "data-wasm-url": "/ui/ui.wasm", "data-libwasm-url": "/ui/ui-libwasm.wasm" });
    const mount = new TestNode("libwasm-root"), note = new TestNode("libwasm-status"), status = new TestNode("status");
    const target = new TestNode("menu-title", { "data-fetch": "/bios/menu" });
    const file = parseSvelte("src/Wait.svelte", '<script>fetchBios("/bios/menu");</script><p id="status">boot</p>');
    let finishRead: Function = () => {};
    const response = new Promise((resolve) => { finishRead = resolve; });
    let mounted: Function = () => {};
    const ready = new Promise((resolve) => { mounted = resolve; });
    const api = {
      Tag: WebAssembly.Tag,
      instantiate: async (bytes: ArrayBuffer, imports: any) => bytes.byteLength === 8 ? { instance: { exports: {
        memory: new WebAssembly.Memory({ initial: 1 }), __heap_base: { value: 1024 },
        _start: () => { imports.env.appendChild(1, imports.env.createElement(26)); mounted(); },
      } } } : WebAssembly.instantiate(bytes, imports),
    };
    const app = createBrowserApp(testDocument([ui, mount, note, status, target]), async (url: string) => {
      if (url === "/bios/menu") return response;
      return { ok: true, arrayBuffer: async () => url.endsWith("ui-libwasm.wasm") ? new ArrayBuffer(8) : emitWasm([file]) };
    }, api);
    const started = app.start();
    await ready;
    expect(note.textContent).toContain("1 allocated nodes");
    expect(mount.children.length).toBe(1);
    finishRead({ ok: true, json: async () => ({}) });
    await started;
  });

  test("a trapping optional cell leaves fallback and BoardSpec navigation intact", async () => {
    const mount = new TestNode("libwasm-root"), original = new TestNode("original");
    original.textContent = "fallback";
    mount.appendChild(original);
    const ui = new TestNode("bios-ui", { "data-libwasm-url": "/ui/ui-libwasm.wasm", "data-start-menu": "cpu" });
    const note = new TestNode("libwasm-status"), status = new TestNode("status");
    const main = new TestNode("menu-main", { "data-menu": "main" }), cpu = new TestNode("menu-cpu", { "data-menu": "cpu" });
    const memory = new WebAssembly.Memory({ initial: 1 });
    const api = {
      Tag: WebAssembly.Tag,
      instantiate: async (_: unknown, imports: any) => ({ instance: { exports: {
        memory, __heap_base: { value: 1024 },
        _start: () => { imports.env.appendChild(1, imports.env.createElement(26)); throw new Error("start trap"); },
      } } }),
    };
    const app = createBrowserApp(testDocument([ui, mount, note, status, main, cpu]), async () => ({ ok: true, arrayBuffer: async () => new ArrayBuffer(8) }), api);
    await app.start();
    expect(mount.childNodes).toEqual([original]);
    expect(note.textContent).toContain("start trap");
    expect(main.hidden).toBe(true);
    expect(cpu.hidden).toBe(false);
  });

  test.each([
    "libasync_promise_all__promise",
    "libasync_promise_any__promise",
    "libasync_promise_allsettled__promise",
  ])("B68: %s rejects a non-promise handle array", (fn) => {
    const { env, memory } = fixture();
    const u32 = new Uint32Array(memory.buffer);
    u32[0] = env.libwasm_add__int(1);
    u32[1] = env.libwasm_add__int(2);
    const arr = env.libwasm_add__uints(2, 0);
    expect(() => env[fn](arr)).toThrow(/not a promise/);
  });

  test("B68: typed array and DataView Create read from guest memory", () => {
    const { env, memory, string } = fixture();
    const u8 = new Uint8Array(memory.buffer);
    const i32 = new Int32Array(memory.buffer, 16, 4);
    const f32 = new Float32Array(memory.buffer, 32, 4);
    for (let i = 0; i < 4; i++) {
      u8[i] = i;
      i32[i] = 100 + i;
      f32[i] = i + 0.5;
    }
    const i8h = env.Int8Array_Create(4, 0);
    const u8h = env.Uint8Array_Create(4, 0);
    const i32h = env.Int32Array_Create(4, 16);
    const f32h = env.Float32Array_Create(4, 32);
    const dvh = env.DataView_Create(4, 0);

    expect(env.libwasm_get__int(env.libwasm_get_idx__field(i8h, 1))).toBe(1);
    expect(env.libwasm_get__int(env.libwasm_get_idx__field(u8h, 2))).toBe(2);
    expect(env.libwasm_get__int(env.libwasm_get_idx__field(i32h, 2))).toBe(102);
    expect(env.libwasm_get__float(env.libwasm_get_idx__field(f32h, 3))).toBe(3.5);
    expect(env.libwasm_get__int(env.libwasm_get_idx__field(dvh, 3))).toBe(3);
    expect(env.libwasm_get__int(env.libwasm_get__field(u8h, ...string("length")))).toBe(4);
    expect(env.libwasm_get__int(env.libwasm_get__field(dvh, ...string("length")))).toBe(4);
  });

  test("B67: first-party Moment creates Date handles and reads scalar methods", () => {
    const { env, memory, string } = fixture();
    const t = 1_700_000_000_000n;
    const now = env.libwasm_moment_now();
    const fixed = env.libwasm_moment_from_millis(t);
    expect(now).toBeGreaterThanOrEqual(0x100000);
    expect(fixed).toBeGreaterThanOrEqual(0x100000);

    const v = env.Object_Call_string__double(fixed, ...string("getTime"), ...string(""));
    expect(v).toBe(1_700_000_000_000);
    expect(env.Object_Call_string__uint(fixed, ...string("getFullYear"), ...string(""))).toBe(2023);
    expect(env.Object_Call_string__uint(fixed, ...string("getMonth"), ...string(""))).toBe(10);
    expect(env.Object_Call_string__uint(fixed, ...string("getDate"), ...string(""))).toBe(14);
    env.Object_Call_string__string(64, fixed, ...string("toISOString"), ...string(""));
    const u32 = new Uint32Array(memory.buffer, 64, 2);
    const u8 = new Uint8Array(memory.buffer);
    const s = new TextDecoder().decode(u8.subarray(u32[1], u32[1] + u32[0]));
    expect(s).toMatch(/^2023-11-14T/);
  });

  test("B69: generic DOM method calls handle setAttribute, getAttribute, removeAttribute and classList", () => {
    const { env, memory, string } = fixture();
    const node = env.createElement(26); // div

    env.Object_Call_string_string__void(node, ...string("setAttribute"), ...string("data-x"), ...string("hello"));
    env.Object_Call_string_string__void(node, ...string("setAttribute"), ...string("data-y"), ...string("world"));

    const raw = 256;
    env.Object_Call_string__OptionalString(raw, node, ...string("getAttribute"), ...string("data-x"));
    const u8 = new Uint8Array(memory.buffer);
    const u32 = new Uint32Array(memory.buffer, raw, 2);
    const len = u32[0];
    const ptr = u32[1];
    expect(u8[raw + 8]).toBe(1);
    expect(new TextDecoder().decode(u8.subarray(ptr, ptr + len))).toBe("hello");

    const missing = 320;
    env.Object_Call_string__OptionalString(missing, node, ...string("getAttribute"), ...string("absent"));
    expect(u8[missing + 8]).toBe(0);

    env.Object_Call_string__void(node, ...string("removeAttribute"), ...string("data-y"));
    env.Object_Call_string__OptionalString(raw, node, ...string("getAttribute"), ...string("data-y"));
    expect(u8[raw + 8]).toBe(0);

    const cl = env.Object_Getter__Handle(node, ...string("classList"));
    expect(cl).toBeGreaterThanOrEqual(0x100000);
    env.Object_Call_string__void(cl, ...string("add"), ...string("bios"));
    env.Object_Call_string__void(cl, ...string("add"), ...string("g6lc"));
    expect(env.Object_Call_string__bool(cl, ...string("contains"), ...string("bios"))).toBe(1);
    expect(env.Object_Call_string__bool(cl, ...string("contains"), ...string("missing"))).toBe(0);
    env.Object_Call_string__void(cl, ...string("remove"), ...string("bios"));
    expect(env.Object_Call_string__bool(cl, ...string("contains"), ...string("bios"))).toBe(0);
    expect(env.Object_Call_string__bool(cl, ...string("toggle"), ...string("flash"))).toBe(1);
    expect(env.Object_Call_string__bool(cl, ...string("toggle"), ...string("flash"))).toBe(0);
  });

  test("B69: bounded ES6 Map surface round-trips string keys and values", () => {
    const { env, memory, string } = fixture();
    const m = env.libwasm_map_create();
    expect(m).toBeGreaterThanOrEqual(0x100000);

    env.libwasm_map_set(m, ...string("k1"), ...string("v1"));
    env.libwasm_map_set(m, ...string("k2"), ...string("v2"));
    expect(env.libwasm_map_has(m, ...string("k1"))).toBe(1);
    expect(env.libwasm_map_has(m, ...string("missing"))).toBe(0);

    const raw = 256;
    env.libwasm_map_get__OptionalString(raw, m, ...string("k1"));
    const u8 = new Uint8Array(memory.buffer);
    const u32 = new Uint32Array(memory.buffer, raw, 2);
    expect(u8[raw + 8]).toBe(1);
    const len = u32[0], ptr = u32[1];
    expect(new TextDecoder().decode(u8.subarray(ptr, ptr + len))).toBe("v1");

    const missing = 320;
    env.libwasm_map_get__OptionalString(missing, m, ...string("missing"));
    expect(u8[missing + 8]).toBe(0);

    env.libwasm_map_delete(m, ...string("k1"));
    expect(env.libwasm_map_has(m, ...string("k1"))).toBe(0);
    env.libwasm_map_clear(m);
    expect(env.libwasm_map_has(m, ...string("k2"))).toBe(0);
  });

  test("B67: getTimeStamp returns current epoch milliseconds as i64", () => {
    const { env } = fixture();
    const before = BigInt(Date.now());
    const ts = env.getTimeStamp();
    const after = BigInt(Date.now());
    expect(typeof ts).toBe("bigint");
    expect(ts >= before && ts <= after).toBe(true);
  });

  test("B66: named delegates, timers and event handlers can be set and read back", () => {
    const { env, memory, string } = fixture();

    // Named delegate registry round-trips.
    const [n1, p1] = string("navigate_to");
    env.libwasm_set__function(n1, p1, 42, 7);
    env.libwasm_unset__function(n1, p1);

    // Timer ids are positive and clearable even without an asyncify host.
    const id1 = env.setTimeout(1, 2, 10);
    expect(id1).toBeGreaterThan(0);
    const id2 = env.setInterval(3, 4, 20);
    expect(id2).toBeGreaterThan(id1);
    const id3 = env.requestAnimationFrame(1, 2);
    expect(id3).toBeGreaterThan(id2);
    env.clearTimeout(id1);
    env.clearInterval(id2);
    env.cancelAnimationFrame(id3);

    // Event handler set/get round-trip on a DOM node.
    const node = env.createElement(26);
    const [m1, mp1] = string("onclick");
    env.Object_Call_EventHandler__void(node, m1, mp1, 1, 5, 6);
    const raw = 1024;
    env.Object_Getter__EventHandler(raw, node, m1, mp1);
    const u32 = new Uint32Array(memory.buffer);
    expect(u32[raw / 4]).toBe(5);
    expect(u32[raw / 4 + 1]).toBe(6);
    expect(new Uint8Array(memory.buffer)[raw + 8]).toBe(1);

    // Clearing the handler zeroes the optional.
    env.Object_Call_EventHandler__void(node, m1, mp1, 0, 0, 0);
    env.Object_Getter__EventHandler(raw, node, m1, mp1);
    expect(u32[raw / 4]).toBe(0);
    expect(u32[raw / 4 + 1]).toBe(0);
    expect(new Uint8Array(memory.buffer)[raw + 8]).toBe(0);
  });

  test("Object_VarArgCall__void drives DOM with binding tuple JSON; set__function names a D delegate", () => {
    // libwasm/source/libwasm/bindings/Node.d insertBefore / textContent
    // Serialize_Object_VarArgCall tuples; types.d exportDelegate.
    const { env, host, string, mount } = fixture();
    const parent = env.createElement(26);
    const child = env.createElement(69);
    env.appendChild(1, parent);

    const [tm, tp] = string("setAttribute");
    const [td, tdp] = string("string;string");
    const [ta, tap] = string(`["data-menu","cpu"]`);
    env.Object_VarArgCall__void(child, tm, tp, td, tdp, ta, tap);

    const [im, ip] = string("insertBefore");
    const [id, idp] = string("Handle;Optional!Handle");
    const [ia, iap] = string(`[${child},0,0]`);
    env.Object_VarArgCall__void(parent, im, ip, id, idp, ia, iap);

    const [n, np] = string("onReady");
    env.libwasm_set__function(n, np, 11, 1);

    host.commit();
    expect(mount.children[0].children.length).toBe(1);
    expect(mount.children[0].children[0].getAttribute("data-menu")).toBe("cpu");
    expect(mount.children[0].children[0].tagName).toBe("P");
  });

  test("jsCallback re-enters a D delegate from a DOM click after _start", async () => {
    // types.d jsCallback(ctx, fun, handle); EventHandler onclick; virtio/UI
    // click is the same host path as GuestCellLive BTN_LEFT.
    const { host, mount, env } = fixture();
    function u32(n: number) {
      const out: number[] = [];
      n >>>= 0;
      while (n > 0x7f) { out.push((n & 0x7f) | 0x80); n >>>= 7; }
      out.push(n);
      return out;
    }
    function section(id: number, body: number[]) {
      return [id, ...u32(body.length), ...body];
    }
    function name(s: string) {
      const b = [...new TextEncoder().encode(s)];
      return [...u32(b.length), ...b];
    }
    const bytes = new Uint8Array([
      0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
      ...section(1, [
        3,
        0x60, 2, 0x7f, 0x7f, 0,
        0x60, 0, 0,
        0x60, 3, 0x7f, 0x7f, 0x7f, 0,
      ]),
      ...section(3, [3, 0, 1, 2]),
      ...section(4, [1, 0x70, 0x00, 2]),
      ...section(5, [1, 0x00, 1]),
      ...section(7, [
        4,
        ...name("memory"), 2, 0,
        ...name("_start"), 0, 1,
        ...name("jsCallback"), 0, 2,
        ...name("__indirect_function_table"), 1, 0,
      ]),
      ...section(9, [1, 0, 0x41, 1, 0x0b, 1, 0]),
      ...section(10, [
        3,
        ...u32(10), 0, 0x41, 0x80, 0x08, 0x41, 1, 0x36, 2, 0, 0x0b,
        ...u32(2), 0, 0x0b,
        ...u32(11), 0, 0x20, 0, 0x20, 2, 0x20, 1, 0x11, 0, 0, 0x0b,
      ]),
    ]);
    expect(WebAssembly.validate(bytes)).toBe(true);
    const { instance } = await WebAssembly.instantiate(bytes, host.imports);
    const memory = instance.exports.memory as WebAssembly.Memory;
    host.bind(memory);
    host.attach(instance);
    (instance.exports._start as Function)();
    const u8 = new Uint8Array(memory.buffer);
    const put = (s: string, ptr: number): [number, number] => {
      const b = new TextEncoder().encode(s);
      u8.set(b, ptr);
      return [b.length, ptr];
    };
    const node = env.createElement(26);
    env.appendChild(1, node);
    env.libwasm_set__function(...put("click", 0), 99, 1);
    env.Object_Call_EventHandler__void(node, ...put("onclick", 16), 1, 99, 1);
    host.commit();
    const clicked = mount.children[0];
    expect(typeof clicked.listeners.get("click")).toBe("function");
    clicked.listeners.get("click")!({ type: "click" });
    const flag = new DataView(memory.buffer).getInt32(1024, true);
    expect(flag).toBe(1);
  });
});

describe("browser context", () => {
  function ctxFixture(opts: any = {}) {
    const panel = new TestNode("devtools-console");
    const target = new TestNode("status");
    const doc = testDocument([panel, target]);
    let t = 1000;
    const ctx = createBrowserContext(doc as any, { now: () => t++, ...opts });
    return { ctx, panel, target, doc };
  }

  test("is engine-agnostic: no WebAssembly or libwasm needed to construct or use", () => {
    // The whole point of the decoupling — a context is usable from plain JS.
    const { ctx } = ctxFixture();
    ctx.console.log("hello");
    expect(ctx.consolePage().entries[0].data).toBe("hello");
    expect(ctx.globalNames().sort()).toEqual(["console", "document", "pglite", "window"]);
  });

  test("exposes console, window and document singletons that are stable", () => {
    const { ctx } = ctxFixture();
    expect(ctx.global("console")).toBe(ctx.console);
    expect(ctx.global("window")).toBe(ctx.window);
    expect(ctx.global("document")).toBe(ctx.document);
    // window reaches the same singleton objects, not copies.
    expect(ctx.window.console).toBe(ctx.console);
    expect(ctx.window.document).toBe(ctx.document);
    // bindings() is a fresh map but the same objects.
    const b = ctx.bindings();
    expect(b.console).toBe(ctx.console);
    expect(ctx.bindings()).not.toBe(b);
  });

  test("unknown globals are absent rather than fabricated", () => {
    const { ctx } = ctxFixture();
    expect(ctx.global("eval")).toBeUndefined();
    expect(ctx.global("fetch")).toBeUndefined();
    expect(ctx.global("localStorage")).toBeUndefined();
  });

  test("shell BINDINGS intern pglite; nested context and the real DOM do not", () => {
    const { ctx: parent, doc } = ctxFixture({ contextId: "main" });
    const frame = createBrowserContext(doc as any, { contextId: "frame-1" });
    const off = createBrowserContext(doc as any, { contextId: "main", store: false });
    expect(parent.global("pglite")).toBeDefined();
    expect(parent.global("pglite").__g6bStore).toBe("factory");
    expect(frame.global("pglite")).toBeUndefined();
    expect(off.global("pglite")).toBeUndefined();
    expect((globalThis as any).pglite).toBeUndefined();
    if (typeof window !== "undefined") {
      expect((window as any).pglite).toBeUndefined();
      expect((window as any).pgliteWasm).toBeUndefined();
    }
  });

  function jsonResp(status: number, obj: unknown) {
    const text = JSON.stringify(obj);
    return {
      ok: status >= 200 && status < 300,
      status,
      text: async () => text,
      json: async () => obj,
    };
  }

  test("pglite facade opens registry and queries /bios/store", async () => {
    const calls: { url: string; method: string; body?: string }[] = [];
    const fetchFn = async (url: string, init: any = {}) => {
      const method = String(init.method || "GET").toUpperCase();
      calls.push({ url, method, body: init.body });
      if (url === "/bios/store/purpose/registry" && method === "GET") {
        return jsonResp(404, { error: "not found" });
      }
      if (url === "/bios/store" && method === "POST") {
        return jsonResp(200, { ok: true, uuid: "00000000-0000-4000-8000-000000000001", purpose: "registry" });
      }
      if (url === "/bios/store/00000000-0000-4000-8000-000000000001/query" && method === "POST") {
        const body = JSON.parse(String(init.body || "{}"));
        expect(body.sql).toBe("SELECT 1 AS n");
        expect(body.params).toEqual([]);
        return jsonResp(200, { ok: true, rows: [{ n: 1 }], fields: [], affectedRows: 0, ready: true });
      }
      return jsonResp(404, { error: "not found" });
    };
    const { ctx } = ctxFixture({ fetchFn });
    const db = ctx.global("pglite")();
    expect(db.__g6bStore).toBe("instance");
    expect(db.waitReady()).toEqual({ ok: true, ready: true });
    const out = await db.query("SELECT 1 AS n", "[]");
    expect(out.ok).toBe(true);
    expect(out.rows[0].n).toBe(1);
    expect(calls.some((c) => c.url === "/bios/store" && c.method === "POST")).toBe(true);
  });

  test("pglite stat is awaitable for a USB dialog", async () => {
    const calls: { url: string; method: string; body?: string }[] = [];
    let live = false;
    const fetchFn = async (url: string, init: any = {}) => {
      const method = String(init.method || "GET").toUpperCase();
      calls.push({ url, method, body: init.body });
      if (url === "/bios/store/open" && method === "POST") {
        expect(String(init.body || "")).toContain("usb://fat32/registry");
        return jsonResp(200, { ok: true, uuid: "00000000-0000-4000-8000-000000000001", ready: true, live: true });
      }
      if (url === "/bios/store/00000000-0000-4000-8000-000000000001/stat" && method === "GET") {
        const body = { ok: true, persist: "usb", live, ready: live, volume: "fat32", bytes: live ? 64 : 0, format: "g6bs" };
        live = true;
        return jsonResp(200, body);
      }
      return jsonResp(404, { error: "not found" });
    };
    const { ctx } = ctxFixture({ fetchFn });
    const db = ctx.global("pglite")("usb://fat32/registry");
    let s = await db.stat();
    if (!(s.live && s.ready)) s = await db.stat();
    expect(s.ok).toBe(true);
    expect(s.live).toBe(true);
    expect(s.ready).toBe(true);
    expect(s.volume).toBe("fat32");
    expect(calls.some((c) => c.url === "/bios/store/open")).toBe(true);
    expect(calls.filter((c) => c.url.endsWith("/stat")).length).toBeGreaterThanOrEqual(1);
  });

  test("createPgliteWasm uses FileServe bytes and never touches the real DOM", async () => {
    const fetched: string[] = [];
    const fetchFn = async (url: string) => {
      fetched.push(url);
      return {
        ok: true,
        status: 200,
        arrayBuffer: async () => new Uint8Array([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0]).buffer,
        blob: async () => new Blob([new Uint8Array([1, 2, 3])]),
        text: async () => "",
      };
    };
    const created: any[] = [];
    const PGlite = {
      create: async (opts: any) => {
        created.push(opts);
        return { electric: true, dataDir: opts.dataDir };
      },
    };
    const wasmApi = {
      compileStreaming: async () => ({ module: "wasm" }),
      compile: async () => ({ module: "wasm" }),
    };
    const inst = await createPgliteWasm({ fetchFn, PGlite, wasmApi });
    expect(inst.electric).toBe(true);
    expect(inst.dataDir).toBe("memory://");
    expect(fetched).toEqual(["/ui/pglite/pglite.wasm", "/ui/pglite/initdb.wasm", "/ui/pglite/pglite.data"]);
    expect(created[0].initdbWasmModule).toEqual({ module: "wasm" });
    expect((globalThis as any).pgliteWasm).toBeUndefined();
    if (typeof window !== "undefined") expect((window as any).pgliteWasm).toBeUndefined();
  });

  test("createPgliteWasm fails closed without Electric client or FileServe bytes", async () => {
    await expect(createPgliteWasm({})).rejects.toThrow(/Electric client/);
    const PGlite = { create: async () => ({}) };
    await expect(createPgliteWasm({
      PGlite,
      fetchFn: async (url: string) => ({ ok: false, status: 404, text: async () => "missing " + url }),
    })).rejects.toThrow(/missing/);
  });

  test("all five levels record, and an unknown level is refused", () => {
    const { ctx } = ctxFixture();
    for (const level of ctx.console.levels()) ctx.console[level](level + "-msg");
    const page = ctx.consolePage();
    expect(page.entries.map((e: any) => e.level)).toEqual(["log", "info", "warn", "error", "debug"]);
    expect((ctx.console as any).table).toBeUndefined();
  });

  test("polling is incremental via pageRevision", () => {
    const { ctx } = ctxFixture();
    ctx.console.log("one");
    const first = ctx.consolePage();
    expect(first.entries).toHaveLength(1);
    expect(ctx.consolePage(first.pageRevision).entries).toHaveLength(0);
    ctx.console.warn("two");
    const second = ctx.consolePage(first.pageRevision);
    expect(second.entries.map((e: any) => e.data)).toEqual(["two"]);
    expect(second.pageRevision).toBeGreaterThan(first.pageRevision);
  });

  test("the ring is bounded and reports dropped and missed instead of lying", () => {
    const { ctx } = ctxFixture({ consoleLimit: 3 });
    for (let i = 1; i <= 6; i++) ctx.console.log("m" + i);
    const page = ctx.consolePage();
    expect(page.entries.map((e: any) => e.data)).toEqual(["m4", "m5", "m6"]);
    expect(page.dropped).toBe(3);
    // A poller whose cursor fell behind the ring is told how many it missed.
    const stale = ctx.consolePage(1);
    expect(stale.missed).toBe(2); // seq 2 and 3 were evicted
  });

  test("oversized and non-string arguments are bounded, not dropped", () => {
    const { ctx } = ctxFixture();
    ctx.console.log("a".repeat(9000));
    expect(ctx.consolePage().entries[0].data).toContain("...[truncated]");
    ctx.console.clear();
    ctx.console.log("n", 42, true, null, undefined, { a: 1 });
    expect(ctx.consolePage(0).entries.pop().data).toBe('n 42 true null undefined {"a":1}');
  });

  test("a circular object logs a marker rather than throwing", () => {
    const { ctx } = ctxFixture();
    const cycle: any = {}; cycle.self = cycle;
    expect(() => ctx.console.log("c", cycle)).not.toThrow();
    expect(ctx.consolePage().entries[0].data).toContain("[uncloneable]");
  });

  test("instances are isolated, so a frame context cannot interleave into the parent", () => {
    const { ctx: parent, doc } = ctxFixture({ contextId: "main" });
    const frame = createBrowserContext(doc as any, { contextId: "frame-1" });
    parent.console.log("parent-only");
    frame.console.error("frame-only");
    expect(parent.consolePage().entries.map((e: any) => e.data)).toEqual(["parent-only"]);
    expect(frame.consolePage().entries.map((e: any) => e.data)).toEqual(["frame-only"]);
    expect(parent.consolePage().contextId).toBe("main");
    expect(frame.consolePage().contextId).toBe("frame-1");
    expect(frame.console).not.toBe(parent.console);
  });

  test("a DOM element can be painted with the console contents", () => {
    const { ctx, panel } = ctxFixture();
    ctx.console.log("first");
    ctx.console.error("second");
    const cursor = ctx.renderConsoleInto(panel);
    expect(panel.childNodes).toHaveLength(2);
    expect(panel.childNodes[0].textContent).toBe("LOG first");
    expect(panel.childNodes[0].getAttribute("data-console-level")).toBe("log");
    expect(panel.childNodes[1].getAttribute("data-console-level")).toBe("error");
    // Incremental append from the returned cursor does not repaint history.
    ctx.console.warn("third");
    ctx.renderConsoleInto(panel, cursor);
    expect(panel.childNodes).toHaveLength(3);
    expect(panel.childNodes[2].textContent).toBe("WARN third");
  });

  test("logged markup is displayed as text, never parsed as HTML", () => {
    const { ctx, panel } = ctxFixture();
    ctx.console.log("<img src=x onerror=alert(1)>");
    ctx.renderConsoleInto(panel);
    expect(panel.childNodes[0].textContent).toContain("<img src=x onerror=alert(1)>");
    expect(panel.childNodes[0].childNodes).toHaveLength(0);
  });

  test("a dropped-entry notice is rendered so the panel never looks complete when it is not", () => {
    const { ctx, panel } = ctxFixture({ consoleLimit: 2 });
    for (let i = 1; i <= 5; i++) ctx.console.log("m" + i);
    ctx.renderConsoleInto(panel, 1);
    expect(panel.childNodes[0].textContent).toMatch(/earlier entries dropped/);
  });

  test("mirroring forwards entries without recursing", () => {
    const seen: any[] = [];
    const { ctx } = ctxFixture({ mirror: (e: any, id: string) => seen.push([id, e.level, e.data]) });
    ctx.console.warn("w");
    expect(seen).toEqual([["main", "warn", "w"]]);
  });

  test("bad construction and bad render targets are refused", () => {
    const doc = testDocument([]);
    expect(() => createBrowserContext(doc as any, { consoleLimit: 0 })).toThrow(/limit/);
    const ctx = createBrowserContext(doc as any);
    expect(() => ctx.renderConsoleInto(null as any)).toThrow(/unavailable/);
  });

  test("window geometry reads the view and degrades to zero without one", () => {
    const doc = testDocument([]);
    const withView = createBrowserContext(doc as any, { view: { innerWidth: 1920, innerHeight: 1080, devicePixelRatio: 2, location: { href: "http://x/ui/" } } });
    expect(withView.window.innerWidth).toBe(1920);
    expect(withView.window.devicePixelRatio).toBe(2);
    expect(withView.window.href).toBe("http://x/ui/");
    const bare = createBrowserContext(doc as any);
    expect(bare.window.innerWidth).toBe(0);
    expect(bare.window.devicePixelRatio).toBe(1);
    expect(bare.window.href).toBe("");
  });
});

describe("browser context as a libwasm consumer", () => {
  test("libwasm_global resolves singletons to protected handles and console.log reaches the ring", () => {
    const mount = new TestNode("libwasm-root");
    mount.appendChild(new TestNode("original"));
    const doc = testDocument([mount]);
    const ctx = createBrowserContext(doc as any, { contextId: "wasm" });
    const host = createLibwasmHost(doc, mount, WebAssembly, { context: ctx });
    const memory = new WebAssembly.Memory({ initial: 8 });
    host.bind(memory);
    let offset = 0;
    const string = (v: string): [number, number] => {
      const bytes = new TextEncoder().encode(v);
      const ptr = offset; offset += bytes.length;
      new Uint8Array(memory.buffer).set(bytes, ptr);
      return [bytes.length, ptr];
    };
    const env = host.imports.env;

    const c = env.libwasm_global(...string("console"));
    expect(c).toBeGreaterThanOrEqual(0x100000);
    // Stable across calls — a singleton, not a fresh object each time.
    expect(env.libwasm_global(...string("console"))).toBe(c);
    expect(env.libwasm_global(...string("window"))).not.toBe(c);

    // No console ABI needed: the existing typed call family reaches log().
    env.Object_Call_string__void(c, ...string("log"), ...string("from guest"));
    const page = ctx.consolePage();
    expect(page.contextId).toBe("wasm");
    expect(page.entries.map((e: any) => e.data)).toEqual(["from guest"]);

    // Singletons are protected roots: copy is identity, and a free throws.
    // The free must come last — an import error marks the transaction failed
    // by design, so no further import may be called after it.
    expect(env.libwasm_copyObjectRef(c)).toBe(c);
    expect(() => env.libwasm_removeObject(c)).toThrow(/protected root/);
  });

  test("an unknown global and a host with no context both fail closed with handle 0", () => {
    const mount = new TestNode("libwasm-root");
    mount.appendChild(new TestNode("original"));
    const doc = testDocument([mount]);
    const memory = new WebAssembly.Memory({ initial: 8 });
    const put = (m: WebAssembly.Memory, v: string): [number, number] => {
      const bytes = new TextEncoder().encode(v);
      new Uint8Array(m.buffer).set(bytes, 0);
      return [bytes.length, 0];
    };

    const withCtx = createLibwasmHost(doc, mount, WebAssembly, { context: createBrowserContext(doc as any) });
    withCtx.bind(memory);
    expect(withCtx.imports.env.libwasm_global(...put(memory, "eval"))).toBe(0);

    // No context bound at all: still 0, never a fabricated object.
    const noCtx = createLibwasmHost(doc, mount, WebAssembly);
    noCtx.bind(memory);
    expect(noCtx.imports.env.libwasm_global(...put(memory, "console"))).toBe(0);
  });
});

describe("render inspector", () => {
  // A host whose getComputedStyle/rect we control, standing in for a real
  // browser so the diff logic itself is under test.
  function hostFixture(style: Record<string, string>, rect = { width: 130, height: 26 }) {
    const el = new TestNode("status") as any;
    el.tagName = "DIV";
    el.getBoundingClientRect = () => rect;
    const doc = testDocument([el]);
    const view = {
      getComputedStyle: () => ({ getPropertyValue: (p: string) => style[p] ?? "" }),
    };
    return { inspector: createRenderInspector(doc as any, view as any), el };
  }

  // Shape mirrors g6b_css::inspect::StyleReport::to_json.
  const report = (props: Record<string, string>, box: any = { borderBoxWidth: 130, borderBoxHeight: 26 }) => ({
    element: "div#status",
    properties: Object.entries(props).map(([property, value]) => ({ property, value, candidates: [] })),
    box,
  });

  test("agreeing values report ok with the compared list", () => {
    const { inspector } = hostFixture({ width: "100px", display: "block", "padding-left": "10px" });
    const out = inspector.diff("status", report({ width: "100px", display: "block", "padding-left": "10px" }));
    expect(out.ok).toBe(true);
    expect(out.mismatches).toEqual([]);
    expect(out.compared.sort()).toEqual(["display", "padding-left", "width"]);
  });

  test("a wrong length localises the property and reports both sides", () => {
    const { inspector } = hostFixture({ width: "100px", "margin-top": "4px" });
    const out = inspector.diff("status", report({ width: "97px", "margin-top": "4px" }));
    expect(out.ok).toBe(false);
    expect(out.mismatches).toHaveLength(1);
    expect(out.mismatches[0]).toMatchObject({ property: "width", ours: "97px", theirs: "100px", delta: 3, kind: "length" });
  });

  test("tolerance is in whole pixels and applies to lengths only", () => {
    const { inspector } = hostFixture({ width: "100px", display: "block" });
    expect(inspector.diff("status", report({ width: "98px", display: "block" }), 2).ok).toBe(true);
    expect(inspector.diff("status", report({ width: "98px", display: "block" }), 1).ok).toBe(false);
    // A keyword never gets tolerance slack.
    const kw = inspector.diff("status", report({ width: "100px", display: "flex" }), 99);
    expect(kw.ok).toBe(false);
    expect(kw.mismatches[0].kind).toBe("keyword");
  });

  test("keyword comparison is case-insensitive but unit mismatches are loud", () => {
    const { inspector } = hostFixture({ display: "BLOCK", width: "auto" });
    expect(inspector.diff("status", report({ display: "block" })).ok).toBe(true);
    // Ours is a length, the host's is a keyword: a type disagreement.
    const out = inspector.diff("status", report({ width: "100px" }));
    expect(out.mismatches[0].kind).toBe("unit-mismatch");
  });

  test("box model is diffed against the layout rect the browser used", () => {
    const { inspector } = hostFixture({ width: "100px" }, { width: 140, height: 26 });
    const out = inspector.diff("status", report({ width: "100px" }, { borderBoxWidth: 130, borderBoxHeight: 26 }));
    expect(out.ok).toBe(false);
    expect(out.box).toEqual([{ metric: "borderBoxWidth", ours: 130, theirs: 140, delta: 10 }]);
  });

  test("a refused box is not silently treated as agreement", () => {
    const { inspector } = hostFixture({ width: "100px" });
    const out = inspector.diff("status", report({ width: "100px" }, { refused: "css length 2em is not supported" }));
    expect(out.box).toEqual([]);
    expect(out.ok).toBe(true); // properties agreed; the box was not comparable
  });

  test("properties the host does not report are skipped explicitly, not passed", () => {
    const { inspector } = hostFixture({ width: "100px" });
    const out = inspector.diff("status", report({ width: "100px", "background-color": "red" }));
    expect(out.compared).toEqual(["width"]);
    expect(out.skipped).toEqual([{ property: "background-color", reason: "host did not report this property" }]);
  });

  test("a host without getComputedStyle fails loudly instead of reporting a pass", () => {
    const el = new TestNode("status");
    const doc = testDocument([el]);
    const inspector = createRenderInspector(doc as any, {} as any);
    expect(() => inspector.diff("status", report({ width: "1px" }))).toThrow(/getComputedStyle/);
  });

  test("unknown elements and malformed reports are rejected", () => {
    const { inspector } = hostFixture({ width: "100px" });
    expect(() => inspector.diff("missing", report({ width: "1px" }))).toThrow(/unknown element/);
    expect(() => inspector.diff("status", { element: "x" } as any)).toThrow(/properties array/);
    // JSON text is accepted, matching StyleReport::to_json output.
    expect(inspector.diff("status", JSON.stringify(report({ width: "100px" }))).ok).toBe(true);
  });

  test("describe dumps the host view including the layout rect", () => {
    const { inspector } = hostFixture({ width: "100px", display: "block" });
    const text = inspector.describe("status");
    expect(text).toContain("div#status");
    expect(text).toContain("width: 100px");
    expect(text).toContain("rect: 130x26");
  });
});

describe("WASM particle display", () => {
  function fixture() {
    const canvas = new TestNode("bios-fx") as any;
    const ui = new TestNode("bios-ui", { "data-fx-gl": "true", "data-fx-width": "3840", "data-fx-height": "2160", "data-fx-dpi": "192", "data-fx-fps": "30" });
    const note = new TestNode("fx-status"), button = new TestNode("fx-motion");
    const documentEvents = new TestNode("events"), viewEvents = new TestNode("view");
    const motion = Object.assign(new TestNode("media"), { matches: false });
    const frames = new Map<number, Function>();
    let id = 0, draws = 0, deletes = 0;
    const gl: any = new Proxy({
      getShaderParameter: () => true, getProgramParameter: () => true,
      getParameter: (name: string) => name === "MAX_VIEWPORT_DIMS" ? [8192, 8192] : [1, 64],
      getAttribLocation: () => 0, getUniformLocation: () => ({}), isContextLost: () => false,
      createProgram: () => ({}), createShader: () => ({}), createBuffer: () => ({}), createTexture: () => ({}),
      drawArrays: () => { draws++; }, deleteProgram: () => { deletes++; },
    }, { get: (object, key: string) => key in object ? object[key] : /^[A-Z_0-9]+$/.test(key) ? key : () => {} });
    canvas.getContext = () => gl;
    const doc = Object.assign(testDocument([canvas, ui, note, button]), {
      hidden: false,
      addEventListener: documentEvents.addEventListener.bind(documentEvents),
      removeEventListener: documentEvents.removeEventListener.bind(documentEvents),
      createElement: () => ({ getContext: () => ({ clearRect() {}, fillText() {} }) }),
    });
    const view = {
      innerWidth: 1920, innerHeight: 1080, devicePixelRatio: 2,
      requestAnimationFrame: (fn: Function) => { frames.set(++id, fn); return id; },
      cancelAnimationFrame: (id: number) => { frames.delete(id); },
      matchMedia: () => motion,
      addEventListener: viewEvents.addEventListener.bind(viewEvents),
      removeEventListener: viewEvents.removeEventListener.bind(viewEvents),
    };
    const memory = new WebAssembly.Memory({ initial: 1 });
    new Float32Array(memory.buffer).set([0, 0, .8, 4, 0, 0]);
    const steps: number[] = [];
    const exports = { memory, g6b_fx_count: () => 1, g6b_fx_data: () => 0, g6b_fx_logo: () => 16, g6b_fx_step: (dt: number) => { steps.push(dt); } };
    const runFrame = (time: number) => { const [key, fn] = [...frames][0]; frames.delete(key); fn(time); };
    return { canvas, ui, note, button, doc, view, frames, motion, exports, steps, runFrame, documentEvents, draws: () => draws, deletes: () => deletes };
  }

  test("D/WASM stepping is frame paced, bounded, DPI-aware and pausable", () => {
    const f = fixture();
    const display = createParticleBackground(f.doc, f.ui, f.exports, f.view)!;
    expect(f.ui.getAttribute("data-fx-active")).toBe("true");
    expect([f.canvas.width, f.canvas.height]).toEqual([3840, 2160]);
    expect(f.steps).toEqual([0]);
    f.runFrame(0);
    f.runFrame(10);
    expect(f.steps).toEqual([0, 0]);
    f.runFrame(34);
    expect(f.steps.at(-1)).toBeCloseTo(.034);
    f.runFrame(10000);
    expect(f.steps.at(-1)).toBe(.05);
    f.button.listeners.get("click")!();
    expect(display.paused()).toBe(true);
    expect(f.frames.size).toBe(0);
    display.stop();
    expect(f.deletes()).toBe(3);
    expect(f.canvas.hidden).toBe(true);
    expect(f.ui.getAttribute("data-fx-active")).toBeNull();
  });

  test("hidden tabs and reduced motion stop scheduling, context loss preserves setup", () => {
    const f = fixture();
    f.motion.matches = true;
    createParticleBackground(f.doc, f.ui, f.exports, f.view);
    expect(f.frames.size).toBe(0);
    expect(f.draws()).toBe(3);
    f.motion.matches = false;
    f.motion.listeners.get("change")!();
    expect(f.frames.size).toBe(1);
    f.doc.hidden = true;
    f.documentEvents.listeners.get("visibilitychange")!();
    expect(f.frames.size).toBe(0);
    let prevented = false;
    f.canvas.listeners.get("webglcontextlost")!({ preventDefault() { prevented = true; } });
    expect(prevented).toBe(true);
    expect(f.note.textContent).toContain("context lost");
    expect(f.ui.getAttribute("data-fx-active")).toBeNull();
  });

  test("missing GL and invalid WASM state fail locally without animations", () => {
    for (const reason of ["gl", "pointer", "nan", "count"]) {
      const f = fixture();
      if (reason === "gl") f.canvas.getContext = () => null;
      if (reason === "pointer") f.exports.g6b_fx_data = () => 65535;
      if (reason === "count") f.exports.g6b_fx_count = () => 1000000;
      if (reason === "nan") new Float32Array(f.exports.memory.buffer)[0] = NaN;
      createParticleBackground(f.doc, f.ui, f.exports, f.view);
      expect(f.note.textContent).toContain("unavailable");
      expect(f.frames.size).toBe(0);
      expect(f.ui.getAttribute("data-fx-active")).toBeNull();
    }
    const disabled = fixture();
    disabled.ui.setAttribute("data-fx-gl", "false");
    expect(createParticleBackground(disabled.doc, disabled.ui, disabled.exports, disabled.view)).toBeNull();
    expect(disabled.steps).toEqual([]);
  });
});

describe("svelte-d BIOS compile", () => {
  test("refuses SvelteKit", () => {
    expect(refuseKit("export const load = () => {}")).not.toBeNull();
    expect(refuseKit("+page.svelte")).not.toBeNull();
    expect(refuseKit("<p id=\"x\">ok</p>")).toBeNull();
  });

  test("parses FileMgr fetch + holyc", () => {
    const f = parseSvelte(
      "src/FileMgr.svelte",
      `<script lang="ts">
let listing = "USB-FILES";
fetchBios("/bios/files/ntfs");
holycEval("UsbLs(\\"ntfs\\")");
</script>
<section id="filemgr"><p id="fm-list">{listing}</p></section>
`,
    );
    expect(f.langTs).toBe(true);
    expect(f.ops.some((o) => o.kind === "fetch" && o.url === "/bios/files/ntfs")).toBe(true);
    expect(f.ops.some((o) => o.kind === "text" && o.id === "fm-list" && o.value === "USB-FILES")).toBe(
      true,
    );
    expect(f.ops.some((o) => o.kind === "holyc" && o.line.includes("UsbLs"))).toBe(true);
  });

  test("pglite SQL _start is awaited insert/select in generated D", () => {
    const f = parseSvelte(
      "src/App.svelte",
      `<script>
pgliteExec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)");
pgliteQuery("INSERT INTO t VALUES ($1, $2)", "[1,\\"alice\\"]");
await pgliteQuery("SELECT name FROM t WHERE id = $1", "[1]");
</script>
<main id="bios-ui"><p id="status">boot</p></main>
`,
    );
    expect(f.ops.some((o) => o.kind === "pglite" && o.method === "exec" && o.arg1.includes("CREATE TABLE t"))).toBe(true);
    expect(f.ops.some((o) => o.kind === "pglite" && o.method === "query" && o.arg1.startsWith("INSERT"))).toBe(true);
    const sel = f.ops.find((o) => o.kind === "pglite" && o.awaited);
    expect(sel).toBeDefined();
    expect(sel && sel.kind === "pglite" && sel.method).toBe("queryAsync");
    const d = printApp([f]);
    expect(d).toContain("auto db = PgLite();");
    expect(d).toContain('db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)");');
    expect(d).toContain('db.query("INSERT INTO t VALUES ($1, $2)", "[1,\\"alice\\"]");');
    expect(d).toContain("queryAsync");
    expect(d).toContain("SELECT name FROM t WHERE id = $1");
  });

  test("svelte-d parses the store tutorial call forms", () => {
    const f = parseSvelte(
      "src/App.svelte",
      `<script>
pgliteOpen("usb://fat32/registry");
await pgliteWaitReady();
await pgliteStat();
pgliteExec("CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT)");
pgliteQuery("INSERT INTO kv VALUES ($1, $2)", "[\\"boot\\",\\"opensbi\\"]");
await pgliteQuery("SELECT v FROM kv WHERE k = $1", "[\\"boot\\"]");
pgliteBegin();
pgliteCommit();
pgliteListen("ticks");
pgliteExport("fat32");
holycEval("StoreStat(\\"registry\\")");
fetchBios("/bios/store");
</script>
<main id="bios-ui"><p id="status">boot</p></main>
`,
    );
    const methods = f.ops.filter((o) => o.kind === "pglite").map((o) => o.kind === "pglite" ? o.method : "");
    expect(methods).toEqual([
      "open",
      "waitReady",
      "stat",
      "exec",
      "query",
      "queryAsync",
      "begin",
      "commit",
      "listen",
      "export",
    ]);
    expect(f.ops.some((o) => o.kind === "pglite" && o.method === "open" && o.arg1 === "usb://fat32/registry")).toBe(true);
    expect(f.ops.some((o) => o.kind === "holyc" && o.line.includes("StoreStat"))).toBe(true);
    expect(f.ops.some((o) => o.kind === "fetch" && o.url === "/bios/store")).toBe(true);
    const d = printApp([f]);
    expect(d).toContain('auto db = PgLite("usb://fat32/registry");');
    expect(d).toContain("db.waitReady()");
    expect(d).toContain("db.statAsync()");
    expect(d).toContain("db.exec(");
    expect(d).toContain("db.queryAsync(");
    expect(d).toContain("db.listen(");
    expect(d).toContain('db.exportUsb("fat32")');
    expect(printG6bJs([f])).toContain('fetch("/bios/store")');
    expect(printG6bJs([f])).not.toMatch(/\bpglite\s*\(/);
    expect(d).toContain("g6b_holyc");
    expect(d).toContain('g6b_fetch("/bios/store")');
  });

  test("pgliteOpen names the store in the dataDir path", () => {
    const f = parseSvelte(
      "src/App.svelte",
      `<script>
pgliteOpen("usb://fat32/registry");
pgliteOpen("memory://registry");
pgliteOpen("memory://00000000-0000-4000-8000-000000000001");
</script>
<main id="bios-ui"><p id="status">boot</p></main>
`,
    );
    const opens = f.ops
      .filter((o) => o.kind === "pglite" && o.method === "open")
      .map((o) => (o.kind === "pglite" ? o.arg1 : ""));
    expect(opens).toEqual([
      "usb://fat32/registry",
      "memory://registry",
      "memory://00000000-0000-4000-8000-000000000001",
    ]);
    const d = printApp([f]);
    expect(d).toContain('auto db = PgLite("memory://00000000-0000-4000-8000-000000000001")');
    const ts = printGeneratedTs(f);
    expect(ts).toContain('pglite("memory://00000000-0000-4000-8000-000000000001")');
  });

  test("pglite JSON binds paint into markup", () => {
    const f = parseSvelte(
      "src/App.svelte",
      `<script>
let rows = await pgliteQuery("SELECT name FROM t WHERE id = $1", "[1]");
let st = await pgliteStat();
</script>
<main id="bios-ui">
  <p id="out">{rows}</p>
  <p id="live">{st.ready}</p>
</main>
`,
    );
    const q = f.ops.find((o) => o.kind === "pglite" && o.method === "queryAsync");
    expect(q && q.kind === "pglite" && q.bind).toBe("rows");
    const st = f.ops.find((o) => o.kind === "pglite" && o.method === "stat");
    expect(st && st.kind === "pglite" && st.bind).toBe("st");
    expect(f.ops.some((o) => o.kind === "text" && o.id === "out" && o.bind === "rows")).toBe(true);
    expect(
      f.ops.some((o) => o.kind === "text" && o.id === "live" && o.bind === "st" && o.field === "ready"),
    ).toBe(true);
    const d = printApp([f]);
    expect(d).toContain('auto rows = db.queryAsync("SELECT name FROM t WHERE id = $1", "[1]")');
    expect(d).toContain("auto st = db.statAsync()");
    expect(d).toContain('setProperty(out, "innerText", JSON.stringify(rows))');
    expect(d).toContain('st["ready"]');
    expect(d).toContain("JSON.stringify(pglite_field_0)");
    expect(d).not.toContain('"{rows}"');
    const ts = printGeneratedTs(f);
    expect(ts).toContain('const rows = await db.query("SELECT name FROM t WHERE id = $1", "[1]")');
    expect(ts).toContain("const st = await db.stat()");
    expect(ts).toContain('document.getElementById("out").innerText = JSON.stringify(rows)');
    expect(ts).toContain('document.getElementById("live").innerText = JSON.stringify(st && st.ready)');
    expect(printG6bJs([f])).not.toMatch(/\bpglite\s*\(/);
    expect(() =>
      parseSvelte(
        "src/App.svelte",
        `<script>let db = await pgliteQuery("SELECT 1", "[]");</script><p id="x">x</p>`,
      ),
    ).toThrow(/reserved/);
    expect(() =>
      parseSvelte(
        "src/App.svelte",
        `<script>let x = pgliteOpen("registry");</script><p id="x">x</p>`,
      ),
    ).toThrow(/cannot be assigned/);
  });

  test("LDC 1.43 is the wasm cell; 1.41/1.42 refused", () => {
    expect(isLdc143Text("LDC - the LLVM D compiler (1.43.0-git-1218a47):")).toBe(true);
    expect(isLdc143Text("LDC - the LLVM D compiler (1.41.0):")).toBe(false);
    expect(isLdc143Text("LDC - the LLVM D compiler (1.42.0):")).toBe(false);
    const tc = resolveToolchain(root);
    if (tc.ldc) {
      expect(tc.ok).toBe(true);
      expect(tc.versionLine).toMatch(/1\.43|1\.44|1\.45|1\.46/);
      expect(tc.versionLine).not.toMatch(/1\.41|1\.42/);
    }
  });

  test("project compiles to wasm + js exports", () => {
    const r = compileProject(root, { dub: false });
    expect(r.wasm[0]).toBe(0x00);
    expect(r.wasm[1]).toBe(0x61);
    expect(r.wasm[2]).toBe(0x73);
    expect(r.wasm[3]).toBe(0x6d);
    expect(r.js).toContain('document.getElementById("status").innerText = "UI-BOOT"');
    expect(r.js).toContain('fetch("/bios/files/ntfs")');
    expect(r.js).toContain("kernel.holyc");
    expect(r.js).toContain("kernel.register");
    expect(r.wsFiles.some((p) => p.includes("src-d/app.d"))).toBe(true);
    expect(r.wsFiles.some((p) => p.includes("src-ts/jsExports.ts"))).toBe(true);
    expect(r.wsFiles.some((p) => p.includes(".svelte-d/manifest.json"))).toBe(true);
    expect(r.wsFiles.some((p) => p === "dub.sdl")).toBe(true);
    expect(r.wsFiles.some((p) => p.includes("src-d/app.d"))).toBe(true);
    expect(r.js).toContain('fetch("/bios/menu")');
    expect(r.js).toContain('fetch("/bios/menu/settings")');
    expect(r.js).toContain('fetch("/bios/menu/cpu")');
    expect(r.js).toContain('fetch("/bios/store")');
    expect(r.js).toContain('document.getElementById("store-title").innerText = "Store"');
    expect(r.js).not.toMatch(/\bpglite\s*\(/);
    const d = printApp(loadProject(join(root, "src")));
    const awaitAt = d.indexOf("libwasm_await__void");
    const tryAt = d.lastIndexOf("try {", awaitAt);
    const catchAt = d.indexOf("} catch (Exception e)", tryAt);
    expect(catchAt).toBeGreaterThan(tryAt);
    expect(catchAt).toBeLessThan(awaitAt);
    expect(d.indexOf("try {", awaitAt)).toBeGreaterThan(awaitAt);
    expect(d).toContain('g6b_fetch("/bios/menu")');
    expect(d).toContain('g6b_fetch("/bios/menu/cpu")');
    expect(d).toContain('g6b_fetch("/bios/store")');
    expect(d).toContain('auto db = PgLite("memory://registry")');
    expect(d).toContain("CREATE TABLE IF NOT EXISTS bios_ui");
    expect(d).toContain("auto rows = db.queryAsync");
    expect(d).toContain('setProperty(store_status, "innerText", JSON.stringify(rows))');
    expect(projectHtml(loadProject(join(root, "src")))).toContain('id="store"');
    expect(d).toContain('setProperty(bios_mark, "src", "/ui/g6lc.svg")');
    expect(d).toContain('g6b_listen("tab-cpu", "click")');
    expect(d).toContain('g6b_listen("refresh", "click")');
    expect(d).toContain("Handle menu_cpu_body = 0;");
    expect(d.indexOf("Handle menu_cpu_body = 0;")).toBeLessThan(d.indexOf("try {"));
    expect(d).toMatch(/menu_cpu_body = createElement\(NodeType\.tbody\)/);
    expect(d).not.toContain("auto menu_cpu_body = createElement");
    expect(d).not.toContain('setProperty(tab_cpu, "on:click"');
    expect(r.catalog).toContain("Settings");
    expect(r.cell?.via).toBe("skip");
    expect(r.catalog).toContain("FileMgr");
    expect(r.catalog).toContain("Store");
    expect(marker("NodeDef")).toBe("SVELTE-LIVE NodeDef");
    expect(marker("{#await}")).toBe("SVELTE-STUB {#await}");
    expect(marker("sveltekit")).toBe("SVELTE-REFUSED sveltekit");
    expect(catalogJson()).toContain('"_start"');
  });
});
