// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// mb.ts — Motherboard (corev-mb) command: the "SoC + MB die and board configure" step.
//
// Subcommands:
//   list                    Boards discovered under corev-mb (selectable + documented-only).
//   select <id>             Configure step: adapt soc.* to the board, fetch+enable its vendor
//                           controllers, and generate the board package + board.mk.
//   check [id]              Report CPU⇄board compatibility + required-controller checkout state.
//   create <id>             Scaffold a new custom board (board.json [+ design.py]).
//   design <id>             Run the SKiDL schematic (custom boards only): ERC + netlist/BOM.
//   expand <id> --add ...   Add interfaces (e.g. usb_host:2,pcie_x1:1) and (optionally) query PHYs.
//   parts --query "..."     One-off pcbparts.dev search (network-gated by --online).
//   test [id]               Report/verify the tandem core+board feature set; --run drives the build.
//
// One board is active at a time. `select` writes the gitignored overlay
// (build-platform/.config.local.ts) so `build`/`test`/`vendor` all see the same
// board. Nothing hits the network or a flist implicitly.

import { existsSync } from "node:fs";
import { writeFile } from "node:fs/promises";
import { isAbsolute, join } from "node:path";

import { flagBool, flagString } from "../args.ts";
import { requireContext, type Command } from "../command.ts";
import { childEnv, type PlatformContext } from "../../context.ts";
import { hasBinary, run } from "../../platform/exec.ts";
import { createPcbPartsClient, type PcbPartsTool } from "../../tooling/pcbparts.ts";
import { checkoutStatuses, syncControllers } from "../../tooling/vendor.ts";
import { aiCoreHints, resolveAiBoard } from "../../tooling/ai-board.ts";
import {
  BoardSpecError,
  boardPaths,
  checkCompatibility,
  featureMatrix,
  listBoards,
  loadBoardSpec,
  requiredControllerIds,
  scaffoldBoard,
  writeGeneratedArtifacts,
  writeOverlay,
  type BoardClass,
  type BoardInterface,
} from "../../tooling/motherboard.ts";

export const mbCommand: Command = {
  name: "mb",
  summary: "Select / create / design a motherboard (corev-mb) and adapt core + corev_apu to it.",
  usage:
    "bun run src/cli/index.ts mb [list|select|check|create|design|expand|parts|test] [id] [--board <id>] [--online] [--fix] [--add <spec>] [--query <q>] [--dry-run] [--json]",
  details:
    "A board is described by corev-mb/boards/<id>/board.json and a development\n" +
    "architectural target under corev-mb/architecture/<id>/. `mb select <id>` is a\n" +
    "single configure step: it adapts soc.coreConfig/xlen/extensions to the board,\n" +
    "fetches + enables the vendor controllers the board needs, and generates a\n" +
    "(non-compiled) board package. Third-party / reference boards set\n" +
    "\"skidl\":\"omitted\" and skip schematics; custom boards run SKiDL via `mb design`.\n" +
    "pcbparts.dev tools are only reached with --online (never implicitly).",
  examples: [
    "bun run src/cli/index.ts mb list",
    "bun run src/cli/index.ts mb select genesys2",
    "bun run src/cli/index.ts mb check genesys2",
    "bun run src/cli/index.ts mb create my-board --core cv64a6_imafdc_sv39 --class custom",
    "bun run src/cli/index.ts mb create ai-card --ai --class custom",
    "bun run src/cli/index.ts mb expand my-board --add usb_host:2,pcie_x1:1 --online",
    "bun run src/cli/index.ts mb parts --query 'gigabit ethernet rgmii phy' --online",
    "bun run src/cli/index.ts mb test genesys2",
  ],
  needsContext: true,
  async run(args) {
    const ctx = requireContext(args);
    const { logger } = ctx;
    const sub = args.positionals[0] ?? "list";
    const rest = args.positionals.slice(1);
    const json = flagBool(args.flags, "json");

    try {
      switch (sub) {
        case "list":
          return await cmdList(ctx, json);
        case "select":
          return await cmdSelect(ctx, resolveId(ctx, rest, args.flags), args.flags);
        case "check":
          return await cmdCheck(ctx, resolveId(ctx, rest, args.flags, true), json);
        case "create":
          return await cmdCreate(ctx, rest[0], args.flags);
        case "design":
          return await cmdDesign(ctx, resolveId(ctx, rest, args.flags), args.flags);
        case "expand":
          return await cmdExpand(ctx, resolveId(ctx, rest, args.flags), args.flags);
        case "parts":
          return await cmdParts(ctx, args.flags, rest);
        case "test":
          return await cmdTest(ctx, resolveId(ctx, rest, args.flags, true), args.flags);
        default:
          logger.error(`Unknown mb subcommand '${sub}'.`);
          logger.info("Use one of: list, select, check, create, design, expand, parts, test.");
          return 1;
      }
    } catch (err) {
      if (err instanceof BoardSpecError) {
        logger.error(err.message);
        for (const issue of err.issues) logger.error(`  - ${issue}`);
        return 1;
      }
      if (err instanceof MbUsageError) {
        logger.error(err.message);
        return 1;
      }
      throw err;
    }
  },
};

