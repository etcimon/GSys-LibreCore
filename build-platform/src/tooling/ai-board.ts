// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// ai-board.ts — Factor generic AI-island board defaults for the `mb` layer.
//
// Custom boards can opt into an optional `ai` object on board.json. On
// `mb select` / writeGeneratedArtifacts we emit:
//   - generated/<id>_ai.dtsi          (g6lc,ai-matrix fragment)
//   - generated/<id>_ai.profile.toml  (ai-tensor profile pin)
//   - generated/ai-tensor.env         (AI_TENSOR_* discovery exports)
//   - MbAi_* localparams in the board package
//
// Hardware defaults track ariane_soc AiIslandBase (0x4000_0000), PLIC source 8,
// AccTile 256, and the island-p3-v1 profile. See:
//   architecture/ai-matrix/board-uio-eventfd.md
//   corev_apu/bootrom/ariane-ai.dts
//   ai-tensor/profiles/island-p3-v1.toml
//
// Deliberately does NOT import BoardSpec from motherboard.ts (avoids cycles).

// ---------------------------------------------------------------------------
// Defaults (ariane_soc / ariane-ai.dts / island-p3-v1)
// ---------------------------------------------------------------------------

export const AI_BOARD_DEFAULTS = {
  /** ariane_soc::AiIslandBase / GPIO window. */
  mmioBase: 0x4000_0000,
  /** CAP + CTL + doorbell + regions + desc + PMU (4 KiB). */
  mmioSize: 0x1000,
  /** irq_sources[7] → PLIC ID 8. */
  plicSource: 8,
  /** I1 AccTile / Macs freeze. */
  accTileM: 256,
  accTileN: 256,
  accTileK: 256,
  macsPerCycle: 256,
  /** DTS-advertised queue geometry (CAP may report more). */
  queues: 1,
  queueDepth: 8,
  nocWidth: 64,
  profileId: "island-p3-v1",
  preferredCoreConfig: "g6lc64_ai",
  uioDeviceDefault: "/dev/uio0",
  features: [
    "t2_desc_v1",
    "completion_word_v1",
    "ai3_regions",
    "op_gemm",
    "dma_fetch",
    "wr_cpl_en",
    "plic_src8",
    "pmu_v1",
    "acc_tile_256",
  ],
} as const;

/** Allowed UIO / host-wait connector kinds (board.json ai.uioConnectors[].kind). */
export const AI_UIO_KINDS = ["uio-mmio", "eventfd", "devmem", "soft-sticky"] as const;
export type AiUioKind = (typeof AI_UIO_KINDS)[number];

// ---------------------------------------------------------------------------
// board.json `ai` shape
// ---------------------------------------------------------------------------

export interface BoardAiUioConnector {
  /** Connector id (also the key under uioConnectors). */
  id?: string;
  kind: string;
  /** Logical island target (e.g. "island0"). */
  target?: string;
  /** Host path when kind is uio-mmio (e.g. "/dev/uio0"). */
  path?: string;
  notes?: string;
}

export interface BoardAiSpec {
  /** When false, AI artifacts are suppressed even if `ai` is present. Default true if object present. */
  enabled?: boolean;
  mmioBase?: number | string;
  mmioSize?: number | string;
  plicSource?: number;
  accTileM?: number;
  accTileN?: number;
  accTileK?: number;
  macsPerCycle?: number;
  queues?: number;
  queueDepth?: number;
  nocWidth?: number;
  profileId?: string;
  /** Keyed by connector id — custom boards get UIO connectors by id. */
  uioConnectors?: Record<string, BoardAiUioConnector>;
  /** Preferred primary connector id for AI_TENSOR_UIO. */
  primaryUio?: string;
  features?: string[];
}

/** Minimal board view — avoids importing BoardSpec from motherboard.ts. */
export interface AiBoardView {
  boardid: string;
  core: { config: string };
  ai?: BoardAiSpec;
}

export interface ResolvedAiBoard {
  boardid: string;
  enabled: true;
  mmioBase: number;
  mmioSize: number;
  plicSource: number;
  accTileM: number;
  accTileN: number;
  accTileK: number;
  macsPerCycle: number;
  queues: number;
  queueDepth: number;
  nocWidth: number;
  profileId: string;
  /** Fully resolved connectors (id always set). */
  connectors: BoardAiUioConnector[];
  primaryUioId: string;
  primaryUioPath: string;
  features: string[];
}

