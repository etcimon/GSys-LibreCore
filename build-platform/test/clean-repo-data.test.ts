// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// clean-repo-data.test.ts — repo-level clean purposes (traces / runs /
// repo-cache / regen): holds, tag families, trace-only removal, allowlist.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { gunzipSync } from "node:zlib";

import { DEFAULT_CONFIG } from "../src/config/defaults.ts";
import {
  cleanAllowRoots,
  collectCitedTags,
  listRepoDataTargets,
  purposesFromSubcommand,
  removeCleanTargets,
  runFamily,
  selectCleanTargets,
  type CleanTarget,
} from "../src/workspace/clean.ts";
import type { WorkspacePaths } from "../src/workspace/layout.ts";

const FIX = join(tmpdir(), `cva6-clean-repo-test-${process.pid}`);
// Holds never expire in the base fixture; the expiry test sets its own ages.
const CFG = {
  ...DEFAULT_CONFIG.workspace.clean,
  regenerableDirs: ["pkg/target"],
  citedMaxAgeDays: 0,
  keptMaxAgeDays: 0,
  logCompressMinMiB: 0.001,
};
const DAY = 86_400_000;
const NOW = Date.now();

function put(rel: string, body: string, ageDays: number): void {
  const p = join(FIX, rel);
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, body);
  const t = (NOW - ageDays * DAY) / 1000;
  utimesSync(p, t, t);
}

function age(rel: string, ageDays: number): void {
  const t = (NOW - ageDays * DAY) / 1000;
  utimesSync(join(FIX, rel), t, t);
}

function inventory(cited = new Set<string>()): CleanTarget[] {
  return listRepoDataTargets(FIX, CFG, cited, NOW);
}

beforeAll(() => {
  rmSync(FIX, { recursive: true, force: true });
  // family "soak": r1 oldest .. r4 newest, all stale
  for (const [i, d] of [[1, 40], [2, 30], [3, 20], [4, 10]] as const) {
    put(`remote-runs/soak-r${i}/output/trial/trace_hart_0.dasm`, "T".repeat(1000), d);
    put(`remote-runs/soak-r${i}/output/trial/iti.traces`, "I".repeat(500), d);
    put(`remote-runs/soak-r${i}/output/trial/run.log`, "log\n", d);
    put(`remote-runs/soak-r${i}/output/results.json`, "{}\n", d);
    for (const sub of ["output/trial", "output", ""]) age(`remote-runs/soak-r${i}/${sub}`, d);
  }
  // an active run (written today) and a cited evidence run
  put("remote-runs/live-r1/output/trace_hart_0.dasm", "L".repeat(800), 0);
  put("remote-runs/evid-r1/output/trace_hart_0.dasm", "E".repeat(800), 15);
  age("remote-runs/evid-r1/output", 15);
  age("remote-runs/evid-r1", 15);
  // protected manifests dir
  put("remote-runs/builds/work-ver.manifest.json", "{}\n", 60);
  age("remote-runs/builds", 60);
  // repo-root scratch cache: one stale, one active
  put(".cache/old-scratch/a.bin", "x".repeat(300), 20);
  age(".cache/old-scratch", 20);
  put(".cache/apu-guest/b.bin", "y".repeat(300), 0);
  // regenerable build dir
  put("pkg/target/debug/deps.o", "z".repeat(200), 20);
  age("pkg/target/debug", 20);
  age("pkg/target", 20);
});

afterAll(() => {
  rmSync(FIX, { recursive: true, force: true });
});

test("runFamily strips repeat counters, timestamps and old/new markers", () => {
  expect(runFamily("ooocoh-n1d-int2l3-r16-24M-L0-r4")).toBe("ooocoh-n1d-int2l3-r16-24M-L0");
  expect(runFamily("l2-equiv-20260926T153816-28d7daa7e28d")).toBe("l2-equiv");
  expect(runFamily("ooocoh-t17-smt2-osbi-old")).toBe("ooocoh-t17-smt2-osbi");
  expect(runFamily("ooocoh-t17-int2l3-r16-24M")).toBe("ooocoh-t17-int2l3-r16-24M");
});

