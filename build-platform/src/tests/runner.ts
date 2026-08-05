// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// runner.ts — Execute LibreCore regression suites via the verif/regress scripts.
//
// Shared by the `test` CLI command and the `bun test` specs. Each suite is a
// bash regression script run from the repo root with the managed toolchain
// environment (so RISCV/VERILATOR_INSTALL_DIR/etc. point at workspace/tooling).

import { existsSync } from "node:fs";
import { join } from "node:path";

import { childEnv, type PlatformContext } from "../context.ts";
import { hasBinary } from "../platform/exec.ts";
import {
  detectFalsePassSignals,
  resolveBashBinary,
  resolveRegressEngine,
  runRegressScript,
} from "../platform/shell.ts";
import type { ManagedTool, ResolvedBuildConfig, TestGroup, TestSuite } from "../config/schema.ts";
import { findOssCadVerilatorRoot, isVerilatorInstalled } from "../tooling/recipes.ts";

export interface SuiteResult {
  id: string;
  ok: boolean;
  code: number;
  durationMs: number;
  skipped: boolean;
  reason?: string;
}

export interface RunSuiteOptions {
  dryRun?: boolean;
  /** Skip host preflight (used by `bun test`, where an un-runnable suite is a pass). */
  skipPreflight?: boolean;
  /**
   * Absolute path to a timings precompile out-dir. Exported as CVA6_FROM_TIMING
   * / FROM_TIMING for regress scripts (T1 soak hand-off).
   */
  fromTimingDir?: string;
}

/** Ordered list of valid test-group names (CLI validation + help). */
export const TEST_GROUPS: TestGroup[] = [
  "smoke", "benchmark", "arch", "directed", "uvm", "generated", "pk", "linux",
];

export interface SuitePreflight {
  runnable: boolean;
  reason?: string;
}

/** Resolve suite ids (or the configured defaults) to suite definitions. */
export function selectSuites(
  config: ResolvedBuildConfig,
  ids?: string[],
): { suites: TestSuite[]; unknown: string[] } {
  const wanted = ids && ids.length > 0 ? ids : config.tests.defaultSuites;
  const byId = new Map(config.tests.suites.map((s) => [s.id, s]));
  const suites: TestSuite[] = [];
  const unknown: string[] = [];
  for (const id of wanted) {
    const suite = byId.get(id);
    if (suite) suites.push(suite);
    else unknown.push(id);
  }
  return { suites, unknown };
}

/** True if the host can execute a regression script (bash and/or PowerShell). */
export function canRunSuites(): boolean {
  return hasBinary("bash") || hasBinary("pwsh") || hasBinary("powershell");
}

/** All suites belonging to a group. */
export function suitesInGroup(
  config: ResolvedBuildConfig,
  group: string,
): TestSuite[] {
  return config.tests.suites.filter((s) => s.group === group);
}

/**
 * Broad selection for `--all` / `--open-source`. Optional (heavy) suites are
 * excluded unless includeOptional is set; commercial/UVM suites are kept only
 * when openSourceOnly is false (they self-skip in preflight without a UVM sim).
 */
export function broadSuites(
  config: ResolvedBuildConfig,
  opts: { openSourceOnly?: boolean; includeOptional?: boolean } = {},
): TestSuite[] {
  return config.tests.suites.filter((s) => {
    if (opts.openSourceOnly && !s.openSource) return false;
    if (!opts.includeOptional && s.optional) return false;
    return true;
  });
}

/** True when a managed tool is available (installed in workspace or on PATH). */
export function hasManagedTool(ctx: PlatformContext, tool: ManagedTool): boolean {
  const { tools, host, config, paths } = ctx;
  const exe = (name: string) => name + host.exeSuffix;
  switch (tool) {
    case "verilator":
      // Managed pin, OSS CAD Suite drop-in, or anything already on PATH.
      return (
        isVerilatorInstalled(tools.verilatorBin) ||
        findOssCadVerilatorRoot(paths.tooling) !== null ||
        hasBinary("verilator")
      );
    case "spike":
      // Managed Spike is a Linux ELF (even under Windows/WSL install); also accept PATH.
      return (
        existsSync(join(tools.spikeBin, "spike")) ||
        existsSync(join(tools.spikeBin, exe("spike"))) ||
        hasBinary("spike")
      );
    case "iverilog":
      return existsSync(join(tools.iverilogBin, exe("iverilog"))) || hasBinary("iverilog");
    case "riscv-gcc": {
      const prefix = config.toolchain.riscvGcc.toolPrefix ?? "riscv-none-elf-";
      return (
        existsSync(join(tools.riscvBin, exe(`${prefix}gcc`))) ||
        hasBinary(`${prefix}gcc`) ||
        hasBinary("riscv64-unknown-elf-gcc") ||
        hasBinary("riscv32-unknown-elf-gcc")
      );
    }
  }
}

/** True when a UVM-capable (commercial) simulator is on PATH. */
export function hasUvmSimulator(): boolean {
  return ["vcs", "vsim", "xrun", "dsim"].some((bin) => hasBinary(bin));
}

/** True when a required submodule is initialised (gitlink present at its path). */
export function submoduleCheckedOut(ctx: PlatformContext, id: string): boolean {
  const spec = ctx.config.dependencies.submodules[id];
  if (!spec) return false;
  return existsSync(join(ctx.repoRoot, spec.path, ".git"));
}

