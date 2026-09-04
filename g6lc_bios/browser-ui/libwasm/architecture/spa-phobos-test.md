# spa-phobos test (LDC 1.43 default + exception-using Phobos)

## How it works

`tests/spa-phobos` is a **spa-wasm-eh-shaped** libwasm SPA (`mixin Spa!App`, NodeDef tree, `construct`). It exists to prove that the **1.43 carry** emits the Phobos modules that were omitted only because wasm EH was missing, and that those modules run under Node.

The runner `tests/spa-phobos/run.ps1`:

1. **Source probe.** Same wasm-eh needles as `spa-wasm-eh` (`useWasmEH`, `emitCatchBodiesWasm`, `ExceptionModel=Wasm`). Skip if missing.
2. **Re-carry.** Always `runtime-adapt --carry --ldc-tag v1.43.0 --stock-root ../ldc2`. 1.43 emit keeps `std.numeric` / `std.complex` / `std.mathspecial` / `std.json` / `std.regex` / `std.random` / `std.datetime.date` / … File/socket/process/concurrency and dwarf unwind stay omitted.
3. **SPA package.** `dub build --arch=wasm32-unknown-wasi --compiler=<master ldc2> --config=ldc-master --build=release`. The 1.43 `druntime-wasm` recipe compiles the exception-using Phobos set and excludes logger / experimental allocator / POSIX `systime`/`timezone` / `stdatomic`.
4. **Node.** `run-node.mjs` instantiates the raw module (Proxy `env` + `__cpp_exception` tag) and calls `spa_phobos_probe`. Expects `1`.

`probe.d` is a separate module **without** `nothrow` (1.43 `-foptimize-nothrow` deletes landing pads). `pragma(inline, false)` + `--foptimize-nothrow=false`. Node `spa_phobos_probe` returns 1 when these slices pass:

- `throw`/`catch` Exception
- `std.conv.to!int` + `ConvException`
- `std.format` (CTFE `format!"%d"`)
- `std.algorithm` / `std.range` (`iota`/`map`/`sum`)
- `std.numeric.gcd` (the old 1.36 hole)
- `std.mathspecial.gamma` (CTFE) + `std.math` `exp`/`log`
- `std.complex`
- `std.random` (`Mt19937`/`uniform`)
- `std.typecons` (`Tuple`/`Nullable`)

Compiled into `runtime-v1.43.0` but **not** required at runtime in this cell: `std.json` (heap-sensitive), `std.regex` (OOB on this allocator), `std.datetime.date.Date` ctor (faults; `Clock.currTime` is POSIX and omitted). File/socket/process/concurrency stay kernel-omitted.

## Loci

`tests/spa-phobos/{run.ps1,dub.sdl,src-d/app.d,run-node.mjs}`  
`tools/runtime-adapt/source/{emit,principles,versions,kernel}.d`  
`libwasm/dub.sdl` configuration `library` / `ldc-master` → `runtime-v1.43.0`

## Invariants

- Do not inherit stock LDC `import/` on the wasm triple. Construction.
- Do not import `std.file` / `std.stdio` / `std.socket` / `std.concurrency` — those are still kernel, not EH. Convention.
- Do not import `std.datetime` package (pulls systime/timezone POSIX clocks); use `std.datetime.date`. Convention.
- Keep `-fno-moduleinfo`. Construction.

## Open

Binaryen 132 `--asyncify` still cannot Flatten `try_table`. Multi-type LSDA scan is not ported. `std.datetime.systime` / logger / experimental allocator stay unimported.
