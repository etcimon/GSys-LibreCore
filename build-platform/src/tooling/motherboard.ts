// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// motherboard.ts — The engine behind the `mb` command (the corev-mb board layer).
//
// A "board" is described by one machine-readable spec: <boardsRoot>/<id>/board.json.
// That single file is what makes `mb select <id>` behave like a unified
// "SoC + MB die and board configure" step:
//   - it names the core target config (soc.coreConfig) the board requires, so
//     selecting a board adapts the CPU/uncore elaboration;
//   - it lists which vendor controllers (corev_apu uncore IP) to fetch/enable;
//   - it declares the board interfaces + PHYs to reproduce.
//
// From it we (a) check CPU/board compatibility, (b) resolve the vendor
// controllers to sync, and (c) generate a NON-COMPILED board package
// (corev-mb/boards/<id>/generated/<id>_board_pkg.sv) plus a board.mk snippet.
// Nothing here is added to a flist automatically — generation lands under a
// gitignored generated/ dir, honouring the AGENTS.md §0 rule against churning
// the working RTL hierarchy. Promotion into a real board top-level is manual.

import { existsSync } from "node:fs";
import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { isAbsolute, join } from "node:path";

import type { MotherboardSkidlMode, ResolvedBuildConfig } from "../config/schema.ts";
import type { PlatformContext } from "../context.ts";
import {
  generateAiBoardPackageDisabled,
  generateAiBoardPackageParams,
  generateAiDtsFragment,
  generateAiTensorEnv,
  generateAiTensorProfile,
  resolveAiBoard,
  starterAiSpec,
  validateBoardAi,
  type BoardAiSpec,
} from "./ai-board.ts";

// ---------------------------------------------------------------------------
// Board spec (board.json) shape
// ---------------------------------------------------------------------------

export type BoardStatus = "reference" | "analysis" | "third-party" | "custom";
export type BoardClass = "fpga" | "asic-soc" | "custom";

export interface BoardCoreReq {
  /** CVA6 target config package name (e.g. "cv64a6_imafdc_sv39"). */
  config: string;
  xlen: 32 | 64;
  /** Lower-case extension tokens (["i","m","a","f","d","c",...]). */
  extensions: string[];
  isaString?: string;
}

export interface BoardControllerRef {
  /** Vendor catalog id (config.vendor.controllers[].id). */
  id: string;
  variant?: string;
  /** Whether `mb select` should fetch + enable it. */
  enable: boolean;
  note?: string;
}

export interface BoardApu {
  axiDataWidth?: number;
  noc?: string;
  socket?: { enabled: boolean; type?: string; note?: string };
  controllers: BoardControllerRef[];
}

export interface BoardInterface {
  id: string;
  /** memory / network / interconnect / storage / display / usb / peripheral. */
  domain: string;
  kind: string;
  controller?: string;
  phy?: string;
  count?: number;
  notes?: string;
}

export interface BoardPhy {
  /** Reference designator or logical name (e.g. "eth_phy"). */
  ref: string;
  interface: string;
  mpn?: string;
  vendor?: string;
  package?: string;
  datasheet?: string;
  /** SPDX id or "vendor" for licensed/NDA docs. */
  license?: string;
  status?: "planned" | "documented" | "selected";
  /** How to (re-)discover it via pcbparts.dev. */
  mcp?: { tool?: string; query?: string; lcsc?: string };
}

export interface BoardReferences {
  /** Spec anchors (e.g. "#vol:priv"). */
  spec?: string[];
  /** Licensed vendor documentation references (titles / URLs / part numbers). */
  vendorDocs?: string[];
  /** pcbparts.dev OSHW board id/slug this board draws from. */
  oshwBoard?: string;
}

export interface BoardSpec {
  boardid: string;
  name: string;
  vendor: string;
  status: BoardStatus;
  class: BoardClass;
  skidl: MotherboardSkidlMode;
  summary?: string;
  core: BoardCoreReq;
  apu: BoardApu;
  interfaces: BoardInterface[];
  phys: BoardPhy[];
  references?: BoardReferences;
  /**
   * Optional AI island / UIO host path. When present and not disabled, `mb select`
   * emits AI DTS/profile/env artifacts and MbAi_* board-package localparams.
   * See build-platform/src/tooling/ai-board.ts and architecture/ai-matrix/board-uio-eventfd.md.
   */
  ai?: BoardAiSpec;
}

