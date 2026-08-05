// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// locations.ts — Canonical install locations for managed tools.
//
// Recipes install into these convention paths and the child-process env
// (see context.childEnv) points the CVA6 flow at the same paths. Keeping the
// convention in one place means a recipe and the environment never drift.

import { join } from "node:path";

import type { HostOS, ResolvedBuildConfig } from "../config/schema.ts";
import type { WorkspacePaths } from "../workspace/layout.ts";

export interface ToolLocations {
  /** RISC-V GCC toolchain prefix directory (contains bin/). */
  riscv: string;
  riscvBin: string;
  /** Verilator install dir, versioned so pins can coexist. */
  verilator: string;
  verilatorBin: string;
  /** Spike ISS install dir. */
  spike: string;
  spikeBin: string;
  /** Icarus Verilog install dir. */
  iverilog: string;
  iverilogBin: string;
  /** Device-tree-compiler install dir. */
  dtc: string;
  /** Python venv bin/Scripts dir. */
  pythonVenvBin: string;
}

/** Resolve managed tool locations from the workspace layout and config pins. */
export function toolLocations(
  paths: WorkspacePaths,
  config: ResolvedBuildConfig,
  os: HostOS,
): ToolLocations {
  const t = paths.tooling;
  const verilator = join(t, `verilator-${config.toolchain.versions.verilator}`);
  const iverilog = join(t, `iverilog-${config.toolchain.versions.iverilog}`);
  const spike = join(t, "spike");
  const riscv = join(t, "riscv");
  const dtc = join(t, "dtc");
  const pythonVenvBin = join(
    paths.pythonVenv,
    os === "windows" ? "Scripts" : "bin",
  );

  return {
    riscv,
    riscvBin: join(riscv, "bin"),
    verilator,
    verilatorBin: join(verilator, "bin"),
    spike,
    spikeBin: join(spike, "bin"),
    iverilog,
    iverilogBin: join(iverilog, "bin"),
    dtc,
    pythonVenvBin,
  };
}
