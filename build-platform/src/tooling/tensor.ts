// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// tensor.ts — host adapter for the standalone `ai-tensor/` package.
//
// Mirror of timings.ts for sv-timing: monorepo may spawn and discover ai-tensor;
// it must not become a Cargo path dependency of package crates (KD0).
//
// See ai-tensor/architecture/HOST.md.
//
// Board/core/from-timing options mirror diag/test: preflight timings package,
// export AI_TENSOR_* from board.json ai{}, and spawn frameworks/regress through
// virt-ai-pcie (virtual PCIe + soft UIO) by default.

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

import type { PlatformContext } from "../context.ts";
import {
  inferAiTensorBackend,
  resolveAiBoard,
  type AiBoardView,
  type ResolvedAiBoard,
} from "./ai-board.ts";
import { hasBinary, run } from "../platform/exec.ts";
import {
  runRegressScript,
  windowsPathToPosix,
} from "../platform/shell.ts";
import { findHostPython } from "../python/venv.ts";
import {
  applyFromTimingFlags,
  formatTimingsDashboardLines,
  summarizeTimingsPackage,
  writeTimingsDashboard,
} from "./timings.ts";
import { boardPaths, loadBoardSpec } from "./motherboard.ts";

/** Virtual implementation phases: soft host, SV HARD, sv-timing package. */
export type TensorImplPhase = "soft" | "hard" | "timing";

export type TensorImplMode = "soft" | "hard" | "full" | "hard-only";

export function parseImplMode(raw?: string): TensorImplMode {
  const s = (raw ?? "soft").trim().toLowerCase();
  if (s === "hard" || s === "rtl" || s === "rtl-hard") return "hard";
  if (s === "full" || s === "all") return "full";
  if (s === "hard-only" || s === "rtl-only") return "hard-only";
  return "soft";
}

export function implModeToPhases(
  mode: TensorImplMode,
  opts: { rtlHard?: boolean; fromTiming?: boolean } = {},
): TensorImplPhase[] {
  let phases: TensorImplPhase[];
  switch (mode) {
    case "hard":
      phases = ["soft", "hard"];
      break;
    case "hard-only":
      phases = ["hard"];
      break;
    case "full":
      phases = ["soft", "hard", "timing"];
      break;
    default:
      phases = ["soft"];
  }
  if (opts.rtlHard && !phases.includes("hard")) {
    phases = [...phases, "hard"];
  }
  if (opts.fromTiming && !phases.includes("timing") && mode === "full") {
    // full already has timing
  } else if (opts.fromTiming && mode === "full") {
    /* ok */
  } else if (opts.fromTiming && mode !== "soft" && !phases.includes("timing")) {
    // When HARD is requested with --from-timing, still run timing echo phase
    if (phases.includes("hard")) phases = [...phases, "timing"];
  }
  // Explicit: --from-timing alone on soft mode still exports env + host dashboard;
  // timing phase only when hard/full so soft CI stays cheap.
  return phases;
}

/** Resolve package root: repo-root/ai-tensor or AI_TENSOR_DIR. */
export function resolveAiTensorRoot(ctx: PlatformContext): string | null {
  const env = process.env.AI_TENSOR_DIR?.trim();
  if (env && existsSync(env)) return env;
  const cand = join(ctx.repoRoot, "ai-tensor");
  if (existsSync(join(cand, "Cargo.toml"))) return cand;
  return null;
}

export function resolveAiTensorSpawnScript(ctx: PlatformContext): string | null {
  const script = join(ctx.repoRoot, "monorepo-soak", "run-ai-tensor.sh");
  return existsSync(script) ? script : null;
}

export type TensorSpawnCmd =
  | "check"
  | "test"
  | "golden"
  | "cosim"
  | "queue-soak"
  | "event-fd-soak"
  | "rtl"
  | "virt-card"
  | "frameworks"
  | "pytorch"
  | "virt-impl"
  | "regress";

export function isTensorSpawnCmd(s: string): s is TensorSpawnCmd {
  return (
    s === "check" ||
    s === "test" ||
    s === "golden" ||
    s === "cosim" ||
    s === "queue-soak" ||
    s === "event-fd-soak" ||
    s === "rtl" ||
    s === "virt-card" ||
    s === "frameworks" ||
    s === "pytorch" ||
    s === "virt-impl" ||
    s === "regress"
  );
}