// ---------------------------------------------------------------------------
// Validation / resolve
// ---------------------------------------------------------------------------

function parseNum(v: unknown, field: string, issues: string[]): number | undefined {
  if (v === undefined || v === null) return undefined;
  if (typeof v === "number" && Number.isFinite(v) && v >= 0) return Math.trunc(v);
  if (typeof v === "string") {
    const t = v.trim().toLowerCase();
    const n = t.startsWith("0x") ? Number.parseInt(t, 16) : Number.parseInt(t, 10);
    if (Number.isFinite(n) && n >= 0) return n;
  }
  issues.push(`ai.${field} must be a non-negative number (got ${JSON.stringify(v)}).`);
  return undefined;
}

/** Validate optional board.json `ai` object. Empty array when absent. */
export function validateBoardAi(raw: unknown, boardid: string): string[] {
  if (raw === undefined || raw === null) return [];
  const issues: string[] = [];
  if (typeof raw !== "object" || Array.isArray(raw)) {
    return [`ai must be an object (board '${boardid}').`];
  }
  const a = raw as Record<string, unknown>;
  if (a.enabled !== undefined && typeof a.enabled !== "boolean") {
    issues.push("ai.enabled must be a boolean.");
  }
  parseNum(a.mmioBase, "mmioBase", issues);
  parseNum(a.mmioSize, "mmioSize", issues);
  const plic = parseNum(a.plicSource, "plicSource", issues);
  if (plic !== undefined && plic < 1) issues.push("ai.plicSource must be >= 1.");
  for (const f of [
    "accTileM",
    "accTileN",
    "accTileK",
    "macsPerCycle",
    "queues",
    "queueDepth",
    "nocWidth",
  ] as const) {
    parseNum(a[f], f, issues);
  }
  if (a.profileId !== undefined && (typeof a.profileId !== "string" || a.profileId.length === 0)) {
    issues.push("ai.profileId must be a non-empty string.");
  }
  if (a.primaryUio !== undefined && (typeof a.primaryUio !== "string" || a.primaryUio.length === 0)) {
    issues.push("ai.primaryUio must be a non-empty string.");
  }
  if (a.features !== undefined) {
    if (!Array.isArray(a.features) || a.features.some((x) => typeof x !== "string")) {
      issues.push("ai.features must be an array of strings.");
    }
  }
  if (a.uioConnectors !== undefined) {
    if (typeof a.uioConnectors !== "object" || a.uioConnectors === null || Array.isArray(a.uioConnectors)) {
      issues.push("ai.uioConnectors must be an object keyed by connector id.");
    } else {
      for (const [id, entry] of Object.entries(a.uioConnectors as Record<string, unknown>)) {
        if (!id || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(id)) {
          issues.push(`ai.uioConnectors key '${id}' must be a C-like identifier.`);
        }
        if (entry === null || typeof entry !== "object" || Array.isArray(entry)) {
          issues.push(`ai.uioConnectors['${id}'] must be an object.`);
          continue;
        }
        const c = entry as Record<string, unknown>;
        if (typeof c.kind !== "string" || c.kind.length === 0) {
          issues.push(`ai.uioConnectors['${id}'].kind is required.`);
        } else if (!(AI_UIO_KINDS as readonly string[]).includes(c.kind)) {
          issues.push(
            `ai.uioConnectors['${id}'].kind '${c.kind}' is invalid (expected one of ${AI_UIO_KINDS.join(", ")}).`,
          );
        }
        if (c.path !== undefined && typeof c.path !== "string") {
          issues.push(`ai.uioConnectors['${id}'].path must be a string.`);
        }
        if (c.target !== undefined && typeof c.target !== "string") {
          issues.push(`ai.uioConnectors['${id}'].target must be a string.`);
        }
      }
    }
  }
  void boardid;
  return issues;
}

function defaultConnectors(): BoardAiUioConnector[] {
  return [
    {
      id: "island0",
      kind: "uio-mmio",
      target: "island0",
      path: AI_BOARD_DEFAULTS.uioDeviceDefault,
      notes: "Primary CAP/CTL MMIO window via UIO",
    },
  ];
}

/**
 * Resolve AI board settings. Returns null when `ai` is absent or explicitly
 * disabled. If connectors are omitted, synthesizes one uio-mmio island0.
 */
