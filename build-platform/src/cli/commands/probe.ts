// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// probe.ts — In-depth cross-platform capability probe (categorical boxes).
//
//   probe                 full report (all categories as boxes + tab strip)
//   probe host|platform|pkg|utils|tools|env|commands|install
//   probe list            list categories / tabs
//   probe --json          machine-readable full report
//   probe --deep          full package-manager PREREQS scan
//
// Complements `doctor` (quick PATH readiness) and `status` (config snapshot).
// Never installs; `probe install` prints the install playbook for missing caps.

import { requireContext, type Command } from "../command.ts";
import { flagBool } from "../args.ts";
import {
  gatherProbeReport,
  PROBE_CATEGORIES,
  resolveProbeCategory,
  type ProbeCategoryId,
  type ProbeReport,
} from "../../tooling/probe.ts";
import { renderBox, renderTabStrip, statusValue, type BoxRow } from "../../util/box.ts";
import type { Logger } from "../../util/log.ts";

function colorOn(_logger: Logger, flags: Record<string, string | boolean>): boolean {
  if (flagBool(flags, "no-color")) return false;
  return !process.env.NO_COLOR;
}

function printBox(logger: Logger, title: string, rows: BoxRow[], tabId: string, color: boolean): void {
  logger.raw(renderBox(rows, { title, tabId, color, width: 76 }) + "\n");
}

function renderHost(report: ProbeReport, color: boolean, logger: Logger): void {
  const h = report.host;
  const rows: BoxRow[] = [
    { label: "OS", value: `${h.os} / ${h.arch}`, tone: "ok" },
    { label: "CPUs", value: String(h.cpuCount), tone: "plain" },
    { label: "Shell", value: h.defaultShell, tone: "plain" },
    { label: "Home", value: h.home, tone: "dim" },
    { label: "exeSuffix", value: h.exeSuffix || '""', tone: "dim" },
    { label: "PATH sep", value: JSON.stringify(h.pathSep), tone: "dim" },
    {
      label: "Runtime",
      value: h.nodeLike + (h.bunVersion ? `  (bun ${h.bunVersion})` : ""),
      tone: h.bunVersion ? "ok" : "warn",
    },
    {
      label: "WSL",
      value: h.wsl ? "on PATH" : h.os === "windows" ? "not found (Spike/R3 need WSL)" : "n/a (native Unix)",
      tone: h.os === "windows" ? (h.wsl ? "ok" : "warn") : "dim",
    },
    {
      label: "Cygwin",
      value: h.cygwinHint ? "detected (OpenSBI Windows path; Spike unsupported)" : "not detected",
      tone: h.cygwinHint ? "warn" : "dim",
    },
  ];
  printBox(logger, "Host OS & runtime", rows, "host", color);
}

function renderPlatform(report: ProbeReport, color: boolean, logger: Logger): void {
  const p = report.platform;
  const rows: BoxRow[] = [
    { label: "Package", value: `${p.name} v${p.version}`, tone: "ok" },
    { label: "Repo", value: p.repoRoot, tone: "dim" },
    {
      label: "Config",
      value: p.configPath ?? "(defaults only)",
      tone: p.configPath ? "ok" : "warn",
    },
    {
      label: "Overlay",
      value: p.overlayPath ?? "(none)",
      tone: p.overlayPath ? "ok" : "dim",
    },
    {
      label: "Workspace",
      value: `${p.workspaceRoot} ${p.workspaceExists ? "(exists)" : "(missing — run setup)"}`,
      tone: p.workspaceExists ? "ok" : "warn",
    },
    { label: "Core cfg", value: `${p.coreConfig} (RV${p.xlen})`, tone: "ok" },
    { label: "Frequency", value: `${p.frequencyMHz} MHz`, tone: "plain" },
    { label: "Process", value: p.process, tone: "plain" },
    { label: "Default sim", value: p.defaultSim, tone: "plain" },
    { label: "Generated", value: report.generatedAt, tone: "dim" },
  ];
  printBox(logger, "Build platform", rows, "platform", color);
}

