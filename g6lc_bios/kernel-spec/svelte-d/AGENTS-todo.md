# svelte-D — path to serving Svelte/SvelteKit through svelte-engine-ws

Queue for **this folder**. Priors live in `architecture/`. Do not edit `../AGENTS-todo.md`.

```
green_now:   dub build --config=application && dub build --config=library
             && bun test packages/svelte-kit-d
             && bun test packages/svelte-d-coverage
             && bun test packages/svelte-d-kit-app
             && bun test packages/svelte-d-kit-fs
             && bun test packages/svelte-d-kit-host
             && bun test packages/svelte-d-kit-env
             && bun test packages/svelte-d-kit-admin
             && svelte-d wasm --ws svelte-engine-ws --probes
             && svelte-d host --ws svelte-engine-ws
next:        coverage suites 4–10 (each-else, await, bind, …)
blocked_on:  none
```

## Thesis

**Guiding principles:**

1. **Fall-through.** Svelte / SvelteKit syntax in a **svelte-d + bun** project **falls through** to the corresponding **libwasm** / **vibe.0** equivalent in a **roughly equivalent structure** inside `svelte-engine-ws`. See [architecture/fallthrough.md](architecture/fallthrough.md).
2. **Accommodate in the engine.** All kit syntactic and underlying features, and further development of them, are **accommodated by changes in svelte-engine / libwasm / vibe.0**. svelte-d does not grow a third runtime. An updated engine is **integrated as svelte-engine-ws at compile time** in the D IR format that engine already builds. bun + TS + svelte-d tests and projects prove it. See [architecture/bootstrap.md](architecture/bootstrap.md).
3. **AST ≡ libwasm D IR.** The walker produces an AST whose kinds **are** the libwasm graph (`NodeDef` / NamedNode / `@prop` / Slot / `@connect` / `@inject` / `UnorderedList`). Pretty-print that; do not invent a third IR. Lodash / moment / bindings are **sparse procedural** execution inside methods. **Names** of D modules, structs, and author variables stay representative of the Svelte (`ClickField.svelte` → `src-d/lib/ClickField.d` / `struct ClickField` / `go`). See [architecture/ast-ir.md](architecture/ast-ir.md) and [architecture/udas.md](architecture/udas.md).
4. **Scoped pool precedence.** D allocation falls through to `libwasm/rt/memory.d`. A live `ScopedPool` is the precedent pool for `alloc` / `_d_allocmemory` / `allocString`. Scope heavy methods; copy survivors into `compile!()` fields or ThreadMem `Array`/`Vector`; `freeze`/`unfreeze` when a nested alloc must outlive the scope. Language `new` never joins the pool. See [architecture/AGENTS-D-IR-memory-management.md](architecture/AGENTS-D-IR-memory-management.md).
5. **Spa / compile! lifetime.** Printed D uses libwasm’s hooks (`construct` after inject, `onMount` after render, `onUnmount` on detach, App `ready` / optional `main`). One `mixin Spa!App`; printed structs hang as `@child`. See [architecture/AGENTS-D-IR-lifetime.md](architecture/AGENTS-D-IR-lifetime.md).

A **Svelte / SvelteKit program** (nominal `.svelte` the official language server can attach to) is compiled by **svelte-d** (D + vibe.0 + Pegged spec + libdparse; importable as `import { … } from 'svelte-d'`) into **svelte-engine-ws**, then **served** as:

- wasm frontend = libwasm IR (`ws/src-d/`, including `lang="d"` and PgLite)
- JS glue = `ws/src-ts/modules/` with **`lang="ts"` functions registered** via `jsExports` **and** `window.__svelteD.ts[ident]` (`callTs` / `exportDelegate`)
- host = vibe.0 (`ws/webserver`)
- bun DX / HMR = `packages/svelte-kit-d` (`bun test`, `bun src/cli.ts dev` → Vite `:5173` + WS `:3001` + optional `:8180`)

Two script languages in one `.svelte` file, **not** one or the other:

| Block | Where it lands in svelte-engine-ws | Why |
|---|---|---|
| `<script lang="d">` | `src-d/*.d` libwasm (`NodeDef`, `this.update`, `Lodash`, `moment`, `bindings`) | Wasm cell. IDE: svelte.config.js blanks `lang=d` so the Svelte LS does not parse D as TS. |
| `<script lang="ts">` or `context="module" lang="ts"` | `src-ts/modules/generated/*.ts` exporting `jsExports`, merged into `modules/index.ts`; `registerTs(ident, name)` | JS cell. vscode-svelte / tsserver parse this. `libwasm.init` folds `jsExports`. Same-file D calls the simple name (`callTs`). |
| `+page.server.d` / `+server.d` | `webserver/source/generated/` | Host cell (vibe.0). |

Do not put `lang="d"` into `src-ts/`. Do not put `lang="ts"` into `src-d/`. Do not parse with npm `svelte/compiler`.

---

## Already green (do not re-prove unless a pass touches the cell)