export function resolveAiBoard(spec: AiBoardView): ResolvedAiBoard | null {
  const raw = spec.ai;
  if (!raw) return null;
  if (raw.enabled === false) return null;

  const issues: string[] = [];
  const mmioBase = parseNum(raw.mmioBase, "mmioBase", issues) ?? AI_BOARD_DEFAULTS.mmioBase;
  const mmioSize = parseNum(raw.mmioSize, "mmioSize", issues) ?? AI_BOARD_DEFAULTS.mmioSize;
  const plicSource = parseNum(raw.plicSource, "plicSource", issues) ?? AI_BOARD_DEFAULTS.plicSource;
  const accTileM = parseNum(raw.accTileM, "accTileM", issues) ?? AI_BOARD_DEFAULTS.accTileM;
  const accTileN = parseNum(raw.accTileN, "accTileN", issues) ?? AI_BOARD_DEFAULTS.accTileN;
  const accTileK = parseNum(raw.accTileK, "accTileK", issues) ?? AI_BOARD_DEFAULTS.accTileK;
  const macsPerCycle =
    parseNum(raw.macsPerCycle, "macsPerCycle", issues) ?? AI_BOARD_DEFAULTS.macsPerCycle;
  const queues = parseNum(raw.queues, "queues", issues) ?? AI_BOARD_DEFAULTS.queues;
  const queueDepth = parseNum(raw.queueDepth, "queueDepth", issues) ?? AI_BOARD_DEFAULTS.queueDepth;
  const nocWidth = parseNum(raw.nocWidth, "nocWidth", issues) ?? AI_BOARD_DEFAULTS.nocWidth;
  const profileId = raw.profileId?.trim() || AI_BOARD_DEFAULTS.profileId;
  const features =
    raw.features && raw.features.length > 0 ? [...raw.features] : [...AI_BOARD_DEFAULTS.features];

  let connectors: BoardAiUioConnector[] = [];
  if (raw.uioConnectors && Object.keys(raw.uioConnectors).length > 0) {
    connectors = Object.entries(raw.uioConnectors).map(([id, c]) => ({
      ...c,
      id: c.id ?? id,
      kind: c.kind,
    }));
  } else {
    connectors = defaultConnectors();
  }

  const mmioConnectors = connectors.filter((c) => c.kind === "uio-mmio");
  const primaryUioId =
    raw.primaryUio && connectors.some((c) => c.id === raw.primaryUio)
      ? raw.primaryUio
      : (mmioConnectors[0]?.id ?? connectors[0]?.id ?? "island0");
  const primary = connectors.find((c) => c.id === primaryUioId);
  const primaryUioPath =
    primary?.path ||
    mmioConnectors[0]?.path ||
    AI_BOARD_DEFAULTS.uioDeviceDefault;

  return {
    boardid: spec.boardid,
    enabled: true,
    mmioBase,
    mmioSize,
    plicSource,
    accTileM,
    accTileN,
    accTileK,
    macsPerCycle,
    queues,
    queueDepth,
    nocWidth,
    profileId,
    connectors,
    primaryUioId,
    primaryUioPath,
    features,
  };
}

/** Soft warnings when core.config is not the preferred AI package. */
export function aiCoreHints(spec: AiBoardView, resolved: ResolvedAiBoard | null): string[] {
  if (!resolved) return [];
  const hints: string[] = [];
  if (spec.core.config !== AI_BOARD_DEFAULTS.preferredCoreConfig) {
    hints.push(
      `board '${spec.boardid}' enables AI island but core.config='${spec.core.config}' ` +
        `(preferred '${AI_BOARD_DEFAULTS.preferredCoreConfig}' so xg6lcai / AiMatrixEn match DTS).`,
    );
  }
  return hints;
}

// ---------------------------------------------------------------------------
// Generators
// ---------------------------------------------------------------------------

function hex(n: number): string {
  return "0x" + n.toString(16);
}

function hexSv(n: number, width = 64): string {
  const h = n.toString(16);
  return `${width}'h${h}`;
}

