// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// vendor.ts — Manage uncore controller + PHY IP (the corev_apu "surrounding die").
//
// Subcommands:
//   list            Catalog grouped by domain (default).
//   status          Checkout / registration / scan-needed summary.
//   sync [ids...]   Fetch enabled controllers (or the named ids / --all).
//   add <ids...>    Fetch the named controllers (alias of sync with explicit ids).
//   update <id>     Bump the checked-out ref (--ref <tag|sha|branch>) or re-snapshot.
//   scan <ids...>   Enumerate the RTL a controller exposes (before wiring it in).
//
// Nothing is fetched implicitly. See AGENTS-vendor.md for behaviour + licensing,
// and AGENTS-core-platform-vendor-actives.md for the substructure this drives.

import { flagBool, flagString } from "../args.ts";
import { requireContext, type Command } from "../command.ts";
import type { VendorDomain } from "../../config/schema.ts";
import {
  checkoutStatuses,
  findController,
  needsScan,
  scanController,
  syncControllers,
  updateController,
} from "../../tooling/vendor.ts";

/** Stable display order for domain groupings. */
const DOMAIN_ORDER: VendorDomain[] = [
  "memory",
  "network",
  "interconnect",
  "storage",
  "display",
  "usb",
  "phy",
  "peripheral",
  "util",
];

export const vendorCommand: Command = {
  name: "vendor",
  summary: "List / fetch / update / scan uncore controller + PHY IP.",
  usage: "bun run src/cli/index.ts vendor [list|status|sync|add|update|scan] [ids...] [--all] [--ref <r>] [--json] [--dry-run]",
  details:
    "The vendor catalog (config.vendor.controllers) is the typed migration of\n" +
    "vendor/*.vendor.hjson + peripheral submodules into one control surface.\n" +
    "Every entry is planned + disabled by default, so nothing is fetched until\n" +
    "you name it (or pass --all). Controllers are tracked as git submodules under\n" +
    "vendor/ (easy pinned update + rescan); the 'vendor' mechanism snapshots\n" +
    "source in-tree. Scanning enumerates a block's RTL before you wire it into a\n" +
    "corev_apu flist. Actual git network operations are gated behind these\n" +
    "subcommands — run them yourself; use --dry-run to preview.",
  examples: [
    "bun run src/cli/index.ts vendor list",
    "bun run src/cli/index.ts vendor status",
    "bun run src/cli/index.ts vendor sync litedram verilog-ethernet --dry-run",
    "bun run src/cli/index.ts vendor add hdmi",
    "bun run src/cli/index.ts vendor update litedram --ref 1.0.0",
    "bun run src/cli/index.ts vendor scan litedram --json",
  ],
  needsContext: true,
  async run(args) {
    const ctx = requireContext(args);
    const { logger, config } = ctx;
    const sub = args.positionals[0] ?? "list";
    const ids = args.positionals.slice(1);
    const json = flagBool(args.flags, "json");

    switch (sub) {
      case "list":
        return listCatalog(ctx, json);
      case "status":
        return await showStatus(ctx, json);
      case "sync":
        return summarizeSync(
          logger,
          await syncControllers(ctx, { ids, all: flagBool(args.flags, "all"), dryRun: ctx.dryRun }),
        );
      case "add":
        if (ids.length === 0) {
          logger.error("`vendor add` needs at least one controller id (see `vendor list`).");
          return 1;
        }
        return summarizeSync(logger, await syncControllers(ctx, { ids, dryRun: ctx.dryRun }));
      case "update": {
        const id = ids[0];
        if (!id) {
          logger.error("`vendor update` needs a controller id.");
          return 1;
        }
        const res = await updateController(ctx, id, flagString(args.flags, "ref"), ctx.dryRun);
        return summarizeSync(logger, [res]);
      }
      case "scan":
        return await runScan(ctx, ids, flagBool(args.flags, "all"), json);
      default:
        logger.error(`Unknown vendor subcommand '${sub}'.`);
        logger.info("Use one of: list, status, sync, add, update, scan.");
        return 1;
    }

    function listCatalog(_ctx: typeof ctx, asJson: boolean): number {
      if (asJson) {
        logger.raw(JSON.stringify(config.vendor, null, 2) + "\n");
        return 0;
      }
      // Build one buffer and emit a single write so domain headers and rows
      // never interleave (robust across consoles / unicode-bullet handling).
      let out = `\nUncore controller + PHY catalog (root: ${config.vendor.root})\n`;
      for (const domain of DOMAIN_ORDER) {
        const group = config.vendor.controllers.filter((c) => c.domain === domain);
        if (group.length === 0) continue;
        out += `\n[${domain}]\n`;
        for (const c of group) {
          const flag = c.enabled ? "on " : "off";
          out += `  ${c.id.padEnd(18)} ${flag} ${c.status.padEnd(11)} ${c.kind.padEnd(15)} ${c.license.padEnd(14)} ${c.path}\n`;
          out += `  ${" ".repeat(18)} ${c.description}\n`;
        }
      }
      out += "\nFetch with: vendor sync <id>   Inspect RTL with: vendor scan <id>\n";
      logger.raw(out);
      return 0;
    }
  },
};

