// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/**
 * svelte-engine-ws wasm cell — svelte-d `workspace/wasm_build.d`:
 *   dub build --arch=wasm32-unknown-wasi --compiler=<LDC 1.43> --config=application
 * DFLAGS/DC/DMD cleared so 1.41 objects never mix. Host vibe.0 cell refused.
 */
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { runtimePreflight, wasmLdcConfig, type Toolchain } from "./ldc.ts";
import { resolveWasmOpt } from "./binaryen.ts";
import { createBrowserContext, createLibwasmHost } from "../src/kernel.ts";

export type WasmCellResult = {
  status: number;
  via: "dub" | "skip";
  reason: string;
  raw: string;
  ship: string;
  log: string;
  requested?: boolean;
  artifact?: "fresh" | "stale" | "unavailable";
  provenance?: CellProvenance;
};

export const LIBWASM_ABI = "g6lc-libwasm-dom-shell-fx/v1";
export type CellProvenance = {
  schema: "g6lc-libwasm-artifact/v1";
  abi: string;
  inputs: string;
  sha256: string;
  buildType: "debug" | "release";
  compiler: string;
  /**
   * The `wasm-opt` that ran the asyncify pass, as `<version> <source>`, or
   * absent when the artifact was not asyncified.
   *
   * Informational, like `compiler`: deliberately **not** part of `inputs` and
   * not compared by `checkCellArtifact`. A different wasm-opt does change the
   * output bytes, but those are already pinned exactly by `sha256`, and making
   * the tool a staleness trigger would report a perfectly good committed
   * artifact as stale on any machine that has not installed the (gitignored)
   * toolchain — which is the failure mode this manifest exists to avoid.
   */
  asyncifyTool?: string;
  imports: string[];
};

export function sha256(data: string | Uint8Array): string {
  return createHash("sha256").update(data).digest("hex");
}

