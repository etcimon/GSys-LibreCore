# Fall-through — kit syntax → libwasm / vibe.0 in an equivalent ws tree

The next change that invents a third app layout, flattens `src/routes` into a bag of generated names, or “compiles Svelte to JS then wraps wasm” should read this and then stop.

**Guiding principle (construction):** a **svelte-d + bun** project’s Svelte / SvelteKit syntax **falls through** to the corresponding **libwasm** (wasm cell) or **vibe.0** (host cell) equivalent, in a **roughly equivalent structure**, inside **`svelte-engine-ws`**. The kit relative path is the workspace relative path. Only the **cell prefix** changes.

```
bun project (SvelteKit)                 svelte-engine-ws
────────────────────────────────────────────────────────────────
src/routes/+page.svelte              →  src-svelte/routes/+page.svelte     source (preserved)
                                     →  src-d/routes/page.d                libwasm (NodeDef, this.update)
                                     →  src-ts/modules/generated/…         lang=ts jsExports + __svelteD.ts
src/routes/+layout.svelte            →  src-svelte/routes/+layout.svelte
                                     →  src-d/routes/layout.d              @child wrapper (not a 2nd wasm)
src/lib/Dock.svelte                  →  src-svelte/lib/Dock.svelte
                                     →  src-d/lib/Dock.d                   libwasm struct
src/routes/+page.server.ts|.d        →  src-svelte/routes/+page.server.*
                                     →  webserver/source/generated/routes/page_server.d
                                                                           vibe.0 URLRouter / registerWebInterface
src/routes/+server.ts|.d             →  webserver/source/generated/routes/server.d
src/hooks.server.ts                  →  webserver/source/generated/hooks.d
src/lib/jquery-bridge.ts             →  src-ts/modules/helpers/lib/jquery-bridge.ts
src/styles/app.scss                  →  styles/app.scss
node_modules/svelte-grid/Grid.svelte →  src-svelte/ext/svelte-grid/Grid.svelte
                                     →  src-d/ext/svelte-grid/Grid.d
                                     →  src-ts/modules/generated/…     lang=ts splice
public/logo.png                      →  public/logo.png                vibe.0 serveStaticFiles
app.html                             →  index.html / SSR skeleton
```

`src/` and `src-svelte/` are the same kit tree. A bun consumer may use either; `normalizeKitRel` strips the prefix. Groups `(app)` stay in the dest path. Param folders are dest-sanitized (`[slug]` → `_slug_`, `[[lang]]` → `_lang_`, `[...path]` → `_path_`) so LDC 1.43 on Windows does not `globMatch`-assert on `[` in argv. Source `src-svelte` keeps the kit names. `+page.svelte` becomes `page.d` (D cannot start a module file with `+`). Component files keep their Svelte name: `ClickField.svelte` → `src-d/lib/ClickField.d` / `struct ClickField` ([ast-ir.md](ast-ir.md)).

Template-only files that have no kit source (`src-d/pglite.d`, `probe.d`, `jshost.d`) stay as **passthrough** libwasm IR. They are not remapped. The printer (T3) emits kit-sourced D into the fall-through paths above; it does not delete unknowns.

Who implements the *meaning* of a construct is the engine and its runtimes, not this map. See [bootstrap.md](bootstrap.md).

Compile writes `ws/.svelte-d/fallthrough.json` (`schema: svelte-d-fallthrough/v1`). The D CLI `svelte-d map <path>` and the TS export `mapKitPath` must agree (tested).

## Loci

`packages/svelte-d/source/svelte_d/fallthrough.d` — D source of truth  
`packages/svelte-d/ts/fallthrough.ts` — bun-importable mirror  
`packages/svelte-d/source/svelte_d/parse/kit_fs.d` — kit walk  
`packages/svelte-kit-d/test/import-library.test.ts` — import + mapping tests  
[frontend-libwasm.md](frontend-libwasm.md) — what `src-d/` must look like  
[backend-vibe0.md](backend-vibe0.md) — what `webserver/source/generated/` must look like  
[sveltekit-feature-map.md](sveltekit-feature-map.md) — per-construct status  

## Invariants

- Do not invent a third tree. Cell prefixes are `src-svelte`, `src-d`, `src-ts`, `webserver`. (construction)
- `lang="d"` falls through to libwasm D. `lang="ts"` falls through to `src-ts/modules` `jsExports` **and** `window.__svelteD.ts[ident]`. Crossing is Lodash `callTs` / `exportDelegate` ([cross-calling.md](cross-calling.md)), not a third cell. Host files fall through to vibe.0. (construction)
- `lang=ts` npm imports fall through from the **project** (declared range + copy of the project’s `node_modules/<pkg>` + dest `bun install` if missing). Do not dump `package.json` and do not `file:` a relative path between two `node_modules`. (construction)
- Layouts stay mounted `@child`; they are not a second wasm module. (construction of K17)
- Mapping a path is not a claim the printer has emitted it. Status stays in the feature map. (convention)
- `mapKitPath` (TS) and `mapKitRel` (D) stay byte-for-byte on field values. (construction of the import API)

## Extension points

A new kit filename is a new arm in `fallthrough.d` **and** `fallthrough.ts` plus a bun test. A new cell is a new prefix, not a flattening.

## Did not close

Whether T3 reprints into `src-d/routes/page.d` while still keeping template `src-d/app.d` as the `mixin Spa!App` root (recommendation: yes — `app.d` remains the root; kit pages become `@child` under it). Whether `[slug]` folders are sanitized for D module names (paths keep brackets; `module` identifiers are sanitized at print).
