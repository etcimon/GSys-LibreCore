// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// clean.test.ts — unit tests for workspace clean inventory / filters / allowlist.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { existsSync, mkdirSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import {
  cleanAllowRoots,
  formatBytes,
  isPathAllowed,
  listCleanTargets,
  measurePath,
  parseDurationMs,
  purposesFromLegacyFlags,
  purposesFromSubcommand,
  removeCleanTargets,
  selectCleanTargets,
  type CleanTarget,
} from "../src/workspace/clean.ts";
import {
  formatTimingsDashboardLines,
  parsePortableFlistPaths,
  resolveTimingsOutputDir,
  summarizeTimingsPackage,
  validateTimingsOutDir,
  writeTimingsDashboard,
  writeTimingsStamp,
} from "../src/tooling/timings.ts";
import {
  buildSeedsSdc,
  listSourcesFromPortableF,
  materializeStaSmokePackage,
  parseOpenStaPathReport,
  runStaHandoff,
} from "../src/tooling/staHandoff.ts";
import { which } from "../src/platform/exec.ts";
import { checkFo4Golden } from "../src/tooling/fo4Golden.ts";
import { parseBenchLog } from "../src/tooling/benchMetrics.ts";
import { buildLabReport, formatLabReportMarkdown } from "../src/tooling/labReport.ts";
import { parseArgs } from "../src/cli/args.ts";
import { readFileSync } from "node:fs";
import type { PlatformContext } from "../src/context.ts";
import type { WorkspacePaths } from "../src/workspace/layout.ts";

const FIX = join(tmpdir(), `cva6-clean-test-${process.pid}`);

function makePaths(root: string): WorkspacePaths {
  return {
    root,
    build: join(root, "build"),
    tooling: join(root, "tooling"),
    toolsBin: join(root, "tooling", "bin"),
    pythonVenv: join(root, "tooling", "python-venv"),
    cache: join(root, ".cache"),
    downloads: join(root, ".cache", "downloads"),
    manifests: join(root, ".cache", "manifests"),
  };
}

function fakeCtx(repoRoot: string, paths: WorkspacePaths): PlatformContext {
  return {
    config: {} as PlatformContext["config"],
    repoRoot,
    host: {} as PlatformContext["host"],
    paths,
    tools: {} as PlatformContext["tools"],
    derived: {} as PlatformContext["derived"],
    logger: {} as PlatformContext["logger"],
    configPath: null,
    overlayPath: null,
    dryRun: false,
  };
}

beforeAll(() => {
  rmSync(FIX, { recursive: true, force: true });
  mkdirSync(join(FIX, "ws", "build", "diagnostics"), { recursive: true });
  mkdirSync(join(FIX, "ws", "build", "sv-timing", "host-cv64a6"), { recursive: true });
  mkdirSync(join(FIX, "ws", "build", "formal", "rob"), { recursive: true });
  mkdirSync(join(FIX, "ws", ".cache", "manifests"), { recursive: true });
  mkdirSync(join(FIX, "ws", "tooling"), { recursive: true });
  mkdirSync(join(FIX, "repo", "work-ver"), { recursive: true });
  mkdirSync(join(FIX, "repo", "sv-timing", "target", "debug"), { recursive: true });
  mkdirSync(join(FIX, "repo", "sv-timing", ".tools", "cargo"), { recursive: true });
  mkdirSync(join(FIX, "repo", "sv-timing", ".sv-timing-out"), { recursive: true });
  writeFileSync(join(FIX, "ws", "build", "diagnostics", "a.f"), "x\n");
  writeFileSync(join(FIX, "ws", "build", "sv-timing", "host-cv64a6", "portable.f"), "core/alu.sv\n");
  writeFileSync(
    join(FIX, "ws", "build", "sv-timing", "host-cv64a6", "analyze.json"),
    JSON.stringify({ schema: "analyze-result.v1", modules: ["alu"] }) + "\n",
  );
  writeFileSync(join(FIX, "ws", "build", "formal", "rob", "log"), "ok\n");
  writeFileSync(join(FIX, "repo", "work-ver", "obj"), "big\n");
  writeFileSync(join(FIX, "repo", "sv-timing", "target", "debug", "deps"), "cargo-out\n");
  writeFileSync(join(FIX, "repo", "sv-timing", ".tools", "cargo", "bin"), "tool\n");
  writeFileSync(join(FIX, "repo", "sv-timing", ".sv-timing-out", "x"), "out\n");
  // Old timings child for age filter
  mkdirSync(join(FIX, "ws", "build", "sv-timing", "old-run"), { recursive: true });
  writeFileSync(join(FIX, "ws", "build", "sv-timing", "old-run", "x"), "y\n");
  const old = (Date.now() - 10 * 86_400_000) / 1000;
  utimesSync(join(FIX, "ws", "build", "sv-timing", "old-run"), old, old);
  utimesSync(join(FIX, "ws", "build", "sv-timing", "old-run", "x"), old, old);
});

