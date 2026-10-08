// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// aiTesting.ts — Shared SI-island CLI knobs for test / diag / verify / remote / g6q.
//
// Mirrors the OoO surface (`diag run ooo`, `test --suite ooo-l3-tests`, `--from-timing`)
// so Xg6lcai clusters, matrix, DRAM channels, GHz/timing, and ai-tensor/QEMU
// higher-level checks are selected from existing handlers rather than a new command.
//
// Not Variane evidence: g6lc_qemu / --ai-qemu is a higher-level Linux/emulation
// path. Remote testharness (`--ai-remote`, flavour ai-dt/ai-d*) is the RTL pin.

import { flagBool, flagString } from "../cli/args.ts";

/** Local directed gates (optional, not defaultSuites) selected by `--ai`. */
export const AI_DEFAULT_SUITE_IDS = [
  "ai-config-smoke",
  "ai-matrix-directed",
  "ai-island-veri",
  "ai-dram-atomics",
] as const;

export const AI_REMOTE_SUITE_IDS = ["ai-s4-mshr-xbar"] as const;
export const AI_QEMU_SUITE_IDS = ["ai-qemu-linux"] as const;
export const AI_CHANNEL_SUITE_IDS = ["ai-dram-channels"] as const;
/** Class-0 SRAM stripe (cores + island), selected by `--channels N` without `--ai-dram 1`. */
export const AI_STRIPE_SUITE_IDS = ["ai-dram-stripe"] as const;
export const AI_WRAP_SUITE_IDS = ["ai-litedram-wrap"] as const;
export const AI_TIMING_SUITE_IDS = ["ai-dram-timing"] as const;
export const AI_TENSOR_SUITE_IDS = ["smt2-ai-tensor-track"] as const;
export const AI_VERI_SUITE_IDS = ["ai-matrix-veri"] as const;

export const AI_ALL_SUITE_IDS: readonly string[] = [
  ...AI_DEFAULT_SUITE_IDS,
  ...AI_REMOTE_SUITE_IDS,
  ...AI_QEMU_SUITE_IDS,
  ...AI_CHANNEL_SUITE_IDS,
  ...AI_STRIPE_SUITE_IDS,
  ...AI_WRAP_SUITE_IDS,
  ...AI_TIMING_SUITE_IDS,
  ...AI_TENSOR_SUITE_IDS,
  ...AI_VERI_SUITE_IDS,
];

export const AI_CHANNELS = [1, 2, 4, 8] as const;
export type AiChannels = (typeof AI_CHANNELS)[number];

export const AI_DRAM_CLASSES = [0, 1, 2] as const;
export type AiDramClass = (typeof AI_DRAM_CLASSES)[number];

/** Remote testharness / Variane flavour ids (proxy AI_FLAVOURS + class-0 stripe). */
export const AI_FLAVOURS = [
  "ai",
  "ai-dt",
  "ai-d1",
  "ai-d2",
  "ai-d4",
  "ai-d8",
  "ai-sc2",
  "ai-sc4",
  "ai-sc8",
] as const;
export type AiFlavour = (typeof AI_FLAVOURS)[number];

export interface AiFlavourMeta {
  flavour: AiFlavour;
  defines: string;
  verlib: string;
  dramClass: AiDramClass;
  channels: AiChannels;
  timing: boolean;
}

