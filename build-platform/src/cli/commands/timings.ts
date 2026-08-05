// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// timings.ts — Host CLI for the standalone sv-timing package.
//
//   timings status              locate package + report paths
//   timings flist               flatten verify flist → portable .f
//   timings compile|analyze     flist + analyze into --output out-dir
//   timings correct             flist + correct (optional --emit into out-dir)
//   timings validate            structural check of a precompile out-dir
//
// --output / -o / --out  : compile target directory (portable.f + JSON + cache + stamp)
// Does not link monorepo code into sv-timing crates. See sv-timing/AGENTS-host.md.

import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { flagBool } from "../args.ts";
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
import {
  buildBenchCorrelation,
  materializeStaSmokePackage,
  runStaHandoff,
} from "../../tooling/staHandoff.ts";
import { readFileSync as readFileSyncNode } from "node:fs";
import {
  buildSvTimingAnalyzeArgs,
  buildSvTimingCorrectArgs,
  buildSvtRunCommand,
  formatTimingsDashboardLines,
  resolveSvTimingRoot,
  resolveTimingsOutputDir,
  summarizeTimingsPackage,
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
  kind: "analyze" | "correct" | "compile",
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

  // compile is analyze with a guaranteed out-dir layout
  const runKind: "analyze" | "correct" = kind === "correct" ? "correct" : "analyze";

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
    (runKind === "analyze" ? layout.analyzeJson : layout.correctJson);
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

  const mhz = targetMhz != null ? Number(targetMhz) : ctx.config.soc.targetFrequencyMHz;
  const fo4 = fo4Ps != null ? Number(fo4Ps) : undefined;

  let paramMapPath = paramMapFlag;
  if (!paramMapPath && autoParamMap) {
    paramMapPath = writeHostParamMap(ctx, {
      outPath: layout.paramMap,
      xlen: assumeXlen,
    });
    logger.info(`param-map: ${paramMapPath}`);
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
      : buildSvTimingCorrectArgs({
          portableFlist: portable.portablePath,
          modules,
          allModules,
          targetMhz: mhz,
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

  const cmd = buildSvtRunCommand(ctx, cliArgs);
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
    "bun run src/cli/index.ts timings [status|doctor|flist|compile|analyze|correct|validate|summary|dashboard|sta-handoff|correlate|fo4-golden|retune-propose|parse-bench-log|lab-run] [options…]",
  details:
    "Prepares monorepo flists for the independent sv-timing package and spawns\n" +
    "its CLI via `python tools/svt.py run -- …`. Never links monorepo code into\n" +
    "sv-timing crates.\n" +
    "\n" +
    "  timings status     locate sv-timing/ and print default out dirs\n" +
    "  timings flist      flatten → portable.f (use --output DIR for package layout)\n" +
    "  timings compile    analyze into a full --output out-dir (portable+JSON+cache+stamp)\n" +
    "  timings analyze    same as compile (alias; prefers --output over ad-hoc --json-out)\n" +
    "  timings correct    correct (+ optional --emit into <output>/corrected)\n" +
    "  timings validate   structural check of a precompile out-dir (--from-timing)\n" +
    "  timings summary    soak dashboard from analyze.json (alias: dashboard)\n" +
    "  timings sta-handoff  S0–S2 OpenSTA handoff from --from-timing (--try-tools)\n" +
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
    "bun run src/cli/index.ts timings correct --modules alu --allow-latency --emit -o out/t1",
    "bun run src/cli/index.ts timings validate --from-timing out/t1",
    "bun run src/cli/index.ts timings summary --from-timing out/t1",
    "bun run src/cli/index.ts timings sta-handoff --from-timing out/t1 --try-tools",
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

    if (sub === "compile" || sub === "analyze" || sub === "correct") {
      return runAnalyzeOrCorrect(
        ctx,
        args,
        sub === "compile" ? "compile" : sub === "correct" ? "correct" : "analyze",
      );
    }

    logger.error(`unknown timings subcommand: ${sub}`);
    logger.info(
      "Use: timings status | doctor | flist | compile | analyze | correct | validate | summary | sta-handoff | correlate | fo4-golden | retune-propose | parse-bench-log | lab-run",
    );
    return 2;
  },
};

function dirnameSafe(p: string): string {
  const i = Math.max(p.lastIndexOf("/"), p.lastIndexOf("\\"));
  return i >= 0 ? p.slice(0, i) : ".";
}
