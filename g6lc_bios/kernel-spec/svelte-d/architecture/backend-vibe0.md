# Backend — mapping SvelteKit server features onto vibe.0

The next change that emits server D should open vibe.0’s request journey and then emit **idiomatic vibe.0**. Diet is not there. `vibe.web.rest` is not there. A second HTTP stack is not allowed.

Consumer shape is construction: `VibeCustomMain`, your own `main()`, `listenHTTP`, `runEventLoop()`. Default `appmain.d:28` static-asserts otherwise. `vibe.core.core` starts the only backend, `LibasyncDriver`. `listenHTTP` (`http/server.d:77`) may run on one thread (`g_ctor`). One fiber per TCP connection owns HTTP/1.1 keep-alive or an HTTP/2 session (libhttp2: ALPN `h2`, preface, h2c). Dispatch is `context.requestHandler` → `URLRouter.handleRequest`. `registerWebInterface` (`web/web.d:115`) turns public methods + `@path` `@method` `@before` `@after` into `router.match` entries. `vibeVersionString` is still `"0.7.23"`; the git tag is `v1.2.1`. Do not conflate them. Green is **unverified** on this host (absolute `libs-windows-*` in `dub.json:25-26`, undeclared memutils, Botan/OpenSSL not re-probed).

SvelteKit `+page.server.d` prints as `generated.routes.page_server` / `class PageServer` and is `registerWebInterface`'d under `/__svelte-d/host/` (Vite keeps `/`). `svelte-d host` is `dub build` in `ws/webserver` (host LDC 1.42). SvelteKit `load` becomes a generated `URLRouter.get` that runs D `load` and then either writes SSR HTML or JSON. `actions` become `post` (and `post` + `?/name`). `+server.ts` verbs become `router.match(HTTPMethod.*, …)` or a small `registerWebInterface` class. Layout `load` is **composed in generated D** — vibe.0 has no layout primitive. `hooks.server` `handle` is `router.any("*", …)` registered **before** page routes, or `@before`. `handleError` is `HTTPServerSettings.errorPageHandler`. Cookies are `req.cookies` / `res.setCookie`. Sessions are `settings.sessionStore` (slideshow3dai uses `RedisSessionStore` at `webserver/source/app.d:84`). `redirect` / `error` are `res.redirect` / `enforceHTTP`. Streaming is chunked `bodyWriter` / HTTP/2 DATA — there is no SvelteKit `defer` protocol yet.

Host `+page.server.d` imports third-party packages **the same way as PG/Redis**: they are already on the engine `webserver/dub.sdl` graph (`vibe-0`, `botan`, `memutils`). `import helpers;` public-imports `vibe.db.pgsql.pgsql`, `vibe.db.redis.redis`, `vibe.data.json`, `botan.passhash.bcrypt`, `std.conv`, `std.datetime`, … Authors may also write those `import` lines directly; the printer lifts them to the generated module header (outside the `registerWebInterface` class). Do not fetch a new D package from the bun project — add it to the engine host `dub.sdl`, then import. `import libwasm` on the host is rejected.

`URLRouter` match language (`http/router.d:157-174`): literals, `:name` (one segment), trailing `*`, max 64 placeholders, a character between placeholders. SvelteKit `[id]` → `:id`. Groups `(app)` strip. `[[optional]]` expands to two registrations. `[...rest]` → trailing `*` and **loses the name** (Requires-new-vibe.0-seam for named rest; v1 can pass the leftover path as a generated local). Matchers `[id=uuid]` are handler-side predicates in v1. Duplicate placeholder names must be renamed by the compiler.

**SSR HTML decision:** generated D string builders writing to `HTTPServerResponse.bodyWriter`, filling `app.html` placeholders. Not Diet-in-vibe.0 (deleted). Not diet-wasm on the host cell (wrong package graph, breaks the two-compiler invariant). Not “run libwasm structs on the server” (they call JS `createElement` imports — that would be a second DOM). v1 hydration is **replace**: wasm `_start` renders into `#root` as today. Attaching handles to existing DOM is a libwasm seam. Diet files in `src-d-views/*.dt` stay wasm-cell `stringImportPaths` only (`slideshow3dai/src-d-views/home.dt` is an Onsen stub, not the SSR engine).

