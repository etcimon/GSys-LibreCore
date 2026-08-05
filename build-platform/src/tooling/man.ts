// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// man.ts — Human-facing "manual" Q&A over the repo via Grok headless sessions.
//
// Each man id maps to a persistent Grok session (UUID). Follow-up `man <id>`
// calls resume that session so answers build on prior turns. Answers are written
// to workspace/man/<id>/answer.html and opened in a browser for human readers.
//
// Invokes the local `grok` CLI (Grok Build), model `grok-build` by default:
//   new:    grok -p … -s <uuid> -m grok-build --output-format json …
//   resume: grok -r <uuid> -p … --output-format json …

import { randomBytes, randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join, relative, resolve } from "node:path";

import type { PlatformContext } from "../context.ts";
import { hasBinary, run, which } from "../platform/exec.ts";

export interface ManSessionMeta {
  id: string;
  /** Grok session UUID (for -s / -r). */
  grokSessionId: string;
  createdAt: string;
  updatedAt: string;
  title: string;
  lastQuery: string;
  files: string[];
  turnCount: number;
}

export interface ManIndex {
  sessions: Record<string, ManSessionMeta>;
}

export interface ManAskOptions {
  /** Existing man id, or omit to allocate man-<random>. */
  id?: string;
  /** Repo-relative or absolute files to ground the answer. */
  files?: string[];
  /** Human question (required unless stdin provides it). */
  query: string;
  /** Model id (default grok-build). */
  model?: string;
  /** Max agent turns (default 12). */
  maxTurns?: number;
  /** Dry-run: do not call grok. */
  dryRun?: boolean;
}

export interface ManAskResult {
  id: string;
  grokSessionId: string;
  query: string;
  answerText: string;
  answerHtmlPath: string;
  answerMdPath: string;
  isNew: boolean;
  browserOpened: boolean;
  meta: ManSessionMeta;
}

function manRoot(ctx: PlatformContext): string {
  return join(ctx.paths.root, "man");
}

function sessionDir(ctx: PlatformContext, id: string): string {
  return join(manRoot(ctx), id);
}

function indexPath(ctx: PlatformContext): string {
  return join(manRoot(ctx), "index.json");
}

export function loadManIndex(ctx: PlatformContext): ManIndex {
  const p = indexPath(ctx);
  if (!existsSync(p)) return { sessions: {} };
  try {
    return JSON.parse(readFileSync(p, "utf8")) as ManIndex;
  } catch {
    return { sessions: {} };
  }
}

function saveManIndex(ctx: PlatformContext, index: ManIndex): void {
  mkdirSync(manRoot(ctx), { recursive: true });
  writeFileSync(indexPath(ctx), JSON.stringify(index, null, 2) + "\n", "utf8");
}

/** Allocate a short human-friendly man id (not a Grok UUID). */
export function generateManId(): string {
  return `man-${randomBytes(4).toString("hex")}`;
}

/** True if token looks like a man session id (not a path / free text). */
export function looksLikeManId(token: string): boolean {
  if (/^man-[0-9a-f]{6,}$/i.test(token)) return true;
  // bare 8+ hex slug
  if (/^[0-9a-f]{8,16}$/i.test(token)) return true;
  // full UUID (rare as man id, but allow)
  if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(token)) {
    return true;
  }
  return false;
}

export function resolveGrokBinary(): string | null {
  if (hasBinary("grok")) return which("grok");
  if (hasBinary("grok.exe")) return which("grok.exe");
  const candidates = [
    join(homedir(), ".grok", "bin", "grok.exe"),
    join(homedir(), ".grok", "bin", "grok"),
    join(homedir(), ".local", "bin", "grok"),
  ];
  for (const c of candidates) {
    if (existsSync(c)) return c;
  }
  return null;
}

function normalizeFiles(repoRoot: string, files: string[]): string[] {
  const out: string[] = [];
  for (const f of files) {
    const abs = isAbsolute(f) ? f : resolve(repoRoot, f);
    if (!existsSync(abs)) continue;
    const rel = relative(repoRoot, abs).replaceAll("\\", "/");
    out.push(rel.startsWith("..") ? abs.replaceAll("\\", "/") : rel);
  }
  return [...new Set(out)];
}

