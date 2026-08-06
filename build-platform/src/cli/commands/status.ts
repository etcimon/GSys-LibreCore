// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// status.ts — One-glance status of the build platform (setup + parameters).
//
// A lightweight snapshot that ties the whole core → uncore → board → foundry
// flow together: the resolved SoC target, the pinned toolchain + whether it is
// provisioned in the managed workspace, and the subsystem state (tests, vendor,
// motherboard, technology). It installs nothing and probes no host PATH — run
// `doctor` for host readiness and `config` for the full resolved tree.

import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";

import pkg from "../../../package.json";
import { requireContext, type Command } from "../command.ts";
import { resolveBashBinary } from "../../platform/shell.ts";
import { hasBinary } from "../../platform/exec.ts";
import { resolveSvTimingRoot } from "../../tooling/timings.ts";

export const statusCommand: Command = {
  name: "status",
  summary: "One-glance setup + parameters: SoC target, toolchain, workspace, subsystems.",
  usage: "bun run src/cli/index.ts status [--json]",
  details:
    "Prints the current build-platform status: resolved SoC target, pinned\n" +
    "toolchain and whether it is provisioned in build-platform/workspace, and the\n" +
    "core -> uncore -> board -> foundry subsystem state (tests, vendor, motherboard,\n" +
    "technology). Installs/probes nothing; use `doctor` for host readiness and\n" +
    "`config` for the full resolved configuration.",
  examples: [
    "bun run src/cli/index.ts status",
    "bun run src/cli/index.ts status --json",
  ],
  needsContext: true,
  async run(args) {
    const ctx = requireContext(args);
    const { logger, config, paths, tools, derived } = ctx;

    const provisioned: Record<string, boolean> = {
      "riscv-gcc": existsSync(tools.riscvBin),
      verilator: existsSync(tools.verilatorBin),
      spike:
        existsSync(join(tools.spikeBin, "spike")) ||
        existsSync(join(tools.spikeBin, `spike${ctx.host.exeSuffix}`)),
      iverilog: existsSync(tools.iverilogBin),
      python: existsSync(tools.pythonVenvBin),
    };
    const vendorByStatus = { planned: 0, vendored: 0, integrated: 0 };
    for (const c of config.vendor.controllers) vendorByStatus[c.status]++;

    if (args.flags.json) {
      logger.raw(
        JSON.stringify(
          {
            platform: {
              name: pkg.name,
              version: pkg.version,
              repoRoot: ctx.repoRoot,
              config: ctx.configPath,
              overlay: ctx.overlayPath,
            },
            soc: config.soc,
            clockPeriodNs: derived.clockPeriodNs,
            provisioned,
            verify: {
              targets: config.verify.targets,
              formalTasks: config.verify.formalTasks,
              simSuites: config.verify.simSuites,
              stages: config.verify.stages,
            },
            subsystems: {
              tests: { total: config.tests.suites.length, default: config.tests.defaultSuites },
              vendor: { total: config.vendor.controllers.length, ...vendorByStatus },
              motherboard: { activeBoard: config.motherboard.activeBoard },
              technology: {
                optimizationPass: config.technology.optimizationPass,
                pdkMode: config.technology.pdkMode,
                guardMacro: config.technology.guardMacro,
              },
              timings: {
                package: resolveSvTimingRoot(ctx) != null,
                packagesDir: join(paths.build, "sv-timing"),
                staHandoffDir: join(paths.build, "sta-handoff"),
              },
              simHost: {
                bash: resolveBashBinary(),
                yosys: hasBinary("yosys"),
                opensta: hasBinary("sta") || hasBinary("opensta"),
                openroad: hasBinary("openroad"),
              },
            },
          },
          null,
          2,
        ) + "\n",
      );
      return 0;
    }

    const mark = (b: boolean): string => (b ? "installed" : "missing  ");

    logger.heading(`${pkg.name ?? "@cva6/build-platform"} v${pkg.version ?? "0.0.0"} — status`);
    logger.info(`repo root : ${ctx.repoRoot}`);
    logger.info(`config    : ${ctx.configPath ?? "(defaults only)"}`);
    if (ctx.overlayPath) logger.info(`overlay   : ${ctx.overlayPath}`);

    logger.heading("SoC target (CPU)");
    logger.info(`core config : ${config.soc.coreConfig} (RV${config.soc.xlen})`);
    logger.info(
      `frequency   : ${config.soc.targetFrequencyMHz} MHz (period ${derived.clockPeriodNs.toFixed(3)} ns) @ ${config.soc.targetVoltageV} V`,
    );
    logger.info(`process/PDK : ${config.soc.process}`);
    logger.info(`default sim : ${config.simulation.default}`);

    logger.heading("Toolchain (pinned) + workspace provisioning");
    logger.info(`riscv-gcc  : ${mark(provisioned["riscv-gcc"]!)} ${config.toolchain.riscvGcc.version}`);
    logger.info(`verilator  : ${mark(provisioned.verilator!)} ${config.toolchain.versions.verilator}`);
    logger.info(`spike      : ${mark(provisioned.spike!)} ${config.toolchain.versions.spike}`);
    logger.info(`iverilog   : ${mark(provisioned.iverilog!)} ${config.toolchain.versions.iverilog}`);
    logger.info(`python venv: ${mark(provisioned.python!)} (>= ${config.toolchain.python.minVersion})`);
    logger.info(`workspace  : ${paths.root} ${existsSync(paths.root) ? "(exists)" : "(not created)"}`);

    logger.heading("Subsystems (core -> uncore -> board -> foundry)");
    logger.info(`tests      : ${config.tests.suites.length} suites (default: ${config.tests.defaultSuites.join(", ")})`);
    logger.info(
      `vendor     : ${config.vendor.controllers.length} controllers (integrated ${vendorByStatus.integrated}, vendored ${vendorByStatus.vendored}, planned ${vendorByStatus.planned})`,
    );
    logger.info(`motherboard: ${config.motherboard.activeBoard ?? "(no active board)"}`);
    logger.info(
      `technology : pass ${config.technology.optimizationPass ? "on" : "off"} (pdk ${config.technology.pdkMode}, guard ${config.technology.guardMacro})`,
    );

    logger.heading("Verify gate (AGENTS.md §0.2)");
    logger.info(`targets    : ${config.verify.targets.join(", ")}`);
    logger.info(
      `formal     : ${config.verify.formalTasks.length} task(s)` +
        (config.verify.formalTasks.length
          ? ` (${config.verify.formalTasks.map((t) => t.split("/").pop()).join(", ")})`
          : " — empty; set verify.formalTasks"),
    );
    logger.info(`sim suites : ${config.verify.simSuites.join(", ")}`);
    logger.info(
      "opt-in pkgs: g6lc64_ooo, g6lc64_ooo_server, g6lc64_server_math, g6lc64_stream8, g6lc64_smt2, cv64a6_spec_deep",
    );
    logger.info(
      "opt-in test: mc-stream-tests, ooo-l3-tests, server-math-tests, dual-hart-ci, timings-sta-handoff, sv-timing-*",
    );

    logger.heading("Timings / STA handoff");
    const svt = resolveSvTimingRoot(ctx);
    logger.info(`sv-timing  : ${svt ? svt : "NOT FOUND (repo-root/sv-timing)"}`);
    const tdir = join(paths.build, "sv-timing");
    const sdir = join(paths.build, "sta-handoff");
    let npkg = 0;
    let nsta = 0;
    try {
      if (existsSync(tdir)) npkg = readdirSync(tdir).length;
    } catch {
      /* ignore */
    }
    try {
      if (existsSync(sdir)) nsta = readdirSync(sdir).length;
    } catch {
      /* ignore */
    }
    logger.info(`packages   : ${tdir} (${npkg} entr${npkg === 1 ? "y" : "ies"})`);
    logger.info(`sta-handoff: ${sdir} (${nsta} entr${nsta === 1 ? "y" : "ies"})`);
    const bash = resolveBashBinary();
    logger.info(
      `sim bash   : ${bash ? `${bash.flavor} ${bash.path ?? bash.bin}` : "missing (Git-Bash preferred on Windows)"}`,
    );
    logger.info(
      `PD tools   : yosys ${hasBinary("yosys") ? "yes" : "no"}  opensta ${hasBinary("sta") || hasBinary("opensta") ? "yes" : "no"}  openroad ${hasBinary("openroad") ? "yes" : "no"}`,
    );

    const anyProvisioned = Object.values(provisioned).some(Boolean);
    logger.heading("Next steps");
    if (!anyProvisioned) {
      logger.info("setup   : g6lc-build setup --install    provision the open-source toolchain");
    }
    logger.info("doctor  : g6lc-build doctor             host readiness (installs nothing)");
    logger.info("probe   : g6lc-build probe              in-depth capability boxes + install help");
    logger.info("verify  : g6lc-build verify --lint      per-change gate (lint/formal/sim/synth)");
    logger.info("test    : g6lc-build test timings-sta-handoff   S0–S2 timings/STA smoke");
    logger.info("timings : g6lc-build timings sta-handoff --try-tools --from-timing <pkg>");
    logger.info("board   : g6lc-build mb list            select/build a motherboard (around the die)");
    logger.info("vendor  : g6lc-build vendor list        uncore controllers + PHY (ara = U10ᵇ)");
    logger.info("foundry : g6lc-build tech status        technology / PDK optimization for tape-out");
    logger.info("alias   : cva6-build is a permanent equivalent of g6lc-build");
    return 0;
  },
};
