// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// The gate must run the built, patched Verilator: these tests pin the check
// that `tools install verilator`, `diag status`, `verify` and the sim
// preflight share, against the real verif/regress/verilator-*.patch set.

import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  formatVerilatorPatchStatus,
  listVerilatorPatches,
  patchedHeaderLines,
  verilatorPatchStatus,
} from "../src/tooling/verilatorPatch.ts";

const repoRoot = join(import.meta.dir, "..", "..");

function fakePrefix(headers: Record<string, string>): string {
  const prefix = mkdtempSync(join(tmpdir(), "g6lc-vl-"));
  const inc = join(prefix, "share", "verilator", "include");
  mkdirSync(join(prefix, "bin"), { recursive: true });
  mkdirSync(inc, { recursive: true });
  for (const [rel, text] of Object.entries(headers)) writeFileSync(join(inc, rel), text);
  return prefix;
}

test("the repo ships at least the VlUnpacked::data() fix and it parses to header lines", () => {
  const patches = listVerilatorPatches(repoRoot);
  expect(patches.length).toBeGreaterThan(0);
  const all = new Map<string, string[]>();
  for (const p of patches) for (const [k, v] of patchedHeaderLines(readFileSync(p, "utf8"))) all.set(k, v);
  // docs/CONTRIBUTORS is touched by the patch but is not an installed header.
  expect([...all.keys()].every((k) => !k.includes("CONTRIBUTORS"))).toBe(true);
  const types = all.get("verilated_types.h") ?? [];
  expect(types.some((l) => l.includes("(WData*)&m_storage[0]"))).toBe(true);
});

test("patchedHeaderLines keeps only include/ additions and skips blank ones", () => {
  const patch = [
    "diff --git a/docs/X b/docs/X",
    "--- a/docs/X",
    "+++ b/docs/X",
    "@@ -1 +1,2 @@",
    "+ignored: not a header",
    "diff --git a/include/foo.h b/include/foo.h",
    "--- a/include/foo.h",
    "+++ b/include/foo.h",
    "@@ -1,2 +1,4 @@",
    " ctx",
    "+int fixed();",
    "+",
    "-int broken();",
    "+  // note",
  ].join("\n");
  const m = patchedHeaderLines(patch);
  expect([...m.keys()]).toEqual(["foo.h"]);
  expect(m.get("foo.h")).toEqual(["int fixed();", "  // note"]);
});

test("verilatorPatchStatus accepts a prefix carrying every patched line and rejects a stock one", () => {
  const patches = listVerilatorPatches(repoRoot);
  const headers: Record<string, string> = {};
  for (const p of patches) {
    for (const [rel, lines] of patchedHeaderLines(readFileSync(p, "utf8"))) {
      headers[rel] = (headers[rel] ?? "// header\n") + lines.join("\n") + "\n";
    }
  }
  const patched = fakePrefix(headers);
  const stock = fakePrefix(Object.fromEntries(Object.keys(headers).map((k) => [k, "// stock header\n"])));
  const empty = fakePrefix({});
  try {
    const ok = verilatorPatchStatus(patched, repoRoot);
    expect(ok.patched).toBe(true);
    expect(ok.missing).toEqual([]);
    expect(formatVerilatorPatchStatus(ok)).toContain("patched (");

    const bad = verilatorPatchStatus(stock, repoRoot);
    expect(bad.patched).toBe(false);
    expect(bad.missing.length).toBeGreaterThan(0);
    expect(formatVerilatorPatchStatus(bad)).toContain("UNPATCHED");

    const none = verilatorPatchStatus(empty, repoRoot);
    expect(none.patched).toBe(false);
    expect(none.unreadable.length).toBeGreaterThan(0);
  } finally {
    for (const d of [patched, stock, empty]) rmSync(d, { recursive: true, force: true });
  }
});

test("a repo without custom patches is reported as such, not as unpatched", () => {
  const noPatchRepo = mkdtempSync(join(tmpdir(), "g6lc-nopatch-"));
  try {
    const st = verilatorPatchStatus("/nonexistent/prefix", noPatchRepo);
    expect(st.patches).toEqual([]);
    expect(st.patched).toBe(false);
    expect(formatVerilatorPatchStatus(st)).toBe("no custom patches in verif/regress");
  } finally {
    rmSync(noPatchRepo, { recursive: true, force: true });
  }
});
