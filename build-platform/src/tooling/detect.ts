// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// detect.ts — Probe the host for tools and their versions.
//
// Used by `doctor` (host readiness) and `tools` (managed-tool status). Probing
// never installs anything; it only reports what is resolvable on PATH.

import { capture, which } from "../platform/exec.ts";

export type ToolCategory =
  | "core"
  | "package-manager"
  | "compiler"
  | "simulator"
  | "python"
  | "eda";

export interface ToolProbe {
  id: string;
  /** Executable name to resolve on PATH. */
  bin: string;
  /** Arguments that print a version (first line is captured). */
  versionArgs: string[];
  category: ToolCategory;
  /** Human note shown when the tool is missing. */
  hint?: string;
}

export interface ToolStatus {
  id: string;
  bin: string;
  category: ToolCategory;
  found: boolean;
  path: string | null;
  version: string | null;
  hint?: string;
}

/** Host prerequisites and open-source EDA tools the platform cares about. */
export const HOST_PROBES: ToolProbe[] = [
  { id: "git", bin: "git", versionArgs: ["--version"], category: "core" },
  { id: "bun", bin: "bun", versionArgs: ["--version"], category: "core" },
  { id: "bash", bin: "bash", versionArgs: ["--version"], category: "core", hint: "Git-Bash or WSL provides bash on Windows." },
  { id: "make", bin: "make", versionArgs: ["--version"], category: "core" },
  { id: "cmake", bin: "cmake", versionArgs: ["--version"], category: "core" },
  { id: "python", bin: "python3", versionArgs: ["--version"], category: "python", hint: "Python 3.8+ required for cva6.py and riscv-dv." },
  { id: "chocolatey", bin: "choco", versionArgs: ["--version"], category: "package-manager", hint: "Windows package manager." },
  { id: "winget", bin: "winget", versionArgs: ["--version"], category: "package-manager" },
  { id: "brew", bin: "brew", versionArgs: ["--version"], category: "package-manager", hint: "macOS package manager." },
  { id: "apt", bin: "apt-get", versionArgs: ["--version"], category: "package-manager", hint: "Debian/Ubuntu package manager." },
  { id: "dnf", bin: "dnf", versionArgs: ["--version"], category: "package-manager", hint: "Fedora/RHEL package manager." },
  { id: "scoop", bin: "scoop", versionArgs: ["--version"], category: "package-manager", hint: "Windows scoop package manager." },
  { id: "gcc", bin: "gcc", versionArgs: ["--version"], category: "compiler" },
  { id: "g++", bin: "g++", versionArgs: ["--version"], category: "compiler" },
  { id: "clang", bin: "clang", versionArgs: ["--version"], category: "compiler" },
  { id: "verilator", bin: "verilator", versionArgs: ["--version"], category: "simulator" },
  { id: "spike", bin: "spike", versionArgs: ["--help"], category: "simulator" },
  { id: "iverilog", bin: "iverilog", versionArgs: ["-V"], category: "simulator" },
  { id: "dtc", bin: "dtc", versionArgs: ["--version"], category: "core" },
  { id: "vcs", bin: "vcs", versionArgs: ["-full64", "-ID"], category: "eda", hint: "Synopsys VCS (licensed; detect-only)." },
  { id: "vsim", bin: "vsim", versionArgs: ["-version"], category: "eda", hint: "Siemens QuestaSim (licensed; detect-only)." },
  { id: "vivado", bin: "vivado", versionArgs: ["-version"], category: "eda", hint: "AMD/Xilinx Vivado (licensed; detect-only)." },
  { id: "openroad", bin: "openroad", versionArgs: ["-version"], category: "eda", hint: "OpenROAD (open PnR; detect-only; see architecture/build-platform-opensta-from-timing.md)." },
  { id: "opensta", bin: "sta", versionArgs: ["-version"], category: "eda", hint: "OpenSTA binary often named `sta` (S2 handoff soft-skip if missing)." },
];

function firstLine(text: string): string | null {
  const line = text.split(/\r?\n/).find((l) => l.trim().length > 0);
  return line ? line.trim() : null;
}

/** Probe a single tool. */
export async function probeTool(tool: ToolProbe): Promise<ToolStatus> {
  const path = which(tool.bin);
  if (!path) {
    return {
      id: tool.id,
      bin: tool.bin,
      category: tool.category,
      found: false,
      path: null,
      version: null,
      hint: tool.hint,
    };
  }
  try {
    const out = await capture(tool.bin, tool.versionArgs);
    return {
      id: tool.id,
      bin: tool.bin,
      category: tool.category,
      found: true,
      path,
      version: firstLine(out),
      hint: tool.hint,
    };
  } catch {
    // which() found a name but spawn failed (broken shim / ENOENT).
    return {
      id: tool.id,
      bin: tool.bin,
      category: tool.category,
      found: false,
      path,
      version: null,
      hint: tool.hint ?? "resolved on PATH but failed to execute",
    };
  }
}

/** Probe many tools concurrently. */
export function probeAll(tools: ToolProbe[] = HOST_PROBES): Promise<ToolStatus[]> {
  return Promise.all(tools.map(probeTool));
}
