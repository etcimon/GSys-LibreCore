// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Connection test: TypeScript client ↔ Rust analyze JSON (exported AST stub).

import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";

import {
  createClient,
  isAnalyzeResult,
  packageRootFromJs,
} from "../src/index.ts";

const pkg = packageRootFromJs();
const outDir = join(pkg, ".sv-timing-out", "js-test");
const fixtureList = join("fixtures", "filelist.txt");

describe("analyze connection (TS ↔ Rust AST JSON)", () => {
  test("analyze fixture returns schema_version 0 and ast stub", async () => {
    mkdirSync(outDir, { recursive: true });
    const client = createClient({ packageRoot: pkg, cwd: pkg });
    const jsonOut = join(outDir, "analyze.json");
    const result = await client.analyze({
      filesFrom: fixtureList,
      modules: ["comb_adder_cloud"],
      targetMhz: 1000,
      jsonOut,
    });

    expect(isAnalyzeResult(result)).toBe(true);
    expect(result.schema_version).toBe("0");
    expect(result.disclaimer.toLowerCase()).toContain("not");
    // lower_to_ir exports timing_ir_v0
    expect(result.ast.kind === "timing_ir_v0" || result.ast.kind === "parsed_unit_stub").toBe(
      true,
    );
    expect(result.ast.files_parsed).toBeGreaterThanOrEqual(1);
    expect(result.files.length).toBeGreaterThanOrEqual(1);
    expect(result.files.every((f) => f.parse_ok)).toBe(true);
    expect(result.modules_requested).toEqual(["comb_adder_cloud"]);
    expect(result.target_mhz).toBe(1000);
    expect(existsSync(jsonOut)).toBe(true);
    if (result.ast.kind === "timing_ir_v0") {
      expect((result.ast.path_count ?? 0) + (result.paths?.length ?? 0)).toBeGreaterThan(0);
      expect(result.modules?.some((m) => m.name === "comb_adder_cloud")).toBe(true);
    }
  }, 180_000);

  test("analyze without modules rejects in client", async () => {
    const client = createClient({ packageRoot: pkg, cwd: pkg });
    await expect(
      client.analyze({
        filesFrom: fixtureList,
        jsonOut: join(outDir, "should-fail.json"),
      }),
    ).rejects.toThrow(/modules/);
  });
});
