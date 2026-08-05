// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// shell.ts — Conditional shell selection and dispatch.
//
// The platform executes host commands through whichever shell is appropriate:
// PowerShell (pwsh/powershell) on Windows, zsh on macOS, bash on Linux. The
// LibreCore verification flow ships bash scripts (verif/regress/*.sh).
//
// Windows regress policy (G6LC_REGRESS_ENGINE / CVA6_REGRESS_ENGINE):
//   auto (default) — use WSL when available (GNU make, python3, coreutils, Spike ELF);
//                    otherwise Git-Bash with an enriched PATH (usr/bin prepended).
//   wsl            — force WSL
//   git-bash|bash  — force Git-Bash / resolved bash (never WSL)
//
// Why WSL is preferred for .sh suites: Bun childEnv injects a pure Windows PATH.
// Non-login Git-Bash then loses /usr/bin (dirname/sed/rm missing), and Chocolatey
// `make` is a Windows shim that cannot run the Unix Makefile. Suites that lack
// `set -e` previously exited 0 after those failures — a false PASS.

import { existsSync } from "node:fs";
import { dirname, join } from "node:path";

import type { HostOS, ShellKind } from "../config/schema.ts";
import { detectOS } from "./os.ts";
import { hasBinary, run, which, type CommandResult, type RunOptions } from "./exec.ts";

export interface ShellSpec {
  kind: ShellKind;
  bin: string;
  /** Build argv to run an inline script string. */
  commandArgs(script: string): string[];
  /** Build argv to run a script file with arguments. */
  fileArgs(file: string, args: string[]): string[];
}

const SHELLS: Record<ShellKind, ShellSpec> = {
  pwsh: {
    kind: "pwsh",
    bin: "pwsh",
    commandArgs: (s) => ["-NoProfile", "-NonInteractive", "-Command", s],
    fileArgs: (f, a) => ["-NoProfile", "-NonInteractive", "-File", f, ...a],
  },
  powershell: {
    kind: "powershell",
    bin: "powershell",
    commandArgs: (s) => ["-NoProfile", "-NonInteractive", "-Command", s],
    fileArgs: (f, a) => ["-NoProfile", "-NonInteractive", "-File", f, ...a],
  },
  cmd: {
    kind: "cmd",
    bin: "cmd",
    commandArgs: (s) => ["/d", "/s", "/c", s],
    fileArgs: (f, a) => ["/d", "/s", "/c", f, ...a],
  },
  bash: {
    kind: "bash",
    bin: "bash",
    commandArgs: (s) => ["-c", s],
    fileArgs: (f, a) => [f, ...a],
  },
  zsh: {
    kind: "zsh",
    bin: "zsh",
    commandArgs: (s) => ["-c", s],
    fileArgs: (f, a) => [f, ...a],
  },
  sh: {
    kind: "sh",
    bin: "sh",
    commandArgs: (s) => ["-c", s],
    fileArgs: (f, a) => [f, ...a],
  },
};

/** Fallback chain per OS when the preferred shell is unavailable. */
const FALLBACKS: Record<HostOS, ShellKind[]> = {
  windows: ["pwsh", "powershell", "cmd"],
  darwin: ["zsh", "bash", "sh"],
  linux: ["bash", "sh", "zsh"],
};

/**
 * Resolve the shell to use, honouring an optional override and falling back to
 * the first available shell for the OS. Throws if none can be found.
 */
export function resolveShell(
  os: HostOS = detectOS(),
  override?: ShellKind,
): ShellSpec {
  const candidates: ShellKind[] = [];
  if (override) candidates.push(override);
  candidates.push(...FALLBACKS[os]);

  for (const kind of candidates) {
    const spec = SHELLS[kind];
    if (hasBinary(spec.bin)) return spec;
  }
  // Last resort: return the OS default spec even if not found, so callers get a
  // meaningful "command not found" error rather than an undefined shell.
  return SHELLS[FALLBACKS[os][0] as ShellKind];
}

export interface ShellRunOptions extends RunOptions {
  /** Force a specific shell kind. */
  shell?: ShellKind;
  os?: HostOS;
}

