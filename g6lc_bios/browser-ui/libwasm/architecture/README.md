# Architectural notes — libwasm

Produced by analysis of this tree. Each note is addressed to the next change.

```
pin:            02f21a6 (v0.9.0-11-g02f21a6)
upstream:       https://github.com/etcimon/libwasm.git
ldc_required:   default 1.43.0 (`__VERSION__` 2106 / 2112 / 2113 in `source/libwasm/spa.d`)
runtime:        default `runtime-v1.43.0` (wasm EH + Phobos); pin `druntime-wasm/` is 1.36 FILE-CMP
persistence:    untracked-local
riscv_affinity: none (WASM / WASI; no RISC-V claim)
```

| Note | Area | State |
|---|---|---|
| [overview.md](overview.md) | SPA + JS glue + custom runtime | current |
| [ldc-136.md](ldc-136.md) | Why 1.36.0; BUILDING.md; replacing LDC defaultlibs | current |
| [runtime-vs-ldc.md](runtime-vs-ldc.md) | druntime-wasm vs stock LDC 1.36 | current (inventory via runtime-adapt) |
| [stub-kernel.md](stub-kernel.md) | Omitting OS/GC/threads/EH; what replaces them | current |
| [js-events-memory.md](js-events-memory.md) | Handle table, WasmAllocator, assert-shaped EH | current |
| [ctfe-apps.md](ctfe-apps.md) | mixin Spa / GetCss interactive apps | current |
| [runtime-adapt.md](runtime-adapt.md) | D/dub + libdparse (serve-d parser) generate tool | current |
| [upgrade-ldc.md](upgrade-ldc.md) | 1.42 + wasm-eh; reapply 22 adapts | current |
| [wasm-eh-test.md](wasm-eh-test.md) | slideshow-shaped SPA vs LDC master wasm-eh | current |
| [spa-phobos-test.md](spa-phobos-test.md) | 1.43 default + major Phobos through wasm | current |
| [flags.md](flags.md) | dflags / lflags / wasm-opt --asyncify | current |
| [build-test.md](build-test.md) | dub + ldc2.conf + Binaryen | current |
| [open-questions.md](open-questions.md) | Unclosed WASM / EH / Phobos | current |
