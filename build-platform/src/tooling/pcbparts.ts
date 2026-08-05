// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// pcbparts.ts — Typed client for the pcbparts.dev MCP server.
//
// This is the engine the `mb` command uses to reach the 14 pcbparts.dev tools
// (JLCPCB / Mouser / DigiKey search, pinouts, alternatives, OSHW reference
// boards, KiCad footprints, and design rules). It speaks the MCP "Streamable
// HTTP" transport (JSON-RPC 2.0 over a single POST endpoint, response either
// application/json or a text/event-stream carrying `data:` frames).
//
// Two hard rules, matching the rest of build-platform:
//   1. NO IMPLICIT NETWORK. A tool call only reaches the wire when the caller
//      passes { allowNetwork: true } (wired to an explicit CLI flag). Otherwise
//      the client is cache-first and returns a typed "would query" stub.
//   2. Everything is cached under the managed workspace so re-queries during
//      the ERC↔alternatives design loop are fast and reproducible offline.
//
// No API key is required by pcbparts.dev, so there is no secret handling here.

import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

import type { Logger } from "../util/log.ts";

/** The 14 tools published by pcbparts.dev, as of the server's tool registry. */
export type PcbPartsTool =
  | "jlc_search"
  | "jlc_stock_check"
  | "jlc_get_part"
  | "jlc_get_pinout"
  | "jlc_find_alternatives"
  | "jlc_search_help"
  | "sensor_recommend"
  | "board_search"
  | "board_get"
  | "mouser_get_part"
  | "digikey_get_part"
  | "cse_search"
  | "cse_get_kicad"
  | "get_design_rules";

export const PCBPARTS_TOOLS: readonly PcbPartsTool[] = [
  "jlc_search",
  "jlc_stock_check",
  "jlc_get_part",
  "jlc_get_pinout",
  "jlc_find_alternatives",
  "jlc_search_help",
  "sensor_recommend",
  "board_search",
  "board_get",
  "mouser_get_part",
  "digikey_get_part",
  "cse_search",
  "cse_get_kicad",
  "get_design_rules",
] as const;

export interface PcbPartsClientOptions {
  url: string;
  timeoutMs: number;
  retries: number;
  /** Absolute cache directory. */
  cacheDir: string;
  logger: Logger;
  /** When false (default), never hit the network — return cache or a stub. */
  allowNetwork?: boolean;
}

export interface PcbPartsResult<T = unknown> {
  tool: PcbPartsTool;
  args: Record<string, unknown>;
  /** Parsed tool payload (from the MCP tool result content), or null. */
  data: T | null;
  /** Where the result came from. */
  source: "cache" | "network" | "stub";
  /** Present when source === "stub" (network disabled) or on error. */
  note?: string;
  ok: boolean;
}

interface JsonRpcResponse {
  jsonrpc: "2.0";
  id: number | string;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}

/**
 * Minimal MCP client. Stateless between process runs; a session id (if the
 * server issues one) is kept for the life of the instance only.
 */
export class PcbPartsClient {
  private readonly url: string;
  private readonly timeoutMs: number;
  private readonly retries: number;
  private readonly cacheDir: string;
  private readonly logger: Logger;
  private readonly allowNetwork: boolean;
  private sessionId: string | null = null;
  private initialised = false;
  private nextId = 1;

  constructor(options: PcbPartsClientOptions) {
    this.url = options.url;
    this.timeoutMs = options.timeoutMs;
    this.retries = options.retries;
    this.cacheDir = options.cacheDir;
    this.logger = options.logger;
    this.allowNetwork = options.allowNetwork ?? false;
  }

  /** Stable cache path for a tool call (name + normalised args). */
  private cachePath(tool: PcbPartsTool, args: Record<string, unknown>): string {
    const key = createHash("sha1")
      .update(tool + "\u0000" + stableStringify(args))
      .digest("hex")
      .slice(0, 16);
    return join(this.cacheDir, `${tool}-${key}.json`);
  }

  private async readCache<T>(path: string): Promise<T | null> {
    if (!existsSync(path)) return null;
    try {
      return JSON.parse(await readFile(path, "utf8")) as T;
    } catch {
      return null;
    }
  }

  private async writeCache(path: string, value: unknown): Promise<void> {
    await mkdir(this.cacheDir, { recursive: true });
    await writeFile(path, JSON.stringify(value, null, 2) + "\n", "utf8");
  }

