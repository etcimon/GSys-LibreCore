// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// motherboard.test.ts — Unit tests for the `mb` command + engine + pcbparts client.
//
// No network and no real repo mutation: everything runs against a temp dir with
// synthetic board.json specs. Network-facing pcbparts calls are exercised only
// in their cache-first / stub (network-disabled) paths.

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { DEFAULT_CONFIG } from "../src/config/defaults.ts";
import { validateConfig } from "../src/config/load.ts";
import { mbCommand } from "../src/cli/commands/mb.ts";
import type { PlatformContext } from "../src/context.ts";
import { Logger } from "../src/util/log.ts";
import { PcbPartsClient, PCBPARTS_TOOLS } from "../src/tooling/pcbparts.ts";
import {
  boardPaths,
  checkCompatibility,
  generateBoardMakefile,
  generateBoardPackage,
  listBoards,
  loadBoardSpec,
  renderOverlay,
  requiredControllerIds,
  scaffoldBoard,
  writeGeneratedArtifacts,
  type BoardSpec,
} from "../src/tooling/motherboard.ts";

function cloneConfig() {
  return JSON.parse(JSON.stringify(DEFAULT_CONFIG)) as typeof DEFAULT_CONFIG;
}

function makeCtx(root: string): PlatformContext {
  const config = cloneConfig();
  const wsRoot = join(root, "build-platform", "workspace");
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
      os: "linux",
      arch: "x64",
      cpuCount: 4,
      home: root,
      exeSuffix: "",
      pathSep: ":",
      defaultShell: "bash",
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

function sampleSpec(overrides: Partial<BoardSpec> = {}): BoardSpec {
  return {
    boardid: "testboard",
    name: "Test Board",
    vendor: "ACME",
    status: "reference",
    class: "fpga",
    skidl: "omitted",
    core: {
      config: "cv64a6_imafdc_sv39",
      xlen: 64,
      extensions: ["i", "m", "a", "f", "d", "c", "zicsr", "zifencei"],
      isaString: "rv64imafdc",
    },
    apu: {
      axiDataWidth: 64,
      noc: "axi4",
      socket: { enabled: false },
      controllers: [{ id: "litedram", enable: false }],
    },
    interfaces: [
      { id: "eth0", domain: "network", kind: "rgmii", phy: "RTL8211E", count: 1 },
      { id: "uart0", domain: "peripheral", kind: "uart", count: 1 },
    ],
    phys: [{ ref: "eth_phy", interface: "rgmii", mpn: "RTL8211E", status: "documented" }],
    ...overrides,
  };
}

function writeBoard(root: string, id: string, spec: BoardSpec): void {
  const dir = join(root, "corev-mb", "boards", id);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "board.json"), JSON.stringify(spec, null, 2));
}

describe("config: motherboard defaults", () => {
  test("DEFAULT_CONFIG validates with an inactive board", () => {
    expect(() => validateConfig(DEFAULT_CONFIG)).not.toThrow();
    expect(DEFAULT_CONFIG.motherboard.activeBoard).toBeNull();
    expect(DEFAULT_CONFIG.motherboard.pcbParts.mcpUrl).toStartWith("http");
  });

  test("invalid pcbParts url is rejected", () => {
    const cfg = cloneConfig();
    cfg.motherboard.pcbParts.mcpUrl = "not-a-url";
    expect(() => validateConfig(cfg)).toThrow();
  });
});

