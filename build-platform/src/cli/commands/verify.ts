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
// Exit codes: 0 = gate passed, 1 = a stage failed, 3 = tools missing,
//             4 = incomplete (a stage was skipped and did not run).

import { requireContext, type Command } from "../command.ts";
import { flagBool, flagString } from "../args.ts";
import {
  edaPaths,
  edaPresence,
  elaborateTarget,
  runFormalTasks,
  lintTarget,
  lintTargetsRemote,
  synthTarget,
  synthTargetsRemote,
  type GateStageId,
  type StageOutcome,
} from "../../tooling/eda.ts";
import { applyFromTimingFlags } from "../../tooling/timings.ts";
import {
  assessSimPreflight,
  formatSimPreflightLines,
} from "../../tooling/simPreflight.ts";
import { runSuite, runSuites, selectSuites, selectQualification, type QualificationSelection } from "../../tests/runner.ts";
import { offerInstallMissingTools } from "../../tooling/offerInstall.ts";
import type { ManagedTool } from "../../config/schema.ts";
import {
  applyAiEnv,
  formatAiResolvedLine,
  parseAiFlagErrors,
  parseAiFlags,
  resolveAiTesting,
} from "../../tooling/aiTesting.ts";

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

/**
 * The gate verdict. A skipped step is not a passed step: announcing
 * "Gate passed" while stages did not run is how a plan gets mistaken for
 * evidence, so skips make the verdict incomplete (exit 4) unless accepted
 * explicitly, and a dry run never reports a gate result at all.
 */
export function gateVerdict(
  outcomes: StageOutcome[],
  opts: { dryRun: boolean; allowSkips: boolean; qualified: boolean },
): { code: number; level: "success" | "error" | "info"; message: string } {
  const failed = outcomes.filter((o) => o.status === "fail");
  if (failed.length > 0) {
    return {
      code: 1,
      level: "error",
      message: `Gate failed: ${failed.length} of ${outcomes.length} step(s).`,
    };
  }
  if (opts.dryRun) {
    return {
      code: 0,
      level: "info",
      message: `Dry run: ${outcomes.length} step(s) planned, none executed. This is not a gate result.`,
    };
  }
  const skipped = outcomes.filter((o) => o.status === "skip");
  if (skipped.length > 0 && !opts.allowSkips) {
    return {
      code: 4,
      level: "error",
      message:
        `Gate incomplete: ${skipped.length} of ${outcomes.length} step(s) did not run ` +
        `(${skipped.map((o) => `${o.stage}/${o.target ?? "-"}`).join(", ")}). ` +
        `A skipped step qualifies nothing; pass --allow-skips to accept this run.`,
    };
  }
  const suffix = skipped.length > 0 ? ` (${skipped.length} skipped, accepted by --allow-skips)` : "";
  return {
    code: 0,
    level: "success",
    message: `${opts.qualified ? "Simulation evidence qualified" : "Gate passed"}: ${outcomes.length} step(s)${suffix}.`,
  };
}

