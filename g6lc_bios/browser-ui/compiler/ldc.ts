// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/**
 * LDC 1.43+ discovery — same rules as kernel-spec/svelte-d
 * `packages/svelte-d/ts/platform.ts` / `workspace/ldc.d`.
 * Never returns 1.36 / 1.41 / 1.42 (PATH on this host is 1.41).
 */
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

export const DEFAULT_LDC_VERSION = process.env.SVELTE_D_LDC_VERSION || "1.43.0-beta1";

export type HostTriple = {
  os: "windows" | "linux" | "osx";
  arch: "x64" | "arm64";
  exe: string;
};

export function hostTriple(
  platform = process.platform,
  arch = process.arch,
): HostTriple {
  const os = platform === "win32" ? "windows" : platform === "darwin" ? "osx" : "linux";
  const a: "x64" | "arm64" = arch === "arm64" ? "arm64" : "x64";
  const exe = os === "windows" ? "ldc2.exe" : "ldc2";
  return { os, arch: a, exe };
}

/** True when `--version` text is 1.43 or later (not 1.42 / 1.41 / 1.36). */
export function isLdc143Text(text: string): boolean {
  if (!text) return false;
  const first =
    text.split(/\r?\n/).find((l) => /LDC - the LLVM D compiler/i.test(l)) || text;
  const m = first.match(/\(([^)]+)\)/);
  const ver = m?.[1] ?? first;
  return /^1\.43\.\d+(?:[-+][\w.-]+)?$/.test(ver.trim());
}

export function isLdc143(bin: string): boolean {
  if (!bin || !existsSync(bin)) return false;
  const r = spawnSync(bin, ["--version"], { encoding: "utf8", shell: false });
  return r.status === 0 && isLdc143Text((r.stdout || "") + (r.stderr || ""));
}

function which(cmd: string): string {
  const r = spawnSync(process.platform === "win32" ? "where" : "which", [cmd], {
    encoding: "utf8",
    shell: false,
  });
  if (r.status !== 0) return "";
  return (
    (r.stdout || "")
      .split(/\r?\n/)
      .map((s) => s.trim())
      .find(Boolean) || ""
  );
}

export function toolchainHome(): string {
  const env = process.env.SVELTE_D_TOOLCHAINS;
  if (env) return env;
  return join(homedir(), ".svelte-d", "toolchains");
}

function scanToolchainDir(root: string, exe: string): string {
  if (!existsSync(root)) return "";
  let names: string[] = [];
  try {
    names = readdirSync(root);
  } catch {
    return "";
  }
  const prefer = names
    .filter((n) => /ldc2-(1\.43|1\.44|1\.45|master|build)/i.test(n))
    .sort()
    .reverse();
  for (const n of prefer) {
    const bin = join(root, n, "bin", exe);
    if (isLdc143(bin)) return bin;
  }
  return "";
}

function walkParents(start: string): string[] {
  const out: string[] = [];
  let p = resolve(start);
  for (let i = 0; i < 12; i++) {
    out.push(p);
    const parent = dirname(p);
    if (parent === p) break;
    p = parent;
  }
  return out;
}

/** Author + repo seeds (svelte-d `riscv-compilers/ldc2-build/bin`). */
export function ldcSeeds(start?: string): string[] {
  const seeds: string[] = [];
  const add = (s?: string) => {
    if (s && existsSync(s)) seeds.push(resolve(s));
  };
  add(start);
  add(process.cwd());
  add(process.env.RISCV_COMPILERS);
  add("E:\\cva6\\riscv-compilers");
  add("C:\\cva6\\riscv-compilers");
  for (const p of walkParents(start || process.cwd())) {
    add(join(p, "riscv-compilers"));
    add(p);
  }
  return [...new Set(seeds)];
}

/** LDC 1.43+ for the wasm-eh cell. Never returns 1.42/1.41. */
export function findLdc(start?: string): string {
  const exe = hostTriple().exe;
  for (const k of ["SVELTE_D_LDC", "LDC", "WASM_LDC", "SVELTE_D_WASM_LDC"]) {
    const v = process.env[k];
    if (v) return existsSync(v) && isLdc143(v) ? resolve(v) : "";
  }
  const dc = process.env.DC;
  if (dc && existsSync(dc) && isLdc143(dc)) return dc;
  const cached = scanToolchainDir(toolchainHome(), exe);
  if (cached) return cached;
  for (const seed of ldcSeeds(start)) {
    for (const rel of [join("ldc2-build", "bin"), join("bin")]) {
      const bin = join(seed, rel, exe);
      if (isLdc143(bin)) return bin;
    }
    const fromTc = scanToolchainDir(join(seed, "toolchains"), exe);
    if (fromTc) return fromTc;
  }
  const onPath = which("ldc2");
  if (onPath && isLdc143(onPath)) return onPath;
  return "";
}

