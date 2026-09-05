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
import { createLibwasmHost } from "../src/kernel.ts";

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
    __cpp_exception: "127->",
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
    get childNodes() { return this.children; }
    set textContent(_: string) { this.replaceChildren(); }
    contains(node: Element): boolean { return this === node || this.children.some((child) => child.contains(node)); }
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
  const host = createLibwasmHost({ createElement: () => new Element() }, mount);
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

/** Engine `dub.sdl` (wasm-eh / ldc-master), BIOS target names. */
export function engineDubSdl(libwasm: string): string {
  const lib = `dependency "libwasm" path=${JSON.stringify(posix(libwasm || "../libwasm"))}\n`;
  return `name "svelte-engine"
description "BIOS-UI wasm cell: libwasm SPA (svelte-d fall-through). Not vibe.0."
authors "Etienne Cimon"
copyright "Copyright © 2026, Etienne Cimon"
license "MIT"
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
    lflags "--export=_start" "--export=allocString" "--export=__heap_base" "--export=g6b_fx_data" "--export=g6b_fx_count" "--export=g6b_fx_step" "--export=g6b_fx_logo"
    ${lib}    subConfiguration "libwasm" "ldc-master"
}

configuration "ldc-master" {
    targetType "executable"
    dflags "-link-internally" "-defaultlib=" "--foptimize-nothrow=false"
    lflags "--export=_start" "--export=allocString" "--export=__heap_base" "--export=g6b_fx_data" "--export=g6b_fx_count" "--export=g6b_fx_step" "--export=g6b_fx_logo"
    ${lib}    subConfiguration "libwasm" "ldc-master"
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
    result.reason = "verified cached LDC component-shell artifact (not full Svelte tree)";
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
  const awaitSource = existsSync(join(ws, "src-svelte")) && readdirSync(join(ws, "src-svelte")).filter((name) => name.endsWith(".svelte")).some((name) => /\{#await\b|\bawait\s/.test(readFileSync(join(ws, "src-svelte", name), "utf8")));
  if (opts.asyncify || process.env.G6B_WASM_ASYNCIFY === "1" || awaitSource) {
    return finish(3, "Asyncify with wasm EH is unverified; nonblocking await transformation is unavailable");
  }
  const errors = runtimePreflight(tc);
  if (errors.length) return finish(3, errors.join("; "));
  if (!existsSync(join(ws, "dub.sdl")) || readFileSync(join(ws, "dub.sdl"), "utf8") !== engineDubSdl(tc.libwasm)) {
    return finish(3, "generated dub.sdl does not match the pinned local libwasm cell");
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
    const bytes = readFileSync(raw);
    const imports = verifyLibwasmAbi(bytes);
    verifyLibwasmStartup(bytes);
    const provenance: CellProvenance = { schema: "g6lc-libwasm-artifact/v1", abi: LIBWASM_ABI, inputs, sha256: sha256(bytes), buildType, compiler: tc.versionLine, imports };
    writeFileSync(ship, bytes);
    writeFileSync(manifest, JSON.stringify(provenance, null, 2) + "\n");
    return finish(0, "verified LDC component-shell artifact (not full Svelte tree)", log, provenance);
  } catch (error) {
    rmSync(ship, { force: true });
    rmSync(manifest, { force: true });
    return finish(2, String(error), log + "\n" + String(error));
  }
}
