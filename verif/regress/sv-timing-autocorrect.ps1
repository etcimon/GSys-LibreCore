# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "../sv-timing-tests/scripts/common.ps1")
$Root = Get-SvtRepoRoot $ScriptDir
Set-Location $Root

$Out = Join-Path (Get-SvtOutBase $Root) "autocorrect"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Mhz = if ($env:SVT_TARGET_MHZ) { $env:SVT_TARGET_MHZ } else { "2500" }
$Emit = if ($env:SVT_EMIT) { $env:SVT_EMIT } else { "1" }
$FlistFix = "verif/sv-timing-tests/flists/fixture_project_mini.f"

Write-Host "[sv-timing-autocorrect] correct dry-run fixture"
Invoke-SvtTimings -Root $Root correct `
  --flist $FlistFix `
  --all-modules `
  --target-mhz $Mhz `
  --allow-latency `
  --assume-clk `
  --json-out (Join-Path $Out "correct-dry.json")

if ($Emit -eq "1") {
  Write-Host "[sv-timing-autocorrect] correct --emit fixture"
  Invoke-SvtTimings -Root $Root correct `
    --flist $FlistFix `
    --all-modules `
    --target-mhz $Mhz `
    --allow-latency `
    --assume-clk `
    --emit `
    --out (Join-Path $Out "corrected") `
    --json-out (Join-Path $Out "correct-emit.json")
}

Write-Host "[sv-timing-autocorrect] PASS"