/** Device-tree fragment (include into a full tree; not a boot image by itself). */
export function generateAiDtsFragment(r: ResolvedAiBoard): string {
  const base = r.mmioBase >>> 0;
  const size = r.mmioSize >>> 0;
  const baseHex = base.toString(16);
  const lines = [
    `// GENERATED by build-platform mb select ${r.boardid} — do not edit by hand.`,
    `// AI island DTS fragment for board '${r.boardid}'.`,
    `// Golden full tree: corev_apu/bootrom/ariane-ai.dts`,
    `// Generic template: architecture/ai-matrix/dts/g6lc-ai-matrix.dtsi`,
    "",
    `// Include under /soc { ... } or paste as a sibling of other peripherals.`,
    `ai_matrix: ai-matrix@${baseHex} {`,
    `  compatible = "g6lc,ai-matrix";`,
    `  reg = <0x0 ${hex(base)} 0x0 ${hex(size)}>;`,
    `  interrupt-parent = <&PLIC0>;`,
    `  interrupts = <${r.plicSource}>;`,
    `  g6lc,board-id = "${r.boardid}";`,
    `  g6lc,uio-primary = "${r.primaryUioId}";`,
    `  g6lc,acc-tile-m = <${r.accTileM}>;`,
    `  g6lc,acc-tile-n = <${r.accTileN}>;`,
    `  g6lc,acc-tile-k = <${r.accTileK}>;`,
    `  g6lc,macs-per-cycle = <${r.macsPerCycle}>;`,
    `  g6lc,queues = <${r.queues}>;`,
    `  g6lc,queue-depth = <${r.queueDepth}>;`,
    `  g6lc,noc-width = <${r.nocWidth}>;`,
    `  status = "okay";`,
    `};`,
    "",
  ];
  return lines.join("\n");
}

/** ai-tensor profile TOML (board-local pin; not the package-committed island-p3-v1). */
export function generateAiTensorProfile(r: ResolvedAiBoard): string {
  const feat = r.features.map((f) => `  "${f}",`).join("\n");
  return [
    `# GENERATED by build-platform mb select ${r.boardid} — do not edit by hand.`,
    `# Board-local ai-tensor profile derived from board.json ai{} + AI_BOARD_DEFAULTS.`,
    `id = "${r.profileId}"`,
    `board_id = "${r.boardid}"`,
    `abi_rev = "0.1.0"`,
    `isa_doc_rev = "monorepo:architecture/ai-matrix/isa-encoding.md"`,
    `island_rev = "monorepo:ai-matrix-p1"`,
    `backend = "linux-uio"`,
    `mmio_map = "island_p3_v1"`,
    `mmio_base = "${hex(r.mmioBase)}"`,
    `uio_primary = "${r.primaryUioPath}"`,
    `uio_primary_id = "${r.primaryUioId}"`,
    `noc_width = ${r.nocWidth}`,
    `acc_tile_m = ${r.accTileM}`,
    `acc_tile_n = ${r.accTileN}`,
    `acc_tile_k = ${r.accTileK}`,
    `macs_per_cycle = ${r.macsPerCycle}`,
    `plic_source = ${r.plicSource}`,
    `wait_policy = "poll"`,
    `submit_mode = "latch"`,
    `features = [`,
    feat,
    `]`,
    `notes = "Generated for board ${r.boardid}; see architecture/ai-matrix/board-uio-eventfd.md."`,
    "",
  ].join("\n");
}

/** Infer ai-tensor Device backend from resolved board UIO path / id. */
export function inferAiTensorBackend(r: ResolvedAiBoard): string {
  if (
    r.boardid.startsWith("virt") ||
    r.primaryUioPath.startsWith("virt://") ||
    r.connectors.some((c) => c.kind === "soft-sticky")
  ) {
    return "virt-card";
  }
  return "linux-uio";
}

/** Shell env snippet for AI_TENSOR_* discovery (source from host scripts). */
export function generateAiTensorEnv(r: ResolvedAiBoard): string {
  const backend = inferAiTensorBackend(r);
  return [
    `# GENERATED by build-platform mb select ${r.boardid} — do not edit by hand.`,
    `# source this file (or export manually) before ai-tensor board runs.`,
    `export AI_TENSOR_BOARD_ID=${r.boardid}`,
    `export AI_TENSOR_BACKEND=${backend}`,
    `export AI_TENSOR_UIO=${r.primaryUioPath}`,
    `export AI_TENSOR_MMIO_BASE=${hex(r.mmioBase)}`,
    `export AI_TENSOR_PLIC_SOURCE=${r.plicSource}`,
    `export AI_TENSOR_ACC_TILE_M=${r.accTileM}`,
    `export AI_TENSOR_ACC_TILE_N=${r.accTileN}`,
    `export AI_TENSOR_ACC_TILE_K=${r.accTileK}`,
    `export AI_TENSOR_MACS=${r.macsPerCycle}`,
    `export AI_TENSOR_NOC_WIDTH=${r.nocWidth}`,
    `export AI_TENSOR_PROFILE=${r.profileId}`,
    "",
  ].join("\n");
}