/** Print checkout + scan-needed state. */
async function showStatus(ctx: Parameters<Command["run"]>[0]["ctx"], asJson: boolean): Promise<number> {
  const context = ctx!;
  const { logger } = context;
  const statuses = await checkoutStatuses(context);
  if (asJson) {
    logger.raw(JSON.stringify(statuses, null, 2) + "\n");
    return 0;
  }
  logger.heading("Vendor checkout status");
  for (const s of statuses) {
    const spec = findController(context, s.id)!;
    const mark = s.exists ? "present" : "absent ";
    const reg = s.registered ? "submodule" : "unregistered";
    logger.info(`${s.id.padEnd(18)} ${mark} ${s.status.padEnd(10)} ${reg.padEnd(13)} ${s.path}`);
    if (!s.exists && needsScan(spec, "on-fetch")) {
      logger.info(`${" ".repeat(18)} → fetch: vendor sync ${s.id}`);
    }
  }
  return 0;
}

/** Scan one or more controllers and print (or JSON) the RTL they expose. */
async function runScan(
  ctx: Parameters<Command["run"]>[0]["ctx"],
  ids: string[],
  all: boolean,
  asJson: boolean,
): Promise<number> {
  const context = ctx!;
  const { logger, config } = context;
  const targets = all
    ? config.vendor.controllers
    : ids.map((id) => findController(context, id)).filter((c): c is NonNullable<typeof c> => Boolean(c));

  if (targets.length === 0) {
    logger.error("`vendor scan` needs a controller id (or --all). See `vendor list`.");
    return 1;
  }

  const results = [];
  for (const spec of targets) {
    results.push(await scanController(context, spec));
  }

  if (asJson) {
    logger.raw(JSON.stringify(results, null, 2) + "\n");
    return 0;
  }

  let missing = 0;
  for (const r of results) {
    logger.heading(`scan ${r.id}`);
    if (!r.exists) {
      missing++;
      logger.warn(`not checked out (${r.path}); fetch with: vendor sync ${r.id}`);
      continue;
    }
    const exts = Object.entries(r.byExtension)
      .map(([k, v]) => `${k}:${v}`)
      .join("  ");
    logger.info(`roots  : ${r.scannedRoots.length}`);
    logger.info(`rtl    : ${r.files.length} file(s)${r.truncated ? " (truncated)" : ""}  ${exts}`);
    for (const f of r.files.slice(0, 40)) logger.info(`  ${f}`);
    if (r.files.length > 40) logger.info(`  ... ${r.files.length - 40} more`);
  }
  return missing > 0 && missing === results.length ? 1 : 0;
}

/** Reduce sync results to a summary + exit code. */
function summarizeSync(
  logger: Parameters<Command["run"]>[0]["logger"],
  results: { id: string; ok: boolean; skipped: boolean; reason?: string }[],
): number {
  const failed = results.filter((r) => !r.ok);
  logger.heading("Vendor summary");
  logger.info(`processed: ${results.length}, failed: ${failed.length}`);
  if (failed.length > 0) {
    logger.error(`failed: ${failed.map((f) => `${f.id}${f.reason ? ` (${f.reason})` : ""}`).join(", ")}`);
    return 1;
  }
  return 0;
}
