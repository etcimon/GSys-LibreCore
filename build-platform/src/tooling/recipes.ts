// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// recipes.ts — Install recipes for the managed open-source-sim toolchain.
//
// Where the CVA6 repo already ships a proven installer (Verilator, Spike), the
// recipe REUSES it (verif/regress/install-*.sh) with the environment pointed at
// workspace/tooling, rather than re-implementing configure/make. RISC-V GCC is
// fetched as a prebuilt tarball. Icarus is delegated to the package manager.
// Everything is confined to the managed workspace + respects dry-run.

import { existsSync, mkdirSync, readdirSync, rmSync, cpSync, symlinkSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import { basename, join } from "node:path";

import { childEnv, type PlatformContext } from "../context.ts";
import { hasBinary, run } from "../platform/exec.ts";
import { resolveBashBinary, runBashScript } from "../platform/shell.ts";
import { recommendedJobs } from "../platform/os.ts";

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
 * Point the managed Verilator prefix at an existing OSS CAD Suite install so
 * VERILATOR_INSTALL_DIR/bin/verilator resolves without a full source rebuild.
 * Uses directory junctions/symlinks when possible; falls back to a shallow copy
 * of bin/ + share/verilator/.
 */
function adoptVerilatorFromOssCad(
  toolsVerilator: string,
  ossRoot: string,
  logger: PlatformContext["logger"],
): boolean {
  const destBin = join(toolsVerilator, "bin");
  const destShare = join(toolsVerilator, "share");
  const srcBin = join(ossRoot, "bin");
  const srcShareVl = join(ossRoot, "share", "verilator");

  try {
    mkdirSync(toolsVerilator, { recursive: true });
    // Prefer junctions/symlinks (cheap, stay in sync with oss-cad updates).
    const linkDir = (target: string, linkPath: string): void => {
      if (existsSync(linkPath)) return;
      try {
        // Windows: 'junction' for dirs; Node maps type 'junction' → mklink /J.
        symlinkSync(target, linkPath, process.platform === "win32" ? "junction" : "dir");
      } catch {
        mkdirSync(linkPath, { recursive: true });
        cpSync(target, linkPath, { recursive: true, force: true });
      }
    };

    // Link the whole bin/ (includes verilator + verilator_bin*) and share/verilator.
    linkDir(srcBin, destBin);
    if (existsSync(srcShareVl)) {
      mkdirSync(destShare, { recursive: true });
      linkDir(srcShareVl, join(destShare, "verilator"));
    }

    const ok = isVerilatorInstalled(destBin);
    if (ok) {
      logger.info(`Verilator: adopted OSS CAD Suite at ${ossRoot} → ${toolsVerilator}`);
    }
    return ok;
  } catch (err) {
    logger.warn(`Verilator: failed to adopt OSS CAD Suite (${err})`);
    return false;
  }
}

/**
 * Verilator: install into workspace/tooling/verilator-<pin>.
 *
 * Order:
 *  1. Already present at the managed prefix.
 *  2. Adopt workspace/tooling/oss-cad-suite when it already has Verilator
 *     (common on Windows after a prior OSS CAD drop-in).
 *  3. **Windows**: build under WSL into the managed prefix (Git-Bash alone
 *     rarely has autoconf/flex/bison for a source build).
 *  4. **Linux/macOS** (or Windows with a usable bash and no WSL): run
 *     verif/regress/install-verilator.sh via resolveBashBinary() (Git-Bash
 *     preferred — not hasBinary("bash"), which misses off-PATH Git installs).
 */
export async function installVerilator(
  ctx: PlatformContext,
  options: RecipeOptions = {},
): Promise<RecipeResult> {
  const { logger, repoRoot, tools, host, paths } = ctx;

  if (!options.force && isVerilatorInstalled(tools.verilatorBin)) {
    return already("verilator", "already installed");
  }

  // Fast path: re-use OSS CAD Suite Verilator already under workspace/tooling.
  if (!options.force) {
    const oss = findOssCadVerilatorRoot(paths.tooling);
    if (oss) {
      if (options.dryRun) {
        logger.info(`[dry-run] adopt verilator from ${oss} → ${tools.verilator}`);
        return already("verilator", "dry-run adopt oss-cad-suite");
      }
      if (adoptVerilatorFromOssCad(tools.verilator, oss, logger)) {
        return {
          id: "verilator",
          ok: true,
          skipped: false,
          reason: `adopted from ${oss}`,
        };
      }
    }
  }

  const scriptRel = "verif/regress/install-verilator.sh";
  const scriptAbs = join(repoRoot, scriptRel);
  if (!existsSync(scriptAbs)) {
    return { id: "verilator", ok: false, skipped: false, reason: `${scriptRel} missing` };
  }

  if (options.dryRun) {
    if (host.os === "windows") {
      logger.info(`[dry-run] wsl -e bash ${scriptRel} (→ ${tools.verilator})`);
    } else {
      logger.info(`[dry-run] bash ${scriptRel} (→ ${tools.verilator})`);
    }
    return already("verilator", "dry-run");
  }

  // --- Windows: prefer WSL source build (parity with Spike) ---------------
  if (host.os === "windows" && hasBinary("wsl")) {
    const installWsl = await windowsPathToWsl(tools.verilator);
    const buildWsl = await windowsPathToWsl(join(paths.cache, "verilator-build"));
    const scriptWsl = await windowsPathToWsl(scriptAbs);
    const jobs = String(recommendedJobs());

    logger.info(`Verilator: building/installing under WSL → ${tools.verilator}`);
    const shellCmd = [
      "set -euo pipefail",
      `export VERILATOR_INSTALL_DIR=${JSON.stringify(installWsl)}`,
      `export VERILATOR_BUILD_DIR=${JSON.stringify(buildWsl)}`,
      `export NUM_JOBS=${JSON.stringify(jobs)}`,
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

    const ok = res.ok && isVerilatorInstalled(tools.verilatorBin);
    if (ok) {
      return { id: "verilator", ok: true, skipped: false, reason: `${tools.verilator} (via WSL)` };
    }

    // If WSL build failed but OSS CAD is present, still try adopt as salvage.
    const oss = findOssCadVerilatorRoot(paths.tooling);
    if (oss && adoptVerilatorFromOssCad(tools.verilator, oss, logger)) {
      logger.warn(
        `Verilator WSL build failed (exit ${res.code}); adopted OSS CAD Suite instead.`,
      );
      return {
        id: "verilator",
        ok: true,
        skipped: false,
        reason: `adopted from ${oss} after WSL build failure`,
      };
    }

    return {
      id: "verilator",
      ok: false,
      skipped: false,
      reason:
        `WSL verilator install failed (exit ${res.code}); need autoconf/flex/bison/g++/make in WSL, ` +
        `or drop OSS CAD Suite under build-platform/workspace/tooling/oss-cad-suite`,
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
      reason:
        "bash required (install Git for Windows, or enable WSL and re-run tools install verilator)",
    };
  }

  if (host.os === "windows") {
    logger.warn(
      `Verilator: building via ${bash.flavor} at ${bash.bin}. ` +
        "Source builds usually need MSYS/autoconf tools; prefer WSL or OSS CAD Suite.",
    );
  }

  const env = childEnv(ctx, {
    VERILATOR_INSTALL_DIR: tools.verilator,
    VERILATOR_BUILD_DIR: join(paths.cache, "verilator-build"),
    NUM_JOBS: String(recommendedJobs()),
  });
  const res = await runBashScript(scriptRel, [], {
    cwd: repoRoot,
    env,
    logger,
    allowFailure: true,
  });
  const ok = res.ok && isVerilatorInstalled(tools.verilatorBin);
  return {
    id: "verilator",
    ok,
    skipped: false,
    reason: ok ? undefined : `verilator install failed (exit ${res.code}; bash=${bash.bin})`,
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
