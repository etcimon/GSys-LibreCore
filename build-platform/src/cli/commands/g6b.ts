// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// g6b.ts — Build-platform gateway to the g6lc_bios package.
//
// Delegates to `g6lc_bios/tools/build.py` so the build-platform gets a single
// top-level command surface for all g6lc_bios build types: minimal zealcli VGA,
// browser-ui (wasm+js+css+dom+dom rendering), optional LDC 1.43 libwasm cell,
// and the full dual build. The build orchestrator auto-installs requirements
// (cargo, bun, pinned LDC) and falls through to build-platform's own
// `tools install` when a host tool is missing.

import { join } from "node:path";

import { requireContext, type Command } from "../command.ts";
import { flagBool } from "../args.ts";
import { run, which } from "../../platform/exec.ts";

export const g6bCommand: Command = {
  name: "g6b",
  summary: "Gateway to the g6lc_bios build orchestrator.",
  usage:
    "bun run src/cli/index.ts g6b <zealcli|browser|libwasm|full|test|check|all> [options]",
  details:
    "Thin pass-through to g6lc_bios/tools/build.py.\n" +
    "\n" +
    "Build types:\n" +
    "  zealcli     Minimal g6b-zealcli VGA (cargo build g6b-cli + smoke).\n" +
    "  browser     Browser-ui first-party wasm lane (bun run build).\n" +
    "  libwasm     Browser-ui + optional LDC 1.43.0-beta1 libwasm cell.\n" +
    "  full        zealcli + browser + libwasm (the dual build).\n" +
    "  test        Generic QEMU test with parameters (--fs, --spec, --libwasm, --settle, --keywords, --disk).\n" +
    "  check       g6b.py check (independence + bun + cargo gates); --rust-only skips the\n" +
    "              browser-ui bun lane (CI without the libwasm/svelte-d submodules or LDC).\n" +
    "  all         Alias for full.\n" +
    "\n" +
    "Auto-installs cargo/bun/LDC as needed; falls through to build-platform\n" +
    "`tools install sim` when cargo is missing. The `test` command runs QEMU\n" +
    "through WSL on Windows and emits the hand-laid btrfs fixture (no mkfs.btrfs needed).",
  examples: [
    "bun run src/cli/index.ts g6b zealcli",
    "bun run src/cli/index.ts g6b browser",
    "bun run src/cli/index.ts g6b libwasm",
    "bun run src/cli/index.ts g6b full",
    "bun run src/cli/index.ts g6b test --spec fixtures/g6lc64-btrfs-test.json --fs btrfs",
    "bun run src/cli/index.ts g6b test --spec fixtures/g6lc64-btrfs-test.json --fs btrfs --libwasm",
    "bun run src/cli/index.ts g6b test --no-emit-fs --disk out/btrfs-key.img --keywords btrfs,STORE",
    "bun run src/cli/index.ts g6b zealcli --spec fixtures/g6lc64-zealcli.json",
    "bun run src/cli/index.ts g6b check",
    "bun run src/cli/index.ts g6b check --rust-only",
  ],
  needsContext: true,
  async run(args) {
    const ctx = requireContext(args);
    const repoRoot = ctx.repoRoot;

    if (flagBool(args.flags, "help")) {
      args.logger.raw(
        `g6b — gateway to g6lc_bios\n\n` +
          `Usage: ${g6bCommand.usage}\n\n` +
          `${g6bCommand.details}\n\n` +
          `Examples:\n` +
          g6bCommand.examples!.map((e) => `  ${e}`).join("\n") +
          "\n",
      );
      return 0;
    }

    const scriptPath = join(repoRoot, "g6lc_bios", "tools", "build.py");
    const python = which("python") || which("python3") || which("py");
    if (!python) {
      args.logger.error(
        "No Python interpreter found on PATH. Install python and re-run.",
      );
      return 1;
    }

    // Reconstruct the child argv from the raw process.argv so that every
    // package-level flag and positional survives unchanged. Drop the leading
    // `g6b` command.
    const raw = process.argv.slice(2);
    const childArgs = raw.slice(1);

    if (childArgs.length === 0) {
      args.logger.error(
        "g6b: no subcommand given. Use: zealcli, browser, libwasm, full, check, or all.",
      );
      return 2;
    }

    args.logger.info(`g6b: -> ${scriptPath} ${childArgs.join(" ")}`);

    const result = await run(
      python,
      [scriptPath, ...childArgs],
      { cwd: join(repoRoot, "g6lc_bios"), stdio: "both", allowFailure: true },
    );
    return result.code;
  },
};
