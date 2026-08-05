# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# build.ps1 - Top-level bootstrap entry (Windows PowerShell 5.1+ / pwsh).
#
# Ensures a usable developer environment, then delegates every argument to the
# GSys LibreCore build platform (build-platform/). Examples:
#
#   .\build.ps1 probe              # capability boxes + install playbook
#   .\build.ps1 tools install sim  # or dual-hart / all / spike
#   .\build.ps1 diag run           # compartmentalized diagnostics
#   .\build.ps1 doctor
#   .\build.ps1 setup
#   .\build.ps1 build --iss verilator
#   .\build.ps1 test --suite ooo-l3-tests
#   .\build.ps1 verify --target g6lc64_ooo_server
#   .\build.ps1 config --json
#
# Bootstrap steps (in order):
#   1. Import MSVC (VS 2019-2026) cl/link env when missing - newest first.
#   2. Note WSL availability (Spike / dual-hart Linux tooling).
#   3. Ensure Bun is on PATH (install if necessary).
#   4. Optionally offer y/n install when workspace tooling looks incomplete
#      and the command needs sim/verify tools (interactive TTY only).
#   5. Run build-platform/src/cli/index.ts with the same arguments.
#
# Encoding: ASCII-only so Windows PowerShell 5.1 parses this without a UTF-8 BOM.

$ErrorActionPreference = "Stop"

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$platformEntry = Join-Path $here "build-platform\src\cli\index.ts"
$workspaceTooling = Join-Path $here "build-platform\workspace\tooling"

# ---------------------------------------------------------------------------
# 1. MSVC 2019-2026 developer environment (prefer most recent)
# ---------------------------------------------------------------------------
function Test-MsvcReady {
  return [bool](Get-Command cl -ErrorAction SilentlyContinue)
}

function Import-MsvcEnvironment {
  if (Test-MsvcReady) {
    $clPath = (Get-Command cl).Source
    Write-Host "[build.ps1] MSVC already on PATH ($clPath)."
    return $true
  }

  $pf86 = ${env:ProgramFiles(x86)}
  $pf = $env:ProgramFiles
  $vswhereCandidates = @(
    (Join-Path $pf86 "Microsoft Visual Studio\Installer\vswhere.exe"),
    (Join-Path $pf "Microsoft Visual Studio\Installer\vswhere.exe")
  )
  $vswhere = $vswhereCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

  $vcvars = $null
  if ($vswhere) {
    # Prefer newest product in the VS 16-18 range (2019-2026).
    $installPath = & $vswhere `
      -latest `
      -products * `
      -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
      -version "[16.0,19.0)" `
      -property installationPath 2>$null
    if ($installPath) {
      $cand64 = Join-Path $installPath "VC\Auxiliary\Build\vcvars64.bat"
      $candAll = Join-Path $installPath "VC\Auxiliary\Build\vcvarsall.bat"
      if (Test-Path $cand64) { $vcvars = $cand64 }
      elseif (Test-Path $candAll) { $vcvars = $candAll }
    }
  }

  # Fallback: walk year folders newest-first when vswhere is absent.
  if (-not $vcvars) {
    $years = @(2026, 2025, 2024, 2022, 2019)
    $editions = @("Enterprise", "Professional", "Community", "BuildTools", "Preview")
    $roots = @(
      (Join-Path $pf "Microsoft Visual Studio"),
      (Join-Path $pf86 "Microsoft Visual Studio")
    )
    foreach ($year in $years) {
      foreach ($root in $roots) {
        foreach ($ed in $editions) {
          $cand = Join-Path $root "$year\$ed\VC\Auxiliary\Build\vcvars64.bat"
          if (Test-Path $cand) {
            $vcvars = $cand
            break
          }
        }
        if ($vcvars) { break }
      }
      if ($vcvars) { break }
    }
  }

  if (-not $vcvars) {
    Write-Host "[build.ps1] MSVC not found (VS 2019-2026). Native Windows builds needing cl/link will fail."
    Write-Host "[build.ps1] Install Visual Studio Build Tools with the C++ workload, or use WSL for Linux tooling."
    return $false
  }

  Write-Host "[build.ps1] Importing MSVC environment via $vcvars ..."
  # Capture env after vcvars in a disposable cmd so we can apply it here.
  # Note: '&&' lives only inside the cmd.exe string - not PowerShell syntax.
  if ($vcvars -like "*vcvarsall.bat") {
    $cmdLine = "`"$vcvars`" x64 >nul 2>&1 && set"
  } else {
    $cmdLine = "`"$vcvars`" >nul 2>&1 && set"
  }
  try {
    $lines = & cmd.exe /c $cmdLine 2>$null
    foreach ($line in $lines) {
      if ($line -match '^(.*?)=(.*)$') {
        $name = $Matches[1]
        $value = $Matches[2]
        # Skip pseudo-vars that cmd emits and that break PowerShell sessions.
        if ($name -match '^[a-zA-Z_][a-zA-Z0-9_]*$') {
          Set-Item -Path ("Env:" + $name) -Value $value
        }
      }
    }
  } catch {
    Write-Warning ("[build.ps1] Failed to import MSVC env from {0}: {1}" -f $vcvars, $_)
    return $false
  }

  if (Test-MsvcReady) {
    $clPath = (Get-Command cl).Source
    Write-Host "[build.ps1] MSVC ready: $clPath"
    return $true
  }
  Write-Warning "[build.ps1] vcvars ran but cl.exe is still not on PATH."
  return $false
}

[void](Import-MsvcEnvironment)

