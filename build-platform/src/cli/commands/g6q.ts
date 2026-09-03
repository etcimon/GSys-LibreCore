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
import { flagBool, flagString } from "../args.ts";
import { run, which } from "../../platform/exec.ts";
import { applyFromTimingFlags } from "../../tooling/timings.ts";
import {
  applyAiEnv,
  formatAiResolvedLine,
  injectG6qAiTarget,
  parseAiFlagErrors,
  parseAiFlags,
  resolveAiTesting,
  stripGatewayFlags,
} from "../../tooling/aiTesting.ts";

export const g6qCommand: Command = {
  name: "g6q",
  summary: "Gateway to the g6lc_qemu package CLI.",
  usage:
    "bun run src/cli/index.ts g6q [--remote] [--ai] [--from-timing DIR] <subcommand> [args...]",
  details:
    "Thin pass-through to g6lc_qemu/tools/g6q.py. " +
    "Use --remote to call g6lc_qemu/tools/g6q_remote.py instead.\n" +
    "\n" +
    "Higher-level Linux / tensor emulation (NOT Variane evidence):\n" +
    "  --ai                 default g6lc64_ai target on gen/conform/run/diag/dts;\n" +
    "                       `g6q --ai` with no verb runs doctor.\n" +
    "  --from-timing DIR    validate FO4 package (same as test/diag) then export env.\n" +
    "  --channels / --ai-dram / --ai-ghz / --ai-clusters\n" +
    "                       stamp AI_ISLAND_* env for ingest/bridge (I2 clusters>1 not live).\n" +
    "Directed RTL remains `test --ai` / `test --ai-remote` / `tensor --rtl-hard`.",
  examples: [
    "bun run src/cli/index.ts g6q doctor",
    "bun run src/cli/index.ts g6q --ai",
    "bun run src/cli/index.ts g6q --ai run -- gen --emit qemu",
    "bun run src/cli/index.ts g6q --ai --from-timing workspace/build/sv-timing/host-cv64a6_imafdc_sv39 doctor",
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

    const aiFlagErrors = parseAiFlagErrors(args.flags as Record<string, string | boolean>);
    if (aiFlagErrors.length) {
      for (const e of aiFlagErrors) args.logger.error(e);
      return 2;
    }
    const aiKnobs = parseAiFlags(args.flags as Record<string, string | boolean>);
    const ai = resolveAiTesting(aiKnobs);
    if (ai.errors.length) {
      for (const e of ai.errors) args.logger.error(e);
      return 2;
    }
    if (ai.active) {
      applyAiEnv(ai);
      args.logger.info(formatAiResolvedLine(ai));
      args.logger.warn(
        "g6lc_qemu is higher-level Linux/emulation — not Variane evidence.",
      );
      for (const w of ai.warnings) args.logger.warn(w);
    }

    const fromTiming = flagString(args.flags, "from-timing");
    if (fromTiming) {
      const ft = applyFromTimingFlags(ctx, {
        fromTiming,
        useEmit: flagBool(args.flags, "use-emit"),
        requireEmit: flagBool(args.flags, "require-emit"),
      });
      if (!ft.ok) {
        args.logger.error(`--from-timing structure invalid: ${ft.dir ?? fromTiming}`);
        return 1;
      }
      args.logger.success(`--from-timing OK: ${ft.dir}`);
      Object.assign(process.env, ft.env);
    }

    // Reconstruct the child argv from the raw process.argv so that every
    // package-level flag and positional survives unchanged. Drop the leading
    // `g6q` command and the internal `--remote` / `--ai*` gateway flags.
    const raw = process.argv.slice(2);
    let childArgs = stripGatewayFlags(
      raw
        .slice(1)
        .filter((t) => t !== "--remote" && !t.startsWith("--remote=")),
    );
    if (aiKnobs.wantAi && childArgs.length === 0) {
      childArgs = ["doctor"];
    }
    if (aiKnobs.wantAi) {
      childArgs = injectG6qAiTarget(childArgs);
    }

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
