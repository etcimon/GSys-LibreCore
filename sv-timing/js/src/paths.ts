// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Resolve sv-timing package root and contained cargo from the js/ project.

import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

/** Absolute path to `sv-timing/` (parent of `js/`). */
export function packageRootFromJs(): string {
  // js/src -> js -> sv-timing
  return resolve(here, "..", "..");
}

/** Path to schemas/analyze-result.v0.json */
export function analyzeSchemaPath(pkgRoot = packageRootFromJs()): string {
  return join(pkgRoot, "schemas", "analyze-result.v0.json");
}

/** Contained cargo under .tools/cargo/bin if present. */
export function containedCargo(pkgRoot = packageRootFromJs()): string | null {
  const isWin = process.platform === "win32";
  const name = isWin ? "cargo.exe" : "cargo";
  const p = join(pkgRoot, ".tools", "cargo", "bin", name);
  return existsSync(p) ? p : null;
}

/** Built CLI binary path if present. */
export function builtCliPath(pkgRoot = packageRootFromJs()): string | null {
  const isWin = process.platform === "win32";
  const name = isWin ? "sv-timing.exe" : "sv-timing";
  const p = join(pkgRoot, "target", "debug", name);
  return existsSync(p) ? p : null;
}

/** Env for contained rustup/cargo. */
export function containedRustEnv(pkgRoot = packageRootFromJs()): Record<string, string> {
  const rustup = join(pkgRoot, ".tools", "rustup");
  const cargoHome = join(pkgRoot, ".tools", "cargo");
  const bin = join(cargoHome, "bin");
  const pathKey = process.platform === "win32" ? "Path" : "PATH";
  const prev = process.env[pathKey] ?? process.env.PATH ?? "";
  return {
    ...process.env,
    SV_TIMING_ROOT: pkgRoot,
    RUSTUP_HOME: rustup,
    CARGO_HOME: cargoHome,
    [pathKey]: `${bin}${isPathSep()}${prev}`,
  } as Record<string, string>;
}

function isPathSep(): string {
  return process.platform === "win32" ? ";" : ":";
}
