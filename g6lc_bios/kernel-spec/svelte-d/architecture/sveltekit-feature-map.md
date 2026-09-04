# SvelteKit feature map

The next change that implements or *advertises* a SvelteKit feature updates this table in the same PR. Statuses are exclusive. “Works” in a README is a bug unless the row is **Implemented-by-mapping** and a fixture exists.

Legend:

| Status | Meaning |
|---|---|
| **Implemented-by-mapping** | Existing libwasm or vibe.0 mechanism is enough; printer emits it |
| **Requires-new-libwasm-seam** | Designed; needs a later PR *in libwasm* |
| **Requires-new-vibe.0-seam** | Designed; needs a later PR *in vibe.0* |
| **Host-JS-only** | bun / generated JS adapter; not D |
| **Out-of-scope-for-v1** | Named and deferred |

Parser input is Svelte/SvelteKit source. **Accommodation is not a svelte-d runtime:** Implemented-by-mapping means the construct already exists as a libwasm or vibe.0 idiom **in svelte-engine**; svelte-d only prints that shape into the compile-time `svelte-engine-ws` bootstrap ([bootstrap.md](bootstrap.md)). Requires-new-*-seam means update that runtime first, then the engine, then the printer. Nothing below is implemented as a third stack in svelte-d. **“Implemented-by-mapping” applies only to the v1 source subset** (canonical design). A construct not on that list cannot be Implemented-by-mapping.

## Routing and filesystem

| Feature | Status | Target / gap |
|---|---|---|
| `src/routes` file-based routing | Implemented-by-mapping | IR `Route` + printers |
| `+page.svelte` | Implemented-by-mapping | libwasm struct + optional SSR builder |
| `+layout.svelte` (nested) | Implemented-by-mapping | `@child` wrappers; not router entries |
| `+error.svelte` | Implemented-by-mapping | client error struct + `errorPageHandler` |
| `+page.ts` universal `load` | Out-of-scope-for-v1 | forbid; diagnostic: use `+page.server.ts` |
| `+page.server.ts` `load` | Implemented-by-mapping | **sync** `load({ params })` → JSON scalars only (v1 subset) |
| `+layout.ts` universal `load` | Out-of-scope-for-v1 | same as `+page.ts` |
| `+layout.server.ts` `load` | Implemented-by-mapping | composed D; `+layout.server.d` → dest-unique vibe.0 class (`AppLayoutServer`) |
| `+server.ts` HTTP verbs | Implemented-by-mapping | `GET`/`POST` returning `json({scalars})` or `Response("literal")` only |
| `+page.server.ts` `actions` | Implemented-by-mapping | vibe.0 `post` / `postSave` (`InboxPageServer`; `?/name` ≈ `/save`) |
| `(groups)` | Implemented-by-mapping | stripped from URL (`(app)/shop` → `/shop`; fixture + `svelte-d-kit-fs`) |
| `[slug]` | Implemented-by-mapping | `:slug` (both routers, max 64). libwasm `keepBestEntering` so `/:slug` does not steal `/admin`. `@entering` assigns `ev.parameters["id"]` onto the page field + `applyKitParams()` |
| browser back/forward | Implemented-by-mapping | JS `popstate` → `callNative('navigate_to')`; `dropActive` + re-enter so a previously shown page remounts |
| `[...rest]` | Requires-new-vibe.0-seam (named); v1 trailing `*` | `files/[...path]` → `/files/*`; name dropped |
| `[[optional]]` | Implemented-by-mapping | `kitToPatterns` omit + include (`[[lang]]` → `/docs` + `/docs/:lang`) |
| `src/params` matchers | Implemented-by-mapping (handler predicate v1) | first-class matcher = vibe.0 seam |
| rest+matcher combo | Out-of-scope-for-v1 | |
| `hooks.server` `handle` | Out-of-scope-for-v1 | non-identity body rejected; generated identity only |
| `hooks.server` `handleError` | Implemented-by-mapping | `settings.errorPageHandler` + `Hooks.handleError` (`hooks.server.d`) |
| `hooks.server` `handleFetch` | Out-of-scope-for-v1 | vibe.0 client unread; do not claim |
| `hooks.client` | Requires-new-libwasm-seam | `ready()` + router always_cb is a partial map |
| `reroute` | Out-of-scope-for-v1 | |
| `trailingSlash` | Implemented-by-mapping | `WebInterfaceSettings.ignoreTrailingSlash` / extra routes |
| `base` path | Implemented-by-mapping | `URLRouter` prefix + `libwasm.router.setBasePath` (`router.d:206`) |

## Rendering modes

