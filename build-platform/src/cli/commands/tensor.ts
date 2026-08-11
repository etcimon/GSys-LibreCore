// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// tensor.ts — Host CLI for the standalone ai-tensor package.
//
//   tensor status      locate package + spawn script
//   tensor doctor      independence + cargo doctor (package-local)
//   tensor test        monorepo-soak/run-ai-tensor.sh test
//   tensor golden      golden-check (+ harness)
//   tensor cosim       harness suite + CLI external checks
//   tensor virt-card   hostless virt-ai-pcie soft UIO/eventfd smoke
//   tensor frameworks  PyTorch/TF/numpy via Device (default virt-card board)
//   tensor pytorch     structured unittest: ai_island features via virt-ai-pcie
//   tensor regress     virt-card + frameworks + pytorch full hostless gate
//
// Options (like diag): --board, --core, --from-timing, --backend, --virt-mode
// Does not link monorepo code into ai-tensor crates. See HOST.md.

import { flagBool, flagString } from "../args.ts";
import { requireContext, type Command, type CommandArgs } from "../command.ts";
import {
  formatTensorStatus,
  isTensorSpawnCmd,
  runAiTensorDoctor,
  runAiTensorProbe,
  runAiTensorRtlHard,
  runAiTensorSpawn,
  type TensorRunOptions,
} from "../../tooling/tensor.ts";

function flagStr(
  flags: Record<string, string | boolean>,
  name: string,
): string | undefined {
  const v = flags[name];
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

function collectRunOptions(args: CommandArgs): TensorRunOptions {
  const dryRun = flagBool(args.flags, "dry-run");
  const fromTiming =
    flagStr(args.flags, "from-timing") ?? flagString(args.flags, "from-timing");
  return {
    dryRun,
    board: flagStr(args.flags, "board"),
    core: flagStr(args.flags, "core"),
    apu: flagStr(args.flags, "apu"),
    backend: flagStr(args.flags, "backend"),
    virtMode: flagStr(args.flags, "virt-mode"),
    fromTiming,
    requireEmit: flagBool(args.flags, "require-emit"),
    // remaining positionals after subcommand → frameworks_regress extra args
    extraArgs: args.positionals.slice(1),
  };
}

export const tensorCommand: Command = {
  name: "tensor",
  summary:
    "Host adapter for standalone ai-tensor (spawn doctor/test/frameworks/regress)",
  usage:
    "bun run src/cli/index.ts tensor [status|doctor|probe|test|golden|cosim|queue-soak|rtl|rtl-hard|virt-card|frameworks|pytorch|regress|check] " +
    "[--board ID] [--core CFG] [--from-timing DIR] [--backend sim|mmio|virt-card] [--virt-mode auto|local|tcp] [--dry-run] [--json]",
  details:
    "Spawns ai-tensor package tooling without Cargo path deps.\n" +
    "Mirrors timings → sv-timing and diag --from-timing preflight.\n" +
    "\n" +
    "  tensor status         locate package + spawn script\n" +
    "  tensor doctor         independence + cargo doctor\n" +
    "  tensor probe          ProbeReport JSON\n" +
    "  tensor test|golden|cosim|queue-soak|event-fd-soak|rtl\n" +
    "  tensor virt-card      hostless virt-ai-pcie soft UIO/eventfd smoke\n" +
    "  tensor frameworks     PyTorch/TF/numpy Device regress (board propagates)\n" +
    "  tensor pytorch        structured unittest: ai_island features via virt-ai-pcie\n" +
    "                        (python/tests/test_torch_virt_ai_island.py; --core g6lc64_ai)\n" +
    "  tensor regress        virt-card + frameworks + pytorch (local + TCP agent)\n" +
    "  tensor rtl-hard       work-ver-ai mmio+gemm_s8 HARD (lab)\n" +
    "\n" +
    "  --board <id>          corev-mb board (default virt-ai-pcie for pytorch/frameworks/regress)\n" +
    "  --core <cfg>          ai_island core package (default g6lc64_ai for pytorch/regress)\n" +
    "  --apu <note>          optional AI_TENSOR_APU export\n" +
    "  --backend <be>        sim | mmio | virt-card\n" +
    "  --virt-mode <m>       auto | local | tcp (virt-card path)\n" +
    "  --from-timing <dir>   preflight structural validate of timings out-dir\n" +
    "                        (exports CVA6_FROM_TIMING; does not replace live RTL)\n" +
    "\n" +
    "Select path: mb select virt-ai-pcie  (writes generated/ai-tensor.env) then\n" +
    "  tensor pytorch --board virt-ai-pcie --core g6lc64_ai\n" +
    "Or pass --board/--core without select — board.json ai{} still loads.\n" +
    "Docs: architecture/ai-matrix/frameworks-virt-pcie.md\n" +
    "Env: AI_TENSOR_BOARD_ID, AI_TENSOR_BACKEND, AI_TENSOR_UIO, AI_TENSOR_CORE.",
  examples: [
    "bun run src/cli/index.ts tensor status",
    "bun run src/cli/index.ts tensor virt-card --board virt-ai-pcie",
    "bun run src/cli/index.ts tensor pytorch --board virt-ai-pcie --core g6lc64_ai",
    "bun run src/cli/index.ts tensor pytorch --board virt-ai-pcie --core g6lc64_ai --from-timing workspace/build/sv-timing/host-g6lc64_ai",
    "bun run src/cli/index.ts tensor frameworks --board virt-ai-pcie --core g6lc64_ai",
    "bun run src/cli/index.ts tensor frameworks --board virt-ai-pcie --virt-mode tcp",
    "bun run src/cli/index.ts tensor regress --board virt-ai-pcie --core g6lc64_ai",
    "bun run src/cli/index.ts tensor regress --from-timing workspace/build/sv-timing/host-g6lc64_ai",
    "bun run src/cli/index.ts tensor frameworks --backend sim --suites torch,tf",
    "bun run src/cli/index.ts tensor rtl-hard",
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
    const runOpts = collectRunOptions(args);
    runOpts.dryRun = dryRun;

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
      logger.info(`core     : ${body.coreConfig}`);
      logger.info(`board    : ${body.activeBoard ?? "(none; use --board virt-ai-pcie)"}`);
      logger.info(`note     : ${body.note}`);
      logger.info(
        "commands : tensor doctor|probe|test|golden|cosim|queue-soak|rtl|rtl-hard|virt-card|frameworks|pytorch|regress|check",
      );
      return body.present ? 0 : 1;
    }

    if (sub === "doctor") {
      return runAiTensorDoctor(ctx, { dryRun, json: asJson });
    }

    if (sub === "probe") {
      return runAiTensorProbe(ctx, { dryRun });
    }

    if (sub === "rtl-hard") {
      return runAiTensorRtlHard(ctx, runOpts);
    }

    if (isTensorSpawnCmd(sub) || sub === "check") {
      const cmd = sub === "check" ? "check" : sub;
      return runAiTensorSpawn(ctx, cmd, runOpts);
    }

    logger.error(`unknown tensor subcommand: ${sub}`);
    logger.info(
      "usage: tensor [status|doctor|probe|test|golden|cosim|queue-soak|rtl|rtl-hard|virt-card|frameworks|pytorch|regress|check] " +
        "[--board virt-ai-pcie] [--core g6lc64_ai] [--from-timing DIR]",
    );
    return 2;
  },
};
