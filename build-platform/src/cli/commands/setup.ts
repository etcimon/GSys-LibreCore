// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// setup.ts — Provision the workspace: directories, submodules, toolchain plan.

import { requireContext, type Command } from "../command.ts";
import { flagBool } from "../args.ts";
import { ensureWorkspace } from "../../workspace/layout.ts";
import { syncSubmodules } from "../../tooling/submodules.ts";
import { installPrerequisites } from "../../tooling/packageManagers.ts";
import { ensureVenv, pipInstall } from "../../python/venv.ts";
import {
  installProfile,
  listInstallProfiles,
  resolveInstallProfile,
} from "../../tooling/installProfiles.ts";
import { gatherProbeReport } from "../../tooling/probe.ts";

export const setupCommand: Command = {
  name: "setup",
  summary: "Provision workspace + submodules; with --install, the toolchain too.",
  usage:
    "bun run src/cli/index.ts setup [--install] [--profile <sim|dual-hart|opensbi|all>] [--allow-system-install] [--skip-submodules] [--force] [--dry-run]",
  details:
    "Steps: (1) create the workspace tree, (2) init/update git submodules. With\n" +
    "--install it also (3) installs OS build prerequisites (needs\n" +
    "--allow-system-install or platform.allowSystemInstall), (4) creates the\n" +
    "Python venv + pins, (5) runs an install **profile** into workspace/tooling.\n" +
    "\n" +
    "Profiles (also available via `tools install <profile>`):\n" +
    "  sim (default)   — open-source sim: riscv-gcc, verilator, spike, iverilog\n" +
    "  dual-hart       — riscv-gcc + OpenSBI SMT2 fw_payload scripts\n" +
    "  opensbi         — OpenSBI SMT2 only\n" +
    "  all             — sim + dual-hart\n" +
    "\n" +
    "Without --install, prints the toolchain plan only.",
  examples: [
    "bun run src/cli/index.ts setup",
    "bun run src/cli/index.ts setup --install --allow-system-install",
    "bun run src/cli/index.ts setup --install --profile dual-hart",
    "bun run src/cli/index.ts setup --install --profile all --force",
    "bun run src/cli/index.ts setup --install --dry-run",
  ],
  needsContext: true,
  async run(args) {
    const ctx = requireContext(args);
    const { logger } = ctx;
    const doInstall = flagBool(args.flags, "install");
    const allowSystem =
      flagBool(args.flags, "allow-system-install") || ctx.config.platform.allowSystemInstall;
    const profileName =
      typeof args.flags.profile === "string" ? args.flags.profile : "sim";

    logger.heading("LibreCore build-platform setup");

    logger.heading("1. Workspace");
    if (ctx.dryRun) logger.info(`[dry-run] mkdir -p ${ctx.paths.root}`);
    else await ensureWorkspace(ctx.paths);
    logger.success(`workspace: ${ctx.paths.root}`);

    if (flagBool(args.flags, "skip-submodules")) {
      logger.heading("2. Submodules (skipped)");
    } else {
      logger.heading("2. Submodules");
      const results = await syncSubmodules(ctx, { dryRun: ctx.dryRun });
      const failed = results.filter((r) => !r.ok && !r.skipped);
      if (failed.length > 0) {
        logger.error(`submodule sync failed: ${failed.map((f) => f.id).join(", ")}`);
        return 1;
      }
    }

    if (!doInstall) {
      logger.heading("3. Toolchain (plan only — pass --install to provision)");
      logger.info(`  riscv-gcc  ${ctx.config.toolchain.riscvGcc.version}  → ${ctx.tools.riscv}`);
      logger.info(`  verilator  ${ctx.config.toolchain.versions.verilator}  → ${ctx.tools.verilator}`);
      logger.info(`  spike      ${ctx.config.toolchain.versions.spike}  → ${ctx.tools.spike}`);
      logger.info(`  iverilog   ${ctx.config.toolchain.versions.iverilog}  → ${ctx.tools.iverilog}`);
      logger.info(`  python     venv  → ${ctx.paths.pythonVenv}`);
      logger.info("");
      logger.heading("Install profiles");
      for (const p of listInstallProfiles()) {
        logger.info(`  ${p.id.padEnd(16)} ${p.summary}`);
      }
      logger.info("");
      logger.info(
        "Provision with: bun run src/cli/index.ts setup --install [--profile dual-hart] [--allow-system-install]",
      );
      logger.info("Or:            bun run src/cli/index.ts tools install dual-hart");
      logger.heading("Setup complete (plan only)");
      return 0;
    }

    if (!resolveInstallProfile(profileName)) {
      logger.error(
        `Unknown --profile ${profileName}. Known: ${listInstallProfiles().map((p) => p.id).join(", ")}`,
      );
      return 1;
    }

    logger.heading("3. Build prerequisites");
    if (allowSystem) {
      const { manager } = await installPrerequisites(ctx.host.os, {
        logger,
        dryRun: ctx.dryRun,
        useSudo: true,
        preferred: ctx.config.toolchain.packageManager[ctx.host.os],
      });
      if (manager) logger.success(`prerequisites handled via ${manager}`);
    } else {
      logger.warn("Skipping OS package install (enable with --allow-system-install or platform.allowSystemInstall).");
    }

    logger.heading("4. Python environment");
    const venvOk = await ensureVenv(ctx, { dryRun: ctx.dryRun });
    if (venvOk) await pipInstall(ctx, { dryRun: ctx.dryRun });
    else logger.error("Python venv creation failed; skipping pip install.");

    logger.heading(`5. Toolchain profile: ${profileName}`);
    const toolResults = await installProfile(ctx, profileName, {
      dryRun: ctx.dryRun,
      force: flagBool(args.flags, "force"),
    });
    const toolFailures = toolResults.filter((r) => !r.ok && !r.skipped);

    logger.heading("Setup summary");
    for (const r of toolResults) {
      const mark = r.ok ? (r.skipped ? "skip" : "ok  ") : "FAIL";
      logger.info(`  ${mark}  ${r.id}${r.reason ? ` — ${r.reason}` : ""}`);
    }
    logger.info(`tools: ${toolResults.length}, failures: ${toolFailures.length}`);
    if (toolFailures.length > 0) {
      logger.error(`failed: ${toolFailures.map((r) => r.id).join(", ")}`);
      logger.info("Diagnose: bun run src/cli/index.ts probe install");
      return 1;
    }
    logger.success("Setup complete.");

    // Compact post-setup capability snapshot (tools tab only — fast).
    logger.heading("6. Post-setup probe (tools)");
    try {
      const report = await gatherProbeReport(ctx);
      for (const t of report.managedTools) {
        const mark = t.installed ? "ok  " : "miss";
        logger.info(`  ${mark}  ${t.id.padEnd(14)} ${t.installed ? t.pin : t.installHint}`);
      }
      const blocked = report.commands.filter((c) => c.status === "blocked");
      if (blocked.length) {
        logger.warn(`${blocked.length} command(s) still blocked — run: probe install`);
      } else {
        logger.success("No blocked commands. Full report: probe");
      }
    } catch {
      logger.info("probe snapshot skipped; run: bun run src/cli/index.ts probe tools");
    }
    return 0;
  },
};
