#!/usr/bin/env bun
// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// index.ts — CLI entrypoint and dispatcher.
//
// Parses argv, handles help/version, creates the platform context for commands
// that need it (loading + validating .config.ts), and dispatches. All commands
// are discovered from registry.ts.

import pkg from "../../package.json";
import { ConfigError } from "../config/load.ts";
import { createContext } from "../context.ts";
import type { LogLevel } from "../util/log.ts";
import { Logger } from "../util/log.ts";
import { flagBool, flagString, parseArgs } from "./args.ts";
import type { Command } from "./command.ts";
import { renderCommandHelp, renderGeneralHelp } from "./help.ts";
import { COMMANDS, findCommand } from "./registry.ts";

const CLI_INFO = { name: pkg.name ?? "@cva6/build-platform", version: pkg.version ?? "0.0.0" };

function pickLogLevel(flags: Record<string, string | boolean>): LogLevel | undefined {
  const explicit = flagString(flags, "log-level");
  if (explicit) return explicit as LogLevel;
  if (flagBool(flags, "verbose")) return "debug";
  if (flagBool(flags, "quiet")) return "error";
  return undefined;
}

async function main(): Promise<number> {
  const { command, positionals, flags } = parseArgs(process.argv.slice(2));
  const bootLogger = new Logger();

  // Version.
  if (flagBool(flags, "version") || command === "version") {
    bootLogger.raw(`${CLI_INFO.name} v${CLI_INFO.version}\n`);
    return 0;
  }

  // General help / `help [command]`.
  if (!command || command === "help") {
    const topic = positionals[0] ? findCommand(positionals[0]) : undefined;
    bootLogger.raw(topic ? renderCommandHelp(topic) : renderGeneralHelp(COMMANDS, CLI_INFO));
    return 0;
  }

  const cmd: Command | undefined = findCommand(command);
  if (!cmd) {
    bootLogger.error(`Unknown command '${command}'.`);
    bootLogger.raw(renderGeneralHelp(COMMANDS, CLI_INFO));
    return 1;
  }

  // Per-command help.
  if (flagBool(flags, "help")) {
    bootLogger.raw(renderCommandHelp(cmd));
    return 0;
  }

  // Build context for commands that need it.
  let ctx = null;
  if (cmd.needsContext) {
    try {
      ctx = await createContext({
        configPath: flagString(flags, "config"),
        dryRun: flagBool(flags, "dry-run"),
        logLevel: pickLogLevel(flags),
        ensureWorkspaceDirs: false,
      });
    } catch (err) {
      if (err instanceof ConfigError) {
        bootLogger.error(err.message);
        for (const issue of err.issues) bootLogger.error(`  - ${issue}`);
        bootLogger.info("Fix the repo-root .config.ts and retry.");
        return 1;
      }
      throw err;
    }
  }

  const logger = ctx?.logger ?? bootLogger;
  try {
    return await cmd.run({ ctx, positionals, flags, logger });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    logger.error(message);
    if (flagBool(flags, "verbose") && err instanceof Error && err.stack) {
      logger.raw(err.stack + "\n");
    }
    return 1;
  }
}

main()
  .then((code) => {
    process.exitCode = code;
  })
  .catch((err) => {
    // Last-resort handler; individual commands handle their own errors.
    console.error(err);
    process.exitCode = 1;
  });
