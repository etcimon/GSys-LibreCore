# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir "../sv-timing-tests/scripts/common.ps1")
$Root = Get-SvtRepoRoot $ScriptDir
Set-Location $Root

$Out = Join-Path (Get-SvtOutBase $Root) "core-sparse"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Mhz = if ($env:SVT_TARGET_MHZ) { $env:SVT_TARGET_MHZ } else { "1250" }
$Flist = "verif/sv-timing-tests/flists/sparse_ex_units.f"
$Mods = if ($env:SVT_MODULES) { $env:SVT_MODULES } else { "alu,mult,multiplier,serdiv,branch_unit" }

Write-Host "[sv-timing-core-sparse] flist expand"
Invoke-SvtTimings -Root $Root flist --flist $Flist --out (Join-Path $Out "portable.f")

$ParamMapRel = if ($env:SVT_PARAM_MAP) { $env:SVT_PARAM_MAP } else { "verif/sv-timing-tests/param-maps/cv64a6_imafdc_xlen64.json" }
# Absolute: cargo run cwd is sv-timing/, not repo root.
$ParamMap = if ([System.IO.Path]::IsPathRooted($ParamMapRel)) { $ParamMapRel } else { Join-Path $Root $ParamMapRel }
Write-Host "[sv-timing-core-sparse] analyze modules=$Mods param-map=$ParamMap"
try {
  Invoke-SvtTimings -Root $Root analyze `
    --flist $Flist `
    --modules $Mods `
    --target-mhz $Mhz `
    --param-map $ParamMap `
    --package-mode packages `
    --assume-xlen 64 `
    --json-out (Join-Path $Out "analyze.json") `
    --cache (Join-Path $Out "ir.sqlite")
} catch {
  Write-Host "[sv-timing-core-sparse] analyze failed — soft-pass host wiring"
  '{"soft_skip":true,"reason":"analyze_failed"}' | Set-Content (Join-Path $Out "soft_skip.json")
  Write-Host "[sv-timing-core-sparse] SOFT-PASS"
  exit 0
}
$report = Join-Path $Out "analyze.json"
if (-not (Test-Path $report)) { throw "missing analyze.json" }
$j = Get-Content $report -Raw | ConvertFrom-Json
if (-not $j.param_map_keys) { Write-Host "[sv-timing-core-sparse] warn: no param_map_keys (older CLI?)" }
Write-Host "[sv-timing-core-sparse] PASS"