describe("motherboard engine", () => {
  let tmp: string;
  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), "mb-test-"));
  });
  afterEach(() => {
    rmSync(tmp, { recursive: true, force: true });
  });

  test("loadBoardSpec reads + validates board.json", async () => {
    const ctx = makeCtx(tmp);
    writeBoard(tmp, "testboard", sampleSpec());
    const spec = await loadBoardSpec(ctx, "testboard");
    expect(spec.boardid).toBe("testboard");
    expect(spec.core.config).toBe("cv64a6_imafdc_sv39");
  });

  test("loadBoardSpec rejects a mismatched boardid", async () => {
    const ctx = makeCtx(tmp);
    writeBoard(tmp, "testboard", sampleSpec({ boardid: "wrong" }));
    await expect(loadBoardSpec(ctx, "testboard")).rejects.toThrow();
  });

  test("loadBoardSpec rejects xlen/config inconsistency", async () => {
    const ctx = makeCtx(tmp);
    writeBoard(tmp, "bad", sampleSpec({ boardid: "bad", core: { config: "cv32a6_imac_sv32", xlen: 64, extensions: [] } }));
    await expect(loadBoardSpec(ctx, "bad")).rejects.toThrow();
  });

  test("checkCompatibility flags config + extension deltas", () => {
    const cfg = cloneConfig();
    const ok = checkCompatibility(cfg, sampleSpec());
    expect(ok.ok).toBe(true);

    const spec = sampleSpec({ core: { config: "cv32a6_imac_sv32", xlen: 32, extensions: ["i", "m", "a", "c", "zbb"] } });
    const bad = checkCompatibility(cfg, spec);
    expect(bad.ok).toBe(false);
    expect(bad.issues.some((i) => i.field === "soc.coreConfig")).toBe(true);
    expect(bad.missingExtensions).toContain("zbb");
  });

  test("requiredControllerIds returns only enabled controllers", () => {
    const spec = sampleSpec({
      apu: {
        controllers: [
          { id: "litedram", enable: true },
          { id: "verilog-ethernet", enable: false },
        ],
      },
    });
    expect(requiredControllerIds(spec)).toEqual(["litedram"]);
  });

  test("generateBoardPackage emits localparams for controllers + interfaces", () => {
    const sv = generateBoardPackage(sampleSpec());
    expect(sv).toContain("package testboard_board_pkg;");
    expect(sv).toContain('localparam string CoreConfig    = "cv64a6_imafdc_sv39";');
    expect(sv).toContain("localparam bit MbCtrl_litedram_En = 1'b0;");
    expect(sv).toContain("MbIf_ETH0_En");
    expect(sv).toContain('MbIf_ETH0_Phy = "RTL8211E";');
    // Non-AI boards stay MbAi_En=0 (additive optional ai{}).
    expect(sv).toContain("localparam bit MbAi_En = 1'b0;");
    expect(sv).toContain("endpackage : testboard_board_pkg");
  });

  test("generateBoardMakefile carries board + core config", () => {
    const mk = generateBoardMakefile(sampleSpec());
    expect(mk).toContain("CVA6_MB_BOARD      := testboard");
    expect(mk).toContain("CVA6_MB_CORE_CFG   := cv64a6_imafdc_sv39");
  });

  test("writeGeneratedArtifacts respects dry-run then writes", async () => {
    const ctx = makeCtx(tmp);
    const spec = sampleSpec();
    const paths = boardPaths(ctx, "testboard");

    const dry = await writeGeneratedArtifacts(ctx, spec, { dryRun: true });
    expect(dry.wrote).toBe(false);
    expect(existsSync(paths.packageFile)).toBe(false);

    const real = await writeGeneratedArtifacts(ctx, spec, {});
    expect(real.wrote).toBe(true);
    expect(existsSync(paths.packageFile)).toBe(true);
    expect(existsSync(paths.makefileSnippet)).toBe(true);
  });

  test("renderOverlay pins the active board + core config", () => {
    const overlay = renderOverlay(sampleSpec());
    expect(overlay).toContain('activeBoard: "testboard"');
    expect(overlay).toContain('coreConfig: "cv64a6_imafdc_sv39"');
    expect(overlay).toContain("defineBuildConfig");
  });

  test("listBoards separates selectable from documented-only", async () => {
    const ctx = makeCtx(tmp);
    writeBoard(tmp, "testboard", sampleSpec());
    mkdirSync(join(tmp, "corev-mb", "architecture", "analysisonly"), { recursive: true });

    const boards = await listBoards(ctx);
    const byId = Object.fromEntries(boards.map((b) => [b.boardid, b]));
    expect(byId["testboard"]?.selectable).toBe(true);
    expect(byId["analysisonly"]?.selectable).toBe(false);
    expect(byId["analysisonly"]?.documented).toBe(true);
  });

  test("scaffoldBoard creates board.json (+ design.py for custom)", async () => {
    const ctx = makeCtx(tmp);
    const res = await scaffoldBoard(ctx, "newcustom", { skidl: "custom", xlen: 64 });
    const paths = boardPaths(ctx, "newcustom");
    expect(res.dryRun).toBe(false);
    expect(existsSync(paths.specFile)).toBe(true);
    expect(existsSync(paths.designFile)).toBe(true);
  });

  test("scaffoldBoard --ai pins g6lc64_ai and starter ai{}", async () => {
    const ctx = makeCtx(tmp);
    const res = await scaffoldBoard(ctx, "aiboard", { skidl: "custom", ai: true });
    expect(res.spec.core.config).toBe("g6lc64_ai");
    expect(res.spec.core.xlen).toBe(64);
    expect(res.spec.ai?.enabled).toBe(true);
    expect(res.spec.ai?.uioConnectors?.island0?.kind).toBe("uio-mmio");
    expect(res.spec.interfaces.some((i) => i.id === "ai0")).toBe(true);
    const sv = generateBoardPackage(res.spec);
    expect(sv).toContain("localparam bit MbAi_En = 1'b1;");
  });

  test("class virtual + status custom loads (virt-ai-pcie shape)", async () => {
    const ctx = makeCtx(tmp);
    const virt = sampleSpec({
      boardid: "virt-ai-pcie",
      name: "Virtual PCIe AI card (sim)",
      vendor: "GSys",
      status: "custom",
      class: "virtual",
      skidl: "omitted",
      core: {
        config: "g6lc64_ai",
        xlen: 64,
        extensions: ["i", "m", "a", "f", "d", "c"],
        isaString: "rv64imafdc_xg6lcai",
      },
      ai: {
        enabled: true,
        primaryUio: "island0",
        uioConnectors: {
          island0: {
            kind: "soft-sticky",
            path: "virt://virt-ai-pcie/island0",
            target: "island0",
          },
          island0_irq: {
            kind: "eventfd",
            path: "virt://virt-ai-pcie/island0_irq",
            target: "island0",
          },
        },
      },
    });
    writeBoard(tmp, "virt-ai-pcie", virt);
    const spec = await loadBoardSpec(ctx, "virt-ai-pcie");
    expect(spec.class).toBe("virtual");
    expect(spec.status).toBe("custom");
    expect(spec.skidl).toBe("omitted");
    expect(spec.ai?.uioConnectors?.island0?.kind).toBe("soft-sticky");
    const pkg = generateBoardPackage(spec);
    expect(pkg).toContain("localparam bit MbAi_En = 1'b1;");
    expect(pkg).toContain('BoardClass    = "virtual"');
    expect(pkg).toContain("soft-sticky");
  });
});