function renderPkg(report: ProbeReport, color: boolean, logger: Logger): void {
  const rows: BoxRow[] = [
    {
      label: "Active",
      value: report.activePackageManager ?? "none detected",
      tone: report.activePackageManager ? "ok" : "warn",
    },
  ];
  for (const p of report.packageManagers) {
    if (p.found) {
      const prereq =
        p.prereqsKnown > 0
          ? `  prereqs ~${p.prereqsPresent}/${p.prereqsKnown}` +
            (p.prereqMissing.length ? `  miss: ${p.prereqMissing.slice(0, 4).join(",")}` : "")
          : "";
      rows.push({
        label: p.id,
        value: `${p.version ?? "present"}${prereq}`,
        tone: "ok",
      });
    } else {
      rows.push({
        label: p.id,
        value: p.hint ? `not found — ${p.hint}` : "not found",
        tone: "dim",
      });
    }
  }
  printBox(logger, "Package managers (choco / brew / apt / dnf / …)", rows, "pkg", color);
}

function renderUtils(report: ProbeReport, color: boolean, logger: Logger): void {
  const critical = new Set(["git", "bash", "make", "g++", "python3", "python", "dtc", "bun", "wsl"]);
  const rows: BoxRow[] = [];
  for (const u of report.utils) {
    const sv = statusValue(u.found, u.version, u.found ? u.path ?? undefined : u.hint);
    // Downgrade non-critical misses to dim
    if (!u.found && !critical.has(u.id)) {
      rows.push({ label: u.id, value: sv.value, tone: "dim" });
    } else {
      rows.push({ label: u.id, value: sv.value, tone: sv.tone });
    }
  }
  printBox(logger, "Host utils / compilers / libs (PATH)", rows, "utils", color);
}

function renderTools(report: ProbeReport, color: boolean, logger: Logger): void {
  const rows: BoxRow[] = [];
  for (const t of report.managedTools) {
    if (t.installed) {
      rows.push({
        label: t.id,
        value: `installed  pin=${t.pin}${t.versionHint ? `  | ${t.versionHint}` : ""}`,
        tone: "ok",
      });
      rows.push({ label: "", value: t.path, tone: "dim" });
    } else {
      rows.push({
        label: t.id,
        value: `missing  pin=${t.pin}  → ${t.installHint}`,
        tone: "miss",
      });
    }
  }
  rows.push({ label: "Profiles", value: report.installProfiles.map((p) => p.id).join(", "), tone: "plain" });
  printBox(logger, "Managed tooling (workspace/tooling)", rows, "tools", color);
}

function renderEnv(report: ProbeReport, color: boolean, logger: Logger): void {
  const rows: BoxRow[] = [];
  rows.push({
    value: report.deep ? "deep pkg scan: on" : "deep pkg scan: off (pass --deep)",
    tone: "dim",
  });
  for (const e of report.envVars) {
    if (e.name === "PATH" && e.value) {
      // Use OS path separator only — never split on ':' (Windows drive letters).
      const sep = report.host.pathSep;
      const parts = e.value.split(sep).filter(Boolean);
      const head = parts.slice(0, 3).join(sep + " ");
      rows.push({
        label: "PATH",
        value: `${parts.length} entries; head: ${head}${parts.length > 3 ? "…" : ""}`,
        tone: "plain",
      });
      continue;
    }
    rows.push({
      label: e.name.length > 14 ? e.name.slice(0, 12) + "…" : e.name,
      value: e.value ? e.value.slice(0, 48) + (e.value.length > 48 ? "…" : "") : `(unset)  ${e.role}`,
      tone: e.value ? "ok" : "dim",
    });
  }
  rows.push({ value: "── residual tool roots ──", tone: "dim" });
  for (const r of report.residualRoots) {
    rows.push({
      label: r.id.slice(0, 14),
      value: r.present
        ? (r.detail ?? r.path).slice(0, 55)
        : `missing  ${r.path}`,
      tone: r.present ? "ok" : "dim",
    });
  }
  printBox(logger, "Environment + residual roots", rows, "env", color);
}