export function findDub(ldc = findLdc()): string {
  const name = process.platform === "win32" ? "dub.exe" : "dub";
  if (ldc) {
    const cand = join(dirname(ldc), name);
    if (existsSync(cand)) return cand;
  }
  const seeds: string[] = [];
  const add = (p?: string) => {
    if (p && existsSync(p)) seeds.push(resolve(p));
  };
  add(process.env.SVELTE_D_DUB);
  if (ldc) {
    add(join(dirname(dirname(ldc)), "_tools", "dmd2", "windows", "bin"));
    add(join(dirname(dirname(ldc)), "_tools", "dmd2", "windows", "bin64"));
    add(join(dirname(dirname(ldc)), "toolchains"));
    add(join(dirname(ldc), "..", "toolchains"));
  }
  add("E:\\cva6\\riscv-dev\\_tools\\dmd2\\windows\\bin");
  add("E:\\cva6\\riscv-dev\\_tools\\dmd2\\windows\\bin64");
  add("E:\\cva6\\riscv-dev\\toolchains");
  add("E:\\cva6\\riscv-dev");
  for (const seed of [...new Set(seeds)]) {
    for (const rel of ["", "bin", "bin64"]) {
      const cand = join(seed, rel, name);
      if (existsSync(cand)) return cand;
    }
    try {
      for (const entry of readdirSync(seed)) {
        if (/dub|dmd|ldc/i.test(entry)) {
          for (const rel of ["", "bin", "bin64"]) {
            const cand = join(seed, entry, rel, name);
            if (existsSync(cand)) return cand;
          }
        }
      }
    } catch {
      // not a directory or unreadable
    }
  }
  return which("dub");
}

function isLibwasmRoot(p: string): boolean {
  return existsSync(join(p, "source", "libwasm", "dom.d")) && existsSync(join(p, "dub.sdl"));
}

/** Spec checkout only (kernel-spec/libwasm). Never a DUB cache tree. */
export function findLibwasmCheckout(start?: string): string {
  const env = process.env.LIBWASM_ROOT;
  if (env) return isLibwasmRoot(env) ? resolve(env) : "";
  for (const seed of ldcSeeds(start)) {
    for (const cand of [
      join(seed, "libwasm"),
      join(seed, "browser-ui", "libwasm"),
      join(seed, "g6lc_bios", "browser-ui", "libwasm"),
      join(seed, "riscv-compilers", "libwasm"),
    ]) {
      if (isLibwasmRoot(cand)) return cand;
    }
  }
  return "";
}

const CUSTOM_BINARYEN = "C:\\Users\\etcim\\.grok\\worktrees\\cva6\\svelte-dev-2\\riscv-dev\\svelte-D\\binaryen";

export function findWasmOpt(start?: string): string {
  const windowsNames = ["wasm-opt.exe", "wasm-opt"];
  const names = process.platform === "win32" ? windowsNames : ["wasm-opt"];
  for (const k of ["SVELTE_D_WASM_OPT", "WASM_OPT"]) {
    const v = process.env[k];
    if (v && existsSync(v)) return v;
  }
  const seeds = [...ldcSeeds(start), CUSTOM_BINARYEN];
  const rels = [
    join("build", "bin"),
    join("binaryen-build", "bin"),
    join("toolchains", "binaryen-svelte-d", "bin"),
    join("bin"),
    "",
  ];
  for (const seed of [...new Set(seeds)]) {
    for (const rel of rels) {
      for (const name of names) {
        const cand = join(seed, rel, name);
        if (existsSync(cand)) return cand;
      }
    }
  }
  return which("wasm-opt");
}

export type Toolchain = {
  ldc: string;
  dub: string;
  libwasm: string;
  wasmOpt: string;
  versionLine: string;
  ok: boolean;
};

