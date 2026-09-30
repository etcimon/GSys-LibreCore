// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// ai-overlay — pin / check the generated `<pkg>_ai` packages and DTS files.
//
//   ai-overlay pin --target g6lc64_ooo_int2_l3 [--int] [--island-cfg <literal>]
//   ai-overlay check            # every configured pin matches the generator
//   ai-overlay list

import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, relative } from "node:path";

import { requireContext, type Command } from "../command.ts";
import { flagBool, flagString } from "../args.ts";
import { checkPin, computePin, type PinOptions } from "../../tooling/aiOverlay.ts";

export const aiOverlayCommand: Command = {
  name: "ai-overlay",
  summary: "Pin the AI overlay as generated <pkg>_ai packages + DTS; check drift.",
  usage:
    "bun run src/cli/index.ts ai-overlay <pin|check|list> [--target <g6lc64_pkg>] [--int] [--island-cfg <literal>] [--dry-run]",
  details:
    "`+define+G6LC_AI_OVERLAY` gives any package the canonical island plane at build time\n" +
    "(config_pkg::AiCfgIsland via build_config_pkg). `pin` writes the shareable form: a\n" +
    "core/include/<pkg>_ai_config_pkg.sv derived from the base with exactly CvxifEn,\n" +
    "CoproType and AiCfg rewritten, and corev_apu/bootrom/ariane-<pkg>-ai.dts including the\n" +
    "base DTS + g6lc-ai-matrix.dtsi with xg6lcai on every cpu. `check` regenerates every pin\n" +
    "listed in soc.aiOverlayPins and reports drift (also run by `bun test`).",
  examples: [
    "bun run src/cli/index.ts ai-overlay pin --target g6lc64_ooo_int2_l3",
    "bun run src/cli/index.ts ai-overlay pin --target g6lc64_smt2_ooo_int --int",
    "bun run src/cli/index.ts ai-overlay check",
  ],
  needsContext: true,
  async run(args) {
    const ctx = requireContext(args);
    const { logger } = args;
    const verb = args.positionals[0] ?? "list";
    const pins = ctx.config.soc.aiOverlayPins;

    if (verb === "list") {
      if (pins.length === 0) logger.info("no pins configured (soc.aiOverlayPins)");
      for (const p of pins) logger.info(`${p.target}_ai  plane=${p.int ? "AiCfgIslandInt" : "AiCfgIsland"}  island=${p.islandCfg ?? "AiIslandLatencyDefault"}`);
      return 0;
    }

    if (verb === "check") {
      let bad = 0;
      for (const p of pins) {
        const r = await checkPin(ctx.repoRoot, p);
        (r.ok ? logger.success : logger.error).call(logger, `${p.target}_ai: ${r.detail}`);
        if (!r.ok) bad++;
      }
      return bad === 0 ? 0 : 1;
    }

    if (verb === "pin") {
      const target = flagString(args.flags, "target");
      if (!target) { logger.error("ai-overlay pin: --target <g6lc64_pkg> is required"); return 2; }
      const opts: PinOptions = {
        target,
        int: flagBool(args.flags, "int"),
        islandCfg: flagString(args.flags, "island-cfg") ?? undefined,
      };
      const pin = await computePin(ctx.repoRoot, opts);
      const files: Array<[string, string]> = [[pin.packagePath, pin.packageText]];
      if (pin.dtsPath && pin.dtsText) files.push([pin.dtsPath, pin.dtsText]);
      for (const [path, text] of files) {
        if (ctx.dryRun) { logger.info(`[dry-run] would write ${relative(ctx.repoRoot, path)}`); continue; }
        mkdirSync(dirname(path), { recursive: true });
        writeFileSync(path, text);
        logger.success(`wrote ${relative(ctx.repoRoot, path)}`);
      }
      if (!pin.dtsPath) logger.warn(`no base DTS for ${target} (corev_apu/bootrom); package pinned without a DTS`);
      if (!pins.some((p) => p.target === target)) {
        logger.warn(`add { target: "${target}"${opts.int ? ", int: true" : ""} } to soc.aiOverlayPins so 'ai-overlay check' and bun test guard it`);
      }
      return 0;
    }

    logger.error(`ai-overlay: unknown verb '${verb}'`);
    return 2;
  },
};
