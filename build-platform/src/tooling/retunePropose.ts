// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// retunePropose.ts — S3b-lab host proposal from correlate.json + fo4-v1 inventory.
// Never edits fo4-v1.toml; emits review-only JSON/Markdown for lab operators.

import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, isAbsolute, join } from "node:path";

import type { PlatformContext } from "../context.ts";
import { posixPath } from "./eda.ts";
import {
  fo4RetuneChecklist,
  inventoryFo4Model,
  type Fo4ModelInventory,
} from "./fo4Inventory.ts";

export interface CorrelateSnapshot {
  path: string;
  schema?: string;
  overlap_score: number | null;
  overlap: string[];
  missing_in_sta: string[];
  missing_in_fo4: string[];
  fo4_rank: Array<{
    rank?: number;
    path_id?: number | null;
    total_fo4?: number;
    start?: string;
    end?: string;
    kind?: string;
  }>;
  sta_rank: Array<{
    rank?: number;
    start?: string;
    end?: string;
    slack?: number;
  }>;
  package?: string;
  top?: string;
  sta_report?: string | null;
  note?: string;
}

export interface CostHint {
  costKey: string;
  reason: string;
  current?: number;
  pathKinds: string[];
  examples: string[];
}

export interface RetuneProposal {
  schema: "cva6-fo4-retune-proposal.v0";
  generatedAt: string;
  disclaimer: string;
  correlatePath: string | null;
  fo4ModelPath: string | null;
  fo4Version: string | null;
  overlap_score: number | null;
  agreement: "high" | "medium" | "low" | "unknown" | "fixture_or_empty";
  syntheticLikely: boolean;
  actions: string[];
  costHints: CostHint[];
  missing_in_sta: string[];
  missing_in_fo4: string[];
  checklist: string[];
  costs: Record<string, number>;
}

/** Map FO4 path kinds / names to fo4-v1.toml cost keys (best-effort). */
export function mapKindToCostKeys(kind: string | undefined, pathLabel: string): string[] {
  const k = (kind ?? "").toLowerCase();
  const p = pathLabel.toLowerCase();
  const keys = new Set<string>();
  const add = (...xs: string[]) => xs.forEach((x) => keys.add(x));

  if (/mul|mult/.test(k) || /\bmul\b|\bmult\b/.test(p)) add("mul");
  if (/div|rem/.test(k) || /\bdiv\b|\brem\b/.test(p)) add("div_rem");
  if (/mux|sel|priority/.test(k) || /\bmux\b/.test(p)) add("mux", "priority_mux_per_level");
  if (/add|sub|alu|arith/.test(k) || /\badd\b|\bsub\b/.test(p)) add("add_sub");
  if (/cmp|compare|eq|lt|gt/.test(k) || /\bcmp\b/.test(p)) add("compare");
  if (/shift|sh[lr]|rot/.test(k) || /\bsh[lr]\b|\bshift\b/.test(p)) {
    add("shift_var", "shift_const");
  }
  if (/concat|cat/.test(k)) add("concat");
  if (keys.size === 0) {
    if (/in_to_reg|reg_to_out|comb/.test(k)) add("logic_bit", "add_sub", "other");
    else add("other", "logic_bit");
  }
  return [...keys];
}

export function classifyAgreement(
  score: number | null,
  hasSta: boolean,
): RetuneProposal["agreement"] {
  if (!hasSta || score == null) return "unknown";
  if (score >= 0.75) return "high";
  if (score >= 0.4) return "medium";
  return "low";
}

