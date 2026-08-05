// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

import { describe, expect, test } from "bun:test";
import {
  generateManId,
  looksLikeManId,
  markdownToHtml,
  parseManPositionals,
  shouldOpenBrowserForHuman,
} from "../src/tooling/man.ts";

describe("man id helpers", () => {
  test("generateManId shape", () => {
    const id = generateManId();
    expect(id.startsWith("man-")).toBe(true);
    expect(looksLikeManId(id)).toBe(true);
  });

  test("looksLikeManId", () => {
    expect(looksLikeManId("man-deadbeef")).toBe(true);
    expect(looksLikeManId("How does probe work?")).toBe(false);
    expect(looksLikeManId("build-platform/AGENTS.md")).toBe(false);
  });
});

describe("parseManPositionals", () => {
  test("query only", () => {
    const p = parseManPositionals(["How", "does", "probe", "work?"], process.cwd());
    expect(p.id).toBeUndefined();
    expect(p.files).toEqual([]);
    expect(p.query).toBe("How does probe work?");
  });

  test("id then query", () => {
    const p = parseManPositionals(["man-abc12345", "follow-up", "question"], process.cwd());
    expect(p.id).toBe("man-abc12345");
    expect(p.query).toBe("follow-up question");
  });
});

describe("markdownToHtml", () => {
  test("renders headings and code", () => {
    const html = markdownToHtml("## Title\n\nUse `probe`.\n\n```bash\n./build.sh probe\n```\n", {
      id: "man-test",
      query: "How to probe?",
      title: "Probe",
    });
    expect(html).toContain("<h2>Title</h2>");
    expect(html).toContain("<code>probe</code>");
    expect(html).toContain("build.sh probe");
    expect(html).toContain("man-test");
  });
});

describe("human browser policy", () => {
  test("CI skips browser", () => {
    const prev = process.env.CI;
    process.env.CI = "1";
    expect(shouldOpenBrowserForHuman(false)).toBe(false);
    expect(shouldOpenBrowserForHuman(true)).toBe(true);
    if (prev === undefined) delete process.env.CI;
    else process.env.CI = prev;
  });
});
