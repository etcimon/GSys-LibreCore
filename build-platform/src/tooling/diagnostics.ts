// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// diagnostics.ts — Compartmentalized diagnostic tests with per-test Verilator
// configs. Driven by config.diagnostics; surfaced by `diag` and `probe diag`.

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

import type { PlatformContext } from "../context.ts";
import type {
  DiagnosticCompartment,
  DiagnosticTest,
  DiagnosticsConfig,
} from "../config/schema.ts";
import {
  edaPaths,
  lintWithSurface,
  type EdaPaths,
  type StageOutcome,
} from "./eda.ts";
import { hasManagedTool } from "../tests/runner.ts";
import type { ProbeReport } from "./probe.ts";

export const DIAG_COMPARTMENTS: DiagnosticCompartment[] = [
  "host",
  "core",
  "smt2",
  "ooo",
  "ai",
  "apu",
  "residual",
];

export interface DiagnosticOutcome {
  id: string;
  compartment: DiagnosticCompartment;
  kind: DiagnosticTest["kind"];
  status: "pass" | "fail" | "skip";
  detail: string;
  durationMs: number;
  optional: boolean;
  /** Verilator warning count when applicable. */
  warnings?: number;
  log?: string[];
}

export interface DiagnosticRunSummary {
  outcomes: DiagnosticOutcome[];
  passed: number;
  failed: number;
  skipped: number;
  /** Failed non-optional tests. */
  hardFails: number;
}

export function listDiagnostics(config: DiagnosticsConfig): DiagnosticTest[] {
  return config.tests;
}

export function selectDiagnostics(
  config: DiagnosticsConfig,
  filter?: string[],
): { tests: DiagnosticTest[]; unknown: string[] } {
  if (!filter || filter.length === 0) {
    const comps = new Set(
      config.defaultCompartments.length
        ? config.defaultCompartments
        : DIAG_COMPARTMENTS,
    );
    return {
      tests: config.tests.filter((t) => comps.has(t.compartment) && !t.optional),
      unknown: [],
    };
  }

  const byId = new Map(config.tests.map((t) => [t.id, t]));
  const tests: DiagnosticTest[] = [];
  const unknown: string[] = [];
  const seen = new Set<string>();

  for (const f of filter) {
    const key = f.trim().toLowerCase();
    // compartment name
    if ((DIAG_COMPARTMENTS as string[]).includes(key)) {
      for (const t of config.tests.filter((x) => x.compartment === key)) {
        if (!seen.has(t.id)) {
          seen.add(t.id);
          tests.push(t);
        }
      }
      continue;
    }
    // exact id
    const t = byId.get(f) ?? byId.get(key);
    if (t) {
      if (!seen.has(t.id)) {
        seen.add(t.id);
        tests.push(t);
      }
    } else {
      unknown.push(f);
    }
  }
  return { tests, unknown };
}

async function runProbeCap(
  ctx: PlatformContext,
  test: DiagnosticTest,
  report: ProbeReport | null,
): Promise<DiagnosticOutcome> {
  const started = performance.now();
  const caps = test.probeCaps ?? [];
  // Lazy-load report once for the batch (caller may pass cached; dynamic import
  // avoids probe ↔ diagnostics circular init).
  const r =
    report ??
    (await (await import("./probe.ts")).gatherProbeReport(ctx));
  // Reuse residual + managed from report via a light check:
  // capability strings map to managed/utils/residual presence already computed
  // for the command matrix — re-scan tools similarly.
  const missing: string[] = [];
  for (const cap of caps) {
    const ok = capSatisfied(cap, r, ctx);
    if (!ok) missing.push(cap);
  }
  const durationMs = Math.round(performance.now() - started);
  if (missing.length === 0) {
    return {
      id: test.id,
      compartment: test.compartment,
      kind: test.kind,
      status: "pass",
      detail: `caps ok: ${caps.join(", ") || "(none)"}`,
      durationMs,
      optional: Boolean(test.optional),
    };
  }
  if (test.optional) {
    return {
      id: test.id,
      compartment: test.compartment,
      kind: test.kind,
      status: "skip",
      detail: `optional caps missing: ${missing.join(", ")}`,
      durationMs,
      optional: true,
    };
  }
  return {
    id: test.id,
    compartment: test.compartment,
    kind: test.kind,
    status: "fail",
    detail: `missing caps: ${missing.join(", ")}`,
    durationMs,
    optional: false,
  };
}