export function verifyLibwasmAbi(bytes: Uint8Array, lane: "app" | "fx-probe" = "app"): string[] {
  if (!WebAssembly.validate(bytes)) throw new Error("invalid libwasm binary or unsupported wasm EH engine");
  const types: string[] = [];
  const functions: number[] = [];
  const globals: number[] = [];
  const exports = new Map<string, { kind: number; index: number }>();
  const imports: string[] = [];
  let memoryCount = 0;
  let offset = 8;
  let end = bytes.length;
  const byte = () => {
    if (offset >= end) throw new Error("truncated libwasm ABI section");
    return bytes[offset++];
  };
  const uint = () => {
    let value = 0;
    for (let i = 0; i < 5; i++) {
      const b = byte();
      value += (b & 127) * 2 ** (7 * i);
      if (!(b & 128)) return value;
    }
    throw new Error("invalid libwasm ABI integer");
  };
  const name = () => {
    const length = uint();
    if (offset + length > end) throw new Error("truncated libwasm ABI name");
    const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes.subarray(offset, offset + length));
    offset += length;
    return text;
  };
  const vector = () => Array.from({ length: uint() }, () => byte()).join(",");
  const expected: Record<string, string> = {
    createElement: "127->127",
    appendChild: "127,127->",
    setProperty: "127,127,127,127,127->",
    fetch: "127,127->127",
    holyc: "127,127->127",
    register_endpoint: "127,127,127,127->",
    libwasm_await__void: "127->",
    libwasm_await_supported: "->127",
    libwasm_await_failed: "->127",
    libwasm_await_error: "127->",
    libwasm_await_value: "127->",
    libwasm_note_await_fail: "127->",
    libwasm_note_await_ok: "127->",
    libwasm_get__string: "127,127->",
    libwasm_add__string: "127,127->127",
    libwasm_add__object: "->127",
    // B72: resolve a browser-instance global to a protected object handle.
    libwasm_global: "127,127->127",
    // svelte-engine spa.ts: `addCss` is void(string); `getRoot` is Handle().
    addCss: "127,127->",
    getRoot: "->127",
    libwasm_removeObject: "127->",
    libwasm_copyObjectRef: "127->127",

    // B62 scalar box/unbox.  127=i32, 126=i64, 125=f32, 124=f64.
    libwasm_add__bool: "127->127",
    libwasm_add__int: "127->127",
    libwasm_add__uint: "127->127",
    libwasm_add__long: "126->127",
    libwasm_add__ulong: "126->127",
    libwasm_add__short: "127->127",
    libwasm_add__ushort: "127->127",
    libwasm_add__float: "125->127",
    libwasm_add__double: "124->127",
    libwasm_add__byte: "127->127",
    libwasm_add__ubyte: "127->127",
    libwasm_add__ints: "127,127->127",

    // B70: DOM event host boundary.
    addEventListener: "127,127,127,127,127,127->",
    removeEventListener: "127->",
    dispatchEvent: "127,127,127,127,127,127->127",
    // G6LC_G6B D names (`g6b_listen` → add_event_listener).
    add_event_listener: "127,127,127,127,127,127->",
    remove_event_listener: "127->",
    dispatch_event: "127,127,127,127,127,127->127",
    libwasm_add__uints: "127,127->127",

    libwasm_get__bool: "127->127",
    libwasm_get__int: "127->127",
    libwasm_get__uint: "127->127",
    libwasm_get__long: "127->126",
    libwasm_get__ulong: "127->126",
    libwasm_get__short: "127->127",
    libwasm_get__ushort: "127->127",
    libwasm_get__float: "127->125",
    libwasm_get__double: "127->124",
    libwasm_get__byte: "127->127",
    libwasm_get__ubyte: "127->127",
    // B63 property registry scaffold and typed getter/call core.
    libwasm_get__field: "127,127,127->127",
    libwasm_get_idx__field: "127,127->127",
    ...Object.fromEntries(
      (() => {
        const entries: [string, string][] = [];
        for (const t of ["int", "uint", "ushort", "bool"]) {
          entries.push([`Object_Getter__${t}`, "127,127,127->127"]);
        }
        entries.push(["Object_Getter__float", "127,127,127->125"]);
        entries.push(["Object_Getter__double", "127,127,127->124"]);
        entries.push(["Object_Getter__Handle", "127,127,127->127"]);
        entries.push(["Object_Getter__string", "127,127,127,127->"]);
        // B64 Optional!T getters: value at raw, presence flag at raw+sizeof(T).
        for (const t of ["Handle", "Uint", "Double", "String", "Bool"]) {
          entries.push([`Object_Getter__Optional${t}`, "127,127,127,127->"]);
        }
        const calls: [string, string[], string][] = [
          ["", [], "void"],
          ["string", ["127", "127"], "void"],
          ["uint", ["127"], "void"],
          ["int", ["127"], "void"],
          ["bool", ["127"], "void"],
          ["double", ["124"], "void"],
          ["float", ["125"], "void"],
          ["Handle", ["127"], "void"],
          ["string_string", ["127", "127", "127", "127"], "void"],
          ["double_double", ["124", "124"], "void"],
          ["string", ["127", "127"], "Handle"],
          ["uint", ["127"], "Handle"],
          ["int", ["127"], "Handle"],
          ["bool", ["127"], "Handle"],
          ["Handle", ["127"], "Handle"],
          ["string_string", ["127", "127", "127", "127"], "Handle"],
          ["string", ["127", "127"], "bool"],
          ["string", ["127", "127"], "string"],
          ["uint", ["127"], "string"],
          ["uint_uint", ["127", "127"], "string"],
        ];
        for (const [argPart, argSig, ret] of calls) {
          const name = `Object_Call_${argPart}__${ret}`;
          const sret = ret === "string" ? ["127"] : [];
          const params = [...sret, "127", "127", "127", ...argSig];
          const result =
            ret === "void" || ret === "string"
              ? ""
              : ret === "Handle" || ret === "bool" || ret === "int" || ret === "uint" || ret === "ushort"
              ? "127"
              : ret === "float"
              ? "125"
              : "124";
          entries.push([name, params.join(",") + "->" + result]);
        }
        // B64 Optional!T method calls: optional Handle or string result only.
        for (const [argPart, argSig] of [
          ["string", ["127", "127"]],
          ["uint", ["127"]],
          ["int", ["127"]],
          ["bool", ["127"]],
        ] as [string, string[]][]) {
          for (const ret of ["OptionalHandle", "OptionalString"]) {
            const name = `Object_Call_${argPart}__${ret}`;
            const params = ["127", "127", "127", "127", ...argSig];
            entries.push([name, params.join(",") + "->"]);
          }
        }
        return entries;
      })(),
    ),

    // B65 JSON codec.
    JSON_parse_string: "127,127->127",
    JSON_stringify: "127,127->",

    // B65 overload-resolving vararg calls.  The wasm import is
    //   (sret?, handle, method_len, method_ptr, argsdef_len, argsdef_ptr, args_len, args_ptr) -> ret
    ...Object.fromEntries(["void", "bool", "int", "uint", "short", "ushort", "long", "ulong", "float", "double", "Handle", "string"].map((ret) => {
      const sret = ret === "string" ? ["127"] : [];
      const params = [...sret, "127", "127", "127", "127", "127", "127", "127"];
      const result =
        ret === "void" || ret === "string"
          ? ""
          : ret === "Handle" || ret === "bool" || ret === "int" || ret === "uint" || ret === "short" || ret === "ushort"
          ? "127"
          : ret === "float"
          ? "125"
          : "124";
      return [`Object_VarArgCall__${ret}`, params.join(",") + "->" + result];
    })),

    // B67 getTimeStamp returns a D `long` (i64 milliseconds).
    getTimeStamp: "->126",

    // B68 promise combinators: each takes a handle to a handle-array and
    // returns a new promise handle.
    libasync_promise_all__promise: "127->127",
    libasync_promise_any__promise: "127->127",
    libasync_promise_allsettled__promise: "127->127",

    // B68 typed array / DataView Create: a D slice (len, ptr) -> Handle.
    Int8Array_Create: "127,127->127",

    // B67 Moment: first-party Date handle creation.
    libwasm_moment_now: "->127",
    libwasm_moment_from_millis: "126->127",

    // B69: bounded ES6 Map host surface.
    libwasm_map_create: "->127",
    libwasm_map_set: "127,127,127,127,127->",
    libwasm_map_get__OptionalString: "127,127,127,127->",
    libwasm_map_has: "127,127,127->127",
    libwasm_map_delete: "127,127,127->",
    libwasm_map_clear: "127->",

    // Object_Call result kinds expanded for Moment method calls.
    Object_Call_string__uint: "127,127,127,127->127",
    Object_Call_string__int: "127,127,127,127->127",
    Object_Call_string__double: "127,127,127,127->124",
    Int32Array_Create: "127,127->127",
    Uint8Array_Create: "127,127->127",
    Float32Array_Create: "127,127->127",
    DataView_Create: "127,127->127",

    // B66 named delegates and event handlers.
    // libwasm_set__function(name, ctx, ptr) and unset are host-controlled.
    libwasm_set__function: "127,127,127,127->",
    libwasm_unset__function: "127,127->",
    // setTimeout/setInterval take (ctx, ptr, ms) and return a timer id.
    setTimeout: "127,127,127->127",
    setInterval: "127,127,127->127",
    clearTimeout: "127->",
    clearInterval: "127->",
    requestAnimationFrame: "127,127->127",
    cancelAnimationFrame: "127->",
    // Object_Call_EventHandler__void(handle, name, defined, ctx, ptr) -> void.
    Object_Call_EventHandler__void: "127,127,127,127,127,127->",
    // Object_Getter__EventHandler(sret, handle, name) -> void (sret holds ctx, ptr, defined).
    Object_Getter__EventHandler: "127,127,127,127->",

    __cpp_exception: "127->",
    // B67 Lodash: 3 init kinds x 4 result kinds. A `string` result is sret
    // (leading i32); a `string` init is (len, ptr) plus a trailing eval flag;
    // a `long` init is a real i64 and `long`/`double` results are i64/f64.
    // 127=i32, 126=i64, 124=f64 (LIBWASM-ABI.md §2).
    ...Object.fromEntries(["Handle", "long", "string"].flatMap((k) =>
      ["string", "long", "double", "Handle"].map((r) => {
        const init = k === "long" ? ["126"] : k === "string" ? ["127", "127"] : ["127"];
        const params = [...(r === "string" ? ["127"] : []), ...init, "127", "127", "127", "127", "127", "127",
          ...(k === "string" ? ["127"] : [])];
        const result = r === "string" ? "" : r === "long" ? "126" : r === "double" ? "124" : "127";
        return [`ldexec_${k}__${r}`, params.join(",") + "->" + result];
      }),
    )),
  };
  while (offset < bytes.length) {
    end = bytes.length;
    const section = byte();
    const size = uint();
    end = offset + size;
    if (end > bytes.length) throw new Error("truncated libwasm section");
    if (section === 1) {
      const count = uint();
      for (let i = 0; i < count; i++) {
        if (byte() !== 0x60) throw new Error("unsupported libwasm function type");
        types.push(vector() + "->" + vector());
      }
    } else if (section === 2) {
      const count = uint();
      for (let i = 0; i < count; i++) {
        const module = name();
        const field = name();
        const kind = byte();
        if (module !== "env" || !Object.hasOwn(expected, field) || imports.includes(field)) {
          throw new Error(`unsupported libwasm import: ${module}.${field}`);
        }
        if (kind !== (field === "__cpp_exception" ? 4 : 0)) throw new Error(`libwasm import kind mismatch: ${field}`);
        if (kind === 4 && byte() !== 0) throw new Error("unsupported exception tag attribute");
        const type = uint();
        if (types[type] !== expected[field]) throw new Error(`libwasm import signature mismatch: ${field}`);
        if (kind === 0) functions.push(type);
        imports.push(field);
      }
    } else if (section === 3) {
      const count = uint();
      for (let i = 0; i < count; i++) functions.push(uint());
    } else if (section === 5) {
      memoryCount = uint();
      if (memoryCount !== 1) throw new Error("libwasm requires one wasm32 memory");
      const flags = uint();
      if (flags > 1) throw new Error("shared/memory64 libwasm memory is unsupported");
      uint();
      if (flags === 1) uint();
    } else if (section === 6) {
      const count = uint();
      for (let i = 0; i < count; i++) {
        globals.push(byte());
        byte();
        if (byte() !== 0x41) throw new Error("unsupported libwasm global initializer");
        uint();
        if (byte() !== 0x0b) throw new Error("unsupported libwasm global expression");
      }
    } else if (section === 7) {
      const count = uint();
      for (let i = 0; i < count; i++) exports.set(name(), { kind: byte(), index: uint() });
    } else if (section === 8) {
      throw new Error("libwasm start section must not run before memory is bound");
    }
    offset = end;
  }
  if (lane === "fx-probe" && imports.length) throw new Error("particle probe must not import a runtime service");
  const required = [["g6b_fx_data", "->127"], ["g6b_fx_count", "->127"], ["g6b_fx_logo", "->127"], ["g6b_fx_step", "125->"]];
  if (lane === "app") required.push(["_start", "127->"], ["allocString", "127->127"]);
  for (const [field, signature] of required) {
    const entry = exports.get(field);
    if (!entry || entry.kind !== 0 || types[functions[entry.index]] !== signature) throw new Error(`libwasm export signature mismatch: ${field}`);
  }
  const memory = exports.get("memory");
  const heap = exports.get("__heap_base");
  if (memoryCount !== 1 || memory?.kind !== 2 || memory.index !== 0 || heap?.kind !== 3 || globals[heap.index] !== 127) {
    throw new Error("libwasm requires exported memory and i32 __heap_base");
  }
  return imports.sort();
}

