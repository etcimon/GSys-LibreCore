// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// TypeScript DTOs mirroring Rust CLI JSON (schemas/analyze-result.v0.json and debug/correct exports).

/** Origin kind for source locations (matches Rust OriginKind). */
export type OriginKind = "user_file" | "expanded_macro" | "include_expanded" | "unknown";

/** Source span for IR nodes and edit traces. */
export interface SourceLoc {
  file: string;
  start_line: number;
  start_col: number;
  end_line: number;
  end_col: number;
  byte_start?: number;
  byte_end?: number;
  origin?: OriginKind;
}

/** Per-file parse summary in analyze JSON. */
export interface AnalyzedFile {
  path: string;
  parse_ok: boolean;
  byte_len?: number;
}

/** AST / IR export summary (v0). */
export interface AstStub {
  /** `parsed_unit_stub` (legacy) or `timing_ir_v0` after lower_to_ir. */
  kind: "parsed_unit_stub" | "timing_ir_v0" | string;
  files_parsed: number;
  module_count?: number;
  path_count?: number;
  opportunity_count?: number;
  note?: string;
}

/** Module summary in analyze JSON. */
export interface ModuleSummaryDto {
  id: number;
  name: string;
  file: string;
  node_count: number;
  region_count: number;
}

/** Path summary in analyze JSON. */
export interface PathSummaryDto {
  path_id: number;
  module_id: number;
  total_fo4: number;
  slack_fo4: number;
  multi_cycle: boolean;
  node_count: number;
  primary_loc?: SourceLoc;
}

/** Version banner embedded in reports. */
export interface VersionBannerDto {
  ir?: string;
  parser_pin?: string;
  cost_model?: string;
  /**
   * Measurement semantics — *how* delay is computed, independent of the cost table.
   * `"delay-v1"` = def-use DAG longest path + expression critical chain + width scaling.
   * `"legacy-sum"` = pre-P14 source-order sums (width-blind). Never compare across values.
   */
  measurement?: string;
  package?: string;
}

/** Optimization level preset (a preset only sets {@link OptDialsDto}). */
export type OptLevelDto = "O0" | "O1" | "O2" | "O3" | "Os" | "Oz";

/** The ten resolved optimization dials (P15). */
export interface OptDialsDto {
  max_passes: number;
  worklist_width: number;
  cut_strategy: "mid-node" | "cost-balanced" | "budget-fit";
  max_stages_per_region: number;
  min_gain_fo4: number;
  slack_target_fo4: number;
  area_weight: number;
  allow_reassoc: boolean;
  effort: "fast" | "balanced" | "thorough";
  jobs: number | null;
  cache_mode: "off" | "ir" | "unit" | "full";
}

/**
 * Resolved optimization surface echoed by `analyze` / `correct`.
 *
 * A level never relaxes a safety gate (allowlist, refuse lists, `--allow-latency`,
 * dry-run, emit containment) — see `architecture/OPTIMIZATION-LEVELS.md` §3.
 */
export interface OptResultDto {
  level: OptLevelDto;
  /** Stable digest of the dials; also folded into the cache design key. */
  digest: string;
  measurement?: string;
  dials: OptDialsDto;
}

/**
 * AnalyzeResult v0 — contract between `sv-timing analyze --json-out` and this package.
 * Schema file: `../schemas/analyze-result.v0.json`.
 */
export interface AnalyzeResult {
  schema_version: "0";
  disclaimer: string;
  banner: string;
  target_mhz: number;
  fo4_ps?: number;
  budget_margin?: number;
  files: AnalyzedFile[];
  modules_requested: string[] | "*";
  ast: AstStub;
  modules?: ModuleSummaryDto[];
  paths?: PathSummaryDto[];
  opportunities?: OpportunityDto[];
  budget_fo4?: number;
  versions?: VersionBannerDto;
  /** Resolved `-O` level + dials (present since P15). */
  opt?: OptResultDto;
}

/** Pipeline / rewrite opportunity (partial until IR lower). */
export interface OpportunityDto {
  kind: "insert_reg" | "split_assign" | string;
  path_id?: number;
  estimated_fo4_before?: number;
  estimated_fo4_after?: number;
  loc?: SourceLoc;
  rationale?: string;
  requires_clock_in_scope?: boolean;
  changes_latency?: boolean;
}

