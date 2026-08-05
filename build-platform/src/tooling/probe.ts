// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// probe.ts — Cross-platform capability probe for the build platform.
//
// Gathers host OS, build-platform identity, package managers (choco/brew/apt/
// dnf/…), host utils/libs, managed tooling install state, and a command→needs
// capability matrix. Used by `probe` CLI; never installs anything.

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

import type { PlatformContext } from "../context.ts";
import { capture, hasBinary } from "../platform/exec.ts";
import type { HostOS, PackageManager } from "../config/schema.ts";
import { PREREQS, detectPackageManager } from "./packageManagers.ts";
import { isSpikeInstalled } from "./recipes.ts";
import { listInstallProfiles } from "./installProfiles.ts";
import {
  HOST_PROBES,
  probeAll,
  probeTool,
  type ToolCategory,
  type ToolProbe,
  type ToolStatus,
} from "./detect.ts";

// ---------------------------------------------------------------------------
// Categories / tabs
// ---------------------------------------------------------------------------

export type ProbeCategoryId =
  | "host"
  | "platform"
  | "pkg"
  | "utils"
  | "tools"
  | "env"
  | "diag"
  | "commands"
  | "install";

export interface ProbeCategoryMeta {
  id: ProbeCategoryId;
  label: string;
  summary: string;
}

export const PROBE_CATEGORIES: ProbeCategoryMeta[] = [
  { id: "host", label: "Host", summary: "OS, arch, shell, Bun, WSL, path layout" },
  { id: "platform", label: "Platform", summary: "build-platform version, config, workspace" },
  { id: "pkg", label: "Pkg mgrs", summary: "choco / brew / apt / dnf / winget / scoop + prereqs" },
  { id: "utils", label: "Utils", summary: "Host compilers, make/cmake/dtc/flex/bison/python" },
  { id: "tools", label: "Tooling", summary: "Managed workspace/tooling install state + pins" },
  { id: "env", label: "Env", summary: "Child env vars + residual WSL/oss-cad tool roots" },
  {
    id: "diag",
    label: "Diag",
    summary: "Compartmentalized diagnostics (per-test Verilator configs)",
  },
  { id: "commands", label: "Commands", summary: "CLI capability matrix (what each command needs)" },
  { id: "install", label: "Install help", summary: "How to provision missing pieces" },
];

export function resolveProbeCategory(name: string): ProbeCategoryMeta | undefined {
  const key = name.trim().toLowerCase();
  const aliases: Record<string, ProbeCategoryId> = {
    host: "host",
    os: "host",
    platform: "platform",
    build: "platform",
    pkg: "pkg",
    package: "pkg",
    packages: "pkg",
    "package-manager": "pkg",
    "package-managers": "pkg",
    pm: "pkg",
    utils: "utils",
    util: "utils",
    libs: "utils",
    tools: "tools",
    tooling: "tools",
    managed: "tools",
    env: "env",
    environment: "env",
    residual: "env",
    diag: "diag",
    diagnostics: "diag",
    diagnostic: "diag",
    commands: "commands",
    cmds: "commands",
    caps: "commands",
    capabilities: "commands",
    install: "install",
    help: "install",
    fix: "install",
  };
  const id = aliases[key] ?? (PROBE_CATEGORIES.find((c) => c.id === key)?.id);
  return PROBE_CATEGORIES.find((c) => c.id === id);
}

/** Options for gatherProbeReport. */
export interface GatherProbeOptions {
  /** Scan full PREREQS list per manager (slower; default samples first 12). */
  deep?: boolean;
}

// ---------------------------------------------------------------------------
// Extra probes (beyond HOST_PROBES)
// ---------------------------------------------------------------------------

/** Package-manager binaries (all OS; missing ones simply show not found). */
export const PKG_MANAGER_PROBES: ToolProbe[] = [
  { id: "chocolatey", bin: "choco", versionArgs: ["--version"], category: "package-manager", hint: "Windows: https://chocolatey.org" },
  { id: "winget", bin: "winget", versionArgs: ["--version"], category: "package-manager", hint: "Windows App Installer" },
  { id: "scoop", bin: "scoop", versionArgs: ["--version"], category: "package-manager", hint: "Windows: https://scoop.sh" },
  { id: "brew", bin: "brew", versionArgs: ["--version"], category: "package-manager", hint: "macOS/Linux: https://brew.sh" },
  { id: "apt", bin: "apt-get", versionArgs: ["--version"], category: "package-manager", hint: "Debian/Ubuntu" },
  { id: "dnf", bin: "dnf", versionArgs: ["--version"], category: "package-manager", hint: "Fedora/RHEL" },
  { id: "pacman", bin: "pacman", versionArgs: ["--version"], category: "package-manager", hint: "Arch" },
  { id: "zypper", bin: "zypper", versionArgs: ["--version"], category: "package-manager", hint: "openSUSE" },
];

