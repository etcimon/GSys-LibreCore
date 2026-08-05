// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "bun:test";

import { createContext } from "../src/context.ts";
import {
  fo4RetuneChecklist,
  inventoryFo4Model,
  parseFo4Toml,
} from "../src/tooling/fo4Inventory.ts";
import {
  buildRetuneProposal,
  classifyAgreement,
  loadCorrelateJson,
  mapKindToCostKeys,
  proposeFo4Retune,
} from "../src/tooling/retunePropose.ts";
import { assessTimingsDoctor } from "../src/tooling/timingsDoctor.ts";

test("parseFo4Toml reads version and costs", () => {
  const t = `
# comment
version = "fo4-v1"
mul = 56.0
div_rem = 120
logic_bit = 1.0
`;
  const p = parseFo4Toml(t);
  expect(p.version).toBe("fo4-v1");
  expect(p.costs.mul).toBe(56);
  expect(p.costs.div_rem).toBe(120);
  expect(p.costs.logic_bit).toBe(1);
});

test("inventoryFo4Model finds package model", async () => {
  const ctx = await createContext({ ensureWorkspaceDirs: false });
  const inv = inventoryFo4Model(ctx);
  expect(inv.present).toBe(true);
  expect(inv.version).toBe("fo4-v1");
  expect(inv.costs.mul).toBeGreaterThan(0);
  const cl = fo4RetuneChecklist(inv);
  expect(cl.some((l) => l.includes("correlate"))).toBe(true);
});

test("assessTimingsDoctor runs", async () => {
  const ctx = await createContext({ ensureWorkspaceDirs: false });
  const d = assessTimingsDoctor(ctx);
  expect(d.svTimingRoot).toBeTruthy();
  expect(d.fo4.present).toBe(true);
  expect(d.ok).toBe(true);
});

test("mapKindToCostKeys and classifyAgreement", () => {
  expect(mapKindToCostKeys("mul", "x")).toContain("mul");
  expect(mapKindToCostKeys("in_to_reg", "a→b")).toContain("logic_bit");
  expect(classifyAgreement(1, true)).toBe("high");
  expect(classifyAgreement(0.5, true)).toBe("medium");
  expect(classifyAgreement(0.1, true)).toBe("low");
  expect(classifyAgreement(null, false)).toBe("unknown");
});

test("buildRetuneProposal flags synthetic fixture and never auto-edits", async () => {
  const ctx = await createContext({ ensureWorkspaceDirs: false });
  const inv = inventoryFo4Model(ctx);
  const tmp = join(ctx.paths.build, "sta-handoff", "retune-unit");
  mkdirSync(join(tmp, "opensta"), { recursive: true });
  const staRpt = join(tmp, "opensta", "paths.rpt");
  writeFileSync(
    staRpt,
    "# Synthetic OpenSTA-like path report for offline S3a\nStartpoint: a\nEndpoint: b\nslack (MET) 0.1\n",
    "utf8",
  );
  const corrPath = join(tmp, "correlate.json");
  writeFileSync(
    corrPath,
    JSON.stringify({
      schema: "cva6-sta-correlate.v0",
      overlap_score: 1,
      overlap: ["a→b"],
      missing_in_sta: [],
      missing_in_fo4: [],
      fo4_rank: [{ rank: 1, start: "a", end: "b", kind: "in_to_reg", total_fo4: 8 }],
      sta_rank: [{ rank: 1, start: "a", end: "b", slack: 0.1 }],
      sta_report: staRpt,
    }) + "\n",
    "utf8",
  );
  const corr = loadCorrelateJson(corrPath);
  expect(corr).not.toBeNull();
  const prop = buildRetuneProposal(corr, inv);
  expect(prop.schema).toBe("cva6-fo4-retune-proposal.v0");
  expect(prop.syntheticLikely).toBe(true);
  expect(prop.agreement).toBe("fixture_or_empty");
  expect(prop.actions.some((a) => /do not retune/i.test(a))).toBe(true);

  const written = proposeFo4Retune(ctx, { fromHandoff: tmp, outDir: tmp });
  expect(written.ok).toBe(true);
  expect(existsSync(join(tmp, "retune-proposal.md"))).toBe(true);
  expect(existsSync(join(tmp, "retune-proposal.json"))).toBe(true);
});
