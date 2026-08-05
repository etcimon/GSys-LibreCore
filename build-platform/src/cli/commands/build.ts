// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// build.ts — Build the simulation model for the configured target/simulator.
//
// Uses workspace discovery (size+mtime manifests) so a second `build` with
// unchanged RTL inputs is a no-op. Pass --force to rebuild anyway.

import { requireContext, type Command } from "../command.ts";
import { flagBool, flagString } from "../args.ts";
import { childEnv } from "../../context.ts";
import { hasBinary, run } from "../../platform/exec.ts";
import { applyFromTimingFlags } from "../../tooling/timings.ts";
import { ensureWorkspace } from "../../workspace/layout.ts";
import {
  commitManifest,
  detectChanges,
  discoverFiles,
} from "../../workspace/discovery.ts";

/** Inputs that affect a Verilator model build for the active target. */
const BUILD_INPUT_GLOBS = [
  "core/**/*.sv",
  "core/**/*.svh",
  "core/**/*.vlt",
  "core/Flist.cva6",
  "core/Flist.cva6_gate",
  "core/include/**/*",
  "Makefile",
  "verilator_config.vlt",
];

export const buildCommand: Command = {
  name: "build",
  summary: "Build the RTL simulation model (Verilator on the open-source path).",
  usage:
    "bun run src/cli/index.ts build [--iss <sim>] [--elf <path>] [--force] [--from-timing DIR] [--use-emit] [--dry-run]",
  details:
    "Drives the repo Makefile with the managed toolchain environment. With no\n" +
    "--elf it verilates the model (`make verilate`); with --elf it also runs the\n" +
    "model (`make sim-verilator`). Non-Verilator simulators are detect-only in\n" +
    "this pass.\n" +
    "Incremental: fingerprints core RTL + flists under workspace/.cache/manifests\n" +
    "and skips verilate when inputs are unchanged. Use --force to rebuild.\n" +
    "\n" +
    "Expert timings hand-off:\n" +
    "  --from-timing DIR   validate precompile out-dir structure first\n" +
    "  --use-emit          (with --from-timing) point child env at corrected flist\n" +
    "                      when present; never merges into core/ (default off)",
  needsContext: true,
  async run(args) {
    const ctx = requireContext(args);
    const { logger, config, repoRoot, paths } = ctx;
    const sim = flagString(args.flags, "iss") ?? config.simulation.default;
    const force = args.flags.force === true;

    logger.heading(`Build — ${sim}, target ${config.soc.coreConfig}`);

    if (sim !== "verilator") {
      logger.warn(
        `Simulator '${sim}' is detect-only in the open-source-sim pass; ` +
          "use `--iss verilator` for the auto-buildable flow.",
      );
      return 2;
    }
    if (!hasBinary("make")) {
      logger.error(
        "`make` not found on PATH. Run `bun run src/cli/index.ts setup` and install prerequisites.",
      );
      return 1;
    }

    const elf = flagString(args.flags, "elf");
    // Incremental skip only applies to pure verilate (no ELF run).
    if (!elf && !force) {
      await ensureWorkspace(paths);
      const files = await discoverFiles(BUILD_INPUT_GLOBS, {
        cwd: repoRoot,
        exclude: ["**/formal/**", "**/*_props.sv"],
      });
      const manifestKey = `verilate-${config.soc.coreConfig}`;
      const report = await detectChanges(paths.manifests, manifestKey, files);
      if (!report.changed) {
        logger.success(
          `Build inputs unchanged (${files.length} files); skipping verilate. Use --force to rebuild.`,
        );
        return 0;
      }
      const delta =
        report.added.length + report.removed.length + report.modified.length;
      logger.info(
        `Build inputs changed: ${delta} path(s) vs last successful verilate (${files.length} tracked).`,
      );
    } else if (force) {
      logger.info("--force: rebuilding regardless of input fingerprints.");
    }

    const fromTiming = flagString(args.flags, "from-timing");
    const useEmit = flagBool(args.flags, "use-emit");
    if (useEmit && !fromTiming) {
      logger.error("--use-emit requires --from-timing <dir>");
      return 2;
    }
    const ft = applyFromTimingFlags(ctx, {
      fromTiming,
      useEmit,
      requireEmit: useEmit,
    });
    if (!ft.ok) {
      logger.error(`--from-timing structure invalid: ${ft.dir ?? fromTiming}`);
      for (const issue of ft.issues.filter((i) => i.level === "error")) {
        logger.error(`  [${issue.code}] ${issue.message}`);
      }
      return 1;
    }
    if (fromTiming) {
      logger.success(`--from-timing OK: ${ft.dir}`);
      if (useEmit && ft.emitFlist) {
        logger.warn(
          `expert --use-emit: CVA6_TIMINGS_EMIT_FLIST=${ft.emitFlist} (live Makefile flist unchanged unless consumer reads env)`,
        );
      }
    }

    const target = elf ? "sim-verilator" : "verilate";
    const makeArgs = [target, `target=${config.soc.coreConfig}`];
    if (elf) makeArgs.push(`elf_file=${elf}`);

    const env = childEnv(ctx, ft.env);
    if (ctx.dryRun) {
      logger.info(`[dry-run] make ${makeArgs.join(" ")}  (cwd: ${repoRoot})`);
      return 0;
    }

    const result = await run("make", makeArgs, {
      cwd: repoRoot,
      env,
      logger,
      allowFailure: true,
    });
    if (result.ok) {
      logger.success(`Build finished in ${(result.durationMs / 1000).toFixed(1)}s`);
      // Commit fingerprints only after a successful pure verilate.
      if (!elf) {
        await ensureWorkspace(paths);
        const files = await discoverFiles(BUILD_INPUT_GLOBS, {
          cwd: repoRoot,
          exclude: ["**/formal/**", "**/*_props.sv"],
        });
        const report = await detectChanges(
          paths.manifests,
          `verilate-${config.soc.coreConfig}`,
          files,
        );
        await commitManifest(report);
      }
      return 0;
    }
    logger.error(`Build failed (exit ${result.code}).`);
    return result.code || 1;
  },
};