`locals` is not `req.params`. v1 may use a fiber-local / `Task`-keyed map. A real `HTTPServerRequest.locals` field is Requires-new-vibe.0-seam and must not be smuggled in as a “drive-by” on a svelte-D PR. CSRF: vibe.0 has none (slideshow3dai comments only); the printer generates an origin check on actions. `$env/static/private` and `$app/server` are host-cell only; the IR graph check is a compile error if they leak into wasm.

Adapters are bun packages that consume `manifest.json`: `adapter-vibe0`, `adapter-vibe0-proxy` (slideshow3dai `reverseProxyRequest` to `:5173`, `app.d:56-63`), `adapter-static`, `adapter-libwasm-spa`. Implementation: `packages/svelte-d/ts/adapter.ts` `adaptWorkspace` writes `out/adapter.json` (`svelte-d-adapter/v1`) and copies artifacts only. `adapter-static` flattens `public/` (and `dist/` / `.svelte-d/prerender/` when present). `adapter-libwasm-spa` is the same CSR shell without prerender. `adapter-vibe0` copies the host exe + `public/` + `certs/`. `adapter-vibe0-proxy` is the current engine host (proxy to Vite `:5173`). None of them rewrite `app.d` or add a Node HTTP stack. Node/Cloudflare JS-SSR adapters are out of scope (they reintroduce Svelte-to-JS).

## Loci

`appmain.d:24-40` — custom main / dead default  
`http/server.d:77-168` — listen + `listenTCP`  
`http/router.d:144-174` — match language  
`web/web.d:115-183` — `registerWebInterface`  
`http/debugger.d` — `setupDebugger`, allocations, tasks  
`core/trace.d:1-49` — `Name` / `Breadcrumb` / `TaskDebugger`  
`dub.json:15-27` — deps + **absolute** Windows libs  
`LICENSE.txt` — MIT + Boost/BSD file exceptions  
`vibe.0/architecture/{overview,http,open-questions}.md`  
`slideshow3dai/webserver/dub.sdl` — `VibeCustomMain` and a mix of versions including `DisableDebugger` which **is not matched** in `source/`  
`slideshow3dai/webserver/source/app.d:30-149`  
`packages/svelte-d/ts/adapter.ts` — `adaptWorkspace`  
`packages/adapter-{static,libwasm-spa,vibe0,vibe0-proxy}/` — bun packages

## Invariants

- Generated server always sets `VibeCustomMain` and calls `runEventLoop()`. (construction)
- Do not restore `VibeDefaultMain` / `appmain.main`. (construction of this fork)
- Do not add a second event backend. (construction — `getEventDriver()` is `LibasyncDriver`)
- Do not import libwasm or diet-wasm from server modules. (construction of the cell split)
- Do not rewrite vibe.0 `libs-windows-*` from a svelte-D pass. (convention of vibe.0 packaging; interface change)
- Do not claim the host cell is green without a log on this host. (convention of vibe.0 notes)
- `Server` header stays whatever vibe.0 emits unless the *app* sets `serverString` (slideshow3dai sets `"3D AI Slideshow"`). Changing `vibeVersionString` is a vibe.0 identity change. (convention)

## Extension points

New SvelteKit server feature → printer arm against `URLRouter` / `registerWebInterface` / `errorPageHandler`, or a named vibe.0 seam with its own green cell. New adapter → reads manifest, copies artifacts, does not add a Node HTTP framework.

## Did not close

Fiber-local `locals` vs a vibe.0 field. Whether Phase 4 link tests wait for a POSIX runner. Whether generated apps should set `serverString` to `svelte-d` (fingerprint). `handleFetch` / `fetch` in `load` are **out of v1** (client unread). WebSocket over HTTP/2 unverified. `useCompressionIfPossible` defaults true with a “known issues with GZIP” comment in settings.
