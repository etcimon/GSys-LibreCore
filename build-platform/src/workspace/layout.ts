// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// layout.ts — Resolve and materialise the managed workspace.
//
// Everything the platform installs or produces lives under a single workspace
// root (default: build-platform/workspace), which is fully gitignored:
//
//   workspace/
//     build/         all build/simulation/PnR outputs
//     tooling/       installed tools, git-sourced deps, python venv
//       bin/         aggregated bin dir prepended to PATH for child processes
//       python-venv/ contained pip environment
//     .cache/
//       manifests/   change-detection manifests
//       downloads/   fetched archives

import { mkdir } from "node:fs/promises";
import { isAbsolute, join } from "node:path";

import type { ResolvedBuildConfig } from "../config/schema.ts";

export interface WorkspacePaths {
  /** Absolute workspace root. */
  root: string;
  /** All build/sim/PnR outputs. */
  build: string;
  /** Installed tools + git deps + python venv. */
  tooling: string;
  /** Aggregated bin directory prepended to child-process PATH. */
  toolsBin: string;
  /** Contained Python virtual environment. */
  pythonVenv: string;
  /** Download/cache root. */
  cache: string;
  /** Fetched archives. */
  downloads: string;
  /** Change-detection manifests. */
  manifests: string;
}

/**
 * Resolve absolute workspace paths from the config. A relative workspace root
 * is interpreted relative to the build-platform directory (repoRoot/build-platform).
 */
export function resolveWorkspacePaths(
  repoRoot: string,
  config: ResolvedBuildConfig,
): WorkspacePaths {
  const platformDir = join(repoRoot, "build-platform");
  const root = isAbsolute(config.workspace.root)
    ? config.workspace.root
    : join(platformDir, config.workspace.root);

  const build = join(root, config.workspace.buildDir);
  const tooling = join(root, config.workspace.toolingDir);
  const cache = join(root, config.workspace.cacheDir);

  return {
    root,
    build,
    tooling,
    toolsBin: join(tooling, "bin"),
    pythonVenv: join(tooling, "python-venv"),
    cache,
    downloads: join(cache, "downloads"),
    manifests: join(cache, "manifests"),
  };
}

/** Create every workspace directory if missing (idempotent). */
export async function ensureWorkspace(paths: WorkspacePaths): Promise<void> {
  const dirs = [
    paths.root,
    paths.build,
    paths.tooling,
    paths.toolsBin,
    paths.cache,
    paths.downloads,
    paths.manifests,
  ];
  for (const dir of dirs) {
    await mkdir(dir, { recursive: true });
  }
}
