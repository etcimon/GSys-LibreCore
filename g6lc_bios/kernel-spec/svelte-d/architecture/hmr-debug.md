# HMR and debugging

The next change that “improves reload” or “adds source maps” should preserve dumpApp/loadApp and should not ship `generateSourceMap.py` as-is.

Hot reload of a libwasm app is already a product: `version(hmr)` exports `dumpApp` / `loadApp` (`spa.d:148-165`) which serialize/deserialize the application struct tree (`hmr.d`). The JS client (`spa.ts:574-626`) on WS message `reload` calls `dumpApp`, tears down handle-table entries `> 2`, recreates `#root`, re-imports glue, `init`s, and `loadApp`s. `full-reload` is `location.reload()`. The socket today is `ws://localhost:3001` (`spa.ts:605`), owned by the Vite plugin (`vite.config.js:40`). `notifyClients` must invoke the notify loop even when `building` is false (engine seam, T8/G22). svelte-d writes `public/__svelte-d/hmr-tick` after an incremental compile (`reload` when wasm dests changed, `full-reload` for glue). The engine Vite plugin watches that file and forwards the opcode so HMR pipes through svelte-d → engine, not a second socket. Outstanding `setTimeout` and other scheduled work is **not** cancelled (`spa.ts:578-580`).

The serializer walks `tupleof` and writes booleans, strings, integrals, nested aggregates, and **`List` / `HTMLArray` items** as `:l:N:[{item}…]` (`hmr.d` dump/load). It still **skips** pointers, `EventEmitter`, `NamedNode`, `ManagedPool`, and enums. After wasm reload, `_start` re-runs `construct()` (seed items); `loadApp` then shrinks/puts so the dumped count and item fields win. New items are `ThreadMem` + `Item.init` then `List.put` (renders) or `HTMLArray.put`. Overlay emits `status=hmr-each` (`info`) when the debug map has `kind=each`. Old dumps without `:l:` still load (lists stay at `construct()` seeds). New dumps need this `loadApp` — `skipField` understands `l` so an unmatched list field does not abort the rest of the object.

svelte-D’s job is to **own the websocket** (default port `3579`, override `3001` for slideshow3dai compat), keep the string opcodes `reload` / `full-reload` as aliases, and add a JSON opcode `{type, hashes?, overlay?}` for errors. Compile failures (printer, LDC, `wasm-opt`) go to `/__svelte-d/overlay`, not only stdout
(I2: `compile` writes `public/__svelte-d/overlay.json` + `overlay/index.html`, dest
`.d` lines rewritten through the debug map). Server-only dirty cones must not force `dumpApp`.

Source maps are a chain, not a single file:

```
.svelte / +page.server.ts  →  IR node id  →  generated .d:line  →  wasm function
```

The D printer emits `//# svelte-d-ir:<id> orig:<file>:<line>` comments (v1 success: an assertion overlay names the original `.svelte` line). I4 joins the wasm **name section** onto those dests (`writeWasmNameMap`); it does **not** ship `generateSourceMap.py` (incomplete, line `0`, duplicated header). LDC DWARF / `--output-ll` is cell-aware: 1.42 + full LTO + debug DI aborted LLVM 21; that app uses `-flto=thin` on the 1.42 config.

Server debug uses what vibe.0 already has. `mixin(Trace)` is on `handleHTTPConnection` / `handleRequest` (`server.d:1738+`, `1897+`). `vibe.http.debugger` serves allocation and task dumps (`debugger.d`). `TaskDebugger` lives in `core/trace.d:49`. `EnableDebugger` is on in vibe.0 `dub.json`; `VibeNoDebug` strips traces. slideshow3dai’s `webserver/dub.sdl:12` sets `DisableDebugger` `VibeNoDebug` **and** `VibeRequestDebugger` — `DisableDebugger` is **not** a `version(...)` in `source/` (vibe.0 `AGENTS.md`). Generated apps must only emit versions that exist: `VibeCustomMain`, and `VibeNoDebug` only when the user asked to strip. Dev adapter mounts debugger routes under `/__svelte-d/debug/*`.

## Loci

`spa.d:148-165` — exports  
`hmr.d:16-82,185-330` — format + unittest  
`spa.ts:574-626` — JS reload  
`vite.config.js:36-136` — watch + WS `:3001`  
`generateSourceMap.py:1-72` — do not ship  
`vibe.0/source/vibe/http/debugger.d`  
`vibe.0/source/vibe/core/trace.d`  
`libwasm/architecture/js-events-memory.md` — assert path aborts  

## Invariants

- HMR requires `version(hmr)` and the export list. (construction)
- Handles `1` and `2` are document/window and must not be deleted. (construction of the glue ABI)
- Do not cancel the dump/load protocol in favor of a full reload except on glue/TS changes (today `src-ts` → `full-reload`). (convention)
- Overlay is dev-only; production adapter does not bind the HMR port. (construction of the threat model)
- Debugger routes are not mounted when `VibeNoDebug`. (construction)

## Extension points

JSON WS opcodes. List serialization is in libwasm `hmr.d` (`:l:N:[…]`, G77). IR inspector is I3 (`/__svelte-d/ir`). Forwarding `TaskDebugger` breadcrumbs into the overlay.

## Did not close

How to invalidate outstanding timers without a libwasm scheduler API. Whether wasm source maps are v1 or “best effort after Phase 8.” Whether to keep Vite’s WS and the bun WS both alive during the slideshow3dai transition (risk: two reloads). Whether existing list items should `remount` after load so `@prop` DOM matches dumped fields without a later `update`.

**G84:** `debug-bridge` installs `__svelteDProbe` (rewrite + `console.info` so CDP `Runtime.consoleAPICalled` / `Log.entryAdded` see dest→orig), `window.onerror` / `unhandledrejection` into `__svelteDLastFaults`. The admin sink enables CDP `Log.enable`. `lang-features.test.ts` probes Combo* dests on `/` and `/admin/features`.
