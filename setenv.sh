#!/usr/bin/env bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# setenv.sh — Make `g6lc-build` (and legacy `cva6-build`) available (SOURCE me).
#
#   source ./setenv.sh          # or:   . ./setenv.sh
#
# In order, it:
#   1. ensures Bun is installed and on PATH (persisted into THIS shell),
#   2. runs `bun install` in build-platform/ (dev deps: type stubs + tsc),
#   3. defines `g6lc-build` / `cva6-build` shell functions (wrappers over build.sh),
#   4. prints `g6lc-build status` (the current setup + parameters).
#
# Afterwards, drive the whole core -> uncore -> board -> foundry flow with one
# command, e.g.:
#   g6lc-build doctor | setup --install | test --open-source | mb list | tech status
#
# NOTE: this file is meant to be SOURCED, so it never uses `set -e`/`exit`
# (either would kill your interactive shell). Errors `return` instead.

# --- resolve this script's own directory (bash + zsh) ----------------------
if [ -n "${BASH_SOURCE:-}" ]; then
  _cva6_src="${BASH_SOURCE[0]}"
else
  # zsh sets $0 to the sourced file path; other shells fall back to $0 too.
  _cva6_src="$0"
fi

# --- require sourcing (a run script cannot export a function or PATH) -------
_cva6_sourced=0
if [ -n "${ZSH_VERSION:-}" ]; then
  case "${ZSH_EVAL_CONTEXT:-}" in *:file*) _cva6_sourced=1 ;; esac
elif [ -n "${BASH_VERSION:-}" ]; then
  # `return` only succeeds when the script is sourced.
  (return 0 2>/dev/null) && _cva6_sourced=1
fi
if [ "$_cva6_sourced" -ne 1 ]; then
  echo "[setenv.sh] Please SOURCE this script so 'g6lc-build' persists:" >&2
  echo "            source ./setenv.sh      # or:   . ./setenv.sh" >&2
  exit 1
fi

CVA6_ROOT="$(cd "$(dirname "$_cva6_src")" && pwd)"
export CVA6_ROOT

# --- 1. ensure Bun ---------------------------------------------------------
if ! command -v bun >/dev/null 2>&1; then
  echo "[setenv.sh] Bun not found; installing from https://bun.sh/install ..."
  if curl -fsSL https://bun.sh/install | bash; then
    export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
    export PATH="$BUN_INSTALL/bin:$PATH"
  else
    echo "[setenv.sh] ERROR: Bun install failed; install from https://bun.sh and re-source." >&2
    return 1
  fi
fi
if ! command -v bun >/dev/null 2>&1; then
  echo "[setenv.sh] ERROR: Bun is not on PATH; open a new shell or add \$HOME/.bun/bin to PATH." >&2
  return 1
fi

# --- 2. bun install in build-platform --------------------------------------
if [ -d "$CVA6_ROOT/build-platform" ]; then
  echo "[setenv.sh] bun install (build-platform) ..."
  ( cd "$CVA6_ROOT/build-platform" && bun install ) \
    || echo "[setenv.sh] WARN: 'bun install' failed; g6lc-build still runs (deps are dev-only)." >&2
fi

# --- 3. define g6lc-build / cva6-build -------------------------------------
# Functions (not aliases) so args forward cleanly. Wrappers over build.sh.
g6lc-build() {
  command bash "$CVA6_ROOT/build.sh" "$@"
}
# Brand-forward name is g6lc-build. `cva6-build` is retained as a permanent
# alias: it is baked into AGENTS guides, verif scripts and CI, and renaming the
# only entry point would break the toolchain contract for no benefit
# (AGENTS-branding.md §3, §4). Both names are equivalent.
cva6-build() {
  command bash "$CVA6_ROOT/build.sh" "$@"
}
# Also export them for child bash shells (no-op / harmless under zsh).
export -f cva6-build 2>/dev/null || true
export -f g6lc-build 2>/dev/null || true

echo "[setenv.sh] 'g6lc-build' (and legacy alias 'cva6-build') ready (wraps $CVA6_ROOT/build.sh)."

# --- 4. show the current build-platform status -----------------------------
g6lc-build status || true
