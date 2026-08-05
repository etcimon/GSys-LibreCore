# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Build OpenSBI PLATFORM=generic for CVA6 SMT2 with ariane-smt2.dtb and dual-hart payload.
#   .\software\smt2-linux\scripts\build-opensbi-smt2.ps1
#   .\software\smt2-linux\scripts\build-opensbi-smt2.ps1 -Linux
#   $env:LINUX_IMAGE='path\to\Image'; .\software\smt2-linux\scripts\build-opensbi-smt2.ps1 -Linux

param(
  [switch]$Linux,
  [switch]$SkipFetch
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

Ensure-Dir $Out

if (-not $SkipFetch) {
  & (Join-Path $PSScriptRoot "fetch-opensbi.ps1")
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$cc = Find-CrossCompile
if (-not $cc) {
  Write-Error @"
No RISC-V cross compiler on PATH.
Install one of:
  - xPack riscv-none-elf-gcc (https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases)
  - riscv64-unknown-elf-gcc
Then re-run. Optional: place under build-platform/workspace/tooling/
"@
  exit 2
}
$env:CROSS_COMPILE = $cc
Write-Host "[build-opensbi-smt2] CROSS_COMPILE=$cc"

# --- DTB (system dtc or Python fdt fallback) ---
$dtb = Join-Path $Out "ariane-smt2.dtb"
if (-not (Test-Path $DtsSrc)) { Write-Error "Missing DTS $DtsSrc"; exit 1 }
$dtsPy = Join-Path $Smt2Root "scripts/dts_to_dtb.py"
& python $dtsPy -i $DtsSrc -o $dtb
if ($LASTEXITCODE -ne 0) {
  Write-Error "DTB compile failed (install dtc or: pip install fdt)"
  exit 2
}
Write-Host "[build-opensbi-smt2] DTB $dtb"

# --- S-mode dual-hart payload ---
$payloadElf = Join-Path $Out "smt2_sbi_dual.elf"
$payloadBin = Join-Path $Out "smt2_sbi_dual.bin"
Push-Location $PayloadDir
try {
  & make clean 2>$null
  & make CROSS_COMPILE=$cc
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  Copy-Item -Force "smt2_sbi_dual.elf" $payloadElf
  if (-not (Test-Path "smt2_sbi_dual.bin")) {
    Write-Error "payload bin missing"
    exit 1
  }
  Copy-Item -Force "smt2_sbi_dual.bin" $payloadBin
} finally {
  Pop-Location
}
Write-Host "[build-opensbi-smt2] payload $payloadBin"

# --- Payload selection (OpenSBI wants a raw binary for FW_PAYLOAD_PATH) ---
$payloadPath = $payloadBin
if ($Linux -or $env:LINUX_IMAGE) {
  $img = $env:LINUX_IMAGE
  if (-not $img) {
    $cand = @(
      (Join-Path $Out "Image"),
      (Join-Path $Out "linux/arch/riscv/boot/Image")
    )
    foreach ($c in $cand) { if (Test-Path $c) { $img = $c; break } }
  }
  if (-not $img -or -not (Test-Path $img)) {
    Write-Error "Linux Image not found. Set LINUX_IMAGE= or place Image under $Out"
    exit 1
  }
  $payloadPath = (Resolve-Path $img).Path
  Write-Host "[build-opensbi-smt2] Linux payload $payloadPath"
}

# --- OpenSBI (Unix shell required: Git Bash / MSYS / Linux) ---
$src = $env:OPENSBI_SRC
if (-not $src -or -not (Test-Path $src)) {
  $src = Join-Path $Out "opensbi"
  $env:OPENSBI_SRC = $src
}
if (-not (Test-Path $src)) {
  Write-Error "OpenSBI source missing at $src — run fetch-opensbi.ps1 first (or drop -SkipFetch)"
  exit 2
}
$buildDir = Join-Path $Out "opensbi-build"
Ensure-Dir $buildDir

# Soften PIE requirement for bare-metal xPack (riscv-none-elf lacks -pie)
$patchPy = Join-Path $Smt2Root "scripts/patch_opensbi_nopie.py"
$wrapPy = Join-Path $Smt2Root "scripts/wrap_pie_flags.py"
if (Test-Path $patchPy) {
  & python $patchPy (Join-Path $src "Makefile")
  if (Test-Path $wrapPy) { & python $wrapPy (Join-Path $src "Makefile") }
  Write-Host "[build-opensbi-smt2] non-PIE Makefile patch applied"
}

# Prefer a bash that has both `make` and a consistent path mount for find(1).
# Git Bash often lacks make; Cygwin has make but needs /cygdrive paths.
# Strategy: Cygwin if present (make available), else Git Bash (user may install make).
$bash = $null
$bashFlavor = "other"
$cygBash = "C:\cygwin64\bin\bash.exe"
if (Test-Path $cygBash) {
  # Verify make is available under Cygwin
  $hasMake = & $cygBash -lc "command -v make" 2>$null
  if ($hasMake) {
    $bash = $cygBash
    $bashFlavor = "cygwin"
  }
}
if (-not $bash) {
  foreach ($c in @(
      "C:\Program Files\Git\bin\bash.exe",
      "C:\Program Files\Git\usr\bin\bash.exe",
      "${env:ProgramFiles}\Git\bin\bash.exe",
      "${env:LocalAppData}\Programs\Git\bin\bash.exe"
    )) {
    if ($c -and (Test-Path $c)) { $bash = $c; $bashFlavor = "git"; break }
  }
}
if (-not $bash) {
  $cmd = Get-Command bash -ErrorAction SilentlyContinue
  if ($cmd) {
    $bash = $cmd.Source
    if ($bash -match 'cygwin') { $bashFlavor = "cygwin" }
  }
}
if (-not $bash) {
  Write-Error "OpenSBI build needs Cygwin bash+make or Git Bash with make on PATH."
  exit 2
}
Write-Host "[build-opensbi-smt2] bash=$bash flavor=$bashFlavor"

function Convert-ToUnixPath([string]$winPath) {
  if ([string]::IsNullOrWhiteSpace($winPath)) {
    throw "Convert-ToUnixPath: empty path"
  }
  $full = if (Test-Path $winPath) {
    (Resolve-Path $winPath).Path
  } else {
    [System.IO.Path]::GetFullPath($winPath)
  }
  $p = $full -replace '\\', '/'
  if ($p -match '^([A-Za-z]):/(.*)$') {
    $drive = $Matches[1].ToLower()
    $rest = $Matches[2]
    # Cygwin find/make expect /cygdrive/<d>/...; Git Bash accepts /<d>/...
    if ($bashFlavor -eq "cygwin") {
      return "/cygdrive/$drive/$rest"
    }
    return "/$drive/$rest"
  }
  return $p
}

# Prefer toolchain bin on PATH for bash (also search managed workspace/tooling/riscv)
$gccCmd = Get-Command "${cc}gcc" -ErrorAction SilentlyContinue
if (-not $gccCmd) { $gccCmd = Get-Command "${cc}gcc.exe" -ErrorAction SilentlyContinue }
if (-not $gccCmd) {
  $managed = Join-Path $RepoRoot "build-platform/workspace/tooling/riscv/bin/${cc}gcc.exe"
  if (Test-Path $managed) {
    $env:Path = "$(Split-Path $managed -Parent);$($env:Path)"
    $gccCmd = Get-Command "${cc}gcc.exe" -ErrorAction SilentlyContinue
  }
}
$gccDirUnix = ""
if ($gccCmd) {
  $gccDir = $gccCmd.DirectoryName
  if (-not $gccDir -and $gccCmd.Source) {
    $gccDir = Split-Path -Parent $gccCmd.Source
  }
  if (-not $gccDir) {
    Write-Error "Cannot resolve directory for ${cc}gcc ($($gccCmd | Out-String))"
    exit 2
  }
  $gccDirUnix = Convert-ToUnixPath $gccDir
} else {
  Write-Error "Cannot locate ${cc}gcc for OpenSBI bash make"
  exit 2
}

Write-Host "[build-opensbi-smt2] paths: src=$src build=$buildDir dtb=$dtb pay=$payloadPath gccdir=$gccDir"
$srcU = Convert-ToUnixPath $src
$buildU = Convert-ToUnixPath $buildDir
$dtbU = Convert-ToUnixPath $dtb
$payU = Convert-ToUnixPath $payloadPath

# Cygwin + Windows xPack: inject path-translating wrappers so cc1.exe sees C:/...
$crossWrapU = ""
if ($bashFlavor -eq "cygwin") {
  $wrapDir = Join-Path $Out "cross-wrap"
  Ensure-Dir $wrapDir
  $wrapSh = Join-Path $Smt2Root "scripts/riscv-none-elf-gcc-cygwrap.sh"
  $wrapShU = Convert-ToUnixPath $wrapSh
  $realBinU = $gccDirUnix
  $tools = @(
    "gcc", "g++", "cpp", "as", "ar", "ld", "objcopy", "objdump", "nm",
    "ranlib", "readelf", "size", "strip", "gcc-ar", "gcc-nm", "gcc-ranlib"
  )
  foreach ($t in $tools) {
    $name = "${cc}$t"
    $dest = Join-Path $wrapDir $name
    $body = "#!/usr/bin/env bash`nexport REAL_CROSS_BIN='$realBinU/$name.exe'`nexec bash '$wrapShU' `"`$@`"`n"
    [System.IO.File]::WriteAllText($dest, $body.Replace("`r`n", "`n"))
  }
  $crossWrapU = Convert-ToUnixPath $wrapDir
  & $bash -lc "chmod +x '$crossWrapU'/* '$wrapShU'"
  Write-Host "[build-opensbi-smt2] cygwin cross-wrap → $wrapDir"
}

# MinGW as (.incbin) cannot open /cygdrive paths — use C:/... for payload+FDT
# when driving Windows xPack from Cygwin.
$payMake = $payU
$dtbMake = $dtbU
if ($bashFlavor -eq "cygwin") {
  $payMake = ((Resolve-Path $payloadPath).Path -replace '\\', '/')
  $dtbMake = ((Resolve-Path $dtb).Path -replace '\\', '/')
}

Write-Host "[build-opensbi-smt2] bash make PLATFORM=generic FW_TEXT_START=0x80000000 ..."
Write-Host "  src=$srcU"
Write-Host "  payload=$payMake"
Write-Host "  fdt=$dtbMake"
Write-Host "  gcc=$gccDirUnix"

# Under Cygwin: make/find from Cygwin; CROSS_COMPILE points at wrappers.
# Under Git Bash: prefer /usr/bin and strip cygwin from PATH.
$pathBootstrap = if ($bashFlavor -eq "cygwin" -and $crossWrapU) {
  "export PATH='$crossWrapU':'$gccDirUnix':/usr/bin:/bin:`$PATH`nexport CROSS_COMPILE='$crossWrapU/$cc'"
} elseif ($bashFlavor -eq "cygwin") {
  "export PATH='$gccDirUnix':/usr/bin:/bin:`$PATH`nexport CROSS_COMPILE='$cc'"
} else {
  @"
export PATH=`$(echo "`$PATH" | tr ':' '\n' | grep -v -i cygwin | tr '\n' ':' | sed 's/:`$//')
export PATH='$gccDirUnix':/usr/bin:/bin:`$PATH
export CROSS_COMPILE='$cc'
"@
}

$script = @"
set -e
$pathBootstrap
command -v `${CROSS_COMPILE}gcc
command -v find
command -v make
test -d '$srcU/platform/generic'
test -d '$srcU/lib/sbi'
# find must resolve the source tree (catches path-flavor mismatches)
test -n "`$(find '$srcU/lib/sbi' -name '*.c' | head -1)"
cd '$srcU'
# Keep existing objects if present (incremental); still allow clean rebuild
mkdir -p '$buildU'
make O='$buildU' PLATFORM=generic FW_TEXT_START=0x80000000 \
  FW_PAYLOAD_PATH='$payMake' FW_FDT_PATH='$dtbMake' \
  CROSS_COMPILE=`"`$CROSS_COMPILE`" OPENSBI_ALLOW_NO_PIE=y -j2
"@
& $bash -lc $script
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Collect firmware
$fwDir = Join-Path $buildDir "platform/generic/firmware"
$products = @("fw_payload.elf", "fw_payload.bin", "fw_jump.elf", "fw_jump.bin", "fw_dynamic.elf")
foreach ($p in $products) {
  $srcp = Join-Path $fwDir $p
  if (Test-Path $srcp) {
    Copy-Item -Force $srcp (Join-Path $Out $p)
    Write-Host "  ok $p"
  }
}

$fwPayload = Join-Path $Out "fw_payload.elf"
if (-not (Test-Path $fwPayload)) {
  Write-Error "OpenSBI build did not produce fw_payload.elf under $fwDir"
  exit 1
}

# Export default for suite
$env:CVA6_LINUX_PAYLOAD = $fwPayload
Write-Host "[build-opensbi-smt2] PASS -> $fwPayload"
Write-Host "  Suite: `$env:CVA6_LINUX_PAYLOAD='$fwPayload'; .\verif\regress\smt-linux-rootfs.ps1"
exit 0