describe("pcbparts client (offline paths)", () => {
  let tmp: string;
  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), "pcb-test-"));
  });
  afterEach(() => {
    rmSync(tmp, { recursive: true, force: true });
  });

  test("listTools returns the 14 tool names when offline", async () => {
    const client = new PcbPartsClient({
      url: "https://pcbparts.dev/mcp",
      timeoutMs: 1000,
      retries: 0,
      cacheDir: join(tmp, "cache"),
      logger: new Logger({ level: "silent" }),
      allowNetwork: false,
    });
    const tools = await client.listTools();
    expect(tools).toEqual([...PCBPARTS_TOOLS]);
  });

  test("callTool returns a stub when network is disabled (no cache)", async () => {
    const client = new PcbPartsClient({
      url: "https://pcbparts.dev/mcp",
      timeoutMs: 1000,
      retries: 0,
      cacheDir: join(tmp, "cache"),
      logger: new Logger({ level: "silent" }),
      allowNetwork: false,
    });
    const res = await client.jlcSearch({ query: "rgmii phy" });
    expect(res.source).toBe("stub");
    expect(res.ok).toBe(true);
    expect(res.data).toBeNull();
  });
});

describe("mb command", () => {
  let tmp: string;
  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), "mbcmd-test-"));
    mkdirSync(join(tmp, "build-platform"), { recursive: true });
  });
  afterEach(() => {
    rmSync(tmp, { recursive: true, force: true });
  });

  test("mb list returns 0", async () => {
    const ctx = makeCtx(tmp);
    writeBoard(tmp, "testboard", sampleSpec());
    const code = await mbCommand.run({ ctx, positionals: ["list"], flags: {}, logger: ctx.logger });
    expect(code).toBe(0);
  });

  test("mb check returns 0 when compatible, 3 when not", async () => {
    const ctx = makeCtx(tmp);
    writeBoard(tmp, "testboard", sampleSpec());
    writeBoard(tmp, "mismatch", sampleSpec({ boardid: "mismatch", core: { config: "cv32a6_imac_sv32", xlen: 32, extensions: ["i", "m", "a", "c"] } }));

    const ok = await mbCommand.run({ ctx, positionals: ["check", "testboard"], flags: {}, logger: ctx.logger });
    expect(ok).toBe(0);
    const bad = await mbCommand.run({ ctx, positionals: ["check", "mismatch"], flags: {}, logger: ctx.logger });
    expect(bad).toBe(3);
  });

  test("mb select (real) writes overlay + generated package", async () => {
    const ctx = makeCtx(tmp);
    writeBoard(tmp, "testboard", sampleSpec());
    const code = await mbCommand.run({ ctx, positionals: ["select", "testboard"], flags: {}, logger: ctx.logger });
    expect(code).toBe(0);
    expect(existsSync(join(tmp, "build-platform", ".config.local.ts"))).toBe(true);
    expect(existsSync(boardPaths(ctx, "testboard").packageFile)).toBe(true);
  });

  test("mb select --dry-run writes nothing", async () => {
    const ctx = makeCtx(tmp);
    writeBoard(tmp, "testboard", sampleSpec());
    const code = await mbCommand.run({ ctx, positionals: ["select", "testboard"], flags: { "dry-run": true }, logger: ctx.logger });
    expect(code).toBe(0);
    expect(existsSync(join(tmp, "build-platform", ".config.local.ts"))).toBe(false);
    expect(existsSync(boardPaths(ctx, "testboard").packageFile)).toBe(false);
  });

  test("mb create scaffolds a custom board", async () => {
    const ctx = makeCtx(tmp);
    const code = await mbCommand.run({
      ctx,
      positionals: ["create", "brandnew"],
      flags: { class: "custom" },
      logger: ctx.logger,
    });
    expect(code).toBe(0);
    expect(existsSync(boardPaths(ctx, "brandnew").specFile)).toBe(true);
  });

  test("mb unknown subcommand returns 1", async () => {
    const ctx = makeCtx(tmp);
    const code = await mbCommand.run({ ctx, positionals: ["frobnicate"], flags: {}, logger: ctx.logger });
    expect(code).toBe(1);
  });
});
