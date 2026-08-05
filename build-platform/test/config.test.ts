// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// config.test.ts — Fast sanity checks for config resolution (always run).

import { expect, test } from "bun:test";

import { loadConfig } from "../src/config/load.ts";
import { deepMerge } from "../src/util/object.ts";

test("config resolves and validates", async () => {
  const { config, repoRoot } = await loadConfig();
  expect(repoRoot.length).toBeGreaterThan(0);
  expect(config.soc.coreConfig.length).toBeGreaterThan(0);
  expect(config.simulation.enabled).toContain(config.simulation.default);
  for (const id of config.tests.defaultSuites) {
    expect(config.tests.suites.some((s) => s.id === id)).toBe(true);
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
