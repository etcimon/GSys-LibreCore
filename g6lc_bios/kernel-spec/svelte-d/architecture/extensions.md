# Extensions — third-party Svelte packages, Node/Bun helpers, lang=ts splice

The next change that `npm install`s a Svelte grid and then wraps it as Svelte-to-JS inside svelte-d, or that puts jQuery on a second DOM stack, should read this and then stop.

**Guiding construction:** a bun + SvelteKit project may depend on (1) **Svelte packages** (`svelte-grid`, a graph widget, any `*.svelte` under `node_modules`), (2) **Node/Bun front-end helpers** (SCSS, vanilla TypeScript, jQuery) that Vite already understands, and (3) **`<script lang="ts">`** inside `.svelte` files. All three fall through into **`svelte-engine-ws`**. Markup with `lang=d` still prints libwasm D IR. TS/CSS/jQuery stay in **`src-ts/`** / **`styles/`** and are folded by the existing Vite + `libwasm.init` glue. svelte-d does not grow a third runtime and does not parse production sources with `svelte/compiler`.

```
bun project                                    svelte-engine-ws
────────────────────────────────────────────────────────────────────────
src/lib/GridWrap.svelte                     →  src-svelte/lib/GridWrap.svelte
   + <script lang="d">                      →  src-d/lib/GridWrap.d
   + <script lang="ts">                     →  src-ts/modules/generated/<ident>.ts
                                               spliced into src-ts/modules/index.ts
node_modules/svelte-grid/**/*.svelte        →  src-svelte/ext/svelte-grid/…
                                               src-d/ext/svelte-grid/…   (if lang=d)
src/lib/jquery-bridge.ts                    →  src-ts/modules/helpers/jquery-bridge.ts
src/styles/app.scss                         →  styles/app.scss
package.json "jquery" / "sass"              →  ws package.json deps (Vite)
```

## 1. `<script lang="ts">` splice (implemented)

`attachTsModules` (`ts_attach.d`) copies each `lang=ts` (instance or `context="module"`) body into `ws/src-ts/modules/generated/<identFromRel>.ts` using `js-module.ts.tmpl`. Exported functions are wrapped as `jsExports.env.<name>` (`...args` so defaults stay) and `ensureSvelteD().registerTs(ident, name, fn)`. `context="module"` uses `<ident>_mod`. `rewriteModulesIndex` regenerates `src-ts/modules/index.ts` from `modules-index.ts.tmpl` so `libwasm.init(modules)` picks up every generated module **and** keeps `bindings` / `spa` / `libwasm` / `debug-bridge`.

That is the splice. Do not emit a second `index.ts` or a Node `require` graph. Author `import $ from 'jquery'` inside that TS body is legal Vite input after the helper is on `ws` `package.json`. Same-file D calls those exports by the **simple name** (`callTs` / `callTsPromise` thunks). A printed `import jquery` in `src-d/` would be a third FFI. Crossing, mangling, and optional args: [cross-calling.md](cross-calling.md).

`lang=ts` npm imports fall through from the **project**: dest `package.json` gets the declared range; dest `node_modules/<pkg>` gets a **copy** of the project’s install when it exists (not a `file:` relativePath — that produced `./packages/…` and bun EPERM). `$lib/…` rewrites to `src-ts/modules/helpers/lib/…`. Relative imports rewrite onto dest helpers; another `.svelte` becomes `./<ident>.ts`. `compile` runs `bun install` in the dest when a declared package is still missing. `ensureWsDeps` does the same if Vite or a declared dest dep is absent.

`lang=d` stays Pegged + printer → `src-d/`. Dual-script files do both.

## 2. Third-party Svelte packages (grids, graphs)

`import Grid from 'svelte-grid'` in app Svelte is **not** a JS wrap. The package’s `.svelte` files are **ingested** onto `src-svelte/ext/<pkg>/…` and compiled with the same printer as `src/lib`. `mapKitPath('node_modules/svelte-grid/Grid.svelte')` names those dests.

v1 rules:

- Only files the app actually imports (or a declared `svelte-d.extensions` list) are ingested. Do not dump all of `node_modules`.
- If the package is JS-only (no `.svelte` / no `lang=d`), it is **Host-JS-only**: load it from `src-ts` (section 3). Do not invent D IR for a React/Vue widget.
- Markup in the package that is ordinary Svelte prints as libwasm when it is in the v1 subset. Constructs that need a new primitive stay **Requires-new-libwasm-seam** ([sveltekit-feature-map.md](sveltekit-feature-map.md)).
- Package CSS/SCSS follows section 3.

## 3. Node/Bun helpers (SCSS, jQuery, vanilla TS)

These are **Vite + src-ts** concerns. The wasm cell does not link them.

