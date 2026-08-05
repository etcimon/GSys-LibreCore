// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// os.ts — Host OS detection and per-OS conventions.

import { cpus, homedir } from "node:os";

import type { HostOS, ShellKind } from "../config/schema.ts";

export interface HostInfo {
  os: HostOS;
  arch: string;
  cpuCount: number;
  home: string;
  /** Executable suffix (".exe" on Windows, "" elsewhere). */
  exeSuffix: string;
  /** PATH list separator (";" on Windows, ":" elsewhere). */
  pathSep: string;
  /** Default shell for dispatching conditional commands. */
  defaultShell: ShellKind;
}

/** Map Node/Bun's process.platform to our HostOS union. */
export function detectOS(): HostOS {
  switch (process.platform) {
    case "win32":
      return "windows";
    case "darwin":
      return "darwin";
    default:
      // linux, freebsd, etc. are treated as linux-like for tool purposes.
      return "linux";
  }
}

/** Default shell per OS (overridable via config.platform.shell). */
export function defaultShellFor(os: HostOS): ShellKind {
  switch (os) {
    case "windows":
      return "pwsh";
    case "darwin":
      return "zsh";
    default:
      return "bash";
  }
}

export function getHostInfo(): HostInfo {
  const os = detectOS();
  return {
    os,
    arch: process.arch,
    cpuCount: Math.max(1, cpus().length),
    home: homedir(),
    exeSuffix: os === "windows" ? ".exe" : "",
    pathSep: os === "windows" ? ";" : ":",
    defaultShell: defaultShellFor(os),
  };
}

export function isWindows(): boolean {
  return detectOS() === "windows";
}

export function isDarwin(): boolean {
  return detectOS() === "darwin";
}

export function isLinux(): boolean {
  return detectOS() === "linux";
}

/**
 * Recommended parallel job count for building tools from source. Leaves one
 * core free so an interactive machine stays responsive.
 */
export function recommendedJobs(): number {
  return Math.max(1, getHostInfo().cpuCount - 1);
}