export interface TensorRunOptions {
  dryRun?: boolean;
  /** board.json id (e.g. virt-ai-pcie, ai-card). Propagates AI_TENSOR_BOARD_ID. */
  board?: string;
  /** Core config package (e.g. g6lc64_ai). Propagates AI_TENSOR_CORE / CVA6_CORE_CONFIG. */
  core?: string;
  /** Optional apu/soc note — exported as AI_TENSOR_APU when set. */
  apu?: string;
  /** Device backend override: sim | mmio | virt-card. */
  backend?: string;
  /** virt-card mode: auto | local | tcp. */
  virtMode?: string;
  /** timings precompile out-dir (structural validate; like diag --from-timing). */
  fromTiming?: string;
  /** Expert: point child env at corrected flist (requires --from-timing). */
  useEmit?: boolean;
  requireEmit?: boolean;
  /**
   * Virtual implementation mode:
   *   soft      — Device/PyTorch virt-card only (default)
   *   hard      — soft + SV ai_island RTL HARD
   *   full      — soft + HARD + sv-timing phase (needs --from-timing for timing PASS)
   *   hard-only — SV HARD only
   */
  impl?: string;
  /** Include RTL HARD phase (alias for --impl hard when starting from soft). */
  rtlHard?: boolean;
  /** Fail if HARD work-ver missing (default soft-skip hard phase). */
  requireHard?: boolean;
  /** Fail if timing phase lacks FROM_TIMING (full mode). */
  requireTiming?: boolean;
  /** Extra args after frameworks_regress.py (frameworks only). */
  extraArgs?: string[];
}

function resolveBoardId(
  ctx: PlatformContext,
  opts: TensorRunOptions,
): string | undefined {
  if (opts.board && opts.board.trim()) return opts.board.trim();
  if (process.env.AI_TENSOR_BOARD_ID?.trim()) {
    return process.env.AI_TENSOR_BOARD_ID.trim();
  }
  if (ctx.config.motherboard?.activeBoard) {
    return ctx.config.motherboard.activeBoard;
  }
  return undefined;
}

function resolveCoreConfig(
  ctx: PlatformContext,
  opts: TensorRunOptions,
  boardCore?: string,
): string {
  if (opts.core && opts.core.trim()) return opts.core.trim();
  if (process.env.AI_TENSOR_CORE?.trim()) return process.env.AI_TENSOR_CORE.trim();
  if (process.env.CVA6_CORE_CONFIG?.trim()) {
    return process.env.CVA6_CORE_CONFIG.trim();
  }
  if (boardCore) return boardCore;
  return ctx.config.soc.coreConfig;
}

/**
 * Load board.json ai{} and resolve AI_TENSOR_* env for child processes.
 * Returns null when board missing or has no AI block.
 */
