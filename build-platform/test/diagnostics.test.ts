// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

import { describe, expect, test } from "bun:test";
import { DEFAULT_CONFIG } from "../src/config/defaults.ts";
import {
  DIAG_COMPARTMENTS,
  listDiagnostics,
  selectDiagnostics,
} from "../src/tooling/diagnostics.ts";

describe("diagnostics catalog", () => {
  test("defaults ship compartmentalized tests with verilator targets", () => {
    const tests = listDiagnostics(DEFAULT_CONFIG.diagnostics);
    expect(tests.length).toBeGreaterThan(5);
    const compartments = new Set(tests.map((t) => t.compartment));
    for (const c of ["host", "core", "smt2"] as const) {
      expect(compartments.has(c)).toBe(true);
    }
    const vl = tests.filter((t) => t.kind === "verilator-lint");
    expect(vl.length).toBeGreaterThan(0);
    for (const t of vl) {
      expect(t.verilator?.target).toBeTruthy();
    }
  });

  test("select by compartment and by id", () => {
    const cfg = DEFAULT_CONFIG.diagnostics;
    const byComp = selectDiagnostics(cfg, ["core"]);
    expect(byComp.unknown).toEqual([]);
    expect(byComp.tests.every((t) => t.compartment === "core")).toBe(true);

    const one = selectDiagnostics(cfg, ["diag-core-flist"]);
    expect(one.tests.map((t) => t.id)).toEqual(["diag-core-flist"]);

    const bad = selectDiagnostics(cfg, ["no-such-diag"]);
    expect(bad.unknown).toContain("no-such-diag");
  });

  test("default compartments are known", () => {
    for (const c of DEFAULT_CONFIG.diagnostics.defaultCompartments) {
      expect(DIAG_COMPARTMENTS).toContain(c);
    }
  });

  test("smt2 lint owns its warning budget", () => {
    const smt2 = DEFAULT_CONFIG.diagnostics.tests.find((t) => t.id === "diag-smt2-lint");
    expect(smt2?.verilator?.target).toBe("g6lc64_smt2");
    expect(smt2?.verilator?.warningBudget).toBe(600);
  });

  test("ara lint owns top + extra flist", () => {
    const ara = DEFAULT_CONFIG.diagnostics.tests.find((t) => t.id === "diag-ara-lint");
    expect(ara?.verilator?.top).toBe("g6lc_ara_lint_top");
    expect(ara?.verilator?.extraFlists).toContain("vendor/ara/Flist.ara");
  });
});