# ---------------------------------------------------------------------------
# 2. WSL note (Spike / dual-hart Linux path)
# ---------------------------------------------------------------------------
$wslOk = $false
if (Get-Command wsl -ErrorAction SilentlyContinue) {
  try {
    $wslList = & wsl -l -q 2>$null
    if ($LASTEXITCODE -eq 0 -and $wslList) { $wslOk = $true }
  } catch {
    $wslOk = $false
  }
}
if ($wslOk) {
  Write-Host "[build.ps1] WSL available (preferred for Spike / dual-hart Linux tooling)."
} else {
  Write-Host "[build.ps1] WSL not detected - Spike ISS and some dual-hart installs need WSL or a native Linux host."
}

# ---------------------------------------------------------------------------
# 3. Bun
# ---------------------------------------------------------------------------
if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
  Write-Host "[build.ps1] Bun not found; installing from bun.sh/install.ps1 ..."
  Invoke-RestMethod bun.sh/install.ps1 | Invoke-Expression
  $env:PATH = "$env:USERPROFILE\.bun\bin;$env:PATH"
}

if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
  Write-Error "[build.ps1] Bun installation failed or is not on PATH. Install from https://bun.sh and re-run."
  exit 1
}

# ---------------------------------------------------------------------------
# 4. Optional y/n when workspace tooling looks incomplete for test/verify
# ---------------------------------------------------------------------------
function Test-InteractiveHost {
  try {
    return [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
  } catch {
    return $false
  }
}

function Test-ManagedToolPresent {
  param([string]$Name)

  switch ($Name) {
    "verilator" {
      if (Get-Command verilator -ErrorAction SilentlyContinue) { return $true }
      $roots = Get-ChildItem (Join-Path $workspaceTooling "verilator-*") -Directory -ErrorAction SilentlyContinue
      foreach ($r in $roots) {
        if (Test-Path (Join-Path $r.FullName "bin\verilator.exe")) { return $true }
        if (Test-Path (Join-Path $r.FullName "bin\verilator")) { return $true }
      }
      return $false
    }
    "spike" {
      if (Get-Command spike -ErrorAction SilentlyContinue) { return $true }
      $spikeUnix = Join-Path $workspaceTooling "spike\bin\spike"
      $spikeWin = Join-Path $workspaceTooling "spike\bin\spike.exe"
      return (Test-Path $spikeUnix) -or (Test-Path $spikeWin)
    }
    "riscv-gcc" {
      if (Get-Command riscv-none-elf-gcc -ErrorAction SilentlyContinue) { return $true }
      if (Get-Command riscv64-unknown-elf-gcc -ErrorAction SilentlyContinue) { return $true }
      # Managed prefix is workspace/tooling/riscv (not only riscv-*).
      $gccRoots = @()
      $fixed = Join-Path $workspaceTooling "riscv"
      if (Test-Path $fixed) { $gccRoots += Get-Item $fixed }
      $gccRoots += @(Get-ChildItem (Join-Path $workspaceTooling "riscv-*") -Directory -ErrorAction SilentlyContinue)
      foreach ($r in $gccRoots) {
        $binDir = Join-Path $r.FullName "bin"
        if (-not (Test-Path $binDir)) { continue }
        foreach ($pat in @("riscv-none-elf-gcc.exe", "riscv-none-elf-gcc", "riscv64-unknown-elf-gcc.exe", "riscv64-unknown-elf-gcc", "*gcc*.exe")) {
          $bins = Get-ChildItem $binDir -Filter $pat -ErrorAction SilentlyContinue
          if ($bins) { return $true }
        }
      }
      return $false
    }
    default { return $false }
  }
}

# Snapshot argv before any nested script can shadow automatic $args.
$cliArgs = @($args)
$cmd = if ($cliArgs.Count -gt 0) { [string]$cliArgs[0] } else { "" }
$needsTooling = $cmd -in @("test", "verify", "build", "diag")
$skipPrompt = ($env:G6LC_NO_TOOL_PROMPT -eq "1") -or ($env:CVA6_NO_TOOL_PROMPT -eq "1") -or
              ($cliArgs -contains "--yes") -or ($cliArgs -contains "-y") -or
              ($cliArgs -contains "--dry-run") -or ($cliArgs -contains "-n")

if ($needsTooling -and -not $skipPrompt -and (Test-InteractiveHost)) {
  $missing = @()
  foreach ($t in @("verilator", "spike", "riscv-gcc")) {
    if (-not (Test-ManagedToolPresent $t)) { $missing += $t }
  }
  if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host ("[build.ps1] Workspace tooling incomplete for '{0}': missing {1}." -f $cmd, ($missing -join ", "))
    Write-Host "[build.ps1] On Windows, Spike is installed via WSL into build-platform/workspace/tooling."
    Write-Host "[build.ps1] Install profile 'sim' = riscv-gcc + verilator + spike (+ iverilog detect)."
    $answer = Read-Host "Install managed tools now (tools install sim)? [y/N]"
    if ($answer -match '^[Yy](es)?$') {
      Write-Host "[build.ps1] Running: bun $platformEntry tools install sim"
      & bun $platformEntry tools install sim
      if ($LASTEXITCODE -ne 0) {
        Write-Warning ("[build.ps1] tools install sim exited {0} - continuing; command may still fail preflight." -f $LASTEXITCODE)
      }
    } else {
      Write-Host "[build.ps1] Skipping install. Later: .\build.ps1 tools install sim   (or dual-hart / all)"
      Write-Host "[build.ps1] Non-interactive: set G6LC_NO_TOOL_PROMPT=1 to silence this prompt."
    }
  }
}

# ---------------------------------------------------------------------------
# 5. Delegate
# ---------------------------------------------------------------------------
& bun $platformEntry @cliArgs
exit $LASTEXITCODE
