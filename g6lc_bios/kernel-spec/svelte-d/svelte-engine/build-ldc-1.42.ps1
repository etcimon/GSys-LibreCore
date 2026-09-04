# Validate slideshow3dai against LDC 1.42 + libwasm/runtime-v1.42.0.
# Do not source setenv-wasm.ps1 (that cell is LDC 1.36).
$ErrorActionPreference = 'Stop'
Remove-Item Env:DFLAGS -ErrorAction SilentlyContinue
Remove-Item Env:DC -ErrorAction SilentlyContinue
Remove-Item Env:DMD -ErrorAction SilentlyContinue

$Ldc = 'E:\cva6\riscv-dev\toolchains\ldc2-1.42.0-windows-x64'
$Binaryen = 'E:\cva6\riscv-dev\toolchains\binaryen-version_132-x86_64-windows'
$env:PATH = "$(Join-Path $Ldc 'bin');$(Join-Path $Binaryen 'bin');$env:PATH"

Write-Host "ldc2     $(& ldc2 --version | Select-Object -First 1)"
Write-Host "dub      $((Get-Command dub).Source)"
Write-Host "wasm-opt $((Get-Command wasm-opt -ErrorAction SilentlyContinue).Source)"

Set-Location 'E:\cva6\riscv-dev\slideshow3dai'
& dub build --arch=wasm32-unknown-wasi --compiler=ldc2 --config=ldc-1.42 --build=release --force
exit $LASTEXITCODE
