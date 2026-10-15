// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// rtlTiming.ts — Gate-level static timing of a config-package target
// (core/ + corev_apu/ RTL) with the tools/openroad fork.
//
// Two steps, the same on both routes:
//   1. Yosys (integrated slang frontend) reads the flattened manifest for the
//      target, `synth`s it, maps flops and logic onto the liberty with
//      dfflibmap + abc, and writes a gate-level netlist.
//   2. The fork's openroad runs build-platform/scripts/openroad-timing.tcl on
//      that netlist (set_thread_count = toolchain.openroad.threads, every core
//      by default) against a generated SDC: one clock on the clock port at the
//      SoC target frequency, I/O delays at 20% of the period like the fork's
//      own flow tests.
//
// Local: managed formal yosys + managed openroad (WSL on Windows). Remote: the
// same two steps as one script on the testharness builder, through the proxy
// (`runRemoteScript`), building the fork there first when its prefix is
// missing — -march floor, PGO and jobs from toolchain.openroad, nproc jobs.
//
// The liberty is a study library unless the project points at its own:
// physicalDesign.pdk.liberty / CVA6_LIBERTY first, else the fork's test
// platform matching soc.process (nangate45 / sky130hd / sky130hs / asap7).
// Numbers from a study library rank paths; they are not sign-off.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { isAbsolute, join } from "node:path";

import type { PlatformContext } from "../context.ts";
import { run } from "../platform/exec.ts";
import { getHostInfo } from "../platform/os.ts";
import { windowsPathToWsl, wslCommand } from "../platform/wsl.ts";
import {
  REMOTE_FORMAL,
  REMOTE_OPENROAD,
  REMOTE_OPENROAD_SRC,
  REMOTE_REPO,
  edaEnv,
  edaPaths,
  posixPath,
  resolveSynthTop,
  runRemoteScript,
  toRemotePaths,
  writeFlatManifest,
} from "./eda.ts";
import { resolveStaTool, staThreadCount, type StaTool } from "./staHandoff.ts";
import {
  buildSvTimingCorrectArgs,
  buildSvtRunCommand,
  fo4BudgetFor,
  targetMhzForFo4Budget,
  timingsRepoEnv,
  validateTimingsOutDir,
  writeHostParamMap,
  writeVerifyPortableFlist,
} from "./timings.ts";

export interface RtlTimingOptions {
  /** Config-package target (default soc.coreConfig). */
  target: string;
  /** Synthesis top (default verify.synthTopByTarget / verify.top). */
  top?: string;
  /** Liberty .lib (default: physicalDesign.pdk.liberty, CVA6_LIBERTY, then the platform library). */
  liberty?: string;
  /** Fork test platform for the study liberty (default soc.process when it is one). */
  platform?: string;
  /** Clock port on the top (default clk_i). */
  clockPort: string;
  /** Clock frequency for the SDC (default soc.targetFrequencyMHz). */
  targetMhz: number;
  /** Run on the testharness builder instead of this host. */
  remote: boolean;
  /** Remote only: rebuild the fork prefix even when present. */
  rebuildOpenroad?: boolean;
  /** Output root (default workspace/build/sta-rtl/<target>). */
  outDir?: string;
  /**
   * Run sv-timing first: `correct --all-modules --emit --allow-latency` on the
   * target's flist at this structural budget (FO4 per stage), and synthesize
   * the corrected emit instead of the live RTL. 10 is the deep-pipeline
   * target the package documents (sv-timing AGENTS.md §3.2.1: 4000 MHz at
   * fo4_ps 20, margin 0.2). Review-only emit — never merged into core/.
   */
  fo4Budget?: number;
  /** Process FO4 in ps for the budget (default 20; quote it with every number). */
  fo4Ps?: number;
  /** Budget margin 0..1 (default 0.2). */
  budgetMargin?: number;
  /**
   * sv-timing `--opt-level` preset for the pre-pass. Default `3` when a budget
   * is given: multi-cut `pipeline_region` with `budget-fit` cuts is the only
   * preset that can take a 97 FO4 path to 10 (`-O2` places one register).
   */
  svtOptLevel?: string;
  /** Raw sv-timing `correct` arguments appended after the adapter's (`--svt-args`). */
  svtExtraArgs?: string[];
  /** Reuse an existing `timings correct --emit` package instead of running the pre-pass. */
  fromTiming?: string;
  /** Yosys lowering before the liberty map: `lean` (default) or Yosys's full `synth`. */
  mapRecipe?: "lean" | "synth";
}

export interface RtlTimingResult {
  ok: boolean;
  outDir: string;
  target: string;
  top: string;
  liberty: string;
  /** Corrected-emit flist the synthesis used, when the sv-timing pre-pass ran. */
  emitFlist?: string;
  /** Structural budget of the pre-pass (FO4) and the clock it maps to. */
  fo4Budget?: number;
  svtTargetMhz?: number;
  stages: { id: string; status: "pass" | "skip" | "fail"; detail: string }[];
  /** Parsed from the STA_RESULT line of openroad-timing.tcl. */
  wnsMax?: number;
  tnsMax?: number;
  wnsMin?: number;
  tnsMin?: number;
}