function manSystemRules(): string {
  return [
    "You are writing a man-page style answer for a HUMAN engineer reading in a browser.",
    "Audience: human readers only (not CI agents). Prefer clear prose, sections, and examples.",
    "Structure: Title; Synopsis; Description; Options/Key concepts; Examples; Files; See also.",
    "Ground claims in the listed source files when provided; quote paths as `path/to/file`.",
    "Do not invent CLI flags or install steps; if unsure, say so and point at probe/tools docs.",
    "Prefer the LibreCore build-platform loop: probe → tools install → diag → verify.",
    "Keep answers self-contained enough to read offline as a temporary HTML man page.",
    "Use Markdown: ## headings, fenced code blocks with language tags, bullet lists.",
  ].join(" ");
}

function buildPrompt(opts: {
  query: string;
  files: string[];
  isNew: boolean;
  priorTitle?: string;
}): string {
  const parts: string[] = [];
  parts.push(manSystemRules());
  parts.push("");
  if (opts.isNew) {
    parts.push("This is a new man-page session. Answer the question as a standalone manual page.");
  } else {
    parts.push(
      "Continue the existing man-page session. Build on prior answers; refine or extend without discarding useful context.",
    );
    if (opts.priorTitle) parts.push(`Prior topic: ${opts.priorTitle}`);
  }
  if (opts.files.length) {
    parts.push("");
    parts.push("Ground the answer in these repository files (read them with tools before answering):");
    for (const f of opts.files) parts.push(`- ${f}`);
  }
  parts.push("");
  parts.push("QUESTION:");
  parts.push(opts.query);
  return parts.join("\n");
}