afterAll(() => {
  rmSync(FIX, { recursive: true, force: true });
});

test("parseDurationMs accepts d/h/m/s", () => {
  expect(parseDurationMs("7d")).toBe(7 * 86_400_000);
  expect(parseDurationMs("12h")).toBe(12 * 3_600_000);
  expect(parseDurationMs("30m")).toBe(30 * 60_000);
  expect(parseDurationMs("90s")).toBe(90_000);
  expect(parseDurationMs("nope")).toBeNull();
  expect(parseDurationMs("")).toBeNull();
});

test("formatBytes scales", () => {
  expect(formatBytes(500)).toContain("B");
  expect(formatBytes(2048)).toContain("KiB");
  expect(formatBytes(2 * 1024 * 1024)).toContain("MiB");
});

test("isPathAllowed confines to roots", () => {
  const root = join(FIX, "ws");
  expect(isPathAllowed(join(root, "build"), [root])).toBe(true);
  expect(isPathAllowed(join(FIX, "repo", "core"), [root])).toBe(false);
  expect(isPathAllowed(join(FIX, "repo", "work-ver"), [root, join(FIX, "repo", "work-ver")])).toBe(
    true,
  );
});

test("listCleanTargets sees fixture layout", () => {
  const paths = makePaths(join(FIX, "ws"));
  const ctx = fakeCtx(join(FIX, "repo"), paths);
  const inv = listCleanTargets(ctx, { repoSimOutDirs: ["work-ver"] });
  const by = Object.fromEntries(inv.map((t) => [t.purpose, t]));
  expect(by.diag?.present).toBe(true);
  expect(by.timings?.present).toBe(true);
  expect(by.formal?.present).toBe(true);
  expect(by.sim?.present).toBe(true);
  expect(by.tooling?.present).toBe(true);
  expect(measurePath(by.diag!.path).bytes).toBeGreaterThan(0);
  // Multiple targets may share purpose "svt" — pick by label/path
  const svtTargets = inv.filter((t) => t.purpose === "svt");
  expect(svtTargets.some((t) => t.path.endsWith(join("sv-timing", "target")) || t.path.includes(`${"sv-timing"}${"/"}target`) || t.path.includes("sv-timing\\target") || t.path.includes("sv-timing/target"))).toBe(true);
  expect(svtTargets.some((t) => t.present && t.bytes > 0)).toBe(true);
  const svtTools = inv.find((t) => t.purpose === "svt-tools");
  expect(svtTools?.present).toBe(true);
  expect(svtTools?.requiresYes).toBe(true);
});

test("purposesFromSubcommand and legacy flags", () => {
  expect(purposesFromSubcommand("diag")).toEqual(["diag"]);
  expect(purposesFromSubcommand("all")).toEqual(["workspace"]);
  expect(purposesFromSubcommand("status")).toEqual([]);
  expect(purposesFromSubcommand("nope")).toBeNull();
  expect(purposesFromSubcommand("svt")).toEqual(["svt"]);
  expect(purposesFromSubcommand("rust-target")).toEqual(["svt"]);
  expect(purposesFromSubcommand("sv-timing-target")).toEqual(["svt"]);
  expect(purposesFromSubcommand("svt-tools")).toEqual(["svt-tools"]);
  expect(purposesFromLegacyFlags({})).toEqual(["build"]);
  expect(purposesFromLegacyFlags({ tooling: true, cache: true })).toEqual([
    "build",
    "tooling",
    "cache",
  ]);
  expect(purposesFromLegacyFlags({ all: true })).toEqual(["workspace"]);
});

