// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// clean.ts — Inventory and safely remove managed workspace (and opt-in repo)
// artifacts. Deletions are allowlist-guarded; never walks the whole repo.

import {
  existsSync,
  lstatSync,
  readFileSync,
  readdirSync,
  realpathSync,
  statSync,
} from "node:fs";
import { rm } from "node:fs/promises";
import { isAbsolute, join, normalize, resolve, sep } from "node:path";

import { DEFAULT_CONFIG } from "../config/defaults.ts";
import type { CleanConfig } from "../config/schema.ts";
import type { PlatformContext } from "../context.ts";
import type { WorkspacePaths } from "./layout.ts";

/** How to select stamp-bearing artifacts (timings packages, etc.). */
export type CleanExecutionFilter = "all" | "last" | "failed" | "ok";

/** Purpose ids for clean status / subcommands. */
export type CleanPurpose =
  | "build"
  | "diag"
  | "verify"
  | "formal"
  | "timings"
  | "sta"
  | "cache"
  | "manifests"
  | "downloads"
  | "man"
  | "dts"
  | "tooling"
  | "firmware"
  | "sim"
  /** Package-local Cargo `sv-timing/target` (+ optional package out dirs). */
  | "svt"
  /** Contained rustup/cargo under `sv-timing/.tools` (re-setup needed). */
  | "svt-tools"
  /** Trace dumps (`.dasm`/`.traces`/waves) inside stale, uncited remote runs; logs + results kept. */
  | "traces"
  /** Whole remote runs superseded within their tag family (stale, uncited, not newest-N). */
  | "runs"
  /** Stale children of the repo-root scratch `.cache/`. */
  | "repo-cache"
  /** Regenerable build outputs (Cargo targets, UE intermediates, Next.js) not used recently. */
  | "regen"
  | "workspace";

export const CLEAN_PURPOSES: CleanPurpose[] = [
  "build",
  "diag",
  "verify",
  "formal",
  "timings",
  "sta",
  "cache",
  "manifests",
  "downloads",
  "man",
  "dts",
  "tooling",
  "firmware",
  "sim",
  "svt",
  "svt-tools",
  "traces",
  "runs",
  "repo-cache",
  "regen",
  "workspace",
];

/** Purposes that require --yes when not dry-run (expensive / destructive). */
export const CLEAN_REQUIRES_YES: ReadonlySet<CleanPurpose> = new Set([
  "tooling",
  "firmware",
  "sim",
  "svt-tools",
  "traces",
  "runs",
  "repo-cache",
  "workspace",
]);

/** Purposes whose inventory needs the (slower) repo-level scan. */
export const REPO_DATA_PURPOSES: ReadonlySet<CleanPurpose> = new Set([
  "traces",
  "runs",
  "repo-cache",
  "regen",
]);

export interface CleanTarget {
  purpose: CleanPurpose;
  /** Absolute path that would be removed. */
  path: string;
  /** Human label for logs. */
  label: string;
  present: boolean;
  /** Recursive file byte total when present; 0 if missing. */
  bytes: number;
  /** Newest mtime (ms) under the tree when present; null if missing/empty. */
  mtimeMs: number | null;
  /** Needs --yes for non-dry-run delete. */
  requiresYes: boolean;
  /** Root class for allowlist checks. */
  rootKind: "workspace" | "repo-sim" | "repo-pkg" | "repo-data";
  /** When set, only these files are removed (the target dir itself stays). */
  files?: string[];
  /**
   * Why the target is kept by default: `active` (modified within
   * `activeAgeDays`), `cited` (run tag referenced by a tracked file — evidence),
   * `kept` (newest-N of its tag family). Lifted by --include-active / --include-cited.
   */
  hold?: "active" | "cited" | "kept";
  /** Selectable children (aggregate repo-data targets); status shows the parent. */
  parts?: CleanTarget[];
  /** Extra status text (counts / holds). */
  detail?: string;
}

