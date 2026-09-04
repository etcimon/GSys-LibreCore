# Upgrade path: newest LDC + wasm-eh

## How it works

The pin is LDC **1.36.0** / frontend **2.106.1** / LLVM **17**. The newest compiler in this workspace is LDC **1.42.0** / frontend **2.112.1** / LLVM **21**. `spa.d` will refuse to compile on 1.42 until the assert moves.

`runtime-adapt --new-import <1.42 import/>` compared the current adaptations to that import tree:

| verdict | n | meaning |
|---|---:|---|
| rebase-from-new | 106 | was identical to 1.36 — take the 1.42 body |
| reapply-adapt | 22 | including `object.d`, `rt/lifetime.d`, `core/lifetime.d`, `core/memory.d` — replay no-GC / `CRuntime_LIBWASM` / no-ModuleInfo |
| stub-or-port | 24 | new in 1.42 (`core/interpolation.d`, fiber split, …). Frontend-required ones need a stub; OS/GC ones stay omitted |
| still-omit-or-stub | 565 | still kernel |
| keep / drop | 21 / 39 | libwasm-only extras, or 1.36 files gone upstream |

Error handling is the reason to move: LLVM 21’s wasm EH is the intended replacement for “throw calls `_d_throw_exception` then `unreachable`” on LLVM 17 (README: `--wasm-enable-eh` is buggy on the pin). The frontend **still** names `_d_throw_exception` (`DtoThrow`). The JS side should treat that import like `onAssertErrorMsg` (abort after decoding the D string), not log-and-continue. Generated glue: `tmp/generated-druntime-wasm/js/error-handling.ts`.

Procedure (do not skip):

1. Keep 1.36 + current `druntime-wasm` as `--config=ldc-1.36` (FILE-CMP pin). Default is 1.43 + exception-using Phobos (`tests/spa-phobos`). Do not copy `std.file` / `std.socket`.
2. `dub run` in `tools/runtime-adapt` against `tmp/ldc-1.36.0` (refresh recipes).
3. Point `--new-import` at the newest LDC `import/` (or a recursive clone of that tag).
4. Reapply the 22 adapt files via `--carry --ldc-tag v1.42.0` (taught
   splices on 1.42 stock, not copy of 1.36 `object.d`). Stub only
   frontend-required newcomers (`missed-libwasm` / `stub-or-port`).
5. Move `spa.d` `__VERSION__`, `druntime-wasm/dub.sdl` version, and the `import-libwasm` junction together.
6. Install assert-shaped JS EH. Retest `--wasm-enable-eh` + `--asyncify`.

## Loci

`source/libwasm/spa.d:3`  
`tools/runtime-adapt/`  
`tests/spa-wasm-eh/run.ps1` (LDC master wasm-eh cell)  
`tmp/runtime-adapt-report.md` (upgrade map)  
LDC `gen/llvmhelpers.cpp` `DtoThrow`

## Invariants

- Dual worlds stay split: wasm front end vs host vibe-0. Construction.
- slideshow3dai `--config=ldc-1.42 --build=release` is the 1.42 compile cell
  (carry `runtime-v1.42.0`, thin LTO, Binaryen bulk-memory). Convention.
- `mvendorid`-style identity does not apply here; do not fake LDC version macros. Convention.

## Extension points

A later LDC than 1.42 uses the same `--new-import`. If DtoThrow starts emitting wasm `throw` to a tag, extend `installErrorHandling` to catch `WebAssembly.Exception` and abort with the same decoder.
