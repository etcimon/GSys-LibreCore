# libwasm — in-tree queue

**Thesis:** 1.43 is the default EH-capable runtime. Carry emits exception-using Phobos; file/socket/process/concurrency stay kernel-omitted.

**Current state:** `library` / helper defaults point at `runtime-v1.43.0`. Pin `druntime-wasm/` remains the 1.36 FILE-CMP source (`--config=ldc-1.36`).

**wasm-eh cell (2026-08-13):** `tests/spa-wasm-eh/run.ps1` PASS on LDC 1.43.0-git-1218a47. `rt/eh.d` throws via `llvm_wasm_throw`; Node `spa_eh_probe` returns 1 (D catch). Selector is still “first catch type” (no LSDA). Binaryen 132 asyncify still crashes Flatten.cpp on `try_table`.

**Phobos cell (2026-08-13):** `tests/spa-phobos/run.ps1` PASS. 1.43 carry emits exception-using Phobos (`numeric`/`complex`/`mathspecial`/`json`/`regex`/…). Node `spa_phobos_probe==1` for conv/format/algorithm/numeric/math/complex/random/typecons + D catch. `std.json` / `std.regex` / `Date` ctor still flaky on the bump allocator; file/socket/process/concurrency stay omitted.

**HMR lists (2026-08-14):** `hmr.d` dump/load serializes `List`/`HTMLArray` as `:l:N:[{item}…]`. New items are `ThreadMem` + `Item.init` then `put`. `ManagedPool` still skipped.
