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
//   tensor pytorch     structured unittest (+ optional --rtl-hard / --impl / --from-timing)
//   tensor virt-impl   multi-phase soft → SV HARD → sv-timing structure
//   tensor regress     virt-card + frameworks + pytorch full hostless gate
//
// Options (like diag/test): --board, --core, --from-timing, --use-emit, --impl
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
  runAiTensorVirtImpl,
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
    useEmit: flagBool(args.flags, "use-emit"),
    requireEmit: flagBool(args.flags, "require-emit"),
    impl: flagStr(args.flags, "impl"),
    rtlHard:
      flagBool(args.flags, "rtl-hard") || flagBool(args.flags, "hard"),
    requireHard:
      flagBool(args.flags, "require-hard") ||
      flagBool(args.flags, "require-rtl"),
    requireTiming: flagBool(args.flags, "require-timing"),
    // remaining positionals after subcommand → frameworks_regress extra args
    extraArgs: args.positionals.slice(1),
  };
}

export const tensorCommand: Command = {
  name: "tensor",
  summary:
    "Host adapter for standalone ai-tensor (spawn doctor/test/frameworks/virt-impl)",
  usage:
    "bun run src/cli/index.ts tensor [status|doctor|probe|test|golden|cosim|queue-soak|rtl|rtl-hard|virt-card|frameworks|pytorch|virt-impl|regress|check] " +
    "[--board ID] [--core CFG] [--impl soft|hard|full] [--rtl-hard] " +
    "[--from-timing DIR] [--use-emit] [--backend sim|mmio|virt-card] [--virt-mode auto|local|tcp] [--dry-run] [--json]",
  details:
    "Spawns ai-tensor package tooling without Cargo path deps.\n" +
    "Mirrors timings → sv-timing and diag/test --from-timing preflight.\n" +
    "\n" +
    "  tensor status         locate package + spawn script\n" +
    "  tensor doctor         independence + cargo doctor\n" +
    "  tensor probe          ProbeReport JSON\n" +
    "  tensor test|golden|cosim|queue-soak|event-fd-soak|rtl\n" +
    "  tensor virt-card      hostless virt-ai-pcie soft UIO/eventfd smoke\n" +
    "  tensor frameworks     PyTorch/TF/numpy Device regress (board propagates)\n" +
    "  tensor pytorch        structured unittest: ai_island features via virt-ai-pcie\n" +
    "                        with optional multi-phase: --rtl-hard / --impl hard|full\n" +
    "  tensor virt-impl      multi-phase virtual implementation structure:\n" +
    "                          soft  = Device/PyTorch virt-card (host software)\n" +
    "                          hard  = SV ai_island RTL HARD (work-ver-ai mmio+gemm_s8)\n" +
    "                          timing= sv-timing package re-check (needs --from-timing)\n" +
    "  tensor regress        virt-card + frameworks + pytorch (local + TCP agent)\n" +
    "  tensor rtl-hard       work-ver-ai mmio+gemm_s8 HARD only (lab)\n" +
    "\n" +
    "  --board <id>          corev-mb board (default virt-ai-pcie for pytorch/virt-impl)\n" +
    "  --core <cfg>          ai_island core package (default g6lc64_ai)\n" +
    "  --impl soft|hard|full virtual implementation phases (default soft)\n" +
    "  --rtl-hard            include SV HARD phase after soft pytorch\n" +
    "  --require-hard        fail if work-ver-ai missing (else soft-skip hard)\n" +
    "  --from-timing <dir>   preflight + FO4 dashboard of timings out-dir (like test)\n" +
    "  --use-emit            expert: export corrected flist env (requires --from-timing)\n" +
    "  --require-timing      fail if timing phase has no FROM_TIMING\n" +
    "  --backend / --virt-mode  Device path for soft phase\n" +
    "\n" +
    "Docs: architecture/ai-matrix/frameworks-virt-pcie.md\n" +
    "Note: soft ≠ SV RTL; hard = real island TB; --from-timing is structural FO4 not STA.",
  examples: [
    "bun run src/cli/index.ts tensor status",
    "bun run src/cli/index.ts tensor pytorch --board virt-ai-pcie --core g6lc64_ai",
    "bun run src/cli/index.ts tensor pytorch --board virt-ai-pcie --core g6lc64_ai --rtl-hard",
    "bun run src/cli/index.ts tensor pytorch --impl full --board virt-ai-pcie --core g6lc64_ai --from-timing workspace/build/sv-timing/host-g6lc64_ai",
    "bun run src/cli/index.ts tensor virt-impl --impl hard --board virt-ai-pcie --core g6lc64_ai --from-timing workspace/build/sv-timing/host-g6lc64_ai",
    "bun run src/cli/index.ts tensor virt-impl --impl full --require-hard --from-timing workspace/build/sv-timing/host-g6lc64_ai",
    "bun run src/cli/index.ts tensor frameworks --board virt-ai-pcie --core g6lc64_ai",
    "bun run src/cli/index.ts tensor regress --board virt-ai-pcie --core g6lc64_ai",
    "bun run src/cli/index.ts tensor rtl-hard --core g6lc64_ai --from-timing workspace/build/sv-timing/host-g6lc64_ai",
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

    if (runOpts.useEmit && !runOpts.fromTiming) {
      logger.error("--use-emit requires --from-timing <dir>");
      return 2;
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
      logger.info(`core     : ${body.coreConfig}`);
      logger.info(`board    : ${body.activeBoard ?? "(none; use --board virt-ai-pcie)"}`);
      logger.info(`note     : ${body.note}`);
      logger.info(
        "commands : tensor doctor|probe|test|golden|cosim|queue-soak|rtl|rtl-hard|virt-card|frameworks|pytorch|virt-impl|regress|check",
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

    if (sub === "virt-impl") {
      return runAiTensorVirtImpl(ctx, runOpts);
    }

    if (isTensorSpawnCmd(sub) || sub === "check") {
      const cmd = sub === "check" ? "check" : sub;
      return runAiTensorSpawn(ctx, cmd, runOpts);
    }

    logger.error(`unknown tensor subcommand: ${sub}`);
    logger.info(
      "usage: tensor [status|doctor|probe|test|golden|cosim|queue-soak|rtl|rtl-hard|virt-card|frameworks|pytorch|virt-impl|regress|check] " +
        "[--board virt-ai-pcie] [--core g6lc64_ai] [--impl soft|hard|full] [--rtl-hard] [--from-timing DIR]",
    );
    return 2;
  },
};