export interface CleanSelectFilters {
  /** Only targets older than this age in ms (based on tree mtime). */
  olderThanMs?: number;
  /** Substring filter for path (e.g. target name). Case-insensitive. */
  target?: string;
  /** Substring filter for path (compartment tags). Case-insensitive. */
  compartment?: string;
  /**
   * Stamp-based selection (reads `stamp.json` under each candidate when present):
   * - `all` (default): no stamp filter
   * - `failed`: only packages with stamp.exitCode !== 0 (or missing stamp treated as unknown → skip)
   * - `ok`: only successful stamps (exitCode === 0)
   * - `last`: among siblings under the same parent purpose dir, keep the newest
   *   successful stamp and select older packages for deletion
   */
  execution?: CleanExecutionFilter;
  /** Lift the `active` hold (recently modified runs / caches / build dirs). */
  includeActive?: boolean;
  /** Lift the `cited` and `kept` holds (evidence runs, newest-N per family). */
  includeCited?: boolean;
}

/** Resolved repo-level clean config (tolerates partial test contexts). */
export function cleanConfigOf(ctx: Pick<PlatformContext, "config">): CleanConfig {
  return { ...DEFAULT_CONFIG.workspace.clean, ...(ctx.config?.workspace?.clean ?? {}) };
}

/**
 * Tag family for `clean runs`: strip a trailing `-rN` repeat counter, a
 * `-YYYYMMDDTHHMMSS[Z]-<hash>` stamp, or an `-old`/`-new` marker.
 */
export function runFamily(tag: string): string {
  return tag
    .replace(/-\d{8}T\d{6}Z?-[0-9a-f]{6,}$/i, "")
    .replace(/-r\d+$/i, "")
    .replace(/-(old|new)$/i, "");
}

/**
 * Run tags referenced by any of `files` (tracked docs/code). A cited run is
 * evidence for a recorded result, so it is kept by default.
 */
export function collectCitedTags(
  repoRoot: string,
  files: string[],
  tags: string[],
  extensions: string[],
  maxBytes = 4 * 1024 * 1024,
): Set<string> {
  const want = new Set(tags);
  const cited = new Set<string>();
  const exts = extensions.map((e) => e.toLowerCase());
  for (const rel of files) {
    if (cited.size === want.size) break;
    const lower = rel.toLowerCase();
    if (!exts.some((e) => lower.endsWith(e))) continue;
    const abs = join(repoRoot, rel);
    let text: string;
    try {
      if (statSync(abs).size > maxBytes) continue;
      text = readFileSync(abs, "utf8");
    } catch {
      continue;
    }
    for (const tok of text.match(/[A-Za-z0-9][A-Za-z0-9._-]{4,}/g) ?? []) {
      if (want.has(tok)) cited.add(tok);
    }
  }
  return cited;
}

function dirChildren(dir: string): string[] {
  try {
    return readdirSync(dir).filter((n) => {
      try {
        return lstatSync(join(dir, n)).isDirectory();
      } catch {
        return false;
      }
    });
  } catch {
    return [];
  }
}

/** Trace files (by suffix) under `dir`, with total bytes. Never follows symlinks. */
function findTraceFiles(dir: string, suffixes: string[]): { files: string[]; bytes: number } {
  const files: string[] = [];
  let bytes = 0;
  const walk = (p: string): void => {
    let names: string[];
    try {
      names = readdirSync(p);
    } catch {
      return;
    }
    for (const n of names) {
      const c = join(p, n);
      let st;
      try {
        st = lstatSync(c);
      } catch {
        continue;
      }
      if (st.isDirectory()) walk(c);
      else if (st.isFile() && suffixes.some((s) => n.toLowerCase().endsWith(s))) {
        files.push(c);
        bytes += st.size;
      }
    }
  };
  walk(dir);
  return { files, bytes };
}

function aggregate(
  purpose: CleanPurpose,
  path: string,
  label: string,
  parts: CleanTarget[],
  what: string,
): CleanTarget {
  const free = parts.filter((p) => !p.hold);
  const n = (h: CleanTarget["hold"]) => parts.filter((p) => p.hold === h).length;
  const holds = [
    n("cited") ? `${n("cited")} cited` : "",
    n("kept") ? `${n("kept")} newest-kept` : "",
    n("active") ? `${n("active")} active` : "",
  ].filter(Boolean);
  return {
    purpose,
    path,
    label,
    present: existsSync(path),
    bytes: free.reduce((a, p) => a + p.bytes, 0),
    mtimeMs: parts.reduce<number | null>((a, p) => (p.mtimeMs == null ? a : Math.max(a ?? 0, p.mtimeMs)), null),
    requiresYes: CLEAN_REQUIRES_YES.has(purpose),
    rootKind: "repo-data",
    parts,
    detail: `reclaimable: ${free.length}/${parts.length} ${what}` + (holds.length ? `; held: ${holds.join(", ")}` : ""),
  };
}

