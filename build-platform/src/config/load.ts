// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// load.ts — Resolve the effective configuration.
//
// Resolution order (lowest to highest precedence):
//   1. DEFAULT_CONFIG (defaults.ts)
//   2. <repoRoot>/.config.ts               (the committed control surface)
//   3. <repoRoot>/build-platform/.config.local.ts  (optional, gitignored)
//
// The result is validated and returned alongside the detected repo root and a
// few derived values (e.g. clock period from target frequency).

import { existsSync } from "node:fs";
import { dirname, isAbsolute, join } from "node:path";
import { pathToFileURL } from "node:url";

import { deepMerge } from "../util/object.ts";
import { DEFAULT_CONFIG } from "./defaults.ts";
import type { BuildConfigInput, ResolvedBuildConfig } from "./schema.ts";

export class ConfigError extends Error {
  constructor(message: string, readonly issues: string[] = []) {
    super(message);
    this.name = "ConfigError";
  }
}

export interface LoadedConfig {
  config: ResolvedBuildConfig;
  repoRoot: string;
  /** Absolute path to the primary .config.ts, or null if none was found. */
  configPath: string | null;
  /** Absolute path to the local overlay, or null if none was found. */
  overlayPath: string | null;
  derived: {
    /** Target clock period in nanoseconds, from soc.targetFrequencyMHz. */
    clockPeriodNs: number;
  };
}

/**
 * Files that mark the repository root. Only markers that are unique to the true
 * root are used: `.git` and `.gitmodules`. (AGENTS.md is intentionally excluded
 * because it also appears in subdirectories such as build-platform/.)
 */
const ROOT_MARKERS = [".git", ".gitmodules"];

/**
 * Walk upward from `start` until a directory containing a root marker is found.
 * Falls back to the build-platform parent directory.
 */
export function findRepoRoot(start: string = import.meta.dir): string {
  let dir = start;
  // Bounded walk to avoid infinite loops on odd filesystems.
  for (let i = 0; i < 64; i++) {
    for (const marker of ROOT_MARKERS) {
      if (existsSync(join(dir, marker))) return dir;
    }
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  // src/config -> src -> build-platform -> repoRoot
  return join(import.meta.dir, "..", "..", "..");
}

async function importConfigModule(path: string): Promise<BuildConfigInput> {
  const module = (await import(pathToFileURL(path).href)) as {
    default?: BuildConfigInput;
    config?: BuildConfigInput;
  };
  const value = module.default ?? module.config;
  if (value === undefined) {
    throw new ConfigError(
      `Config file '${path}' must 'export default defineBuildConfig({ ... })'.`,
    );
  }
  return value;
}

/** Validate cross-field invariants; throws ConfigError with all issues. */
export function validateConfig(config: ResolvedBuildConfig): void {
  const issues: string[] = [];
  const { soc, simulation, tests, vendor } = config;

  const { motherboard } = config;
  const coreLower = soc.coreConfig.toLowerCase();
  if (coreLower.startsWith("cv32") && soc.xlen !== 32) {
    issues.push(`soc.xlen must be 32 for coreConfig '${soc.coreConfig}'.`);
  }
  if (coreLower.startsWith("cv64") && soc.xlen !== 64) {
    issues.push(`soc.xlen must be 64 for coreConfig '${soc.coreConfig}'.`);
  }
  if (!(soc.targetFrequencyMHz > 0)) {
    issues.push("soc.targetFrequencyMHz must be greater than 0.");
  }
  if (!(soc.targetVoltageV > 0)) {
    issues.push("soc.targetVoltageV must be greater than 0.");
  }
  if (!simulation.enabled.includes(simulation.default)) {
    issues.push(
      `simulation.default '${simulation.default}' is not in simulation.enabled [${simulation.enabled.join(", ")}].`,
    );
  }
  const suiteIds = new Set(tests.suites.map((s) => s.id));
  for (const id of tests.defaultSuites) {
    if (!suiteIds.has(id)) {
      issues.push(`tests.defaultSuites references unknown suite '${id}'.`);
    }
  }
  if (tests.parallelism < 1) {
    issues.push("tests.parallelism must be >= 1.");
  }

  // Vendor catalog: ids and checkout paths must be unique, and every entry
  // needs a url + path so `vendor sync` can act on it.
  const vendorIds = new Set<string>();
  const vendorPaths = new Set<string>();
  for (const c of vendor.controllers) {
    if (vendorIds.has(c.id)) issues.push(`vendor.controllers has duplicate id '${c.id}'.`);
    vendorIds.add(c.id);
    if (vendorPaths.has(c.path)) issues.push(`vendor.controllers has duplicate path '${c.path}' (id '${c.id}').`);
    vendorPaths.add(c.path);
    if (!c.url) issues.push(`vendor controller '${c.id}' is missing a url.`);
    if (!c.path) issues.push(`vendor controller '${c.id}' is missing a path.`);
  }

  // Motherboard: roots must be set, and the pcbparts client needs a sane URL +
  // positive timeout. activeBoard may be null (no board selected) — that is the
  // shipped default, so it is never an error here.
  if (!motherboard.boardsRoot) issues.push("motherboard.boardsRoot must be set.");
  if (!motherboard.architectureRoot) issues.push("motherboard.architectureRoot must be set.");
  if (!motherboard.libRoot) issues.push("motherboard.libRoot must be set.");
  if (!/^https?:\/\//.test(motherboard.pcbParts.mcpUrl)) {
    issues.push("motherboard.pcbParts.mcpUrl must be an http(s) URL.");
  }
  if (!(motherboard.pcbParts.timeoutMs > 0)) {
    issues.push("motherboard.pcbParts.timeoutMs must be greater than 0.");
  }
  if (motherboard.pcbParts.maxFixIterations < 0) {
    issues.push("motherboard.pcbParts.maxFixIterations must be >= 0.");
  }

  // Technology optimization: structural checks + the two safety invariants
  // (a valid guard-macro identifier, and that an "nda" drop names its tech).
  const { technology } = config;
  const TECH_MODES = ["omitted", "open", "nda"];
  if (!TECH_MODES.includes(technology.pdkMode)) {
    issues.push(`technology.pdkMode must be one of ${TECH_MODES.join(", ")}.`);
  }
  if (!technology.pdkRoot) issues.push("technology.pdkRoot must be set.");
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(technology.guardMacro)) {
    issues.push("technology.guardMacro must be a valid Verilog identifier (guards the RTL adaptation).");
  }
  if (technology.specGlobs.length === 0) {
    issues.push("technology.specGlobs must list at least one glob (key 2 of the ignition).");
  }
  if (technology.protectedGlobs.length === 0) {
    issues.push("technology.protectedGlobs must list at least one protected path glob.");
  }
  if (technology.pdkMode === "nda" && !technology.activeTechnology) {
    issues.push('technology.activeTechnology must be set when technology.pdkMode is "nda".');
  }

  // Verification gate: the stages are only meaningful with a manifest, a top
  // module and at least one config-package target to elaborate.
  const { verify } = config;
  if (!verify.flist) issues.push("verify.flist must name the core manifest (e.g. core/Flist.cva6).");
  if (!verify.top) issues.push("verify.top must name the module lint/synthesis elaborates.");
  if (!verify.suite.root) issues.push("verify.suite.root must point at an extracted OSS CAD Suite.");
  if (verify.targets.length === 0) {
    issues.push("verify.targets must list at least one config-package target to elaborate.");
  }
  for (const t of verify.targets) {
    if (!/^[A-Za-z0-9_]+$/.test(t)) {
      issues.push(`verify.targets entry "${t}" must be a bare config name (no _config_pkg suffix, no path).`);
    }
  }
  for (const id of verify.simSuites) {
    if (!tests.suites.some((s) => s.id === id)) {
      issues.push(`verify.simSuites references unknown suite "${id}".`);
    }
  }

  // Diagnostics: unique ids; verilator kinds need a verilator block + target.
  const { diagnostics } = config;
  const diagIds = new Set<string>();
  const COMPARTMENTS = new Set(["host", "core", "smt2", "ooo", "apu", "residual"]);
  for (const d of diagnostics.tests) {
    if (diagIds.has(d.id)) issues.push(`diagnostics.tests has duplicate id '${d.id}'.`);
    diagIds.add(d.id);
    if (!COMPARTMENTS.has(d.compartment)) {
      issues.push(`diagnostics test '${d.id}' has unknown compartment '${d.compartment}'.`);
    }
    if ((d.kind === "verilator-lint" || d.kind === "verilator-elab") && !d.verilator?.target) {
      issues.push(`diagnostics test '${d.id}' (${d.kind}) requires verilator.target.`);
    }
    if (d.kind === "probe-cap" && (!d.probeCaps || d.probeCaps.length === 0)) {
      issues.push(`diagnostics test '${d.id}' (probe-cap) requires probeCaps.`);
    }
    if (d.kind === "path-check" && (!d.paths || d.paths.length === 0)) {
      issues.push(`diagnostics test '${d.id}' (path-check) requires paths.`);
    }
  }
  for (const c of diagnostics.defaultCompartments) {
    if (!COMPARTMENTS.has(c)) {
      issues.push(`diagnostics.defaultCompartments entry '${c}' is not a known compartment.`);
    }
  }

  if (issues.length > 0) {
    throw new ConfigError(
      `Invalid configuration (${issues.length} issue(s)).`,
      issues,
    );
  }
}