export async function loadTensorBoardEnv(
  ctx: PlatformContext,
  boardid: string,
): Promise<{
  resolved: ResolvedAiBoard | null;
  coreConfig: string;
  env: Record<string, string>;
  className?: string;
} | null> {
  const paths = boardPaths(ctx, boardid);
  if (!existsSync(paths.specFile)) {
    return null;
  }
  try {
    const spec = await loadBoardSpec(ctx, boardid);
    const view: AiBoardView = {
      boardid: spec.boardid,
      core: { config: spec.core.config },
      ai: spec.ai,
    };
    const resolved = resolveAiBoard(view);
    const env: Record<string, string> = {
      AI_TENSOR_BOARD_ID: boardid,
    };
    if (resolved) {
      const backend = inferAiTensorBackend(resolved);
      env.AI_TENSOR_BACKEND = backend;
      env.AI_TENSOR_UIO = resolved.primaryUioPath;
      env.AI_TENSOR_MMIO_BASE = `0x${resolved.mmioBase.toString(16)}`;
      env.AI_TENSOR_PLIC_SOURCE = String(resolved.plicSource);
      env.AI_TENSOR_ACC_TILE_M = String(resolved.accTileM);
      env.AI_TENSOR_ACC_TILE_N = String(resolved.accTileN);
      env.AI_TENSOR_ACC_TILE_K = String(resolved.accTileK);
      env.AI_TENSOR_MACS = String(resolved.macsPerCycle);
      env.AI_TENSOR_NOC_WIDTH = String(resolved.nocWidth);
      env.AI_TENSOR_PROFILE = resolved.profileId;
      // Prefer soft-sticky eventfd connector if present
      const efd = resolved.connectors.find((c) => c.kind === "eventfd");
      if (efd?.path) env.AI_TENSOR_EVENTFD = efd.path;
    } else {
      // Board without ai{} — still export id; default virt backend for virt-* ids
      if (boardid.startsWith("virt")) {
        env.AI_TENSOR_BACKEND = "virt-card";
        env.AI_TENSOR_UIO = `virt://${boardid}/island0`;
      }
    }
    // Prefer generated env if present (post mb select)
    const genEnv = join(paths.generatedDir, "ai-tensor.env");
    if (existsSync(genEnv)) {
      try {
        const text = readFileSync(genEnv, "utf8");
        for (const line of text.split("\n")) {
          const m = line.match(/^export\s+([A-Z0-9_]+)=(.*)$/);
          if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, "");
        }
      } catch {
        /* ignore */
      }
    }
    return {
      resolved,
      coreConfig: spec.core.config,
      env,
      className: spec.class,
    };
  } catch (err) {
    ctx.logger.warn(
      `tensor: could not load board '${boardid}': ${err instanceof Error ? err.message : String(err)}`,
    );
    return {
      resolved: null,
      coreConfig: ctx.config.soc.coreConfig,
      env: { AI_TENSOR_BOARD_ID: boardid },
    };
  }
}

/**
 * Preflight --from-timing like test/verify: validate package, optional --use-emit,
 * structural FO4 soak dashboard (not STA). Live RTL flists are not replaced unless
 * expert --use-emit is set.
 */
export function preflightFromTiming(
  ctx: PlatformContext,
  opts: TensorRunOptions,
): {
  ok: boolean;
  dir?: string;
  code?: number;
  env: Record<string, string>;
} {
  if (!opts.fromTiming) return { ok: true, env: {} };
  if (opts.useEmit && !opts.fromTiming) {
    ctx.logger.error("--use-emit requires --from-timing <dir>");
    return { ok: false, code: 2, env: {} };
  }
  const ft = applyFromTimingFlags(ctx, {
    fromTiming: opts.fromTiming,
    useEmit: opts.useEmit === true,
    requireEmit: opts.requireEmit === true || opts.useEmit === true,
  });
  if (!ft.ok) {
    ctx.logger.error(`--from-timing structure invalid: ${ft.dir ?? opts.fromTiming}`);
    for (const issue of ft.issues.filter((i) => i.level === "error")) {
      ctx.logger.error(`  [${issue.code}] ${issue.message}`);
    }
    ctx.logger.info("Fix the out-dir or run: timings validate --from-timing <dir>");
    return { ok: false, dir: ft.dir, code: 1, env: {} };
  }
  ctx.logger.success(
    `--from-timing OK: ${ft.dir} (report=${ft.validation?.reportKind ?? "?"}; live RTL not replaced by default)`,
  );
  if (opts.useEmit && ft.emitFlist) {
    ctx.logger.warn(`expert --use-emit: ${ft.emitFlist}`);
    ctx.logger.info(
      "CVA6_TIMINGS_USE_EMIT=1: child may overlay emit flist (R8); HARD still uses work-ver-ai by default",
    );
  }
  for (const issue of ft.issues.filter((i) => i.level === "warn")) {
    ctx.logger.warn(`  [${issue.code}] ${issue.message}`);
  }
  // Structural FO4 dashboard (same as `test --from-timing`)
  try {
    const dash = summarizeTimingsPackage(ctx, ft.dir!);
    writeTimingsDashboard(ft.dir!, dash);
    ctx.logger.heading("Soak dashboard (structural FO4 — not STA)");
    for (const line of formatTimingsDashboardLines(dash)) {
      ctx.logger.info(line);
    }
  } catch (err) {
    ctx.logger.warn(
      `timings dashboard skipped: ${err instanceof Error ? err.message : String(err)}`,
    );
  }
  return { ok: true, dir: ft.dir, env: ft.env };
}

