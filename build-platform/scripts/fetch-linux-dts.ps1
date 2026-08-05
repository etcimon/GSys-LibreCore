# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# fetch-linux-dts.ps1 — Sparse, blobless checkout of the Linux RISC-V device-tree
# sources (arch/riscv/boot/dts) and the relevant devicetree bindings YAML, for
# CVA6 RTL <-> Linux cross-validation. Companion map: ..\..\AGENTS-dts-validation.md
#
# Why NOT a git submodule: the full kernel is multi-GB and contains
# case-colliding paths that fail to check out on Windows (case-insensitive
# NTFS). A cone-mode sparse checkout combined with --filter=blob:none downloads
# only the few MB we actually need — the RISC-V device trees and their
# bindings — with no case collisions and full history omitted.
#
# Usage:
#   .\build-platform\scripts\fetch-linux-dts.ps1 [-Dir <path>] [-Url <url>]
#                                                 [-Ref <branch|tag>] [-Path <p>...]
# Environment overrides: LINUX_DTS_DIR, LINUX_DTS_URL, LINUX_DTS_REF

[CmdletBinding()]
param(
  [switch]$Help,
  [string]$Dir,
  [string]$Url,
  [string]$Ref,
  [string[]]$Path
)

$ErrorActionPreference = "Stop"

if ($Help) {
  @"
Usage: .\build-platform\scripts\fetch-linux-dts.ps1 [-Help] [-Dir <path>] [-Url <url>]
                                                   [-Ref <branch|tag>] [-Path <p>...]
  -Help       Show this help and exit.
  -Dir        Destination checkout directory (default: build-platform/workspace/linux-dts).
  -Url        Linux git remote (default: https://github.com/torvalds/linux.git).
  -Ref        Branch or tag to track (default: master).
  -Path       Sparse paths to fetch (comma list; defaults to RISC-V DTS + bindings set if omitted).
Environment overrides: LINUX_DTS_DIR, LINUX_DTS_URL, LINUX_DTS_REF
"@ | Write-Host
  exit 0
}

# Run git with an explicit array to avoid PowerShell treating leading '-C' as a
# parameter, and throw on any non-zero exit (native commands do not throw).
function Invoke-Git {
  param([Parameter(Mandatory = $true)][string[]]$GitArgs)
  & git @GitArgs
  if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed (exit $LASTEXITCODE)" }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Dir) { $Dir = if ($env:LINUX_DTS_DIR) { $env:LINUX_DTS_DIR } else { Join-Path $scriptDir "..\workspace\linux-dts" } }
# Normalize 'scripts\..\workspace' to a clean absolute path.
$Dir = [System.IO.Path]::GetFullPath($Dir)
if (-not $Url) { $Url = if ($env:LINUX_DTS_URL) { $env:LINUX_DTS_URL } else { "https://github.com/torvalds/linux.git" } }
if (-not $Ref) { $Ref = if ($env:LINUX_DTS_REF) { $env:LINUX_DTS_REF } else { "master" } }

# Default sparse paths: the RISC-V DTS tree plus the bindings that CVA6 SoC
# device trees actually reference. Override with -Path if you need a different set.
$paths = if ($Path) { $Path } else {
  @(
    "arch/riscv/boot/dts",
    "Documentation/devicetree/bindings/riscv",
    "Documentation/devicetree/bindings/interrupt-controller",
    "Documentation/devicetree/bindings/timer",
    "Documentation/devicetree/bindings/cache"
  )
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Write-Error "fetch-linux-dts: git is required but was not found on PATH."
  exit 1
}

if (Test-Path (Join-Path $Dir ".git")) {
  Write-Host "fetch-linux-dts: updating existing checkout at '$Dir' (ref=$Ref)"
  Invoke-Git -GitArgs (@("-C", $Dir, "sparse-checkout", "set", "--cone") + $paths)
  Invoke-Git -GitArgs @("-C", $Dir, "fetch", "--filter=blob:none", "--depth", "1", "origin", $Ref)
  Invoke-Git -GitArgs @("-C", $Dir, "checkout", "-B", $Ref, "FETCH_HEAD")
} else {
  Write-Host "fetch-linux-dts: cloning $Url (blobless + sparse) into '$Dir'"
  $parent = Split-Path -Parent $Dir
  if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  Invoke-Git -GitArgs @("clone", "--filter=blob:none", "--no-checkout", "--depth", "1", "--branch", $Ref, $Url, $Dir)
  Invoke-Git -GitArgs @("-C", $Dir, "sparse-checkout", "init", "--cone")
  Invoke-Git -GitArgs (@("-C", $Dir, "sparse-checkout", "set") + $paths)
  Invoke-Git -GitArgs @("-C", $Dir, "checkout", $Ref)
}

$sha = (& git -C $Dir rev-parse HEAD).Trim()
$manifest = Join-Path $Dir ".cva6-dts-manifest"
@(
  "url=$Url"
  "ref=$Ref"
  "sha=$sha"
  "fetched=$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
  "paths=$($paths -join ' ')"
) | Set-Content -Path $manifest -Encoding utf8

$dtsDir = Join-Path $Dir "arch/riscv/boot/dts"
$dtsCount = 0
if (Test-Path $dtsDir) { $dtsCount = (Get-ChildItem -Path $dtsDir -Recurse -Include *.dts, *.dtsi -File).Count }
Write-Host "fetch-linux-dts: done."
Write-Host "  dest : $Dir"
Write-Host "  sha  : $sha"
Write-Host "  dts  : $dtsCount RISC-V .dts/.dtsi files"
Write-Host "  next : see AGENTS-dts-validation.md for the DT <-> spec <-> RTL cross-reference."