| ID | Cell | Command | Result |
|---|---|---|---|
| G0 | architecture | notes in `architecture/` | living |
| G1 | svelte-d link | `cd packages/svelte-d && dub build --compiler=ldc2` | `bin/svelte-d.exe` |
| G2 | parse / drop / compile | `svelte-d parse` + `drop-ws` + `compile` | IR JSON + `pglite=passthrough` |
| G3 | bun harness | `cd packages && bun install && bun test` (from svelte-kit-d) | 47 pass (2026-08-14, G22) |
| G4 | template wasm-eh | `svelte-engine/build-ldc-master.ps1` | EH + Phobos probes |
| G5 | template host | `svelte-engine/webserver` `dub build` | `svelte-engine-server.exe` |
| G6 | vibe.0 Windows | `vibe.0/scripts/build-windows-libs.ps1` + `http_static_server` | links |
| G7 | importable library | `dub build --config=application` + `--config=library`; `import from 'svelte-d'` | exe + dll + bun tests |
| G8 | engine bootstrap | compile writes `bootstrap.json`; features land in engine/libwasm/vibe.0 | bun `bootstrap.test.ts` |
| G9 | lang=d Lodash | print `LodashDemo.svelte` → `ws/src-d/lib/lodashdemo.d`; catalog = `lodash.d` | bun `lodash.test.ts` |
| G10 | bindings/types/router + serve | print bindings/types/`[slug]` + `kit_router.d`; drop copies wasm; bun serve smoke | `libwasm.test.ts` + `serve.test.ts` |
| G11 | NodeDef / UDA / lists | interactive Svelte → NodeDef/NamedNode/@connect/@inject/UnorderedList | `dom.test.ts` + [udas.md](architecture/udas.md) |
| G12 | AST ≡ D IR + names | architecture [ast-ir.md](architecture/ast-ir.md); dest `ClickField.d` / `goButton` / `Item` | `dom.test.ts` naming asserts |
| G13 | pool-correct D IR | [AGENTS-D-IR-memory-management.md](architecture/AGENTS-D-IR-memory-management.md); `ScopedPool` + copy-out / freeze | architecture (printer auto-wrap later) |
| G14 | compile!/Spa lifetime | [AGENTS-D-IR-lifetime.md](architecture/AGENTS-D-IR-lifetime.md); `construct`/`onMount`/`ready`/`unmount`; hang under App | architecture (T3-lifetime next) |
| G15 | asyncify ⊥ wasm-eh | [AGENTS-D-IR-asyncify-wasm-eh.md](architecture/AGENTS-D-IR-asyncify-wasm-eh.md); engine glue: wrap `_start`, warn no-op `.await`, preserve `WebAssembly.Exception` | architecture + svelte-engine `src-ts` |
| G16 | T3-lifetime + assemble | `construct`/`onMount`/`onUnmount` kept; `ScopedPool(m_pool)` on heavy `go` + `@connect`; `@child ClickField` / `ListEvents` on `App` via markers | `dom.test.ts` 4 pass |
| G17 | `{#if}` remount | `@visible!"child"` + `bool ident`; `setVisible`/`remount`/`unmount`; `IfToggle.svelte` | `dom.test.ts` 5 pass |
| G18 | Pegged asModule | `grammar/generator` → `sveltekit.d`; `SvelteKit.Document` ParseTree on goldens; print still scan | `parse` + `pipeline.test.ts` |
| G19 | MarkupDoc → MkNode | `unwrapRule` peels `or!`/`and!`; Attr mustaches not text kids; Pegged print path | `dom.test.ts` 5 + pipeline |
| G20 | T6 wasm cell | `svelte-d wasm --ws` elaborates assembled IR; `EventEmitter!()` `~=`; `Eval` truthy; `this.update.x` → child.update / `setVisible` | `wasm.test.ts` + `node run-probes.mjs` PASS |
| G21 | T7 host cell | `svelte-d host --ws` links vibe.0 with printed `PageServer`; prefix `/__svelte-d/host/` | `host.test.ts` + `webserver/svelte-engine-server.exe` |
| G22 | T8 bun dev | `prepareDev` + Vite `:5173` GET `/` + wasm 200; HMR `:3001` `reload`; `bun install` in ws; engine `notifyClients` actually fires | `serve.test.ts` 3 pass |
| G23 | Official `.svelte` coverage | clone `sveltejs/svelte` → `riscv-compilers/svelte-ref-impl`; [svelte-language-coverage.md](architecture/svelte-language-coverage.md); `{#if}` `{:else}` prints | `dom.test.ts` Hidden + else_open |
| G24 | More official AST | `class:` `@style` bool; `style:`; `bind:checked`; `{@html}` innerHTML; PascalCase `@child`; `{#each}{:else}` | `dom.test.ts` LangCoverage |
| G25 | Combinatorial coverage | multi-child `{#if}`; `{:else if}`; `{#await}` trio; `<slot>`; each item from markup + index + `class:`; component props; generic `@attr` | `dom.test.ts` Combo |
| G26 | Official AST batch 2 | `{#snippet}`/`{@render}`; `bind:this`/`group`; `{@const}`/`{@debug}`; `{#key}` remount; `svelte:window` + `on:\|preventDefault`; `$state`/`$derived`/`$effect` | `dom.test.ts` ComboMore |
| G27 | Official AST batch 3 | `use:`/`{@attach}` Handle; `transition:`/`in:`/`out:`/`animate:` `@style`; `{...spread}` comment; static `svelte:element`/`component`; fragment/boundary kids; snippet site | `dom.test.ts` ComboNext |
| G28 | Official AST batch 4 | each key `data-key`; `let:` field; `{let`/`{const` host field; `document().title`; `svelte:options` comments; `svelte:self` kids | `dom.test.ts` ComboRest |
| G29 | Official AST batch 5 | `<style>` `addCss` + `@style`; `style:` live concat + `!important`; dynamic `svelte:element` `data-tag`; `{...}` `data-spread` | `dom.test.ts` ComboCss |
| G30 | Official AST batch 6 | `textarea`/`select`/`option`; `bind:innerHTML`/`open`; boolean `disabled`; `on:once` + several `on:` | `dom.test.ts` ComboForm |
| G31 | Official AST batch 7 | SVG/`video`/`img`/`a`; several binds `paused`+`muted`; `aria-*`; `disabled={bool}`; `on:self`/`trusted`; boundary `failed` snippet | `dom.test.ts` ComboMedia |
| G32 | Official AST batch 8 | `{#if !cond}`; MathML; `dialog`/`audio`/`progress`/`canvas`/`iframe`; custom element; `bind:volume` double; `svelte:document`/`body` | `dom.test.ts` ComboWide |
| G33 | Official AST batch 9 | `{#if a && b}`; await then `{v}`; `{@render greet(who)}`; each `{name}`; table/form/label; `bind:clientWidth` | `dom.test.ts` ComboExpr |
| G34 | Official AST batch 10 | `{#if a \|\| b}`; named slot; `bind:scrollY`; picture/fieldset/meter/time/optgroup; `:global` | `dom.test.ts` ComboOr |
| G35 | Official AST batch 11 | `{#if n > 0}`; `bind:files`; ruby/datalist/template/track/caption; `style:--var`; `DragEvent` | `dom.test.ts` ComboMisc |
| G36 | Official AST batch 12 | `(a && b)`; `a == b`; snippet multi-arg; component `bind:this`; semantic HTML; pointer/focus/wheel/touch | `dom.test.ts` ComboSem |
| G37 | Official AST batch 13 | `a && !b`; each+if item; `[x, y]`; `bind:indeterminate`; clipboard/scroll; object/embed/cite/wbr | `dom.test.ts` ComboNest |
| G38 | Multi-file bun package | `packages/svelte-d-coverage`; `Panel`+`AppShell`; component `on:done` + `emit(done)` Slot; `{#if}`-wrapped `@child`; kit+dual-script | `bun test packages/svelte-d-coverage` |
| G39 | Kit board route | `routes/board` `+layout`+`+page`+`+page.server.d`; unique `BoardPageServer` (`classFromHostDest`); Slot+`svelte:head`+await; not hung on `Spa!App` | `bun test packages/svelte-d-coverage` (8) |
| G40 | Nested kit-app package | `packages/svelte-d-kit-app`; `+error`; `+server.d` POST; `board/[id]` + Panel + await trio; `kit_router` `/` `/board` `/:slug` `/board/:id`; three host classes | `bun test packages/svelte-d-kit-app` |
| G41 | Kit filesystem package | `packages/svelte-d-kit-fs`; `(app)` stripped; `[[lang]]` → `/docs` + `/docs/:lang`; `+layout.server.d` `AppLayoutServer`; shop `ClickField` + await | `bun test packages/svelte-d-kit-fs` |
| G42 | Kit host package | `packages/svelte-d-kit-host`; `[...path]` → `/files/*`; `hooks.server.d` → `errorPageHandler`; inbox `post`/`postSave` `InboxPageServer` | `bun test packages/svelte-d-kit-host` |
| G43 | Kit env package | `packages/svelte-d-kit-env`; `$app/environment`/`paths` + `$env/static/{public,private}`; account cookies/redirect/setCookie; private leak check | `bun test packages/svelte-d-kit-env` |
| G44 | Packaged engine + admin | `templates/engine` is the drop payload; `compile --project` overlays bun `src/`; admin PG/Redis/JSON; debug-map + Puppeteer rewrite | `bun test packages/svelte-d-kit-admin` |
| G45 | Admin I1 features | `users/[id]` + cookies/`$app`; `features` if&&!/ClickField/Panel/each/form/await; `+error`; rewrite `[id]` dests | `bun test packages/svelte-d-kit-admin` |
| G46 | Dual-browser + host log | Chrome+Firefox console → bun prompt; vibe.0 `logInfo`/`logError`/`logTrace` + `kitLog`; ANSI colors; `bun run dev` | `bun test packages/svelte-d-kit-admin` |
| G47 | DevTools stacks | Puppeteer CDP `consoleAPICalled`/`exceptionThrown`; `rewriteDevtoolsFrame`; libwasm `ABORT:` + page `debug-bridge`; public debug-map | `bun test packages/svelte-d-kit-admin` |
| G48 | Live admin probe | Vite `/` + `#root`; public debug-map; Chrome/Firefox `__svelteDRewrite` of AdminDash + `/admin` dests; no `ABORT:`; force-drop keeps `node_modules` | `bun test packages/svelte-d-kit-admin` |
| G49 | I2 overlay | `/__svelte-d/overlay` + `overlay.json`; LDC `file.d(line,col)` rewrite to orig `.svelte`; Chrome opens overlay | `bun test packages/svelte-d-kit-admin` |
| G50 | I3 IR inspector | `/__svelte-d/ir` lists debug-map dest/orig/kind; read-only; no compile!/wasm | `bun test packages/svelte-d-kit-admin` |
| G51 | I4 wasm names | name-section parse; `lib.AdminDash` / `_D` mangle → dest; `wasm://` rewrite; no DWARF | `bun test packages/svelte-d-kit-admin` |
| G52 | T5 kit remount | `@child KitRoutes` on App; `@entering` `setVisible` page+layout; one `Spa!App` | `bun test packages/svelte-d-kit-admin` |
| G53 | layout slot | pages `@child` of matching layout; `@entering` `setVisible!(page)(layout)`; hide slot fallback | `bun test packages/svelte-d-kit-admin` |
| G54 | coverage spread/tag/self | `applySpread` k=v `setAttribute`; `applyTag` data-tag; `svelte:self` `@child SelfDiv` | `bun test packages/svelte-kit-d` |
| G55 | compile! T* | libwasm skip null + same-type Ts growth; printer `@child Host* selfKid` | `bun test packages/svelte-kit-d` |
| G56 | createElement(string) | `createNode` reads `data_tag`; `applyTag` `document().createElement` + `replaceChild`; `this.update.tag` re-applies | `bun test packages/svelte-kit-d` |
| G57 | spread Handle | `applySpread(Handle)` + interned `applyObjectSpread`; ComboCss `{...extra}` | `bun test packages/svelte-kit-d` |
| G58 | T10 watch | `writeIfChanged` reprint-skip; `write.json`; watch rebuilds only the dirty cell | `bun test packages/svelte-kit-d` |
| G59 | dest sanitize | kit dests `_slug_`/`_lang_`/`_path_`; `{title}` prints; Pegged skips `{:else}` | `bun test packages/svelte-kit-d` + kit-app/fs/host |
| G60 | wasm IR keywords | `Slot!"default_"`; combo `@visible` inits in construct(); kit `+page` force-print | `bun test packages/svelte-kit-d` |
| G61 | wasm IR self/copy/events | skip same-type T* compile!/CSS; no @child inject-copy; toEventType drag/pointer/touch | `bun test packages/svelte-kit-d` |
| G62 | wasm IR form/slot/jshost | `nodeHandle` skips form `opDispatch`; emit Slot skip if author mixin; `import jshost : formatNow` | `bun test packages/svelte-kit-d` |
| G63 | live /admin remount | best `@entering`; no `dataset`/`clientWidth` assign; wasm-eh `jsCallback` export; `/admin` layout stays on users | `bun test packages/svelte-d-kit-admin` |
| G64 | compiled chrome | assemble `lib.Dock` + `kitRoutes.rootPage.show` onto App; handwritten `dock`/`Main` not the live IR | `bun test packages/svelte-kit-d` |
| G65 | engine pack + incr compile | engine App markers + HMR tick; `--only` + src-hash skip parse; watch pipes reload | `bun test packages/svelte-kit-d` |
| G66 | admin IR + debug remount | debug-map rewrite features/users; live `/admin/users/:id` + features + logs keep layout | `bun test packages/svelte-d-kit-admin` |
| G67 | kit params | `@entering` `ev.parameters[name]` → page field + `applyKitParams`; live `/admin/users/42` | `bun test packages/svelte-d-kit-admin` |
| G68 | popstate remount | window `popstate` → `callNative(navigate_to)`; `dropActive` + re-enter; live back without test `callNative` | `bun test packages/svelte-d-kit-admin` |
| G69 | Phobos + host pkgs | `lang=d` `import std.*` lifted to wasm module header; host `import vibe.db`/`botan`/`std` like helpers | `bun test packages/svelte-kit-d` + `svelte-d-kit-admin` |
| G70 | compiled NavBar | `NavBar.svelte` → `lib.NavBar`; App `import lib.NavBar`; handwritten `navbar.d` stays EH/PgLite golden | `bun test packages/svelte-kit-d` |
| G71 | host PG/Redis soak | `getSoak` N SETEX/GET + SELECT 1; Redis required when :6379 up; PG skip on auth | `bun test packages/svelte-d-kit-admin/test/soak.test.ts` |
| G72 | Pegged scan fallback | `parseMarkupEx` names pegged vs scan-thin/else/construct/fail; IR `parse=` | `bun test packages/svelte-kit-d` |
| G73 | DevTools interaction faults | CDP/pageerror/ABORT sink on live remount + overlay/IR filter | `bun test packages/svelte-d-kit-admin` |
| G74 | lang-features DevTools | if/each/await/click on live App; rewrite dest→orig; no ABORT | `bun test packages/svelte-d-kit-admin/test/lang-features.test.ts` |
| G75 | $app/navigation + HMR each | `gotoUrl` → `navigateTo`; overlay `hmr-each` when kind=each | `bun test packages/svelte-d-kit-env` + overlay |
| G76 | T12 adapters | `adaptWorkspace` + `adapter-{static,libwasm-spa,vibe0,vibe0-proxy}`; `svelte-kit-d adapt`; no Node HTTP | `bun test packages/svelte-kit-d/test/adapter.test.ts` |
| G77 | HMR list serialize | libwasm `hmr.d` dump/load `List`/`HTMLArray` as `:l:N:[{item}…]`; overlay `hmr-each` is info | `bun test packages/svelte-d-kit-admin/test/overlay.test.ts` |
| G78 | DevTools Combo* binds | `this.update.x` keeps host field; `bind:value`/`group`/`checked`/`open` seed + write-back; live ComboMore/Form/Css/Expr/Nest | `bun test packages/svelte-kit-d/test/dom.test.ts` + `svelte-d-kit-admin/test/lang-features.test.ts` |
| G79 | Nested `@child` | element kids hang on the parent struct; if/each/await stay on host; dotted connect/update paths | `bun test packages/svelte-kit-d/test/dom.test.ts` + `lang-features.test.ts` |
| G80 | Incremental wasm skip | `wasmDirty` ignores `src-svelte`; `write.json` `wasm>0` forces link; `svelte-d wasm` skips when dests fresh | `bun test packages/svelte-kit-d/test/watch.test.ts` |
| G81 | Nested struct emit + attr/html seed | child structs stay module-level; `{@html}` / `class:` seeded; attr mustache `id_` not colliding with `bind:value` | `bun test packages/svelte-kit-d/test/dom.test.ts` |
| G82 | Nest if/each/await | `{#if}`/`{#await}` kids hang on the parent element (`@visible` + `setVisible(owner)`); `<ul>{#each}` still absorbs as `UnorderedList`; bind seed only if host field exists; assemble skips non-struct lib modules | `bun test packages/svelte-kit-d/test/dom.test.ts` + `lang-features.test.ts` |
| G83 | Owner @visible sync | nested flip uses `owner.update.field`; construct seeds owner `@visible` bools; host else field stays in lockstep; src-hash pin `g83` | `bun test packages/svelte-kit-d/test/dom.test.ts` + `lang-features.test.ts` |
| G84 | DevTools runtime hook | `__svelteDProbe` + onerror/rejection; CDP `Log.entryAdded`; Combo* dest probes + `/admin/features` under the sink | `bun test packages/svelte-d-kit-admin/test/lang-features.test.ts` |
| G85 | Text mustache seed | `{ident}` `construct` seeds the `@prop` child; DevTools boot snapshot asserts `navy` / `a` / `Shown` / `On` | `dom.test.ts` + `lang-features.test.ts` |
| G86 | each-inner-if | `{#each}{#if cond}<li>` → `@visible` on the list; ComboNest Flip; DevTools click hides Show + items | `dom.test.ts` + `lang-features.test.ts` |
| G87 | await settle + wide flip | no-`job` `{#await}` prints `await_then=true`; ComboWide Flip hides `{#if !off}` | `dom.test.ts` + `lang-features.test.ts` |
| G88 | Element class UDA | `@style!"class"` sits on `NodeDef`, not the first `@child` (ComboWide `.combo-wide` was the Flip button) | `dom.test.ts` + `lang-features.test.ts` |
| G89 | each else live | host `string[]` empty skips seed (`voids_empty=true` → `None`); `xs = []` → `shrinkTo` + `setVisible` Empty (LangCoverage Wipe) | `dom.test.ts` + `lang-features.test.ts` |
| G90 | each else in ul | `<ul>{#each}{:else}` prints `ExtrasList`/`ItemsList` so Empty is a child of the `ul`, not a sibling | `dom.test.ts` + `lang-features.test.ts` |
| G91 | boundary failed | `<svelte:boundary>` hides `{#snippet failed}` until `this.update.boundary_failed`; ComboMedia Trip/Reset | `dom.test.ts` + `lang-features.test.ts` |
| G92 | await then | host `JsPromise` `{#await}` starts pending; `wireAwait` uses `.await` + `libwasmAwaitFailed` (fork) or `.then` (stock); `this.update.await_then` still settles (Combo Go) | `dom.test.ts` + `lang-features.test.ts` + `await-asyncify.test.ts` |
| G93 | await ready | App `ready` calls `combo.wireAwait` after render so settle `setVisible`s with live handles | `dom.test.ts` + `lang-features.test.ts` |
| G94 | each-inner-if items | `{#each}{#if cond}<li>` unmounts each `li`, keeps the `ul` (`sync_items_on`) | `dom.test.ts` + `lang-features.test.ts` |
| G95 | each-inner-if item field | `{#each rows as row}{#if row.ok}` — `bool ok` on the item; first seed true; `sync_rows_ok` / `fill_rows` | `dom.test.ts` + `lang-features.test.ts` |
| G96 | boundary failed(error, reset) | `{#snippet failed(error, reset)}` + `onerror` → `failBoundary` / `resetBoundary`; Retry remounts Ok | `dom.test.ts` + `lang-features.test.ts` |
| G97 | each-if item && host | `{#if pick.ok && on}` — `sync_picks_on` uses `it.ok && on`; Flip hides picks, ok-rows stay | `dom.test.ts` + `lang-features.test.ts` |
| G98 | each-if item \|\| host | `{#if hold.ok \|\| on}` — `sync_holds_on` uses `it.ok \|\| on`; Flip keeps first hold | `dom.test.ts` + `lang-features.test.ts` |
| G99 | each-if !item field | `{#if !skip.ok}` — `sync_skips_ok` uses `!it.ok`; Skip `fill_skips` hides the rest | `dom.test.ts` + `lang-features.test.ts` |
| G100 | each-if !item && host | `{#if !cut.ok && on}` — `sync_cuts_on` uses `!it.ok && on`; Flip hides cuts, skips stay | `dom.test.ts` + `lang-features.test.ts` |
| G101 | each-if !item \|\| host | `{#if !keep.ok \|\| on}` — `sync_keeps_on` uses `!it.ok \|\| on`; Flip keeps the `!ok` row | `dom.test.ts` + `lang-features.test.ts` |
| G102 | each-if item && !host | `{#if drop.ok && !on}` — `sync_drops_on` uses `it.ok && !on`; Flip shows the first drop | `dom.test.ts` + `lang-features.test.ts` |
| G103 | each-if !item \|\| !host | `{#if !both.ok \|\| !on}` — `sync_boths_on` uses `!it.ok \|\| !on`; Flip shows both | `dom.test.ts` + `lang-features.test.ts` |
| G104 | each-if !item && !host | `{#if !nand.ok && !on}` — `sync_nands_on` uses `!it.ok && !on`; Flip shows the `!ok` nand | `dom.test.ts` + `lang-features.test.ts` |
| G105 | boundary D throw | `throwBoundary` same-function `throw`/`catch` → `failBoundary` (navbar EH path; no Navbar edit) | `dom.test.ts` + `lang-features.test.ts` |
| G106 | Svelte NavBar chrome | `NavBar.svelte` burger `{#if open}` + `{#each links}`; Button still EH+PgLite; handwritten `navbar.d` untouched | `dom.test.ts` + `lang-features.test.ts` |
| G107 | per-`.o` wasm | `.svelte-d/o/` + `ldc2 -c -oq --cache` of `src-d` (all files on the line so `routes._app_` resolves) + relink objects + libwasm `.a`; LTO/`describe` miss → `dub` | `wasm.test.ts` |
| G108 | assemble ready skip | `assembleAwaitReady` replaces the ready block in place (no leftover spaces before `begin-ready`); lib scan is sorted | `watch.test.ts` |
| G109 | each-if item `n > 0` | `{#if hit.n > 0}` — `int n` on the item; first seed `1`; `sync_hits_n` / `fill_hits` | `dom.test.ts` + `lang-features.test.ts` |
| G110 | each-if cmp && host | `{#if more.n > 0 && on}` — `sync_mores_on` uses `it.n > 0 && on`; Flip hides mores, hits stay | `dom.test.ts` + `lang-features.test.ts` |
| G111 | each-if cmp \|\| host | `{#if lot.n > 0 \|\| on}` — `sync_lots_on` uses `it.n > 0 \|\| on`; Flip keeps first lot | `dom.test.ts` + `lang-features.test.ts` |
| G112 | each-if cmp && !host | `{#if few.n > 0 && !on}` — `sync_fews_on` uses `it.n > 0 && !on`; Flip shows the first few | `dom.test.ts` + `lang-features.test.ts` |
| G113 | each-if cmp table | 10 remaining mixes in `ComboIfCmp` + `EACH_IF_CMP_CASES` (ops, host-first, `!on`, rhs≠0); one IR loop + one Flip loop | `dom.test.ts` + `lang-features.test.ts` |
| G114 | coverage tables | `coverage-plan.md` 10 suites; ComboNest bool + ComboIfHost host-if table-driven IR/live | `dom.test.ts` + `lang-features.test.ts` |
| G115 | host-if multi-vis | several host `{#if}`s sharing `on` all get `setVisible`; `{#if !on}` kids named `not_on*`; no duplicate `bool on` | `dom.test.ts` + `lang-features.test.ts` |
| G116 | cover tables | `ComboCover` + `each-else` / `await` / `bind` tables (wipe Empty-in-ul, pending→then/catch, value/checked/open/group/files) | `dom.test.ts` + `lang-features.test.ts` |
| G117 | surf tables | `ComboSurf` + `directive` / `special` / `boundary` tables (`class:`/`style:`/`once`/spread/`use:`, element/fragment/component/window, throwBoundary Retry) | `dom.test.ts` + `lang-features.test.ts` |
| G118 | cmp leftovers | `!(n > 0)`, empty `{#each} zeds = []`, `n > lim` (item vs host) on `ComboIfCmp` | `dom.test.ts` + `lang-features.test.ts` |
| G119 | await + fork EH | `wireAwait` prints `.await` + `libwasmAwaitFailed` (stock `.then` fallback); asyncify rewind-on-reject, export queue, `__svelteDRewriteError` | `await-asyncify.test.ts` + `wasm-eh.test.ts` + `admin.test.ts` |
| G120 | wasm-opt CI | CI builds etcimon/binaryen wasm-opt for win/mac/linux; setup downloads into `binaryen-build/` like LDC 1.43; openssl 3.3.4 add-local for vibe-0 | `platform.test.ts` + `.github/workflows/wasm-opt.yml` |
| G121 | await catch text | `{:catch e}` `{e}` filled from `libwasmAwaitError()` after rewind; stock `.error` notes the Any handle first. Do not wrap `.await` in `try` | `await-cases.ts` + `await-asyncify.test.ts` + `wasm-eh.test.ts` |
| G122 | await then text | `{:then v}` `{v}` filled from `libwasmAwaitValue()` after rewind; stock `.then` notes the Any handle first | `await-cases.ts` + `await-asyncify.test.ts` |
| G123 | multi-await wire | each `{#await}` job gets its own `wireAwait` block; first keeps `await_then` / `await_catch`; later jobs use `await_*_<job>` and snapshot `{e}`/`{v}` paths | `await-cases.ts` |
| G124 | await bind uniquify | two `{:catch e}{e}` emit `eP` / `eP2` (unique field + struct); wire snapshots each path so both fills stay | `await-cases.ts` |
| G125 | d↔ts callTs | `lang=ts` exports → `__svelteD.ts[ident]` + `jsExports.env`; D thunks `callTs`/`callTsPromise` (Lodash invoke, optional args); `extern(C) export` → `exportDelegate(ident.fn)`; multi-script + cross-svelte `import lib.X : greet` | `cross-call.test.ts` |
| G126 | ts dep fall-through | `lang=ts` npm imports → dest `package.json` (project declared range) + dest `node_modules/<pkg>` **copy** of the project’s install + `bun install` if missing; `$lib` / relative rewrite; not `file:` | `extensions.test.ts` + `admin.test.ts` |

