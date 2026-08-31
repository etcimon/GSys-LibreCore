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
import { recommendedJobs } from "../platform/os.ts";
import { hasWsl, windowsPathToWsl, wslCommand } from "../platform/wsl.ts";

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
  /**
   * True when `yosys` came from the managed formal prefix (or PATH) rather than
   * the OSS CAD Suite. Those builds are >= v0.67, where the sv-elab/slang
   * frontend is INTEGRATED: `read_slang` exists with no plugin, and loading a
   * plugin that is not there is a hard error. See scripts/install-formal.sh.
   */
  slangIntegrated: boolean;
  /** Where yosys/sby were actually found, for diagnostics. */
  formalSource: "oss-cad" | "managed" | "path" | "missing";
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

  // Formal toolchain resolution, in priority order:
  //   1. OSS CAD Suite (one extracted tree, plugin-based slang)
  //   2. workspace/tooling/formal (source build, integrated slang) -- on
  //      Windows these are Linux ELFs invoked through WSL, so the exe suffix
  //      does not apply to them
  //   3. bare names, letting PATH resolve them
  // The managed prefix is where `tools install formal` puts a Yosys new enough
  // to have `read_slang` built in, which is the only configuration that can
  // parse core/include/config_pkg.sv.
  const ossYosys = join(bin, `yosys${x}`);
  const ossSby = join(bin, `sby${x}`);
  const managedBin = ctx.tools.formalBin;
  const managedYosys = join(managedBin, "yosys");
  const managedSby = join(managedBin, "sby");

  let yosys = ossYosys;
  let sby = ossSby;
  let slangIntegrated = false;
  let formalSource: EdaPaths["formalSource"] = "missing";

  const pluginPath = join(root, "share", "yosys", "plugins", "slang.so");

  if (existsSync(ossYosys) && existsSync(ossSby)) {
    formalSource = "oss-cad";
    // A suite without the plugin file is a Yosys >= v0.67 carrying the frontend
    // internally. Decide on the artifact that is actually there rather than on
    // the suite's name, so a future suite that drops the plugin keeps working.
    slangIntegrated = !existsSync(pluginPath);
  } else if (existsSync(managedYosys) && existsSync(managedSby)) {
    yosys = managedYosys;
    sby = managedSby;
    slangIntegrated = true;
    formalSource = "managed";
  } else if (existsSync(managedYosys)) {
    // Half-installed prefix: still prefer it so the error names the real gap.
    yosys = managedYosys;
    slangIntegrated = true;
    formalSource = "managed";
  } else {
    // Leave the OSS paths in place for the presence report, but record that a
    // PATH lookup is the remaining option (used by the WSL/native runners).
    formalSource = "path";
  }

  return {
    root,
    bin,
    lib,
    verilator: join(bin, `verilator_bin${x}`),
    verilatorRoot: join(root, "share", "verilator"),
    yosys,
    sby,
    slang: join(bin, `slang${x}`),
    iverilog: join(bin, `iverilog${x}`),
    slangPlugin: pluginPath,
    slangIntegrated,
    formalSource,
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
  /** Verilog `+define+` directives collected from the manifest(s). */
  defines: string[];
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
): { files: string[]; incdirs: string[]; defines: string[] } {
  const files: string[] = [];
  const incdirs: string[] = [];
  const defines: string[] = [];
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
      } else if (text.startsWith("+define+")) {
        // Verilog defines from the manifest must be passed through so the
        // flat command file behaves like the original flist.
        if (!defines.includes(text)) defines.push(text);
      } else if (text.startsWith("+") || text.startsWith("-")) {
        // Other directives (-sv, ...) are passed through untouched.
        continue;
      } else {
        const f = resolveFrom(dir, text);
        if (!files.includes(f)) files.push(f);
      }
    }
  };

  walk(entry, cwd);
  return { files, incdirs, defines };
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
  const defines = [...primary.defines];
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
    for (const f of flat.defines) if (!defines.includes(f)) defines.push(f);
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
    ...defines,
    ...files,
    "",
  ].join("\n");
  writeFileSync(out, body, "utf8");
  return { files, incdirs, defines, path: posixPath(out) };
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

  // A Yosys >= v0.67 has the slang frontend built in, so the plugin is neither
  // present nor wanted; only the older OSS CAD layout needs `-m <plugin>`.
  const needsPlugin = !paths.slangIntegrated;
  if (!existsSync(paths.yosys) || (needsPlugin && !existsSync(paths.slangPlugin))) {
    return {
      stage: "synth",
      target,
      status: "skip",
      detail: needsPlugin
        ? "yosys or the yosys-slang plugin is missing"
        : "yosys is missing",
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

  // Older layout: the frontend must be loaded with -m (the in-script
  // `plugin -i` form is not supported by that Yosys build). With an integrated
  // slang there is nothing to load, and passing -m would be a hard error.
  const yosysArgs = needsPlugin
    ? ["-m", paths.slangPlugin, "-p", script]
    : ["-p", script];
  const result = await run(paths.yosys, yosysArgs, {
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

  // Per-task workdir so concurrent tasks do not clobber each other.
  // SymbiYosys resolves [files] relative to the process cwd (not the .sby
  // path), so we run with cwd = the directory that holds the task + props.
  const taskDir = dirname(abs);
  const taskName = basename(abs);
  const taskBase = taskName.replace(/\.sby$/i, "");
  const formalCfg = ctx.config.verify.formal ?? {};
  // `sby -j` bounds the solver processes one task may spawn. The .sby files
  // race two engines, so >1 here is what lets a single task use both cores it
  // asks for instead of serialising them.
  const jobs = formalCfg.jobs ?? recommendedJobs();

  // A task file with a [tasks] section expands to several runs, and sby rejects
  // `-d` for that ("Exactly one task is required when workdir is specified").
  // `--prefix` is the multi-task form: sby appends `_<task>` to it. Detect from
  // the file rather than from configuration so a sweep can be added to any .sby
  // without also editing the platform.
  let multiTask = false;
  try {
    multiTask = /^\s*\[tasks\]/m.test(readFileSync(abs, "utf8"));
  } catch {
    /* unreadable is handled by the existsSync check above */
  }

  const outRoot = formalCfg.workdirRoot
    ? (isAbsolute(formalCfg.workdirRoot)
        ? formalCfg.workdirRoot
        : join(ctx.repoRoot, formalCfg.workdirRoot))
    : join(ctx.paths.build, "formal");
  const outDir = join(outRoot, taskBase);
  mkdirSync(outDir, { recursive: true });

  // On Windows the managed toolchain is a set of Linux ELFs in the workspace;
  // they cannot be exec'd directly. Run them through WSL, translating the three
  // paths that cross the boundary. A solver workdir is deliberately NOT placed
  // on /mnt: DrvFs is slow for the many small files sby writes.
  if (ctx.host.os === "windows" && paths.formalSource !== "oss-cad") {
    if (!hasWsl()) {
      return {
        stage: "formal",
        target: taskFile,
        status: "skip",
        detail: "formal toolchain is a Linux build and wsl is not available",
        durationMs: elapsed(started),
      };
    }
    const sbyWsl = await windowsPathToWsl(paths.sby);
    const dirWsl = await windowsPathToWsl(taskDir);
    // Native-FS workdir under the WSL home keeps the solver off DrvFs.
    const outWsl = `$HOME/.cache/g6lc-formal-run/${taskBase}`;
    const outFlag = multiTask ? `--prefix ${outWsl}` : `-d ${outWsl}`;
    const cmd = [
      `mkdir -p $(dirname ${outWsl})`,
      `cd ${JSON.stringify(dirWsl)}`,
      `${JSON.stringify(sbyWsl)} -f -j ${jobs} ${outFlag} ${JSON.stringify(taskName)}`,
    ].join(" && ");
    const wres = await run("wsl", wslCommand(cmd), {
      cwd: ctx.repoRoot,
      stdio: "capture",
      allowFailure: true,
      dryRun: ctx.dryRun,
      logger: ctx.logger,
    });
    return summarise("formal", taskFile, wres, null, started);
  }

  const outArgs = multiTask ? ["--prefix", outDir] : ["-d", outDir];
  const result = await run(paths.sby, ["-f", "-j", String(jobs), ...outArgs, taskName], {
    cwd: taskDir,
    env: edaEnv(ctx, paths, ctx.config.soc.coreConfig),
    stdio: "capture",
    allowFailure: true,
    dryRun: ctx.dryRun,
    logger: ctx.logger,
  });

  return summarise("formal", taskFile, result, null, started);
}

/** Remote layout used by verif/regress/remote/testharness_proxy.py. */
const REMOTE_REPO = "/opt/testharness/repo";
const REMOTE_FORMAL = "/opt/testharness/toolchains/formal";

/**
 * Bash run remotely to provision the toolchain once and then execute every
 * task, emitting one `RESULT ...` line per task.
 *
 * Everything happens in a single remote shell on purpose: the point of the
 * remote path is to pay one SSH round trip for the whole suite rather than one
 * per task, and to let the builder's core count drive `sby -j`.
 */
function remoteFormalScript(tasks: { rel: string; dir: string; name: string; multi: boolean }[]): string {
  const lines = [
    "set -u",
    `REPO=${REMOTE_REPO}`,
    `FORMAL=${REMOTE_FORMAL}`,
    'J="$(nproc 2>/dev/null || echo 4)"',
    // install-formal.sh is idempotent and adopts an existing install, so this is
    // a no-op after the first run.
    'if [ ! -x "$FORMAL/bin/sby" ] || [ ! -x "$FORMAL/bin/yosys" ]; then',
    '  echo "[formal] provisioning remote toolchain -> $FORMAL"',
    '  FORMAL_INSTALL_DIR="$FORMAL" FORMAL_BUILD_DIR="$HOME/.cache/g6lc-formal" \\',
    '    NUM_JOBS="$J" bash "$REPO/build-platform/scripts/install-formal.sh" \\',
    '      || { echo "RESULT_TOOLCHAIN fail"; exit 3; }',
    "fi",
    'export PATH="$FORMAL/bin:$PATH"',
    // Solver workdirs go on the builder's own filesystem, never a mount.
    'RUNROOT="$HOME/.cache/g6lc-formal-run"',
    'mkdir -p "$RUNROOT"',
    '"$FORMAL/bin/yosys" -V || true',
  ];
  for (const t of tasks) {
    const base = t.name.replace(/\.sby$/i, "");
    const flag = t.multi ? "--prefix" : "-d";
    lines.push(
      `( cd "$REPO/${t.dir}" && "$FORMAL/bin/sby" -f -j "$J" ${flag} "$RUNROOT/${base}" ${JSON.stringify(t.name)} ) > "$RUNROOT/${base}.log" 2>&1`,
      `rc=$?`,
      `st="$(grep -oE 'DONE \\([A-Z]+' "$RUNROOT/${base}.log" | tail -1 | sed 's/DONE (//')"`,
      `echo "RESULT ${t.rel} rc=$rc status=\${st:-UNKNOWN}"`,
    );
  }
  return lines.join("\n") + "\n";
}

/**
 * Run the formal suite on the remote testharness builder.
 *
 * Uses the same transport as the rest of the MT evidence path
 * (`verif/regress/remote-testharness.sh`, which owns the SSH ControlMaster and
 * reads the key passphrase from `$TH_SSH_PASSPHRASE` or an untracked file --
 * this function never handles a credential).
 */
async function runFormalTasksRemote(
  ctx: PlatformContext,
  tasks: string[],
): Promise<StageOutcome[]> {
  const started = performance.now();
  const fail = (detail: string): StageOutcome[] =>
    tasks.map((t) => ({
      stage: "formal" as const,
      target: t,
      status: "fail" as const,
      detail,
      durationMs: elapsed(started),
    }));

  const wrapper = "verif/regress/remote-testharness.sh";
  if (!existsSync(join(ctx.repoRoot, wrapper))) {
    return fail(`${wrapper} missing; remote formal needs the testharness proxy`);
  }

  const specs = tasks.map((rel) => {
    const abs = isAbsolute(rel) ? rel : join(ctx.repoRoot, rel);
    let multi = false;
    try {
      multi = /^\s*\[tasks\]/m.test(readFileSync(abs, "utf8"));
    } catch {
      /* reported as UNKNOWN below */
    }
    const norm = rel.replace(/\\/g, "/");
    const slash = norm.lastIndexOf("/");
    return {
      rel: norm,
      dir: slash >= 0 ? norm.slice(0, slash) : ".",
      name: slash >= 0 ? norm.slice(slash + 1) : norm,
      multi,
    };
  });

  const scriptDir = join(ctx.paths.build, "formal");
  mkdirSync(scriptDir, { recursive: true });
  const scriptPath = join(scriptDir, "remote-formal.sh");
  writeFileSync(scriptPath, remoteFormalScript(specs), "utf8");

  // The proxy is a Python program driven through bash; on Windows that means
  // WSL, and the script path has to cross the boundary too.
  const onWindows = ctx.host.os === "windows";
  if (onWindows && !hasWsl()) {
    return fail("remote formal needs bash; wsl is not available on this host");
  }
  const scriptArg = onWindows ? await windowsPathToWsl(scriptPath) : scriptPath;
  const repoArg = onWindows ? await windowsPathToWsl(ctx.repoRoot) : ctx.repoRoot;
  const hostFlag = ctx.config.verify.formal?.remoteHost
    ? ` --host ${ctx.config.verify.formal.remoteHost}`
    : "";
  // Raise the proxy's one-shot safety net. `shell` defaults to 60s
  // (DEFAULT_SHELL_TIMEOUT), which is right for an interactive query and wrong
  // for a formal suite -- being cut off mid-suite surfaces as "no RESULT line"
  // for every task after the cutoff rather than as a timeout. Note that
  // `--timeout 0` does NOT disable it for this subcommand: cmd_shell treats a
  // non-positive value as "use the default", so an explicit large value is
  // required. It is a GLOBAL flag and must precede the subcommand.
  const budget = Math.max(600, 300 * tasks.length);
  const posix =
    `cd ${JSON.stringify(repoArg)} && ` +
    `bash ${wrapper}${hostFlag} sync && ` +
    `bash ${wrapper}${hostFlag} --timeout ${budget} shell --cmd-file ${JSON.stringify(scriptArg)}`;

  ctx.logger.info(`formal: remote via ${wrapper} (${tasks.length} task(s), sby -j = remote nproc)`);

  // The proxy reads its key passphrase from $TH_SSH_PASSPHRASE or an untracked
  // file. Forward the variables by NAME through WSLENV when they are present in
  // this process's environment: the value crosses as an environment variable, so
  // it never appears in argv, in a log line, or anywhere in the repository. If
  // neither is set the proxy falls back to ~/.config/librecore/th-remote.pass.
  const forward = ["TH_SSH_PASSPHRASE", "TH_REMOTE_HOST"].filter((k) => process.env[k]);
  const wslEnv: Record<string, string> = {};
  if (forward.length > 0) {
    const existing = process.env.WSLENV ? `${process.env.WSLENV}:` : "";
    wslEnv.WSLENV = existing + forward.join(":");
  }

  const res = onWindows
    ? await run("wsl", wslCommand(posix), {
        cwd: ctx.repoRoot,
        env: { ...process.env, ...wslEnv } as Record<string, string>,
        stdio: "capture",
        allowFailure: true,
        dryRun: ctx.dryRun,
        logger: ctx.logger,
      })
    : await run("bash", ["-lc", posix], {
        cwd: ctx.repoRoot,
        stdio: "capture",
        allowFailure: true,
        dryRun: ctx.dryRun,
        logger: ctx.logger,
      });

  const out = `${res.stdout}\n${res.stderr}`;
  if (/RESULT_TOOLCHAIN fail/.test(out)) {
    return fail("remote toolchain provisioning failed (needs cmake>=3.28, ninja, g++>=11)");
  }

  // Classify from the emitted RESULT lines, not from the transport's exit code:
  // an SSH drop is rc=255 and says nothing about any proof.
  const seen = new Map<string, { rc: number; status: string }>();
  for (const m of out.matchAll(/^RESULT (\S+) rc=(\d+) status=(\S+)/gm)) {
    seen.set(m[1] as string, { rc: Number(m[2]), status: (m[3] as string).toUpperCase() });
  }
  if (seen.size === 0) {
    return fail(
      `no RESULT lines from the remote run (transport exit ${res.code}); ` +
        "check the proxy credentials and that `sync` succeeded",
    );
  }

  const durationMs = elapsed(started);
  return specs.map((s) => {
    const r = seen.get(s.rel);
    if (!r) {
      return {
        stage: "formal" as const,
        target: s.rel,
        status: "fail" as const,
        detail: "no RESULT line for this task",
        durationMs,
      };
    }
    const pass = r.status === "PASS" && r.rc === 0;
    return {
      stage: "formal" as const,
      target: s.rel,
      status: pass ? ("pass" as const) : ("fail" as const),
      detail: `remote ${r.status} (rc=${r.rc})`,
      durationMs,
    };
  });
}

/**
 * Run every configured formal task, several at a time.
 *
 * These proofs are small and numerous, so total wall time is dominated by how
 * many run concurrently rather than by any one solver call. Task-level
 * concurrency is bounded separately from `sby -j` so the two multiply out to
 * roughly one core each rather than oversubscribing the host.
 */
export async function runFormalTasks(
  ctx: PlatformContext,
  paths: EdaPaths,
  tasks: string[],
): Promise<StageOutcome[]> {
  if (tasks.length === 0) return [];
  const formalCfg = ctx.config.verify.formal ?? {};
  // Remote first: it replaces the whole local dispatch, including the tool
  // resolution, because the builder provisions its own toolchain.
  if (formalCfg.remote) return runFormalTasksRemote(ctx, tasks);
  const cores = recommendedJobs();
  const perTask = formalCfg.jobs ?? cores;
  const defaultTaskJobs = Math.max(1, Math.min(tasks.length, Math.floor(cores / Math.max(1, perTask)) || 1));
  const taskJobs = Math.max(1, formalCfg.taskJobs ?? defaultTaskJobs);

  if (taskJobs === 1) {
    const out: StageOutcome[] = [];
    for (const t of tasks) out.push(await formalTask(ctx, paths, t));
    return out;
  }

  const results: StageOutcome[] = new Array(tasks.length);
  let next = 0;
  const worker = async (): Promise<void> => {
    for (;;) {
      const i = next++;
      if (i >= tasks.length) return;
      results[i] = await formalTask(ctx, paths, tasks[i] as string);
    }
  };
  await Promise.all(Array.from({ length: Math.min(taskJobs, tasks.length) }, worker));
  return results;
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
