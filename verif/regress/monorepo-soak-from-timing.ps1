# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Package-first monorepo soak → from-timing package → optional OpenSTA handoff.
#   pwsh -File verif/regress/monorepo-soak-from-timing.ps1
#   $env:SVT_STA_HANDOFF=1; pwsh -File verif/regress/monorepo-soak-from-timing.ps1

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$Svt = Join-Path $Root "sv-timing"
$Out = if ($env:SVT_SOAK_OUT) { $env:SVT_SOAK_OUT } else {
  Join-Path $Root "build-platform/workspace/build/sv-timing/monorepo-soak"
}
$Profile = if ($env:SVT_PROFILE) { $env:SVT_PROFILE } else { "sparse_ex" }
$Emit = if ($env:SVT_EMIT) { $env:SVT_EMIT } else { "1" }
$Handoff = if ($env:SVT_STA_HANDOFF) { $env:SVT_STA_HANDOFF } else { "0" }
$Allow = if ($env:SVT_ALLOW_LATENCY) { $env:SVT_ALLOW_LATENCY } else { "1" }

if (-not (Test-Path $Svt)) { throw "sv-timing/ missing" }
$env:CVA6_REPO_DIR = if ($env:CVA6_REPO_DIR) { $env:CVA6_REPO_DIR } else { $Root }
$env:SVT_MONOREPO_ROOT = $env:CVA6_REPO_DIR

Write-Host "[soak-from-timing] monorepo-soak profile=$Profile out=$Out"
$argsList = @("tools/svt.py", "monorepo-soak", "--profile", $Profile, "--out-dir", $Out, "--correct")
if ($Allow -eq "1") { $argsList += "--allow-latency" }
if ($Emit -eq "1") { $argsList += "--emit" }
if ($Handoff -eq "1") {
  $argsList += @("--sta-handoff", "--try-tools")
  if ($Emit -eq "1") { $argsList += "--use-emit" }
}

Push-Location $Svt
try {
  & python @argsList
  $rc = $LASTEXITCODE
} finally {
  Pop-Location
}

$Pkg = Join-Path $Out $Profile
if (-not (Test-Path (Join-Path $Pkg "portable.f"))) {
  Write-Host "[soak-from-timing] package missing at $Pkg"
  exit $(if ($rc) { $rc } else { 1 })
}
Write-Host "[soak-from-timing] package: $Pkg"
$Summary = Join-Path $Out "soak-summary.md"
if (Test-Path $Summary) { Get-Content $Summary -TotalCount 40 }

$bp = Join-Path $Root "build-platform"
if ((Get-Command bun -ErrorAction SilentlyContinue) -and (Test-Path $bp)) {
  Write-Host "[soak-from-timing] timings validate --from-timing"
  Push-Location $bp
  try {
    & bun run src/cli/index.ts timings validate --from-timing $Pkg
    if ($LASTEXITCODE -ne 0) { throw "validate failed" }
  } finally {
    Pop-Location
  }
} else {
  Write-Host "[soak-from-timing] bun/build-platform absent — skip host validate"
}

if ($rc -ne 0) {
  Write-Host "[soak-from-timing] FAIL (fix sv-timing first)"
  exit $rc
}
Write-Host "[soak-from-timing] PASS"
exit 0
