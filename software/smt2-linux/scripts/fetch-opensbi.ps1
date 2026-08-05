# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
# Clone/update OpenSBI for CVA6 SMT2 profile.
#   .\software\smt2-linux\scripts\fetch-opensbi.ps1

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

Ensure-Dir $Out
$url = "https://github.com/riscv-software-src/opensbi.git"
$ver = $env:OPENSBI_VERSION
$src = $env:OPENSBI_SRC

Write-Host "[fetch-opensbi] version=$ver -> $src"

if (-not (Test-Path (Join-Path $src ".git"))) {
  if (Test-Path $src) { Remove-Item -Recurse -Force $src }
  git clone --depth 1 --branch $ver $url $src
  if ($LASTEXITCODE -ne 0) {
    # tag might need full history for some versions
    git clone $url $src
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Push-Location $src
    git checkout $ver
    if ($LASTEXITCODE -ne 0) { Pop-Location; exit $LASTEXITCODE }
    Pop-Location
  }
} else {
  Push-Location $src
  git fetch --depth 1 origin $ver 2>$null
  git checkout $ver 2>$null
  if ($LASTEXITCODE -ne 0) {
    git fetch origin tag $ver --depth 1
    git checkout $ver
  }
  Pop-Location
}

if (-not (Test-Path (Join-Path $src "Makefile"))) {
  Write-Error "OpenSBI checkout incomplete: $src"
  exit 1
}
Write-Host "[fetch-opensbi] OK $src"
exit 0
