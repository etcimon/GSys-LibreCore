// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// man.ts — Human-readable manual pages via Grok headless (model grok-build).
//
//   man [id?] [files...] <query…>
//   man --id <id> --file f1 --file f2 --query "…"
//   man --list
//   echo "query" | man [id?] [files...]
//
// Creates or resumes a Grok session bound to a short man-* id so follow-ups
// build on prior answers. Writes answer.html under workspace/man/<id>/ and
// opens it in a browser for human readers (skipped in CI / non-TTY unless
// --force).

import { requireContext, type Command } from "../command.ts";
import { flagBool, flagString } from "../args.ts";
import {
  listManSessions,
  manAsk,
  parseManPositionals,
  resolveGrokBinary,
  shouldOpenBrowserForHuman,
} from "../../tooling/man.ts";

async function readStdinIfPiped(): Promise<string> {
  if (process.stdin.isTTY) return "";
  try {
    const chunks: Buffer[] = [];
    for await (const chunk of process.stdin) {
      chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
    }
    return Buffer.concat(chunks).toString("utf8").trim();
  } catch {
    return "";
  }
}

export const manCommand: Command = {
  name: "man",
  summary:
    "Human man-page Q&A via Grok (grok-build): persistent id sessions, HTML answer in browser.",
  usage:
    "bun run src/cli/index.ts man [id?] [files...] [query…] [--id <id>] [--file <path>]… [--query <text>] [--list] [--no-open] [--print] [--force] [--dry-run]",
  details:
    "Ask a documentation question grounded in optional source files. Each man id\n" +
    "maps to a Grok headless session (model grok-build) so the next `man <id> …`\n" +
    "continues that conversation.\n" +
    "\n" +
    "  man <query>                         new session (random man-******** id)\n" +
    "  man man-a1b2c3d4 <follow-up>        resume session\n" +
    "  man man-… path/to/file.sv <query>   ground in files (must exist)\n" +
    "  man --list                          list local man sessions\n" +
    "  man --no-open …                     write HTML only (no browser)\n" +
    "  man --print …                       also print Markdown answer to stdout\n" +
    "  echo q | man [id] [files…]          query from stdin\n" +
    "\n" +
    "Invokes local `grok` CLI:\n" +
    "  new:    grok -p … -s <uuid> -m grok-build --output-format json\n" +
    "  resume: grok -r <uuid> -p …\n" +
    "Tools limited to read/search/fetch (no shell/edit). Answers land in\n" +
    "build-platform/workspace/man/<id>/answer.html for human readers.\n" +
    "\n" +
    "Related: probe, diag, tools install — do not invent install steps in answers.",
  examples: [
    'bun run src/cli/index.ts man "How does tools install dual-hart work?"',
    "bun run src/cli/index.ts man man-deadbeef build-platform/AGENTS.md follow-up on spike WSL",
    "bun run src/cli/index.ts man --file core/include/config_pkg.sv --query \"What is check_cfg?\"",
    "bun run src/cli/index.ts man --list",
  ],
  needsContext: true,
  async run(args) {
    const ctx = requireContext(args);
    const { logger } = ctx;

    if (flagBool(args.flags, "list")) {
      const sessions = listManSessions(ctx);
      if (!sessions.length) {
        logger.info("No man sessions yet. Try: man \"How do I run probe?\"");
        return 0;
      }
      logger.heading("Man sessions (workspace/man)");
      for (const s of sessions) {
        logger.info(
          `  ${s.id.padEnd(16)} turns=${s.turnCount}  ${s.updatedAt.slice(0, 19)}  ${s.title}`,
        );
      }
      logger.info("");
      logger.info("Resume: man <id> <follow-up question>");
      return 0;
    }

    const stdinQuery = await readStdinIfPiped();
    const explicitId = flagString(args.flags, "id");
    const explicitQuery = flagString(args.flags, "query") ?? flagString(args.flags, "q");
    const flagFiles: string[] = [];
    // Support repeated --file via flags.file as string (last wins) + positionals
    const oneFile = flagString(args.flags, "file");
    if (oneFile) flagFiles.push(oneFile);

    const parsed = parseManPositionals(args.positionals, ctx.repoRoot, {
      explicitId,
      explicitQuery: explicitQuery || undefined,
    });
    const files = [...flagFiles, ...parsed.files];
    const query = (parsed.query || stdinQuery || "").trim();

    if (!query) {
      logger.error("Usage: man [id?] [files...] <query>   or   man --list");
      logger.info('Example: man "How does diag run smt2 work?"');
      logger.info("Resume:  man man-<id> \"follow-up\"");
      return 1;
    }

    const id = parsed.id;
    const grok = resolveGrokBinary();
    if (!grok && !ctx.dryRun) {
      logger.error("grok CLI not found. Install Grok Build and ensure ~/.grok/bin is on PATH.");
      return 1;
    }

    // Human-reader policy: browser open is for interactive humans.
    const force = flagBool(args.flags, "force");
    const noOpen = flagBool(args.flags, "no-open");
    const wantBrowser = !noOpen && shouldOpenBrowserForHuman(force);

    if (!process.stdout.isTTY && !force && !noOpen) {
      logger.warn(
        "Non-interactive stdout: writing HTML only (pass --force to open browser, or --no-open to silence).",
      );
    }

    logger.heading(id ? `man ${id}` : "man (new session)");
    logger.info(`query: ${query.slice(0, 120)}${query.length > 120 ? "…" : ""}`);
    if (files.length) logger.info(`files: ${files.join(", ")}`);
    if (grok) logger.info(`grok:  ${grok}`);

    try {
      const result = await manAsk(
        ctx,
        {
          id,
          files,
          query,
          dryRun: ctx.dryRun || flagBool(args.flags, "dry-run"),
          model: flagString(args.flags, "model") ?? "grok-build",
        },
        wantBrowser,
      );

      logger.success(`id:     ${result.id}${result.isNew ? " (new)" : ` (turn ${result.meta.turnCount})`}`);
      logger.info(`grok:    session ${result.grokSessionId}`);
      logger.info(`html:    ${result.answerHtmlPath}`);
      logger.info(`md:      ${result.answerMdPath}`);
      if (result.browserOpened) logger.success("Opened answer in browser (human reader).");
      else if (!wantBrowser) logger.info("Browser not opened (--no-open, CI, or non-TTY).");
      else logger.warn("Browser open failed; open the html path manually.");

      logger.info("");
      logger.info(`Continue: bun run src/cli/index.ts man ${result.id} <follow-up>`);

      if (flagBool(args.flags, "print")) {
        logger.raw("\n" + result.answerText + "\n");
      }
      return 0;
    } catch (err) {
      logger.error(err instanceof Error ? err.message : String(err));
      return 1;
    }
  },
};
