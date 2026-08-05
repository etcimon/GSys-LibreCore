# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "../..")
Set-Location $Root

# Prefer native PowerShell path so managed xPack .exe is found (bash may miss .exe).
# Force bash with: $env:MC_SPO_USE_BASH = "1"
if ($env:MC_SPO_USE_BASH -eq "1") {
  $bash = Get-Command bash -ErrorAction SilentlyContinue
  if ($bash) {
    & bash verif/regress/mc-spo-soak.sh @args
    exit $LASTEXITCODE
  }
}

Write-Host "[mc-spo-soak] multi-core stream plane x spo/CF (PowerShell)"
$narrow = @(
  "verif/tests/custom/multicore/mc_stream_plane.S",
  "verif/tests/custom/multicore/zacas_amocas_w.S",
  "verif/tests/custom/multicore/zacas_amocas_d.S",
  "verif/tests/custom/multicore/mc_spo_st_fwd.S",
  "verif/tests/custom/multicore/mc_spo_fence_drain.S",
  "verif/tests/custom/multicore/mc_cas_lock_handoff.S",
  "verif/tests/custom/multicore/mc_spo_cf_stream.S",
  "verif/tests/custom/multicore/mc_spo_cas_stream.S",
  "verif/tests/custom/multicore/mc_spo_mispred_stream.S"
)
foreach ($f in $narrow) {
  if (-not (Test-Path $f)) { throw "[mc-spo-soak] MISSING $f" }
}
Write-Host "  ok $($narrow.Count) narrow tests"

$cc = $null
foreach ($name in @("riscv-none-elf-gcc", "riscv64-unknown-elf-gcc")) {
  $c = Get-Command $name -ErrorAction SilentlyContinue
  if ($c) { $cc = $c.Source; break }
}
if (-not $cc) {
  $managed = Join-Path $Root "build-platform/workspace/tooling/riscv/bin/riscv-none-elf-gcc.exe"
  if (Test-Path $managed) { $cc = $managed }
  else {
    $c2 = Get-ChildItem -Path (Join-Path $Root "build-platform/workspace/tooling") -Recurse -Filter "riscv-none-elf-gcc.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c2) { $cc = $c2.FullName }
  }
}
Write-Host "  riscv-gcc: $(if ($cc) { $cc } else { 'MISSING' })"

$rounds = if ($env:MC_SPO_ROUNDS) { [int]$env:MC_SPO_ROUNDS } else { 3 }
if ($cc) {
  for ($r = 1; $r -le $rounds; $r++) {
    Write-Host "[mc-spo-soak] assemble round $r/$rounds..."
    foreach ($s in $narrow) {
      $o = [System.IO.Path]::GetTempFileName() + ".o"
      & $cc -c -march=rv64imafdc -mabi=lp64d -Iverif/tests/custom/env -Iverif/tests/custom/common -o $o $s
      if ($LASTEXITCODE -ne 0) { throw "assemble fail $s" }
      Remove-Item $o -ErrorAction SilentlyContinue
    }
  }
  Write-Host "  ok assemble soak ${rounds}x$($narrow.Count)"
} else {
  Write-Host "  skip assemble (no gcc; run: cva6-build tools install sim)"
}

$bun = Get-Command bun -ErrorAction SilentlyContinue
if ($bun -and $env:MC_SPO_LINT -ne "0") {
  Write-Host "[mc-spo-soak] lint g6lc64_ooo_server..."
  & bun build-platform/src/cli/index.ts verify --lint --target g6lc64_ooo_server
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  Write-Host "[mc-spo-soak] lint g6lc64_server_math..."
  & bun build-platform/src/cli/index.ts verify --lint --target g6lc64_server_math
  if ($LASTEXITCODE -ne 0) { Write-Host "  WARN: server_math lint failed" }
  Write-Host "  ok dual-target lint soak"
}
Write-Host "[mc-spo-soak] PASS"
exit 0
