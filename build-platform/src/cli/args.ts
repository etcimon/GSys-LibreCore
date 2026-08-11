// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// args.ts — Tiny, dependency-free argv parser.
//
// Supports: a leading subcommand, positionals, `--flag`, `--key=value`,
// `--key value` (for known value-flags), and short `-x` boolean bundles.

export type FlagValue = string | boolean;

export interface ParsedArgs {
  command: string | null;
  positionals: string[];
  flags: Record<string, FlagValue>;
}

/** Global flags that take a value in the `--key value` form. */
const VALUE_FLAGS = new Set([
  "config",
  "iss",
  "target",
  "suite",
  "group",
  "log-level",
  "ref",
  // setup / tools install profiles
  "profile",
  // motherboard (`mb`) flow
  "board",
  "add",
  "query",
  "phy",
  "out",
  "name",
  "vendor",
  "class",
  "core",
  "xlen",
  "tool",
  // technology optimization (`tech`) flow
  "tech",
  "pdk",
  // man (human docs via grok)
  "id",
  "file",
  "query",
  "model",
  "q",
  // timings (sv-timing host adapter) / tensor (ai-tensor host adapter)
  "dir",
  "modules",
  "target-mhz",
  "fo4-ps",
  "json-out",
  "flist",
  "cache",
  "param-map",
  "package-mode",
  "assume-xlen",
  "from-timing",
  "from-handoff",
  "output",
  "bench",
  "liberty",
  "top",
  "golden",
  "inject-sta-fixture",
  // tensor multi-phase / board path
  "impl",
  "backend",
  "virt-mode",
  "apu",
  // clean (workspace lifecycle)
  "older-than",
  "compartment",
  "execution",
  // build/verify expert emit
  "use-emit",
]);

const SHORT_ALIASES: Record<string, string> = {
  h: "help",
  v: "verbose",
  q: "quiet",
  f: "force",
  n: "dry-run",
  y: "yes",
  o: "output",
};

export function parseArgs(argv: string[]): ParsedArgs {
  const positionals: string[] = [];
  const flags: Record<string, FlagValue> = {};
  let command: string | null = null;

  for (let i = 0; i < argv.length; i++) {
    const token = argv[i]!;

    if (token.startsWith("--")) {
      const body = token.slice(2);
      const eq = body.indexOf("=");
      if (eq >= 0) {
        flags[body.slice(0, eq)] = body.slice(eq + 1);
      } else if (VALUE_FLAGS.has(body) && i + 1 < argv.length && !argv[i + 1]!.startsWith("-")) {
        flags[body] = argv[++i]!;
      } else {
        flags[body] = true;
      }
      continue;
    }

    if (token.startsWith("-") && token.length > 1 && !token.startsWith("--")) {
      // Single short option that maps to a value flag: `-o DIR`
      if (token.length === 2) {
        const long = SHORT_ALIASES[token[1]!] ?? token[1]!;
        if (VALUE_FLAGS.has(long) && i + 1 < argv.length && !argv[i + 1]!.startsWith("-")) {
          flags[long] = argv[++i]!;
          continue;
        }
      }
      // `-oDIR` glued form for value flags
      if (token.length > 2) {
        const long = SHORT_ALIASES[token[1]!] ?? token[1]!;
        if (VALUE_FLAGS.has(long)) {
          flags[long] = token.slice(2);
          continue;
        }
      }
      for (const ch of token.slice(1)) {
        flags[SHORT_ALIASES[ch] ?? ch] = true;
      }
      continue;
    }

    if (command === null) {
      command = token;
    } else {
      positionals.push(token);
    }
  }

  return { command, positionals, flags };
}

/** Read a flag as a string, or return the fallback. */
export function flagString(
  flags: Record<string, FlagValue>,
  key: string,
  fallback?: string,
): string | undefined {
  const value = flags[key];
  return typeof value === "string" ? value : fallback;
}

/** Read a flag as a boolean. */
export function flagBool(
  flags: Record<string, FlagValue>,
  key: string,
): boolean {
  return flags[key] === true || flags[key] === "true";
}
