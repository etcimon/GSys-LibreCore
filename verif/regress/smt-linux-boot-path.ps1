# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# Complete in-repo gate for SMT Linux boot (NrHarts=2).
# Does not run full Linux (needs OpenSBI + rootfs images); gates DTS + RTL artifacts
# that must be true before a lab boot can succeed.
#
#   .\verif\regress\smt-linux-boot-path.ps1
#   .\build.ps1 verify --lint --target g6lc64_smt2   # optional elaborate

$ErrorActionPreference = "Stop"
Set-Location (Resolve-Path (Join-Path $PSScriptRoot "../.."))

Write-Host "=== SMT Linux boot path gate ==="

$required = @(
  "core/include/g6lc64_smt2_config_pkg.sv",
  "corev_apu/bootrom/ariane-smt2.dts",
  "corev_apu/bootrom/ariane-linux.dts",
  "architecture/multi-threading/dts-linux-smt.md",
  "architecture/multi-threading/smt2-bringup.md",
  "build-platform/scripts/validate-cva6-dts.ps1",
  "build-platform/scripts/fetch-linux-dts.ps1",
  "core/smt/g6lc_smt_csr_bank.sv",
  "corev_apu/tb/ariane_testharness.sv",
  "corev_apu/src/g6lc_cluster.sv",
  "core/cva6.sv"
)
foreach ($f in $required) {
  if (-not (Test-Path $f)) { Write-Error "Missing $f"; exit 1 }
  Write-Host "  ok $f"
}

# Package asserts dual-hart
$pkg = Get-Content "core/include/g6lc64_smt2_config_pkg.sv" -Raw
if ($pkg -notmatch "NrHarts:\s*unsigned'\(2\)") {
  Write-Error "g6lc64_smt2 must set NrHarts=2"
  exit 1
}
if ($pkg -notmatch "NrCores:\s*unsigned'\(1\)") {
  Write-Host "  note: smt2 package NrCores != 1 (CLINT total harts = NrCores*NrHarts)"
}
Write-Host "  ok NrHarts=2 in smt2 package"

# Harness scales CLINT to NR_HARTS
$th = Get-Content "corev_apu/tb/ariane_testharness.sv" -Raw
if ($th -notmatch "NR_HARTS\s*=" -or $th -notmatch "NR_HARTS_PER_CORE") {
  Write-Error "testharness missing NR_HARTS scaling"
  exit 1
}
if ($th -notmatch "NR_CORES\s*\(\s*NR_HARTS\s*\)") {
  Write-Error "CLINT must be parameterized with NR_HARTS (total software harts)"
  exit 1
}
if ($th -notmatch "core_ipi" -or $th -notmatch "core_timer_irq") {
  Write-Error "testharness must map per-hart IPI/timer into cluster"
  exit 1
}
Write-Host "  ok CLINT NR_HARTS + per-hart fanout in testharness"

# CSR bank per-hart IRQ
$csr = Get-Content "core/smt/g6lc_smt_csr_bank.sv" -Raw
if ($csr -notmatch "time_irq_i\[h\]" -or $csr -notmatch "ipi_i\[h\]") {
  Write-Error "smt_csr_bank must wire per-hart time_irq/ipi"
  exit 1
}
Write-Host "  ok per-hart timer/IPI in smt_csr_bank"

# Active-hart IRQ mux for decode (width safety)
$cva6 = Get-Content "core/cva6.sv" -Raw
if ($cva6 -notmatch "irq_active" -or $cva6 -notmatch "irq_i\[smt_active_hart\]") {
  Write-Error "cva6.sv must mux irq_active = irq_i[smt_active_hart] for ID/RVFI"
  exit 1
}
Write-Host "  ok active-hart irq mux in cva6.sv"

# Cluster hart_id_base = c * NrHarts
$cl = Get-Content "corev_apu/src/g6lc_cluster.sv" -Raw
if ($cl -notmatch "c \* \(\(CVA6Cfg\.NrHarts") {
  Write-Error "g6lc_cluster must set hart_id_base = core * NrHarts"
  exit 1
}
Write-Host "  ok cluster hart_id_base scaling"

# DTS structural checks (no linux tree required)
$dts = Get-Content "corev_apu/bootrom/ariane-smt2.dts" -Raw
foreach ($need in @("cpu@0", "cpu@1", "thread0", "thread1", "CPU0_intc", "CPU1_intc",
                    "sifive,clint0", "sifive,plic-1.0.0", "riscv,isa-base", "riscv,isa-extensions",
                    "timebase-frequency", "mmu-type")) {
  if ($dts -notmatch [regex]::Escape($need)) {
    Write-Error "ariane-smt2.dts missing required fragment: $need"
    exit 1
  }
}
# Two MSIP/MTIP and two M/S external pairs
if (($dts | Select-String -Pattern "CPU0_intc 3" -AllMatches).Matches.Count -lt 1 -or
    ($dts | Select-String -Pattern "CPU1_intc 3" -AllMatches).Matches.Count -lt 1) {
  Write-Error "ariane-smt2.dts CLINT must list both harts"
  exit 1
}
Write-Host "  ok ariane-smt2.dts dual-hart topology + CLINT/PLIC fragments"

# Linux DTS validate if tree present (minimal sparse pull)
if (Test-Path "build-platform/workspace/linux-dts/Documentation/devicetree/bindings/riscv/cpus.yaml") {
  Write-Host "  running validate-cva6-dts.ps1 ..."
  & pwsh -File build-platform/scripts/validate-cva6-dts.ps1
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} else {
  Write-Host "  WARN: linux-dts not fetched — run fetch-linux-dts.ps1 for full schema check"
}

# Optional dtc
if (Get-Command dtc -ErrorAction SilentlyContinue) {
  $tmp = Join-Path $env:TEMP "ariane-smt2.dtb"
  & dtc -I dts -O dtb -o $tmp corev_apu/bootrom/ariane-smt2.dts 2>&1
  if ($LASTEXITCODE -ne 0) { Write-Error "dtc failed on ariane-smt2.dts"; exit 1 }
  Write-Host "  ok dtc ariane-smt2.dts -> dtb"
} else {
  Write-Host "  note: dtc not on PATH (install device-tree-compiler for binary DTB)"
}

Write-Host @"

=== Lab Linux boot (after this gate) ===
0. Sparse Linux refs only (already used by validate):
     .\build-platform\scripts\fetch-linux-dts.ps1
1. DTB:
     dtc -I dts -O dtb -o ariane-smt2.dtb corev_apu/bootrom/ariane-smt2.dts
2. Config package: g6lc64_smt2 (NrHarts=2, NrCores=1 → mhartid 0,1)
3. RTL (landed in tree):
     - CLINT NR_HARTS = NrCores×NrHarts (ariane_testharness)
     - Per-bank time_irq/ipi/irq (g6lc_smt_csr_bank)
     - PLIC contexts 2*(c*NH+h)
4. OpenSBI: expected_harts=2, FW_PAYLOAD or FW_JUMP + DTB
5. Linux: maxcpus=2 earlycon=...; /proc/cpuinfo shows harts 0 and 1
6. Optional: taskset -c 0,1 stress-ng --cpu 2

See architecture/multi-threading/dts-linux-smt.md for Unfixable vs done.
"@
# Real command: lint SMT package (always)
Write-Host "  running lint: g6lc64_smt2 ..."
& .\build.ps1 verify --lint --target g6lc64_smt2
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "[smt-linux-boot-path] PASS"
exit 0
