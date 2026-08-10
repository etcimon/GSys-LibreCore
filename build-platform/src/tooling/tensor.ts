// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// tensor.ts — host adapter for the standalone `ai-tensor/` package.
//
// Mirror of timings.ts for sv-timing: monorepo may spawn and discover ai-tensor;
// it must not become a Cargo path dependency of package crates (KD0).
//
// See ai-tensor/architecture/HOST.md.

import { existsSync } from "node:fs";
import { join } from "node:path";

import type { PlatformContext } from "../context.ts";
import { hasBinary, run } from "../platform/exec.ts";
import {
  runRegressScript,
  windowsPathToPosix,
} from "../platform/shell.ts";
import { findHostPython } from "../python/venv.ts";

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
  | "rtl";

export function isTensorSpawnCmd(s: string): s is TensorSpawnCmd {
  return (
    s === "check" ||
    s === "test" ||
    s === "golden" ||
    s === "cosim" ||
    s === "queue-soak" ||
    s === "rtl"
  );
}

/**
 * Spawn package tests via monorepo-soak adapter (bash / WSL on Windows).
 * Never imports package crates.
 */
export async function runAiTensorSpawn(
  ctx: PlatformContext,
  cmd: TensorSpawnCmd,
  opts: { dryRun?: boolean } = {},
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
  const env: Record<string, string | undefined> = {
    AI_TENSOR_DIR: pkg,
    AI_TENSOR_MONOREPO: ctx.repoRoot,
    AI_TENSOR_COSIM_CMD:
      process.env.AI_TENSOR_COSIM_CMD ?? "python3 tools/cosim_harness.py",
  };
  logger.info(`tensor spawn: ${script} ${cmd}`);
  logger.info(`  AI_TENSOR_DIR=${pkg}`);
  if (opts.dryRun || ctx.dryRun) {
    logger.warn("dry-run: not executing");
    return 0;
  }
  const r = await runRegressScript(script, [cmd], {
    cwd: ctx.repoRoot,
    env,
    logger,
  });
  return r.code ?? 1;
}

/** Package-local doctor: independence + cargo doctor. */
export async function runAiTensorDoctor(
  ctx: PlatformContext,
  opts: { dryRun?: boolean } = {},
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
  if (!hasBinary("cargo")) {
    logger.error("cargo not found on PATH (install Rust or use WSL)");
    return 1;
  }
  const r2 = await run(
    "cargo",
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
    { cwd: pkg, logger },
  );
  return r2.code ?? 1;
}

export function formatTensorStatus(ctx: PlatformContext): Record<string, unknown> {
  const pkg = resolveAiTensorRoot(ctx);
  const script = resolveAiTensorSpawnScript(ctx);
  return {
    aiTensorRoot: pkg,
    present: pkg != null,
    spawnScript: script,
    spawnPresent: script != null,
    note: "spawn only — no Cargo path dep into monorepo; see ai-tensor/architecture/HOST.md",
    commands: [
      "tensor status",
      "tensor doctor",
      "tensor test",
      "tensor golden",
      "tensor cosim",
      "tensor queue-soak",
      "tensor rtl",
    ],
  };
}