Recorded limits: Pegged `mixin(grammar)` stack-overflows (use `grammar/sveltekit.peg` as spec + runtime scan). Template `comfyapi.d` / `dmaxminddb` stubbed. 1.43 wasm has no asyncify.

---

## D IR logical order (why T3 is next)

svelte-d proceeds by **completing the libwasm D IR**, not by jumping to Pegged or wasm because they are “next numbers.” Layers already green stay green. Remaining work is the next unfilled layer.

| Layer | What the D IR still needs | Status | Track item |
|---|---|---|---|
| L0 | Fall-through + engine bootstrap + two cells | G7–G10 | done |
| L1 | Graph kinds: NodeDef / `@child` / `@prop` / Slot / `@connect` / `@inject` / `UnorderedList` | G11 | done |
| L2 | AST ≡ that graph; representative module/struct/var names | G12 | done |
| L3 | Pool-correct allocation (`ScopedPool`, copy-out, freeze) | G13 | documented; printer wrap in T3 |
| L4 | `compile!` / Spa **lifetime methods** (`construct`, `onMount`, `onUnmount`, App `ready`) | G14 + G16 | printed |
| L4c | `{#if ident}` → `@visible` + remount/unmount | G17 + G23 | printed; `{:else}` inverted `setVisible` |
| L4b | Yield: wasm-eh `try`/`catch` must not **wrap** asyncify `.await`; after-rewind flag is OK | G15 | printer: `wireAwait` `.await` + fallback `.then` |
| L5 | **Assemble** printed structs under one `mixin Spa!App` (`@child ClickField`, list `put` in `construct`) | G16 | markers on golden `app.d` |
| L6 | Parse fidelity: Pegged `asModule` onto the **same** AST | G18–G19 | Document + MarkupDoc→MkNode; scan fallback if thin |
| L7 | Kit tree: layouts stay mounted; page swap via `@entering` + remount | G52 | T5 |
| L8 | Cells: wasm/host `dub build` **inside the ws** | G20 + G21 | done |
| L9 | Serve / watch | G22 + G58 | T8–T10 |
| L10 | Kit v1 subset + adapters | G75 + G76 | T11, T12 |

