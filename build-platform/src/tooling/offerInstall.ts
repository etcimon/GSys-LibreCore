// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// offerInstall.ts — When managed tools are missing, offer tools install (y/n).
//
// Keeps `test --suite ooo-l3-tests` / `verify --target g6lc64_ooo_server` usable
// on a default platform by prompting once for the sim profile instead of only
// printing a skip/fail reason.

import type { PlatformContext } from "../context.ts";
import type { ManagedTool } from "../config/schema.ts";
import { confirmToolInstall } from "../util/prompt.ts";
import { installProfile, installRecipeById } from "./installProfiles.ts";
import { hasManagedTool } from "../tests/runner.ts";

const RECIPE_FOR: Record<ManagedTool, string> = {
  "riscv-gcc": "riscv-gcc",
  verilator: "verilator",
  spike: "spike",
  iverilog: "iverilog",
};

export function missingManagedTools(ctx: PlatformContext, tools: ManagedTool[]): ManagedTool[] {
  return tools.filter((t) => !hasManagedTool(ctx, t));
}

/**
 * If any of `tools` are missing, offer to install. Prefer profile `sim` when
 * several core tools are absent; otherwise install single recipes.
 * Returns true when all requested tools are present afterwards (or were already).
 */
export async function offerInstallMissingTools(
  ctx: PlatformContext,
  tools: ManagedTool[],
  flags: Record<string, string | boolean> = {},
): Promise<boolean> {
  const missing = missingManagedTools(ctx, tools);
  if (missing.length === 0) return true;

  const { logger } = ctx;
  const list = missing.join(", ");
  logger.warn(`Missing managed tool(s): ${list}`);
  logger.info("Install with: g6lc-build tools install sim   (or dual-hart / all / <recipe>)");
  if (ctx.host.os === "windows") {
    logger.info("On Windows, Spike is built via WSL into build-platform/workspace/tooling/spike.");
  }

  const useSimProfile =
    missing.includes("verilator") ||
    missing.includes("spike") ||
    (missing.includes("riscv-gcc") && missing.length > 1);

  const profileOrRecipe = useSimProfile ? "sim" : RECIPE_FOR[missing[0]!];
  const ok = await confirmToolInstall(
    `Install missing tools now (tools install ${profileOrRecipe})?`,
    flags,
  );
  if (!ok) {
    logger.info("Skipping install. Re-run with --yes to auto-accept, or set G6LC_NO_TOOL_PROMPT=1 to silence.");
    return false;
  }

  if (useSimProfile) {
    logger.heading("tools install sim (offered for incomplete workspace)");
    const results = await installProfile(ctx, "sim", { force: false, dryRun: false });
    const failed = results.filter((r) => !r.ok && !r.skipped);
    for (const r of results) {
      const mark = r.ok ? (r.skipped ? "skip" : "ok  ") : "FAIL";
      logger.info(`  ${mark}  ${r.id}${r.reason ? ` — ${r.reason}` : ""}`);
    }
    if (failed.length) {
      logger.error(`Install failed: ${failed.map((f) => f.id).join(", ")}`);
      return false;
    }
  } else {
    for (const t of missing) {
      const recipe = RECIPE_FOR[t];
      logger.heading(`tools install ${recipe}`);
      const result = await installRecipeById(ctx, recipe, { force: false, dryRun: false });
      const mark = result.ok ? (result.skipped ? "skip" : "ok  ") : "FAIL";
      logger.info(`  ${mark}  ${result.id}${result.reason ? ` — ${result.reason}` : ""}`);
      if (!result.ok) return false;
    }
  }

  const still = missingManagedTools(ctx, tools);
  if (still.length > 0) {
    logger.warn(`Still missing after install: ${still.join(", ")}`);
    return false;
  }
  logger.success("Managed tools ready.");
  return true;
}
