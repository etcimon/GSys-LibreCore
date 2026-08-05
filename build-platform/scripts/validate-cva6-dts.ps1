# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# validate-cva6-dts.ps1 — Cross-check CVA6 .dts files against the fetched Linux
# RISC-V bindings + reference DTS under build-platform/workspace/linux-dts/.
# Does not invent properties: only reports binding/reference mismatches.
#
# Prerequisite (minimal Linux pull — sparse, not full kernel):
#   .\build-platform\scripts\fetch-linux-dts.ps1
#
# Usage:
#   .\build-platform\scripts\validate-cva6-dts.ps1
#   .\build-platform\scripts\validate-cva6-dts.ps1 -Dts corev_apu/bootrom/ariane-smt2.dts

[CmdletBinding()]
param(
  [string]$LinuxDtsRoot,
  [string[]]$Dts
)

$ErrorActionPreference = "Stop"
$repo = Resolve-Path (Join-Path $PSScriptRoot "../..")
if (-not $LinuxDtsRoot) {
  $LinuxDtsRoot = Join-Path $repo "build-platform/workspace/linux-dts"
}
$LinuxDtsRoot = [System.IO.Path]::GetFullPath($LinuxDtsRoot)

if (-not (Test-Path (Join-Path $LinuxDtsRoot "Documentation/devicetree/bindings/riscv/cpus.yaml"))) {
  Write-Error "Linux DTS tree missing at $LinuxDtsRoot — run fetch-linux-dts.ps1 first."
  exit 2
}

$extYaml = Get-Content (Join-Path $LinuxDtsRoot "Documentation/devicetree/bindings/riscv/extensions.yaml") -Raw
$cpuYaml = Get-Content (Join-Path $LinuxDtsRoot "Documentation/devicetree/bindings/riscv/cpus.yaml") -Raw
$clintYaml = Get-Content (Join-Path $LinuxDtsRoot "Documentation/devicetree/bindings/timer/sifive,clint.yaml") -Raw
$plicYaml = Get-Content (Join-Path $LinuxDtsRoot "Documentation/devicetree/bindings/interrupt-controller/sifive,plic-1.0.0.yaml") -Raw

# Tokens accepted by extensions.yaml (const: lines)
$legalExt = [regex]::Matches($extYaml, '(?m)^\s*-\s*const:\s*([a-z0-9]+)\s*$') |
  ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

$defaultDts = @(
  "corev_apu/bootrom/ariane.dts",
  "corev_apu/fpga/src/bootrom/cv64a6.dts.in",
  "corev_apu/fpga/src/bootrom/cv64a6_agilex.dts.in",
  "corev_apu/bootrom/ariane-linux.dts",
  "corev_apu/bootrom/ariane-smt2.dts"
)
if (-not $Dts) { $Dts = $defaultDts }

$fail = 0
$warn = 0

function Report([string]$level, [string]$file, [string]$msg) {
  $script:line = "[$level] ${file}: $msg"
  Write-Host $script:line
  if ($level -eq "FAIL") { $script:fail++ }
  if ($level -eq "WARN") { $script:warn++ }
  if ($level -eq "GAP")  { $script:warn++ }
}

Write-Host "validate-cva6-dts: linux-dts=$LinuxDtsRoot"
if (Test-Path (Join-Path $LinuxDtsRoot ".cva6-dts-manifest")) {
  Get-Content (Join-Path $LinuxDtsRoot ".cva6-dts-manifest") | ForEach-Object { Write-Host "  $_" }
}
Write-Host "legal riscv,isa-extensions tokens loaded: $($legalExt.Count)"
Write-Host "reference: arch/riscv/boot/dts/sifive/fu540-c000.dtsi (+ mpfs.dtsi CLINT)"
Write-Host ""

