// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// clean.ts — Remove managed workspace outputs with purpose / age granularity.
//
// Plan: architecture/build-platform-workspace-lifecycle.md
// Only deletes under allowlisted roots (workspace + optional work-ver).

import { flagBool, flagString } from "../args.ts";
import { requireContext, type Command } from "../command.ts";
import {
  cleanAllowRoots,
  CLEAN_PURPOSES,
  formatAge,
  formatBytes,
  listCleanTargets,
  parseDurationMs,
  purposesFromLegacyFlags,
  purposesFromSubcommand,
  removeCleanTargets,
  selectCleanTargets,
  type CleanExecutionFilter,
  type CleanPurpose,
  type CleanTarget,
} from "../../workspace/clean.ts";

const REPO_SIM_DIRS = ["work-ver"];

function printStatus(
  targets: CleanTarget[],
  logger: { info: (s: string) => void; heading: (s: string) => void; raw: (s: string) => void },
  asJson: boolean,
): void {
  const now = Date.now();
  if (asJson) {
    logger.raw(
      JSON.stringify(
        {
          targets: targets.map((t) => ({
            purpose: t.purpose,
            path: t.path,
            label: t.label,
            present: t.present,
            bytes: t.bytes,
            mtimeMs: t.mtimeMs,
            age: formatAge(t.mtimeMs, now),
            requiresYes: t.requiresYes,
            rootKind: t.rootKind,
          })),
          totalBytes: targets.reduce((a, t) => a + t.bytes, 0),
        },
        null,
        2,
      ) + "\n",
    );
    return;
  }
  logger.heading("Clean inventory (managed workspace + opt-in sim outs)");
  const pw = Math.max(...targets.map((t) => t.purpose.length), 8);
  const lw = Math.max(...targets.map((t) => t.label.length), 8);
  for (const t of targets) {
    const size = t.present ? formatBytes(t.bytes).padStart(10) : "       —";
    const age = t.present ? formatAge(t.mtimeMs, now).padStart(5) : "    —";
    const mark = t.present ? " " : "!";
    const yes = t.requiresYes ? " [--yes]" : "";
    logger.info(
      `  ${mark}${t.purpose.padEnd(pw)}  ${size}  age ${age}  ${t.label.padEnd(lw)}${yes}`,
    );
  }
  const total = targets.filter((t) => t.purpose !== "workspace" && t.purpose !== "build")
    .reduce((a, t) => a + (t.present ? t.bytes : 0), 0);
  // Prefer leaf totals; also show build + tooling for glance.
  const build = targets.find((t) => t.purpose === "build");
  const tooling = targets.find((t) => t.purpose === "tooling");
  logger.info("");
  logger.info(
    `  build total: ${build?.present ? formatBytes(build.bytes) : "—"}` +
      `   tooling: ${tooling?.present ? formatBytes(tooling.bytes) : "—"}` +
      `   leaf sum*: ${formatBytes(total)}`,
  );
  logger.info("  *leaf sum excludes build/workspace parents (may double-count).");
  logger.info("");
  logger.info("Remove: clean <purpose> [--older-than 7d] [--dry-run] [--yes]");
  logger.info(`Purposes: ${CLEAN_PURPOSES.join(" | ")}`);
}

