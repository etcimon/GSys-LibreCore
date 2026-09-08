// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { dropWorkspace } from "./drop-ws.ts";
import { compileProject, WasmBuildError, writeOut } from "./index.ts";
import { findPinnedLdc, hostTriple, isLdc143Text, resolveToolchain, runtimePreflight, wasmLdcConfig, type Toolchain } from "./ldc.ts";
import { downloadUrl, isPinnedLdcText, pinnedAsset, pinnedLdcBin, readPin, toolchainsDir } from "./ldc-pin.ts";
import { parseSvelte } from "./parse.ts";
import { childFieldName, printApp, printFxD, printModule } from "./print-d.ts";
import { buildWasmCell, cachedWasmCell, checkCellArtifact, engineDubSdl, LIBWASM_ABI, pinWasmLdc, sha256, verifyLibwasmAbi } from "./wasm-cell.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const temp: string[] = [];
afterEach(() => { for (const dir of temp.splice(0)) rmSync(dir, { recursive: true, force: true }); });
const put = (file: string, text = "") => { mkdirSync(dirname(file), { recursive: true }); writeFileSync(file, text); };
const app = () => parseSvelte("src/App.svelte", '<p id="status">ready</p>');

function fixture() {
  const dir = mkdtempSync(join(tmpdir(), "g6lc-build-"));
  temp.push(dir);
  const lib = join(dir, "libwasm");
  put(join(lib, "dub.sdl"), 'configuration "ldc-master" { dependency "druntime-wasm-143" path="./runtime-v1.43.0" dflags "-defaultlib=" }');
  put(join(lib, "source/libwasm/g6b_kernel.d"), "module libwasm.g6b_kernel;");
  put(join(lib, "source/libwasm/dom.d"), "module libwasm.dom;");
  put(join(lib, "runtime-v1.43.0/dub.sdl"), 'name "druntime-wasm-143"\nversion "1.43.0"\nversions "CRuntime_LIBWASM"\ntargetType "sourceLibrary"');
  put(join(lib, "runtime-v1.43.0/object.d"), "version (CRuntime_LIBWASM) {}");
  for (const name of ["core/exception.d", "core/memory.d", "core/stdc/time.d", "core/sys/wasi/time.d", "ldc/attributes.d", "std/format/package.d", "rt/lifetime.d", "etc/stub.d"]) put(join(lib, "runtime-v1.43.0", name));
  for (const name of ["memutils-wasm", "fast-wasm", "optional-wasm", "diet-wasm"]) {
    put(join(lib, name, "dub.sdl"), `name "${name}"\nconfiguration "ldc-master" { importPaths "../runtime-v1.43.0" }`);
    put(join(lib, name, "source/package.d"));
  }
  put(join(dir, "ldc"), "test compiler");
  put(join(dir, "dub"), "test dub");
  put(join(dir, "src/App.svelte"), app().src);
  put(join(dir, "src/kernel.ts"), "export function createBrowserApp() {}\n");
  put(join(dir, "src/worker.ts"), "export function executeComputeJob() {}\n");
  const tc: Toolchain = { ldc: join(dir, "ldc"), dub: join(dir, "dub"), libwasm: lib, wasmOpt: "", ok: true, versionLine: "LDC - the LLVM D compiler (1.43.0-git-test):" };
  const { ws } = dropWorkspace(dir, [app()], lib);
  pinWasmLdc(ws, tc);
  return { dir, ws, tc };
}

