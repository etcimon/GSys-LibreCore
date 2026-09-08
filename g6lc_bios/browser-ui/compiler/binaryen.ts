// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/**
 * `wasm-opt` provider for the asyncify pass, backed by the **svelte-d
 * submodule** (`g6lc_bios/svelte-d`) and its nested `binaryen/` fork.
 *
 * Why a fork is required rather than preferred: stock Binaryen (123 / 132)
 * cannot `--asyncify` a module containing `try_table`, which is exactly what
 * LDC 1.43 emits for wasm-eh. The `etcimon/binaryen` `svelte-d` branch adds the
 * Flatten pass that makes `try_table` asyncifiable. A stock `wasm-opt` on PATH
 * will therefore *fail* the asyncify step rather than silently produce a broken
 * cell, so this module reports which provider it found and whether it is the
 * fork — `resolveWasmOpt().forked` is what the build records in provenance.
 *
 * Resolution order, most reproducible first:
 *   1. `SVELTE_D_WASM_OPT` / `WASM_OPT`            — explicit override
 *   2. `browser-ui/toolchains/binaryen-svelte-d/`  — `install-wasm-opt.ts`
 *   3. `svelte-d/binaryen-build/<variant>/`        — svelte-d's own layout
 *   4. `~/.svelte-d/toolchains/binaryen-svelte-d/` — `bunx svelte-d setup`
 *   5. `svelte-d/binaryen/{build,out}/bin/`        — a local cmake build
 *   6. PATH                                        — last, and flagged unforked
 *
 * This replaces a hardcoded absolute path to one developer's checkout, which
 * meant the asyncify lane only worked on that machine.
 */
import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

/** Binaryen ≥ this cannot be relied on for `try_table` asyncify unless forked. */
export const MIN_WASM_OPT_VERSION = 123;

/** Rolling release tag carrying the CI-built fork binaries. */
export const WASM_OPT_RELEASE = process.env.SVELTE_D_WASM_OPT_RELEASE || "wasm-opt-svelte-d";
/** Branch holding `wasm-opt-<variant>.tar.gz` when the release is absent. */
export const WASM_OPT_BRANCH = process.env.SVELTE_D_WASM_OPT_BRANCH || "wasm-opt-binaries";
export const WASM_OPT_REPO = process.env.SVELTE_D_WASM_OPT_REPO || "etcimon/binaryen";

export type WasmOptInfo = {
  /** Absolute path, or "" when nothing usable was found. */
  bin: string;
  /** Numeric Binaryen version from `--version`, 0 when unknown. */
  version: number;
  /** True when the path indicates the etcimon Flatten/try_table fork. */
  forked: boolean;
  /** Which rule matched, for the build log and provenance. */
  source: string;
};

/** `browser-ui/` root, i.e. the parent of `compiler/`. */
function browserUiRoot(): string {
  return resolve(dirname(fileURLToPath(import.meta.url)), "..");
}

/** `g6lc_bios/` root. */
export function packageRoot(): string {
  return resolve(browserUiRoot(), "..");
}

/** The svelte-d submodule, or "" when it has not been initialised. */
export function svelteDRoot(): string {
  const env = process.env.SVELTE_D_ROOT;
  if (env && existsSync(env)) return resolve(env);
  const p = join(packageRoot(), "svelte-d");
  return existsSync(join(p, "package.json")) ? p : "";
}

/**
 * The nested `binaryen/` fork source. Identified by `src/passes/Flatten.cpp`
 * the same way svelte-d's `isBinaryenSource` does, so a stock Binaryen
 * checkout parked at that path cannot pass for the fork.
 */
export function binaryenSource(): string {
  const env = process.env.SVELTE_D_BINARYEN;
  if (env && isBinaryenSource(env)) return resolve(env);
  const sd = svelteDRoot();
  if (!sd) return "";
  const p = join(sd, "binaryen");
  return isBinaryenSource(p) ? p : "";
}

export function isBinaryenSource(dir: string): boolean {
  return existsSync(join(dir, "src", "passes", "Flatten.cpp"));
}

/** Asset/folder stem used by the fork's CI, e.g. `windows-x86_64`. */
export function binaryenVariant(platform = process.platform, arch = process.arch): string {
  if (platform === "win32") return "windows-x86_64";
  if (platform === "darwin") return arch === "arm64" ? "darwin-arm64" : "darwin-x86_64";
  return arch === "arm64" ? "linux-aarch64" : "linux-x86_64";
}

export function wasmOptExeName(platform = process.platform): string {
  return platform === "win32" ? "wasm-opt.exe" : "wasm-opt";
}

/** Where `install-wasm-opt.ts` puts the binary: in-tree and gitignored. */
export function localBinaryenHome(root = browserUiRoot()): string {
  return join(root, "toolchains", "binaryen-svelte-d");
}

export function svelteDToolchainHome(): string {
  const env = process.env.SVELTE_D_TOOLCHAINS;
  if (env) return env;
  return join(homedir(), ".svelte-d", "toolchains");
}

/** Ordered download URLs for the host's forked `wasm-opt`. */
export function wasmOptDownloadUrls(
  variant = binaryenVariant(),
  repo = WASM_OPT_REPO,
  tag = WASM_OPT_RELEASE,
  branch = WASM_OPT_BRANCH,
): string[] {
  const asset = `wasm-opt-${variant}.tar.gz`;
  return [
    `https://github.com/${repo}/releases/download/${tag}/${asset}`,
    `https://github.com/${repo}/raw/${branch}/${asset}`,
    `https://raw.githubusercontent.com/${repo}/${branch}/${asset}`,
    `https://nightly.link/${repo}/workflows/wasm-opt.yml/master/wasm-opt-${variant}.zip`,
  ];
}