export function loadCorrelateJson(path: string): CorrelateSnapshot | null {
  if (!existsSync(path)) return null;
  try {
    const raw = JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>;
    return {
      path,
      schema: typeof raw.schema === "string" ? raw.schema : undefined,
      overlap_score:
        typeof raw.overlap_score === "number"
          ? raw.overlap_score
          : raw.overlap_score === null
            ? null
            : null,
      overlap: Array.isArray(raw.overlap) ? (raw.overlap as string[]) : [],
      missing_in_sta: Array.isArray(raw.missing_in_sta)
        ? (raw.missing_in_sta as string[])
        : [],
      missing_in_fo4: Array.isArray(raw.missing_in_fo4)
        ? (raw.missing_in_fo4 as string[])
        : [],
      fo4_rank: Array.isArray(raw.fo4_rank)
        ? (raw.fo4_rank as CorrelateSnapshot["fo4_rank"])
        : [],
      sta_rank: Array.isArray(raw.sta_rank)
        ? (raw.sta_rank as CorrelateSnapshot["sta_rank"])
        : [],
      package: typeof raw.package === "string" ? raw.package : undefined,
      top: typeof raw.top === "string" ? raw.top : undefined,
      sta_report:
        typeof raw.sta_report === "string"
          ? raw.sta_report
          : raw.sta_report === null
            ? null
            : undefined,
      note: typeof raw.note === "string" ? raw.note : undefined,
    };
  } catch {
    return null;
  }
}

/** Resolve correlate.json under a handoff dir or direct path. */
export function resolveCorrelatePath(
  ctx: PlatformContext,
  spec?: string | null,
): string | null {
  if (spec) {
    const candidates = [
      spec,
      join(ctx.repoRoot, spec),
      join(ctx.paths.root, spec),
      join(spec, "correlate.json"),
      join(ctx.repoRoot, spec, "correlate.json"),
      join(ctx.paths.root, spec, "correlate.json"),
    ];
    for (const c of candidates) {
      if (existsSync(c) && c.endsWith(".json")) return c;
      const asDir = join(c, "correlate.json");
      if (existsSync(asDir)) return asDir;
    }
    if (existsSync(spec)) return isAbsolute(spec) ? spec : join(ctx.repoRoot, spec);
    return null;
  }
  const defaults = [
    join(ctx.paths.build, "sta-handoff", "lab-run", "correlate.json"),
    join(ctx.paths.root, "build", "sta-handoff", "lab-run", "correlate.json"),
  ];
  for (const d of defaults) {
    if (existsSync(d)) return d;
  }
  // Newest correlate under sta-handoff/*
  const handoffRoot = join(ctx.paths.build, "sta-handoff");
  if (existsSync(handoffRoot)) {
    try {
      let best: { p: string; m: number } | null = null;
      for (const name of readdirSync(handoffRoot)) {
        const p = join(handoffRoot, name, "correlate.json");
        if (!existsSync(p)) continue;
        const m = statSync(p).mtimeMs;
        if (!best || m > best.m) best = { p, m };
      }
      return best?.p ?? null;
    } catch {
      return null;
    }
  }
  return null;
}

function isSyntheticStaReport(path: string | null | undefined): boolean {
  if (!path || !existsSync(path)) return false;
  try {
    const head = readFileSync(path, "utf8").slice(0, 200);
    return /Synthetic OpenSTA/i.test(head);
  } catch {
    return false;
  }
}

