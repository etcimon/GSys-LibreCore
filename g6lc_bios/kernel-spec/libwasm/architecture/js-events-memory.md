# JS-linked events, memory, and error handling

## How it works

D never holds a JS object pointer. JS owns a handle table (`objects[1]=document`, `objects[2]=window`, then a freelist). D stores `Handle` (uint). Crossing the boundary is always `extern(C)` imports on `env` plus a few exports (`_start`, `domEvent`, `allocString`, `__heap_base`).

### Events

`addEventListener` (JS) records `{ctx, fun}` on `node.wasmEvents`. The browser fires `eventHandler`, which `addObject(event)` and calls the exported `domEvent(ctx, fun, handle)`. D reconstitutes a `void delegate(Event)` from the two uints (`event.d`) and runs the annotated `@callback`. Type safety is CTFE in `addEventListenerTyped`. Promises use `libwasm_await__void` + Binaryen `--asyncify` — that is the other kernel-like import.

### Memory

`_start(heap_base)` calls `WasmAllocator.init`: bump pointer from `__heap_base`, grow in 64 KiB pages via `memory.grow`. `deallocate` is a no-op; memutils `PoolStack` / `ThreadMem` recycle within D. `gc_malloc` / `_d_allocmemory` allocate from the pool or the bump. JS `gc_*` and `free` are no-ops. Strings into JS go through exported `allocString` (NUL-terminated bump/pool).

### Asserts vs exceptions (the EH model)

`core.internal.abort` under `version(WASI)` calls imported `onAssertErrorMsg(file, line, msg)`. slideshow3dai decodes length+ptr from linear memory and **aborts**. That is the supported fatal path.

Throws go `DtoThrow` → `_d_throw_exception` (`rt/eh.d`). On LDC **1.43+** that is `llvm_wasm_throw(0, header)` so the wasm `try_table`/`catch_ref` in the same function can catch; `_Unwind_CallPersonality` sets the landing-pad selector; `_d_eh_enter_catch` unwraps the `Throwable`. On 1.36 / 1.42 there is no catchable wasm throw, so the same function still calls JS `captureException` (abort). Uncaught 1.43 throws become `WebAssembly.Exception` in the host.

`--asyncify` + `try_table` still crashes Binaryen 132 Flatten.cpp. Do not asyncify an EH module until that is fixed.

## Loci

`source/libwasm/event.d` (`domEvent`)  
`source/libwasm/rt/allocator.d` (`WasmAllocator`, `gc_*`)  
`source/libwasm/rt/eh.d` (`_d_throw_exception`, `_Unwind_CallPersonality`, `_d_eh_enter_catch`)  
`source/libwasm/rt/memory.d` (`wasm_malloc`)  
slideshow3dai `src-ts/modules/{libwasm,spa}.ts`  
`tmp/generated-druntime-wasm/js/error-handling.ts`

## Invariants

- Stack size in `ldc2.conf` (1 MiB) must match `asyncify.ts` `DATA_END`. Convention.
- New async imports must be listed on `wasm-opt --asyncify-imports`. Construction.
- Exception JS hooks must abort (or throw a JS Error the loader already treats as fatal), not `console.log`. Convention of the upgrade.

## Extension points

Adopt `installErrorHandling` in slideshow3dai / dom-ts `jsExports.env`. New DOM APIs stay handle-based.

`callTs` / `callTsPromise` (`libwasm.bridge`) invoke `window.__svelteD.ts` through Lodash. `exportDelegate` / `callNative` remain the JS→D path; `setDRet` is the return slot. Do not add a second handle table.