Do not start T6 (wasm rebuild) until L5 hangs named structs under `App` — otherwise the wasm cell still only boots the golden navbar/dock. Do not let T2 invent IR kinds that `compile!` does not walk.

## Track — ordered, each step has a green command

### T0 — Ledger (this file)

Write and keep this queue honest after every pass.

**Green:** this file lists G* and the single **next** item.

### T1 — Dual-script contract + IDE

- Accept **both** `lang="d"` and `lang="ts"` (and `context="module"`).
- Golden `.svelte` files are **nominal Svelte**: markup + `<script lang="ts">` (IDE) + `<script lang="d">` (libwasm) where both are needed.
- `svelte.config.js` preprocess: `lang="d"` → empty/comment TS so svelte-check / vscode-svelte do not error on D.
- `tsconfig` includes `src-svelte/**/*.svelte` and `src-ts`.
- Compiler **attaches** `lang="ts"` bodies into `src-ts/modules/generated/` using the `jsExports` template (`modules/index.ts` merge).

**Green:** `bun test` still passes; compile writes `generated/` when a `lang="ts"` block exists; parse of dual-script goldens succeeds.

### T2 — Pegged `asModule` feeds the **same** AST

Replace `parse/markup.d` with generated `source/svelte_d/grammar/sveltekit.d` via Pegged `asModule` (webidl-grammar split). Productions lower to the **existing** AST kinds (`Element` / `EachBlock` / mustache / `on:`) that [ast-ir.md](architecture/ast-ir.md) already maps onto NodeDef / UnorderedList. Do not introduce a parallel IR. May run beside T3-lifetime; must not block L5 or invent kinds `compile!` does not walk.