test("cleanAllowRoots permits sv-timing/target but not crates", () => {
  const paths = makePaths(join(FIX, "ws"));
  const repo = join(FIX, "repo");
  const allow = cleanAllowRoots(paths, repo, ["work-ver"]);
  const target = join(repo, "sv-timing", "target");
  const crates = join(repo, "sv-timing", "crates");
  expect(isPathAllowed(target, allow)).toBe(true);
  expect(isPathAllowed(join(target, "debug"), allow)).toBe(true);
  expect(isPathAllowed(crates, allow)).toBe(false);
  expect(isPathAllowed(join(repo, "sv-timing"), allow)).toBe(false);
});

test("removeCleanTargets can dry-run svt cargo target", async () => {
  const paths = makePaths(join(FIX, "ws"));
  const repo = join(FIX, "repo");
  const allow = cleanAllowRoots(paths, repo, ["work-ver"]);
  const inv = listCleanTargets(fakeCtx(repo, paths), { repoSimOutDirs: ["work-ver"] });
  const { selected } = selectCleanTargets(inv, ["svt"]);
  expect(selected.length).toBeGreaterThan(0);
  const results = await removeCleanTargets(selected, {
    dryRun: true,
    yes: false,
    allowRoots: allow,
  });
  expect(results.every((r) => r.status === "would-remove" || r.status === "skipped-missing")).toBe(
    true,
  );
  expect(results.some((r) => r.path.includes("target") && r.status === "would-remove")).toBe(true);
  // Source still present after dry-run
  expect(existsSync(join(repo, "sv-timing", "target", "debug", "deps"))).toBe(true);
});

test("selectCleanTargets filters by --target on children", () => {
  const paths = makePaths(join(FIX, "ws"));
  const ctx = fakeCtx(join(FIX, "repo"), paths);
  const inv = listCleanTargets(ctx);
  const { selected, skipped } = selectCleanTargets(inv, ["timings"], {
    target: "cv64a6",
  });
  expect(selected.some((t) => t.path.includes("host-cv64a6"))).toBe(true);
  expect(selected.every((t) => t.path.toLowerCase().includes("cv64a6"))).toBe(true);
  expect(skipped.some((s) => s.status === "skipped-filter")).toBe(true);
});

test("selectCleanTargets --older-than keeps only old children", () => {
  const paths = makePaths(join(FIX, "ws"));
  const ctx = fakeCtx(join(FIX, "repo"), paths);
  const inv = listCleanTargets(ctx);
  const { selected } = selectCleanTargets(inv, ["timings"], {
    olderThanMs: 5 * 86_400_000,
  });
  expect(selected.some((t) => t.path.includes("old-run"))).toBe(true);
  // host-cv64a6 is fresh — should not be selected
  expect(selected.some((t) => t.path.includes("host-cv64a6"))).toBe(false);
});

test("removeCleanTargets dry-run and yes-gate", async () => {
  const paths = makePaths(join(FIX, "ws"));
  const allow = cleanAllowRoots(paths, join(FIX, "repo"), ["work-ver"]);
  const target: CleanTarget = {
    purpose: "tooling",
    path: paths.tooling,
    label: "tooling",
    present: true,
    bytes: 1,
    mtimeMs: Date.now(),
    requiresYes: true,
    rootKind: "workspace",
  };
  const refused = await removeCleanTargets([target], {
    dryRun: false,
    yes: false,
    allowRoots: allow,
  });
  expect(refused[0]?.status).toBe("refused");
  expect(refused[0]?.detail).toContain("--yes");

  const would = await removeCleanTargets([target], {
    dryRun: true,
    yes: false,
    allowRoots: allow,
  });
  expect(would[0]?.status).toBe("would-remove");
});

test("removeCleanTargets refuses path outside allowlist", async () => {
  const evil: CleanTarget = {
    purpose: "sim",
    path: join(FIX, "repo", "core-secret"),
    label: "evil",
    present: true,
    bytes: 0,
    mtimeMs: null,
    requiresYes: true,
    rootKind: "repo-sim",
  };
  mkdirSync(evil.path, { recursive: true });
  writeFileSync(join(evil.path, "x"), "nope");
  const r = await removeCleanTargets([evil], {
    dryRun: false,
    yes: true,
    allowRoots: [join(FIX, "ws")],
  });
  expect(r[0]?.status).toBe("refused");
  expect(existsSync(join(evil.path, "x"))).toBe(true);
});

