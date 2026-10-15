// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// core-profile.test.ts — `mb ingest` must refuse a board whose advertised hart
// topology or config-package hash disagrees with core/include.

import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

import { checkIngestCore, readCoreTopology, sha256Hex } from "../src/tooling/coreProfile.ts";

const SAMPLE = `
// comment
package g6lc64_demo_config_pkg;
  localparam CVA6ConfigXlen = 64;
  localparam int unsigned CVA6ConfigNrCores = 4;
  localparam config_pkg::cva6_user_cfg_t cva6_cfg = '{
      XLEN: unsigned'(CVA6ConfigXlen),
      L2En: bit'(1),
      NrHarts: unsigned'(2),  // SMT2
      NrCores: unsigned'(CVA6ConfigNrCores),
      OoOEn: bit'(1)
  };
endpackage
`;

describe("readCoreTopology", () => {
  test("reads the supported forms, resolving identifiers through localparams", () => {
    const t = readCoreTopology(SAMPLE);
    expect(t.cores).toBe(4);
    expect(t.threads).toBe(2);
    expect(t.unresolved).toEqual([]);
  });

  test("does not guess an unsupported expression", () => {
    const t = readCoreTopology(SAMPLE.replace("NrHarts: unsigned'(2)", "NrHarts: unsigned'(CVA6ConfigXlen / 32)"));
    expect(t.threads).toBeNull();
    expect(t.unresolved).toEqual(["NrHarts"]);
  });
});

describe("checkIngestCore", () => {
  const verified = {
    config: "g6lc64_demo",
    harts: { count: 8, cores: 4, threads: 2 },
    source: { path: "core/include/g6lc64_demo_config_pkg.sv", sha256: sha256Hex(SAMPLE) },
  };

  test("a bundle that agrees with the package is verified", () => {
    const r = checkIngestCore(verified, SAMPLE);
    expect(r.mode).toBe("verified");
    expect(r.issues).toEqual([]);
  });

  test("a stale advertised topology is refused (the old literal-table class)", () => {
    const r = checkIngestCore({ ...verified, harts: { count: 4, cores: 4, threads: 1 } }, SAMPLE);
    expect(r.issues.some((i) => i.includes("NrCores=4 × NrHarts=2"))).toBe(true);
  });

  test("a changed config package is refused even when the numbers still match", () => {
    const r = checkIngestCore(verified, SAMPLE + "\n// edited after compile\n");
    expect(r.issues.some((i) => i.includes("does not match"))).toBe(true);
  });

  test("count must equal cores times threads", () => {
    const r = checkIngestCore({ ...verified, harts: { count: 6, cores: 4, threads: 2 } }, SAMPLE);
    expect(r.issues.some((i) => i.includes("not cores × threads"))).toBe(true);
  });

  test("a legacy platform.json without harts/source is accepted as legacy, not verified", () => {
    const r = checkIngestCore({ config: "g6lc64_demo" }, SAMPLE);
    expect(r.mode).toBe("legacy");
    expect(r.issues).toEqual([]);
  });

  test("the real ooo_server package has 4 x 2 harts when the monorepo is present", () => {
    const p = join(import.meta.dir, "..", "..", "core", "include", "g6lc64_ooo_server_config_pkg.sv");
    if (!existsSync(p)) return;
    const t = readCoreTopology(readFileSync(p, "utf8"));
    expect(t.cores).toBe(4);
    expect(t.threads).toBe(2);
  });
});
