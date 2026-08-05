// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// verify.ts — The per-change gate: lint, formal, simulation, synthesis.
//
// AGENTS.md §0.2 makes every RTL change prove it is synth-clean, verified and
// timing-aware. This command is that proof, runnable after *every* consecutive
// change rather than once at the end of a feature:
//
//   g6lc-build verify                 # all configured stages, all targets
//   g6lc-build verify --lint          # one stage
//   g6lc-build verify --target g6lc64_ooo_server
//
// Exit codes: 0 = gate passed, 1 = a stage failed, 3 = tools missing.

import { requireContext, type Command } from "../command.ts";
import { flagBool, flagString } from "../args.ts";
import {
  edaPaths,
  edaPresence,
  elaborateTarget,
  formalTask,
  lintTarget,
  synthTarget,
  type GateStageId,
  type StageOutcome,
} from "../../tooling/eda.ts";
import { applyFromTimingFlags } from "../../tooling/timings.ts";
import {
  assessSimPreflight,
  formatSimPreflightLines,
} from "../../tooling/simPreflight.ts";
import { runSuites, selectSuites } from "../../tests/runner.ts";
import { offerInstallMissingTools } from "../../tooling/offerInstall.ts";
import type { ManagedTool } from "../../config/schema.ts";

const STAGES: GateStageId[] = ["lint", "formal", "sim", "synth"];

/** Stages requested on the command line, or the configured default set. */
function requestedStages(
  flags: Record<string, unknown>,
  defaults: Record<GateStageId, boolean>,
): GateStageId[] {
  const explicit = STAGES.filter((s) => flags[s] === true);
  if (explicit.length > 0) return explicit;
  return STAGES.filter((s) => defaults[s]);
}

function symbol(status: StageOutcome["status"]): string {
  return status === "pass" ? "PASS" : status === "fail" ? "FAIL" : "SKIP";
}