// ---------------------------------------------------------------------------
// Path resolution + discovery
// ---------------------------------------------------------------------------

export interface BoardPaths {
  boardDir: string;
  specFile: string;
  designFile: string;
  generatedDir: string;
  outputsDir: string;
  architectureDir: string;
  packageFile: string;
  makefileSnippet: string;
}

function underRepo(repoRoot: string, spec: string): string {
  return isAbsolute(spec) ? spec : join(repoRoot, spec);
}

/** Resolve all repo-relative paths for a board id. */
export function boardPaths(ctx: PlatformContext, boardid: string): BoardPaths {
  const { repoRoot, config } = ctx;
  const boardsRoot = underRepo(repoRoot, config.motherboard.boardsRoot);
  const archRoot = underRepo(repoRoot, config.motherboard.architectureRoot);
  const boardDir = join(boardsRoot, boardid);
  const generatedDir = join(boardDir, "generated");
  return {
    boardDir,
    specFile: join(boardDir, "board.json"),
    designFile: join(boardDir, "design.py"),
    generatedDir,
    outputsDir: join(boardDir, "outputs"),
    architectureDir: join(archRoot, boardid),
    packageFile: join(generatedDir, `${toIdent(boardid)}_board_pkg.sv`),
    makefileSnippet: join(generatedDir, "board.mk"),
  };
}

export interface BoardListing {
  boardid: string;
  /** True when a board.json exists (selectable / buildable). */
  selectable: boolean;
  /** True when a corev-mb/architecture/<id>/ target doc dir exists. */
  documented: boolean;
  status?: BoardStatus;
  name?: string;
  skidl?: MotherboardSkidlMode;
  coreConfig?: string;
}

/**
 * Enumerate boards from both roots. A board with a board.json is selectable; an
 * architecture-only dir is a documented target that is described but not yet
 * included (e.g. bpi-f3, milkv-jupiter, milkv-titan at this stage).
 */