/** Build env for any tensor spawn (board + core + from-timing + package). */
export async function buildTensorChildEnv(
  ctx: PlatformContext,
  opts: TensorRunOptions,
): Promise<{ env: Record<string, string | undefined>; boardId?: string; core: string }> {
  const pkg = resolveAiTensorRoot(ctx);
  const boardId = resolveBoardId(ctx, opts);
  let boardEnv: Record<string, string> = {};
  let boardCore: string | undefined;
  if (boardId) {
    const loaded = await loadTensorBoardEnv(ctx, boardId);
    if (loaded) {
      boardEnv = loaded.env;
      boardCore = loaded.coreConfig;
    } else {
      boardEnv = { AI_TENSOR_BOARD_ID: boardId };
      if (boardId.startsWith("virt")) {
        boardEnv.AI_TENSOR_BACKEND = "virt-card";
        boardEnv.AI_TENSOR_UIO = `virt://${boardId}/island0`;
      }
    }
  }
  const core = resolveCoreConfig(ctx, opts, boardCore);
  const ft = preflightFromTiming(ctx, opts);
  if (!ft.ok) {
    throw new Error("from-timing preflight failed");
  }

  const env: Record<string, string | undefined> = {
    AI_TENSOR_DIR: pkg ?? undefined,
    AI_TENSOR_MONOREPO: ctx.repoRoot,
    AI_TENSOR_COSIM_CMD:
      process.env.AI_TENSOR_COSIM_CMD ?? "python3 tools/cosim_harness.py",
    ...boardEnv,
    ...ft.env,
    AI_TENSOR_CORE: core,
    CVA6_CORE_CONFIG: core,
  };
  if (opts.backend) env.AI_TENSOR_BACKEND = opts.backend;
  if (opts.virtMode) env.AI_TENSOR_VIRT_MODE = opts.virtMode;
  if (opts.apu) env.AI_TENSOR_APU = opts.apu;
  if (opts.requireHard) env.AI_TENSOR_REQUIRE_HARD = "1";
  if (opts.requireTiming) env.AI_TENSOR_REQUIRE_TIMING = "1";
  // Default virt-card for frameworks/regress when board is virtual and backend unset
  if (
    !env.AI_TENSOR_BACKEND &&
    boardId &&
    (boardId.startsWith("virt") || boardEnv.AI_TENSOR_BACKEND === "virt-card")
  ) {
    env.AI_TENSOR_BACKEND = "virt-card";
  }
  return { env, boardId, core };
}

/**
 * Multi-phase virtual implementation gate:
 *   soft   — PyTorch/Device via virt-ai-pcie
 *   hard   — SV ai_island RTL HARD (work-ver-ai mmio+gemm_s8)
 *   timing — re-check --from-timing package in child (host already validated)
 *
 * Prefer: tensor virt-impl | tensor pytorch --impl hard|full --from-timing DIR
 */