test("subcommand aliases map to repo-level purposes", () => {
  expect(purposesFromSubcommand("traces")).toEqual(["traces"]);
  expect(purposesFromSubcommand("remote-runs")).toEqual(["runs"]);
  expect(purposesFromSubcommand("compress-logs")).toEqual(["logs"]);
  expect(purposesFromSubcommand("stale")).toEqual(["traces", "runs", "logs", "repo-cache", "regen"]);
});

test("family heads expire; expired cited runs lose traces but are never deleted", () => {
  const cfg = { ...CFG, citedMaxAgeDays: 12, keptMaxAgeDays: 15 };
  const inv = listRepoDataTargets(FIX, cfg, new Set(["evid-r1"]), NOW);
  const tagsOf = (ts: CleanTarget[]) => ts.map((t) => t.path.split(/[\\/]/).pop()).sort();
  // soak-r3 (20d) outlives keptMaxAgeDays; soak-r4 (10d) stays kept, live-r1
  // stays active, and evid-r1 (cited, 15d) is evidence: never a whole-run target.
  expect(tagsOf(selectCleanTargets(inv, ["runs"]).selected)).toEqual(["soak-r1", "soak-r2", "soak-r3"]);
  // ...but its trace dumps are, once past citedMaxAgeDays.
  expect(tagsOf(selectCleanTargets(inv, ["traces"]).selected)).toContain("evid-r1");
  const fresh = listRepoDataTargets(FIX, { ...cfg, citedMaxAgeDays: 30 }, new Set(["evid-r1"]), NOW);
  expect(tagsOf(selectCleanTargets(fresh, ["traces"]).selected)).not.toContain("evid-r1");
});

test("logs: big logs gzip in place, cited runs included, mtimes preserved", async () => {
  const big = "line of simulator output\n".repeat(200);
  put("remote-runs/gz-r1/output/run.log", big, 15);
  put("remote-runs/gz-r1/output/small.log", "x\n", 15);
  put("remote-runs/gz-r1/output/results.json", "{}\n", 15);
  age("remote-runs/gz-r1/output", 15);
  age("remote-runs/gz-r1", 15);
  put("remote-runs/gz-live/run.log", big, 0);
  const inv = listRepoDataTargets(FIX, CFG, new Set(["gz-r1"]), NOW);
  const { selected } = selectCleanTargets(inv, ["logs"]);
  const part = selected.find((t) => t.path.endsWith("gz-r1"))!;
  expect(part.files!.map((f) => f.split(/[\\/]/).pop())).toEqual(["run.log"]);
  expect(selected.some((t) => t.path.endsWith("gz-live"))).toBe(false);

  const paths = { root: join(FIX, "ws") } as WorkspacePaths;
  const allow = cleanAllowRoots(paths, FIX, [], CFG);
  const dirBefore = statSync(join(FIX, "remote-runs/gz-r1/output")).mtimeMs;
  const [res] = await removeCleanTargets([part], { dryRun: false, yes: true, allowRoots: allow });
  expect(res!.status).toBe("compressed");
  expect(res!.bytes).toBeGreaterThan(0);
  const gz = join(FIX, "remote-runs/gz-r1/output/run.log.gz");
  expect(existsSync(join(FIX, "remote-runs/gz-r1/output/run.log"))).toBe(false);
  expect(gunzipSync(readFileSync(gz)).toString()).toBe(big);
  expect(existsSync(join(FIX, "remote-runs/gz-r1/output/small.log"))).toBe(true);
  expect(Math.abs(statSync(gz).mtimeMs - (NOW - 15 * DAY))).toBeLessThan(2000);
  expect(Math.abs(statSync(join(FIX, "remote-runs/gz-r1/output")).mtimeMs - dirBefore)).toBeLessThan(2000);
  // a compressed run is not offered again
  const again = selectCleanTargets(listRepoDataTargets(FIX, CFG, new Set(), NOW), ["logs"]).selected;
  expect(again.some((t) => t.path.endsWith("gz-r1"))).toBe(false);
  for (const r of ["gz-r1", "gz-live"]) rmSync(join(FIX, "remote-runs", r), { recursive: true, force: true });
});

