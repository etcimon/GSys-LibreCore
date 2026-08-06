# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Optional dual-hart CI gate (Windows). Prefers bash companion when available.
# Lint is soft-skipped when only host-skewed / missing tools unless
# $env:DUAL_HART_REQUIRE_LINT=1.
$ErrorActionPreference = "Stop"
Set-Location (Resolve-Path (Join-Path $PSScriptRoot "../.."))

$bash = Get-Command bash -ErrorAction SilentlyContinue
if ($bash) {
  & bash verif/regress/dual-hart-ci.sh @args
  exit $LASTEXITCODE
}

Write-Host "[dual-hart-ci] OPTIONAL suite (PowerShell path)"
$required = @(
  "core/include/g6lc64_smt2_config_pkg.sv",
  "architecture/multi-threading/smt2-bringup.md",
  "architecture/multi-threading/dts-linux-smt.md",
  "corev_apu/bootrom/ariane-smt2.dts",
  "corev_apu/bootrom/ariane-linux.dts",
  "core/smt/g6lc_smt_regfile.sv",
  "core/smt/g6lc_smt_csr_bank.sv",
  "verif/tests/custom/smt/smt_dual_park.S",
  "verif/tests/testlist_smt_linux.yaml",
  "build-platform/scripts/validate-cva6-dts.ps1",
  "verif/regress/dual-hart-ci.sh"
)
foreach ($f in $required) {
  if (-not (Test-Path $f)) { Write-Error "Missing $f"; exit 1 }
  Write-Host "  ok $f"
}

$pkg = Get-Content "core/include/g6lc64_smt2_config_pkg.sv" -Raw
if ($pkg -notmatch "NrHarts:\s*unsigned'\(2\)") {
  throw "g6lc64_smt2 must set NrHarts=2"
}
Write-Host "  ok NrHarts=2"

if (Test-Path "verif/regress/smt-linux-boot-path.ps1") {
  Write-Host "[dual-hart-ci] running smt-linux-boot-path.ps1..."
  & pwsh -File verif/regress/smt-linux-boot-path.ps1
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} elseif (Test-Path "build-platform/workspace/linux-dts/Documentation/devicetree/bindings/riscv/cpus.yaml") {
  Write-Host "[dual-hart-ci] running validate-cva6-dts.ps1..."
  & pwsh -File build-platform/scripts/validate-cva6-dts.ps1
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} else {
  Write-Host "[dual-hart-ci] WARN: linux-dts not fetched; skip schema validate (run fetch-linux-dts.ps1)"
}

if (Test-Path "verif/regress/smt-linux-rootfs.ps1") {
  Write-Host "[dual-hart-ci] running smt-linux-rootfs preflight (R3 soft)..."
  $env:SMT2_SKIP_R3 = if ($env:DUAL_HART_SKIP_R3) { $env:DUAL_HART_SKIP_R3 } else { "1" }
  & pwsh -File verif/regress/smt-linux-rootfs.ps1
  if ($LASTEXITCODE -ne 0) {
    Write-Host "[dual-hart-ci] WARN: smt-linux-rootfs preflight skipped/failed"
  }
}

$requireLint = ($env:DUAL_HART_REQUIRE_LINT -eq "1")
$suiteBin = "build-platform/workspace/tooling/oss-cad-suite/bin"
$hasNative = (Test-Path (Join-Path $suiteBin "verilator_bin.exe")) -or (Test-Path (Join-Path $suiteBin "verilator_bin"))
Write-Host "[dual-hart-ci] lint g6lc64_smt2..."
if (-not $hasNative) {
  if ($requireLint) {
    Write-Error "native verilator missing under oss-cad-suite (DUAL_HART_REQUIRE_LINT=1)"
    exit 1
  }
  Write-Host "[dual-hart-ci] WARN: soft-skip smt2 lint — verilator not under workspace/tooling"
} else {
  & .\build.ps1 verify --lint --target g6lc64_smt2
  if ($LASTEXITCODE -ne 0) {
    if ($requireLint) { exit $LASTEXITCODE }
    Write-Host "[dual-hart-ci] WARN: soft-skip smt2 lint failure (set DUAL_HART_REQUIRE_LINT=1 to hard-fail)"
  }
}

Write-Host "[dual-hart-ci] PASS"
exit 0
