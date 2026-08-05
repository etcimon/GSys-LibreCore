# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Windows companion to opensbi-linux-boot.sh — OpenSBI / Linux boot gate.
#
# Tier A (artifact gate) runs natively. Tier B (functional boot) needs a Spike
# ISS, which on Windows means WSL: this script delegates the boot to the POSIX
# script inside WSL when available, so there is exactly one implementation of
# the boot logic and the console-decode.
#
# Env: OSBI_BOOT_TIMEOUT, OSBI_HARTS, CVA6_REQUIRE_OSBI_BOOT (see the .sh)
$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Set-Location $Root

$require = ($env:CVA6_REQUIRE_OSBI_BOOT -eq '1')

function Fail($msg) { Write-Host "  $msg" -ForegroundColor Red; Write-Host '[opensbi-linux-boot] FAIL'; exit 1 }
function SkipOrPass($msg) {
  Write-Host "  SKIP: $msg" -ForegroundColor Yellow
  if ($require) { Write-Host '[opensbi-linux-boot] FAIL (CVA6_REQUIRE_OSBI_BOOT=1)'; exit 1 }
  Write-Host '  (set CVA6_REQUIRE_OSBI_BOOT=1 to make this a hard failure)'
  Write-Host '[opensbi-linux-boot] PASS (tier A only)'; exit 0
}

Write-Host '=== OpenSBI / Linux boot gate (GSys LibreCore) ==='
Write-Host '--- A. artifact gate'

$required = @(
  'software/smt2-linux/Makefile',
  'software/smt2-linux/opensbi/g6lc64_smt2.env',
  'software/smt2-linux/payload/smt2_sbi_dual.S',
  'software/smt2-linux/payload/link.ld',
  'software/smt2-linux/scripts/build-opensbi-smt2.ps1',
  'software/smt2-linux/scripts/dts_to_dtb.py',
  'corev_apu/bootrom/ariane-smt2.dts',
  'corev_apu/bootrom/ariane-linux.dts',
  'core/include/g6lc64_smt2_config_pkg.sv'
)
foreach ($f in $required) {
  if (-not (Test-Path $f)) { Fail "MISSING $f" }
  Write-Host "  ok $f"
}

$payload = Get-Content 'software/smt2-linux/payload/smt2_sbi_dual.S' -Raw
foreach ($m in @('SMT2-OSBI: boot hart', 'SMT2-OSBI-OK')) {
  if ($payload -notmatch [regex]::Escape($m)) { Fail "payload lost marker: $m" }
  Write-Host "  ok payload marker: $m"
}

$pkg = Get-Content 'core/include/g6lc64_smt2_config_pkg.sv' -Raw
if ($pkg -notmatch "NrHarts:\s*unsigned'\(2\)") { Fail 'g6lc64_smt2 must set NrHarts=2' }
Write-Host '  ok NrHarts=2 in g6lc64_smt2 package'

# The eth,ariane fallback compatible string is a Linux ABI (AGENTS-branding.md §4).
$dts = Get-Content 'corev_apu/bootrom/ariane-smt2.dts' -Raw
if ($dts -notmatch 'eth,ariane') {
  Fail 'ariane-smt2.dts lost the eth,ariane fallback compatible string (Linux ABI; never substitute)'
}
Write-Host '  ok DTS retains eth,ariane fallback compatible'

Write-Host '--- B. functional boot'

$wsl = Get-Command wsl -ErrorAction SilentlyContinue
if (-not $wsl) { SkipOrPass 'no WSL — Spike is a Linux ELF; tier B needs WSL on Windows' }

# Translate E:\cva6 -> /mnt/e/cva6
$p = $Root.Path
$drive = $p.Substring(0,1).ToLower()
$wslPath = "/mnt/$drive" + ($p.Substring(2) -replace '\\','/')

$envPrefix = ''
foreach ($v in @('OSBI_BOOT_TIMEOUT','OSBI_HARTS','CVA6_REQUIRE_OSBI_BOOT','SPIKE')) {
  $val = [Environment]::GetEnvironmentVariable($v)
  if ($val) { $envPrefix += "$v='$val' " }
}

Write-Host "  delegating to WSL: $wslPath/verif/regress/opensbi-linux-boot.sh"
& wsl bash -c "cd '$wslPath' && ${envPrefix}bash verif/regress/opensbi-linux-boot.sh"
exit $LASTEXITCODE