/**
 * Fork test platforms that ship a free study library, as `test/<platform>.vars`
 * names them: the typical-corner liberty yosys maps onto, and the technology +
 * standard-cell LEF the `openroad` binary needs to link (`sta` does not).
 * asap7 is left out: its libraries are gzip'd, which yosys cannot read.
 */
const PLATFORM_FILES: Record<string, { lib: string; lefs: string[] }> = {
  nangate45: {
    lib: "Nangate45/Nangate45_typ.lib",
    lefs: ["Nangate45/Nangate45_tech.lef", "Nangate45/Nangate45_stdcell.lef"],
  },
  sky130hd: {
    lib: "sky130hd/sky130hd_tt.lib",
    lefs: ["sky130hd/sky130hd.tlef", "sky130hd/sky130hd_std_cell.lef"],
  },
  sky130hs: {
    lib: "sky130hs/sky130hs_tt.lib",
    lefs: ["sky130hs/sky130hs.tlef", "sky130hs/sky130hs_std_cell.lef"],
  },
};

/** Study-liberty path inside a fork checkout for a platform, or null. */
export function platformLiberty(platform: string | undefined): string | null {
  if (!platform) return null;
  const rel = PLATFORM_FILES[platform.toLowerCase()]?.lib;
  return rel ? `test/${rel}` : null;
}

/** LEF paths inside a fork checkout for a platform (tech first), or []. */
export function platformLefs(platform: string | undefined): string[] {
  if (!platform) return [];
  return (PLATFORM_FILES[platform.toLowerCase()]?.lefs ?? []).map((r) => `test/${r}`);
}

/**
 * Resolve the liberty: an explicit path, the project's PDK/env, or the fork's
 * study library for `platform` (default soc.process). Returns a repo-side path
 * plus whether it came from the fork checkout (so the remote route can read it
 * from REMOTE_OPENROAD_SRC rather than needing it synced).
 */
export function resolveTimingLiberty(
  ctx: PlatformContext,
  opts: { liberty?: string; platform?: string },
): {
  path: string;
  source: "explicit" | "pdk" | "env" | "platform";
  forkRel?: string;
  /** Technology + std-cell LEF for the openroad binary (platform source only). */
  lefs: string[];
  lefForkRels: string[];
} | null {
  const platform = (opts.platform ?? ctx.config.soc.process ?? "").toLowerCase();
  const lefForkRels = platformLefs(platform);
  const lefs = lefForkRels.map((r) => join(ctx.repoRoot, "tools", "openroad", r));
  if (opts.liberty) {
    const p = isAbsolute(opts.liberty) ? opts.liberty : join(ctx.repoRoot, opts.liberty);
    if (existsSync(p)) return { path: p, source: "explicit", lefs, lefForkRels };
  }
  const pdk = ctx.config.physicalDesign?.pdk as { liberty?: string } | undefined;
  if (pdk?.liberty) {
    const p = isAbsolute(pdk.liberty) ? pdk.liberty : join(ctx.repoRoot, pdk.liberty);
    if (existsSync(p)) return { path: p, source: "pdk", lefs, lefForkRels };
  }
  if (process.env.CVA6_LIBERTY && existsSync(process.env.CVA6_LIBERTY)) {
    return { path: process.env.CVA6_LIBERTY, source: "env", lefs, lefForkRels };
  }
  const rel = platformLiberty(platform);
  if (rel) {
    const p = join(ctx.repoRoot, "tools", "openroad", rel);
    // The remote route reads it from the builder's fork checkout even when the
    // local submodule is not populated.
    return { path: p, source: "platform", forkRel: rel, lefs, lefForkRels };
  }
  return null;
}

/** SDC text: one clock at the target frequency, I/O delays at 20% of the period. */
export function buildClockSdc(opts: { clockPort: string; targetMhz: number; top: string }): string {
  const period = 1000 / opts.targetMhz;
  const io = (period * 0.2).toFixed(4);
  return [
    `# Generated by build-platform timings sta-rtl for ${opts.top} — review constraints, not sign-off.`,
    `create_clock -name core_clock -period ${period.toFixed(4)} [get_ports ${opts.clockPort}]`,
    `set_input_delay ${io} -clock core_clock [delete_from_list [all_inputs] [get_ports ${opts.clockPort}]]`,
    `set_output_delay ${io} -clock core_clock [all_outputs]`,
    "",
  ].join("\n");
}

/**
 * Yosys script: slang read of the manifest, generic lowering, liberty mapping,
 * netlist. Two recipes:
 *
 * - `lean` (default): `proc; flatten; opt_clean; wreduce; alumacc; memory;
 *   techmap` then `dfflibmap` + `abc -liberty`. No `opt`/`opt_merge`, `share`,
 *   `fsm` or `check`: on a whole core those are the asymptotic passes
 *   (`opt_merge` was measured at ~11 merges/min from ~273k cells; `check`
 *   after `flatten` ran past an hour on g6lc64_ooo), and none of them changes
 *   what STA measures — abc restructures the logic anyway.
 * - `synth`: Yosys's full `synth -flatten` before the mapping (slower, the
 *   netlist Yosys would hand a real flow).
 */