export interface LoadConfigOptions {
  /** Override the starting directory for repo-root detection. */
  cwd?: string;
  /** Explicit path to the primary config file. */
  configPath?: string;
  /** Skip validation (used by `config --raw` for diagnostics). */
  skipValidation?: boolean;
}

/** Load, merge, and validate the effective configuration. */
export async function loadConfig(
  options: LoadConfigOptions = {},
): Promise<LoadedConfig> {
  const repoRoot = options.cwd ? findRepoRoot(options.cwd) : findRepoRoot();

  const configPath = options.configPath ?? join(repoRoot, ".config.ts");
  const overlayPath = join(repoRoot, "build-platform", ".config.local.ts");

  let merged: ResolvedBuildConfig = DEFAULT_CONFIG;
  let resolvedConfigPath: string | null = null;
  let resolvedOverlayPath: string | null = null;

  if (existsSync(configPath)) {
    merged = deepMerge(merged, await importConfigModule(configPath));
    resolvedConfigPath = configPath;
  }
  if (existsSync(overlayPath)) {
    merged = deepMerge(merged, await importConfigModule(overlayPath));
    resolvedOverlayPath = overlayPath;
  }

  // Default the repo root into meta unless the user pinned one explicitly.
  if (!merged.meta.repoRoot) {
    merged = deepMerge(merged, { meta: { repoRoot } });
  }

  if (!options.skipValidation) validateConfig(merged);

  return {
    config: merged,
    repoRoot,
    configPath: resolvedConfigPath,
    overlayPath: resolvedOverlayPath,
    derived: {
      clockPeriodNs: 1000 / merged.soc.targetFrequencyMHz,
    },
  };
}

/** Resolve a workspace-relative path spec to an absolute path. */
export function resolveUnderRepo(repoRoot: string, spec: string): string {
  return isAbsolute(spec) ? spec : join(repoRoot, spec);
}