const FLAVOUR_META: Record<AiFlavour, AiFlavourMeta> = {
  ai: {
    flavour: "ai",
    defines: "",
    verlib: "work-ver-ai",
    dramClass: 0,
    channels: 1,
    timing: false,
  },
  "ai-dt": {
    flavour: "ai-dt",
    defines: "G6LC_AI_DRAM_TIMING",
    verlib: "work-ver-ai-dt",
    dramClass: 0,
    channels: 1,
    timing: true,
  },
  "ai-d1": {
    flavour: "ai-d1",
    defines: "G6LC_AI_DRAM_CLASS1",
    verlib: "work-ver-ai-d1",
    dramClass: 1,
    channels: 1,
    timing: false,
  },
  "ai-d2": {
    flavour: "ai-d2",
    defines: "G6LC_AI_DRAM_CHANS_2",
    verlib: "work-ver-ai-d2",
    dramClass: 1,
    channels: 2,
    timing: false,
  },
  "ai-d4": {
    flavour: "ai-d4",
    defines: "G6LC_AI_DRAM_CHANS_4",
    verlib: "work-ver-ai-d4",
    dramClass: 1,
    channels: 4,
    timing: false,
  },
  "ai-d8": {
    flavour: "ai-d8",
    defines: "G6LC_AI_DRAM_CHANS_8",
    verlib: "work-ver-ai-d8",
    dramClass: 1,
    channels: 8,
    timing: false,
  },
  "ai-sc2": {
    flavour: "ai-sc2",
    defines: "G6LC_AI_DRAM_SIM_CHANS_2",
    verlib: "work-ver-ai-sc2",
    dramClass: 0,
    channels: 2,
    timing: false,
  },
  "ai-sc4": {
    flavour: "ai-sc4",
    defines: "G6LC_AI_DRAM_SIM_CHANS_4",
    verlib: "work-ver-ai-sc4",
    dramClass: 0,
    channels: 4,
    timing: false,
  },
  "ai-sc8": {
    flavour: "ai-sc8",
    defines: "G6LC_AI_DRAM_SIM_CHANS_8",
    verlib: "work-ver-ai-sc8",
    dramClass: 0,
    channels: 8,
    timing: false,
  },
};

/** Child-env keys forwarded into regress scripts (WSL-safe). */
export const AI_CHILD_ENV_KEYS = [
  "AI_ISLAND_DRAM_CHANNELS",
  "AI_ISLAND_DRAM_CLASS",
  "AI_ISLAND_DRAM_TIMING",
  "AI_ISLAND_DRAM_CLASS1",
  "AI_ISLAND_DRAM_CHANS_2",
  "AI_ISLAND_DRAM_CHANS_4",
  "AI_ISLAND_DRAM_CHANS_8",
  "AI_ISLAND_DRAM_SIM_CHANS_2",
  "AI_ISLAND_DRAM_SIM_CHANS_4",
  "AI_ISLAND_DRAM_SIM_CHANS_8",
  "AI_ISLAND_GHZ",
  "AI_ISLAND_CLUSTERS",
  "AI_MATRIX_FLAVOUR",
  "AI_MATRIX_DEFINES",
  "AI_MATRIX_VER_LIBRARY",
  "S4_FLAVOUR",
  "G6Q_TARGET",
  "G6Q_AI",
  "G6Q_AI_LINUX",
  "G6Q_AI_BRIDGE",
] as const;

export interface AiTestKnobs {
  wantAi: boolean;
  wantRemote: boolean;
  wantQemu: boolean;
  wantTensor: boolean;
  wantTiming: boolean;
  includeOptional: boolean;
  channels?: AiChannels;
  dramClass?: AiDramClass;
  ghz?: number;
  clusters?: number;
  flavour?: AiFlavour;
}

export interface AiResolved {
  active: boolean;
  flavour: AiFlavour;
  meta: AiFlavourMeta;
  channels: AiChannels;
  dramClass: AiDramClass;
  ghz?: number;
  clusters: number;
  env: Record<string, string>;
  suiteIds: string[];
  errors: string[];
  warnings: string[];
}

export function isAiSuiteId(id: string): boolean {
  return (
    AI_ALL_SUITE_IDS.includes(id) ||
    id.startsWith("ai-") ||
    id.includes("ai-tensor") ||
    id.includes("ai-matrix")
  );
}

export function isAiFlavour(value: string): value is AiFlavour {
  return (AI_FLAVOURS as readonly string[]).includes(value);
}

function parseChannels(raw: string | undefined): AiChannels | undefined | "bad" {
  if (raw == null || raw === "") return undefined;
  const n = Number(raw);
  if ((AI_CHANNELS as readonly number[]).includes(n)) return n as AiChannels;
  return "bad";
}

function parseDramClass(raw: string | undefined): AiDramClass | undefined | "bad" {
  if (raw == null || raw === "") return undefined;
  const n = Number(raw);
  if ((AI_DRAM_CLASSES as readonly number[]).includes(n)) return n as AiDramClass;
  return "bad";
}

function parseFlavour(raw: string | undefined): AiFlavour | undefined | "bad" {
  if (raw == null || raw === "") return undefined;
  if (isAiFlavour(raw)) return raw;
  return "bad";
}

