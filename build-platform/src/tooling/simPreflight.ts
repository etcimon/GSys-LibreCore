// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// simPreflight.ts — Host readiness for verify --sim / heavy regress before spawn.
// Surfaces Git-Bash preference, managed riscv-gcc/spike/verilator, and clear next steps.

import { existsSync } from "node:fs";
import { join } from "node:path";

import type { PlatformContext } from "../context.ts";
import { hasBinary } from "../platform/exec.ts";
import {
  resolveBashBinary,
  resolveRegressEngine,
  type ResolvedBash,
} from "../platform/shell.ts";
import { hasManagedTool } from "../tests/runner.ts";

export interface SimPreflightItem {
  id: string;
  ok: boolean;
  required: boolean;
  detail: string;
  hint?: string;
}

export interface SimPreflightReport {
  ok: boolean;
  /** True when required items pass; optional gaps only warn. */
  canAttemptSim: boolean;
  bash: ResolvedBash | null;
  items: SimPreflightItem[];
}

/**
 * Assess whether open-source simulation is likely to run (not a guarantee).
 * Does not install anything.
 */
export function assessSimPreflight(ctx: PlatformContext): SimPreflightReport {
  const items: SimPreflightItem[] = [];
  const bash = resolveBashBinary();

  if (!bash) {
    items.push({
      id: "bash",
      ok: false,
      required: true,
      detail: "bash not found",
      hint: "Install Git for Windows (preferred) or WSL; Cygwin is last-resort",
    });
  } else {
    const okFlavor = bash.flavor !== "cygwin";
    items.push({
      id: "bash",
      ok: true,
      required: true,
      detail: `${bash.flavor} → ${bash.path ?? bash.bin}`,
      hint: okFlavor
        ? undefined
        : "Cygwin bash detected; prefer Git for Windows (resolveBashBinary prefers Git when installed)",
    });
    if (bash.flavor === "cygwin") {
      items.push({
        id: "bash-flavor",
        ok: false,
        required: false,
        detail: "using Cygwin bash",
        hint: "Install Git for Windows so Git-Bash is preferred over Cygwin",
      });
    }
  }

  const riscv = hasManagedTool(ctx, "riscv-gcc");
  items.push({
    id: "riscv-gcc",
    ok: riscv,
    required: true,
    detail: riscv ? "managed or PATH" : "missing",
    hint: riscv ? undefined : "tools install riscv-gcc  |  tools install sim",
  });

  // Spike is optional for pure Verilator smoke; required for cosim-heavy suites
  const spike = hasManagedTool(ctx, "spike");
  items.push({
    id: "spike",
    ok: spike,
    required: false,
    detail: spike
      ? "managed or PATH"
      : "missing (needed for ISS cosim; smoke may use veri-testharness only)",
    hint: spike ? undefined : "tools install spike  # Linux/WSL",
  });

  const verilator = hasManagedTool(ctx, "verilator");
  items.push({
    id: "verilator",
    ok: verilator,
    required: true,
    detail: verilator ? "managed or PATH" : "missing",
    hint: verilator
      ? undefined
      : "tools install sim  |  OSS CAD suite under workspace/tooling",
  });

  // make is needed for verilate path — under Windows prefer WSL (GNU make).
  const engine = ctx.host.os === "windows" ? resolveRegressEngine() : "bash";
  const make = hasBinary("make");
  if (engine === "wsl") {
    items.push({
      id: "make",
      ok: true,
      required: true,
      detail: "delegated to WSL (GNU make expected inside distro)",
      hint: undefined,
    });
    items.push({
      id: "regress-engine",
      ok: true,
      required: false,
      detail: "wsl (default on Windows when available)",
      hint: "override with G6LC_REGRESS_ENGINE=git-bash if needed",
    });
  } else {
    items.push({
      id: "make",
      ok: make,
      required: true,
      detail: make ? "on PATH (must be GNU Make, not Chocolatey Windows shim)" : "missing",
      hint: make
        ? undefined
        : "install GNU make, or enable WSL (G6LC_REGRESS_ENGINE=wsl)",
    });
  }

  // Windows note: spike ELF may need WSL
  if (ctx.host.os === "windows" && spike) {
    const spikeElf = join(ctx.tools.spikeBin, "spike");
    if (existsSync(spikeElf) && !hasBinary("wsl") && engine !== "wsl") {
      items.push({
        id: "spike-wsl",
        ok: false,
        required: false,
        detail: "managed Spike is Linux ELF; WSL not detected",
        hint: "Enable WSL to run managed spike, or use Linux CI for ISS cosim",
      });
    }
  }

  const requiredFail = items.filter((i) => i.required && !i.ok);
  return {
    ok: requiredFail.length === 0,
    canAttemptSim: requiredFail.length === 0,
    bash,
    items,
  };
}

/** Human lines for logger. */
export function formatSimPreflightLines(r: SimPreflightReport): string[] {
  const lines: string[] = [];
  lines.push(
    r.canAttemptSim
      ? "sim preflight: READY to attempt (tools present)"
      : "sim preflight: NOT READY — fix required gaps before verify --sim",
  );
  for (const i of r.items) {
    const mark = i.ok ? "ok" : i.required ? "NEED" : "warn";
    let line = `  [${mark}] ${i.id}: ${i.detail}`;
    if (i.hint && !i.ok) line += `  → ${i.hint}`;
    lines.push(line);
  }
  return lines;
}