function abiFixture(importName = "createElement", importParam = 0x7f, stepParam = 0x7d, trap = false) {
  const u = (value: number): number[] => value < 128 ? [value] : [(value & 127) | 128, ...u(Math.floor(value / 128))];
  const text = (value: string) => [...u(value.length), ...new TextEncoder().encode(value)];
  const section = (id: number, data: number[]) => [id, ...u(data.length), ...data];
  const type = (params: number[], results: number[]) => [0x60, ...u(params.length), ...params, ...u(results.length), ...results];
  const entry = (name: string, kind: number, index: number) => [...text(name), kind, ...u(index)];
  const body = (ops: number[]) => { const bytes = [0, ...ops, 0x0b]; return [...u(bytes.length), ...bytes]; };
  return new Uint8Array([
    0, 97, 115, 109, 1, 0, 0, 0,
    ...section(1, [6, ...type([0x7f], []), ...type([0x7f], [0x7f]), ...type([], [0x7f]), ...type([stepParam], []), ...type([importParam], [0x7f]), ...type([0x7f, 0x7f], [])]),
    ...section(2, [2, ...text("env"), ...text(importName), 0, 4, ...text("env"), ...text("appendChild"), 0, 5]),
    ...section(3, [6, 0, 1, 2, 2, 2, 3]),
    ...section(5, [1, 0, 1]),
    ...section(6, [1, 0x7f, 0, 0x41, 0x80, 0x80, 1, 0x0b]),
    ...section(7, [8, ...entry("_start", 0, 2), ...entry("allocString", 0, 3), ...entry("g6b_fx_data", 0, 4), ...entry("g6b_fx_count", 0, 5), ...entry("g6b_fx_logo", 0, 6), ...entry("g6b_fx_step", 0, 7), ...entry("memory", 2, 0), ...entry("__heap_base", 3, 0)]),
    ...section(10, [6, ...body(trap ? [0] : [0x41, 1, ...(importParam === 0x7f ? [0x41, 26] : [0x43, 0, 0, 0, 0]), 0x10, 0, 0x10, 1]), ...body([0x41, 0]), ...body([0x41, 0]), ...body([0x41, 0x80, 2]), ...body([0x41, 0]), ...body([])]),
  ]);
}

function runResult(status: number, action = () => {}) {
  return ((...args: any[]) => { action(); return { status, signal: null, stdout: "test dub", stderr: "", pid: 0, output: [] }; }) as any;
}

