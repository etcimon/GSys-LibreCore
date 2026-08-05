// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Connection test: TypeScript ↔ debug-export bundle.

import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";

import {
  createClient,
  isDebugExportResult,
  packageRootFromJs,
} from "../src/index.ts";

const pkg = packageRootFromJs();
const outDir = join(pkg, ".sv-timing-out", "js-test", "debug");

describe("debug-export connection", () => {
  test("debug-export writes bundle metadata JSON", async () => {
    mkdirSync(outDir, { recursive: true });
    const client = createClient({ packageRoot: pkg, cwd: pkg });
    const result = await client.debugExport({
      outDir,
      tag: "js-test",
      filesFrom: join("fixtures", "filelist.txt"),
      modules: ["comb_adder_cloud"],
    });

    expect(isDebugExportResult(result)).toBe(true);
    expect(result.schema_version).toBe("0");
    expect(result.tag).toBe("js-test");
    expect(result.files.length).toBeGreaterThanOrEqual(1);
    expect(existsSync(result.dir) || existsSync(outDir)).toBe(true);
  }, 180_000);
});
