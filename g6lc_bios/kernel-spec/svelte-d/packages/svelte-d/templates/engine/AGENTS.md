# svelte-engine — Agent Guider

```
id: svelte-engine
kind: bootstrap copy of slideshow3dai (pin 0b130ee files; not a nested clone)
purpose: target D IR + wasm-eh SPA + vibe.0 host for svelte-D
default_wasm_cell: LDC 1.43 / master + runtime-v1.43.0 (wasm-eh, no asyncify)
host_cell: LDC 1.43 + vibe-0 (DUB; add-local only if checkouts exist)
```

**Is:** a runnable libwasm app whose `src-d/` *is* the D the svelte-D printer must emit, plus a vibe.0 `webserver/`.  
**Is not:** a rewrite of slideshow3dai; not the bun compiler (`../svelte-D/packages/svelte-d/`).

**Role in svelte-d:** this tree is the **compile-time bootstrap**. Updating it (using libwasm / vibe.0 idioms, or a titled seam in those libraries) is how a new Svelte / SvelteKit feature is accommodated. svelte-d drops this tree to `../svelte-engine-ws` and compiles kit sources into that copy — it does not invent a third runtime. See `../svelte-D/architecture/bootstrap.md`.

## Two compilers

| Cell | Command |
|---|---|
| WASM / EH | `powershell -File build-ldc-master.ps1` then `node run-probes.mjs` |
| Host | `. ..\setenv.ps1` then `cd webserver; dub build --compiler=ldc2` |

Do not mix objects. Host uses `setenv.ps1`; wasm uses `setenv-wasm.ps1` / `ldc2-build`.

## Navigate

| Intent | Open |
|---|---|
| What this copy preserves | `architecture/overview.md` |
| Dynamic UI / `this.update` | `src-d/app.d`, `src-d/dock.d` |
| wasm-eh probes | `src-d/probe.d`, `run-probes.mjs` |
| `<script lang="d">` plan | `architecture/script-lang-d.md`, `src-svelte/` |
| IR shape | `architecture/ir-target.md` |
| Host / vibe.0 | `webserver/`, `../vibe.0/scripts/build-windows-libs.ps1` |

## Invariants

- Default `dub.sdl` configuration is wasm-eh (`application` / `ldc-master`). Do not asyncify that module on Binaryen 132.
- Client D stays idiomatic libwasm (`mixin Spa!App`, `NodeDef!`, `@child`, `@connect`, `this.update`).
- Server stays idiomatic vibe.0 (`VibeCustomMain`, `listenHTTP`, `runEventLoop`).
