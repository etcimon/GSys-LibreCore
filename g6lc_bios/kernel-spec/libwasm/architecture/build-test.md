# Build and test (BUILDING.md)

## How it works

BUILDING.md’s happy path is: pin LDC, empty WASM `post-switches`, `dub build --arch=wasm32-unknown-wasi`, then (for an app) Binaryen `wasm-opt --asyncify`, then `yarn`/`npm` for the JS shell.

This workspace:

- Compiler: `riscv-dev/toolchains/ldc2-1.36.0-windows-x64` (DMD 2.106.1, LLVM 17.0.6, `wasm32`/`wasm64` registered).
- Binaryen: `riscv-dev/toolchains/binaryen-version_132-x86_64-windows` (`wasm-opt version 132`).
- Conf: that LDC’s `etc/ldc2.conf` WASM section has `post-switches = [];` as BUILDING requires.
- Env: untracked `riscv-dev/setenv-wasm.ps1` puts both bins on PATH and `dub add-local`s this tree (and its path-local packages) at semver `0.9.0` / `1.36.0`.

Green command (library, BUILDING):

```text
dub build --arch=wasm32-unknown-wasi --compiler=ldc2
```

Green command (slideshow3dai consumer):

```text
dub build --arch=wasm32-unknown-wasi --compiler=ldc2
# postBuild: wasm-opt --asyncify --pass-arg=asyncify-imports@env.libwasm_await__void
```

If directories move, BUILDING says update `dub.sdl` paths. Consumers that used `path="../libwasm"` are switched to `version="~>0.9.0"` plus `add-local` so the trees need not be siblings.

## Loci

`BUILDING.md`  
`dub.sdl`  
`examples/dom-ts/dub.sdl`  
`tests/ut/`  

## Invariants

- Do not test this tree with LDC 1.42/1.43. Construction (`__VERSION__`).
- Do not restore WASM `-I` to LDC import. Construction.

## Open questions / cell

**Observed 2026-08-13** (slideshow3dai `dub build --arch=wasm32-unknown-wasi --compiler=ldc2 --build=release`, LDC 1.36.0, DUB 1.35.1 built 2024-01-06):

| Step | Result |
|---|---|
| Empty `post-switches` only | **FAIL** — ldc2 cannot find `object.d` for dub’s platform probe |
| `post-switches = -I%%ldcbinarypath%%/../import-libwasm` + `-d-version=CRuntime_LIBWASM` (junction → `druntime-wasm`) | Probe **PASS** (BUILDING intent: not LDC `import/`) |
| memutils-wasm / fast-wasm / diet-wasm / optional-wasm | **PASS** (up to date) |
| libwasm library | **FAIL** — `druntime-wasm` Phobos subset: `std.complex` (unused import, removed locally), `core.math` (copied from LDC 1.36 `import/core/math.d`), then `std.numeric` from `std.internal.math.gammafunction` |

DUB 1.35.1 is **four days earlier** than BUILDING’s “after 2024-01-10” line; it still selected packages and drove LDC.

Binaryen `wasm-opt` is on PATH; postBuild never ran because LDC did not emit `*-raw.wasm`.

**object.d source of truth (reconfirmed):** `ldc2 -c -mtriple=wasm32-unknown-wasi -v` on `tmp/probe_object.d` imported

`import object (…\import-libwasm\object.d)`

that junction targets `libwasm/druntime-wasm`. Stock `import/object.d` is not on the path. `runtime-adapt` regenerates the same `object.d` (kind stub-adapt) into `tmp/generated-druntime-wasm/object.d`.

Host tool cell: `cd tools/runtime-adapt && dub build --compiler=<host ldc 1.42>`. That is **not** the wasm cell.