class MbUsageError extends Error {}

/** Resolve a board id from positional/--board/activeBoard. */
function resolveId(
  ctx: PlatformContext,
  rest: string[],
  flags: Record<string, string | boolean>,
  allowActive = false,
): string {
  const id = rest[0] ?? flagString(flags, "board");
  if (id) return id;
  if (allowActive && ctx.config.motherboard.activeBoard) return ctx.config.motherboard.activeBoard;
  throw new MbUsageError(
    "Missing board id. Pass it positionally (e.g. `mb select genesys2`)" +
      (allowActive ? " or select a board first." : "."),
  );
}

/** Absolute pcbparts cache dir (workspace-relative unless absolute). */
function pcbCacheDir(ctx: PlatformContext): string {
  const spec = ctx.config.motherboard.pcbParts.cacheDir;
  return isAbsolute(spec) ? spec : join(ctx.paths.root, spec);
}

// ---------------------------------------------------------------------------
// list
// ---------------------------------------------------------------------------

async function cmdList(ctx: PlatformContext, json: boolean): Promise<number> {
  const { logger } = ctx;
  const boards = await listBoards(ctx);
  if (json) {
    logger.raw(JSON.stringify(boards, null, 2) + "\n");
    return 0;
  }
  const active = ctx.config.motherboard.activeBoard;
  let out = `\nMotherboards (boards: ${ctx.config.motherboard.boardsRoot}, arch: ${ctx.config.motherboard.architectureRoot})\n\n`;
  if (boards.length === 0) {
    out += "  (none yet — scaffold one with `mb create <id>`)\n";
    logger.raw(out);
    return 0;
  }
  for (const b of boards) {
    const mark = b.boardid === active ? "*" : " ";
    const kind = b.selectable ? "selectable" : "documented";
    const status = b.status ?? (b.selectable ? "?" : "analysis");
    const extra = b.selectable ? `${status.padEnd(11)} ${b.skidl ?? "-"} → ${b.coreConfig ?? "-"}` : `${status.padEnd(11)} (architecture target only)`;
    out += ` ${mark} ${b.boardid.padEnd(16)} ${kind.padEnd(11)} ${extra}\n`;
    if (b.name) out += `   ${" ".repeat(16)} ${b.name}\n`;
  }
  out += "\nSelect with: mb select <id>   Study a documented target: corev-mb/architecture/<id>/\n";
  logger.raw(out);
  return 0;
}

// ---------------------------------------------------------------------------
// select — the configure step
// ---------------------------------------------------------------------------

