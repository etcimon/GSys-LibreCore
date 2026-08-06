# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Optional stream8 smoke (Windows). Prefers bash companion.
$ErrorActionPreference = "Stop"
Set-Location (Resolve-Path (Join-Path $PSScriptRoot "../.."))
$bash = Get-Command bash -ErrorAction SilentlyContinue
if ($bash) {
  & bash verif/regress/stream8-smoke.sh @args
  exit $LASTEXITCODE
}
Write-Host "[stream8-smoke] PowerShell artifact path"
$need = @(
  "core/include/g6lc64_stream8_config_pkg.sv",
  "corev_apu/bootrom/ariane-stream8.dts",
  "verif/tests/testlist_stream8.yaml",
  "architecture/stream8-class.md"
)
foreach ($f in $need) {
  if (-not (Test-Path $f)) { Write-Error "Missing $f"; exit 1 }
  Write-Host "  ok $f"
}
$pkg = Get-Content "core/include/g6lc64_stream8_config_pkg.sv" -Raw
if ($pkg -notmatch "NrCores:\s*unsigned'\(2\)") { throw "NrCores must be 2" }
if ($pkg -notmatch "RVZacas:\s*bit'\(1\)") { throw "RVZacas must be 1" }
if ($pkg -notmatch "DeepSpecEn:\s*bit'\(1\)") { throw "DeepSpecEn must be 1" }
Write-Host "  ok stream8 cfg envelope"
Write-Host "[stream8-smoke] PASS (artifacts; run bash path for compile/lint)"
exit 0