**Green (G18–G19):** `asModule` + `SvelteKit.Document` on goldens. `parseMarkup` lowers `MarkupDoc` through `unwrapRule` onto the same `MkNode` kinds. Scan is fallback only. `svelte-d parse … --dump-peg` prints the tree. `dom.test.ts` + `pipeline.test.ts` green.

### T3 — Pretty-print AST → assembled D IR  (partial; lifetime+assemble green)

Printer emits the libwasm D IR ([udas.md](architecture/udas.md), [AGENTS-D-IR-lifetime.md](architecture/AGENTS-D-IR-lifetime.md)):

**T3-graph (G9–G12, done):** `mixin NodeDef` → NamedNode, `@child`, `@prop`/`@attr`, `@callback`, `@connect` / `@inject`, `UnorderedList` + `HTMLArray.assignEventListeners`. Names match the Svelte. Lodash / moment / bindings only when `lang=d` already wrote them.

**T3-lifetime (G16):**

- Emit `void construct()` for field init, `{#each}` seed (`menulist.put(...)` like `navbar.d:62-65`), and `ManagedPool` only on App (or the golden owner). No DOM in `construct`.
- Map Svelte `onMount` / `onDestroy` → `void onMount()` / `void onUnmount()`. Do not print JS imports.
- Do **not** print `App.ready()` unless the Svelte has first-load work (missing `ready` keeps default `navigateTo`).
- Wrap heavy `@connect` / list-rebuild / Lodash bodies in `ScopedPool(m_pool)` and copy survivors ([AGENTS-D-IR-memory-management.md](architecture/AGENTS-D-IR-memory-management.md)).
- `{#if}` → `setVisible` / `remount` / `unmount`, not a second struct type.
- **Yield:** wasm-eh `wireAwait` prints `.await` + `libwasmAwaitFailed()` when the fork asyncified the module, else `JsPromise.then`. A rejected reason fills `{:catch e}` via `libwasmAwaitError()` after rewind; a resolve fills `{:then v}` via `libwasmAwaitValue()`. A `try` must not wrap the import. Keep `--foptimize-nothrow=false` on that `dub.sdl`. See [AGENTS-D-IR-asyncify-wasm-eh.md](architecture/AGENTS-D-IR-asyncify-wasm-eh.md).

