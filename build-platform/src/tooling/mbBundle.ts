// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// mbBundle.ts — the mbgen compile bundle as `mb ingest` sees it.
//
// `mbgen compile` writes design/circuit/layout/platform/firmware/... and then
// `manifest.json` last with a sha256 per file. Ingest therefore has two
// honest states: a *bundle* (manifest present → every listed file must hash
// as declared, or the bundle is partial/tampered and refused) and a *legacy*
// single `platform.json` (no manifest → only the platform is ingested and the
// circuit flow stays unavailable for that board). Nothing in between.

import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";

/** Files copied next to board.json when present and verified. */
export const BUNDLE_SIDE_FILES = ["circuit.json", "layout.json"] as const;

export interface BundleManifest {
  schema_version: number;
  circuit_sha256?: string;
  files: Record<string, { sha256: string; bytes?: number }>;
  core_source?: { path?: string; sha256?: string };
}

export interface BundleCheck {
  /** `bundle` when a manifest sits next to platform.json, else `legacy`. */
  mode: "bundle" | "legacy";
  dir: string;
  manifest: BundleManifest | null;
  /** Files verified against the manifest and ready to copy (name → text). */
  files: Record<string, string>;
  issues: string[];
}

export function sha256Hex(text: string): string {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

/**
 * Inspect the directory holding `platformPath`. With a manifest, every
 * manifest-listed file that ingest consumes (platform.json + side files) is
 * read and hashed; a missing or drifted file is an issue.
 */
export async function inspectBundle(platformPath: string, platformText: string): Promise<BundleCheck> {
  const dir = dirname(platformPath);
  const manifestPath = join(dir, "manifest.json");
  const out: BundleCheck = { mode: "legacy", dir, manifest: null, files: {}, issues: [] };
  if (!existsSync(manifestPath)) return out;
  out.mode = "bundle";
  let manifest: BundleManifest;
  try {
    manifest = JSON.parse(await readFile(manifestPath, "utf8")) as BundleManifest;
  } catch (err) {
    out.issues.push(`manifest.json is not readable JSON: ${(err as Error).message}`);
    return out;
  }
  out.manifest = manifest;
  if (!manifest.files || typeof manifest.files !== "object") {
    out.issues.push("manifest.json has no files table");
    return out;
  }
  const check = (name: string, text: string): boolean => {
    const entry = manifest.files[name];
    if (!entry) {
      out.issues.push(`${name} is not listed in manifest.json`);
      return false;
    }
    const actual = sha256Hex(text);
    if (actual !== entry.sha256) {
      out.issues.push(`${name} sha256 ${actual.slice(0, 12)}… differs from manifest ${entry.sha256.slice(0, 12)}… (partial or edited bundle)`);
      return false;
    }
    return true;
  };
  check("platform.json", platformText);
  for (const name of BUNDLE_SIDE_FILES) {
    const path = join(dir, name);
    if (!existsSync(path)) {
      if (manifest.files[name]) out.issues.push(`${name} is listed in manifest.json but missing`);
      continue;
    }
    const text = await readFile(path, "utf8");
    if (check(name, text)) out.files[name] = text;
  }
  if (manifest.circuit_sha256 && out.files["circuit.json"]) {
    const compact = JSON.stringify(JSON.parse(out.files["circuit.json"]));
    if (sha256Hex(compact) !== manifest.circuit_sha256) {
      out.issues.push("circuit.json content hash differs from manifest circuit_sha256");
    }
  }
  return out;
}
