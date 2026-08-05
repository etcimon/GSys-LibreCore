// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// diag.ts — Compartmentalized diagnostic tests (own Verilator configs).
//
//   diag list                    list tests by compartment
//   diag status                  readiness without running Verilator
//   diag run [compartment|id…]   execute selected diagnostics
//   diag run --all               include optional tests
//
// Each verilator-* diagnostic owns target/top/flist/lintArgs/warningBudget
// under config.diagnostics (see schema). Complements full `verify` and `probe`.

import { requireContext, type Command } from "../command.ts";
import { flagBool, flagString } from "../args.ts";
import {
  DIAG_COMPARTMENTS,
  diagnosticReadiness,
  listDiagnostics,
  runDiagnostics,
  selectDiagnostics,
} from "../../tooling/diagnostics.ts";
import { gatherProbeReport } from "../../tooling/probe.ts";
import { edaPaths, edaPresence } from "../../tooling/eda.ts";
import { validateTimingsOutDir } from "../../tooling/timings.ts";
import { renderBox, type BoxRow } from "../../util/box.ts";

export const diagCommand: Command = {
  name: "diag",
  summary:
    "Compartmentalized diagnostics with per-test Verilator configs (host/core/smt2/ooo/apu).",
  usage:
    "bun run src/cli/index.ts diag [list|status|run] [compartment|id…] [--all] [--from-timing DIR] [--json] [--dry-run]",
  details:
    "Diagnostics are small, self-contained gates from config.diagnostics.tests.\n" +
    "Unlike `verify` (full multi-target sweep), each test can declare its own\n" +
    "Verilator surface: target, top, flist extras, lintArgs, defines, warningBudget.\n" +
    "\n" +
    "  diag list              list compartments + tests\n" +
    "  diag status            readiness (no heavy lint unless tools already there)\n" +
    "  diag run               run default compartments (diagnostics.defaultCompartments)\n" +
    "  diag run core smt2     run compartments\n" +
    "  diag run diag-smt2-lint  run one test by id\n" +
    "  diag run --all         include optional tests when selecting by compartment\n" +
    "  --from-timing <dir>    preflight structural validate of timings out-dir\n" +
    "                         (does not replace live RTL flists; see lifecycle plan)\n" +
    "\n" +
    "Compartments: host | core | smt2 | ooo | apu | residual\n" +
    "Related: probe diag | verify --lint | probe install | timings validate",
  examples: [
    "bun run src/cli/index.ts diag list",
    "bun run src/cli/index.ts diag status",
    "bun run src/cli/index.ts diag run",
    "bun run src/cli/index.ts diag run core",
    "bun run src/cli/index.ts diag run diag-smt2-lint",
    "bun run src/cli/index.ts diag run smt2 --all",
    "bun run src/cli/index.ts diag run core --from-timing workspace/build/sv-timing/host-cv64a6_imafdc_sv39",
  ],
  needsContext: true,
  async run(args) {
    const ctx = requireContext(args);
    const { logger, config } = ctx;
    const sub = (args.positionals[0] ?? "list").toLowerCase();
    const filter = args.positionals.slice(1);
    const asJson = flagBool(args.flags, "json");
    const includeOptional = flagBool(args.flags, "all");
    const color = !process.env.NO_COLOR && !flagBool(args.flags, "no-color");

    if (sub === "list" || sub === "ls") {
      if (asJson) {
        logger.raw(JSON.stringify(config.diagnostics, null, 2) + "\n");
        return 0;
      }
      logger.heading("Diagnostic compartments");
      for (const c of DIAG_COMPARTMENTS) {
        const tests = config.diagnostics.tests.filter((t) => t.compartment === c);
        if (!tests.length) continue;
        logger.info(`\n  [${c}]  (${tests.length} test(s))`);
        for (const t of tests) {
          const vl = t.verilator
            ? `  verilator:target=${t.verilator.target}` +
              (t.verilator.top ? ` top=${t.verilator.top}` : "") +
              (t.verilator.warningBudget != null
                ? ` budget=${t.verilator.warningBudget}`
                : "")
            : "";
          const opt = t.optional ? " (optional)" : "";
          logger.info(`    ${t.id.padEnd(28)} ${t.kind.padEnd(16)}${opt}`);
          logger.info(`      ${t.description}${vl}`);
        }
      }
      logger.info("");
      logger.info(
        `default run: ${config.diagnostics.defaultCompartments.join(", ") || "(all non-optional)"}`,
      );
      logger.info("Run: diag run [compartment|id…]   Status: diag status");
      return 0;
    }

    if (sub === "status") {
      const paths = edaPaths(ctx);
      const presence = edaPresence(paths);
      let probeReport = null;
      try {
        probeReport = await gatherProbeReport(ctx);
      } catch {
        /* optional */
      }
      const rows = diagnosticReadiness(ctx, probeReport);

      if (asJson) {
        logger.raw(
          JSON.stringify({ eda: presence, diagnostics: rows }, null, 2) + "\n",
        );
        return 0;
      }

      logger.heading("EDA suite (verify.suite)");
      for (const t of presence) {
        const line = `${t.id.padEnd(12)} ${t.present ? "present" : "MISSING"}  ${t.path}`;
        if (t.present) logger.success(line);
        else logger.warn(line);
      }

      const boxRows: BoxRow[] = [];
      for (const c of DIAG_COMPARTMENTS) {
        const subset = rows.filter((r) => r.compartment === c);
        if (!subset.length) continue;
        boxRows.push({ value: `── ${c} ──`, tone: "dim" });
        for (const r of subset) {
          boxRows.push({
            label: r.id.slice(0, 14),
            value: `${r.ready ? "ready" : "not ready"}  ${r.note}${r.optional ? " (opt)" : ""}`,
            tone: r.ready ? "ok" : r.optional ? "dim" : "warn",
          });
        }
      }
      logger.raw(
        "\n" +
          renderBox(boxRows, {
            title: "Diagnostic readiness",
            tabId: "diag",
            color,
            width: 76,
          }) +
          "\n",
      );
      logger.info("Execute: diag run   |   probe diag");
      return 0;
    }

    if (sub === "run") {
      let runFilter = filter;
      if (includeOptional && filter.length === 0) {
        // all tests including optional
        runFilter = config.diagnostics.tests.map((t) => t.id);
      } else if (includeOptional && filter.length > 0) {
        // expand compartments to include optional
        const expanded: string[] = [];
        for (const f of filter) {
          if ((DIAG_COMPARTMENTS as string[]).includes(f.toLowerCase())) {
            for (const t of config.diagnostics.tests.filter(
              (x) => x.compartment === f.toLowerCase(),
            )) {
              expanded.push(t.id);
            }
          } else {
            expanded.push(f);
          }
        }
        runFilter = expanded;
      }

      const fromTiming = flagString(args.flags, "from-timing");
      if (fromTiming) {
        const v = validateTimingsOutDir(ctx, {
          fromTiming,
          requireEmit: flagBool(args.flags, "require-emit"),
        });
        if (!v.ok) {
          logger.error(`--from-timing structure invalid: ${v.dir}`);
          for (const issue of v.issues.filter((i) => i.level === "error")) {
            logger.error(`  [${issue.code}] ${issue.message}`);
          }
          return 1;
        }
        logger.success(
          `--from-timing OK: ${v.dir} (${v.fileCount} files; live RTL still used for Verilator)`,
        );
        // Export for any diagnostic subprocess that opts in (lint surfaces stay live).
        process.env.CVA6_FROM_TIMING = v.dir;
        process.env.FROM_TIMING = v.dir;
      }

      const preview = selectDiagnostics(
        config.diagnostics,
        runFilter.length ? runFilter : undefined,
      );
      if (preview.unknown.length) {
        logger.error(`Unknown: ${preview.unknown.join(", ")}`);
        logger.info("diag list  for ids and compartments");
        return 1;
      }

      logger.heading(
        `Running ${preview.tests.length} diagnostic(s)` +
          (ctx.dryRun ? " [dry-run]" : ""),
      );
      for (const t of preview.tests) {
        logger.info(
          `  · ${t.id}  [${t.compartment}/${t.kind}]` +
            (t.verilator ? `  cfg=${t.verilator.target}` : ""),
        );
      }

      const summary = await runDiagnostics(
        ctx,
        runFilter.length ? runFilter : undefined,
      );

      if (asJson) {
        logger.raw(JSON.stringify(summary, null, 2) + "\n");
        return summary.hardFails > 0 ? 1 : 0;
      }

      logger.heading("Results");
      for (const o of summary.outcomes) {
        const mark =
          o.status === "pass" ? "PASS" : o.status === "skip" ? "SKIP" : "FAIL";
        const line = `${mark.padEnd(4)} ${o.id.padEnd(28)} ${o.detail}`;
        if (o.status === "pass") logger.success(line);
        else if (o.status === "skip") logger.warn(line);
        else logger.error(line);
        if (o.warnings != null) logger.info(`       warnings=${o.warnings}`);
      }

      logger.heading("Summary");
      logger.info(
        `pass=${summary.passed}  fail=${summary.failed}  skip=${summary.skipped}  hardFails=${summary.hardFails}`,
      );
      if (summary.hardFails > 0) {
        logger.error("Diagnostics failed.");
        logger.info("probe install  |  tools install sim  |  verify --lint");
        return 1;
      }
      logger.success("Diagnostics passed (or optional skips only).");
      return 0;
    }

    logger.error(`Unknown diag subcommand '${sub}'. Use list | status | run.`);
    return 1;
  },
};
