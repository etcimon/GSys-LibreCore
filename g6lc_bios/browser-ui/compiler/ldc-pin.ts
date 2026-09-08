// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
/**
 * The pinned LDC release used by the optional libwasm cell.
 *
 * `toolchains/ldc.lock.json` names one upstream release
 * (github.com/ldc-developers/ldc) and carries the upstream SHA-256 for every
 * host asset. `scripts/install-ldc.ts` is the only writer of
 * `toolchains/<dir>/`; this module is the only reader, so discovery
 * (`ldc.ts`) and installation cannot drift apart.
 *
 * Bounded on purpose: a lock with no entry for the running host is an error,
 * not a fall-through to "whatever ldc2 is on PATH" — the cell's provenance
 * hash covers the compiler binary, so a substituted toolchain would silently
 * invalidate every shipped artifact.
 */
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export type PinnedAsset = {
  /** Release asset file name, exactly as published. */
  file: string;
  /** Top-level directory the asset extracts to, under `toolchains/`. */
  dir: string;
  /** Upstream SHA-256, verbatim from `ldc2-<version>.sha256sums.txt`. */
  sha256: string;
  bytes: number;
};

export type LdcPin = {
  schema: "g6lc-ldc-pin/v1";
  version: string;
  tag: string;
  repository: string;
  releaseNotes: string;
  frontend: string;
  sums: string;
  bundlesDub: boolean;
  assets: Record<string, PinnedAsset>;
};

/** `browser-ui/toolchains` — the pin lives with the tree it installs into. */
export function toolchainsDir(root = defaultRoot()): string {
  return join(root, "toolchains");
}

function defaultRoot(): string {
  return resolve(dirname(fileURLToPath(import.meta.url)), "..");
}

export function pinPath(root = defaultRoot()): string {
  return join(toolchainsDir(root), "ldc.lock.json");
}

/** Parse and validate the lock. Throws rather than returning a partial pin. */
export function readPin(root = defaultRoot()): LdcPin {
  const file = pinPath(root);
  if (!existsSync(file)) throw new Error(`missing LDC pin: ${file}`);
  const pin = JSON.parse(readFileSync(file, "utf8")) as LdcPin;
  if (pin.schema !== "g6lc-ldc-pin/v1") throw new Error(`unsupported LDC pin schema: ${pin.schema}`);
  if (!/^1\.43\.\d+(?:[-+][\w.-]+)?$/.test(pin.version)) {
    throw new Error(`pinned LDC ${pin.version} is not a 1.43 release; the carried runtime-v1.43.0 requires it`);
  }
  if (pin.tag !== `v${pin.version}`) throw new Error("LDC pin tag does not match the pinned version");
  if (!/^https:\/\/github\.com\/ldc-developers\/ldc$/.test(pin.repository)) {
    throw new Error("LDC pin must resolve to the upstream ldc-developers/ldc repository");
  }
  for (const [triple, asset] of Object.entries(pin.assets)) {
    if (!/^(windows|linux|osx)-(x64|arm64)$/.test(triple)) throw new Error(`unsupported host triple in LDC pin: ${triple}`);
    if (!asset.file.includes(pin.version)) throw new Error(`pinned asset ${asset.file} is not from ${pin.version}`);
    if (!/^[0-9a-f]{64}$/.test(asset.sha256)) throw new Error(`pinned asset ${asset.file} has no usable SHA-256`);
    if (!Number.isInteger(asset.bytes) || asset.bytes <= 0) throw new Error(`pinned asset ${asset.file} has no usable size`);
  }
  return pin;
}

/** The asset for `triple`, or a clear refusal when the host is not covered. */
export function pinnedAsset(triple: string, root = defaultRoot()): PinnedAsset {
  const pin = readPin(root);
  const asset = pin.assets[triple];
  if (!asset) {
    throw new Error(
      `LDC ${pin.version} publishes no ${triple} build; the optional libwasm cell cannot be built on this host ` +
        `(the first-party out/bios-ui.wasm lane is unaffected)`,
    );
  }
  return asset;
}

export function downloadUrl(asset: PinnedAsset, pin: LdcPin): string {
  return `${pin.repository}/releases/download/${pin.tag}/${asset.file}`;
}

/** Extraction root for the pinned asset: `toolchains/<dir>`. */
export function pinnedLdcHome(triple: string, root = defaultRoot()): string {
  return join(toolchainsDir(root), pinnedAsset(triple, root).dir);
}

/** `toolchains/<dir>/bin/ldc2[.exe]`, whether or not it is installed yet. */
export function pinnedLdcBin(triple: string, exe: string, root = defaultRoot()): string {
  return join(pinnedLdcHome(triple, root), "bin", exe);
}

/** True when `--version` text is exactly the pinned release. */
export function isPinnedLdcText(text: string, root = defaultRoot()): boolean {
  if (!text) return false;
  const line = text.split(/\r?\n/).find((l) => /LDC - the LLVM D compiler/i.test(l)) || text;
  return line.match(/\(([^)]+)\)/)?.[1]?.trim() === readPin(root).version;
}

/** Receipt written by the installer; absent until a successful install. */
export function receiptPath(root = defaultRoot()): string {
  return join(toolchainsDir(root), "installed.json");
}
