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
}

export interface RtlTimingResult {
  ok: boolean;
  outDir: string;
  target: string;
  top: string;
  liberty: string;
  stages: { id: string; status: "pass" | "skip" | "fail"; detail: string }[];
  /** Parsed from the STA_RESULT line of openroad-timing.tcl. */
  wnsMax?: number;
  tnsMax?: number;
  wnsMin?: number;
  tnsMin?: number;
}

/** Fork test platforms that ship a free study liberty. */
const PLATFORM_LIBERTY: Record<string, string> = {
  nangate45: "Nangate45/Nangate45_typ.lib",
  sky130hd: "sky130hd/sky130_fd_sc_hd__tt_025C_1v80.lib",
  sky130hs: "sky130hs/sky130_fd_sc_hs__tt_025C_1v80.lib",
  asap7: "asap7/asap7sc7p5t_AO_RVT_FF_nldm_211120.lib.gz",
};

/** Study-liberty path inside a fork checkout for a platform, or null. */
export function platformLiberty(platform: string | undefined): string | null {
  if (!platform) return null;
  const rel = PLATFORM_LIBERTY[platform.toLowerCase()];
  return rel ? `test/${rel}` : null;
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
): { path: string; source: "explicit" | "pdk" | "env" | "platform"; forkRel?: string } | null {
  if (opts.liberty) {
    const p = isAbsolute(opts.liberty) ? opts.liberty : join(ctx.repoRoot, opts.liberty);
    if (existsSync(p)) return { path: p, source: "explicit" };
  }
  const pdk = ctx.config.physicalDesign?.pdk as { liberty?: string } | undefined;
  if (pdk?.liberty) {
    const p = isAbsolute(pdk.liberty) ? pdk.liberty : join(ctx.repoRoot, pdk.liberty);
    if (existsSync(p)) return { path: p, source: "pdk" };
  }
  if (process.env.CVA6_LIBERTY && existsSync(process.env.CVA6_LIBERTY)) {
    return { path: process.env.CVA6_LIBERTY, source: "env" };
  }
  const rel = platformLiberty(opts.platform ?? ctx.config.soc.process);
  if (rel) {
    const p = join(ctx.repoRoot, "tools", "openroad", rel);
    // The remote route reads it from the builder's fork checkout even when the
    // local submodule is not populated.
    return { path: p, source: "platform", forkRel: rel };
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

/** Yosys script: slang read of the manifest, synth, liberty mapping, netlist. */
export function buildMapScript(opts: {
  manifest: string;
  top: string;
  liberty: string;
  netlist: string;
  defines: string[];
  slangArgs: string[];
}): string {
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
    // Generic synthesis, then the technology mapping STA needs: flops onto the
    // liberty's cells, logic through abc with liberty areas/delays. `-flatten`
    // keeps one timing graph for the fork's report.
    `synth -top ${opts.top} -flatten`,
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

async function toolPath(tool: StaTool, p: string): Promise<string> {
  return tool.viaWsl ? windowsPathToWsl(p) : posixPath(p);
}

/** Local route: managed yosys + managed openroad on this host (WSL on Windows). */
async function runLocal(
  ctx: PlatformContext,
  opts: RtlTimingOptions,
  top: string,
  liberty: string,
  outDir: string,
): Promise<RtlTimingResult> {
  const stages: RtlTimingResult["stages"] = [];
  const paths = edaPaths(ctx);
  const netlist = join(outDir, "netlist.v");
  const sdc = join(outDir, "clock.sdc");
  writeFileSync(sdc, buildClockSdc({ clockPort: opts.clockPort, targetMhz: opts.targetMhz, top }), "utf8");

  const manifest = writeFlatManifest(ctx, paths, opts.target, { outSubdir: "sta-rtl", outTag: opts.target });
  const result: RtlTimingResult = { ok: false, outDir: posixPath(outDir), target: opts.target, top, liberty: posixPath(liberty), stages };

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
  const envPairs = [
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
  outDir: string,
): Promise<RtlTimingResult> {
  const stages: RtlTimingResult["stages"] = [];
  const result: RtlTimingResult = { ok: false, outDir: posixPath(outDir), target: opts.target, top, liberty: posixPath(libertyLocal), stages };
  const paths = edaPaths(ctx);
  const manifest = writeFlatManifest(ctx, paths, opts.target, { outSubdir: "sta-rtl", outTag: opts.target });
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
    `OR_LIBERTY="$LIB" OR_VERILOG="$RUN/netlist.v" OR_SDC="$RUN/clock.sdc" OR_TOP=${JSON.stringify(top)} OR_THREADS=${threads} OR_REPORT_DIR="$RUN/reports" \\`,
    '  /usr/bin/time -f "STA_MEASURE maxrss_kb=%M elapsed_s=%e" "$OR/bin/openroad" -no_init -exit "$REPO/build-platform/scripts/openroad-timing.tcl" > "$RUN/sta.log" 2>&1',
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
  if (opts.remote) return runRemote(ctx, opts, top, lib.path, lib.forkRel, outDir);
  if (!existsSync(lib.path)) {
    return {
      ok: false, outDir: posixPath(outDir), target: opts.target, top, liberty: posixPath(lib.path),
      stages: [{ id: "s0-liberty", status: "fail", detail: `${lib.path} missing (populate tools/openroad: git submodule update --init tools/openroad, or run --remote)` }],
    };
  }
  return runLocal(ctx, opts, top, lib.path, outDir);
}

/** Host core count, for the help text and dry-run lines. */
export function hostCores(): number {
  return Math.max(1, getHostInfo().cpuCount);
}