test("parsePortableFlistPaths skips directives", () => {
  const paths = parsePortableFlistPaths(
    "# c\n+incdir+/x\n// y\n/abs/a.sv\ncore/b.sv\n",
  );
  expect(paths).toEqual(["/abs/a.sv", "core/b.sv"]);
});

test("validateTimingsOutDir accepts fixture host-cv64a6", () => {
  const paths = makePaths(join(FIX, "ws"));
  const ctx = fakeCtx(join(FIX, "repo"), paths);
  const dir = join(FIX, "ws", "build", "sv-timing", "host-cv64a6");
  const result = validateTimingsOutDir(ctx, {
    fromTiming: dir,
    checkSourcePaths: false,
  });
  expect(result.ok).toBe(true);
  expect(result.portableF).toBeTruthy();
  expect(result.reportJson).toBeTruthy();
  expect(result.schemaHint).toBe("analyze-result.v1");
  expect(result.fileCount).toBe(1);
});

test("validateTimingsOutDir fails missing dir", () => {
  const paths = makePaths(join(FIX, "ws"));
  const ctx = fakeCtx(join(FIX, "repo"), paths);
  const result = validateTimingsOutDir(ctx, {
    fromTiming: join(FIX, "no-such-dir"),
  });
  expect(result.ok).toBe(false);
  expect(result.issues.some((i) => i.code === "dir-missing")).toBe(true);
});

test("validateTimingsOutDir requireEmit", () => {
  const paths = makePaths(join(FIX, "ws"));
  const ctx = fakeCtx(join(FIX, "repo"), paths);
  const dir = join(FIX, "ws", "build", "sv-timing", "host-cv64a6");
  const result = validateTimingsOutDir(ctx, {
    fromTiming: dir,
    requireEmit: true,
    checkSourcePaths: false,
  });
  expect(result.ok).toBe(false);
  expect(result.issues.some((i) => i.code === "emit-missing")).toBe(true);
});

test("resolveTimingsOutputDir lays out compile package paths", () => {
  const paths = makePaths(join(FIX, "ws"));
  const ctx = fakeCtx(join(FIX, "repo"), paths);
  const layout = resolveTimingsOutputDir(ctx, join(FIX, "ws", "build", "sv-timing", "pack"), {
    tag: "host-x",
  });
  expect(layout.portableF.endsWith("portable.f")).toBe(true);
  expect(layout.analyzeJson.endsWith("analyze.json")).toBe(true);
  expect(layout.cache.endsWith("ir.sqlite")).toBe(true);
  expect(layout.correctedDir.endsWith("corrected")).toBe(true);
  writeTimingsStamp(layout, {
    kind: "compile",
    target: "cv64",
    command: "test",
    exitCode: 0,
    mtimeMs: Date.now(),
    portableF: layout.portableF,
    reportJson: layout.analyzeJson,
  });
  expect(existsSync(layout.stamp)).toBe(true);
});

test("parseArgs supports --output and -o value", () => {
  const a = parseArgs(["timings", "compile", "--output", "out/t1", "--modules", "alu"]);
  expect(a.flags.output).toBe("out/t1");
  const b = parseArgs(["timings", "compile", "-o", "out/t2", "--all-modules"]);
  expect(b.flags.output).toBe("out/t2");
});

