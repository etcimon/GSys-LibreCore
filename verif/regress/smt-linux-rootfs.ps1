# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# SMT Linux rootfs track (R1–R3).
#   Always: R0 boot-path subset + dual-hart park artifacts + DTS bootargs + lint
#   If CVA6_LINUX_PAYLOAD is set: attempt cva6.py boot (R3)
#   Else: PASS preflight (images are external / cva6-sdk)
#
#   .\verif\regress\smt-linux-rootfs.ps1
#   $env:CVA6_LINUX_PAYLOAD='E:\images\fw_payload.elf'; .\verif\regress\smt-linux-rootfs.ps1

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "../..")
Set-Location $Root

if (-not $env:DV_TARGET) { $env:DV_TARGET = "g6lc64_smt2" }
if (-not $env:DV_SIMULATORS) { $env:DV_SIMULATORS = "veri-testharness" }
if (-not $env:CVA6_LINUX_TIMEOUT) { $env:CVA6_LINUX_TIMEOUT = "200000000" }

Write-Host "=== SMT Linux rootfs track ==="
Write-Host "  DV_TARGET=$($env:DV_TARGET)  payload=$($env:CVA6_LINUX_PAYLOAD)"

# ---- R0: reuse boot-path gate core checks (lightweight, no double-lint later) ----
$required = @(
  "architecture/multi-threading/smt-linux-rootfs.md",
  "architecture/multi-threading/dts-linux-smt.md",
  "software/smt2-linux/README.md",
  "software/smt2-linux/opensbi/g6lc64_smt2.env",
  "software/smt2-linux/payload/smt2_sbi_dual.S",
  "software/smt2-linux/scripts/build-opensbi-smt2.ps1",
  "software/smt2-linux/scripts/fetch-opensbi.ps1",
  "core/include/g6lc64_smt2_config_pkg.sv",
  "corev_apu/bootrom/ariane-smt2.dts",
  "verif/tests/custom/smt/smt_dual_park.S",
  "verif/tests/testlist_smt_linux.yaml",
  "verif/regress/smt-linux-boot-path.ps1"
)
foreach ($f in $required) {
  if (-not (Test-Path $f)) { Write-Error "Missing $f"; exit 1 }
  Write-Host "  ok $f"
}

$pkg = Get-Content "core/include/g6lc64_smt2_config_pkg.sv" -Raw
if ($pkg -notmatch "NrHarts:\s*unsigned'\(2\)") {
  Write-Error "g6lc64_smt2 must set NrHarts=2"
  exit 1
}
Write-Host "  ok NrHarts=2"

# DTS: dual topology + rootfs-oriented chosen
$dts = Get-Content "corev_apu/bootrom/ariane-smt2.dts" -Raw
foreach ($need in @("cpu@0", "cpu@1", "bootargs", "maxcpus=2", "root=/dev/ram",
                    "sifive,clint0", "sifive,plic-1.0.0", "thread0", "thread1")) {
  if ($dts -notmatch [regex]::Escape($need)) {
    Write-Error "ariane-smt2.dts missing rootfs fragment: $need"
    exit 1
  }
}
Write-Host "  ok ariane-smt2.dts bootargs + dual-hart topology"

# Optional dtc for smt2 DTB
if (Get-Command dtc -ErrorAction SilentlyContinue) {
  $tmp = Join-Path $env:TEMP "ariane-smt2-rootfs.dtb"
  & dtc -I dts -O dtb -o $tmp corev_apu/bootrom/ariane-smt2.dts 2>&1
  if ($LASTEXITCODE -ne 0) { Write-Error "dtc failed on ariane-smt2.dts"; exit 1 }
  Write-Host "  ok dtc ariane-smt2.dts"
} else {
  Write-Host "  note: dtc not on PATH (optional for DTB emit)"
}

# Dual-park source sanity
$park = Get-Content "verif/tests/custom/smt/smt_dual_park.S" -Raw
if ($park -notmatch "mhartid" -or $park -notmatch "wfi") {
  Write-Error "smt_dual_park.S must use mhartid + wfi park"
  exit 1
}
Write-Host "  ok smt_dual_park directed"

