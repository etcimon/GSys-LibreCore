# Admin panel + Puppeteer D-IR debug platform

The next change that adds an “admin UI”, “Chrome debug”, or “source maps” starts
here. It does **not** replace [hmr-debug.md](hmr-debug.md). That note still owns
`dumpApp`/`loadApp`, the HMR websocket, and the ban on shipping
`generateSourceMap.py`. This note is the **incremental program**: a real
SvelteKit admin tree printed onto the existing libwasm D IR, plus a bun
Puppeteer/CDP harness that rewrites DOM / TS / wasm console errors **through**
that IR back to the `.svelte` that produced it.

## Thesis

The D IR is the correctness surface. A proper implementation means the printed
struct (`NodeDef` / `@child` / `@prop` / `@visible` / `UnorderedList`) **is**
the app. Debug does not invent a second Svelte runtime, a second DOM, or a
JS-compiled `.svelte`. It records a **trace**:

```
.svelte / +page.server.d  →  printed .d:line  →  (later) wasm func / JS frame
```

If the IR is wrong, the admin panel is wrong and the rewrite is a lie. If the
IR is right, a Chrome stack that names `src-d/routes/admin/users/page.d:42`
must name `src-svelte/routes/admin/users/+page.svelte:<line>` in the same
report. Puppeteer is a **test platform** that consumes that map. It is not a
third cell.

Guiding principles stay: kit syntax falls through into `svelte-engine-ws`;
features are accommodated in svelte-engine / libwasm / vibe.0; one `Spa!App`;
two LDC cells; no `svelte/compiler`.

## Incremental kit tree (the admin panel)

Build the admin tree in the **bun project** (`packages/svelte-d-kit-admin/src/routes/admin/`),
not in svelte-engine. `drop-ws` copies the **packaged** engine
(`svelte-d/templates/engine`); `compile --project` overlays this `src/` onto
the workspace. I1 adds `users/[id]`, `features`, and `+error`. Each increment
adds routes that **already print**. Do not wait for a new libwasm widget.

| Inc | Files | What it proves |
|---|---|---|
| **I0** | `+layout.svelte`, `+page.svelte` (dashboard), `users/+page.svelte`, `logs/+page.svelte`, host trio | Nested kit admin compiles; Slot layout; dashboard `{#if}`+`<Panel>`; users `{#each}`; logs `{#if}`+each; dest-unique host classes; vibe.0 **PostgreSQL + Redis + JSON** |
| **I1** | `users/[id]/+page.svelte` + cookies/`$app`; `features/+page.svelte`; `+error.svelte` | Param `/admin/users/:id`; host cookies; features stack; error not a router entry |
| **I1b** | `src/lib/AdminDash.svelte` hung on `Spa!App`; live Vite+Chrome/Firefox | DevTools fetch `/__svelte-d/debug-map.json`; `__svelteDRewrite` maps AdminDash + `/admin` dests onto `.svelte`; `console.info('svelte-d-probe', …)` in Chrome/Firefox; no `ABORT:`; wasm copied after drop; `--force` drop keeps `node_modules`; `{#if}` around `{#each}` now `@visible`s the list |
| **I2** | overlay page + `/__svelte-d/overlay` | Compile writes `overlay.json` + `overlay.html` + `overlay/index.html`; LDC `file.d(line,col)` and `file.d:line` rewrite to orig `.svelte`; Vite middleware serves `/__svelte-d/overlay` (SPA fallback does not steal it); Chrome opens the page |
| **I3** | IR inspector (read-only) | Compile writes `ir.json` + `ir.html`; lists dest/orig/kind from `debug-map.json`; filter box; no `compile!` / wasm; Chrome opens `/__svelte-d/ir.html` |
| **I4** | wasm name section | Parse custom `name` section; join `lib.AdminDash.construct` / `_D3lib9AdminDash…` onto dests; `wasm://` frames rewrite only when dest is known; no DWARF; `_start` stays unmapped |
| **G63** | live `/admin` remount | URLRouter one best `@entering` (static beats `:param`); `{#each}` index is `int i` not `@prop!"dataset"`; `setProperty` skips getter-only; wasm-eh exports `jsCallback`; `callNative('navigate_to')` `/admin` → `/admin/users` keeps `.admin-layout` |
| **G68** (this pass) | history popstate remount | `dropActive` on leave; re-fire `@entering` on a previously visited route; JS `popstate` → `callNative('navigate_to')` (no test-side native); live back `/admin/logs` → `/admin/features` and `/admin/users/42` |
| **G125 / G126** | AdminBridge / AdminPeer / `admin-mini` | Dual-script `src/lib/AdminBridge.svelte` + `AdminPeer.svelte` + `admin-fmt.ts`; features page mounts both; `package.json` `admin-mini` `1.0.0` copies into dest `node_modules`; `admin.test.ts` asserts `callTs` / `exportDelegate` / dest range. See [cross-calling.md](cross-calling.md). |

