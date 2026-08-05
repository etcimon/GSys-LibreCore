// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// labReport.ts — Aggregate timings lab-run / sta-handoff into a single report
// artifact for CI and human review (structural FO4 — not STA).

import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import type { Fo4GoldenCheckResult } from "./fo4Golden.ts";
import type { StaHandoffResult } from "./staHandoff.ts";
import {
  formatTimingsDashboardLines,
  type TimingsSoakDashboard,
} from "./timings.ts";
import { posixPath } from "./eda.ts";

export interface LabReportInput {
  packageDir: string;
  handoffDir: string;
  golden: Fo4GoldenCheckResult;
  handoff: StaHandoffResult;
  dashboard?: TimingsSoakDashboard;
  hostNote?: string;
}

export interface LabReport {
  schema: "cva6-timings-lab-report.v0";
  generatedAt: string;
  disclaimer: string;
  packageDir: string;
  handoffDir: string;
  golden: Fo4GoldenCheckResult;
  stages: StaHandoffResult["stages"];
  files: {
    seedsSdc?: string;
    fo4Csv?: string;
    correlate?: string;
    netlist?: string;
    openstaReport?: string | null;
    soakDashboard?: string;
  };
  dashboard?: TimingsSoakDashboard;
  hostNote?: string;
  ok: boolean;
}

export function buildLabReport(input: LabReportInput): LabReport {
  const files: LabReport["files"] = {
    seedsSdc: input.handoff.seedsSdc || undefined,
    fo4Csv: input.handoff.fo4Csv || undefined,
    correlate: input.handoff.correlate || undefined,
    netlist: input.handoff.netlist,
    openstaReport: input.handoff.stages.some((s) => s.id === "s2-opensta" && s.status === "pass")
      ? posixPath(join(input.handoffDir, "opensta", "paths.rpt"))
      : null,
    soakDashboard: existsSync(join(input.handoffDir, "soak-dashboard.json"))
      ? posixPath(join(input.handoffDir, "soak-dashboard.json"))
      : undefined,
  };
  return {
    schema: "cva6-timings-lab-report.v0",
    generatedAt: new Date().toISOString(),
    disclaimer: "structural FO4 estimates only — not STA sign-off",
    packageDir: posixPath(input.packageDir),
    handoffDir: posixPath(input.handoffDir),
    golden: input.golden,
    stages: input.handoff.stages,
    files,
    dashboard: input.dashboard ?? input.handoff.dashboard,
    hostNote: input.hostNote,
    ok: input.golden.ok && input.handoff.ok,
  };
}

export function formatLabReportMarkdown(r: LabReport): string {
  const lines: string[] = [
    "# Timings lab report",
    "",
    `> ${r.disclaimer}`,
    "",
    `- **Generated:** ${r.generatedAt}`,
    `- **OK:** ${r.ok ? "yes" : "no"}`,
    `- **Package:** \`${r.packageDir}\``,
    `- **Handoff:** \`${r.handoffDir}\``,
    "",
    "## FO4 golden",
    "",
    `- Compared paths: ${r.golden.compared}`,
    `- Tolerance: ${r.golden.tolerance}`,
    `- Result: ${r.golden.ok ? "MATCH" : "MISMATCH"}`,
    "",
  ];
  if (r.golden.mismatches.length) {
    lines.push("### Mismatches", "");
    for (const m of r.golden.mismatches) {
      lines.push(`- **${m.kind}:** ${m.detail}`);
    }
    lines.push("");
  }
  lines.push("## Stages", "");
  for (const s of r.stages) {
    lines.push(`- \`${s.status}\` **${s.id}** — ${s.detail}`);
  }
  lines.push("", "## Artifacts", "");
  for (const [k, v] of Object.entries(r.files)) {
    if (v) lines.push(`- **${k}:** \`${v}\``);
  }
  if (r.dashboard) {
    lines.push("", "## Soak dashboard", "", "```");
    lines.push(...formatTimingsDashboardLines(r.dashboard));
    lines.push("```", "");
  }
  if (r.hostNote) {
    lines.push("## Notes", "", r.hostNote, "");
  }
  lines.push(
    "---",
    "",
    "Plan: `architecture/build-platform-opensta-from-timing.md`",
    "",
  );
  return lines.join("\n");
}

/** Write lab-report.json + lab-report.md under handoffDir. */
export function writeLabReport(
  handoffDir: string,
  input: LabReportInput,
): { json: string; md: string; report: LabReport } {
  mkdirSync(handoffDir, { recursive: true });
  const report = buildLabReport(input);
  const json = join(handoffDir, "lab-report.json");
  const md = join(handoffDir, "lab-report.md");
  writeFileSync(json, JSON.stringify(report, null, 2) + "\n", "utf8");
  writeFileSync(md, formatLabReportMarkdown(report), "utf8");
  return { json: posixPath(json), md: posixPath(md), report };
}
