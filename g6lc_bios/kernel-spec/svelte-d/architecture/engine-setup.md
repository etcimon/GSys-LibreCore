# Engine setup — one LDC 1.43 (Windows / macOS / Linux)

The next change that installs a second LDC (1.42) for the host cell, or that points wasm at a different `ldc2` than the CLI, should read this and stop.

**Guiding construction:** one **LDC 1.43+** binary compiles (1) the svelte-d CLI, (2) the vibe.0 host in `svelte-engine-ws/webserver`, and (3) the wasm-eh cell in `svelte-engine-ws`. Wasm vs host stay different *targets* (wasm32-unknown-wasi vs native; cleared `DFLAGS` / `DC`; no shared `.o`). They share this compiler. `bunx svelte-d setup` finds or downloads that LDC for the current OS/arch.

```
bunx svelte-d setup             →  LDC 1.43 + fork wasm-opt (binaryen-build/ + toolchains) + openssl add-local
bun run build-wasm-opt          →  cmake the etcimon/binaryen submodule (author-only)
bun install / bun run build     →  LDC 1.43  →  packages/svelte-d/bin/svelte-d
svelte-d drop-ws / compile      →  pin ws/.svelte-d/wasm-ldc.json to that ldc2
svelte-d wasm --ws <ws>         →  same ldc2 + fork wasm-opt --asyncify then -Oz
svelte-d host --ws <ws>         →  same ldc2  →  ws/webserver/svelte-engine-server
```

## Why 1.43 only

Navbar-style `try`/`catch` and printed `throwBoundary` need `try_table` / `catch_ref`. LDC 1.42 does not emit that for wasm. Keeping a second host compiler was extra machinery (two PATH cells, two toolchain folders, Windows-only `setenv.ps1` 1.42). Official 1.43 prebuilts exist for Windows x64, Linux x86_64/aarch64, and macOS x86_64/arm64.

## Discovery

`findLdc` (`ts/platform.ts` + `workspace/ldc.d`) resolves, in order:

1. `SVELTE_D_LDC` / `LDC` / `WASM_LDC` / `DC` if that binary’s `--version` is 1.43+.
2. `SVELTE_D_TOOLCHAINS` or `~/.svelte-d/toolchains/ldc2-1.43*`.
3. Walk for `riscv-compilers/ldc2-build/bin/ldc2` (this repo’s master/wasm-eh cell).
4. Walk `toolchains/ldc2-1.43*` / `ldc2-master*` next to the engine host.
5. `ldc2` on `PATH` **only** when `--version` is 1.43 or later (1.42 is refused).

`findHostLdc` and `findWasmLdc` are aliases of `findLdc`.

## `svelte-d setup`

Works **before** the native exe exists (`bin/svelte-d.ts` runs `scripts/setup-platform.ts`):

- Detects `windows-x64` / `linux-x86_64` / `linux-aarch64` / `osx-x86_64` / `osx-arm64`.
- Downloads official `ldc-developers/ldc` **1.43.0-beta1** (override `SVELTE_D_LDC_VERSION`) into `~/.svelte-d/toolchains` when nothing is found.
- Downloads the CI-built **etcimon/binaryen** `wasm-opt` (release `wasm-opt-svelte-d`) into `binaryen-build/<triple>/` + `~/.svelte-d/toolchains/binaryen-svelte-d`. Official Binaryen ≥123 is the fallback. `--no-download` / `SVELTE_D_NO_DOWNLOAD=1` skips the fetch.
- If the **`binaryen/` submodule** is checked out and CMake is on PATH (or `CMAKE`), `SVELTE_D_BUILD_WASM_OPT=1 bun run setup` or `bun run build-wasm-opt` compiles the fork locally.
- `dub add-local` for a live `libwasm` checkout (`~master`) and, when present, the vibe.0 host graph. **openssl ~>3.3.4** is cloned from `github.com/etcimon/openssl` when missing (vibe-0 1.2.1 `library-manual-link` is not on the DUB registry).
- Without checkouts: wasm `dub.sdl` still `repository="git+https://github.com/etcimon/libwasm.git"`; host `vibe-0` comes from the DUB registry.

Windows extract of the official `.7z` needs 7-Zip. Unix uses `tar -xJf`.

## Loci

`packages/svelte-d/ts/platform.ts` — triple, find, download LDC + forked `wasm-opt` (`darwin-arm64` on Apple Silicon) from the rolling Release, `wasm-opt-binaries` branch, or CI artifacts (`nightly.link`); `buildWasm` / `bunx svelte-d wasm` call `ensureForkedWasmOpt` before the dest engine post-link. A pulled fork does **not** compile Binaryen (`shouldBuildWasmOptFromSource`; set `SVELTE_D_BUILD_WASM_OPT=1` to force).  

`packages/svelte-d/ts/native.ts` — dest `buildWasm` pins `SVELTE_D_WASM_OPT` to that fork  

`binaryen/` — submodule `https://github.com/etcimon/binaryen` branch `svelte-d`  
`scripts/setup-platform.ts` — `bun run setup` / `bunx svelte-d setup`  
`packages/svelte-d/source/svelte_d/workspace/ldc.d` — D `findLdc`  
`packages/svelte-d/source/svelte_d/workspace/wasm_build.d` — `findWasmLdc` → `findLdc`; `findWasmOpt` + `-Oz` / `-g -O0`  
`packages/svelte-d/source/svelte_d/workspace/host_build.d` — `findHostLdc` → `findLdc`  
`scripts/build-cli.ts` — CLI build; setup-if-missing  
[package.md](package.md)

## Invariants

- One LDC 1.43+ compiles CLI, host, and wasm. Never silently fall back to 1.42. (construction)
- Wasm objects and host objects still do not mix (cleared `DFLAGS`/`DC` per cell). (construction)
- Official 123/132 must not `--asyncify` `try_table`. The fork wasm-opt (binaryen-build / binaryen-svelte-d) does, then `-Oz`. (construction)
- Packaged engine `dub.sdl` keeps `subConfiguration "libwasm" "ldc-master"`. (construction)

## Did not close

Official pin is **1.43.0-beta1** until a final 1.43.0 tarball is published (`SVELTE_D_LDC_VERSION` overrides). WASI addon packages from that release are not fetched (engine still uses libwasm’s own wasm runtime). System OpenSSL/sqlite on macOS/Linux for vibe.0 is assumed present when there is no riscv-dev checkout.
