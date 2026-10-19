// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

import { describe, expect, test } from "bun:test";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { inspectBundle, sha256Hex } from "../src/tooling/mbBundle.ts";

async function bundleDir(files: Record<string, string>, manifest?: object): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "mbgen-bundle-"));
  for (const [name, text] of Object.entries(files)) await writeFile(join(dir, name), text, "utf8");
  if (manifest) await writeFile(join(dir, "manifest.json"), JSON.stringify(manifest), "utf8");
  return dir;
}

describe("mb ingest bundle inspection", () => {
  test("a lone platform.json is legacy, not an error", async () => {
    const platform = JSON.stringify({ boardid: "x" });
    const dir = await bundleDir({ "platform.json": platform });
    const check = await inspectBundle(join(dir, "platform.json"), platform);
    expect(check.mode).toBe("legacy");
    expect(check.issues).toEqual([]);
    expect(Object.keys(check.files)).toEqual([]);
  });

  test("a manifest-verified bundle yields the side files", async () => {
    const platform = JSON.stringify({ boardid: "x" });
    const circuit = JSON.stringify({ schema_version: 1, nets: [] }, null, 2);
    const layout = JSON.stringify({ units: "um" });
    const manifest = {
      schema_version: 2,
      circuit_sha256: sha256Hex(JSON.stringify(JSON.parse(circuit))),
      files: {
        "platform.json": { sha256: sha256Hex(platform) },
        "circuit.json": { sha256: sha256Hex(circuit) },
        "layout.json": { sha256: sha256Hex(layout) },
      },
    };
    const dir = await bundleDir({ "platform.json": platform, "circuit.json": circuit, "layout.json": layout }, manifest);
    const check = await inspectBundle(join(dir, "platform.json"), platform);
    expect(check.mode).toBe("bundle");
    expect(check.issues).toEqual([]);
    expect(Object.keys(check.files).sort()).toEqual(["circuit.json", "layout.json"]);
  });

  test("a drifted or missing file is refused, naming the file", async () => {
    const platform = JSON.stringify({ boardid: "x" });
    const circuit = JSON.stringify({ schema_version: 1 });
    const manifest = {
      schema_version: 2,
      files: {
        "platform.json": { sha256: sha256Hex(platform) },
        "circuit.json": { sha256: sha256Hex(circuit + " ") },
        "layout.json": { sha256: "0".repeat(64) },
      },
    };
    const dir = await bundleDir({ "platform.json": platform, "circuit.json": circuit }, manifest);
    const check = await inspectBundle(join(dir, "platform.json"), platform);
    expect(check.mode).toBe("bundle");
    expect(check.issues.some((i) => i.startsWith("circuit.json sha256"))).toBe(true);
    expect(check.issues.some((i) => i.startsWith("layout.json is listed"))).toBe(true);
    expect(check.files["circuit.json"]).toBeUndefined();
  });

  test("an edited platform.json inside a bundle is detected", async () => {
    const platform = JSON.stringify({ boardid: "x" });
    const manifest = { schema_version: 2, files: { "platform.json": { sha256: sha256Hex(platform) } } };
    const dir = await bundleDir({ "platform.json": platform }, manifest);
    const check = await inspectBundle(join(dir, "platform.json"), platform + "\n// edited");
    expect(check.issues.some((i) => i.startsWith("platform.json sha256"))).toBe(true);
  });
});