**T3-assemble (G16):**

- Hang each printed component as `@child` on golden `App` (or on a layout that is already `@child` of `App`). One `mixin Spa!App`. Do not emit a second `_start`.
- Import the fall-through module (`import lib.ClickField;` — `sourcePaths "src-d"`).
- Do not overwrite `src-d/{app,dock,navbar,pglite,jshost,probe}.d` bodies; insert only the `@child` + import needed to compile the new graph.

**Green (G16+G17):** `dom.test.ts` 5 pass — lifetime + assemble + `{#if}` `@visible`. `{:else}` still skipped.

### T4 — `lang="ts"` registration template (complete; G125 extends)

- Template file in `packages/svelte-d/templates/js-module.ts.tmpl`.
- If the TS block already `export let jsExports`, copy through.
- Else wrap exported functions as `jsExports.env.<name>(...args)` **and** `ensureSvelteD().registerTs(ident, name, fn)`. Skip name `jsExports`.
- Rewrite `src-ts/modules/index.ts` from `templates/modules-index.ts.tmpl` (always keep `bindings`, `spa`, `libwasm`, `debug-bridge`).
- **G125 seam:** D→TS is Lodash `callTs` / `callTsPromise` on `__svelteD.ts`. TS→D is `exportDelegate` + `callNative` (`setDRet` / `__svelteD.ret`). Not a new WASM import list. See [cross-calling.md](architecture/cross-calling.md).

**Green:** bun test that a `lang="ts"` `hello()` appears in `ws/src-ts/modules/generated/` and `index.ts` imports it. G125: `cross-call.test.ts`. G126: dest deps in `extensions.test.ts` + `admin.test.ts`.

### T5 — Kit filesystem + layouts

`+page`, `+layout`, `(groups)`, `[param]`. Layouts stay mounted `@child`. Page swap is `unmount` / `remount` inside `@entering` on the compiled graph (`registerRoutes`), not a second wasm module and not a second `Spa!`. See [AGENTS-D-IR-lifetime.md](architecture/AGENTS-D-IR-lifetime.md).

**Green (G52+G53):** `KitRoutes` hung on `App`; slotted pages are `@child` of the matching layout; `@entering` `setVisible`s the page on that layout and hides `slot_default`. `bun test packages/svelte-d-kit-admin`.

### T6 — Wasm cell driver **inside the ws** (G20)

Requires L5 (printed structs hang under `App`). `svelte-d` or `svelte-kit-d` invokes `dub build --arch=wasm32-unknown-wasi` using **ws** `dub.sdl` (default wasm-eh). Never build the template. The wasm module must elaborate the **assembled** IR (`compile!(App)` sees the new `@child`s).

Titled libwasm seams this pass: `EventEmitter!()` `add` appends (`~=`); `Eval.opCast!bool`; `Lodash.this` assigns by `T` (`@trusted`); `Command.setString` `str.handle`. Printer: `this.update.msg` → `msgSpan.update.msg`; `{#if}` → `setVisible!"child"`; `Slot!"click"`; `@trusted` on printed structs; `location()` not `.front`.

**Green (G20):** `ws/public/svelte-engine.wasm` from this build; `node run-probes.mjs` PASS (eh + phobos); `wasm.test.ts` pass.

### T7 — Host cell driver (G21)

Print `+page.server.d` / `+server.d` into `ws/webserver/source/generated/` as a vibe.0 `registerWebInterface` class (`PageServer`). Hang on golden `webserver/source/app.d` under `/__svelte-d/host/` (does not steal Vite `/`). `svelte-d host --ws` runs `dub build` in `ws/webserver` with host LDC 1.42. Never build the template.

**Green (G21):** `ws/webserver/svelte-engine-server.exe` links; `host.json` `ok: true`; `host.test.ts` pass.

### T8 — bun dev serves the compiled program (G22)

`bun src/cli.ts dev`:

1. drop-ws if needed  
2. compile (D + TS attach)  
3. wasm + host builds if dirty (`if-stale`)  
4. `bun install` in the ws (drop skips `node_modules`)  
5. local Vite in ws (`:5173`, HMR `:3001`)  
6. start vibe.0 `:8180` if the binary exists (`--no-host` to skip)  
7. watch `src-svelte` → compile → dirty wasm or `notifyWasmReload`

Engine seam: `vite.config.js` `notifyClients` now always starts the notify loop (it previously only armed a timer when `building` was already true, so wasm mtime never posted `reload`).

**Green (G22):** GET `/` and `/svelte-engine.wasm` are 200; HMR ws sends `reload` after the wasm file is rewritten (`serve.test.ts`).

### T9 — bun test: full program

`packages/svelte-kit-d/test/serve.test.ts` (or similar): drop → compile → (optional) wasm/host → assert manifest + generated TS module + `src-d/pglite.d` + parse of dual-script goldens. Gate wasm/host on tools present.

**Green:** `bun test` all green on this Windows host.

### T10 — Incremental watch

Reprint-skip + opposite-cell-skip; G80 skips the relink when dests are unchanged. G107: dirty `src-d` `.o` + relink on the default cell.

### T11 — SvelteKit v1 feature subset

`load` / actions / `$app` env as in [architecture/sveltekit-feature-map.md](architecture/sveltekit-feature-map.md). Honesty over coverage.

### T12 — Adapters (G76)

`adaptWorkspace` in `packages/svelte-d/ts/adapter.ts` reads `ws/.svelte-d/manifest.json` and copies artifacts. Bun packages: `adapter-static`, `adapter-libwasm-spa`, `adapter-vibe0`, `adapter-vibe0-proxy`. CLI: `svelte-kit-d adapt`. Does not add a Node HTTP stack. Capacitor remains out of v1 (consume SPA output later).

---

## Invariants (every pass)

- Two LDC cells. svelte-d itself is host-cell only (no libwasm in *its* link line).
- Builds of the **app** happen in `svelte-engine-ws`, never in `svelte-engine/`.
- Kit syntax falls through to libwasm / vibe.0 in an equivalent ws tree. Do not invent a third layout.
- AST kinds are the libwasm D IR. Lodash/moment/bindings are sparse procedural. Printed names stay representative of the Svelte.
- Printed wasm D is pool-correct: live `ScopedPool` precedes `alloc`/`_d_allocmemory`/`allocString`; copy or freeze before a pointer escapes the scope; do not print language `new` for handler temps.
- Printed D uses libwasm lifetime hooks (`construct` / `onMount` / `onUnmount` / App `ready`). One `Spa!App`. Printed structs hang as `@child`. No Svelte JS `onMount`.
- wasm-eh cell: `wireAwait` `.await` (fork) or `.then` (stock); keep `--foptimize-nothrow=false`. Official post-link is Binaryen ≥123 `wasm-opt -Oz` / `-g -O0` with `--enable-exception-handling`. Official 123/132 still must not `--asyncify` `try_table`. Fork `binaryen-svelte-d` does. Landing pad must not wrap `libwasm_await__void`.
- Kit features are accommodated in svelte-engine / libwasm / vibe.0. Compile integrates the current engine as svelte-engine-ws. svelte-d only prints that D IR.
- `lang="d"` → libwasm D. `lang="ts"` → `src-ts/modules` `jsExports`. Crossing is Lodash `callTs` / `exportDelegate` with module-mangled names.
- Pegged/libdparse never enter the wasm `dub.sdl`.
- PgLite stays the persistence wrap (`pglite.d` / `window.pglite`).
- Do not mutate slideshow3dai, libwasm, vibe.0 unless a titled seam PR.