| Feature | Status | Target / gap |
|---|---|---|
| CSR SPA | Implemented-by-mapping | `mixin Spa!App` + `_start` |
| SSR HTML first paint | Implemented-by-mapping | D string builders → `bodyWriter` |
| True hydration (reuse DOM) | Requires-new-libwasm-seam | v1 **replaces** `#root` |
| `export const ssr = false` | Implemented-by-mapping | skip builder; send shell |
| `export const csr = false` | Implemented-by-mapping | **omit wasm boot `<script>` on that document**; still **one** app wasm module (K17). Not a per-route wasm split. |
| `export const prerender = true` | Implemented-by-mapping | bun writes files; `adapter-static` / fileserver |
| `prerender` crawl + entries | Host-JS-only | bun crawler |
| `entries` / parameterized prerender | Implemented-by-mapping | printer + crawler |
| Streaming / `defer` | Requires-new-vibe.0-seam | chunked write exists; protocol does not |
| `load` promises in page (SvelteKit streaming) | Out-of-scope-for-v1 | |
| Incremental static regen | Out-of-scope-for-v1 | |

## Data, forms, env, app modules

| Feature | Status | Target / gap |
|---|---|---|
| cookies | Implemented-by-mapping | `req.cookies.get` / `res.setCookie` (`account/+page.server.d`) |
| `locals` | Requires-new-vibe.0-seam | v1 fiber-local map (honest gap) |
| `fetch` in `load` | Out-of-scope-for-v1 | `vibe.http.client` not line-walked; not in v1 subset |
| `depends` / `invalidate` / `invalidateAll` | Requires-new-libwasm-seam | |
| `setHeaders` | Implemented-by-mapping | `res.headers["X-Svelte-D"]` (`account/+page.server.d`) |
| `redirect` / `error` | Implemented-by-mapping | `res.redirect("/inbox")`; `enforceHTTP` still available |
| form `use:enhance` | Requires-new-libwasm-seam | native POST works without it (progressive enhancement via SSR HTML) |
| `$app/environment` | Implemented-by-mapping | `src-d/kit/app_environment.d` (`browser`/`server`/`dev`) per cell |
| `$app/paths` | Implemented-by-mapping | `src-d/kit/app_paths.d` (`base`/`assets`, empty v1) |
| `$app/navigation` | Implemented-by-mapping | wasm `kit.app_navigation.gotoUrl` → `router().navigateTo` (D `goto` is reserved). `invalidate` / `beforeNavigate` still a seam |
| `$app/state` / `page` store | Out-of-scope-for-v1 | not in v1 user-import list |
| `$app/forms` | Requires-new-libwasm-seam | |
| `$app/server` | Out-of-scope-for-v1 | not in v1 user-import list (host printer may still use `req` internally) |
| `$env/static/public` | Implemented-by-mapping | `PUBLIC_*` from `.env` both cells (`env_static_public.d`) |
| `$env/static/private` | Implemented-by-mapping | host `env_static_private.d`; wasm import is a compile graph error |
| `$env/dynamic/public` | Out-of-scope-for-v1 | not in v1 import list |
| `$env/dynamic/private` | Out-of-scope-for-v1 | not in v1 import list |
| `$lib` alias | Implemented-by-mapping | printer import paths |
| `import std.*` in `lang=d` | Implemented-by-mapping | wasm Phobos (spa-phobos); lifted to module header; `std.file`/`stdio`/`socket` rejected |
| host `import vibe.db.*` / botan / std | Implemented-by-mapping | same engine graph as `helpers.connectDB` / `connectCache`; no new package manager |
| `$service-worker` | Host-JS-only | |

## Client UI (Svelte language)