/** Decide whether a suite can run on this host, and if not, why. */
export function preflightSuite(ctx: PlatformContext, suite: TestSuite): SuitePreflight {
  if (!canRunSuites()) {
    return {
      runnable: false,
      reason: "no shell to run regress scripts (need bash and/or pwsh/powershell)",
    };
  }
  // On Windows without a usable bash (Git-Bash preferred), require sibling .ps1
  const bash = resolveBashBinary();
  if (!bash && /\.sh$/i.test(suite.script)) {
    const ps1 = join(ctx.repoRoot, suite.script.replace(/\.sh$/i, ".ps1"));
    if (!existsSync(ps1)) {
      return {
        runnable: false,
        reason: `bash not found (prefer Git-Bash over Cygwin on Windows) and no sibling ${suite.script.replace(/\.sh$/i, ".ps1")}`,
      };
    }
  }
  const missing = suite.tools.filter((t) => !hasManagedTool(ctx, t));
  if (missing.length > 0) {
    return { runnable: false, reason: `missing tool(s): ${missing.join(", ")} — run 'bun run src/cli/index.ts setup --install'` };
  }
  if (suite.requiresSubmodule && !submoduleCheckedOut(ctx, suite.requiresSubmodule)) {
    return { runnable: false, reason: `submodule '${suite.requiresSubmodule}' not checked out — run 'bun run src/cli/index.ts setup'` };
  }
  if (suite.requiresUvm && !hasUvmSimulator()) {
    return { runnable: false, reason: "needs a UVM simulator (vcs/questa/xcelium) — not detected" };
  }
  return { runnable: true };
}

/** Run a single suite; resolves even on failure (inspect result.ok). */
export async function runSuite(
  ctx: PlatformContext,
  suite: TestSuite,
  options: RunSuiteOptions = {},
): Promise<SuiteResult> {
  const { logger, config, repoRoot } = ctx;
  const dvTarget = suite.dvTarget ?? suite.target;
  const extra: Record<string, string> = {
    DV_SIMULATORS: suite.dvSimulators,
    UVM_VERBOSITY: config.tests.uvmVerbosity,
    DV_TARGET: dvTarget,
  };
  if (options.fromTimingDir) {
    extra.CVA6_FROM_TIMING = options.fromTimingDir;
    extra.FROM_TIMING = options.fromTimingDir;
  }
  // Propagate expert emit flags if the parent already validated --use-emit.
  if (process.env.CVA6_TIMINGS_EMIT_FLIST) {
    extra.CVA6_TIMINGS_EMIT_FLIST = process.env.CVA6_TIMINGS_EMIT_FLIST;
  }
  if (process.env.CVA6_TIMINGS_USE_EMIT) {
    extra.CVA6_TIMINGS_USE_EMIT = process.env.CVA6_TIMINGS_USE_EMIT;
  }
  const env = childEnv(ctx, extra);

  if (options.dryRun) {
    logger.info(
      `[dry-run] ${suite.script}  (DV_SIMULATORS=${suite.dvSimulators} DV_TARGET=${dvTarget})`,
    );
    return { id: suite.id, ok: true, code: 0, durationMs: 0, skipped: true, reason: "dry-run" };
  }

  if (!options.skipPreflight) {
    const pf = preflightSuite(ctx, suite);
    if (!pf.runnable) {
      return { id: suite.id, ok: true, code: 0, durationMs: 0, skipped: true, reason: pf.reason };
    }
  }

  const scriptPath = join(repoRoot, suite.script);
  if (process.platform === "win32" && /\.sh$/i.test(suite.script)) {
    ctx.logger.info(
      `regress engine: ${resolveRegressEngine()} (set G6LC_REGRESS_ENGINE=wsl|git-bash to override)`,
    );
  }
  const result = await runRegressScript(scriptPath, [], {
    cwd: repoRoot,
    env,
    logger,
    allowFailure: true,
    stdio: "both",
  });

  // Legacy smoke scripts sometimes exited 0 after make/python failures.
  // Treat known failure signatures as a failed suite even if code===0.
  let ok = result.ok;
  let code = result.code;
  let reason: string | undefined;
  if (ok) {
    const falsePass = detectFalsePassSignals(result.stdout, result.stderr);
    if (falsePass) {
      ok = false;
      code = code === 0 ? 1 : code;
      reason = `false PASS suppressed: ${falsePass}`;
      logger.error(`${suite.id}: ${reason}`);
    }
  }

  return {
    id: suite.id,
    ok,
    code,
    durationMs: result.durationMs,
    skipped: false,
    reason,
  };
}

/** Run several suites sequentially (hardware sims are resource-heavy). */
export async function runSuites(
  ctx: PlatformContext,
  suites: TestSuite[],
  options: RunSuiteOptions = {},
): Promise<SuiteResult[]> {
  const results: SuiteResult[] = [];
  let index = 0;
  for (const suite of suites) {
    index++;
    ctx.logger.step(index, suites.length, `${suite.id} (${suite.script})`);
    const result = await runSuite(ctx, suite, options);
    if (result.skipped) {
      if (result.reason === "dry-run") ctx.logger.info(`${suite.id}: ${result.reason}`);
      else ctx.logger.warn(`${suite.id}: skipped — ${result.reason}`);
    } else if (result.ok) {
      ctx.logger.success(`${suite.id} passed (${(result.durationMs / 1000).toFixed(1)}s)`);
    } else {
      ctx.logger.error(`${suite.id} failed (exit ${result.code})`);
    }
    results.push(result);
  }
  return results;
}
