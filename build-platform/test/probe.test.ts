// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

import { describe, expect, test } from "bun:test";
import { renderBox, renderTabStrip, statusValue } from "../src/util/box.ts";
import {
  PROBE_CATEGORIES,
  resolveProbeCategory,
} from "../src/tooling/probe.ts";

describe("probe categories", () => {
  test("lists expected tabs", () => {
    const ids = PROBE_CATEGORIES.map((c) => c.id);
    expect(ids).toContain("host");
    expect(ids).toContain("platform");
    expect(ids).toContain("pkg");
    expect(ids).toContain("utils");
    expect(ids).toContain("tools");
    expect(ids).toContain("env");
    expect(ids).toContain("diag");
    expect(ids).toContain("commands");
    expect(ids).toContain("install");
  });

  test("resolveProbeCategory aliases", () => {
    expect(resolveProbeCategory("pkg")?.id).toBe("pkg");
    expect(resolveProbeCategory("package-managers")?.id).toBe("pkg");
    expect(resolveProbeCategory("tooling")?.id).toBe("tools");
    expect(resolveProbeCategory("environment")?.id).toBe("env");
    expect(resolveProbeCategory("diagnostics")?.id).toBe("diag");
    expect(resolveProbeCategory("cmds")?.id).toBe("commands");
    expect(resolveProbeCategory("nope")).toBeUndefined();
  });
});

describe("box renderer", () => {
  test("renders framed box with title", () => {
    const out = renderBox(
      [
        { label: "OS", value: "windows", tone: "ok" },
        { label: "Bun", value: "not found", tone: "miss" },
      ],
      { title: "Host", tabId: "host", color: false, width: 48 },
    );
    expect(out).toContain("Host");
    expect(out).toContain("[host]");
    expect(out).toContain("OS");
    expect(out).toContain("windows");
    expect(out).toContain("┌");
    expect(out).toContain("└");
  });

  test("tab strip marks active", () => {
    const out = renderTabStrip(
      [
        { id: "host", label: "Host", active: true },
        { id: "pkg", label: "Pkg", missing: 2 },
      ],
      { color: false },
    );
    expect(out).toContain("[Host]");
    expect(out).toContain("Pkg");
    expect(out).toContain("(2↓)");
  });

  test("statusValue tones", () => {
    expect(statusValue(false, null).tone).toBe("miss");
    expect(statusValue(true, "1.2.3").tone).toBe("ok");
    expect(statusValue(true, null).value).toBe("present");
  });
});