test("summarizeTimingsPackage builds soak dashboard from analyze.json", () => {
  const paths = makePaths(join(FIX, "ws"));
  const ctx = fakeCtx(join(FIX, "repo"), paths);
  const dir = join(FIX, "ws", "build", "sv-timing", "host-cv64a6");
  // Richer analyze.json for dashboard fields
  writeFileSync(
    join(dir, "analyze.json"),
    JSON.stringify({
      schema_version: "1",
      disclaimer: "structural FO4 — not STA",
      target_mhz: 1250,
      fo4_ps: 20,
      budget_fo4: 40,
      paths: [
        {
          path_id: 1,
          path_kind: "reg_to_reg",
          startpoint: "a",
          endpoint: "b",
          total_fo4: 55,
          slack_fo4: -15,
          max_freq_mhz: 900,
          closes: false,
        },
        {
          path_id: 2,
          path_kind: "in_to_out",
          startpoint: "in",
          endpoint: "out",
          total_fo4: 10,
          slack_fo4: 30,
          max_freq_mhz: 2000,
          closes: true,
        },
      ],
      modules: [{ name: "alu" }],
      opportunities: [{}],
      sta_hints: [{ kind: "pipeline" }],
      frequency_closure: {
        closes: false,
        target_mhz: 1250,
        budget_fo4: 40,
        max_freq_mhz: 900,
        worst_slack_fo4: -15,
        worst_path_fo4: 55,
        worst_startpoint: "a",
        worst_endpoint: "b",
        failing_paths: 1,
      },
      ast: { kind: "timing_ir_v0", files_parsed: 3, path_count: 2, module_count: 1 },
    }) + "\n",
  );
  const dash = summarizeTimingsPackage(ctx, dir);
  expect(dash.ok).toBe(true);
  expect(dash.pathCount).toBe(2);
  expect(dash.moduleCount).toBe(1);
  expect(dash.closes).toBe(false);
  expect(dash.hottest[0]?.totalFo4).toBe(55);
  expect(dash.hottest[0]?.start).toBe("a");
  const lines = formatTimingsDashboardLines(dash);
  expect(lines.some((l) => l.includes("hottest"))).toBe(true);
  expect(lines.some((l) => l.includes("MISS") || l.includes("closure"))).toBe(true);
  writeTimingsDashboard(dir, dash);
  expect(existsSync(join(dir, "soak-dashboard.json"))).toBe(true);
});

test("runStaHandoff S0 writes seeds.sdc and correlate scaffold", async () => {
  const paths = makePaths(join(FIX, "ws"));
  const ctx = fakeCtx(join(FIX, "repo"), paths);
  const dir = join(FIX, "ws", "build", "sv-timing", "host-cv64a6");
  writeFileSync(join(dir, "portable.f"), "core/x.sv\n");
  writeFileSync(
    join(dir, "analyze.json"),
    JSON.stringify({
      schema_version: "1",
      disclaimer: "structural FO4",
      target_mhz: 1250,
      paths: [
        {
          path_id: 7,
          path_kind: "reg_to_reg",
          startpoint: "u_a/q",
          endpoint: "u_b/d",
          total_fo4: 33,
          slack_fo4: -3,
          max_freq_mhz: 1000,
          closes: false,
        },
      ],
      sta_hints: [{ from: "u_a/q", to: "u_b/d", sdc_comment: "seed" }],
      modules: [],
      opportunities: [],
      frequency_closure: {
        closes: false,
        target_mhz: 1250,
        budget_fo4: 40,
        max_freq_mhz: 1000,
        worst_slack_fo4: -3,
        worst_path_fo4: 33,
        worst_startpoint: "u_a/q",
        worst_endpoint: "u_b/d",
        failing_paths: 1,
      },
      ast: { kind: "timing_ir_v0", files_parsed: 1 },
    }) + "\n",
  );
  const out = join(FIX, "ws", "build", "sta-handoff", "unit");
  const result = await runStaHandoff(ctx, {
    fromTiming: dir,
    outDir: out,
    tryTools: false,
  });
  expect(result.ok).toBe(true);
  expect(existsSync(join(out, "seeds.sdc"))).toBe(true);
  expect(existsSync(join(out, "fo4_paths.csv"))).toBe(true);
  expect(existsSync(join(out, "correlate.json"))).toBe(true);
  const sdc = readFileSync(join(out, "seeds.sdc"), "utf8");
  expect(sdc).toContain("REVIEW-ONLY");
  expect(sdc).toContain("create_clock");
  expect(sdc).toContain("u_a/q");
  const seeds = buildSeedsSdc({
    targetMhz: 1000,
    rows: [
      {
        rank: 1,
        pathId: 1,
        totalFo4: 1,
        slackFo4: 0,
        maxFreqMhz: 1000,
        kind: "reg_to_reg",
        start: "a",
        end: "b",
        closes: true,
      },
    ],
    sourceDir: "/tmp/x",
  });
  expect(seeds).toContain("period");
});