export function cellInputHash(ws: string, tc: Toolchain, buildType: "debug" | "release" = "release"): string {
  const entries: [string, string][] = [];
  const add = (key: string, path: string) => entries.push([key, sha256(readFileSync(path))]);
  const tree = (key: string, path: string) => {
    for (const entry of readdirSync(path, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name, "en"))) {
      if (entry.isSymbolicLink()) throw new Error(`symlink in build inputs: ${path}/${entry.name}`);
      if (entry.isDirectory()) tree(`${key}/${entry.name}`, join(path, entry.name));
      else if (/\.(d|di|dt|ts|svelte|sdl|json)$/.test(entry.name)) add(`${key}/${entry.name}`, join(path, entry.name));
    }
  };
  for (const dir of ["src-d", "src-d-views", "src-svelte"]) tree(`workspace/${dir}`, join(ws, dir));
  add("workspace/dub.sdl", join(ws, "dub.sdl"));
  add("workspace/ldc.conf", join(ws, ".svelte-d", "ldc2-wasm.conf"));
  add("libwasm/dub.sdl", join(tc.libwasm, "dub.sdl"));
  tree("libwasm/source", join(tc.libwasm, "source"));
  for (const dir of ["memutils-wasm", "fast-wasm", "diet-wasm", "optional-wasm"]) {
    add(`${dir}/dub.sdl`, join(tc.libwasm, dir, "dub.sdl"));
    tree(`${dir}/source`, join(tc.libwasm, dir, "source"));
  }
  const runtime = join(tc.libwasm, "runtime-v1.43.0");
  add("runtime/dub.sdl", join(runtime, "dub.sdl"));
  add("runtime/object.d", join(runtime, "object.d"));
  for (const dir of ["core", "ldc", "std", "rt", "etc"]) tree(`runtime/${dir}`, join(runtime, dir));
  const compiler = dirname(fileURLToPath(import.meta.url));
  for (const file of readdirSync(compiler).filter((name) => name.endsWith(".ts") && !name.endsWith(".test.ts")).sort()) {
    add(`compiler/${file}`, join(compiler, file));
  }
  add("adapter", join(compiler, "..", "src", "kernel.ts"));
  add("worker", join(compiler, "..", "src", "worker.ts"));
  add("ldc", tc.ldc);
  add("dub", tc.dub);
  return sha256(JSON.stringify({ abi: LIBWASM_ABI, version: tc.versionLine, buildType, entries }));
}