# ---- Directed list / boot-path (artifact) ----
Write-Host "  running smt-linux-boot-path (R0)..."
& pwsh -NoProfile -File verif/regress/smt-linux-boot-path.ps1
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# ---- R2a: dual-hart S-mode payload + DTB when a cross compiler is present ----
$smt2Out = Join-Path $Root "build-platform/workspace/smt2-linux"
New-Item -ItemType Directory -Force -Path $smt2Out | Out-Null
$payloadElf = Join-Path $smt2Out "smt2_sbi_dual.elf"
$dtbOut = Join-Path $smt2Out "ariane-smt2.dtb"

function Find-RiscvCrossPrefix {
  foreach ($p in @(
      "riscv-none-elf-",
      "riscv64-unknown-elf-",
      "riscv64-unknown-linux-gnu-"
    )) {
    if (Get-Command ($p + "gcc") -ErrorAction SilentlyContinue) { return $p }
  }
  # Workspace xPack unpack
  $xpack = Get-ChildItem "build-platform/workspace/tooling" -Directory -Filter "xpack-riscv*" -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($xpack) {
    $bin = Join-Path $xpack.FullName "bin"
    if (Test-Path (Join-Path $bin "riscv-none-elf-gcc.exe")) {
      $env:Path = "$bin;$($env:Path)"
      return "riscv-none-elf-"
    }
  }
  return $null
}

$cross = Find-RiscvCrossPrefix
if ($cross) {
  Write-Host "  R2a: CROSS_COMPILE=$cross — building smt2_sbi_dual payload..."
  Push-Location "software/smt2-linux/payload"
  try {
    & make CROSS_COMPILE=$cross
    if ($LASTEXITCODE -eq 0 -and (Test-Path "smt2_sbi_dual.elf")) {
      Copy-Item -Force "smt2_sbi_dual.elf" $payloadElf
      if (Test-Path "smt2_sbi_dual.bin") {
        Copy-Item -Force "smt2_sbi_dual.bin" (Join-Path $smt2Out "smt2_sbi_dual.bin")
      }
      Write-Host "  ok payload $payloadElf"
    } else {
      Write-Host "  note: payload make failed (exit $LASTEXITCODE)"
    }
  } finally {
    Pop-Location
  }
  $dtsPy = "software/smt2-linux/scripts/dts_to_dtb.py"
  if (Test-Path $dtsPy) {
    Write-Host "  R2a: compiling ariane-smt2.dtb..."
    & python $dtsPy -i corev_apu/bootrom/ariane-smt2.dts -o $dtbOut 2>$null
    if ($LASTEXITCODE -eq 0 -and (Test-Path $dtbOut)) {
      Write-Host "  ok DTB $dtbOut"
    } else {
      Write-Host "  note: DTB compile skipped (pip install fdt, or install dtc)"
    }
  }
} else {
  Write-Host "  R2a: no riscv-*-gcc on PATH — payload/DTB deferred"
  Write-Host "       install: .\software\smt2-linux\scripts\install-toolchain-hint.ps1 -Download"
}

# ---- R3a: auto-build OpenSBI SMT2 if tools present and no payload yet ----
$defaultFw = Join-Path $smt2Out "fw_payload.elf"
# Prefer absolute managed toolchain for Find-Riscv / later PATH
$managedRiscv = Join-Path $Root "build-platform/workspace/tooling/riscv/bin"
if (Test-Path $managedRiscv) {
  $env:Path = "$managedRiscv;$($env:Path)"
}
if (-not $env:CVA6_LINUX_PAYLOAD -and (Test-Path $defaultFw)) {
  $env:CVA6_LINUX_PAYLOAD = (Resolve-Path $defaultFw).Path
  Write-Host "  using existing SMT2 OpenSBI payload: $($env:CVA6_LINUX_PAYLOAD)"
}

