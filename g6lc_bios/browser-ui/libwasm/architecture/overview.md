# Overview

## How it works

libwasm is a D-to-browser toolchain: a compile-time SPA framework (`mixin Spa!App`), generated WebIDL bindings (`source/libwasm/bindings/`), and a **replacement runtime** so LDC can emit `wasm32-unknown-wasi` without linking stock druntime or Phobos. It is a fork of spasm, not a thin wrapper around LDC’s own WASM support.

A representative journey starts at `_start(uint heap_base)` injected by `mixin Spa!(Application, Theme)` (`source/libwasm/spa.d`). That C export initialises a bump/page allocator (`libwasm.rt.allocator.WasmAllocator`) from the WASM linear-memory heap base, initialises `memutils` `PoolStack`, asks JS for the DOM root (`getRoot`), injects compile-time CSS, then renders the annotated structs (`@child`, `@prop`, `@callback`, `@style`) into the page. JS holds DOM objects in an integer handle table (`src-ts/modules/libwasm.ts` in consumers). D never stores JS object pointers.

Promises are not native WASM async. D calls `libwasm_await__void(Handle)` (`types.d`); Binaryen `wasm-opt --asyncify` rewrites the module so that import can unwind the WASM stack; the JS wrapper (`asyncify.ts`) waits on the Promise and rewinds. That is why `postBuildCommands` is part of the product, not an optional optimiser.

## Loci

`source/libwasm/spa.d` — `_start`, `__VERSION__ == 2106`  
`source/libwasm/package.d` — barrel  
`source/libwasm/rt/{allocator,memory,stubs}.d` — heap, malloc, EH stub  
`druntime-wasm/` — replacement object/core/std  
`dub.sdl` — library configuration, hidden visibility, exception-handling attr  
`BUILDING.md` — ldc2.conf and compiler pin  

## Invariants

- Exactly LDC 1.36.0 / frontend 2.106.1. Construction (`spa.d` static assert).
- Stock LDC `-Iimport` for WASM must be empty so `druntime-wasm/object.d` wins. Construction (BUILDING.md + `object.d` `CRuntime_LIBWASM`).
- `-fno-moduleinfo` is required: this runtime does not implement LDC’s `__minfo` ModuleInfo registry. Construction.
- Allocation is `WasmAllocator` + memutils, not LDC’s GC. Convention of this fork; GC APIs remain as stubs/types.

## Extension points

New DOM API: generate or hand-write under `source/libwasm/bindings/`. New JS import: `extern(C)` in D plus `jsExports` in the consumer’s `modules/`. New Phobos module: port into `druntime-wasm/std/` and keep it GC-free. Refresh the recipe with `tools/runtime-adapt`.

## Open questions

Which LDC 1.36 WASM EH bugs still bite this pin is in `js-events-memory.md` / `upgrade-ldc.md`. The 1.36 vs libwasm file map is no longer incomplete (`runtime-vs-ldc.md`, `tmp/runtime-adapt-report.md`).