function capSatisfied(cap: string, report: ProbeReport, ctx: PlatformContext): boolean {
  // Managed / residual
  if (cap === "spike") {
    return (
      report.managedTools.some((t) => t.id === "spike" && t.installed) ||
      report.residualRoots.some((r) => r.present && r.id.includes("spike"))
    );
  }
  if (cap === "verilator") {
    return (
      report.managedTools.some((t) => t.id === "verilator" && t.installed) ||
      report.utils.some((u) => u.id === "verilator" && u.found) ||
      report.residualRoots.some(
        (r) => r.present && (r.id.includes("verilator") || r.id.includes("oss-cad")),
      )
    );
  }
  if (cap === "riscv-gcc") {
    return (
      report.managedTools.some((t) => t.id === "riscv-gcc" && t.installed) ||
      report.residualRoots.some((r) => r.present && r.id.includes("riscv"))
    );
  }
  if (cap === "opensbi-smt2") {
    return (
      report.managedTools.some((t) => t.id === "opensbi-smt2" && t.installed) ||
      report.residualRoots.some((r) => r.id === "smt2-fw_payload" && r.present)
    );
  }
  if (cap === "linux-or-wsl") {
    return report.host.os !== "windows" || report.host.wsl;
  }
  if (cap === "bun" || cap === "git" || cap === "bash" || cap === "make" || cap === "python") {
    if (cap === "python") {
      return report.utils.some((u) => (u.id === "python" || u.id === "python3") && u.found);
    }
    return report.utils.some((u) => u.id === cap && u.found) || (cap === "bun" && Boolean(report.host.bunVersion));
  }
  // Command matrix already evaluated capabilities
  const cmdHit = report.commands.find((c) => c.needs.includes(cap) || c.required.includes(cap));
  if (cmdHit && cmdHit.status === "ok") return true;
  void ctx;
  return false;
}

function runPathCheck(ctx: PlatformContext, test: DiagnosticTest): DiagnosticOutcome {
  const started = performance.now();
  const missing: string[] = [];
  for (const p of test.paths ?? []) {
    if (!existsSync(join(ctx.repoRoot, p))) missing.push(p);
  }
  const durationMs = Math.round(performance.now() - started);
  if (missing.length === 0) {
    return {
      id: test.id,
      compartment: test.compartment,
      kind: test.kind,
      status: "pass",
      detail: `paths ok (${test.paths?.length ?? 0})`,
      durationMs,
      optional: Boolean(test.optional),
    };
  }
  if (test.optional) {
    return {
      id: test.id,
      compartment: test.compartment,
      kind: test.kind,
      status: "skip",
      detail: `optional paths missing: ${missing.join(", ")}`,
      durationMs,
      optional: true,
    };
  }
  return {
    id: test.id,
    compartment: test.compartment,
    kind: test.kind,
    status: "fail",
    detail: `missing: ${missing.join(", ")}`,
    durationMs,
    optional: false,
  };
}

function stageToDiag(
  test: DiagnosticTest,
  outcome: StageOutcome,
): DiagnosticOutcome {
  return {
    id: test.id,
    compartment: test.compartment,
    kind: test.kind,
    status: outcome.status,
    detail: outcome.detail,
    durationMs: outcome.durationMs,
    optional: Boolean(test.optional),
    warnings: outcome.warnings,
    log: outcome.log,
  };
}

/** Collect files under `roots` with a matching extension, skipping `exclude`. */
function collectSourceFiles(
  repoRoot: string,
  roots: string[],
  extensions: string[],
  exclude: string[],
): string[] {
  const out: string[] = [];
  const skip = exclude.map((e) => e.replace(/\\/g, "/"));
  const walk = (rel: string): void => {
    const norm = rel.replace(/\\/g, "/");
    if (skip.some((s) => norm === s || norm.startsWith(`${s}/`))) return;
    const abs = join(repoRoot, rel);
    let st;
    try {
      st = statSync(abs);
    } catch {
      return;
    }
    if (st.isFile()) {
      if (extensions.some((e) => norm.endsWith(e))) out.push(norm);
      return;
    }
    if (!st.isDirectory()) return;
    let names: string[];
    try {
      names = readdirSync(abs);
    } catch {
      return;
    }
    for (const n of names) walk(`${norm}/${n}`);
  };
  for (const r of roots) walk(r);
  return out;
}

/**
 * Mechanical red-line tripwire. Whitespace is collapsed before matching so a
 * pattern can span a multi-line `if`; the reported line number is recovered by
 * locating the match's first token in the raw text.
 */