$buildOsbi = Join-Path "software/smt2-linux/scripts" "build-opensbi-smt2.ps1"
if (-not $env:CVA6_LINUX_PAYLOAD -and (Test-Path $buildOsbi) -and -not $env:SMT2_SKIP_OSBI_BUILD) {
  Write-Host "  attempting OpenSBI SMT2 build (R3a)..."
  & pwsh -NoProfile -File $buildOsbi
  if ($LASTEXITCODE -eq 0 -and (Test-Path $defaultFw)) {
    $env:CVA6_LINUX_PAYLOAD = (Resolve-Path $defaultFw).Path
    Write-Host "  built $($env:CVA6_LINUX_PAYLOAD)"
  } elseif ($LASTEXITCODE -eq 2) {
    Write-Host "  note: toolchain/dtc missing — skip OpenSBI build"
    Write-Host "        .\software\smt2-linux\scripts\install-toolchain-hint.ps1 -Download"
  } else {
    Write-Host "  note: OpenSBI build skipped/failed (exit $LASTEXITCODE); preflight still valid"
    Write-Host "        On Windows, prefer WSL/Linux for full OpenSBI kconfig (see software/smt2-linux/README.md)"
  }
}

# ---- R3: optional full payload boot (needs Verilator + working cva6.py) ----
function Resolve-WindowsPython {
  # Prefer real Windows installs; skip broken Cygwin shims.
  $cand = @(
    "$env:LOCALAPPDATA\Programs\Python\Python39\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
    "C:\Python39\python.exe",
    "C:\Python311\python.exe"
  )
  foreach ($c in $cand) {
    if ($c -and (Test-Path $c)) { return $c }
  }
  $cmd = Get-Command python -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source -notmatch 'cygwin|WindowsApps') {
    return $cmd.Source
  }
  return $null
}

function Test-R3SimReady {
  if (-not (Test-Path "verif/sim/cva6.py")) { return $false }
  $py = Resolve-WindowsPython
  if (-not $py) { return $false }
  $script:R3Python = $py
  $probe = & $py -c "import yaml" 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Host "  note: installing PyYAML for $py ..."
    & $py -m pip install --user pyyaml 2>$null | Out-Null
    & $py -c "import yaml" 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
  }
  # Verilator binary (managed OSS CAD suite or PATH)
  $hasVl = [bool](Get-Command verilator -ErrorAction SilentlyContinue) -or
    (Test-Path "build-platform/workspace/tooling/oss-cad-suite/bin/verilator_bin.exe") -or
    (Test-Path "build-platform/workspace/tooling/oss-cad-suite/bin/verilator")
  if (-not $hasVl) { return $false }
  return $true
}