foreach ($rel in $Dts) {
  $path = Join-Path $repo $rel
  if (-not (Test-Path $path)) {
    Report "WARN" $rel "file not present (skip)"
    continue
  }
  $text = Get-Content $path -Raw
  Write-Host "=== $rel ==="

  # --- cpus / hart ---
  if ($text -notmatch 'device_type\s*=\s*"cpu"') {
    Report "FAIL" $rel "missing device_type = `"cpu`""
  }
  if ($text -notmatch 'compatible\s*=\s*"[^"]*riscv') {
    Report "FAIL" $rel "cpu compatible must contain `"riscv`" (cpus.yaml)"
  }
  # Linux enum does not list eth,ariane — simulator-only form is plain "riscv"
  if ($text -match 'compatible\s*=\s*"eth,\s*ariane"') {
    Report "GAP" $rel "compatible `"eth, ariane`" is NOT in Linux cpus.yaml enum (space also invalid). Use `"riscv`" only, or upstream a vendor ID. Cannot fix Linux enum from this tree."
  } elseif ($text -match 'compatible\s*=\s*"eth,ariane"') {
    Report "GAP" $rel "compatible `"eth,ariane`" is NOT in Linux cpus.yaml enum. Prefer `"riscv`" for schema; vendor string needs Linux upstream."
  }

  if ($text -match 'riscv,isa-base') {
    if ($text -notmatch 'riscv,isa-base\s*=\s*"rv64i"') {
      Report "WARN" $rel "riscv,isa-base present but not rv64i (expected for CVA6-64)"
    }
  } else {
    Report "FAIL" $rel "missing riscv,isa-base (modern cpus.yaml / extensions.yaml; riscv,isa alone is deprecated)"
  }

  # Parse isa-extensions list
  if ($text -match 'riscv,isa-extensions\s*=\s*([^;]+);') {
    $raw = $Matches[1]
    $toks = [regex]::Matches($raw, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
    foreach ($t in $toks) {
      if ($legalExt -notcontains $t) {
        Report "FAIL" $rel "riscv,isa-extensions token `"$t`" not in Linux extensions.yaml"
      }
    }
    foreach ($need in @("i", "m", "a", "f", "d", "c", "zicntr", "zicsr", "zifencei")) {
      if ($toks -notcontains $need -and $text -match 'rv64imafdc') {
        Report "WARN" $rel "baseline rv64imafdc DTS should list extension `"$need`" (see fu540-c000.dtsi)"
      }
    }
  } else {
    Report "FAIL" $rel "missing riscv,isa-extensions"
  }

  if ($text -notmatch 'mmu-type\s*=\s*"riscv,sv39"') {
    Report "WARN" $rel "missing or non-sv39 mmu-type (expected for application-class CVA6)"
  }

  # timebase on /cpus
  if ($text -notmatch 'timebase-frequency') {
    Report "FAIL" $rel "missing cpus/timebase-frequency (required for CLINT timer rate)"
  }

  # Honest L1 line size: CVA6 default LineWidth=128 → 16 B; advertising 64 would lie
  if ($text -match 'i-cache-block-size\s*=\s*<64>' -or $text -match 'd-cache-block-size\s*=\s*<64>') {
    Report "WARN" $rel "L1 *-cache-block-size=64 may disagree with CVA6 LineWidth=128 (16 B). Prefer <16> or omit; CMO uses riscv,cbo*-block-size."
  }

  # --- CLINT ---
  $cpuCount = ([regex]::Matches($text, 'cpu@\d+')).Count
  if ($text -match 'clint@') {
    if ($text -match 'compatible\s*=\s*"riscv,clint0"\s*;' -and $text -notmatch 'sifive,clint0') {
      Report "WARN" $rel "add sifive,clint0 before riscv,clint0 for binding-valid dual-string"
    }
    if ($text -match 'compatible\s*=\s*"sifive,clint0"\s*,\s*"riscv,clint0"') {
      # Deprecated dual form is QEMU-only per sifive,clint.yaml — expected GAP for bare platform
      Report "GAP" $rel "CLINT uses QEMU dual `"sifive,clint0`", `"riscv,clint0`" (deprecated). Chip-specific first string needs product SKU + Linux binding enum."
    }
    if ($text -notmatch 'interrupts-extended') {
      Report "FAIL" $rel "CLINT missing interrupts-extended"
    } else {
      # Count soft/timer pairs: each hart needs MSIP(3) + MTIP(7)
      $clintIrqs = ([regex]::Matches($text, '&CPU\d+_intc\s+\d+')).Count
      # Prefer counting only within clint node if possible
      if ($text -match '(?s)clint@\d+\s*\{(.*?)\}') {
        $clintBody = $Matches[1]
        $clintIrqs = ([regex]::Matches($clintBody, '&CPU\d+_intc\s+\d+')).Count
      }
      $expectClint = 2 * $cpuCount
      if ($cpuCount -gt 0 -and $clintIrqs -ne $expectClint) {
        Report "FAIL" $rel "CLINT interrupts-extended has $clintIrqs cells, expected $expectClint (2 per cpu@ for MSIP+MTIP; see mpfs.dtsi)"
      }
    }
  } else {
    Report "WARN" $rel "no clint@ node"
  }

  # --- PLIC (ignore commented blocks for max-priority / compatible checks) ---
  $plicLive = ($text -match '(?m)^\s*PLIC0:' -or $text -match '(?m)^\s*plic\d*:') -and
              ($text -notmatch 'PLIC needs to be disabled')
  if ($text -match '//\s*PLIC0:' -or $text -match 'PLIC needs to be disabled') {
    Report "GAP" $rel "PLIC is commented out (tandem verification). Linux boot needs PLIC enabled — use ariane-linux.dts / profile DTS, not the tandem bare DTS."
  } elseif ($plicLive -or ($text -match 'interrupt-controller@c000000' -and $text -notmatch '//\s*.*interrupt-controller@c000000')) {
    if ($text -match 'compatible\s*=\s*"riscv,plic0"' -and $text -notmatch 'sifive,plic-1.0.0') {
      Report "WARN" $rel "PLIC should prefer sifive,plic-1.0.0 (riscv,plic0 is legacy/QEMU)"
    }
    if ([regex]::IsMatch($text, '(?m)^\s*riscv,max-priority')) {
      Report "GAP" $rel "riscv,max-priority is not in sifive,plic-1.0.0.yaml; omit for strict binding match"
    }
    # M+S external per hart (11 + 9) — fu540 app harts
    if ($text -match '(?s)interrupt-controller@c000000\s*\{(.*?)\}') {
      $plicBody = $Matches[1]
      $plicCells = ([regex]::Matches($plicBody, '&CPU\d+_intc\s+\d+')).Count
      $expectPlic = 2 * $cpuCount
      if ($cpuCount -gt 0 -and $plicCells -ne $expectPlic) {
        Report "FAIL" $rel "PLIC interrupts-extended has $plicCells cells, expected $expectPlic (M+S external per cpu@)"
      }
    }
  }

  # multi-hart / SMT topology
  if ($rel -match 'smt2' -and $cpuCount -lt 2) {
    Report "FAIL" $rel "SMT2 profile DTS must describe >=2 cpu@ nodes (harts)"
  }
  if ($cpuCount -ge 2 -and $text -notmatch 'cpu-map') {
    Report "WARN" $rel "multi-hart DTS should include cpu-map (see fu540-c000.dtsi topology)"
  }
  if ($rel -match 'smt2') {
    if ($text -notmatch 'thread0' -or $text -notmatch 'thread1') {
      Report "FAIL" $rel "SMT topology should use cpu-map thread0/thread1 under one core (cpus.yaml hart model)"
    }
  }

  # PMU
  if ($text -match 'compatible\s*=\s*"riscv,pmu"') {
    Report "WARN" $rel "riscv,pmu present; confirm binding against full kernel docs (may be outside sparse fetch)"
  }

  Write-Host ""
}

Write-Host "---- summary: FAIL=$fail WARN/GAP=$warn ----"
Write-Host "Reference DTS: arch/riscv/boot/dts/sifive/fu540-c000.dtsi"
Write-Host "Bindings: Documentation/devicetree/bindings/riscv/{cpus,extensions}.yaml"
Write-Host "Full matrix: AGENTS-dts-validation.md §3 + architecture/multi-threading/dts-linux-smt.md"
if ($fail -gt 0) { exit 1 }
exit 0
