// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// wsl.ts — WSL interop for POSIX-only EDA tools on a Windows host.
//
// Several tools in this stack have no usable native Windows build: Spike
// (fesvr `addr_t` clashes under Cygwin), and Yosys/SymbiYosys plus their solver
// stack. The established pattern is to install a Linux binary into the managed
// workspace prefix and invoke it through `wsl`. This module holds the two
// primitives that pattern needs, so the installer and the gate engine share one
// implementation rather than each keeping a private copy.

import { run } from "./exec.ts";
import { hasBinary } from "./exec.ts";

/** True when a `wsl` launcher is on PATH (Windows hosts only). */
export function hasWsl(): boolean {
  return hasBinary("wsl");
}

/**
 * Convert a Windows path to its WSL `/mnt/...` form via `wslpath`, falling back
 * to a deterministic transform when `wslpath` is unavailable.
 */
export async function windowsPathToWsl(winPath: string): Promise<string> {
  const res = await run("wsl", ["-e", "wslpath", "-a", winPath], {
    allowFailure: true,
    stdio: "capture",
  });
  const out = res.stdout.trim().split(/\r?\n/).filter(Boolean).pop();
  if (res.ok && out && out.startsWith("/")) return out;

  // Fallback: C:\a\b -> /mnt/c/a/b
  const m = /^([A-Za-z]):[\\/](.*)$/.exec(winPath);
  if (!m) return winPath.replace(/\\/g, "/");
  const drive = (m[1] as string).toLowerCase();
  const rest = (m[2] as string).replace(/\\/g, "/");
  return `/mnt/${drive}/${rest}`;
}

/**
 * Wrap a POSIX command line so it executes inside WSL.
 *
 * Returns the argv for `run("wsl", argv)`. The command is passed to a login
 * shell so the distro's PATH and any user tool roots are present.
 */
export function wslCommand(posixCommand: string): string[] {
  return ["-e", "bash", "-lc", posixCommand];
}