describe("LDC pin", () => {
  test("the lock names one upstream release with a usable digest per host", () => {
    const pin = readPin(root);
    expect(pin.schema).toBe("g6lc-ldc-pin/v1");
    expect(pin.version).toBe("1.43.0-beta1");
    expect(pin.tag).toBe("v1.43.0-beta1");
    expect(pin.repository).toBe("https://github.com/ldc-developers/ldc");
    // The carried runtime is runtime-v1.43.0 / DMD 2.113; the pin must agree.
    expect(pin.frontend).toBe("2.113.0");
    for (const triple of ["windows-x64", "linux-x64", "linux-arm64", "osx-x64", "osx-arm64"]) {
      const asset = pinnedAsset(triple, root);
      expect(asset.sha256).toMatch(/^[0-9a-f]{64}$/);
      expect(asset.file).toContain("1.43.0-beta1");
      expect(asset.bytes).toBeGreaterThan(0);
      // Every download is an upstream release asset for the pinned tag only.
      expect(downloadUrl(asset, pin)).toBe(
        `https://github.com/ldc-developers/ldc/releases/download/v1.43.0-beta1/${asset.file}`,
      );
    }
    // A host with no published build is refused, not silently downgraded.
    expect(() => pinnedAsset("windows-arm64", root)).toThrow(/publishes no windows-arm64/);
    expect(() => pinnedAsset("plan9-x64", root)).toThrow();
  });

  test("only the pinned version text counts as the pin", () => {
    expect(isPinnedLdcText("LDC - the LLVM D compiler (1.43.0-beta1):", root)).toBe(true);
    // An ambient 1.43 passes isLdc143Text but is NOT the pin: the cell's
    // provenance hash covers the compiler binary, so it is a different build.
    for (const line of [
      "LDC - the LLVM D compiler (1.43.0-git-1218a47):",
      "LDC - the LLVM D compiler (1.43.0):",
      "LDC - the LLVM D compiler (1.42.0):",
      "",
    ]) {
      expect(isPinnedLdcText(line, root)).toBe(false);
    }
    expect(isLdc143Text("LDC - the LLVM D compiler (1.43.0-beta1):")).toBe(true);
  });

  test("a lock that is not a 1.43 upstream release is refused", () => {
    const dir = mkdtempSync(join(tmpdir(), "g6lc-pin-"));
    temp.push(dir);
    const base = readPin(root);
    const write = (patch: Record<string, unknown>) =>
      put(join(dir, "toolchains", "ldc.lock.json"), JSON.stringify({ ...base, ...patch }));
    write({ schema: "g6lc-ldc-pin/v2" });
    expect(() => readPin(dir)).toThrow(/schema/);
    write({ version: "1.42.0", tag: "v1.42.0" });
    expect(() => readPin(dir)).toThrow(/not a 1\.43 release/);
    write({ tag: "v1.43.0" });
    expect(() => readPin(dir)).toThrow(/tag does not match/);
    write({ repository: "https://github.com/attacker/ldc" });
    expect(() => readPin(dir)).toThrow(/upstream ldc-developers\/ldc/);
    write({ assets: { "linux-x64": { ...base.assets["linux-x64"], sha256: "nope" } } });
    expect(() => readPin(dir)).toThrow(/SHA-256/);
    write({ assets: { "linux-x64": { ...base.assets["linux-x64"], file: "ldc2-1.42.0-linux-x86_64.tar.xz" } } });
    expect(() => readPin(dir)).toThrow(/not from 1\.43\.0-beta1/);
    rmSync(join(dir, "toolchains", "ldc.lock.json"));
    expect(() => readPin(dir)).toThrow(/missing LDC pin/);
  });

  test("the pin is installed under browser-ui/toolchains and wins over ambient 1.43", () => {
    const triple = hostTriple();
    const expected = pinnedLdcBin(`${triple.os}-${triple.arch}`, triple.exe, root);
    expect(expected.startsWith(toolchainsDir(root))).toBe(true);
    const pinned = findPinnedLdc(root);
    if (!pinned) return; // not installed on this host; `bun run install-ldc`
    expect(pinned).toBe(expected);
    const tc = resolveToolchain(root);
    expect(tc.ldc).toBe(expected);
    expect(tc.pinned).toBe(true);
    expect(isPinnedLdcText(tc.versionLine, root)).toBe(true);
    // The release bundles dub, so the cell never mixes a foreign dub/LDC pair.
    expect(dirname(tc.dub)).toBe(dirname(expected));
  });
});

