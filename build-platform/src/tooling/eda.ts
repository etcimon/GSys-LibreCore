// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// eda.ts — Open EDA gate engine (lint / formal / sim / synth).
//
// AGENTS.md §0.2 requires every RTL change to be synth-clean, verified and
// timing-aware. This module resolves the tools that make that checkable and
// builds the invocations, so the `verify` command stays a thin orchestrator.
//
// One extracted OSS CAD Suite supplies every tool:
//   - verilator  : lint + style warnings over core/Flist.cva6
//   - slang      : full SystemVerilog elaboration (handles `parameter type`,
//                  which Verilator tolerates but Icarus cannot parse at all)
//   - yosys+slang: synthesis smoke (RTL -> generic gates), plugin-loaded
//   - sby        : bounded formal (SymbiYosys) over the task files in config
//
// Nothing here mutates the repository; every invocation is read-only against
// the RTL and writes only into the managed, gitignored workspace.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, isAbsolute, join } from "node:path";

import type { PlatformContext } from "../context.ts";
import { run, type CommandResult } from "../platform/exec.ts";

/** Absolute locations of every binary the gate can drive. */
export interface EdaPaths {
  /** Extracted OSS CAD Suite root. */
  root: string;
  bin: string;
  /** Shared libraries; must be on PATH or the binaries fail with DLL-not-found. */
  lib: string;
  /** Verilator's real binary (the `verilator` wrapper is a shell script). */
  verilator: string;
  /** VERILATOR_ROOT — Verilator cannot find its includes without it. */
  verilatorRoot: string;
  yosys: string;
  sby: string;
  slang: string;
  iverilog: string;
  /** yosys-slang plugin, giving Yosys a real SystemVerilog frontend. */
  slangPlugin: string;
}

export interface EdaToolStatus {
  id: string;
  path: string;
  present: boolean;
  /** False when the stage that needs it can still run without it. */
  required: boolean;
}

export type GateStageId = "lint" | "formal" | "sim" | "synth";

export interface StageOutcome {
  stage: GateStageId;
  target: string | null;
  status: "pass" | "fail" | "skip";
  detail: string;
  durationMs: number;
  /** Verilator/slang warning count when the stage produced one. */
  warnings?: number;
  /** Leading lines of the tool log, retained so a failure is diagnosable. */
  log?: string[];
}

/**
 * Resolve the suite layout. A relative `verify.suite.root` lands under
 * workspace/tooling so the suite is a managed, gitignored artifact.
 */
export function edaPaths(ctx: PlatformContext): EdaPaths {
  const configured = ctx.config.verify.suite.root;
  const root = isAbsolute(configured)
    ? configured
    : join(ctx.paths.tooling, configured);
  const bin = join(root, "bin");
  const lib = join(root, "lib");
  const x = ctx.host.exeSuffix;

  return {
    root,
    bin,
    lib,
    verilator: join(bin, `verilator_bin${x}`),
    verilatorRoot: join(root, "share", "verilator"),
    yosys: join(bin, `yosys${x}`),
    sby: join(bin, `sby${x}`),
    slang: join(bin, `slang${x}`),
    iverilog: join(bin, `iverilog${x}`),
    slangPlugin: join(root, "share", "yosys", "plugins", "slang.so"),
  };
}

/** Report which gate tools are actually installed. */
export function edaPresence(paths: EdaPaths): EdaToolStatus[] {
  return [
    { id: "verilator", path: paths.verilator, present: existsSync(paths.verilator), required: true },
    { id: "slang", path: paths.slang, present: existsSync(paths.slang), required: false },
    { id: "yosys", path: paths.yosys, present: existsSync(paths.yosys), required: false },
    { id: "yosys-slang", path: paths.slangPlugin, present: existsSync(paths.slangPlugin), required: false },
    { id: "sby", path: paths.sby, present: existsSync(paths.sby), required: false },
    { id: "iverilog", path: paths.iverilog, present: existsSync(paths.iverilog), required: false },
  ];
}

