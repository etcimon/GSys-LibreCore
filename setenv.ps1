# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# setenv.ps1 — Make `g6lc-build` (and legacy `cva6-build`) available in this session.
#
#   . .\setenv.ps1        # dot-source is recommended (the function is set global either way)
#
# In order, it:
#   1. ensures Bun is installed and on PATH (for this session),
#   2. runs `bun install` in build-platform\ (dev deps: type stubs + tsc),
#   3. defines global `g6lc-build` / `cva6-build` (wrappers over build.ps1),
#   4. prints `g6lc-build status` (the current setup + parameters).
#
# Afterwards, drive the whole core -> uncore -> board -> foundry flow with one
# command, e.g.:
#   g6lc-build doctor ; g6lc-build setup --install ; g6lc-build test --open-source
#   g6lc-build mb list ; g6lc-build tech status
#
# NOTE: this script does NOT mutate your session's global $ErrorActionPreference;
# it handles its own errors so sourcing never destabilises your shell.

# --- resolve this script's own directory -----------------------------------
$CVA6_ROOT = $PSScriptRoot
if (-not $CVA6_ROOT) { $CVA6_ROOT = Split-Path -Parent $MyInvocation.MyCommand.Path }
$env:CVA6_ROOT = $CVA6_ROOT

# --- 1. ensure Bun ----------------------------------------------------------
if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
  Write-Host "[setenv.ps1] Bun not found; installing from bun.sh/install.ps1 ..."
  try {
    Invoke-RestMethod bun.sh/install.ps1 | Invoke-Expression
    $env:PATH = "$env:USERPROFILE\.bun\bin;$env:PATH"
  } catch {
    Write-Warning "[setenv.ps1] Bun install failed; install from https://bun.sh and re-run."
  }
}
if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
  Write-Warning "[setenv.ps1] Bun is not on PATH; open a new shell or add %USERPROFILE%\.bun\bin to PATH."
  return
}

# --- 2. bun install in build-platform ---------------------------------------
$bp = Join-Path $CVA6_ROOT "build-platform"
if (Test-Path $bp) {
  Write-Host "[setenv.ps1] bun install (build-platform) ..."
  Push-Location $bp
  try { & bun install } catch { Write-Warning "[setenv.ps1] 'bun install' failed; cva6-build still runs (deps are dev-only)." }
  Pop-Location
}

# --- 3. define the cva6-build command ---------------------------------------
# `global:` so the function persists in the session whether the script is
# dot-sourced or run. It wraps the top-level build.ps1 entry.
function global:cva6-build {
  & (Join-Path $env:CVA6_ROOT "build.ps1") @args
}
# Brand-forward name for GSys LibreCore. `cva6-build` is retained as a permanent
# alias: it is baked into AGENTS guides, verif scripts and CI, and renaming the
# only entry point would break the toolchain contract for no benefit
# (AGENTS-branding.md §3, §4). Both names are equivalent.
function global:g6lc-build {
  & (Join-Path $env:CVA6_ROOT "build.ps1") @args
}
Write-Host "[setenv.ps1] 'g6lc-build' (and legacy alias 'cva6-build') ready (wraps $CVA6_ROOT\build.ps1)."

# --- 4. show the current build-platform status ------------------------------
g6lc-build status
