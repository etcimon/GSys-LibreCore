# slideshow3dai — what the reference app already proves

The next change that “rewrites slideshow3dai in Svelte” or treats it as a stub should read this. The **product UI** is a stub. The **toolchain surface** is complete. svelte-D’s first golden is the toolchain, not the product list in `app.d:12-32`.

This worktree copy has **no nested `.git`**. The `0b130ee` string in `AGENTS.md` is a **documented header, unverifiable here**. File:line claims match the files on disk. Upstream is `https://github.com/etcimon/slideshow3dai`. It is two programs that share a name.

**Browser/WASM.** `src-d/` + `src-d-views/` + `src-ts/` + root `dub.sdl`. `mixin Spa!App` in `src-d/app.d:11`. `@child` NavBar / Main / Dock. Diet under `src-d-views/` (`home.dt` is an Onsen-era fragment, still a string-import path). JS glue is `src-ts/modules/{libwasm,asyncify,spa,bindings,error-handling}.ts`. Vite + Tailwind + daisyUI + Capacitor wrap the wasm. Versions `hmr`. `targetName` `slideshow3dai-raw`; postBuild writes `slideshow3dai.wasm`.

**Configs (do not invent `ldc-1.36`):**

| App config | What it is | `subConfiguration "libwasm"` | asyncify |
|---|---|---|---|
| `application` (default) | historically the 1.36 cell; **no** libwasm sub-config | **absent** — on libwasm HEAD `64a97ce` this pulls default `"library"` = **1.43** | yes (`wasm-opt --asyncify`) |
| `ldc-1.42` | thin LTO + bulk-memory (validated 2026-08-13) | `"ldc-1.42"` | yes |
| `ldc-master` | EH/Phobos probes | `"ldc-master"` | **no** (copy raw→final) |

svelte-D’s generated recipe for `wasmCell=ldc-1.36` must **not** copy `application`. It must be a new app config named `ldc-1.36` with `subConfiguration "libwasm" "ldc-1.36"`.

**Host server.** `webserver/` is a separate vibe-0 + memutils + botan executable. Newer host LDC. **Not** compiled with LDC 1.36 / libwasm. `VibeCustomMain`. HTTPS `:8180`, Botan TLS, Redis sessions, `registerWebInterface` InstallationAPI + UserAPI, `reverseProxyRequest` `*` → `localhost:5173` (`webserver/source/app.d:55-63`). `listenHTTP` + `runEventLoop()`.

**HMR.** Vite plugin watches `src-d/*.d`, `src-d-views/*`, `public/*.wasm` (`vite.config.js:67-69`), runs `dub build --arch=wasm32-unknown-wasi`, WS `:3001` sends `reload` / `full-reload`. Client `spa.ts` dumpApp/loadApp.

**JS runtime.** Handle table `{1: document, 2: window}`. String encode/decode through the WASM heap. `libwasm_await__void`. `asyncify.ts` Apache-2.0 Google. `DATA_END = 1048576`.

**Maps.** `generateSourceMap.py` sketches wasm-objdump → D; incomplete; file header duplicated. Do not treat as a working map pipeline.

**Env.** Front-end resolution is `setenv-wasm.ps1` (`dub add-local` libwasm `0.9.0`). Host is `setenv.ps1`. Do not mix.

## What svelte-D may use it for

1. `PassthroughD` fixture: **copy** `src-d/*.d` into `packages/svelte-d/fixtures/slideshow-app/` (this tree has no nested git). Drive a svelte-D `dub.sdl` (see table), not the live checkout.
2. HMR compatibility: keep `:3001` and string opcodes until bun owns the socket.
3. Glue templates (copy with attribution).
4. Host-printer shape: `main` + `URLRouter` + TLS + proxy + `registerWebInterface`.
5. Negative tests: stock Binaryen 123/132 must not asyncify `try_table`; the fork may. Raw vs final names must stay paired.

## What it does not prove

File-based routing, SSR, load/actions, `$app/*`, incremental IR cache, source maps, Svelte parser fidelity, vibe.0 green on this Windows host, `navbar.d` Exception + PgLite under 1.36 wasm-eh (open in that app’s notes).

## Loci

`src-d/app.d` — `mixin Spa!App`, product comment list, `ManagedPool`  
`src-d/navbar.d` — real UDA surface (`@child`, `@callback`, `@connect`, `Slot`, `UnorderedList`, `Exception`)  
`src-d/dock.d`, `pglite.d`, `probe.d`  
`dub.sdl` — flags, three configs  
`vite.config.js:36-136`  
`src-ts/modules/*`  
`webserver/source/app.d`, `webserver/dub.sdl`  
`architecture/{overview,compile,open-questions}.md`  
`package.json` — Vite 6, lodash, moment, PgLite, Capacitor 7, daisyUI  

## Invariants

- Two programs, two compilers. (construction)
- `slideshow3dai-raw.wasm` ≠ the file JS fetches on 1.36/1.42. (construction)
- svelte-D v1 must not become a required input to this app’s existing `dub.sdl` / Vite flow. Rollback is “delete `.svelte-d/`.” (convention of the rollout)
- Do not rewrite this app in a compiler PR. (convention)

## Extension points

A later *product* pass may add `src/routes` beside `src-d`. That is a slideshow3dai change, not a svelte-D compiler change.

## Did not close

Copied fixture is **closed** (PR3/PR4). Capacitor remains out of svelte-D v1.
