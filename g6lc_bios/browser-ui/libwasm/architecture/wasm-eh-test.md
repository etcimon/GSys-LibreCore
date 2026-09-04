# wasm-eh test (LDC master)

## How it works

`tests/spa-wasm-eh` is a **slideshow-shaped** libwasm SPA (`mixin Spa!App`, NodeDef tree, `construct`, hmr, `wasm-opt --asyncify`). It exists to prove D `try`/`catch`/`throw` against **LDC master** from `riscv-compilers/ldc2`, not to replace slideshow3dai.

The runner `tests/spa-wasm-eh/run.ps1`:

1. **Source probe.** This checkout implements wasm-eh if `useWasmEH()`, `emitCatchBodiesWasm`, `ExceptionHandling::Wasm`, and `--wasm-enable-eh` are present (`gen/irstate.cpp`, `gen/trycatchfinally.cpp`, `driver/targetmachine.cpp`, `driver/cl_options.cpp`). Master CHANGELOG: “WebAssembly: Exceptions are now supported.” If the needles are missing, the cell **skips** (`-SkipIfMissing` → exit 0, else exit 2).
2. **Build the compiler.** `ninja -C riscv-compilers/ldc2-build ldc2` (the recorded green tree). Does not cold-cmake; configure is `ldc2/AGENTS.md`.
3. **IR probe.** Compile `probe-wasm-eh.d` with that `ldc2` (`-mtriple=wasm32-unknown-wasi --wasm-enable-eh -output-ll`). Must contain `catchpad`, `llvm.wasm.get.exception`, and `+exception-handling`. Throw still goes through `_d_throw_exception` (`DtoThrow`).
4. **Carry.** `runtime-adapt --carry --ldc-tag v1.43.0 --stock-root ../ldc2` → `libwasm/runtime-v1.43.0` (gitignored).
5. **SPA package.** `dub build --arch=wasm32-unknown-wasi --compiler=<master ldc2> --config=ldc-master --build=release`. Helpers use `subConfiguration … ldc-master` (`-I runtime-v1.43.0`). Linked `*-raw.wasm` contains standard wasm EH (`try_table` / `catch_ref`). Binaryen 132 `--asyncify` still crashes Flatten.cpp on that mix — not part of this cell.

`spa.d` accepts `__VERSION__` 2113 (DMD 2.113 / LDC 1.43).

## Loci

`tests/spa-wasm-eh/{run.ps1,dub.sdl,src-d/app.d,probe-wasm-eh.d}`  
`libwasm/dub.sdl` configuration `ldc-master`  
`riscv-compilers/ldc2/gen/trycatchfinally.cpp` `emitCatchBodiesWasm`  
`riscv-compilers/ldc2-build/bin/ldc2.exe`

## Invariants

- Do not treat 1.36 `--wasm-enable-eh` as this cell; that path is still abort-on-throw. Construction.
- Skip (do not fail) when the LDC tree has no wasm-eh. Convention of “if implemented in that version”.
- Do not inherit stock `import/` on the wasm triple. Construction.

## Open

`rt/eh.d` implements throw (`llvm_wasm_throw`), `_Unwind_CallPersonality` (selector = 1), and `_d_eh_enter_catch`. `run-node.mjs` calls exported `spa_eh_probe` and expects 1 (D catch ran). Do not mark `probeCatch` `nothrow` and do not LTO-strip it — 1.43 `-foptimize-nothrow` deletes catch. Multi-type LSDA scan is not ported. Binaryen 132 `--asyncify` still cannot Flatten `try_table`.
