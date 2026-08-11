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
  const timeOutRaw =
    flagStr(args.flags, "time-out") ?? flagStr(args.flags, "timeout");
  const timeOut =
    timeOutRaw && Number.isFinite(Number(timeOutRaw))
      ? Number(timeOutRaw)
      : undefined;
  return {
    dryRun,
    board: flagStr(args.flags, "board"),
    core: flagStr(args.flags, "core"),
    target: flagStr(args.flags, "target"),
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
    // diag-style narrow HARD surface
    rtlSuite:
      flagStr(args.flags, "rtl-suite") ?? flagStr(args.flags, "suite"),
    verLibrary: flagStr(args.flags, "ver-library"),
    tests: flagStr(args.flags, "tests"),
    timeOut,
    rebuild: flagBool(args.flags, "rebuild"),
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
    "[--board ID] [--core|--target CFG] [--impl soft|hard|full] [--rtl-hard] " +
    "[--suite|--rtl-suite narrow|smoke|ci|peak|full] [--tests LIST] [--ver-library DIR] " +
    "[--from-timing DIR] [--use-emit] [--backend sim|mmio|virt-card] [--dry-run] [--json]",
  details:
    "Spawns ai-tensor package tooling without Cargo path deps.\n" +
    "Mirrors timings → sv-timing and diag/test --from-timing preflight.\n" +
    "HARD RTL uses **narrow Verilator surfaces** (diag-style ownership of target/tests/library).\n" +
    "\n" +
    "  tensor status         locate package + spawn script\n" +
    "  tensor doctor         independence + cargo doctor\n" +
    "  tensor probe          ProbeReport JSON\n" +
    "  tensor test|golden|cosim|queue-soak|event-fd-soak|rtl\n" +
    "  tensor virt-card      hostless virt-ai-pcie soft UIO/eventfd smoke\n" +
    "  tensor frameworks     PyTorch/TF/numpy Device regress (board propagates)\n" +
    "  tensor pytorch        structured unittest via virt-ai-pcie (+ optional HARD)\n" +
    "  tensor virt-impl      multi-phase: soft → SV HARD → sv-timing\n" +
    "  tensor regress        virt-card + frameworks + pytorch (local + TCP)\n" +
    "  tensor rtl-hard       SV HARD only (default suite=narrow)\n" +
    "\n" +
    "Board / core:\n" +
    "  --board <id>          corev-mb board (default virt-ai-pcie for pytorch/virt-impl)\n" +
    "  --core|--target <cfg> DV_TARGET / ai_island package (default g6lc64_ai)\n" +
    "\n" +
    "Phases:\n" +
    "  --impl soft|hard|full|hard-only   virtual implementation phases\n" +
    "  --rtl-hard                        include HARD after soft (pytorch)\n" +
    "  --require-hard                    fail if work-ver library missing\n" +
    "\n" +
    "Narrow HARD surface (like diag compartment verilator{}):\n" +
    "  --suite|--rtl-suite narrow|smoke|ci|peak|full\n" +
    "                        narrow = mmio+gemm_s8 (default for --rtl-hard)\n" +
    "                        smoke  = + multi-claim FIFO\n" +
    "                        ci/peak/full = AI_MATRIX_HARD_SUITE maps\n" +
    "  --tests <list>        override directed ELFs (comma/space)\n" +
    "  --ver-library <dir>   work-ver-* name (default work-ver-ai)\n" +
    "  --time-out <cycles>   AI_MATRIX_TIME_OUT\n" +
    "  --rebuild             AI_MATRIX_VERI_REBUILD=1 (long)\n" +
    "\n" +
    "  --from-timing <dir>   FO4 package preflight + dashboard (like test)\n" +
    "  --use-emit            expert corrected flist env\n" +
    "\n" +
    "Docs: architecture/ai-matrix/frameworks-virt-pcie.md\n" +
    "Note: soft ≠ SV RTL; hard = real island TB; --from-timing is FO4 not STA.",
  examples: [
    "bun run src/cli/index.ts tensor pytorch --board virt-ai-pcie --core g6lc64_ai",
    "bun run src/cli/index.ts tensor pytorch --rtl-hard --suite narrow --board virt-ai-pcie --core g6lc64_ai",
    "bun run src/cli/index.ts tensor virt-impl --impl hard --suite smoke --require-hard",
    "bun run src/cli/index.ts tensor rtl-hard --suite narrow --target g6lc64_ai --ver-library work-ver-ai",
    "bun run src/cli/index.ts tensor rtl-hard --tests ai_island_mmio_smoke,ai_gemm_s8_smoke",
    "bun run src/cli/index.ts tensor virt-impl --impl full --suite narrow --from-timing workspace/build/sv-timing/host-cv64a6_imafdc_sv39",
    "bun run src/cli/index.ts tensor frameworks --board virt-ai-pcie --core g6lc64_ai",
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
