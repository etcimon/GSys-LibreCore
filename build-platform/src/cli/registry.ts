// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// registry.ts — The canonical list of CLI commands.
//
// Adding a command = importing it here and appending to COMMANDS. The help
// renderer and dispatcher both read from this single source, so a new command
// is discovered everywhere automatically (file-discovery / minimal-wiring goal).

import type { Command } from "./command.ts";
import { buildCommand } from "./commands/build.ts";
import { cleanCommand } from "./commands/clean.ts";
import { configCommand } from "./commands/config.ts";
import { diagCommand } from "./commands/diag.ts";
import { doctorCommand } from "./commands/doctor.ts";
import { manCommand } from "./commands/man.ts";
import { mbCommand } from "./commands/mb.ts";
import { probeCommand } from "./commands/probe.ts";
import { setupCommand } from "./commands/setup.ts";
import { statusCommand } from "./commands/status.ts";
import { technologyCommand } from "./commands/technology.ts";
import { testCommand } from "./commands/test.ts";
import { tensorCommand } from "./commands/tensor.ts";
import { timingsCommand } from "./commands/timings.ts";
import { toolsCommand } from "./commands/tools.ts";
import { vendorCommand } from "./commands/vendor.ts";
import { verifyCommand } from "./commands/verify.ts";

export const COMMANDS: Command[] = [
  statusCommand,
  doctorCommand,
  probeCommand,
  diagCommand,
  manCommand,
  setupCommand,
  toolsCommand,
  vendorCommand,
  mbCommand,
  technologyCommand,
  buildCommand,
  testCommand,
  verifyCommand,
  timingsCommand,
  tensorCommand,
  cleanCommand,
  configCommand,
];

export function findCommand(name: string): Command | undefined {
  return COMMANDS.find((c) => c.name === name);
}