async function cmdSelect(
  ctx: PlatformContext,
  boardid: string,
  flags: Record<string, string | boolean>,
): Promise<number> {
  const { logger } = ctx;
  const spec = await loadBoardSpec(ctx, boardid);
  const adapt = !flagBool(flags, "no-adapt");
  const doVendor = !flagBool(flags, "no-vendor");
  const dryRun = ctx.dryRun || flagBool(flags, "dry-run");

  logger.heading(`Configure board: ${spec.name} (${spec.boardid})`);
  logger.info(`class=${spec.class}  status=${spec.status}  skidl=${spec.skidl}`);
  logger.info(`core → ${spec.core.config} (xlen ${spec.core.xlen})`);

  // 1) Compatibility snapshot against the currently-resolved config.
  const compat = checkCompatibility(ctx.config, spec);
  if (!compat.ok) {
    logger.warn("Active config differs from the board requirement:");
    for (const i of compat.issues) logger.warn(`  ${i.field}: config=${i.actual} board=${i.expected}`);
    logger.info(adapt ? "→ writing overlay to adapt the config to the board." : "→ adapt disabled (--no-adapt); fix .config.ts manually.");
  } else {
    logger.success("Active config already matches the board requirement.");
  }

  // 2) Adapt the build config to the board via the gitignored overlay.
  if (adapt) {
    const { path, wrote } = await writeOverlay(ctx, spec, { dryRun });
    logger.info(`${wrote ? "wrote" : "[dry-run] would write"} ${path}`);
  }

  // 3) Fetch + enable the vendor controllers the board needs.
  const ids = requiredControllerIds(spec);
  if (doVendor && ids.length > 0) {
    logger.heading("Vendor controllers");
    const unknown = ids.filter((id) => !ctx.config.vendor.controllers.some((c) => c.id === id));
    if (unknown.length > 0) {
      logger.warn(`board references unknown vendor ids: ${unknown.join(", ")} (add them to the catalog)`);
    }
    const known = ids.filter((id) => !unknown.includes(id));
    if (known.length > 0) {
      const results = await syncControllers(ctx, { ids: known, dryRun });
      for (const r of results) {
        const tag = r.ok ? (r.skipped ? "skip" : "ok") : "FAIL";
        logger.info(`  ${r.id.padEnd(18)} ${tag}${r.reason ? ` (${r.reason})` : ""}`);
      }
    }
  } else if (ids.length === 0) {
    logger.info("No vendor controllers requested by this board.");
  }

  // 4) Generate the (non-compiled) board package + board.mk (+ AI artifacts when enabled).
  const gen = await writeGeneratedArtifacts(ctx, spec, { dryRun });
  logger.heading("Generated artifacts");
  logger.info(`  ${gen.wrote ? "wrote" : "[dry-run]"} ${gen.packageFile}`);
  logger.info(`  ${gen.wrote ? "wrote" : "[dry-run]"} ${gen.makefileSnippet}`);
  if (gen.aiDtsFile) logger.info(`  ${gen.wrote ? "wrote" : "[dry-run]"} ${gen.aiDtsFile}`);
  if (gen.aiProfileFile) logger.info(`  ${gen.wrote ? "wrote" : "[dry-run]"} ${gen.aiProfileFile}`);
  if (gen.aiEnvFile) logger.info(`  ${gen.wrote ? "wrote" : "[dry-run]"} ${gen.aiEnvFile}`);

  const ai = resolveAiBoard(spec);
  for (const hint of aiCoreHints(spec, ai)) logger.warn(hint);
  if (ai) {
    logger.heading("AI island");
    logger.info(`  board_id=${ai.boardid}  mmio=${"0x" + ai.mmioBase.toString(16)}  plic=${ai.plicSource}`);
    logger.info(`  UIO primary id=${ai.primaryUioId} path=${ai.primaryUioPath}`);
    logger.info(`  source ${gen.aiEnvFile ?? "generated/ai-tensor.env"} for AI_TENSOR_* discovery`);
  }

  logger.heading("Next");
  if (spec.skidl === "custom") logger.info(`  design the PCB:  mb design ${spec.boardid} [--online] [--fix]`);
  else logger.info(`  (schematic omitted for this ${spec.status} board — no SKiDL step)`);
  logger.info(`  verify tandem:   mb test ${spec.boardid}`);
  logger.info(`  build the model: build   (target ${spec.core.config})`);
  return 0;
}

// ---------------------------------------------------------------------------
// check
// ---------------------------------------------------------------------------

async function cmdCheck(ctx: PlatformContext, boardid: string, json: boolean): Promise<number> {
  const { logger } = ctx;
  const spec = await loadBoardSpec(ctx, boardid);
  const compat = checkCompatibility(ctx.config, spec);
  const ids = requiredControllerIds(spec);
  const statuses = await checkoutStatuses(ctx);
  const vendorState = ids.map((id) => {
    const s = statuses.find((x) => x.id === id);
    return { id, known: Boolean(s), present: s?.exists ?? false };
  });

  if (json) {
    logger.raw(JSON.stringify({ boardid, compat, vendor: vendorState }, null, 2) + "\n");
    return compat.ok ? 0 : 3;
  }

  logger.heading(`Check ${spec.boardid} vs active config`);
  if (compat.ok) logger.success("core config compatible");
  else {
    for (const i of compat.issues) logger.warn(`  ${i.field}: config=${i.actual} board=${i.expected}`);
    if (compat.missingExtensions.length > 0) logger.warn(`  missing extensions: ${compat.missingExtensions.join(",")}`);
  }
  logger.heading("Required vendor controllers");
  if (vendorState.length === 0) logger.info("  (none)");
  for (const v of vendorState) {
    const tag = !v.known ? "UNKNOWN id" : v.present ? "present" : "not fetched";
    logger.info(`  ${v.id.padEnd(18)} ${tag}`);
  }
  return compat.ok ? 0 : 3;
}