export function buildMapScript(opts: {
  manifest: string;
  top: string;
  liberty: string;
  netlist: string;
  defines: string[];
  slangArgs: string[];
  recipe?: "lean" | "synth";
}): string {
  const lowering =
    (opts.recipe ?? "lean") === "synth"
      ? [`synth -top ${opts.top} -flatten`]
      : [
          "proc",
          "flatten",
          "opt_clean",
          "wreduce",
          "alumacc",
          "opt_clean",
          "memory -nomap",
          "memory_map",
          "opt_clean",
          "techmap",
          "opt_clean",
        ];
  return [
    [
      "read_slang -f",
      opts.manifest,
      `--top ${opts.top}`,
      "--single-unit",
      ...opts.defines.map((d) => `-D${d}`),
      ...opts.slangArgs,
    ].join(" "),
    `hierarchy -check -top ${opts.top}`,
    ...lowering,
    // The technology mapping STA needs: flops onto the liberty's cells, logic
    // through abc with liberty areas/delays; one flat timing graph.
    `dfflibmap -liberty ${opts.liberty}`,
    `abc -liberty ${opts.liberty}`,
    "opt_clean -purge",
    `stat -liberty ${opts.liberty}`,
    `write_verilog -noattr -noexpr ${opts.netlist}`,
  ].join("; ");
}

export function parseStaResult(text: string): Pick<RtlTimingResult, "wnsMax" | "tnsMax" | "wnsMin" | "tnsMin"> {
  const m = text.match(/^STA_RESULT .*wns_max=(\S+) tns_max=(\S+) wns_min=(\S+) tns_min=(\S+)/m);
  if (!m) return {};
  const n = (s: string | undefined) => {
    const v = Number(s);
    return Number.isFinite(v) ? v : undefined;
  };
  return { wnsMax: n(m[1]), tnsMax: n(m[2]), wnsMin: n(m[3]), tnsMin: n(m[4]) };
}

function marchValue(ctx: PlatformContext): string {
  return ctx.config.toolchain.openroad.march;
}

/** Outcome of the optional sv-timing pre-pass. */
interface SvtPrepass {
  stage: RtlTimingResult["stages"][number];
  /** `svt_corrected.f` to overlay on the manifest, when the pass emitted. */
  emitFlist?: string;
  targetMhz?: number;
}

/**
 * sv-timing before synthesis: correct the target's RTL to `fo4Budget` and
 * emit the corrected tree under `<outDir>/svt/corrected`. The budget is turned
 * into the clock target sv-timing derives it from (`targetMhzForFo4Budget`),
 * so `--fo4 10` means budget_fo4 = 10.0 exactly for the given fo4_ps/margin.
 * With `fromTiming`, an existing `timings correct --emit` package is reused.
 */
