# druntime-wasm / Phobos vs stock LDC 1.36 WASM

File-by-file inventory is produced by `tools/runtime-adapt` (libdparse). Numbers below are from the 2026-08-13 run against `tmp/ldc-1.36.0` (tag v1.36.0, phobos `ac5257e`). libwasm’s README still states Phobos is being integrated and that `ldc2 --wasm-enable-eh` has a known bug on this pin.

## How it works

Stock LDC 1.36 (LLVM 17, frontend 2.106.1) can *emit* `wasm32` / `wasm64` (registered targets). It does **not** ship WASM defaultlibs in the Windows package (`lib-dirs = []`, `-defaultlib=`). Its WASI story, when used, is `CRuntime_WASI` plus a ModuleInfo registry in `__minfo` (see `tests/codegen/wasi.d` at tag `v1.36.0`). Later LDC (1.43+) grew WASI p1/p2, `ldc-build-runtime`, a pointer-spill pass, and `sections_wasm.d`. None of that is what this tree uses.

libwasm vendors a parallel tree:

| Stock LDC 1.36 WASM (when used) | libwasm replacement |
|---|---|
| `import/object.d` via `post-switches -I` | `druntime-wasm/object.d` (`CRuntime_LIBWASM`) |
| `CRuntime_WASI` | `CRuntime_LIBWASM` (+ `CRuntime_DRUNTIME_WASM` in druntime-wasm’s dub.sdl) |
| `__minfo` ModuleInfo | **`-fno-moduleinfo`** — no ModuleInfo |
| GC + conservative scan | `WasmAllocator` bump + `memory.grow`; memutils pools; `deallocate` is a no-op |
| Phobos as defaultlib (not in Win pkg) | Partial `druntime-wasm/std/` for CTFE and a few algorithms; “most phobos functions don’t work” (README) |
| EH: incomplete / buggy on WASM | `--wasm-enable-eh` + `-mattr=+exception-handling`; `_d_throw_exception` → JS `captureException` (`rt/stubs.d`) |
| TLS / fibers / threads | Pretends Glibc+Posix in comments; no real threads; fibers unused |

`core.memory.GC` still exists as types and some `extern(C)` hooks so frontend-generated lifetime calls compile. `rt/lifetime.d` is annotated “made mostly nothrow and non-reliant on BlkInfo”. That is an **adaptation of LDC/DMD lifetime**, not a deletion of the API. Callers that actually collect will not get a real GC.

`ldc/` under `druntime-wasm` copies LDC 1.36-era `ldc.intrinsics` / gccbuiltins (including `gccbuiltins_riscv.di`) so the frontend’s implicit LDC imports resolve **from this tree**, not from LDC’s `import/ldc`.

## Loci

`druntime-wasm/object.d`  
`druntime-wasm/rt/lifetime.d`  
`druntime-wasm/core/memory.d`  
`druntime-wasm/core/sys/wasi/`  
`source/libwasm/rt/allocator.d` (`WasmAllocator`, 64 KiB pages)  
`source/libwasm/rt/stubs.d` (`_d_throw_exception`)  
`source/libwasm/rt/memory.d` (`wasm_malloc` / `memset`)  

## Invariants

- Do not re-enable ModuleInfo without implementing `__minfo` and dropping `-fno-moduleinfo` everywhere (libwasm, memutils-wasm, fast-wasm, diet-wasm, optional-wasm, slideshow3dai). Construction.
- A Phobos module that uses TLS, exceptions-as-values, or the real GC is not portable here until rewritten. Convention + known gap.

## Extension points

Porting a Phobos module: copy into `druntime-wasm/std/`, strip GC/TLS, compile with the same hidden + no-moduleinfo flags. EH-using code waits on the LDC WASM EH bug (README).

## Inventory (runtime-adapt)

| kind | n |
|---|---:|
| identical (regenerate from LDC 1.36) | 110 |
| adapted | 21 |
| stub-adapt (`object.d`, `core/memory.d`, …) | 4 |
| extra (`core/sys/wasi`, gccbuiltins, `rt/aApply1.d`) | 14 |
| missing (omitted kernel / unported) | 604 |

CTFE-keep Phobos (`std.algorithm` / `traits` / `meta` / `format` / `range` / …): **0 missing**. Accidental runtime hole: `std.numeric`, `std.complex`, `std.mathspecial` (phobos-math). Full tables: `tmp/runtime-adapt-report.md`. Generated tree: `tmp/generated-druntime-wasm/` (same `object.d` the `import-libwasm` junction serves).

## Open questions

- Whether `CRuntime_DRUNTIME_WASM` is ever tested (`object.d` checks `CRuntime_LIBWASM` only).
- How this allocator interacts with later LDC’s wasm pointer-spill pass (1.42+): open if the pin moves (`upgrade-ldc.md`).
