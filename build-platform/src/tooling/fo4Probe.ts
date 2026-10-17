// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// Platform FO4 probe inputs: find the liberty's minimum inverter and write a
// netlist of two inverter chains (8 and 4 stages, each stage loaded by four
// copies) for scripts/openroad-fo4-probe.tcl. The probe's result — the
// stage delay of an inverter driving four of itself — is the unit that turns
// a mapped path delay into an adjusted FO4 (`sv-timing adjusted`), so the
// 10-FO4 budget reads as a cycle time on the platform that was mapped and as
// a frequency on any process characterised by its own fo4_ps.
//
// The liberty scan is textual and deliberately narrow: a cell whose single
// input pin feeds one output pin with function `!A`, `(!A)`, `!(A)` or `A'`
// (any pin name), smallest `area` first. Gzip'd libraries are read through
// Bun's gunzip, so asap7's `.lib.gz` qualifies for the probe even though yosys
// cannot map onto it.

import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, join } from "node:path";

export interface LibertyInverter {
  cell: string;
  inputPin: string;
  outputPin: string;
  area: number;
}

/**
 * Follow a symlink that a checkout without symlink support stored as a tiny
 * file holding the target's name (the fork's `sky130hd_tt.lib` →
 * `sky130_fd_sc_hd__tt_025C_1v80.lib` on Windows). Real files pass through.
 */
export function resolveLibertyLink(path: string, depth = 0): string {
  if (depth > 4 || !existsSync(path)) return path;
  try {
    if (statSync(path).size > 256) return path;
    const target = readFileSync(path, "utf8").trim();
    if (!target || /[\n\r{};]/.test(target)) return path;
    const candidate = join(dirname(path), target);
    return existsSync(candidate) ? resolveLibertyLink(candidate, depth + 1) : path;
  } catch {
    return path;
  }
}

/** Read a liberty, inflating `.gz` when needed. */
export function readLibertyText(path: string): string {
  const real = resolveLibertyLink(path);
  const raw = readFileSync(real);
  if (real.endsWith(".gz")) return Buffer.from(Bun.gunzipSync(raw)).toString("utf8");
  return raw.toString("utf8");
}

/**
 * Walk the liberty text once with a brace depth counter, collecting each
 * `cell (NAME) { … }` body, then inspect its `pin (…) { … }` groups.
 */
export function findInverters(libertyText: string): LibertyInverter[] {
  const out: LibertyInverter[] = [];
  const cellRe = /\bcell\s*\(\s*"?([^")\s]+)"?\s*\)\s*\{/g;
  let m: RegExpExecArray | null;
  while ((m = cellRe.exec(libertyText))) {
    const start = cellRe.lastIndex;
    const end = matchBrace(libertyText, start - 1);
    if (end < 0) break;
    const body = libertyText.slice(start, end);
    cellRe.lastIndex = end;
    const inv = inverterOf(m[1]!, body);
    if (inv) out.push(inv);
  }
  // Smallest area first; among equal footprints (sky130's clkinv_1 / inv_1,
  // asap7's INVxp33 / INVx1) the plainest name is the unit logic inverter.
  return out.sort((a, b) => a.area - b.area || a.cell.length - b.cell.length || a.cell.localeCompare(b.cell));
}

/** Inverters across several libraries (a platform's corner may split cells by family). */
export function findInvertersIn(libertyPaths: string[]): LibertyInverter[] {
  const all: LibertyInverter[] = [];
  for (const p of libertyPaths) {
    try {
      all.push(...findInverters(readLibertyText(p)));
    } catch {
      // a missing or unreadable member leaves the others
    }
  }
  return all.sort((a, b) => a.area - b.area || a.cell.length - b.cell.length || a.cell.localeCompare(b.cell));
}

/** Index of the `}` closing the `{` at `open`, or -1. */
function matchBrace(text: string, open: number): number {
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    const c = text[i];
    if (c === "{") depth++;
    else if (c === "}") {
      depth--;
      if (depth === 0) return i;
    }
  }
  return -1;
}

