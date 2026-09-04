# Stubbing the missing kernel

## How it works

Stock druntime assumes an OS kernel: a GC, threads, `_d_run_main`, ModuleInfo (`__minfo`), dwarf/msvc unwind, and POSIX/Win32. None of that exists in the browser. libwasm **omits** those files (604 of 753 LDC 1.36 sources) and **replaces** the few symbols the frontend still emits.

| Kernel | LDC files (group) | What runs instead |
|---|---|---|
| GC | 10 missing + `core/memory.d` adapted | `WasmAllocator` bump + `memory.grow`; JS `gc_*` no-ops; D `gc_malloc` → `_d_allocmemory` |
| Threads | 16 missing | single-threaded; no `core.thread` / `core.sync` |
| Bootstrap | 18 missing | `mixin Spa!_start(uint heap_base)`; `-fno-moduleinfo` |
| EH | stock `dwarfeh` / `eh_msvc` omitted | `libwasm.rt.eh._d_throw_exception` → `llvm_wasm_throw` on 1.43+; JS `captureException` on 1.36/1.42 |
| OS | 388 missing | `core/sys/wasi/*` (extra) + JS `getTimeStamp` / DOM |
| libc | 12 missing, 22 kept | `core/stdc` subset + JS `snprintf` / `memset` in D |
| Phobos I/O, conc | still omitted | DOM, fetch, no stdio/process/socket/threads |
| Phobos math / other | **1.43+ emitted** | `std.numeric` / `complex` / `mathspecial` / `json` / `regex` / `random` / `datetime.date` … |
| CTFE keep | 0 missing | `std.algorithm` / `traits` / `meta` / `format` / `range` … |

LDC’s frontend still calls `_d_throw_exception` (`DtoThrow` in `gen/llvmhelpers.cpp`) and `_d_assert_msg`. Those are the only EH/assert hooks that must exist. Everything else is either CTFE (erased at compile time) or never referenced because `-fno-moduleinfo` and `-defaultlib=` cut the rest.

`object.d` pretends Glibc+Posix in a comment but **static-asserts** `CRuntime_LIBWASM`. The wasm `ldc2.conf` sets `-d-version=CRuntime_LIBWASM` and `-Iimport-libwasm` so this file wins over LDC `import/object.d`.

## Loci

`druntime-wasm/object.d`  
`source/libwasm/rt/{eh,stubs,allocator,memory}.d`  
`source/libwasm/spa.d` (`_start`)  
`tmp/runtime-adapt-report.md` (inventory)

## Invariants

- Do not link stock `druntime-ldc` / `phobos2-ldc` on wasm. Construction (`-defaultlib=`).
- Do not restore ModuleInfo without implementing `__minfo`. Construction.
- Do not wholesale-copy LDC `import/std` for **file/socket/process/concurrency**. Convention — those still need a kernel. 1.43+ carry *does* emit exception-using Phobos (`numeric`, `json`, `regex`, …) from stock, not from LDC `import/`.

## Extension points

A new frontend implicit (`_d_*`) needs either a D stub in `libwasm.rt` or a JS `env` import. Record it in `tools/runtime-adapt/source/kernel.d` so generate keeps the catalog.
