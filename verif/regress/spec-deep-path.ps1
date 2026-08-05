# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# FSE S1–S3 gate: artifacts + real lint of DeepSpec and OoO packages.
#   .\verif\regress\spec-deep-path.ps1

$ErrorActionPreference = "Stop"
Set-Location (Resolve-Path (Join-Path $PSScriptRoot "../.."))

Write-Host "=== FSE speculative-execution path gate ==="

$required = @(
  "architecture/speculative-execution/full-speculation-architecture.md",
  "architecture/speculative-execution/UPDATE-PLAN.md",
  "architecture/out-of-order/recovery-timeline.md",
  "core/include/cv64a6_spec_deep_config_pkg.sv",
  "core/include/g6lc64_ooo_config_pkg.sv",
  "core/frontend/g6lc_bp_ckpt.sv",
  "core/frontend/g6lc_bp_top.sv",
  "core/frontend/ras.sv",
  "core/store_buffer.sv",
  "core/ooo/g6lc_memdep.sv",
  "core/ooo/formal/g6lc_ooo_cancel_props.sv",
  "verif/tests/custom/spec/spec_mispredict_chain.S",
  "verif/tests/custom/spec/spec_stq_stress.S",
  "verif/tests/custom/spec/spec_fence_drain.S",
  "verif/tests/custom/spec/spec_rvwmo_litmus.S",
  "verif/tests/testlist_spec_deep.yaml"
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

$ckpt = Get-Content "core/frontend/g6lc_bp_ckpt.sv" -Raw
if ($ckpt -notmatch "RAS_DEPTH" -or $ckpt -notmatch "restore_ras") {
  Write-Error "g6lc_bp_ckpt must checkpoint/restore RAS"
  exit 1
}
Write-Host "  ok bp_ckpt RAS fields"

$md = Get-Content "core/ooo/g6lc_memdep.sv" -Raw
if ($md -notmatch "dep_observe_i" -or $md -notmatch "NR_TRAIN") {
  Write-Error "memdep must multi-train + dep_observe"
  exit 1
}
Write-Host "  ok memdep S3 train ports"

$ras = Get-Content "core/frontend/ras.sv" -Raw
if ($ras -notmatch "stack_snapshot_o" -or $ras -notmatch "restore_i") {
  Write-Error "ras.sv must export snapshot + restore"
  exit 1
}
Write-Host "  ok RAS snapshot/restore ports"

$top = Get-Content "core/frontend/g6lc_bp_top.sv" -Raw
if ($top -notmatch "ghist_flush" -or $top -notmatch "ras_restore_o") {
  Write-Error "bp_top must flush GHR on empty-ckpt mispredict and restore RAS"
  exit 1
}
Write-Host "  ok bp_top GHR flush + RAS restore"

$st = Get-Content "core/store_buffer.sv" -Raw
if ($st -notmatch "DeepSpecEn" -or $st -notmatch "DEPTH_SPEC") {
  Write-Error "store_buffer must scale DEPTH under DeepSpecEn"
  exit 1
}
if ($st -notmatch "cancelled_mask_i" -or $st -notmatch "trans_id") {
  Write-Error "store_buffer must support FSE S4 younger cancel (tid + cancelled_mask)"
  exit 1
}
Write-Host "  ok store_buffer DeepSpec depth + S4 cancel"

$ld = Get-Content "core/load_unit.sv" -Raw
if ($ld -notmatch "cancelled_mask_i") {
  Write-Error "load_unit must accept cancelled_mask for S4 younger flush"
  exit 1
}
Write-Host "  ok load_unit S4 cancel"

$sb = Get-Content "core/scoreboard.sv" -Raw
if ($sb -notmatch "resolved_branch_i\.hart_id") {
  Write-Error "scoreboard must filter cancel by resolved_branch.hart_id (FSE S5)"
  exit 1
}
Write-Host "  ok S5 hart-filtered cancel"

$ckpt = Get-Content "core/frontend/g6lc_bp_ckpt.sv" -Raw
if ($ckpt -notmatch "hart_i") {
  Write-Error "g6lc_bp_ckpt must take hart_i (FSE S5 banked ckpt)"
  exit 1
}
Write-Host "  ok S5 banked BP ckpt"

# --- Real commands (not just file existence) ---
Write-Host "  running lint: cv64a6_spec_deep ..."
& .\build.ps1 verify --lint --target cv64a6_spec_deep
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "  running lint: g6lc64_ooo ..."
& .\build.ps1 verify --lint --target g6lc64_ooo
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "[spec-deep-path] PASS"
exit 0
