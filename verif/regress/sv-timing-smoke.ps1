# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Host smoke (Windows): timings compile --output package.

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "../sv-timing-tests/scripts/common.ps1")
$Root = Get-SvtRepoRoot $ScriptDir
Set-Location $Root

$Out = Join-Path (Get-SvtOutBase $Root) "smoke"
$Mhz = if ($env:SVT_TARGET_MHZ) { $env:SVT_TARGET_MHZ } else { "1250" }
$Flist = "verif/sv-timing-tests/flists/fixture_project_mini.f"

$from = Test-SvtFromTiming -Root $Root
if ($from) {
  $Out = $from
  Write-Host "[sv-timing-smoke] reusing precompiled package at $Out"
  $report = Join-Path $Out "analyze.json"
  if (-not (Test-Path $report)) { $report = Join-Path $Out "correct.json" }
  if (-not (Test-Path $report)) { throw "missing analyze.json/correct.json in from-timing dir" }
  Write-Host "[sv-timing-smoke] PASS (from-timing)"
  exit 0
}

New-Item -ItemType Directory -Force -Path $Out | Out-Null

Write-Host "[sv-timing-smoke] timings status"
Invoke-SvtTimings -Root $Root status

Write-Host "[sv-timing-smoke] compile fixture → --output $Out"
Invoke-SvtTimings -Root $Root compile `
  --flist $Flist `
  --all-modules `
  --target-mhz $Mhz `
  --output $Out

$report = Join-Path $Out "analyze.json"
if (-not (Test-Path $report)) { throw "missing analyze.json" }
if (-not (Test-Path (Join-Path $Out "portable.f"))) { throw "missing portable.f" }
$j = Get-Content $report -Raw | ConvertFrom-Json
if (-not $j.disclaimer) { throw "analyze.json missing disclaimer" }
Write-Host "[sv-timing-smoke] PASS"