export function runtimePreflight(tc: Toolchain): string[] {
  const errors: string[] = [];
  if (!tc.ok || !tc.ldc || !tc.dub || !isLdc143Text(tc.versionLine)) {
    errors.push("LDC 1.43 and dub are required for runtime-v1.43.0 (DMD 2.113)");
  }
  if (!tc.libwasm || /(?:^|[\\/])(?:kernel-spec|riscv-compilers)(?:[\\/]|$)/i.test(tc.libwasm)) {
    errors.push("LIBWASM_ROOT must select the local browser-ui/libwasm adaptation, not a spec/toolchain checkout");
    return errors;
  }
  const requireText = (rel: string, patterns: RegExp[]) => {
    const file = join(tc.libwasm, rel);
    if (!existsSync(file)) {
      errors.push(`missing carried runtime/dependency: ${file}`);
      return;
    }
    const text = readFileSync(file, "utf8");
    if (patterns.some((pattern) => !pattern.test(text))) errors.push(`incompatible carried runtime configuration: ${file}`);
  };
  requireText("dub.sdl", [/configuration\s+"ldc-master"\s*\{[^}]*dependency\s+"druntime-wasm-143"\s+path="\.\/runtime-v1\.43\.0"/s, /"-defaultlib="/]);
  requireText("source/libwasm/g6b_kernel.d", [/module libwasm\.g6b_kernel;/]);
  requireText("runtime-v1.43.0/dub.sdl", [/name\s+"druntime-wasm-143"/, /version\s+"1\.43\.0"/, /versions\s+"CRuntime_LIBWASM"/, /targetType\s+"sourceLibrary"/]);
  requireText("runtime-v1.43.0/object.d", [/version\s*\(CRuntime_LIBWASM\)/]);
  for (const rel of ["core/exception.d", "core/memory.d", "ldc/attributes.d", "std/format/package.d", "rt/lifetime.d"]) {
    requireText(`runtime-v1.43.0/${rel}`, []);
  }
  for (const name of ["memutils-wasm", "fast-wasm", "optional-wasm"]) {
    requireText(`${name}/dub.sdl`, [/configuration\s+"ldc-master"\s*\{[^}]*importPaths\s+"\.\.\/runtime-v1\.43\.0\/?"/s]);
  }
  requireText("diet-wasm/dub.sdl", [/name\s+"diet-wasm"/]);
  const time = join(tc.libwasm, "runtime-v1.43.0/core/stdc/time.d");
  requireText("runtime-v1.43.0/core/stdc/time.d", []);
  requireText("runtime-v1.43.0/core/sys/wasi/time.d", []);
  if (existsSync(time)) {
    const body = readFileSync(time, "utf8");
    const posixFirst = /version\s*\(Posix\)/.exec(body)?.index ?? -1;
    const localFirst = /version\s*\(CRuntime_LIBWASM\)/.exec(body)?.index ?? Infinity;
    const wasiFirst = /version\s*\(WASI\)/.exec(body)?.index ?? Infinity;
    if (posixFirst >= 0 && posixFirst < Math.min(localFirst, wasiFirst) && !existsSync(join(tc.libwasm, "runtime-v1.43.0/core/sys/posix/stdc/time.d"))) {
      errors.push("incomplete runtime-v1.43.0: core.stdc.time selects Posix before WASI but core/sys/posix/stdc/time.d is missing; repair the carried CRuntime_LIBWASM time selection (no stock imports)");
    }
  }
  return errors;
}

export function wasmLdcConfig(libwasm: string): string {
  const runtime = JSON.stringify("-I" + join(libwasm, "runtime-v1.43.0").replace(/\\/g, "/"));
  return `default:\n{\n    switches = [ "-mtriple=wasm32-unknown-wasi", "-defaultlib=", "-d-version=CRuntime_LIBWASM", "-d-version=G6LC_G6B", "-fno-moduleinfo", "-mattr=+exception-handling", "--wasm-enable-eh", "-link-internally", "--foptimize-nothrow=false", "-L-z", "-Lstack-size=1048576", "-L--stack-first" ];\n    post-switches = [ ${runtime} ];\n    lib-dirs = [];\n};\n`;
}

export function resolveToolchain(start?: string): Toolchain {
  const ldc = findLdc(start);
  let versionLine = "";
  if (ldc) {
    const r = spawnSync(ldc, ["--version"], { encoding: "utf8", shell: false });
    versionLine =
      ((r.stdout || "") + (r.stderr || ""))
        .split(/\r?\n/)
        .find((l) => /LDC - the LLVM D compiler/i.test(l)) || "";
  }
  const dub = findDub(ldc);
  const libwasm = findLibwasmCheckout(start);
  const wasmOpt = findWasmOpt(start);
  return {
    ldc,
    dub,
    libwasm,
    wasmOpt,
    versionLine,
    ok: Boolean(ldc && dub && isLdc143(ldc)),
  };
}
