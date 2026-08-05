// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// prompt.ts — Interactive y/n helpers for incomplete workspace tooling.
//
// Used by test/verify when managed tools are missing so a default Windows or
// Linux host can provision with one confirmation instead of a hard skip/fail.
// Never prompts when stdin is not a TTY, when --yes/--dry-run, or when
// G6LC_NO_TOOL_PROMPT / CVA6_NO_TOOL_PROMPT is set.

import * as readline from "node:readline";

/** True when we may ask the user a question. */
export function canPromptInteractive(flags: Record<string, string | boolean> = {}): boolean {
  if (process.env.G6LC_NO_TOOL_PROMPT === "1" || process.env.CVA6_NO_TOOL_PROMPT === "1") {
    return false;
  }
  if (process.env.CI === "true" || process.env.CI === "1") return false;
  if (flags["dry-run"] === true || flags.n === true) return false;
  // --yes means auto-accept, still "interactive path" for callers that check separately
  return Boolean(process.stdin.isTTY && process.stdout.isTTY);
}

export function wantsAutoYes(flags: Record<string, string | boolean> = {}): boolean {
  return flags.yes === true || flags.y === true || process.env.G6LC_TOOLS_INSTALL_YES === "1";
}

/**
 * Ask a yes/no question. Returns true for y/yes.
 * Default is **no** when the user presses enter on an empty line.
 */
export async function promptYesNo(question: string, defaultYes = false): Promise<boolean> {
  const hint = defaultYes ? "Y/n" : "y/N";
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  try {
    const answer: string = await new Promise((resolve) => {
      rl.question(`${question} [${hint}] `, resolve);
    });
    const a = (answer ?? "").trim().toLowerCase();
    if (a === "") return defaultYes;
    return a === "y" || a === "yes";
  } finally {
    rl.close();
  }
}

/**
 * Resolve whether to install: auto-yes flags, interactive prompt, or decline.
 */
export async function confirmToolInstall(
  message: string,
  flags: Record<string, string | boolean> = {},
): Promise<boolean> {
  if (wantsAutoYes(flags)) return true;
  if (!canPromptInteractive(flags)) return false;
  return promptYesNo(message, false);
}