`assembleAppChildren` is still `src-d/lib/` only. **T5** hangs one `@child KitRoutes`
on `App`. **G53** projects covered pages as `@child` of the matching layout
(`assembleSlotPages`); `@entering` `setVisible`s the page *on the layout* and
hides `slot_default`. Orphan pages (no layout) stay on `KitRoutes`. No second `Spa!`.

## SvelteKit host data — vibe.0 PostgreSQL / Redis / JSON

Kit `+page.server.d` / `+server.d` are the **host cell**. They must not import
libwasm. Persistence and JSON fall through to idioms **already** in
`svelte-engine/webserver` (not a new SQL stack, not Prisma-in-D, not wasm
PgLite on the host):

| Kit idea | vibe.0 / engine idiom | Locus |
|---|---|---|
| `load` / GET JSON | `vibe.data.json.Json` + `serializeToJson` / `serializeToJsonString` + `res.writeBody(..., "application/json")` | `vibe.0/source/vibe/data/json.d:1248`; engine `api.d:42` |
| session / cache | `connectCache()` → `RedisDatabase` `set` / `get` / `mget` | `helpers.d:69-83`; `app.d` already uses `RedisSessionStore` |
| durable rows | `connectDB()` → `PostgresDB.lockConnection` + `scoped!PGCommand` | `helpers.d:32-67`; `api.d` SELECT/UPDATE |
| cookie session | `RedisSessionStore` on `HTTPServerSettings` | `app.d:90` |

**Wasm stays PgLite** (`src-d/pglite.d`). Postgres and Redis are host-only.
`$env/static/private` may hold connection overrides later; I0 uses the golden
`helpers.connectDB` / `connectCache` params.

I0 admin host methods **call** these APIs and wrap live failures:

```
try { auto redis = connectCache(); redis.set("admin:ping", "1"); }
catch (Exception) { payload["redis"] = "skip"; }
try { auto pg = connectDB(); scoped!PGCommand(pg, "SELECT 1"); }
catch (Exception) { payload["postgres"] = "skip"; }
res.writeBody(payload.serializeToJsonString(), "application/json");
```

Compile + libdparse + host **link** prove the IR. Tests assert the *printed*
`connectDB` / `connectCache` / `serializeToJsonString` calls. A live
`localhost:5432` / `:6379` is **optional**; `"skip"` is the honest offline
result. Do not fail `bun test` because Postgres/Redis are down.

