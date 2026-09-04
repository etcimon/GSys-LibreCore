// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/**
 * LDC 1.43+ discovery — same rules as kernel-spec/svelte-d
 * `packages/svelte-d/ts/platform.ts` / `workspace/ldc.d`.
 * Never returns 1.36 / 1.41 / 1.42 (PATH on this host is 1.41).
 */
import { existsSync, readdirSync } from "node:fs";
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
  if (/1\.(36|40|41|42)\./.test(ver)) return false;
  return /1\.(43|44|45|46)/.test(ver);
}

export function isLdc143(bin: string): boolean {
  if (!bin || !existsSync(bin)) return false;
  const r = spawnSync(bin, ["--version"], { encoding: "utf8", shell: false });
  return isLdc143Text((r.stdout || "") + (r.stderr || ""));
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
    if (v && existsSync(v) && isLdc143(v)) return v;
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
  if (ldc) {
    const name = process.platform === "win32" ? "dub.exe" : "dub";
    const cand = join(dirname(ldc), name);
    if (existsSync(cand)) return cand;
  }
  return which("dub");
}

function isLibwasmRoot(p: string): boolean {
  return existsSync(join(p, "source", "libwasm", "dom.d")) && existsSync(join(p, "dub.sdl"));
}

/** Spec checkout only (kernel-spec/libwasm). Never a DUB cache tree. */
export function findLibwasmCheckout(start?: string): string {
  const env = process.env.LIBWASM_ROOT;
  if (env && isLibwasmRoot(env)) return resolve(env);
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

export function findWasmOpt(start?: string): string {
  const exe = process.platform === "win32" ? "wasm-opt.exe" : "wasm-opt";
  for (const k of ["SVELTE_D_WASM_OPT", "WASM_OPT"]) {
    const v = process.env[k];
    if (v && existsSync(v)) return v;
  }
  for (const seed of ldcSeeds(start)) {
    for (const rel of [
      join("binaryen-build", "bin", exe),
      join("toolchains", "binaryen-svelte-d", "bin", exe),
    ]) {
      const cand = join(seed, rel);
      if (existsSync(cand)) return cand;
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
