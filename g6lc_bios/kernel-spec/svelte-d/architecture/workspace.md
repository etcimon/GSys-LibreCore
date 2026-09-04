# svelte-engine-ws — dropped compile workspace

The next change that writes generated D into `svelte-engine/` itself, or invents a third app layout, should read this and then write into **svelte-engine-ws**.

`svelte-engine/` is the **source** of the runtime bootstrap. `bun scripts/pack-engine.ts`
copies it into **`packages/svelte-d/svelte-engine`** (and `templates/engine` as the
legacy name). A bun + svelte-d consumer does not need a sibling checkout: after
`bun install`, the engine lives at **`node_modules/svelte-d/svelte-engine`**. `drop-ws`
copies that tree to **`svelte-engine-ws`**. Dest order: `svelte-d.config.ts` /
`.js` / `.json` `workspace` (relative to that file), else `<kit-project>/svelte-engine-ws`,
else an existing checkout sibling. The default for a consumer app is the **project
top-level** `./svelte-engine-ws`, not `node_modules/svelte-d/svelte-engine-ws`.
The compiler must **not** mutate the packaged engine (or the submodule) **while
compiling an app**. App Svelte / SvelteKit lives in the bun project `src/` and is
**ingested** onto the dropped workspace (`compile --project`, or automatically when
cwd has `src/routes`).

Accommodation goldens (`src-svelte/lib/Combo*.svelte`, `Panel.svelte`) stay
in the bootstrap so printer tests have an idiom library. **Application**
trees (admin panel, site routes) belong in the project, not in the engine.

`svelte-engine-ws` is the **working tree** svelte-d drops when it materializes D IR. It is svelte-engine plus generated `src-d/`, `.svelte-d/` cache, `fallthrough.json`, and `manifest.json`. All `dub build` / `wasm-opt` / host link for an app happen **inside** that tree, using that tree’s `dub.sdl` and `webserver/dub.sdl`. Kit paths **fall through** into this tree with the same relative shape ([fallthrough.md](fallthrough.md)). That is how “compile svelte to D within that structure” is construction, not a slogan.

## Drop

```
svelte-d drop-ws [--dest <path>]
```

Default dest: `svelte-d.config.ts` `workspace` (this repo: `./svelte-engine-ws`),
or `<project>/svelte-engine-ws` when cwd is a SvelteKit tree (**not** inside
`svelte-engine/` itself, **not** inside `node_modules/svelte-d`). Copy file-by-file
from the packaged `svelte-engine/`, excluding `.dub`, `node_modules`, `*.exe`,
`*.pdb`, `*.wasm`, `generateSourceMap.py`, `capacitor.config.json`.

Dest is never `rmdirRecurse`’d. `drop-ws` **overlays** the template: missing files are filled; `--force` overwrites template-owned files so a new engine revision can land; files the user added stay. `node_modules`, `.dub`, `.git`, and `.svelte-d` are never deleted. Locked individual files are skip-logged. An empty leftover dest is filled without `--force`.

Engine `src-d/app.d` ships assemble markers (`begin-imports` / `begin-children` / `begin-kit-*`). Vite watches `public/__svelte-d/hmr-tick` so svelte-d incremental compile can `reload` / `full-reload` without a second websocket. Pack with `bun packages/svelte-d/scripts/pack-engine.ts` after engine edits.

After drop, `svelte-d compile --ws` then `svelte-kit-d` `bun dev` means:

1. Walk `svelte-engine-ws/src-svelte/` (kit-fs).
2. Pegged-parse each `.svelte`; libdparse each `lang=d` body and each `*.d`.
3. Write IR JSON → `ws/.svelte-d/ir/` + `manifest.json`.
4. **`src-d/` is the libwasm IR.** Passthrough goldens stay for chrome that has no Svelte source (`navbar.d` EH/PgLite idiom, `pglite.d`, `jshost.d`, `probe.d`). `Dock.svelte`, `NavBar.svelte`, and `routes/+page.svelte` **print** and assemble onto `App` (`import lib.Dock`, `import lib.NavBar`, `kitRoutes.rootPage.show`) so those capabilities are compiled, not handwritten `import dock` / `import navbar` / `struct Main`. Persistence is PgLite. The printer does not delete unknowns.
5. `bunx vite` in the ws (HMR `:3001`). Whole-program `dub` wasm / `webserver` when those cells are invoked.

Passthrough: if a `src-d/` file has no svelte source, it stays (probe.d, pglite.d). The printer does not delete unknowns.

## Why a drop and not in-place

The template is the golden. IR experiments must not destroy it. slideshow3dai stays the *product* tree and is never the dest. Windows case-fold: dest is `svelte-engine-ws`, not `svelte-engine`.

## Loci

`svelte-engine/` — template (submodule at repo root; packaged copy inside svelte-d)  
`svelte-engine/src-d/` — target D shape  
`svelte-engine/src-svelte/` — target Svelte+D shape  
`svelte-engine/dub.sdl` — wasm-eh default; libwasm is `~master` from `github.com/etcimon/libwasm` (local `dub add-local`, else fetch)  
`svelte-engine/webserver/` — vibe.0 host  
`packages/svelte-d/svelte-engine` — packaged drop payload (`node_modules/svelte-d/svelte-engine`)  
`packages/svelte-d/templates/engine` — legacy packaged name  
`packages/svelte-d/scripts/pack-engine.ts` — sync from the svelte-engine submodule  
`packages/svelte-d/source/svelte_d/workspace/drop.d` — drop implementation  
`packages/svelte-d/source/svelte_d/workspace/config.d` — `svelte-d.config.ts/js` dest  
`packages/svelte-d/ts/config.ts` — same dest policy on the bun side  
`packages/svelte-d/source/svelte_d/workspace/ingest.d` — project `src/` overlay  

## Invariants

- svelte-d never `dub build`s the template directory. (construction)
- wasm and host cells inside the ws share LDC 1.43 but still clear `DFLAGS`/`DC` so objects do not mix. (construction)
- Generated D in `ws/src-d/` is a function of IR; hand-edits there lose to the next print. Hand-edits in the **template** `src-d/` are the golden. (construction)
- `svelte-engine-ws` is generated; do not admit it to the host ledger. (convention)

## Extension points

A new template (e.g. spa-only) is a second bootstrap dir + a `--template` flag, not a fork of drop.d. Adapters consume `ws/.svelte-d/manifest.json` (`packages/svelte-d/ts/adapter.ts`; `svelte-kit-d adapt`).

## Did not close

Dest is configurable (`svelte-d.config.ts` `workspace`). Default is the consuming
project’s top-level `./svelte-engine-ws`. Certs/keys are not packed.
