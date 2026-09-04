# D IR yield — wasm-eh with Binaryen ≥123, and how await composes after the fork

The next change that wraps `.await` in `try/catch`, or runs official (non-fork) `wasm-opt --asyncify` on a `try_table` module, should read this and then **keep the two yields disjoint**.

**Guiding construction:** libwasm has two pause/resume stories. **wasm-eh** is LDC’s `try`/`catch` (`llvm_wasm_throw` + `try_table`/`catch_ref`). **asyncify** is Binaryen rewriting the module so `env.libwasm_await__void` can unwind the wasm stack into linear memory and rewind when a JS Promise settles. They are **not** the same mechanism. Binaryen **≥123 parses `try_table`** (Ubuntu apt 108 cannot). Official Flatten `--asyncify` is still **UNREACHABLE** on `try_table` in 123 **and** 132. The **etcimon/binaryen** fork Flattens `try_table` and asyncifies the wasm-eh module. They still **must not share a try** (rewind is not a landing pad). Printed D IR follows the **cell**:

| Cell | LDC | Post-link | `.await` | D `try`/`catch` |
|---|---|---|---|---|
| `ldc-master` / `application` (default) | 1.43 + `--wasm-enable-eh` | **fork** `--asyncify` then `-Oz`; stock 123/132 `-Oz` only | **off landing-pad functions** | **yes** (`rt/eh.d`, throwBoundary) |
| `ldc-1.42` | 1.42 + `--wasm-enable-eh` (abort-on-throw) | `wasm-opt --asyncify` + bulk-memory | **yes** | **no** (JS `captureException` abort) |
| `ldc-1.36` | 1.36 + `--wasm-enable-eh` (abort-on-throw) | `wasm-opt --asyncify` | **yes** | **no** (same abort) |

Svelte `async` stays out of v1. `{#await}` prints `wireAwait` (`.await` + flag, or `.then` on stock Binaryen). Kit `load` that must wait uses the same `JsPromise` handle.

```
D  try { throw e; } catch (Exception e) { … }
     LDC 1.43  --wasm-enable-eh -mattr=+exception-handling
     →  llvm_wasm_throw → try_table / catch_ref
     →  _d_throw_exception / _Unwind_CallPersonality / _d_eh_enter_catch
     Binaryen ≥123     →  parses try_table; -Oz / -g -O0
     Official Flatten  →  UNREACHABLE on try_table   (do not --asyncify)
     etcimon fork      →  Flatten + Asyncify try_table, then -Oz

D  promise.await;
     types.d:926  →  import env.libwasm_await__void
     wasm-opt --asyncify --pass-arg=asyncify-imports@env.libwasm_await__void
     JS asyncify.ts  wrapExportFn / wrapImportFn  unwind → await Promise → rewind
     without that pass  →  JS async starts and is dropped; D continues  (libwasm bug)
```

## How LDC handling breaks catches

`--wasm-enable-eh` and `-mattr=+exception-handling` ask LLVM to emit **standard wasm exception-handling** instead of “throw then `unreachable`.”

**1.36 / 1.42.** The frontend still names `_d_throw_exception` (`DtoThrow`). LLVM 17/21 on those pins do **not** emit a catchable wasm `throw` that a D `catch` can land on. `rt/eh.d:88-94` therefore calls JS `captureException` and `assert(0)`. `--wasm-enable-eh` on those cells is **not** “D catch works.” Navbar-style `try`/`catch` is dead. README’s “wasm EH currently has a bug” is this pin, not 1.43.

**1.43 / master.** `useWasmEH` / `emitCatchBodiesWasm` emit `catchpad` / `llvm.wasm.get.exception` / `try_table` / `catch_ref`. `rt/eh.d:80-86` does `llvm_wasm_throw(0, &header)` so a landing pad in the **same function** can catch. Personality is stubbed: `_Unwind_CallPersonality` sets `selector = 1` (first catch type only). Multi-type LSDA is not ported. Uncaught throws become `WebAssembly.Exception` in the host (`libwasm.ts` `_start` / `spa.ts` `domEvent`).

**`-foptimize-nothrow` (LDC 1.43 default).** Landing pads inside `nothrow` functions are deleted. Almost every printed / golden struct is `nothrow:` (`d-dom.d.tmpl:11`, `navbar.d:14`). A `try`/`catch` in a `nothrow` method **vanishes** unless the wasm-eh cell sets `--foptimize-nothrow=false` (svelte-engine `dub.sdl:27`, libwasm `ldc-master`, `spa-wasm-eh`). Full LTO + strip can delete an unused `probeCatch`. `spa-wasm-eh` uses `pragma(inline, false)` and `--export=spa_eh_probe` for that reason.

**Printed IR.** Keep `--foptimize-nothrow=false` on the wasm-eh `dub.sdl`. Do not print `try`/`catch` inside a method the author marked `nothrow` if a consumer might build without that flag. Never print `.await` inside a function that also has a landing pad (see below).

