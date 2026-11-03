// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { loadConfig } from "../src/config/load.ts";
import { childEnv, createContext } from "../src/context.ts";
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

for (const scenario of [
  { name: "reject unpatched fallback", managed: false, fallback: true, managedPatched: false, fallbackPatched: false },
  { name: "check patched fallback", managed: false, fallback: true, managedPatched: false, fallbackPatched: true },
  { name: "do not borrow fallback patches", managed: true, fallback: true, managedPatched: false, fallbackPatched: true },
  { name: "prefer patched managed runtime", managed: true, fallback: true, managedPatched: true, fallbackPatched: false },
  { name: "reject missing selected prefix", managed: false, fallback: false, managedPatched: false, fallbackPatched: false },
]) {
  test(`simulation runtime selection: ${scenario.name}`, async () => {
    const base = await createContext({ ensureWorkspaceDirs: false });
    const root = mkdtempSync(join(tmpdir(), "g6lc-sim-preflight-"));
    try {
      const tooling = join(root, "tooling");
      const managed = join(tooling, "verilator-managed");
      const fallback = join(tooling, "oss-cad-suite");
      const patchDir = join(root, "verif", "regress");
      mkdirSync(patchDir, { recursive: true });
      writeFileSync(join(patchDir, "verilator-fixture.patch"),
        "--- a/include/verilated.h\n+++ b/include/verilated.h\n@@ -1 +1 @@\n-stock\n+fixture_runtime_fix\n");
      const installFixture = (prefix: string, patched: boolean) => {
        mkdirSync(join(prefix, "bin"), { recursive: true });
        mkdirSync(join(prefix, "share", "verilator", "include"), { recursive: true });
        // Presence-only fixture; no compiler is executed by this test.
        writeFileSync(join(prefix, "bin", "verilator"), "");
        writeFileSync(join(prefix, "share", "verilator", "include", "verilated.h"),
          patched ? "fixture_runtime_fix\n" : "stock\n");
      };
      if (scenario.managed) installFixture(managed, scenario.managedPatched);
      if (scenario.fallback) installFixture(fallback, scenario.fallbackPatched);
      const ctx = {
        ...base,
        repoRoot: root,
        paths: { ...base.paths, tooling },
        tools: { ...base.tools, verilator: managed, verilatorBin: join(managed, "bin") },
      };
      const selected = scenario.managed ? managed : scenario.fallback ? fallback : managed;
      expect(childEnv(ctx).VERILATOR_INSTALL_DIR).toBe(selected);
      const report = assessSimPreflight(ctx);
      expect(report.items.find((item) => item.id === "verilator")?.ok)
        .toBe(scenario.managed || scenario.fallback);
      const patch = report.items.find((item) => item.id === "verilator-patch");
      if (scenario.managed || scenario.fallback) {
        const patched = scenario.managed ? scenario.managedPatched : scenario.fallbackPatched;
        expect(patch).toMatchObject({ ok: patched, required: true });
        if (!patched) expect(report.canAttemptSim).toBe(false);
      } else {
        expect(patch).toBeUndefined();
        expect(report.canAttemptSim).toBe(false);
      }
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
}
