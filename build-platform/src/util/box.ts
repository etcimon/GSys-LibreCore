// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// box.ts — Terminal categorical boxes / tab strips for probe reports.
//
// Pure string builders (no side effects). Used by `probe` so host/platform/
// package-manager/tooling sections render as consistent framed panels.

export interface BoxRow {
  /** Left label (padded). Empty = full-width value line. */
  label?: string;
  value: string;
  /** ok | warn | miss | dim | plain */
  tone?: "ok" | "warn" | "miss" | "dim" | "plain";
}

export interface BoxOptions {
  title: string;
  width?: number;
  color?: boolean;
  /** Optional tab id shown as [id] in the title bar. */
  tabId?: string;
}

const ANSI = {
  reset: "\x1b[0m",
  bold: "\x1b[1m",
  dim: "\x1b[2m",
  red: "\x1b[31m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  cyan: "\x1b[36m",
  gray: "\x1b[90m",
} as const;

function paint(color: boolean, code: string, text: string): string {
  if (!color) return text;
  return `${code}${text}${ANSI.reset}`;
}

function stripAnsi(s: string): string {
  return s.replace(/\x1b\[[0-9;]*m/g, "");
}

function visibleLen(s: string): number {
  return stripAnsi(s).length;
}

function padVis(s: string, width: number): string {
  const n = visibleLen(s);
  if (n >= width) return s.slice(0, Math.max(0, width));
  return s + " ".repeat(width - n);
}

function toneMark(tone: BoxRow["tone"], color: boolean): string {
  switch (tone) {
    case "ok":
      return paint(color, ANSI.green, "✓");
    case "warn":
      return paint(color, ANSI.yellow, "!");
    case "miss":
      return paint(color, ANSI.red, "✗");
    case "dim":
      return paint(color, ANSI.gray, "·");
    default:
      return " ";
  }
}

function toneValue(tone: BoxRow["tone"], color: boolean, value: string): string {
  switch (tone) {
    case "ok":
      return paint(color, ANSI.green, value);
    case "warn":
      return paint(color, ANSI.yellow, value);
    case "miss":
      return paint(color, ANSI.red, value);
    case "dim":
      return paint(color, ANSI.gray, value);
    default:
      return value;
  }
}

/** Draw a single framed box with labelled rows. */
export function renderBox(rows: BoxRow[], options: BoxOptions): string {
  const width = Math.max(40, Math.min(options.width ?? 72, 100));
  const color = options.color ?? true;
  const inner = width - 2; // between vertical bars
  const tab = options.tabId ? ` [${options.tabId}]` : "";
  const titleRaw = ` ${options.title}${tab} `;
  const title = paint(color, ANSI.bold + ANSI.cyan, titleRaw);
  const titleVis = visibleLen(titleRaw);
  const fill = Math.max(0, inner - 1 - titleVis);
  const top =
    "┌" +
    "─" +
    title +
    "─".repeat(fill) +
    "┐";

  const lines: string[] = [top];
  const labelW = 14;

  for (const row of rows) {
    const mark = toneMark(row.tone, color);
    let body: string;
    if (row.label) {
      const lab = paint(color, ANSI.dim, padVis(row.label, labelW));
      const val = toneValue(row.tone, color, row.value);
      body = `${mark} ${lab} ${val}`;
    } else {
      body = `${mark} ${toneValue(row.tone, color, row.value)}`;
    }
    // Truncate if needed (on visible length)
    let out = body;
    if (visibleLen(out) > inner - 2) {
      const plain = stripAnsi(out);
      out = plain.slice(0, inner - 5) + "...";
      if (color && row.tone === "miss") out = paint(true, ANSI.red, out);
    }
    lines.push("│ " + padVis(out, inner - 2) + " │");
  }

  lines.push("└" + "─".repeat(inner) + "┘");
  return lines.join("\n");
}

/** Tab strip: active tab highlighted, others dim. */
export function renderTabStrip(
  tabs: { id: string; label: string; active?: boolean; missing?: number }[],
  options: { color?: boolean } = {},
): string {
  const color = options.color ?? true;
  const parts = tabs.map((t) => {
    const badge = t.missing && t.missing > 0 ? ` (${t.missing}↓)` : "";
    const text = `${t.label}${badge}`;
    if (t.active) return paint(color, ANSI.bold + ANSI.cyan, `[${text}]`);
    if (t.missing && t.missing > 0) return paint(color, ANSI.yellow, ` ${text} `);
    return paint(color, ANSI.dim, ` ${text} `);
  });
  return parts.join(paint(color, ANSI.dim, " │ "));
}

/** Compact key=value status line used inside boxes. */
export function statusValue(
  found: boolean,
  version: string | null | undefined,
  extra?: string,
): { value: string; tone: BoxRow["tone"] } {
  if (!found) {
    return { value: extra ? `not found — ${extra}` : "not found", tone: "miss" };
  }
  const v = version?.trim() || "present";
  return { value: extra ? `${v}  ${extra}` : v, tone: "ok" };
}
