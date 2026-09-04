# Overview — compile and runtime journey

The next change that adds a pipeline stage, a third compiler cell, or a “just run everything through Vite” shortcut should read this first and then stop.

svelte-D is a **D program** that links **vibe.0 as a library**. It does not implement a DOM. It **does** parse (Pegged + libdparse), pretty-print D, and may later `listenHTTP` for HMR. It lowers Svelte/SvelteKit sources (and passthrough D) into an IR, writes them into a dropped **`svelte-engine-ws`**, and invokes two **already separate** LDC environments **inside that workspace**. The browser loads JS glue plus wasm; the **app** host is a second vibe.0 process (`ws/webserver`). That pairing is not hypothetical: svelte-engine already ships it by hand.

A representative production request after a `svelte-d build` is: TLS accept on the vibe.0 process (`listenHTTP` at `vibe.0/source/vibe/http/server.d:77`), one libasync fiber per connection (`architecture/overview.md` in that clone), `URLRouter.handleRequest`, either a generated `+server`/`load` handler or a static/prerendered file, and — for document routes — an HTML string builder plus a `<script>` that fetches `*.wasm` (never `*-raw.wasm` on the 1.36/1.42 cells). The wasm `_start` (`libwasm/source/libwasm/spa.d:114-146`) initialises `WasmAllocator` from `__heap_base`, injects `GetCss`, `compile()`s structs, optionally `setupRouter()`, and `libwasm.dom.render`s into the JS handle table. Promises only yield if Binaryen `--asyncify` listed `env.libwasm_await__void` (`types.d:181`). None of that is svelte-D’s to reimplement.

A representative **dev** save is: svelte-d (or later `svelte-d serve`) sees `svelte-engine-ws/src-svelte/routes/foo/+page.svelte`, Pegged-parses it, libdparse-checks the `lang=d` body, recomputes IR hashes, reprints only the dirty cone into `ws/src-d/`, splices `lang=ts` into `ws/src-ts/modules/generated/` (`jsExports` + `__svelteD.ts`), falls through npm specs onto dest `package.json` / `node_modules`, then rebuilds **only the dirty cell** inside the ws (K6: per-`.o` `src-d` + relink on the default no-LTO cell, G107; LTO cells still whole-program `dub`), rewrites `ws/.svelte-d/manifest.json`, and sends `reload` on the HMR websocket so `dumpApp`/`loadApp` can tear down handles `> 2`. One wasm artifact per app (K17). Crossing the two scripts is Lodash `callTs` / `exportDelegate` ([cross-calling.md](cross-calling.md)), not a third cell.

```mermaid
sequenceDiagram
  participant Dev as svelte-d (vibe.0)
  participant IR as IR cache
  participant WC as wasm LDC cell
  participant HC as host LDC cell
  participant Br as browser
  participant Sv as vibe.0 process
  Dev->>IR: parse + hash cone
  alt client dirty
    Dev->>WC: dub build wasm32-unknown-wasi
    WC->>WC: wasm-opt --asyncify
    Dev->>Br: WS reload
    Br->>Br: dumpApp / loadApp
  end
  alt server dirty
    Dev->>HC: dub build host
    HC->>Sv: replace binary / hot restart
  end
  Br->>Sv: HTTPS document or /api
  Sv->>Br: HTML + wasm URL
  Br->>Br: fetch .wasm ; _start
```

## Loci

`libwasm/source/libwasm/spa.d:104-166` — `mixin Spa`, `_start`, dumpApp/loadApp  
`libwasm/source/libwasm/types.d:181` — `libwasm_await__void`  
`vibe.0/source/vibe/http/server.d:77` — `listenHTTP`  
`vibe.0/source/vibe/appmain.d:24-28` — `VibeCustomMain` required  
`slideshow3dai/architecture/overview.md` — two programs, two compilers  
`slideshow3dai/webserver/source/app.d:55-63,147-149` — reverse proxy + `runEventLoop`  
`riscv-dev/setenv-wasm.ps1` vs `setenv.ps1` + `modules.json` — cell split  

## Invariants

- Two LDC cells. Mixing `object.d` (libwasm vs Phobos) is construction failure, not a config knob. (construction)
- `public/<name>-raw.wasm` is LDC output; `public/<name>.wasm` is what JS instantiates on 1.36/1.42. Do not rename one without the other. (construction for slideshow3dai; convention svelte-D must preserve in the manifest)
- svelte-d (host cell) never links libwasm. The **app** wasm cell never links svelte-d’s Pegged/libdparse. (construction)
- Dropped workspace is `svelte-engine-ws`. The template `svelte-engine/` is not a build dest. (construction)
- Kit syntax falls through to libwasm / vibe.0 in an equivalent ws tree ([fallthrough.md](fallthrough.md)). Do not invent a third layout. (construction)
- Kit features are accommodated in svelte-engine / libwasm / vibe.0; compile integrates the engine as the ws bootstrap ([bootstrap.md](bootstrap.md)). svelte-d does not grow a third runtime. (construction)
- Parse of `.svelte` is Pegged (`SvelteKit:`). Parse of D is libdparse. Not `svelte/compiler`. (construction of K16)
- Workspace default wasm cell follows **svelte-engine** (`ldc-master` / wasm-eh). Fork wasm-opt `--asyncify` then `-Oz`; stock 123/132 `-Oz` only. `{#await}` prints `.await` only when `libwasmAwaitSupported()`. Named `ldc-1.36` / `ldc-1.42` remain. (construction of the yield protocol)
- `lang=ts` is spliced into `src-ts` `jsExports` and `__svelteD.ts`. Crossing is `callTs` / `exportDelegate`, not a new WASM import list. (construction)

## Extension points

A new pipeline stage is a D module between parse and print (IR pass) or after print (cell driver). A new runtime target is a **third printer + third cell**, not a flag that reuses wasm `object.d` on the host. A new adapter consumes `ws/.svelte-d/manifest.json`; it does not replace `listenHTTP`.

## Did not close

Whether the bun dev server should *replace* Vite for slideshow3dai in phase 8 or only sit beside the existing `vite.config.js:36-136` plugin. `adapter-libwasm-spa` is first-class **packaging** (G76); a Vite-less JS bundle still needs `ws/dist` from a Vite build. Whether hot-restarting the vibe.0 binary is acceptable in dev (it is: there is no proven vibe.0 module-replace HMR).
