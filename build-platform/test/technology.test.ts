// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// technology.test.ts — The technology-optimization pass is inert + safe by default.

import { expect, test } from "bun:test";

import { DEFAULT_CONFIG } from "../src/config/defaults.ts";
import { validateConfig } from "../src/config/load.ts";
import { createContext } from "../src/context.ts";
import { assessPass, detectSpecDocs, readinessGates } from "../src/tooling/technology.ts";
import { deepMerge } from "../src/util/object.ts";

test("technology defaults: pass off + omitted PDK (nothing auto-arms)", () => {
  const t = DEFAULT_CONFIG.technology;
  expect(t.optimizationPass).toBe(false);
  expect(t.pdkMode).toBe("omitted");
  expect(t.activeTechnology).toBeNull();
  expect(t.guardMacro).toMatch(/^[A-Za-z_][A-Za-z0-9_]*$/);
  expect(t.specGlobs.length).toBeGreaterThan(0);
  expect(t.protectedGlobs.length).toBeGreaterThan(0);
});

test("technology pass is inert by default (two-key ignition not met)", async () => {
  const ctx = await createContext({ logLevel: "silent" });
  const assess = await assessPass(ctx);
  expect(assess.flagOn).toBe(false);
  expect(assess.armed).toBe(false);
  // Detection returns an array (empty is fine when no tech-spec docs exist).
  expect(Array.isArray(await detectSpecDocs(ctx))).toBe(true);
});

test("readiness: a disabled pass reports flagOn=false and a valid guard macro", async () => {
  const ctx = await createContext({ logLevel: "silent" });
  const report = await readinessGates(ctx);
  expect(report.flagOn).toBe(false);
  expect(report.armed).toBe(false);
  const guard = report.gates.find((g) => g.id === "guard-macro");
  expect(guard?.ok).toBe(true);
});

test("validation rejects an invalid guard macro identifier", () => {
  const bad = deepMerge(DEFAULT_CONFIG, { technology: { guardMacro: "9 not-an-ident" } });
  expect(() => validateConfig(bad)).toThrow();
});

test('validation rejects "nda" pdkMode without an activeTechnology', () => {
  const bad = deepMerge(DEFAULT_CONFIG, { technology: { pdkMode: "nda", activeTechnology: null } });
  expect(() => validateConfig(bad)).toThrow();
});
