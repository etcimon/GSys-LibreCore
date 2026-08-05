// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// submodules.ts — Git-focused dependency sync (the "cargo-like" pull step).
//
// Initialises/updates the submodules declared in the config and checks out any
// pinned ref. Only touches submodules marked enabled.

import { run } from "../platform/exec.ts";
import type { PlatformContext } from "../context.ts";

export interface SyncOptions {
  dryRun?: boolean;
  /** Only sync this submodule id, if given. */
  only?: string;
}

export interface SyncResult {
  id: string;
  path: string;
  ref?: string;
  ok: boolean;
  skipped: boolean;
}

/** Initialise/update enabled submodules and checkout pinned refs. */
export async function syncSubmodules(
  ctx: PlatformContext,
  options: SyncOptions = {},
): Promise<SyncResult[]> {
  const { config, repoRoot, logger } = ctx;
  const dependencies = config.dependencies;
  const entries = Object.entries(config.dependencies.submodules);
  const results: SyncResult[] = [];

  const enabled = entries.filter(
    ([id, spec]) => spec.enabled && (!options.only || options.only === id),
  );
  const depthArgs = dependencies.shallow ? ["--depth", "1"] : [];

  let index = 0;
  for (const [id, spec] of enabled) {
    index++;
    logger.step(index, enabled.length, `submodule ${id} → ${spec.path}`);

    if (options.dryRun) {
      logger.info(`[dry-run] git submodule update --init ${depthArgs.join(" ")} -- ${spec.path}`);
      if (spec.ref) logger.info(`[dry-run] git -C ${spec.path} checkout ${spec.ref}`);
      results.push({ id, path: spec.path, ref: spec.ref, ok: true, skipped: true });
      continue;
    }

    const init = await run(
      "git",
      ["submodule", "update", "--init", ...depthArgs, "--", spec.path],
      { cwd: repoRoot, logger, allowFailure: true },
    );
    let ok = init.ok;

    if (ok && spec.ref) {
      const checkout = await run("git", ["-C", spec.path, "checkout", spec.ref], {
        cwd: repoRoot,
        logger,
        allowFailure: true,
      });
      ok = checkout.ok;
    }

    if (ok) logger.success(`synced ${id}`);
    else logger.error(`failed to sync ${id}`);
    results.push({ id, path: spec.path, ref: spec.ref, ok, skipped: false });
  }

  return results;
}
