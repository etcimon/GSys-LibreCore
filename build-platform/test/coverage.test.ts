// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

import { expect, test } from "bun:test";
import { DEFAULT_CONFIG } from "../src/config/defaults.ts";
import { ConfigError, validateConfig } from "../src/config/load.ts";
import { parseArgs } from "../src/cli/args.ts";
import { suiteTools } from "../src/tests/runner.ts";
import type { TestSuite } from "../src/config/schema.ts";

const suite = (over: Partial<TestSuite> = {}): TestSuite => ({
  id: "x", description: "", script: "s.sh", group: "directed", target: "t",
  dvSimulators: "none", tools: ["riscv-gcc"], openSource: true, ...over,
});

test("coverage tools are cumulative across levels", () => {
  const s = suite({ coverageTools: { standard: ["verilator"], full: ["formal"] } });
  expect(suiteTools(s, "quick")).toEqual(["riscv-gcc"]);
  expect(suiteTools(s, "standard")).toEqual(["riscv-gcc", "verilator"]);
  expect(suiteTools(s, "full")).toEqual(["riscv-gcc", "verilator", "formal"]);
  expect(suiteTools(suite(), "full")).toEqual(["riscv-gcc"]);
});

test("the coverage-aware subproject gates are catalogued and optional", () => {
  for (const id of ["apu-ci", "storamic-ci"]) {
    const s = DEFAULT_CONFIG.tests.suites.find((x) => x.id === id)!;
    expect(s.execution).toBe("host");
    expect(s.optional).toBe(true);
    expect(suiteTools(s, "quick")).toEqual([]);
    expect(suiteTools(s, "standard")).toEqual(["verilator"]);
  }
  expect(DEFAULT_CONFIG.tests.coverage).toBe("quick");
});

const issuesOf = (cfg: typeof DEFAULT_CONFIG): string[] => {
  try {
    validateConfig(cfg);
    return [];
  } catch (e) {
    return e instanceof ConfigError ? e.issues : [String(e)];
  }
};

test("coverage level and per-level tool keys are validated", () => {
  expect(issuesOf(structuredClone(DEFAULT_CONFIG))).toEqual([]);
  const bad = structuredClone(DEFAULT_CONFIG);
  (bad.tests as { coverage: string }).coverage = "max";
  expect(issuesOf(bad).join("\n")).toContain("tests.coverage 'max'");
  const badKey = structuredClone(DEFAULT_CONFIG);
  (badKey.tests.suites[0]! as { coverageTools: object }).coverageTools = { deep: ["verilator"] };
  expect(issuesOf(badKey).join("\n")).toContain("coverageTools level 'deep'");
});

test("--coverage consumes its level argument", () => {
  const args = parseArgs(["test", "apu-ci", "--coverage", "standard", "--strict"]);
  expect(args.flags.coverage).toBe("standard");
  expect(args.flags.strict).toBe(true);
  expect(args.positionals).toEqual(["apu-ci"]);
});
