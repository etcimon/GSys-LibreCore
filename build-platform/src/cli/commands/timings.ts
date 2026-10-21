// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// timings.ts — Host CLI for the standalone sv-timing package.
//
//   timings status              locate package + report paths
//   timings flist               flatten verify flist → portable .f
//   timings compile|analyze     flist + analyze into --output out-dir
//   timings correct             flist + correct (optional --emit into out-dir)
//   timings area               flist + area report into <output>/area-report.json
//   timings validate            structural check of a precompile out-dir
//
// --output / -o / --out  : compile target directory (portable.f + JSON + cache + stamp)
// Does not link monorepo code into sv-timing crates. See sv-timing/AGENTS-host.md.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { flagBool } from "../args.ts";
import { snapshotCvaCfg } from "../../tooling/cfgSnapshot.ts";
import { requireContext, type Command, type CommandArgs } from "../command.ts";
import type { PlatformContext } from "../../context.ts";
import { run } from "../../platform/exec.ts";
import { edaEnv, edaPaths, posixPath } from "../../tooling/eda.ts";
import { parseBenchLog, applyBenchMetricsToEnv } from "../../tooling/benchMetrics.ts";
import {
  checkFo4Golden,
  goldenFromAnalyze,
  writeFo4Golden,
} from "../../tooling/fo4Golden.ts";
import { writeLabReport } from "../../tooling/labReport.ts";
import { assessTimingsDoctor } from "../../tooling/timingsDoctor.ts";
import { proposeFo4Retune } from "../../tooling/retunePropose.ts";
import { hostCores, platformFo4Table, runAdjustedFo4, runPlatformFo4Probes, runRtlTiming, tradeoffRows } from "../../tooling/rtlTiming.ts";
import { describePlatform, detectOpenroadPlatforms } from "../../tooling/openroadPlatforms.ts";
import {
  buildBenchCorrelation,
  materializeStaSmokePackage,
  runStaHandoff,
} from "../../tooling/staHandoff.ts";
import { readFileSync as readFileSyncNode } from "node:fs";
import {
  buildSvTimingAnalyzeArgs,
  buildSvTimingAreaArgs,
  buildSvTimingCorrectArgs,
  buildSvtRunCommand,
  fo4BudgetFor,
  formatTimingsDashboardLines,
  resolveSvTimingRoot,
  resolveTimingsOutputDir,
  splitSvtArgs,
  summarizeTimingsPackage,
  targetMhzForFo4Budget,
  timingsRepoEnv,
  type TimingsOutputLayout,
  validateTimingsOutDir,
  writeHostParamMap,
  writePortableTimingsFlist,
  writeTimingsDashboard,
  writeTimingsStamp,
  writeVerifyPortableFlist,
} from "../../tooling/timings.ts";

