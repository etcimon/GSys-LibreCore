// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// coreProfile.ts — the config-package facts a board bundle must agree with.
//
// `mb ingest` used to check only that `core/include/<config>_config_pkg.sv`
// exists. A board can therefore advertise a hart count that the RTL does not
// have (the mbgen literal table once said `g6lc64_ooo_server` = 4 harts; the
// package says NrCores=4 × NrHarts=2). That mismatch is a compile-time
// constant discovered at BIOS/Linux boot — the most expensive place.
//
// This module reads the same narrow SystemVerilog forms mbcore's generator
// reads (`unsigned'(X)`, `bit'(X)`, decimal / sized literals, identifiers that
// resolve through earlier `localparam`s) and refuses to guess anything else.
// It is read-only toward the RTL.

import { createHash } from "node:crypto";

export interface CoreTopology {
  cores: number | null;
  threads: number | null;
  /** Field names whose value could not be resolved from the supported forms. */
  unresolved: string[];
}

function stripComments(text: string): string {
  return text.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/[^\n]*/g, "");
}

const RADIX: Record<string, number> = { b: 2, d: 10, h: 16, o: 8 };

function sizedLiteral(expr: string): number | null {
  const m = /^(\d+)'([bBdDhHoO])([0-9a-fA-F_]+)$/.exec(expr);
  const base = m?.[2];
  const digits = m?.[3];
  if (base === undefined || digits === undefined) return null;
  const radix = RADIX[base.toLowerCase()];
  if (radix === undefined) return null;
  const n = parseInt(digits.replace(/_/g, ""), radix);
  return Number.isFinite(n) ? n : null;
}

/** Evaluate one expression against the localparams seen so far. */
function evalInt(expr: string, params: Map<string, number>): number | null {
  const e = expr.trim();
  if (/^-?\d[\d_]*$/.test(e)) return parseInt(e.replace(/_/g, ""), 10);
  const sized = sizedLiteral(e);
  if (sized !== null) return sized;
  const cast = /^([A-Za-z_][\w:]*)'\((.*)\)$/s.exec(e);
  const inner = cast?.[2];
  if (inner !== undefined) return evalInt(inner, params);
  if (/^[A-Za-z_]\w*$/.test(e)) return params.get(e) ?? null;
  return null;
}

/** NrCores / NrHarts from a `*_config_pkg.sv`, or null where unresolved. */
export function readCoreTopology(svText: string): CoreTopology {
  const clean = stripComments(svText);
  const params = new Map<string, number>();
  for (const m of clean.matchAll(/localparam\s+(?:[\w:\s]+?\s)?([A-Za-z_]\w*)\s*=\s*([^;{]+);/g)) {
    const name = m[1];
    const expr = m[2];
    if (name === undefined || expr === undefined) continue;
    const v = evalInt(expr, params);
    if (v !== null) params.set(name, v);
  }
  const field = (name: string): number | null => {
    const m = new RegExp(`\\b${name}\\s*:\\s*([^,}]+)`).exec(clean);
    const expr = m?.[1];
    return expr === undefined ? null : evalInt(expr, params);
  };
  const cores = field("NrCores");
  const threads = field("NrHarts");
  const unresolved: string[] = [];
  if (cores === null) unresolved.push("NrCores");
  if (threads === null) unresolved.push("NrHarts");
  return { cores, threads, unresolved };
}

export function sha256Hex(text: string): string {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

export interface IngestCoreCheck {
  /** `legacy` when the bundle predates `core.harts` / `core.source`. */
  mode: "verified" | "legacy";
  issues: string[];
}

/**
 * Cross-check a `platform.json` `core` block against the config package it
 * names. Any issue blocks ingest; a legacy bundle (no `harts` / `source`) is
 * accepted with a warning so old scaffolds still import.
 */
export function checkIngestCore(core: Record<string, unknown>, pkgText: string): IngestCoreCheck {
  const harts = core.harts as { count?: unknown; cores?: unknown; threads?: unknown } | undefined;
  const source = core.source as { sha256?: unknown; path?: unknown } | undefined;
  if (!harts && !source) return { mode: "legacy", issues: [] };
  const issues: string[] = [];
  if (source && typeof source.sha256 === "string") {
    const actual = sha256Hex(pkgText);
    if (actual !== source.sha256) {
      issues.push(
        `core.source.sha256 ${source.sha256} does not match ${String(source.path ?? "the config package")} (${actual}); ` +
          "the config package changed after the board was compiled — recompile the board.",
      );
    }
  } else {
    issues.push("core.source.sha256 is missing; a verified bundle must name the config package it was compiled from.");
  }
  const topo = readCoreTopology(pkgText);
  if (topo.unresolved.length > 0) {
    issues.push(`config package topology unresolved: ${topo.unresolved.join(", ")}.`);
  }
  if (!harts || typeof harts.count !== "number" || typeof harts.cores !== "number" || typeof harts.threads !== "number") {
    issues.push("core.harts must carry numeric count, cores and threads.");
    return { mode: "verified", issues };
  }
  if (harts.count !== harts.cores * harts.threads) {
    issues.push(`core.harts.count ${harts.count} is not cores × threads (${harts.cores} × ${harts.threads}).`);
  }
  if (topo.cores !== null && topo.threads !== null) {
    if (topo.cores !== harts.cores || topo.threads !== harts.threads) {
      issues.push(
        `board advertises ${harts.cores} cores × ${harts.threads} threads; the config package has NrCores=${topo.cores} × NrHarts=${topo.threads}.`,
      );
    }
  }
  return { mode: "verified", issues };
}
