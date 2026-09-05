// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { describe, expect, test } from "bun:test";
import { dirname, join } from "node:path";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { catalogJson, marker, refuseKit } from "./constructs.ts";
import { compileProject, loadProject, projectHtml } from "./index.ts";
import { emitWasm } from "./emit-wasm.ts";
import { printG6bJs } from "./print-ts.ts";
import { createWasmHost, createBrowserApp, createLibwasmHost, createParticleBackground } from "../src/kernel.ts";
import { isLdc143Text, resolveToolchain } from "./ldc.ts";
import { parseSvelte } from "./parse.ts";

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
    expect(html).toContain('<section id="bios-ui">\n<p id="status">');
    expect(html).toContain('<nav id="bios-menu">\n<p id="menu-title">');
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

  test("full emitted module preserves selective filesystem tabs and suppresses disabled settings reads", async () => {
    const files = loadProject(join(root, "src"));
    const nodes = new Map<string, TestNode>();
    for (const file of files) for (const op of file.ops) {
      if (op.kind === "text") nodes.set(op.id, new TestNode(op.id));
    }
    nodes.get("bios-ui")!.setAttribute("data-wasm-url", "/custom/ui.wasm");
    const tabs = nodes.get("fm-tabs")!;
    tabs.textContent = "fat32";
    tabs.setAttribute("data-preserve", "true");
    nodes.set("fm-fat32", new TestNode("fm-fat32", { "data-fetch": "/bios/files/fat32" }));
    const reads: string[] = [];
    const app = createBrowserApp(testDocument([...nodes.values()]), async (url: string) => {
      reads.push(url);
      if (url === "/custom/ui.wasm") return { ok: true, arrayBuffer: async () => emitWasm(files) };
      return { ok: true, json: async () => ({ fs: "fat32" }) };
    });
    await app.start();
    expect(tabs.textContent).toBe("fat32");
    expect(nodes.get("fm-fat32")!.textContent).toContain('"fs": "fat32"');
    expect(new Set(reads)).toEqual(new Set(["/custom/ui.wasm", "/bios/files/fat32"]));
    expect(nodes.get("status")!.textContent).not.toContain("failed");
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
    for (const property of ["innerHTML", "outerHTML", "src", "href", "onclick", "__proto__", "constructor", "id", "style"]) {
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
    const { host, mount } = fixture();
    const { instance } = await WebAssembly.instantiate(bytes, host.imports);
    host.bind(instance.exports.memory);
    (instance.exports._start as Function)((instance.exports.__heap_base as WebAssembly.Global).value);
    host.commit();
    expect(mount.textContent).toContain("UI-BOOT");
    expect(mount.textContent).toContain("CPU");
    expect(mount.textContent).toContain("Settings");
    expect(host.nodeCount()).toBeGreaterThan(10);
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
    expect(r.catalog).toContain("Settings");
    expect(r.cell?.via).toBe("skip");
    expect(r.catalog).toContain("FileMgr");
    expect(marker("NodeDef")).toBe("SVELTE-LIVE NodeDef");
    expect(marker("{#await}")).toBe("SVELTE-STUB {#await}");
    expect(marker("sveltekit")).toBe("SVELTE-REFUSED sveltekit");
    expect(catalogJson()).toContain('"_start"');
  });
});