function runSourceScan(ctx: PlatformContext, test: DiagnosticTest): DiagnosticOutcome {
  const started = performance.now();
  const cfg = test.sourceScan;
  const fin = (
    status: DiagnosticOutcome["status"],
    detail: string,
    recorded?: string[],
  ): DiagnosticOutcome => ({
    id: test.id,
    compartment: test.compartment,
    kind: test.kind,
    status,
    detail,
    durationMs: Math.round(performance.now() - started),
    optional: Boolean(test.optional),
    // Recorded (waived) hits are the H7 ledger entries, surfaced as log lines.
    log: recorded && recorded.length > 0 ? recorded : undefined,
  });
  if (!cfg) return fin("fail", "source-scan diagnostic has no sourceScan config");

  const files = collectSourceFiles(
    ctx.repoRoot,
    cfg.roots,
    cfg.extensions,
    cfg.exclude ?? [],
  );
  const violations: string[] = [];
  const waived: string[] = [];

  for (const rel of files) {
    let raw: string;
    try {
      raw = readFileSync(join(ctx.repoRoot, rel), "utf8");
    } catch {
      continue;
    }
    // Collapse whitespace while keeping a collapsed-index -> raw-index map, so
    // a hit reports the line it is actually on rather than the first textual
    // lookalike in the file.
    let collapsed = "";
    const rawAt: number[] = [];
    for (let i = 0; i < raw.length; i++) {
      const ch = raw[i] as string;
      if (ch === " " || ch === "\t" || ch === "\n" || ch === "\r" || ch === "\f" || ch === "\v") {
        if (collapsed.length > 0 && collapsed[collapsed.length - 1] !== " ") {
          collapsed += " ";
          rawAt.push(i);
        }
        continue;
      }
      collapsed += ch;
      rawAt.push(i);
    }
    // Line number of each raw offset, computed once per file.
    const lineAt = (rawIdx: number): number => {
      let n = 1;
      for (let i = 0; i < rawIdx && i < raw.length; i++) if (raw[i] === "\n") n++;
      return n;
    };
    for (const f of cfg.forbid) {
      const flags = f.flags ?? "";
      const re = new RegExp(f.pattern, flags.includes("g") ? flags : `${flags}g`);
      let m: RegExpExecArray | null;
      while ((m = re.exec(collapsed)) !== null) {
        if (m[0].length === 0) {
          re.lastIndex += 1;
          continue;
        }
        const line = lineAt(rawAt[m.index] ?? 0);
        const at = `${rel}:${line}`;
        const allow = (cfg.allow ?? []).find(
          (a) => a.id === f.id && rel.startsWith(a.path.replace(/\\/g, "/")),
        );
        if (allow) {
          waived.push(`${f.id} ${at} (recorded: ${allow.note})`);
        } else {
          violations.push(`${f.id} ${at}\n      ${f.rationale}\n      remedy: ${f.remedy}`);
        }
      }
    }
  }

  const scanned = `scanned ${files.length} file(s)`;
  if (violations.length > 0) {
    return fin(
      "fail",
      `${violations.length} red-line violation(s); ${scanned}\n    ${violations.join("\n    ")}`,
      waived,
    );
  }
  return fin(
    "pass",
    `no new red lines; ${scanned}${waived.length > 0 ? `, ${waived.length} recorded` : ""}`,
    waived,
  );
}

async function runVerilatorDiag(
  ctx: PlatformContext,
  paths: EdaPaths,
  test: DiagnosticTest,
): Promise<DiagnosticOutcome> {
  const v = test.verilator;
  if (!v) {
    return {
      id: test.id,
      compartment: test.compartment,
      kind: test.kind,
      status: "fail",
      detail: "verilator config missing on diagnostic",
      durationMs: 0,
      optional: Boolean(test.optional),
    };
  }

  // Preflight tools
  for (const tool of test.tools ?? []) {
    if (!hasManagedTool(ctx, tool) && tool === "verilator") {
      // Residual Verilator: edaPaths may still find oss-cad under workspace
      if (!existsSync(paths.verilator)) {
        if (test.optional) {
          return {
            id: test.id,
            compartment: test.compartment,
            kind: test.kind,
            status: "skip",
            detail: "verilator not available (optional)",
            durationMs: 0,
            optional: true,
          };
        }
        return {
          id: test.id,
          compartment: test.compartment,
          kind: test.kind,
          status: "fail",
          detail: `missing tool: ${tool}`,
          durationMs: 0,
          optional: false,
        };
      }
    }
  }

  const envDefines = (process.env.AI_MATRIX_DEFINES ?? "")
    .split("+")
    .map((d) => d.trim())
    .filter(Boolean);
  const surface = {
    target: v.target,
    top: v.top,
    flist: v.flist,
    extraFlists: v.extraFlists,
    lintArgs: v.lintArgs,
    lintArgsMode: v.lintArgsMode,
    defines: [...(v.defines ?? []), ...envDefines],
    waiverFile: v.waiverFile,
    warningBudget: v.warningBudget,
    tag: test.id,
  };

  const outcome = await lintWithSurface(ctx, paths, surface);
  if (outcome.status === "skip" && test.optional) {
    return stageToDiag(test, { ...outcome, status: "skip" });
  }
  return stageToDiag(test, outcome);
}

