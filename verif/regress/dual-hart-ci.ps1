# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Optional dual-hart CI gate (Windows). Prefers bash companion when available.
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
  Write-Host "[dual-hart-ci] running smt-linux-rootfs preflight..."
  & pwsh -File verif/regress/smt-linux-rootfs.ps1
  if ($LASTEXITCODE -ne 0) {
    Write-Host "[dual-hart-ci] WARN: smt-linux-rootfs preflight skipped/failed"
  }
}

Write-Host "[dual-hart-ci] lint g6lc64_smt2..."
& .\build.ps1 verify --lint --target g6lc64_smt2
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "[dual-hart-ci] PASS"
exit 0