export async function runAiTensorVirtImpl(
  ctx: PlatformContext,
  opts: TensorRunOptions = {},
): Promise<number> {
  const { logger } = ctx;
  const script = join(ctx.repoRoot, "monorepo-soak", "run-ai-tensor-virt-impl.sh");
  if (!existsSync(script)) {
    logger.error("monorepo-soak/run-ai-tensor-virt-impl.sh missing");
    return 1;
  }

  const opts2: TensorRunOptions = { ...opts };
  if (
    !opts2.board &&
    !process.env.AI_TENSOR_BOARD_ID &&
    !ctx.config.motherboard?.activeBoard
  ) {
    opts2.board = "virt-ai-pcie";
  }
  if (
    !opts2.core &&
    !process.env.AI_TENSOR_CORE &&
    !process.env.CVA6_CORE_CONFIG
  ) {
    opts2.core = "g6lc64_ai";
  }

  const mode = parseImplMode(opts2.impl);
  let phases = implModeToPhases(mode, {
    rtlHard: opts2.rtlHard === true,
    fromTiming: !!opts2.fromTiming,
  });
  // full / hard + --from-timing: include timing echo phase after host preflight
  if (
    opts2.fromTiming &&
    (mode === "full" || mode === "hard" || opts2.rtlHard) &&
    !phases.includes("timing")
  ) {
    phases = [...phases, "timing"];
  }

  let env: Record<string, string | undefined>;
  let boardId: string | undefined;
  let core: string;
  try {
    ({ env, boardId, core } = await buildTensorChildEnv(ctx, opts2));
  } catch {
    return 1;
  }
  env.AI_TENSOR_IMPL_PHASES = phases.join(",");

  logger.heading("ai-tensor virtual implementation test");
  logger.info(`  phases  : ${phases.join(" → ")}`);
  logger.info(`  board   : ${boardId ?? "?"}`);
  logger.info(`  core    : ${core} (ai_island package selection)`);
  logger.info(`  backend : ${env.AI_TENSOR_BACKEND ?? "?"}`);
  if (env.CVA6_FROM_TIMING) {
    logger.info(`  timing  : ${env.CVA6_FROM_TIMING} (sv-timing structural FO4)`);
  } else if (phases.includes("timing")) {
    logger.warn("  timing  : phase requested but no --from-timing (will soft-skip unless --require-timing)");
  }
  logger.info(
    "  note    : soft = host software; hard = SV RTL; timing ≠ STA sign-off",
  );

  if (opts2.dryRun || ctx.dryRun) {
    logger.warn("dry-run: not executing virt-impl phases");
    return 0;
  }

  const r = await runRegressScript(script, [], {
    cwd: ctx.repoRoot,
    env,
    logger,
  });
  return r.code ?? 1;
}

/** Lab HARD RTL: mmio + gemm_s8 on work-ver-ai (opt-in). */
export async function runAiTensorRtlHard(
  ctx: PlatformContext,
  opts: TensorRunOptions = {},
): Promise<number> {
  const { logger } = ctx;
  const script = join(ctx.repoRoot, "monorepo-soak", "run-ai-tensor-rtl-hard.sh");
  if (!existsSync(script)) {
    logger.error("monorepo-soak/run-ai-tensor-rtl-hard.sh missing");
    return 1;
  }
  let env: Record<string, string | undefined>;
  try {
    ({ env } = await buildTensorChildEnv(ctx, opts));
  } catch {
    return 1;
  }
  logger.info(`tensor rtl-hard: ${script}`);
  if (opts.dryRun || ctx.dryRun) {
    logger.warn("dry-run: not executing HARD RTL");
    return 0;
  }
  const r = await runRegressScript(script, [], {
    cwd: ctx.repoRoot,
    env,
    logger,
  });
  return r.code ?? 1;
}

/**
 * Spawn package tests via monorepo-soak adapter (bash / WSL on Windows).
 * Never imports package crates.
 */
