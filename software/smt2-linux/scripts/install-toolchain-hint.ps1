# SPDX-License-Identifier: MIT
# Download xPack RISC-V GCC + dtc hints for Windows SMT2 OpenSBI builds.
#   .\software\smt2-linux\scripts\install-toolchain-hint.ps1 [-Download]

param([switch]$Download)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")
Ensure-Dir (Join-Path $RepoRoot "build-platform/workspace/tooling")

Write-Host @"
CVA6 SMT2 OpenSBI toolchain requirements
----------------------------------------
Preferred (build-platform):
  .\build.ps1 tools install dual-hart
  # or: setup --install --profile dual-hart
  # Profiles: sim | dual-hart | opensbi | all
  # See build-platform/README.md and tools install --help

Manual pieces:
1. RISC-V GCC → workspace/tooling/riscv (xPack)
   bun build-platform/src/cli/index.ts tools install riscv-gcc

2. DTB: python + pip install fdt  (or system dtc)

3. OpenSBI make host:
   - Windows: Cygwin bash + make (Git Bash usually lacks make)
   - build-opensbi-smt2.ps1 auto-wraps xPack for Cygwin /cygdrive paths
   - Linux/WSL: native make + CROSS_COMPILE

Then (if not using tools install dual-hart):
  .\software\smt2-linux\scripts\fetch-opensbi.ps1
  .\software\smt2-linux\scripts\build-opensbi-smt2.ps1
"@

if (-not $Download) { exit 0 }

$toolRoot = Join-Path $RepoRoot "build-platform/workspace/tooling"
$zip = Join-Path $toolRoot "xpack-riscv-none-elf-gcc-win32-x64.zip"
# Pin a known release URL (update when bumping)
$url = "https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v14.2.0-3/xpack-riscv-none-elf-gcc-14.2.0-3-win32-x64.zip"

Write-Host "[install-toolchain] downloading $url ..."
Write-Host "  (large ~380MB — this may take several minutes)"
curl.exe -L --retry 3 -o $zip $url
if ($LASTEXITCODE -ne 0) { Write-Error "download failed"; exit 1 }

Write-Host "[install-toolchain] expanding..."
Expand-Archive -Path $zip -DestinationPath $toolRoot -Force
Write-Host "[install-toolchain] done under $toolRoot"
Write-Host "  Re-open shell or ensure PATH includes .../xpack-riscv-none-elf-gcc-*/bin"
exit 0