export const verifyCommand: Command = {
  name: "verify",
  summary: "Run the per-change gate: lint, formal, simulation, synthesis.",
  usage:
    "bun run src/cli/index.ts verify [--lint] [--formal] [--sim] [--synth] [--target <cfg>] [--qualification <profile>] [--ai] [--from-timing DIR] [--use-emit] [--remote] [--allow-skips] [--yes] [--json] [--dry-run]",
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
    "  --qualification P with --sim: require target-specific, fresh remote RTL evidence\n" +
    "                    from verify.qualifications[P]; skips/fallbacks cannot qualify.\n" +
    "                    This qualifies simulation only, not full RTL or PPA sign-off.\n" +
    "  --from-timing DIR  validate timings precompile package before stages\n" +
    "  --ai               opt-in g6lc64_ai lint target + AI directed sim suites\n" +
    "                     (like --target g6lc64_ooo_server). Remote S4 is\n" +
    "                     `test --ai-remote`, not this gate.\n" +
    "  --channels / --ai-dram / --ai-ghz / --ai-flavour\n" +
    "                     stamp AI_ISLAND_DRAM_* env for sim (same as test --ai)\n" +
    "  --use-emit         expert: export emit flist env for sim consumers (default off)\n" +
    "  --allow-skips      accept a run in which stages were skipped. Without it a\n" +
    "                     skipped stage makes the verdict incomplete (exit 4):\n" +
    "                     a step that did not run has qualified nothing.\n" +
    "  --yes / -y         auto-accept tools install when managed tools are missing\n" +
    "  --formal-jobs N    solver processes per sby task (sby -j; default: host cores)\n" +
    "  --formal-tasks N   sby tasks run concurrently (default: cores / formal-jobs)\n" +
    "  --formal-remote    run the formal suite on the remote testharness builder\n" +
    "                     (one SSH round trip for the whole suite; the builder\n" +
    "                     provisions its own toolchain and sby -j = its nproc)\n" +
    "  --formal-host H    remote alias, implies --formal-remote\n" +
    "\n" +
    "The formal stage needs Yosys >= v0.67, where the slang SystemVerilog frontend\n" +
    "is integrated: below that, `read_slang` does not exist and any task reading a\n" +
    "config package fails at parse. Provision it with:\n" +
    "  tools install formal        (source build; runs under WSL on Windows)",
  examples: [
    "verify",
    "verify --lint",
    "verify --lint --synth --target g6lc64_ooo_server",
    "verify --lint --ai --from-timing workspace/build/sv-timing/host-cv64a6_imafdc_sv39",
    "verify --json",
    "verify --lint --from-timing workspace/build/sv-timing/host-cv64a6_imafdc_sv39",
  ],
  needsContext: true,
  async run(args) {
    const ctx = requireContext(args);
    const { logger, config } = ctx;
    const qualificationName = flagString(args.flags, "qualification");
    let qualification: QualificationSelection[] | undefined;
    if (args.flags.qualification !== undefined) {
      if (!qualificationName || !flagBool(args.flags, "sim") || ctx.dryRun ||
          ["lint", "formal", "synth", "ai", "from-timing", "use-emit"].some((key) => args.flags[key])) {
        logger.error("Qualification currently requires --sim and a profile, with no dry-run, other stages or build overrides. Full RTL verification remains separate.");
        return 2;
      }
      try {
        qualification = selectQualification(config, qualificationName, flagString(args.flags, "target") ?? undefined);
      } catch (error) {
        logger.error(error instanceof Error ? error.message : String(error));
        return 2;
      }
    }
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
    if (!ctx.dryRun && !qualification) {
      const want: ManagedTool[] = ["verilator", "riscv-gcc"];
      await offerInstallMissingTools(ctx, want, args.flags as Record<string, string | boolean>);
      presence = edaPresence(paths);
    }

    const missingRequired = presence.filter((t) => t.required && !t.present);
    if (missingRequired.length > 0 && !ctx.dryRun && !qualification) {
      logger.error(
        `Verification gate unavailable: missing ${missingRequired.map((t) => t.id).join(", ")}.`,
      );
      logger.info(`Expected under ${paths.root}`);
      logger.info(
        "Install: g6lc-build tools install sim   or extract the OSS CAD Suite / set verify.suite.root.",
      );
      return 3;
    }

    if (flagBool(args.flags, "ai-remote")) {
      logger.error(
        "verify does not run the remote testharness. Use: test --ai-remote  (or remote --ai build)",
      );
      return 2;
    }

    const aiFlagErrors = parseAiFlagErrors(args.flags as Record<string, string | boolean>);
    if (aiFlagErrors.length) {
      for (const e of aiFlagErrors) logger.error(e);
      return 2;
    }
    const aiKnobs = parseAiFlags(args.flags as Record<string, string | boolean>);
    const ai = resolveAiTesting(aiKnobs);
    if (ai.errors.length) {
      for (const e of ai.errors) logger.error(e);
      return 2;
    }
    if (ai.active) {
      applyAiEnv(ai);
      logger.info(formatAiResolvedLine(ai));
      for (const w of ai.warnings) logger.warn(w);
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

    // CLI parallelism overrides land on the resolved config so the runner and
    // any nested call see one source of truth.
    const formalJobs = flagString(args.flags, "formal-jobs");
    const formalTaskJobs = flagString(args.flags, "formal-tasks");
    // --remote is the whole-gate switch; the per-stage flags stay for one stage.
    const allRemote = flagBool(args.flags, "remote");
    const lintRemote = allRemote || flagBool(args.flags, "lint-remote");
    const synthRemote = allRemote || flagBool(args.flags, "synth-remote");
    const formalRemote = allRemote || flagBool(args.flags, "formal-remote");
    const formalHost = flagString(args.flags, "formal-host");
    if (formalJobs || formalTaskJobs || formalRemote || formalHost) {
      const f = (config.verify.formal ??= {});
      if (formalJobs) f.jobs = Math.max(1, Number(formalJobs) || 1);
      if (formalTaskJobs) f.taskJobs = Math.max(1, Number(formalTaskJobs) || 1);
      if (formalRemote) f.remote = true;
      if (formalHost) {
        f.remote = true;
        f.remoteHost = formalHost;
      }
    }

    const stages = requestedStages(args.flags as Record<string, unknown>, config.verify.stages);
    const targetFlag = typeof args.flags.target === "string" ? args.flags.target : null;
    const targets = qualification
      ? [...new Set(qualification.map((entry) => entry.target))]
      : targetFlag
      ? [targetFlag]
      : aiKnobs.wantAi
        ? [...config.verify.targets, "g6lc64_ai"].filter(
            (t, i, a) => a.indexOf(t) === i,
          )
        : config.verify.targets;
    const outcomes: StageOutcome[] = [];

    for (const stage of stages) {
      if (stage === "lint") {
        logger.heading(`Lint + elaboration (${targets.length} target(s))`);
        if (lintRemote) {
          // Remote route: one round trip per stage half, on the builder's own
          // Verilator and its Yosys-integrated slang frontend.
          outcomes.push(...(await lintTargetsRemote(ctx, paths, targets)));
          // Strict elaboration stays local: the builder carries no standalone
          // slang, and substituting the Yosys-integrated frontend does not run
          // the same check — it rejects hpdcache SVA that standalone slang
          // accepts, so it would only pass with assertions defined out.
          // Provisioning slang on the builder is the fix, not a substitution.
          for (const target of targets) {
            outcomes.push({
              stage: "lint",
              target,
              status: "skip",
              detail: "strict slang elaboration is local-only: no standalone slang on the builder",
              durationMs: 0,
            });
          }
        } else {
          for (const target of targets) {
            outcomes.push(await lintTarget(ctx, paths, target));
            outcomes.push(await elaborateTarget(ctx, paths, target));
          }
        }
      } else if (stage === "synth") {
        logger.heading("Synthesis smoke");
        if (synthRemote) {
          outcomes.push(...(await synthTargetsRemote(ctx, paths, targets)));
        } else {
          for (const target of targets) {
            outcomes.push(await synthTarget(ctx, paths, target));
          }
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
        } else {
          logger.info(
            `toolchain: ${paths.formalSource}` +
              (paths.slangIntegrated ? " (slang integrated)" : "") +
              `  sby=${paths.sby}`,
          );
          outcomes.push(...(await runFormalTasks(ctx, paths, config.verify.formalTasks)));
        }
      } else {
        logger.heading("Simulation");
        if (qualification) {
          for (const entry of qualification) {
            const result = await runSuite(ctx, entry.suite, { qualification: entry });
            outcomes.push({
              stage: "sim", target: entry.target,
              status: result.ok && !result.skipped && result.evidence ? "pass" : "fail",
              detail: `${entry.suite.id}: ${result.reason ?? (result.evidence ? `${result.evidence.kind}, ${result.evidence.checks} checks, run ${result.evidence.runId}` : "missing evidence")}`,
              durationMs: result.durationMs,
            });
          }
          continue;
        }
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
          const simIds = aiKnobs.wantAi
            ? [...config.verify.simSuites, ...ai.suiteIds.filter((id) =>
                ["ai-config-smoke", "ai-matrix-directed", "ai-island-veri"].includes(id),
              )]
            : config.verify.simSuites;
          const { suites, unknown } = selectSuites(config, simIds);
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
      logger.raw(JSON.stringify({ stages, targets, outcomes, qualification: qualificationName }, null, 2) + "\n");
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

    const verdict = gateVerdict(outcomes, {
      dryRun: ctx.dryRun,
      allowSkips: flagBool(args.flags, "allow-skips"),
      qualified: Boolean(qualification),
    });
    if (verdict.level === "error") logger.error(verdict.message);
    else if (verdict.level === "success") logger.success(verdict.message);
    else logger.info(verdict.message);
    return verdict.code;
  },
};
