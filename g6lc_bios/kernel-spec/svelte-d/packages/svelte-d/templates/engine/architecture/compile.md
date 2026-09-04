# Compilation (libwasm + LDC 1.36 / 1.42 + Binaryen)

## How it works

Follow libwasm `BUILDING.md`, then this package’s `dub.sdl`.

**Default cell is wasm-eh** (`configuration "application"` = LDC master / 1.43, `subConfiguration "libwasm" "ldc-master"`, copy-raw then svelte-d `wasm-opt`: fork `--asyncify` then `-Oz`, stock 123/132 `-Oz` only). Named alternates: `ldc-1.42`, `ldc-1.36`.

**Debug vs release.** `buildType "debug"` keeps symbols (name section + DWARF) and `wasm-opt -g -O0` still parses `try_table`. `buildType "release"` is optimize + `lflags -strip-all` then `wasm-opt -Oz --converge --strip-*`. `svelte-d wasm` / `svelte-d build` use release; `svelte-d wasm --debug` and `bun run dev` use debug. On the kit-admin tree that is 12.64 MiB debug wasm versus **0.93 MiB** / 224 KB gzipped shipped. The host `webserver/dub.sdl` has the same pair (`--debug` default, `--release` + `/OPT:REF` on Windows).

**1. Compiler and conf.** Use LDC 1.36.0. BUILDING.md’s empty `post-switches` alone fails the dub platform probe (`cannot find object.d`). This workspace sets `post-switches = -I%%ldcbinarypath%%/../import-libwasm` and `-d-version=CRuntime_LIBWASM`. The junction `import-libwasm` → `libwasm/druntime-wasm`, so **`object.d` is libwasm’s**, not LDC `import/object.d`. `-defaultlib=` is already empty in the 1.36 Windows package.

**2. Resolve libwasm without `path:`.** Upstream assumed a sibling `../libwasm`. This checkout uses `version="~>0.9.0"` for `libwasm`, `memutils-wasm`, `fast-wasm`, `diet-wasm`. `setenv-wasm.ps1` does `dub add-local` on `riscv-compilers/libwasm` (and its inner packages). libwasm’s *own* `path=./memutils-wasm` deps stay path-local inside that clone.

**3. LDC command** (what dub will run):

```text
ldc2 --arch=wasm32-unknown-wasi
  --wasm-enable-eh -mattr=+exception-handling
  -fvisibility=hidden -flto=full -fno-moduleinfo
  -L-strip-all
  -of=public/slideshow3dai-raw.wasm
  src-d/*.d
```

plus libwasm sources pulled in as a library. Versions: `hmr`. String imports: `src-d-views`.

**4. Binaryen post-build** (must be on PATH):

```text
wasm-opt --asyncify --pass-arg=asyncify-imports@env.libwasm_await__void
  public/slideshow3dai-raw.wasm -o public/slideshow3dai.wasm
```

This is Binaryen (`WebAssembly/binaryen`), not wasm-pack. `--asyncify` rewrites the module so `env.libwasm_await__void` may yield. Stack size 1 MiB in `ldc2.conf` must stay aligned with `asyncify.ts` `DATA_END`.

**5. JS shell.** `yarn` / `npm run dev` (Vite). Not required to prove the D/wasm cell.

Flag meanings are in libwasm `architecture/flags.md` (carried here by reference to that file’s facts, not a path).

## Loci

`dub.sdl`  
`BUILDING.md` in the libwasm clone  
`src-ts/modules/asyncify.ts`  
`setenv-wasm.ps1` (workspace, untracked)

## Invariants

- `targetName` `slideshow3dai-raw` vs postBuild output `slideshow3dai.wasm` — do not rename one without the other.
- add-local semver is `0.9.0` to satisfy `~>0.9.0`. Do not register `~master`.

## Open questions

**LDC 1.42 cell** (`--config=ldc-1.42 --build=release`): libwasm
`runtime-v1.42.0` (carry: stock-N ClassInfo + taught splices + pin WASI).
`dub.selections.json` pins `druntime-wasm` at that tree. Helpers use
`subConfiguration … ldc-1.42` so they `-I runtime-v1.42.0`, not
`druntime-wasm`. Link uses `-flto=thin` (full LTO + debug DI aborts LLVM 21).
`wasm-opt` needs `--enable-bulk-memory{,-opt}` for LLVM 21 `memory.copy`/`fill`.
Validated 2026-08-13: `public/slideshow3dai-raw.wasm` + asyncify
`public/slideshow3dai.wasm`.

Helpers (memutils/fast/diet/optional) PASS on 1.36. Default `application`
config still blocked on pin `std.numeric` if gammafunction is compiled.

**LDC master / 1.43 cell** (`--config=ldc-master --build=release`):
`runtime-v1.43.0`, `--foptimize-nothrow=false`, no LTO. Official Binaryen
123/132 Flatten.cpp is UNREACHABLE on `try_table`. The etcimon fork
(`binaryen/` `svelte-d`) `--asyncify`s then `-Oz`. Stock 123/132 stay
`-Oz` / `-g -O0` with `--enable-exception-handling`. TS
`error-handling.ts` installs `__cpp_exception`; `instantiate()` wraps
when `asyncify_get_state` exists. `wireAwait` uses `.await` then, else
`JsPromise.then` (see svelte-D
[AGENTS-D-IR-asyncify-wasm-eh.md](../../architecture/AGENTS-D-IR-asyncify-wasm-eh.md)).
Probes: `slideshow_eh_probe` /
`slideshow_phobos_probe` (`src-d/probe.d`). Runner:
`build-ldc-master.ps1` then `node run-probes.mjs`.