/**
 * Environment for a gate invocation.
 *
 * Two independent requirements are satisfied here:
 *  1. The OSS CAD Suite runtime: bin AND lib must both be on PATH (the
 *     binaries link against DLLs in lib), plus YOSYSHQ_ROOT and the bundled
 *     interpreter that the python-based tools (sby) exec.
 *  2. The CVA6 manifest: `core/Flist.cva6` expands ${CVA6_REPO_DIR},
 *     ${TARGET_CFG} and ${HPDCACHE_DIR}, so all three must be exported or the
 *     manifest resolves to nonsense paths.
 */
export function edaEnv(
  ctx: PlatformContext,
  paths: EdaPaths,
  target: string,
): Record<string, string> {
  const currentPath = process.env.PATH ?? process.env.Path ?? "";
  const newPath = [paths.bin, paths.lib, currentPath].join(ctx.host.pathSep);
  const env: Record<string, string> = {
    PATH: newPath,
    Path: newPath,
    // environment.ps1 stores the root with a trailing separator; tools that
    // concatenate rather than join depend on it.
    YOSYSHQ_ROOT: paths.root + (ctx.host.os === "windows" ? "\\" : "/"),
    SSL_CERT_FILE: join(paths.root, "etc", "cacert.pem"),
    CVA6_REPO_DIR: posixPath(ctx.repoRoot),
    TARGET_CFG: target,
    HPDCACHE_DIR: posixPath(join(ctx.repoRoot, "core", "cache_subsystem", "hpdcache")),
    VERILATOR_ROOT: posixPath(paths.verilatorRoot),
  };
  const bundledPython = join(paths.lib, ctx.host.os === "windows" ? "python3.exe" : "python3");
  if (existsSync(bundledPython)) env.PYTHON_EXECUTABLE = bundledPython;
  return env;
}

/**
 * Normalise to forward slashes.
 *
 * Verilator decides whether a path inside a command file is absolute by looking
 * for a leading '/'. A Windows `E:\cva6\...` value therefore looks *relative*
 * and gets prefixed with the enclosing manifest's directory, which breaks the
 * nested `-F ${HPDCACHE_DIR}/rtl/hpdcache.Flist` include. Exporting POSIX-style
 * paths keeps one manifest working identically on every host.
 */
export function posixPath(p: string): string {
  return p.replaceAll("\\", "/");
}

export interface FlatManifest {
  /** Absolute, POSIX-style source paths in manifest order. */
  files: string[];
  /** Absolute, POSIX-style include directories. */
  incdirs: string[];
  /** Path of the generated flat command file. */
  path: string;
}

/**
 * Flatten `core/Flist.cva6` into a single command file.
 *
 * The manifest nests (`-F ${HPDCACHE_DIR}/rtl/hpdcache.Flist`) and relies on
 * ${VAR} expansion. Verilator resolves a nested `-F` entry relative to the
 * including file *unless* the entry looks absolute — and on Windows it does not
 * recognise a drive-letter path as absolute, so every hpdcache source resolves
 * to a doubled path. Rather than depend on each tool's nesting rules, expand the
 * manifest ourselves: one flat file, absolute POSIX paths, identical on every
 * host. This mirrors what util/flist_flattener.py does for the FPGA flow.
 */
