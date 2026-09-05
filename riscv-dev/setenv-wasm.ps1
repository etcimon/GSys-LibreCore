# Untracked: LDC 1.36.0 + dub add-local for libwasm (WASM front-end only).
# Does not replace setenv.ps1 (1.42 + host D packages).
#
#   cd E:\cva6\riscv-dev
#   . .\setenv-wasm.ps1
#
# libwasm lives in the sibling scaffold: ../riscv-compilers/libwasm

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Ldc = Join-Path $Root 'toolchains\ldc2-1.36.0-windows-x64'
$Binaryen = Join-Path $Root 'toolchains\binaryen-version_132-x86_64-windows'
$Libwasm = Join-Path (Split-Path $Root -Parent) 'riscv-compilers\libwasm'

if (-not (Test-Path (Join-Path $Ldc 'bin\ldc2.exe'))) {
  throw "LDC 1.36.0 missing at $Ldc — extract ldc2-1.36.0-windows-x64.7z under toolchains/"
}
if (-not (Test-Path (Join-Path $Libwasm 'dub.sdl'))) {
  throw "libwasm missing at $Libwasm"
}

$binPaths = @((Join-Path $Ldc 'bin'))
if (Test-Path (Join-Path $Binaryen 'bin\wasm-opt.exe')) {
  $binPaths += (Join-Path $Binaryen 'bin')
} else {
  Write-Warning "Binaryen wasm-opt missing at $Binaryen — postBuildCommands will fail"
}
$env:PATH = (($binPaths + $env:PATH) -join ';')
$env:DC = Join-Path $Ldc 'bin\ldc2.exe'
$env:DMD = Join-Path $Ldc 'bin\ldmd2.exe'

$dub = Join-Path $Ldc 'bin\dub.exe'
$pkgs = @(
  @{ Dir = $Libwasm; Ver = '0.9.0' }
  @{ Dir = (Join-Path $Libwasm 'memutils-wasm'); Ver = '0.9.0' }
  @{ Dir = (Join-Path $Libwasm 'fast-wasm'); Ver = '0.9.0' }
  @{ Dir = (Join-Path $Libwasm 'diet-wasm'); Ver = '0.9.0' }
  @{ Dir = (Join-Path $Libwasm 'optional-wasm'); Ver = '0.9.0' }
  @{ Dir = (Join-Path $Libwasm 'druntime-wasm'); Ver = '1.36.0' }
)
foreach ($p in $pkgs) {
  & $dub remove-local $p.Dir 2>$null | Out-Null
  & $dub add-local $p.Dir $p.Ver
  Write-Host "add-local $($p.Dir) $($p.Ver)"
}

Write-Host "ldc2     $(& (Join-Path $Ldc 'bin\ldc2.exe') --version | Select-Object -First 1)"
Write-Host "dub      $((Get-Command dub -ErrorAction SilentlyContinue).Source)"
Write-Host "wasm-opt $((Get-Command wasm-opt -ErrorAction SilentlyContinue).Source)"
Write-Host "DC       $env:DC"
