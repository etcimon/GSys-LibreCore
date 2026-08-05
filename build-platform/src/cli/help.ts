// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// help.ts — Render general and per-command help text.

import type { Command } from "./command.ts";

const GLOBAL_FLAGS: [string, string][] = [
  ["-h, --help", "Show help (global, or for a specific command)."],
  ["-n, --dry-run", "Print actions without executing side effects."],
  ["-v, --verbose", "Increase log verbosity (debug)."],
  ["-q, --quiet", "Decrease log verbosity (errors only)."],
  ["--log-level <lvl>", "Set level: silent|error|warn|info|debug|trace."],
  ["--config <path>", "Use an explicit .config.ts instead of the repo-root one."],
  ["--json", "Emit machine-readable JSON where supported."],
];

export interface CliInfo {
  name: string;
  version: string;
}

export function renderGeneralHelp(commands: Command[], info: CliInfo): string {
  const lines: string[] = [];
  lines.push(`${info.name} v${info.version}`);
  lines.push("Cross-platform Bun build platform for GSys LibreCore (RISC-V SystemVerilog).");
  lines.push("");
  lines.push("USAGE");
  lines.push("  bun run src/cli/index.ts <command> [options]");
  lines.push("  bun run start <command> [options]");
  lines.push("");
  lines.push("COMMANDS");
  const width = Math.max(...commands.map((c) => c.name.length));
  for (const c of commands) {
    lines.push(`  ${c.name.padEnd(width)}  ${c.summary}`);
  }
  lines.push("");
  lines.push("GLOBAL OPTIONS");
  const fw = Math.max(...GLOBAL_FLAGS.map(([f]) => f.length));
  for (const [flag, desc] of GLOBAL_FLAGS) {
    lines.push(`  ${flag.padEnd(fw)}  ${desc}`);
  }
  lines.push("");
  lines.push("EXAMPLES");
  lines.push("  bun run src/cli/index.ts doctor                 # check host readiness");
  lines.push("  bun run src/cli/index.ts probe                  # in-depth capability boxes");
  lines.push("  bun run src/cli/index.ts probe diag             # diagnostic compartments readiness");
  lines.push("  bun run src/cli/index.ts diag run core          # run core Verilator diagnostics");
  lines.push("  bun run src/cli/index.ts man \"How does probe work?\"  # human man page (browser)");
  lines.push("  bun run src/cli/index.ts probe install          # how to provision missing pieces");
  lines.push("  bun run src/cli/index.ts setup                  # workspace + submodules + toolchain plan");
  lines.push("  bun run src/cli/index.ts tools install dual-hart  # RISC-V GCC + OpenSBI SMT2 fw_payload");
  lines.push("  bun run src/cli/index.ts setup --install --profile sim");
  lines.push("  bun run src/cli/index.ts build --iss verilator  # verilate the configured target");
  lines.push("  bun run src/cli/index.ts test --list            # discover regression suites");
  lines.push("  bun run src/cli/index.ts test --open-source     # run all OSS-runnable suites");
  lines.push("  bun run src/cli/index.ts config --json          # dump the resolved configuration");
  lines.push("");
  lines.push("Config: edit the repo-root .config.ts (single control surface).");
  lines.push("Docs:   build-platform/AGENTS.md and build-platform/README.md.");
  return lines.join("\n") + "\n";
}

export function renderCommandHelp(cmd: Command): string {
  const lines: string[] = [];
  lines.push(`${cmd.name} — ${cmd.summary}`);
  lines.push("");
  lines.push("USAGE");
  lines.push(`  ${cmd.usage}`);
  if (cmd.details) {
    lines.push("");
    lines.push("DETAILS");
    for (const line of cmd.details.split("\n")) lines.push(`  ${line}`);
  }
  if (cmd.examples && cmd.examples.length > 0) {
    lines.push("");
    lines.push("EXAMPLES");
    for (const ex of cmd.examples) lines.push(`  ${ex}`);
  }
  return lines.join("\n") + "\n";
}
