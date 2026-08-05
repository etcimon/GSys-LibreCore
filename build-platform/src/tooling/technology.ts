// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// technology.ts — The engine behind the `tech` command (the PDK-swap orchestration).
//
// This drives the agentic "technology optimization pass": it detects whether
// the pass is armed, plans the macro-protected adaptation, and verifies the
// SoC-readiness gates — WITHOUT ever editing RTL or committing NDA content.
//
// Two-key ignition (both required to arm):
//   1. config.technology.optimizationPass === true
//   2. at least one `*.tech-spec.md` doc under a scoped core/** or corev_apu/** area
//
// When armed, the pass emits a PLAN keyed to the sanctioned PDK-swap seams
// (tech_cells_generic tc_sram/tc_clk/tc_pwr; sram_cache TECHNO_CUT; hpdcache
// behav/blackbox/<tech> macros). Any actual RTL adaptation an agent performs is
// fenced behind `\`ifdef <guardMacro>` so the generic path is byte-for-byte
// unchanged when the macro is undefined. Proprietary PDK views live only under
// the gitignored pdkRoot. See AGENTS-technology.md + AGENTS-technology-optimization.md.

import type { Dirent } from "node:fs";
import { existsSync } from "node:fs";
import { mkdir, readFile, readdir, stat, writeFile } from "node:fs/promises";
import { isAbsolute, join, relative } from "node:path";

import type { TechnologyConfig, TechnologyPdkMode } from "../config/schema.ts";
import type { PlatformContext } from "../context.ts";

// ---------------------------------------------------------------------------
// Path resolution
// ---------------------------------------------------------------------------

function underRepo(repoRoot: string, spec: string): string {
  return isAbsolute(spec) ? spec : join(repoRoot, spec);
}

/** Repo-relative, forward-slash form of an absolute path (stable across OSes). */
function rel(repoRoot: string, abs: string): string {
  return relative(repoRoot, abs).replace(/\\/g, "/");
}

export interface TechnologyPaths {
  pdkRoot: string;
  coreAreaRoot: string;
  apuAreaRoot: string;
  manifestFile: string;
  manifestExample: string;
  readme: string;
  gitignore: string;
}

/** Resolve the protected-root + per-area paths for the technology pass. */
export function technologyPaths(ctx: PlatformContext): TechnologyPaths {
  const { repoRoot, config } = ctx;
  const t = config.technology;
  const pdkRoot = underRepo(repoRoot, t.pdkRoot);
  const coreAreaRoot = underRepo(repoRoot, t.areaRoots.find((r) => r.replace(/\\/g, "/").endsWith("core")) ?? "pd/pdk/core");
  const apuAreaRoot = underRepo(repoRoot, t.areaRoots.find((r) => r.replace(/\\/g, "/").includes("corev_apu")) ?? "pd/pdk/corev_apu");
  return {
    pdkRoot,
    coreAreaRoot,
    apuAreaRoot,
    manifestFile: join(pdkRoot, "manifest.json"),
    manifestExample: join(pdkRoot, "manifest.example.json"),
    readme: join(pdkRoot, "README.md"),
    gitignore: join(pdkRoot, ".gitignore"),
  };
}

// ---------------------------------------------------------------------------
// Spec-doc detection (key 2 of the ignition)
// ---------------------------------------------------------------------------

export type TechArea = "core" | "corev_apu" | "other";

export interface TechSpecDoc {
  /** Repo-relative, forward-slash path. */
  path: string;
  area: TechArea;
  bytes: number;
}

/** Split a `<base>/**​/<pattern>` glob into a walk base + a literal filename suffix. */
function parseGlob(glob: string): { base: string; suffix: string } {
  const g = glob.replace(/\\/g, "/");
  const star2 = g.indexOf("**");
  if (star2 >= 0) {
    const base = g.slice(0, star2).replace(/\/+$/, "") || ".";
    const tail = g.slice(star2 + 2);
    const lastStar = tail.lastIndexOf("*");
    const suffix = lastStar >= 0 ? tail.slice(lastStar + 1) : tail.replace(/^\/+/, "");
    return { base, suffix };
  }
  const slash = g.lastIndexOf("/");
  return { base: slash >= 0 ? g.slice(0, slash) : ".", suffix: slash >= 0 ? g.slice(slash + 1) : g };
}

function areaOf(base: string): TechArea {
  const b = base.replace(/\\/g, "/");
  if (b === "core" || b.startsWith("core/")) return "core";
  if (b === "corev_apu" || b.startsWith("corev_apu/")) return "corev_apu";
  return "other";
}

