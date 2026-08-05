// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// technology.ts — Drive the agentic technology-optimization pass (PDK-swap seam).
//
// Subcommands:
//   status          Flag + PDK + arming summary (default).
//   specs           List the `*.tech-spec.md` docs that scope the pass.
//   plan            Read-only adaptation plan (what the pass WOULD do). No RTL edits.
//   check           Verify the SoC-readiness gates; exit 3 if enabled-but-not-ready.
//   init <tech>     Scaffold a gitignored per-technology PDK drop-in (README only).
//
// The pass is inert unless BOTH config.technology.optimizationPass is true AND a
// tech-spec doc is present. It NEVER edits RTL and NEVER commits NDA content —
// see AGENTS-technology.md + agents/guides/AGENTS-technology-optimization.md.

import { flagBool, flagString } from "../args.ts";
import { requireContext, type Command } from "../command.ts";
import {
  assessPass,
  detectSpecDocs,
  loadManifest,
  pdkPresence,
  planAdaptation,
  readinessGates,
  scaffoldTechnology,
} from "../../tooling/technology.ts";

export const technologyCommand: Command = {
  name: "tech",
  summary: "Drive the technology-optimization pass (foundry PDK adaptation at the tech-cell seam).",
  usage: "bun run src/cli/index.ts tech [status|specs|plan|check|init] [tech-id] [--json] [--dry-run]",
  details:
    "Orchestrates an agentic 'technology optimization pass' that binds a foundry's\n" +
    "proprietary, high-level abstraction layers (memory compilers, ICG/retention/\n" +
    "level-shifter cells, power kits, hard macros) at CVA6's existing PDK-swap seam\n" +
    "(tech_cells_generic, sram_cache TECHNO_CUT, hpdcache behav/blackbox/<tech>).\n" +
    "\n" +
    "Two-key ignition — the pass is inert unless BOTH hold:\n" +
    "  1. config.technology.optimizationPass === true\n" +
    "  2. a *.tech-spec.md doc exists under a scoped core/** or corev_apu/** area\n" +
    "\n" +
    "Every adaptation is fenced behind `ifdef <guardMacro> so the generic path is\n" +
    "byte-for-byte unchanged when the macro is undefined. Proprietary PDK views live\n" +
    "only under the gitignored pdkRoot; this command never edits RTL and never writes\n" +
    "NDA content. Use `check` in CI to gate an enabled pass.",
  examples: [
    "bun run src/cli/index.ts tech status",
    "bun run src/cli/index.ts tech specs --json",
    "bun run src/cli/index.ts tech plan",
    "bun run src/cli/index.ts tech check",
    "bun run src/cli/index.ts tech init tsmcN5 --dry-run",
  ],
  needsContext: true,
  async run(args) {
    const ctx = requireContext(args);
    const { logger } = ctx;
    const sub = args.positionals[0] ?? "status";
    const json = flagBool(args.flags, "json");

    switch (sub) {
      case "status":
        return await showStatus(ctx, json);
      case "specs":
        return await showSpecs(ctx, json);
      case "plan":
        return await showPlan(ctx, json);
      case "check":
        return await runCheck(ctx, json);
      case "init":
        return await runInit(ctx, args.positionals[1] ?? flagString(args.flags, "tech"));
      default:
        logger.error(`Unknown tech subcommand '${sub}'.`);
        logger.info("Use one of: status, specs, plan, check, init.");
        return 1;
    }
  },
};

async function showStatus(ctx: Parameters<Command["run"]>[0]["ctx"], asJson: boolean): Promise<number> {
  const context = ctx!;
  const { logger, config } = context;
  const t = config.technology;
  const assess = await assessPass(context);
  const presence = await pdkPresence(context);
  const manifest = await loadManifest(context);

  if (asJson) {
    logger.raw(JSON.stringify({ config: t, assessment: assess, pdk: presence, manifest }, null, 2) + "\n");
    return 0;
  }

  logger.heading("Technology optimization pass");
  logger.info(`optimizationPass : ${t.optimizationPass ? "on" : "off"}`);
  logger.info(`pdkMode          : ${t.pdkMode}`);
  logger.info(`activeTechnology : ${t.activeTechnology ?? "(none)"}`);
  logger.info(`guardMacro       : ${t.guardMacro}`);
  logger.info(`pdkRoot          : ${presence.root} ${presence.exists ? "(present)" : "(absent)"}`);
  logger.info(`pdk content      : ${presence.ndaContentPresent ? `drops=[${presence.drops.join(", ")}] manifest=${presence.manifestPresent}` : "none (generic path)"}`);
  logger.info(`tech-spec docs   : ${assess.specDocs.length}`);
  logger.info(`armed            : ${assess.armed ? "YES" : "no"}`);
  for (const r of assess.reasons) logger.info(`  - ${r}`);
  logger.info("Next: tech specs | tech plan | tech check | tech init <tech-id>");
  return 0;
}

