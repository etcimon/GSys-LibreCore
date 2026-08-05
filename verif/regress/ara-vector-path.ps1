# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "../..")
Set-Location $Root
$bash = Get-Command bash -ErrorAction SilentlyContinue
if ($bash) {
  & bash verif/regress/ara-vector-path.sh @args
  exit $LASTEXITCODE
}
$need = @(
  "architecture/ara-vector-attach.md",
  "agents/guides/AGENTS-vector.md",
  "vendor/ara/Flist.ara",
  "core/include/g6lc64_server_math_v_config_pkg.sv",
  "corev_apu/bootrom/ariane-server-math-v.dts",
  "verif/tests/custom/vector/v_memcpy_skip.S",
  "verif/tests/custom/vector/v_misa_v.S",
  "verif/tests/custom/vector/v_memcpy_lmul.S",
  "verif/tests/testlist_ara_vector.yaml"
)
foreach ($f in $need) {
  if (-not (Test-Path $f)) { throw "[ara-vector-path] MISSING $f" }
}
$dts = Get-Content "corev_apu/bootrom/ariane-server-math-v.dts" -Raw
if ($dts -notmatch '"v"') { throw "[ara-vector-path] FAIL: DTS missing v token" }
if (Test-Path "vendor/ara/upstream/hardware/src/ara.sv") {
  Write-Host "  ok upstream Ara RTL present"
} else {
  Write-Host "  WARN: run cva6-build vendor sync ara"
}
$bun = Get-Command bun -ErrorAction SilentlyContinue
if ($bun) {
  & bun build-platform/src/cli/index.ts verify --lint --target g6lc64_server_math
  if (Test-Path "vendor/ara/upstream/hardware/src/ara.sv") {
    & bun build-platform/src/cli/index.ts verify --lint --target g6lc64_server_math_v
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $env:CVA6_ARA_ATTACH = "1"
    & bun build-platform/src/cli/index.ts verify --lint --target g6lc64_server_math_v
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }
}
Write-Host "[ara-vector-path] PASS (PowerShell path)"
exit 0
