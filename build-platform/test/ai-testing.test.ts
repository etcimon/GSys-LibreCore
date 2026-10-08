// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

import { describe, expect, test } from "bun:test";

import { DEFAULT_CONFIG } from "../src/config/defaults.ts";
import { DIAG_COMPARTMENTS } from "../src/tooling/diagnostics.ts";
import {
  AI_DEFAULT_SUITE_IDS,
  injectG6qAiTarget,
  parseAiFlags,
  resolveAiFlavour,
  resolveAiTesting,
  stripGatewayFlags,
} from "../src/tooling/aiTesting.ts";

describe("SI testing CLI knobs", () => {
  test("diag compartment ai is catalogued like ooo", () => {
    expect(DIAG_COMPARTMENTS).toContain("ai");
    expect(DIAG_COMPARTMENTS).toContain("ooo");
    const ai = DEFAULT_CONFIG.diagnostics.tests.filter((t) => t.compartment === "ai");
    expect(ai.map((t) => t.id)).toContain("diag-ai-cfg-paths");
    expect(ai.map((t) => t.id)).toContain("diag-ai-lint");
    const lint = ai.find((t) => t.id === "diag-ai-lint");
    expect(lint?.optional).toBe(true);
    expect(lint?.verilator?.target).toBe("g6lc64_ai");
  });

  test("default suites include SI directed + remote + qemu + wrap", () => {
    const ids = DEFAULT_CONFIG.tests.suites.map((s) => s.id);
    for (const id of [
      "ai-config-smoke",
      "ai-matrix-directed",
      "ai-island-veri",
      "ai-dram-atomics",
      "ai-s4-mshr-xbar",
      "ai-litedram-wrap",
      "ai-dram-channels",
      "ai-dram-stripe",
      "ai-dram-timing",
      "ai-qemu-linux",
    ]) {
      expect(ids).toContain(id);
    }
    const qemu = DEFAULT_CONFIG.tests.suites.find((s) => s.id === "ai-qemu-linux");
    expect(qemu?.group).toBe("linux");
    expect(qemu?.optional).toBe(true);
  });

  test("class × channels maps onto testharness flavours (x4 = ai-d4)", () => {
    expect(resolveAiFlavour({ wantAi: true, wantRemote: false, wantQemu: false, wantTensor: false, wantTiming: false, includeOptional: false, dramClass: 1, channels: 4 }).meta.flavour).toBe("ai-d4");
    expect(resolveAiFlavour({ wantAi: true, wantRemote: false, wantQemu: false, wantTensor: false, wantTiming: false, includeOptional: false, dramClass: 1, channels: 1 }).meta.defines).toBe("G6LC_AI_DRAM_CLASS1");
    expect(resolveAiFlavour({ wantAi: true, wantRemote: false, wantQemu: false, wantTensor: false, wantTiming: true, includeOptional: false }).meta.flavour).toBe("ai-dt");
    expect(resolveAiFlavour({ wantAi: true, wantRemote: false, wantQemu: false, wantTensor: false, wantTiming: false, includeOptional: false, channels: 4 }).meta.flavour).toBe("ai-sc4");
    const c2 = resolveAiFlavour({
      wantAi: true,
      wantRemote: false,
      wantQemu: false,
      wantTensor: false,
      wantTiming: false,
      includeOptional: false,
      dramClass: 2,
    });
    expect(c2.errors.length).toBeGreaterThan(0);
  });

  test("test --ai selects directed gates; --ai-remote selects S4", () => {
    const local = resolveAiTesting(
      parseAiFlags({ ai: true }),
    );
    expect(local.active).toBe(true);
    expect(local.suiteIds).toEqual(expect.arrayContaining([...AI_DEFAULT_SUITE_IDS]));
    expect(local.suiteIds).not.toContain("ai-s4-mshr-xbar");

    const remote = resolveAiTesting(parseAiFlags({ "ai-remote": true }));
    expect(remote.suiteIds).toContain("ai-s4-mshr-xbar");
    expect(remote.flavour).toBe("ai-dt");

    const x4 = resolveAiTesting(
      parseAiFlags({ ai: true, channels: "4", "ai-dram": "1" }),
    );
    expect(x4.flavour).toBe("ai-d4");
    expect(x4.env.AI_ISLAND_DRAM_CHANS_4).toBe("1");
    expect(x4.env.S4_FLAVOUR).toBe("ai-d4");
    expect(x4.suiteIds).toContain("ai-dram-channels");
    expect(x4.suiteIds).toContain("ai-litedram-wrap");
    expect(x4.suiteIds).not.toContain("ai-dram-stripe");

    const sc4 = resolveAiTesting(parseAiFlags({ ai: true, channels: "4" }));
    expect(sc4.flavour).toBe("ai-sc4");
    expect(sc4.env.AI_ISLAND_DRAM_SIM_CHANS_4).toBe("1");
    expect(sc4.suiteIds).toContain("ai-dram-stripe");
    expect(sc4.suiteIds).not.toContain("ai-dram-channels");
  });

  test("I2 clusters>1 warns and still exports CAP env", () => {
    const r = resolveAiTesting(parseAiFlags({ ai: true, "ai-clusters": "4" }));
    expect(r.clusters).toBe(4);
    expect(r.env.AI_ISLAND_CLUSTERS).toBe("4");
    expect(r.warnings.some((w) => w.includes("I2"))).toBe(true);
  });

  test("g6q gateway strips host flags and injects --target g6lc64_ai on gen", () => {
    const stripped = stripGatewayFlags([
      "--ai",
      "--from-timing",
      "out/t1",
      "--channels",
      "4",
      "run",
      "--",
      "gen",
      "--emit",
      "qemu",
    ]);
    expect(stripped).toEqual(["run", "--", "gen", "--emit", "qemu"]);
    expect(injectG6qAiTarget(stripped)).toEqual([
      "run",
      "--",
      "gen",
      "--target",
      "g6lc64_ai",
      "--emit",
      "qemu",
    ]);
  });
});