/** Bounded recursive file collector (skips dotfiles; caps count + depth). */
async function collectFiles(
  root: string,
  match: (name: string) => boolean,
  cap = 200,
  maxDepth = 12,
): Promise<string[]> {
  const out: string[] = [];
  async function walk(dir: string, depth: number): Promise<void> {
    if (depth > maxDepth || out.length >= cap) return;
    let entries: Dirent[];
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      if (out.length >= cap) return;
      if (e.name.startsWith(".")) continue;
      const full = join(dir, e.name);
      if (e.isDirectory()) await walk(full, depth + 1);
      else if (e.isFile() && match(e.name)) out.push(full);
    }
  }
  await walk(root, 0);
  return out;
}

/** Find the `*.tech-spec.md` docs that scope the pass (config.technology.specGlobs). */
export async function detectSpecDocs(ctx: PlatformContext): Promise<TechSpecDoc[]> {
  const { repoRoot, config } = ctx;
  const seen = new Set<string>();
  const docs: TechSpecDoc[] = [];
  for (const glob of config.technology.specGlobs) {
    const { base, suffix } = parseGlob(glob);
    if (suffix.length === 0) continue;
    const absBase = underRepo(repoRoot, base);
    if (!existsSync(absBase)) continue;
    for (const f of await collectFiles(absBase, (n) => n.endsWith(suffix))) {
      const r = rel(repoRoot, f);
      if (seen.has(r)) continue;
      seen.add(r);
      let bytes = 0;
      try {
        bytes = (await stat(f)).size;
      } catch {
        /* ignore */
      }
      docs.push({ path: r, area: areaOf(base), bytes });
    }
  }
  docs.sort((a, b) => a.path.localeCompare(b.path));
  return docs;
}

// ---------------------------------------------------------------------------
// PDK presence + manifest
// ---------------------------------------------------------------------------

const RESERVED_DIRS = new Set(["core", "corev_apu", "technology.example"]);

export interface TechManifest {
  technology?: string;
  vendor?: string;
  node?: string;
  pdkMode?: TechnologyPdkMode;
  [key: string]: unknown;
}

/** Read pdkRoot/manifest.json (never the committed .example). Null if absent/invalid. */
export async function loadManifest(ctx: PlatformContext): Promise<TechManifest | null> {
  const paths = technologyPaths(ctx);
  if (!existsSync(paths.manifestFile)) return null;
  try {
    return JSON.parse(await readFile(paths.manifestFile, "utf8")) as TechManifest;
  } catch {
    return null;
  }
}

export interface PdkPresence {
  /** Repo-relative pdkRoot. */
  root: string;
  exists: boolean;
  manifestPresent: boolean;
  /** Top-level dirs under pdkRoot that look like real (NDA) technology drops. */
  drops: string[];
  ndaContentPresent: boolean;
}

/** Detect whether a real PDK (manifest or a technology drop) is present on disk. */
export async function pdkPresence(ctx: PlatformContext): Promise<PdkPresence> {
  const paths = technologyPaths(ctx);
  const root = rel(ctx.repoRoot, paths.pdkRoot);
  if (!existsSync(paths.pdkRoot)) {
    return { root, exists: false, manifestPresent: false, drops: [], ndaContentPresent: false };
  }
  const manifestPresent = existsSync(paths.manifestFile);
  const drops: string[] = [];
  try {
    for (const e of await readdir(paths.pdkRoot, { withFileTypes: true })) {
      if (e.isDirectory() && !RESERVED_DIRS.has(e.name) && !e.name.startsWith(".")) drops.push(e.name);
    }
  } catch {
    /* ignore */
  }
  drops.sort();
  return { root, exists: true, manifestPresent, drops, ndaContentPresent: manifestPresent || drops.length > 0 };
}

// ---------------------------------------------------------------------------
// Assessment + adaptation plan (read-only)
// ---------------------------------------------------------------------------

export interface PassAssessment {
  flagOn: boolean;
  pdkMode: TechnologyPdkMode;
  guardMacro: string;
  specDocs: TechSpecDoc[];
  armed: boolean;
  reasons: string[];
}