test("materializeStaSmokePackage + S1 when yosys present", async () => {
  const paths = makePaths(join(FIX, "ws"));
  const ctx = fakeCtx(join(FIX, "repo"), paths);
  // Point repoRoot at real repo so fixture paths resolve
  const { loadConfig } = await import("../src/config/load.ts");
  const { config, repoRoot } = await loadConfig();
  const realCtx = {
    ...ctx,
    config,
    repoRoot,
    paths: makePaths(join(FIX, "ws")),
  };
  const pkg = join(FIX, "ws", "build", "sv-timing", "sta-smoke-unit");
  const mat = materializeStaSmokePackage(realCtx as typeof ctx, pkg);
  expect(existsSync(mat.portableF)).toBe(true);
  const out = join(FIX, "ws", "build", "sta-handoff", "sta-smoke-unit");
  const result = await runStaHandoff(realCtx as typeof ctx, {
    fromTiming: pkg,
    outDir: out,
    tryTools: true,
    top: "comb_adder",
  });
  expect(result.ok).toBe(true);
  expect(existsSync(join(out, "seeds.sdc"))).toBe(true);
  const yosys =
    which("yosys") ||
    (existsSync(
      join(
        repoRoot,
        "build-platform",
        "workspace",
        "tooling",
        "oss-cad-suite",
        "bin",
        process.platform === "win32" ? "yosys.exe" : "yosys",
      ),
    )
      ? "managed"
      : null);
  if (yosys) {
    // Managed yosys is used via edaPaths when suite is installed
    const s1 = result.stages.find((s) => s.id === "s1-yosys-synth");
    // pass or fail or skip — must not crash; if pass, netlist exists
    expect(s1).toBeTruthy();
    if (s1?.status === "pass") {
      expect(existsSync(join(out, "synth", "netlist.v"))).toBe(true);
    }
  } else {
    const s1 = result.stages.find((s) => s.id === "s1-yosys-synth");
    expect(s1?.status === "skip" || s1?.status === "fail").toBe(true);
  }
});

test("injectStaFixture fills correlate overlap_score offline", async () => {
  const { loadConfig } = await import("../src/config/load.ts");
  const { config, repoRoot } = await loadConfig();
  const paths = makePaths(join(FIX, "ws"));
  const ctx = { ...fakeCtx(repoRoot, paths), config };
  const pkg = join(FIX, "ws", "build", "sv-timing", "inject-sta-unit");
  const mat = materializeStaSmokePackage(ctx, pkg);
  const out = join(FIX, "ws", "build", "sta-handoff", "inject-sta-unit");
  const hand = await runStaHandoff(ctx, {
    fromTiming: mat.dir,
    outDir: out,
    tryTools: false,
    top: "comb_adder",
    injectStaFixture: true,
  });
  expect(hand.ok).toBe(true);
  expect(existsSync(join(out, "opensta", "paths.rpt"))).toBe(true);
  const corr = JSON.parse(
    readFileSync(join(out, "correlate.json"), "utf8"),
  ) as { overlap_score: number | null; sta_rank: unknown[] };
  expect(corr.sta_rank.length).toBeGreaterThanOrEqual(1);
  expect(corr.overlap_score).not.toBeNull();
  expect(corr.overlap_score!).toBeGreaterThan(0);
  expect(
    hand.stages.some(
      (s) => s.id === "s2-opensta-fixture" && s.status === "pass",
    ),
  ).toBe(true);

  // Re-run still injects (overwrite) and keeps numeric overlap_score.
  const hand2 = await runStaHandoff(ctx, {
    fromTiming: mat.dir,
    outDir: out,
    tryTools: false,
    top: "comb_adder",
    injectStaFixture: true,
  });
  expect(
    hand2.stages.some(
      (s) => s.id === "s2-opensta-fixture" && s.status === "pass",
    ),
  ).toBe(true);

  // --no-sta-fixture drops synthetic leftover → FO4-only correlate.
  const hand3 = await runStaHandoff(ctx, {
    fromTiming: mat.dir,
    outDir: out,
    tryTools: false,
    top: "comb_adder",
    injectStaFixture: false,
  });
  const corr3 = JSON.parse(
    readFileSync(join(out, "correlate.json"), "utf8"),
  ) as { overlap_score: number | null; sta_rank: unknown[] };
  expect(corr3.sta_rank.length).toBe(0);
  expect(
    hand3.stages.some((s) => s.id === "s3-correlate" && s.status === "skip"),
  ).toBe(true);
});

test("checkFo4Golden matches sta_smoke fixture", async () => {
  const { loadConfig } = await import("../src/config/load.ts");
  const { repoRoot } = await loadConfig();
  const fix = join(repoRoot, "verif/sv-timing-tests/fixtures/sta_smoke");
  // Package dir = fixture itself (has analyze + golden)
  const r = checkFo4Golden(fix);
  expect(r.ok).toBe(true);
  expect(r.compared).toBe(2);
});