/** Read `--ai*` knobs from parsed CLI flags. */
export function parseAiFlags(
  flags: Record<string, string | boolean>,
): AiTestKnobs {
  const flavourRaw =
    flagString(flags, "ai-flavour") ?? flagString(flags, "flavour");
  const flavour = parseFlavour(flavourRaw);
  const channels = parseChannels(flagString(flags, "channels"));
  const dramClass = parseDramClass(flagString(flags, "ai-dram"));
  const ghzRaw = flagString(flags, "ai-ghz");
  const clustersRaw = flagString(flags, "ai-clusters");
  const mhzRaw = flagString(flags, "target-mhz");

  let ghz: number | undefined;
  if (ghzRaw && Number.isFinite(Number(ghzRaw))) ghz = Number(ghzRaw);
  else if (mhzRaw && Number.isFinite(Number(mhzRaw))) ghz = Number(mhzRaw) / 1000;

  let clusters: number | undefined;
  if (clustersRaw && Number.isFinite(Number(clustersRaw))) {
    clusters = Number(clustersRaw);
  }

  return {
    wantAi: flagBool(flags, "ai"),
    wantRemote: flagBool(flags, "ai-remote"),
    wantQemu: flagBool(flags, "ai-qemu"),
    wantTensor: flagBool(flags, "ai-tensor"),
    wantTiming:
      flagBool(flags, "ai-timing") ||
      Boolean(flagString(flags, "from-timing")) ||
      ghz != null,
    includeOptional: flagBool(flags, "include-optional") || flagBool(flags, "all"),
    channels: channels === "bad" ? undefined : channels,
    dramClass: dramClass === "bad" ? undefined : dramClass,
    ghz,
    clusters,
    flavour: flavour === "bad" ? undefined : flavour,
  };
}

export function parseAiFlagErrors(
  flags: Record<string, string | boolean>,
): string[] {
  const errors: string[] = [];
  const flavourRaw =
    flagString(flags, "ai-flavour") ?? flagString(flags, "flavour");
  if (parseFlavour(flavourRaw) === "bad") {
    errors.push(
      `unknown --flavour/--ai-flavour '${flavourRaw}'. Valid: ${AI_FLAVOURS.join(", ")}.`,
    );
  }
  if (parseChannels(flagString(flags, "channels")) === "bad") {
    errors.push(
      `invalid --channels '${flagString(flags, "channels")}'. Valid: ${AI_CHANNELS.join(", ")} (power of two, max 8).`,
    );
  }
  if (parseDramClass(flagString(flags, "ai-dram")) === "bad") {
    errors.push(
      `invalid --ai-dram '${flagString(flags, "ai-dram")}'. Valid: 0 (SRAM), 1 (DDR4 LiteDRAM), 2 (LPDDR5 — not live).`,
    );
  }
  return errors;
}

/**
 * Map class × channels × timing onto a testharness flavour.
 * Class 2 (400 GB/s LPDDR5) is refused — it is not live.
 */
export function resolveAiFlavour(knobs: AiTestKnobs): {
  meta: AiFlavourMeta;
  errors: string[];
  warnings: string[];
} {
  const errors: string[] = [];
  const warnings: string[] = [];
  if (knobs.flavour) {
    return { meta: FLAVOUR_META[knobs.flavour], errors, warnings };
  }

  const dramClass: AiDramClass = knobs.dramClass ?? 0;
  const channels: AiChannels = knobs.channels ?? 1;

  if (dramClass === 2) {
    errors.push(
      "DRAM class 2 (LPDDR5, 400 GB/s SKU) is not live. Use --ai-dram 0 (SRAM) or 1 (DDR4 LiteDRAM, N×19 GB/s nameplate).",
    );
    return { meta: FLAVOUR_META.ai, errors, warnings };
  }

  if (dramClass === 1) {
    const map: Record<AiChannels, AiFlavour> = {
      1: "ai-d1",
      2: "ai-d2",
      4: "ai-d4",
      8: "ai-d8",
    };
    return { meta: FLAVOUR_META[map[channels]], errors, warnings };
  }

  // Class 0 SRAM. Timing SKU (Cas=14, MaxAROut=8) is N=1 only.
  // Remote S4 (`test --ai-remote`) defaults to ai-dt, matching s4-mshr-xbar.sh.
  if ((knobs.wantTiming || knobs.wantRemote) && channels === 1) {
    return { meta: FLAVOUR_META["ai-dt"], errors, warnings };
  }
  if (knobs.wantTiming && channels > 1) {
    warnings.push(
      `class-0 timing (Cas=14) is N=1 (ai-dt); --channels ${channels} uses SIM_CHANS stripe instead.`,
    );
  }
  if (channels === 1) return { meta: FLAVOUR_META.ai, errors, warnings };
  const sim: Record<2 | 4 | 8, AiFlavour> = {
    2: "ai-sc2",
    4: "ai-sc4",
    8: "ai-sc8",
  };
  return { meta: FLAVOUR_META[sim[channels]], errors, warnings };
}