/**
 * Repo-level targets outside `workspace/`: remote-run traces and superseded
 * runs, the repo-root scratch cache, and regenerable build outputs. Holds mark
 * what is still useful (active, cited as evidence, newest per family).
 */
export function listRepoDataTargets(
  repoRoot: string,
  cfg: CleanConfig,
  citedTags: Set<string>,
  now = Date.now(),
): CleanTarget[] {
  const activeMs = cfg.activeAgeDays * 86_400_000;
  const isActive = (m: number | null) => m != null && now - m < activeMs;
  const out: CleanTarget[] = [];

  const runsRoot = join(repoRoot, cfg.remoteRunsDir);
  const protect = new Set(cfg.remoteRunsProtect.map((p) => p.toLowerCase()));
  const runs = dirChildren(runsRoot)
    .filter((t) => !protect.has(t.toLowerCase()))
    .map((tag) => {
      const path = join(runsRoot, tag);
      const m = measurePath(path);
      return { tag, path, ...m };
    });

  const traceParts: CleanTarget[] = [];
  for (const r of runs) {
    const tr = findTraceFiles(r.path, cfg.traceSuffixes);
    if (tr.files.length === 0) continue;
    traceParts.push({
      purpose: "traces",
      path: r.path,
      label: `${cfg.remoteRunsDir}/${r.tag} (traces)`,
      present: true,
      bytes: tr.bytes,
      mtimeMs: r.mtimeMs,
      requiresYes: true,
      rootKind: "repo-data",
      files: tr.files,
      hold: isActive(r.mtimeMs) ? "active" : citedTags.has(r.tag) ? "cited" : undefined,
    });
  }
  out.push(aggregate("traces", runsRoot, `${cfg.remoteRunsDir} traces`, traceParts, "runs"));

  const families = new Map<string, typeof runs>();
  for (const r of runs) {
    const f = runFamily(r.tag);
    families.set(f, [...(families.get(f) ?? []), r]);
  }
  const runParts: CleanTarget[] = [];
  for (const members of families.values()) {
    members.sort((a, b) => (b.mtimeMs ?? 0) - (a.mtimeMs ?? 0));
    members.forEach((r, i) => {
      runParts.push({
        purpose: "runs",
        path: r.path,
        label: `${cfg.remoteRunsDir}/${r.tag}`,
        present: true,
        bytes: r.bytes,
        mtimeMs: r.mtimeMs,
        requiresYes: true,
        rootKind: "repo-data",
        hold: isActive(r.mtimeMs)
          ? "active"
          : citedTags.has(r.tag)
            ? "cited"
            : i < cfg.keepRunsPerFamily
              ? "kept"
              : undefined,
      });
    });
  }
  out.push(aggregate("runs", runsRoot, `${cfg.remoteRunsDir} superseded`, runParts, "runs"));

  const cacheRoot = join(repoRoot, cfg.repoCacheDir);
  const cacheParts: CleanTarget[] = [];
  // Loose files under 1 MiB (scripts, notes, small logs) are never candidates:
  // they are the operator's working notes, not space.
  const SMALL_FILE = 1024 * 1024;
  const sizeableFiles = (dir: string): string[] => {
    try {
      return readdirSync(dir).filter((c) => {
        try {
          const st = lstatSync(join(dir, c));
          return st.isFile() && st.size >= SMALL_FILE;
        } catch {
          return false;
        }
      });
    } catch {
      return [];
    }
  };
  const cachePart = (path: string, label: string): CleanTarget => {
    const m = measurePath(path);
    return {
      purpose: "repo-cache",
      path,
      label,
      present: true,
      bytes: m.bytes,
      mtimeMs: m.mtimeMs,
      requiresYes: true,
      rootKind: "repo-data",
      hold: isActive(m.mtimeMs) ? "active" : undefined,
    };
  };
  for (const n of [...dirChildren(cacheRoot), ...sizeableFiles(cacheRoot)]) {
    const part = cachePart(join(cacheRoot, n), `${cfg.repoCacheDir}/${n}`);
    // An active entry is a working tree (e.g. a guest/regress scratch dir): its
    // own stale sub-entries are still reclaimable, so offer those instead of
    // holding the whole entry.
    const sub = part.hold === "active"
      ? [...dirChildren(part.path), ...sizeableFiles(part.path)]
      : [];
    if (sub.length === 0) {
      cacheParts.push(part);
      continue;
    }
    for (const c of sub) cacheParts.push(cachePart(join(part.path, c), `${part.label}/${c}`));
  }
  out.push(aggregate("repo-cache", cacheRoot, `${cfg.repoCacheDir} (repo root)`, cacheParts, "entries"));

  for (const rel of cfg.regenerableDirs) {
    const t = targetOf("regen", join(repoRoot, rel), rel, "repo-pkg");
    if (t.present && isActive(t.mtimeMs)) t.hold = "active";
    out.push(t);
  }
  return out;
}