export function verifyLibwasmStartup(bytes: Uint8Array): void {
  class Element {
    children: Element[] = [];
    parentNode: Element | null = null;
    id = "";
    className = "";
    title = "";
    value = "";
    attrs = new Map<string, string>();
    get childNodes() { return this.children; }
    set textContent(_: string) { this.replaceChildren(); }
    get textContent(): string { return this.children.map((c) => c.textContent).join(""); }
    contains(node: Element): boolean { return this === node || this.children.some((child) => child.contains(node)); }
    getAttribute(key: string) { return this.attrs.get(key) ?? null; }
    setAttribute(key: string, value: string) { this.attrs.set(key, value); }
    removeAttribute(key: string) { this.attrs.delete(key); }
    remove() {
      if (this.parentNode) this.parentNode.children.splice(this.parentNode.children.indexOf(this), 1);
      this.parentNode = null;
    }
    insertBefore(child: Element, sibling: Element | null) {
      if (child === sibling) return;
      child.remove();
      this.children.splice(sibling ? this.children.indexOf(sibling) : this.children.length, 0, child);
      child.parentNode = this;
    }
    replaceChildren(...children: Element[]) {
      for (const child of this.children) child.parentNode = null;
      this.children = [];
      for (const child of children) this.insertBefore(child, null);
    }
  }
  const mount = new Element();
  const doc = { createElement: () => new Element() };
  // The cell's `_start` resolves `window.pglite` through the lodash host-eval
  // path (`PgLite()` -> `defaultTo(Eval("window.pglite"))`, libwasm/pglite.d).
  // With no context bound, `internParam` sees `ctx === null` and refuses the
  // name, so `_start` throws and a perfectly good artifact is reported stale.
  // Bind the *first-party* context rather than a mock: `createBrowserContext`
  // is what the browser runtime uses, and it wires `pglite` into `bindings()`
  // itself. `contextId` is not "main" (so the module-level `pglite` export is
  // not reassigned by a build step) and `biosStore` opts the factory in
  // anyway. `fetchFn` is intentionally omitted: the synchronous lodash path
  // degrades every store method before any request is made, so a reachable
  // fetch here would be a bug and fails closed.
  const context = createBrowserContext(doc, { contextId: "libwasm-verify", biosStore: true });
  const host = createLibwasmHost(doc, mount, globalThis.WebAssembly, { context });
  const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), host.imports);
  const e = instance.exports as Record<string, any>;
  try {
    host.bind(e.memory);
    const heap = e.__heap_base.value;
    if (!Number.isInteger(heap) || heap < 0 || heap > e.memory.buffer.byteLength) throw new Error("invalid libwasm heap base");
    e._start(heap);
    host.commit();
    e.g6b_fx_step(0);
    const count = e.g6b_fx_count();
    if (count !== 256) throw new Error("unexpected particle ABI count");
    for (const [ptr, length] of [[e.g6b_fx_data(), count * 4], [e.g6b_fx_logo(), 2]]) {
      if (!Number.isInteger(ptr) || ptr < 0 || ptr % 4 || ptr + length * 4 > e.memory.buffer.byteLength) throw new Error("particle ABI bounds violation");
      if (!new Float32Array(e.memory.buffer, ptr, length).every(Number.isFinite)) throw new Error("non-finite particle ABI state");
    }
  } finally { host.rollback(); }
}

