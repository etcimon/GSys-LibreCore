// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// installProfiles.ts — Named install profiles for sim + dual-hart bring-up.
//
// Profiles group individual recipes so agents/users can provision only what a
// use case needs:
//
//   tools install sim          — RISC-V GCC + Spike (+ Verilator if scripted)
//   tools install dual-hart    — RISC-V GCC + OpenSBI SMT2 fw_payload
//   tools install all          — sim + dual-hart
//   setup --install --profile dual-hart
//
// Platform notes:
// - Windows OpenSBI: software/smt2-linux/scripts/build-opensbi-smt2.ps1
//   (Cygwin make + xPack path-wrap).
// - Spike: Linux native, or Windows via WSL (`tools install spike` runs
//   build-platform/scripts/install-spike.sh under wsl). Cygwin unsupported
//   (fesvr addr_t clash). Adopts ~/tools/spike when present.

import { existsSync } from "node:fs";
import { join } from "node:path";

import type { PlatformContext } from "../context.ts";
import { childEnv } from "../context.ts";
import { hasBinary, run } from "../platform/exec.ts";
import {
  installIcarus,
  installOpenSourceSimTools,
  installRiscvGcc,
  installSpike,
  installVerilator,
  type RecipeOptions,
  type RecipeResult,
} from "./recipes.ts";

export type InstallProfileId = "sim" | "dual-hart" | "opensbi" | "all" | "open-source-sim";

export interface InstallProfile {
  id: InstallProfileId;
  /** Human-readable summary. */
  summary: string;
  /** Recipe ids that make up this profile (for plan/list). */
  recipeIds: string[];
}

export const INSTALL_PROFILES: InstallProfile[] = [
  {
    id: "sim",
    summary:
      "Open-source sim path: riscv-gcc + Verilator installer + Spike (Linux/WSL) + Icarus detect",
    recipeIds: ["riscv-gcc", "verilator", "spike", "iverilog"],
  },
  {
    id: "open-source-sim",
    summary: "Alias of sim (historical name used by setup --install)",
    recipeIds: ["riscv-gcc", "verilator", "spike", "iverilog"],
  },
  {
    id: "dual-hart",
    summary:
      "SMT2 dual-hart: riscv-gcc + OpenSBI SMT2 fw_payload (calls software/smt2-linux scripts)",
    recipeIds: ["riscv-gcc", "opensbi-smt2"],
  },
  {
    id: "opensbi",
    summary: "OpenSBI SMT2 firmware only (requires riscv-gcc already installed)",
    recipeIds: ["opensbi-smt2"],
  },
  {
    id: "all",
    summary: "sim + dual-hart (full residual software stack for suites + R3a)",
    recipeIds: ["riscv-gcc", "verilator", "spike", "iverilog", "opensbi-smt2"],
  },
];

export function listInstallProfiles(): InstallProfile[] {
  return INSTALL_PROFILES;
}

export function resolveInstallProfile(name: string): InstallProfile | undefined {
  const key = name.trim().toLowerCase();
  return INSTALL_PROFILES.find((p) => p.id === key);
}

