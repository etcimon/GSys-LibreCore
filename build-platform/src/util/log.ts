// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// log.ts — Minimal, dependency-free leveled logger with optional ANSI colour.

export type LogLevel =
  | "silent"
  | "error"
  | "warn"
  | "info"
  | "debug"
  | "trace";

const LEVEL_ORDER: Record<LogLevel, number> = {
  silent: 0,
  error: 1,
  warn: 2,
  info: 3,
  debug: 4,
  trace: 5,
};

const ANSI = {
  reset: "\x1b[0m",
  bold: "\x1b[1m",
  dim: "\x1b[2m",
  red: "\x1b[31m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  blue: "\x1b[34m",
  magenta: "\x1b[35m",
  cyan: "\x1b[36m",
  gray: "\x1b[90m",
} as const;

export interface LoggerOptions {
  level: LogLevel;
  color: boolean;
  timestamps: boolean;
}

export class Logger {
  private level: LogLevel;
  private color: boolean;
  private timestamps: boolean;

  constructor(options: Partial<LoggerOptions> = {}) {
    this.level = options.level ?? "info";
    this.color = options.color ?? true;
    this.timestamps = options.timestamps ?? false;
  }

  configure(options: Partial<LoggerOptions>): void {
    if (options.level) this.level = options.level;
    if (options.color !== undefined) this.color = options.color;
    if (options.timestamps !== undefined) this.timestamps = options.timestamps;
  }

  private paint(color: keyof typeof ANSI, text: string): string {
    if (!this.color) return text;
    return `${ANSI[color]}${text}${ANSI.reset}`;
  }

  private enabled(level: LogLevel): boolean {
    return LEVEL_ORDER[level] <= LEVEL_ORDER[this.level];
  }

  private prefix(tag: string, color: keyof typeof ANSI): string {
    const ts = this.timestamps
      ? this.paint("gray", `${new Date().toISOString()} `)
      : "";
    return `${ts}${this.paint(color, tag)}`;
  }

  error(message: string): void {
    if (this.enabled("error")) {
      process.stderr.write(`${this.prefix("✗", "red")} ${message}\n`);
    }
  }

  warn(message: string): void {
    if (this.enabled("warn")) {
      process.stderr.write(`${this.prefix("!", "yellow")} ${message}\n`);
    }
  }

  info(message: string): void {
    if (this.enabled("info")) {
      process.stdout.write(`${this.prefix("•", "cyan")} ${message}\n`);
    }
  }

  success(message: string): void {
    if (this.enabled("info")) {
      process.stdout.write(`${this.prefix("✓", "green")} ${message}\n`);
    }
  }

  debug(message: string): void {
    if (this.enabled("debug")) {
      process.stdout.write(`${this.prefix("»", "magenta")} ${message}\n`);
    }
  }

  trace(message: string): void {
    if (this.enabled("trace")) {
      process.stdout.write(`${this.prefix("·", "gray")} ${this.paint("gray", message)}\n`);
    }
  }

  /** Emit a bold section heading (respects the info threshold). */
  heading(text: string): void {
    if (this.enabled("info")) {
      process.stdout.write(`\n${this.paint("bold", text)}\n`);
    }
  }

  /** Emit a labelled multi-step marker, e.g. "[2/5] Installing Verilator". */
  step(index: number, total: number, text: string): void {
    if (this.enabled("info")) {
      const marker = this.paint("blue", `[${index}/${total}]`);
      process.stdout.write(`${marker} ${text}\n`);
    }
  }

  /**
   * Passthrough for child-process output. Callers that stream WSL/Git-Bash
   * should pre-decorate with CRLF on Windows (see exec.decorateConsoleChunk);
   * this method writes bytes as given so line buffering can stay correct.
   */
  raw(text: string): void {
    process.stdout.write(text);
  }
}

/** Shared default logger; reconfigured from config in the CLI entrypoint. */
export const log = new Logger();
