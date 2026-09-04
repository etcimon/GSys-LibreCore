# IR — internal AST, cache, incremental update of D apps

The next change that adds a node kind, changes a hash input, or “just concatenates D strings” should read this and then not concatenate D strings.

svelte-D’s primary artifact is an **AST that *is* the libwasm D IR** ([ast-ir.md](ast-ir.md), [udas.md](udas.md)) — not a private component JSON, not LLVM bitcode. Pegged `ParseTree` (or the v1 markup scan) plus libdparse are *front ends* onto that graph. There is no `svelte/compiler`. D written into **`svelte-engine-ws/src-d/`** is a pretty-print of those nodes, with **names that still read as the Svelte**. Lodash / moment / bindings are **sparse procedural** leaves, not the tree. v1 incrementality is **reprint-skip + opposite-cell-skip + skip-fresh-wasm**, and **G107** adds per-`.o` for the default (no-LTO) wasm cell: content-hash IR nodes, cache emitted D, invalidate the route/component/layout cone, then `ldc2 -c` dirty `src-d` into `.svelte-d/o/` and relink those objects with the libwasm `.a` set from `dub describe`. A hash-skip compile (or a touched `.svelte` whose dest bytes did not change) does **not** relink wasm — `wasmDirty` looks at `write.json` `wasm` plus `src-d/`/`dub.sdl` vs the artifact, not at `src-svelte` mtimes. `svelte-d wasm` skips the link when dests are not newer (`wasm.json` `"skipped":true`); `--force` always links. LTO cells (`-flto=full` on 1.36, `-flto=thin` on 1.42) still whole-program `dub`.

A node is `{ id, kind, sourceSpan, payload, childIds, contentHash, printerKey, cell }`. `cell` is `wasm | host | both | js`. `contentHash = blake3(SCHEMA_VERSION || kind || canonicalize(payload) || sorted child hashes || PRINTER_VERSION || cellPin)`. `cellPin` includes the LDC version and the libwasm or vibe.0 pin so a runtime bump cannot silently reuse objects. The on-disk cache is `svelte-engine-ws/.svelte-d/` (name is a Key Decision; do not call it `.next` or `.svelte-kit`). Layout:

```
svelte-engine-ws/.svelte-d/cache/ir/<hash>.json
svelte-engine-ws/.svelte-d/cache/d/<hash>.d
svelte-engine-ws/.svelte-d/manifest.json
svelte-engine-ws/.svelte-d/stats.json
svelte-engine-ws/src-d/                 # assembled D the workspace already compiles
svelte-engine-ws/src-svelte/            # Svelte+D sources (kit-fs)
```

v1 default is **one assembled `.d` file per component** under `ws/src-d/`, matching svelte-engine’s `navbar.d` / `dock.d` / `app.d`. The cache stores the per-node fragment; assembly is a printer step so diffs stay at a path `dub.sdl` already lists.

Invalidation walks dependents, not the whole graph. T10 (`writeIfChanged`) skips dest writes when bytes match so mtime stays put; watch uses `cellForSrc` so a `.svelte` edit does not host-link and a `+page.server.d` edit does not wasm-link. A `+page.svelte` edit reprints that `Page` + `Template` children and relinks wasm (G107: dirty `.o` + archives; LTO: whole-program `dub`); it does **not** invoke the host cell. A `+page.server.ts` edit reprints `ServerLoad` (+ route table if exports changed) and whole-program host-links; it does **not** run `wasm-opt`. A printer-version bump invalidates all D. A wasm cell-pin bump invalidates wasm **artifacts** and forces one wasm relink. `PassthroughD` nodes hash file bytes; the printer copies them. `DietView` nodes hash Diet source and remain wasm-cell `stringImportPaths`. User script/TS is accepted only if it is in the **v1 source subset** (canonical design); otherwise the node is never hashed — parse fails.

v1 node kinds: `App`, `Route`, `Layout`, `Page`, `ServerLoad`, `UniversalLoad`, `Endpoint`, `Component`, `Template`, `Element`, `EachBlock`, `IfBlock`, `AwaitBlock`, `Slot`, `Snippet`, `Style`, `Script`, `PassthroughD`, `DietView`, `GlueModule`, `Hook`, `Matcher`, `ErrorPage`, `Fallback`, `ServiceWorker`, plus the wasm-only JS surface: **`BindingCall`**, **`LodashChain`**, **`MomentCall`**, **`JsHostWrap`** ([libwasm-js.md](libwasm-js.md)). Adding a kind is a `SCHEMA_VERSION` bump. `UniversalLoad` that cannot be expressed in **both** printers is rejected, not silently compiled for one cell. `LodashChain` / `BindingCall` / `MomentCall` on a host-cell node is a compile error.

This cache is a Turbopack/Next **compile** cache for IR/D. It is not LDC IR. 1.42 full LTO + debug DI already aborted LLVM 21 (slideshow3dai `dub.sdl` on `ldc-1.42`). Do not promise object-level incrementality in Phase/PR10.

## Loci

slideshow3dai `src-d/app.d` — the shape the client printer’s first golden must match  
slideshow3dai `dub.sdl:13-14` — `targetName` `slideshow3dai-raw` vs postBuild `slideshow3dai.wasm`  
libwasm `spa.d:5-7` — three legal `__VERSION__` values; cellPin must name which  

## Invariants

- D in `generated/` is always a function of IR + printer version. Hand-edits there are discarded. (construction of incrementality)
- Hash inputs include child hashes (Merkle). Reordering children with different hashes must change the parent. (construction)
- `host`-only nodes are unreachable from wasm modules; the graph check is a compile error, not a warning. (construction — secrets)
- Default `application` / `ldc-master` cells cache LDC `.o` files under `.svelte-d/o/` (G107). LTO cells do not. (construction of K6, relaxed for no-LTO)
- Do not store LLVM bitcode as the *primary* key. (convention of this design; breaking it is a new design)
- AST kinds conform to libwasm `compile!()` (NodeDef / @child / @prop / Slot / connect / inject / UnorderedList). A kind with no libwasm form is a diagnostic. (construction)
- Printed D names are D-legal spellings of the Svelte names. (construction — representativeness)

## Extension points

New syntax → new node kind + lowerer + printer arm + fixture. New cell pin → new `cellPin` string, no schema change. Cache format is **JSON files** (owner 2026-08-14). A later SQLite swap would be a new design, not v1.

## Did not close

Whether `.svelte-d/generated/**/*.d` is committable in apps (recommendation: fixtures yes, apps no). Exact `canonicalize(payload)` encoding (JSON with sorted keys is enough for v1). Whether `PassthroughD` should be parsed with a D parser to extract `import` edges or use a regex in v1 (recommendation: regex + explicit `imports:` in fixture metadata).
