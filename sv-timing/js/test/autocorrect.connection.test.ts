// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Connection test: TypeScript ↔ auto-correct dry-run JSON (policy + edits).

import { describe, expect, test } from "bun:test";
import { mkdirSync } from "node:fs";
import { join } from "node:path";

import {
  createClient,
  isCorrectResult,
  packageRootFromJs,
} from "../src/index.ts";

const pkg = packageRootFromJs();
const outDir = join(pkg, ".sv-timing-out", "js-test");

describe("auto-correct connection", () => {
  test("correct --dry-run returns typed edits array and policy flags", async () => {
    mkdirSync(outDir, { recursive: true });
    const client = createClient({ packageRoot: pkg, cwd: pkg });
    const jsonOut = join(outDir, "correct-dry.json");
    const result = await client.correct({
      modulesAllow: ["deep_add_chain"],
      filesFrom: join("fixtures", "auto_correct", "filelist_deep.txt"),
      files: [join("fixtures", "auto_correct", "deep_add_chain.sv")],
      targetMhz: 3000,
      allowLatency: true,
      assumeClk: true,
      dryRun: true,
      jsonOut,
    });

    expect(isCorrectResult(result)).toBe(true);
    expect(result.schema_version).toBe("0");
    expect(result.dry_run).toBe(true);
    expect(result.allow_latency).toBe(true);
    expect(result.modules_allowlist).toContain("deep_add_chain");
    expect(Array.isArray(result.edits)).toBe(true);
    // Tight budget + allow-latency should produce at least one pipeline edit.
    expect(result.edits.length).toBeGreaterThanOrEqual(1);
    expect(result.note ?? "").toMatch(/dry|correct|edit/i);
  }, 180_000);

  test("correct refuses empty allowlist connection (CLI error or empty edits policy)", async () => {
    mkdirSync(outDir, { recursive: true });
    const client = createClient({ packageRoot: pkg, cwd: pkg });
    const jsonOut = join(outDir, "correct-empty-allow.json");
    // CLI should still succeed with note that nothing was applied when allowlist empty
    // OR exit non-zero — client must surface either cleanly.
    try {
      const result = await client.correct({
        modulesAllow: [],
        dryRun: true,
        jsonOut,
      });
      expect(isCorrectResult(result)).toBe(true);
      expect(result.edits.length).toBe(0);
    } catch (e) {
      expect(String(e)).toMatch(/allow|module|correct/i);
    }
  }, 180_000);
});