**G71 soak:** `GET /__svelte-d/host/soak?n=16` (`AdminPageServer.getSoak`) runs N
Redis `SETEX`/`GET` and N Postgres `SELECT 1` through `helpers.connectCache` /
`connectDB`. `bun test` `soak.test.ts` starts vibe.0 `:8180` (TLS certs copied
from the engine, reject unauthorized). Redis hits are required when `:6379`
answers. Postgres uses `PGPASSWORD` from the environment or a gitignored
`.env` (`packages/svelte-d-kit-admin/.env`, see `.env.example`) plus
`PGSSL=disable` + `slideshow3dai` (created if missing); `"skip"` only when
`:5432` is down. Connection overrides:
`PGHOST`/`PGDATABASE`/`PGUSER`/`PGPASSWORD`/`PGSSL`/`REDIS_HOST` (engine
`helpers.d`). Do not commit passwords. Do not add a second SQL library. Do not run Prisma from the D host
(`webserver/prisma` stays JS seed tooling).

## Debug map (construction)

Printer emits, in the generated `.d` only (comments; they do not change
`compile!` behaviour):

```
//# svelte-d-ir orig=<src-svelte rel>:<line> kind=<file|if|each|await|component|slot|callback> name=<ident>
```

`kind=file` is once per dest. Other kinds sit on the IR node they describe.
Line is the 1-based line of a distinctive needle in the **original** `.svelte`
(`{#if show`, `<Panel`, `{#each users`). Compile walks printed `src-d/**/*.d`
and writes `ws/.svelte-d/debug-map.json`:

```
{"schema":"svelte-d-debug-map/v1",
 "principle":"D-IR-is-correctness-surface; map-is-trace-only",
 "entries":[{"dest":"src-d/routes/admin/page.d","destLine":18,
             "orig":"src-svelte/routes/admin/+page.svelte","origLine":14,
             "kind":"if","name":"show"}]}
```

`loadDebugMap` / `rewriteStack` / `rewriteConsole` live in `svelte-d` (TS).
A frame that mentions a dest file + line maps to the closest `destLine <= line`.
Unmapped frames stay verbatim. A rewrite that cannot find an orig must not
invent one.

**Correctness rule:** the map is derived from the printed IR. If a comment
and the IR disagree, the IR wins and the comment is a printer bug. Do not
hand-edit `debug-map.json`.

## Console in the bun prompt (Chrome, Firefox, vibe.0)

`bun src/cli.ts dev` (or `bun run dev`) in `svelte-d-kit-admin`:

1. Drops the **packaged** engine, ingests this package `src/`, compiles.
2. Starts Vite; optionally the vibe.0 host.
3. Attaches **Chrome** (Puppeteer) and **Firefox** (Playwright) when present.
4. Prints every browser `console.*` / `pageerror` and every host log line to
   **this** bun command prompt, rewritten through `debug-map.json`.

Host logging is vibe.0 `vibe.core.log` (`logTrace` / `logDebug` / `logInfo` /
`logWarn` / `logError`), not `writeln`. `helpers.kitLog("info", msg)` maps
SvelteKit-shaped names onto those functions. `app.d` sets
`FileLogger.Format.threadTime` and `LogLevel.trace` in debug builds so
`INF`/`WRN`/`ERR`/`dbg`/`trc` prefixes appear. The bun bridge colorizes those
prefixes (red error, yellow warn, green info, cyan debug/trace) unless
`NO_COLOR` is set.

## Puppeteer / Chrome debug platform (I0 subset)

Package `packages/svelte-d-kit-admin` is a bun + ts + svelte-d **consumer**.
It imports `svelte-d` and (optionally) `puppeteer`. The platform is TS:

