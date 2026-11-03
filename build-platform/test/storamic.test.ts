// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

import { expect, test } from "bun:test";
import { DEFAULT_CONFIG } from "../src/config/defaults.ts";
import { storamicConfigIssues, storamicEnv, validateStoramicFlags } from "../src/tooling/storamic.ts";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const off = DEFAULT_CONFIG.soc;
const on = { ...off, storamic: { enable: true, profile: "skeleton" as const, maxSticks: 3 } };

test("Storamic is default off and outside default suites", () => {
  expect(storamicEnv(off)).toEqual({});
  const suite = DEFAULT_CONFIG.tests.suites.find((s) => s.id === "storamic-remote-leaf");
  expect(suite?.execution).toBe("remote-proxy");
  expect(suite?.optional).toBe(true);
  expect(DEFAULT_CONFIG.tests.defaultSuites).not.toContain("storamic-remote-leaf");
});

test("Storamic produces one canonical explicit skeleton selection", () => {
  expect(storamicEnv(on)).toEqual({
    G6LC_STORAMIC_DEFINES: "G6LC_STORAMIC+G6LC_STORAMIC_SKELETON+G6LC_STORAMIC_MAX_STICKS=3",
  });
  for (const count of [1, 2, 3, 4, 8]) {
    expect(storamicConfigIssues({ ...on, storamic: { ...on.storamic, maxSticks: count } })).toEqual([]);
  }
  for (const count of [0, 9, 1.5, Number.NaN]) {
    expect(storamicConfigIssues({ ...on, storamic: { ...on.storamic, maxSticks: count } }).length).toBe(1);
  }
});

test("direct-memory flags and environment cannot silently override Storamic", () => {
  for (const defines of ["G6LC_AI_DRAM_CLASS1", "G6LC_AI_DRAM_CHANS_4", "G6LC_AI_DRAM_SIM_CHANS_2", "G6LC_AI_DRAM_TIMING"]) {
    expect(() => storamicEnv(on, { defines })).toThrow("mutually exclusive");
  }
  const flagSets: Record<string, string | boolean>[] = [
    { "ai-dram": "0" }, { "ai-dram": "1" }, { channels: "4" },
  ];
  for (const flags of flagSets) {
    expect(() => validateStoramicFlags(on, flags)).toThrow("cannot be combined");
  }
  expect(() => storamicEnv(on, { AI_ISLAND_DRAM_CLASS: "2" })).toThrow();
  expect(() => storamicEnv(on, { defines: "G6LC_STORAMIC_MAX_STICKS=4" })).toThrow();
  expect(() => storamicEnv(off, { defines: "G6LC_STORAMIC" })).toThrow("explicit skeleton");
});

test("standalone Storamic source list names only first-party RTL", () => {
  const root = resolve(import.meta.dir, "../..");
  const rows = readFileSync(resolve(root, "g6lc_storamic/Flist.storamic"), "utf8").trim().split(/\r?\n/);
  expect(rows.length).toBe(6);
  for (const row of rows) {
    expect(row.startsWith("${CVA6_REPO_DIR}/g6lc_storamic/rtl/")).toBe(true);
    const text = readFileSync(resolve(root, row.replace("${CVA6_REPO_DIR}/", "")), "utf8");
    expect(text).not.toMatch(/`include|vendor\/|axi_pkg::|common_cells/);
  }
});

test("board wrappers cannot silently ignore a Storamic selection", () => {
  const root = resolve(import.meta.dir, "../..");
  for (const file of [
    "corev_apu/fpga/src/ariane_xilinx.sv",
    "corev_apu/altera/src/cva6_altera.sv",
    "corev_apu/openpiton/ariane_verilog_wrap.sv",
  ]) {
    const text = readFileSync(resolve(root, file), "utf8");
    expect(text).toMatch(/if \((CVA6Cfg|cva6_cfg)\.StoramicEn\) begin : gen_storamic_unbound\s+initial \$fatal\(1, "STORAMIC_BOARD_UNSUPPORTED"\)/);
  }
});
