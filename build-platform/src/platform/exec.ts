// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// exec.ts — Process runner built on Bun.spawn.
//
// Provides a single primitive for running external commands with consistent
// logging, output capture, live streaming, dry-run support, and locating
// executables on PATH. All tool recipes and shell dispatch build on this.

import { log as defaultLog, type Logger } from "../util/log.ts";

export type ExecStdio = "inherit" | "capture" | "both";

export interface RunOptions {
  cwd?: string;
  /** Extra environment entries merged over the current process env. */
  env?: Record<string, string | undefined>;
  /** How to handle child output. "both" captures AND echoes live (default). */
  stdio?: ExecStdio;
  /** Text piped to the child's stdin. */
  input?: string;
  /** When true, log the command but do not execute it. */
  dryRun?: boolean;
  /** Logger to use for command echo + streamed output. */
  logger?: Logger;
  /** Treat a non-zero exit as success (caller inspects result.code). */
  allowFailure?: boolean;
}

export interface CommandResult {
  command: string;
  code: number;
  stdout: string;
  stderr: string;
  durationMs: number;
  ok: boolean;
  dryRun: boolean;
}

export class CommandError extends Error {
  constructor(readonly result: CommandResult) {
    super(
      `Command failed (exit ${result.code}): ${result.command}\n${result.stderr.trim()}`,
    );
    this.name = "CommandError";
  }
}

function quoteForDisplay(parts: string[]): string {
  return parts
    .map((p) => (/\s|["']/.test(p) ? JSON.stringify(p) : p))
    .join(" ");
}

/**
 * Windows consoles (PowerShell 5.1 especially) treat bare LF poorly when child
 * streams are piped through Bun: lines "staircase" or run together. Convert to
 * CRLF for the host console only (captured text stays as the child produced it,
 * with normalized `\n` for tools).
 */
export function decorateConsoleChunk(text: string): string {
  // Collapse any existing CRLF/CR so we do not double-expand.
  const normalized = text.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
  if (process.platform === "win32") {
    return normalized.replace(/\n/g, "\r\n");
  }
  return normalized;
}

/**
 * Line-buffer child output so partial chunks (common from WSL/make) do not
 * interleave mid-line with the other stream or with host logger prefixes.
 */
export class LineBufferedEcho {
  private buf = "";
  constructor(
    private readonly write: (s: string) => void,
    private readonly decorate: (s: string) => string = decorateConsoleChunk,
  ) {}

  push(chunk: string): void {
    if (!chunk) return;
    // Normalize CR-only progress updates into LF so we flush clean lines.
    this.buf += chunk.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
    for (;;) {
      const nl = this.buf.indexOf("\n");
      if (nl < 0) break;
      const line = this.buf.slice(0, nl + 1);
      this.buf = this.buf.slice(nl + 1);
      this.write(this.decorate(line));
    }
  }

  flush(): void {
    if (!this.buf) return;
    // Ensure a trailing newline so the next host log line is not glued on.
    const tail = this.buf.endsWith("\n") ? this.buf : `${this.buf}\n`;
    this.buf = "";
    this.write(this.decorate(tail));
  }
}

async function pump(
  stream: ReadableStream<Uint8Array> | null,
  echo: LineBufferedEcho | null,
): Promise<string> {
  if (!stream) return "";
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let acc = "";
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      const text = decoder.decode(value, { stream: true });
      acc += text;
      if (echo) echo.push(text);
    }
    acc += decoder.decode();
  } finally {
    if (echo) echo.flush();
  }
  // Normalize captured text to LF for consistent false-pass grepping.
  return acc.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
}

/**
 * Run a command. Rejects with CommandError on non-zero exit unless
 * `allowFailure` is set.
 */
export async function run(
  cmd: string,
  args: string[] = [],
  options: RunOptions = {},
): Promise<CommandResult> {
  const logger = options.logger ?? defaultLog;
  const stdio: ExecStdio = options.stdio ?? "both";
  const display = quoteForDisplay([cmd, ...args]);
  const started = performance.now();

  logger.trace(`$ ${display}${options.cwd ? `  (cwd: ${options.cwd})` : ""}`);

  if (options.dryRun) {
    logger.info(`[dry-run] ${display}`);
    return {
      command: display,
      code: 0,
      stdout: "",
      stderr: "",
      durationMs: 0,
      ok: true,
      dryRun: true,
    };
  }

  const mergedEnv: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (v !== undefined) mergedEnv[k] = v;
  }
  if (options.env) {
    for (const [k, v] of Object.entries(options.env)) {
      if (v !== undefined) mergedEnv[k] = v;
    }
  }

  const wantCapture = stdio === "capture" || stdio === "both";
  const wantEcho = stdio === "inherit" || stdio === "both";

  let proc: ReturnType<typeof Bun.spawn>;
  try {
    proc = Bun.spawn([cmd, ...args], {
      cwd: options.cwd,
      env: mergedEnv,
      stdin: options.input ? "pipe" : "inherit",
      stdout: wantCapture ? "pipe" : "inherit",
      stderr: wantCapture ? "pipe" : "inherit",
    });
  } catch (err) {
    // Missing binary / uv_spawn ENOENT — treat as failed command when allowed.
    const msg = err instanceof Error ? err.message : String(err);
    const result: CommandResult = {
      command: display,
      code: 127,
      stdout: "",
      stderr: msg,
      durationMs: Math.round(performance.now() - started),
      ok: false,
      dryRun: false,
    };
    if (!options.allowFailure) throw new CommandError(result);
    return result;
  }

  if (options.input && proc.stdin && typeof proc.stdin !== "number") {
    proc.stdin.write(options.input);
    await proc.stdin.end();
  }

  // Line-buffered echo with CRLF on Windows so PowerShell 5.1 / conhost show
  // WSL and Git-Bash output with correct line breaks (not staircased/glued).
  const outEcho = wantEcho
    ? new LineBufferedEcho((s) => {
        logger.raw(s);
      })
    : null;
  const errEcho = wantEcho
    ? new LineBufferedEcho((s) => {
        process.stderr.write(s);
      })
    : null;

  const [stdout, stderr] = await Promise.all([
    wantCapture
      ? pump(proc.stdout as ReadableStream<Uint8Array>, outEcho)
      : Promise.resolve(""),
    wantCapture
      ? pump(proc.stderr as ReadableStream<Uint8Array>, errEcho)
      : Promise.resolve(""),
  ]);

  const code = await proc.exited;
  const durationMs = Math.round(performance.now() - started);
  const result: CommandResult = {
    command: display,
    code,
    stdout,
    stderr,
    durationMs,
    ok: code === 0,
    dryRun: false,
  };

  if (!result.ok && !options.allowFailure) {
    throw new CommandError(result);
  }
  return result;
}

/** Locate an executable on PATH; returns its absolute path or null. */
export function which(bin: string): string | null {
  return Bun.which(bin);
}

/** True if an executable is resolvable on PATH. */
export function hasBinary(bin: string): boolean {
  return which(bin) !== null;
}

/** Run a command purely to capture its stdout (trimmed); "" on failure. */
export async function capture(
  cmd: string,
  args: string[] = [],
  options: RunOptions = {},
): Promise<string> {
  const result = await run(cmd, args, {
    ...options,
    stdio: "capture",
    allowFailure: true,
  });
  return result.ok ? result.stdout.trim() : "";
}