function envForMeta(
  meta: AiFlavourMeta,
  knobs: AiTestKnobs,
): Record<string, string> {
  const env: Record<string, string> = {
    AI_ISLAND_DRAM_CHANNELS: String(meta.channels),
    AI_ISLAND_DRAM_CLASS: String(meta.dramClass),
    AI_MATRIX_FLAVOUR: meta.flavour,
    AI_MATRIX_VER_LIBRARY: meta.verlib,
    S4_FLAVOUR: meta.flavour,
    G6Q_TARGET: "g6lc64_ai",
  };
  if (meta.defines) env.AI_MATRIX_DEFINES = meta.defines;
  if (meta.timing) env.AI_ISLAND_DRAM_TIMING = "1";
  if (meta.dramClass === 1) env.AI_ISLAND_DRAM_CLASS1 = "1";
  if (meta.dramClass === 1 && meta.channels === 2) env.AI_ISLAND_DRAM_CHANS_2 = "1";
  if (meta.dramClass === 1 && meta.channels === 4) env.AI_ISLAND_DRAM_CHANS_4 = "1";
  if (meta.dramClass === 1 && meta.channels === 8) env.AI_ISLAND_DRAM_CHANS_8 = "1";
  if (meta.dramClass === 0 && meta.channels === 2) {
    env.AI_ISLAND_DRAM_SIM_CHANS_2 = "1";
  }
  if (meta.dramClass === 0 && meta.channels === 4) {
    env.AI_ISLAND_DRAM_SIM_CHANS_4 = "1";
  }
  if (meta.dramClass === 0 && meta.channels === 8) {
    env.AI_ISLAND_DRAM_SIM_CHANS_8 = "1";
  }
  if (knobs.ghz != null) env.AI_ISLAND_GHZ = String(knobs.ghz);
  if (knobs.clusters != null) env.AI_ISLAND_CLUSTERS = String(knobs.clusters);
  if (knobs.wantQemu || knobs.wantAi) env.G6Q_AI = "1";
  return env;
}

function uniqueIds(ids: string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const id of ids) {
    if (!seen.has(id)) {
      seen.add(id);
      out.push(id);
    }
  }
  return out;
}

/**
 * Resolve flavour + env + suite ids for `--ai` / `--ai-remote` / `--ai-qemu`.
 * Does not replace an explicit `--suite` list — callers merge.
 */
export function resolveAiTesting(knobs: AiTestKnobs): AiResolved {
  const flagErrors: string[] = [];
  const { meta, errors, warnings } = resolveAiFlavour(knobs);
  flagErrors.push(...errors);

  if (knobs.clusters != null && knobs.clusters > 1) {
    warnings.push(
      `I2 multi-cluster is not live (Clusters=${knobs.clusters} exported for QEMU CAP/F8 only). Measure I3 bandwidth before I2.`,
    );
  }

  const suiteIds: string[] = [];
  const select =
    knobs.wantAi ||
    knobs.wantRemote ||
    knobs.wantQemu ||
    knobs.wantTensor ||
    knobs.channels != null ||
    knobs.dramClass != null ||
    knobs.flavour != null ||
    knobs.ghz != null ||
    knobs.clusters != null;

  if (knobs.wantAi || (select && !knobs.wantRemote && !knobs.wantQemu && !knobs.wantTensor)) {
    suiteIds.push(...AI_DEFAULT_SUITE_IDS);
  }
  if (knobs.wantRemote) suiteIds.push(...AI_REMOTE_SUITE_IDS);
  if (knobs.wantQemu) suiteIds.push(...AI_QEMU_SUITE_IDS);
  if (knobs.wantTensor) suiteIds.push(...AI_TENSOR_SUITE_IDS);
  if (meta.channels > 1 || (knobs.channels != null && knobs.channels > 1)) {
    if (meta.dramClass === 1) suiteIds.push(...AI_CHANNEL_SUITE_IDS);
    else suiteIds.push(...AI_STRIPE_SUITE_IDS);
  }
  if (meta.dramClass === 1) suiteIds.push(...AI_WRAP_SUITE_IDS);
  if (knobs.wantTiming || (meta.timing && knobs.wantAi)) {
    suiteIds.push(...AI_TIMING_SUITE_IDS);
  }
  if (knobs.includeOptional && knobs.wantAi) {
    suiteIds.push(
      ...AI_WRAP_SUITE_IDS,
      ...AI_CHANNEL_SUITE_IDS,
      ...AI_STRIPE_SUITE_IDS,
      ...AI_TIMING_SUITE_IDS,
      ...AI_VERI_SUITE_IDS,
      ...AI_TENSOR_SUITE_IDS,
      ...AI_QEMU_SUITE_IDS,
    );
  }

  const env = envForMeta(meta, knobs);

  return {
    active: select || knobs.wantAi,
    flavour: meta.flavour,
    meta,
    channels: meta.channels,
    dramClass: meta.dramClass,
    ghz: knobs.ghz,
    clusters: knobs.clusters ?? 1,
    env,
    suiteIds: uniqueIds(suiteIds),
    errors: flagErrors,
    warnings,
  };
}