## Open (do not block T1–T4)

Pegged `asModule` vs scan; HMR port 3579 vs 3001; `bun install` in ws for Vite; whether `index.ts` is fully generated or patched between markers.

## Pass log

| date | pass | outcome |
|---|---|---|
| 2026-08-14 | G1–G3 CLI + bun test | parse/drop/compile; 5 bun tests |
| 2026-08-14 | T1 start | dual-script + TS jsExports template + AGENTS-todo |
| 2026-08-14 | T1 | dual-script goldens; compile attaches lang=ts → `src-ts/modules/generated` + index merge; `bun test` 5 pass |
| 2026-08-14 | G7 | svelte-d is an importable TS+exe+lib; kit→ws fall-through mapping; bun consumer tests 17 pass |
| 2026-08-14 | G8 | accommodate kit features in svelte-engine/libwasm/vibe.0; compile-time ws bootstrap |
| 2026-08-14 | G9 | lang=d Lodash → ws/src-d/lib/lodashdemo.d; catalog from libwasm lodash.d |
| 2026-08-14 | G10 | lang=d bindings/types + kit URLRouter; serve surfaces + vite smoke |
| 2026-08-14 | G11 | NodeDef→NamedNode, @connect/@inject paths, HTMLArray list events; udas.md |
| 2026-08-14 | G12 | AST≡libwasm D IR; representative dest/module/struct/var names |
| 2026-08-14 | G13 | memutils + libwasm fall-through; ScopedPool precedence; copy-out / freeze |
| 2026-08-14 | G14 | compile!/Spa lifetime hooks; D IR logical order; T3-lifetime next |
| 2026-08-14 | G15 | asyncify vs wasm-eh: LDC nothrow + Binaryen Flatten; engine `_start`/await glue |
| 2026-08-14 | G16 | T3-lifetime/assemble: ScopedPool + onMount + hang lib structs on App |
| 2026-08-14 | G17 | `{#if open}` → `@visible!"child" bool open` + remount; IfToggle fixture |
| 2026-08-14 | G18 | Pegged asModule Document ParseTree; markup print remains scan |
| 2026-08-14 | G19 | MarkupDoc→MkNode via unwrapRule; Pegged is the print AST |
| 2026-08-14 | G26 | ComboMore: snippet/render, bind:this/group, const/debug, key remount, svelte:window, rune peel |
| 2026-08-14 | G27 | ComboNext: use:/attach Handle, transition @style, spread, svelte:element/fragment/component/boundary |
| 2026-08-14 | G28 | ComboRest: each key, let:, {let}, svelte:head title, svelte:options, svelte:self kids |
| 2026-08-14 | G29 | ComboCss: addCss from &lt;style&gt;, style: concat+important, data-tag, data-spread |
| 2026-08-14 | G30 | ComboForm: textarea/select, bind:innerHTML/open, disabled, on:once+keydown |
| 2026-08-14 | G31 | ComboMedia: svg/circle/video/aria, bind:paused+muted, on:self\|trusted, boundary failed |
| 2026-08-14 | G32 | ComboWide: !if, math/dialog/audio volume, custom element, svelte:document/body |
| 2026-08-14 | G33 | ComboExpr: a&&b if, await {v}, render args, each {name}, table/form, clientWidth |
| 2026-08-14 | G34 | ComboOr: a\|\|b if, named slot, window scrollY, picture/fieldset/meter, :global |
| 2026-08-14 | G35 | ComboMisc: n>0 if, bind:files, ruby/template/track, style:--var, dragstart |
| 2026-08-14 | G36 | ComboSem: (a&&b), a==b, pair args, component bind:this, landmarks, pointer/focus |
| 2026-08-14 | G37 | ComboNest: on&&!hide, each+if, [x,y], indeterminate, clipboard/scroll, more tags |
| 2026-08-14 | G38 | svelte-d-coverage: multi-file Panel+AppShell, component on:, emit Slot, bun import |
| 2026-08-14 | G39 | board layout+page+host; classFromHostDest BoardPageServer; coverage route-board 8 pass |
| 2026-08-14 | G40 | svelte-d-kit-app: error+[id]+endpoint; kit_router four patterns; 3 host classes |
| 2026-08-14 | G41 | svelte-d-kit-fs: (groups) strip, [[optional]] expand, AppLayoutServer; kitToPatterns |
| 2026-08-14 | G42 | svelte-d-kit-host: [...rest] *, hooks errorPageHandler, inbox post/postSave |
| 2026-08-14 | G43 | svelte-d-kit-env: $app/$env enums, account cookies/redirect, private leak |
| 2026-08-14 | G44 | pack svelte-engine into svelte-d/templates/engine; drop that; --project ingest; admin PG/Redis/JSON + debug-map |
| 2026-08-14 | G45 | admin I1: users/:id cookies+$app, features combo page, +error, [id] stack rewrite |
| 2026-08-14 | G46 | chrome+firefox bridge; vibe.0 kitLog + colored INF/WRN/ERR; bun run dev |
| 2026-08-14 | G47 | CDP DevTools stacks; wasm abort → svelte orig; debug-bridge + public map |
| 2026-08-14 | G48 | live Vite+Puppeteer/Firefox: debug-map HTTP, AdminDash on App, no ABORT |
| 2026-08-14 | G48 | DevTools rewrite of AdminDash+/admin dests; force-drop keeps node_modules; {#if}+{#each} @visible |
| 2026-08-14 | G49 | I2 overlay page + overlay.json; LDC dest rewrite; live Chrome overlay |
| 2026-08-14 | G50 | I3 read-only IR inspector; ir.json dests+kinds; Chrome lists AdminDash |
| 2026-08-14 | G51 | I4 wasm name section → dest/orig; _start unmapped; no DWARF |
| 2026-08-14 | G52 | T5 KitRoutes remount via @entering setVisible; layouts stay |
| 2026-08-14 | G53 | slot projection: admin pages @child of layout; setVisible on layout |
| 2026-08-14 | G54 | applySpread k=v; applyTag; svelte:self @child SelfDiv |
| 2026-08-14 | G55 | compile!/registerRoutes same-type T*; svelte:self @child Host* selfKid |
| 2026-08-14 | G56 | createElement(string) in createNode; applyTag replaceChild + handle steal |
| 2026-08-14 | G57 | applySpread(Handle) + interned applyObjectSpread; ComboCss Handle extra |
| 2026-08-14 | G58 | T10 reprint-skip writeIfChanged; opposite-cell watch; write.json |
| 2026-08-14 | G59 | dest sanitize; ExpressionTag print; {:else} scan path (no dup OpenP) |
| 2026-08-14 | G60 | Slot default_; @visible CTFE → construct; force-print kit page.d |
| 2026-08-14 | G61 | compile!/CSS skip T*; setParam skip @child; toEventType drag/clipboard/pointer |
| 2026-08-14 | G62 | nodeHandle for form listeners; emitSlotNames skip existing mixin Slot; formatNow jshost |
| 2026-08-14 | G63 | URLRouter keepBestEntering; each index not dataset; skip getter-only props; export jsCallback; live /admin remount |
| 2026-08-14 | G64 | assemble printed Dock + kit root Page onto App; no live import dock / Main |
| 2026-08-14 | G65 | pack engine App markers + vite hmr-tick; compile --only + src-hash skip |
| 2026-08-14 | G66 | admin svelte→D IR debug-map; live remount :id/features/logs |
| 2026-08-14 | G67 | kit :param → page field + applyKitParams; live users/42 |
| 2026-08-14 | G68 | dropActive + re-enter on revisit; popstate → navigate_to; live back features + users/42 |
| 2026-08-14 | G69 | lang=d Phobos lift; host vibe/botan/std imports same graph as helpers PG/Redis |
| 2026-08-14 | G70 | printed NavBar.svelte on App; handwritten navbar.d passthrough |
| 2026-08-14 | G71 | host soak getSoak; Redis live; Postgres skip if golden creds fail |
| 2026-08-14 | G72 | parseMarkupEx named fallback; Dock pegged; Combo scan- |
| 2026-08-14 | G73 | DevTools sink on kit nav/popstate + overlay/IR inspector |
| 2026-08-14 | G74 | live IfToggle/ClickField/ListEvents/Combo DevTools rewrite |
| 2026-08-14 | G75 | kit.app_navigation.gotoUrl; overlay hmr-each warn |
| 2026-08-14 | G76 | T12 adapters consume manifest.json; four bun packages; no Node HTTP |
| 2026-08-14 | G77 | libwasm HMR serializes List/HTMLArray; overlay hmr-each is info |
| 2026-08-14 | G78 | bind:value/group write-back + this.update host lockstep; DevTools Combo* |
| 2026-08-14 | G79 | nested @child (option in select, p in svelte:element); if/each stay on host |
| 2026-08-14 | G80 | skip whole-program wasm when dests unchanged; still one dub when dirty |
| 2026-08-14 | G81 | module-level child structs; {@html}/class: construct seed; id_ vs bind:value |
| 2026-08-14 | G82 | nest {#if}/{#await} on parent element; ul+each stays UnorderedList; LangCoverage section+if |
| 2026-08-14 | G83 | owner.update.@visible lockstep on flip; construct seeds owner bools; src-hash printer pin |
| 2026-08-14 | G84 | CDP Log + __svelteDProbe runtime dest rewrite; Combo* + /admin/features DevTools check |
| 2026-08-14 | G85 | {ident} construct seed; live DOM snapshot via DevTools hook |
| 2026-08-14 | G86 | {#each}{#if cond} gates UnorderedList; ComboNest Flip + DevTools hide |
| 2026-08-14 | G87 | {#await} without job settles to then; ComboWide Flip + live hide Shown |
| 2026-08-14 | G88 | element class UDA on NodeDef; ComboWide Shown first paint |
| 2026-08-14 | G89 | {#each}{:else} empty host array + extras=[] wipe; DevTools None/Empty |
| 2026-08-14 | G90 | ul+each+else prints ExtrasList; Empty remounts inside ul |
| 2026-08-14 | G91 | svelte:boundary ok/failed @visible; ComboMedia Trip/Reset live |
| 2026-08-14 | G92 | {#await} pending first; Combo Go this.update.await_then |
| 2026-08-14 | G93 | App.ready wireAwait after render; job.then Wait→Done |
| 2026-08-14 | G94 | {#each}{#if} sync_items_on; Flip hides lis, ul stays |
| 2026-08-14 | G95 | {#each}{#if row.ok} item field; Pin fill_rows 1→2 ok-row |
| 2026-08-14 | G96 | svelte:boundary failed(error, reset) + onerror; Retry live |
| 2026-08-14 | G97 | {#if pick.ok && on} sync_picks_on; Flip hides picks |
| 2026-08-14 | G98 | {#if hold.ok || on} sync_holds_on; Flip keeps first hold |
| 2026-08-14 | G99 | {#if !skip.ok} sync_skips_ok; Skip fill hides rest |
| 2026-08-14 | G100 | {#if !cut.ok && on} sync_cuts_on; Flip hides cuts |
| 2026-08-14 | G101 | {#if !keep.ok || on} sync_keeps_on; Flip keeps !ok |
| 2026-08-14 | G102 | {#if drop.ok && !on} sync_drops_on; Flip shows first drop |
| 2026-08-14 | G103 | {#if !both.ok || !on} sync_boths_on; Flip shows both |
| 2026-08-14 | G104 | {#if !nand.ok && !on} sync_nands_on; Flip shows !ok nand |
| 2026-08-14 | G105 | throwBoundary try/throw/catch → failBoundary; Trip live |
| 2026-08-14 | G106 | NavBar.svelte burger {#if}+{#each}; EH Button; navbar.d untouched |
| 2026-08-14 | G107 | per-.o wasm: ldc2 -c dirty src-d → .svelte-d/o/; relink + libwasm .a; dub fallback |
| 2026-08-14 | G108 | assembleAwaitReady in-place ready block; second compile no longer rewrites app.d |
| 2026-08-14 | G109 | {#if hit.n > 0} int n on item; Hit fill_hits 1→2 hit-row |
| 2026-08-14 | G110 | {#if more.n > 0 && on} sync_mores_on; Flip hides mores |
| 2026-08-14 | G111 | {#if lot.n > 0 || on} sync_lots_on; Flip keeps first lot |
| 2026-08-14 | G112 | {#if few.n > 0 && !on} sync_fews_on; Flip shows first few |
| 2026-08-14 | G113 | ComboIfCmp 10-case table; generic IR + live Flip |
| 2026-08-14 | G114 | coverage-plan 10 suites; EACH_IF_BOOL + HOST_IF tables |
| 2026-08-14 | pack | svelte-engine packaged in svelte-d; drop → svelte-engine-ws; isolated bun import |
| 2026-08-15 | libwasm | engine dub.sdl uses ~master + git fetch; add-local checkout wins |
| 2026-08-15 | pkg | repo-root svelte-d package; bun install builds CLI; GHA CI |
| 2026-08-15 | ext | engine-setup 1.43 + extensions plan (svelte pkg / scss / jquery / lang=ts splice) |
| 2026-08-15 | ingest | imported node_modules .svelte + project ts/scss onto ws; not package.json dump |
| 2026-08-15 | engine | drop 3dify/comfy/prisma; vibe.0 serveStaticFiles public/; pin wasm 1.43 |
| 2026-08-15 | cfg | svelte-d.config.ts workspace → project-root svelte-engine-ws; drop generateSourceMap/capacitor |
| 2026-08-15 | ldc | one LDC 1.43 for CLI/host/wasm; bunx svelte-d setup on win/mac/linux |
| 2026-08-15 | docs | docs/ Nextra site: lang→D IR + simplified admin example |
| 2026-08-15 | wasm-opt | Binaryen ≥123 official post-link: parse try_table, -Oz release / -g -O0 debug, never --asyncify; kit-admin ship 0.93 MiB / 224 KB gzip |
| 2026-08-15 | binaryen | fork etcimon/binaryen; submodule binaryen/ branch svelte-d; Flatten try_table start; bun run build-wasm-opt |
| 2026-08-15 | wasm-eh+ay | fork asyncify LDC try_table; eh_probe=1 on ship; throwBoundary IR; run-probes raw+asyncify |
| 2026-08-15 | G125 | d↔ts `callTs` / `exportDelegate`; module-mangled `__svelteD`; optional `ARGS...`; `cross-call.test.ts` |
| 2026-08-15 | G126 | dest npm = declared range + copy of project install + `bun install`; `$lib` rewrite; admin `admin-mini` |
| 2026-08-15 | docs | architecture/cross-calling.md + stale notes/human pages match g126 |
