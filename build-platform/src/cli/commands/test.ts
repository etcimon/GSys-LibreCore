// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// test.ts — Run LibreCore regression suite(s) discovered from verif/regress.

import { requireContext, type Command } from "../command.ts";
import { flagBool, flagString } from "../args.ts";
import {
  broadSuites,
  canRunSuites,
  preflightSuite,
  runSuites,
  selectSuites,
  suitesInGroup,
  TEST_GROUPS,
} from "../../tests/runner.ts";
import type { PlatformContext } from "../../context.ts";
import type { TestSuite } from "../../config/schema.ts";
import {
  applyFromTimingFlags,
  formatTimingsDashboardLines,
  summarizeTimingsPackage,
  writeTimingsDashboard,
} from "../../tooling/timings.ts";
import { offerInstallMissingTools } from "../../tooling/offerInstall.ts";
import type { ManagedTool } from "../../config/schema.ts";

/** Print every catalogued suite with its group, tags, and runnable status. */
function printList(ctx: PlatformContext): void {
  const { logger, config } = ctx;
  const suites = config.tests.suites;
  logger.heading("Regression suites (verif/regress)");
  const idW = Math.max(...suites.map((s) => s.id.length));
  const grpW = Math.max(...suites.map((s) => s.group.length));
  for (const s of suites) {
    const pf = preflightSuite(ctx, s);
    const tags = [
      s.openSource ? "oss" : "commercial",
      ...(s.requiresUvm ? ["uvm"] : []),
      ...(s.requiresSubmodule ? [s.requiresSubmodule] : []),
      ...(s.optional ? ["optional"] : []),
    ].join(",");
    const line = `${s.id.padEnd(idW)}  ${s.group.padEnd(grpW)}  [${tags}]  ${pf.runnable ? "runnable" : (pf.reason ?? "")}`;
    if (pf.runnable) logger.success(line);
    else logger.warn(line);
  }
  logger.info("");
  logger.info(`Groups: ${TEST_GROUPS.join(", ")}`);
  logger.info("Select: bun run src/cli/index.ts test <id...> | --suite a,b | --group <g> | --all | --open-source");
}