/** Run an inline script string in the OS-appropriate shell. */
export function runScript(
  script: string,
  options: ShellRunOptions = {},
): Promise<CommandResult> {
  const spec = resolveShell(options.os ?? detectOS(), options.shell);
  return run(spec.bin, spec.commandArgs(script), options);
}

/** Run a script file (auto-selecting the shell) with arguments. */
export function runScriptFile(
  file: string,
  args: string[] = [],
  options: ShellRunOptions = {},
): Promise<CommandResult> {
  const spec = resolveShell(options.os ?? detectOS(), options.shell);
  return run(spec.bin, spec.fileArgs(file, args), options);
}

export type BashFlavor = "git-bash" | "cygwin" | "msys" | "unix" | "unknown";

export interface ResolvedBash {
  /** Absolute or PATH-resolvable bash binary. */
  bin: string;
  flavor: BashFlavor;
  /** True when a better Git-Bash candidate exists but was not chosen (should not happen). */
  cygwinPreferredOverGit: boolean;
  path: string | null;
}

/** Classify a bash path (exported for unit tests). */
export function classifyBashPath(p: string): BashFlavor {
  const n = p.replace(/\\/g, "/").toLowerCase();
  if (n.includes("/git/") || /\/git\/(bin|usr\/bin)\//.test(n)) {
    return "git-bash";
  }
  if (/\/git\/bin\/bash/.test(n) || /\/git\/usr\/bin\/bash/.test(n)) return "git-bash";
  if (n.includes("cygwin")) return "cygwin";
  if (n.includes("msys") || n.includes("mingw")) return "msys";
  if (process.platform !== "win32") return "unix";
  return "unknown";
}

/** Well-known Git for Windows bash locations (preferred over Cygwin on PATH). */
function windowsGitBashCandidates(): string[] {
  const pf = process.env["ProgramFiles"] ?? "C:\\Program Files";
  const pf86 = process.env["ProgramFiles(x86)"] ?? "C:\\Program Files (x86)";
  const local = process.env["LOCALAPPDATA"] ?? "";
  return [
    joinWin(pf, "Git", "bin", "bash.exe"),
    joinWin(pf, "Git", "usr", "bin", "bash.exe"),
    joinWin(pf86, "Git", "bin", "bash.exe"),
    local ? joinWin(local, "Programs", "Git", "bin", "bash.exe") : "",
  ].filter(Boolean);
}

function joinWin(...parts: string[]): string {
  return parts.join("\\");
}

/**
 * Convert `C:\\foo\\bar` / `C:/foo/bar` to POSIX for MSYS (`/c/foo/bar`) or
 * WSL (`/mnt/c/foo/bar`). Non-Windows paths are returned with backslashes fixed.
 */
export function windowsPathToPosix(winPath: string, style: "msys" | "wsl" = "msys"): string {
  // Normalise slashes and collapse duplicates (E:\\cva6 / E://cva6 → E:/cva6).
  const n = winPath.replace(/\\/g, "/").replace(/\/+/g, "/");
  const m = n.match(/^([A-Za-z]):\/(.*)$/);
  if (!m?.[1]) return n;
  const drive = m[1].toLowerCase();
  const rest = (m[2] ?? "").replace(/^\/+/, "");
  const out = style === "wsl" ? `/mnt/${drive}/${rest}` : `/${drive}/${rest}`;
  return out.replace(/\/+/g, "/");
}

