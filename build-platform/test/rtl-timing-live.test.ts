// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "bun:test";

import { checkFo4Completion, moduleBoardShell, writeCalibration } from "../src/tooling/rtlTiming.ts";

const report = () => ({
  dry_run: false,
  post_analyze_valid: true,
  integrity: { joint_ok: true, reparse_ok: true, structural_ok: true },
  post_analyze: {
    budget_fo4: 10,
    skipped_files: [],
    modules: [{ id: 1, name: "g6lc_iq" }, { id: 2, name: "g6lc_ai_exec" }],
    frequency_closure: { uninstantiated_modules: ["g6lc_ai_exec"] },
    paths: [
      { multi_cycle: false, path_kind: "regtoreg", total_fo4: 9.5, module_id: 1, primary_loc: { start_line: 12 } },
      { multi_cycle: false, path_kind: "regtoreg", total_fo4: 280.5, module_id: 2, primary_loc: { start_line: 7 } },
    ],
  },
});

test("the FO4 verdict is the live design's: an uninstantiated module's cone cannot miss the budget", () => {
  const r = report();
  const ok = checkFo4Completion(r, 10);
  expect(ok.ok).toBe(true);
  expect(ok.detail).toContain("1 uninstantiated modules excluded");
  expect(ok.detail).toContain("280.5");
  // a live miss still misses
  r.post_analyze.paths[0]!.total_fo4 = 11;
  const miss = checkFo4Completion(r, 10);
  expect(miss.ok).toBe(false);
  expect(miss.detail).toContain("worst live primary 11.0");
  // without a width map nothing is excluded
  const noMap = report();
  noMap.post_analyze.frequency_closure = { uninstantiated_modules: [] };
  expect(checkFo4Completion(noMap, 10).ok).toBe(false);
});

test("calibration joins the structural worst per live module with the module board", () => {
  const dir = mkdtempSync(join(tmpdir(), "svt-cal-"));
  const correct = join(dir, "correct.json");
  writeFileSync(correct, JSON.stringify(report()), "utf8");
  const board = join(dir, "module-board.tsv");
  writeFileSync(board, [
    "module\tinstances\tclock\tworst_reg2reg_ns\tcells_on_path\tstartpoint\tendpoint\tworst_any_ns\tbroadcast_drivers_disabled\tstart_net\tend_net\ttrace",
    "g6lc_iq$cva6.i_iq\t1\tclk_i\t3.042\t41\ta\tb\t3.1\t0\tx\ty\tx > y",
    "g6lc_ai_exec\t1\tclk_i\t-\t-\t-\t-\t-\t-\t-\t-\tno netlist",
    "other\t1\tclk_i\t1.000\t12\ta\tb\t1.0\t0\tx\ty\tx > y",
  ].join("\n") + "\n", "utf8");
  const out = join(dir, "calibration.tsv");
  const summary = writeCalibration(correct, board, out);
  const rows = readFileSync(out, "utf8").trim().split("\n");
  expect(rows[0]).toContain("cells_per_fo4");
  // worst mapped path of any kind first; live module ratio 41 / 9.5 = 4.3 → under-read;
  // the dead module's row (no netlist) is dropped
  expect(rows[1]).toMatch(/^g6lc_iq\t3\.100\t9\.5\tregtoreg\t3\.042\t41\t9\.5\t12\t4\.32\tunder-read/);
  expect(rows.some((r) => r.startsWith("other\t1.000\t-\t-\t1.000\t12"))).toBe(true);
  expect(rows.some((r) => r.startsWith("g6lc_ai_exec"))).toBe(false);
  expect(summary).toContain("worst mapped: g6lc_iq 3.10 ns");
  expect(summary).toContain("1 under-read");
  // A live mapping must not inherit an earlier corrected tree's FO4.
  const live = writeCalibration(undefined, board, out);
  const liveRows = readFileSync(out, "utf8");
  expect(liveRows).toContain("g6lc_iq\t3.100\t-\t-\t3.042\t41\t-");
  expect(live).toContain("0 under-read");
});

test("the module board shell keeps the heredoc-local variables literal", () => {
  const text = moduleBoardShell({ runDir: "$RUN", liberty: "$LIB", periodNs: 0.25, pullTag: "t" }).join("\n");
  expect(text).toContain("IFS=\\$'\\t'");
  expect(text).toContain('printf "%s\\0%s\\0" "\\$f" "\\$m"');
  expect(text).toContain('top="${m#\\\\}"');
  expect(text).not.toContain("\t");
  expect(text).not.toContain("\0");
});