// ---------------------------------------------------------------------------
// create
// ---------------------------------------------------------------------------

async function cmdCreate(
  ctx: PlatformContext,
  boardid: string | undefined,
  flags: Record<string, string | boolean>,
): Promise<number> {
  const { logger } = ctx;
  if (!boardid) {
    logger.error("`mb create` needs a board id (e.g. `mb create my-board`).");
    return 1;
  }
  const paths = boardPaths(ctx, boardid);
  if (existsSync(paths.specFile)) {
    logger.error(`Board '${boardid}' already exists at ${paths.specFile}.`);
    return 1;
  }
  const dryRun = ctx.dryRun || flagBool(flags, "dry-run");
  const xlenStr = flagString(flags, "xlen");
  const xlen = xlenStr === "32" ? 32 : xlenStr === "64" ? 64 : undefined;
  const ai = flagBool(flags, "ai");
  const result = await scaffoldBoard(ctx, boardid, {
    name: flagString(flags, "name"),
    vendor: flagString(flags, "vendor"),
    class: flagString(flags, "class") as BoardClass | undefined,
    coreConfig: flagString(flags, "core"),
    xlen,
    dryRun,
    ai,
  });
  logger.heading(`Scaffold board ${boardid}${ai ? " (AI island)" : ""}`);
  for (const f of result.created) logger.info(`  ${dryRun ? "[dry-run] would create" : "created"} ${f}`);
  if (dryRun && result.created.length === 0) logger.info(`  [dry-run] would create ${paths.specFile}`);
  logger.heading("Next");
  logger.info(`  1. edit ${paths.specFile} (interfaces, phys, apu.controllers${ai ? ", ai.uioConnectors" : ""})`);
  logger.info(`  2. write the target: corev-mb/architecture/${boardid}/README.md`);
  logger.info(`  3. mb select ${boardid}   then   mb design ${boardid} --online`);
  if (ai) {
    logger.info(`  4. source generated/ai-tensor.env after select for AI_TENSOR_BOARD_ID / UIO`);
  }
  return 0;
}

// ---------------------------------------------------------------------------
// design — SKiDL schematic (custom boards)
// ---------------------------------------------------------------------------

async function cmdDesign(
  ctx: PlatformContext,
  boardid: string,
  flags: Record<string, string | boolean>,
): Promise<number> {
  const { logger } = ctx;
  const spec = await loadBoardSpec(ctx, boardid);
  const paths = boardPaths(ctx, boardid);
  const dryRun = ctx.dryRun || flagBool(flags, "dry-run");

  if (spec.skidl !== "custom") {
    logger.warn(`Board '${boardid}' has skidl="${spec.skidl}" — no in-tree schematic to run.`);
    logger.info(
      spec.skidl === "reference"
        ? "It is a reference board: study it with `mb parts` / pcbparts board_get instead."
        : "It is a third-party board: only the RTL target is configured (no PCB).",
    );
    return 2;
  }
  if (!existsSync(paths.designFile)) {
    logger.error(`Missing ${paths.designFile}. Re-scaffold with \`mb create ${boardid}\` or add design.py.`);
    return 1;
  }
  if (!hasBinary("python") && !hasBinary("python3")) {
    logger.error("python not found on PATH. Run `setup --install` to provision the venv.");
    return 1;
  }

  const python = hasBinary("python3") ? "python3" : "python";
  const libRoot = isAbsolute(ctx.config.motherboard.libRoot)
    ? ctx.config.motherboard.libRoot
    : join(ctx.repoRoot, ctx.config.motherboard.libRoot);
  const env = childEnv(ctx, {
    PYTHONPATH: libRoot,
    CVA6_MB_BOARD: boardid,
    CVA6_MB_OUTPUTS: paths.outputsDir,
    PCBPARTS_MCP_URL: ctx.config.motherboard.pcbParts.mcpUrl,
    PCBPARTS_CACHE_DIR: pcbCacheDir(ctx),
    PCBPARTS_ALLOW_NETWORK: flagBool(flags, "online") ? "1" : "0",
    ERC_FIX: flagBool(flags, "fix") ? "1" : "0",
    ERC_MAX_ITER: String(ctx.config.motherboard.pcbParts.maxFixIterations),
  });

  logger.heading(`Design ${spec.name} (${boardid})`);
  logger.info(`skidl script: ${paths.designFile}`);
  logger.info(`network: ${flagBool(flags, "online") ? "enabled (--online)" : "disabled"}  fix: ${flagBool(flags, "fix") ? "on" : "off"}`);
  const result = await run(python, [paths.designFile], {
    cwd: ctx.repoRoot,
    env,
    logger,
    dryRun,
    allowFailure: true,
  });
  if (result.dryRun) return 0;
  if (result.ok) {
    logger.success(`design finished; outputs under ${paths.outputsDir}`);
    return 0;
  }
  logger.error(`design failed (exit ${result.code}).`);
  return result.code || 1;
}

