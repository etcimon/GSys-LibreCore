// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// command.ts — Command contract shared by the CLI dispatcher and each command.

import type { PlatformContext } from "../context.ts";
import type { Logger } from "../util/log.ts";
import type { FlagValue } from "./args.ts";

export interface CommandArgs {
  /** Resolved context; non-null iff the command declares needsContext. */
  ctx: PlatformContext | null;
  positionals: string[];
  flags: Record<string, FlagValue>;
  logger: Logger;
}

export interface Command {
  name: string;
  summary: string;
  usage: string;
  /** Longer help shown by `<cmd> --help`. */
  details?: string;
  /** Example invocations for help output. */
  examples?: string[];
  /** When true, the dispatcher loads + validates config before running. */
  needsContext: boolean;
  run(args: CommandArgs): Promise<number>;
}

/** Assert a context is present (for needsContext commands). */
export function requireContext(args: CommandArgs): PlatformContext {
  if (!args.ctx) {
    throw new Error("Internal error: command requires a context but none was created.");
  }
  return args.ctx;
}