async function runSvtPrepass(
  ctx: PlatformContext,
  opts: RtlTimingOptions,
  outDir: string,
): Promise<SvtPrepass> {
  const fo4Ps = opts.fo4Ps ?? 20;
  const margin = opts.budgetMargin ?? 0.2;
  if (opts.fromTiming) {
    const v = validateTimingsOutDir(ctx, { fromTiming: opts.fromTiming, requireEmit: true });
    if (!v.ok || !v.correctedFlist) {
      return {
        stage: {
          id: "s0-svt-correct",
          status: "fail",
          detail: `--from-timing ${opts.fromTiming}: ${v.issues.map((i) => i.message).join("; ") || "no corrected emit"}`,
        },
      };
    }
    return {
      stage: { id: "s0-svt-correct", status: "pass", detail: `reusing emit ${posixPath(v.correctedFlist)}` },
      emitFlist: v.correctedFlist,
    };
  }
  const budget = opts.fo4Budget;
  if (budget === undefined) {
    return { stage: { id: "s0-svt-correct", status: "skip", detail: "no --fo4 budget; live RTL" } };
  }
  const targetMhz = targetMhzForFo4Budget(budget, fo4Ps, margin);
  if (!Number.isFinite(targetMhz)) {
    return { stage: { id: "s0-svt-correct", status: "fail", detail: `bad budget ${budget} FO4 (fo4_ps ${fo4Ps}, margin ${margin})` } };
  }
  const svtDir = join(outDir, "svt");
  mkdirSync(svtDir, { recursive: true });
  let env: Record<string, string>;
  try {
    env = { ...timingsRepoEnv(ctx, opts.target), ...edaEnv(ctx, edaPaths(ctx), opts.target) };
  } catch {
    env = timingsRepoEnv(ctx, opts.target);
  }
  const portable = writeVerifyPortableFlist(ctx, env, opts.target, {
    tag: `sta-rtl-${opts.target}`,
    outPath: posixPath(join(svtDir, "portable.f")),
  });
  const paramMap = writeHostParamMap(ctx, {
    outPath: posixPath(join(svtDir, "param-map.json")),
    xlen: ctx.config.soc.xlen as number | undefined,
  });
  const correctedDir = posixPath(join(svtDir, "corrected"));
  // Defaults that make the budget reachable and the emit synthesizable:
  // -O3 (multi-cut, budget-fit), enough stages per region for the deepest
  // cone the core shows (~100 FO4) at this budget, and the real-feed emit
  // (the lean sidecar feeds inserted registers with zero, which yosys would
  // sweep away before STA ever saw a stage). Every one is overridable
  // through --svt-args, which is appended last.
  const extra = opts.svtExtraArgs ?? [];
  const has = (flag: string) => extra.includes(flag);
  const defaults: string[] = [];
  if (!has("--opt-max-stages-per-region")) {
    defaults.push("--opt-max-stages-per-region", String(Math.min(16, Math.max(8, Math.ceil(128 / budget)))));
  }
  if (!has("--real-cut-feeds")) defaults.push("--real-cut-feeds");
  if (!has("--emit-balance-mux-rtl")) defaults.push("--emit-balance-mux-rtl");
  const args = buildSvTimingCorrectArgs({
    portableFlist: portable.portablePath,
    allModules: true,
    targetMhz,
    fo4Ps,
    budgetMargin: margin,
    optLevel: opts.svtOptLevel ?? "3",
    allowLatency: true,
    emit: true,
    outDir: correctedDir,
    jsonOut: posixPath(join(svtDir, "correct.json")),
    cache: posixPath(join(svtDir, "ir.sqlite")),
    paramMap,
    assumeXlen: ctx.config.soc.xlen as number | undefined,
    packageMode: "packages",
    extraArgs: [...defaults, ...extra],
  });
  const cmd = buildSvtRunCommand(ctx, args, { release: true });
  if (!cmd) {
    return { stage: { id: "s0-svt-correct", status: "fail", detail: "sv-timing package not found at repo root" } };
  }
  const budgetNote = `${fo4BudgetFor(targetMhz, fo4Ps, margin).toFixed(1)} FO4 (target ${targetMhz.toFixed(0)} MHz, fo4_ps=${fo4Ps}, margin=${margin})`;
  ctx.logger.info(`sta-rtl: sv-timing correct --all-modules --emit at ${budgetNote}`);
  ctx.logger.info(`+ ${cmd.argv.join(" ")}`);
  if (ctx.dryRun) {
    return { stage: { id: "s0-svt-correct", status: "skip", detail: `dry-run ${budgetNote}` }, targetMhz };
  }
  const res = await run(cmd.argv[0]!, cmd.argv.slice(1), {
    cwd: cmd.cwd,
    allowFailure: true,
    stdio: "capture",
    env: { ...process.env, ...env, RUST_MIN_STACK: process.env.RUST_MIN_STACK ?? "16777216" } as Record<string, string>,
    logger: ctx.logger,
  });
  writeFileSync(join(svtDir, "correct.log"), `exit=${res.code}\n${res.stdout}\n${res.stderr}\n`, "utf8");
  const emitFlist = join(correctedDir, "svt_corrected.f");
  if (!res.ok) {
    return { stage: { id: "s0-svt-correct", status: "fail", detail: `sv-timing correct exit ${res.code} (svt/correct.log)` }, targetMhz };
  }
  if (!existsSync(emitFlist)) {
    // Nothing to rewrite at this budget (or every candidate was refused): the
    // live RTL is the corrected RTL. Report it rather than failing.
    return { stage: { id: "s0-svt-correct", status: "pass", detail: `${budgetNote}: no emitted rewrites; live RTL` }, targetMhz };
  }
  const replaced = readFileSync(emitFlist, "utf8").split(/\r?\n/).filter((l) => /__svt\.(sv|v|svh)$/i.test(l.trim())).length;
  return {
    stage: { id: "s0-svt-correct", status: "pass", detail: `${budgetNote}: ${replaced} corrected file(s) → ${posixPath(emitFlist)}` },
    emitFlist: posixPath(emitFlist),
    targetMhz,
  };
}

async function toolPath(tool: StaTool, p: string): Promise<string> {
  return tool.viaWsl ? windowsPathToWsl(p) : posixPath(p);
}