export function checkCellArtifact(bytes: Uint8Array, provenance: CellProvenance, inputs: string): void {
  if (provenance.schema !== "g6lc-libwasm-artifact/v1" || provenance.abi !== LIBWASM_ABI || provenance.inputs !== inputs || !["debug", "release"].includes(provenance.buildType)) {
    throw new Error("stale libwasm provenance: source/runtime/toolchain/ABI mismatch");
  }
  if (sha256(bytes) !== provenance.sha256) throw new Error("libwasm artifact hash mismatch");
  if (JSON.stringify(verifyLibwasmAbi(bytes)) !== JSON.stringify(provenance.imports)) throw new Error("libwasm import manifest mismatch");
  verifyLibwasmStartup(bytes);
}

function posix(p: string): string {
  return p.replace(/\\/g, "/");
}

function winToWsl(p: string): string {
  return posix(p).replace(/^([A-Za-z]):/, (__, drive) => `/mnt/${drive.toLowerCase()}`);
}

function isElfLikeWasmOpt(bin: string): boolean {
  if (!existsSync(bin) || bin.toLowerCase().endsWith(".exe")) return false;
  try {
    const head = readFileSync(bin).subarray(0, 4);
    return head[0] === 0x7f && head[1] === 0x45 && head[2] === 0x4c && head[3] === 0x46;
  } catch {
    return false;
  }
}

