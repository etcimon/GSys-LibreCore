// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// ai-board.test.ts — Unit tests for AI island board factoring (mb + UIO).

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { DEFAULT_CONFIG } from "../src/config/defaults.ts";
import type { PlatformContext } from "../src/context.ts";
import { Logger } from "../src/util/log.ts";
import {
  AI_BOARD_DEFAULTS,
  generateAiDtsFragment,
  generateAiTensorEnv,
  resolveAiBoard,
  starterAiSpec,
  validateBoardAi,
} from "../src/tooling/ai-board.ts";
import {
  generateBoardPackage,
  loadBoardSpec,
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

function baseSpec(overrides: Partial<BoardSpec> = {}): BoardSpec {
  return {
    boardid: "testboard",
    name: "Test Board",
    vendor: "ACME",
    status: "custom",
    class: "custom",
    skidl: "custom",
    core: {
      config: "g6lc64_ai",
      xlen: 64,
      extensions: ["i", "m", "a", "f", "d", "c", "zicsr", "zifencei"],
    },
    apu: { axiDataWidth: 64, noc: "axi4", socket: { enabled: false }, controllers: [] },
    interfaces: [],
    phys: [],
    ...overrides,
  };
}

describe("ai-board resolve / validate", () => {
  test("resolveAiBoard null when no ai", () => {
    expect(resolveAiBoard(baseSpec())).toBeNull();
  });

  test("resolveAiBoard null when ai.enabled=false", () => {
    expect(resolveAiBoard(baseSpec({ ai: { enabled: false } }))).toBeNull();
  });

  test("resolveAiBoard fills defaults + default connector", () => {
    const r = resolveAiBoard(baseSpec({ ai: { enabled: true } }));
    expect(r).not.toBeNull();
    expect(r!.mmioBase).toBe(AI_BOARD_DEFAULTS.mmioBase);
    expect(r!.plicSource).toBe(AI_BOARD_DEFAULTS.plicSource);
    expect(r!.accTileM).toBe(256);
    expect(r!.profileId).toBe("island-p3-v1");
    expect(r!.connectors.length).toBe(1);
    expect(r!.connectors[0]!.id).toBe("island0");
    expect(r!.connectors[0]!.kind).toBe("uio-mmio");
    expect(r!.primaryUioPath).toBe("/dev/uio0");
  });

  test("resolveAiBoard keeps explicit uioConnectors by id", () => {
    const r = resolveAiBoard(
      baseSpec({
        ai: {
          enabled: true,
          primaryUio: "island0",
          uioConnectors: {
            island0: { kind: "uio-mmio", path: "/dev/uio1", target: "island0" },
            island0_irq: { kind: "eventfd", target: "island0" },
          },
        },
      }),
    );
    expect(r!.connectors.map((c) => c.id).sort()).toEqual(["island0", "island0_irq"]);
    expect(r!.primaryUioPath).toBe("/dev/uio1");
  });

  test("resolveAiBoard accepts soft-sticky primary (virt-ai-pcie CI path)", () => {
    const r = resolveAiBoard(
      baseSpec({
        boardid: "virt-ai-pcie",
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
      }),
    );
    expect(r).not.toBeNull();
    expect(r!.primaryUioId).toBe("island0");
    expect(r!.primaryUioPath).toBe("virt://virt-ai-pcie/island0");
    expect(r!.connectors.find((c) => c.id === "island0")?.kind).toBe("soft-sticky");
    const env = generateAiTensorEnv(r!);
    expect(env).toContain("AI_TENSOR_BOARD_ID=virt-ai-pcie");
    expect(env).toContain("AI_TENSOR_UIO=virt://virt-ai-pcie/island0");
    expect(validateBoardAi(r && {
      enabled: true,
      primaryUio: "island0",
      uioConnectors: {
        island0: { kind: "soft-sticky", path: "virt://virt-ai-pcie/island0" },
        island0_irq: { kind: "eventfd", path: "virt://virt-ai-pcie/island0_irq" },
      },
    }, "virt-ai-pcie")).toEqual([]);
  });

  test("generateAiDtsFragment contains board-id and plic", () => {
    const r = resolveAiBoard(baseSpec({ boardid: "ai-card", ai: starterAiSpec("ai-card") }))!;
    const dts = generateAiDtsFragment(r);
    expect(dts).toContain('g6lc,board-id = "ai-card"');
    expect(dts).toContain("interrupts = <8>");
    expect(dts).toContain("ai-matrix@40000000");
    expect(dts).toContain('compatible = "g6lc,ai-matrix"');
    expect(dts).toContain('g6lc,uio-primary = "island0"');
  });

  test("validate rejects bad uio kind", () => {
    const issues = validateBoardAi(
      {
        enabled: true,
        uioConnectors: {
          bad: { kind: "not-a-real-kind" },
        },
      },
      "x",
    );
    expect(issues.some((i) => i.includes("kind") && i.includes("not-a-real-kind"))).toBe(true);
  });

  test("validate accepts starterAiSpec", () => {
    expect(validateBoardAi(starterAiSpec("ai-card"), "ai-card")).toEqual([]);
  });
});

describe("ai-board package + artifacts", () => {
  let tmp: string;
  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), "ai-mb-"));
  });
  afterEach(() => {
    rmSync(tmp, { recursive: true, force: true });
  });

  test("generateBoardPackage with ai.enabled emits MbAi_En = 1", () => {
    const sv = generateBoardPackage(baseSpec({ ai: { enabled: true } }));
    expect(sv).toContain("localparam bit MbAi_En = 1'b1;");
    expect(sv).toContain("MbAi_PlicSource");
    expect(sv).toContain("MbAi_MmioBase");
  });

  test("generateBoardPackage without ai emits MbAi_En = 0", () => {
    const sv = generateBoardPackage(baseSpec());
    expect(sv).toContain("localparam bit MbAi_En = 1'b0;");
  });

  test("writeGeneratedArtifacts emits AI dtsi/profile/env when resolved", async () => {
    const ctx = makeCtx(tmp);
    const spec = baseSpec({
      boardid: "aicard",
      ai: starterAiSpec("aicard"),
    });
    const dir = join(tmp, "corev-mb", "boards", "aicard");
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "board.json"), JSON.stringify(spec, null, 2));

    const loaded = await loadBoardSpec(ctx, "aicard");
    const gen = await writeGeneratedArtifacts(ctx, loaded, {});
    expect(gen.wrote).toBe(true);
    expect(gen.aiDtsFile).toBeTruthy();
    expect(gen.aiProfileFile).toBeTruthy();
    expect(gen.aiEnvFile).toBeTruthy();
    expect(existsSync(gen.aiDtsFile!)).toBe(true);
    expect(existsSync(gen.aiProfileFile!)).toBe(true);
    expect(existsSync(gen.aiEnvFile!)).toBe(true);

    const env = readFileSync(gen.aiEnvFile!, "utf8");
    expect(env).toContain("export AI_TENSOR_BOARD_ID=aicard");
    expect(env).toContain("export AI_TENSOR_UIO=/dev/uio0");
    expect(env).toContain("export AI_TENSOR_MMIO_BASE=0x40000000");
    expect(env).toContain("export AI_TENSOR_PLIC_SOURCE=8");

    const profile = readFileSync(gen.aiProfileFile!, "utf8");
    expect(profile).toContain('board_id = "aicard"');
    expect(profile).toContain("plic_source = 8");
  });
});
