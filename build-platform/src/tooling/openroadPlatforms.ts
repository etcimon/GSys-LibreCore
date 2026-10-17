// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// OpenROAD test platforms, discovered from the fork checkout: every
// `tools/openroad/test/<dir>/<name>.vars` the upstream flow tests ship
// (Nangate45, sky130hd, sky130hs, asap7, …) names its liberty corner, LEFs,
// site, tracks and layer RC. Reading those files instead of a hand-kept
// table means a platform added to the fork is a `--platform` the moment it
// is checked in, and the FO4 probe / module board / place study take their
// inputs from the same record the fork's own tests use.
//
// Each platform carries two readiness flags: `yosysMappable` (its liberty is
// plain text — yosys cannot read gzip'd libraries) and `staReadable` (OpenSTA
// reads `.lib.gz`, so asap7 still yields a platform FO4 and can time a
// netlist mapped elsewhere).

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { basename, join } from "node:path";

export interface OpenroadPlatform {
  /** Lower-case id as `set platform` names it (dir name when absent). */
  id: string;
  /** Directory under the fork's `test/`. */
  dir: string;
  /** `<dir>/<name>.vars`, fork-relative. */
  varsFile: string;
  /** Typical-corner liberty, fork-relative (`test/...`). */
  liberty: string;
  /** Extra liberties the corner splits across (fork-relative). */
  extraLiberty: string[];
  /** Technology LEF then standard-cell LEF(s), fork-relative. */
  lefs: string[];
  site?: string;
  tracksFile?: string;
  layerRcFile?: string;
  pdnCfg?: string;
  yosysMappable: boolean;
  staReadable: boolean;
  /** Fork-relative paths that do not exist in this checkout. */
  missing: string[];
}

/** `set name "value"` / `set name value` / `set name {a b}` pairs of a .vars file. */
export function parseTclVars(text: string): Map<string, string[]> {
  const out = new Map<string, string[]>();
  // Join backslash continuations so multi-line quoted values are one statement.
  const joined = text.replace(/\\\r?\n/g, " ");
  const re = /^\s*set\s+(\w+)\s+(\{[^}]*\}|"(?:[^"\\]|\\.)*"|\S+)\s*$/gm;
  let m: RegExpExecArray | null;
  while ((m = re.exec(joined))) {
    const raw = m[2]!;
    let values: string[];
    if (raw.startsWith("{")) values = raw.slice(1, -1).trim().split(/\s+/).filter(Boolean).map((v) => v.replace(/^"|"$/g, ""));
    else if (raw.startsWith('"')) values = [raw.slice(1, -1)];
    else values = [raw];
    out.set(m[1]!, values);
  }
  return out;
}

function platformFromVars(forkRoot: string, dir: string, varsFile: string): OpenroadPlatform | null {
  const text = readFileSync(join(forkRoot, "test", varsFile), "utf8");
  const vars = parseTclVars(text);
  const liberty = vars.get("liberty_file")?.[0];
  if (!liberty) return null;
  const rel = (p: string) => `test/${p}`;
  const lefs = [...(vars.get("tech_lef") ?? []), ...(vars.get("std_cell_lef") ?? []), ...(vars.get("extra_lef") ?? [])].map(rel);
  const extraLiberty = (vars.get("extra_liberty") ?? []).map(rel);
  const all = [rel(liberty), ...extraLiberty, ...lefs];
  const missing = all.filter((p) => !existsSync(join(forkRoot, p)));
  const gz = liberty.endsWith(".gz");
  return {
    id: (vars.get("platform")?.[0] ?? dir).toLowerCase(),
    dir,
    varsFile: rel(varsFile),
    liberty: rel(liberty),
    extraLiberty,
    lefs,
    site: vars.get("site")?.[0],
    tracksFile: vars.get("tracks_file")?.[0] ? rel(vars.get("tracks_file")![0]!) : undefined,
    layerRcFile: vars.get("layer_rc_file")?.[0] ? rel(vars.get("layer_rc_file")![0]!) : undefined,
    pdnCfg: vars.get("pdn_cfg")?.[0] ? rel(vars.get("pdn_cfg")![0]!) : undefined,
    yosysMappable: !gz && !missing.includes(rel(liberty)),
    staReadable: !missing.includes(rel(liberty)),
    missing,
  };
}

/** Every platform the fork checkout under `forkRoot` describes, by id. */
export function detectOpenroadPlatforms(forkRoot: string): OpenroadPlatform[] {
  const testDir = join(forkRoot, "test");
  if (!existsSync(testDir)) return [];
  const out: OpenroadPlatform[] = [];
  for (const dir of readdirSync(testDir)) {
    const full = join(testDir, dir);
    let isDir = false;
    try {
      isDir = statSync(full).isDirectory();
    } catch {
      continue;
    }
    if (!isDir) continue;
    for (const f of readdirSync(full)) {
      if (!f.endsWith(".vars")) continue;
      try {
        const p = platformFromVars(forkRoot, dir, `${dir}/${f}`);
        if (p) out.push(p);
      } catch {
        // an unreadable vars file is not a platform
      }
    }
  }
  return out.sort((a, b) => a.id.localeCompare(b.id));
}

/** The platform whose id (or directory) matches, case-insensitively. */
export function findOpenroadPlatform(forkRoot: string, idOrDir: string): OpenroadPlatform | undefined {
  const k = idOrDir.toLowerCase();
  return detectOpenroadPlatforms(forkRoot).find((p) => p.id === k || p.dir.toLowerCase() === k || basename(p.varsFile, ".vars").toLowerCase() === k);
}

/** One-line description for listings. */
export function describePlatform(p: OpenroadPlatform): string {
  const flags = [p.yosysMappable ? "yosys-map" : "sta-only", p.staReadable ? "sta" : "no-liberty"];
  const miss = p.missing.length ? ` missing: ${p.missing.length}` : "";
  return `${p.id.padEnd(10)} ${p.liberty}${p.extraLiberty.length ? ` (+${p.extraLiberty.length} lib)` : ""} [${flags.join(", ")}]${miss}`;
}