/** Read host timings/suite stamp.json if present. */
export function readStampJson(
  dir: string,
): { exitCode?: number; mtimeMs?: number; kind?: string } | null {
  const p = join(dir, "stamp.json");
  if (!existsSync(p)) return null;
  try {
    const j = JSON.parse(readFileSync(p, "utf8")) as Record<string, unknown>;
    return {
      exitCode: typeof j.exitCode === "number" ? j.exitCode : undefined,
      mtimeMs: typeof j.mtimeMs === "number" ? j.mtimeMs : undefined,
      kind: typeof j.kind === "string" ? j.kind : undefined,
    };
  } catch {
    return null;
  }
}

export interface CleanRemoveOptions {
  dryRun: boolean;
  yes: boolean;
  /** Allowlisted absolute roots (workspace + optional repo sim dirs). */
  allowRoots: string[];
}

export interface CleanRemoveResult {
  purpose: CleanPurpose;
  path: string;
  label: string;
  status: "removed" | "would-remove" | "skipped-missing" | "skipped-age" | "skipped-filter" | "refused";
  detail?: string;
  bytes: number;
}

/** Parse duration like `7d`, `12h`, `30m`, `90s` into milliseconds. */
export function parseDurationMs(spec: string): number | null {
  const s = spec.trim().toLowerCase();
  const m = /^(\d+(?:\.\d+)?)\s*([dhms])$/.exec(s);
  if (!m) return null;
  const n = Number(m[1]);
  if (!Number.isFinite(n) || n < 0) return null;
  const unit = m[2]!;
  const mult =
    unit === "d" ? 86_400_000 : unit === "h" ? 3_600_000 : unit === "m" ? 60_000 : 1000;
  return Math.floor(n * mult);
}

/** Format bytes for human status lines. */
export function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KiB`;
  if (n < 1024 * 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MiB`;
  return `${(n / (1024 * 1024 * 1024)).toFixed(2)} GiB`;
}

/** Format age from mtimeMs relative to now. */
export function formatAge(mtimeMs: number | null, now = Date.now()): string {
  if (mtimeMs == null) return "—";
  const age = Math.max(0, now - mtimeMs);
  if (age < 60_000) return `${Math.floor(age / 1000)}s`;
  if (age < 3_600_000) return `${Math.floor(age / 60_000)}m`;
  if (age < 86_400_000) return `${Math.floor(age / 3_600_000)}h`;
  return `${Math.floor(age / 86_400_000)}d`;
}

/**
 * True if `path` is under one of the allowlisted roots (after normalize +
 * realpath when the path exists). Refuses symlink escapes.
 */
export function isPathAllowed(path: string, allowRoots: string[]): boolean {
  let resolved: string;
  try {
    resolved = existsSync(path) ? realpathSync(path) : resolve(path);
  } catch {
    resolved = resolve(path);
  }
  const norm = normalize(resolved);
  for (const root of allowRoots) {
    let rootAbs: string;
    try {
      rootAbs = existsSync(root) ? realpathSync(root) : resolve(root);
    } catch {
      rootAbs = resolve(root);
    }
    const r = normalize(rootAbs);
    if (norm === r) return true;
    const prefix = r.endsWith(sep) ? r : r + sep;
    if (norm.startsWith(prefix)) return true;
    // Windows: case-insensitive compare
    if (process.platform === "win32") {
      const nL = norm.toLowerCase();
      const rL = r.toLowerCase();
      if (nL === rL) return true;
      const pL = rL.endsWith(sep) ? rL : rL + sep;
      if (nL.startsWith(pL)) return true;
    }
  }
  return false;
}