/** OpenSBI SMT2: fetch + build fw_payload via in-tree scripts. */
export async function installOpensbiSmt2(
  ctx: PlatformContext,
  options: RecipeOptions = {},
): Promise<RecipeResult> {
  const { logger, repoRoot, host, tools } = ctx;
  const outDir = join(repoRoot, "build-platform", "workspace", "smt2-linux");
  const fw = join(outDir, "fw_payload.elf");

  if (!options.force && existsSync(fw)) {
    return already("opensbi-smt2", `already present: ${fw}`);
  }

  const gccName = `${ctx.config.toolchain.riscvGcc.toolPrefix ?? "riscv-none-elf-"}gcc${host.exeSuffix}`;
  if (!existsSync(join(tools.riscvBin, gccName)) && !hasBinary(gccName.replace(host.exeSuffix, ""))) {
    // Best-effort: install riscv-gcc first
    const gcc = await installRiscvGcc(ctx, options);
    if (!gcc.ok && !gcc.skipped) {
      return { id: "opensbi-smt2", ok: false, skipped: false, reason: "riscv-gcc missing" };
    }
  }

  if (options.dryRun) {
    logger.info(
      host.os === "windows"
        ? "[dry-run] pwsh software/smt2-linux/scripts/build-opensbi-smt2.ps1"
        : "[dry-run] bash software/smt2-linux/scripts/build-opensbi-smt2.sh",
    );
    return already("opensbi-smt2", "dry-run");
  }

  const env = childEnv(ctx, {
    CROSS_COMPILE: ctx.config.toolchain.riscvGcc.toolPrefix ?? "riscv-none-elf-",
    PATH: [tools.riscvBin, process.env.PATH ?? ""].join(host.pathSep),
    Path: [tools.riscvBin, process.env.Path ?? process.env.PATH ?? ""].join(host.pathSep),
    SMT2_LINUX_OUT: outDir,
  });

  if (host.os === "windows") {
    const script = join(repoRoot, "software", "smt2-linux", "scripts", "build-opensbi-smt2.ps1");
    if (!existsSync(script)) {
      return { id: "opensbi-smt2", ok: false, skipped: false, reason: "build-opensbi-smt2.ps1 missing" };
    }
    // Prefer already-fetched tree; scripts fetch when needed.
    const res = await run(
      "pwsh",
      ["-NoProfile", "-File", script],
      { cwd: repoRoot, env, logger, allowFailure: true, stdio: "both" },
    );
    const ok = res.ok && existsSync(fw);
    return {
      id: "opensbi-smt2",
      ok,
      skipped: false,
      reason: ok ? fw : `OpenSBI build failed (exit ${res.code}); need Cygwin make + xPack (see software/smt2-linux/README.md)`,
    };
  }

  const sh = join(repoRoot, "software", "smt2-linux", "scripts", "build-opensbi-smt2.sh");
  if (!existsSync(sh)) {
    return { id: "opensbi-smt2", ok: false, skipped: false, reason: "build-opensbi-smt2.sh missing" };
  }
  const res = await run("bash", [sh], {
    cwd: repoRoot,
    env,
    logger,
    allowFailure: true,
    stdio: "both",
  });
  const ok = res.ok && existsSync(fw);
  return {
    id: "opensbi-smt2",
    ok,
    skipped: false,
    reason: ok ? fw : `OpenSBI build failed (exit ${res.code})`,
  };
}

function already(id: string, reason: string): RecipeResult {
  return { id, ok: true, skipped: true, reason };
}

/** Install a single recipe by id. */
export async function installRecipeById(
  ctx: PlatformContext,
  id: string,
  options: RecipeOptions = {},
): Promise<RecipeResult> {
  switch (id) {
    case "riscv-gcc":
      return installRiscvGcc(ctx, options);
    case "verilator":
      return installVerilator(ctx, options);
    case "spike":
      return installSpike(ctx, options);
    case "iverilog":
      return installIcarus(ctx, options);
    case "opensbi-smt2":
    case "opensbi":
      return installOpensbiSmt2(ctx, options);
    default:
      return { id, ok: false, skipped: false, reason: `unknown recipe: ${id}` };
  }
}

/**
 * Run a named install profile. Returns per-recipe results.
 * Unknown profile throws (caller validates).
 */
export async function installProfile(
  ctx: PlatformContext,
  profileId: string,
  options: RecipeOptions = {},
): Promise<RecipeResult[]> {
  const profile = resolveInstallProfile(profileId);
  if (!profile) {
    throw new Error(
      `Unknown install profile "${profileId}". Known: ${INSTALL_PROFILES.map((p) => p.id).join(", ")}`,
    );
  }

  // sim / open-source-sim: keep the historical step sequence from recipes.ts
  if (profile.id === "sim" || profile.id === "open-source-sim") {
    return installOpenSourceSimTools(ctx, options);
  }

  if (profile.id === "all") {
    const sim = await installOpenSourceSimTools(ctx, options);
    const opensbi = await installOpensbiSmt2(ctx, options);
    return [...sim, opensbi];
  }

  const results: RecipeResult[] = [];
  let index = 0;
  for (const rid of profile.recipeIds) {
    index++;
    const result = await installRecipeById(ctx, rid, options);
    ctx.logger.step(
      index,
      profile.recipeIds.length,
      `${result.id}: ${result.skipped ? (result.reason ?? "skipped") : result.ok ? "ok" : "FAILED"}`,
    );
    results.push(result);
  }
  return results;
}