/** Minimal Markdown → HTML for browser display. */
export function markdownToHtml(md: string, meta: { id: string; query: string; title: string }): string {
  const escape = (s: string) =>
    s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

  let html = "";
  const lines = md.replace(/\r\n/g, "\n").split("\n");
  let inCode = false;
  let codeLang = "";
  let codeBuf: string[] = [];
  let para: string[] = [];

  const flushPara = () => {
    if (!para.length) return;
    const text = para.join(" ");
    para = [];
    // inline code
    const withCode = text.replace(/`([^`]+)`/g, "<code>$1</code>");
    html += `<p>${withCode}</p>\n`;
  };

  for (const line of lines) {
    const fence = line.match(/^```(\w*)\s*$/);
    if (fence) {
      flushPara();
      if (!inCode) {
        inCode = true;
        codeLang = fence[1] || "";
        codeBuf = [];
      } else {
        html += `<pre class="code" data-lang="${escape(codeLang)}"><code>${escape(codeBuf.join("\n"))}</code></pre>\n`;
        inCode = false;
        codeLang = "";
        codeBuf = [];
      }
      continue;
    }
    if (inCode) {
      codeBuf.push(line);
      continue;
    }
    if (/^#{1,3}\s+/.test(line)) {
      flushPara();
      const hashes = line.match(/^(#+)/)?.[1];
      const level = hashes?.length ?? 1;
      const text = line.replace(/^#+\s+/, "");
      html += `<h${level}>${escape(text)}</h${level}>\n`;
      continue;
    }
    if (/^[-*]\s+/.test(line)) {
      flushPara();
      if (!html.endsWith("</ul>\n")) html += "<ul>\n";
      html += `<li>${escape(line.replace(/^[-*]\s+/, ""))}</li>\n`;
      // close list loosely on blank later
      continue;
    }
    if (line.trim() === "") {
      if (html.endsWith("</li>\n")) html += "</ul>\n";
      flushPara();
      continue;
    }
    if (html.endsWith("</li>\n") && !/^[-*]\s+/.test(line)) html += "</ul>\n";
    para.push(escape(line));
  }
  if (inCode) {
    html += `<pre class="code"><code>${escape(codeBuf.join("\n"))}</code></pre>\n`;
  }
  if (html.endsWith("</li>\n")) html += "</ul>\n";
  flushPara();

  const q = escape(meta.query);
  const title = escape(meta.title || meta.query.slice(0, 80));
  const id = escape(meta.id);

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>man ${id} — ${title}</title>
  <style>
    :root {
      --bg: #0f1419;
      --fg: #e7ecf3;
      --muted: #8b9bb4;
      --accent: #6cb6ff;
      --code-bg: #1a2332;
      --border: #2a3548;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "Segoe UI", system-ui, -apple-system, sans-serif;
      background: var(--bg);
      color: var(--fg);
      line-height: 1.55;
    }
    header {
      border-bottom: 1px solid var(--border);
      padding: 1rem 1.5rem;
      background: #121a24;
      position: sticky;
      top: 0;
    }
    header .id { color: var(--accent); font-family: ui-monospace, Consolas, monospace; }
    header .query { color: var(--muted); font-size: 0.95rem; margin-top: 0.35rem; }
    main {
      max-width: 52rem;
      margin: 0 auto;
      padding: 1.5rem;
    }
    h1, h2, h3 { color: #fff; line-height: 1.25; }
    h1 { font-size: 1.6rem; }
    h2 { font-size: 1.25rem; margin-top: 1.75rem; border-bottom: 1px solid var(--border); padding-bottom: 0.25rem; }
    a { color: var(--accent); }
    code {
      font-family: ui-monospace, "Cascadia Code", Consolas, monospace;
      font-size: 0.9em;
      background: var(--code-bg);
      padding: 0.1em 0.35em;
      border-radius: 4px;
    }
    pre.code {
      background: var(--code-bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 0.9rem 1rem;
      overflow-x: auto;
    }
    pre.code code { background: none; padding: 0; }
    ul { padding-left: 1.25rem; }
    footer {
      max-width: 52rem;
      margin: 2rem auto;
      padding: 0 1.5rem 2rem;
      color: var(--muted);
      font-size: 0.85rem;
    }
  </style>
</head>
<body>
  <header>
    <div class="id">g6lc-build man · ${id}</div>
    <div class="query">${q}</div>
  </header>
  <main>
${html}
  </main>
  <footer>
    Generated for human readers. Continue with:
    <code>g6lc-build man ${id} &lt;follow-up question&gt;</code>
  </footer>
</body>
</html>
`;
}

async function launchBrowser(urlOrPath: string, logger: PlatformContext["logger"]): Promise<boolean> {
  const fileUrl = urlOrPath.startsWith("file:")
    ? urlOrPath
    : "file:///" + urlOrPath.replaceAll("\\", "/");

  try {
    if (process.platform === "win32") {
      await run("cmd", ["/c", "start", "", fileUrl], {
        allowFailure: true,
        stdio: "capture",
        logger,
      });
      return true;
    }
    if (process.platform === "darwin") {
      await run("open", [urlOrPath], { allowFailure: true, stdio: "capture", logger });
      return true;
    }
    await run("xdg-open", [urlOrPath], { allowFailure: true, stdio: "capture", logger });
    return true;
  } catch {
    return false;
  }
}

/** Whether this process should open a browser (human interactive reader). */
export function shouldOpenBrowserForHuman(force?: boolean): boolean {
  if (force) return true;
  if (process.env.CI === "true" || process.env.CI === "1") return false;
  if (process.env.CVA6_MAN_NO_BROWSER === "1") return false;
  // Agents / non-TTY: still write HTML, skip auto-open unless forced
  if (!process.stdout.isTTY) return false;
  return true;
}

interface GrokJsonResult {
  text?: string;
  sessionId?: string;
  stopReason?: string;
  type?: string;
  message?: string;
}

async function invokeGrok(opts: {
  grokBin: string;
  prompt: string;
  cwd: string;
  model: string;
  maxTurns: number;
  /** New session UUID, or null to resume. */
  newSessionId: string | null;
  resumeSessionId: string | null;
  dryRun?: boolean;
  logger: PlatformContext["logger"];
}): Promise<{ text: string; sessionId: string | null; raw: string }> {
  const args: string[] = [
    "-p",
    opts.prompt,
    "-m",
    opts.model,
    "--output-format",
    "json",
    "--cwd",
    opts.cwd,
    "--max-turns",
    String(opts.maxTurns),
    // Read-only man page research; no shell/edit (human docs, not agentic edits).
    "--tools",
    "read_file,grep,list_dir,web_search,web_fetch,open_page",
    "--disallowed-tools",
    "run_terminal_cmd,search_replace,write,Agent,image_gen",
    "--permission-mode",
    "bypassPermissions",
    "--verbatim",
  ];

  if (opts.resumeSessionId) {
    args.push("-r", opts.resumeSessionId);
  } else if (opts.newSessionId) {
    args.push("-s", opts.newSessionId);
  }

  if (opts.dryRun) {
    opts.logger.info(`[dry-run] ${opts.grokBin} ${args.map((a) => (a.length > 40 ? a.slice(0, 40) + "…" : a)).join(" ")}`);
    return {
      text: "(dry-run) Man page would be generated by Grok headless here.",
      sessionId: opts.newSessionId ?? opts.resumeSessionId,
      raw: "",
    };
  }

  const res = await run(opts.grokBin, args, {
    cwd: opts.cwd,
    allowFailure: true,
    stdio: "capture",
    logger: opts.logger,
  });

  const raw = (res.stdout || res.stderr || "").trim();
  let text = raw;
  let sessionId: string | null = opts.newSessionId ?? opts.resumeSessionId;

  // Prefer last JSON object in stdout
  try {
    const start = raw.lastIndexOf("{");
    if (start >= 0) {
      const parsed = JSON.parse(raw.slice(start)) as GrokJsonResult;
      if (parsed.text) text = parsed.text;
      if (parsed.sessionId) sessionId = parsed.sessionId;
      if (parsed.type === "error") {
        throw new Error(parsed.message ?? "grok error");
      }
    }
  } catch (e) {
    if (e instanceof Error && e.message !== "grok error" && !res.ok) {
      // keep plain text
    } else if (e instanceof Error && e.message === "grok error") {
      throw e;
    }
  }

  if (!res.ok && !text) {
    throw new Error(`grok exited ${res.code}: ${raw.slice(0, 500)}`);
  }

  return { text, sessionId, raw };
}

/**
 * Ask / continue a man-page session. Returns paths to formatted artifacts.
 */
export async function manAsk(
  ctx: PlatformContext,
  options: ManAskOptions,
  openBrowser: boolean,
): Promise<ManAskResult> {
  const grokBin = resolveGrokBinary();
  if (!grokBin && !options.dryRun) {
    throw new Error(
      "grok CLI not found (expected ~/.grok/bin/grok or PATH). Install Grok Build and re-run.",
    );
  }

  const query = options.query.trim();
  if (!query) throw new Error("man requires a query (positional text, --query, or stdin)");

  const files = normalizeFiles(ctx.repoRoot, options.files ?? []);
  const index = loadManIndex(ctx);

  let id = options.id?.trim() || "";
  let isNew = false;
  let meta: ManSessionMeta | undefined = id ? index.sessions[id] : undefined;

  if (!id) {
    id = generateManId();
    isNew = true;
  } else if (!meta) {
    // User supplied id but no local mapping — start a new Grok session under that id
    isNew = true;
  }

  const dir = sessionDir(ctx, id);
  mkdirSync(dir, { recursive: true });

  const grokSessionId = isNew ? randomUUID() : meta!.grokSessionId;
  const now = new Date().toISOString();
  const title = query.length > 72 ? query.slice(0, 69) + "…" : query;

  const prompt = buildPrompt({
    query,
    files: files.length ? files : meta?.files ?? [],
    isNew,
    priorTitle: meta?.title,
  });

  const { text, sessionId } = await invokeGrok({
    grokBin: grokBin ?? "grok",
    prompt,
    cwd: ctx.repoRoot,
    model: options.model ?? "grok-build",
    maxTurns: options.maxTurns ?? 12,
    newSessionId: isNew ? grokSessionId : null,
    resumeSessionId: isNew ? null : meta!.grokSessionId,
    dryRun: options.dryRun,
    logger: ctx.logger,
  });

  const finalGrokId = sessionId ?? grokSessionId;
  const mergedFiles = [...new Set([...(meta?.files ?? []), ...files])];

  const next: ManSessionMeta = {
    id,
    grokSessionId: finalGrokId,
    createdAt: meta?.createdAt ?? now,
    updatedAt: now,
    title: isNew ? title : meta?.title ?? title,
    lastQuery: query,
    files: mergedFiles,
    turnCount: (meta?.turnCount ?? 0) + 1,
  };

  index.sessions[id] = next;
  saveManIndex(ctx, index);

  const mdPath = join(dir, "answer.md");
  const htmlPath = join(dir, "answer.html");
  const historyPath = join(dir, "history.jsonl");

  const mdBody = `# ${next.title}\n\n> man **${id}** · turn ${next.turnCount}\n\n${text}\n`;
  writeFileSync(mdPath, mdBody, "utf8");
  writeFileSync(
    htmlPath,
    markdownToHtml(text, { id, query, title: next.title }),
    "utf8",
  );
  writeFileSync(join(dir, "meta.json"), JSON.stringify(next, null, 2) + "\n", "utf8");
  writeFileSync(
    historyPath,
    (existsSync(historyPath) ? readFileSync(historyPath, "utf8") : "") +
      JSON.stringify({ at: now, query, files, answerChars: text.length }) +
      "\n",
    "utf8",
  );

  let browserOpened = false;
  if (openBrowser && shouldOpenBrowserForHuman()) {
    browserOpened = await launchBrowser(htmlPath, ctx.logger);
  }

  return {
    id,
    grokSessionId: finalGrokId,
    query,
    answerText: text,
    answerHtmlPath: htmlPath,
    answerMdPath: mdPath,
    isNew,
    browserOpened,
    meta: next,
  };
}

export function listManSessions(ctx: PlatformContext): ManSessionMeta[] {
  const index = loadManIndex(ctx);
  return Object.values(index.sessions).sort((a, b) =>
    a.updatedAt < b.updatedAt ? 1 : -1,
  );
}

/**
 * Parse man CLI positionals into id / files / query.
 * Convention: optional id (man-* or hex), then existing file paths, then query words.
 * Use `--` in argv flags handling: anything after bare `--` is query-only (caller splits).
 */
export function parseManPositionals(
  positionals: string[],
  repoRoot: string,
  opts: { explicitId?: string; explicitQuery?: string } = {},
): { id?: string; files: string[]; query: string } {
  let id = opts.explicitId;
  const files: string[] = [];
  const queryParts: string[] = [];

  if (opts.explicitQuery) {
    // Files only from positionals; optional id still first
    let i = 0;
    if (!id && positionals[0] && looksLikeManId(positionals[0])) {
      id = positionals[0];
      i = 1;
    }
    for (; i < positionals.length; i++) {
      const t = positionals[i]!;
      const abs = isAbsolute(t) ? t : resolve(repoRoot, t);
      if (existsSync(abs)) files.push(t);
      else queryParts.push(t);
    }
    return { id, files, query: opts.explicitQuery };
  }

  let i = 0;
  if (!id && positionals[0] && looksLikeManId(positionals[0]!)) {
    id = positionals[0];
    i = 1;
  }
  for (; i < positionals.length; i++) {
    const t = positionals[i]!;
    const abs = isAbsolute(t) ? t : resolve(repoRoot, t);
    if (existsSync(abs) && !queryParts.length) {
      files.push(t);
    } else {
      queryParts.push(t);
    }
  }
  return { id, files, query: queryParts.join(" ").trim() };
}