/** Recursive size + newest mtime for a directory or file. Caps work on huge trees. */
export function measurePath(
  path: string,
  opts: { maxFiles?: number } = {},
): { bytes: number; mtimeMs: number | null; files: number } {
  const maxFiles = opts.maxFiles ?? 200_000;
  if (!existsSync(path)) return { bytes: 0, mtimeMs: null, files: 0 };

  let bytes = 0;
  let mtimeMs: number | null = null;
  let files = 0;

  const walk = (p: string): void => {
    if (files >= maxFiles) return;
    let st;
    try {
      st = lstatSync(p);
    } catch {
      return;
    }
    if (st.isSymbolicLink()) {
      // Count link itself only; do not follow (safety).
      files++;
      bytes += st.size;
      mtimeMs = mtimeMs == null ? st.mtimeMs : Math.max(mtimeMs, st.mtimeMs);
      return;
    }
    if (st.isFile()) {
      files++;
      bytes += st.size;
      mtimeMs = mtimeMs == null ? st.mtimeMs : Math.max(mtimeMs, st.mtimeMs);
      return;
    }
    if (st.isDirectory()) {
      mtimeMs = mtimeMs == null ? st.mtimeMs : Math.max(mtimeMs, st.mtimeMs);
      let entries: string[];
      try {
        entries = readdirSync(p);
      } catch {
        return;
      }
      for (const name of entries) {
        if (files >= maxFiles) return;
        walk(join(p, name));
      }
    }
  };

  walk(path);
  return { bytes, mtimeMs, files };
}

function targetOf(
  purpose: CleanPurpose,
  path: string,
  label: string,
  rootKind: CleanTarget["rootKind"],
): CleanTarget {
  const present = existsSync(path);
  const m = present ? measurePath(path) : { bytes: 0, mtimeMs: null, files: 0 };
  return {
    purpose,
    path,
    label,
    present,
    bytes: m.bytes,
    mtimeMs: m.mtimeMs,
    requiresYes: CLEAN_REQUIRES_YES.has(purpose),
    rootKind,
  };
}

/**
 * Build the full inventory of clean targets for a context.
 * `repoSimOutDirs` are repo-relative dirs (default: work-ver).
 */
export function listCleanTargets(
  ctx: PlatformContext,
  opts: {
    repoSimOutDirs?: string[];
    /** Include the repo-level purposes (traces/runs/repo-cache/regen); walks remote runs. */
    repoData?: { citedTags: Set<string>; now?: number };
  } = {},
): CleanTarget[] {
  const paths = ctx.paths;
  const simDirs = opts.repoSimOutDirs ?? ["work-ver"];
  const out: CleanTarget[] = [
    targetOf("build", paths.build, "workspace/build", "workspace"),
    targetOf("diag", join(paths.build, "diagnostics"), "build/diagnostics", "workspace"),
    targetOf("verify", join(paths.build, "verify"), "build/verify", "workspace"),
    targetOf("formal", join(paths.build, "formal"), "build/formal", "workspace"),
    targetOf("timings", join(paths.build, "sv-timing"), "build/sv-timing", "workspace"),
    targetOf("sta", join(paths.build, "sta-handoff"), "build/sta-handoff", "workspace"),
    targetOf("cache", paths.cache, "workspace/.cache", "workspace"),
    targetOf("manifests", paths.manifests, ".cache/manifests", "workspace"),
    targetOf("downloads", paths.downloads, ".cache/downloads", "workspace"),
    targetOf("man", join(paths.root, "man"), "workspace/man", "workspace"),
    targetOf("dts", join(paths.root, "linux-dts"), "workspace/linux-dts", "workspace"),
    targetOf("tooling", paths.tooling, "workspace/tooling", "workspace"),
    targetOf("firmware", join(paths.root, "smt2-linux"), "workspace/smt2-linux", "workspace"),
    targetOf("workspace", paths.root, "workspace (entire)", "workspace"),
  ];
  for (const rel of simDirs) {
    const abs = isAbsolute(rel) ? rel : join(ctx.repoRoot, rel);
    out.push(targetOf("sim", abs, rel, "repo-sim"));
  }
  // Package-local sv-timing Cargo / cache outs (never crates/ or source).
  const svtRoot = join(ctx.repoRoot, "sv-timing");
  out.push(
    targetOf("svt", join(svtRoot, "target"), "sv-timing/target", "repo-pkg"),
    targetOf(
      "svt",
      join(svtRoot, ".sv-timing-out"),
      "sv-timing/.sv-timing-out",
      "repo-pkg",
    ),
    targetOf(
      "svt",
      join(svtRoot, ".sv-timing-cache"),
      "sv-timing/.sv-timing-cache",
      "repo-pkg",
    ),
    targetOf("svt-tools", join(svtRoot, ".tools"), "sv-timing/.tools", "repo-pkg"),
  );
  if (opts.repoData) {
    out.push(
      ...listRepoDataTargets(ctx.repoRoot, cleanConfigOf(ctx), opts.repoData.citedTags, opts.repoData.now),
    );
  }
  return out;
}