## How Binaryen `wasm-opt --asyncify` breaks those catches

Asyncify is **not** an LDC flag. `postBuildCommands` run Binaryen `wasm-opt --asyncify` on `*-raw.wasm`. The pass:

1. Finds every function that can reach `env.libwasm_await__void`.
2. Runs **Flatten** so each function is a shape Asyncify can split at the import.
3. Instruments unwind/rewind (`asyncify_start_unwind`, `asyncify_start_rewind`, …).

**Flatten does not support wasm Exception Handling.** Binaryen 123 and 132 both parse `try_table` with `--enable-exception-handling` (that is the official `-Oz` ship path). Both still hit `UNREACHABLE` in `Flatten.cpp` on `--asyncify` (same family as [binaryen#4470](https://github.com/WebAssembly/binaryen/issues/4470) Asyncify+Try, [binaryen#8372](https://github.com/WebAssembly/binaryen/issues/8372) Flatten/`try_table`). `asyncify-remove-list` of EH symbols and `asyncify-only-list` of leaf exports still Flatten-crash. That is why the default cell **never passes `--asyncify`**. `dub.sdl` still copies raw; `svelte-d wasm` then runs `wasm-opt -Oz` (release) or `-g -O0` (debug).

Even if Flatten learned `try_table`, **catch across `.await` is still unsound**:

- Unwind copies the wasm stack into linear memory at `DATA_ADDR` (524288) … `DATA_END` (1048576). Those addresses **must** match `ldc2.conf` `-Lstack-size=1048576`.
- Rewind **re-enters the export from the top** (`asyncify.ts` `wrapExportFn` calls `fn(...args)` again). Landing-pad state (`__wasm_lpad_context` in `rt/eh.d:75`) is not part of that protocol.
- A `throw` that crosses the import, or a `catch` that wraps `.await`, leaves the personality/selector and `ExceptionHeader` stack (`eh.d:30-31`, single-slot `storage`) in an undefined state.
- `ScopedPool` dtors live on the wasm stack. A reject that does **not** rewind leaks the pool; a Flatten that treats unwind as a return would **pop** the pool while the handler is paused.

So the correction is **not** “turn on both flags.” It is: **keep EH CFGs and asyncify CFGs disjoint**, and do not Flatten `try_table` until Binaryen can.

### Official post-link (measured 2026-08-15)

`findWasmOpt` requires Binaryen **≥123**. Ubuntu apt 108 cannot parse `try_table`. `bunx svelte-d setup` downloads `version_123` into `~/.svelte-d/toolchains`. The Flatten-`try_table` work lives in the **etcimon/binaryen** submodule (`binaryen/`, branch `svelte-d`); `bun run build-wasm-opt` installs it as `~/.svelte-d/toolchains/binaryen-svelte-d`. Author trees may already have stock 132 under `riscv-dev/toolchains/` — that binary still Flatten-crashes on `--asyncify`.

```text
# release (kit-admin: 1.59 MiB LDC+strip → 0.93 MiB / 224 KB gzip; 971,820 / 223,909)
wasm-opt -Oz --converge --strip-debug --strip-dwarf --strip-producers
  --enable-exception-handling --enable-bulk-memory --enable-bulk-memory-opt
  --enable-reference-types --enable-multivalue
  --enable-nontrapping-float-to-int --enable-sign-ext
  svelte-engine-raw.wasm -o svelte-engine.wasm

# debug (keep DWARF / name section)
wasm-opt -g -O0 --enable-exception-handling …same features…
```

Official 123/132 still do **not** put `--asyncify` on that line. The etcimon fork does, then `-Oz`. Flatten+asyncify on `try_table` is **green** on the fork (catch_all and valued dest at `--optimize-level=0`; kit-admin raw asyncifies). The printer rule stays: a function that `throw`s/`catch`es must not **wrap** `.await`.

## libwasm implementation bugs (the glue, not Flatten)

These were in **libwasm’s** await/asyncify implementation and the engine copies. Engine `src-ts/modules/` now implements the sound path. libwasm `examples/dom-ts` and `types.d` remain a **titled libwasm seam**.

1. **`.await` is a silent no-op without Asyncify.** `await()` still imports `libwasm_await__void`. Without Binaryen instrumentation the import returns immediately. **Fix:** printed `wireAwait` calls `libwasmAwaitSupported()` (JS `asyncify_get_state`) and falls back to `JsPromise.then`. A bare `.await` on stock 123/132 is still a no-op.

2. **`finally` swallowed rejection.** Old JS did `promise.finally(() => resolve(null))` so D never saw fail. **Fix:** record reject on `await-status.ts` (`libwasmAwaitFailed` / `__svelteDLastAwait`) and still resolve so rewind happens. D settles `{:catch}` *after* the import. `wrapExportFn` also rewinds if the Promise it awaits rejects.

3. **`_start` must be wrapped.** `EXPORTED_FROM_D` includes `_start` so `ready` → `wireAwait` → `.await` rewinds.

4. **`wrapExportFn` must keep `WebAssembly.Exception`.** It rethrows the original. `__svelteDRewriteError` only rewrites the *text* for DevTools.

5. **`callNative` must `await jsCallback`.** Done. Overlapping exports are queued (one unwind).

6. **`eventHandler` must not `forEach(async)`.** Serial `for` + `await domEvent`.

7. **Promise handles skip the freelist** (`libwasm_removeObject`). Convention leak, not EH.

## What svelte-d must print (functionally memory- and yield-correct D IR)

- **wasm-eh cell (default):** `wireAwait` prints `job.await` plus `libwasmAwaitFailed()` settle when asyncify is present; else `JsPromise.then` / `.error`. `{:catch e}` `{e}` is assigned from `libwasmAwaitError()` after rewind (stock `.error` calls `libwasmNoteAwaitFail` first). Sync D `try`/`catch` / `throwBoundary` in functions that never reach `libwasm_await__void` (navbar `onClick`, printed `throwBoundary`). The etcimon/binaryen fork asyncifies the **module** so those catches still run (`svelte_engine_eh_probe` == 1). Do not wrap `.await` in `try`.
- **asyncify cells (1.36 / 1.42):** `.await` allowed in `@connect` / `onMount` / `ready` **without** a landing pad around the import. Wrap with `ScopedPool`; copy survivors before the await returns ([AGENTS-D-IR-memory-management.md](AGENTS-D-IR-memory-management.md), [AGENTS-D-IR-lifetime.md](AGENTS-D-IR-lifetime.md)).
- Never print `.await` in `construct` / `compile!` / `_start` / `registerRoutes` / `throwBoundary`.
- Never print Svelte `async` (v1 out of scope). `{#await}` *is* printed as `wireAwait`.
- Generated `dub.sdl` must not emit `--asyncify` on `ldc-master` / `application` (svelte-d wasm does that when the fork is installed). Must emit `--foptimize-nothrow=false` on that cell.

## Loci

`libwasm/source/libwasm/types.d:181,925-928` — import + `await()`  
`libwasm/source/libwasm/rt/eh.d:80-118` — throw / personality / enter_catch  
`libwasm/source/libwasm/spa.d:5-7` — `__VERSION__` 2106 / 2112 / 2113  
`libwasm/architecture/{flags,js-events-memory,wasm-eh-test}.md`  
`libwasm/tests/spa-wasm-eh/` — catch probe; **no** asyncify  
`libwasm/examples/dom-ts/src-d/app.d:102-129` — `.await` under `nothrow` (1.36-shaped)  
`svelte-engine/dub.sdl:20-66` — copy-raw then svelte-d `wasm-opt` (fork `--asyncify` then `-Oz`; stock `-Oz` only)  
`svelte-engine/src-ts/modules/asyncify.ts` — `DATA_*`, `EXPORTED_FROM_D`, queue, rewind-on-reject  
`svelte-engine/src-ts/modules/await-status.ts` — last-await flag  
`svelte-engine/src-ts/modules/libwasm.ts` — `_start`, `libwasm_await__void` / `_supported` / `_failed`  
`svelte-engine/src-d/await_status.d` — D view of those imports (`_supported` / `_failed` / `_error` / `_note`)  
`svelte-engine/src-d/navbar.d:25-35` — sync `try`/`catch` (wasm-eh golden)  
Binaryen `src/passes/{Flatten.cpp,Asyncify.cpp}`; issues #4470, #8372  

## Invariants

- Official 123/132: do not `--asyncify` `try_table` (Flatten UNREACHABLE). Fork `binaryen-svelte-d`: asyncify then `-Oz`. (construction)
- wasm-eh cell keeps `--foptimize-nothrow=false` or D `catch` is deleted. (construction of 1.43)
- Printed `.await` is gated by `libwasmAwaitSupported()`; stock modules keep `.then`. (construction of the yield protocol)
- A function with a landing pad must not **wrap** `libwasm_await__void`. After rewind, same-function flag checks are fine. (construction of catch/asyncify disjointness)
- `DATA_END` == `ldc2.conf` stack size. (convention)
- New pausing imports append to `--asyncify-imports`. Status queries (`_supported` / `_failed`) are sync and stay off that list. (construction)
- One in-flight Asyncify unwind (`wrapExportFn` queue). (construction of `asyncify.ts` state)

## Extension points

JSPI (`WebAssembly.promising`) would replace Binaryen Asyncify; that is a new glue ABI, not a printer flag.

## Did not close

`asyncify-remove-list` of EH symbols and `asyncify-only-list` of leaf exports still Flatten-crash on Binaryen 123 and 132 (measured). Whether a later Flatten that understands `try_table` lands, or 1.43 grows a **second** imported await that JSPI wraps while EH stays native. Whether `ExceptionHeader` should be a stack, not a single `__gshared` slot, before any catch-across-await experiment.
