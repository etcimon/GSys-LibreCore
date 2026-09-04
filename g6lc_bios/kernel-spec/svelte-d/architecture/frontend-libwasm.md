# Frontend — mapping SvelteKit client features onto libwasm

The next change that emits client D or copies JS glue should open the libwasm files cited here and then emit **idiomatic libwasm**, not a new component runtime.

libwasm is a CTFE SPA: `mixin Spa!App` injects `_start` (`spa.d:104-146`) which `alloc_init`s from `__heap_base`, `PoolStack.initialize`s, `getRoot()`s, injects `GetCss!(Application, Theme)` (`css.d:689`), `application.compile()`s, `setupRouter()` + `registerRoutes()`, and `libwasm.dom.render`s. Components are structs with `mixin NodeDef!"tag"` (`node.d:119-125`), `@child` fields discovered by `getChildren` (`node.d:5-18`), `@prop` / `@attr` / `@style` / `@callback`, `mixin Slot!` + `@connect` (see `navbar.d:58` and `dom.d:1080`), and lists via `List!(T,tag)` / `UnorderedList` (`array.d:202-211`). JS holds DOM in a handle table starting `{1: document, 2: window}` (`slideshow3dai/src-ts/modules/libwasm.ts:19`). D stores `Handle`. Events cross as `domEvent(ctx, fun, handle)` (`event.d:14-38`). There is no GC; `-fno-moduleinfo` is required; stock LDC `-Iimport` must not win.

Browser-facing **logic** (fetch, arrays of JS values, dates, `window.*`) is **not** extra TS. It is libwasm D: `libwasm.bindings.*`, `Lodash` chains + `execute!T()`, `moment()`, or a PgLite-style `Eval("window.X")` wrapper. See [libwasm-js.md](libwasm-js.md). The printer keeps those calls when the script is already D; it rewrites only Svelte leftovers into that syntax.

The client printer’s job is to lower IR `Component`/`Page`/`Layout`/`Template` nodes into that idiom — **only** constructs on the canonical **v1 source subset**. Svelte markup elements become `mixin NodeDef!"tag"` → `NamedNode` → `TagHtmlElementMap` (typed `HTMLButtonElement`, …). Child components become `@child`. Text and attribute interpolations become `@prop!"name"`/`@attr` on the struct that owns the NamedNode. Author `this.update.msg` is rewritten to `msgSpan.update.msg` (golden `heading.update.innerText`); `{#if}` to `setVisible`. Named `on:click={handler}` becomes child `Slot` + `@callback!"click"` + parent `@connect!"child.click"`. Empty `Slot!"click"` is `EventEmitter!()` — libwasm `add` **appends** (`~=`); assigning a delegate into `Vector` does not compile. `{#each}` becomes `UnorderedList!T` (`HTMLArray` + `ArrayItemEvents` + `assignEventListeners`) and list `@connect!("list.items","slot")` with a `size_t` first parameter. List-item parent pointers are `@inject!"host"` set in the item ctor (`compile!` does not walk appenders). Full UDA / path / attach-detach map: [udas.md](udas.md). `{#if ident}` becomes `@visible!"child"` on `bool ident` plus `setVisible` / `remount` / `unmount` (`dom.d:1318`) — not a second struct type. `{:else}` is skipped in v1. `<style>` becomes `@styleset` / `GetCss` or `addCss`. Instance `let`/`const`/`$state` **scalars** become struct fields. Svelte `onMount` / `onDestroy` map to libwasm `void onMount()` / `void onUnmount()` ([AGENTS-D-IR-lifetime.md](AGENTS-D-IR-lifetime.md)) — not JS imports. **Rejected in v1 (not mappings):** `$derived`, `$effect`, `$props`, `{#await}`, `{#key}`, `<svelte:head>` / `window` / `document` / `body`. The root remains `mixin Spa!App` (slideshow3dai `app.d:11`). Printed structs hang as `@child` of that App. **One wasm module per app**; `csr = false` omits the boot script on that document only.

`libwasm.router` (`router.d`) is experimental: `:name`, `*`, `maxRouteParameters = 64` (`router.d:44`), entering/leaving/always callbacks returning `Optional!(Promise!void)`, popstate + `exportDelegate("navigate_to")` (`router.d:237`). Engine `debug-bridge.ts` + `libwasm.ts` listen for `popstate` and call `callNative('navigate_to', location.pathname)` (wasm-eh `onpopstate` UDA is not reliable). `navigateTo` does not `pushState` when the browser path already matches. Leaving **drops** the route from `m_activeRoutes`; a later visit (back/forward) still fires `@entering` even if the route was seen before, so kit `setVisible` + `applyKitParams` re-run. It is **not** SvelteKit. The printer may emit patterns it can express (`/foo/:id`, trailing `*`). Layouts are **not** router entries — they stay mounted as `@child` wrappers; the page is swapped in the entering callback. `goto` / `invalidate` / `beforeNavigate` / prefetch / true hydration (attach handles to existing SSR DOM) are **Requires-new-libwasm-seam**. Until those exist, do not print APIs that call them.