export async function listBoards(ctx: PlatformContext): Promise<BoardListing[]> {
  const { repoRoot, config } = ctx;
  const boardsRoot = underRepo(repoRoot, config.motherboard.boardsRoot);
  const archRoot = underRepo(repoRoot, config.motherboard.architectureRoot);

  const ids = new Set<string>();
  for (const [root, kind] of [
    [boardsRoot, "board"],
    [archRoot, "arch"],
  ] as const) {
    if (!existsSync(root)) continue;
    for (const entry of await readdir(root, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      if (entry.name.startsWith("_") || entry.name.startsWith(".")) continue;
      if (kind === "arch" && entry.name.toLowerCase() === "readme.md") continue;
      ids.add(entry.name);
    }
  }

  const out: BoardListing[] = [];
  for (const boardid of [...ids].sort()) {
    const paths = boardPaths(ctx, boardid);
    const selectable = existsSync(paths.specFile);
    const documented = existsSync(paths.architectureDir);
    const listing: BoardListing = { boardid, selectable, documented };
    if (selectable) {
      try {
        const spec = await loadBoardSpec(ctx, boardid);
        listing.status = spec.status;
        listing.name = spec.name;
        listing.skidl = spec.skidl;
        listing.coreConfig = spec.core.config;
      } catch {
        /* leave partial listing; validation surfaces on select */
      }
    }
    out.push(listing);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Loading + validation
// ---------------------------------------------------------------------------

export class BoardSpecError extends Error {
  constructor(message: string, readonly issues: string[] = []) {
    super(message);
    this.name = "BoardSpecError";
  }
}

/** Read + validate <boardsRoot>/<id>/board.json. */
export async function loadBoardSpec(ctx: PlatformContext, boardid: string): Promise<BoardSpec> {
  const paths = boardPaths(ctx, boardid);
  if (!existsSync(paths.specFile)) {
    throw new BoardSpecError(`No board.json for '${boardid}' at ${paths.specFile}.`);
  }
  let raw: unknown;
  try {
    raw = JSON.parse(await readFile(paths.specFile, "utf8"));
  } catch (err) {
    throw new BoardSpecError(`board.json for '${boardid}' is not valid JSON: ${String(err)}`);
  }
  const issues = validateBoardSpec(raw, boardid);
  if (issues.length > 0) {
    throw new BoardSpecError(`Invalid board.json for '${boardid}' (${issues.length} issue(s)).`, issues);
  }
  return raw as BoardSpec;
}

const STATUSES: readonly BoardStatus[] = ["reference", "analysis", "third-party", "custom"];
const CLASSES: readonly BoardClass[] = ["fpga", "asic-soc", "custom"];
const SKIDL_MODES: readonly MotherboardSkidlMode[] = ["omitted", "reference", "custom"];

function validateBoardSpec(raw: unknown, boardid: string): string[] {
  const issues: string[] = [];
  if (raw === null || typeof raw !== "object") return ["board.json must be a JSON object."];
  const s = raw as Record<string, unknown>;

  if (s.boardid !== boardid) {
    issues.push(`boardid '${String(s.boardid)}' must match directory name '${boardid}'.`);
  }
  if (typeof s.name !== "string" || s.name.length === 0) issues.push("name is required.");
  if (typeof s.vendor !== "string" || s.vendor.length === 0) issues.push("vendor is required.");
  if (!STATUSES.includes(s.status as BoardStatus)) issues.push(`status must be one of ${STATUSES.join(", ")}.`);
  if (!CLASSES.includes(s.class as BoardClass)) issues.push(`class must be one of ${CLASSES.join(", ")}.`);
  if (!SKIDL_MODES.includes(s.skidl as MotherboardSkidlMode)) {
    issues.push(`skidl must be one of ${SKIDL_MODES.join(", ")}.`);
  }

  const core = s.core as Record<string, unknown> | undefined;
  if (!core || typeof core !== "object") {
    issues.push("core is required.");
  } else {
    if (typeof core.config !== "string" || core.config.length === 0) issues.push("core.config is required.");
    if (core.xlen !== 32 && core.xlen !== 64) issues.push("core.xlen must be 32 or 64.");
    if (!Array.isArray(core.extensions)) issues.push("core.extensions must be an array.");
    if (typeof core.config === "string") {
      const lower = core.config.toLowerCase();
      if (lower.startsWith("cv32") && core.xlen !== 32) issues.push("core.xlen must be 32 for a cv32 config.");
      if (lower.startsWith("cv64") && core.xlen !== 64) issues.push("core.xlen must be 64 for a cv64 config.");
    }
  }

  const apu = s.apu as Record<string, unknown> | undefined;
  if (!apu || typeof apu !== "object") {
    issues.push("apu is required.");
  } else if (!Array.isArray(apu.controllers)) {
    issues.push("apu.controllers must be an array.");
  } else {
    const seen = new Set<string>();
    for (const c of apu.controllers as Record<string, unknown>[]) {
      if (typeof c.id !== "string") {
        issues.push("apu.controllers[].id must be a string.");
        continue;
      }
      if (seen.has(c.id)) issues.push(`apu.controllers has duplicate id '${c.id}'.`);
      seen.add(c.id);
      if (typeof c.enable !== "boolean") issues.push(`apu.controllers['${c.id}'].enable must be a boolean.`);
    }
  }

  if (s.interfaces !== undefined && !Array.isArray(s.interfaces)) issues.push("interfaces must be an array.");
  if (s.phys !== undefined && !Array.isArray(s.phys)) issues.push("phys must be an array.");

  // Optional AI island / UIO connectors (custom AI boards).
  issues.push(...validateBoardAi(s.ai, boardid));

  return issues;
}

// ---------------------------------------------------------------------------
// Compatibility (CPU ⇄ board handshake)
// ---------------------------------------------------------------------------

export interface CompatIssue {
  field: string;
  expected: string;
  actual: string;
}

export interface CompatReport {
  ok: boolean;
  boardid: string;
  issues: CompatIssue[];
  /** Extensions the board wants that the active config lacks. */
  missingExtensions: string[];
}

/** Compare the active build config against the board's core requirement. */
export function checkCompatibility(config: ResolvedBuildConfig, spec: BoardSpec): CompatReport {
  const issues: CompatIssue[] = [];
  if (config.soc.coreConfig !== spec.core.config) {
    issues.push({ field: "soc.coreConfig", expected: spec.core.config, actual: config.soc.coreConfig });
  }
  if (config.soc.xlen !== spec.core.xlen) {
    issues.push({ field: "soc.xlen", expected: String(spec.core.xlen), actual: String(config.soc.xlen) });
  }
  const have = new Set(config.soc.extensions.map((e) => e.toLowerCase()));
  const missingExtensions = spec.core.extensions
    .map((e) => e.toLowerCase())
    .filter((e) => !have.has(e));
  if (missingExtensions.length > 0) {
    issues.push({
      field: "soc.extensions",
      expected: spec.core.extensions.join(","),
      actual: config.soc.extensions.join(","),
    });
  }
  return { ok: issues.length === 0, boardid: spec.boardid, issues, missingExtensions };
}

/** Controller ids the board wants fetched + enabled (for `vendor sync`). */
export function requiredControllerIds(spec: BoardSpec): string[] {
  return spec.apu.controllers.filter((c) => c.enable).map((c) => c.id);
}

/** Rows describing the tandem core + board feature set (used by `mb test`). */
export interface FeatureRow {
  layer: "core" | "uncore" | "board";
  feature: string;
  detail: string;
}

export function featureMatrix(config: ResolvedBuildConfig, spec: BoardSpec): FeatureRow[] {
  const rows: FeatureRow[] = [];
  rows.push({ layer: "core", feature: "target config", detail: spec.core.config });
  rows.push({ layer: "core", feature: "xlen", detail: String(spec.core.xlen) });
  rows.push({ layer: "core", feature: "isa", detail: spec.core.isaString ?? spec.core.extensions.join("") });
  for (const c of spec.apu.controllers) {
    rows.push({
      layer: "uncore",
      feature: c.id,
      detail: `${c.enable ? "enabled" : "off"}${c.variant ? ` (${c.variant})` : ""}`,
    });
  }
  if (spec.apu.socket?.enabled) {
    rows.push({ layer: "board", feature: "socket", detail: spec.apu.socket.type ?? "enabled" });
  }
  for (const i of spec.interfaces) {
    rows.push({
      layer: "board",
      feature: `${i.domain}/${i.id}`,
      detail: `${i.kind}${i.count && i.count > 1 ? ` x${i.count}` : ""}${i.phy ? ` [${i.phy}]` : ""}`,
    });
  }
  void config;
  return rows;
}

// ---------------------------------------------------------------------------
// Generation (board package + board.mk) — non-compiled scaffold artifacts
// ---------------------------------------------------------------------------

/** SystemVerilog identifier-safe token (lower). */
function toIdent(s: string): string {
  const t = s.toLowerCase().replace(/[^a-z0-9_]/g, "_");
  return /^[a-z_]/.test(t) ? t : `b_${t}`;
}

/** `define`-safe UPPER token. */
function toUpper(s: string): string {
  return toIdent(s).toUpperCase();
}

/** Generate the board package SystemVerilog (localparams only, no logic). */
export function generateBoardPackage(spec: BoardSpec): string {
  const pkg = `${toIdent(spec.boardid)}_board_pkg`;
  const lines: string[] = [];
  lines.push("// Copyright (c) 2026 Etienne Cimon");
  lines.push("// SPDX-License-Identifier: MIT");
  lines.push("//");
  lines.push(`// ${pkg}.sv — GENERATED by build-platform \`mb select ${spec.boardid}\`. Do not edit by hand.`);
  lines.push("//");
  lines.push("// SCAFFOLD: this package is NOT referenced by any flist. It records the");
  lines.push("// board's parameterization so a board top-level (corev_apu/fpga/src) can import");
  lines.push("// it when the board is promoted from documented target to integrated wrapper.");
  lines.push("// Promotion is manual and gated (see AGENTS-motherboard.md).");
  lines.push("");
  lines.push(`package ${pkg};`);
  lines.push("");
  lines.push(`  localparam string BoardId       = "${spec.boardid}";`);
  lines.push(`  localparam string BoardName     = "${spec.name.replace(/"/g, "'")}";`);
  lines.push(`  localparam string BoardVendor   = "${spec.vendor.replace(/"/g, "'")}";`);
  lines.push(`  localparam string BoardClass    = "${spec.class}";`);
  lines.push(`  localparam string SkidlMode     = "${spec.skidl}";`);
  lines.push("");
  lines.push(`  localparam string CoreConfig    = "${spec.core.config}";`);
  lines.push(`  localparam int unsigned Xlen    = ${spec.core.xlen};`);
  lines.push(`  localparam int unsigned AxiDataWidth = ${spec.apu.axiDataWidth ?? spec.core.xlen};`);
  lines.push(`  localparam bit    SocketEn      = 1'b${spec.apu.socket?.enabled ? 1 : 0};`);
  lines.push("");
  lines.push("  // --- Uncore controller enables (from apu.controllers) ---------------");
  for (const c of spec.apu.controllers) {
    lines.push(`  localparam bit MbCtrl_${toIdent(c.id)}_En = 1'b${c.enable ? 1 : 0};`);
  }
  lines.push("");
  lines.push("  // --- Board interface presence + counts (from interfaces) ------------");
  for (const i of spec.interfaces) {
    const tok = toUpper(i.id);
    lines.push(`  localparam bit MbIf_${tok}_En = 1'b1;`);
    lines.push(`  localparam int unsigned MbIf_${tok}_Count = ${i.count ?? 1};`);
    if (i.phy) lines.push(`  localparam string MbIf_${tok}_Phy = "${i.phy.replace(/"/g, "'")}";`);
  }
  lines.push("");
  const ai = resolveAiBoard(spec);
  if (ai) {
    lines.push(generateAiBoardPackageParams(ai));
  } else {
    lines.push(generateAiBoardPackageDisabled());
  }
  lines.push("");
  lines.push(`endpackage : ${pkg}`);
  lines.push("");
  return lines.join("\n");
}

/** Generate a Makefile snippet the root Makefile can optionally include. */
export function generateBoardMakefile(spec: BoardSpec): string {
  const enabled = requiredControllerIds(spec).join(" ");
  return [
    "# GENERATED by build-platform `mb select " + spec.boardid + "`. Do not edit by hand.",
    "# Include from the root Makefile only when CVA6_MB_BOARD is set.",
    `CVA6_MB_BOARD      := ${spec.boardid}`,
    `CVA6_MB_CORE_CFG   := ${spec.core.config}`,
    `CVA6_MB_XLEN       := ${spec.core.xlen}`,
    `CVA6_MB_SKIDL      := ${spec.skidl}`,
    `CVA6_MB_VENDOR_IDS := ${enabled}`,
    "",
  ].join("\n");
}

export interface GenerateResult {
  packageFile: string;
  makefileSnippet: string;
  wrote: boolean;
  /** Present when board.json enables AI island. */
  aiDtsFile?: string;
  aiProfileFile?: string;
  aiEnvFile?: string;
}

/** Write the generated artifacts under the (gitignored) generated/ dir. */
export async function writeGeneratedArtifacts(
  ctx: PlatformContext,
  spec: BoardSpec,
  opts: { dryRun?: boolean } = {},
): Promise<GenerateResult> {
  const paths = boardPaths(ctx, spec.boardid);
  const pkg = generateBoardPackage(spec);
  const mk = generateBoardMakefile(spec);
  const ai = resolveAiBoard(spec);
  const aiDtsFile = ai
    ? join(paths.generatedDir, `${toIdent(spec.boardid)}_ai.dtsi`)
    : undefined;
  const aiProfileFile = ai
    ? join(paths.generatedDir, `${toIdent(spec.boardid)}_ai.profile.toml`)
    : undefined;
  const aiEnvFile = ai ? join(paths.generatedDir, "ai-tensor.env") : undefined;

  if (opts.dryRun) {
    return {
      packageFile: paths.packageFile,
      makefileSnippet: paths.makefileSnippet,
      wrote: false,
      aiDtsFile,
      aiProfileFile,
      aiEnvFile,
    };
  }
  await mkdir(paths.generatedDir, { recursive: true });
  await writeFile(paths.packageFile, pkg, "utf8");
  await writeFile(paths.makefileSnippet, mk, "utf8");
  if (ai && aiDtsFile && aiProfileFile && aiEnvFile) {
    await writeFile(aiDtsFile, generateAiDtsFragment(ai), "utf8");
    await writeFile(aiProfileFile, generateAiTensorProfile(ai), "utf8");
    await writeFile(aiEnvFile, generateAiTensorEnv(ai), "utf8");
  }
  return {
    packageFile: paths.packageFile,
    makefileSnippet: paths.makefileSnippet,
    wrote: true,
    aiDtsFile,
    aiProfileFile,
    aiEnvFile,
  };
}

// ---------------------------------------------------------------------------
// Overlay writer (selecting a board adapts the build config)
// ---------------------------------------------------------------------------

/**
 * Render the gitignored overlay (build-platform/.config.local.ts) that pins the
 * active board and adapts soc.* to the board's core requirement. This is how
 * `mb select` makes the board a first-class config axis without editing the
 * committed .config.ts.
 */
export function renderOverlay(spec: BoardSpec): string {
  const ext = JSON.stringify(spec.core.extensions);
  return [
    "// Copyright (c) 2026 Etienne Cimon",
    "// SPDX-License-Identifier: MIT",
    "//",
    "// .config.local.ts — GENERATED overlay written by `mb select " + spec.boardid + "`.",
    "// Gitignored, highest-precedence config layer. Delete it to detach the board.",
    "",
    'import { defineBuildConfig } from "./src/config/schema.ts";',
    "",
    "export default defineBuildConfig({",
    "  soc: {",
    `    coreConfig: "${spec.core.config}",`,
    `    xlen: ${spec.core.xlen},`,
    `    extensions: ${ext},`,
    "  },",
    "  motherboard: {",
    `    activeBoard: "${spec.boardid}",`,
    "  },",
    "});",
    "",
  ].join("\n");
}

/** Absolute path to the overlay file. */
export function overlayPath(ctx: PlatformContext): string {
  return join(ctx.repoRoot, "build-platform", ".config.local.ts");
}

/** Write the overlay (or preview it under dry-run). */
export async function writeOverlay(
  ctx: PlatformContext,
  spec: BoardSpec,
  opts: { dryRun?: boolean } = {},
): Promise<{ path: string; wrote: boolean }> {
  const path = overlayPath(ctx);
  if (opts.dryRun) return { path, wrote: false };
  await writeFile(path, renderOverlay(spec), "utf8");
  return { path, wrote: true };
}

// ---------------------------------------------------------------------------
// Scaffolding a new custom board
// ---------------------------------------------------------------------------

export interface ScaffoldOptions {
  name?: string;
  vendor?: string;
  class?: BoardClass;
  skidl?: MotherboardSkidlMode;
  coreConfig?: string;
  xlen?: 32 | 64;
  dryRun?: boolean;
  /**
   * When true, pin core to g6lc64_ai (xlen 64), attach starter AI UIO connectors,
   * and seed board.json ai{} for AI island / ai-tensor discovery.
   */
  ai?: boolean;
}

/** Build a starter BoardSpec for a brand-new (custom) board. */
export function starterSpec(boardid: string, opts: ScaffoldOptions): BoardSpec {
  const ai = Boolean(opts.ai);
  const xlen: 32 | 64 = ai ? 64 : (opts.xlen ?? 64);
  const coreConfig =
    opts.coreConfig ??
    (ai ? "g6lc64_ai" : xlen === 32 ? "cv32a6_imac_sv32" : "cv64a6_imafdc_sv39");
  const extensions =
    xlen === 32
      ? ["i", "m", "a", "c", "zicsr", "zifencei"]
      : ["i", "m", "a", "f", "d", "c", "zicsr", "zifencei"];
  const summary = ai
    ? `Custom AI-island board scaffold (g6lc64_ai + Xg6lcai). Advertise xg6lcai only when AiMatrixEn=1. Edit board.json ai.uioConnectors and corev-mb/architecture/${boardid}/README.md.`
    : "New custom board scaffold — edit board.json and corev-mb/architecture/" + boardid + "/README.md.";
  const interfaces: BoardInterface[] = [];
  if (ai) {
    interfaces.push(
      {
        id: "uart0",
        domain: "peripheral",
        kind: "uart",
        count: 1,
        notes: "Console UART (ns16550-class).",
      },
      {
        id: "ai0",
        domain: "accelerator",
        kind: "uio-mmio",
        count: 1,
        notes: "Xg6lcai island CAP/CTL MMIO via UIO (board.json ai.uioConnectors).",
      },
    );
  }
  const spec: BoardSpec = {
    boardid,
    name: opts.name ?? boardid,
    vendor: opts.vendor ?? "custom",
    status: "custom",
    class: opts.class ?? "custom",
    skidl: opts.skidl ?? "custom",
    summary,
    core: {
      config: coreConfig,
      xlen,
      extensions,
      ...(ai ? { isaString: "rv64imafdc_xg6lcai" } : {}),
    },
    apu: { axiDataWidth: xlen, noc: "axi4", socket: { enabled: false }, controllers: [] },
    interfaces,
    phys: [],
    references: { spec: [], vendorDocs: [] },
  };
  if (ai) {
    spec.ai = starterAiSpec(boardid);
  }
  return spec;
}

/** Create the board dir + board.json (+ a design.py stub for custom SKiDL). */
export async function scaffoldBoard(
  ctx: PlatformContext,
  boardid: string,
  opts: ScaffoldOptions = {},
): Promise<{ created: string[]; spec: BoardSpec; dryRun: boolean }> {
  const paths = boardPaths(ctx, boardid);
  const spec = starterSpec(boardid, opts);
  const created: string[] = [];
  if (opts.dryRun) {
    return { created: [paths.specFile, paths.designFile], spec, dryRun: true };
  }
  await mkdir(paths.boardDir, { recursive: true });
  if (!existsSync(paths.specFile)) {
    await writeFile(paths.specFile, JSON.stringify(spec, null, 2) + "\n", "utf8");
    created.push(paths.specFile);
  }
  if (spec.skidl === "custom" && !existsSync(paths.designFile)) {
    await writeFile(paths.designFile, starterDesignPy(boardid), "utf8");
    created.push(paths.designFile);
  }
  return { created, spec, dryRun: false };
}

function starterDesignPy(boardid: string): string {
  return [
    "# Copyright (c) 2026 Etienne Cimon",
    "# SPDX-License-Identifier: MIT",
    "#",
    `# design.py — SKiDL schematic for the custom board '${boardid}'.`,
    "#",
    "# Only 'custom' boards have this file. Third-party / reference boards set",
    '# "skidl": "omitted" in board.json and have no schematic here.',
    "#",
    "# Run via: g6lc-build mb design " + boardid + " [--online] [--fix]",
    "",
    "import os",
    "import sys",
    "",
    "# corev-mb has a hyphen (not importable as a package), so put the flat lib",
    "# dir on sys.path and import its modules directly. `mb design` also exports",
    "# PYTHONPATH to the same dir, so either invocation works.",
    'sys.path.insert(0, os.path.join(os.environ.get("CVA6_REPO_DIR", os.getcwd()), "corev-mb", "lib"))',
    "",
    "from soc import build_board  # noqa: E402",
    "",
    "",
    "def main() -> int:",
    '    """Assemble the board, run ERC, and emit a netlist + BOM."""',
    `    return build_board("${boardid}")`,
    "",
    "",
    'if __name__ == "__main__":',
    "    raise SystemExit(main())",
    "",
  ].join("\n");
}

export { toIdent, toUpper };
