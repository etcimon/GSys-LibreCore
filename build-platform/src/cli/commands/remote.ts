// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// remote.ts — Build-platform gateway to the remote testharness proxy.
//
// Delegates to verif/regress/remote/testharness_proxy.py (Python) so the
// build-platform gains remote harness execution without re-implementing
// SSH agent handling, rsync filters, or Verilator build plumbing.
//
// The first time a host is used, the user is prompted for the key passphrase
// (or password) and it is cached in build-platform/.remote-ssh-creds, which
// is gitignored. The cache is keyed by the ssh host alias from ~/.ssh/config.

import { existsSync, readFileSync as readFileSyncRaw } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

import { requireContext, type Command } from "../command.ts";
import { canPromptInteractive } from "../../util/prompt.ts";
import { runBashScript } from "../../platform/shell.ts";
import { flagString } from "../args.ts";

const DEFAULT_HOST = "ovh_calltorch";
const CACHE_FILE = ".remote-ssh-creds";
const CACHE_DIR = "build-platform";

interface CredEntry {
  host: string;
  passphrase?: string | null;
  identity?: string | null;
}

interface CredCache {
  default?: string;
  hosts: Record<string, CredEntry>;
}

async function readCache(repoRoot: string): Promise<CredCache> {
  const path = join(repoRoot, CACHE_DIR, CACHE_FILE);
  if (!existsSync(path)) return { hosts: {} };
  try {
    const text = await readFile(path, "utf-8");
    return JSON.parse(text) as CredCache;
  } catch {
    return { hosts: {} };
  }
}

async function writeCache(repoRoot: string, cache: CredCache): Promise<void> {
  const path = join(repoRoot, CACHE_DIR, CACHE_FILE);
  await writeFile(path, JSON.stringify(cache, null, 2) + "\n", { mode: 0o600 });
}

function readSshConfigHost(alias: string): { hostname?: string; user?: string; identityFile?: string } | null {
  const configPath = join(homedir(), ".ssh", "config");
  if (!existsSync(configPath)) return null;
  // Minimal parser: find the Host block for the alias and pull first HostName,
  // User, and IdentityFile values that appear inside it.
  try {
    const text = readFileSyncRaw(configPath, "utf-8");
    const lines = text.split("\n");
    let inBlock = false;
    const result: { hostname?: string; user?: string; identityFile?: string } = {};
    for (const raw of lines) {
      const line = raw.trim().replace(/\s+/g, " ");
      const match = line.match(/^Host\s+(.+)$/i);
      if (match) {
        const names = match[1]!.split(/\s+/);
        inBlock = names.includes(alias) || names.includes("*");
        continue;
      }
      if (inBlock) {
        if (!result.hostname) {
          const hm = line.match(/^HostName\s+(\S+)$/i);
          if (hm) result.hostname = hm[1];
        }
        if (!result.user) {
          const um = line.match(/^User\s+(\S+)$/i);
          if (um) result.user = um[1];
        }
        if (!result.identityFile) {
          const im = line.match(/^IdentityFile\s+(\S+)$/i);
          if (im) result.identityFile = im[1];
        }
      }
    }
    return Object.keys(result).length ? result : null;
  } catch {
    return null;
  }
}

function readFileSync(path: string): string {
  const fs = require("node:fs");
  return fs.readFileSync(path, "utf-8");
}

async function promptPassphrase(): Promise<string | null> {
  if (!canPromptInteractive()) return null;
  const readline = require("node:readline");
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  try {
    const answer: string = await new Promise((resolve) => {
      rl.question("SSH key passphrase (or password): ", (v: string) => resolve(v));
    });
    return answer.trim() || null;
  } finally {
    rl.close();
  }
}

function wrapperPath(repoRoot: string): string {
  return join(repoRoot, "verif", "regress", "remote-testharness.sh");
}

export const remoteCommand: Command = {
  name: "remote",
  summary: "Run the remote testharness proxy (SSH + rsync + Verilator).",
  usage:
    "bun run src/cli/index.ts remote [--remote-ssh <host>] <proxy-subcommand> [args...]",
  details:
    "Thin gateway to verif/regress/remote/testharness_proxy.py.\n" +
    "Subcommands: doctor, setup, sync, build <B|legacy>, run <elf>,\n" +
    "soak, pull, shell, clean [runs|work|all|everything].\n" +
    "Passphrase is cached in build-platform/.remote-ssh-creds (gitignored, 0600).",
  examples: [
    "bun run src/cli/index.ts remote --remote-ssh ovh_calltorch doctor",
    "bun run src/cli/index.ts remote setup",
    "bun run src/cli/index.ts remote build B",
    "bun run src/cli/index.ts remote --remote-ssh-pass pwrd128 build B",
    "bun run src/cli/index.ts remote soak --flavour B",
  ],
  needsContext: true,
  async run(args) {
    const ctx = requireContext(args);
    const repoRoot = ctx.repoRoot;

    let host = flagString(args.flags, "remote-ssh") || DEFAULT_HOST;
    const explicitPass = flagString(args.flags, "remote-ssh-pass");
    const explicitIdentity = flagString(args.flags, "remote-ssh-identity");

    const cache = await readCache(repoRoot);
    const entry = cache.hosts[host] || { host };

    if (explicitIdentity) {
      entry.identity = explicitIdentity;
    } else if (!entry.identity) {
      const sshConfig = readSshConfigHost(host);
      if (sshConfig?.identityFile) {
        entry.identity = sshConfig.identityFile;
      }
    }

    let passphrase: string | null | undefined = explicitPass ?? entry.passphrase;
    if (!passphrase) {
      passphrase = await promptPassphrase();
      if (passphrase) {
        entry.passphrase = passphrase;
        cache.hosts[host] = entry;
        if (!cache.default) cache.default = host;
        await writeCache(repoRoot, cache);
      }
    }

    if (!passphrase) {
      args.logger.warn(
        "No passphrase cached; provide --remote-ssh-pass or run interactively.",
      );
      args.logger.info(
        "Passphrase cache: build-platform/.remote-ssh-creds (create manually if non-interactive).",
      );
      return 1;
    }

    if (explicitPass && entry.passphrase !== explicitPass) {
      entry.passphrase = explicitPass;
      cache.hosts[host] = entry;
      await writeCache(repoRoot, cache);
    }

    const wrapper = wrapperPath(repoRoot);
    if (!existsSync(wrapper)) {
      args.logger.error(`Remote harness wrapper not found: ${wrapper}`);
      return 1;
    }

    const [subcommand, ...rest] = args.positionals;
    if (!subcommand) {
      args.logger.error("Missing remote subcommand.");
      return 1;
    }

    // Forward global verbose/debug flags to the proxy.
    const proxyArgs: string[] = [];
    if (args.flags.verbose) proxyArgs.push("-v");
    if (args.flags.debug || args.flags["log-level"] === "debug") proxyArgs.push("-d");
    proxyArgs.push("--host", host, subcommand, ...rest);

    const env: Record<string, string> = {
      TH_SSH_PASSPHRASE: passphrase,
    };
    if (entry.identity) {
      env.TH_SSH_IDENTITY = entry.identity;
    }

    // The proxy script must run under a Unix-like environment. On Windows the
    // build-platform's runBashScript will route through WSL or Git-Bash.
    args.logger.info(`remote: ${host} -> ${wrapper} ${proxyArgs.join(" ")}`);
    const result = await runBashScript(
      wrapper,
      proxyArgs,
      { env, cwd: repoRoot, stdio: "both" },
    );
    return result.code;
  },
};