async function showSpecs(ctx: Parameters<Command["run"]>[0]["ctx"], asJson: boolean): Promise<number> {
  const context = ctx!;
  const { logger, config } = context;
  const docs = await detectSpecDocs(context);
  if (asJson) {
    logger.raw(JSON.stringify(docs, null, 2) + "\n");
    return 0;
  }
  logger.heading(`Tech-spec docs (globs: ${config.technology.specGlobs.join(", ")})`);
  if (docs.length === 0) {
    logger.info("none — add a `*.tech-spec.md` under core/** or corev_apu/** to scope the pass.");
    return 0;
  }
  for (const d of docs) logger.info(`  ${d.area.padEnd(10)} ${d.path} (${d.bytes} B)`);
  return 0;
}

async function showPlan(ctx: Parameters<Command["run"]>[0]["ctx"], asJson: boolean): Promise<number> {
  const context = ctx!;
  const { logger } = context;
  const plan = await planAdaptation(context);
  if (asJson) {
    logger.raw(JSON.stringify(plan, null, 2) + "\n");
    return 0;
  }
  logger.heading("Adaptation plan (read-only — no RTL is edited)");
  logger.info(`armed=${plan.armed} pdkMode=${plan.pdkMode} activeTechnology=${plan.activeTechnology ?? "(none)"}`);
  if (!plan.armed) {
    for (const r of plan.reasons) logger.info(`  - ${r}`);
    return 0;
  }
  for (const target of plan.targets) {
    logger.info(`  [${target.area}] ${target.specDoc}`);
    logger.info(`      seam   : ${target.seam}`);
    logger.info(`      guard  : \`ifdef ${target.guardMacro}`);
    logger.info(`      output : ${target.outputDir}/ (gitignored)`);
    logger.info(`      note   : ${target.note}`);
  }
  return 0;
}

async function runCheck(ctx: Parameters<Command["run"]>[0]["ctx"], asJson: boolean): Promise<number> {
  const context = ctx!;
  const { logger } = context;
  const report = await readinessGates(context);
  if (asJson) {
    logger.raw(JSON.stringify(report, null, 2) + "\n");
  } else {
    logger.heading("SoC-readiness gates");
    for (const g of report.gates) {
      const mark = g.ok ? "ok  " : g.hard ? "FAIL" : "warn";
      logger.info(`  [${mark}] ${g.id.padEnd(26)} ${g.detail}`);
    }
  }
  // A disabled pass is intentionally off — never a CI failure. An *enabled* pass
  // that fails a hard gate is a real misconfiguration (exit 3, mirroring `mb`).
  if (!report.flagOn) {
    logger.info("technology.optimizationPass is off — pass disabled, nothing to gate.");
    return 0;
  }
  if (!report.ok) {
    logger.error("Pass is enabled but not SoC-ready — fix the FAIL gates above.");
    return 3;
  }
  logger.success("Technology pass is armed and SoC-ready.");
  return 0;
}

async function runInit(ctx: Parameters<Command["run"]>[0]["ctx"], techId: string | undefined): Promise<number> {
  const context = ctx!;
  const { logger, config } = context;
  const id = techId ?? config.technology.activeTechnology ?? undefined;
  if (!id) {
    logger.error("`tech init` needs a technology id, e.g. `tech init tsmcN5` (or set technology.activeTechnology).");
    return 1;
  }
  const res = await scaffoldTechnology(context, id, { dryRun: context.dryRun });
  if (res.dryRun) {
    logger.heading(`tech init ${id} (dry-run)`);
    for (const f of res.files) logger.info(`  would create ${f}`);
    logger.info("Re-run without --dry-run to write the (gitignored) drop-in scaffold.");
    return 0;
  }
  logger.heading(`tech init ${id}`);
  if (res.files.length === 0) {
    logger.info(`${res.dir}/ already scaffolded.`);
  } else {
    for (const f of res.files) logger.success(`created ${f}`);
  }
  logger.warn("Drop NDA/foundry PDK views into this dir — it is gitignored and must never be committed.");
  return 0;
}
