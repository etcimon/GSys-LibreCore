// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// discovery.ts — File discovery + incremental change detection.
//
// This is the mechanism behind "auto-detect files, minimal customization for
// new features": build steps declare glob patterns (e.g. all *.sv under core/)
// and ask whether anything changed since the last successful run. Fingerprints
// are size+mtime (fast, make-like) and persisted as a JSON manifest under
// workspace/.cache/manifests so a step can be skipped when its inputs are
// unchanged.

import { Glob } from "bun";
import { existsSync } from "node:fs";
import { mkdir, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";

export interface DiscoverOptions {
  cwd: string;
  /** Exclude patterns (glob) applied after matching. */
  exclude?: string[];
}

/** Discover absolute file paths matching any of the patterns under cwd. */
export async function discoverFiles(
  patterns: string[],
  options: DiscoverOptions,
): Promise<string[]> {
  const excludeGlobs = (options.exclude ?? []).map((p) => new Glob(p));
  const found = new Set<string>();
  for (const pattern of patterns) {
    const glob = new Glob(pattern);
    for await (const path of glob.scan({ cwd: options.cwd, absolute: true, onlyFiles: true })) {
      if (excludeGlobs.some((g) => g.match(path))) continue;
      found.add(path);
    }
  }
  return [...found].sort();
}

/** size:mtime fingerprint for one file; empty string if it cannot be stat-ed. */
async function fingerprintOne(path: string): Promise<string> {
  try {
    const s = await stat(path);
    return `${s.size}:${Math.round(s.mtimeMs)}`;
  } catch {
    return "";
  }
}

export type Manifest = Record<string, string>;

/** Build a fingerprint manifest (path → size:mtime) for the given files. */
export async function fingerprint(files: string[]): Promise<Manifest> {
  const manifest: Manifest = {};
  await Promise.all(
    files.map(async (f) => {
      manifest[f] = await fingerprintOne(f);
    }),
  );
  return manifest;
}

export interface ChangeReport {
  changed: boolean;
  added: string[];
  removed: string[];
  modified: string[];
  manifestPath: string;
  current: Manifest;
}

function manifestPathFor(manifestsDir: string, key: string): string {
  const safe = key.replace(/[^a-zA-Z0-9._-]/g, "_");
  return join(manifestsDir, `${safe}.json`);
}

async function readManifest(path: string): Promise<Manifest | null> {
  if (!existsSync(path)) return null;
  try {
    return (await Bun.file(path).json()) as Manifest;
  } catch {
    return null;
  }
}

/**
 * Compare the current fingerprints for `files` against the stored manifest for
 * `key`. Does NOT persist; call commitManifest after a step succeeds.
 */
export async function detectChanges(
  manifestsDir: string,
  key: string,
  files: string[],
): Promise<ChangeReport> {
  const manifestPath = manifestPathFor(manifestsDir, key);
  const stored = await readManifest(manifestPath);
  const previous = stored ?? {};
  const firstRun = stored === null;
  const current = await fingerprint(files);

  const added: string[] = [];
  const removed: string[] = [];
  const modified: string[] = [];

  for (const [path, fp] of Object.entries(current)) {
    if (!(path in previous)) added.push(path);
    else if (previous[path] !== fp) modified.push(path);
  }
  for (const path of Object.keys(previous)) {
    if (!(path in current)) removed.push(path);
  }

  const changed =
    firstRun ||
    added.length > 0 ||
    removed.length > 0 ||
    modified.length > 0;

  return { changed, added, removed, modified, manifestPath, current };
}

/** Persist a manifest so the next detectChanges can compare against it. */
export async function commitManifest(report: ChangeReport): Promise<void> {
  await mkdir(join(report.manifestPath, ".."), { recursive: true });
  await writeFile(report.manifestPath, JSON.stringify(report.current, null, 2));
}
