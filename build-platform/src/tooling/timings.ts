// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// timings.ts — host adapter for the standalone `sv-timing/` package.
//
// Lives in build-platform (host), not inside sv-timing crates. Responsibilities:
//   1. Flatten monorepo / EDA flists (env + nested -F) via eda.flattenFlist
//   2. Write a portable `.f` the package CLI understands (+incdir+, paths)
//   3. Build argv for `sv-timing` analyze / correct (spawned by the host)
//
// The package itself remains monorepo-independent: hosts prepare inputs and
// consume JSON / emit trees. See sv-timing/AGENTS-host.md.

import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";

import type { PlatformContext } from "../context.ts";
import { flattenFlist, posixPath, type FlatManifest } from "./eda.ts";

// ---------------------------------------------------------------------------
// Compile out-dir layout (--output / --out)
// ---------------------------------------------------------------------------
//
// A self-contained timings precompile package that validate --from-timing and
// soak consumers understand:
//
//   <output>/
//     portable.f
//     analyze.json | correct.json
//     param-map.json
//     ir.sqlite          (optional IR cache)
//     stamp.json         (host metadata)
//     corrected/         (optional emit tree)
//

export interface TimingsOutputLayout {
  /** Absolute path of the out-dir root. */
  dir: string;
  portableF: string;
  analyzeJson: string;
  correctJson: string;
  paramMap: string;
  cache: string;
  stamp: string;
  correctedDir: string;
}

/**
 * Resolve `--output` / `--out` to an absolute out-dir and canonical file paths.
 * Relative specs resolve under repoRoot, then under workspace/build/sv-timing/.
 */
export function resolveTimingsOutputDir(
  ctx: PlatformContext,
  spec: string | undefined,
  opts: { tag?: string; create?: boolean } = {},
): TimingsOutputLayout {
  const tag = opts.tag ?? "default";
  let dir: string;
  if (spec == null || spec.trim() === "") {
    dir = join(ctx.paths.build, "sv-timing", tag);
  } else if (isAbsolute(spec) || /^[A-Za-z]:[\\/]/.test(spec)) {
    dir = resolve(spec);
  } else {
    // Operators often type workspace/build/... meaning the managed workspace.
    const underRepo = resolve(ctx.repoRoot, spec);
    const underCwd = resolve(process.cwd(), spec);
    const underBuildSv = resolve(ctx.paths.build, "sv-timing", spec);
    // Prefer managed workspace when path starts with "workspace/".
    if (/^workspace[/\\]/i.test(spec)) {
      dir = resolve(ctx.paths.root, spec.replace(/^workspace[/\\]/i, ""));
    } else if (/^build-platform[/\\]workspace[/\\]/i.test(spec)) {
      dir = underRepo;
    } else if (existsSync(underRepo)) dir = underRepo;
    else if (existsSync(underBuildSv)) dir = underBuildSv;
    else if (existsSync(underCwd)) dir = underCwd;
    else dir = underRepo;
  }
  if (opts.create !== false) {
    mkdirSync(dir, { recursive: true });
  }
  return {
    dir: posixPath(dir),
    portableF: posixPath(join(dir, "portable.f")),
    analyzeJson: posixPath(join(dir, "analyze.json")),
    correctJson: posixPath(join(dir, "correct.json")),
    paramMap: posixPath(join(dir, "param-map.json")),
    cache: posixPath(join(dir, "ir.sqlite")),
    stamp: posixPath(join(dir, "stamp.json")),
    correctedDir: posixPath(join(dir, "corrected")),
  };
}

export interface TimingsStamp {
  kind: "analyze" | "correct" | "compile";
  target: string;
  targetMhz?: number;
  modules?: string[];
  allModules?: boolean;
  command: string;
  exitCode: number;
  mtimeMs: number;
  portableF: string;
  reportJson: string;
  paramMap?: string;
  emitDir?: string;
  schema?: string;
}

/** Write host stamp.json next to analyze/correct artifacts. */
export function writeTimingsStamp(
  layout: TimingsOutputLayout,
  stamp: TimingsStamp,
): string {
  mkdirSync(layout.dir, { recursive: true });
  writeFileSync(layout.stamp, JSON.stringify(stamp, null, 2) + "\n", "utf8");
  return layout.stamp;
}

// ---------------------------------------------------------------------------
// T3b — soak dashboard (structural FO4 summary; not STA)
// ---------------------------------------------------------------------------

export interface TimingsPathHot {
  pathId?: number;
  kind?: string;
  start?: string;
  end?: string;
  totalFo4: number;
  slackFo4?: number;
  maxFreqMhz?: number;
  closes?: boolean;
  /** Soft multi-cycle / atomic — excluded from primary FO4 ranking */
  multiCycle?: boolean;
  pathClass?: string;
}

