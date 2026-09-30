// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// verilatorPatch.ts — Are the LibreCore fixes to Verilator present in a prefix?
//
// The gate's Verilator is the pinned tag PLUS every verif/regress/verilator-*.patch.
// The upstream installer applies them with `git apply || true`, so an unpatched
// tool can appear silently; this module is the single check that
// `tools install verilator`, `diag status`/`edaPresence` and the sim preflight
// share so the platform always runs the built, patched version.
//
// Verification is by content: for each file a patch touches under include/,
// every added line must appear verbatim in <prefix>/share/verilator/include/<file>.
// Patches to src/ have no installed artefact to inspect; `--version` prints
// "(mod)" for a tree built with local modifications and is reported as well.

import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

/** Repo-relative directory that holds the custom Verilator patches. */
export const VERILATOR_PATCH_DIR = "verif/regress";

export interface VerilatorPatchStatus {
  /** Every checked header line is present (and there was something to check). */
  patched: boolean;
  /** Absolute paths of the patches that were considered. */
  patches: string[];
  /** Added header lines verified present. */
  checked: number;
  /** Human-readable misses: `<installed header>: <line>`. */
  missing: string[];
  /** Installed header files that could not be read at all. */
  unreadable: string[];
}

/** Absolute paths of verif/regress/verilator-*.patch, sorted. */
export function listVerilatorPatches(repoRoot: string): string[] {
  const dir = join(repoRoot, VERILATOR_PATCH_DIR);
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((f) => /^verilator-.*\.patch$/.test(f))
    .sort()
    .map((f) => join(dir, f));
}

/**
 * Added lines per patched `include/` file, keyed by the path relative to
 * include/ (e.g. `verilated_types.h`). Blank additions are ignored.
 */
export function patchedHeaderLines(patchText: string): Map<string, string[]> {
  const out = new Map<string, string[]>();
  let file: string | null = null;
  for (const raw of patchText.split(/\r?\n/)) {
    if (raw.startsWith("+++ ")) {
      const target = raw.slice(4);
      const m = target.match(/^b\/include\/(.+)$/);
      file = m ? (m[1] as string) : null;
      continue;
    }
    if (raw.startsWith("+") && !raw.startsWith("+++") && file) {
      const added = raw.slice(1);
      if (added.trim().length === 0) continue;
      const list = out.get(file) ?? [];
      list.push(added);
      out.set(file, list);
    }
  }
  return out;
}

/**
 * Check an installed Verilator prefix (`<prefix>/share/verilator/include`)
 * against the repo's custom patches.
 */
export function verilatorPatchStatus(prefix: string, repoRoot: string): VerilatorPatchStatus {
  const patches = listVerilatorPatches(repoRoot);
  const incRoot = join(prefix, "share", "verilator", "include");
  const missing: string[] = [];
  const unreadable: string[] = [];
  let checked = 0;
  for (const p of patches) {
    const lines = patchedHeaderLines(readFileSync(p, "utf8"));
    for (const [rel, added] of lines) {
      const installed = join(incRoot, rel);
      let text: string;
      try {
        text = readFileSync(installed, "utf8");
      } catch {
        unreadable.push(installed);
        continue;
      }
      for (const line of added) {
        checked += 1;
        if (!text.includes(line)) missing.push(`${installed}: ${line.trim()}`);
      }
    }
  }
  return {
    patched: patches.length > 0 && checked > 0 && missing.length === 0 && unreadable.length === 0,
    patches,
    checked,
    missing,
    unreadable,
  };
}

/** One-line summary for logs and status boxes. */
export function formatVerilatorPatchStatus(s: VerilatorPatchStatus): string {
  if (s.patches.length === 0) return "no custom patches in verif/regress";
  if (s.patched) return `patched (${s.checked} header line(s) from ${s.patches.length} patch(es))`;
  const why = s.unreadable.length
    ? `header(s) not readable: ${s.unreadable.map((u) => u.split(/[\\/]/).pop()).join(", ")}`
    : `${s.missing.length} patched line(s) missing`;
  return `UNPATCHED — ${why}`;
}
