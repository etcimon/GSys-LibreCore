// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// AI overlay pins: every configured <pkg>_ai package/DTS equals a fresh generation.
import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import { readFileSync } from "node:fs";

import { DEFAULT_CONFIG } from "../src/config/defaults.ts";
import { checkPin, pinPackageText, pinDtsText, AI_OVERLAY_MARKER } from "../src/tooling/aiOverlay.ts";

const repoRoot = join(import.meta.dir, "..", "..");

describe("ai-overlay", () => {
  test("pinned packages and DTS match the generator", async () => {
    for (const pin of DEFAULT_CONFIG.soc.aiOverlayPins) {
      const r = await checkPin(repoRoot, pin);
      expect(r.ok, `${pin.target}: ${r.detail}`).toBe(true);
    }
  });

  test("the package rewrite touches exactly CvxifEn, CoproType and AiCfg", () => {
    const base = readFileSync(join(repoRoot, "core/include/g6lc64_ooo_int2_l3_config_pkg.sv"), "utf8");
    const out = pinPackageText(base, { target: "g6lc64_ooo_int2_l3" }, "x", "0".repeat(64));
    expect(out).toContain(AI_OVERLAY_MARKER);
    expect(out).toMatch(/CvxifEn:\s*bit'\(1\)/);
    expect(out).toMatch(/CoproType:\s*config_pkg::COPRO_G6LC_AI/);
    expect(out).toMatch(/AiCfg:\s*config_pkg::AiCfgIsland,/);
    const strip = (t: string) =>
      t.split("\n").filter((l) => !/^\s*(CvxifEn|CoproType|AiCfg):/.test(l) && !l.startsWith("//") && l.trim() !== "").join("\n");
    expect(strip(out)).toBe(strip(base));
  });

  test("the DTS appends xg6lcai to every cpu and includes the island dtsi", () => {
    const base = readFileSync(join(repoRoot, "corev_apu/bootrom/ariane-ooo-int2-l3.dts"), "utf8");
    const out = pinDtsText(base, "ariane-ooo-int2-l3.dts", { target: "g6lc64_ooo_int2_l3" });
    expect(out).toContain('/include/ "ariane-ooo-int2-l3.dts"');
    expect(out).toContain('/include/ "g6lc-ai-matrix.dtsi"');
    const cpus = (base.match(/CPU\d+:\s*cpu@/g) ?? []).length;
    expect((out.match(/"xg6lcai"/g) ?? []).length).toBe(cpus);
    expect(out).toContain("&ai_matrix {");
  });
});