/** Host build utils / libraries commonly required by recipes. */
export const UTILS_PROBES: ToolProbe[] = [
  { id: "git", bin: "git", versionArgs: ["--version"], category: "core" },
  { id: "bun", bin: "bun", versionArgs: ["--version"], category: "core" },
  { id: "bash", bin: "bash", versionArgs: ["--version"], category: "core", hint: "Git-Bash or WSL on Windows" },
  { id: "pwsh", bin: "pwsh", versionArgs: ["--version"], category: "core" },
  { id: "make", bin: "make", versionArgs: ["--version"], category: "core" },
  { id: "cmake", bin: "cmake", versionArgs: ["--version"], category: "core" },
  { id: "gcc", bin: "gcc", versionArgs: ["--version"], category: "compiler" },
  { id: "g++", bin: "g++", versionArgs: ["--version"], category: "compiler" },
  { id: "clang", bin: "clang", versionArgs: ["--version"], category: "compiler" },
  { id: "python3", bin: "python3", versionArgs: ["--version"], category: "python", hint: "or python on Windows" },
  { id: "python", bin: "python", versionArgs: ["--version"], category: "python" },
  { id: "pip", bin: "pip3", versionArgs: ["--version"], category: "python" },
  { id: "dtc", bin: "dtc", versionArgs: ["--version"], category: "core", hint: "device-tree-compiler" },
  { id: "flex", bin: "flex", versionArgs: ["--version"], category: "core" },
  { id: "bison", bin: "bison", versionArgs: ["--version"], category: "core" },
  { id: "autoconf", bin: "autoconf", versionArgs: ["--version"], category: "core" },
  { id: "pkg-config", bin: "pkg-config", versionArgs: ["--version"], category: "core" },
  { id: "curl", bin: "curl", versionArgs: ["--version"], category: "core" },
  { id: "tar", bin: "tar", versionArgs: ["--version"], category: "core" },
  { id: "wsl", bin: "wsl", versionArgs: ["--version"], category: "core", hint: "Required on Windows for Spike / R3 cosim" },
  { id: "verilator", bin: "verilator", versionArgs: ["--version"], category: "simulator" },
  { id: "spike", bin: "spike", versionArgs: ["--help"], category: "simulator" },
  { id: "iverilog", bin: "iverilog", versionArgs: ["-V"], category: "simulator" },
  { id: "yosys", bin: "yosys", versionArgs: ["-V"], category: "eda" },
  { id: "slang", bin: "slang", versionArgs: ["--version"], category: "eda" },
  { id: "sby", bin: "sby", versionArgs: ["--version"], category: "eda", hint: "SymbiYosys formal" },
];

// ---------------------------------------------------------------------------
// Report model
// ---------------------------------------------------------------------------

export interface ManagedToolState {
  id: string;
  pin: string;
  installed: boolean;
  path: string;
  versionHint: string | null;
  installHint: string;
}

export interface PkgManagerState {
  id: string;
  bin: string;
  found: boolean;
  path: string | null;
  version: string | null;
  /** Best-effort count of CVA6 prereq packages detected as installed. */
  prereqsKnown: number;
  prereqsPresent: number;
  prereqMissing: string[];
  hint?: string;
}

export interface CommandCapability {
  command: string;
  summary: string;
  /** Capability ids that should be present (soft unless required). */
  needs: string[];
  /** Capability ids that block the command when missing. */
  required: string[];
  /** tools install / setup hint when missing. */
  install: string;
  /** ok | partial | blocked */
  status: "ok" | "partial" | "blocked";
  missingRequired: string[];
  missingOptional: string[];
}

export interface InstallAction {
  title: string;
  commands: string[];
  note?: string;
  /** Related missing capability ids. */
  covers: string[];
}

export interface ResidualToolRoot {
  id: string;
  path: string;
  present: boolean;
  detail: string | null;
}

export interface EnvVarState {
  name: string;
  value: string | null;
  /** How the build-platform uses it. */
  role: string;
}