| CDP / Puppeteer surface | I0 | Later |
|---|---|---|
| `page.on('console')` | yes — rewrite args through the map | |
| `page.on('pageerror')` | yes — rewrite `error.stack` | |
| `page.on('error')` worker crash | collect + rewrite | |
| CDP `exceptionThrown` + `ABORT` after remount/filter | **G73** — `devtools-sink` on live kit nav/popstate + overlay/IR inspector | |
| `page.evaluate` / `waitForSelector` | yes — admin compile tests do not need Chrome; CDP tests use `about:blank` first | **I2** hits Vite `/` and `/__svelte-d/overlay/` |
| screenshot / pdf | later | I2 |
| coverage / tracing / `Page.captureScreenshot` | later | I3 |
| `Network.*` / request intercept | later | I3 |
| `Debugger.paused` / wasm DWARF | name section only (I4); LDC DI is cell-aware and not v1 | |
| `Runtime.consoleAPICalled` stack | **G47** Puppeteer CDP `rewriteCdpStack` (0-based) | |
| `Runtime.exceptionThrown` | **G47** rewritten + wasm `ABORT:` via `__svelteDFormatAbort` | |
| page `debug-bridge.ts` | **G47** wraps console; fetches `/__svelte-d/debug-map.json` | |
| `Log.entryAdded` | later | I3 |

I0 does **not** require a live wasm `_start` to prove the rewriter. Unit tests
feed synthetic stacks. A CDP smoke launches headless Chrome only when
Puppeteer can resolve a browser; otherwise the test skips. Never fail the
package green because Chromium is absent.

Uncaught wasm-eh still goes through `error-handling.ts`
(`onAssertErrorMsg` / `captureException` / `WebAssembly.Exception`). The
rewriter treats those messages as frames when they name a `.d` file.

## What this is not

- Not a Svelte-to-JS admin. Official Svelte is the **source**; libwasm is the
  **sink**.
- Not a replacement for vibe.0 `mixin(Trace)` / `vibe.http.debugger`. Host
  stacks stay host. I2 may *display* them next to the wasm rewrite.
- Not DWARF in I0. Full wasm source maps wait for a titled LDC/libwasm seam
  ([hmr-debug.md](hmr-debug.md) “best effort after Phase 8”).
- Not a second overlay framework. `/__svelte-d/overlay` is I2, written into
  `public/__svelte-d/` and served by Vite (same prefix as `debug-map.json`).

## Loci

`packages/svelte-d/source/svelte_d/print/dom_print.d` — origin comments  
`packages/svelte-d/source/svelte_d/print/debug_map.d` — collect + write  
`packages/svelte-d/source/svelte_d/print/overlay.d` — overlay.json + overlay page  
`packages/svelte-d/source/svelte_d/print/inspector.d` — ir.json + read-only inspector page  
`packages/svelte-d/ts/debug.ts` — `loadDebugMap` / `rewriteStack` / `loadOverlay` / `loadInspector` / `destFromWasmName`  
`packages/svelte-d/ts/wasm_names.ts` — name-section parse + `writeWasmNameMap`  
`packages/svelte-d-kit-admin/` — consumer + Puppeteer platform  
`packages/svelte-d-kit-admin/src/lib/{AdminBridge,AdminPeer,admin-fmt.ts}` — G125/G126 fixtures  
`packages/svelte-d-kit-admin/node_modules/admin-mini/` — local npm fall-through  
`svelte-engine/src-svelte/routes/admin/` — kit fixtures  
`src-ts/modules/error-handling.ts` — wasm abort / Exception  
`architecture/hmr-debug.md` — HMR + overlay + no `generateSourceMap.py`

## Invariants

- D IR remains the only executable client graph. (construction)
- Origin comments are D comments; they must not change `compile!` walk. (construction)
- `debug-map.json` is derived, never authorial. (construction)
- `rewriteStack` must not invent an orig path. (convention of honesty)
- Puppeteer is a test dependency of `svelte-d-kit-admin`, not of `svelte-d`. (convention)
- Two cells stay two cells; Chrome talks to the **served** ws, never to the template. (construction)
- Do not parse production with npm `svelte/compiler`. (construction)

## Extension points

Forward `TaskDebugger` breadcrumbs into the same rewrite report.

## Did not close

Whether dest-line matching should prefer exact `kind=callback` over the
nearest comment. Whether Chrome’s wasm function *index* (not the name
section string) can be joined without DWARF. Whether the admin panel later
becomes a product surface or stays a fixture.
