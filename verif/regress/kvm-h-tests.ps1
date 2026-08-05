# SPDX-License-Identifier: MIT
# Optional KVM/H suite artifact gate.
$ErrorActionPreference = "Stop"
Set-Location (Resolve-Path (Join-Path $PSScriptRoot "../.."))
Write-Host "[kvm-h-tests] OPTIONAL suite"
$required = @(
  "verif/tests/custom/kvm_h/kvm_h_stress.S",
  "verif/tests/custom/kvm_h/hlv_hsv_smoke.S",
  "verif/tests/testlist_kvm_h.yaml",
  "verif/tests/custom/sstc_h/vstimecmp_htimedelta.S"
)
foreach ($f in $required) {
  if (-not (Test-Path $f)) { Write-Error "Missing $f"; exit 1 }
  Write-Host "  ok $f"
}
if (Get-Command bash -ErrorAction SilentlyContinue) {
  bash verif/regress/kvm-h-tests.sh @args
  exit $LASTEXITCODE
}
Write-Host "[kvm-h-tests] PASS (artifact gates)"
exit 0