/** Run one diagnostic test. */
export async function runDiagnostic(
  ctx: PlatformContext,
  test: DiagnosticTest,
  options: { paths?: EdaPaths; probeReport?: ProbeReport | null } = {},
): Promise<DiagnosticOutcome> {
  const paths = options.paths ?? edaPaths(ctx);
  switch (test.kind) {
    case "path-check":
      return runPathCheck(ctx, test);
    case "source-scan":
      return runSourceScan(ctx, test);
    case "probe-cap":
      return runProbeCap(ctx, test, options.probeReport ?? null);
    case "verilator-lint":
    case "verilator-elab":
      // elab currently shares lint surface (Verilator); slang can be added later
      return runVerilatorDiag(ctx, paths, test);
    default:
      return {
        id: test.id,
        compartment: test.compartment,
        kind: test.kind,
        status: "fail",
        detail: `unknown kind ${test.kind}`,
        durationMs: 0,
        optional: Boolean(test.optional),
      };
  }
}

/** Run a selection of diagnostics. */
export async function runDiagnostics(
  ctx: PlatformContext,
  filter?: string[],
): Promise<DiagnosticRunSummary> {
  const { tests, unknown } = selectDiagnostics(ctx.config.diagnostics, filter);
  const paths = edaPaths(ctx);
  // One probe report for all probe-cap diags
  let probeReport: ProbeReport | null = null;
  if (tests.some((t) => t.kind === "probe-cap")) {
    probeReport = await (await import("./probe.ts")).gatherProbeReport(ctx);
  }

  const outcomes: DiagnosticOutcome[] = [];
  for (const u of unknown) {
    outcomes.push({
      id: u,
      compartment: "host",
      kind: "path-check",
      status: "fail",
      detail: `unknown diagnostic or compartment: ${u}`,
      durationMs: 0,
      optional: false,
    });
  }

  for (const t of tests) {
    outcomes.push(await runDiagnostic(ctx, t, { paths, probeReport }));
  }

  const passed = outcomes.filter((o) => o.status === "pass").length;
  const failed = outcomes.filter((o) => o.status === "fail").length;
  const skipped = outcomes.filter((o) => o.status === "skip").length;
  const hardFails = outcomes.filter((o) => o.status === "fail" && !o.optional).length;

  return { outcomes, passed, failed, skipped, hardFails };
}

/** Status rows for probe without running Verilator. */
export function diagnosticReadiness(
  ctx: PlatformContext,
  probeReport?: ProbeReport | null,
): {
  id: string;
  compartment: DiagnosticCompartment;
  kind: DiagnosticTest["kind"];
  ready: boolean;
  note: string;
  optional: boolean;
  verilatorTarget?: string;
}[] {
  return ctx.config.diagnostics.tests.map((t) => {
    if (t.kind === "path-check") {
      const missing = (t.paths ?? []).filter((p) => !existsSync(join(ctx.repoRoot, p)));
      return {
        id: t.id,
        compartment: t.compartment,
        kind: t.kind,
        ready: missing.length === 0,
        note: missing.length ? `missing ${missing[0]}` : "paths present",
        optional: Boolean(t.optional),
      };
    }
    if (t.kind === "source-scan") {
      // No tool required: the scan is pure file reading, so it is always ready.
      const roots = t.sourceScan?.roots ?? [];
      const missing = roots.filter((p) => !existsSync(join(ctx.repoRoot, p)));
      return {
        id: t.id,
        compartment: t.compartment,
        kind: t.kind,
        ready: missing.length === 0,
        note: missing.length
          ? `missing root ${missing[0]}`
          : `${t.sourceScan?.forbid.length ?? 0} forbidden pattern(s) over ${roots.length} root(s)`,
        optional: Boolean(t.optional),
      };
    }
    if (t.kind === "verilator-lint" || t.kind === "verilator-elab") {
      const paths = edaPaths(ctx);
      const hasVl = existsSync(paths.verilator);
      return {
        id: t.id,
        compartment: t.compartment,
        kind: t.kind,
        ready: hasVl,
        note: hasVl
          ? `verilator ready → target ${t.verilator?.target ?? "?"}`
          : "verilator missing (OSS CAD under verify.suite.root)",
        optional: Boolean(t.optional),
        verilatorTarget: t.verilator?.target,
      };
    }
    if (t.kind === "probe-cap" && probeReport) {
      const missing = (t.probeCaps ?? []).filter((c) => !capSatisfied(c, probeReport, ctx));
      return {
        id: t.id,
        compartment: t.compartment,
        kind: t.kind,
        ready: missing.length === 0,
        note: missing.length ? `need ${missing.join(",")}` : "caps present",
        optional: Boolean(t.optional),
      };
    }
    return {
      id: t.id,
      compartment: t.compartment,
      kind: t.kind,
      ready: true,
      note: "run diag to evaluate",
      optional: Boolean(t.optional),
    };
  });
}
