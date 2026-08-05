# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Shared helpers for verif/regress/sv-timing-*.ps1

function Get-SvtRepoRoot {
  param([string]$ScriptDir)
  return (Resolve-Path (Join-Path $ScriptDir "../..")).Path
}

function Get-SvtOutBase {
  param([string]$Root)
  if ($env:SVT_VERIF_OUT) { return $env:SVT_VERIF_OUT }
  return (Join-Path $Root "build-platform/workspace/build/sv-timing/verif-tests")
}

function Invoke-SvtTimings {
  param(
    [string]$Root,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$TimingsArgs
  )
  $bun = Get-Command bun -ErrorAction SilentlyContinue
  if (-not $bun) { throw "bun not on PATH (required for build-platform timings)" }
  Push-Location (Join-Path $Root "build-platform")
  try {
    & bun run src/cli/index.ts timings @TimingsArgs
    if ($LASTEXITCODE -ne 0) { throw "timings failed exit=$LASTEXITCODE" }
  } finally {
    Pop-Location
  }
}

# Validate CVA6_FROM_TIMING / FROM_TIMING package; sets script-scoped reuse path.
function Test-SvtFromTiming {
  param([string]$Root)
  $dir = if ($env:CVA6_FROM_TIMING) { $env:CVA6_FROM_TIMING } elseif ($env:FROM_TIMING) { $env:FROM_TIMING } else { $null }
  if (-not $dir) { return $null }
  Write-Host "[sv-timing-tests] --from-timing consume: $dir"
  Invoke-SvtTimings -Root $Root validate --from-timing $dir
  return $dir
}
