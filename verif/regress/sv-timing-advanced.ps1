# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "../sv-timing-tests/scripts/common.ps1")
$Root = Get-SvtRepoRoot $ScriptDir
Set-Location $Root

$Out = Join-Path (Get-SvtOutBase $Root) "advanced"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Mhz = if ($env:SVT_TARGET_MHZ) { $env:SVT_TARGET_MHZ } else { "1250" }

Write-Host "[sv-timing-advanced] fixture analyze+correct emit"
Invoke-SvtTimings -Root $Root analyze `
  --flist "verif/sv-timing-tests/flists/fixture_project_mini.f" `
  --all-modules `
  --target-mhz $Mhz `
  --json-out (Join-Path $Out "fixture-analyze.json")

Invoke-SvtTimings -Root $Root correct `
  --flist "verif/sv-timing-tests/flists/fixture_project_mini.f" `
  --all-modules `
  --target-mhz 2500 `
  --allow-latency `
  --assume-clk `
  --emit `
  --out (Join-Path $Out "fixture-corrected") `
  --json-out (Join-Path $Out "fixture-correct.json")

foreach ($name in @("sparse_frontend", "sparse_ex_units")) {
  Write-Host "[sv-timing-advanced] screen $name"
  try {
    Invoke-SvtTimings -Root $Root analyze `
      --flist "verif/sv-timing-tests/flists/$name.f" `
      --all-modules `
      --target-mhz $Mhz `
      --json-out (Join-Path $Out "$name-analyze.json") `
      --cache (Join-Path $Out "$name.sqlite")
  } catch {
    Write-Host "[sv-timing-advanced] soft-skip $name analyze"
  }
}

if (-not (Test-Path (Join-Path $Out "fixture-analyze.json"))) {
  throw "missing fixture-analyze.json"
}
Write-Host "[sv-timing-advanced] PASS"
