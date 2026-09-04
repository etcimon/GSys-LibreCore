# Bootstrap — accommodate kit features in svelte-engine / libwasm / vibe.0

The next change that implements a Svelte / SvelteKit feature *inside svelte-d* as a new DOM, a new HTTP stack, or a Svelte-to-JS wrap should read this and then stop.

**Guiding development principle (construction):** every Svelte / SvelteKit **syntactic** feature, every **underlying** runtime feature, and all **further development** of those features is **accommodated by changes in**

1. **`svelte-engine/`** — the golden bootstrap (libwasm `src-d/` + vibe.0 `webserver/` + `src-svelte/` + `src-ts/`)
2. **`libwasm`** — wasm-cell primitives (`NodeDef`, `this.update`, bindings, Lodash, moment, HMR)
3. **`vibe.0`** — host-cell primitives (`listenHTTP`, `URLRouter`, `registerWebInterface`)

when the engine does not already express them. **svelte-d does not grow a third runtime.** It parses kit sources and **prints D IR in the format svelte-engine already compiles**.

An updated `svelte-engine` becomes the **`svelte-engine-ws` bootstrap at compile time**: `drop-ws` copies the engine; `compile` integrates it (writes `.svelte-d/bootstrap.json`, verifies required surfaces, then walks kit sources into that tree). bun + TypeScript + svelte-d tests and projects are the demonstration surface (`import { … } from 'svelte-d'`).

```
kit feature needed
        │
        ▼
does svelte-engine already show the idiom?
   │ yes                              │ no
   ▼                                  ▼
printer emits that shape     update svelte-engine
                             (and a titled libwasm or vibe.0
                              seam if a new primitive is required)
                                      │
                                      ▼
                        next compile drops/integrates
                        svelte-engine → svelte-engine-ws
```

Path fall-through ([fallthrough.md](fallthrough.md)) says *where* a kit file lands. This note says *who implements the meaning*: the engine and its two runtimes, not the compiler host.

## What “proper D IR format” means

The IR svelte-d writes toward is **the D svelte-engine already builds** ([../svelte-engine/architecture/ir-target.md](../../svelte-engine/architecture/ir-target.md)):

| Cell | Format | Engine locus |
|---|---|---|
| wasm | idiomatic libwasm (`mixin Spa!App`, `NodeDef`, `@child`, `this.update`, Lodash / moment / bindings, `pglite.d`) | `svelte-engine/src-d/` |
| JS glue | `jsExports` folded by `libwasm.init`; `window.__svelteD` for `callTs` / `exportDelegate` | `svelte-engine/src-ts/modules/` |
| host | idiomatic vibe.0 (`VibeCustomMain`, `listenHTTP`, `URLRouter`) | `svelte-engine/webserver/` |

JSON under `ws/.svelte-d/ir/` is a cache key, not a second language.

## Compile-time integration

1. `svelte-d compile` **ensures** `svelte-engine-ws` exists (drops the current engine if missing).
2. It **verifies** required bootstrap surfaces (root `src-d/app.d`, `pglite.d`, `src-ts/modules`, `webserver/source/app.d`, kit `src-svelte/`, both `dub.sdl`s).
3. It **records** `ws/.svelte-d/bootstrap.json` (`schema: svelte-d-bootstrap/v1`): template path, workspace, surface presence, template file hashes, and the accommodation table.
4. It then walks kit sources into that bootstrap ([fallthrough.md](fallthrough.md)).

Updating `svelte-engine` is how a new kit capability enters the product. `drop-ws --force` refreshes an existing ws from the new engine; a missing ws is integrated on the next compile. Do not mutate the template from a compile of an app.

## Loci

`packages/svelte-d/source/svelte_d/bootstrap.d` — D contract  
`packages/svelte-d/ts/bootstrap.ts` — bun-importable mirror  
`packages/svelte-kit-d/test/bootstrap.test.ts` — bun + ts + svelte-d proof  
`../svelte-engine/` — bootstrap that may be updated  
[frontend-libwasm.md](frontend-libwasm.md) / [backend-vibe0.md](backend-vibe0.md) — how a seam is printed  
[sveltekit-feature-map.md](sveltekit-feature-map.md) — per-construct status  

## Invariants

- New kit syntax is not a svelte-d runtime. Land it in svelte-engine; add a libwasm or vibe.0 seam only when the engine cannot express it. (construction)
- Compile integrates **this** svelte-engine as `svelte-engine-ws`. Builds of the app happen in the ws, never in the template. (construction)
- Printed D must be legal input to the engine’s wasm `dub.sdl` or host `webserver/dub.sdl`. (construction)
- A titled **seam** PR is the only svelte-D-driven edit of libwasm or vibe.0. slideshow3dai stays the product tree and is not the dest. (construction)
- `bootstrap.json` + `mapKitPath` stay in lockstep with the D CLI (`svelte-d bootstrap` / `map`). (construction of the import API)

## Extension points

A new kit filename or construct: (1) show it in svelte-engine, (2) row in the feature map, (3) arm in fall-through + printer, (4) bun test. A new cell is a new engine surface, not a compiler-side runtime.

## Did not close

Whether compile incrementally refreshes template-owned passthrough files (`pglite.d`, `probe.d`) when the engine hash changes without `--force` (recommendation: later; v1 records the hash and requires `drop-ws --force`). Whether a second bootstrap template (`--template spa`) is v1 (no).
