// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// config.ts — Print the resolved configuration and its provenance.

import { requireContext, type Command } from "../command.ts";

export const configCommand: Command = {
  name: "config",
  summary: "Show the resolved configuration (defaults + .config.ts overlays).",
  usage: "bun run src/cli/index.ts config [--json]",
  details:
    "Merges defaults.ts, the repo-root .config.ts, and the optional local\n" +
    "overlay, validates the result, and prints it. Use --json for the full tree.",
  needsContext: true,
  async run(args) {
    const ctx = requireContext(args);
    const { logger, config } = ctx;

    if (args.flags.json) {
      logger.raw(JSON.stringify(config, null, 2) + "\n");
      return 0;
    }

    logger.heading("Provenance");
    logger.info(`Repo root : ${ctx.repoRoot}`);
    logger.info(`Config    : ${ctx.configPath ?? "(defaults only)"}`);
    logger.info(`Overlay   : ${ctx.overlayPath ?? "(none)"}`);

    logger.heading("SoC");
    logger.info(`coreConfig       : ${config.soc.coreConfig}`);
    logger.info(`xlen             : ${config.soc.xlen}`);
    logger.info(`extensions       : ${config.soc.extensions.join(", ")}`);
    logger.info(`frequency (MHz)  : ${config.soc.targetFrequencyMHz}`);
    logger.info(`voltage (V)      : ${config.soc.targetVoltageV}`);
    logger.info(`process/PDK      : ${config.soc.process}`);
    logger.info(`clock period (ns): ${ctx.derived.clockPeriodNs.toFixed(3)}`);

    logger.heading("Toolchain (pinned versions)");
    logger.info(`riscv-gcc : ${config.toolchain.riscvGcc.version} (${config.toolchain.riscvGcc.source})`);
    logger.info(`verilator : ${config.toolchain.versions.verilator}`);
    logger.info(`spike     : ${config.toolchain.versions.spike}`);
    logger.info(`iverilog  : ${config.toolchain.versions.iverilog}`);
    logger.info(`python    : >= ${config.toolchain.python.minVersion}`);

    logger.heading("Simulation");
    logger.info(`enabled : ${config.simulation.enabled.join(", ")}`);
    logger.info(`default : ${config.simulation.default}`);
    logger.info(`maxCycles: ${config.simulation.maxCycles}`);

    logger.heading("Tests");
    logger.info(`default suites : ${config.tests.defaultSuites.join(", ")}`);
    logger.info(`all suites     : ${config.tests.suites.map((s) => s.id).join(", ")}`);
    logger.info(`parallelism    : ${config.tests.parallelism}`);

    logger.heading("Dependencies (submodules)");
    for (const [id, spec] of Object.entries(config.dependencies.submodules)) {
      logger.info(`${id.padEnd(14)} ${spec.enabled ? "[on] " : "[off]"} ${spec.ref ?? "(default ref)"} → ${spec.path}`);
    }

    logger.heading("Vendor (uncore controllers + PHY)");
    const byStatus = { planned: 0, vendored: 0, integrated: 0 };
    for (const c of config.vendor.controllers) byStatus[c.status]++;
    logger.info(
      `catalog: ${config.vendor.controllers.length} (planned ${byStatus.planned}, vendored ${byStatus.vendored}, integrated ${byStatus.integrated})`,
    );
    logger.info("Manage with: vendor list | vendor status | vendor sync <id>");

    logger.heading("Physical design");
    logger.info(`flow : ${config.physicalDesign.flow}`);
    if (config.physicalDesign.pdk) {
      logger.info(`pdk  : ${config.physicalDesign.pdk.name}`);
    }

    return 0;
  },
};
