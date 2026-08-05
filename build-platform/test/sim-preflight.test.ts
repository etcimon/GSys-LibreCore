// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

import { expect, test } from "bun:test";

import { loadConfig } from "../src/config/load.ts";
import { createContext } from "../src/context.ts";
import {
  assessSimPreflight,
  formatSimPreflightLines,
} from "../src/tooling/simPreflight.ts";

test("assessSimPreflight returns structured items", async () => {
  const ctx = await createContext({ ensureWorkspaceDirs: false });
  const r = assessSimPreflight(ctx);
  expect(r.items.length).toBeGreaterThan(0);
  expect(r.items.some((i) => i.id === "bash")).toBe(true);
  expect(r.items.some((i) => i.id === "riscv-gcc")).toBe(true);
  const lines = formatSimPreflightLines(r);
  expect(lines.some((l) => l.includes("sim preflight"))).toBe(true);
});

test("loadConfig still valid after sim preflight import", async () => {
  const { config } = await loadConfig();
  expect(config.soc.coreConfig.length).toBeGreaterThan(0);
});