export interface TimingsSoakDashboard {
  /** Package or report path. */
  source: string;
  reportJson: string | null;
  ok: boolean;
  note: string;
  targetMhz?: number;
  fo4Ps?: number;
  budgetFo4?: number;
  pathCount: number;
  moduleCount: number;
  opportunityCount: number;
  staHintCount: number;
  filesParsed?: number;
  /** frequency_closure.closes when present */
  closes?: boolean;
  maxFreqMhz?: number;
  worstSlackFo4?: number;
  worstPathFo4?: number;
  failingPaths?: number;
  worstStart?: string;
  worstEnd?: string;
  /** Top primary (non multi_cycle) paths by total_fo4, then multi_cycle tails */
  hottest: TimingsPathHot[];
  /** Count of multi_cycle paths omitted from primary ranking */
  multiCyclePathCount?: number;
  stampExitCode?: number;
  issues: string[];
}

function num(v: unknown): number | undefined {
  return typeof v === "number" && Number.isFinite(v) ? v : undefined;
}

function str(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

/**
 * Build a soak dashboard from a timings out-dir or a direct analyze/correct JSON path.
 * Structural FO4 only — disclaimer is always structural-not-STA.
 */
export function summarizeTimingsPackage(
  ctx: PlatformContext,
  fromTimingOrJson: string,
  opts: { topN?: number } = {},
): TimingsSoakDashboard {
  const topN = opts.topN ?? 5;
  const note = "structural FO4 estimates only — not STA sign-off";
  const issues: string[] = [];

  let dirOrFile = fromTimingOrJson;
  if (!isAbsolute(fromTimingOrJson) && !/^[A-Za-z]:[\\/]/.test(fromTimingOrJson)) {
    // Prefer package dir resolution when not a .json path
    if (!fromTimingOrJson.toLowerCase().endsWith(".json")) {
      dirOrFile = resolveFromTimingDir(ctx, fromTimingOrJson);
    } else {
      const underRepo = resolve(ctx.repoRoot, fromTimingOrJson);
      dirOrFile = existsSync(underRepo) ? underRepo : resolve(process.cwd(), fromTimingOrJson);
    }
  } else {
    dirOrFile = resolve(fromTimingOrJson);
  }

  let reportJson: string | null = null;
  let source = posixPath(dirOrFile);

  if (existsSync(dirOrFile) && dirOrFile.toLowerCase().endsWith(".json")) {
    reportJson = dirOrFile;
    source = posixPath(dirname(dirOrFile));
  } else {
    const v = validateTimingsOutDir(ctx, {
      fromTiming: dirOrFile,
      checkSourcePaths: false,
    });
    source = v.dir;
    reportJson = v.reportJson;
    if (!v.ok) {
      for (const i of v.issues.filter((x) => x.level === "error")) {
        issues.push(`[${i.code}] ${i.message}`);
      }
    }
  }

  const stamp = readStampIfPresent(source);

  if (!reportJson || !existsSync(reportJson)) {
    return {
      source,
      reportJson: null,
      ok: false,
      note,
      pathCount: 0,
      moduleCount: 0,
      opportunityCount: 0,
      staHintCount: 0,
      hottest: [],
      stampExitCode: stamp?.exitCode,
      issues: issues.length ? issues : ["no analyze.json/correct.json to summarize"],
    };
  }

  let raw: Record<string, unknown>;
  try {
    raw = JSON.parse(readFileSync(reportJson, "utf8")) as Record<string, unknown>;
  } catch (e) {
    return {
      source,
      reportJson: posixPath(reportJson),
      ok: false,
      note,
      pathCount: 0,
      moduleCount: 0,
      opportunityCount: 0,
      staHintCount: 0,
      hottest: [],
      stampExitCode: stamp?.exitCode,
      issues: [`report parse failed: ${e instanceof Error ? e.message : String(e)}`],
    };
  }

  const paths = Array.isArray(raw.paths) ? (raw.paths as Record<string, unknown>[]) : [];
  const modules = Array.isArray(raw.modules) ? raw.modules : [];
  const opportunities = Array.isArray(raw.opportunities) ? raw.opportunities : [];
  const staHints = Array.isArray(raw.sta_hints) ? raw.sta_hints : [];
  const ast = (raw.ast ?? {}) as Record<string, unknown>;
  // analyze.json uses frequency_closure; correct.json uses post_closure (primary after transforms).
  let closure = (raw.frequency_closure ?? raw.post_closure ?? {}) as Record<string, unknown>;
  let reportNote = note;
  // When the loaded report is analyze.json but correct.json exists beside it, overlay
  // post_closure so host dashboard shows post-correct primary FO4 (not pre-BalanceMux).
  const pkgDir = source;
  const correctBeside = join(pkgDir, "correct.json");
  if (
    reportJson.toLowerCase().endsWith("analyze.json") &&
    existsSync(correctBeside)
  ) {
    try {
      const cj = JSON.parse(readFileSync(correctBeside, "utf8")) as Record<string, unknown>;
      const post = (cj.post_closure ?? {}) as Record<string, unknown>;
      if (typeof post.closes === "boolean" || post.worst_path_fo4 != null) {
        closure = { ...closure, ...post };
        reportNote =
          "structural FO4 estimates only — not STA sign-off; closure from correct.json post_closure";
      }
    } catch {
      /* keep analyze closure */
    }
  }

  const scored: TimingsPathHot[] = paths.map((p) => ({
    pathId: num(p.path_id),
    kind: str(p.path_kind),
    start: str(p.startpoint),
    end: str(p.endpoint),
    totalFo4: num(p.total_fo4) ?? 0,
    slackFo4: num(p.slack_fo4),
    maxFreqMhz: num(p.max_freq_mhz),
    closes: typeof p.closes === "boolean" ? p.closes : undefined,
    multiCycle: p.multi_cycle === true,
    pathClass: str(p.path_class),
  }));
  // Primary first (single-cycle screening), then multi_cycle tails by FO4.
  scored.sort((a, b) => {
    const am = a.multiCycle ? 1 : 0;
    const bm = b.multiCycle ? 1 : 0;
    if (am !== bm) return am - bm;
    return b.totalFo4 - a.totalFo4;
  });
  const multiCyclePathCount = scored.filter((p) => p.multiCycle).length;

  const dashboard: TimingsSoakDashboard = {
    source,
    reportJson: posixPath(reportJson),
    ok: true,
    note: reportNote,
    targetMhz: num(raw.target_mhz) ?? num(closure.target_mhz),
    fo4Ps: num(raw.fo4_ps),
    budgetFo4: num(raw.budget_fo4) ?? num(closure.budget_fo4),
    pathCount: paths.length || (num(ast.path_count) ?? 0),
    moduleCount: modules.length || (num(ast.module_count) ?? 0),
    opportunityCount: opportunities.length || (num(ast.opportunity_count) ?? 0),
    staHintCount: staHints.length,
    filesParsed: num(ast.files_parsed),
    closes: typeof closure.closes === "boolean" ? closure.closes : undefined,
    maxFreqMhz: num(closure.max_freq_mhz),
    worstSlackFo4: num(closure.worst_slack_fo4),
    worstPathFo4: num(closure.worst_path_fo4),
    failingPaths: num(closure.failing_paths),
    worstStart: str(closure.worst_startpoint),
    worstEnd: str(closure.worst_endpoint),
    hottest: scored.slice(0, topN),
    multiCyclePathCount,
    stampExitCode: stamp?.exitCode,
    issues,
  };
  return dashboard;
}

function readStampIfPresent(dir: string): { exitCode?: number } | null {
  const p = join(dir, "stamp.json");
  if (!existsSync(p)) return null;
  try {
    const j = JSON.parse(readFileSync(p, "utf8")) as Record<string, unknown>;
    return { exitCode: typeof j.exitCode === "number" ? j.exitCode : undefined };
  } catch {
    return null;
  }
}

/** Human lines for logger (heading separate). */
export function formatTimingsDashboardLines(d: TimingsSoakDashboard): string[] {
  const lines: string[] = [];
  lines.push(`source   : ${d.source}`);
  if (d.reportJson) lines.push(`report   : ${d.reportJson}`);
  lines.push(`note     : ${d.note}`);
  if (!d.ok) {
    for (const i of d.issues) lines.push(`issue    : ${i}`);
    return lines;
  }
  const tgt = d.targetMhz != null ? `${d.targetMhz} MHz` : "—";
  const budget = d.budgetFo4 != null ? `${d.budgetFo4.toFixed(1)} FO4` : "—";
  const fo4ps = d.fo4Ps != null ? `${d.fo4Ps} ps` : "—";
  lines.push(`target   : ${tgt}   budget: ${budget}   fo4_ps: ${fo4ps}`);
  lines.push(
    `counts   : paths=${d.pathCount}  modules=${d.moduleCount}  opps=${d.opportunityCount}  sta_hints=${d.staHintCount}` +
      (d.filesParsed != null ? `  files_parsed=${d.filesParsed}` : ""),
  );
  if (d.closes !== undefined || d.maxFreqMhz != null) {
    const cl = d.closes === true ? "CLOSES" : d.closes === false ? "MISS" : "—";
    const maxf = d.maxFreqMhz != null ? `${d.maxFreqMhz.toFixed(1)} MHz` : "—";
    const fail = d.failingPaths != null ? String(d.failingPaths) : "—";
    const wfo4 = d.worstPathFo4 != null ? d.worstPathFo4.toFixed(1) : "—";
    const wsl = d.worstSlackFo4 != null ? d.worstSlackFo4.toFixed(1) : "—";
    lines.push(
      `closure  : ${cl}  max_freq≈${maxf}  failing=${fail}  worst_path=${wfo4} FO4  slack=${wsl}`,
    );
    if (d.worstStart || d.worstEnd) {
      lines.push(`worst    : ${d.worstStart ?? "?"} → ${d.worstEnd ?? "?"}`);
    }
  }
  if (d.hottest.length) {
    const mcN = d.multiCyclePathCount ?? 0;
    lines.push(
      mcN > 0
        ? `hottest  : (primary first, then multi_cycle; ${mcN} multi_cycle path(s) total)`
        : "hottest  : (by total FO4, primary first)",
    );
    for (const h of d.hottest) {
      const id = h.pathId != null ? `#${h.pathId}` : "#?";
      const kind = h.kind ?? "?";
      const tag = h.multiCycle ? " multi_cycle" : "";
      const cls = h.pathClass ? ` ${h.pathClass}` : "";
      lines.push(
        `  ${id.padEnd(5)} ${h.totalFo4.toFixed(1).padStart(8)} FO4  ${kind.padEnd(12)}  ${h.start ?? "?"} → ${h.end ?? "?"}${tag}${cls}`,
      );
    }
  }
  if (d.stampExitCode != null) {
    lines.push(`stamp    : exitCode=${d.stampExitCode}`);
  }
  for (const i of d.issues) lines.push(`warn     : ${i}`);
  return lines;
}

/** Write soak-dashboard.json next to a timings package (optional artifact). */
export function writeTimingsDashboard(
  dir: string,
  dashboard: TimingsSoakDashboard,
): string {
  const out = join(dir, "soak-dashboard.json");
  mkdirSync(dir, { recursive: true });
  writeFileSync(out, JSON.stringify(dashboard, null, 2) + "\n", "utf8");
  return posixPath(out);
}

/**
 * Preflight --from-timing for host commands. Optionally resolve emit flist for
 * expert --use-emit (never auto-merges into core/).
 */
export function applyFromTimingFlags(
  ctx: PlatformContext,
  opts: {
    fromTiming?: string;
    useEmit?: boolean;
    requireEmit?: boolean;
  },
): {
  ok: boolean;
  dir?: string;
  emitFlist?: string;
  env: Record<string, string>;
  issues: TimingsValidateIssue[];
  validation?: TimingsValidateResult;
} {
  if (!opts.fromTiming) {
    return { ok: true, env: {}, issues: [] };
  }
  const validation = validateTimingsOutDir(ctx, {
    fromTiming: opts.fromTiming,
    requireEmit: opts.requireEmit || opts.useEmit === true,
  });
  if (!validation.ok) {
    return {
      ok: false,
      dir: validation.dir,
      env: {},
      issues: validation.issues,
      validation,
    };
  }
  const env: Record<string, string> = {
    CVA6_FROM_TIMING: validation.dir,
    FROM_TIMING: validation.dir,
  };
  let emitFlist: string | undefined;
  if (opts.useEmit) {
    emitFlist = validation.correctedFlist ?? undefined;
    if (!emitFlist) {
      return {
        ok: false,
        dir: validation.dir,
        env,
        issues: [
          ...validation.issues,
          {
            level: "error",
            code: "use-emit-missing",
            message:
              "--use-emit requires corrected flist (timings correct --emit -o <dir>)",
          },
        ],
        validation,
      };
    }
    env.CVA6_TIMINGS_EMIT_FLIST = emitFlist;
    env.CVA6_TIMINGS_USE_EMIT = "1";
  }
  return {
    ok: true,
    dir: validation.dir,
    emitFlist,
    env,
    issues: validation.issues,
    validation,
  };
}

/** Options when materializing a portable filelist for sv-timing. */
export interface TimingsFlistOptions {
  /** Absolute or repo-relative path to the entry flist. */
  entryFlist: string;
  /** Env map for ${VAR} / $VAR expansion (e.g. edaEnv(ctx, paths, target)). */
  env: Record<string, string>;
  /** Working directory used for -f resolution (default: ctx.repoRoot). */
  cwd?: string;
  /**
   * Where to write the portable `.f`. Default:
   * `$paths.build/sv-timing/<tag>/portable.f`
   */
  outPath?: string;
  /** Filename tag when using the default outPath (default: "default"). */
  tag?: string;
  /** Extra include dirs merged after flatten (absolute or repo-relative). */
  extraIncdirs?: string[];
  /** Extra source files merged after flatten. */
  extraFiles?: string[];
  /** Optional +define+ NAME or NAME=VAL lines. */
  defines?: string[];
}

/** Result of writing a portable filelist for sv-timing. */
export interface TimingsPortableFlist {
  /** Absolute POSIX path of the portable `.f`. */
  portablePath: string;
  /** Flattened source files (absolute POSIX). */
  files: string[];
  /** Flattened include directories (absolute POSIX). */
  incdirs: string[];
  /** Defines as "NAME" or "NAME=VAL". */
  defines: string[];
}

/** Locate the standalone sv-timing package root (repo-relative). */
export function resolveSvTimingRoot(ctx: PlatformContext): string | null {
  const candidates = [
    join(ctx.repoRoot, "sv-timing"),
    // Nested worktrees / alternate layouts
    join(ctx.repoRoot, "tools", "sv-timing"),
  ];
  for (const c of candidates) {
    if (existsSync(join(c, "Cargo.toml")) && existsSync(join(c, "tools", "svt.py"))) {
      return posixPath(c);
    }
  }
  return null;
}

function absPosix(root: string, p: string): string {
  if (isAbsolute(p) || /^[A-Za-z]:/.test(p)) return posixPath(p);
  return posixPath(join(root, p));
}

/**
 * Flatten a host flist (with env / nested -F) and write a **portable** `.f`
 * suitable for `sv-timing --files-from`.
 *
 * Mirrors the package's portable grammar: +incdir+, +define+, bare paths.
 * Does not invoke the Rust CLI; pure host prep.
 */
export function writePortableTimingsFlist(
  ctx: PlatformContext,
  opts: TimingsFlistOptions,
): TimingsPortableFlist {
  const cwd = posixPath(opts.cwd ?? ctx.repoRoot);
  const entry = absPosix(ctx.repoRoot, opts.entryFlist);
  if (!existsSync(entry)) {
    throw new Error(`timings flist not found: ${entry}`);
  }

  const flat = flattenFlist(entry, opts.env, cwd);
  const files = [...flat.files];
  const incdirs = [...flat.incdirs];
  for (const d of opts.extraIncdirs ?? []) {
    const a = absPosix(ctx.repoRoot, d);
    if (!incdirs.includes(a)) incdirs.push(a);
  }
  for (const f of opts.extraFiles ?? []) {
    const a = absPosix(ctx.repoRoot, f);
    if (!files.includes(a)) files.push(a);
  }
  const defines = [...(opts.defines ?? [])];

  const tag = opts.tag ?? "default";
  const outPath = opts.outPath
    ? absPosix(ctx.repoRoot, opts.outPath)
    : posixPath(join(ctx.paths.build, "sv-timing", tag, "portable.f"));

  mkdirSync(dirname(outPath), { recursive: true });

  const lines: string[] = [
    "# portable filelist for sv-timing — generated by build-platform timings.ts",
    `# entry=${entry}`,
    `# host=${posixPath(ctx.repoRoot)}`,
  ];
  for (const d of incdirs) {
    lines.push(`+incdir+${d}`);
  }
  for (const def of defines) {
    lines.push(`+define+${def}`);
  }
  for (const f of files) {
    lines.push(f);
  }
  writeFileSync(outPath, lines.join("\n") + "\n", "utf8");

  return {
    portablePath: outPath,
    files,
    incdirs,
    defines,
  };
}

/** Build argv for the sv-timing CLI (analyze). Does not spawn. */
export function buildSvTimingAnalyzeArgs(opts: {
  portableFlist: string;
  modules?: string[];
  allModules?: boolean;
  targetMhz?: number;
  fo4Ps?: number;
  cache?: string;
  jsonOut?: string;
  paramMap?: string;
  assumeXlen?: number;
  packageMode?: "off" | "packages";
}): string[] {
  const args = ["analyze", "--files-from", opts.portableFlist];
  if (opts.allModules) {
    args.push("--all-modules");
  } else if (opts.modules && opts.modules.length > 0) {
    args.push("--modules", opts.modules.join(","));
  }
  if (opts.targetMhz !== undefined) {
    args.push("--target-mhz", String(opts.targetMhz));
  }
  if (opts.fo4Ps !== undefined) {
    args.push("--fo4-ps", String(opts.fo4Ps));
  }
  if (opts.cache) {
    args.push("--cache", opts.cache);
  }
  if (opts.jsonOut) {
    args.push("--json-out", opts.jsonOut);
  }
  if (opts.paramMap) {
    args.push("--param-map", opts.paramMap);
  }
  if (opts.assumeXlen !== undefined) {
    args.push("--assume-xlen", String(opts.assumeXlen));
  }
  if (opts.packageMode) {
    args.push("--package-mode", opts.packageMode);
  }
  return args;
}

/** Build argv for the sv-timing CLI (correct + optional emit). Does not spawn. */
export function buildSvTimingCorrectArgs(opts: {
  portableFlist: string;
  modules?: string[];
  allModules?: boolean;
  targetMhz?: number;
  allowLatency?: boolean;
  assumeClk?: boolean;
  emit?: boolean;
  outDir?: string;
  jsonOut?: string;
  cache?: string;
  paramMap?: string;
  assumeXlen?: number;
  packageMode?: "off" | "packages";
}): string[] {
  const args = ["correct", "--files-from", opts.portableFlist];
  if (opts.allModules) {
    args.push("--all-modules");
  } else if (opts.modules && opts.modules.length > 0) {
    args.push("--modules", opts.modules.join(","));
  }
  if (opts.targetMhz !== undefined) {
    args.push("--target-mhz", String(opts.targetMhz));
  }
  if (opts.allowLatency) args.push("--allow-latency");
  if (opts.assumeClk) args.push("--assume-clk");
  if (opts.emit) args.push("--emit");
  if (opts.outDir) args.push("--out-dir", opts.outDir);
  if (opts.cache) args.push("--cache", opts.cache);
  if (opts.jsonOut) args.push("--json-out", opts.jsonOut);
  if (opts.paramMap) {
    args.push("--param-map", opts.paramMap);
  }
  if (opts.assumeXlen !== undefined) {
    args.push("--assume-xlen", String(opts.assumeXlen));
  }
  if (opts.packageMode) {
    args.push("--package-mode", opts.packageMode);
  }
  return args;
}

/**
 * Write a host param-map JSON for sv-timing (`--param-map`).
 * Keys are free-form; XLEN-related entries help hierarchical dims.
 */
export function writeHostParamMap(
  ctx: PlatformContext,
  opts: {
    outPath?: string;
    xlen?: number;
    extra?: Record<string, number | string | boolean>;
  } = {},
): string {
  const xlen = opts.xlen ?? ctx.config.soc.xlen ?? 64;
  const outPath = opts.outPath
    ? absPosix(ctx.repoRoot, opts.outPath)
    : posixPath(join(ctx.paths.build, "sv-timing", "param-map.json"));
  mkdirSync(dirname(outPath), { recursive: true });
  const body: Record<string, number | string | boolean> = {
    XLEN: xlen,
    "CVA6Cfg.XLEN": xlen,
    "cva6_cfg.XLEN": xlen,
    CVA6ConfigXlen: xlen,
    "CVA6Cfg.XLEN-1": Math.max(0, xlen - 1),
    ...(opts.extra ?? {}),
  };
  writeFileSync(outPath, JSON.stringify(body, null, 2) + "\n", "utf8");
  return outPath;
}

/**
 * Convenience: flatten verify.flist for a target into a portable timings list.
 * Requires callers to supply `edaEnv` as `env` (keeps this module free of
 * full EdaPaths coupling beyond flattenFlist).
 */
export function writeVerifyPortableFlist(
  ctx: PlatformContext,
  env: Record<string, string>,
  target: string,
  override: { flist?: string; tag?: string; outPath?: string } = {},
): TimingsPortableFlist {
  const flistRel = override.flist ?? ctx.config.verify?.flist ?? "core/Flist.cva6";
  return writePortableTimingsFlist(ctx, {
    entryFlist: flistRel,
    env,
    tag: override.tag ?? `verify-${target}`,
    outPath: override.outPath,
  });
}

/**
 * Minimal env for flist expansion without requiring a full OSS CAD Suite
 * install (CVA6_REPO_DIR / TARGET_CFG / HPDCACHE_DIR only).
 */
export function timingsRepoEnv(
  ctx: PlatformContext,
  target: string,
): Record<string, string> {
  return {
    CVA6_REPO_DIR: posixPath(ctx.repoRoot),
    TARGET_CFG: target,
    HPDCACHE_DIR: posixPath(
      join(ctx.repoRoot, "core", "cache_subsystem", "hpdcache"),
    ),
  };
}

/** Resolve host Python for spawning `tools/svt.py` (Windows `py -3` fallback). */
export function resolveHostPython(): string[] {
  if (process.env.SVT_PYTHON) return [process.env.SVT_PYTHON];
  if (process.platform === "win32") {
    return ["py", "-3"];
  }
  return ["python3"];
}

/**
 * Build a full `python tools/svt.py run -- <cli…>` invocation for the package.
 * Returns null when `sv-timing/` is missing.
 */
export function buildSvtRunCommand(
  ctx: PlatformContext,
  cliArgs: string[],
): { cwd: string; argv: string[] } | null {
  const root = resolveSvTimingRoot(ctx);
  if (!root) return null;
  const py = resolveHostPython();
  const svt = join(root, "tools", "svt.py");
  return {
    cwd: root,
    argv: [...py, svt, "run", "--", ...cliArgs],
  };
}

// ---------------------------------------------------------------------------
// --from-timing: structural validation of a precompile out-dir (host-only)
// ---------------------------------------------------------------------------

export interface TimingsValidateOptions {
  /** Absolute or repo-/cwd-relative path to timings out directory. */
  fromTiming: string;
  /** Fail if corrected emit tree is missing. */
  requireEmit?: boolean;
  /**
   * When true, check that source paths listed in portable.f exist on disk.
   * Soft-warns by default (missing paths become warnings, not errors).
   */
  checkSourcePaths?: boolean;
}

export interface TimingsValidateIssue {
  level: "error" | "warn";
  code: string;
  message: string;
}

export interface TimingsValidateResult {
  ok: boolean;
  dir: string;
  portableF: string | null;
  reportJson: string | null;
  reportKind: "analyze" | "correct" | null;
  paramMap: string | null;
  emitDir: string | null;
  correctedFlist: string | null;
  schemaHint: string | null;
  fileCount: number;
  issues: TimingsValidateIssue[];
}

/** Resolve --from-timing dir relative to repo root, workspace build, or cwd. */
export function resolveFromTimingDir(
  ctx: PlatformContext,
  spec: string,
): string {
  if (isAbsolute(spec) || /^[A-Za-z]:[\\/]/.test(spec)) {
    return resolve(spec);
  }
  if (/^workspace[/\\]/i.test(spec)) {
    return resolve(ctx.paths.root, spec.replace(/^workspace[/\\]/i, ""));
  }
  const candidates = [
    resolve(ctx.repoRoot, spec),
    resolve(ctx.paths.build, "sv-timing", spec),
    resolve(ctx.paths.build, spec),
    resolve(ctx.paths.root, spec),
    resolve(process.cwd(), spec),
  ];
  for (const c of candidates) {
    if (existsSync(c)) return c;
  }
  return resolve(ctx.repoRoot, spec);
}

function findFirstExisting(dir: string, names: string[]): string | null {
  for (const n of names) {
    const p = join(dir, n);
    if (existsSync(p)) return p;
  }
  return null;
}

/** Parse portable.f for bare source paths (skip directives/comments). */
export function parsePortableFlistPaths(content: string): string[] {
  const files: string[] = [];
  for (const line of content.split(/\r?\n/)) {
    const text = line.replace(/\/\/.*$/, "").replace(/^\s*#.*$/, "").trim();
    if (!text) continue;
    if (text.startsWith("+") || text.startsWith("-")) continue;
    files.push(text);
  }
  return files;
}

/**
 * Structural validation of a timings precompile output directory.
 * Does not invoke the Rust CLI. See architecture/build-platform-workspace-lifecycle.md §5.
 */
export function validateTimingsOutDir(
  ctx: PlatformContext,
  opts: TimingsValidateOptions,
): TimingsValidateResult {
  const dir = resolveFromTimingDir(ctx, opts.fromTiming);
  const issues: TimingsValidateIssue[] = [];
  const checkPaths = opts.checkSourcePaths !== false;

  if (!existsSync(dir)) {
    issues.push({
      level: "error",
      code: "dir-missing",
      message: `timings out-dir not found: ${dir}`,
    });
    return {
      ok: false,
      dir,
      portableF: null,
      reportJson: null,
      reportKind: null,
      paramMap: null,
      emitDir: null,
      correctedFlist: null,
      schemaHint: null,
      fileCount: 0,
      issues,
    };
  }

  // Prefer host-normalized flist when monorepo-soak ran under WSL
  const portableF = findFirstExisting(dir, [
    "portable.host.f",
    "portable.f",
    "analyze.f",
    "files.f",
  ]);
  if (!portableF) {
    issues.push({
      level: "error",
      code: "portable-missing",
      message: "expected portable.f (or analyze.f) in out-dir",
    });
  }

  let reportJson = findFirstExisting(dir, ["analyze.json", "correct.json"]);
  let reportKind: TimingsValidateResult["reportKind"] = null;
  if (reportJson?.endsWith("correct.json")) reportKind = "correct";
  else if (reportJson?.endsWith("analyze.json")) reportKind = "analyze";

  // Also accept any *.json that looks like analyze-result if canonical names missing
  if (!reportJson) {
    try {
      for (const name of readdirSync(dir)) {
        if (!name.endsWith(".json") || name === "param-map.json") continue;
        const p = join(dir, name);
        try {
          const raw = readFileSync(p, "utf8");
          const j = JSON.parse(raw) as Record<string, unknown>;
          if (
            j &&
            (typeof j.schema === "string" ||
              typeof j.schema_version === "string" ||
              Array.isArray(j.modules) ||
              Array.isArray(j.paths) ||
              j.design != null)
          ) {
            reportJson = p;
            reportKind = name.includes("correct") ? "correct" : "analyze";
            break;
          }
        } catch {
          /* try next */
        }
      }
    } catch {
      /* ignore */
    }
  }

  if (!reportJson) {
    issues.push({
      level: "error",
      code: "report-missing",
      message: "expected analyze.json or correct.json (analyze-result schema)",
    });
  }

  let schemaHint: string | null = null;
  if (reportJson) {
    try {
      const raw = readFileSync(reportJson, "utf8");
      const j = JSON.parse(raw) as Record<string, unknown>;
      if (typeof j.schema === "string") schemaHint = j.schema;
      else if (typeof j.schema_version === "string") schemaHint = j.schema_version;
      else if (typeof j.version === "string") schemaHint = j.version;
      else schemaHint = "unknown";
      // Soft accept: any parseable JSON object is structurally ok for v1 host gate.
      if (typeof j !== "object" || j === null || Array.isArray(j)) {
        issues.push({
          level: "error",
          code: "report-not-object",
          message: "report JSON root must be an object",
        });
      }
    } catch (e) {
      issues.push({
        level: "error",
        code: "report-parse",
        message: `failed to parse report JSON: ${e instanceof Error ? e.message : String(e)}`,
      });
    }
  }

  const paramMap = findFirstExisting(dir, ["param-map.json"]);
  if (!paramMap) {
    issues.push({
      level: "warn",
      code: "param-map-missing",
      message: "param-map.json not found (recommended for package mode)",
    });
  }

  let fileCount = 0;
  if (portableF) {
    try {
      const content = readFileSync(portableF, "utf8");
      const paths = parsePortableFlistPaths(content);
      fileCount = paths.length;
      if (paths.length === 0) {
        issues.push({
          level: "error",
          code: "portable-empty",
          message: "portable.f has no source file paths",
        });
      } else if (checkPaths) {
        let missing = 0;
        for (const p of paths.slice(0, 500)) {
          const abs =
            isAbsolute(p) || /^[A-Za-z]:[\\/]/.test(p)
              ? p
              : join(dirname(portableF), p);
          if (!existsSync(abs)) missing++;
        }
        if (missing > 0) {
          issues.push({
            level: "warn",
            code: "sources-missing",
            message: `${missing} portable.f path(s) not found on disk (checked up to 500)`,
          });
        }
      }
    } catch (e) {
      issues.push({
        level: "error",
        code: "portable-read",
        message: `failed to read portable.f: ${e instanceof Error ? e.message : String(e)}`,
      });
    }
  }

  // Emit tree detection
  const emitCandidates = [
    join(dir, "corrected"),
    join(dir, "emit"),
    join(dir, "out"),
  ];
  let emitDir: string | null = null;
  for (const c of emitCandidates) {
    if (existsSync(c)) {
      emitDir = c;
      break;
    }
  }
  const correctedFlist =
    findFirstExisting(dir, ["svt_corrected.f", "corrected.f"]) ??
    (emitDir
      ? findFirstExisting(emitDir, ["svt_corrected.f", "corrected.f", "portable.f"])
      : null);

  if (opts.requireEmit) {
    if (!emitDir && !correctedFlist) {
      issues.push({
        level: "error",
        code: "emit-missing",
        message: "require-emit: no corrected/ tree or svt_corrected.f in out-dir",
      });
    }
  }

  const ok = !issues.some((i) => i.level === "error");
  return {
    ok,
    dir: posixPath(dir),
    portableF: portableF ? posixPath(portableF) : null,
    reportJson: reportJson ? posixPath(reportJson) : null,
    reportKind,
    paramMap: paramMap ? posixPath(paramMap) : null,
    emitDir: emitDir ? posixPath(emitDir) : null,
    correctedFlist: correctedFlist ? posixPath(correctedFlist) : null,
    schemaHint,
    fileCount,
    issues,
  };
}

/** Re-export flatten shape for hosts that already hold a FlatManifest. */
export function portableFromFlatManifest(
  ctx: PlatformContext,
  manifest: FlatManifest,
  opts: { tag?: string; outPath?: string; defines?: string[] } = {},
): TimingsPortableFlist {
  const tag = opts.tag ?? "from-manifest";
  const outPath = opts.outPath
    ? absPosix(ctx.repoRoot, opts.outPath)
    : posixPath(join(ctx.paths.build, "sv-timing", tag, "portable.f"));
  mkdirSync(dirname(outPath), { recursive: true });
  const defines = opts.defines ?? [];
  const lines: string[] = [
    "# portable filelist for sv-timing — from FlatManifest",
    `# manifest=${manifest.path}`,
  ];
  for (const d of manifest.incdirs) lines.push(`+incdir+${d}`);
  for (const def of defines) lines.push(`+define+${def}`);
  for (const f of manifest.files) lines.push(f);
  writeFileSync(outPath, lines.join("\n") + "\n", "utf8");
  return {
    portablePath: outPath,
    files: [...manifest.files],
    incdirs: [...manifest.incdirs],
    defines,
  };
}
