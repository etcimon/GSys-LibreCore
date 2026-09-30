// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// recipes.ts — Install recipes for the managed open-source-sim toolchain.
//
// Verilator, Spike and the formal stack are built by the platform's own scripts
// under build-platform/scripts/ (install-*.sh) with the environment pointed at
// workspace/tooling; Verilator's script applies the repo's custom patches
// strictly and verifies them, which the upstream verif/regress installer does
// not. RISC-V GCC is fetched as a prebuilt tarball. Icarus is delegated to the
// package manager.
// Everything is confined to the managed workspace + respects dry-run.

import { cpSync, existsSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import { basename, join } from "node:path";

import { childEnv, type PlatformContext } from "../context.ts";
import { hasBinary, run, which } from "../platform/exec.ts";
import { resolveBashBinary, runBashScript } from "../platform/shell.ts";
import { recommendedJobs } from "../platform/os.ts";
import { formatVerilatorPatchStatus, verilatorPatchStatus } from "./verilatorPatch.ts";

export interface RecipeOptions {
  dryRun?: boolean;
  force?: boolean;
}

export interface RecipeResult {
  id: string;
  ok: boolean;
  skipped: boolean;
  reason?: string;
}

function already(id: string, reason: string): RecipeResult {
  return { id, ok: true, skipped: true, reason };
}

/** True when a Verilator install prefix has a usable binary (wrapper or bin). */
export function isVerilatorInstalled(verilatorBin: string): boolean {
  return (
    existsSync(join(verilatorBin, "verilator")) ||
    existsSync(join(verilatorBin, "verilator.exe")) ||
    existsSync(join(verilatorBin, "verilator_bin")) ||
    existsSync(join(verilatorBin, "verilator_bin.exe"))
  );
}

/** OSS CAD Suite root under workspace/tooling when it carries Verilator. */
export function findOssCadVerilatorRoot(toolingRoot: string): string | null {
  const root = join(toolingRoot, "oss-cad-suite");
  const bin = join(root, "bin");
  if (
    existsSync(join(bin, "verilator")) ||
    existsSync(join(bin, "verilator.exe")) ||
    existsSync(join(bin, "verilator_bin")) ||
    existsSync(join(bin, "verilator_bin.exe"))
  ) {
    return root;
  }
  return null;
}

/**
 * Verilator: install the PATCHED pinned tag into workspace/tooling/verilator-<pin>.
 *
 * One recipe for every host, `build-platform/scripts/install-verilator.sh`
 * (mirrors install-spike.sh / install-formal.sh):
 *  - clones the pinned tag, applies every `verif/regress/verilator-*.patch`
 *    strictly (the upstream `verif/regress/install-verilator.sh` does
 *    `git apply || true`, which can silently build a stock tool), skips
 *    Verilator's own `make test`, and verifies the installed headers carry
 *    every patched line before reporting success;
 *  - adopts an existing prefix (OSS CAD Suite drop-in, a prior WSL build)
 *    ONLY when that prefix passes the same verification — an unpatched suite
 *    is never linked into the managed prefix;
 *  - **Windows** runs it under WSL (Git-Bash rarely has autoconf/flex/bison),
 *    installing Linux binaries into the managed prefix, like Spike/formal.
 *
 * A prefix that is present but unpatched is reported as a failure, not
 * "already installed": the platform always runs the built, patched version.
 */
export async function installVerilator(
  ctx: PlatformContext,
  options: RecipeOptions = {},
): Promise<RecipeResult> {
  const { logger, repoRoot, tools, host, paths, config } = ctx;

  const patchSummary = (): string =>
    formatVerilatorPatchStatus(verilatorPatchStatus(tools.verilator, repoRoot));

  if (!options.force && isVerilatorInstalled(tools.verilatorBin)) {
    const st = verilatorPatchStatus(tools.verilator, repoRoot);
    if (st.patched || st.patches.length === 0) {
      return already("verilator", `already installed (${formatVerilatorPatchStatus(st)})`);
    }
    logger.warn(`Verilator at ${tools.verilator} is ${formatVerilatorPatchStatus(st)}; rebuilding.`);
    for (const m of st.missing) logger.warn(`  missing: ${m}`);
    options = { ...options, force: true };
  }

  const scriptRel = "build-platform/scripts/install-verilator.sh";
  const scriptAbs = join(repoRoot, scriptRel);
  if (!existsSync(scriptAbs)) {
    return { id: "verilator", ok: false, skipped: false, reason: `${scriptRel} missing` };
  }

  // Candidate to adopt (the script verifies it is patched before copying).
  const ossRoot = findOssCadVerilatorRoot(paths.tooling);
  const adoptFrom = process.env.VERILATOR_ADOPT_FROM ?? ossRoot ?? "";
  const tag = config.toolchain.versions.verilator;

  if (options.dryRun) {
    const how = host.os === "windows" ? "wsl -e bash" : "bash";
    logger.info(`[dry-run] ${how} ${scriptRel} tag=${tag} patches=verif/regress/verilator-*.patch (→ ${tools.verilator})`);
    if (adoptFrom) logger.info(`[dry-run]   adopt candidate (only if patched): ${adoptFrom}`);
    return already("verilator", "dry-run");
  }

  const jobs = String(recommendedJobs());
  const forceFlag = options.force ? "1" : "0";

  // --- Windows: build under WSL into the managed prefix ---------------------
  if (host.os === "windows") {
    if (!hasBinary("wsl")) {
      return {
        id: "verilator",
        ok: false,
        skipped: true,
        reason:
          "windows: WSL required to build the patched Verilator (Git-Bash lacks autoconf/flex/bison); " +
          "enable WSL and re-run tools install verilator",
      };
    }
    const installWsl = await windowsPathToWsl(tools.verilator);
    const repoWsl = await windowsPathToWsl(repoRoot);
    const scriptWsl = await windowsPathToWsl(scriptAbs);
    const adoptWsl = adoptFrom ? await windowsPathToWsl(adoptFrom) : "";

    logger.info(`Verilator ${tag}: building patched tool under WSL → ${tools.verilator}`);
    const shellCmd = [
      "set -euo pipefail",
      `export CVA6_REPO_DIR=${JSON.stringify(repoWsl)}`,
      `export VERILATOR_INSTALL_DIR=${JSON.stringify(installWsl)}`,
      `export VERILATOR_TAG=${JSON.stringify(tag)}`,
      `export NUM_JOBS=${JSON.stringify(jobs)}`,
      `export VERILATOR_FORCE=${JSON.stringify(forceFlag)}`,
      adoptWsl ? `export VERILATOR_ADOPT_FROM=${JSON.stringify(adoptWsl)}` : "true",
      // Build deps often live in apt or mamba envs under WSL.
      'if [ -x "$HOME/tools/mamba/envs/build/bin/autoconf" ]; then',
      '  export PATH="$HOME/tools/mamba/envs/build/bin:$PATH"',
      "fi",
      `bash ${JSON.stringify(scriptWsl)}`,
    ].join("; ");

    const res = await run("wsl", ["-e", "bash", "-lc", shellCmd], {
      cwd: repoRoot,
      logger,
      allowFailure: true,
      stdio: "both",
    });
    const ok = res.ok && isVerilatorInstalled(tools.verilatorBin) && verilatorPatchStatus(tools.verilator, repoRoot).patched;
    return {
      id: "verilator",
      ok,
      skipped: false,
      reason: ok
        ? `${tools.verilator} (via WSL; ${patchSummary()})`
        : `WSL verilator install failed (exit ${res.code}); need autoconf/flex/bison/g++/make in WSL — ${patchSummary()}`,
    };
  }

  // --- Native / Git-Bash path ---------------------------------------------
  // Do NOT use hasBinary("bash"): Git for Windows is often off-PATH while still
  // installed at Program Files\Git\bin\bash.exe (resolveBashBinary finds it).
  const bash = resolveBashBinary();
  if (!bash) {
    return {
      id: "verilator",
      ok: false,
      skipped: false,
      reason: "bash required (install Git for Windows, or enable WSL and re-run tools install verilator)",
    };
  }

  const env = childEnv(ctx, {
    CVA6_REPO_DIR: repoRoot,
    VERILATOR_INSTALL_DIR: tools.verilator,
    VERILATOR_TAG: tag,
    VERILATOR_BUILD_DIR: join(paths.cache, `verilator-build-${tag}`),
    NUM_JOBS: jobs,
    VERILATOR_FORCE: forceFlag,
    ...(adoptFrom ? { VERILATOR_ADOPT_FROM: adoptFrom } : {}),
  });
  const res = await runBashScript(scriptRel, [], {
    cwd: repoRoot,
    env,
    logger,
    allowFailure: true,
  });
  const ok = res.ok && isVerilatorInstalled(tools.verilatorBin) && verilatorPatchStatus(tools.verilator, repoRoot).patched;
  return {
    id: "verilator",
    ok,
    skipped: false,
    reason: ok
      ? `${tools.verilator} (${patchSummary()})`
      : `verilator install failed (exit ${res.code}; bash=${bash.bin}) — ${patchSummary()}`,
  };
}

/** True when the managed Spike ISS binary is present (ELF on Linux/WSL path). */
export function isSpikeInstalled(toolsSpikeBin: string, exeSuffix = ""): boolean {
  return (
    existsSync(join(toolsSpikeBin, "spike")) ||
    (exeSuffix !== "" && existsSync(join(toolsSpikeBin, `spike${exeSuffix}`)))
  );
}

/**
 * Convert a Windows path to a WSL `/mnt/...` path via `wslpath`, with a
 * deterministic fallback when wslpath is unavailable.
 */
async function windowsPathToWsl(winPath: string): Promise<string> {
  const res = await run("wsl", ["-e", "wslpath", "-a", winPath], {
    allowFailure: true,
    stdio: "capture",
  });
  const out = res.stdout.trim().split(/\r?\n/).filter(Boolean).pop();
  if (res.ok && out && out.startsWith("/")) return out;

  // Fallback: C:\foo\bar → /mnt/c/foo/bar
  const m = winPath.replace(/\\/g, "/").match(/^([A-Za-z]):\/(.*)$/);
  if (m?.[1] && m[2] !== undefined) return `/mnt/${m[1].toLowerCase()}/${m[2]}`;
  return winPath.replace(/\\/g, "/");
}

/**
 * Spike ISS: build/install into workspace/tooling/spike.
 *
 * Host rules:
 * - **Linux / macOS**: `build-platform/scripts/install-spike.sh` (vendored
 *   riscv-isa-sim; adopts `~/tools/spike` when present).
 * - **Windows**: never native/Cygwin (`addr_t` clash). Uses **WSL** to run the
 *   same script, installing a Linux ELF into the managed prefix (run via `wsl`).
 * - Requires `dtc`, `make`, and a C++ toolchain inside the build environment
 *   (system packages or `~/tools/mamba/envs/build` under WSL).
 */
export async function installSpike(
  ctx: PlatformContext,
  options: RecipeOptions = {},
): Promise<RecipeResult> {
  const { logger, repoRoot, tools, host } = ctx;
  if (!options.force && isSpikeInstalled(tools.spikeBin, host.exeSuffix)) {
    return already("spike", "already installed");
  }

  const scriptRel = "build-platform/scripts/install-spike.sh";
  const scriptAbs = join(repoRoot, scriptRel);
  if (!existsSync(scriptAbs)) {
    return { id: "spike", ok: false, skipped: false, reason: `${scriptRel} missing` };
  }

  if (options.dryRun) {
    if (host.os === "windows") {
      logger.info(`[dry-run] wsl -e bash ${scriptRel} (→ ${tools.spike})`);
    } else {
      logger.info(`[dry-run] bash ${scriptRel} (→ ${tools.spike})`);
    }
    return already("spike", "dry-run");
  }

  // --- Windows: build/install under WSL into the managed prefix ------------
  if (host.os === "windows") {
    if (!hasBinary("wsl")) {
      logger.warn(
        "Spike requires WSL on Windows (native/Cygwin builds are unsupported). " +
          "Install WSL, then re-run: bun run src/cli/index.ts tools install spike",
      );
      return {
        id: "spike",
        ok: false,
        skipped: true,
        reason: "windows: wsl required for spike build",
      };
    }

    const installWsl = await windowsPathToWsl(tools.spike);
    const repoWsl = await windowsPathToWsl(repoRoot);
    const scriptWsl = await windowsPathToWsl(scriptAbs);
    const srcWsl = `${repoWsl}/verif/core-v-verif/vendor/riscv/riscv-isa-sim`;
    const jobs = String(recommendedJobs());
    const forceFlag = options.force ? "1" : "0";

    // Prefer adopting a prior WSL install at ~/tools/spike (fast path).
    const shellCmd = [
      "set -euo pipefail",
      `export CVA6_REPO_DIR=${JSON.stringify(repoWsl)}`,
      `export SPIKE_INSTALL_DIR=${JSON.stringify(installWsl)}`,
      `export SPIKE_SRC_DIR=${JSON.stringify(srcWsl)}`,
      `export NUM_JOBS=${JSON.stringify(jobs)}`,
      `export SPIKE_FORCE=${JSON.stringify(forceFlag)}`,
      // Adopt only when not forcing a rebuild
      forceFlag === "0"
        ? 'export SPIKE_ADOPT_FROM="${HOME}/tools/spike"'
        : "true",
      `bash ${JSON.stringify(scriptWsl)}`,
    ].join("; ");

    logger.info(`Spike: building/installing under WSL → ${tools.spike}`);
    logger.info(`  WSL prefix: ${installWsl}`);

    const res = await run("wsl", ["-e", "bash", "-lc", shellCmd], {
      cwd: repoRoot,
      logger,
      allowFailure: true,
      stdio: "both",
    });

    const ok = res.ok && isSpikeInstalled(tools.spikeBin, "");
    return {
      id: "spike",
      ok,
      skipped: false,
      reason: ok
        ? `${tools.spikeBin}/spike (Linux ELF; run via wsl)`
        : `WSL spike install failed (exit ${res.code}); need make/g++/dtc in WSL (or ~/tools/mamba/envs/build)`,
    };
  }

  // --- Linux / macOS native ------------------------------------------------
  if (!hasBinary("bash")) {
    return { id: "spike", ok: false, skipped: false, reason: "bash required" };
  }

  const env = childEnv(ctx, {
    SPIKE_INSTALL_DIR: tools.spike,
    SPIKE_SRC_DIR: join(repoRoot, "verif/core-v-verif/vendor/riscv/riscv-isa-sim"),
    CVA6_REPO_DIR: repoRoot,
    NUM_JOBS: String(recommendedJobs()),
    SPIKE_FORCE: options.force ? "1" : "0",
    SPIKE_ADOPT_FROM: process.env.SPIKE_ADOPT_FROM ?? join(process.env.HOME ?? "", "tools/spike"),
  });
  const res = await runBashScript(scriptRel, [], {
    cwd: repoRoot,
    env,
    logger,
    allowFailure: true,
  });
  const ok = res.ok && isSpikeInstalled(tools.spikeBin, host.exeSuffix);
  return {
    id: "spike",
    ok,
    skipped: false,
    reason: ok ? undefined : `spike install failed (exit ${res.code})`,
  };
}

function isFormalInstalled(formalBin: string): boolean {
  // Both halves matter: yosys without sby cannot run a task file, and sby
  // without a slang-capable yosys fails at parse on any config package.
  return existsSync(join(formalBin, "yosys")) && existsSync(join(formalBin, "sby"));
}

/**
 * Bounded-formal toolchain: Yosys (with the integrated sv-elab/slang frontend)
 * plus SymbiYosys, into workspace/tooling/formal.
 *
 * Host rules mirror Spike:
 * - **Linux / macOS**: `build-platform/scripts/install-formal.sh` natively.
 * - **Windows**: never native. Yosys/sby are POSIX tools and the solver stack
 *   is not usable from Cygwin here, so the same script runs under **WSL** and
 *   installs Linux binaries into the managed prefix (invoke via `wsl`).
 *
 * Source build is not a preference, it is a requirement: distro Yosys (0.33 on
 * Ubuntu 24.04) has no `read_slang`, and its classic frontend cannot parse
 * `core/include/config_pkg.sv`. sv-elab is integrated from Yosys v0.67.
 */
export async function installFormal(
  ctx: PlatformContext,
  options: RecipeOptions = {},
): Promise<RecipeResult> {
  const { logger, repoRoot, tools, host, config, paths } = ctx;

  if (!options.force && isFormalInstalled(tools.formalBin)) {
    return already("formal", "already installed");
  }

  const scriptRel = "build-platform/scripts/install-formal.sh";
  const scriptAbs = join(repoRoot, scriptRel);
  if (!existsSync(scriptAbs)) {
    return { id: "formal", ok: false, skipped: false, reason: `${scriptRel} missing` };
  }

  const versions = config.toolchain.versions;
  const yosysRef = versions.yosys ?? "main";
  const sbyRef = versions.sby ?? "main";
  const jobs = String(recommendedJobs());

  if (options.dryRun) {
    const via = host.os === "windows" ? "wsl -e bash" : "bash";
    logger.info(`[dry-run] ${via} ${scriptRel} (yosys=${yosysRef} → ${tools.formal})`);
    return already("formal", "dry-run");
  }

  // --- Windows: build under WSL into the managed prefix --------------------
  if (host.os === "windows") {
    if (!hasBinary("wsl")) {
      logger.warn(
        "The formal toolchain requires WSL on Windows (Yosys/SymbiYosys are POSIX tools). " +
          "Install WSL, then re-run: bun run src/cli/index.ts tools install formal",
      );
      return {
        id: "formal",
        ok: false,
        skipped: true,
        reason: "windows: wsl required for the formal toolchain",
      };
    }

    const installWsl = await windowsPathToWsl(tools.formal);
    const scriptWsl = await windowsPathToWsl(scriptAbs);
    // Build under the WSL home, never on /mnt: DrvFs is slow for a ninja build
    // and an 8-core build plus a solver was observed to crash the WSL VM.
    const shellCmd = [
      `export FORMAL_INSTALL_DIR=${JSON.stringify(installWsl)}`,
      'export FORMAL_BUILD_DIR="$HOME/.cache/g6lc-formal"',
      `export FORMAL_YOSYS_REF=${JSON.stringify(yosysRef)}`,
      `export FORMAL_SBY_REF=${JSON.stringify(sbyRef)}`,
      `export NUM_JOBS=${jobs}`,
      `export FORMAL_FORCE=${options.force ? "1" : "0"}`,
      `bash ${JSON.stringify(scriptWsl)}`,
    ].join("; ");

    logger.info(`Formal toolchain: building under WSL → ${tools.formal}`);
    logger.info(`  yosys ref ${yosysRef} (needs >= v0.67 for integrated slang), ${jobs} jobs`);

    const res = await run("wsl", ["-e", "bash", "-lc", shellCmd], {
      cwd: repoRoot,
      logger,
      allowFailure: true,
      stdio: "both",
    });

    const ok = res.ok && isFormalInstalled(tools.formalBin);
    return {
      id: "formal",
      ok,
      skipped: false,
      reason: ok
        ? `${tools.formalBin}/{yosys,sby} (Linux ELF; run via wsl)`
        : `WSL formal install failed (exit ${res.code}); need cmake>=3.28, ninja and g++>=11 in WSL`,
    };
  }

  // --- Linux / macOS native -------------------------------------------------
  if (!hasBinary("bash")) {
    return { id: "formal", ok: false, skipped: true, reason: "bash not found" };
  }

  const env = childEnv(ctx, {
    FORMAL_INSTALL_DIR: tools.formal,
    FORMAL_BUILD_DIR: join(paths.cache, "formal-build"),
    FORMAL_YOSYS_REF: yosysRef,
    FORMAL_SBY_REF: sbyRef,
    NUM_JOBS: jobs,
    FORMAL_FORCE: options.force ? "1" : "0",
  });
  logger.info(`Formal toolchain: building natively → ${tools.formal} (${jobs} jobs)`);
  const res = await runBashScript(scriptRel, [], {
    cwd: repoRoot,
    env,
    logger,
    allowFailure: true,
  });
  const ok = res.ok && isFormalInstalled(tools.formalBin);
  return {
    id: "formal",
    ok,
    skipped: false,
    reason: ok ? undefined : `formal install failed (exit ${res.code})`,
  };
}

/** Icarus Verilog: delegate to the OS package manager (brew/apt install). */
export async function installIcarus(
  ctx: PlatformContext,
  options: RecipeOptions = {},
): Promise<RecipeResult> {
  if (!options.force && hasBinary("iverilog")) return already("iverilog", "already on PATH");
  ctx.logger.info("Icarus Verilog is installed via the OS package manager; run setup --install to trigger prerequisites.");
  return { id: "iverilog", ok: true, skipped: true, reason: "delegated to package manager" };
}

/**
 * Download a URL to a local path (used for prebuilt toolchains).
 * Prefer curl for large archives (streaming); fall back to fetch+Bun.write.
 */
async function download(url: string, dest: string): Promise<boolean> {
  if (hasBinary("curl") || hasBinary("curl.exe")) {
    const curl = hasBinary("curl.exe") ? "curl.exe" : "curl";
    const res = await run(
      curl,
      ["-L", "--retry", "3", "--fail", "--progress-bar", "-o", dest, url],
      { allowFailure: true },
    );
    if (res.ok && existsSync(dest)) return true;
  }
  try {
    const response = await fetch(url);
    if (!response.ok) return false;
    await Bun.write(dest, response);
    return existsSync(dest);
  } catch {
    return false;
  }
}

/**
 * RISC-V GCC: fetch a prebuilt archive for the host OS into workspace/tooling/riscv.
 * - Linux: Embecosm .tar.gz (strip 1 component into tools.riscv)
 * - Windows: xPack .zip (unpack nested root → tools.riscv so bin/<prefix>gcc.exe lands)
 */
export async function installRiscvGcc(
  ctx: PlatformContext,
  options: RecipeOptions = {},
): Promise<RecipeResult> {
  const { logger, tools, host, config } = ctx;
  const gcc = config.toolchain.riscvGcc;
  const prefix = gcc.toolPrefix ?? "riscv-none-elf-";
  const gccName = `${prefix}gcc${host.exeSuffix}`;

  if (!options.force && existsSync(join(tools.riscvBin, gccName))) {
    return already("riscv-gcc", "already installed");
  }

  const url = gcc.source === "prebuilt" ? gcc.prebuiltUrl?.[host.os] : undefined;
  if (!url) {
    logger.warn(
      `No prebuilt RISC-V GCC URL for ${host.os}; set toolchain.riscvGcc.prebuiltUrl.${host.os} ` +
        "or build from source (util/toolchain-builder).",
    );
    return { id: "riscv-gcc", ok: false, skipped: true, reason: "no prebuilt url for host" };
  }

  const isZip = url.toLowerCase().endsWith(".zip");
  if (!isZip && !hasBinary("tar")) {
    return { id: "riscv-gcc", ok: false, skipped: false, reason: "tar required" };
  }

  const archive = join(ctx.paths.downloads, basename(url));
  if (options.dryRun) {
    logger.info(`[dry-run] download ${url} → ${archive}`);
    logger.info(
      isZip
        ? `[dry-run] expand zip → ${tools.riscv}`
        : `[dry-run] tar -x -f ${archive} --strip-components=1 -C ${tools.riscv}`,
    );
    return already("riscv-gcc", "dry-run");
  }

  await mkdir(ctx.paths.downloads, { recursive: true });
  await mkdir(tools.riscv, { recursive: true });

  if (!existsSync(archive)) {
    logger.info(`Downloading RISC-V GCC (${gcc.version})...`);
    if (!(await download(url, archive))) {
      return { id: "riscv-gcc", ok: false, skipped: false, reason: "download failed" };
    }
  } else {
    logger.info(`Using cached archive ${archive}`);
  }

  // xPack zip/tar.gz nests bin/<prefix>gcc under a versioned root folder.
  const isNestedArchive =
    isZip ||
    /xpack-riscv|riscv-none-elf-gcc.*\.(tar\.gz|tgz)$/i.test(basename(url));

  if (isNestedArchive) {
    const expandDir = join(ctx.paths.downloads, `riscv-gcc-expand-${Date.now()}`);
    await mkdir(expandDir, { recursive: true });
    let expandOk = false;
    if (hasBinary("tar") || hasBinary("tar.exe")) {
      const tar = hasBinary("tar.exe") ? "tar.exe" : "tar";
      const expand = await run(tar, ["-x", "-f", archive, "-C", expandDir], {
        logger,
        allowFailure: true,
      });
      expandOk = expand.ok;
    }
    if (!expandOk && isZip) {
      const expand = await run(
        "powershell",
        [
          "-NoProfile",
          "-Command",
          `Import-Module Microsoft.PowerShell.Archive -ErrorAction SilentlyContinue; Expand-Archive -LiteralPath '${archive.replace(/'/g, "''")}' -DestinationPath '${expandDir.replace(/'/g, "''")}' -Force`,
        ],
        { logger, allowFailure: true },
      );
      expandOk = expand.ok;
    }
    if (!expandOk) {
      return {
        id: "riscv-gcc",
        ok: false,
        skipped: false,
        reason: isZip ? "zip expand failed" : "tar expand failed",
      };
    }
    let root = expandDir;
    const kids = readdirSync(expandDir, { withFileTypes: true });
    const nested = kids.find(
      (d) =>
        d.isDirectory() &&
        existsSync(join(expandDir, d.name, "bin", gccName)),
    );
    if (nested) root = join(expandDir, nested.name);
    else if (!existsSync(join(expandDir, "bin", gccName))) {
      for (const d of kids.filter((k) => k.isDirectory())) {
        const cand = join(expandDir, d.name);
        const sub = readdirSync(cand, { withFileTypes: true }).find(
          (s) => s.isDirectory() && existsSync(join(cand, s.name, "bin", gccName)),
        );
        if (sub) {
          root = join(cand, sub.name);
          break;
        }
      }
    }
    if (!existsSync(join(root, "bin", gccName))) {
      try {
        rmSync(expandDir, { recursive: true, force: true });
      } catch {
        /* ignore */
      }
      return {
        id: "riscv-gcc",
        ok: false,
        skipped: false,
        reason: `archive missing bin/${gccName}`,
      };
    }
    try {
      rmSync(tools.riscv, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
    await mkdir(tools.riscv, { recursive: true });
    cpSync(root, tools.riscv, { recursive: true });
    try {
      rmSync(expandDir, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
    const ok = existsSync(join(tools.riscvBin, gccName));
    return {
      id: "riscv-gcc",
      ok,
      skipped: false,
      reason: ok ? undefined : `install missing ${gccName}`,
    };
  }

  const res = await run("tar", ["-x", "-f", archive, "--strip-components=1", "-C", tools.riscv], {
    logger,
    allowFailure: true,
  });
  return { id: "riscv-gcc", ok: res.ok, skipped: false };
}

/** Run all open-source-sim recipes in order; returns per-recipe results. */
export async function installOpenSourceSimTools(
  ctx: PlatformContext,
  options: RecipeOptions = {},
): Promise<RecipeResult[]> {
  const results: RecipeResult[] = [];
  const recipes = [installRiscvGcc, installVerilator, installSpike, installIcarus];
  let index = 0;
  for (const recipe of recipes) {
    index++;
    const result = await recipe(ctx, options);
    ctx.logger.step(index, recipes.length, `${result.id}: ${result.skipped ? (result.reason ?? "skipped") : result.ok ? "ok" : "FAILED"}`);
    results.push(result);
  }
  return results;
}

/** Locate a Python interpreter that can drive g6lc_qemu/tools/g6q.py. */
function findPython(): string | null {
  return which("python3") || which("python") || which("py");
}

/**
 * Generic fetch recipe for a g6lc_qemu loader. Clones the pinned upstream
 * source tree under workspace/tooling/loader-src/<loader> by delegating to
 * the package's own fetch-fw command so the pin is authoritative.
 */
async function installLoaderSrc(
  ctx: PlatformContext,
  loader: "u-boot" | "edk2",
  options: RecipeOptions = {},
): Promise<RecipeResult> {
  const { logger, repoRoot, paths } = ctx;
  const recipeId = `${loader}-src`;
  const python = findPython();
  if (!python) {
    return { id: recipeId, ok: false, skipped: false, reason: "python3 not found on PATH" };
  }

  const script = join(repoRoot, "g6lc_qemu", "tools", "g6q.py");
  if (!existsSync(script)) {
    return { id: recipeId, ok: false, skipped: false, reason: `g6q.py missing: ${script}` };
  }

  const srcDir = join(paths.tooling, "loader-src", loader);
  const gitMarker = join(srcDir, ".git");
  if (!options.force && existsSync(gitMarker)) {
    return already(recipeId, `already present: ${srcDir}`);
  }

  const fwArgs = ["fetch-fw", "--loader", loader, "--loader-src", srcDir];
  if (loader === "edk2") {
    const platDir = join(paths.tooling, "loader-src", "edk2-platforms");
    fwArgs.push("--edk2-platforms-src", platDir);
  }
  if (options.dryRun) {
    fwArgs.push("--dry-run");
  }

  if (options.dryRun) {
    logger.info(`[dry-run] ${python} tools/g6q.py ${fwArgs.join(" ")}`);
    return already(recipeId, "dry-run");
  }

  logger.info(`${recipeId}: fetching pinned ${loader} source into ${srcDir}`);
  const res = await run(python, [script, ...fwArgs], {
    cwd: join(repoRoot, "g6lc_qemu"),
    env: childEnv(ctx),
    logger,
    allowFailure: true,
    stdio: "both",
  });

  const ok = res.ok && existsSync(gitMarker);
  return {
    id: recipeId,
    ok,
    skipped: false,
    reason: ok ? srcDir : `${loader} source fetch failed (exit ${res.code})`,
  };
}

/** Fetch pinned U-Boot source into workspace/tooling/loader-src/u-boot. */
export async function installUbootSrc(
  ctx: PlatformContext,
  options: RecipeOptions = {},
): Promise<RecipeResult> {
  return installLoaderSrc(ctx, "u-boot", options);
}

/** Fetch pinned EDK2 source (edk2 + edk2-platforms) into workspace/tooling/loader-src. */
export async function installEdk2Src(
  ctx: PlatformContext,
  options: RecipeOptions = {},
): Promise<RecipeResult> {
  return installLoaderSrc(ctx, "edk2", options);
}
