// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// branding-g6lc.test.ts — Lint gate for GSys LibreCore (G6LC) rename integrity.
//
// Locks AGENTS-branding.md for core/ + corev_apu/:
//   * every g6lc_*.sv file (except active config packages) declares a matching
//     module/package stem;
//   * no dangling pre-rename LibreCore module tokens (cva6_ooo_*, cva6_smt_*, …);
//   * the five g6lc64_* config packages exist and brand constants in g6lc_pkg
//     match the product strings.
//
// Run: bun test test/branding-g6lc.test.ts

import { readdirSync, readFileSync, statSync, existsSync } from "node:fs";
import { basename, join, relative } from "node:path";

import { describe, expect, test } from "bun:test";

import { createContext } from "../src/context.ts";

const ctx = await createContext({ logLevel: "warn" });
const repo = ctx.repoRoot;

const G6LC_ROOTS = ["core", "corev_apu"] as const;

/** Pre-rename LibreCore module/package identifiers that must not reappear. */
const FORBIDDEN_MODULE_TOKENS: RegExp[] = [
  /\bcva6_ooo_/g,
  /\bcva6_smt_/g,
  /\bcva6_slice_/g,
  /\bcva6_bp_/g,
  /\bcva6_ftq\b/g,
  /\bcva6_fdip\b/g,
  /\bcva6_loop_buffer\b/g,
  /\bcva6_way_predictor\b/g,
  /\bcva6_rrip_repl\b/g,
  // g6lc_icache replaced cva6_icache; tier-U cva6_icache_axi_wrapper stays (no \b match).
  /\bcva6_icache\b/g,
  /\bcva6_l2_/g,
  /\bcva6_l3_/g,
  /\bcva6_coherence_/g,
  /\bcva6_server_prefetcher\b/g,
  /\bcva6_ara_attach\b/g,
  /\bcva6_axi_2to1/g,
  /\bcva6_cluster\b/g,
  /\bcv64a6_smt2\b/g,
  /\bcv64a6_ooo_server\b/g,
  /\bcv64a6_ooo\b/g,
  /\bcv64a6_server_math_v\b/g,
  /\bcv64a6_server_math\b/g,
];

const REQUIRED_CONFIG_PKGS = [
  "g6lc64_smt2_config_pkg.sv",
  "g6lc64_ooo_config_pkg.sv",
  "g6lc64_ooo_server_config_pkg.sv",
  "g6lc64_server_math_config_pkg.sv",
  "g6lc64_server_math_v_config_pkg.sv",
] as const;

function walkSv(dir: string, out: string[] = []): string[] {
  if (!existsSync(dir)) return out;
  for (const ent of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, ent.name);
    if (ent.isDirectory()) {
      // Skip tb-only noise under corev_apu/tb for forbidden-token scan of *rtl*
      // but still scan — rename bugs can appear in tb too.
      walkSv(p, out);
    } else if (ent.isFile() && /\.svh?$/i.test(ent.name)) {
      out.push(p);
    }
  }
  return out;
}

function listG6lcSvFiles(): string[] {
  const files: string[] = [];
  for (const root of G6LC_ROOTS) {
    const base = join(repo, root);
    for (const f of walkSv(base)) {
      if (/^g6lc/i.test(basename(f))) files.push(f);
    }
  }
  return files.sort();
}

/** Active config packages keep `package cva6_config_pkg` by design (TARGET_CFG). */
function isActiveConfigPackage(file: string): boolean {
  return /g6lc64_.*_config_pkg\.sv$/i.test(basename(file));
}

function declaredStems(src: string): string[] {
  const stems: string[] = [];
  const re = /\b(?:module|package|interface|program)\s+([A-Za-z_][A-Za-z0-9_]*)/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(src)) !== null) {
    stems.push(m[1]!);
  }
  return stems;
}

describe("GSys LibreCore / G6LC branding rename", () => {
  test("lists a non-empty set of g6lc_*.sv under core/ and corev_apu/", () => {
    const files = listG6lcSvFiles();
    expect(files.length).toBeGreaterThan(40);
  });

  test("g6lc*.sv files declare a matching module/package stem (config pkgs exempt)", () => {
    const failures: string[] = [];
    for (const file of listG6lcSvFiles()) {
      if (isActiveConfigPackage(file)) continue;
      const stem = basename(file).replace(/\.svh?$/i, "");
      const src = readFileSync(file, "utf8");
      const stems = declaredStems(src);
      if (!stems.includes(stem)) {
        failures.push(
          `${relative(repo, file)}: expected module|package ${stem}, found [${stems.join(", ") || "none"}]`,
        );
      }
    }
    expect(failures).toEqual([]);
  });

  test("five g6lc64_* config packages exist under core/include/", () => {
    for (const name of REQUIRED_CONFIG_PKGS) {
      const p = join(repo, "core", "include", name);
      expect(existsSync(p)).toBe(true);
      const src = readFileSync(p, "utf8");
      // Selection contract: active config package name remains cva6_config_pkg.
      expect(src).toMatch(/\bpackage\s+cva6_config_pkg\s*;/);
    }
  });

  test("g6lc_pkg brand constants match GSys LibreCore / LibreCore / G6LC", () => {
    const p = join(repo, "core", "include", "g6lc_pkg.sv");
    expect(existsSync(p)).toBe(true);
    const src = readFileSync(p, "utf8");
    expect(src).toMatch(/package\s+g6lc_pkg\s*;/);
    expect(src).toMatch(/G6LC_PRODUCT_NAME\s*=\s*"GSys LibreCore"/);
    expect(src).toMatch(/G6LC_SHORT_NAME\s*=\s*"LibreCore"/);
    expect(src).toMatch(/G6LC_CODE_PREFIX\s*=\s*"G6LC"/);
    expect(src).toMatch(/typedef\s+config_pkg::cva6_cfg_t\s+g6lc_cfg_t\s*;/);
  });

  test("no dangling pre-rename LibreCore module tokens in core/ and corev_apu/", () => {
    const hits: string[] = [];
    for (const root of G6LC_ROOTS) {
      for (const file of walkSv(join(repo, root))) {
        // Skip pure commentary heritage only if needed — scan all RTL.
        const src = readFileSync(file, "utf8");
        // Strip block comments so historical notes in long headers don't false-positive.
        const stripped = src
          .replace(/\/\*[\s\S]*?\*\//g, " ")
          .replace(/\/\/[^\n]*/g, " ");
        for (const re of FORBIDDEN_MODULE_TOKENS) {
          re.lastIndex = 0;
          if (re.test(stripped)) {
            re.lastIndex = 0;
            const m = stripped.match(re);
            hits.push(`${relative(repo, file)}: ${m?.[0] ?? re.source}`);
          }
        }
      }
    }
    expect(hits).toEqual([]);
  });

  test("g6lc_*.sv files are regular files (not empty stubs)", () => {
    for (const file of listG6lcSvFiles()) {
      const st = statSync(file);
      expect(st.size).toBeGreaterThan(32);
    }
  });
});
