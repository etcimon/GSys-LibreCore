// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// vendor.test.ts — Unit tests for the `vendor` command and its engine.
//
// These tests exercise the underlying behaviour of every `vendor` subcommand
// (list, status, sync, add, update, scan) without touching the network or
// modifying the real repository. They run with `bun run self-test`.

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { DEFAULT_CONFIG } from "../src/config/defaults.ts";
import type { VendorControllerSpec } from "../src/config/schema.ts";
import { vendorCommand } from "../src/cli/commands/vendor.ts";
import type { PlatformContext } from "../src/context.ts";
import { Logger } from "../src/util/log.ts";
import {
  checkoutStatuses,
  controllerPath,
  findController,
  needsScan,
  scanController,
  selectControllers,
  syncController,
  syncControllers,
  updateController,
} from "../src/tooling/vendor.ts";

function cloneConfig() {
  return JSON.parse(JSON.stringify(DEFAULT_CONFIG)) as typeof DEFAULT_CONFIG;
}

function baseController(
  id: string,
  overrides?: Partial<VendorControllerSpec>,
): VendorControllerSpec {
  return {
    id,
    description: `controller ${id}`,
    domain: "peripheral",
    kind: "controller",
    mechanism: "submodule",
    url: `https://example.com/${id}.git`,
    path: `vendor/${id}`,
    license: "MIT",
    status: "planned",
    enabled: false,
    ...overrides,
  };
}

function makeCtx(
  root: string,
  controllers: VendorControllerSpec[] = [],
): PlatformContext {
  const config = cloneConfig();
  config.vendor.controllers = controllers;
  const wsRoot = join(root, "workspace");
  const cache = join(wsRoot, ".cache");
  const tooling = join(wsRoot, "tooling");
  return {
    config,
    repoRoot: root,
    dryRun: false,
    logger: new Logger({ level: "silent" }),
    configPath: null,
    overlayPath: null,
    host: {
      os: "windows",
      arch: "x64",
      cpuCount: 4,
      home: root,
      exeSuffix: ".exe",
      pathSep: ";",
      defaultShell: "pwsh",
    },
    paths: {
      root: wsRoot,
      build: join(wsRoot, "build"),
      tooling,
      toolsBin: join(tooling, "bin"),
      pythonVenv: join(tooling, "python-venv"),
      cache,
      downloads: join(cache, "downloads"),
      manifests: join(cache, "manifests"),
    },
    tools: {
      riscv: "",
      riscvBin: "",
      verilator: "",
      verilatorBin: "",
      spike: "",
      spikeBin: "",
      iverilog: "",
      iverilogBin: "",
      dtc: "",
      pythonVenvBin: "",
    },
    derived: { clockPeriodNs: 10 },
  } as unknown as PlatformContext;
}

