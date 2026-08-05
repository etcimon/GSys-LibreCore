// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// doctor.ts — Report host readiness for the LibreCore build/test flow.

import { existsSync } from "node:fs";

import { requireContext, type Command } from "../command.ts";
import {
  HOST_PROBES,
  probeAll,
  type ToolCategory,
  type ToolStatus,
} from "../../tooling/detect.ts";
import { gatherProbeReport } from "../../tooling/probe.ts";
import { resolveBashBinary } from "../../platform/shell.ts";

const CATEGORY_TITLES: Record<ToolCategory, string> = {
  core: "Core prerequisites",
  "package-manager": "Package managers",
  compiler: "Host compilers",
  simulator: "Open-source simulators / ISS",
  python: "Python",
  eda: "Commercial / PnR EDA (detect-only)",
};

/** Tools whose absence blocks the default open-source test flow. */
const REQUIRED_FOR_TESTS = new Set(["git", "bash", "python"]);

export const doctorCommand: Command = {
  name: "doctor",
  summary: "Diagnose host readiness (tools, versions, workspace).",
  usage: "bun run src/cli/index.ts doctor [--json]",
  details:
    "Probes PATH for prerequisites and open-source EDA tools, then reports the\n" +
    "workspace state and effective SoC target. Never installs anything.\n" +
    "For an in-depth categorical probe (pkg managers, managed tools, command\n" +
    "capability matrix, install playbook):  probe  |  probe tools  |  probe install",
  needsContext: true,
  async run(args) {
    const ctx = requireContext(args);
    const { logger, host, config, paths } = ctx;

    const statuses = await probeAll(HOST_PROBES);

    if (args.flags.json) {
      logger.raw(JSON.stringify({ host, statuses }, null, 2) + "\n");
      return 0;
    }

    logger.heading("Host");
    logger.info(`OS: ${host.os} (${host.arch}), ${host.cpuCount} CPUs`);
    logger.info(`Default shell: ${host.defaultShell}`);
    const bash = resolveBashBinary();
    if (bash) {
      const line = `bash for regress: ${bash.flavor}  ${bash.path ?? bash.bin}`;
      if (bash.flavor === "cygwin") {
        logger.warn(
          `${line} — prefer Git for Windows bash (Cygwin breaks many riscv-gcc/spike mixes)`,
        );
      } else {
        logger.success(line);
      }
    } else {
      logger.warn(
        "bash for regress: not found — install Git for Windows (preferred) or WSL",
      );
    }
    logger.info(`Repo root: ${ctx.repoRoot}`);
    logger.info(`Config: ${ctx.configPath ?? "(defaults only)"}`);

    const byCategory = new Map<ToolCategory, ToolStatus[]>();
    for (const s of statuses) {
      const list = byCategory.get(s.category) ?? [];
      list.push(s);
      byCategory.set(s.category, list);
    }

    for (const [category, title] of Object.entries(CATEGORY_TITLES) as [ToolCategory, string][]) {
      const list = byCategory.get(category);
      if (!list || list.length === 0) continue;
      logger.heading(title);
      for (const s of list) {
        const line = s.found
          ? `${s.id.padEnd(12)} ${s.version ?? ""}`
          : `${s.id.padEnd(12)} not found${s.hint ? ` — ${s.hint}` : ""}`;
        if (s.found) logger.success(line);
        else logger.warn(line);
      }
    }

    logger.heading("SoC target");
    logger.info(`Core config: ${config.soc.coreConfig} (RV${config.soc.xlen})`);
    logger.info(`Frequency: ${config.soc.targetFrequencyMHz} MHz  (period ${ctx.derived.clockPeriodNs.toFixed(3)} ns)`);
    logger.info(`Process/PDK: ${config.soc.process}`);
    logger.info(`Default simulator: ${config.simulation.default}`);

    logger.heading("Workspace");
    logger.info(`Root: ${paths.root} ${existsSync(paths.root) ? "(exists)" : "(not created)"}`);
    logger.info(`Build: ${paths.build}`);
    logger.info(`Tooling: ${paths.tooling}`);

    const missingRequired = statuses.filter(
      (s) => REQUIRED_FOR_TESTS.has(s.id) && !s.found,
    );

    // Compact managed-tool + install hints (full boxes via `probe`)
    logger.heading("Managed tooling (workspace) — see also: probe tools");
    try {
      const report = await gatherProbeReport(ctx);
      for (const t of report.managedTools) {
        if (t.installed) logger.success(`${t.id.padEnd(14)} installed  ${t.pin}`);
        else logger.warn(`${t.id.padEnd(14)} missing   → ${t.installHint}`);
      }
      const blocked = report.commands.filter((c) => c.status === "blocked");
      const partial = report.commands.filter((c) => c.status === "partial");
      if (blocked.length || partial.length) {
        logger.info(
          `Capabilities: ${blocked.length} blocked, ${partial.length} partial — probe commands | probe install`,
        );
      }
    } catch {
      /* non-fatal */
    }

    logger.heading("Verdict");
    if (missingRequired.length === 0) {
      logger.success("Host has the prerequisites for the open-source test flow.");
      logger.info("In-depth: bun run src/cli/index.ts probe");
      return 0;
    }
    logger.error(
      `Missing required tool(s) for tests: ${missingRequired.map((s) => s.id).join(", ")}.`,
    );
    logger.info("Run `bun run src/cli/index.ts setup` to provision the managed toolchain.");
    logger.info("Deep dive: `bun run src/cli/index.ts probe`  (or  probe install)");
    return 1;
  },
};