type SpawnResult = ReturnType<typeof spawnSync>;

function runWasmOpt(bin: string, args: string[], run = spawnSync): SpawnResult {
  if (process.platform === "win32" && isElfLikeWasmOpt(bin)) {
    const wslArgs = [winToWsl(bin), ...args.map((a) => /^[A-Za-z]:[\\\/]/.test(a) ? winToWsl(a) : a)];
    return run("wsl", wslArgs, { encoding: "utf8", shell: false, maxBuffer: 32 * 1024 * 1024 });
  }
  return run(bin, args, { encoding: "utf8", shell: false, maxBuffer: 32 * 1024 * 1024 });
}

/** Engine `dub.sdl` (wasm-eh / ldc-master), BIOS target names. */
export function engineDubSdl(libwasm: string): string {
  const lib = `dependency "libwasm" path=${JSON.stringify(posix(libwasm || "../libwasm"))}\n`;
  return `name "svelte-engine"
description "BIOS-UI wasm cell: libwasm SPA (svelte-d fall-through). Not vibe.0."
authors "Etienne Cimon"
copyright "Copyright © 2026, Etienne Cimon"
license "MIT"
toolchainRequirements ldc=">=1.43.0-beta1"
dflags "--wasm-enable-eh" "-mattr=+exception-handling" "-fvisibility=hidden" "-fno-moduleinfo"
versions "G6LC_G6B"
targetPath "public"
targetName "bios-ui-raw"
sourcePaths "src-d"
stringImportPaths "src-d-views"
buildRequirements "allowWarnings"

configuration "application" {
    targetType "executable"
    dflags "-link-internally" "-defaultlib=" "--foptimize-nothrow=false"
    lflags "--export=_start" "--export=allocString" "--export=__heap_base" "--export=jsCallback" "--export=jsCallback0" "--export=g6b_fx_data" "--export=g6b_fx_count" "--export=g6b_fx_step" "--export=g6b_fx_logo"
    ${lib}    subConfiguration "libwasm" "g6lc-bios"
}

configuration "ldc-master" {
    targetType "executable"
    dflags "-link-internally" "-defaultlib=" "--foptimize-nothrow=false"
    lflags "--export=_start" "--export=allocString" "--export=__heap_base" "--export=jsCallback" "--export=jsCallback0" "--export=g6b_fx_data" "--export=g6b_fx_count" "--export=g6b_fx_step" "--export=g6b_fx_logo"
    ${lib}    subConfiguration "libwasm" "g6lc-bios"
}

buildType "debug" {
    buildOptions "debugMode" "debugInfo"
}

buildType "release" {
    buildOptions "releaseMode" "optimize" "inline"
    lflags "-strip-all"
}
`;
}