function flagStr(
  flags: Record<string, string | boolean>,
  name: string,
): string | undefined {
  const v = flags[name];
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

/** --output / -o preferred; --out is an alias (legacy emit/json parent). */
function flagOutput(flags: Record<string, string | boolean>): string | undefined {
  return flagStr(flags, "output") ?? flagStr(flags, "out");
}

function resolveTarget(args: {
  flags: Record<string, string | boolean>;
  ctx: { config: { soc: { coreConfig: string }; verify: { targets: string[] } } };
}): string {
  return (
    flagStr(args.flags, "target") ??
    args.ctx.config.verify.targets[0] ??
    args.ctx.config.soc.coreConfig
  );
}

function buildEnv(
  ctx: Parameters<typeof edaEnv>[0],
  target: string,
): Record<string, string> {
  try {
    const paths = edaPaths(ctx);
    return { ...timingsRepoEnv(ctx, target), ...edaEnv(ctx, paths, target) };
  } catch {
    return timingsRepoEnv(ctx, target);
  }
}

async function runAnalyzeOrCorrect(
  ctx: PlatformContext,
  args: CommandArgs,
  kind: "analyze" | "correct" | "compile" | "area",
): Promise<number> {
  const { logger } = ctx;
  const flags = args.flags;
  const target = resolveTarget({ flags, ctx });
  const dryRun = flagBool(flags, "dry-run") || ctx.dryRun;
  const allModules = flagBool(flags, "all-modules");
  const modulesRaw = flagStr(flags, "modules");
  const modules = modulesRaw
    ? modulesRaw.split(",").map((s) => s.trim()).filter(Boolean)
    : undefined;
  const targetMhz = flagStr(flags, "target-mhz");
  const fo4Ps = flagStr(flags, "fo4-ps");
  // `--budget-fo4 N` (alias `--fo4 N`): the structural budget itself, turned
  // into the target-mhz sv-timing derives it from (fo4_ps / margin aware).
  const budgetFo4Raw = flagStr(flags, "budget-fo4") ?? flagStr(flags, "fo4");
  const budgetFo4 =
    budgetFo4Raw != null && Number.isFinite(Number(budgetFo4Raw)) && Number(budgetFo4Raw) > 0
      ? Number(budgetFo4Raw)
      : undefined;
  const optLevel = flagStr(flags, "opt-level");
  const jsonOutOverride = flagStr(flags, "json-out");
  const outputSpec = flagOutput(flags);
  const flistOverride = flagStr(flags, "flist");
  const cacheOverride = flagStr(flags, "cache");
  const emit = flagBool(flags, "emit");
  const allowLatency = flagBool(flags, "allow-latency");
  const assumeClk = flagBool(flags, "assume-clk");
  const asJson = flagBool(flags, "json");
  const paramMapFlag = flagStr(flags, "param-map");
  const packageModeRaw = flagStr(flags, "package-mode");
  const packageMode =
    packageModeRaw === "packages" || packageModeRaw === "on"
      ? ("packages" as const)
      : packageModeRaw === "off"
        ? ("off" as const)
        : undefined;
  const assumeXlenRaw = flagStr(flags, "assume-xlen");
  const assumeXlen =
    assumeXlenRaw != null
      ? Number(assumeXlenRaw)
      : (ctx.config.soc.xlen as number | undefined);
  const autoParamMap = !flagBool(flags, "no-param-map");
  const budgetMarginRaw = flagStr(flags, "budget-margin");
  const budgetMargin =
    budgetMarginRaw != null && Number.isFinite(Number(budgetMarginRaw))
      ? Number(budgetMarginRaw)
      : undefined;
  const compareParamMap = flagStr(flags, "compare-param-map");
  const inclusionRaw = flagStr(flags, "inclusion");
  const overlayRaw = flagStr(flags, "config-overlay");
  const topRaw = flagStr(flags, "top");
  const top =
    topRaw != null && Number.isFinite(Number(topRaw)) ? Number(topRaw) : undefined;
  const strictAttribution = flagBool(flags, "strict-attribution");
  const allowParseErrors = flagBool(flags, "allow-parse-errors");
  const metricRaw = flagStr(flags, "metric");
  const metric =
    metricRaw === "area" || metricRaw === "perf" || metricRaw === "perf-per-area"
      ? metricRaw
      : undefined;
  const compareInclusion = flagStr(flags, "compare-inclusion");
  const areaModel = flagStr(flags, "area-model");
  const force = flagBool(flags, "force");

  // compile is analyze with a guaranteed out-dir layout
  const runKind: "analyze" | "correct" | "area" =
    kind === "correct" ? "correct" : kind === "area" ? "area" : "analyze";

  if (!allModules && (!modules || modules.length === 0)) {
    logger.error(
      `timings ${kind} requires --modules m1,m2 or --all-modules`,
    );
    return 2;
  }

  if (kind === "compile" && !outputSpec && !jsonOutOverride) {
    logger.info(
      "timings compile: using default --output under workspace/build/sv-timing/",
    );
  }

  const pkgRoot = resolveSvTimingRoot(ctx);
  if (!pkgRoot) {
    logger.error(
      "sv-timing package not found at repo root. Expected CVA6_REPO_DIR/sv-timing.",
    );
    return 1;
  }

  const env = buildEnv(ctx, target);
  const tag = `host-${target}`;
  // Prefer --output; else parent of --json-out so package stays co-located.
  const derivedOut =
    outputSpec ??
    (jsonOutOverride != null ? dirnameSafe(jsonOutOverride) : undefined);
  const layout: TimingsOutputLayout = resolveTimingsOutputDir(ctx, derivedOut, {
    tag,
    create: true,
  });

  // json-out may still override the report path; otherwise canonical under layout.
  const reportJson =
    jsonOutOverride ??
    (runKind === "analyze"
      ? layout.analyzeJson
      : runKind === "area"
        ? layout.areaJson
        : layout.correctJson);
  const portablePath = layout.portableF;
  const cachePath = cacheOverride ?? layout.cache;
  const emitDir = runKind === "correct" && emit ? layout.correctedDir : undefined;

  mkdirSync(layout.dir, { recursive: true });
  if (jsonOutOverride) {
    mkdirSync(dirnameSafe(reportJson), { recursive: true });
  }

  const portable = flistOverride
    ? writePortableTimingsFlist(ctx, {
        entryFlist: flistOverride,
        env,
        tag,
        outPath: portablePath,
      })
    : writeVerifyPortableFlist(ctx, env, target, {
        tag,
        outPath: portablePath,
      });

  logger.info(`output   : ${layout.dir}`);
  logger.info(`portable : ${portable.portablePath} (${portable.files.length} files)`);

  const fo4 = fo4Ps != null ? Number(fo4Ps) : undefined;
  const mhz =
    budgetFo4 != null
      ? targetMhzForFo4Budget(budgetFo4, fo4, budgetMargin)
      : targetMhz != null
        ? Number(targetMhz)
        : ctx.config.soc.targetFrequencyMHz;
  logger.info(
    `budget   : ${fo4BudgetFor(mhz, fo4, budgetMargin).toFixed(1)} FO4 ` +
      `(target ${mhz.toFixed(0)} MHz, fo4_ps=${fo4 ?? 20}, margin=${budgetMargin ?? 0.2}` +
      `${budgetFo4 != null ? `; from --budget-fo4 ${budgetFo4}` : ""}) — structural, not STA`,
  );
  if (budgetFo4 != null && targetMhz != null) {
    logger.warn(`--budget-fo4 ${budgetFo4} overrides --target-mhz ${targetMhz}`);
  }

  let paramMapPath = paramMapFlag;
  if (!paramMapPath && autoParamMap) {
    // Elaborated CVA6Cfg fields (yosys-slang probe) so width inference sees
    // the cfg-dimensioned counters; falls back to the XLEN-only map.
    let extra: Record<string, number> = {};
    let cfgNote = "XLEN only";
    if (!dryRun) {
      try {
        const snap = await snapshotCvaCfg(ctx, edaPaths(ctx), target, layout.dir);
        if (snap) {
          extra = snap.entries;
          cfgNote = snap.detail;
        }
      } catch (e) {
        cfgNote = `cfg snapshot skipped: ${e instanceof Error ? e.message : String(e)}`;
      }
    }
    paramMapPath = writeHostParamMap(ctx, {
      outPath: layout.paramMap,
      xlen: assumeXlen,
      extra,
    });
    logger.info(`param-map: ${paramMapPath} (${cfgNote})`);
  } else if (paramMapPath) {
    logger.info(`param-map: ${paramMapPath}`);
  }

  const cliArgs =
    runKind === "analyze"
      ? buildSvTimingAnalyzeArgs({
          portableFlist: portable.portablePath,
          modules,
          allModules,
          targetMhz: mhz,
          fo4Ps: fo4,
          cache: cachePath,
          jsonOut: reportJson,
          paramMap: paramMapPath,
          assumeXlen,
          packageMode: packageMode ?? "packages",
        })
      : runKind === "area"
        ? buildSvTimingAreaArgs({
            portableFlist: portable.portablePath,
            modules,
            allModules,
            targetMhz: mhz,
            fo4Ps: fo4,
            budgetMargin,
            cache: cachePath,
            jsonOut: reportJson,
            paramMap: paramMapPath,
            compareParamMap,
            assumeXlen,
            packageMode: packageMode ?? "packages",
            inclusion: inclusionRaw ? [inclusionRaw] : undefined,
            configOverlay: overlayRaw ? [overlayRaw] : undefined,
            top,
            metric,
            compareInclusion,
            areaModel,
            force,
            strictAttribution,
            allowParseErrors,
          })
        : buildSvTimingCorrectArgs({
          portableFlist: portable.portablePath,
          modules,
          allModules,
          targetMhz: mhz,
          fo4Ps: fo4,
          budgetMargin,
          optLevel,
          extraArgs: splitSvtArgs(flagStr(flags, "svt-args")),
          allowLatency,
          assumeClk,
          emit,
          outDir: emitDir,
          jsonOut: reportJson,
          cache: cachePath,
          paramMap: paramMapPath,
          assumeXlen,
          packageMode: packageMode ?? "packages",
        });

  const cmd = buildSvtRunCommand(ctx, cliArgs, { release: true });
  if (!cmd) {
    logger.error("failed to build svt run command");
    return 1;
  }

  logger.info(`+ ${cmd.argv.join(" ")}`);
  if (dryRun) {
    logger.warn("dry-run: not spawning sv-timing");
    if (asJson) {
      logger.raw(
        JSON.stringify(
          {
            dryRun: true,
            kind,
            output: layout.dir,
            reportJson,
            portable: portable.portablePath,
            argv: cmd.argv,
          },
          null,
          2,
        ) + "\n",
      );
    }
    return 0;
  }

  if (!existsSync(join(pkgRoot, "tools", "svt.py"))) {
    logger.error(`missing ${join(pkgRoot, "tools", "svt.py")}`);
    return 1;
  }

  const result = await run(cmd.argv[0]!, cmd.argv.slice(1), {
    cwd: cmd.cwd,
    allowFailure: true,
    logger,
    env: {
      ...process.env,
      ...env,
      RUST_MIN_STACK: process.env.RUST_MIN_STACK ?? "16777216",
    },
  });

  writeTimingsStamp(layout, {
    kind: kind === "compile" ? "compile" : runKind,
    target,
    targetMhz: mhz,
    modules,
    allModules,
    command: cmd.argv.join(" "),
    exitCode: result.code,
    mtimeMs: Date.now(),
    portableF: portable.portablePath,
    reportJson,
    paramMap: paramMapPath,
    emitDir: emit ? layout.correctedDir : undefined,
  });

  if (!result.ok) {
    logger.error(`sv-timing ${runKind} failed (exit ${result.code})`);
    logger.info(`partial out-dir left at ${layout.dir} (stamp records exit)`);
    return result.code || 1;
  }

  // Area shares the out-dir cache. It does not satisfy the analyze/correct
  // package check, and it does not feed the FO4 dashboard.
  if (runKind === "area") {
    if (asJson) {
      logger.raw(
        JSON.stringify(
          {
            ok: true,
            kind,
            output: layout.dir,
            reportJson,
            stamp: layout.stamp,
          },
          null,
          2,
        ) + "\n",
      );
    } else {
      logger.success(`sv-timing area OK → ${reportJson}`);
      logger.success(`out-dir  : ${layout.dir}`);
      logger.info(`stamp    : ${layout.stamp}`);
    }
    return 0;
  }

  // Post-compile structural check when using a unified out-dir
  const validation = validateTimingsOutDir(ctx, {
    fromTiming: layout.dir,
    requireEmit: emit && runKind === "correct",
    checkSourcePaths: false,
  });
  if (asJson) {
    logger.raw(
      JSON.stringify(
        {
          ok: true,
          kind,
          output: layout.dir,
          reportJson,
          stamp: layout.stamp,
          validation,
        },
        null,
        2,
      ) + "\n",
    );
  } else {
    logger.success(`sv-timing ${kind} OK → ${reportJson}`);
    logger.success(`out-dir  : ${layout.dir}`);
    logger.info(`stamp    : ${layout.stamp}`);
    if (validation.ok) {
      logger.success("post-compile structure OK (ready for --from-timing)");
      const dash = summarizeTimingsPackage(ctx, layout.dir);
      writeTimingsDashboard(layout.dir, dash);
      if (!asJson) {
        logger.heading("Soak dashboard (structural FO4 — not STA)");
        for (const line of formatTimingsDashboardLines(dash)) {
          logger.info(line);
        }
      }
    } else {
      logger.warn("post-compile structure incomplete (see timings validate)");
      for (const i of validation.issues) {
        if (i.level === "error") logger.warn(`  [${i.code}] ${i.message}`);
      }
    }
  }
  return 0;
}

export const timingsCommand: Command = {
  name: "timings",
  summary:
    "Host adapter for sv-timing: compile/analyze/correct to --output, validate --from-timing.",
  usage:
    "bun run src/cli/index.ts timings [status|doctor|flist|compile|analyze|area|correct|validate|summary|dashboard|sta-handoff|sta-rtl|correlate|fo4-golden|retune-propose|parse-bench-log|lab-run] [options…]",
  details:
    "Prepares monorepo flists for the independent sv-timing package and spawns\n" +
    "its CLI via `python tools/svt.py run -- …`. Never links monorepo code into\n" +
    "sv-timing crates.\n" +
    "\n" +
    "  timings status     locate sv-timing/ and print default out dirs\n" +
    "  timings flist      flatten → portable.f (use --output DIR for package layout)\n" +
    "  timings compile    analyze into a full --output out-dir (portable+JSON+cache+stamp)\n" +
    "  timings analyze    same as compile (alias; prefers --output over ad-hoc --json-out)\n" +
    "  timings area       structural area into <output>/area-report.json (same cache; no rewrite)\n" +
    "  timings correct    correct (+ optional --emit into <output>/corrected)\n" +
    "                     --budget-fo4 N | --fo4 N  structural budget (10 = 4000 MHz at fo4_ps 20,\n" +
    "                     margin 0.2); --fo4-ps --budget-margin --opt-level forwarded;\n" +
    "                     --svt-args \"--opt-max-stages-per-region 12 --real-cut-feeds\" raw dials\n" +
    "  timings validate   structural check of a precompile out-dir (--from-timing)\n" +
    "  timings summary    soak dashboard from analyze.json (alias: dashboard)\n" +
    "  timings sta-handoff  S0–S2 OpenSTA handoff from --from-timing (--try-tools)\n" +
    "  timings sta-rtl    gate-level STA of a config-package target: yosys maps core/+corev_apu/\n" +
    "                     onto a liberty, the tools/openroad fork reports (openroad-timing.tcl);\n" +
    "                     --target --top --liberty|--platform --clock-port --target-mhz --threads\n" +
    "                     --remote (builder: -march/PGO fork build when absent, nproc threads)\n" +
    "                     --fo4 N|--budget-fo4 N  sv-timing correct --emit first at N FO4 (default\n" +
    "                     physicalDesign.structural.fo4Budget = 10; --fo4 0 = live RTL;\n" +
    "                     fo4_ps 20, margin 0.2 → 4000 MHz) and synthesize\n" +
    "                     the corrected emit; --from-timing <pkg> reuses an existing emit\n" +
    "                     a budget miss stops before mapping; --allow-over-budget requests a study\n" +
    "                     --map-recipe lean|hierarchical|streamed|synth  yosys lowering; hierarchical\n" +
    "                     keeps module boundaries; streamed (remote) maps one module at a time and\n" +
    "                     evicts it, bounding memory to the word-level design\n" +
    "                     --no-sram-stub  keep the behavioural tc_sram (default: registered macro\n" +
    "                     boundary stub, scripts/tc_sram_timing_stub.sv; the flop-per-bit array OOMs)\n" +
    "                     --max-cells-per-fo4 N  sv-timing Dial 11: refuse a register cut / select\n" +
    "                     whose preliminary cells per FO4 of gain exceed N (preset 16; 0 = off); the\n" +
    "                     previous run's calibration.tsv scales it per module (measured cells/FO4)\n" +
    "                     --tradeoffs N  list the N largest area/depth trade-offs (applied + refused)\n" +
    "  timings correlate  FO4 dashboard + optional --bench id metrics JSON\n" +
    "  timings fo4-golden check|write  S3b FO4 golden vs analyze.json\n" +
    "  timings retune-propose  S3b-lab: correlate.json → retune-proposal.md (never edits fo4-v1)\n" +
    "  timings parse-bench-log --file LOG  extract CVA6_BENCH_* from log text\n" +
    "  timings lab-run    one-shot: sta_smoke → golden → handoff + lab-report + retune-propose\n" +
    "                     (injects synthetic OpenSTA paths.rpt for offline S3a; --no-sta-fixture to disable)\n" +
    "  timings doctor     readiness: package, FO4 model, sim/PD tools, retune checklist\n" +
    "\n" +
    "Compile target (--output / -o / --out):\n" +
    "  Directory that becomes the --from-timing package:\n" +
    "    portable.f  analyze.json|correct.json  param-map.json\n" +
    "    ir.sqlite   stamp.json  soak-dashboard.json  [corrected/]\n" +
    "  Relative paths resolve from the repo root (or under workspace/build/sv-timing).\n" +
    "\n" +
    "Disclaimer: structural FO4 estimates only — not STA sign-off.\n" +
    "OpenSTA/OpenROAD plan: architecture/build-platform-opensta-from-timing.md",
  examples: [
    "bun run src/cli/index.ts timings status",
    "bun run src/cli/index.ts timings compile --modules alu --output workspace/build/sv-timing/alu-pack",
    "bun run src/cli/index.ts timings compile --all-modules -o build/my-timings --target-mhz 1250",
    "bun run src/cli/index.ts timings analyze --modules alu --output out/t1",
    "bun run src/cli/index.ts timings area --modules alu --output out/t1",
    "bun run src/cli/index.ts timings correct --modules alu --allow-latency --emit -o out/t1",
    "bun run src/cli/index.ts timings correct --all-modules --budget-fo4 10 --allow-latency --emit -o workspace/build/sv-timing/ooo-fo4-10 --target g6lc64_ooo",
    "bun run src/cli/index.ts timings validate --from-timing out/t1",
    "bun run src/cli/index.ts timings summary --from-timing out/t1",
    "bun run src/cli/index.ts timings sta-handoff --from-timing out/t1 --try-tools",
    "bun run src/cli/index.ts timings sta-rtl --target g6lc64_ooo --platform nangate45",
    "bun run src/cli/index.ts timings sta-rtl --target g6lc64_ooo_server --remote --target-mhz 1250",
    "bun run src/cli/index.ts timings sta-rtl --target g6lc64_ooo --platform nangate45 --fo4 10 --remote",
    "bun run src/cli/index.ts timings platforms",
    "bun run src/cli/index.ts timings fo4-probe --all --remote",
    "bun run src/cli/index.ts timings adjusted --output workspace/build/sta-rtl/g6lc64_ooo --platform nangate45",
    "bun run src/cli/index.ts timings lab-run --try-tools",
    "bun run src/cli/index.ts timings retune-propose",
    "bun run src/cli/index.ts timings retune-propose --from-handoff workspace/build/sta-handoff/lab-run",
    "bun run src/cli/index.ts timings doctor",
    "bun run src/cli/index.ts timings correlate --from-timing out/t1 --bench dhrystone-smoke",
    "bun run src/cli/index.ts test sv-timing-smoke --from-timing out/t1",
  ],
  needsContext: true,
  async run(args) {
    const ctx = requireContext(args);
    const { logger } = ctx;
    const sub = (args.positionals[0] ?? "status").toLowerCase();
    const target = resolveTarget({ flags: args.flags, ctx });
    const asJson = flagBool(args.flags, "json");
    const fromTiming =
      flagStr(args.flags, "from-timing") ??
      ([
        "validate",
        "summary",
        "dashboard",
        "sta-handoff",
        "correlate",
        "sta",
        "fo4-golden",
      ].includes(sub)
        ? args.positionals[1]
        : undefined);
    const requireEmit = flagBool(args.flags, "require-emit");
    const outputSpec = flagOutput(args.flags);
    const flistOverride = flagStr(args.flags, "flist");

    const pkgRoot = resolveSvTimingRoot(ctx);

    if (sub === "status") {
      const defaultLayout = resolveTimingsOutputDir(ctx, undefined, {
        tag: `host-${target}`,
        create: false,
      });
      const body = {
        svTimingRoot: pkgRoot,
        present: pkgRoot != null,
        defaultFlist: ctx.config.verify.flist,
        target,
        defaultOutput: defaultLayout.dir,
        note: "use timings compile -o <dir>; structural FO4 — not STA",
      };
      if (asJson) {
        logger.raw(JSON.stringify(body, null, 2) + "\n");
        return 0;
      }
      logger.heading("sv-timing host adapter");
      if (pkgRoot) {
        logger.success(`package  : ${pkgRoot}`);
      } else {
        logger.warn("package  : NOT FOUND (expected repo-root/sv-timing)");
      }
      logger.info(`flist    : ${ctx.config.verify.flist}`);
      logger.info(`target   : ${target}`);
      logger.info(`default  : ${body.defaultOutput}`);
      logger.info(
        "commands : timings doctor|lab-run|retune-propose|compile|sta-handoff|validate|summary …",
      );
      return pkgRoot ? 0 : 1;
    }

    if (sub === "doctor") {
      const report = assessTimingsDoctor(ctx);
      if (asJson) {
        logger.raw(JSON.stringify(report, null, 2) + "\n");
        return report.ok ? 0 : 1;
      }
      logger.heading("timings doctor (structural FO4 — not STA)");
      if (report.svTimingRoot) {
        logger.success(`sv-timing : ${report.svTimingRoot}`);
      } else {
        logger.error("sv-timing : NOT FOUND");
      }
      logger.info(
        `packages  : ${report.packages.dir} (${report.packages.count} entries)`,
      );
      logger.info(
        `sta-handoff: ${report.staHandoff.dir} (${report.staHandoff.count} entries)`,
      );
      if (report.staHandoff.lastLabReport) {
        logger.success(`lab-report: ${report.staHandoff.lastLabReport}`);
      } else {
        logger.warn("lab-report: none — run timings lab-run");
      }
      logger.heading("Tools");
      logger.info(`bash      : ${report.tools.bash}`);
      logger.info(
        `yosys     : ${report.tools.yosys ? "yes" : "no"}  opensta: ${report.tools.opensta ? "yes" : "no"}  openroad: ${report.tools.openroad ? "yes" : "no"}`,
      );
      logger.info(
        `liberty   : ${report.tools.liberty ?? "(unset — export CVA6_LIBERTY for S2)"}`,
      );
      logger.heading("FO4 model (S3b-lab)");
      if (report.fo4.present) {
        logger.success(
          `fo4-v1    : ${report.fo4.path}  version=${report.fo4.version ?? "?"}`,
        );
        const keys = Object.keys(report.fo4.costs).sort();
        logger.info(
          `costs     : ${keys.map((k) => `${k}=${report.fo4.costs[k]}`).join("  ")}`,
        );
      } else {
        logger.error("fo4-v1    : missing");
      }
      for (const n of report.fo4.notes) logger.info(`  note: ${n}`);
      logger.heading("S3b-lab retune checklist");
      for (const line of report.retuneChecklist) logger.info(`  ${line}`);
      logger.heading("Sim preflight (for verify --sim / benches)");
      for (const i of report.sim.items) {
        const mark = i.ok ? "ok" : i.required ? "NEED" : "warn";
        const line = `  [${mark}] ${i.id}: ${i.detail}`;
        if (!i.ok && i.required) logger.error(line);
        else if (!i.ok) logger.warn(line);
        else logger.info(line);
      }
      if (report.hints.length) {
        logger.heading("Hints");
        for (const h of report.hints) logger.info(`  → ${h}`);
      }
      return report.ok ? 0 : 1;
    }

    if (sub === "validate") {
      if (!fromTiming) {
        logger.error(
          "timings validate requires --from-timing <dir> (or positional path)",
        );
        return 2;
      }
      const result = validateTimingsOutDir(ctx, {
        fromTiming,
        requireEmit,
      });
      if (asJson) {
        logger.raw(JSON.stringify(result, null, 2) + "\n");
        return result.ok ? 0 : 1;
      }
      logger.heading("timings validate (--from-timing)");
      logger.info(`dir      : ${result.dir}`);
      if (result.portableF) {
        logger.success(
          `portable : ${result.portableF} (${result.fileCount} files)`,
        );
      } else logger.error("portable : MISSING");
      if (result.reportJson) {
        logger.success(
          `report   : ${result.reportJson} (${result.reportKind ?? "?"}; schema=${result.schemaHint ?? "?"})`,
        );
      } else logger.error("report   : MISSING");
      if (result.paramMap) logger.info(`param-map: ${result.paramMap}`);
      else logger.warn("param-map: (none)");
      if (result.emitDir || result.correctedFlist) {
        logger.info(
          `emit     : ${result.emitDir ?? "—"}  flist=${result.correctedFlist ?? "—"}`,
        );
      } else if (requireEmit) {
        logger.error("emit     : required but missing");
      } else {
        logger.info("emit     : (none)");
      }
      for (const issue of result.issues) {
        const line = `  [${issue.code}] ${issue.message}`;
        if (issue.level === "error") logger.error(line);
        else logger.warn(line);
      }
      if (result.ok) {
        logger.success("structure OK (post-precompile host gate)");
        const dash = summarizeTimingsPackage(ctx, result.dir);
        writeTimingsDashboard(result.dir, dash);
        logger.heading("Soak dashboard (structural FO4 — not STA)");
        for (const line of formatTimingsDashboardLines(dash)) {
          logger.info(line);
        }
        return 0;
      }
      logger.error("structure INVALID");
      return 1;
    }

    if (sub === "summary" || sub === "dashboard") {
      const spec = fromTiming ?? outputSpec ?? args.positionals[1];
      if (!spec) {
        logger.error(
          "timings summary requires --from-timing <dir> or --output <dir> (or positional)",
        );
        return 2;
      }
      const dash = summarizeTimingsPackage(ctx, spec);
      if (existsSync(dash.source) || dash.reportJson) {
        try {
          writeTimingsDashboard(dash.source, dash);
        } catch {
          /* best-effort */
        }
      }
      if (asJson) {
        logger.raw(JSON.stringify(dash, null, 2) + "\n");
        return dash.ok ? 0 : 1;
      }
      logger.heading("Soak dashboard (structural FO4 — not STA)");
      for (const line of formatTimingsDashboardLines(dash)) {
        if (line.startsWith("issue")) logger.error(line);
        else logger.info(line);
      }
      return dash.ok ? 0 : 1;
    }

    if (sub === "sta-handoff" || sub === "sta") {
      const spec = fromTiming ?? outputSpec ?? args.positionals[1];
      if (!spec) {
        logger.error("timings sta-handoff requires --from-timing <dir>");
        return 2;
      }
      const targetMhz = flagStr(args.flags, "target-mhz");
      const top = flagStr(args.flags, "top") ?? flagStr(args.flags, "modules")?.split(",")[0];
      const liberty = flagStr(args.flags, "liberty");
      const injectFlag = flagStr(args.flags, "inject-sta-fixture");
      const result = await runStaHandoff(ctx, {
        fromTiming: spec,
        outDir: outputSpec,
        targetMhz: targetMhz != null ? Number(targetMhz) : undefined,
        tryTools: flagBool(args.flags, "try-tools"),
        top,
        liberty,
        useEmit: flagBool(args.flags, "use-emit"),
        injectStaFixture: flagBool(args.flags, "inject-sta-fixture")
          ? true
          : injectFlag
            ? injectFlag
            : flagBool(args.flags, "no-sta-fixture")
              ? false
              : undefined,
      });
      if (asJson) {
        logger.raw(JSON.stringify(result, null, 2) + "\n");
        return result.ok ? 0 : 1;
      }
      logger.heading("STA handoff S0 (review-only SDC — not sign-off)");
      logger.info(`out-dir  : ${result.outDir}`);
      if (result.ok) {
        logger.success(`seeds    : ${result.seedsSdc}`);
        logger.success(`fo4 csv  : ${result.fo4Csv}`);
        logger.info(`correlate: ${result.correlate}`);
        logger.info(`manifest : ${result.manifest}`);
      }
      for (const st of result.stages) {
        const line = `  [${st.status}] ${st.id}: ${st.detail}`;
        if (st.status === "fail") logger.error(line);
        else if (st.status === "pass") logger.success(line);
        else logger.info(line);
      }
      for (const i of result.issues) logger.error(`  ${i}`);
      if (result.dashboard) {
        logger.heading("Soak dashboard (structural FO4 — not STA)");
        for (const line of formatTimingsDashboardLines(result.dashboard)) {
          logger.info(line);
        }
      }
      logger.info(
        "Plan: architecture/build-platform-opensta-from-timing.md (S1 synth → S2 OpenSTA)",
      );
      return result.ok ? 0 : 1;
    }

    if (sub === "sta-rtl") {
      const or = ctx.config.toolchain.openroad;
      // --fo4 N / --budget-fo4 N: sv-timing correct --emit first, at that budget.
      const staFo4Raw = flagStr(args.flags, "budget-fo4") ?? flagStr(args.flags, "fo4");
      // `--fo4 0` is an explicit "live RTL"; absent → physicalDesign.structural.
      const staFo4 = staFo4Raw != null && Number.isFinite(Number(staFo4Raw)) ? Number(staFo4Raw) : undefined;
      const staFo4PsRaw = flagStr(args.flags, "fo4-ps");
      const staFo4Ps = staFo4PsRaw != null && Number(staFo4PsRaw) > 0 ? Number(staFo4PsRaw) : undefined;
      const staMarginRaw = flagStr(args.flags, "budget-margin");
      const staMargin = staMarginRaw != null && Number.isFinite(Number(staMarginRaw)) ? Number(staMarginRaw) : undefined;
      const threadsFlag = flagStr(args.flags, "threads");
      if (threadsFlag != null) or.threads = Number(threadsFlag);
      const mhzFlag = flagStr(args.flags, "target-mhz");
      const result = await runRtlTiming(ctx, {
        target,
        top: flagStr(args.flags, "top"),
        flist: flagStr(args.flags, "flist"),
        liberty: flagStr(args.flags, "liberty"),
        platform: flagStr(args.flags, "platform"),
        clockPort: flagStr(args.flags, "clock-port") ?? "clk_i",
        targetMhz: mhzFlag != null ? Number(mhzFlag) : ctx.config.soc.targetFrequencyMHz,
        remote: flagBool(args.flags, "remote"),
        rebuildOpenroad: flagBool(args.flags, "rebuild-openroad"),
        outDir: outputSpec,
        fo4Budget: staFo4,
        fo4Ps: staFo4Ps,
        budgetMargin: staMargin,
        svtOptLevel: flagStr(args.flags, "opt-level"),
        svtExtraArgs: splitSvtArgs(flagStr(args.flags, "svt-args")),
        fromTiming,
        mapRecipe: (["synth", "hierarchical", "streamed"] as const).find((r) => r === flagStr(args.flags, "map-recipe")) ?? "lean",
        sramStub: args.flags["no-sram-stub"] === undefined ? undefined : !flagBool(args.flags, "no-sram-stub"),
        allowOverBudget: args.flags["allow-over-budget"] === undefined
          ? undefined : flagBool(args.flags, "allow-over-budget"),
        maxCellsPerFo4: flagStr(args.flags, "max-cells-per-fo4") != null
          ? Number(flagStr(args.flags, "max-cells-per-fo4")) : undefined,
        tradeoffRows: flagStr(args.flags, "tradeoffs") != null ? Number(flagStr(args.flags, "tradeoffs")) : undefined,
      });
      if (asJson) {
        logger.raw(JSON.stringify(result, null, 2) + "\n");
        return result.ok ? 0 : 1;
      }
      logger.heading(`Gate-level STA: ${result.target} -> ${result.top} (study liberty unless yours; not sign-off)`);
      logger.info(`out-dir  : ${result.outDir}`);
      logger.info(`liberty  : ${result.liberty}`);
      logger.info(`threads  : ${or.threads > 0 ? or.threads : `${hostCores()} (every core)`}  march=${or.march} pgo=${or.pgo}`);
      if (result.fo4Budget != null || result.emitFlist) {
        logger.info(
          `sv-timing: budget ${result.fo4Budget ?? "—"} FO4` +
            `${result.svtTargetMhz != null ? ` (${result.svtTargetMhz.toFixed(0)} MHz, fo4_ps=${staFo4Ps ?? 20}, margin=${staMargin ?? 0.2})` : ""}` +
            `${result.emitFlist ? `; emitted package ${result.emitFlist}` : "; no emitted package selected for mapping"}`,
        );
      }
      for (const st of result.stages) {
        const line = `  [${st.status}] ${st.id}: ${st.detail}`;
        if (st.status === "fail") logger.error(line);
        else if (st.status === "pass") logger.success(line);
        else logger.info(line);
      }
      // The area/depth ledger of the plan (A114): what was bought and refused.
      const rowsWanted = flagStr(args.flags, "tradeoffs") != null
        ? Number(flagStr(args.flags, "tradeoffs"))
        : (ctx.config.physicalDesign?.structural?.tradeoffRows ?? 0);
      if (rowsWanted > 0) {
        const rows = tradeoffRows(join(result.outDir, "svt", "correct.json"), rowsWanted);
        if (rows.length) {
          logger.info(`trade-offs (top ${rows.length - 1} by preliminary cells; svt/correct.json tradeoffs[], calibration.tsv feeds the next run):`);
          for (const r of rows) logger.info(`  ${r}`);
        }
      }
      if (result.ok && result.wnsMax !== undefined) {
        logger.success(`wns_max ${result.wnsMax} ns  tns_max ${result.tnsMax} ns  wns_min ${result.wnsMin} ns  tns_min ${result.tnsMin} ns`);
      }
      return result.ok ? 0 : 1;
    }

    if (sub === "platforms") {
      // Every platform the fork checkout ships (test/<dir>/<name>.vars),
      // with the probed FO4 when this host has one.
      const forkRoot = join(ctx.repoRoot, "tools", "openroad");
      const platforms = detectOpenroadPlatforms(forkRoot);
      const table = platformFo4Table(ctx);
      if (asJson) {
        logger.raw(JSON.stringify({ platforms, fo4: table }, null, 2) + "\n");
        return 0;
      }
      logger.heading(`OpenROAD platforms in ${posixPath(forkRoot)}/test (auto-detected from <platform>.vars)`);
      if (!platforms.length) logger.warn("none: populate the submodule (git submodule update --init tools/openroad)");
      for (const p of platforms) {
        const f = table[p.id];
        logger.info(`  ${describePlatform(p)}${f ? `  FO4 ${f.fo4_ps.toFixed(2)} ps (${f.cell})` : "  FO4 not probed (timings fo4-probe --remote)"}`);
      }
      logger.info("yosys-map: plain-text liberty, usable for sta-rtl mapping; sta-only: gzip'd liberty, FO4 probe and STA only");
      return 0;
    }

    if (sub === "fo4-probe") {
      // Measure the platform FO4 (minimum inverter driving four copies) on
      // the builder for one platform or every detected one. The result is
      // the unit `adjusted` reads mapped delays in.
      const forkRoot = join(ctx.repoRoot, "tools", "openroad");
      const want = flagStr(args.flags, "platform");
      const all = flagBool(args.flags, "all") || want == null;
      const platforms = detectOpenroadPlatforms(forkRoot).filter((p) => p.staReadable && (all || p.id === want.toLowerCase()));
      if (!platforms.length) {
        logger.error(`no probe-able platform${want ? ` named ${want}` : ""} in ${posixPath(forkRoot)}/test`);
        return 2;
      }
      if (!flagBool(args.flags, "remote")) {
        logger.error("timings fo4-probe runs the fork's sta on the builder: pass --remote");
        return 2;
      }
      const res = await runPlatformFo4Probes(ctx, platforms);
      if (asJson) {
        logger.raw(JSON.stringify(res, null, 2) + "\n");
        return res.ok ? 0 : 1;
      }
      logger.heading("Platform FO4 probe (inverter chain 8−4 stages, four loads per stage)");
      for (const r of res.results) {
        const line = `  ${r.platform.padEnd(10)} ${r.ok ? `${r.fo4Ps!.toFixed(2)} ps  ${r.cell}  (chain8 ${r.chain8Ns!.toFixed(4)} ns, chain4 ${r.chain4Ns!.toFixed(4)} ns)` : `fail: ${r.error}`}`;
        if (r.ok) logger.success(line);
        else logger.error(line);
      }
      logger.info(`table → ${posixPath(join(ctx.paths.build, "sta-rtl", "platform-fo4.json"))}`);
      return res.ok ? 0 : 1;
    }

    if (sub === "adjusted") {
      // Re-read an existing sta-rtl out-dir's module board in adjusted FO4.
      const dir = outputSpec ?? fromTiming ?? args.positionals[1];
      if (!dir) {
        logger.error("timings adjusted requires --output <sta-rtl out-dir> (with module-board.tsv)");
        return 2;
      }
      const outDir = resolveTimingsOutputDir(ctx, dir, { create: false }).dir;
      const board = join(outDir, "module-board.tsv");
      if (!existsSync(board)) {
        logger.error(`no module board at ${posixPath(board)} (run sta-rtl --remote --map-recipe streamed first)`);
        return 2;
      }
      const platformId = (flagStr(args.flags, "platform") ?? ctx.config.soc.process ?? "").toLowerCase();
      const probed = platformFo4Table(ctx)[platformId];
      if (!probed) {
        logger.error(`platform ${platformId || "?"} has no probed FO4 (timings fo4-probe --platform ${platformId} --remote)`);
        return 2;
      }
      const cfg = ctx.config.physicalDesign?.structural;
      const report = [join(outDir, "svt", "correct.json"), join(outDir, "svt", "analyze.json")].find((p) => existsSync(p));
      const stage = await runAdjustedFo4(ctx, {
        board, report, outDir, platform: probed,
        budget: Number(flagStr(args.flags, "budget-fo4") ?? flagStr(args.flags, "fo4") ?? cfg?.fo4Budget ?? 10),
        margin: Number(flagStr(args.flags, "budget-margin") ?? cfg?.budgetMargin ?? 0.2),
        targetFo4Ps: Number(flagStr(args.flags, "fo4-ps") ?? cfg?.fo4Ps ?? 20),
      });
      if (asJson) {
        logger.raw(JSON.stringify(stage, null, 2) + "\n");
      } else {
        const line = `  [${stage.status}] ${stage.id}: ${stage.detail}`;
        if (stage.status === "fail") logger.error(line);
        else logger.success(line);
        const txt = join(outDir, "adjusted-fo4.txt");
        if (existsSync(txt)) logger.raw(readFileSync(txt, "utf8"));
      }
      return stage.status === "fail" ? 1 : 0;
    }

    if (sub === "correlate") {
      const spec = fromTiming ?? outputSpec ?? args.positionals[1];
      if (!spec) {
        logger.error("timings correlate requires --from-timing <dir>");
        return 2;
      }
      const benchId = flagStr(args.flags, "bench") ?? "unspecified";
      const dash = summarizeTimingsPackage(ctx, spec);
      const metrics: Record<string, number | string> = {};
      // Optional suite-exported metrics (when parent sets env after a bench run)
      for (const k of [
        "CVA6_BENCH_DMIPS",
        "CVA6_BENCH_ITERATIONS",
        "CVA6_BENCH_CYCLES",
        "CVA6_BENCH_SCORE",
        "CVA6_BENCH_RUNTIME_S",
        "CVA6_BENCH_COREMARK_MHZ",
        "CVA6_BENCH_ITER_PER_SEC",
        "CVA6_BENCH_DHRYSTONES_PER_SEC",
      ]) {
        if (process.env[k]) metrics[k] = process.env[k]!;
      }
      const logFile = flagStr(args.flags, "file");
      if (logFile && existsSync(logFile)) {
        Object.assign(metrics, parseBenchLog(readFileSyncNode(logFile, "utf8")));
      }
      const body = buildBenchCorrelation({
        dashboard: dash,
        benchId,
        metrics,
      });
      const outDir = dash.source;
      mkdirSync(outDir, { recursive: true });
      const outPath = join(outDir, "bench-correlate.json");
      writeFileSync(outPath, JSON.stringify(body, null, 2) + "\n", "utf8");
      if (asJson) {
        logger.raw(JSON.stringify(body, null, 2) + "\n");
      } else {
        logger.heading("Bench × timings correlate (not STA)");
        logger.info(`bench    : ${benchId}`);
        logger.info(`wrote    : ${outPath}`);
        if (Object.keys(metrics).length) {
          logger.info(`metrics  : ${JSON.stringify(metrics)}`);
        }
        for (const line of formatTimingsDashboardLines(dash)) logger.info(line);
      }
      return dash.ok ? 0 : 1;
    }

    if (sub === "fo4-golden") {
      const action = (args.positionals[1] ?? "check").toLowerCase();
      const spec =
        fromTiming ??
        outputSpec ??
        flagStr(args.flags, "from-timing") ??
        args.positionals[2];
      if (!spec) {
        logger.error(
          "timings fo4-golden check|write requires --from-timing <dir>",
        );
        return 2;
      }
      const { resolveFromTimingDir } = await import("../../tooling/timings.ts");
      const dir = resolveFromTimingDir(ctx, spec);
      const goldenFlag = flagStr(args.flags, "golden");

      if (action === "write") {
        const reportPath = existsSync(join(dir, "analyze.json"))
          ? join(dir, "analyze.json")
          : join(dir, "correct.json");
        if (!existsSync(reportPath)) {
          logger.error(`no analyze/correct JSON in ${dir}`);
          return 1;
        }
        const report = JSON.parse(readFileSyncNode(reportPath, "utf8")) as Record<
          string,
          unknown
        >;
        const g = goldenFromAnalyze(report, {
          packageId: dir.replace(/\\/g, "/").split("/").pop(),
        });
        const outG = goldenFlag ?? join(dir, "fo4-golden.json");
        writeFo4Golden(outG, g);
        logger.success(`wrote FO4 golden: ${outG} (${g.paths.length} paths)`);
        return 0;
      }

      // check
      const result = checkFo4Golden(dir, goldenFlag);
      if (asJson) {
        logger.raw(JSON.stringify(result, null, 2) + "\n");
        return result.ok ? 0 : 1;
      }
      logger.heading("FO4 golden check (structural — not STA)");
      logger.info(`report   : ${result.reportPath}`);
      logger.info(`golden   : ${result.goldenPath}`);
      logger.info(`compared : ${result.compared} path(s)  tol=${result.tolerance}`);
      if (result.ok) {
        logger.success("FO4 golden MATCH");
        return 0;
      }
      for (const m of result.mismatches) {
        logger.error(`  [${m.kind}] ${m.detail}`);
      }
      logger.error("FO4 golden MISMATCH");
      return 1;
    }

    if (sub === "parse-bench-log") {
      const file = flagStr(args.flags, "file") ?? args.positionals[1];
      if (!file || !existsSync(file)) {
        logger.error("timings parse-bench-log requires --file <log>");
        return 2;
      }
      const metrics = parseBenchLog(readFileSyncNode(file, "utf8"));
      applyBenchMetricsToEnv(metrics);
      if (asJson) {
        logger.raw(JSON.stringify(metrics, null, 2) + "\n");
      } else {
        logger.heading("Bench metrics from log");
        if (!Object.keys(metrics).length) {
          logger.warn("no recognized Dhrystone/CoreMark markers found");
        }
        for (const [k, v] of Object.entries(metrics)) {
          logger.info(`  ${k}=${v}`);
        }
      }
      return 0;
    }

    if (sub === "lab-run") {
      // One-shot offline lab path: fixture package → FO4 golden → sta-handoff
      const pkgDir =
        outputSpec != null
          ? outputSpec.startsWith("workspace/")
            ? join(ctx.paths.root, outputSpec.replace(/^workspace[/\\]/i, ""))
            : join(ctx.paths.build, "sv-timing", "lab-run")
          : join(ctx.paths.build, "sv-timing", "lab-run");
      const handoffDir = join(ctx.paths.build, "sta-handoff", "lab-run");
      logger.heading("timings lab-run (sta_smoke → golden → handoff)");
      const mat = materializeStaSmokePackage(ctx, pkgDir);
      logger.success(`package  : ${mat.dir}  top=${mat.top}`);
      const gold = checkFo4Golden(mat.dir);
      if (!gold.ok) {
        logger.error("FO4 golden check failed");
        for (const m of gold.mismatches) logger.error(`  [${m.kind}] ${m.detail}`);
        return 1;
      }
      logger.success(`fo4-golden MATCH (${gold.compared} paths)`);
      // Default ON: inject synthetic opensta_paths.rpt so offline S3a always scores.
      // --no-sta-fixture disables; --inject-sta-fixture <path> overrides fixture source.
      const hand = await runStaHandoff(ctx, {
        fromTiming: mat.dir,
        outDir: handoffDir,
        tryTools: !flagBool(args.flags, "no-tools"),
        top: mat.top,
        liberty: flagStr(args.flags, "liberty"),
        injectStaFixture: flagBool(args.flags, "no-sta-fixture")
          ? false
          : flagStr(args.flags, "inject-sta-fixture") ?? true,
      });
      const written = writeLabReport(handoffDir, {
        packageDir: mat.dir,
        handoffDir,
        golden: gold,
        handoff: hand,
        dashboard: hand.dashboard,
        hostNote:
          "S1–S2 soft-skip without yosys/liberty/opensta. Set CVA6_LIBERTY for OpenSTA.",
      });
      const retune = proposeFo4Retune(ctx, {
        fromHandoff: handoffDir,
        outDir: handoffDir,
      });
      if (asJson) {
        logger.raw(
          JSON.stringify(
            { labReport: written.report, retuneProposal: retune.proposal },
            null,
            2,
          ) + "\n",
        );
      } else {
        logger.info(`handoff  : ${hand.outDir}`);
        logger.success(`report   : ${written.md}`);
        logger.info(`json     : ${written.json}`);
        for (const st of hand.stages) {
          const line = `  [${st.status}] ${st.id}: ${st.detail}`;
          if (st.status === "fail") logger.error(line);
          else if (st.status === "pass") logger.success(line);
          else logger.info(line);
        }
        if (hand.dashboard) {
          logger.heading("Soak dashboard (structural FO4 — not STA)");
          for (const line of formatTimingsDashboardLines(hand.dashboard)) {
            logger.info(line);
          }
        }
        if (retune.written) {
          logger.heading("S3b-lab retune proposal (review-only)");
          logger.success(`proposal : ${retune.written.md}`);
          logger.info(
            `agreement: ${retune.proposal.agreement}  overlap_score=${retune.proposal.overlap_score}`,
          );
          for (const a of retune.proposal.actions.slice(0, 3)) {
            logger.info(`  → ${a}`);
          }
        }
        logger.info(
          "Next: set CVA6_LIBERTY and re-run lab-run for S2; see architecture/build-platform-opensta-from-timing.md",
        );
      }
      return hand.ok && gold.ok ? 0 : 1;
    }

    if (sub === "retune-propose") {
      const fromHandoff =
        flagStr(args.flags, "from-handoff") ??
        flagStr(args.flags, "from-timing") ??
        args.positionals[1];
      const out =
        outputSpec ??
        (fromHandoff && existsSync(fromHandoff)
          ? fromHandoff.endsWith(".json")
            ? dirnameSafe(fromHandoff)
            : fromHandoff
          : undefined);
      const result = proposeFo4Retune(ctx, {
        fromHandoff: fromHandoff ?? null,
        outDir: out ?? null,
      });
      if (asJson) {
        logger.raw(JSON.stringify(result, null, 2) + "\n");
        return 0;
      }
      logger.heading("FO4 retune proposal (S3b-lab — review-only)");
      if (result.correlatePath) {
        logger.info(`correlate: ${result.correlatePath}`);
      } else {
        logger.warn("correlate: none — run timings lab-run first");
      }
      logger.info(
        `agreement: ${result.proposal.agreement}  score=${result.proposal.overlap_score}`,
      );
      if (result.written) {
        logger.success(`wrote    : ${result.written.md}`);
        logger.info(`json     : ${result.written.json}`);
      }
      for (const a of result.proposal.actions) logger.info(`  → ${a}`);
      if (result.proposal.costHints.length) {
        logger.heading("Cost hints");
        for (const h of result.proposal.costHints.slice(0, 12)) {
          logger.info(
            `  ${h.costKey}=${h.current ?? "?"}  ${h.reason}`,
          );
        }
      }
      return 0;
    }

    if (sub === "flist") {
      if (!pkgRoot) {
        logger.error("sv-timing package not found at repo root.");
        return 1;
      }
      const env = buildEnv(ctx, target);
      const tag = `host-${target}`;
      const layout = resolveTimingsOutputDir(ctx, outputSpec, { tag, create: true });
      // --out as bare file path still supported when it ends with .f
      const outPath =
        outputSpec && /\.f$/i.test(outputSpec)
          ? outputSpec
          : outputSpec
            ? layout.portableF
            : flagStr(args.flags, "out") && /\.f$/i.test(flagStr(args.flags, "out")!)
              ? flagStr(args.flags, "out")
              : layout.portableF;
      const portable = flistOverride
        ? writePortableTimingsFlist(ctx, {
            entryFlist: flistOverride,
            env,
            tag,
            outPath,
          })
        : writeVerifyPortableFlist(ctx, env, target, {
            tag,
            outPath,
            flist: flistOverride,
          });
      if (asJson) {
        logger.raw(
          JSON.stringify(
            {
              portablePath: portable.portablePath,
              output: outputSpec ? layout.dir : null,
              files: portable.files.length,
              incdirs: portable.incdirs.length,
            },
            null,
            2,
          ) + "\n",
        );
      } else {
        logger.success(`wrote portable flist: ${portable.portablePath}`);
        if (outputSpec && !/\.f$/i.test(outputSpec)) {
          logger.info(`output dir: ${layout.dir}`);
        }
        logger.info(
          `  ${portable.files.length} files, ${portable.incdirs.length} incdirs`,
        );
      }
      return 0;
    }

    if (sub === "compile" || sub === "analyze" || sub === "correct" || sub === "area") {
      return runAnalyzeOrCorrect(
        ctx,
        args,
        sub === "compile" ? "compile" : sub === "correct" ? "correct" : sub === "area" ? "area" : "analyze",
      );
    }

    logger.error(`unknown timings subcommand: ${sub}`);
    logger.info(
      "Use: timings status | doctor | flist | compile | analyze | area | correct | validate | summary | sta-handoff | correlate | fo4-golden | retune-propose | parse-bench-log | lab-run",
    );
    return 2;
  },
};

function dirnameSafe(p: string): string {
  const i = Math.max(p.lastIndexOf("/"), p.lastIndexOf("\\"));
  return i >= 0 ? p.slice(0, i) : ".";
}