describe("LDC build integrity", () => {
  test("Main cannot shadow Spa.main and colliding child fields are rejected", () => {
    const main = parseSvelte("src/Main.svelte", '<p id="main">main</p>');
    const source = printApp([app(), main]);
    expect(childFieldName("Main")).toBe("mainChild");
    expect(source).toContain("@child Main mainChild;");
    expect(source.match(/mixin Spa!App;/g)?.length).toBe(1);
    expect(() => printApp([app(), parseSvelte("src/Spa.svelte", '<p id="spa">spa</p>')])).toThrow(/reserved/);
    expect(() => printApp([app(), main, parseSvelte("src/MainChild.svelte", '<p id="mc">mc</p>')])).toThrow(/collision/);
    expect(() => printModule(parseSvelte("src/Bad.svelte", '<script>let main = "x";</script><p id="b">{main}</p>'))).toThrow(/collision/);
  });

  test("only the matching 1.43 runtime/compiler pair is accepted", () => {
    expect(isLdc143Text("LDC - the LLVM D compiler (1.43.0-git-1218a47):")).toBe(true);
    for (const version of ["1.36.0", "1.41.0", "1.42.0", "1.44.0", "1.430.0"]) expect(isLdc143Text(`LDC - the LLVM D compiler (${version}):`)).toBe(false);
    const { tc } = fixture();
    expect(runtimePreflight(tc)).toEqual([]);
    const config = wasmLdcConfig(tc.libwasm);
    expect(config).toContain("-defaultlib=");
    expect(config).toContain("-mtriple=wasm32-unknown-wasi");
    expect(config).not.toContain("riscv-compilers");
    expect(engineDubSdl("")).not.toContain("repository=");
    put(join(tc.libwasm, "runtime-v1.43.0/core/stdc/time.d"), "version (Posix) public import core.sys.posix.stdc.time; else version (WASI) public import core.sys.wasi.time;");
    expect(runtimePreflight(tc).join("\n")).toContain("selects Posix before WASI");
    put(join(tc.libwasm, "runtime-v1.43.0/core/stdc/time.d"), "version (CRuntime_LIBWASM) public import core.sys.wasi.time; else version (Posix) public import core.sys.posix.stdc.time;");
    expect(runtimePreflight(tc)).toEqual([]);
    rmSync(join(tc.libwasm, "runtime-v1.43.0/object.d"));
    expect(runtimePreflight(tc).join("\n")).toContain("missing carried runtime");
  });

  test("missing runtime, failed dub and missing new output never reuse old artifacts", () => {
    for (const mode of ["runtime", "failure", "no-output", "asyncify", "await-source"]) {
      const { ws, tc } = fixture();
      put(join(ws, "public/bios-ui.wasm"), "old");
      put(join(ws, "public/bios-ui-raw.wasm"), "old");
      put(join(ws, ".svelte-d/wasm-artifact.json"), "{}");
      if (mode === "runtime") rmSync(join(tc.libwasm, "runtime-v1.43.0/object.d"));
      if (mode === "await-source") put(join(ws, "src-svelte/App.svelte"), "{#await unsupported}pending{/await}");
      let called = false;
      const result = buildWasmCell(ws, tc, { asyncify: mode === "asyncify", run: runResult(mode === "failure" ? 7 : 0, () => { called = true; }) });
      expect(result.status).not.toBe(0);
      expect(result.requested).toBe(true);
      expect(result.artifact).toBe("unavailable");
      expect(existsSync(result.ship)).toBe(false);
      expect(called).toBe(mode === "failure" || mode === "no-output");
    }
  });

  test("verified artifact requires matching content hash, exact ABI and fresh inputs", () => {
    const { ws, tc } = fixture();
    const bytes = abiFixture();
    expect(verifyLibwasmAbi(bytes)).toEqual(["appendChild", "createElement"]);
    for (const invalid of [abiFixture("snprintf"), abiFixture("createElement", 0x7d), abiFixture("createElement", 0x7f, 0x7f)]) {
      expect(() => verifyLibwasmAbi(invalid)).toThrow(/import|export/);
    }
    const built = buildWasmCell(ws, tc, { run: runResult(0, () => writeFileSync(join(ws, "public/bios-ui-raw.wasm"), bytes)) });
    expect(built.status).toBe(0);
    expect(built.provenance?.abi).toBe(LIBWASM_ABI);
    expect(cachedWasmCell(ws, tc).artifact).toBe("fresh");
    expect(() => checkCellArtifact(bytes, { ...built.provenance!, sha256: "wrong" }, built.provenance!.inputs)).toThrow(/hash mismatch/);
    expect(() => checkCellArtifact(bytes, built.provenance!, "changed")).toThrow(/stale/);
    put(built.ship, "tampered artifact");
    expect(cachedWasmCell(ws, tc).reason).toContain("hash mismatch");
    writeFileSync(built.ship, bytes);
    put(join(ws, "src-d/app.d"), "changed source");
    expect(cachedWasmCell(ws, tc).artifact).toBe("stale");
  });

  test("an ABI-correct module that traps at startup is never published", () => {
    const { ws, tc } = fixture();
    const bytes = abiFixture("createElement", 0x7f, 0x7d, true);
    expect(() => verifyLibwasmAbi(bytes)).not.toThrow();
    const result = buildWasmCell(ws, tc, { run: runResult(0, () => writeFileSync(join(ws, "public/bios-ui-raw.wasm"), bytes)) });
    expect(result.status).toBe(2);
    expect(result.artifact).toBe("unavailable");
    expect(existsSync(result.ship)).toBe(false);
  });

  test("removed generated components do not remain in the next D link set", () => {
    const { dir, ws, tc } = fixture();
    const old = parseSvelte("src/Old.svelte", '<p id="old">old</p>');
    dropWorkspace(dir, [app(), old], tc.libwasm);
    expect(existsSync(join(ws, "src-d/old.d"))).toBe(true);
    dropWorkspace(dir, [app()], tc.libwasm);
    expect(existsSync(join(ws, "src-d/old.d"))).toBe(false);
  });

  test("requested compile failure throws and invalidates shipped optional bytes", () => {
    const { dir, tc } = fixture();
    put(join(dir, "out/bios-ui-libwasm.wasm"), "stale");
    const previous = { ldc: process.env.SVELTE_D_LDC, lib: process.env.LIBWASM_ROOT };
    try {
      process.env.SVELTE_D_LDC = join(dir, "missing-ldc");
      process.env.LIBWASM_ROOT = tc.libwasm;
      expect(() => compileProject(dir, { dub: true })).toThrow(WasmBuildError);
      expect(readFileSync(join(dir, "out/bios-ui-libwasm.wasm")).length).toBe(0);
    } finally {
      if (previous.ldc === undefined) delete process.env.SVELTE_D_LDC; else process.env.SVELTE_D_LDC = previous.ldc;
      if (previous.lib === undefined) delete process.env.LIBWASM_ROOT; else process.env.LIBWASM_ROOT = previous.lib;
    }
  });

  test("non-DUB output labels absent/stale artifact rather than preserving shipped bytes", () => {
    const { dir } = fixture();
    put(join(dir, "out/bios-ui-libwasm.wasm"), "stale");
    writeOut(dir, { files: [app()], wasm: new Uint8Array(), js: "", catalog: "{}", wsFiles: [] });
    expect(readFileSync(join(dir, "out/bios-ui-libwasm.wasm")).length).toBe(0);
    expect(JSON.parse(readFileSync(join(dir, "out/bios-ui-libwasm.json"), "utf8")).available).toBe(false);
    expect(JSON.parse(readFileSync(join(dir, "out/build.json"), "utf8")).files["bios-ui-libwasm.wasm"]).toBe(sha256(new Uint8Array()));
  });
});

