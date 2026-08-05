# Shared paths for SMT2 OpenSBI scripts. Dot-source only.
$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$Smt2Root = Resolve-Path (Join-Path $ScriptDir "..")
$RepoRoot = Resolve-Path (Join-Path $Smt2Root "../..")

if (-not $env:SMT2_LINUX_OUT) {
  $env:SMT2_LINUX_OUT = Join-Path $RepoRoot "build-platform/workspace/smt2-linux"
}
$Out = $env:SMT2_LINUX_OUT
if (-not $env:OPENSBI_VERSION) { $env:OPENSBI_VERSION = "v1.5" }
if (-not $env:OPENSBI_SRC) {
  $env:OPENSBI_SRC = Join-Path $Out "opensbi"
}

$DtsSrc = Join-Path $RepoRoot "corev_apu/bootrom/ariane-smt2.dts"
$PayloadDir = Join-Path $Smt2Root "payload"

function Find-CrossCompile {
  $prefixes = @(
    $env:CROSS_COMPILE,
    "riscv64-unknown-elf-",
    "riscv-none-elf-",
    "riscv64-unknown-linux-gnu-",
    "riscv64-linux-gnu-"
  ) | Where-Object { $_ }
  foreach ($p in $prefixes) {
    $gcc = "${p}gcc"
    if (Get-Command $gcc -ErrorAction SilentlyContinue) {
      return $p
    }
  }
  # Managed install first (cva6-build setup / installRiscvGcc → workspace/tooling/riscv)
  $managedGcc = Join-Path $RepoRoot "build-platform/workspace/tooling/riscv/bin/riscv-none-elf-gcc.exe"
  if (Test-Path $managedGcc) {
    $bin = Split-Path $managedGcc -Parent
    if ($env:Path -notlike "*$bin*") {
      $env:Path = "$bin;$($env:Path)"
    }
    return "riscv-none-elf-"
  }

  # Search common xPack / workspace locations
  $searchRoots = @(
    (Join-Path $RepoRoot "build-platform/workspace/tooling"),
    (Join-Path $env:USERPROFILE "AppData\Roaming\xPacks"),
    (Join-Path $env:USERPROFILE ".local\xPacks"),
    "C:\xpack"
  )
  foreach ($root in $searchRoots) {
    if (-not (Test-Path $root)) { continue }
    $found = Get-ChildItem -Path $root -Filter "riscv*gcc.exe" -Recurse -ErrorAction SilentlyContinue |
      Select-Object -First 1
    if ($found) {
      $bin = $found.DirectoryName
      if ($env:Path -notlike "*$bin*") {
        $env:Path = "$bin;$env:Path"
      }
      $name = $found.BaseName  # e.g. riscv-none-elf-gcc
      if ($name -match '^(.*-)gcc$') { return $Matches[1] }
    }
  }
  return $null
}

function Ensure-Dir([string]$p) {
  if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}
