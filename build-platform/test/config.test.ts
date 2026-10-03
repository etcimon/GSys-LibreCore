// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// config.test.ts — Fast sanity checks for config resolution (always run).

import { expect, test } from "bun:test";

import { loadConfig } from "../src/config/load.ts";
import { deepMerge } from "../src/util/object.ts";
import { DEFAULT_SYNTH_PASSES, resolveSynthTop } from "../src/tooling/eda.ts";

test("config resolves and validates", async () => {
  const { config, repoRoot } = await loadConfig();
  expect(repoRoot.length).toBeGreaterThan(0);
  expect(config.soc.coreConfig.length).toBeGreaterThan(0);
  expect(config.simulation.enabled).toContain(config.simulation.default);
  for (const id of config.tests.defaultSuites) {
    expect(config.tests.suites.some((s) => s.id === id)).toBe(true);
  }
});

test("AI policy validation compartments stay optional", async () => {
  const { config } = await loadConfig();
  for (const id of ["ai-policy-codec", "ai-policy-subcode", "ai-policy-calibration"]) {
    const suite = config.tests.suites.find((s) => s.id === id);
    expect(suite?.script).toBe(`verif/regress/${id}.sh`);
    expect(suite?.optional).toBe(true);
    expect(suite?.tools).toEqual([]);
    expect(config.tests.defaultSuites).not.toContain(id);
  }
});

test("AI native evaluation and scalar floating gates stay optional", async () => {
  const { config } = await loadConfig();
  for (const id of ["ai-native-eval", "ai-desc-formats", "ai-fp-mac"]) {
    const suite = config.tests.suites.find((s) => s.id === id);
    expect(suite?.script).toBe(`verif/regress/${id}.sh`);
    expect(suite?.optional).toBe(true);
    expect(suite?.tools).toEqual([]);
    expect(config.tests.defaultSuites).not.toContain(id);
  }
});

test("deepMerge overrides scalars and arrays but merges objects", () => {
  const base = { a: 1, nested: { x: 1, y: 2 }, list: [1, 2, 3] };
  const merged = deepMerge(base, { a: 2, nested: { y: 9 }, list: [4] });
  expect(merged).toEqual({ a: 2, nested: { x: 1, y: 9 }, list: [4] });
});

test("vendor catalog has unique ids + paths and required fields", async () => {
  const { config } = await loadConfig();
  const ids = new Set<string>();
  const paths = new Set<string>();
  for (const c of config.vendor.controllers) {
    expect(ids.has(c.id)).toBe(false);
    ids.add(c.id);
    expect(paths.has(c.path)).toBe(false);
    paths.add(c.path);
    expect(c.url.length).toBeGreaterThan(0);
    expect(c.path.length).toBeGreaterThan(0);
  }
  // Nothing auto-fetches: the shipped catalog is entirely opt-in.
  expect(config.vendor.controllers.every((c) => c.enabled === false)).toBe(true);
});

test("verify.formalTasks point at existing SymbiYosys files", async () => {
  const { existsSync } = await import("node:fs");
  const { join } = await import("node:path");
  const { config, repoRoot } = await loadConfig();
  expect(config.verify.formalTasks.length).toBeGreaterThan(0);
  for (const task of config.verify.formalTasks) {
    expect(task.endsWith(".sby")).toBe(true);
    expect(existsSync(join(repoRoot, task))).toBe(true);
  }
});

test("soc envelope matches AGENTS-configuration router class", async () => {
  const { config } = await loadConfig();
  expect(config.soc.targetFrequencyMHz).toBe(1250);
  expect(config.soc.targetVoltageV).toBe(0.8);
  expect(config.soc.process).toContain("12");
});

test("resolveSynthTop prefers synthTopByTarget, then topByTarget, then top", () => {
  const verify = {
    top: "cva6",
    topByTarget: { lint_only: "g6lc_cluster_lint_top" },
    synthTopByTarget: { synth_override: "cva6" },
  };
  expect(resolveSynthTop(verify, "synth_override")).toBe("cva6");
  expect(resolveSynthTop(verify, "lint_only")).toBe("g6lc_cluster_lint_top");
  expect(resolveSynthTop(verify, "unmapped")).toBe("cva6");
});

test("synth defaults override the server top and widen its unroll limit", async () => {
  const { config } = await loadConfig();
  expect(config.verify.synthTopByTarget.g6lc64_ooo_server).toBe("cva6");
  // Lint keeps the cluster top; only synth reroutes to the core-only unit.
  expect(config.verify.topByTarget.g6lc64_ooo_server).toBe("g6lc_cluster_lint_top");
  expect(config.verify.synthSlangArgsByTarget.g6lc64_ooo_server).toContain(
    "--unroll-limit=262144",
  );
});

test("synth pass recipe: unmapped targets keep the default, the server drops opt -fast", async () => {
  const { config } = await loadConfig();
  // The default smoke is unchanged: proc → opt -fast → check -assert → stat.
  expect(DEFAULT_SYNTH_PASSES).toEqual([
    "proc",
    "opt -fast",
    "check -assert",
    "stat",
  ]);
  expect(
    config.verify.synthPassesByTarget.g6lc64_ooo_int2_l3 ?? DEFAULT_SYNTH_PASSES,
  ).toBe(DEFAULT_SYNTH_PASSES);
  // The server skips the asymptotic OPT_MERGE pass and the OOM-bound full
  // check; stat is reported first and the latch/SR check still asserts.
  expect(config.verify.synthPassesByTarget.g6lc64_ooo_server).toEqual([
    "proc",
    "opt_clean",
    "stat",
    "check -latchonly -assert",
  ]);
});
