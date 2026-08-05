// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// fo4Inventory.ts — Read fo4-v1.toml for S3b-lab retune checklist (host-side).
// Does not load Rust cost code; simple TOML key=value inventory for operators.

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

import type { PlatformContext } from "../context.ts";
import { resolveSvTimingRoot } from "./timings.ts";
import { posixPath } from "./eda.ts";

export interface Fo4ModelInventory {
  path: string | null;
  present: boolean;
  version: string | null;
  /** Scalar cost keys from fo4-v1.toml */
  costs: Record<string, number>;
  notes: string[];
}

/** Parse simple key = value TOML (no nested tables) used by fo4-v1.toml. */
export function parseFo4Toml(text: string): {
  version: string | null;
  costs: Record<string, number>;
} {
  let version: string | null = null;
  const costs: Record<string, number> = {};
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.replace(/#.*$/, "").trim();
    if (!line) continue;
    const m = /^([A-Za-z0-9_]+)\s*=\s*(.+)$/.exec(line);
    if (!m) continue;
    const key = m[1]!;
    let val = m[2]!.trim();
    if (val.startsWith('"') && val.endsWith('"')) {
      val = val.slice(1, -1);
      if (key === "version") version = val;
      continue;
    }
    const n = Number(val);
    if (Number.isFinite(n)) costs[key] = n;
  }
  return { version, costs };
}

export function inventoryFo4Model(ctx: PlatformContext): Fo4ModelInventory {
  const notes: string[] = [];
  const root = resolveSvTimingRoot(ctx);
  if (!root) {
    return {
      path: null,
      present: false,
      version: null,
      costs: {},
      notes: ["sv-timing package not found — cannot load fo4-v1.toml"],
    };
  }
  const path = join(root, "resources", "fo4-v1.toml");
  if (!existsSync(path)) {
    return {
      path: posixPath(path),
      present: false,
      version: null,
      costs: {},
      notes: ["resources/fo4-v1.toml missing"],
    };
  }
  const parsed = parseFo4Toml(readFileSync(path, "utf8"));
  notes.push(
    "S3b-lab: when STA correlate disagrees with FO4 ranking, adjust costs here and re-run package goldens (cargo test + timings fo4-golden).",
  );
  notes.push(
    "Do not treat FO4 as STA. Prefer STA WNS for silicon; use FO4 only for structural screening.",
  );
  if (Object.keys(parsed.costs).length === 0) {
    notes.push("no numeric cost keys parsed — check TOML format");
  }
  return {
    path: posixPath(path),
    present: true,
    version: parsed.version,
    costs: parsed.costs,
    notes,
  };
}

/** Suggested retune checklist lines for lab operators. */
export function fo4RetuneChecklist(inv: Fo4ModelInventory): string[] {
  return [
    "1. Run timings lab-run (or compile + sta-handoff) with CVA6_LIBERTY + opensta",
    "2. Inspect sta-handoff/*/correlate.json (overlap_score, missing_in_sta, missing_in_fo4)",
    "3. If FO4 ranks wrong classes (mul/div/mux), edit fo4-v1.toml costs below",
    "4. Re-run: cd sv-timing && python tools/svt.py test -p sv-timing-core",
    "5. Update fixture goldens: timings fo4-golden write --from-timing <pkg>",
    "6. Commit fo4-v1.toml + goldens with lab note (STA tool/liberty revision)",
    inv.path ? `Model file: ${inv.path}` : "Model file: (missing)",
    inv.version ? `Version: ${inv.version}` : "Version: (unknown)",
  ];
}