/** Allowlist roots for a context (workspace root + each repo-sim dir parent path). */
export function cleanAllowRoots(
  paths: WorkspacePaths,
  repoRoot: string,
  repoSimOutDirs: string[] = ["work-ver"],
  clean?: CleanConfig,
): string[] {
  const roots = [paths.root];
  if (clean) {
    roots.push(
      join(repoRoot, clean.remoteRunsDir),
      join(repoRoot, clean.repoCacheDir),
      ...clean.regenerableDirs.map((d) => join(repoRoot, d)),
    );
  }
  for (const rel of repoSimOutDirs) {
    const abs = isAbsolute(rel) ? rel : join(repoRoot, rel);
    // Allow the sim dir itself (may not exist yet).
    roots.push(abs);
  }
  // sv-timing package build/cache/toolchain leaves only (not the package root).
  const svtRoot = join(repoRoot, "sv-timing");
  roots.push(
    join(svtRoot, "target"),
    join(svtRoot, ".sv-timing-out"),
    join(svtRoot, ".sv-timing-cache"),
    join(svtRoot, ".tools"),
  );
  return roots;
}

/**
 * When path filters or age apply to multi-artifact parents (diag/timings/…),
 * expand one level of child directories so filters can match tags like host-cv64a6.
 */
function expandChildrenIfNeeded(
  t: CleanTarget,
  filters: CleanSelectFilters,
): CleanTarget[] {
  const exec = filters.execution ?? "all";
  const needsExpand =
    filters.target != null ||
    filters.compartment != null ||
    filters.olderThanMs != null ||
    exec !== "all";
  if (!needsExpand) return [t];
  // Whole-workspace / whole-build / tooling: never expand — delete as a unit.
  if (
    t.purpose === "build" ||
    t.purpose === "workspace" ||
    t.purpose === "tooling" ||
    t.purpose === "cache" ||
    t.purpose === "sim" ||
    t.purpose === "firmware" ||
    t.purpose === "svt" ||
    t.purpose === "svt-tools" ||
    t.purpose === "regen" ||
    t.parts != null
  ) {
    return [t];
  }
  if (!t.present || !existsSync(t.path)) return [t];
  let st;
  try {
    st = lstatSync(t.path);
  } catch {
    return [t];
  }
  if (!st.isDirectory()) return [t];
  let names: string[];
  try {
    names = readdirSync(t.path);
  } catch {
    return [t];
  }
  const children: CleanTarget[] = [];
  for (const name of names) {
    const childPath = join(t.path, name);
    let cst;
    try {
      cst = lstatSync(childPath);
    } catch {
      continue;
    }
    if (!cst.isDirectory() && !cst.isFile()) continue;
    const m = measurePath(childPath);
    children.push({
      purpose: t.purpose,
      path: childPath,
      label: `${t.label}/${name}`,
      present: true,
      bytes: m.bytes,
      mtimeMs: m.mtimeMs,
      requiresYes: t.requiresYes,
      rootKind: t.rootKind,
    });
  }
  // If empty dir, fall back to parent.
  return children.length > 0 ? children : [t];
}