export function flattenFlist(
  entry: string,
  env: Record<string, string>,
  cwd: string,
): { files: string[]; incdirs: string[] } {
  const files: string[] = [];
  const incdirs: string[] = [];
  const seen = new Set<string>();

  const expand = (s: string): string =>
    s
      .replace(/\$\{(\w+)\}/g, (_m, k: string) => env[k] ?? "")
      .replace(/\$\((\w+)\)/g, (_m, k: string) => env[k] ?? "")
      .replace(/\$(\w+)/g, (_m, k: string) => env[k] ?? "");

  const resolveFrom = (base: string, p: string): string =>
    posixPath(isAbsolute(p) || /^[A-Za-z]:/.test(p) ? p : join(base, p));

  const walk = (manifest: string, base: string): void => {
    const abs = resolveFrom(base, manifest);
    if (seen.has(abs)) return;
    seen.add(abs);
    if (!existsSync(abs)) throw new Error(`manifest not found: ${abs}`);

    const dir = abs.slice(0, abs.lastIndexOf("/"));
    const raw = readFileSync(abs, "utf8");

    for (const line of raw.split(/\r?\n/)) {
      // Manifests use `//` for comments; `#` appears in some vendored lists.
      const text = expand(line.replace(/\/\/.*$/, "").replace(/^\s*#.*$/, "")).trim();
      if (text.length === 0) continue;

      if (text.startsWith("+incdir+")) {
        const d = resolveFrom(dir, text.slice("+incdir+".length));
        if (!incdirs.includes(d)) incdirs.push(d);
      } else if (text.startsWith("-F ") || text.startsWith("-f ")) {
        // -F resolves relative to the including manifest, -f relative to cwd.
        const nested = text.slice(3).trim();
        walk(nested, text.startsWith("-F ") ? dir : cwd);
      } else if (text.startsWith("+") || text.startsWith("-")) {
        // Other directives (+define+, -sv, ...) are passed through untouched.
        continue;
      } else {
        const f = resolveFrom(dir, text);
        if (!files.includes(f)) files.push(f);
      }
    }
  };

  walk(entry, cwd);
  return { files, incdirs };
}

/** Resolve the lint/synth top module for a config-package target. */
export function resolveVerifyTop(
  verify: { top: string; topByTarget?: Record<string, string> },
  target: string,
): string {
  return verify.topByTarget?.[target] ?? verify.top;
}

/** Optional overrides for diagnostic / per-test Verilator surfaces. */
export interface ManifestOverride {
  /** Repo-relative primary flist (default: verify.flist). */
  flist?: string;
  /**
   * Extra flists for this invocation only. When set, replaces the merge of
   * verify.extraFlists + extraFlistsByTarget[target] (pass [] for none).
   * When undefined, uses the verify config merge as usual.
   */
  extraFlists?: string[];
  /** Subdir under workspace/build for the flat .f file (default: verify). */
  outSubdir?: string;
  /** Tag used in the output filename (default: target). */
  outTag?: string;
}

/** Flatten the configured manifest for a target and write the command file. */
export function writeFlatManifest(
  ctx: PlatformContext,
  paths: EdaPaths,
  target: string,
  override: ManifestOverride = {},
): FlatManifest {
  const env = edaEnv(ctx, paths, target);
  const cwd = posixPath(ctx.repoRoot);
  const flistRel = override.flist ?? ctx.config.verify.flist;
  const primary = flattenFlist(
    posixPath(join(ctx.repoRoot, flistRel)),
    env,
    cwd,
  );
  const files = [...primary.files];
  const incdirs = [...primary.incdirs];
  // Opt-in IP (e.g. Ara) — append without mutating core/Flist.cva6.
  const extras =
    override.extraFlists !== undefined
      ? override.extraFlists
      : [
          ...(ctx.config.verify.extraFlists ?? []),
          ...(ctx.config.verify.extraFlistsByTarget?.[target] ?? []),
        ];
  let araOnFlist = false;
  for (const extra of extras) {
    const absExtra = posixPath(join(ctx.repoRoot, extra));
    if (!existsSync(absExtra)) {
      // Soft-skip missing opt-in flists so a fresh clone without `vendor sync
      // ara` still elaborates the core package; the ara-vector-path suite
      // asserts the flist exists when that path is exercised.
      continue;
    }
    if (/Flist\.ara/i.test(extra) || /\/ara\//i.test(extra)) araOnFlist = true;
    const flat = flattenFlist(absExtra, env, cwd);
    for (const d of flat.incdirs) if (!incdirs.includes(d)) incdirs.push(d);
    for (const f of flat.files) if (!files.includes(f)) files.push(f);
  }
  // Ara ships a real cva6_accel_first_pass_decoder; drop the core stub so the
  // flist does not re-define the same module name.
  if (araOnFlist) {
    const filtered = files.filter((f) => !/cva6_accel_first_pass_decoder_stub\.sv$/i.test(f));
    files.length = 0;
    files.push(...filtered);
    // Typed RVV lint top + APU acc intf include + attach glue.
    const extrasApu = [
      "corev_apu/tb/ariane_axi_pkg.sv",
      "corev_apu/src/ariane.sv",
      "corev_apu/src/g6lc_ara_attach.sv",
      "corev_apu/src/g6lc_axi_2to1_mux.sv",
      "verif/tb/g6lc_ara_lint_top.sv",
    ];
    for (const rel of extrasApu) {
      const abs = posixPath(join(ctx.repoRoot, rel));
      if (existsSync(abs) && !files.includes(abs)) files.push(abs);
    }
    for (const rel of [
      "corev_apu/include",
      "corev_apu/tb",
      "vendor/pulp-platform/axi/include",
      "vendor/ara/upstream/hardware/include",
    ]) {
      const abs = posixPath(join(ctx.repoRoot, rel));
      if (existsSync(abs) && !incdirs.includes(abs)) incdirs.push(abs);
    }
  }
  // Runtime-stability R8: when timings --use-emit set env, replace live RTL
  // paths with matching corrected/*__svt.sv from CVA6_TIMINGS_EMIT_FLIST.
  let emitReplaced = 0;
  const emitFlist = process.env.CVA6_TIMINGS_EMIT_FLIST;
  const useEmit =
    process.env.CVA6_TIMINGS_USE_EMIT === "1" ||
    process.env.CVA6_TIMINGS_USE_EMIT === "true";
  if (useEmit && emitFlist && existsSync(emitFlist)) {
    const over = applyEmitOverlay(files, emitFlist);
    files.length = 0;
    files.push(...over.files);
    emitReplaced = over.replaced;
  }

  const outDir = join(ctx.paths.build, override.outSubdir ?? "verify");
  mkdirSync(outDir, { recursive: true });
  const tag = override.outTag ?? target;
  const out = join(outDir, `${tag}.f`);
  const body = [
    `// generated by g6lc-build — target ${target} tag ${tag}`,
    ...(emitReplaced > 0
      ? [
          `// --use-emit overlay: ${emitReplaced} file(s) from ${emitFlist}`,
        ]
      : []),
    ...incdirs.map((d) => `+incdir+${d}`),
    ...files,
    "",
  ].join("\n");
  writeFileSync(out, body, "utf8");
  return { files, incdirs, path: posixPath(out) };
}

/**
 * Map live flist paths to corrected `__svt` sources listed in an emit flist.
 * Basename match: `core/alu.sv` ↔ `…/alu__svt.sv`. Emit always uses `__svt.sv`
 * even when the live source is `.v` (e.g. C910 vfdsu), so we also map the
 * stem to common live extensions. Unmapped files stay live.
 */
export function applyEmitOverlay(
  liveFiles: string[],
  emitFlistAbs: string,
): { files: string[]; replaced: number } {
  const correctedRoot = dirname(emitFlistAbs);
  const text = readFileSync(emitFlistAbs, "utf8");
  /** live basename (alu.sv / foo.v) → absolute corrected path */
  const byLiveBase = new Map<string, string>();
  for (const raw of text.split(/\r?\n/)) {
    const t = raw.trim();
    if (!t || t.startsWith("#") || t.startsWith("//") || t.startsWith("+")) {
      continue;
    }
    const abs = isAbsolute(t) ? t : join(correctedRoot, t);
    const base = basename(t);
    const m = base.match(/^(.*)__svt\.(sv|v|svh)$/i);
    if (!m) continue;
    if (!existsSync(abs)) continue;
    const stem = m[1] ?? "";
    const emitExt = (m[2] ?? "sv").toLowerCase();
    const pos = posixPath(abs);
    // Prefer emit extension, then alternate SV/V suffixes for drop-in match.
    const liveBases = new Set<string>([
      `${stem}.${emitExt}`.toLowerCase(),
      `${stem}.sv`.toLowerCase(),
      `${stem}.v`.toLowerCase(),
      `${stem}.svh`.toLowerCase(),
    ]);
    for (const lb of liveBases) byLiveBase.set(lb, pos);
  }
  let replaced = 0;
  const files = liveFiles.map((f) => {
    const b = basename(f).toLowerCase();
    const rep = byLiveBase.get(b);
    if (rep) {
      replaced += 1;
      return rep;
    }
    return f;
  });
  return { files, replaced };
}

/**
 * Verilator --lint-only with an explicit surface (used by compartmentalized
 * diagnostics). Falls back to verify.* for unset fields.
 */
export interface LintSurface {
  target: string;
  top?: string;
  flist?: string;
  extraFlists?: string[];
  lintArgs?: string[];
  lintArgsMode?: "append" | "replace";
  defines?: string[];
  waiverFile?: string;
  warningBudget?: number | null;
  /** Filename tag under workspace/build/diagnostics/. */
  tag?: string;
}

export async function lintWithSurface(
  ctx: PlatformContext,
  paths: EdaPaths,
  surface: LintSurface,
): Promise<StageOutcome> {
  const started = performance.now();
  const { verify } = ctx.config;
  const target = surface.target;

  if (!existsSync(paths.verilator)) {
    return {
      stage: "lint",
      target,
      status: "skip",
      detail: `verilator not found at ${paths.verilator}`,
      durationMs: elapsed(started),
    };
  }

  const top =
    surface.top ?? resolveVerifyTop(verify, target);
  const manifest = writeFlatManifest(ctx, paths, target, {
    flist: surface.flist,
    extraFlists: surface.extraFlists,
    outSubdir: "diagnostics",
    outTag: surface.tag ?? `diag-${target}`,
  });

  const baseArgs =
    surface.lintArgsMode === "replace" && surface.lintArgs
      ? surface.lintArgs
      : [...verify.lintArgs, ...(surface.lintArgs ?? [])];

  const defineArgs = (surface.defines ?? []).map((d) =>
    d.startsWith("+define+") ? d : `+define+${d}`,
  );

  const waiver = surface.waiverFile ?? verify.waiverFile;
  const args = [
    "--lint-only",
    ...baseArgs,
    ...defineArgs,
    "--top-module",
    top,
    posixPath(join(ctx.repoRoot, waiver)),
    "-f",
    manifest.path,
  ];

  const result = await run(paths.verilator, args, {
    cwd: ctx.repoRoot,
    env: edaEnv(ctx, paths, target),
    stdio: "capture",
    allowFailure: true,
    dryRun: ctx.dryRun,
    logger: ctx.logger,
  });

  let limit: number | null;
  if (surface.warningBudget === null) limit = null;
  else if (typeof surface.warningBudget === "number") limit = surface.warningBudget;
  else limit = verify.warningBaseline[target] ?? (verify.failOnMissingBaseline ? 0 : null);

  return summarise("lint", target, result, limit, started);
}

/** Count Verilator/slang diagnostics of a given severity in a tool log. */
export function countDiagnostics(text: string, kind: "warning" | "error"): number {
  const needle = kind === "warning" ? /%Warning|\bwarning:/gi : /%Error|\berror:/gi;
  return (text.match(needle) ?? []).length;
}

function elapsed(started: number): number {
  return Math.round(performance.now() - started);
}

/**
 * Lint + elaborate one config-package target with Verilator.
 *
 * `--lint-only` keeps this read-only and fast; the waiver file carries the
 * project's accepted exceptions and must never be widened silently.
 */
export async function lintTarget(
  ctx: PlatformContext,
  paths: EdaPaths,
  target: string,
): Promise<StageOutcome> {
  const started = performance.now();
  const { verify } = ctx.config;

  if (!existsSync(paths.verilator)) {
    return {
      stage: "lint",
      target,
      status: "skip",
      detail: `verilator not found at ${paths.verilator}`,
      durationMs: elapsed(started),
    };
  }

  const top = resolveVerifyTop(verify, target);
  const manifest = writeFlatManifest(ctx, paths, target);
  // Live Ara (`CVA6_ARA_ATTACH`) needs full Ara deps + CVFPU ABI match; enable
  // only via verify.defines / env CVA6_ARA_ATTACH=1. Default RVV lint uses the
  // typed attach **stub** so EnableAccelerator elaborates cleanly.
  const araLive = process.env.CVA6_ARA_ATTACH === "1" || process.env.CVA6_ARA_ATTACH === "true";
  const args = [
    "--lint-only",
    ...verify.lintArgs,
    ...(araLive ? ["+define+CVA6_ARA_ATTACH"] : []),
    "--top-module",
    top,
    posixPath(join(ctx.repoRoot, verify.waiverFile)),
    "-f",
    manifest.path,
  ];

  const result = await run(paths.verilator, args, {
    cwd: ctx.repoRoot,
    env: edaEnv(ctx, paths, target),
    stdio: "capture",
    allowFailure: true,
    dryRun: ctx.dryRun,
    logger: ctx.logger,
  });

  const baseline = verify.warningBaseline[target];
  const limit = baseline ?? (verify.failOnMissingBaseline ? 0 : null);
  return summarise("lint", target, result, limit, started);
}

/**
 * Full SystemVerilog elaboration with slang. Verilator is permissive about a
 * few constructs CVA6 relies on; slang is the stricter second opinion and
 * catches type/parameter errors before they reach a commercial tool.
 */
export async function elaborateTarget(
  ctx: PlatformContext,
  paths: EdaPaths,
  target: string,
): Promise<StageOutcome> {
  const started = performance.now();

  if (!existsSync(paths.slang)) {
    return {
      stage: "lint",
      target,
      status: "skip",
      detail: "slang not found (skipping strict elaboration)",
      durationMs: elapsed(started),
    };
  }

  const top = resolveVerifyTop(ctx.config.verify, target);
  const manifest = writeFlatManifest(ctx, paths, target);
  const araLive = process.env.CVA6_ARA_ATTACH === "1" || process.env.CVA6_ARA_ATTACH === "true";
  // Ara upstream uses assignment-pattern `default:'0` with enum fields that
  // strict slang rejects; Verilator is the authoritative gate for live Ara.
  if (araLive) {
    return {
      stage: "lint",
      target,
      status: "skip",
      detail: "slang skipped for CVA6_ARA_ATTACH (use Verilator; Ara enum defaults)",
      durationMs: elapsed(started),
    };
  }
  const args = [
    "-f",
    manifest.path,
    "--top",
    top,
    "--single-unit",
    "-Wrange-width-oob",
  ];

  const result = await run(paths.slang, args, {
    cwd: ctx.repoRoot,
    env: edaEnv(ctx, paths, target),
    stdio: "capture",
    allowFailure: true,
    dryRun: ctx.dryRun,
    logger: ctx.logger,
  });

  // slang's warning set is broader than the project's accepted baseline, so an
  // elaboration pass is judged on errors only; warnings are reported, not fatal.
  return summarise("lint", target, result, null, started);
}

/**
 * Synthesis smoke: elaborate to generic gates with Yosys + the slang frontend.
 * This is not sign-off synthesis — it proves the change is synthesizable and
 * surfaces inferred latches / unmapped constructs early, which is exactly the
 * failure mode AGENTS.md §0.1 forbids.
 */
export async function synthTarget(
  ctx: PlatformContext,
  paths: EdaPaths,
  target: string,
): Promise<StageOutcome> {
  const started = performance.now();

  if (!existsSync(paths.yosys) || !existsSync(paths.slangPlugin)) {
    return {
      stage: "synth",
      target,
      status: "skip",
      detail: "yosys or the yosys-slang plugin is missing",
      durationMs: elapsed(started),
    };
  }

  const { verify } = ctx.config;
  const top = resolveVerifyTop(verify, target);
  const manifest = writeFlatManifest(ctx, paths, target);
  const script = [
    // Unquoted on purpose: the slang frontend does not strip quotes from a
    // command-file argument. Paths are already POSIX-style and space-free.
    [
      "read_slang -f",
      manifest.path,
      `--top ${top}`,
      "--single-unit",
      ...verify.synthDefines.map((d) => `-D${d}`),
    ].join(" "),
    `hierarchy -check -top ${top}`,
    "proc",
    "opt -fast",
    "check -assert",
    "stat",
  ].join("; ");

  // The frontend must be loaded with -m; the in-script `plugin -i` form is not
  // supported by this Yosys build.
  const result = await run(paths.yosys, ["-m", paths.slangPlugin, "-p", script], {
    cwd: ctx.repoRoot,
    env: edaEnv(ctx, paths, target),
    stdio: "capture",
    allowFailure: true,
    dryRun: ctx.dryRun,
    logger: ctx.logger,
  });

  return summarise("synth", target, result, null, started);
}

/** Run one SymbiYosys task file (bounded proof of a named property set). */
export async function formalTask(
  ctx: PlatformContext,
  paths: EdaPaths,
  taskFile: string,
): Promise<StageOutcome> {
  const started = performance.now();
  const abs = isAbsolute(taskFile) ? taskFile : join(ctx.repoRoot, taskFile);

  if (!existsSync(paths.sby)) {
    return {
      stage: "formal",
      target: taskFile,
      status: "skip",
      detail: "sby not found",
      durationMs: elapsed(started),
    };
  }
  if (!existsSync(abs)) {
    return {
      stage: "formal",
      target: taskFile,
      status: "fail",
      detail: `task file missing: ${abs}`,
      durationMs: elapsed(started),
    };
  }

  // Per-task workdir so sequential tasks do not clobber each other.
  // SymbiYosys resolves [files] relative to the process cwd (not the .sby
  // path), so we run with cwd = the directory that holds the task + props.
  const taskDir = dirname(abs);
  const taskName = basename(abs);
  const taskBase = taskName.replace(/\.sby$/i, "");
  const outDir = join(ctx.paths.build, "formal", taskBase);
  mkdirSync(outDir, { recursive: true });
  const result = await run(paths.sby, ["-f", "-d", outDir, taskName], {
    cwd: taskDir,
    env: edaEnv(ctx, paths, ctx.config.soc.coreConfig),
    stdio: "capture",
    allowFailure: true,
    dryRun: ctx.dryRun,
    logger: ctx.logger,
  });

  return summarise("formal", taskFile, result, null, started);
}

/**
 * Judge a tool run.
 *
 * `warningLimit` is the accepted warning count for this target: exceeding it is
 * a regression and fails the gate, matching it (or coming in under it) passes.
 * `null` means warnings are informational for this stage.
 */
function summarise(
  stage: GateStageId,
  target: string | null,
  result: CommandResult,
  warningLimit: number | null,
  started: number,
): StageOutcome {
  const text = `${result.stdout}\n${result.stderr}`;
  const warnings = countDiagnostics(text, "warning");
  const overBaseline = warningLimit !== null && warnings > warningLimit;
  const failed = !result.ok || overBaseline;

  let detail: string;
  if (result.dryRun) detail = "dry run";
  else if (!result.ok) detail = `exit ${result.code}, ${countDiagnostics(text, "error")} error(s)`;
  else if (overBaseline) detail = `${warnings} warning(s), baseline ${warningLimit} — REGRESSION`;
  else if (warningLimit !== null) detail = `${warnings} warning(s) (baseline ${warningLimit})`;
  else if (warnings > 0) detail = `${warnings} warning(s)`;
  else detail = "clean";

  return {
    stage,
    target,
    status: result.dryRun ? "skip" : failed ? "fail" : "pass",
    detail,
    durationMs: elapsed(started),
    warnings,
    log: failed ? logExcerpt(text) : undefined,
  };
}

/** Keep the first lines of a tool log; enough to identify the first failure. */
function logExcerpt(text: string, maxLines = 40): string[] {
  return text
    .split(/\r?\n/)
    .filter((l) => l.trim().length > 0)
    .slice(0, maxLines);
}