function inverterOf(cell: string, body: string): LibertyInverter | null {
  // Only leaf cells: a `ff`/`latch`/`statetable` group or a bus is not an inverter.
  if (/\b(ff|latch|statetable|bus|bundle)\s*\(/.test(body)) return null;
  if (/\bdont_use\s*:\s*true\b/.test(body)) return null;
  // Some libraries omit the `;` after a scalar attribute (asap7's `area`).
  const areaM = body.match(/^\s*area\s*:\s*([\d.eE+-]+)\s*;?/m);
  const area = areaM ? Number(areaM[1]) : NaN;
  const pins: { name: string; direction: string; func?: string }[] = [];
  const pinRe = /\bpin\s*\(\s*"?([^")\s]+)"?\s*\)\s*\{/g;
  let p: RegExpExecArray | null;
  while ((p = pinRe.exec(body))) {
    const s = pinRe.lastIndex;
    const e = matchBrace(body, s - 1);
    if (e < 0) return null;
    const pb = body.slice(s, e);
    pinRe.lastIndex = e;
    const dir = pb.match(/\bdirection\s*:\s*"?(\w+)"?\s*;/)?.[1] ?? "";
    const func = pb.match(/\bfunction\s*:\s*"([^"]*)"\s*;/)?.[1];
    pins.push({ name: p[1]!, direction: dir, func });
  }
  const inputs = pins.filter((x) => x.direction === "input");
  const outputs = pins.filter((x) => x.direction === "output");
  if (inputs.length !== 1 || outputs.length !== 1) return null;
  const a = inputs[0]!.name;
  const f = (outputs[0]!.func ?? "").replace(/\s+/g, "");
  const forms = new Set([`!${a}`, `(!${a})`, `!(${a})`, `${a}'`, `(${a}')`]);
  if (!forms.has(f)) return null;
  if (!Number.isFinite(area)) return null;
  return { cell, inputPin: a, outputPin: outputs[0]!.name, area };
}

/**
 * The probe netlist: chain `a8 → y8` of 8 stages and `a4 → y4` of 4 stages.
 * Each stage output drives the next stage plus three dummy copies whose
 * outputs float, so every measured stage sees exactly four identical loads.
 */
export function probeNetlist(inv: LibertyInverter, stages8 = 8, stages4 = 4): string {
  const lines = ["// Generated FO4 probe: two inverter chains, every stage loaded by four copies.", "module fo4_probe(a8, y8, a4, y4);", "  input a8, a4;", "  output y8, y4;"];
  const chain = (prefix: string, input: string, output: string, n: number) => {
    const nets: string[] = [];
    for (let i = 1; i < n; i++) nets.push(`${prefix}_n${i}`);
    if (nets.length) lines.push(`  wire ${nets.join(", ")};`);
    for (let i = 0; i < n; i++) {
      const from = i === 0 ? input : `${prefix}_n${i}`;
      const to = i === n - 1 ? output : `${prefix}_n${i + 1}`;
      lines.push(`  ${inv.cell} ${prefix}_u${i} (.${inv.inputPin}(${from}), .${inv.outputPin}(${to}));`);
      if (i < n - 1) {
        for (let k = 0; k < 3; k++) {
          lines.push(`  ${inv.cell} ${prefix}_l${i}_${k} (.${inv.inputPin}(${to}), .${inv.outputPin}());`);
        }
      }
    }
  };
  chain("c8", "a8", "y8", stages8);
  chain("c4", "a4", "y4", stages4);
  lines.push("endmodule", "");
  return lines.join("\n");
}

/** Pick the platform's inverter and render the probe netlist, or explain why not. */
export function buildProbe(libertyPaths: string | string[]): { inverter: LibertyInverter; netlist: string } | { error: string } {
  const paths = Array.isArray(libertyPaths) ? libertyPaths : [libertyPaths];
  const missing = paths.filter((p) => !existsSync(p));
  if (missing.length === paths.length) return { error: `liberty not found: ${paths.join(", ")}` };
  const inverters = findInvertersIn(paths.filter((p) => existsSync(p)));
  if (!inverters.length) return { error: `no single-input inverter cell with an area in ${paths.join(", ")}` };
  const inverter = inverters[0]!;
  return { inverter, netlist: probeNetlist(inverter) };
}

/** Parse the probe's stdout line into a record, or null. */
export function parseProbeOutput(text: string): { fo4Ps: number; cell: string; chain8Ns: number; chain4Ns: number } | null {
  const m = text.match(/^FO4_PROBE ps=([\d.]+) cell=(\S+) chain8_ns=([\d.]+) chain4_ns=([\d.]+)/m);
  if (!m) return null;
  return { fo4Ps: Number(m[1]), cell: m[2]!, chain8Ns: Number(m[3]), chain4Ns: Number(m[4]) };
}