export const testCommand: Command = {
  name: "test",
  summary: "Run LibreCore regression suite(s) discovered from verif/regress.",
  usage:
    "bun run src/cli/index.ts test [<id...>] [--suite a,b] [--group <g>] [--all] [--open-source] [--list] [--from-timing DIR] [--use-emit] [--yes] [--dry-run]",
  details:
    "Selection (first match wins):\n" +
    "  <id...> / --suite a,b   explicit suite ids\n" +
    `  --group <g>             a whole family (${TEST_GROUPS.join("|")})\n` +
    "  --all                   every non-optional suite (+ --include-optional)\n" +
    "  --open-source           only suites runnable on the managed OSS toolchain\n" +
    "  (none)                  tests.defaultSuites from .config.ts\n" +
    "Suites whose tools / submodule / UVM simulator are missing are SKIPPED\n" +
    "(not failed), so a broad run validates cleanly on a partially-provisioned\n" +
    "host — unless you accept an interactive install prompt (or pass --yes).\n" +
    "`--list` shows every suite with its runnable status.\n" +
    "\n" +
    "--from-timing <dir>  validate timings precompile out-dir structure first,\n" +
    "                     then export CVA6_FROM_TIMING for regress scripts.\n" +
    "--use-emit           expert: also export CVA6_TIMINGS_EMIT_FLIST (default off).\n" +
    "                     Default soaks still use live RTL.\n" +
    "--yes / -y           auto-accept tools install when managed tools are missing.",
  examples: [
    "bun run src/cli/index.ts test --list",
    "bun run src/cli/index.ts test smoke-cv64a6",
    "bun run src/cli/index.ts test --suite ooo-l3-tests",
    "bun run src/cli/index.ts test --group arch",
    "bun run src/cli/index.ts test --open-source --dry-run",
    "bun run src/cli/index.ts test --all --include-optional",
    "bun run src/cli/index.ts test sv-timing-smoke --from-timing workspace/build/sv-timing/verif-tests/smoke",
  ],
  needsContext: true,
  async run(args) {
    const ctx = requireContext(args);
    const { logger, config } = ctx;

    if (flagBool(args.flags, "list")) {
      printList(ctx);
      return 0;
    }

    logger.heading("LibreCore regression");

    if (!ctx.dryRun && !canRunSuites()) {
      logger.error(
        "No shell available to run regression scripts (need bash and/or pwsh/powershell). " +
          "On Windows install Git-Bash/WSL or use pwsh with sibling .ps1 scripts.",
      );
      return 1;
    }

    const suiteFlag = flagString(args.flags, "suite");
    const ids = [
      ...args.positionals,
      ...(suiteFlag ? suiteFlag.split(",").map((s) => s.trim()).filter(Boolean) : []),
    ];
    const includeOptional = flagBool(args.flags, "include-optional");

    let suites: TestSuite[];
    if (ids.length > 0) {
      const sel = selectSuites(config, ids);
      for (const u of sel.unknown) logger.warn(`unknown suite '${u}' — skipping (see: test --list).`);
      suites = sel.suites;
    } else if (typeof args.flags.group === "string") {
      const group = args.flags.group;
      if (!(TEST_GROUPS as string[]).includes(group)) {
        logger.error(`unknown group '${group}'. Valid groups: ${TEST_GROUPS.join(", ")}.`);
        return 1;
      }
      suites = suitesInGroup(config, group);
    } else if (flagBool(args.flags, "all")) {
      suites = broadSuites(config, { includeOptional });
    } else if (flagBool(args.flags, "open-source")) {
      suites = broadSuites(config, { openSourceOnly: true, includeOptional });
    } else {
      suites = selectSuites(config).suites;
    }

    if (suites.length === 0) {
      logger.warn("No suites selected. Try `bun run src/cli/index.ts test --list`.");
      return 0;
    }

    // Offer install when selected suites need managed tools that are missing.
    if (!ctx.dryRun) {
      const needed = new Set<ManagedTool>();
      for (const s of suites) for (const t of s.tools) needed.add(t);
      // Heavy directed suites often list tools:[] but still need Verilator at runtime.
      if (suites.some((s) => s.group === "directed" || s.id.includes("ooo") || s.id.includes("l3"))) {
        needed.add("verilator");
        needed.add("riscv-gcc");
      }
      if (needed.size > 0) {
        await offerInstallMissingTools(ctx, [...needed], args.flags as Record<string, string | boolean>);
      }
    }

    const fromTiming = flagString(args.flags, "from-timing");
    const useEmit = flagBool(args.flags, "use-emit");
    if (useEmit && !fromTiming) {
      logger.error("--use-emit requires --from-timing <dir>");
      return 2;
    }
    let fromTimingDir: string | undefined;
    if (fromTiming) {
      const ft = applyFromTimingFlags(ctx, {
        fromTiming,
        useEmit,
        requireEmit: useEmit || flagBool(args.flags, "require-emit"),
      });
      if (!ft.ok) {
        logger.error(`--from-timing structure invalid: ${ft.dir ?? fromTiming}`);
        for (const issue of ft.issues.filter((i) => i.level === "error")) {
          logger.error(`  [${issue.code}] ${issue.message}`);
        }
        logger.info("Fix the out-dir or run: timings validate --from-timing <dir>");
        return 1;
      }
      fromTimingDir = ft.dir;
      logger.success(
        `--from-timing OK: ${ft.dir} (report=${ft.validation?.reportKind ?? "?"})`,
      );
      if (useEmit && ft.emitFlist) {
        logger.warn(`expert --use-emit: ${ft.emitFlist}`);
        logger.info(
          "CVA6_TIMINGS_USE_EMIT=1: writeFlatManifest overlays matching *__svt.sv from emit flist (R8)",
        );
        Object.assign(process.env, ft.env);
      }
      for (const issue of ft.issues.filter((i) => i.level === "warn")) {
        logger.warn(`  [${issue.code}] ${issue.message}`);
      }
      // T3b: structural FO4 soak dashboard next to suite run (not STA)
      const dash = summarizeTimingsPackage(ctx, ft.dir!);
      writeTimingsDashboard(ft.dir!, dash);
      logger.heading("Soak dashboard (structural FO4 — not STA)");
      for (const line of formatTimingsDashboardLines(dash)) {
        logger.info(line);
      }
    }

    const results = await runSuites(ctx, suites, {
      dryRun: ctx.dryRun,
      fromTimingDir,
    });
    const failures = results.filter((r) => !r.ok && !r.skipped);
    const skipped = results.filter((r) => r.skipped && r.reason !== "dry-run");

    logger.heading("Summary");
    logger.info(
      `selected: ${results.length}, skipped: ${skipped.length}, failures: ${failures.length}`,
    );
    return failures.length > 0 ? 1 : 0;
  },
};