export function pinWasmLdc(ws: string, tc: Toolchain): void {
  mkdirSync(join(ws, ".svelte-d"), { recursive: true });
  const body = JSON.stringify(
    {
      schema: "svelte-d-wasm-ldc/v1",
      ldc: posix(tc.ldc),
      dub: posix(tc.dub),
      libwasm: posix(tc.libwasm),
      cell: "wasm-eh",
      version: tc.versionLine,
      ok: tc.ok,
    },
    null,
    2,
  ) + "\n";
  writeFileSync(join(ws, ".svelte-d", "wasm-ldc.json"), body);
  writeFileSync(join(ws, ".svelte-d", "ldc2-wasm.conf"), wasmLdcConfig(tc.libwasm));
}

function cellEnv(ws?: string): NodeJS.ProcessEnv {
  const env = { ...process.env };
  for (const key of ["DFLAGS", "DC", "DMD", "LDC", "LDC_FLAGS", "LDFLAGS"]) delete env[key];
  if (ws) env.DFLAGS = `-conf="${posix(join(ws, ".svelte-d", "ldc2-wasm.conf"))}"`;
  return env;
}

export function cachedWasmCell(ws: string, tc: Toolchain): WasmCellResult {
  const result: WasmCellResult = {
    status: 0, via: "skip", requested: false, reason: "optional LDC artifact unavailable; set G6B_DUB_WASM=1 to build",
    raw: join(ws, "public", "bios-ui-raw.wasm"), ship: join(ws, "public", "bios-ui.wasm"), log: "", artifact: "unavailable",
  };
  const manifest = join(ws, ".svelte-d", "wasm-artifact.json");
  if (!existsSync(result.ship) && !existsSync(manifest)) return result;
  try {
    const errors = runtimePreflight(tc);
    if (errors.length) throw new Error(errors.join("; "));
    const provenance: CellProvenance = JSON.parse(readFileSync(manifest, "utf8"));
    checkCellArtifact(readFileSync(result.ship), provenance, cellInputHash(ws, tc, provenance.buildType));
    result.artifact = "fresh";
    result.provenance = provenance;
    const asyncified = provenance.imports.includes("libwasm_await__void");
    result.reason = asyncified
      ? "verified cached asyncified LDC artifact (wasm EH + asyncify)"
      : "verified cached LDC component-shell artifact (not full Svelte tree)";
  } catch (error) {
    result.artifact = "stale";
    result.reason = String(error);
  }
  return result;
}