/** Local route: managed yosys + managed openroad on this host (WSL on Windows). */
async function runLocal(
  ctx: PlatformContext,
  opts: RtlTimingOptions,
  top: string,
  liberty: string,
  lefs: string[],
  outDir: string,
  pre: SvtPrepass,
): Promise<RtlTimingResult> {
  const stages: RtlTimingResult["stages"] = [pre.stage];
  const paths = edaPaths(ctx);
  const netlist = join(outDir, "netlist.v");
  const sdc = join(outDir, "clock.sdc");
  writeFileSync(sdc, buildClockSdc({ clockPort: opts.clockPort, targetMhz: opts.targetMhz, top }), "utf8");

  const manifest = writeFlatManifest(ctx, paths, opts.target, {
    outSubdir: "sta-rtl", outTag: opts.target, emitFlist: pre.emitFlist,
  });
  const result: RtlTimingResult = {
    ok: false, outDir: posixPath(outDir), target: opts.target, top, liberty: posixPath(liberty), stages,
    emitFlist: pre.emitFlist, fo4Budget: opts.fo4Budget, svtTargetMhz: pre.targetMhz,
  };
  if (pre.stage.status === "fail") return result;

  if (!existsSync(paths.yosys)) {
    stages.push({ id: "s1-yosys-map", status: "skip", detail: "yosys missing: tools install formal" });
    return result;
  }
  const staTool = resolveStaTool(ctx);
  if (!staTool) {
    stages.push({ id: "s1-yosys-map", status: "skip", detail: "no STA engine: tools install openroad" });
    return result;
  }
  // Yosys and openroad share the WSL rule on Windows (both are Linux ELFs
  // under workspace/tooling), so the paths in the scripts follow the STA tool.
  const p = (x: string) => toolPath(staTool, x);
  const script = buildMapScript({
    manifest: await p(manifest.path),
    top,
    liberty: await p(liberty),
    netlist: await p(netlist),
    defines: ctx.config.verify.synthDefines,
    slangArgs: ctx.config.verify.synthSlangArgsByTarget[opts.target] ?? [],
    recipe: opts.mapRecipe,
  });
  const synthLog = join(outDir, "synth.log");
  let synth;
  if (staTool.viaWsl) {
    const ys = await windowsPathToWsl(paths.yosys);
    const cwd = await windowsPathToWsl(ctx.repoRoot);
    synth = await run("wsl", wslCommand(`cd ${JSON.stringify(cwd)} && ${JSON.stringify(ys)} -p ${JSON.stringify(script)}`), {
      cwd: ctx.repoRoot, stdio: "capture", allowFailure: true, dryRun: ctx.dryRun, logger: ctx.logger,
    });
  } else {
    synth = await run(paths.yosys, ["-p", script], {
      cwd: ctx.repoRoot, env: edaEnv(ctx, paths, opts.target), stdio: "capture", allowFailure: true, dryRun: ctx.dryRun, logger: ctx.logger,
    });
  }
  writeFileSync(synthLog, `exit=${synth.code}\n${synth.stdout}\n${synth.stderr}\n`, "utf8");
  if (ctx.dryRun) {
    stages.push({ id: "s1-yosys-map", status: "skip", detail: "dry-run" });
    return result;
  }
  if (!synth.ok || !existsSync(netlist)) {
    stages.push({ id: "s1-yosys-map", status: "fail", detail: `yosys exit ${synth.code} (see synth.log)` });
    return result;
  }
  stages.push({ id: "s1-yosys-map", status: "pass", detail: `netlist.v (${top}, liberty-mapped)` });

  const threads = staThreadCount(ctx);
  const tcl = join(ctx.repoRoot, "build-platform", "scripts", "openroad-timing.tcl");
  const reportDir = join(outDir, "reports");
  // openroad's link_design needs the technology; sta links from the liberty.
  const lefsPresent = lefs.filter((l) => existsSync(l));
  if (staTool.kind === "openroad" && lefsPresent.length === 0) {
    stages.push({ id: "s2-openroad-sta", status: "fail", detail: `the openroad binary needs LEF to link (ORD-2010): use --platform nangate45|sky130hd|sky130hs, or install the fork's sta (tools install openroad --force)` });
    return result;
  }
  const lefsForTool: string[] = [];
  for (const l of lefsPresent) lefsForTool.push(await p(l));
  const envPairs = [
    ...(staTool.kind === "openroad" ? [`OR_LEF=${JSON.stringify(lefsForTool.join(" "))}`] : []),
    `OR_LIBERTY=${JSON.stringify(await p(liberty))}`,
    `OR_VERILOG=${JSON.stringify(await p(netlist))}`,
    `OR_SDC=${JSON.stringify(await p(sdc))}`,
    `OR_TOP=${JSON.stringify(top)}`,
    `OR_THREADS=${threads}`,
    `OR_REPORT_DIR=${JSON.stringify(await p(reportDir))}`,
  ];
  const args = staTool.kind === "openroad" ? "-no_init -exit" : "-exit";
  const staLog = join(outDir, "sta.log");
  let sta;
  if (staTool.viaWsl) {
    const bin = await windowsPathToWsl(staTool.bin);
    const envFile = await windowsPathToWsl(join(ctx.tools.openroad, "openroad-env.sh"));
    const cmd = `[ -f ${JSON.stringify(envFile)} ] && . ${JSON.stringify(envFile)}; ${envPairs.join(" ")} ${JSON.stringify(bin)} ${args} ${JSON.stringify(await p(tcl))}`;
    sta = await run("wsl", wslCommand(cmd), { cwd: outDir, stdio: "capture", allowFailure: true, logger: ctx.logger });
  } else {
    const envFile = join(ctx.tools.openroad, "openroad-env.sh");
    const source = existsSync(envFile) ? `. ${JSON.stringify(envFile)}; ` : "";
    sta = await run("bash", ["-lc", `${source}${envPairs.join(" ")} ${JSON.stringify(staTool.bin)} ${args} ${JSON.stringify(tcl)}`], {
      cwd: outDir, stdio: "capture", allowFailure: true, logger: ctx.logger,
    });
  }
  const staText = `${sta.stdout}\n${sta.stderr}`;
  writeFileSync(staLog, `exit=${sta.code}\n${staText}\n`, "utf8");
  const parsed = parseStaResult(staText);
  if (!sta.ok || parsed.wnsMax === undefined) {
    stages.push({ id: "s2-openroad-sta", status: "fail", detail: `${staTool.kind} exit ${sta.code} (see sta.log)` });
    return result;
  }
  stages.push({
    id: "s2-openroad-sta",
    status: "pass",
    detail: `wns_max ${parsed.wnsMax} tns_max ${parsed.tnsMax} (${staTool.kind} ${staTool.source}, ${threads} threads)`,
  });
  return { ...result, ...parsed, ok: true };
}

