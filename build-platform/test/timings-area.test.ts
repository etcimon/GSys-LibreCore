// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// timings area argv. The builder lists CLI flags. It does not compute area.

import { expect, test } from "bun:test";

import { parseArgs } from "../src/cli/args.ts";
import { buildSvTimingAreaArgs } from "../src/tooling/timings.ts";

test("buildSvTimingAreaArgs lists the area command and the caller knobs", () => {
  const args = buildSvTimingAreaArgs({
    portableFlist: "/work/portable.f",
    modules: ["alu", "serdiv"],
    cache: "/work/ir.sqlite",
    jsonOut: "/work/area-report.json",
    paramMap: "/work/param-map.json",
    compareParamMap: "/work/other.json",
    targetMhz: 1000,
    fo4Ps: 20,
    budgetMargin: 0.2,
    assumeXlen: 64,
    packageMode: "packages",
    inclusion: ["path-kind:reg_to_reg"],
    configOverlay: ["EN=1"],
    top: 20,
    strictAttribution: true,
    allowParseErrors: true,
  });
  expect(args).toEqual([
    "area",
    "--files-from",
    "/work/portable.f",
    "--modules",
    "alu,serdiv",
    "--target-mhz",
    "1000",
    "--fo4-ps",
    "20",
    "--budget-margin",
    "0.2",
    "--cache",
    "/work/ir.sqlite",
    "--json-out",
    "/work/area-report.json",
    "--param-map",
    "/work/param-map.json",
    "--compare-param-map",
    "/work/other.json",
    "--assume-xlen",
    "64",
    "--package-mode",
    "packages",
    "--inclusion",
    "path-kind:reg_to_reg",
    "--config-overlay",
    "EN=1",
    "--top",
    "20",
    "--strict-attribution",
    "--allow-parse-errors",
  ]);
  expect(args.includes("analyze")).toBe(false);
  expect(args.includes("correct")).toBe(false);
  expect(args.includes("--emit")).toBe(false);
  expect(args.includes("--out-dir")).toBe(false);
});

test("all-modules drops the module list and omits unset knobs", () => {
  const args = buildSvTimingAreaArgs({
    portableFlist: "portable.f",
    allModules: true,
    modules: ["alu"],
  });
  expect(args).toEqual(["area", "--files-from", "portable.f", "--all-modules"]);
});

test("area argv forwards metric, compare inclusion, model, and force", () => {
  const args = buildSvTimingAreaArgs({
    portableFlist: "portable.f",
    allModules: true,
    metric: "perf-per-area",
    compareInclusion: "subtree:serdiv",
    areaModel: "area-v1",
    force: true,
  });
  expect(args).toEqual([
    "area",
    "--files-from",
    "portable.f",
    "--all-modules",
    "--metric",
    "perf-per-area",
    "--compare-inclusion",
    "subtree:serdiv",
    "--area-model",
    "area-v1",
    "--force",
  ]);
});

test("area value flags stay attached to their options", () => {
  const parsed = parseArgs([
    "timings",
    "area",
    "--modules",
    "alu",
    "--inclusion",
    "path-kind:reg_to_reg",
    "--config-overlay",
    "EN=1",
    "--budget-margin",
    "0.2",
    "--compare-param-map",
    "other.json",
    "--strict-attribution",
    "--output",
    "workspace/build/sv-timing/alu-pack",
  ]);
  expect(parsed.command).toBe("timings");
  expect(parsed.positionals).toEqual(["area"]);
  expect(parsed.flags.modules).toBe("alu");
  expect(parsed.flags.inclusion).toBe("path-kind:reg_to_reg");
  expect(parsed.flags["config-overlay"]).toBe("EN=1");
  expect(parsed.flags["budget-margin"]).toBe("0.2");
  expect(parsed.flags["compare-param-map"]).toBe("other.json");
  expect(parsed.flags["strict-attribution"]).toBe(true);
  expect(parsed.flags.output).toBe("workspace/build/sv-timing/alu-pack");
});
