# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# docs.ps1 — Bootstrap entry for the CVA6 Next.js documentation site.
#
# Ensures Bun is available (installing it if necessary), then runs the docs site
# under docs/website. Passes all arguments to the Next.js CLI.
#
#   .\docs.ps1 dev          # start local dev server
#   .\docs.ps1 build        # static export
#   .\docs.ps1 start        # serve the previously exported build

$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$docsDir = Join-Path $here "docs/website"

if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
  Write-Host "[docs.ps1] Bun not found; installing from bun.sh/install.ps1 ..."
  Invoke-RestMethod bun.sh/install.ps1 | Invoke-Expression
  $env:PATH = "$env:USERPROFILE\.bun\bin;$env:PATH"
}

if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
  Write-Error "[docs.ps1] Bun installation failed or is not on PATH. Install from https://bun.sh and re-run."
  exit 1
}

if (-not (Test-Path (Join-Path $docsDir "node_modules"))) {
  Write-Host "[docs.ps1] Installing docs dependencies in $docsDir ..."
  Push-Location $docsDir
  try {
    & bun install
  } finally {
    Pop-Location
  }
}

Push-Location $docsDir
try {
  & bun run @args
  exit $LASTEXITCODE
} finally {
  Pop-Location
}