/**
 * Remote route: one script on the builder. Builds the fork prefix there when
 * absent (install-openroad-g6lc.sh from the synced build-platform/scripts, the
 * fork checkout under /opt/testharness/src, -march/PGO from the config, nproc
 * jobs), then yosys map + openroad report. Logs come back on RESULT lines.
 */
async function runRemote(
  ctx: PlatformContext,
  opts: RtlTimingOptions,
  top: string,
  libertyLocal: string,
  libertyForkRel: string | undefined,
  lefForkRels: string[],
  outDir: string,
  pre: SvtPrepass,
): Promise<RtlTimingResult> {
  const stages: RtlTimingResult["stages"] = [pre.stage];
  const result: RtlTimingResult = {
    ok: false, outDir: posixPath(outDir), target: opts.target, top, liberty: posixPath(libertyLocal), stages,
    emitFlist: pre.emitFlist, fo4Budget: opts.fo4Budget, svtTargetMhz: pre.targetMhz,
  };
  if (pre.stage.status === "fail") return result;
  const paths = edaPaths(ctx);
  // The corrected emit must reach the builder: `sync` ships
  // build-platform/workspace/build/sta-rtl/ (testharness_proxy.py
  // SYNC_INCLUDE), so an emit under this out-dir rewrites to the remote
  // checkout like any repo file; one elsewhere cannot be used remotely.
  if (pre.emitFlist && !posixPath(pre.emitFlist).toLowerCase().startsWith(posixPath(join(ctx.paths.build, "sta-rtl")).toLowerCase())) {
    stages.push({
      id: "s0-manifest",
      status: "fail",
      detail: `remote route needs the emit under ${posixPath(join(ctx.paths.build, "sta-rtl"))} (synced); got ${pre.emitFlist} — drop --from-timing and let --fo4 run the pre-pass here`,
    });
    return result;
  }
  const manifest = writeFlatManifest(ctx, paths, opts.target, {
    outSubdir: "sta-rtl", outTag: opts.target, emitFlist: pre.emitFlist,
  });
  let flist: string;
  try {
    flist = toRemotePaths(readFileSync(manifest.path, "utf8"), ctx.repoRoot).replace(/\r/g, "");
  } catch {
    stages.push({ id: "s0-manifest", status: "fail", detail: "could not read the generated manifest" });
    return result;
  }
  const sdcText = buildClockSdc({ clockPort: opts.clockPort, targetMhz: opts.targetMhz, top });
  writeFileSync(join(outDir, "clock.sdc"), sdcText, "utf8");

  // The liberty: the fork's test library on the builder's checkout, or a
  // project file inside the synced repo subset.
  const libRemote = libertyForkRel
    ? `${REMOTE_OPENROAD_SRC}/${libertyForkRel}`
    : toRemotePaths(posixPath(libertyLocal), ctx.repoRoot);
  const lefRemote = lefForkRels.map((r) => `${REMOTE_OPENROAD_SRC}/${r}`).join(" ");
  const or = ctx.config.toolchain.openroad;
  const threads = or.threads > 0 ? String(or.threads) : "$(nproc)";
  const pin = gitlink(ctx, "tools/openroad") ?? "";
  const script = buildMapScript({
    manifest: `$RUN/${opts.target}.f`,
    top,
    liberty: "$LIB",
    netlist: "$RUN/netlist.v",
    defines: ctx.config.verify.synthDefines,
    slangArgs: ctx.config.verify.synthSlangArgsByTarget[opts.target] ?? [],
    recipe: opts.mapRecipe,
  });

  const lines = [
    "set -u",
    `REPO=${REMOTE_REPO}`,
    `OR=${REMOTE_OPENROAD}`,
    `RUN="$HOME/.cache/g6lc-sta/${opts.target}"`,
    'mkdir -p "$RUN"',
    `LIB=${JSON.stringify(libRemote)}`,
    `YS=${REMOTE_FORMAL}/bin/yosys`,
    'if [ ! -x "$YS" ]; then YS="$(command -v yosys || true)"; fi',
    'if [ -z "$YS" ]; then echo "RESULT_TOOLCHAIN fail yosys"; exit 3; fi',
    'if [ ! -f "$LIB" ]; then echo "RESULT_TOOLCHAIN fail liberty $LIB"; exit 3; fi',
    // The fork prefix: build it here with the same script the local recipe
    // uses. nproc jobs saturate the builder; -march/PGO from the config.
    `if [ ! -x "$OR/bin/openroad" ] || [ "${opts.rebuildOpenroad ? 1 : 0}" = 1 ]; then`,
    '  echo "OPENROAD_BUILD start $(date -u +%FT%TZ)"',
    `  REPO_ROOT="$REPO" OPENROAD_SRC=${REMOTE_OPENROAD_SRC} OPENROAD_PIN=${JSON.stringify(pin)} OPENROAD_PREFIX="$OR" \\`,
    `    OPENROAD_PGO=${or.pgo ? 1 : 0} OPENROAD_MARCH=${JSON.stringify(marchValue(ctx))} OPENROAD_CMAKE_ARGS=${JSON.stringify(or.cmakeArgs.join(" "))} \\`,
    `    JOBS=${or.jobs > 0 ? or.jobs : "$(nproc)"} bash "$REPO/build-platform/scripts/install-openroad-g6lc.sh" > "$RUN/openroad-install.log" 2>&1`,
    '  rc=$?; echo "OPENROAD_BUILD rc=$rc $(date -u +%FT%TZ)"; tail -5 "$RUN/openroad-install.log"',
    '  if [ "$rc" != 0 ]; then echo "RESULT_TOOLCHAIN fail openroad"; exit 3; fi',
    "fi",
    '[ -f "$OR/openroad-env.sh" ] && . "$OR/openroad-env.sh"',
    // The fork's sta links from the liberty alone; openroad needs the LEF.
    'STA="$OR/bin/sta"; STA_ARGS="-exit"; if [ ! -x "$STA" ]; then STA="$OR/bin/openroad"; STA_ARGS="-no_init -exit"; fi',
    `LEF=${JSON.stringify(lefRemote)}`,
    'if [ "$STA" = "$OR/bin/openroad" ] && [ -z "$LEF" ]; then echo "RESULT_TOOLCHAIN fail lef"; exit 3; fi',
    `cat > "$RUN/${opts.target}.f" <<'G6LC_FLIST_EOF'`,
    flist,
    "G6LC_FLIST_EOF",
    `cat > "$RUN/clock.sdc" <<'G6LC_SDC_EOF'`,
    sdcText.trimEnd(),
    "G6LC_SDC_EOF",
    'cd "$REPO"',
    `echo "SYNTH start $(date -u +%FT%TZ)"`,
    `/usr/bin/time -f "SYNTH_MEASURE maxrss_kb=%M elapsed_s=%e" "$YS" -p ${JSON.stringify(script)} > "$RUN/synth.log" 2>&1`,
    'rc=$?; echo "SYNTH rc=$rc"; grep -E "SYNTH_MEASURE|Number of cells|Chip area" "$RUN/synth.log" | tail -4',
    'if [ "$rc" != 0 ] || [ ! -s "$RUN/netlist.v" ]; then echo "RESULT fail synth"; echo LOGSTART; tail -40 "$RUN/synth.log"; echo LOGEND; exit 1; fi',
    `echo "STA start $(date -u +%FT%TZ) threads=${threads}"`,
    `OR_LEF="$LEF" OR_LIBERTY="$LIB" OR_VERILOG="$RUN/netlist.v" OR_SDC="$RUN/clock.sdc" OR_TOP=${JSON.stringify(top)} OR_THREADS=${threads} OR_REPORT_DIR="$RUN/reports" \\`,
    '  /usr/bin/time -f "STA_MEASURE maxrss_kb=%M elapsed_s=%e" "$STA" $STA_ARGS "$REPO/build-platform/scripts/openroad-timing.tcl" > "$RUN/sta.log" 2>&1',
    'rc=$?; echo "STA rc=$rc"; grep -E "STA_RESULT|STA_MEASURE" "$RUN/sta.log"',
    'echo LOGSTART; tail -80 "$RUN/sta.log"; echo LOGEND',
    'echo "RESULT $rc"',
  ];

  ctx.logger.info(`sta-rtl: remote via the testharness proxy (${opts.target} → ${top}, liberty ${libRemote})`);
  const res = await runRemoteScript(ctx, lines.join("\n") + "\n", {
    name: `sta-rtl-${opts.target}`,
    // A first run may build the fork (two full builds with PGO).
    budgetSeconds: 4 * 3600,
    sync: true,
  });
  writeFileSync(join(outDir, "remote.log"), res.text, "utf8");
  if (res.error) {
    stages.push({ id: "remote", status: "fail", detail: res.error });
    return result;
  }
  if (/RESULT_TOOLCHAIN fail yosys/.test(res.text)) {
    stages.push({ id: "s1-yosys-map", status: "fail", detail: "no yosys on the builder (install-formal.sh)" });
    return result;
  }
  if (/RESULT_TOOLCHAIN fail liberty/.test(res.text)) {
    stages.push({ id: "s0-liberty", status: "fail", detail: `liberty not on the builder: ${libRemote}` });
    return result;
  }
  if (/RESULT_TOOLCHAIN fail lef/.test(res.text)) {
    stages.push({ id: "s2-openroad-sta", status: "fail", detail: "builder has only the openroad binary and no platform LEF: use --platform, or rebuild the fork prefix (--rebuild-openroad) to get sta" });
    return result;
  }
  if (/RESULT_TOOLCHAIN fail openroad/.test(res.text)) {
    stages.push({ id: "s0-openroad-build", status: "fail", detail: "fork build failed on the builder (openroad-install.log)" });
    return result;
  }
  const build = res.text.match(/^OPENROAD_BUILD rc=(\d+)/m);
  if (build) {
    stages.push({ id: "s0-openroad-build", status: build[1] === "0" ? "pass" : "fail", detail: `built the fork on the builder (march=${marchValue(ctx)}, pgo=${or.pgo})` });
  }
  if (/^RESULT fail synth/m.test(res.text)) {
    const log = res.text.match(/^LOGSTART$([\s\S]*?)^LOGEND$/m);
    stages.push({ id: "s1-yosys-map", status: "fail", detail: `yosys failed on the builder: ${(log?.[1] ?? "").trim().split("\n").slice(-3).join(" | ")}` });
    return result;
  }
  const synthM = res.text.match(/SYNTH_MEASURE maxrss_kb=(\d+) elapsed_s=([\d.]+)/);
  stages.push({ id: "s1-yosys-map", status: "pass", detail: synthM ? `netlist.v on the builder (${synthM[2]} s, ${Math.round(Number(synthM[1]) / 1024)} MiB)` : "netlist.v on the builder" });
  const parsed = parseStaResult(res.text);
  const staRc = res.text.match(/^RESULT (\d+)$/m)?.[1];
  const staM = res.text.match(/STA_MEASURE maxrss_kb=(\d+) elapsed_s=([\d.]+)/);
  if (staRc !== "0" || parsed.wnsMax === undefined) {
    stages.push({ id: "s2-openroad-sta", status: "fail", detail: `openroad rc=${staRc ?? "?"} on the builder (remote.log)` });
    return result;
  }
  stages.push({
    id: "s2-openroad-sta",
    status: "pass",
    detail: `wns_max ${parsed.wnsMax} tns_max ${parsed.tnsMax}${staM ? ` (${staM[2]} s, ${threads} threads)` : ""}`,
  });
  return { ...result, ...parsed, ok: true };
}