export interface ProbeReport {
  generatedAt: string;
  deep: boolean;
  host: {
    os: HostOS;
    arch: string;
    cpuCount: number;
    home: string;
    exeSuffix: string;
    pathSep: string;
    defaultShell: string;
    bunVersion: string | null;
    nodeLike: string;
    wsl: boolean;
    cygwinHint: boolean;
  };
  platform: {
    name: string;
    version: string;
    repoRoot: string;
    configPath: string | null;
    overlayPath: string | null;
    workspaceRoot: string;
    workspaceExists: boolean;
    coreConfig: string;
    xlen: number;
    frequencyMHz: number;
    process: string;
    defaultSim: string;
  };
  packageManagers: PkgManagerState[];
  activePackageManager: PackageManager | null;
  utils: ToolStatus[];
  hostProbes: ToolStatus[];
  managedTools: ManagedToolState[];
  installProfiles: { id: string; summary: string; recipeIds: string[] }[];
  /** Env vars relevant to CVA6 child processes + residual tool roots. */
  envVars: EnvVarState[];
  residualRoots: ResidualToolRoot[];
  /** Compartmentalized diagnostic readiness (config.diagnostics). */
  diagnostics: {
    id: string;
    compartment: string;
    kind: string;
    ready: boolean;
    note: string;
    optional: boolean;
    verilatorTarget?: string;
  }[];
  commands: CommandCapability[];
  installActions: InstallAction[];
  /** Missing counts per category (for tab badges). */
  missingByCategory: Record<ProbeCategoryId, number>;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function firstLine(text: string): string | null {
  const line = text.split(/\r?\n/).find((l) => l.trim().length > 0);
  return line ? line.trim().slice(0, 120) : null;
}

async function tryVersion(bin: string, args: string[]): Promise<string | null> {
  if (!hasBinary(bin)) return null;
  const out = await capture(bin, args);
  return firstLine(out);
}

async function probeManagedBinaryVersion(binPath: string, args: string[]): Promise<string | null> {
  if (!existsSync(binPath)) return null;
  // Prefer running by absolute path when possible
  const out = await capture(binPath, args);
  return firstLine(out);
}

/**
 * Best-effort: is package `name` installed according to the manager?
 * Returns null when the query is unsupported / fails.
 */
async function isPkgInstalled(manager: PackageManager, name: string): Promise<boolean | null> {
  try {
    switch (manager) {
      case "apt": {
        // dpkg-query is more reliable than apt-cache for "installed?"
        if (hasBinary("dpkg-query")) {
          const out = await capture("dpkg-query", ["-W", "-f=${Status}", name]);
          return out.includes("install ok installed");
        }
        return null;
      }
      case "dnf": {
        const out = await capture("rpm", ["-q", name]);
        return out.length > 0 && !out.includes("not installed") && !out.includes("is not");
      }
      case "brew": {
        // `brew list --versions name` prints nothing if missing
        const out = await capture("brew", ["list", "--versions", name]);
        return out.trim().length > 0;
      }
      case "pacman": {
        const out = await capture("pacman", ["-Q", name]);
        return out.trim().length > 0 && !out.toLowerCase().includes("was not found");
      }
      case "chocolatey": {
        const out = await capture("choco", ["list", "--local-only", "--exact", name, "-r"]);
        return out.trim().length > 0;
      }
      default:
        return null;
    }
  } catch {
    return null;
  }
}

async function probePkgManagerState(
  probe: ToolProbe,
  deep: boolean,
): Promise<PkgManagerState> {
  const status = await probeTool(probe);
  // Map probe ids to PackageManager enum keys used by PREREQS
  const pmKey: PackageManager | null =
    probe.id === "apt"
      ? "apt"
      : probe.id === "chocolatey"
        ? "chocolatey"
        : (["dnf", "brew", "pacman", "winget", "scoop", "zypper"] as string[]).includes(probe.id)
          ? (probe.id as PackageManager)
          : null;

  let prereqsKnown = 0;
  let prereqsPresent = 0;
  const prereqMissing: string[] = [];

  if (status.found && pmKey && PREREQS[pmKey]) {
    const names = PREREQS[pmKey]!;
    const sample = deep ? names : names.slice(0, 12);
    prereqsKnown = sample.length;
    for (const n of sample) {
      const inst = await isPkgInstalled(pmKey, n);
      if (inst === true) prereqsPresent++;
      else if (inst === false) prereqMissing.push(n);
      // null → skip counting as missing
    }
  }

  return {
    id: probe.id,
    bin: probe.bin,
    found: status.found,
    path: status.path,
    version: status.version,
    prereqsKnown,
    prereqsPresent,
    prereqMissing,
    hint: probe.hint,
  };
}

/** Residual tool roots (WSL home, oss-cad-suite) used when PATH lacks tools. */
async function probeResidualRoots(
  ctx: PlatformContext,
): Promise<ResidualToolRoot[]> {
  const { repoRoot, tools, host } = ctx;
  const roots: ResidualToolRoot[] = [];

  const candidates: { id: string; path: string; check: string; detailCmd?: string[] }[] = [
    {
      id: "managed-spike",
      path: tools.spike,
      check: join(tools.spikeBin, "spike"),
    },
    {
      id: "managed-riscv",
      path: tools.riscv,
      check: join(tools.riscvBin, `${ctx.config.toolchain.riscvGcc.toolPrefix ?? "riscv-none-elf-"}gcc${host.exeSuffix}`),
    },
    {
      id: "managed-verilator",
      path: tools.verilator,
      check: join(tools.verilatorBin, "verilator"),
    },
    {
      id: "workspace-oss-cad",
      path: join(repoRoot, "build-platform/workspace/tooling/oss-cad-suite"),
      check: join(repoRoot, "build-platform/workspace/tooling/oss-cad-suite/bin/verilator"),
    },
    {
      id: "smt2-fw_payload",
      path: join(repoRoot, "build-platform/workspace/smt2-linux"),
      check: join(repoRoot, "build-platform/workspace/smt2-linux/fw_payload.elf"),
    },
  ];

  for (const c of candidates) {
    const present = existsSync(c.check);
    roots.push({
      id: c.id,
      path: c.path,
      present,
      detail: present ? c.check : null,
    });
  }

  // WSL residual (best-effort; only when wsl on PATH)
  if (hasBinary("wsl")) {
    const wslChecks: { id: string; shell: string }[] = [
      { id: "wsl-oss-cad-verilator", shell: "test -x $HOME/tools/oss-cad-suite/bin/verilator && $HOME/tools/oss-cad-suite/bin/verilator --version | head -1" },
      { id: "wsl-mamba-make", shell: "test -x $HOME/tools/mamba/envs/build/bin/make && $HOME/tools/mamba/envs/build/bin/make --version | head -1" },
      { id: "wsl-home-spike", shell: "test -x $HOME/tools/spike/bin/spike && $HOME/tools/spike/bin/spike --help 2>&1 | head -1" },
      { id: "wsl-home-riscv", shell: "test -x $HOME/tools/riscv/bin/riscv-none-elf-gcc && $HOME/tools/riscv/bin/riscv-none-elf-gcc --version | head -1" },
    ];
    for (const w of wslChecks) {
      const out = await capture("wsl", ["-e", "bash", "-lc", w.shell]);
      const present = out.trim().length > 0 && !out.toLowerCase().includes("no such");
      roots.push({
        id: w.id,
        path: `wsl:${w.id}`,
        present,
        detail: present ? firstLine(out) : null,
      });
    }
  }

  return roots;
}

function collectEnvVars(ctx: PlatformContext): EnvVarState[] {
  const names: { name: string; role: string }[] = [
    { name: "PATH", role: "Host PATH (managed bins prepended by childEnv)" },
    { name: "RISCV", role: "RISC-V toolchain root (setup-env / OpenSBI)" },
    { name: "CVA6_REPO_DIR", role: "Repo root for Makefile / cva6.py" },
    { name: "SPIKE_INSTALL_DIR", role: "Spike prefix (bin/spike)" },
    { name: "SPIKE_PATH", role: "Spike bin dir for cva6.yaml" },
    { name: "VERILATOR_ROOT", role: "Verilator share root (VPI headers)" },
    { name: "VERILATOR_INSTALL_DIR", role: "Managed Verilator install" },
    { name: "CVA6_LINUX_PAYLOAD", role: "R3 guest ELF for smt-linux-rootfs" },
    { name: "CROSS_COMPILE", role: "OpenSBI / payload cross prefix" },
    { name: "NUM_JOBS", role: "Parallel make jobs" },
    { name: "TARGET_CFG", role: "Active CVA6 config package" },
    { name: "DV_TARGET", role: "cva6.py target override" },
    { name: "DV_SIMULATORS", role: "cva6.py ISS list" },
    { name: "CVA6_REQUIRE_R3_SIM", role: "Hard-fail R3 cosim when set=1" },
    { name: "WSL_DISTRO_NAME", role: "Set when running inside WSL" },
  ];
  return names.map(({ name, role }) => ({
    name,
    value: process.env[name] ?? null,
    role,
  }));
}

function capabilityPresent(
  id: string,
  ctx: PlatformContext,
  utils: ToolStatus[],
  managed: ManagedToolState[],
  residual: ResidualToolRoot[] = [],
): boolean {
  const u = (name: string) => utils.find((x) => x.id === name)?.found ?? false;
  const m = (name: string) => managed.find((x) => x.id === name)?.installed ?? false;
  const r = (name: string) => residual.find((x) => x.id === name)?.present ?? false;

  switch (id) {
    case "bun":
      return u("bun") || hasBinary("bun");
    case "bash":
      return u("bash");
    case "pwsh":
      return u("pwsh") || hasBinary("powershell");
    case "make":
      return u("make") || r("wsl-mamba-make");
    case "git":
      return u("git");
    case "python":
      return u("python3") || u("python");
    case "gcc":
      return u("gcc") || u("g++") || u("clang");
    case "g++":
      return u("g++") || u("gcc");
    case "dtc":
      return u("dtc");
    case "wsl":
      return u("wsl") || ctx.host.os !== "windows";
    case "verilator":
      return (
        m("verilator") ||
        u("verilator") ||
        r("workspace-oss-cad") ||
        r("wsl-oss-cad-verilator")
      );
    case "spike":
      return m("spike") || u("spike") || r("wsl-home-spike") || r("managed-spike");
    case "riscv-gcc":
      return m("riscv-gcc") || r("wsl-home-riscv") || r("managed-riscv");
    case "iverilog":
      return m("iverilog") || u("iverilog");
    case "opensbi-smt2":
      return m("opensbi-smt2") || r("smt2-fw_payload");
    case "yosys":
      return u("yosys");
    case "sby":
      return u("sby");
    case "slang":
      return u("slang");
    case "workspace":
      return existsSync(ctx.paths.root);
    case "linux-or-wsl":
      return ctx.host.os !== "windows" || u("wsl");
    default:
      return u(id) || m(id);
  }
}

function buildCommandMatrix(
  ctx: PlatformContext,
  utils: ToolStatus[],
  managed: ManagedToolState[],
  residual: ResidualToolRoot[],
): CommandCapability[] {
  const defs: Omit<CommandCapability, "status" | "missingRequired" | "missingOptional">[] = [
    {
      command: "status",
      summary: "One-glance SoC + provisioning snapshot",
      needs: ["bun"],
      required: ["bun"],
      install: "Install Bun: https://bun.sh",
    },
    {
      command: "doctor",
      summary: "Quick host readiness (PATH probes)",
      needs: ["bun", "git", "bash", "python"],
      required: ["bun"],
      install: "probe install  |  setup --install",
    },
    {
      command: "probe",
      summary: "In-depth capability boxes (this command)",
      needs: ["bun"],
      required: ["bun"],
      install: "Install Bun: https://bun.sh",
    },
    {
      command: "diag run",
      summary: "Compartmentalized diagnostics (per-test Verilator configs)",
      needs: ["bun", "verilator"],
      required: ["bun"],
      install: "diag list  |  tools install sim  |  verify.suite OSS CAD under workspace/tooling",
    },
    {
      command: "timings doctor",
      summary: "Timings/STA readiness + FO4 model retune checklist",
      needs: ["bun"],
      required: ["bun"],
      install: "timings doctor  |  timings lab-run",
    },
    {
      command: "timings lab-run",
      summary: "sta_smoke fixture → FO4 golden → sta-handoff (S0–S2 soft)",
      needs: ["bun"],
      required: ["bun"],
      install: "timings lab-run --try-tools  # optional yosys/opensta/liberty",
    },
    {
      command: "timings sta-handoff",
      summary: "OpenSTA handoff from --from-timing package",
      needs: ["bun"],
      required: ["bun"],
      install: "timings sta-handoff --from-timing <pkg> --try-tools",
    },
    {
      command: "verify --sim",
      summary: "Regression sim stage (bash + riscv-gcc + verilator)",
      needs: ["bun", "bash", "riscv-gcc", "verilator", "make"],
      required: ["bun", "bash"],
      install: "tools install sim  |  prefer Git-Bash over Cygwin on Windows",
    },
    {
      command: "setup",
      summary: "Workspace + optional toolchain install",
      needs: ["bun", "git"],
      required: ["bun", "git"],
      install: "tools install sim|dual-hart|all",
    },
    {
      command: "setup --install",
      summary: "Full provision (prereqs + venv + profile)",
      needs: ["bun", "git", "python"],
      required: ["bun", "git"],
      install: "setup --install --profile sim|dual-hart [--allow-system-install]",
    },
    {
      command: "tools install sim",
      summary: "riscv-gcc + verilator + spike + iverilog",
      needs: ["bun", "bash", "linux-or-wsl", "make", "g++", "dtc"],
      required: ["bun"],
      install: "tools install sim   # Spike via WSL on Windows",
    },
    {
      command: "tools install dual-hart",
      summary: "riscv-gcc + OpenSBI SMT2 fw_payload",
      needs: ["bun", "make", "python"],
      required: ["bun"],
      install: "tools install dual-hart",
    },
    {
      command: "tools install spike",
      summary: "Spike ISS (Linux native / Windows WSL)",
      needs: ["linux-or-wsl", "make", "g++", "dtc"],
      required: ["linux-or-wsl"],
      install: "tools install spike",
    },
    {
      command: "tools install opensbi",
      summary: "OpenSBI SMT2 only",
      needs: ["riscv-gcc", "make"],
      required: ["bun"],
      install: "tools install dual-hart  # or opensbi after riscv-gcc",
    },
    {
      command: "tools install all",
      summary: "sim + dual-hart full residual stack",
      needs: ["bun", "bash", "linux-or-wsl", "make", "python"],
      required: ["bun"],
      install: "tools install all",
    },
    {
      command: "verify --lint",
      summary: "Per-change lint gate (all targets)",
      needs: ["bun", "verilator"],
      required: ["bun"],
      install: "tools install sim  |  setup --install --profile sim",
    },
    {
      command: "verify --formal",
      summary: "SymbiYosys formal tasks",
      needs: ["bun", "sby", "yosys"],
      required: ["bun"],
      install: "Install SymbiYosys/yosys (oss-cad-suite) or PATH tools",
    },
    {
      command: "verify --sim",
      summary: "Configured regression suites",
      needs: ["bun", "bash", "riscv-gcc", "verilator"],
      required: ["bun"],
      install: "tools install all",
    },
    {
      command: "verify --synth",
      summary: "Yosys synthesis smoke",
      needs: ["bun", "yosys"],
      required: ["bun"],
      install: "Install yosys (oss-cad-suite) on PATH",
    },
    {
      command: "test --open-source",
      summary: "Open-source verif/regress suites",
      needs: ["bun", "bash", "python", "riscv-gcc", "verilator", "spike"],
      required: ["bun", "bash"],
      install: "tools install sim && setup",
    },
    {
      command: "test dual-hart-ci",
      summary: "SMT2 dual-hart CI gate",
      needs: ["bun", "riscv-gcc"],
      required: ["bun"],
      install: "tools install dual-hart",
    },
    {
      command: "test smt-linux-rootfs",
      summary: "R0–R3a firmware + optional R3 cosim",
      needs: ["bun", "riscv-gcc", "opensbi-smt2", "linux-or-wsl", "verilator"],
      required: ["bun"],
      install: "tools install all  # R3: WSL + oss-cad Verilator (probe env)",
    },
    {
      command: "test smt-linux-boot-path",
      summary: "DTS/RTL dual-hart boot-path gate",
      needs: ["bun"],
      required: ["bun"],
      install: "setup (lint target g6lc64_smt2)",
    },
    {
      command: "r3-cosim (WSL)",
      summary: "Verilator RTL boot of fw_payload.elf",
      needs: ["linux-or-wsl", "opensbi-smt2", "verilator", "make", "g++"],
      required: ["linux-or-wsl", "opensbi-smt2"],
      install: "wsl -e bash verif/regress/smt-linux-r3-cosim.sh",
    },
    {
      command: "build",
      summary: "Makefile-driven RTL / sim build",
      needs: ["bun", "make", "bash"],
      required: ["bun", "make"],
      install: "Host make (choco/brew/apt) + tools install sim",
    },
    {
      command: "vendor",
      summary: "Uncore controller/PHY catalog sync",
      needs: ["bun", "git"],
      required: ["bun", "git"],
      install: "Install git on PATH",
    },
    {
      command: "mb",
      summary: "Motherboard / board flow (SKiDL)",
      needs: ["bun", "python"],
      required: ["bun"],
      install: "python3 + pip; mb uses corev-mb/",
    },
    {
      command: "tech",
      summary: "Technology / PDK optimization pass",
      needs: ["bun"],
      required: ["bun"],
      install: "tech status  (opt-in; needs tech-spec + PDK)",
    },
    {
      command: "config",
      summary: "Dump resolved .config.ts",
      needs: ["bun"],
      required: ["bun"],
      install: "Install Bun",
    },
    {
      command: "clean",
      summary: "Remove workspace build/tooling outputs",
      needs: ["bun"],
      required: ["bun"],
      install: "Install Bun",
    },
  ];

  return defs.map((d) => {
    const missingRequired = d.required.filter(
      (c) => !capabilityPresent(c, ctx, utils, managed, residual),
    );
    const missingOptional = d.needs.filter(
      (c) =>
        !d.required.includes(c) && !capabilityPresent(c, ctx, utils, managed, residual),
    );
    let status: CommandCapability["status"] = "ok";
    if (missingRequired.length) status = "blocked";
    else if (missingOptional.length) status = "partial";
    return { ...d, status, missingRequired, missingOptional };
  });
}

function buildInstallActions(
  ctx: PlatformContext,
  utils: ToolStatus[],
  managed: ManagedToolState[],
  pkg: PkgManagerState[],
  residual: ResidualToolRoot[],
  commands: CommandCapability[],
): InstallAction[] {
  const actions: InstallAction[] = [];
  const os = ctx.host.os;
  const active = detectPackageManager(os);
  const missingUtils = utils.filter((u) => !u.found).map((u) => u.id);
  const missingManaged = managed.filter((m) => !m.installed);
  const blocked = commands.filter((c) => c.status === "blocked");

  if (missingManaged.length) {
    const ids = new Set(missingManaged.map((m) => m.id));
    const cmds = ["bun run src/cli/index.ts tools install"];
    if (ids.has("riscv-gcc") || ids.has("verilator") || ids.has("spike") || ids.has("iverilog")) {
      cmds.push("bun run src/cli/index.ts tools install sim");
    }
    if (ids.has("opensbi-smt2") || ids.has("riscv-gcc")) {
      cmds.push("bun run src/cli/index.ts tools install dual-hart");
    }
    if (ids.has("spike")) cmds.push("bun run src/cli/index.ts tools install spike");
    if (ids.size >= 3) cmds.push("bun run src/cli/index.ts tools install all");
    if (ids.has("python-venv")) {
      cmds.push("bun run src/cli/index.ts setup --install --profile sim");
    }
    actions.push({
      title: "Managed toolchain (workspace/tooling)",
      commands: cmds,
      note: `Missing: ${missingManaged.map((m) => m.id).join(", ")}`,
      covers: missingManaged.map((m) => m.id),
    });
  }

  // Prefer installing only packages the active manager reports missing
  const activeState = pkg.find((p) => p.id === active || (active === "chocolatey" && p.id === "chocolatey") || (active === "apt" && p.id === "apt"));
  if (active && PREREQS[active]?.length) {
    const want =
      activeState && activeState.prereqMissing.length
        ? activeState.prereqMissing
        : // host utils missing that map to common package names
          ["make", "cmake", "dtc", "python3", "g++", "flex", "bison"].filter((n) =>
            missingUtils.includes(n) || (n === "python3" && missingUtils.includes("python")),
          );
    if (want.length || missingUtils.includes("dtc") || missingUtils.includes("autoconf")) {
      const list = (want.length ? want : PREREQS[active]!.slice(0, 8)).join(" ");
      const installCmd =
        active === "apt"
          ? `sudo apt-get install -y ${list}`
          : active === "dnf"
            ? `sudo dnf install -y ${list}`
            : active === "brew"
              ? `brew install ${list}`
              : active === "chocolatey"
                ? `choco install -y ${list}`
                : `${active} install ${list}`;
      actions.push({
        title: `Host prerequisites via ${active}`,
        commands: [
          installCmd,
          "bun run src/cli/index.ts setup --install --allow-system-install",
          "bun run src/cli/index.ts probe pkg --deep   # re-check prereqs",
        ],
        note:
          activeState && activeState.prereqMissing.length
            ? `Missing packages (queried): ${activeState.prereqMissing.join(", ")}`
            : `Detected manager: ${active}. Use probe pkg --deep for full PREREQS scan.`,
        covers: want.length ? want : ["make", "cmake", "dtc"],
      });
    }
  } else if (pkg.every((p) => !p.found)) {
    actions.push({
      title: "Install a package manager",
      commands:
        os === "windows"
          ? [
              "winget install Git.Git",
              "https://chocolatey.org/install  # then: choco install make cmake python3",
              "wsl --install   # Spike + R3 cosim",
            ]
          : os === "darwin"
            ? ["/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""]
            : ["sudo apt-get update && sudo apt-get install -y build-essential cmake dtc python3"],
      note: "No supported package manager found on PATH.",
      covers: missingUtils,
    });
  }

  if (os === "windows" && !utils.find((u) => u.id === "wsl")?.found) {
    actions.push({
      title: "WSL (Spike build + R3 Verilator cosim)",
      commands: [
        "wsl --install",
        "bun run src/cli/index.ts tools install spike",
        "wsl -e bash verif/regress/smt-linux-r3-cosim.sh",
      ],
      note: "Native Windows/Cygwin cannot build Spike (addr_t). R3 cosim needs Linux paths.",
      covers: ["wsl", "spike", "linux-or-wsl"],
    });
  } else if (
    os === "windows" &&
    utils.find((u) => u.id === "wsl")?.found &&
    !residual.find((r) => r.id === "wsl-oss-cad-verilator")?.present &&
    !managed.find((m) => m.id === "verilator")?.installed
  ) {
    actions.push({
      title: "WSL Verilator for R3 cosim",
      commands: [
        "wsl -e bash -lc ' # install oss-cad-suite or: sudo apt install verilator'",
        "wsl -e bash verif/regress/smt-linux-r3-cosim.sh",
        "probe env   # shows residual WSL tool roots",
      ],
      note: "WSL is present but no residual Verilator detected under ~/tools/oss-cad-suite.",
      covers: ["verilator"],
    });
  }

  if (blocked.length) {
    actions.push({
      title: "Blocked commands (required caps missing)",
      commands: blocked.map((c) => `${c.command}  →  ${c.install}`),
      note: blocked.map((c) => `${c.command}: need ${c.missingRequired.join(",")}`).join("; "),
      covers: [...new Set(blocked.flatMap((c) => c.missingRequired))],
    });
  }

  if (!utils.find((u) => u.id === "bash")?.found && os === "windows") {
    actions.push({
      title: "bash on Windows",
      commands: ["winget install Git.Git  # Git Bash", "or enable WSL"],
      covers: ["bash"],
    });
  }

  if (!hasBinary("bun")) {
    actions.push({
      title: "Bun runtime",
      commands: [
        "curl -fsSL https://bun.sh/install | bash",
        "powershell -c \"irm bun.sh/install.ps1 | iex\"",
        "./build.sh  /  .\\build.ps1   # wrappers bootstrap Bun",
      ],
      covers: ["bun"],
    });
  }

  actions.push({
    title: "Re-probe after installs",
    commands: [
      "bun run src/cli/index.ts probe",
      "bun run src/cli/index.ts probe tools",
      "bun run src/cli/index.ts probe install",
      "bun run src/cli/index.ts doctor",
    ],
    covers: [],
  });

  return actions;
}

// ---------------------------------------------------------------------------
// Main gather
// ---------------------------------------------------------------------------

export async function gatherProbeReport(
  ctx: PlatformContext,
  options: GatherProbeOptions = {},
): Promise<ProbeReport> {
  const deep = options.deep ?? false;
  const { host, config, paths, tools, repoRoot } = ctx;

  let pkgJson = { name: "@cva6/build-platform", version: "0.0.0" };
  try {
    const raw = readFileSync(join(repoRoot, "build-platform/package.json"), "utf8");
    pkgJson = JSON.parse(raw) as typeof pkgJson;
  } catch {
    /* defaults */
  }

  const [hostProbes, utils, pkgStates, bunVersion, residualRoots] = await Promise.all([
    probeAll(HOST_PROBES),
    Promise.all(UTILS_PROBES.map(probeTool)),
    Promise.all(PKG_MANAGER_PROBES.map((p) => probePkgManagerState(p, deep))),
    tryVersion("bun", ["--version"]),
    probeResidualRoots(ctx),
  ]);

  // Managed tools
  const gccName = `${config.toolchain.riscvGcc.toolPrefix ?? "riscv-none-elf-"}gcc${host.exeSuffix}`;
  const riscvInstalled = existsSync(join(tools.riscvBin, gccName));
  const verilatorInstalled =
    existsSync(join(tools.verilatorBin, "verilator")) ||
    existsSync(join(tools.verilatorBin, `verilator${host.exeSuffix}`));
  const spikeInstalled = isSpikeInstalled(tools.spikeBin, host.exeSuffix);
  const iverilogInstalled =
    existsSync(join(tools.iverilogBin, "iverilog")) ||
    existsSync(join(tools.iverilogBin, `iverilog${host.exeSuffix}`));
  const pyInstalled =
    existsSync(join(tools.pythonVenvBin, host.os === "windows" ? "python.exe" : "python3")) ||
    existsSync(join(tools.pythonVenvBin, "python"));
  const opensbiInstalled = existsSync(
    join(repoRoot, "build-platform/workspace/smt2-linux/fw_payload.elf"),
  );

  const managedTools: ManagedToolState[] = [
    {
      id: "riscv-gcc",
      pin: config.toolchain.riscvGcc.version,
      installed: riscvInstalled,
      path: tools.riscvBin,
      versionHint: riscvInstalled
        ? await probeManagedBinaryVersion(join(tools.riscvBin, gccName), ["--version"])
        : null,
      installHint: "tools install riscv-gcc  |  tools install dual-hart",
    },
    {
      id: "verilator",
      pin: config.toolchain.versions.verilator,
      installed: verilatorInstalled,
      path: tools.verilatorBin,
      versionHint: verilatorInstalled
        ? await probeManagedBinaryVersion(join(tools.verilatorBin, "verilator"), ["--version"])
        : null,
      installHint: "tools install verilator  |  tools install sim",
    },
    {
      id: "spike",
      pin: config.toolchain.versions.spike,
      installed: spikeInstalled,
      path: tools.spikeBin,
      versionHint: spikeInstalled
        ? await probeManagedBinaryVersion(join(tools.spikeBin, "spike"), ["--help"])
        : null,
      installHint: "tools install spike  # Linux native / Windows via WSL",
    },
    {
      id: "iverilog",
      pin: config.toolchain.versions.iverilog,
      installed: iverilogInstalled || hasBinary("iverilog"),
      path: tools.iverilogBin,
      versionHint: await tryVersion("iverilog", ["-V"]),
      installHint: "tools install iverilog  |  OS package manager (iverilog)",
    },
    {
      id: "python-venv",
      pin: `>= ${config.toolchain.python.minVersion}`,
      installed: pyInstalled,
      path: tools.pythonVenvBin,
      versionHint: null,
      installHint: "setup  (creates workspace/tooling/python-venv)",
    },
    {
      id: "opensbi-smt2",
      pin: "v1.5/generic",
      installed: opensbiInstalled,
      path: join(repoRoot, "build-platform/workspace/smt2-linux"),
      versionHint: opensbiInstalled ? "fw_payload.elf present" : null,
      installHint: "tools install dual-hart  |  tools install opensbi",
    },
  ];

  const commands = buildCommandMatrix(ctx, utils, managedTools, residualRoots);
  const installActions = buildInstallActions(
    ctx,
    utils,
    managedTools,
    pkgStates,
    residualRoots,
    commands,
  );
  const profiles = listInstallProfiles().map((p) => ({
    id: p.id,
    summary: p.summary,
    recipeIds: p.recipeIds,
  }));
  const envVars = collectEnvVars(ctx);

  // Lazy import to avoid circular load issues at module init
  const { diagnosticReadiness } = await import("./diagnostics.ts");
  const provisionalReport: ProbeReport = {
    generatedAt: new Date().toISOString(),
    deep,
    host: {
      os: host.os,
      arch: host.arch,
      cpuCount: host.cpuCount,
      home: host.home || homedir(),
      exeSuffix: host.exeSuffix,
      pathSep: host.pathSep,
      defaultShell: host.defaultShell,
      bunVersion,
      nodeLike:
        typeof process.versions.bun === "string"
          ? `bun ${process.versions.bun}`
          : `node ${process.version}`,
      wsl: hasBinary("wsl"),
      cygwinHint: hasBinary("cygpath") || Boolean(process.env.CYGWIN),
    },
    platform: {
      name: pkgJson.name,
      version: pkgJson.version,
      repoRoot,
      configPath: ctx.configPath,
      overlayPath: ctx.overlayPath,
      workspaceRoot: paths.root,
      workspaceExists: existsSync(paths.root),
      coreConfig: config.soc.coreConfig,
      xlen: config.soc.xlen,
      frequencyMHz: config.soc.targetFrequencyMHz,
      process: config.soc.process,
      defaultSim: String(config.simulation.default),
    },
    packageManagers: pkgStates,
    activePackageManager: detectPackageManager(host.os),
    utils,
    hostProbes,
    managedTools,
    installProfiles: profiles,
    envVars,
    residualRoots,
    diagnostics: [],
    commands,
    installActions,
    missingByCategory: {
      host: 0,
      platform: 0,
      pkg: 0,
      utils: 0,
      tools: 0,
      env: 0,
      diag: 0,
      commands: 0,
      install: 0,
    },
  };
  const diagnostics = diagnosticReadiness(ctx, provisionalReport);

  const missingByCategory: Record<ProbeCategoryId, number> = {
    host: 0,
    platform: existsSync(paths.root) ? 0 : 1,
    pkg: pkgStates.filter((p) => !p.found).length > 0 && pkgStates.every((p) => !p.found) ? 1 : 0,
    utils: utils.filter((u) =>
      ["git", "bash", "make", "python3", "python", "g++", "dtc"].includes(u.id) ? !u.found : false,
    ).length,
    tools: managedTools.filter((m) => !m.installed).length,
    env: residualRoots.filter((r) => !r.present && r.id.startsWith("managed-")).length,
    diag: diagnostics.filter((d) => !d.ready && !d.optional).length,
    commands: commands.filter((c) => c.status === "blocked").length,
    install: 0,
  };
  // host: count critical PATH misses
  missingByCategory.host = ["bun", "git"].filter((id) => !utils.find((u) => u.id === id)?.found && !hasBinary(id)).length;
  if (host.os === "windows" && !utils.find((u) => u.id === "wsl")?.found) missingByCategory.host++;
  missingByCategory.install = installActions.filter((a) => a.covers.length > 0).length;

  return {
    generatedAt: new Date().toISOString(),
    deep,
    host: {
      os: host.os,
      arch: host.arch,
      cpuCount: host.cpuCount,
      home: host.home || homedir(),
      exeSuffix: host.exeSuffix,
      pathSep: host.pathSep,
      defaultShell: host.defaultShell,
      bunVersion,
      nodeLike: typeof process.versions.bun === "string" ? `bun ${process.versions.bun}` : `node ${process.version}`,
      wsl: hasBinary("wsl"),
      cygwinHint: hasBinary("cygpath") || Boolean(process.env.CYGWIN),
    },
    platform: {
      name: pkgJson.name,
      version: pkgJson.version,
      repoRoot,
      configPath: ctx.configPath,
      overlayPath: ctx.overlayPath,
      workspaceRoot: paths.root,
      workspaceExists: existsSync(paths.root),
      coreConfig: config.soc.coreConfig,
      xlen: config.soc.xlen,
      frequencyMHz: config.soc.targetFrequencyMHz,
      process: config.soc.process,
      defaultSim: String(config.simulation.default),
    },
    packageManagers: pkgStates,
    activePackageManager: detectPackageManager(host.os),
    utils,
    hostProbes,
    managedTools,
    installProfiles: profiles,
    envVars,
    residualRoots,
    diagnostics,
    commands,
    installActions,
    missingByCategory,
  };
}

export type { ToolCategory, ToolStatus };