/** SystemVerilog localparams block when AI is enabled (inserted into board package). */
export function generateAiBoardPackageParams(r: ResolvedAiBoard): string {
  const lines = [
    "  // --- AI island (board.json ai / UIO connectors) -----------------------",
    "  localparam bit MbAi_En = 1'b1;",
    `  localparam logic [63:0] MbAi_MmioBase = ${hexSv(r.mmioBase)};`,
    `  localparam int unsigned MbAi_MmioSize = ${r.mmioSize};`,
    `  localparam int unsigned MbAi_PlicSource = ${r.plicSource};`,
    `  localparam int unsigned MbAi_AccTileM = ${r.accTileM};`,
    `  localparam int unsigned MbAi_AccTileN = ${r.accTileN};`,
    `  localparam int unsigned MbAi_AccTileK = ${r.accTileK};`,
    `  localparam int unsigned MbAi_MacsPerCycle = ${r.macsPerCycle};`,
    `  localparam int unsigned MbAi_Queues = ${r.queues};`,
    `  localparam int unsigned MbAi_QueueDepth = ${r.queueDepth};`,
    `  localparam int unsigned MbAi_NocWidth = ${r.nocWidth};`,
    `  localparam string MbAi_ProfileId = "${r.profileId}";`,
    `  localparam string MbAi_PrimaryUio = "${r.primaryUioPath.replace(/"/g, "'")}";`,
    `  localparam int unsigned MbAi_UioCount = ${r.connectors.length};`,
  ];
  for (const c of r.connectors) {
    const tok = (c.id ?? "conn").toUpperCase().replace(/[^A-Z0-9_]/g, "_");
    lines.push(`  localparam bit MbAi_Uio_${tok}_En = 1'b1;`);
    lines.push(`  localparam string MbAi_Uio_${tok}_Kind = "${c.kind}";`);
  }
  return lines.join("\n");
}

/** SystemVerilog localparams when the board has no AI island. */
export function generateAiBoardPackageDisabled(): string {
  return [
    "  // --- AI island (disabled — no board.json ai or ai.enabled=false) ------",
    "  localparam bit MbAi_En = 1'b0;",
  ].join("\n");
}

/** Starter `ai` object for `mb create --ai` / ai-card scaffold. */
export function starterAiSpec(_boardid: string): BoardAiSpec {
  return {
    enabled: true,
    mmioBase: AI_BOARD_DEFAULTS.mmioBase,
    mmioSize: AI_BOARD_DEFAULTS.mmioSize,
    plicSource: AI_BOARD_DEFAULTS.plicSource,
    accTileM: AI_BOARD_DEFAULTS.accTileM,
    accTileN: AI_BOARD_DEFAULTS.accTileN,
    accTileK: AI_BOARD_DEFAULTS.accTileK,
    macsPerCycle: AI_BOARD_DEFAULTS.macsPerCycle,
    queues: AI_BOARD_DEFAULTS.queues,
    queueDepth: AI_BOARD_DEFAULTS.queueDepth,
    nocWidth: AI_BOARD_DEFAULTS.nocWidth,
    profileId: AI_BOARD_DEFAULTS.profileId,
    primaryUio: "island0",
    features: [...AI_BOARD_DEFAULTS.features],
    uioConnectors: {
      island0: {
        kind: "uio-mmio",
        target: "island0",
        path: AI_BOARD_DEFAULTS.uioDeviceDefault,
        notes: "Primary CAP/CTL MMIO window via UIO (AI_TENSOR_UIO)",
      },
      island0_irq: {
        kind: "eventfd",
        target: "island0",
        notes: "IRQ completion wake — PLIC source 8 / eventfd handoff (AI_TENSOR_EVENTFD)",
      },
    },
  };
}
