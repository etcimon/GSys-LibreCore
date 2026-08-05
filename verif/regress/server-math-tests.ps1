# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Optional U10 server-math gates (artifacts + package fields).

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "../..")
Set-Location $Root

$env:DV_TARGET = if ($env:DV_TARGET) { $env:DV_TARGET } else { "g6lc64_server_math" }
Write-Host "[server-math-tests] OPTIONAL suite; target=$($env:DV_TARGET)"

$required = @(
  "verif/tests/custom/server_math/u10_misa_bhz.S",
  "verif/tests/custom/server_math/u10_cboz_memset.S",
  "verif/tests/custom/server_math/u10_memcpy_stream.S",
  "verif/tests/testlist_server_math.yaml",
  "core/include/g6lc64_server_math_config_pkg.sv",
  "core/include/g6lc64_server_math_v_config_pkg.sv"
)
foreach ($f in $required) {
  if (-not (Test-Path $f)) { Write-Error "Missing $f"; exit 1 }
  Write-Host "  ok $f"
}

$pkg = Get-Content "core/include/g6lc64_server_math_config_pkg.sv" -Raw
foreach ($pat in @(
  "CVA6ConfigHExtEn = 1",
  "CVA6ConfigBExtEn = 1",
  "HPDCACHE_WT",
  "RVZiCboz",
  "HwPrefetchEn: bit'(1)",
  "NrCores: unsigned'(2)"
)) {
  if ($pkg -notmatch [regex]::Escape($pat) -and $pkg -notmatch $pat) {
    # RVZiCboz appears as bit'(1) field
    if ($pat -eq "RVZiCboz" -and $pkg -match "RVZiCboz: bit'\(1\)") { Write-Host "  cfg RVZiCboz"; continue }
    if ($pat -eq "CVA6ConfigHExtEn = 1" -and $pkg -match "CVA6ConfigHExtEn = 1") { Write-Host "  cfg H"; continue }
    if ($pat -eq "CVA6ConfigBExtEn = 1" -and $pkg -match "CVA6ConfigBExtEn = 1") { Write-Host "  cfg B"; continue }
    Write-Error "server_math package missing: $pat"
    exit 1
  }
  Write-Host "  cfg $pat"
}

if (Get-Command bash -ErrorAction SilentlyContinue) {
  bash verif/regress/server-math-tests.sh @args
  exit $LASTEXITCODE
}
Write-Host "[server-math-tests] PASS (artifact + config gates)"
exit 0
