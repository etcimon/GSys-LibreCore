# Open questions

1. DUB 1.35.1 (LDC 1.36 bundle, 2024-01-06) ran; BUILDING asked for post-2024-01-10 — no evidence that was the failure.
2. WASM EH (`--wasm-enable-eh`) still buggy on 1.36 — which slideshow3dai / navbar exception paths explode? Target: assert-shaped `captureException` abort (`js-events-memory.md`) then 1.42 (`upgrade-ldc.md`).
3. `CRuntime_DRUNTIME_WASM` vs `CRuntime_LIBWASM` mismatch in `druntime-wasm/dub.sdl`.
4. Phobos I/O / concurrency still omitted (kernel). 1.43+ carry emits exception-using Phobos; `tests/spa-phobos` is the cell. Do not copy stock `std.file` / `std.socket`.
5. Full `yarn dev` / webpack cell unrun (JS side). Adopt generated `js/error-handling.ts` when that cell runs.
6. `wasm-opt --asyncify` vs LLVM 17 (and later 21) EH composition untested.
7. Generated `tmp/generated-druntime-wasm/` not yet swapped in for `druntime-wasm/` — compare-only until a wasm compile cell matches.
8. `--carry` FILE-CMP still shows ~22 `missed-libwasm` (adapted files without a taught splice: `core/demangle.d`, `std/traits.d`, …). Teach `adapt.d` or leave as pin-only until a wasm cell needs them.