  /** Low-level JSON-RPC POST with timeout + retry, decoding json or SSE. */
  private async rpc(method: string, params: unknown): Promise<JsonRpcResponse> {
    const body = JSON.stringify({ jsonrpc: "2.0", id: this.nextId++, method, params });
    let lastErr: unknown;
    for (let attempt = 0; attempt <= this.retries; attempt++) {
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), this.timeoutMs);
      try {
        const headers: Record<string, string> = {
          "content-type": "application/json",
          accept: "application/json, text/event-stream",
        };
        if (this.sessionId) headers["mcp-session-id"] = this.sessionId;
        const res = await fetch(this.url, {
          method: "POST",
          headers,
          body,
          signal: ctrl.signal,
        });
        const sid = res.headers.get("mcp-session-id");
        if (sid) this.sessionId = sid;
        const text = await res.text();
        if (!res.ok) throw new Error(`HTTP ${res.status}: ${text.slice(0, 200)}`);
        return parseRpcPayload(text);
      } catch (err) {
        lastErr = err;
        this.logger.debug(`pcbparts rpc '${method}' attempt ${attempt + 1} failed: ${String(err)}`);
      } finally {
        clearTimeout(timer);
      }
    }
    throw new Error(`pcbparts rpc '${method}' failed after ${this.retries + 1} attempt(s): ${String(lastErr)}`);
  }

  /** MCP initialize handshake (once per client). */
  private async ensureInitialised(): Promise<void> {
    if (this.initialised) return;
    await this.rpc("initialize", {
      protocolVersion: "2025-06-18",
      capabilities: {},
      clientInfo: { name: "g6lc-build-platform", version: "0.1.0" },
    });
    // Best-effort notification; ignore failures on servers that do not need it.
    try {
      await this.rpc("notifications/initialized", {});
    } catch {
      /* not fatal */
    }
    this.initialised = true;
  }

  /** List the tools the server advertises (network-gated). */
  async listTools(opts: { allowNetwork?: boolean } = {}): Promise<string[]> {
    if (!(opts.allowNetwork ?? this.allowNetwork)) return [...PCBPARTS_TOOLS];
    await this.ensureInitialised();
    const resp = await this.rpc("tools/list", {});
    const tools = (resp.result as { tools?: { name: string }[] } | undefined)?.tools ?? [];
    return tools.map((t) => t.name);
  }

  /**
   * Call one pcbparts.dev tool. Cache-first; only reaches the network when
   * allowNetwork is set (per call or client-wide). Returns a typed result with
   * an explicit `source` so callers can surface provenance.
   */
  async callTool<T = unknown>(
    tool: PcbPartsTool,
    args: Record<string, unknown>,
    opts: { allowNetwork?: boolean; refresh?: boolean } = {},
  ): Promise<PcbPartsResult<T>> {
    const cachePath = this.cachePath(tool, args);
    if (!opts.refresh) {
      const cached = await this.readCache<T>(cachePath);
      if (cached !== null) return { tool, args, data: cached, source: "cache", ok: true };
    }

    const allow = opts.allowNetwork ?? this.allowNetwork;
    if (!allow) {
      return {
        tool,
        args,
        data: null,
        source: "stub",
        ok: true,
        note: "network disabled (pass --online to query pcbparts.dev)",
      };
    }

    try {
      await this.ensureInitialised();
      const resp = await this.rpc("tools/call", { name: tool, arguments: args });
      if (resp.error) {
        return { tool, args, data: null, source: "network", ok: false, note: resp.error.message };
      }
      const data = extractToolPayload<T>(resp.result);
      await this.writeCache(cachePath, data);
      return { tool, args, data, source: "network", ok: true };
    } catch (err) {
      return { tool, args, data: null, source: "network", ok: false, note: String(err) };
    }
  }

  // --- Typed convenience wrappers over the 14 tools ------------------------

  /** Parametric part search with spec filters. */
  jlcSearch(args: { query?: string; category?: string; filters?: Record<string, unknown>; limit?: number }, o?: CallOpts) {
    return this.callTool("jlc_search", args, o);
  }
  /** Real-time stock verification. */
  jlcStockCheck(args: { lcsc?: string; mpn?: string }, o?: CallOpts) {
    return this.callTool("jlc_stock_check", args, o);
  }
  /** Part details, datasheet, footprint. */
  jlcGetPart(args: { lcsc?: string; mpn?: string }, o?: CallOpts) {
    return this.callTool("jlc_get_part", args, o);
  }
  /** Pin info from EasyEDA symbols. */
  jlcGetPinout(args: { lcsc?: string; mpn?: string }, o?: CallOpts) {
    return this.callTool("jlc_get_pinout", args, o);
  }
  /** Spec-compatible alternative parts. */
  jlcFindAlternatives(args: { lcsc?: string; mpn?: string; limit?: number }, o?: CallOpts) {
    return this.callTool("jlc_find_alternatives", args, o);
  }
  /** Browse categories & filterable specs. */
  jlcSearchHelp(args: { category?: string } = {}, o?: CallOpts) {
    return this.callTool("jlc_search_help", args, o);
  }
  /** Sensor ICs by measurand, protocol, platform. */
  sensorRecommend(args: { measure?: string; protocol?: string; platform?: string }, o?: CallOpts) {
    return this.callTool("sensor_recommend", args, o);
  }
  /** Search ~285 OSHW reference schematics. */
  boardSearch(args: { query?: string; limit?: number }, o?: CallOpts) {
    return this.callTool("board_search", args, o);
  }
  /** Board BOM, neighborhoods, and design rules. */
  boardGet(args: { id?: string; slug?: string }, o?: CallOpts) {
    return this.callTool("board_get", args, o);
  }
  /** Cross-reference an MPN on Mouser. */
  mouserGetPart(args: { mpn: string }, o?: CallOpts) {
    return this.callTool("mouser_get_part", args, o);
  }
  /** Cross-reference an MPN on DigiKey. */
  digikeyGetPart(args: { mpn: string }, o?: CallOpts) {
    return this.callTool("digikey_get_part", args, o);
  }
  /** Search ECAD models and datasheets. */
  cseSearch(args: { query: string; limit?: number }, o?: CallOpts) {
    return this.callTool("cse_search", args, o);
  }
  /** KiCad symbols and footprints. */
  cseGetKicad(args: { mpn?: string; id?: string }, o?: CallOpts) {
    return this.callTool("cse_get_kicad", args, o);
  }
  /** PCB design rules & best practices. */
  getDesignRules(args: { process?: string; layers?: number; class?: string } = {}, o?: CallOpts) {
    return this.callTool("get_design_rules", args, o);
  }
}