export async function runAiTensorSpawn(
  ctx: PlatformContext,
  cmd: TensorSpawnCmd,
  opts: TensorRunOptions = {},
): Promise<number> {
  const { logger } = ctx;
  const pkg = resolveAiTensorRoot(ctx);
  const script = resolveAiTensorSpawnScript(ctx);
  if (!pkg) {
    logger.error(
      "ai-tensor package not found (set AI_TENSOR_DIR or place at repo-root/ai-tensor)",
    );
    return 1;
  }
  if (!script) {
    logger.error("monorepo-soak/run-ai-tensor.sh missing");
    return 1;
  }

  // frameworks / pytorch / regress / virt-card default board to virt-ai-pcie
  const opts2: TensorRunOptions = { ...opts };
  if (
    (cmd === "frameworks" ||
      cmd === "pytorch" ||
      cmd === "regress" ||
      cmd === "virt-card") &&
    !opts2.board &&
    !process.env.AI_TENSOR_BOARD_ID &&
    !ctx.config.motherboard?.activeBoard
  ) {
    opts2.board = "virt-ai-pcie";
  }
  // Default core for AI island path when unset
  if (
    (cmd === "frameworks" || cmd === "pytorch" || cmd === "regress") &&
    !opts2.core &&
    !process.env.AI_TENSOR_CORE &&
    !process.env.CVA6_CORE_CONFIG
  ) {
    opts2.core = "g6lc64_ai";
  }

  let env: Record<string, string | undefined>;
  let boardId: string | undefined;
  let core: string;
  try {
    ({ env, boardId, core } = await buildTensorChildEnv(ctx, opts2));
  } catch {
    return 1;
  }

  // Multi-phase pytorch / virt-impl before dry-run early-return so --rtl-hard previews phases
  if (cmd === "pytorch") {
    const mode = parseImplMode(opts2.impl);
    const wantHard =
      opts2.rtlHard === true ||
      mode === "hard" ||
      mode === "full" ||
      mode === "hard-only";
    const wantTiming = mode === "full" || (wantHard && !!opts2.fromTiming);
    if (wantHard || wantTiming || mode !== "soft") {
      return runAiTensorVirtImpl(ctx, {
        ...opts2,
        impl: opts2.impl ?? (wantHard ? "hard" : "soft"),
        rtlHard: wantHard,
      });
    }
  }
  if (cmd === "virt-impl") {
    return runAiTensorVirtImpl(ctx, opts2);
  }

  logger.info(`tensor spawn: ${script} ${cmd}`);
  logger.info(`  AI_TENSOR_DIR=${pkg}`);
  if (boardId) logger.info(`  board=${boardId} backend=${env.AI_TENSOR_BACKEND ?? "?"}`);
  logger.info(`  core=${core}`);
  if (env.CVA6_FROM_TIMING) {
    logger.info(`  from-timing=${env.CVA6_FROM_TIMING}`);
  }
  if (opts.dryRun || ctx.dryRun) {
    logger.warn("dry-run: not executing");
    return 0;
  }

  // frameworks can take extra args for suites/tcp
  if (cmd === "frameworks") {
    const fw = join(ctx.repoRoot, "monorepo-soak", "run-ai-tensor-frameworks.sh");
    if (!existsSync(fw)) {
      logger.error("monorepo-soak/run-ai-tensor-frameworks.sh missing");
      return 1;
    }
    const r = await runRegressScript(fw, opts.extraArgs ?? [], {
      cwd: ctx.repoRoot,
      env,
      logger,
    });
    return r.code ?? 1;
  }
  if (cmd === "pytorch") {
    const pt = join(ctx.repoRoot, "monorepo-soak", "run-ai-tensor-pytorch.sh");
    if (!existsSync(pt)) {
      logger.error("monorepo-soak/run-ai-tensor-pytorch.sh missing");
      return 1;
    }
    logger.info(
      "  pytorch suite: ai-tensor/python/tests/test_torch_virt_ai_island.py " +
        "(Device always; full torch cases if torch installed; use --rtl-hard for SV)",
    );
    const r = await runRegressScript(pt, opts.extraArgs ?? [], {
      cwd: ctx.repoRoot,
      env,
      logger,
    });
    return r.code ?? 1;
  }
  if (cmd === "regress") {
    const rg = join(ctx.repoRoot, "monorepo-soak", "run-ai-tensor-regress.sh");
    if (!existsSync(rg)) {
      logger.error("monorepo-soak/run-ai-tensor-regress.sh missing");
      return 1;
    }
    const r = await runRegressScript(rg, [], {
      cwd: ctx.repoRoot,
      env,
      logger,
    });
    return r.code ?? 1;
  }

  const r = await runRegressScript(script, [cmd], {
    cwd: ctx.repoRoot,
    env,
    logger,
  });
  return r.code ?? 1;
}

/** Run package cargo CLI (WSL when Windows lacks cargo). */
async function runPackageCargo(
  ctx: PlatformContext,
  pkg: string,
  cargoArgs: string[],
  opts: { dryRun?: boolean } = {},
): Promise<number> {
  const { logger } = ctx;
  if (opts.dryRun || ctx.dryRun) {
    logger.warn(`dry-run: cargo ${cargoArgs.join(" ")} in ${pkg}`);
    return 0;
  }
  const useWsl =
    process.platform === "win32" && hasBinary("wsl") && !hasBinary("cargo");
  if (useWsl) {
    const pkgWsl = windowsPathToPosix(pkg, "wsl");
    const quoted = cargoArgs.map((a) => JSON.stringify(a)).join(" ");
    const shellCmd = `cd ${JSON.stringify(pkgWsl)} && cargo ${quoted}`;
    const r = await run("wsl", ["-e", "bash", "-lc", shellCmd], { logger });
    return r.code ?? 1;
  }
  if (!hasBinary("cargo")) {
    logger.error("cargo not found on PATH (install Rust or use WSL)");
    return 1;
  }
  const r = await run("cargo", cargoArgs, { cwd: pkg, logger });
  return r.code ?? 1;
}

