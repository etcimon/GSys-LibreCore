# IR target — `src-d/` is the D the printer must emit

svelte-engine does not invent a second IR file format for the running app. The **target IR** is the libwasm/vibe.0 D already in this tree. JSON under `ir/` is a **cache key sketch** for the later bun compiler (svelte-D K6: JSON files in `<app>/.svelte-d/`).

## Node kinds (v1, matches svelte-D design)

| Kind | Source | D sink in this tree |
|---|---|---|
| `App` | `+layout` root | `src-d/app.d` `struct App` + `mixin Spa!App` |
| `Component` | `.svelte` | one `src-d/<name>.d` struct |
| `Page` | `+page.svelte` | `@child` of App / layout |
| `Template` | markup | `NodeDef` + `@child` / `@prop` / `@style` |
| `Handler` | `on:` / script method | `@callback` + optional `Slot` / `@connect` |
| `Route` | `src/routes` | `libwasm.router` pattern and/or vibe.0 `@path` |
| `ServerLoad` | `+page.server.d` | vibe.0 web-interface method |
| `ScriptD` | `<script lang="d">` | fields + methods, not a string blob |
| `BindingCall` | `document` / `fetch` / … | `libwasm.bindings.*` on a `Handle` |
| `LodashChain` | JS arrays / `window._` / `lang=d` Lodash | `Lodash(…).map/filter/invoke/attempt.execute!T()` — fixture `src-svelte/lib/LodashDemo.svelte` prints to `src-d/lib/lodashdemo.d` |
| `MomentCall` | dates | `moment(...).format` |
| `JsHostWrap` | `window.pglite` etc. | `pglite.d` pattern |

Hash = `SCHEMA_VERSION` + kind + source path + canonical D pretty-print of that node. Dirty cone reprints that `.d` file only; the wasm cell still **whole-program** links (no `.o` cache under LTO).

## Features the IR must preserve (this bootstrap)

- wasm-eh: probes + navbar `try/catch` (`--wasm-enable-eh`, `--foptimize-nothrow=false`).
- Dynamic UI: `this.update` on `@prop` fields; parent `@connect` to a child `Slot`.
- HMR: `version(hmr)` `dumpApp`/`loadApp` (`List`/`HTMLArray` as `:l:N:[{item}…]` in `libwasm/hmr.d`).
- Host: `VibeCustomMain` + `listenHTTP` + `runEventLoop` + reverse proxy.

## Example cache record

See `ir/example-app.json`. The bun compiler writes these under `<app>/.svelte-d/ir/<hash>.json` later. Do not treat that directory as required to run this bootstrap.