/** Edit record from auto-correct. */
export interface EditRecordDto {
  id: number;
  kind: string;
  origin: SourceLoc;
  path_id?: number | null;
  node_id?: number | null;
  new_name?: string | null;
  fo4_before?: number | null;
  fo4_after?: number | null;
  rationale: string;
}

/** Correct (dry-run or emit) result JSON. */
export interface CorrectResult {
  schema_version: "0";
  disclaimer: string;
  dry_run: boolean;
  allow_latency: boolean;
  modules_allowlist: string[];
  edits: EditRecordDto[];
  integrity?: IntegrityReportDto;
  emit_dir?: string | null;
  note?: string;
  /** Resolved `-O` level + dials that produced these edits (present since P15). */
  opt?: OptResultDto;
}

/** Integrity report after emit. */
export interface IntegrityReportDto {
  reparse_ok: boolean;
  structural_ok: boolean;
  lint_ran?: boolean;
  lint_ok?: boolean;
  sim_ran?: boolean;
  sim_ok?: boolean;
  messages: string[];
}

/** Debug export bundle metadata. */
export interface DebugExportResult {
  schema_version: "0";
  tag: string;
  dir: string;
  files: string[];
  note?: string;
}

/** Status command structured JSON (optional). */
export interface StatusResult {
  schema_version: "0";
  banner: string;
  ir_version: string;
  cache?: string | null;
}

/** Runtime options for spawning the Rust CLI. */
export interface SvTimingClientOptions {
  /** Absolute path to package root (sv-timing/). */
  packageRoot: string;
  /**
   * Path to `sv-timing` binary. If omitted, uses
   * `cargo run -p sv-timing-cli` with contained RUSTUP/CARGO if env set.
   */
  cliPath?: string;
  /** Working directory for relative fixture paths (default packageRoot). */
  cwd?: string;
  /** Extra env for the child process. */
  env?: Record<string, string>;
  /** Timeout ms for child processes (default 120_000). */
  timeoutMs?: number;
}

/** Analyze CLI arguments. */
export interface AnalyzeOptions {
  files?: string[];
  filesFrom?: string;
  incdirs?: string[];
  defines?: string[];
  modules?: string[];
  allModules?: boolean;
  targetMhz?: number;
  jsonOut: string;
}

/** Correct CLI arguments. */
export interface CorrectOptions {
  modulesAllow: string[];
  allowLatency?: boolean;
  assumeClk?: boolean;
  dryRun?: boolean;
  emitDir?: string;
  jsonOut: string;
  /** Sources to analyze before correct. */
  filesFrom?: string;
  files?: string[];
  targetMhz?: number;
  maxPasses?: number;
}

/** Debug-export CLI arguments. */
export interface DebugExportOptions {
  tag?: string;
  outDir: string;
  jsonOut?: string;
  filesFrom?: string;
  modules?: string[];
}

/** Guard: narrow unknown JSON to AnalyzeResult. */
export function isAnalyzeResult(v: unknown): v is AnalyzeResult {
  if (typeof v !== "object" || v === null) return false;
  const o = v as Record<string, unknown>;
  return (
    o.schema_version === "0" &&
    typeof o.disclaimer === "string" &&
    typeof o.banner === "string" &&
    typeof o.target_mhz === "number" &&
    Array.isArray(o.files) &&
    typeof o.ast === "object" &&
    o.ast !== null
  );
}

/** Guard for CorrectResult. */
export function isCorrectResult(v: unknown): v is CorrectResult {
  if (typeof v !== "object" || v === null) return false;
  const o = v as Record<string, unknown>;
  return (
    o.schema_version === "0" &&
    typeof o.dry_run === "boolean" &&
    Array.isArray(o.edits)
  );
}

/** Guard for DebugExportResult. */
export function isDebugExportResult(v: unknown): v is DebugExportResult {
  if (typeof v !== "object" || v === null) return false;
  const o = v as Record<string, unknown>;
  return (
    o.schema_version === "0" &&
    typeof o.dir === "string" &&
    Array.isArray(o.files)
  );
}