/** Package-local doctor: independence + cargo doctor. */
export async function runAiTensorDoctor(
  ctx: PlatformContext,
  opts: { dryRun?: boolean; json?: boolean } = {},
): Promise<number> {
  const { logger } = ctx;
  const pkg = resolveAiTensorRoot(ctx);
  if (!pkg) {
    logger.error("ai-tensor not found");
    return 1;
  }
  if (opts.dryRun || ctx.dryRun) {
    logger.warn(`dry-run: would run doctor in ${pkg}`);
    return 0;
  }

  if (opts.json) {
    return runPackageCargo(
      ctx,
      pkg,
      [
        "run",
        "-q",
        "-p",
        "ai-tensor-cli",
        "--",
        "probe",
        "--profile",
        "profiles/island-p3-v1.toml",
      ],
      opts,
    );
  }

  // Prefer WSL on Windows when cargo lives there (common monorepo layout).
  const useWsl =
    process.platform === "win32" &&
    hasBinary("wsl") &&
    !hasBinary("cargo");

  if (useWsl) {
    const pkgWsl = windowsPathToPosix(pkg, "wsl");
    const shellCmd =
      `cd ${JSON.stringify(pkgWsl)} && ` +
      `python3 tools/check_independence.py && ` +
      `cargo run -q -p ai-tensor-cli -- doctor --profile profiles/island-p3-v1.toml`;
    logger.info(`tensor doctor via WSL: ${pkgWsl}`);
    const r = await run("wsl", ["-e", "bash", "-lc", shellCmd], { logger });
    return r.code ?? 1;
  }

  const py = findHostPython(ctx);
  if (!py) {
    logger.error(
      "python not found (need python3/python for independence check)",
    );
    return 1;
  }
  const r1 = await run(py, ["tools/check_independence.py"], {
    cwd: pkg,
    logger,
  });
  if ((r1.code ?? 1) !== 0) return r1.code ?? 1;
  return runPackageCargo(
    ctx,
    pkg,
    [
      "run",
      "-q",
      "-p",
      "ai-tensor-cli",
      "--",
      "doctor",
      "--profile",
      "profiles/island-p3-v1.toml",
    ],
    opts,
  );
}

/** Emit ProbeReport JSON only. */
export async function runAiTensorProbe(
  ctx: PlatformContext,
  opts: { dryRun?: boolean; profile?: string } = {},
): Promise<number> {
  const pkg = resolveAiTensorRoot(ctx);
  if (!pkg) {
    ctx.logger.error("ai-tensor not found");
    return 1;
  }
  const profile = opts.profile ?? "profiles/island-p3-v1.toml";
  return runPackageCargo(
    ctx,
    pkg,
    ["run", "-q", "-p", "ai-tensor-cli", "--", "probe", "--profile", profile],
    opts,
  );
}

export function formatTensorStatus(ctx: PlatformContext): Record<string, unknown> {
  const pkg = resolveAiTensorRoot(ctx);
  const script = resolveAiTensorSpawnScript(ctx);
  return {
    aiTensorRoot: pkg,
    present: pkg != null,
    spawnScript: script,
    spawnPresent: script != null,
    activeBoard: ctx.config.motherboard?.activeBoard ?? null,
    coreConfig: ctx.config.soc.coreConfig,
    note:
      "spawn only — no Cargo path dep into monorepo; see ai-tensor/architecture/HOST.md. " +
      "tensor pytorch|virt-impl|regress --board virt-ai-pcie --core g6lc64_ai " +
      "[--impl soft|hard|full] [--rtl-hard] [--from-timing DIR] [--use-emit]",
    commands: [
      "tensor status",
      "tensor doctor",
      "tensor test",
      "tensor golden",
      "tensor cosim",
      "tensor queue-soak",
      "tensor event-fd-soak",
      "tensor virt-card",
      "tensor frameworks",
      "tensor pytorch",
      "tensor virt-impl",
      "tensor regress",
      "tensor rtl",
      "tensor rtl-hard",
    ],
  };
}