export const verifyCommand: Command = {
  name: "verify",
  summary: "Run the per-change gate: lint, formal, simulation, synthesis.",
  usage:
    "bun run src/cli/index.ts verify [--lint] [--formal] [--sim] [--synth] [--target <cfg>] [--from-timing DIR] [--use-emit] [--yes] [--json] [--dry-run]",
  details:
    "Runs the AGENTS.md §0.2 verification gate with the open EDA suite pinned in\n" +
    ".config.ts (verify.suite). Stages:\n" +
    "  lint   Verilator --lint-only over core/Flist.cva6 + strict slang elaboration,\n" +
    "         swept across every config-package target in verify.targets so a change\n" +
    "         cannot break the 'minimal configs still elaborate' rule.\n" +
    "  formal SymbiYosys task files listed in verify.formalTasks (bounded proofs).\n" +
    "  sim    The regression suites in verify.simSuites (needs bash + a toolchain).\n" +
    "  synth  Yosys + yosys-slang elaboration to generic gates: proves the change is\n" +
    "         synthesizable and surfaces inferred latches early.\n" +
    "With no stage flag, the stages enabled in verify.stages all run.\n" +
    "\n" +
    "  --from-timing DIR  validate timings precompile package before stages\n" +
    "  --use-emit         expert: export emit flist env for sim consumers (default off)\n" +
    "  --yes / -y         auto-accept tools install when managed tools are missing",
  examples: [
    "verify",
    "verify --lint",
    "verify --lint --synth --target g6lc64_ooo_server",
    "verify --json",
    "verify --lint --from-timing workspace/build/sv-timing/host-cv64a6_imafdc_sv39",
  ],
  needsContext: true,
  async run(args) {
    const ctx = requireContext(args);
    const { logger, config } = ctx;
    const paths = edaPaths(ctx);
    let presence = edaPresence(paths);

    if (args.flags.tools) {
      logger.heading(`OSS CAD Suite (pinned ${config.verify.suite.version})`);
      for (const t of presence) {
        const line = `${t.id.padEnd(12)} ${t.present ? "present" : "MISSING"}  ${t.path}`;
        if (t.present) logger.success(line);
        else logger.warn(line);
      }
      return presence.some((t) => t.required && !t.present) ? 3 : 0;
    }

    // Managed tools (Verilator via tools install) before OSS CAD suite path check.
    if (!ctx.dryRun) {
      const want: ManagedTool[] = ["verilator", "riscv-gcc"];
      await offerInstallMissingTools(ctx, want, args.flags as Record<string, string | boolean>);
      presence = edaPresence(paths);
    }

    const missingRequired = presence.filter((t) => t.required && !t.present);
    if (missingRequired.length > 0 && !ctx.dryRun) {
      logger.error(
        `Verification gate unavailable: missing ${missingRequired.map((t) => t.id).join(", ")}.`,
      );
      logger.info(`Expected under ${paths.root}`);
      logger.info(
        "Install: g6lc-build tools install sim   or extract the OSS CAD Suite / set verify.suite.root.",
      );
      return 3;
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
      if (useEmit) {
        logger.info(
          "expert --use-emit: emit flist overlay enabled for Verilator/slang manifests (basename *__svt.sv → live file)",
        );
      }
      Object.assign(process.env, ft.env);
    }

    const stages = requestedStages(args.flags as Record<string, unknown>, config.verify.stages);
    const targetFlag = typeof args.flags.target === "string" ? args.flags.target : null;
    const targets = targetFlag ? [targetFlag] : config.verify.targets;
    const outcomes: StageOutcome[] = [];

    for (const stage of stages) {
      if (stage === "lint") {
        logger.heading(`Lint + elaboration (${targets.length} target(s))`);
        for (const target of targets) {
          outcomes.push(await lintTarget(ctx, paths, target));
          outcomes.push(await elaborateTarget(ctx, paths, target));
        }
      } else if (stage === "synth") {
        logger.heading("Synthesis smoke");
        for (const target of targets) {
          outcomes.push(await synthTarget(ctx, paths, target));
        }
      } else if (stage === "formal") {
        logger.heading("Formal (SymbiYosys)");
        if (config.verify.formalTasks.length === 0) {
          outcomes.push({
            stage: "formal",
            target: null,
            status: "skip",
            detail: "no tasks configured (verify.formalTasks is empty)",
            durationMs: 0,
          });
        }
        for (const task of config.verify.formalTasks) {
          outcomes.push(await formalTask(ctx, paths, task));
        }
      } else {
        logger.heading("Simulation");
        const pre = assessSimPreflight(ctx);
        for (const line of formatSimPreflightLines(pre)) {
          if (line.includes("NEED") || line.includes("NOT READY")) logger.error(line);
          else if (line.includes("warn") || line.includes("Cygwin")) logger.warn(line);
          else logger.info(line);
        }
        if (!pre.canAttemptSim && !ctx.dryRun) {
          outcomes.push({
            stage: "sim",
            target: null,
            status: "fail",
            detail:
              "sim preflight failed — " +
              pre.items
                .filter((i) => i.required && !i.ok)
                .map((i) => i.id)
                .join(", "),
            durationMs: 0,
          });
        } else {
          const { suites, unknown } = selectSuites(config, config.verify.simSuites);
          for (const id of unknown) {
            outcomes.push({
              stage: "sim",
              target: id,
              status: "fail",
              detail: "unknown suite id",
              durationMs: 0,
            });
          }
          const results = await runSuites(ctx, suites, {
            dryRun: ctx.dryRun,
            fromTimingDir: ft.dir,
          });
          for (const r of results) {
            outcomes.push({
              stage: "sim",
              target: r.id,
              status: r.skipped ? "skip" : r.ok ? "pass" : "fail",
              detail: r.reason ?? (r.ok ? "ok" : `exit ${r.code}`),
              durationMs: r.durationMs ?? 0,
            });
          }
        }
      }
    }

    if (args.flags.json) {
      logger.raw(JSON.stringify({ stages, targets, outcomes }, null, 2) + "\n");
    } else {
      logger.heading("Gate summary");
      for (const o of outcomes) {
        const line = `${symbol(o.status).padEnd(5)} ${o.stage.padEnd(7)} ${(o.target ?? "-").padEnd(22)} ${o.detail} (${o.durationMs} ms)`;
        if (o.status === "pass") logger.success(line);
        else if (o.status === "fail") logger.error(line);
        else logger.info(line);
      }
      for (const o of outcomes) {
        if (o.status !== "fail" || !o.log?.length) continue;
        logger.heading(`${o.stage} log — ${o.target ?? "-"}`);
        for (const l of o.log) logger.raw(`  ${l}\n`);
      }
    }

    const failed = outcomes.filter((o) => o.status === "fail");
    if (failed.length > 0) {
      logger.error(`Gate failed: ${failed.length} of ${outcomes.length} step(s).`);
      return 1;
    }
    logger.success(`Gate passed: ${outcomes.length} step(s).`);
    return 0;
  },
};