/** The two-key ignition check: flag on AND at least one scoped tech-spec doc. */
export async function assessPass(ctx: PlatformContext): Promise<PassAssessment> {
  const t = ctx.config.technology;
  const specDocs = await detectSpecDocs(ctx);
  const reasons: string[] = [];
  if (!t.optimizationPass) reasons.push("technology.optimizationPass is false (key 1 of 2).");
  if (specDocs.length === 0) reasons.push("no *.tech-spec.md doc in the scoped core/** or corev_apu/** areas (key 2 of 2).");
  const armed = t.optimizationPass && specDocs.length > 0;
  if (armed) reasons.push(`armed: ${specDocs.length} tech-spec doc(s); adaptation fenced behind \`define ${t.guardMacro}.`);
  return { flagOn: t.optimizationPass, pdkMode: t.pdkMode, guardMacro: t.guardMacro, specDocs, armed, reasons };
}

const SEAM_BY_AREA: Record<TechArea, string> = {
  core: "tech_cells_generic (tc_sram/tc_clk/tc_pwr) + common/local/util/sram_cache.sv TECHNO_CUT + hpdcache behav/blackbox/<tech> macro",
  corev_apu: "corev_apu SoC macros: DDR/HBM PHY, PLL/clocking, IO pads via tech_cells_generic + vendor PHY (AGENTS-corev-apu.md / AGENTS-vendor.md)",
  other: "documented PDK-swap seam (AGENTS-technology.md)",
};

function areaRootFor(t: TechnologyConfig, area: TechArea): string {
  const want = area === "corev_apu" ? "corev_apu" : "core";
  return (
    t.areaRoots.find((r) => {
      const s = r.replace(/\\/g, "/");
      return s === want || s.endsWith("/" + want) || s.includes(want);
    }) ?? t.pdkRoot
  );
}

export interface AdaptationTarget {
  specDoc: string;
  area: TechArea;
  seam: string;
  guardMacro: string;
  /** Gitignored drop-in dir the macro-protected wrapper is generated into. */
  outputDir: string;
  note: string;
}

export interface AdaptationPlan {
  armed: boolean;
  activeTechnology: string | null;
  pdkMode: TechnologyPdkMode;
  targets: AdaptationTarget[];
  reasons: string[];
}

/** Produce the read-only adaptation plan (never edits RTL; emits guarded targets). */
export async function planAdaptation(ctx: PlatformContext): Promise<AdaptationPlan> {
  const t = ctx.config.technology;
  const assess = await assessPass(ctx);
  const techId = t.activeTechnology ?? (t.pdkMode === "omitted" ? "omitted" : "unnamed");
  const targets: AdaptationTarget[] = [];
  if (assess.armed) {
    for (const doc of assess.specDocs) {
      const areaRoot = areaRootFor(t, doc.area).replace(/\\/g, "/");
      targets.push({
        specDoc: doc.path,
        area: doc.area,
        seam: SEAM_BY_AREA[doc.area],
        guardMacro: t.guardMacro,
        outputDir: `${areaRoot}/${techId}`,
        note: `Bind PDK views at the seam behind \`ifdef ${t.guardMacro}; keep the generic path intact.`,
      });
    }
  }
  return { armed: assess.armed, activeTechnology: t.activeTechnology, pdkMode: t.pdkMode, targets, reasons: assess.reasons };
}

// ---------------------------------------------------------------------------
// SoC-readiness gates (verify)
// ---------------------------------------------------------------------------

export interface Gate {
  id: string;
  ok: boolean;
  /** Hard gates must pass before the pass may run; soft gates are advisory. */
  hard: boolean;
  detail: string;
}

export interface ReadinessReport {
  ok: boolean;
  flagOn: boolean;
  armed: boolean;
  gates: Gate[];
}

const IDENT_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;

/** Verify the SoC-readiness gates for arming the pass (see AGENTS-technology.md §gates). */
export async function readinessGates(ctx: PlatformContext): Promise<ReadinessReport> {
  const t = ctx.config.technology;
  const paths = technologyPaths(ctx);
  const assess = await assessPass(ctx);
  const presence = await pdkPresence(ctx);
  const gates: Gate[] = [];

  gates.push({
    id: "armed",
    hard: true,
    ok: assess.armed,
    detail: assess.armed ? "flag on + tech-spec doc present" : assess.reasons.join(" "),
  });
  gates.push({
    id: "guard-macro",
    hard: true,
    ok: IDENT_RE.test(t.guardMacro),
    detail: `\`define ${t.guardMacro}\` fences every adaptation (undefined ⇒ generic path)`,
  });
  const giExists = existsSync(paths.gitignore);
  gates.push({
    id: "protected-root-gitignored",
    hard: true,
    ok: giExists,
    detail: giExists
      ? `${presence.root}/.gitignore keeps NDA content out of git`
      : `missing ${presence.root}/.gitignore — NDA content could leak`,
  });

  let consistent = true;
  let cdetail = "";
  if (t.pdkMode === "nda") {
    consistent = Boolean(t.activeTechnology) && presence.exists;
    cdetail = consistent
      ? `nda drop for '${t.activeTechnology}' present under ${presence.root}`
      : "nda mode needs activeTechnology + a drop under pdkRoot";
  } else if (t.pdkMode === "omitted") {
    consistent = !presence.ndaContentPresent;
    cdetail = consistent ? "no PDK content on disk (generic path)" : "omitted mode but PDK content is present under pdkRoot";
  } else {
    cdetail = `open PDK '${t.activeTechnology ?? "?"}'`;
  }
  gates.push({ id: "pdk-consistency", hard: true, ok: consistent, detail: cdetail });

  gates.push({
    id: "explicit-only",
    hard: false,
    ok: t.requireExplicit,
    detail: t.requireExplicit ? "pass never edits RTL / hits network implicitly" : "requireExplicit is false (not recommended)",
  });

  const ok = gates.filter((g) => g.hard).every((g) => g.ok);
  return { ok, flagOn: t.optimizationPass, armed: assess.armed, gates };
}