export const cleanCommand: Command = {
  name: "clean",
  summary:
    "Remove workspace build/cache artifacts by purpose (and opt-in sim outs).",
  usage:
    "bun run src/cli/index.ts clean [status|build|diag|verify|formal|timings|cache|manifests|downloads|man|dts|tooling|firmware|sim|svt|svt-tools|rust-target|all] [--older-than Nd|Nh|Nm] [--execution all|last|failed|ok] [--target T] [--compartment C] [--tooling] [--cache] [--all] [--yes] [--json] [--dry-run]",
  details:
    "Frees space from managed outputs (diag/verify/formal/timings caches, etc.).\n" +
    "Bare `clean` (no subcommand) removes workspace/build only (compat).\n" +
    "\n" +
    "Subcommands:\n" +
    "  status | list     inventory sizes and ages (no delete)\n" +
    "  build             workspace/build (all build outputs)\n" +
    "  diag|verify|formal|timings|sta   purpose leaves under build/\n" +
    "  cache|manifests|downloads    .cache tree or leaves\n" +
    "  man|dts|firmware  workspace session / dts / smt2-linux firmware\n" +
    "  tooling           installed tools (requires --yes)\n" +
    "  sim               repo-root work-ver/ Verilator library (requires --yes)\n" +
    "  svt | rust-target   package Cargo dir sv-timing/target (+ .sv-timing-out/cache)\n" +
    "  svt-tools         sv-timing/.tools contained rustup/cargo (requires --yes)\n" +
    "  all               entire workspace root (requires --yes; use --tooling legacy ok)\n" +
    "\n" +
    "Filters:\n" +
    "  --older-than 7d|12h|30m   only remove trees older than the duration\n" +
    "  --execution all|last|failed|ok\n" +
    "      stamp.json-based selection (best with timings packages):\n" +
    "      last=delete older packages, keep newest exit 0; failed=exit≠0; ok=exit 0\n" +
    "  --target <str>            path substring filter (e.g. config package)\n" +
    "  --compartment <str>       path substring (diag tags)\n" +
    "\n" +
    "Legacy flags (no subcommand): --tooling --cache --all still work.\n" +
    "Deletions are allowlist-confined; never deletes core/, sv-timing/crates/, or pd/pdk/.\n" +
    "Plan: architecture/build-platform-workspace-lifecycle.md",
  examples: [
    "bun run src/cli/index.ts clean status",
    "bun run src/cli/index.ts clean",
    "bun run src/cli/index.ts clean diag --older-than 3d",
    "bun run src/cli/index.ts clean timings --older-than 14d --dry-run",
    "bun run src/cli/index.ts clean timings --execution failed --dry-run",
    "bun run src/cli/index.ts clean timings --execution last --dry-run",
    "bun run src/cli/index.ts clean svt",
    "bun run src/cli/index.ts clean rust-target --dry-run",
    "bun run src/cli/index.ts clean svt-tools --yes",
    "bun run src/cli/index.ts clean sim --yes",
    "bun run src/cli/index.ts clean tooling --yes",
    "bun run src/cli/index.ts clean all --yes",
  ],
  needsContext: true,
  async run(args) {
    const ctx = requireContext(args);
    const { logger, paths, dryRun } = ctx;
    const asJson = flagBool(args.flags, "json");
    const yes = flagBool(args.flags, "yes") || flagBool(args.flags, "y");
    const olderRaw = flagString(args.flags, "older-than");
    const targetFilter = flagString(args.flags, "target");
    const compartment = flagString(args.flags, "compartment");
    const execRaw = flagString(args.flags, "execution")?.toLowerCase();
    let execution: CleanExecutionFilter | undefined;
    if (execRaw) {
      if (
        execRaw !== "all" &&
        execRaw !== "last" &&
        execRaw !== "failed" &&
        execRaw !== "ok"
      ) {
        logger.error(
          `invalid --execution '${execRaw}' (use all|last|failed|ok)`,
        );
        return 2;
      }
      execution = execRaw;
    }

    let olderThanMs: number | undefined;
    if (olderRaw) {
      const parsed = parseDurationMs(olderRaw);
      if (parsed == null) {
        logger.error(
          `invalid --older-than '${olderRaw}' (use e.g. 7d, 12h, 30m, 90s)`,
        );
        return 2;
      }
      olderThanMs = parsed;
    }

    const inventory = listCleanTargets(ctx, { repoSimOutDirs: REPO_SIM_DIRS });
    const allowRoots = cleanAllowRoots(paths, ctx.repoRoot, REPO_SIM_DIRS);

    const subRaw = args.positionals[0];
    const sub = subRaw?.toLowerCase();

    // status / list
    if (sub === "status" || sub === "list" || sub === "ls") {
      printStatus(inventory, logger, asJson);
      return 0;
    }

    // Resolve purposes: subcommand and/or legacy flags.
    let purposes: CleanPurpose[];
    if (sub) {
      const fromSub = purposesFromSubcommand(sub);
      if (fromSub === null) {
        logger.error(
          `unknown clean subcommand '${subRaw}'. See: clean --help | clean status`,
        );
        return 2;
      }
      if (fromSub.length === 0) {
        printStatus(inventory, logger, asJson);
        return 0;
      }
      purposes = fromSub;
      // Allow combining: clean all --tooling is just workspace; fine.
      if (flagBool(args.flags, "tooling") && !purposes.includes("tooling")) {
        purposes = [...purposes, "tooling"];
      }
      if (flagBool(args.flags, "cache") && !purposes.includes("cache")) {
        purposes = [...purposes, "cache"];
      }
    } else {
      // Bare clean or legacy flags only.
      purposes = purposesFromLegacyFlags({
        all: flagBool(args.flags, "all"),
        tooling: flagBool(args.flags, "tooling"),
        cache: flagBool(args.flags, "cache"),
      });
    }

    // Multiple purpose positionals: clean diag timings
    const extra = args.positionals.slice(1);
    for (const p of extra) {
      const more = purposesFromSubcommand(p);
      if (more === null || more.length === 0) {
        logger.error(`unknown clean purpose '${p}'`);
        return 2;
      }
      for (const x of more) {
        if (!purposes.includes(x)) purposes.push(x);
      }
    }

    const { selected, skipped } = selectCleanTargets(inventory, purposes, {
      olderThanMs,
      target: targetFilter,
      compartment,
      execution,
    });

    if (asJson && dryRun) {
      logger.raw(
        JSON.stringify(
          {
            purposes,
            selected: selected.map((t) => ({
              purpose: t.purpose,
              path: t.path,
              bytes: t.bytes,
            })),
            skipped,
            dryRun: true,
          },
          null,
          2,
        ) + "\n",
      );
      return 0;
    }

    if (selected.length === 0) {
      for (const s of skipped) {
        if (s.status === "skipped-age") {
          logger.info(`skip ${s.label}: ${s.detail}`);
        } else if (s.status === "skipped-filter") {
          logger.info(`skip ${s.label}: ${s.detail}`);
        }
      }
      logger.info("Nothing to clean.");
      logger.info("Hint: clean status  |  clean --help");
      return 0;
    }

    // Preflight --yes for destructive purposes
    const needsYes = selected.some((t) => t.requiresYes);
    if (needsYes && !yes && !dryRun) {
      logger.error(
        `Refusing destructive clean (${selected
          .filter((t) => t.requiresYes)
          .map((t) => t.purpose)
          .join(", ")}): pass --yes (or --dry-run to preview).`,
      );
      return 2;
    }

    const results = await removeCleanTargets(selected, {
      dryRun: dryRun || ctx.dryRun,
      yes,
      allowRoots,
    });

    let removed = 0;
    let refused = 0;
    for (const r of results) {
      if (r.status === "removed") {
        logger.success(`Removed ${r.label}: ${r.path} (${formatBytes(r.bytes)})`);
        removed++;
      } else if (r.status === "would-remove") {
        logger.info(
          `[dry-run] would remove ${r.label}: ${r.path} (${formatBytes(r.bytes)})`,
        );
      } else if (r.status === "refused") {
        logger.error(`Refused ${r.label}: ${r.detail ?? "?"} (${r.path})`);
        refused++;
      } else if (r.status === "skipped-missing") {
        logger.trace(`${r.label}: nothing to remove`);
      }
    }
    for (const s of skipped) {
      if (s.status === "skipped-age" || s.status === "skipped-filter") {
        logger.info(`skip ${s.label}: ${s.detail}`);
      }
    }

    if (!dryRun && !ctx.dryRun && removed === 0 && refused === 0) {
      logger.info("Nothing to clean.");
    }
    return refused > 0 ? 1 : 0;
  },
};