// ---------------------------------------------------------------------------
// expand — add interfaces (+ optional PHY discovery)
// ---------------------------------------------------------------------------

const DOMAIN_HINTS: Record<string, string> = {
  usb: "usb",
  usb_host: "usb",
  usb_device: "usb",
  pcie: "interconnect",
  pcie_x1: "interconnect",
  pcie_x4: "interconnect",
  eth: "network",
  ethernet: "network",
  rgmii: "network",
  sata: "storage",
  sdcard: "storage",
  emmc: "storage",
  hdmi: "display",
  display: "display",
  ddr: "memory",
  ddr3: "memory",
  ddr4: "memory",
  uart: "peripheral",
  i2c: "peripheral",
  spi: "peripheral",
};

async function cmdExpand(
  ctx: PlatformContext,
  boardid: string,
  flags: Record<string, string | boolean>,
): Promise<number> {
  const { logger } = ctx;
  const spec = await loadBoardSpec(ctx, boardid);
  const paths = boardPaths(ctx, boardid);
  const addSpec = flagString(flags, "add");
  if (!addSpec) {
    logger.error("`mb expand` needs --add <kind[:count],...> (e.g. --add usb_host:2,pcie_x1:1).");
    return 1;
  }
  const dryRun = ctx.dryRun || flagBool(flags, "dry-run");
  const online = flagBool(flags, "online");

  const additions = parseAddSpec(addSpec);
  if (additions.length === 0) {
    logger.error(`Could not parse --add '${addSpec}'.`);
    return 1;
  }

  const client = online
    ? createPcbPartsClient(
        { url: ctx.config.motherboard.pcbParts.mcpUrl, timeoutMs: ctx.config.motherboard.pcbParts.timeoutMs, retries: ctx.config.motherboard.pcbParts.retries, cacheDir: pcbCacheDir(ctx) },
        logger,
        true,
      )
    : null;

  logger.heading(`Expand ${boardid}`);
  for (const add of additions) {
    const domain = DOMAIN_HINTS[add.kind] ?? "peripheral";
    const existing = spec.interfaces.filter((i) => i.kind === add.kind).length;
    for (let n = 0; n < add.count; n++) {
      const iface: BoardInterface = {
        id: `${add.kind}${existing + n}`,
        domain,
        kind: add.kind,
        count: 1,
        notes: "added by mb expand",
      };
      if (client) {
        const q = `${add.kind.replace(/_/g, " ")} phy connector`;
        const res = await client.jlcSearch({ query: q, limit: 3 });
        if (res.ok && res.data) iface.notes = `mb expand; pcbparts jlc_search '${q}' (${res.source})`;
        else if (res.note) logger.info(`  pcbparts: ${res.note}`);
      }
      spec.interfaces.push(iface);
      logger.info(`  + ${iface.domain}/${iface.id} (${iface.kind})`);
    }
  }

  if (dryRun) {
    logger.info(`[dry-run] would update ${paths.specFile} (+${additions.reduce((a, x) => a + x.count, 0)} interfaces)`);
    return 0;
  }
  await writeFile(paths.specFile, JSON.stringify(spec, null, 2) + "\n", "utf8");
  logger.success(`updated ${paths.specFile}`);
  logger.info(`Re-run: mb select ${boardid}   to regenerate the board package.`);
  return 0;
}