/** 0 = built/skipped, 2 = dub failed, 3 = LDC 1.43 missing. */
export function buildWasmCell(
  ws: string,
  tc: Toolchain,
  opts: { force?: boolean; buildType?: "debug" | "release"; asyncify?: boolean; run?: typeof spawnSync } = {},
): WasmCellResult {
  const raw = join(ws, "public", "bios-ui-raw.wasm");
  const ship = join(ws, "public", "bios-ui.wasm");
  const manifest = join(ws, ".svelte-d", "wasm-artifact.json");
  pinWasmLdc(ws, tc);
  mkdirSync(join(ws, "public"), { recursive: true });
  for (const file of [raw, ship, manifest]) rmSync(file, { force: true });
  const finish = (status: number, reason: string, log = reason, provenance?: CellProvenance): WasmCellResult => {
    const result: WasmCellResult = { status, via: "dub", requested: true, artifact: status === 0 ? "fresh" : "unavailable", reason, raw, ship, log, provenance };
    writeFileSync(join(ws, ".svelte-d", "wasm-build.json"), JSON.stringify(result, null, 2) + "\n");
    writeFileSync(join(ws, ".svelte-d", "wasm-build.log"), log);
    return result;
  };
  const svelteAwait = existsSync(join(ws, "src-svelte")) && readdirSync(join(ws, "src-svelte")).filter((name) => name.endsWith(".svelte")).some((name) => /\{#await\b/.test(readFileSync(join(ws, "src-svelte", name), "utf8")));
  if (svelteAwait) {
    return finish(3, "Svelte markup `{#await}` is not yet lowered to the libwasm D cell");
  }
  const dAwait = existsSync(join(ws, "src-d")) && readdirSync(join(ws, "src-d")).filter((name) => name.endsWith(".d")).some((name) => /\bawait\s*\(|libwasm_await__void/.test(readFileSync(join(ws, "src-d", name), "utf8")));
  const doAsyncify = opts.asyncify || process.env.G6B_WASM_ASYNCIFY === "1" || dAwait;
  if (doAsyncify && !tc.wasmOpt) {
    return finish(3, "wasm-opt required for asyncify; set SVELTE_D_WASM_OPT or add binaryen to PATH");
  }
  const errors = runtimePreflight(tc);
  if (errors.length) return finish(3, errors.join("; "));
  if (!existsSync(join(ws, "dub.sdl")) || readFileSync(join(ws, "dub.sdl"), "utf8") !== engineDubSdl(tc.libwasm)) {
    return finish(3, "generated dub.sdl does not match the pinned local libwasm cell");
  }
  // A `dub.selections.json` left over from an earlier libwasm location silently
  // overrides the path in dub.sdl: when browser-ui/libwasm was retired in favour
  // of the g6lc_bios/libwasm submodule, a stale selections file kept resolving
  // `libwasm` to `../libwasm` and dub then reported the `g6lc-bios`
  // configuration as non-existent. Selections are a lockfile for *registry*
  // versions and carry no information we need for an all-path graph, so a stale
  // one is dropped rather than trusted.
  const selections = join(ws, "dub.selections.json");
  if (existsSync(selections)) {
    let stale = true;
    try {
      const picked = JSON.parse(readFileSync(selections, "utf8"))?.versions?.libwasm?.path;
      stale = typeof picked !== "string" || posix(join(ws, picked)) !== posix(tc.libwasm);
    } catch {
      stale = true; // unparsable is stale by definition
    }
    if (stale) rmSync(selections, { force: true });
  }
  const buildType = opts.buildType ?? "release";
  const args = ["build", "--arch=wasm32-unknown-wasi", `--compiler=${tc.ldc}`, "--config=application", `--build=${buildType}`, "--force", "--verbose"];
  let log = `+ ${tc.dub} ${args.join(" ")}\n`;
  try {
    const inputs = cellInputHash(ws, tc, buildType);
    const r = (opts.run ?? spawnSync)(tc.dub, args, { cwd: ws, encoding: "utf8", shell: false, env: cellEnv(ws), maxBuffer: 32 * 1024 * 1024 });
    log += `${r.stdout || ""}${r.stderr || ""}${r.error || ""}`;
    if (r.status !== 0) return finish(2, `dub failed (status ${r.status}, signal ${r.signal})`, log);
    if (!existsSync(raw)) return finish(2, "dub succeeded without producing the requested raw artifact", log);
    if (cellInputHash(ws, tc, buildType) !== inputs) return finish(2, "build inputs changed during compilation; rebuild required", log);
    let bytes = readFileSync(raw);
    let imports = verifyLibwasmAbi(bytes, "app");
    if (doAsyncify) {
      const asyncifyArgs = ["--enable-bulk-memory", "--enable-exception-handling", "--enable-reference-types", "--asyncify", "--pass-arg=asyncify-imports@env.libwasm_await__void", raw, "-o", ship];
      log += `+ ${tc.wasmOpt} ${asyncifyArgs.join(" ")}\n`;
      const opt = runWasmOpt(tc.wasmOpt, asyncifyArgs, opts.run);
      log += `${opt.stdout || ""}${opt.stderr || ""}${opt.error || ""}`;
      if (opt.status !== 0) return finish(2, `wasm-opt --asyncify failed (status ${opt.status}, signal ${opt.signal})`, log);
      if (!existsSync(ship)) return finish(2, "wasm-opt succeeded without producing the requested artifact", log);
      bytes = readFileSync(ship);
    } else {
      writeFileSync(ship, bytes);
    }
    imports = verifyLibwasmAbi(bytes, "app");
    verifyLibwasmStartup(bytes);
    const provenance: CellProvenance = { schema: "g6lc-libwasm-artifact/v1", abi: LIBWASM_ABI, inputs, sha256: sha256(bytes), buildType, compiler: tc.versionLine, imports };
    if (doAsyncify) {
      const info = resolveWasmOpt();
      provenance.asyncifyTool = `${info.version || "unknown"} ${info.source}${info.forked ? " (fork)" : " (NOT the fork)"}`;
    }
    writeFileSync(manifest, JSON.stringify(provenance, null, 2) + "\n");
    return finish(0, doAsyncify ? "verified asyncified LDC artifact (wasm EH + asyncify)" : "verified LDC component-shell artifact (not full Svelte tree)", log, provenance);
  } catch (error) {
    rmSync(ship, { force: true });
    rmSync(manifest, { force: true });
    return finish(2, String(error), log + "\n" + String(error));
  }
}