JS glue is copied from slideshow3dai / libwasm `examples/dom-ts` (`libwasm.ts`, `asyncify.ts`, `spa.ts`, `bindings.ts`, `error-handling.ts`), parameterized from the manifest (today `libwasm.ts:113` hard-codes `slideshow3dai.wasm`). Engine `libwasm.ts` also plants `window.__svelteD` (`ensureSvelteD`) so `lang=ts` exports and `exportDelegate` share one registry ([cross-calling.md](cross-calling.md)). Google’s `asyncify.ts` is Apache-2.0 — keep the header. `DATA_END = 1048576` (`asyncify.ts:36`) must match `ldc2.conf` stack. New `extern(C)` imports must be appended to `wasm-opt --asyncify-imports` (construction).

**Do not emit:** vibe.0 imports, Phobos I/O over JS handles (use `Lodash`), `new Date` (use `moment`), a virtual DOM, GC classes as the primary component model, or raw `extern(C)` JS. **Do emit** author `import std.algorithm` / `std.conv` / `std.range` (spa-phobos cell) at **module** scope — not inside the `nothrow` struct, not `std.file` / `std.stdio` / `std.socket`. slideshow3dai / svelte-engine use `ManagedPool(64 * 1024)` in `App.construct` — pools, not `new` trees. Language `new` bumps `WasmAllocator` and is never recycled. A live `ScopedPool` takes `alloc` / `_d_allocmemory` / `allocString`. Heavy printed methods wrap that pool and copy survivors onto the NodeDef graph. See [AGENTS-D-IR-memory-management.md](AGENTS-D-IR-memory-management.md).

Size baselines to beat without a note: libwasm README, dom-ts ≈ 49 kb gzip wasm + 30 kb gzip JS; spasm todo-mvc ≈ 5.8 kb + 2.2 kb gzip.

## Loci

`spa.d:5-7` static-assert 2106/2112/2113  
`spa.d:104-166` mixin Spa / HMR exports  
`node.d:119-125` NodeDef  
`hmr.d` dump/load; `List`/`HTMLArray` as `:l:N:[{item}…]`; still skips pointers / EventEmitter / NamedNode / ManagedPool / enums  
`router.d:44,61-105,162-247` matcher + URLRouter class  
`package.d:1-29` barrel including `diet.html`  
`dub.sdl:18-37` — **drift:** default `"library"` is 1.43 (`:20-27` exports); `"ldc-1.36"` is `:30-37`. Do not cite `:26-27` as the 1.36 export list.  
libwasm live HEAD `64a97ce` / `v0.10.0` (2026-08-14); `AGENTS.md` pin `02f21a6` lags; `architecture/overview.md` still says “Exactly LDC 1.36.0”.  
`event.d:14-38` `domEvent`  
`css.d:689` `GetCss`  
`slideshow3dai/src-d/navbar.d` — `@child`, `@callback`, `@connect`, `UnorderedList`, `Slot`  
`slideshow3dai/src-ts/modules/spa.ts:31-572` `jsExports.env`  
`svelte-engine/src-ts/modules/libwasm.ts:39-76` `ensureSvelteD` / `registerTs` / `registerD` / `callNative` returns `reg.ret`  
`libwasm/architecture/{overview,flags,js-events-memory,ctfe-apps}.md`  
[AGENTS-D-IR-memory-management.md](AGENTS-D-IR-memory-management.md) — `ScopedPool` / `rt/memory.d` fall-through

## Invariants

- Emitted client D compiles in the selected wasm cell with `-fno-moduleinfo` and without stock `-Iimport`. (construction)
- Export list includes `_start`, `domEvent`, `allocString`, `dumpApp`, `loadApp`, `__heap_base` when HMR is on (`dub.sdl:36-37` on **ldc-1.36**; `:26-27` is the 1.43 `library` config). (construction)
- Generated client `dub.sdl` must emit `subConfiguration "libwasm" "ldc-1.36"` (and helper sub-configs) when `wasmCell=ldc-1.36`. Do not copy slideshow3dai `application`. (construction)
- Official Binaryen 123/132 must not `--asyncify` a `try_table` module (Flatten.cpp UNREACHABLE). The etcimon fork (`binaryen/`, `binaryen-build/`) does, then `-Oz`. Stock post-link stays `-Oz` / `-g -O0` with `--enable-exception-handling`. (construction)
- Print `{#await}` as `wireAwait`: `.await` + `libwasmAwaitFailed()` when `asyncify_get_state` is present, else `JsPromise.then`. Fill `{:catch e}` from `libwasmAwaitError()` and `{:then v}` from `libwasmAwaitValue()` after rewind. Do not wrap `.await` in `try`. `throwBoundary` stays a same-function landing pad off the import. ([AGENTS-D-IR-asyncify-wasm-eh.md](AGENTS-D-IR-asyncify-wasm-eh.md))
- Do not invent a second handle table or a second `domEvent`. (construction of the ABI)
- One generated file per component is convention (matches slideshow3dai). (convention)

## Extension points

New DOM/Web API: generate or hand-write under `libwasm/bindings/` *in that tree* (webidl), then emit the D call. New JS library: Lodash wrap like `pglite.d` + `window.X` in TS glue, **or** a `lang=ts` export reached by `callTs` ([cross-calling.md](cross-calling.md)). New Svelte syntax: lowerer arm or a hard diagnostic — never a JS fallback in the wasm module.

## Did not close

v1 subset is now specified in the canonical design (reject-by-default). Whether `{#if}` `{:else}` should be a second `@child` with inverted `@visible` (v1: else skipped). Whether `navbar.d`’s `Exception` + PgLite JSON survives `--wasm-enable-eh` on 1.36 (slideshow3dai overview: untested).