/** Stamp resolved SI env onto `process.env` so runner / g6q / proxy children see it. */
export function applyAiEnv(resolved: AiResolved): void {
  Object.assign(process.env, resolved.env);
}

export function copyAiEnv(
  extra: Record<string, string>,
): Record<string, string> {
  for (const k of AI_CHILD_ENV_KEYS) {
    if (process.env[k]) extra[k] = process.env[k]!;
  }
  return extra;
}

/** Build-platform-only flags that g6q.py must not see. */
const G6Q_STRIP = new Set([
  "ai",
  "ai-remote",
  "ai-qemu",
  "ai-timing",
  "ai-tensor",
  "from-timing",
  "use-emit",
  "require-emit",
  "channels",
  "ai-dram",
  "ai-ghz",
  "ai-clusters",
  "ai-flavour",
  "flavour",
  "target-mhz",
]);

/**
 * Drop host-gateway flags from a reconstructed g6q child argv.
 * Value-flags consume the following token when it is not another flag.
 */
export function stripGatewayFlags(argv: string[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < argv.length; i++) {
    const tok = argv[i]!;
    if (!tok.startsWith("--")) {
      out.push(tok);
      continue;
    }
    const body = tok.slice(2);
    const eq = body.indexOf("=");
    const name = eq >= 0 ? body.slice(0, eq) : body;
    if (!G6Q_STRIP.has(name)) {
      out.push(tok);
      continue;
    }
    if (eq < 0 && i + 1 < argv.length && !argv[i + 1]!.startsWith("-")) {
      i++;
    }
  }
  return out;
}

/** Inject `--target g6lc64_ai` next to g6q-cli ingest verbs, unless already set. */
export function injectG6qAiTarget(childArgs: string[]): string[] {
  const hasTarget = childArgs.some(
    (t) =>
      t === "--target" ||
      t.startsWith("--target=") ||
      t === "--config-pkg" ||
      t.startsWith("--config-pkg="),
  );
  if (hasTarget) return childArgs;
  // g6q.py itself has no `gen`; ingest lives under `g6q run -- gen|conform|diag|dts`.
  const ingest = new Set(["gen", "conform", "diag", "dts", "tandem"]);
  const verbIdx = childArgs.findIndex((t) => ingest.has(t));
  if (verbIdx < 0) return childArgs;
  return [
    ...childArgs.slice(0, verbIdx + 1),
    "--target",
    "g6lc64_ai",
    ...childArgs.slice(verbIdx + 1),
  ];
}

export function formatAiResolvedLine(resolved: AiResolved): string {
  const ghz = resolved.ghz != null ? ` ghz=${resolved.ghz}` : "";
  return (
    `SI flavour=${resolved.flavour} class=${resolved.dramClass} ` +
    `channels=${resolved.channels} clusters=${resolved.clusters}${ghz} ` +
    `verlib=${resolved.meta.verlib}` +
    (resolved.meta.defines ? ` defines=${resolved.meta.defines}` : "")
  );
}