test("buildLabReport markdown includes golden and stages", async () => {
  const { loadConfig } = await import("../src/config/load.ts");
  const { config, repoRoot } = await loadConfig();
  const paths = makePaths(join(FIX, "ws"));
  const ctx = fakeCtx(repoRoot, paths);
  ctx.config = config;
  const pkg = join(FIX, "ws", "build", "sv-timing", "lab-report-unit");
  const { materializeStaSmokePackage, runStaHandoff } = await import(
    "../src/tooling/staHandoff.ts"
  );
  const mat = materializeStaSmokePackage(ctx, pkg);
  const gold = checkFo4Golden(mat.dir);
  const hand = await runStaHandoff(ctx, {
    fromTiming: mat.dir,
    outDir: join(FIX, "ws", "build", "sta-handoff", "lab-report-unit"),
    tryTools: false,
    top: "comb_adder",
  });
  const report = buildLabReport({
    packageDir: mat.dir,
    handoffDir: hand.outDir,
    golden: gold,
    handoff: hand,
  });
  expect(report.ok).toBe(true);
  const md = formatLabReportMarkdown(report);
  expect(md).toContain("FO4 golden");
  expect(md).toContain("s0-sdc-seeds");
});

test("parseBenchLog extracts CoreMark and Dhrystone markers", () => {
  const cm = parseBenchLog(`
CoreMark Size    : 666
Iterations       : 1000
Iterations/Sec   : 12.5
CoreMark/MHz 1.0 : 3.14 / source
`);
  expect(cm.CVA6_BENCH_ITERATIONS).toBe(1000);
  expect(cm.CVA6_BENCH_SCORE).toBe(3.14);
  const dh = parseBenchLog("Result: 1.23 DMIPS (Dhrystones per Second: 2200)\n");
  expect(dh.CVA6_BENCH_DMIPS).toBe(1.23);
});

test("listSourcesFromPortableF and parseOpenStaPathReport", () => {
  const pf = join(FIX, "ws", "build", "portable-unit.f");
  const src = join(FIX, "ws", "build", "unit.v");
  writeFileSync(src, "module m; endmodule\n");
  writeFileSync(pf, `# c\n${src}\n+incdir+/x\n`);
  const files = listSourcesFromPortableF(pf);
  expect(files.some((f) => f.includes("unit.v"))).toBe(true);
  const rpt = `
Startpoint: u_a/q
Endpoint: u_b/d
  slack (VIOLATED) -0.12
Startpoint: a
Endpoint: b
  slack (MET) 0.05
`;
  const rows = parseOpenStaPathReport(rpt);
  expect(rows.length).toBeGreaterThanOrEqual(1);
  expect(rows[0]?.start).toBe("u_a/q");
});

test("selectCleanTargets --execution failed/ok uses stamp.json", () => {
  const paths = makePaths(join(FIX, "ws"));
  const ctx = fakeCtx(join(FIX, "repo"), paths);
  // stamps under timings children
  const okDir = join(FIX, "ws", "build", "sv-timing", "host-cv64a6");
  const failDir = join(FIX, "ws", "build", "sv-timing", "old-run");
  writeFileSync(
    join(okDir, "stamp.json"),
    JSON.stringify({ exitCode: 0, mtimeMs: Date.now(), kind: "compile" }) + "\n",
  );
  writeFileSync(
    join(failDir, "stamp.json"),
    JSON.stringify({ exitCode: 3, mtimeMs: Date.now() - 1000, kind: "compile" }) + "\n",
  );
  const inv = listCleanTargets(ctx);
  const failed = selectCleanTargets(inv, ["timings"], { execution: "failed" });
  expect(failed.selected.some((t) => t.path.includes("old-run"))).toBe(true);
  expect(failed.selected.every((t) => !t.path.includes("host-cv64a6") || t.path.endsWith("old-run"))).toBe(
    true,
  );
  const ok = selectCleanTargets(inv, ["timings"], { execution: "ok" });
  expect(ok.selected.some((t) => t.path.includes("host-cv64a6"))).toBe(true);
  expect(ok.selected.some((t) => t.path.includes("old-run"))).toBe(false);
});