type CallOpts = { allowNetwork?: boolean; refresh?: boolean };

/** Build a client from the resolved motherboard config + an absolute cache dir. */
export function createPcbPartsClient(
  opts: { url: string; timeoutMs: number; retries: number; cacheDir: string },
  logger: Logger,
  allowNetwork = false,
): PcbPartsClient {
  return new PcbPartsClient({ ...opts, logger, allowNetwork });
}

/** Deterministic JSON for cache keys (sorted object keys). */
function stableStringify(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  const obj = value as Record<string, unknown>;
  const keys = Object.keys(obj).sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${stableStringify(obj[k])}`).join(",")}}`;
}

/** Decode either a JSON body or an SSE body into a single JSON-RPC response. */
function parseRpcPayload(text: string): JsonRpcResponse {
  const trimmed = text.trim();
  if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
    return JSON.parse(trimmed) as JsonRpcResponse;
  }
  // Server-Sent Events: pick the last non-empty `data:` frame that parses.
  const dataLines = trimmed
    .split(/\r?\n/)
    .filter((l) => l.startsWith("data:"))
    .map((l) => l.slice(5).trim())
    .filter(Boolean);
  for (let i = dataLines.length - 1; i >= 0; i--) {
    try {
      return JSON.parse(dataLines[i]!) as JsonRpcResponse;
    } catch {
      /* try earlier frame */
    }
  }
  throw new Error("unparseable MCP response payload");
}

/**
 * MCP tool results wrap output in `content: [{type:'text', text:'...'}]` (and
 * often a `structuredContent`). Prefer structured content, else parse the first
 * text block as JSON, else return the raw text.
 */
function extractToolPayload<T>(result: unknown): T {
  const r = result as
    | { structuredContent?: unknown; content?: { type: string; text?: string }[] }
    | undefined;
  if (r?.structuredContent !== undefined) return r.structuredContent as T;
  const text = r?.content?.find((c) => c.type === "text")?.text;
  if (text === undefined) return result as T;
  try {
    return JSON.parse(text) as T;
  } catch {
    return text as unknown as T;
  }
}