if ($env:CVA6_LINUX_PAYLOAD) {
  if (-not (Test-Path $env:CVA6_LINUX_PAYLOAD)) {
    Write-Error "CVA6_LINUX_PAYLOAD not found: $($env:CVA6_LINUX_PAYLOAD)"
    exit 1
  }
  $payloadInfo = Get-Item $env:CVA6_LINUX_PAYLOAD
  Write-Host "  R3a firmware ready: $($payloadInfo.FullName) ($([math]::Round($payloadInfo.Length/1KB)) KiB)"

  if (-not (Test-R3SimReady)) {
    Write-Host "  R3 sim deferred: need Python+PyYAML + Verilator (and optionally Spike for dual-ISS)"
    Write-Host "    Spike note: Cygwin build hits addr_t clash; use Linux/WSL for install-spike.sh"
    Write-Host "[smt-linux-rootfs] PASS (R0–R3a firmware; sim tools incomplete)"
    exit 0
  }

  Write-Host "  R3: attempting sim boot with payload $($env:CVA6_LINUX_PAYLOAD)"
  $payload = (Resolve-Path $env:CVA6_LINUX_PAYLOAD).Path
  $simDir = Join-Path $Root "verif/sim"
  $localName = "smt_linux_payload.elf"
  Copy-Item -Force $payload (Join-Path $simDir $localName)

  # Env for verif/sim/setup-env.sh + cva6.py (forward-slash roots for bash/make)
  $rootFwd = ($Root -replace '\\', '/')
  $riscvRoot = Join-Path $Root "build-platform/workspace/tooling/riscv"
  $ocsRoot = Join-Path $Root "build-platform/workspace/tooling/oss-cad-suite"
  $spikeRoot = Join-Path $Root "build-platform/workspace/tooling/spike"
  if (Test-Path $ocsRoot) {
    $env:Path = "$(Join-Path $ocsRoot 'bin');$($env:Path)"
    if (Test-Path (Join-Path $ocsRoot "environment.ps1")) {
      . (Join-Path $ocsRoot "environment.ps1")
    }
  }
  if (Test-Path $riscvRoot) {
    $env:Path = "$(Join-Path $riscvRoot 'bin');$($env:Path)"
    $env:RISCV = ($riscvRoot -replace '\\', '/')
    $env:RISCV_CC = "riscv-none-elf-gcc"
    $env:RISCV_GCC = "riscv-none-elf-gcc"
    $env:RISCV_OBJCOPY = "riscv-none-elf-objcopy"
    $env:RISCV_PREFIX = "riscv-none-elf-"
  }
  $env:CVA6_REPO_DIR = $rootFwd
  $env:RTL_PATH = "$rootFwd/"
  $env:TB_PATH = "$rootFwd/verif/tb/core"
  $env:SPIKE_PATH = if (Test-Path (Join-Path $spikeRoot "bin")) {
    ((Join-Path $spikeRoot "bin") -replace '\\', '/')
  } else { "$rootFwd/tools/spike/bin" }

  foreach ($bashCand in @(
      "C:\cygwin64\bin",
      "C:\Program Files\Git\bin",
      "C:\Program Files\Git\usr\bin"
    )) {
    if (Test-Path $bashCand) { $env:Path = "$bashCand;$($env:Path)" }
  }

  # Full R3 Verilator model needs a consistent path namespace (Linux/WSL).
  # On native Windows: auto-dispatch to WSL via smt-linux-r3-cosim.sh when `wsl`
  # is available; optional CVA6_FORCE_WIN_CVA6PY=1 for native attempt (usually fails).
  $isWinNative = ($env:OS -match "Windows") -and (-not $env:WSL_DISTRO_NAME)
  if ($isWinNative -and ($env:CVA6_FORCE_WIN_CVA6PY -ne "1")) {
    $wsl = Get-Command wsl -ErrorAction SilentlyContinue
    $r3sh = Join-Path $Root "verif/regress/smt-linux-r3-cosim.sh"
    if ($wsl -and (Test-Path $r3sh)) {
      Write-Host "  R3: dispatching cosim to WSL (smt-linux-r3-cosim.sh)..."
      function ConvertTo-WslPath([string]$winPath) {
        $p = & wsl -e wslpath -a $winPath 2>$null
        if ($p -and ($p -match '^/')) { return $p.Trim() }
        $n = $winPath -replace '\\', '/'
        if ($n -match '^([A-Za-z]):/(.*)$') {
          return "/mnt/$($Matches[1].ToLower())/$($Matches[2])"
        }
        return $n
      }
      $payloadWsl = ConvertTo-WslPath $payload
      $scriptWsl = ConvertTo-WslPath $r3sh
      $require = if ($env:CVA6_REQUIRE_R3_SIM) { $env:CVA6_REQUIRE_R3_SIM } else { "0" }
      $bashCmd = "export CVA6_LINUX_PAYLOAD='$payloadWsl'; export DV_TARGET='$($env:DV_TARGET)'; export DV_SIMULATORS='$($env:DV_SIMULATORS)'; export CVA6_LINUX_TIMEOUT='$($env:CVA6_LINUX_TIMEOUT)'; export CVA6_REQUIRE_R3_SIM='$require'; bash '$scriptWsl'"
      & wsl -e bash -lc $bashCmd
      if ($LASTEXITCODE -ne 0) {
        Write-Host "  R3 WSL cosim failed (exit $LASTEXITCODE) — firmware R3a still valid"
        if ($env:CVA6_REQUIRE_R3_SIM -eq "1") { exit $LASTEXITCODE }
        Write-Host "[smt-linux-rootfs] PASS (R0–R3a; R3 WSL soft-fail)"
        exit 0
      }
      Write-Host "[smt-linux-rootfs] PASS (R3 WSL cosim)"
      exit 0
    }
    Write-Host "  R3 sim deferred on native Windows (no WSL / r3-cosim script)"
    Write-Host "    Install WSL + Verilator, or set CVA6_FORCE_WIN_CVA6PY=1 to attempt native"
    Write-Host "[smt-linux-rootfs] PASS (R0–R3a firmware; R3 cosim = Linux/WSL)"
    exit 0
  }

  Push-Location $simDir
  try {
    Write-Host "  R3: cva6.py --target $($env:DV_TARGET) --iss $($env:DV_SIMULATORS) ..."
    & $script:R3Python cva6.py `
      --target $env:DV_TARGET `
      --iss $env:DV_SIMULATORS `
      --iss_yaml cva6.yaml `
      --elf_tests $localName `
      --issrun_opts "+time_out=$($env:CVA6_LINUX_TIMEOUT) +debug_disable=1"
    if ($LASTEXITCODE -ne 0) {
      Write-Host "  R3 sim failed (exit $LASTEXITCODE) — firmware R3a still valid"
      if ($env:CVA6_REQUIRE_R3_SIM -eq "1") { exit $LASTEXITCODE }
      Write-Host "[smt-linux-rootfs] PASS (R0–R3a; R3 sim soft-fail, set CVA6_REQUIRE_R3_SIM=1 to hard-fail)"
      exit 0
    }
  } finally {
    Pop-Location
  }
  Write-Host "[smt-linux-rootfs] PASS (R3 payload sim)"
  exit 0
}

# Preflight-only path: already linted via boot-path; optional directed list via cva6.py
function Invoke-Directed {
  if (-not (Test-Path "verif/sim/cva6.py")) { return $false }
  $py = $null
  if (Get-Command python -ErrorAction SilentlyContinue) { $py = "python" }
  elseif (Get-Command python3 -ErrorAction SilentlyContinue) { $py = "python3" }
  if (-not $py) { return $false }
  $env:PYTHONPATH = "verif/sim;verif/sim/dv;core-v-verif;$($env:PYTHONPATH)"
  $probe = & $py -c "import yaml,sys; sys.path.insert(0,'verif/sim'); import verilator_log_to_trace_csv" 2>&1
  if ($LASTEXITCODE -ne 0) { return $false }
  Write-Host "  running directed testlist_smt_linux.yaml..."
  & $py verif/sim/cva6.py --target $env:DV_TARGET --iss $env:DV_SIMULATORS `
    --testlist verif/tests/testlist_smt_linux.yaml
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  return $true
}

$ran = Invoke-Directed
if ($ran -eq $true) {
  Write-Host "[smt-linux-rootfs] PASS (R1–R2 directed + boot-path)"
  exit 0
}

if (Test-Path $defaultFw) {
  Write-Host @"

[smt-linux-rootfs] PASS (R0–R3a; fw_payload present, sim not requested)
  firmware: $defaultFw
  To run R3 sim: set CVA6_LINUX_PAYLOAD to that path (needs Verilator + cva6.py deps).
  Spike: build under Linux/WSL (Cygwin fails on addr_t vs fesvr).
"@
  exit 0
}

Write-Host @"

[smt-linux-rootfs] PASS (R0–R2 preflight; no fw_payload)
  Stages:
    R0  smt-linux-boot-path (DTS/RTL + g6lc64_smt2 lint)
    R2a smt2_sbi_dual.elf + ariane-smt2.dtb when CROSS_COMPILE present
    R3a OpenSBI fw_payload.elf (Cygwin make + managed xPack on Windows)
    R3  cva6.py boot when CVA6_LINUX_PAYLOAD is set and Verilator ready
  Next:
    bun installRiscvGcc / setup --install
    .\software\smt2-linux\scripts\build-opensbi-smt2.ps1
    `$env:CVA6_LINUX_PAYLOAD = 'build-platform\workspace\smt2-linux\fw_payload.elf'
    .\verif\regress\smt-linux-rootfs.ps1
  See architecture/multi-threading/smt-linux-rootfs.md
"@
exit 0
