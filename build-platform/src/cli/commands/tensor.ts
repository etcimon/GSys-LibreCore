// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// tensor.ts — Host CLI for the standalone ai-tensor package.
//
//   tensor status   locate package + spawn script
//   tensor doctor   independence + cargo doctor (package-local)
//   tensor test     monorepo-soak/run-ai-tensor.sh test
//   tensor golden   golden-check (+ harness)
//   tensor cosim    harness suite + CLI external checks
//
// Does not link monorepo code into ai-tensor crates. See HOST.md.

import { flagBool } from "../args.ts";
import { requireContext, type Command, type CommandArgs } from "../command.ts";
import {
  formatTensorStatus,
  isTensorSpawnCmd,
  runAiTensorDoctor,
  runAiTensorSpawn,
} from "../../tooling/tensor.ts";

function flagStr(
  flags: Record<string, string | boolean>,
  name: string,
): string | undefined {
  const v = flags[name];
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

export const tensorCommand: Command = {
  name: "tensor",
  summary:
    "Host adapter for standalone ai-tensor (spawn doctor/test/golden/cosim)",
  usage:
    "bun run src/cli/index.ts tensor [status|doctor|test|golden|cosim|check] [--dry-run] [--json]",
  details:
    "Spawns ai-tensor package tooling without Cargo path deps. " +
    "Mirrors timings → sv-timing. Package owns sim/SoftIsland goldens and cosim_harness.",
  examples: [
    "bun run src/cli/index.ts tensor status",
    "bun run src/cli/index.ts tensor test",
    "bun run src/cli/index.ts tensor cosim",
    "AI_TENSOR_DIR=/path/to/ai-tensor bun run src/cli/index.ts tensor doctor",
  ],
  needsContext: true,
  async run(args: CommandArgs): Promise<number> {
    const ctx = requireContext(args);
    const { logger } = ctx;
    const sub = (args.positionals[0] ?? "status").toLowerCase();
    const asJson = flagBool(args.flags, "json");
    const dryRun = flagBool(args.flags, "dry-run") || ctx.dryRun;
    const dirOverride = flagStr(args.flags, "dir");
    if (dirOverride) {
      process.env.AI_TENSOR_DIR = dirOverride;
    }

    if (sub === "status") {
      const body = formatTensorStatus(ctx);
      if (asJson) {
        logger.raw(JSON.stringify(body, null, 2) + "\n");
        return body.present ? 0 : 1;
      }
      logger.heading("ai-tensor host adapter");
      if (body.aiTensorRoot) {
        logger.success(`package  : ${body.aiTensorRoot}`);
      } else {
        logger.warn(
          "package  : NOT FOUND (repo-root/ai-tensor or AI_TENSOR_DIR)",
        );
      }
      if (body.spawnScript) {
        logger.success(`spawn    : ${body.spawnScript}`);
      } else {
        logger.warn("spawn    : monorepo-soak/run-ai-tensor.sh missing");
      }
      logger.info(`note     : ${body.note}`);
      logger.info("commands : tensor doctor|test|golden|cosim|check");
      return body.present ? 0 : 1;
    }

    if (sub === "doctor") {
      if (asJson) {
        logger.raw(
          JSON.stringify(
            { root: formatTensorStatus(ctx).aiTensorRoot, sub: "doctor" },
            null,
            2,
          ) + "\n",
        );
      }
      return runAiTensorDoctor(ctx, { dryRun });
    }

    if (isTensorSpawnCmd(sub) || sub === "check") {
      const cmd = sub === "check" ? "check" : sub;
      return runAiTensorSpawn(ctx, cmd, { dryRun });
    }

    logger.error(`unknown tensor subcommand: ${sub}`);
    logger.info("usage: tensor [status|doctor|test|golden|cosim|check]");
    return 2;
  },
};