function renderCommands(report: ProbeReport, color: boolean, logger: Logger): void {
  const rows: BoxRow[] = [];
  for (const c of report.commands) {
    const tone = c.status === "ok" ? "ok" : c.status === "partial" ? "warn" : "miss";
    let detail = c.status;
    if (c.missingRequired.length) detail += `  need: ${c.missingRequired.join(",")}`;
    if (c.missingOptional.length) detail += `  opt: ${c.missingOptional.join(",")}`;
    // Prefer full command on its own row when long
    if (c.command.length > 18) {
      rows.push({ value: c.command, tone });
      rows.push({ label: "", value: `${detail}  — ${c.summary}`, tone });
    } else {
      rows.push({ label: c.command, value: `${detail}  — ${c.summary}`, tone });
    }
    if (c.status !== "ok") {
      rows.push({ label: "", value: `fix: ${c.install}`, tone: "dim" });
    }
  }
  printBox(logger, "Command capability matrix", rows, "commands", color);
}

function renderInstall(report: ProbeReport, color: boolean, logger: Logger): void {
  const rows: BoxRow[] = [];
  if (report.installActions.length === 0) {
    rows.push({ value: "Nothing obvious missing — re-run probe after changing PATH.", tone: "ok" });
  }
  for (const a of report.installActions) {
    rows.push({ value: a.title, tone: a.covers.length ? "warn" : "plain" });
    if (a.note) rows.push({ value: a.note, tone: "dim" });
    for (const cmd of a.commands) {
      rows.push({ value: `$ ${cmd}`, tone: "plain" });
    }
    rows.push({ value: "─".repeat(40), tone: "dim" });
  }
  printBox(logger, "Install help (missing → provision)", rows, "install", color);
}

function renderCategory(
  id: ProbeCategoryId,
  report: ProbeReport,
  color: boolean,
  logger: Logger,
): void {
  switch (id) {
    case "host":
      renderHost(report, color, logger);
      break;
    case "platform":
      renderPlatform(report, color, logger);
      break;
    case "pkg":
      renderPkg(report, color, logger);
      break;
    case "utils":
      renderUtils(report, color, logger);
      break;
    case "tools":
      renderTools(report, color, logger);
      break;
    case "env":
      renderEnv(report, color, logger);
      break;
    case "diag":
      renderDiag(report, color, logger);
      break;
    case "commands":
      renderCommands(report, color, logger);
      break;
    case "install":
      renderInstall(report, color, logger);
      break;
  }
}

function renderDiag(report: ProbeReport, color: boolean, logger: Logger): void {
  const rows: BoxRow[] = [
    {
      value: "Per-test Verilator configs live in config.diagnostics — run: diag run",
      tone: "dim",
    },
  ];
  const byComp = new Map<string, typeof report.diagnostics>();
  for (const d of report.diagnostics) {
    const list = byComp.get(d.compartment) ?? [];
    list.push(d);
    byComp.set(d.compartment, list);
  }
  for (const [comp, list] of byComp) {
    rows.push({ value: `── ${comp} ──`, tone: "dim" });
    for (const d of list) {
      const vl = d.verilatorTarget ? `  cfg=${d.verilatorTarget}` : "";
      rows.push({
        label: d.id.slice(0, 14),
        value: `${d.ready ? "ready" : "not ready"}  ${d.kind}  ${d.note}${vl}${d.optional ? " (opt)" : ""}`,
        tone: d.ready ? "ok" : d.optional ? "dim" : "warn",
      });
    }
  }
  rows.push({
    value: "$ bun run src/cli/index.ts diag list | diag status | diag run [core|smt2|…]",
    tone: "plain",
  });
  printBox(logger, "Compartmentalized diagnostics", rows, "diag", color);
}