const realFxTest = process.env.G6B_TEST_LDC_FX === "1" ? test : test.skip;
const fullCellTest = process.env.G6B_TEST_LDC_CELL === "1" ? test : test.skip;
fullCellTest("actual full LDC cell starts with the explicit DOM ABI", () => {
  const bytes = readFileSync(join(root, "svelte-engine-ws/public/bios-ui.wasm"));
  const imports = verifyLibwasmAbi(bytes);
  // verifyLibwasmAbi already refuses any import outside the declared ABI, so
  // the list is checked for the shell's own boundary rather than frozen: the
  // set tracks what App.svelte declares, and did grow when the BIOS endpoint
  // and HolyC operations landed.
  expect(imports).toContain("__cpp_exception");
  expect(imports).toEqual([...imports].sort());
  for (const name of ["fetch", "holyc", "register_endpoint"]) expect(imports).toContain(name);
  // The published artifact must be the one the pinned compiler produced.
  const provenance = JSON.parse(readFileSync(join(root, "svelte-engine-ws/.svelte-d/wasm-artifact.json"), "utf8"));
  expect(provenance.imports).toEqual(imports);
  expect(provenance.sha256).toBe(sha256(bytes));
  expect(isPinnedLdcText(provenance.compiler, root)).toBe(true);
  exerciseFx(bytes);
});
realFxTest("isolated generated D particle code compiles with LDC and remains finite, bounded and deterministic", () => {
  const { dir } = fixture();
  const tc = resolveToolchain(root);
  expect(tc.ok).toBe(true);
  const source = join(dir, "fx.d");
  const binary = join(dir, "fx.wasm");
  const config = join(dir, "ldc2-wasm.conf");
  put(source, "module fx;\nnothrow:\n@safe:\n" + printFxD());
  put(config, wasmLdcConfig(tc.libwasm));
  const env = { ...process.env };
  for (const key of ["DFLAGS", "DC", "DMD", "LDC", "LDC_FLAGS", "LDFLAGS"]) delete env[key];
  const args = [`-conf=${config}`, "-mtriple=wasm32-unknown-wasi", "-O3", "-release", "-L--no-entry", "-L--export=__heap_base", ...["g6b_fx_data", "g6b_fx_count", "g6b_fx_step", "g6b_fx_logo"].map((name) => "-L--export=" + name), `-of=${binary}`, source];
  const result = spawnSync(tc.ldc, args, { cwd: dir, encoding: "utf8", shell: false, env });
  if (result.status !== 0) throw new Error(`LDC particle probe failed: ${result.stdout}${result.stderr}${result.error || ""}`);
  const bytes = readFileSync(binary);
  expect(verifyLibwasmAbi(bytes, "fx-probe")).toEqual([]);
  exerciseFx(bytes);
});

