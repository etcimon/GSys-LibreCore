# Compiler host — D program, vibe.0 library, two LDC cells

The next change that adds a bun `package.json` as the compiler, or shells `svelte/compiler` from Node, should stop. **svelte-d is a D executable.** It links **vibe.0 as a library** (`VibeCustomMain`). Pegged parses Svelte; libdparse parses D; vibe.0 supplies CLI, later `listenHTTP` / WebSocket HMR, and the same HTTP types the host-cell printer emits.

Two packages under `packages/`:

| Package | Language | Role |
|---|---|---|
| **`svelte-d`** | D + vibe.0 + Pegged + libdparse + **TS export** | Compiler. `dub` builds `bin/svelte-d` (exe) and `lib/svelte-d` (dll/so). `package.json` `exports` `./ts/index.ts`. `drop-ws` / `parse` / `scan` / `compile` / `map`. Writes libwasm IR + `fallthrough.json` into `svelte-engine-ws`. |
| **`svelte-kit-d`** | TypeScript, **bun** | Consumer project. `import { … } from 'svelte-d'` (`file:../svelte-d`). DX + test + `bun dev`. Vite HMR in the ws (`:3001`) beside vibe.0 (`:8180`). |

**Guiding principles:** kit syntax falls through to libwasm / vibe.0 in an equivalent ws tree ([fallthrough.md](fallthrough.md)). Kit features are accommodated in svelte-engine / libwasm / vibe.0; `compile` integrates the engine as the ws bootstrap ([bootstrap.md](bootstrap.md)). `mapKitPath` and `accommodateFeatures` are part of the public import API.

Neither package is a sibling `riscv-dev/svelte-d/` (Windows case-fold). bun does **not** parse Svelte; Pegged/scan does.

**Script split (construction):** `lang="d"` → `ws/src-d/` libwasm IR. `lang="ts"` → `ws/src-ts/modules/generated/` + regenerated `index.ts` so `libwasm.init` picks up `jsExports` **and** `ensureSvelteD().registerTs`. Same-file D calls those exports by the simple name (`callTs`). D `extern(C) export` is `exportDelegate`. npm imports on `lang=ts` fall through onto dest `package.json` + dest `node_modules` (copy + `bun install`). See [cross-calling.md](cross-calling.md) and [AGENTS-todo.md](../AGENTS-todo.md) T1/T4 / G125–G126.

```
svelte-d drop-ws [--dest svelte-engine-ws]
svelte-d parse <file.svelte|+page.server.d>
svelte-d build [--ws <dir>]
svelte-d serve          # later: vibe.0 listen + HMR WS
svelte-d inspect
svelte-kit-d adapt <static|libwasm-spa|vibe0|vibe0-proxy> --out <dir>
```

`drop-ws` copies the **packaged** `svelte-engine/` (inside svelte-d, or the submodule) to **`svelte-engine-ws`** (default: `svelte-d.config.ts` `workspace` at the project root). `build` compiles **inside** that workspace (see [workspace.md](workspace.md)). svelte-d itself is native LDC 1.43 (`bunx svelte-d setup`). It never links libwasm.

Parse path:

1. kit-fs walk of `ws/src-svelte/` (SvelteKit filenames).
2. Pegged `SvelteKit:` on each `.svelte` ([pegged-grammar.md](pegged-grammar.md); same `asModule` / mixin split as `libwasm/webidl/webidl-grammar`).
3. libdparse on `<script lang="d">` bodies, `+*.d`, and passthrough `src-d/`.
4. IR hash → `ws/.svelte-d/`.
5. Print D → `ws/src-d/`.
6. Whole-program `dub` in `ws` (wasm) and/or `ws/webserver` (host).

serve-d is the IDE for those D files; it is **not** linked.

Two environments stay first-class for the **app** (the workspace), not for the compiler: wasm = `setenv-wasm.ps1` + workspace `dub.sdl` (svelte-engine default is wasm-eh / `ldc-master`); host = `setenv.ps1` + `webserver/dub.sdl`. svelte-d refuses to `add-local` libwasm into its own graph.

`manifest.json` is written to `ws/.svelte-d/manifest.json` (same fields as before: cell pins, raw vs final wasm, routes). Vite in the template remains the optional JS shell; svelte-d does not require bun.

## Loci

`packages/svelte-d/dub.sdl` — vibe-0 + pegged + libdparse  
`packages/svelte-d/source/app.d` — CLI  
`libwasm/webidl/webidl-grammar/generator/source/app.d` — Pegged `asModule`  
`../svelte-engine/` — template  
`../setenv.ps1` — host cell for svelte-d itself  

## Invariants

- svelte-d is host-cell D. No wasm `object.d` in its link line. (construction)
- vibe.0 is a library (`VibeCustomMain`). Do not revive `VibeDefaultMain`. (construction)
- Builds of the app happen in `svelte-engine-ws`, never in the template. (construction)
- Pegged/libdparse stay out of the wasm graph. (construction)

## Extension points

`serve` is `listenHTTP` + the existing dumpApp/loadApp WS (port 3579 / 3001). A bun leftover is only the *app’s* Vite glue, not the compiler.

## Did not close

Hot-restart of `ws/webserver` vs in-process vibe.0. Whether `inspect` talks LSP to a running serve-d.