describe("vendor tooling", () => {
  let tmp: string;

  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), "vendor-test-"));
  });

  afterEach(() => {
    rmSync(tmp, { recursive: true, force: true });
  });

  test("controllerPath joins repoRoot and spec.path", () => {
    const ctx = makeCtx(tmp);
    const spec = baseController("abc");
    expect(controllerPath(ctx, spec)).toBe(join(tmp, "vendor/abc"));
  });

  test("findController returns matching spec or undefined", () => {
    const a = baseController("a");
    const b = baseController("b");
    const ctx = makeCtx(tmp, [a, b]);
    expect(findController(ctx, "a")).toBe(a);
    expect(findController(ctx, "missing")).toBeUndefined();
  });

  test("needsScan uses defaults and custom scanOn", () => {
    const spec = baseController("c");
    expect(needsScan(spec, "on-fetch")).toBe(true);
    expect(needsScan(spec, "manual")).toBe(false);
    expect(needsScan({ ...spec, scanOn: ["manual"] }, "manual")).toBe(true);
    expect(needsScan({ ...spec, scanOn: ["manual"] }, "on-fetch")).toBe(false);
  });

  test("selectControllers by ids, all, enabled, and unknown", () => {
    const a = baseController("a", { enabled: true });
    const b = baseController("b");
    const ctx = makeCtx(tmp, [a, b]);

    expect(selectControllers(ctx, { ids: ["a"] })).toEqual({
      selected: [a],
      unknown: [],
    });
    expect(selectControllers(ctx, { ids: ["a", "missing"] }).unknown).toEqual([
      "missing",
    ]);
    expect(selectControllers(ctx, { all: true }).selected).toHaveLength(2);
    expect(selectControllers(ctx, {}).selected).toEqual([a]);
  });

  test("checkoutStatuses reports exists and registered", async () => {
    const a = baseController("a");
    const ctx = makeCtx(tmp, [a]);

    let statuses = await checkoutStatuses(ctx);
    expect(statuses).toHaveLength(1);
    expect(statuses[0]!.exists).toBe(false);
    expect(statuses[0]!.registered).toBe(false);

    mkdirSync(join(tmp, "vendor", "a"), { recursive: true });
    writeFileSync(join(tmp, "vendor", "a", "file.txt"), "");
    statuses = await checkoutStatuses(ctx);
    expect(statuses[0]!.exists).toBe(true);

    writeFileSync(
      join(tmp, ".gitmodules"),
      '[submodule "a"]\n\tpath = vendor/a\n\turl = https://example.com/a.git\n',
    );
    statuses = await checkoutStatuses(ctx);
    expect(statuses[0]!.registered).toBe(true);
  });

  test("syncController dry-run submodule add when absent", async () => {
    const a = baseController("a");
    const ctx = makeCtx(tmp, [a]);
    const res = await syncController(ctx, a, { dryRun: true });
    expect(res.ok).toBe(true);
    expect(res.skipped).toBe(true);
    expect(res.action).toBe("add");
  });

  test("syncController dry-run submodule update when present/registered", async () => {
    const a = baseController("a");
    mkdirSync(join(tmp, "vendor", "a"), { recursive: true });
    writeFileSync(join(tmp, "vendor", "a", "file.txt"), "");
    writeFileSync(
      join(tmp, ".gitmodules"),
      '[submodule "a"]\n\tpath = vendor/a\n',
    );
    const ctx = makeCtx(tmp, [a]);
    const res = await syncController(ctx, a, { dryRun: true });
    expect(res.ok).toBe(true);
    expect(res.skipped).toBe(true);
    expect(res.action).toBe("update");
  });

  test("syncController dry-run vendor snapshot", async () => {
    const a = baseController("a", { mechanism: "vendor" });
    const ctx = makeCtx(tmp, [a]);
    const res = await syncController(ctx, a, { dryRun: true });
    expect(res.ok).toBe(true);
    expect(res.skipped).toBe(true);
    expect(res.action).toBe("vendor");
  });

  test("syncControllers handles unknown ids and selection", async () => {
    const a = baseController("a");
    const b = baseController("b", { enabled: true });
    const ctx = makeCtx(tmp, [a, b]);

    const missing = await syncControllers(ctx, { ids: ["unknown"], dryRun: true });
    expect(missing).toHaveLength(1);
    expect(missing[0]!.ok).toBe(false);
    expect(missing[0]!.skipped).toBe(true);
    expect(missing[0]!.reason).toBe("unknown id");

    const all = await syncControllers(ctx, { all: true, dryRun: true });
    expect(all).toHaveLength(2);
    expect(all.every((r) => r.ok && r.skipped)).toBe(true);
  });

  test("updateController dry-run falls back to add for missing submodule", async () => {
    const a = baseController("a");
    const ctx = makeCtx(tmp, [a]);
    const res = await updateController(ctx, "a", undefined, true);
    expect(res.ok).toBe(true);
    expect(res.skipped).toBe(true);
    expect(res.action).toBe("add");
  });

  test("updateController dry-run updates present submodule", async () => {
    const a = baseController("a");
    mkdirSync(join(tmp, "vendor", "a"), { recursive: true });
    writeFileSync(join(tmp, "vendor", "a", "file.txt"), "");
    const ctx = makeCtx(tmp, [a]);
    const res = await updateController(ctx, "a", "v2", true);
    expect(res.ok).toBe(true);
    expect(res.skipped).toBe(true);
    expect(res.action).toBe("update");
    expect(res.ref).toBe("v2");
  });

  test("updateController dry-run vendor snapshot", async () => {
    const a = baseController("a", { mechanism: "vendor" });
    const ctx = makeCtx(tmp, [a]);
    const res = await updateController(ctx, "a", "v2", true);
    expect(res.ok).toBe(true);
    expect(res.skipped).toBe(true);
    expect(res.action).toBe("vendor");
  });

  test("scanController returns empty when path absent", async () => {
    const a = baseController("a");
    const ctx = makeCtx(tmp, [a]);
    const res = await scanController(ctx, a);
    expect(res.exists).toBe(false);
    expect(res.files).toEqual([]);
  });

  test("scanController enumerates RTL files and ignores .git", async () => {
    const a = baseController("a", { scanPaths: ["rtl"] });
    const ctx = makeCtx(tmp, [a]);
    const rtlDir = join(tmp, "vendor", "a", "rtl");
    mkdirSync(rtlDir, { recursive: true });
    writeFileSync(join(rtlDir, "top.sv"), "");
    writeFileSync(join(rtlDir, "pkg.svh"), "");
    writeFileSync(join(rtlDir, "readme.md"), "");
    mkdirSync(join(rtlDir, ".git"), { recursive: true });
    writeFileSync(join(rtlDir, ".git", "config"), "");

    const res = await scanController(ctx, a);
    expect(res.exists).toBe(true);
    expect(res.files).toHaveLength(2);
    expect(res.byExtension[".sv"]).toBe(1);
    expect(res.byExtension[".svh"]).toBe(1);
    expect(res.scannedRoots).toEqual([rtlDir]);
  });

  test("vendorCommand list returns 0", async () => {
    const ctx = makeCtx(tmp, [baseController("a")]);
    const code = await vendorCommand.run({
      ctx,
      positionals: ["list"],
      flags: {},
      logger: ctx.logger,
    });
    expect(code).toBe(0);
  });

  test("vendorCommand default subcommand is list", async () => {
    const ctx = makeCtx(tmp, [baseController("a")]);
    const code = await vendorCommand.run({
      ctx,
      positionals: [],
      flags: {},
      logger: ctx.logger,
    });
    expect(code).toBe(0);
  });

  test("vendorCommand status returns 0", async () => {
    const ctx = makeCtx(tmp, [baseController("a")]);
    const code = await vendorCommand.run({
      ctx,
      positionals: ["status"],
      flags: {},
      logger: ctx.logger,
    });
    expect(code).toBe(0);
  });

  test("vendorCommand sync/add/update respect dry-run and errors", async () => {
    const a = baseController("a");
    const ctx = makeCtx(tmp, [a]);
    ctx.dryRun = true;

    expect(
      await vendorCommand.run({
        ctx,
        positionals: ["sync", "a"],
        flags: {},
        logger: ctx.logger,
      }),
    ).toBe(0);

    expect(
      await vendorCommand.run({
        ctx,
        positionals: ["add"],
        flags: {},
        logger: ctx.logger,
      }),
    ).toBe(1);

    expect(
      await vendorCommand.run({
        ctx,
        positionals: ["add", "a"],
        flags: {},
        logger: ctx.logger,
      }),
    ).toBe(0);

    expect(
      await vendorCommand.run({
        ctx,
        positionals: ["update"],
        flags: {},
        logger: ctx.logger,
      }),
    ).toBe(1);

    expect(
      await vendorCommand.run({
        ctx,
        positionals: ["update", "a"],
        flags: { ref: "v2" },
        logger: ctx.logger,
      }),
    ).toBe(0);
  });

  test("vendorCommand scan reports missing or found RTL", async () => {
    const a = baseController("a", { scanPaths: ["rtl"] });
    const ctx = makeCtx(tmp, [a]);

    const missing = await vendorCommand.run({
      ctx,
      positionals: ["scan", "a"],
      flags: {},
      logger: ctx.logger,
    });
    expect(missing).toBe(1);

    const rtlDir = join(tmp, "vendor", "a", "rtl");
    mkdirSync(rtlDir, { recursive: true });
    writeFileSync(join(rtlDir, "top.sv"), "");

    const found = await vendorCommand.run({
      ctx,
      positionals: ["scan", "a"],
      flags: {},
      logger: ctx.logger,
    });
    expect(found).toBe(0);
  });

  test("vendorCommand unknown subcommand returns 1", async () => {
    const ctx = makeCtx(tmp, [baseController("a")]);
    const code = await vendorCommand.run({
      ctx,
      positionals: ["nope"],
      flags: {},
      logger: ctx.logger,
    });
    expect(code).toBe(1);
  });
});