export function buildRetuneProposal(
  corr: CorrelateSnapshot | null,
  inv: Fo4ModelInventory,
): RetuneProposal {
  const score = corr?.overlap_score ?? null;
  const hasSta = (corr?.sta_rank?.length ?? 0) > 0;
  const syntheticLikely =
    isSyntheticStaReport(corr?.sta_report) ||
    (corr?.note?.toLowerCase().includes("fixture") ?? false);
  const agreement = syntheticLikely
    ? "fixture_or_empty"
    : classifyAgreement(score, hasSta);

  const costHints = new Map<string, CostHint>();
  const bump = (key: string, reason: string, kind: string, example: string) => {
    const cur = costHints.get(key);
    if (cur) {
      if (!cur.pathKinds.includes(kind)) cur.pathKinds.push(kind);
      if (cur.examples.length < 6 && !cur.examples.includes(example)) {
        cur.examples.push(example);
      }
      return;
    }
    costHints.set(key, {
      costKey: key,
      reason,
      current: inv.costs[key],
      pathKinds: kind ? [kind] : [],
      examples: example ? [example] : [],
    });
  };

  if (corr) {
    for (const row of corr.fo4_rank.slice(0, 16)) {
      const label = `${row.start ?? "?"}→${row.end ?? "?"}`;
      const kind = row.kind ?? "";
      // Paths FO4 ranks highly that STA missed → FO4 may over-weight this class
      const missed = corr.missing_in_sta.some(
        (m) =>
          m.includes(row.start ?? "\0") ||
          m === label ||
          m.replace(/→/g, "->") === label.replace(/→/g, "->"),
      );
      for (const key of mapKindToCostKeys(kind, label)) {
        if (missed) {
          bump(
            key,
            "FO4 top path missing in STA — FO4 may over-rank this class or names differ",
            kind,
            label,
          );
        } else if (agreement === "low" || agreement === "medium") {
          bump(
            key,
            "Imperfect FO4↔STA overlap — review cost if rank order disagrees with STA WNS",
            kind,
            label,
          );
        }
      }
    }
    for (const m of corr.missing_in_fo4.slice(0, 12)) {
      for (const key of mapKindToCostKeys(undefined, m)) {
        bump(
          key,
          "STA path not in FO4 top-N — FO4 may under-rank or hierarchical names diverge",
          "",
          m,
        );
      }
    }
  }

  const actions: string[] = [];
  if (!corr) {
    actions.push("No correlate.json found — run: timings lab-run  (or sta-handoff --from-timing …)");
  } else if (!hasSta) {
    actions.push(
      "correlate has no sta_rank — run with CVA6_LIBERTY + opensta, or keep offline fixture for S3a only",
    );
  } else if (syntheticLikely) {
    actions.push(
      "STA report looks synthetic (offline fixture) — do not retune fo4-v1.toml from this correlate",
    );
    actions.push(
      "Lab: CVA6_LIBERTY=/path/to.lib timings lab-run --no-sta-fixture --try-tools  then re-run retune-propose",
    );
  } else if (agreement === "high" && corr.missing_in_sta.length === 0 && corr.missing_in_fo4.length === 0) {
    actions.push(
      "High overlap and no missing paths — no FO4 table edit required from this correlate",
    );
    actions.push(
      "Optional: compare FO4 total_fo4 rank order vs STA slack order; only retune if critical paths disagree by class",
    );
  } else {
    actions.push(
      "Review costHints below; edit sv-timing/resources/fo4-v1.toml only with real STA evidence",
    );
    actions.push(
      "After edit: cd sv-timing && python tools/svt.py test -p sv-timing-core",
    );
    actions.push(
      "Refresh package goldens: timings fo4-golden write --from-timing <pkg>",
    );
  }

  if (costHints.size === 0 && inv.present) {
    // Always surface primary arithmetic costs as lab context when no specific disagreement
    for (const key of ["mul", "div_rem", "add_sub", "mux", "logic_bit"] as const) {
      if (inv.costs[key] != null) {
        costHints.set(key, {
          costKey: key,
          reason: "Inventory reference (no specific disagreement flagged)",
          current: inv.costs[key],
          pathKinds: [],
          examples: [],
        });
      }
    }
  }

  return {
    schema: "cva6-fo4-retune-proposal.v0",
    generatedAt: new Date().toISOString(),
    disclaimer:
      "Review-only S3b-lab proposal — never auto-edits fo4-v1.toml; FO4 is not STA sign-off",
    correlatePath: corr ? posixPath(corr.path) : null,
    fo4ModelPath: inv.path,
    fo4Version: inv.version,
    overlap_score: score,
    agreement,
    syntheticLikely,
    actions,
    costHints: [...costHints.values()].sort((a, b) => a.costKey.localeCompare(b.costKey)),
    missing_in_sta: corr?.missing_in_sta ?? [],
    missing_in_fo4: corr?.missing_in_fo4 ?? [],
    checklist: fo4RetuneChecklist(inv),
    costs: inv.costs,
  };
}