| Project file | ws dest | Who runs it |
|---|---|---|
| `src/**/*.ts` (not `+*.server.*`) | `src-ts/modules/helpers/…` (copy) | Vite; import from `src-ts/main.ts` or a generated helper index |
| `<script lang="ts">` in `.svelte` | `src-ts/modules/generated/…` + index splice | `libwasm.init` / `jsExports` |
| `src/**/*.scss` / `.sass` / `.css` | `styles/…` | Vite (`vite.config.js` already has postcss/tailwind; add `sass` when a `.scss` is ingested) |
| npm `jquery`, `d3`, … | stay in `ws/package.json`; import from helpers or `main.ts`; optional `window.$` | Vite |
| D that must call a `lang=ts` export | simple name → `callTs` / `callTsPromise` (Lodash invoke) | [cross-calling.md](cross-calling.md) |
| D that must call a window host object | `Eval("window.$")` / Lodash `defaultTo` like `pglite.d` | libwasm, not a second FFI |

`ensureWsDeps` (`svelte-kit-d` pipeline) already `bun install`s in the ws when Vite is missing. Ingest of SCSS records `sass` as a ws dep; ingest of `import 'jquery'` records `jquery`. Do not start a Node HTTP stack to serve them.

## Status

| Surface | Status |
|---|---|
| `lang=ts` → generated + `index.ts` splice | **Implemented** (`ts_attach.d`, pipeline test) |
| D ↔ TS `callTs` / `exportDelegate` | **Implemented** (G125; [cross-calling.md](cross-calling.md)) |
| `lang=ts` npm → dest range + copy + `bun install` | **Implemented** (G126; `ws_deps.d`) |
| `$lib` / relative / `.svelte` TS import rewrite | **Implemented** (`rewriteTsImports`) |
| `mapKitPath` for `.ts` helpers, `.scss`, `node_modules/…/*.svelte` | **Mapped** (this pass) |
| Ingest imported `node_modules/<pkg>` `.svelte` onto `src-svelte/ext/` | **Implemented** (`ingestImportedSvelte`; not all of `package.json` dependencies) |
| Copy project standalone `.ts` / `.scss` onto mapped dests | **Implemented** (`ingestLocalHelpers`) |
| Rewrite `vite.config.js` `ldc2` to discovered 1.43 | **Implemented** (`pinWasmToolchain` on drop/compile) |
| Project `public/` → `ws/public/` + vibe.0 `serveStaticFiles` | **Implemented** (`ingestPublicDir`, host `app.d`) |

## Loci

`packages/svelte-d/source/svelte_d/print/ts_attach.d` — lang=ts splice  
`packages/svelte-d/source/svelte_d/print/cross_call.d` — thunks, peel, import rewrite  
`packages/svelte-d/source/svelte_d/workspace/ws_deps.d` — dest range + copy + install  
`packages/svelte-d/templates/js-module.ts.tmpl` / `modules-index.ts.tmpl`  
`packages/svelte-d/source/svelte_d/fallthrough.d` + `ts/fallthrough.ts` — map  
`packages/svelte-d/source/svelte_d/workspace/ingest.d` — project `src/` (ext ingest next)  
`packages/svelte-kit-d/test/extensions.test.ts` — table + live splice + `fake-grid`  
`packages/svelte-kit-d/test/cross-call.test.ts` — Bridge / Peer  
`packages/svelte-d-kit-admin/test/admin.test.ts` — AdminBridge / `admin-mini`  
[cross-calling.md](cross-calling.md) · [fallthrough.md](fallthrough.md) · [libwasm-js.md](libwasm-js.md) · [engine-setup.md](engine-setup.md)

## Invariants

- `lang=ts` is spliced into `src-ts/modules` `jsExports` and `__svelteD.ts[ident]`. Same-file D calls use Lodash `callTs` thunks; D `extern(C) export` uses `exportDelegate`. (construction)
- Third-party `.svelte` is compiled as Svelte, not wrapped as JS. JS-only packages stay in `src-ts`. (construction)
- jQuery / SCSS / vanilla TS do not become a second DOM or a Node HTTP stack. (construction)
- Printed wasm D still starts `import libwasm;` and talks to JS via bindings / Lodash / `callTs` / `jsExports`. (construction)

## Did not close

Whether extension ingest is automatic from `import 'svelte-grid'` or an allow-list in `package.json` `svelte-d.extensions` (recommendation: start with allow-list + imported `.svelte` paths). Whether scoped npm names (`@xyflow/svelte`) use `src-svelte/ext/@xyflow/svelte/`.

**Closed (G126):** a `lang=ts` body that `import`s a helper is rewritten (`$lib` → `helpers/lib/…`, relative → dest helper, `.svelte` → `./<ident>.ts`). npm specifiers stay bare and fall through as dest range + copy.

**Closed (G126):** a `lang=ts` body that `import`s a helper is rewritten (`$lib` → `helpers/lib/…`, relative → dest helper, `.svelte` → `./<ident>.ts`). npm specifiers stay bare and fall through as dest range + copy.
