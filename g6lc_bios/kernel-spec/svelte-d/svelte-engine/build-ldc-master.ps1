# Build svelte-engine with LDC master (1.43 wasm-eh) + libwasm runtime-v1.43.0,
# then run EH + Phobos probes under Node using the TS error-handling runtime.
$ErrorActionPreference = 'Stop'
Remove-Item Env:DFLAGS -ErrorAction SilentlyContinue
Remove-Item Env:DC -ErrorAction SilentlyContinue
Remove-Item Env:DMD -ErrorAction SilentlyContinue

$Root = $PSScriptRoot
$Libwasm = Join-Path $Root '..\..\riscv-compilers\libwasm'
$Ldc2 = Join-Path $Root '..\..\riscv-compilers\ldc2-build\bin\ldc2.exe'
$HostLdc = Join-Path $Root '..\toolchains\ldc2-1.42.0-windows-x64'
if (-not (Test-Path $Ldc2)) { throw "ldc2.exe missing: $Ldc2" }

$env:PATH = "$(Split-Path $Ldc2 -Parent);$(Join-Path $HostLdc 'bin');$env:PATH"
Write-Host "ldc2     $(& $Ldc2 --version | Select-Object -First 1)"

$sel = Join-Path $Root 'dub.selections.json'
@'
{
	"fileVersion": 1,
	"versions": {
		"diet-wasm": {"path":"../../riscv-compilers/libwasm/diet-wasm"},
		"druntime-wasm": {"path":"../../riscv-compilers/libwasm/runtime-v1.43.0"},
		"fast-wasm": {"path":"../../riscv-compilers/libwasm/fast-wasm"},
		"libwasm": {"path":"../../riscv-compilers/libwasm"},
		"memutils-wasm": {"path":"../../riscv-compilers/libwasm/memutils-wasm"},
		"optional-wasm": {"path":"../../riscv-compilers/libwasm/optional-wasm"}
	}
}
'@ | Set-Content -Encoding utf8 $sel

$raw = Join-Path $Root 'public\svelte-engine-raw.wasm'
if (Test-Path $raw) { Remove-Item -Force $raw }

Set-Location $Root
& dub build --arch=wasm32-unknown-wasi --compiler=$Ldc2 --config=application --build=release --force
$ex = $LASTEXITCODE
if (-not (Test-Path $raw)) { throw "dub build failed: $ex (no raw.wasm)" }
if ($ex -ne 0) {
    Write-Host "    dub post-build exited $ex; raw.wasm is enough for probes"
}
Write-Host "    raw      $raw  $((Get-Item $raw).Length) bytes"

$ship = Join-Path $Root 'public\svelte-engine.wasm'
if (-not (Test-Path $ship)) {
    Copy-Item $raw $ship
    Write-Host "    copied   raw → svelte-engine.wasm (no asyncify on EH)"
}

Write-Host "==> node run-probes.mjs"
& node .\run-probes.mjs
if ($LASTEXITCODE -ne 0) { throw "svelte-engine probes failed: $LASTEXITCODE" }
Write-Host "PASS  svelte-engine ldc-master EH + Phobos"
exit 0