/** Git install root from a bash.exe path, or null. */
export function gitRootFromBashPath(bashPath: string): string | null {
  const n = bashPath.replace(/\//g, "\\");
  // ...\Git\bin\bash.exe  or  ...\Git\usr\bin\bash.exe
  const m = n.match(/^(.*)\\Git\\(?:usr\\)?bin\\bash\.exe$/i);
  if (m?.[1]) return join(m[1], "Git");
  // Fallback: walk up looking for usr\bin\dirname.exe
  let cur = dirname(bashPath);
  for (let i = 0; i < 4; i++) {
    if (existsSync(join(cur, "usr", "bin", "dirname.exe")) || existsSync(join(cur, "usr", "bin", "dirname"))) {
      return cur;
    }
    const parent = dirname(cur);
    if (parent === cur) break;
    cur = parent;
  }
  return null;
}

/**
 * Prepend Git usr/bin (+ bin, mingw64/bin) so non-login Git-Bash still finds
 * dirname/sed/rm when the parent (Bun) injected a pure Windows PATH.
 * Also rewrites key monorepo path env vars to MSYS form.
 */
export function enrichGitBashEnv(
  env: Record<string, string | undefined> | undefined,
  bash: ResolvedBash,
): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (v !== undefined) out[k] = v;
  }
  if (env) {
    for (const [k, v] of Object.entries(env)) {
      if (v !== undefined) out[k] = v;
    }
  }

  if (process.platform !== "win32") return out;
  if (bash.flavor !== "git-bash" && bash.flavor !== "msys") return out;

  const root = gitRootFromBashPath(bash.path ?? bash.bin);
  if (root) {
    const extras = [
      join(root, "usr", "bin"),
      join(root, "bin"),
      join(root, "mingw64", "bin"),
    ].filter((p) => existsSync(p));
    if (extras.length) {
      const cur = out.PATH ?? out.Path ?? "";
      // Filter known-broken Windows make shims when a later GNU make may exist under Git
      // (Git usually has no make — still prepend usr/bin for coreutils).
      const filtered = cur
        .split(";")
        .filter((p) => !/chocolatey\\bin$/i.test(p.replace(/\//g, "\\")))
        .join(";");
      out.PATH = [...extras, filtered].filter(Boolean).join(";");
      out.Path = out.PATH;
    }
  }

  for (const key of [
    "CVA6_REPO_DIR",
    "RISCV",
    "VERILATOR_INSTALL_DIR",
    "VERILATOR_ROOT",
    "VERILATOR_BUILD_DIR",
    "SPIKE_INSTALL_DIR",
    "SPIKE_SRC_DIR",
  ]) {
    const v = out[key];
    if (v && /^[A-Za-z]:[\\/]/.test(v)) {
      out[key] = windowsPathToPosix(v, "msys");
    }
  }
  return out;
}

/**
 * Resolve bash for LibreCore regress scripts.
 * On Windows: prefer Git for Windows bash over Cygwin when both exist
 * (Cygwin bash breaks many riscv-gcc / spike / path mixes — AGENTS-todo).
 */
export function resolveBashBinary(): ResolvedBash | null {
  if (process.platform !== "win32") {
    const p = which("bash");
    if (!p && !hasBinary("bash")) return null;
    return {
      bin: p ?? "bash",
      flavor: "unix",
      cygwinPreferredOverGit: false,
      path: p,
    };
  }

  // 1) Prefer known Git-Bash install paths even if Cygwin is first on PATH
  for (const cand of windowsGitBashCandidates()) {
    if (existsSync(cand)) {
      return {
        bin: cand,
        flavor: "git-bash",
        cygwinPreferredOverGit: false,
        path: cand,
      };
    }
  }

  // 2) which("bash") — classify; if cygwin, still use it but flag
  const onPath = which("bash");
  if (onPath) {
    const flavor = classifyBashPath(onPath);
    return {
      bin: onPath,
      flavor,
      cygwinPreferredOverGit: flavor === "cygwin",
      path: onPath,
    };
  }
  if (hasBinary("bash")) {
    return {
      bin: "bash",
      flavor: "unknown",
      cygwinPreferredOverGit: false,
      path: null,
    };
  }
  return null;
}

/** Regress engine selection for Windows .sh suites. */
export function resolveRegressEngine(): "wsl" | "bash" {
  if (process.platform !== "win32") return "bash";
  const raw = (
    process.env.G6LC_REGRESS_ENGINE ??
    process.env.CVA6_REGRESS_ENGINE ??
    "auto"
  ).toLowerCase();
  if (raw === "wsl") return hasBinary("wsl") ? "wsl" : "bash";
  if (raw === "git-bash" || raw === "bash" || raw === "msys") return "bash";
  // auto
  return hasBinary("wsl") ? "wsl" : "bash";
}

/**
 * Run a bash script regardless of host OS. On Windows Git-Bash, PATH is
 * enriched so coreutils remain visible under a Bun-injected Windows PATH.
 */
export function runBashScript(
  file: string,
  args: string[] = [],
  options: RunOptions = {},
): Promise<CommandResult> {
  const bash = resolveBashBinary();
  if (!bash) {
    throw new Error(
      "bash was not found on PATH. The verification scripts require bash " +
        "(install Git for Windows or enable WSL, then re-run).",
    );
  }
  const env = enrichGitBashEnv(options.env, bash);
  return run(bash.bin, [file, ...args], { ...options, env });
}

/**
 * Failure patterns that mean a suite must not report PASS even if the process
 * exit code was 0 (legacy smoke scripts without `set -e`).
 */
export function detectFalsePassSignals(stdout: string, stderr: string): string | null {
  const text = `${stdout}\n${stderr}`;
  const patterns: [RegExp, string][] = [
    [/command not found/i, "unix utility missing (command not found)"],
    [/is not recognized as an internal or external command/i, "Windows cmd invoked instead of Unix tools"],
    [/CreateProcess\(NULL,\s*rm\s/i, "Windows make cannot run Unix recipe (rm)"],
    [/Python was not found/i, "python3 missing / Windows Store stub"],
    [/make:\s*\*\*\*.*Error/i, "make reported Error"],
    [/Makefile:\d+:.*Error/i, "Makefile Error"],
    [/Error: RISCV variable undefined/i, "RISCV unset"],
    [/\*\*\* Variable SPIKE_SRC_DIR must point/i, "SPIKE_SRC_DIR invalid"],
  ];
  for (const [re, label] of patterns) {
    if (re.test(text)) return label;
  }
  return null;
}

/** Run verif/regress under WSL with a clean Unix PATH and path conversion. */
async function runRegressUnderWsl(
  file: string,
  args: string[] = [],
  options: RunOptions = {},
): Promise<CommandResult> {
  const cwd = options.cwd ?? process.cwd();
  const cwdWsl = windowsPathToPosix(cwd, "wsl");
  const absFile = /^(?:[A-Za-z]:[\\/]|\\\\|\/)/.test(file)
    ? file
    : join(cwd, file);
  const scriptWsl = windowsPathToPosix(absFile, "wsl");

  const e = options.env ?? {};
  const repoWsl = e.CVA6_REPO_DIR
    ? windowsPathToPosix(e.CVA6_REPO_DIR, "wsl")
    : cwdWsl;
  const spikeWsl = e.SPIKE_INSTALL_DIR
    ? windowsPathToPosix(e.SPIKE_INSTALL_DIR, "wsl")
    : "";
  const riscvWin = e.RISCV ? windowsPathToPosix(e.RISCV, "wsl") : "";

  const argStr = args.map((a) => JSON.stringify(a)).join(" ");
  // Prefer WSL-native gcc/verilator/make/python; keep managed Spike (Linux ELF).
  // Use real newlines — joining with ';' produces invalid `then; cmd` syntax.
  // Note: WSL inherits the caller's env and often the distro profile (e.g.
  // RISCV=/opt/xpack/..., CV_SW_PREFIX=riscv-none-elf-). Never force RISCV=/usr
  // while leaving CV_SW_PREFIX=riscv-none-elf- — setup-env then looks for
  // /usr/bin/riscv-none-elf-gcc and fails. Clear prefix tools and re-resolve.
  const shellCmd = `
set -eo pipefail
cd ${JSON.stringify(cwdWsl)}
export CVA6_REPO_DIR=${JSON.stringify(repoWsl)}
${spikeWsl ? `export SPIKE_INSTALL_DIR=${JSON.stringify(spikeWsl)}` : "true"}

# Drop Windows-injected / stale cross-prefix so setup-env.sh re-detects.
unset CV_SW_PREFIX RISCV_CC RISCV_GCC RISCV_OBJCOPY CROSS_COMPILE || true

_riscv_ok() {
  # True when \$1/bin has a runnable *gcc (executes under Linux; rejects PE via --version fail).
  local root="\$1"
  [ -n "\$root" ] || return 1
  local g
  for g in "\$root/bin/riscv-none-elf-gcc" "\$root/bin/riscv64-unknown-elf-gcc" "\$root/bin/riscv32-unknown-elf-gcc"; do
    if [ -x "\$g" ] && "\$g" --version >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

# Resolve RISCV (prefer working native WSL toolchains over Windows PE under /mnt).
if _riscv_ok "\${RISCV:-}"; then
  : # keep profile / caller RISCV (e.g. /opt/xpack/xpack-riscv-none-elf-gcc-*)
elif command -v riscv-none-elf-gcc >/dev/null 2>&1; then
  export RISCV="\$(cd "\$(dirname "\$(command -v riscv-none-elf-gcc)")/.." && pwd)"
elif command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then
  export RISCV="\$(cd "\$(dirname "\$(command -v riscv64-unknown-elf-gcc)")/.." && pwd)"
elif command -v riscv32-unknown-elf-gcc >/dev/null 2>&1; then
  export RISCV="\$(cd "\$(dirname "\$(command -v riscv32-unknown-elf-gcc)")/.." && pwd)"
${
  riscvWin
    ? `elif _riscv_ok ${JSON.stringify(riscvWin)}; then
  export RISCV=${JSON.stringify(riscvWin)}`
    : ""
}
else
  echo "ERROR: no usable RISC-V GCC under WSL (install xpack riscv-none-elf-gcc or apt gcc-riscv64-unknown-elf)" >&2
  exit 127
fi

# Prefer project-pinned Verilator 5.008 over distro 5.0xx (Debian 5.020 has
# hit internal faults on this design). Order: home install, managed workspace,
# then PATH.
if [ -x "\$HOME/tools/verilator-v5.008/bin/verilator" ]; then
  export VERILATOR_INSTALL_DIR="\$HOME/tools/verilator-v5.008"
  export PATH="\$VERILATOR_INSTALL_DIR/bin:\$PATH"
elif [ -x "${repoWsl}/build-platform/workspace/tooling/verilator-v5.008/bin/verilator" ]; then
  export VERILATOR_INSTALL_DIR="${repoWsl}/build-platform/workspace/tooling/verilator-v5.008"
  export PATH="\$VERILATOR_INSTALL_DIR/bin:\$PATH"
elif command -v verilator >/dev/null 2>&1; then
  _vl_bin="\$(command -v verilator)"
  export VERILATOR_INSTALL_DIR="\$(cd "\$(dirname "\$_vl_bin")/.." && pwd)"
  unset _vl_bin
fi
if command -v verilator >/dev/null 2>&1; then
  export VERILATOR_ROOT="\$(verilator -getenv VERILATOR_ROOT 2>/dev/null || echo "\${VERILATOR_INSTALL_DIR}/share/verilator")"
fi

export PATH="\$RISCV/bin:\${VERILATOR_INSTALL_DIR:+\$VERILATOR_INSTALL_DIR/bin:}/usr/local/bin:/usr/bin:/bin\${SPIKE_INSTALL_DIR:+:\$SPIKE_INSTALL_DIR/bin}"
${e.DV_SIMULATORS ? `export DV_SIMULATORS=${JSON.stringify(e.DV_SIMULATORS)}` : "true"}
${e.DV_TARGET ? `export DV_TARGET=${JSON.stringify(e.DV_TARGET)}` : "true"}
${e.UVM_VERBOSITY ? `export UVM_VERBOSITY=${JSON.stringify(e.UVM_VERBOSITY)}` : 'export UVM_VERBOSITY=UVM_NONE'}
${e.NUM_JOBS ? `export NUM_JOBS=${JSON.stringify(e.NUM_JOBS)}` : "true"}
# Managed workspace Spike often reports bare "1.1.1-dev"; do not fail on monorepo git walk.
export CVA6_SPIKE_VERSION_RELAXED="\${CVA6_SPIKE_VERSION_RELAXED:-1}"
export G6LC_SPIKE_VERSION_RELAXED="\${G6LC_SPIKE_VERSION_RELAXED:-1}"

command -v dirname >/dev/null
command -v make >/dev/null
command -v python3 >/dev/null
make --version 2>/dev/null | head -1 | grep -qi "GNU Make" || {
  echo "ERROR: need GNU Make under WSL" >&2
  exit 127
}
# Prove the cross compiler actually runs (catches prefix/RISCV mismatch early).
if ! "\$RISCV/bin/"*gcc --version >/dev/null 2>&1; then
  # Fall back to PATH resolution after prefix auto-detect in the suite.
  if ! command -v riscv-none-elf-gcc >/dev/null 2>&1 && ! command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then
    echo "ERROR: RISCV=\$RISCV has no working gcc" >&2
    ls -la "\$RISCV/bin" 2>/dev/null | head -20 >&2 || true
    exit 127
  fi
fi
echo "[regress] engine=wsl repo=\$CVA6_REPO_DIR script=${scriptWsl} RISCV=\$RISCV VERILATOR_INSTALL_DIR=\${VERILATOR_INSTALL_DIR:-} \$(verilator --version 2>/dev/null | head -1)"
bash ${JSON.stringify(scriptWsl)} ${argStr}
`.trim();

  return run("wsl", ["-e", "bash", "-lc", shellCmd], {
    cwd: options.cwd,
    logger: options.logger,
    allowFailure: options.allowFailure,
    stdio: options.stdio ?? "both",
    dryRun: options.dryRun,
    // Do not forward the Bun Windows PATH into WSL — the -lc script sets PATH.
    env: {
      // Keep a minimal Windows env for wsl.exe itself.
      SystemRoot: process.env.SystemRoot,
      WINDIR: process.env.WINDIR,
      PATH: process.env.PATH,
    },
  });
}

/**
 * Run a verif/regress script.
 * - `.ps1` → pwsh/powershell
 * - `.sh` on Windows → WSL (auto) or Git-Bash with enriched PATH
 * - `.sh` elsewhere → resolved bash
 */
export async function runRegressScript(
  file: string,
  args: string[] = [],
  options: RunOptions = {},
): Promise<CommandResult> {
  const isPs1 = /\.ps1$/i.test(file);
  if (isPs1) {
    if (hasBinary("pwsh")) {
      return run("pwsh", ["-NoProfile", "-NonInteractive", "-File", file, ...args], options);
    }
    if (hasBinary("powershell")) {
      return run("powershell", ["-NoProfile", "-NonInteractive", "-File", file, ...args], options);
    }
    throw new Error(`PowerShell not found to run ${file}`);
  }

  if (resolveRegressEngine() === "wsl") {
    return runRegressUnderWsl(file, args, options);
  }

  const bash = resolveBashBinary();
  if (bash) {
    const env = enrichGitBashEnv(options.env, bash);
    return run(bash.bin, [file, ...args], { ...options, env });
  }
  // No bash: try sibling .ps1
  const ps1 = file.replace(/\.sh$/i, ".ps1");
  if (ps1 !== file) {
    if (hasBinary("pwsh")) {
      return run("pwsh", ["-NoProfile", "-NonInteractive", "-File", ps1, ...args], options);
    }
    if (hasBinary("powershell")) {
      return run("powershell", ["-NoProfile", "-NonInteractive", "-File", ps1, ...args], options);
    }
  }
  throw new Error(
    `Cannot run ${file}: need WSL or bash (Git-Bash preferred over Cygwin on Windows) or a sibling .ps1 with PowerShell.`,
  );
}

/** Absolute path of the resolved shell binary, or null if unavailable. */
export function resolvedShellPath(
  os: HostOS = detectOS(),
  override?: ShellKind,
): string | null {
  return which(resolveShell(os, override).bin);
}
