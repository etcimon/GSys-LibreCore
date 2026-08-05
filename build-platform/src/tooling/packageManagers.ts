// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// packageManagers.ts — Detect and drive the host OS package manager.
//
// Used to install build prerequisites (compilers, autoconf, flex/bison, dtc,
// python) needed to build Verilator/Spike from source. Installs are gated:
// they only run when explicitly allowed (config.platform.allowSystemInstall or
// an explicit --install/--allow-system-install), never implicitly.

import type { HostOS, PackageManager } from "../config/schema.ts";
import { hasBinary, run, type CommandResult } from "../platform/exec.ts";
import type { Logger } from "../util/log.ts";

/** Executable that fronts each package manager. */
const MANAGER_BIN: Record<PackageManager, string> = {
  chocolatey: "choco",
  winget: "winget",
  scoop: "scoop",
  apt: "apt-get",
  dnf: "dnf",
  pacman: "pacman",
  zypper: "zypper",
  brew: "brew",
};

/** Install subcommand/flags per manager (package name(s) appended). */
const INSTALL_ARGS: Record<PackageManager, string[]> = {
  chocolatey: ["install", "-y"],
  winget: ["install", "-e", "--accept-package-agreements", "--accept-source-agreements", "--id"],
  scoop: ["install"],
  apt: ["install", "-y"],
  dnf: ["install", "-y"],
  pacman: ["-S", "--noconfirm"],
  zypper: ["install", "-y"],
  brew: ["install"],
};

/** Managers that typically require root and are not themselves elevated. */
const NEEDS_SUDO: Set<PackageManager> = new Set(["apt", "dnf", "pacman", "zypper"]);

const DEFAULT_BY_OS: Record<HostOS, PackageManager[]> = {
  windows: ["chocolatey", "winget", "scoop"],
  darwin: ["brew"],
  linux: ["apt", "dnf", "pacman", "zypper"],
};

/**
 * Build-prerequisite package names per manager. Names target the packages the
 * CVA6 open-source-sim toolchain needs to compile (Verilator, Spike, dtc).
 */
export const PREREQS: Partial<Record<PackageManager, string[]>> = {
  apt: [
    "git", "curl", "wget", "make", "cmake", "autoconf", "automake", "g++", "flex", "bison", "gperf",
    "device-tree-compiler", "python3", "python3-pip", "python3-venv", "help2man", "libfl2", "libfl-dev",
  ],
  dnf: [
    "git", "curl", "wget", "make", "cmake", "autoconf", "automake", "gcc-c++", "flex", "bison", "gperf",
    "dtc", "python3", "python3-pip", "help2man",
  ],
  pacman: [
    "git", "make", "cmake", "autoconf", "gcc", "flex", "bison", "gperf",
    "dtc", "python", "python-pip", "help2man",
  ],
  brew: ["git", "make", "cmake", "autoconf", "flex", "bison", "gperf", "dtc", "python", "help2man", "verilator", "icarus-verilog"],
  chocolatey: ["git", "make", "cmake", "python3", "dtc"],
};

export function detectPackageManager(
  os: HostOS,
  preferred?: PackageManager,
): PackageManager | null {
  const order: PackageManager[] = [];
  if (preferred) order.push(preferred);
  for (const m of DEFAULT_BY_OS[os]) if (!order.includes(m)) order.push(m);
  return order.find((m) => hasBinary(MANAGER_BIN[m])) ?? null;
}

export interface InstallOptions {
  logger: Logger;
  dryRun?: boolean;
  /** Prefix apt/dnf/etc. with sudo when not already root. */
  useSudo?: boolean;
}

/** Install one or more packages with the given manager. */
export async function installPackages(
  manager: PackageManager,
  packages: string[],
  options: InstallOptions,
): Promise<CommandResult> {
  const bin = MANAGER_BIN[manager];
  const argv = [...INSTALL_ARGS[manager], ...packages];

  const needsSudo = options.useSudo && NEEDS_SUDO.has(manager) && hasBinary("sudo");
  const cmd = needsSudo ? "sudo" : bin;
  const args = needsSudo ? [bin, ...argv] : argv;

  if (options.dryRun) {
    options.logger.info(`[dry-run] ${cmd} ${args.join(" ")}`);
    return { command: `${cmd} ${args.join(" ")}`, code: 0, stdout: "", stderr: "", durationMs: 0, ok: true, dryRun: true };
  }
  options.logger.info(`Installing ${packages.length} package(s) via ${manager}...`);
  return run(cmd, args, { logger: options.logger, allowFailure: true });
}

/** Install the LibreCore build prerequisites for the detected manager. */
export async function installPrerequisites(
  os: HostOS,
  options: InstallOptions & { preferred?: PackageManager },
): Promise<{ manager: PackageManager | null; result: CommandResult | null }> {
  const manager = detectPackageManager(os, options.preferred);
  if (!manager) {
    options.logger.warn("No supported package manager found; install prerequisites manually.");
    return { manager: null, result: null };
  }
  const packages = PREREQS[manager];
  if (!packages || packages.length === 0) {
    options.logger.warn(`No prerequisite package list defined for ${manager}.`);
    return { manager, result: null };
  }
  const result = await installPackages(manager, packages, options);
  return { manager, result };
}