function exerciseFx(bytes: Uint8Array) {
  const module = new WebAssembly.Module(bytes);
  // The particle lane must run with every declared import inert, so the stub
  // is derived from the module rather than hand-listed: a new DOM/kernel
  // import must not silently turn this into a link error instead of a test.
  const create = () => {
    let handle = 1;
    const env: Record<string, unknown> = {};
    for (const entry of WebAssembly.Module.imports(module)) {
      if (entry.module !== "env") throw new Error(`unexpected import module ${entry.module}`);
      env[entry.name] = entry.kind === "tag"
        ? new WebAssembly.Tag({ parameters: ["i32"] })
        : () => (entry.name === "createElement" ? ++handle : 0);
    }
    const instance = new WebAssembly.Instance(module, { env });
    const e = instance.exports as any;
    if (e._start) e._start(e.__heap_base.value);
    e.g6b_fx_step(0);
    expect(e.g6b_fx_count()).toBe(256);
    const state = new Float32Array(e.memory.buffer, e.g6b_fx_data(), 256 * 4);
    const logo = new Float32Array(e.memory.buffer, e.g6b_fx_logo(), 2);
    return { e, state, logo };
  };
  const a = create();
  const b = create();
  expect([...a.state]).toEqual([...b.state]);
  const before = [...a.state];
  for (const dt of [NaN, -Infinity, -1, 0]) a.e.g6b_fx_step(dt);
  expect([...a.state]).toEqual(before);
  a.e.g6b_fx_step(Infinity);
  b.e.g6b_fx_step(0.05);
  expect([...a.state]).toEqual([...b.state]);
  expect([...a.state]).not.toEqual(before);
  expect([...a.logo]).not.toEqual([0, 0]);
  const bounds = () => {
    expect([...a.state, ...a.logo].every(Number.isFinite)).toBe(true);
    for (let i = 0; i < 256; i++) {
      expect(Math.abs(a.state[i * 4])).toBeLessThanOrEqual(1);
      expect(Math.abs(a.state[i * 4 + 1])).toBeLessThanOrEqual(1);
      expect(a.state[i * 4 + 2]).toBeGreaterThanOrEqual(0.1);
      expect(a.state[i * 4 + 2]).toBeLessThanOrEqual(1);
      expect(a.state[i * 4 + 3]).toBeGreaterThanOrEqual(2);
      expect(a.state[i * 4 + 3]).toBeLessThanOrEqual(10);
    }
    expect(Math.abs(a.logo[0])).toBeLessThanOrEqual(0.761);
    expect(Math.abs(a.logo[1])).toBeLessThanOrEqual(0.781);
  };
  for (let frame = 0; frame < 12000; frame++) { a.e.g6b_fx_step(1 / 60); if (frame % 120 === 0) bounds(); }
  bounds();
}