interface AddItem {
  kind: string;
  count: number;
}

function parseAddSpec(spec: string): AddItem[] {
  const out: AddItem[] = [];
  for (const part of spec.split(",")) {
    const trimmed = part.trim();
    if (!trimmed) continue;
    const [kindRaw, countRaw] = trimmed.split(":");
    const kind = (kindRaw ?? "").trim().toLowerCase();
    if (!kind) continue;
    const count = countRaw ? Math.max(1, parseInt(countRaw, 10) || 1) : 1;
    out.push({ kind, count });
  }
  return out;
}

// ---------------------------------------------------------------------------
// parts — one-off pcbparts.dev query
// ---------------------------------------------------------------------------

async function cmdParts(
  ctx: PlatformContext,
  flags: Record<string, string | boolean>,
  rest: string[],
): Promise<number> {
  const { logger } = ctx;
  const query = flagString(flags, "query") ?? rest.join(" ");
  const toolFlag = flagString(flags, "tool") as PcbPartsTool | undefined;
  const online = flagBool(flags, "online");
  if (!query && !toolFlag) {
    logger.error("`mb parts` needs --query \"...\" (or --tool <name>).");
    return 1;
  }
  const client = createPcbPartsClient(
    {
      url: ctx.config.motherboard.pcbParts.mcpUrl,
      timeoutMs: ctx.config.motherboard.pcbParts.timeoutMs,
      retries: ctx.config.motherboard.pcbParts.retries,
      cacheDir: pcbCacheDir(ctx),
    },
    logger,
    online,
  );
  const tool: PcbPartsTool = toolFlag ?? "jlc_search";
  const res = await client.callTool(tool, query ? { query } : {});
  logger.heading(`pcbparts ${tool}`);
  logger.info(`source=${res.source}${res.note ? `  note=${res.note}` : ""}`);
  if (res.data !== null) logger.raw(JSON.stringify(res.data, null, 2) + "\n");
  else if (!online) logger.info("Pass --online to query pcbparts.dev (results are then cached).");
  return res.ok ? 0 : 1;
}

// ---------------------------------------------------------------------------
// test — tandem core + board feature set
// ---------------------------------------------------------------------------

async function cmdTest(
  ctx: PlatformContext,
  boardid: string,
  flags: Record<string, string | boolean>,
): Promise<number> {
  const { logger } = ctx;
  const spec = await loadBoardSpec(ctx, boardid);
  const compat = checkCompatibility(ctx.config, spec);
  const rows = featureMatrix(ctx.config, spec);
  const paths = boardPaths(ctx, boardid);
  const generated = existsSync(paths.packageFile);

  logger.heading(`Tandem feature set — ${spec.name} (${boardid})`);
  for (const r of rows) logger.info(`  [${r.layer.padEnd(6)}] ${r.feature.padEnd(22)} ${r.detail}`);

  logger.heading("Readiness");
  logger.info(`  core config compatible : ${compat.ok ? "yes" : "NO (run `mb select`)"}`);
  logger.info(`  board package generated : ${generated ? "yes" : "no (run `mb select`)"}`);
  const ids = requiredControllerIds(spec);
  const statuses = await checkoutStatuses(ctx);
  const missing = ids.filter((id) => !(statuses.find((s) => s.id === id)?.exists ?? false));
  logger.info(`  vendor controllers      : ${ids.length - missing.length}/${ids.length} present${missing.length ? ` (missing: ${missing.join(",")})` : ""}`);

  if (!flagBool(flags, "run")) {
    logger.heading("Run");
    logger.info(`  drive the RTL tests with: test --target ${spec.core.config}`);
    logger.info("  (add --run to invoke the build here)");
    return compat.ok ? 0 : 3;
  }

  if (!compat.ok) {
    logger.error("Refusing to --run: config incompatible. Run `mb select` first.");
    return 3;
  }
  if (!hasBinary("make")) {
    logger.error("`make` not found. Run `setup --install`.");
    return 1;
  }
  const dryRun = ctx.dryRun || flagBool(flags, "dry-run");
  const env = childEnv(ctx, { CVA6_MB_BOARD: boardid });
  const result = await run("make", ["verilate", `target=${spec.core.config}`], {
    cwd: ctx.repoRoot,
    env,
    logger,
    dryRun,
    allowFailure: true,
  });
  if (result.dryRun) return 0;
  return result.ok ? 0 : result.code || 1;
}
