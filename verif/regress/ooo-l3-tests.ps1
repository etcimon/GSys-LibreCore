# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Windows-native OoO + L2/L3 directed suite. Always runs real commands:
#   1) artifact + package gates
#   2) cva6.py when Python+yaml available
#   3) else bun verify --lint for DV_TARGET
#
#   .\verif\regress\ooo-l3-tests.ps1
#   $env:DV_TARGET='g6lc64_ooo'; .\verif\regress\ooo-l3-tests.ps1

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "../..")
Set-Location $Root

if (-not $env:DV_TARGET) { $env:DV_TARGET = "g6lc64_ooo_server" }
if (-not $env:DV_SIMULATORS) { $env:DV_SIMULATORS = "veri-testharness,spike" }

Write-Host "[ooo-l3-tests] target=$($env:DV_TARGET) simulators=$($env:DV_SIMULATORS)"

$required = @(
  "verif/tests/custom/ooo/ooo_ilp_chain.S",
  "verif/tests/custom/ooo/ooo_mem_dep.S",
  "verif/tests/custom/l3/l3_stride_stream.S",
  "verif/tests/custom/spec/spec_mispredict_chain.S",
  "verif/tests/testlist_ooo_l3.yaml",
  "core/include/g6lc64_ooo_server_config_pkg.sv",
  "core/include/g6lc64_ooo_config_pkg.sv"
)
foreach ($f in $required) {
  if (-not (Test-Path $f)) { Write-Error "Missing $f"; exit 1 }
  Write-Host "  ok $f"
}

# Prefer matching package for target
$pkgPath = if ($env:DV_TARGET -match "ooo_server") {
  "core/include/g6lc64_ooo_server_config_pkg.sv"
} elseif ($env:DV_TARGET -match "ooo") {
  "core/include/g6lc64_ooo_config_pkg.sv"
} else {
  $null
}
if ($pkgPath) {
  $pkg = Get-Content $pkgPath -Raw
  if ($pkg -notmatch "OoOEn:\s*bit'\(1\)") {
    Write-Error "$pkgPath must set OoOEn=1"
    exit 1
  }
  Write-Host "  ok OoOEn=1 in $pkgPath"
}

function Invoke-Cva6Py {
  # IMPORTANT: only return $true/$false — any other pipeline output makes `if (fn)` true in PowerShell.
  if (-not (Test-Path "verif/sim/cva6.py")) { return $false }
  $py = $null
  if (Get-Command python -ErrorAction SilentlyContinue) { $py = "python" }
  elseif (Get-Command python3 -ErrorAction SilentlyContinue) { $py = "python3" }
  if (-not $py) { return $false }

  $env:PYTHONPATH = "verif/sim;verif/sim/dv;core-v-verif;$($env:PYTHONPATH)"
  $null = & $py -c "import yaml" 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Host "[ooo-l3-tests] installing PyYAML..."
    $null = & $py -m pip install --user pyyaml 2>&1
  }
  # Probe import graph; missing riscv-dv modules ⇒ lint fallback
  $probe = & $py -c @"
import sys
sys.path.insert(0, 'verif/sim')
try:
    import yaml
    import verilator_log_to_trace_csv  # pulls riscv_trace_csv
except Exception as e:
    print(e)
    sys.exit(2)
sys.exit(0)
"@ 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Host "[ooo-l3-tests] cva6.py not runnable ($probe) — will lint"
    return $false
  }

  Write-Host "[ooo-l3-tests] running cva6.py --target $($env:DV_TARGET) --iss $($env:DV_SIMULATORS)"
  & $py verif/sim/cva6.py `
    --target $env:DV_TARGET `
    --iss $env:DV_SIMULATORS `
    --testlist verif/tests/testlist_ooo_l3.yaml
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  Write-Host "[ooo-l3-tests] PASS (cva6.py)"
  return $true
}

$ranPy = Invoke-Cva6Py
if ($ranPy -eq $true) { exit 0 }

# Real fallback command: lint the DV target via build platform
Write-Host "[ooo-l3-tests] cva6.py unavailable — running lint for $($env:DV_TARGET)"
if (Test-Path ".\build.ps1") {
  & .\build.ps1 verify --lint --target $env:DV_TARGET
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  Write-Host "[ooo-l3-tests] PASS (lint fallback)"
  exit 0
}

Write-Error "[ooo-l3-tests] cannot run cva6.py or build.ps1"
exit 1
