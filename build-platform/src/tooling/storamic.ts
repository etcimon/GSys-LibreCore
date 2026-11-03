// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

import type { SocConfig } from "../config/schema.ts";

export function storamicConfigIssues(soc: SocConfig): string[] {
  const cfg = soc.storamic;
  if (cfg === undefined) return [];
  const issues: string[] = [];
  if (typeof cfg.enable !== "boolean") issues.push("soc.storamic.enable must be boolean.");
  if (cfg.profile !== "skeleton") issues.push("Only the Storamic skeleton profile exists.");
  if (!Number.isInteger(cfg.maxSticks) || cfg.maxSticks < 1 || cfg.maxSticks > 8) {
    issues.push("soc.storamic.maxSticks must be an integer in 1..8.");
  }
  return issues;
}

export function storamicEnv(
  soc: SocConfig,
  env: Record<string, string | undefined> = {},
): Record<string, string> {
  const issues = storamicConfigIssues(soc);
  if (issues.length) throw new Error(issues.join(" "));
  const tokens = [env.defines, env.DEFINES, env.AI_MATRIX_DEFINES, env.G6LC_STORAMIC_DEFINES]
    .filter(Boolean).join("+").split(/[+\s]+/).filter(Boolean);
  const rawEnable = tokens.some((token) => token.split("=")[0] === "G6LC_STORAMIC");
  const enabled = soc.storamic?.enable || rawEnable;
  if (!enabled) return {};
  const direct = tokens.some((token) =>
    /^G6LC_AI_DRAM_(CLASS1|CHANS_[248]|SIM_CHANS_[248]|TIMING)(=|$)/.test(token));
  if (direct || Number(env.AI_ISLAND_DRAM_CLASS ?? 0) !== 0 ||
      Number(env.AI_ISLAND_DRAM_CHANNELS ?? 1) !== 1 ||
      env.AI_ISLAND_DRAM_TIMING === "1") {
    throw new Error("Storamic is mutually exclusive with direct DRAM backend selections.");
  }
  const rawCounts = tokens.filter((token) => token.startsWith("G6LC_STORAMIC_MAX_STICKS="))
    .map((token) => Number(token.split("=")[1]));
  const maxSticks = soc.storamic?.enable ? soc.storamic.maxSticks : (rawCounts[0] ?? 1);
  if (!Number.isInteger(maxSticks) || maxSticks < 1 || maxSticks > 8 ||
      rawCounts.some((count) => count !== maxSticks)) {
    throw new Error("Invalid or inconsistent Storamic maximum stick count.");
  }
  if (rawEnable && !soc.storamic?.enable &&
      !tokens.some((token) => token.split("=")[0] === "G6LC_STORAMIC_SKELETON")) {
    throw new Error("Storamic requires explicit skeleton profile selection.");
  }
  return {
    G6LC_STORAMIC_DEFINES:
      `G6LC_STORAMIC+G6LC_STORAMIC_SKELETON+G6LC_STORAMIC_MAX_STICKS=${maxSticks}`,
  };
}

export function validateStoramicFlags(
  soc: SocConfig,
  flags: Readonly<Record<string, string | boolean>>,
): void {
  if (soc.storamic?.enable &&
      ["ai-dram", "channels", "ai-timing", "ai-flavour"].some((key) => key in flags)) {
    throw new Error("Explicit direct-memory flags cannot be combined with soc.storamic.enable.");
  }
}
