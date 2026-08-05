// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// venv.ts — Manage a contained Python environment under workspace/tooling.
//
// The CVA6 flow (cva6.py, riscv-dv) needs Python 3 with specific packages. We
// create a venv inside workspace/tooling/python-venv and pip-install the pinned
// requirements + the repo's requirements.txt files into it, so nothing touches
// the host's global Python. pip works identically across Windows/Linux/macOS.

import { existsSync } from "node:fs";
import { join } from "node:path";

import type { PlatformContext } from "../context.ts";
import { hasBinary, run, which, type CommandResult } from "../platform/exec.ts";

/** Absolute path to the venv's Python interpreter. */
export function venvPython(ctx: PlatformContext): string {
  return ctx.host.os === "windows"
    ? join(ctx.paths.pythonVenv, "Scripts", "python.exe")
    : join(ctx.paths.pythonVenv, "bin", "python3");
}

/** Resolve a host Python interpreter to base the venv on. */
export function findHostPython(ctx: PlatformContext): string | null {
  const configured = ctx.config.toolchain.python.interpreter;
  if (configured && (existsSync(configured) || which(configured))) return configured;
  return which("python3") ?? which("python");
}

export interface VenvOptions {
  dryRun?: boolean;
}

/** Create the venv if it does not already exist. Returns true if usable. */
export async function ensureVenv(
  ctx: PlatformContext,
  options: VenvOptions = {},
): Promise<boolean> {
  const { logger } = ctx;
  if (existsSync(venvPython(ctx))) {
    logger.trace(`python venv already present at ${ctx.paths.pythonVenv}`);
    return true;
  }
  const host = findHostPython(ctx);
  if (!host) {
    logger.error("No host Python 3 found; install Python 3 and re-run.");
    return false;
  }
  if (options.dryRun) {
    logger.info(`[dry-run] ${host} -m venv ${ctx.paths.pythonVenv}`);
    return true;
  }
  logger.info(`Creating Python venv at ${ctx.paths.pythonVenv} (base: ${host})`);
  const result = await run(host, ["-m", "venv", ctx.paths.pythonVenv], {
    logger,
    allowFailure: true,
  });
  return result.ok;
}

/** Install pinned inline requirements + repo requirements files into the venv. */
export async function pipInstall(
  ctx: PlatformContext,
  options: VenvOptions = {},
): Promise<boolean> {
  const { logger, config, repoRoot } = ctx;
  const py = venvPython(ctx);
  const { requirements, requirementsFiles } = config.toolchain.python;

  const fileArgs: string[] = [];
  for (const rel of requirementsFiles) {
    const abs = join(repoRoot, rel);
    if (existsSync(abs)) fileArgs.push("-r", abs);
    else logger.warn(`requirements file not found (skipping): ${rel}`);
  }

  if (requirements.length === 0 && fileArgs.length === 0) {
    logger.info("No Python requirements configured; nothing to install.");
    return true;
  }

  if (options.dryRun) {
    logger.info(`[dry-run] ${py} -m pip install --upgrade pip`);
    logger.info(`[dry-run] ${py} -m pip install ${[...requirements, ...fileArgs].join(" ")}`);
    return true;
  }

  const upgrade = await run(py, ["-m", "pip", "install", "--upgrade", "pip"], {
    logger,
    allowFailure: true,
  });
  if (!upgrade.ok) logger.warn("pip self-upgrade failed; continuing.");

  const install = await run(
    py,
    ["-m", "pip", "install", ...requirements, ...fileArgs],
    { logger, allowFailure: true },
  );
  if (install.ok) logger.success("Python requirements installed into venv.");
  else logger.error(`pip install failed (exit ${install.code}).`);
  return install.ok;
}

/** True if a usable venv Python exists. */
export function venvExists(ctx: PlatformContext): boolean {
  return existsSync(venvPython(ctx));
}