export function formatRetuneProposalMarkdown(p: RetuneProposal): string {
  const lines: string[] = [
    "# FO4 retune proposal (S3b-lab)",
    "",
    `> ${p.disclaimer}`,
    "",
    `- **Generated:** ${p.generatedAt}`,
    `- **Agreement:** \`${p.agreement}\`${p.syntheticLikely ? " (synthetic STA fixture)" : ""}`,
    `- **overlap_score:** ${p.overlap_score ?? "null"}`,
    `- **correlate:** \`${p.correlatePath ?? "(none)"}\``,
    `- **fo4 model:** \`${p.fo4ModelPath ?? "(none)"}\` version=${p.fo4Version ?? "?"}`,
    "",
    "## Actions",
    "",
  ];
  for (const a of p.actions) lines.push(`- ${a}`);
  lines.push("", "## Cost hints", "");
  if (p.costHints.length === 0) {
    lines.push("_No cost hints._", "");
  } else {
    lines.push("| key | current | reason | examples |", "|-----|---------|--------|----------|");
    for (const h of p.costHints) {
      const ex = h.examples.slice(0, 3).join("; ") || "—";
      lines.push(
        `| \`${h.costKey}\` | ${h.current ?? "—"} | ${h.reason} | ${ex} |`,
      );
    }
    lines.push("");
  }
  if (p.missing_in_sta.length || p.missing_in_fo4.length) {
    lines.push("## Missing paths", "");
    if (p.missing_in_sta.length) {
      lines.push("### FO4 tops missing in STA", "");
      for (const m of p.missing_in_sta) lines.push(`- \`${m}\``);
      lines.push("");
    }
    if (p.missing_in_fo4.length) {
      lines.push("### STA tops missing in FO4", "");
      for (const m of p.missing_in_fo4) lines.push(`- \`${m}\``);
      lines.push("");
    }
  }
  lines.push("## Checklist", "");
  for (const c of p.checklist) lines.push(`- ${c}`);
  lines.push(
    "",
    "---",
    "",
    "Plan: `architecture/build-platform-opensta-from-timing.md` § S3b-lab",
    "",
  );
  return lines.join("\n");
}

export function writeRetuneProposal(
  outDir: string,
  proposal: RetuneProposal,
): { json: string; md: string; proposal: RetuneProposal } {
  mkdirSync(outDir, { recursive: true });
  const json = join(outDir, "retune-proposal.json");
  const md = join(outDir, "retune-proposal.md");
  writeFileSync(json, JSON.stringify(proposal, null, 2) + "\n", "utf8");
  writeFileSync(md, formatRetuneProposalMarkdown(proposal), "utf8");
  return { json: posixPath(json), md: posixPath(md), proposal };
}

export function proposeFo4Retune(
  ctx: PlatformContext,
  opts?: {
    /** Path to correlate.json or handoff dir */
    fromHandoff?: string | null;
    /** Write under this dir (default: same as correlate parent or sta-handoff/lab-run) */
    outDir?: string | null;
  },
): {
  ok: boolean;
  correlatePath: string | null;
  written: { json: string; md: string } | null;
  proposal: RetuneProposal;
} {
  const corrPath = resolveCorrelatePath(ctx, opts?.fromHandoff);
  const corr = corrPath ? loadCorrelateJson(corrPath) : null;
  const inv = inventoryFo4Model(ctx);
  const proposal = buildRetuneProposal(corr, inv);
  let outDir = opts?.outDir ?? null;
  if (!outDir && corrPath) outDir = dirname(corrPath);
  if (!outDir) outDir = join(ctx.paths.build, "sta-handoff", "lab-run");
  const written = writeRetuneProposal(outDir, proposal);
  return {
    ok: true,
    correlatePath: corrPath,
    written: { json: written.json, md: written.md },
    proposal,
  };
}
