// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// build.ts — Build the simulation model for the configured target/simulator.
//
// Uses workspace discovery (size+mtime manifests) so a second `build` with
// unchanged RTL inputs is a no-op. Pass --force to rebuild anyway.

import { join } from "node:path";

import { requireContext, type Command } from "../command.ts";
import { flagBool, flagString } from "../args.ts";
import { childEnv } from "../../context.ts";
import { hasBinary, run } from "../../platform/exec.ts";
import { resolveBashBinary, runBashScript } from "../../platform/shell.ts";
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
    "bun run src/cli/index.ts build [--iss <sim>] [--elf <path>] [--force] [--make] [--no-pgo] [--from-timing DIR] [--use-emit] [--dry-run]",
  details:
    "Builds the model with the build of record (simulation.verilator.recipe =\n" +
    "harness): verif/regress/soft-ladder-build-harness.sh with the configured\n" +
    "Verilator flavour (g6lc fork by default), the split-loops .vlt, -O2 and\n" +
    "PGO (instrument -> in-repo training probe -> -fprofile-use). --make (or\n" +
    "recipe: make) drives the plain repo Makefile (`make verilate`) instead;\n" +
    "--no-pgo skips the profile round. With --elf the built model runs the ELF.\n" +
    "Non-Verilator simulators are detect-only in this pass.\n" +
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

    const env = childEnv(ctx, ft.env);
    const vopts = config.simulation.verilator;
    const bash = resolveBashBinary();
    let recipe: "harness" | "make" = flagBool(args.flags, "make") ? "make" : vopts.recipe;
    if (recipe === "harness" && !bash) {
      logger.warn("no bash found for the harness recipe; falling back to `make verilate`");
      recipe = "make";
    }
    const pgo = flagBool(args.flags, "no-pgo") ? false : vopts.pgo;
    const verlib = join(repoRoot, "work-ver");

    let result;
    if (recipe === "harness") {
      // The build of record: flavour, split .vlt, -O2, PGO all resolved by the
      // harness from this environment (childEnv carries VLT_HOME and the flavour).
      const harnessEnv: Record<string, string> = {
        ...env,
        SOFT_LADDER_BUILD_TARGET: config.soc.coreConfig,
        SOFT_LADDER_VERLIB: verlib,
        SOFT_LADDER_VERILATOR_THREADS: vopts.threads > 0 ? String(vopts.threads) : "4",
        SOFT_LADDER_BUILD_PGO: pgo ? "1" : "0",
        SOFT_LADDER_BUILD_SPLIT_VLT: vopts.splitVlt ? "1" : "0",
        SOFT_LADDER_BUILD_OPT: vopts.opt,
        ...(vopts.trace ? (vopts.traceFormat === "vcd" ? { SOFT_LADDER_BUILD_TRACE_FAST: "1" } : { SOFT_LADDER_BUILD_TRACE_COMPACT: "1" }) : {}),
      };
      const script = "verif/regress/soft-ladder-build-harness.sh";
      if (ctx.dryRun) {
        logger.info(`[dry-run] ${script} B  (target ${config.soc.coreConfig}, pgo=${pgo}, split=${vopts.splitVlt}, opt=${vopts.opt}, threads=${harnessEnv.SOFT_LADDER_VERILATOR_THREADS}; cwd: ${repoRoot})`);
        if (elf) logger.info(`[dry-run] ${verlib}/Variane_testharness ${elf}`);
        return 0;
      }
      result = await runBashScript(script, ["B"], { cwd: repoRoot, env: harnessEnv, logger, allowFailure: true });
      if (result.ok && elf) {
        result = await run(join(verlib, "Variane_testharness"), [elf], { cwd: repoRoot, env, logger, allowFailure: true });
      }
    } else {
      const target = elf ? "sim-verilator" : "verilate";
      const makeArgs = [target, `target=${config.soc.coreConfig}`];
      if (elf) makeArgs.push(`elf_file=${elf}`);
      if (ctx.dryRun) {
        logger.info(`[dry-run] make ${makeArgs.join(" ")}  (cwd: ${repoRoot})`);
        return 0;
      }
      result = await run("make", makeArgs, { cwd: repoRoot, env, logger, allowFailure: true });
    }
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