/** Select targets by purpose ids and optional age/path filters. */
export function selectCleanTargets(
  inventory: CleanTarget[],
  purposes: CleanPurpose[],
  filters: CleanSelectFilters = {},
  now = Date.now(),
): { selected: CleanTarget[]; skipped: CleanRemoveResult[] } {
  const want = new Set(purposes);
  const selected: CleanTarget[] = [];
  const skipped: CleanRemoveResult[] = [];

  for (const base of inventory) {
    if (!want.has(base.purpose)) continue;

    if (!base.present) {
      skipped.push({
        purpose: base.purpose,
        path: base.path,
        label: base.label,
        status: "skipped-missing",
        bytes: 0,
      });
      continue;
    }

    let candidates = base.parts ?? expandChildrenIfNeeded(base, filters);
    candidates = candidates.filter((c) => {
      const lifted =
        c.hold == null ||
        (c.hold === "active" && filters.includeActive) ||
        ((c.hold === "cited" || c.hold === "kept") && filters.includeCited);
      if (!lifted) {
        skipped.push({
          purpose: c.purpose,
          path: c.path,
          label: c.label,
          status: "skipped-filter",
          detail: `held (${c.hold})`,
          bytes: c.bytes,
        });
      }
      return lifted;
    });

    // --execution last: among expanded children with successful stamps, keep
    // the newest (do not delete it); select older packages.
    const exec = filters.execution ?? "all";
    if (exec === "last" && candidates.length > 1) {
      let newestOkPath: string | null = null;
      let newestMs = -1;
      for (const c of candidates) {
        const st = readStampJson(c.path);
        const ms = st?.mtimeMs ?? c.mtimeMs ?? 0;
        if (st && st.exitCode === 0 && ms >= newestMs) {
          newestMs = ms;
          newestOkPath = c.path;
        }
      }
      if (newestOkPath) {
        for (const c of candidates) {
          if (c.path === newestOkPath) {
            skipped.push({
              purpose: c.purpose,
              path: c.path,
              label: c.label,
              status: "skipped-filter",
              detail: "kept by --execution last (newest ok stamp)",
              bytes: c.bytes,
            });
          }
        }
        candidates = candidates.filter((c) => c.path !== newestOkPath);
      }
    }

    for (const t of candidates) {
      if (filters.olderThanMs != null && t.mtimeMs != null) {
        const age = now - t.mtimeMs;
        if (age < filters.olderThanMs) {
          skipped.push({
            purpose: t.purpose,
            path: t.path,
            label: t.label,
            status: "skipped-age",
            detail: `age ${formatAge(t.mtimeMs, now)} < threshold`,
            bytes: t.bytes,
          });
          continue;
        }
      }

      if (filters.target) {
        const needle = filters.target.toLowerCase();
        if (
          !t.path.toLowerCase().includes(needle) &&
          !t.label.toLowerCase().includes(needle)
        ) {
          skipped.push({
            purpose: t.purpose,
            path: t.path,
            label: t.label,
            status: "skipped-filter",
            detail: `no match for --target ${filters.target}`,
            bytes: t.bytes,
          });
          continue;
        }
      }

      if (filters.compartment) {
        const needle = filters.compartment.toLowerCase();
        if (!t.path.toLowerCase().includes(needle) && !t.label.toLowerCase().includes(needle)) {
          skipped.push({
            purpose: t.purpose,
            path: t.path,
            label: t.label,
            status: "skipped-filter",
            detail: `no match for --compartment ${filters.compartment}`,
            bytes: t.bytes,
          });
          continue;
        }
      }

      if (exec === "failed" || exec === "ok") {
        const st = readStampJson(t.path);
        if (!st || st.exitCode === undefined) {
          skipped.push({
            purpose: t.purpose,
            path: t.path,
            label: t.label,
            status: "skipped-filter",
            detail: `no stamp.json for --execution ${exec}`,
            bytes: t.bytes,
          });
          continue;
        }
        if (exec === "failed" && st.exitCode === 0) {
          skipped.push({
            purpose: t.purpose,
            path: t.path,
            label: t.label,
            status: "skipped-filter",
            detail: "stamp exitCode=0 (not failed)",
            bytes: t.bytes,
          });
          continue;
        }
        if (exec === "ok" && st.exitCode !== 0) {
          skipped.push({
            purpose: t.purpose,
            path: t.path,
            label: t.label,
            status: "skipped-filter",
            detail: `stamp exitCode=${st.exitCode} (not ok)`,
            bytes: t.bytes,
          });
          continue;
        }
      }

      selected.push(t);
    }
  }

  return { selected, skipped };
}