| Feature | Status | Target / gap |
|---|---|---|
| elements, text, attrs | Implemented-by-mapping | `NodeDef`, `@prop`, `@attr`; nested `@child` on the parent element |
| components / props | Implemented-by-mapping | PascalCase `<ClickField>` → `@child ClickField` + `import lib.ClickField` |
| `{@html}` | Implemented-by-mapping | `@prop!"innerHTML"` wrapper div |
| `class:` / `style:` | Implemented-by-mapping | `@style` / `@attr` |
| `on:` events | Implemented-by-mapping | `@callback` + `domEvent` |
| `bind:value` (inputs) | Implemented-by-mapping | `@prop` named after host ident; `construct` seed; `input` Slot writes host back |
| `bind:this` | Implemented-by-mapping | `Handle` field + `onMount` assign from `child.node.handle` |
| `{#if}` (v1 conds) | Implemented-by-mapping | `setVisible` / `remount` / `unmount` |
| `{:else}` on `{#if}` | Implemented-by-mapping | second `@child` + inverted `setVisible`; [svelte-language-coverage.md](svelte-language-coverage.md) |
| `onMount` | Implemented-by-mapping | `void onMount()` after `render` (`propagateOnMount`). Not a JS import. [AGENTS-D-IR-lifetime.md](AGENTS-D-IR-lifetime.md) |
| `onDestroy` | Implemented-by-mapping | `void onUnmount()` (`unmount` / `removeChild`). Child walk is a libwasm seam. |
| `{#each}` | Implemented-by-mapping | `UnorderedList` / `List`. HMR `dumpApp`/`loadApp` serializes items as `:l:N:[{item}…]` (`hmr.d`); overlay `hmr-each` is info |
| `{#key}` | Implemented-by-mapping | `remount!"child"(this)` helper when the key ident changes |
| unnamed `<slot />` | Implemented-by-mapping | `mixin Slot!("default")` + fallback child |
| `{#await}` | Implemented-by-mapping | pending/then/catch `@visible`; `wireAwait` is `.await` + `libwasmAwaitFailed()` on the fork, else `JsPromise.then`. `{:catch e}` is filled from `libwasmAwaitError()` after rewind. Do not wrap the import. ([AGENTS-D-IR-asyncify-wasm-eh.md](AGENTS-D-IR-asyncify-wasm-eh.md)) |
| snippets / named slots | Implemented-by-mapping | `{#snippet}` stored; `{@render}` walks the body as `@child` |
| `$state` (scalar / `string[]` only) | Implemented-by-mapping | v1 subset → struct field + `update` |
| `$derived` | Implemented-by-mapping | peel `$derived(expr)` to `expr` (no rune runner) |
| `$effect` | Implemented-by-mapping | body merged into `void onMount()` |
| `$props` | Out-of-scope-for-v1 | parent assigns `@child` fields; `$props()` stripped |
| stores (Svelte 4) | Out-of-scope-for-v1 | use fields |
| transitions / animations | Implemented-by-mapping | `transition:` / `in:` / `out:` / `animate:` → `@style!"name"` |
| actions `use:` | Implemented-by-mapping | `onMount` `action(Handle)` — no action lifecycle beyond that |
| context API | Requires-new-libwasm-seam | or parent pointer convention |
| `<svelte:head>` | Implemented-by-mapping | `document()` + `document().title` from `<title>` kids |
| `<svelte:window>` / `document` / `body` | Implemented-by-mapping | `window()` / `document()` (handles `{2,1}`) + `on:` modifiers |
| `<svelte:element>` / dynamic | Implemented-by-mapping | static `this="tag"` → `NodeDef!"tag"`; dynamic `this={tag}` → `data_tag` + `createElement(string)` / `applyTag` replace |
| special elements `svelte:self` | Out-of-scope-for-v1 | CTFE recursion risk |

## App shell, adapters, PWA, misc

| Feature | Status | Target / gap |
|---|---|---|
| `app.html` | Implemented-by-mapping | SSR skeleton + CSR shell |
| `error.html` | Implemented-by-mapping | static file / `errorPageHandler` |
| `hooks.server` CSRF origin | Implemented-by-mapping | **generated** check (vibe.0 has none) |
| CSP | Out-of-scope-for-v1 | |
| `adapter-node` (JS) | Out-of-scope-for-v1 | would be Svelte-to-JS |
| `adapter-static` | Implemented-by-mapping | `adaptWorkspace({adapter:'static'})` copies `public/` + `index.html` + optional `dist/` / prerender; fileserver of `out/` |
| `adapter-libwasm-spa` | Implemented-by-mapping | same CSR shell, no prerender, no host exe |
| `adapter-vibe0` / `vibe0-proxy` | Implemented-by-mapping | `adapter-vibe0` = exe + `public/` + certs; `vibe0-proxy` = current `reverseProxyRequest` to `:5173` |
| service worker | Host-JS-only | generated JS |
| `version` / `updated` store | Implemented-by-mapping | manifest hash |
| `preload` / `data-sveltekit-preload-data` | Requires-new-libwasm-seam | |
| `data-sveltekit-reload` etc. | Requires-new-libwasm-seam | |
| `snapshot` (scroll/focus) | Out-of-scope-for-v1 | dumpApp is not this |
| `onNavigate` / `beforeNavigate` / `afterNavigate` | Requires-new-libwasm-seam | |
| `goto` / `pushState` / `replaceState` | Requires-new-libwasm-seam | `navigateTo` + History bindings exist |
| i18n routing | Out-of-scope-for-v1 | |
| `instrumentation` | Out-of-scope-for-v1 | |
| remote functions (SvelteKit experimental) | Out-of-scope-for-v1 | |
| Capacitor / mobile wrap | Out-of-scope-for-v1 | consume SPA adapter output |
| Vite-only TS apps (no D) | Out-of-scope-for-v1 | not the product |

## Did not close

Whether handler-side matchers count as Implemented-by-mapping (this table says yes) or should be marked a seam — pick one when the first matcher fixture lands. Universal `load` is **closed**: rejected in v1.
