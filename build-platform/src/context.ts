// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// context.ts — The shared runtime context passed to every command.
//
// A PlatformContext bundles the resolved config, detected repo root, host
// info, workspace paths, tool locations, and a configured logger. It also
// builds the child-process environment that points the CVA6 flow (Makefile,
// verif scripts) at the managed toolchain in workspace/tooling.

import { existsSync } from "node:fs";
import { join } from "node:path";

import { loadConfig, type LoadedConfig } from "./config/load.ts";
import type { ResolvedBuildConfig } from "./config/schema.ts";
import { getHostInfo, recommendedJobs, type HostInfo } from "./platform/os.ts";
import { toolLocations, type ToolLocations } from "./tooling/locations.ts";
import {
  findOssCadVerilatorRoot,
  isVerilatorInstalled,
} from "./tooling/recipes.ts";
import type { LogLevel } from "./util/log.ts";
import { Logger } from "./util/log.ts";
import {
  ensureWorkspace,
  resolveWorkspacePaths,
  type WorkspacePaths,
} from "./workspace/layout.ts";

export interface PlatformContext {
  config: ResolvedBuildConfig;
  repoRoot: string;
  host: HostInfo;
  paths: WorkspacePaths;
  tools: ToolLocations;
  derived: LoadedConfig["derived"];
  logger: Logger;
  configPath: string | null;
  overlayPath: string | null;
  /** When true, side-effecting commands only print what they would do. */
  dryRun: boolean;
}

export interface CreateContextOptions {
  cwd?: string;
  configPath?: string;
  dryRun?: boolean;
  /** Force a log level (e.g. from --verbose/--quiet) over the config value. */
  logLevel?: LogLevel;
  /** Create the workspace directory tree up front. */
  ensureWorkspaceDirs?: boolean;
}

/** Build a PlatformContext by loading + validating the effective config. */
export async function createContext(
  options: CreateContextOptions = {},
): Promise<PlatformContext> {
  const loaded = await loadConfig({
    cwd: options.cwd,
    configPath: options.configPath,
  });
  const host = getHostInfo();
  const paths = resolveWorkspacePaths(loaded.repoRoot, loaded.config);
  const tools = toolLocations(paths, loaded.config, host.os);

  const logger = new Logger({
    level: options.logLevel ?? loaded.config.logging.level,
    color: loaded.config.logging.color,
    timestamps: loaded.config.logging.timestamps,
  });

  if (options.ensureWorkspaceDirs) {
    await ensureWorkspace(paths);
  }

  return {
    config: loaded.config,
    repoRoot: loaded.repoRoot,
    host,
    paths,
    tools,
    derived: loaded.derived,
    logger,
    configPath: loaded.configPath,
    overlayPath: loaded.overlayPath,
    dryRun: options.dryRun ?? false,
  };
}

/**
 * Assemble the environment for CVA6 child processes: prepend managed tool bin
 * directories to PATH and export the variables the Makefile / verif scripts
 * expect (RISCV, CVA6_REPO_DIR, VERILATOR_INSTALL_DIR, SPIKE_INSTALL_DIR,
 * TARGET_CFG, NUM_JOBS).
 */
export function childEnv(
  ctx: PlatformContext,
  extra: Record<string, string> = {},
): Record<string, string> {
  const { host, tools, paths, repoRoot, config } = ctx;
  const ossCadRoot = findOssCadVerilatorRoot(paths.tooling);
  const ossCadBin = ossCadRoot ? join(ossCadRoot, "bin") : null;
  const managedVl = isVerilatorInstalled(tools.verilatorBin);

  // Prefer managed pin; fall back to OSS CAD Suite so smoke scripts that source
  // install-verilator.sh see an already-populated VERILATOR_INSTALL_DIR.
  const verilatorInstallDir = managedVl
    ? tools.verilator
    : (ossCadRoot ?? tools.verilator);

  const prepend = [
    paths.toolsBin,
    tools.riscvBin,
    tools.verilatorBin,
    ...(ossCadBin && existsSync(ossCadBin) ? [ossCadBin] : []),
    tools.spikeBin,
    tools.iverilogBin,
    tools.pythonVenvBin,
  ];
  const currentPath = process.env.PATH ?? process.env.Path ?? "";
  const newPath = [...prepend, currentPath].join(host.pathSep);

  return {
    PATH: newPath,
    // Windows resolves the env var name case-insensitively but Bun.spawn keys
    // are case-sensitive; set both to be safe.
    Path: newPath,
    RISCV: tools.riscv,
    CVA6_REPO_DIR: repoRoot,
    VERILATOR_INSTALL_DIR: verilatorInstallDir,
    // OSS CAD / Verilator perl wrapper honors VERILATOR_ROOT when set.
    ...(existsSync(join(verilatorInstallDir, "share", "verilator"))
      ? { VERILATOR_ROOT: join(verilatorInstallDir, "share", "verilator") }
      : {}),
    SPIKE_INSTALL_DIR: tools.spike,
    TARGET_CFG: config.soc.coreConfig,
    NUM_JOBS: String(recommendedJobs()),
    ...extra,
  };
}