/** Map a CLI subcommand token to purpose(s). */
export function purposesFromSubcommand(sub: string): CleanPurpose[] | null {
  const s = sub.toLowerCase();
  if (s === "status" || s === "list" || s === "ls") return [];
  if (s === "all") return ["workspace"];
  // Aliases for package Cargo target (architecture: clean rust-target).
  if (
    s === "svt" ||
    s === "rust-target" ||
    s === "sv-timing-target" ||
    s === "svt-target" ||
    s === "cargo-target"
  ) {
    return ["svt"];
  }
  if (s === "svt-tools" || s === "sv-timing-tools" || s === "rust-tools") {
    return ["svt-tools"];
  }
  if (s === "remote-traces") return ["traces"];
  if (s === "remote-runs") return ["runs"];
  if (s === "regenerable") return ["regen"];
  // Everything stale and reclaimable at repo level, holds still apply.
  if (s === "stale") return ["traces", "runs", "repo-cache", "regen"];
  if ((CLEAN_PURPOSES as string[]).includes(s)) return [s as CleanPurpose];
  // Legacy flags handled in command, not here.
  return null;
}

/**
 * Remove selected targets. Refuses paths outside allowRoots.
 * Does not create parent dirs after delete.
 */
export async function removeCleanTargets(
  targets: CleanTarget[],
  opts: CleanRemoveOptions,
): Promise<CleanRemoveResult[]> {
  const results: CleanRemoveResult[] = [];
  for (const t of targets) {
    if (!existsSync(t.path)) {
      results.push({
        purpose: t.purpose,
        path: t.path,
        label: t.label,
        status: "skipped-missing",
        bytes: 0,
      });
      continue;
    }
    if (!isPathAllowed(t.path, opts.allowRoots)) {
      results.push({
        purpose: t.purpose,
        path: t.path,
        label: t.label,
        status: "refused",
        detail: "path outside allowlist",
        bytes: t.bytes,
      });
      continue;
    }
    if (t.requiresYes && !opts.yes && !opts.dryRun) {
      results.push({
        purpose: t.purpose,
        path: t.path,
        label: t.label,
        status: "refused",
        detail: "requires --yes",
        bytes: t.bytes,
      });
      continue;
    }
    if (opts.dryRun) {
      results.push({
        purpose: t.purpose,
        path: t.path,
        label: t.label,
        status: "would-remove",
        bytes: t.bytes,
      });
      continue;
    }
    if (t.files) {
      const outside = t.files.filter((f) => !isPathAllowed(f, opts.allowRoots));
      if (outside.length > 0) {
        results.push({
          purpose: t.purpose,
          path: t.path,
          label: t.label,
          status: "refused",
          detail: `${outside.length} file(s) outside allowlist`,
          bytes: t.bytes,
        });
        continue;
      }
      try {
        for (const f of t.files) await rm(f, { force: true });
        results.push({ purpose: t.purpose, path: t.path, label: t.label, status: "removed", bytes: t.bytes });
      } catch (e) {
        results.push({
          purpose: t.purpose,
          path: t.path,
          label: t.label,
          status: "refused",
          detail: e instanceof Error ? e.message : String(e),
          bytes: t.bytes,
        });
      }
      continue;
    }
    try {
      // Extra safety: refuse if path is a plain file that is not under workspace
      // (should not happen for our inventory).
      const st = statSync(t.path);
      if (!st.isDirectory() && !st.isFile()) {
        results.push({
          purpose: t.purpose,
          path: t.path,
          label: t.label,
          status: "refused",
          detail: "not a file or directory",
          bytes: t.bytes,
        });
        continue;
      }
      await rm(t.path, { recursive: true, force: true });
      results.push({
        purpose: t.purpose,
        path: t.path,
        label: t.label,
        status: "removed",
        bytes: t.bytes,
      });
    } catch (e) {
      results.push({
        purpose: t.purpose,
        path: t.path,
        label: t.label,
        status: "refused",
        detail: e instanceof Error ? e.message : String(e),
        bytes: t.bytes,
      });
    }
  }
  return results;
}

/** Resolve purpose list from legacy flags (compat with old clean CLI). */
export function purposesFromLegacyFlags(flags: {
  all?: boolean;
  tooling?: boolean;
  cache?: boolean;
}): CleanPurpose[] {
  if (flags.all) return ["workspace"];
  const purposes: CleanPurpose[] = ["build"];
  if (flags.tooling) purposes.push("tooling");
  if (flags.cache) purposes.push("cache");
  return purposes;
}
