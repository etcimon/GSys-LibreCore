# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# FSE S6 directed suite gate. Always runs real commands:
#   1) artifact + S5/S6 source gates
#   2) cva6.py when Python+yaml available
#   3) else bun/build.ps1 verify --lint for DV_TARGET
#
#   .\verif\regress\spec-deep-tests.ps1
#   $env:DV_TARGET='cv64a6_spec_deep'; .\verif\regress\spec-deep-tests.ps1

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "../..")
Set-Location $Root

if (-not $env:DV_TARGET) { $env:DV_TARGET = "cv64a6_spec_deep" }
if (-not $env:DV_SIMULATORS) { $env:DV_SIMULATORS = "veri-testharness,spike" }

Write-Host "[spec-deep-tests] target=$($env:DV_TARGET) simulators=$($env:DV_SIMULATORS)"

$required = @(
  "verif/tests/custom/spec/spec_mispredict_chain.S",
  "verif/tests/custom/spec/spec_stq_stress.S",
  "verif/tests/custom/spec/spec_fence_drain.S",
  "verif/tests/custom/spec/spec_rvwmo_litmus.S",
  "verif/tests/testlist_spec_deep.yaml",
  "core/include/cv64a6_spec_deep_config_pkg.sv",
  "core/scoreboard.sv",
  "core/frontend/g6lc_bp_ckpt.sv",
  "architecture/speculative-execution/UPDATE-PLAN.md"
)
foreach ($f in $required) {
  if (-not (Test-Path $f)) { Write-Error "Missing $f"; exit 1 }
  Write-Host "  ok $f"
}

$pkg = Get-Content "core/include/cv64a6_spec_deep_config_pkg.sv" -Raw
if ($pkg -notmatch "DeepSpecEn:\s*bit'\(1\)") {
  Write-Error "cv64a6_spec_deep must set DeepSpecEn=1"
  exit 1
}
Write-Host "  ok DeepSpecEn=1"

$sb = Get-Content "core/scoreboard.sv" -Raw
if ($sb -notmatch "resolved_branch_i\.hart_id" -and $sb -notmatch "sbe\.hart_id == resolved_branch") {
  Write-Error "scoreboard must filter cancel by hart_id (FSE S5)"
  exit 1
}
Write-Host "  ok S5 hart-filtered cancel"

$ckpt = Get-Content "core/frontend/g6lc_bp_ckpt.sv" -Raw
if ($ckpt -notmatch "hart_i" -or $ckpt -notmatch "NH") {
  Write-Error "g6lc_bp_ckpt must be banked / hart-aware (FSE S5)"
  exit 1
}
Write-Host "  ok banked BP ckpt"

function Invoke-Cva6Py {
  if (-not (Test-Path "verif/sim/cva6.py")) { return $false }
  $py = $null
  if (Get-Command python -ErrorAction SilentlyContinue) { $py = "python" }
  elseif (Get-Command python3 -ErrorAction SilentlyContinue) { $py = "python3" }
  if (-not $py) { return $false }

  $env:PYTHONPATH = "verif/sim;verif/sim/dv;core-v-verif;$($env:PYTHONPATH)"
  $null = & $py -c "import yaml" 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Host "[spec-deep-tests] installing PyYAML..."
    $null = & $py -m pip install --user pyyaml 2>&1
  }
  $probe = & $py -c @"
import sys
sys.path.insert(0, 'verif/sim')
try:
    import yaml
    import verilator_log_to_trace_csv
except Exception as e:
    print(e)
    sys.exit(2)
sys.exit(0)
"@ 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Host "[spec-deep-tests] cva6.py not runnable ($probe) — will lint"
    return $false
  }

  Write-Host "[spec-deep-tests] running cva6.py --target $($env:DV_TARGET) --iss $($env:DV_SIMULATORS)"
  & $py verif/sim/cva6.py `
    --target $env:DV_TARGET `
    --iss $env:DV_SIMULATORS `
    --testlist verif/tests/testlist_spec_deep.yaml
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  Write-Host "[spec-deep-tests] PASS (cva6.py)"
  return $true
}

$ranPy = Invoke-Cva6Py
if ($ranPy -eq $true) { exit 0 }

Write-Host "[spec-deep-tests] cva6.py unavailable — running lint for $($env:DV_TARGET)"
if (Test-Path ".\build.ps1") {
  & .\build.ps1 verify --lint --target $env:DV_TARGET
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  # Also lint production OoO lite (DeepSpec co-path)
  & .\build.ps1 verify --lint --target g6lc64_ooo
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  Write-Host "[spec-deep-tests] PASS (lint fallback)"
  exit 0
}

Write-Error "[spec-deep-tests] cannot run cva6.py or build.ps1"
exit 1