function gitlink(ctx: PlatformContext, path: string): string | null {
  try {
    const out = Bun.spawnSync(["git", "-C", ctx.repoRoot, "ls-tree", "HEAD", path], { stdout: "pipe", stderr: "pipe" });
    const m = out.stdout.toString().match(/^\d+ commit ([0-9a-f]+)/);
    return m?.[1] ?? null;
  } catch {
    return null;
  }
}

/** Entry point for `timings sta-rtl`. */
export async function runRtlTiming(ctx: PlatformContext, opts: RtlTimingOptions): Promise<RtlTimingResult> {
  const top = opts.top ?? resolveSynthTop(ctx.config.verify, opts.target);
  // Same resolution as sta-handoff: absolute as given, `workspace/...` under
  // the managed workspace, anything else repo-relative.
  const outDir = !opts.outDir
    ? join(ctx.paths.build, "sta-rtl", opts.target)
    : isAbsolute(opts.outDir)
      ? opts.outDir
      : /^workspace[/\\]/i.test(opts.outDir)
        ? join(ctx.paths.root, opts.outDir.replace(/^workspace[/\\]/i, ""))
        : join(ctx.repoRoot, opts.outDir);
  mkdirSync(outDir, { recursive: true });
  const lib = resolveTimingLiberty(ctx, { liberty: opts.liberty, platform: opts.platform });
  if (!lib) {
    return {
      ok: false, outDir: posixPath(outDir), target: opts.target, top, liberty: "",
      stages: [{ id: "s0-liberty", status: "fail", detail: "no liberty: --liberty, physicalDesign.pdk.liberty, CVA6_LIBERTY, or --platform nangate45|sky130hd|sky130hs|asap7" }],
    };
  }
  if (!opts.remote && !existsSync(lib.path)) {
    return {
      ok: false, outDir: posixPath(outDir), target: opts.target, top, liberty: posixPath(lib.path),
      stages: [{ id: "s0-liberty", status: "fail", detail: `${lib.path} missing (populate tools/openroad: git submodule update --init tools/openroad, or run --remote)` }],
    };
  }
  // sv-timing runs here on both routes: the package is a host tool and the
  // emit is synced to the builder with the rest of the workspace sta-rtl tree.
  const pre = await runSvtPrepass(ctx, opts, outDir);
  if (opts.remote) return runRemote(ctx, opts, top, lib.path, lib.forkRel, lib.lefForkRels, outDir, pre);
  return runLocal(ctx, opts, top, lib.path, lib.lefs, outDir, pre);
}

/** Host core count, for the help text and dry-run lines. */
export function hostCores(): number {
  return Math.max(1, getHostInfo().cpuCount);
}