/** `wasm-opt version 132 (version_132)` -> 132. 0 when unreadable. */
export function parseWasmOptVersion(text: string): number {
  if (!text) return 0;
  const m = text.match(/version[_\s]+(\d+)/i);
  return m ? parseInt(m[1], 10) : 0;
}

export function wasmOptVersion(bin: string, run = spawnSync): number {
  if (!bin || !existsSync(bin)) return 0;
  const r = run(bin, ["--version"], { encoding: "utf8", shell: false });
  if (r.status !== 0) return 0;
  return parseWasmOptVersion(String(r.stdout || "") + String(r.stderr || ""));
}

/**
 * Path-shape test for the fork. It is a heuristic on purpose and is only used
 * to *label* the provider, never to skip the version check: a binary in a
 * `binaryen-svelte-d` / `binaryen-build` / `binaryen/build` location came from
 * the fork's release, CI or a build of the fork source.
 */
export function isForkedPath(bin: string): boolean {
  if (!bin) return false;
  const n = bin.replace(/\\/g, "/").toLowerCase();
  return (
    n.includes("binaryen-svelte-d") ||
    n.includes("binaryen-build") ||
    /\/binaryen\/(bin|build|out)\//.test(n)
  );
}

function candidates(): { dir: string; source: string }[] {
  const variant = binaryenVariant();
  const out: { dir: string; source: string }[] = [];
  out.push({ dir: join(localBinaryenHome(), "bin"), source: "browser-ui/toolchains" });
  const sd = svelteDRoot();
  if (sd) {
    const build = process.env.SVELTE_D_BINARYEN_BUILD || join(sd, "binaryen-build");
    out.push({ dir: join(build, variant), source: "svelte-d/binaryen-build" });
    out.push({ dir: build, source: "svelte-d/binaryen-build" });
    out.push({ dir: join(sd, "binaryen", "build", "bin"), source: "svelte-d/binaryen (cmake)" });
    out.push({ dir: join(sd, "binaryen", "out", "bin"), source: "svelte-d/binaryen (cmake)" });
    out.push({ dir: join(sd, "binaryen", "bin"), source: "svelte-d/binaryen (cmake)" });
  }
  out.push({ dir: join(svelteDToolchainHome(), "binaryen-svelte-d", "bin"), source: "~/.svelte-d" });
  return out;
}

function which(cmd: string): string {
  const r = spawnSync(process.platform === "win32" ? "where" : "which", [cmd], {
    encoding: "utf8",
    shell: false,
  });
  if (r.status !== 0) return "";
  return (r.stdout || "").split(/\r?\n/).map((s) => s.trim()).find(Boolean) || "";
}

/**
 * Resolve `wasm-opt`. Never throws: an empty `bin` means the asyncify lane must
 * fail closed, which the caller reports rather than skipping the pass.
 */
export function resolveWasmOpt(): WasmOptInfo {
  const exe = wasmOptExeName();
  const miss: WasmOptInfo = { bin: "", version: 0, forked: false, source: "none" };

  for (const key of ["SVELTE_D_WASM_OPT", "WASM_OPT"]) {
    const v = process.env[key];
    if (v && existsSync(v)) {
      return { bin: resolve(v), version: wasmOptVersion(v), forked: isForkedPath(v), source: `$${key}` };
    }
  }
  for (const { dir, source } of candidates()) {
    for (const name of [exe, "wasm-opt"]) {
      const cand = join(dir, name);
      if (!existsSync(cand)) continue;
      return { bin: cand, version: wasmOptVersion(cand), forked: isForkedPath(cand), source };
    }
  }
  const onPath = which("wasm-opt");
  if (onPath) {
    return { bin: onPath, version: wasmOptVersion(onPath), forked: isForkedPath(onPath), source: "PATH" };
  }
  return miss;
}

/**
 * Human-readable reason the provider is unusable, or "" when it is fine.
 * Kept separate from `resolveWasmOpt` so the build can *report* an unforked
 * or too-old tool instead of discovering it as an opaque asyncify failure.
 */
export function wasmOptProblem(info: WasmOptInfo): string {
  if (!info.bin) {
    return "no wasm-opt: run `bun scripts/install-wasm-opt.ts` (needs the svelte-d submodule)";
  }
  if (info.version && info.version < MIN_WASM_OPT_VERSION) {
    return `wasm-opt ${info.version} at ${info.bin} is older than ${MIN_WASM_OPT_VERSION}`;
  }
  if (!info.forked) {
    return `wasm-opt at ${info.bin} (${info.source}) is not the etcimon svelte-d fork; stock Binaryen cannot --asyncify try_table`;
  }
  return "";
}

/** `binaryen-build/LICENSE` text, so a shipped wasm-opt keeps its terms. */
export function binaryenLicense(): string {
  const sd = svelteDRoot();
  if (!sd) return "";
  const p = join(sd, "binaryen-build", "LICENSE");
  try {
    return existsSync(p) ? readFileSync(p, "utf8") : "";
  } catch {
    return "";
  }
}