// ---------------------------------------------------------------------------
// Scaffolding a per-technology drop-in (gitignored; never NDA content)
// ---------------------------------------------------------------------------

const TECH_ID_RE = /^[A-Za-z0-9_.-]+$/;

export interface ScaffoldTechResult {
  techId: string;
  dir: string;
  files: string[];
  wrote: boolean;
  dryRun: boolean;
}

function techDropGitignore(): string {
  return [
    "# Per-technology PDK drop-in — NDA / foundry content only.",
    "# Everything here is ignored; only this file + README.md are ever committed.",
    "/*",
    "!/.gitignore",
    "!/README.md",
    "",
  ].join("\n");
}

function techDropReadme(techId: string, guardMacro: string): string {
  return [
    `# PDK drop-in: \`${techId}\` (protected / NDA)`,
    "",
    "**Do not commit any foundry content here.** This directory is gitignored except",
    "for this README and its `.gitignore`. Drop the proprietary, NDA-covered PDK views",
    "into the layout below; the build consumes them only at synthesis / PnR and only",
    `behind the \`${guardMacro}\` guard macro.`,
    "",
    "```",
    `${techId}/`,
    "  manifest.json      # copy of ../manifest.example.json, filled in (gitignored)",
    "  lib/               # timing/power (.lib/.db) — NDA",
    "  lef/               # abstract layout (.lef) — NDA",
    "  gds/               # layout (.gds) — NDA",
    "  macros/            # compiled SRAM/ROM/regfile + hard-macro wrappers — NDA",
    "  cells/             # ICG / retention / level-shifter / IO cell wrappers — NDA",
    "  views/             # Liberty/UPF/CPF power views — NDA",
    "```",
    "",
    "The generic, behavioural path (`tech_cells_generic`, `sram_cache` with",
    "`TECHNO_CUT=0`, hpdcache `behav` macros) is always what elaborates when the guard",
    "macro is undefined, so simulation and open-source CI never need this drop-in.",
    "",
    "See `../README.md`, `AGENTS-technology.md`, and `agents/guides/AGENTS-technology-optimization.md`.",
    "",
  ].join("\n");
}

/** Create a gitignored per-technology drop-in dir (README + .gitignore only). */
export async function scaffoldTechnology(
  ctx: PlatformContext,
  techId: string,
  opts: { dryRun?: boolean } = {},
): Promise<ScaffoldTechResult> {
  if (!TECH_ID_RE.test(techId)) {
    throw new Error(`Invalid technology id '${techId}' (allowed: letters, digits, _ . -).`);
  }
  const paths = technologyPaths(ctx);
  const dir = join(paths.pdkRoot, techId);
  const relDir = rel(ctx.repoRoot, dir);
  if (opts.dryRun) {
    return { techId, dir: relDir, files: [`${relDir}/.gitignore`, `${relDir}/README.md`], wrote: false, dryRun: true };
  }
  await mkdir(dir, { recursive: true });
  const files: string[] = [];
  const gi = join(dir, ".gitignore");
  const readme = join(dir, "README.md");
  if (!existsSync(gi)) {
    await writeFile(gi, techDropGitignore(), "utf8");
    files.push(`${relDir}/.gitignore`);
  }
  if (!existsSync(readme)) {
    await writeFile(readme, techDropReadme(techId, ctx.config.technology.guardMacro), "utf8");
    files.push(`${relDir}/README.md`);
  }
  return { techId, dir: relDir, files, wrote: true, dryRun: false };
}
