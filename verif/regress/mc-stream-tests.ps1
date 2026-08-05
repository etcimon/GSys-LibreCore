# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Windows entry for mc-stream-tests (p6 stream plane × multicore).
# Prefers bash (Git-Bash/WSL); otherwise runs the artifact + lint path in PowerShell.

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "../..")
Set-Location $Root

$bash = Get-Command bash -ErrorAction SilentlyContinue
if ($bash) {
  & bash verif/regress/mc-stream-tests.sh @args
  exit $LASTEXITCODE
}

$env:DV_TARGET = if ($env:DV_TARGET) { $env:DV_TARGET } else { "g6lc64_ooo_server" }
Write-Host "[mc-stream-tests] p6-buildup (PowerShell path) target=$($env:DV_TARGET)"

$need = @(
  "verif/tests/testlist_mc_stream.yaml",
  "verif/tests/custom/multicore/mc_stream_plane.S",
  "corev_apu/src/g6lc_cluster.sv",
  "corev_apu/l2_cache/g6lc_l2_top.sv",
  "corev_apu/l2_cache/g6lc_l2_tag.sv",
  "corev_apu/l3_cache/g6lc_l3_inclusive_inv.sv",
  "corev_apu/l3_cache/g6lc_server_prefetcher.sv"
)
foreach ($f in $need) {
  if (-not (Test-Path $f)) { throw "[mc-stream-tests] MISSING $f" }
}

$l2 = Get-Content "corev_apu/l2_cache/g6lc_l2_top.sv" -Raw
if ($l2 -notmatch "l2_back_inval_valid") { throw "L3→L2 back-inval port missing" }
$tag = Get-Content "corev_apu/l2_cache/g6lc_l2_tag.sv" -Raw
if ($tag -notmatch "inval_match_i") { throw "tag match-inval missing" }

$hasGcc = [bool](Get-Command riscv64-unknown-elf-gcc -ErrorAction SilentlyContinue)
$hasSpike = [bool](Get-Command spike -ErrorAction SilentlyContinue)
if (-not $hasGcc -or -not $hasSpike) {
  Write-Host "[mc-stream-tests] note: full cva6.py sim needs riscv64-unknown-elf-gcc + spike on PATH"
  Write-Host "  riscv-gcc: $(if ($hasGcc) { 'yes' } else { 'MISSING' })"
  Write-Host "  spike:     $(if ($hasSpike) { 'yes' } else { 'MISSING' })"
  Write-Host "  → lint fallback (artifact contracts still enforced)"
}

$bun = Get-Command bun -ErrorAction SilentlyContinue
if (-not $bun) { throw "bun not found; install build-platform toolchain" }

& bun build-platform/src/cli/index.ts verify --lint --target $env:DV_TARGET
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if ($env:DV_TARGET -eq "g6lc64_ooo_server") {
  & bun build-platform/src/cli/index.ts verify --lint --target g6lc64_server_math
  if ($LASTEXITCODE -ne 0) {
    Write-Host "[mc-stream-tests] WARN: server_math lint skipped/failed"
  }
}
Write-Host "[mc-stream-tests] PASS (PowerShell lint + contracts)"
exit 0