export const probeCommand: Command = {
  name: "probe",
  summary:
    "In-depth platform capability probe: host, pkg managers, utils, managed tools, command matrix.",
  usage:
    "bun run src/cli/index.ts probe [all|host|platform|pkg|utils|tools|env|commands|install|list] [--json] [--deep] [--no-color]",
  details:
    "Cross-platform capability report rendered as categorical boxes (tab strip).\n" +
    "\n" +
    "  probe                 full report (all categories)\n" +
    "  probe host            OS, arch, shell, Bun, WSL, Cygwin\n" +
    "  probe platform        build-platform version, config, workspace, SoC\n" +
    "  probe pkg             choco / brew / apt / dnf / winget / scoop + prereq sample\n" +
    "  probe utils           make, cmake, g++, dtc, flex, bison, python, verilator, …\n" +
    "  probe tools           managed workspace/tooling install state + pins\n" +
    "  probe env             child env vars + residual WSL/oss-cad tool roots\n" +
    "  probe diag            compartmentalized diagnostics readiness (Verilator per-test)\n" +
    "  probe commands        CLI command → required/optional capability matrix\n" +
    "  probe install         install playbook for missing pieces (does not install)\n" +
    "  probe list            list categories / tabs\n" +
    "  --deep                full PREREQS package scan per manager (slower)\n" +
    "\n" +
    "Related:\n" +
    "  doctor   quick PATH readiness verdict\n" +
    "  diag     run compartmentalized diagnostics (own Verilator configs)\n" +
    "  status   SoC + provisioning snapshot (no PATH probes)\n" +
    "  tools    list/install managed recipes (sim | dual-hart | spike | all)\n" +
    "\n" +
    "Install hints always point at the right tools install / setup / OS package\n" +
    "manager commands for this host.",
  examples: [
    "bun run src/cli/index.ts probe",
    "bun run src/cli/index.ts probe tools",
    "bun run src/cli/index.ts probe env",
    "bun run src/cli/index.ts probe pkg --deep",
    "bun run src/cli/index.ts probe commands",
    "bun run src/cli/index.ts probe install",
    "bun run src/cli/index.ts probe --json",
    "./build.sh probe utils",
    ".\\build.ps1 probe",
  ],
  needsContext: true,
  async run(args) {
    const ctx = requireContext(args);
    const { logger } = ctx;
    const sub = (args.positionals[0] ?? "all").toLowerCase();
    const color = colorOn(logger, args.flags);
    const asJson = flagBool(args.flags, "json");
    const deep = flagBool(args.flags, "deep");

    if (sub === "list" || sub === "tabs") {
      logger.heading("Probe categories (tabs)");
      for (const c of PROBE_CATEGORIES) {
        logger.info(`  ${c.id.padEnd(12)} ${c.label.padEnd(14)} ${c.summary}`);
      }
      logger.info("");
      logger.info("Usage: probe [<category>] [--deep]   probe install   probe --json");
      return 0;
    }

    logger.info(
      deep
        ? "Probing host / platform / tooling (read-only, deep prereq scan)…"
        : "Probing host / platform / tooling (read-only)…",
    );
    const report = await gatherProbeReport(ctx, { deep });

    if (asJson) {
      logger.raw(JSON.stringify(report, null, 2) + "\n");
      return 0;
    }

    const activeId =
      sub === "all" || sub === ""
        ? null
        : (resolveProbeCategory(sub)?.id ?? null);

    if (sub !== "all" && sub !== "" && !activeId) {
      logger.error(`Unknown probe category "${sub}".`);
      logger.info(`Known: all, list, ${PROBE_CATEGORIES.map((c) => c.id).join(", ")}`);
      return 1;
    }

    const tabs = PROBE_CATEGORIES.map((c) => ({
      id: c.id,
      label: c.label,
      active: activeId === c.id,
      missing: report.missingByCategory[c.id] || undefined,
    }));
    logger.raw("\n" + renderTabStrip(tabs, { color }) + "\n\n");

    if (!activeId) {
      for (const c of PROBE_CATEGORIES) {
        renderCategory(c.id, report, color, logger);
        logger.raw("\n");
      }
    } else {
      renderCategory(activeId, report, color, logger);
      logger.raw("\n");
    }

    // Footer verdict
    const blocked = report.commands.filter((c) => c.status === "blocked").length;
    const partial = report.commands.filter((c) => c.status === "partial").length;
    const toolsMiss = report.managedTools.filter((t) => !t.installed).length;
    logger.heading("Verdict");
    if (blocked === 0 && toolsMiss === 0) {
      logger.success(
        `Ready: no blocked commands; managed tools complete (${report.managedTools.length}).`,
      );
    } else if (blocked === 0) {
      logger.warn(
        `Partial: ${toolsMiss} managed tool(s) missing, ${partial} command(s) partial. See probe install.`,
      );
    } else {
      logger.error(
        `Blocked: ${blocked} command(s) missing required caps; ${toolsMiss} managed tool(s) missing.`,
      );
      logger.info("Next: bun run src/cli/index.ts probe install");
    }
    logger.info(
      "Quick links: tools install | setup --install --profile sim|dual-hart|all | doctor",
    );
    return blocked > 0 ? 1 : 0;
  },
};
