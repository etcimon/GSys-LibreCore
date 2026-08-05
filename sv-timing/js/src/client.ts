// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// TypeScript client: spawn Rust sv-timing CLI and rehydrate JSON DTOs.

import { mkdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

import {
  type AnalyzeOptions,
  type AnalyzeResult,
  type CorrectOptions,
  type CorrectResult,
  type DebugExportOptions,
  type DebugExportResult,
  type StatusResult,
  type SvTimingClientOptions,
  isAnalyzeResult,
  isCorrectResult,
  isDebugExportResult,
} from "./types.ts";
import {
  builtCliPath,
  containedCargo,
  containedRustEnv,
  packageRootFromJs,
} from "./paths.ts";

export class SvTimingClient {
  readonly packageRoot: string;
  readonly cwd: string;
  readonly timeoutMs: number;
  private readonly cliPath?: string;
  private readonly env: Record<string, string>;

  constructor(opts?: Partial<SvTimingClientOptions>) {
    this.packageRoot = opts?.packageRoot ?? packageRootFromJs();
    this.cwd = opts?.cwd ?? this.packageRoot;
    this.timeoutMs = opts?.timeoutMs ?? 180_000;
    this.cliPath = opts?.cliPath;
    this.env = {
      ...containedRustEnv(this.packageRoot),
      ...(opts?.env ?? {}),
    };
  }

  /** Run `sv-timing status` and parse optional --json-out. */
  async status(jsonOut?: string): Promise<{ text: string; json?: StatusResult }> {
    const args = ["status"];
    if (jsonOut) args.push("--json-out", jsonOut);
    const text = await this.runCli(args);
    if (jsonOut) {
      const json = JSON.parse(readFileSync(jsonOut, "utf8")) as StatusResult;
      return { text, json };
    }
    return { text };
  }

  /** Run analyze and return typed AnalyzeResult (requires jsonOut). */
  async analyze(options: AnalyzeOptions): Promise<AnalyzeResult> {
    if (!options.modules?.length && !options.allModules) {
      throw new Error("analyze requires modules[] or allModules (KD17)");
    }
    mkdirSync(dirname(resolve(this.cwd, options.jsonOut)), { recursive: true });
    const args = ["analyze", "--json-out", options.jsonOut];
    if (options.filesFrom) args.push("--files-from", options.filesFrom);
    for (const f of options.files ?? []) args.push("--file", f);
    for (const d of options.incdirs ?? []) args.push("--incdir", d);
    for (const d of options.defines ?? []) args.push("--define", d);
    if (options.allModules) args.push("--all-modules");
    else if (options.modules?.length)
      args.push("--modules", options.modules.join(","));
    if (options.targetMhz != null)
      args.push("--target-mhz", String(options.targetMhz));

    await this.runCli(args);
    const raw = JSON.parse(
      readFileSync(resolve(this.cwd, options.jsonOut), "utf8"),
    ) as unknown;
    if (!isAnalyzeResult(raw)) {
      throw new Error(
        `analyze JSON failed schema guard (schema_version/ast/files); got: ${JSON.stringify(raw).slice(0, 200)}`,
      );
    }
    return raw;
  }

  /** Run correct (default dry-run) and return CorrectResult. */
  async correct(options: CorrectOptions): Promise<CorrectResult> {
    mkdirSync(dirname(resolve(this.cwd, options.jsonOut)), { recursive: true });
    const args = ["correct", "--json-out", options.jsonOut];
    if (options.modulesAllow.length)
      args.push("--modules-allow", options.modulesAllow.join(","));
    if (options.filesFrom) args.push("--files-from", options.filesFrom);
    for (const f of options.files ?? []) args.push("--file", f);
    if (options.allowLatency) args.push("--allow-latency");
    if (options.assumeClk) args.push("--assume-clk");
    if (options.targetMhz != null)
      args.push("--target-mhz", String(options.targetMhz));
    if (options.maxPasses != null)
      args.push("--max-passes", String(options.maxPasses));
    if (options.dryRun !== false) args.push("--dry-run");
    else args.push("--emit");
    if (options.emitDir) args.push("--emit-dir", options.emitDir);

    await this.runCli(args);
    const raw = JSON.parse(
      readFileSync(resolve(this.cwd, options.jsonOut), "utf8"),
    ) as unknown;
    if (!isCorrectResult(raw)) {
      throw new Error("correct JSON failed schema guard");
    }
    return raw;
  }

  /** Run debug-export and return DebugExportResult. */
  async debugExport(options: DebugExportOptions): Promise<DebugExportResult> {
    mkdirSync(resolve(this.cwd, options.outDir), { recursive: true });
    const jsonOut =
      options.jsonOut ?? join(options.outDir, "debug-export.json");
    const args = [
      "debug-export",
      "--out-dir",
      options.outDir,
      "--json-out",
      jsonOut,
    ];
    if (options.tag) args.push("--tag", options.tag);
    if (options.filesFrom) args.push("--files-from", options.filesFrom);
    if (options.modules?.length)
      args.push("--modules", options.modules.join(","));

    await this.runCli(args);
    const raw = JSON.parse(
      readFileSync(resolve(this.cwd, jsonOut), "utf8"),
    ) as unknown;
    if (!isDebugExportResult(raw)) {
      throw new Error("debug-export JSON failed schema guard");
    }
    return raw;
  }

  /** Spawn CLI; return stdout text. Throws on non-zero exit. */
  async runCli(args: string[]): Promise<string> {
    const { cmd, cmdArgs } = this.resolveCommand(args);
    const proc = Bun.spawn([cmd, ...cmdArgs], {
      cwd: this.cwd,
      env: this.env,
      stdout: "pipe",
      stderr: "pipe",
    });

    const timeout = setTimeout(() => {
      try {
        proc.kill();
      } catch {
        /* ignore */
      }
    }, this.timeoutMs);

    const [stdout, stderr, exitCode] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
      proc.exited,
    ]);
    clearTimeout(timeout);

    if (exitCode !== 0) {
      throw new Error(
        `sv-timing ${args.join(" ")} failed (exit ${exitCode})\n${stderr}\n${stdout}`,
      );
    }
    return stdout;
  }

  private resolveCommand(cliArgs: string[]): { cmd: string; cmdArgs: string[] } {
    if (this.cliPath) {
      return { cmd: this.cliPath, cmdArgs: cliArgs };
    }
    const built = builtCliPath(this.packageRoot);
    if (built) {
      return { cmd: built, cmdArgs: cliArgs };
    }
    const cargo = containedCargo(this.packageRoot) ?? "cargo";
    return {
      cmd: cargo,
      cmdArgs: ["run", "-q", "-p", "sv-timing-cli", "--", ...cliArgs],
    };
  }
}

/** Default client rooted at the monorepo package. */
export function createClient(
  opts?: Partial<SvTimingClientOptions>,
): SvTimingClient {
  return new SvTimingClient(opts);
}
