# Overview — svelte-engine bootstrap

slideshow3dai copied here so svelte-D has a **writable golden** that already speaks both cells. Product screens in `src-d/app.d` comments stay as the intended feature list; the live UI is a smaller `this.update` demo plus navbar/dock/pglite.

## What was preserved

- libwasm SPA: `mixin Spa!App`, `@child` navbar / content / dock, Diet views, TS handle-table glue, Vite HMR (`dumpApp`/`loadApp`), wasm-eh probes.
- vibe.0 host: `registerWebInterface`, Botan TLS, Redis sessions, reverse-proxy to Vite `:5173`.
- Two-compiler split.

## What changed vs slideshow3dai

| Item | slideshow3dai | svelte-engine |
|---|---|---|
| Default wasm cell | 1.36 `application` + asyncify | **1.43 wasm-eh** (`application` = `ldc-master` flags; fork `--asyncify` then `-Oz`; stock 123/132 `-Oz` only) |
| Generated `dub.sdl` subConfiguration | 1.36 default had none | always pins `libwasm` `ldc-master` / `ldc-1.36` / `ldc-1.42` |
| Dynamic UI | dock only toggles CSS | dock emits `navigate`; `Main.show` updates heading/status via `this.update` |
| wasm-eh in UI | unused `SomeException` | navbar button **throws and catches** before PgLite |
| Probe exports | `slideshow_*_probe` | `svelte_engine_*_probe` |
| Svelte source | none | `src-svelte/` + `script lang="d"` plan |
| Host package | `slideshow3dai-server` | `svelte-engine-server` (`vibe-0` `>=1.2.2`) |

## Journey

```
src-svelte (+page.svelte, lang=d)   # planned input
        │  svelte-D printer (later)
        ▼
src-d/*.d                          # target IR output (hand-written today)
        │  LDC wasm-eh
        ▼
public/svelte-engine-raw.wasm  → copy → svelte-engine.wasm
        │  Vite + TS glue
        ▼
browser  (#root, handle table, HMR :3001)

webserver/  vibe.0  :8180  ──proxy──►  Vite :5173
```

## Loci

`src-d/app.d` — `mixin Spa!App`, `Main.show`, `@connect!"dock.navigate"`  
`src-d/dock.d` — `mixin Slot!("navigate", string)`  
`src-d/navbar.d` — try/catch `SomeException`  
`src-d/probe.d` — EH + Phobos  
`dub.sdl` — default wasm-eh  
`webserver/source/app.d` — vibe.0 listen + proxy  
