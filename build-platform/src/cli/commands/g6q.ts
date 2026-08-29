// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// g6q.ts — Build-platform gateway to the g6lc_qemu package.
//
// Delegates to the standalone `g6lc_qemu` package CLI so the build-platform
// gets a single top-level command surface for QEMU argument generation,
// native VM execution, tandem diagnosis, and the remote build/test proxy.
//
// With `--remote`, the gateway targets `tools/g6q_remote.py` instead of
// `tools/g6q.py` (e.g. `bun run src/cli/index.ts g6q --remote remote-build`).

import { join } from "node:path";

import { requireContext, type Command } from "../command.ts";
import { flagBool } from "../args.ts";
import { run, which } from "../../platform/exec.ts";

export const g6qCommand: Command = {
  name: "g6q",
  summary: "Gateway to the g6lc_qemu package CLI.",
  usage:
    "bun run src/cli/index.ts g6q [--remote] <subcommand> [args...]",
  details:
    "Thin pass-through to g6lc_qemu/tools/g6q.py. " +
    "Use --remote to call g6lc_qemu/tools/g6q_remote.py instead.",
  examples: [
    "bun run src/cli/index.ts g6q doctor",
    "bun run src/cli/index.ts g6q setup-host --all --dry-run",
    "bun run src/cli/index.ts g6q gen --package config/packages/g6lc64 --emit qemu",
    "bun run src/cli/index.ts g6q --remote remote-build",
    "bun run src/cli/index.ts g6q --remote doctor --dry-run",
  ],
  needsContext: true,
  async run(args) {
    const ctx = requireContext(args);
    const repoRoot = ctx.repoRoot;

    if (flagBool(args.flags, "help")) {
      args.logger.raw(
        `g6q — gateway to g6lc_qemu\n\n` +
          `Usage: ${g6qCommand.usage}\n\n` +
          `${g6qCommand.details}\n\n` +
          `Examples:\n` +
          g6qCommand.examples!.map((e) => `  ${e}`).join("\n") +
          "\n",
      );
      return 0;
    }

    const isRemote = flagBool(args.flags, "remote");
    const scriptName = isRemote ? "g6q_remote.py" : "g6q.py";
    const scriptPath = join(
      repoRoot,
      "g6lc_qemu",
      "tools",
      scriptName,
    );

    const python = which("python") || which("python3") || which("py");
    if (!python) {
      args.logger.error(
        "No Python interpreter found on PATH. " +
          "Install python and re-run.",
      );
      return 1;
    }

    // Reconstruct the child argv from the raw process.argv so that every
    // package-level flag and positional survives unchanged. Drop the leading
    // `g6q` command and the internal `--remote` flag (the target script is
    // chosen by the gateway, not passed through).
    const raw = process.argv.slice(2);
    const childArgs = raw
      .slice(1)
      .filter((t) => t !== "--remote" && !t.startsWith("--remote="));

    args.logger.info(
      `g6q: ${isRemote ? "remote" : "local"} -> ${scriptPath} ${childArgs.join(" ")}`,
    );

    const result = await run(
      python,
      [scriptPath, ...childArgs],
      { cwd: join(repoRoot, "g6lc_qemu"), stdio: "both", allowFailure: true },
    );
    return result.code;
  },
};
