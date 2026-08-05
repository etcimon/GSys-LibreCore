// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// tools.ts — Managed tool status + install profiles.

import { existsSync } from "node:fs";
import { join } from "node:path";

import { requireContext, type Command } from "../command.ts";
import { flagBool } from "../args.ts";
import {
  installProfile,
  installRecipeById,
  listInstallProfiles,
  resolveInstallProfile,
} from "../../tooling/installProfiles.ts";
import { isSpikeInstalled } from "../../tooling/recipes.ts";

interface ManagedTool {
  id: string;
  version: string;
  binDir: string;
  bin: string;
}

export const toolsCommand: Command = {
  name: "tools",
  summary: "List managed tools / install profiles; install sim or dual-hart stacks.",
  usage:
    "bun run src/cli/index.ts tools [list|install] [<profile|recipe>] [--profile <id>] [--force] [--json] [--dry-run]",
  details:
    "Without args: list managed tool pins and install status under workspace/tooling.\n" +
    "\n" +
    "  tools install              list install profiles\n" +
    "  tools install sim          RISC-V GCC + Verilator + Spike (Linux/WSL) + Icarus detect\n" +
    "  tools install dual-hart    RISC-V GCC + OpenSBI SMT2 fw_payload (scripts)\n" +
    "  tools install opensbi      OpenSBI SMT2 only (needs riscv-gcc)\n" +
    "  tools install all          sim + dual-hart\n" +
    "  tools install riscv-gcc    single recipe\n" +
    "  tools install spike        Spike ISS (Linux native; Windows via WSL)\n" +
    "\n" +
    "Profiles map to recipes in tooling/installProfiles.ts. OpenSBI uses\n" +
    "software/smt2-linux/scripts/build-opensbi-smt2.{ps1,sh} (Windows: Cygwin make\n" +
    "+ xPack wrap). Spike builds under Linux/WSL only (Cygwin unsupported);\n" +
    "on Windows, `tools install spike` drives WSL into workspace/tooling/spike.\n" +
    "Equivalent: setup --install --profile dual-hart",
  examples: [
    "bun run src/cli/index.ts tools",
    "bun run src/cli/index.ts tools install",
    "bun run src/cli/index.ts tools install dual-hart",
    "bun run src/cli/index.ts tools install sim --force",
    "bun run src/cli/index.ts tools install --profile all",
  ],
  needsContext: true,
  async run(args) {
    const ctx = requireContext(args);
    const { logger, config, tools, host } = ctx;
    const sub = args.positionals[0] ?? "list";
    const force = flagBool(args.flags, "force");
    const dryRun = ctx.dryRun || flagBool(args.flags, "dry-run");

    // --- install subcommand ---
    if (sub === "install") {
      const want =
        (typeof args.flags.profile === "string" ? args.flags.profile : null) ??
        args.positionals[1] ??
        null;

      if (!want) {
        logger.heading("Install profiles");
        for (const p of listInstallProfiles()) {
          logger.info(`  ${p.id.padEnd(16)} ${p.summary}`);
          logger.info(`                   recipes: ${p.recipeIds.join(", ")}`);
        }
        logger.info("");
        logger.info("Recipes: riscv-gcc | verilator | spike | iverilog | opensbi-smt2");
        logger.info("Example: bun run src/cli/index.ts tools install dual-hart");
        return 0;
      }

      const profile = resolveInstallProfile(want);
      if (profile) {
        logger.heading(`Install profile: ${profile.id}`);
        logger.info(profile.summary);
        const results = await installProfile(ctx, profile.id, { force, dryRun });
        const failed = results.filter((r) => !r.ok && !r.skipped);
        const skipped = results.filter((r) => r.skipped);
        logger.heading("Install summary");
        for (const r of results) {
          const mark = r.ok ? (r.skipped ? "skip" : "ok  ") : "FAIL";
          logger.info(`  ${mark}  ${r.id}${r.reason ? ` — ${r.reason}` : ""}`);
        }
        if (failed.length) {
          logger.error(`failed: ${failed.map((f) => f.id).join(", ")}`);
          return 1;
        }
        if (skipped.length && !results.some((r) => r.ok && !r.skipped)) {
          logger.warn("all steps skipped (already installed or platform-deferred)");
        }
        logger.success(`profile ${profile.id} complete`);
        return 0;
      }

      // Single recipe
      logger.heading(`Install recipe: ${want}`);
      const result = await installRecipeById(ctx, want, { force, dryRun });
      const mark = result.ok ? (result.skipped ? "skip" : "ok  ") : "FAIL";
      logger.info(`  ${mark}  ${result.id}${result.reason ? ` — ${result.reason}` : ""}`);
      return result.ok ? 0 : 1;
    }

    // --- default list ---
    const managed: ManagedTool[] = [
      {
        id: "riscv-gcc",
        version: config.toolchain.riscvGcc.version,
        binDir: tools.riscvBin,
        bin: `${config.toolchain.riscvGcc.toolPrefix ?? "riscv-none-elf-"}gcc${host.exeSuffix}`,
      },
      {
        id: "verilator",
        version: config.toolchain.versions.verilator,
        binDir: tools.verilatorBin,
        bin: `verilator${host.exeSuffix}`,
      },
      {
        id: "spike",
        version: config.toolchain.versions.spike,
        binDir: tools.spikeBin,
        bin: `spike${host.exeSuffix}`,
      },
      {
        id: "iverilog",
        version: config.toolchain.versions.iverilog,
        binDir: tools.iverilogBin,
        bin: `iverilog${host.exeSuffix}`,
      },
      {
        id: "python-venv",
        version: `>= ${config.toolchain.python.minVersion}`,
        binDir: tools.pythonVenvBin,
        bin: host.os === "windows" ? "python.exe" : "python3",
      },
      {
        id: "opensbi-smt2",
        version: "v1.5/generic",
        binDir: join(ctx.repoRoot, "build-platform", "workspace", "smt2-linux"),
        bin: "fw_payload.elf",
      },
    ];

    const rows = managed.map((t) => {
      const installed =
        existsSync(join(t.binDir, t.bin)) ||
        (t.id === "spike" && isSpikeInstalled(t.binDir, host.exeSuffix)) ||
        (t.id === "opensbi-smt2" && existsSync(join(t.binDir, "fw_payload.elf")));
      return { ...t, installed };
    });

    if (args.flags.json) {
      logger.raw(
        JSON.stringify(
          {
            tools: rows,
            profiles: listInstallProfiles(),
          },
          null,
          2,
        ) + "\n",
      );
      return 0;
    }

    logger.heading("Managed tools (workspace/tooling)");
    for (const r of rows) {
      const line = `${r.id.padEnd(14)} ${String(r.version).padEnd(18)} ${r.installed ? "installed" : "not installed"}  ${r.binDir}`;
      if (r.installed) logger.success(line);
      else logger.info(line);
    }

    logger.heading("Install profiles");
    for (const p of listInstallProfiles()) {
      logger.info(`  ${p.id.padEnd(16)} ${p.summary}`);
    }

    logger.info("");
    logger.info("Install: bun run src/cli/index.ts tools install <sim|dual-hart|opensbi|all|recipe>");
    logger.info("Or:      bun run src/cli/index.ts setup --install --profile dual-hart");
    return 0;
  },
};