test("collectCitedTags finds run tags in tracked text", () => {
  put("docs/log.md", "evidence: remote-runs/evid-r1/output/run.log\n", 1);
  const cited = collectCitedTags(FIX, ["docs/log.md", "src/x.bin"], ["evid-r1", "soak-r1"], [".md"]);
  expect([...cited]).toEqual(["evid-r1"]);
});

test("traces: active and cited runs held; builds/ never listed", () => {
  const inv = inventory(new Set(["evid-r1"]));
  const traces = inv.find((t) => t.purpose === "traces")!;
  const byTag = (tag: string) => traces.parts!.find((p) => p.path.endsWith(tag));
  expect(byTag("live-r1")!.hold).toBe("active");
  expect(byTag("evid-r1")!.hold).toBe("cited");
  expect(byTag("soak-r1")!.hold).toBeUndefined();
  expect(traces.parts!.some((p) => p.path.includes("builds"))).toBe(false);
  // only trace suffixes are selected, never logs/results
  for (const f of byTag("soak-r1")!.files!) expect(/\.(dasm|traces)$/.test(f)).toBe(true);
  // reclaimable bytes = the 4 stale soak runs only
  expect(traces.bytes).toBe(4 * 1500);
});

test("runs: newest keepRunsPerFamily kept, older superseded runs selectable", () => {
  const { selected } = selectCleanTargets(inventory(new Set(["evid-r1"])), ["runs"]);
  const tags = selected.map((t) => t.path.split(/[\\/]/).pop()).sort();
  expect(tags).toEqual(["soak-r1", "soak-r2"]);
  const lifted = selectCleanTargets(inventory(new Set(["evid-r1"])), ["runs"], { includeCited: true });
  expect(lifted.selected.length).toBe(5); // + soak-r3/r4 (kept) + evid-r1 (cited); live stays active
});

test("repo-cache and regen hold recently modified entries", () => {
  const inv = inventory();
  const cache = selectCleanTargets(inv, ["repo-cache"]).selected.map((t) => t.label);
  expect(cache).toEqual([".cache/old-scratch"]);
  expect(selectCleanTargets(inv, ["regen"]).selected.map((t) => t.label)).toEqual(["pkg/target"]);
  expect(
    selectCleanTargets(inv, ["repo-cache"], { includeActive: true }).selected.length,
  ).toBe(2);
});

test("removal deletes trace files only, inside the allowlist", async () => {
  const paths = { root: join(FIX, "ws") } as WorkspacePaths;
  const allow = cleanAllowRoots(paths, FIX, [], CFG);
  const { selected } = selectCleanTargets(inventory(new Set(["evid-r1"])), ["traces"]);
  const res = await removeCleanTargets(selected, { dryRun: false, yes: true, allowRoots: allow });
  expect(res.every((r) => r.status === "removed")).toBe(true);
  expect(existsSync(join(FIX, "remote-runs/soak-r1/output/trial/trace_hart_0.dasm"))).toBe(false);
  expect(existsSync(join(FIX, "remote-runs/soak-r1/output/trial/run.log"))).toBe(true);
  expect(existsSync(join(FIX, "remote-runs/soak-r1/output/results.json"))).toBe(true);
  expect(existsSync(join(FIX, "remote-runs/evid-r1/output/trace_hart_0.dasm"))).toBe(true);
  expect(existsSync(join(FIX, "remote-runs/live-r1/output/trace_hart_0.dasm"))).toBe(true);
  // without the repo-level roots the same targets are refused
  const refused = await removeCleanTargets(
    [{ ...selected[0]!, files: [join(FIX, "remote-runs/soak-r2/output/trial/run.log")] }],
    { dryRun: false, yes: true, allowRoots: [paths.root] },
  );
  expect(refused[0]!.status).toBe("refused");
  expect(existsSync(join(FIX, "remote-runs/soak-r2/output/trial/run.log"))).toBe(true);
});
