# svelte-d-kit-admin

bun + TypeScript consumer of `svelte-d`. Incremental **admin panel** from
[architecture/admin-debug.md](../../architecture/admin-debug.md).

`svelte-d.config.ts` sets `workspace: './svelte-engine-ws'` so drop and
compile land in **this package’s top-level** dest, not the repo-root
workspace. `drop-ws` copies the **packaged** engine
(`svelte-d/templates/engine`). `--force` refreshes sources but keeps
`node_modules` so a leftover Vite cannot lock the drop. `compile --project`
overlays this package's `src/routes/admin` onto that dest. After print,
`bun run dev` keeps **debug** wasm/host (symbols, no strip). `bun run build`
is **release + `lflags -strip-all`** for both cells, then Binaryen ≥123
`wasm-opt -Oz` on the wasm-eh module, and writes debug vs release sizes
to `svelte-engine-ws/.svelte-d/artifact-sizes.json`. Shipped wasm on this
tree is **0.93 MiB** / 224 KB gzipped. The engine is not the app.

- kit tree `src/routes/admin` printed to libwasm D IR
- derived `debug-map.json` + `rewriteStack` (D IR → `.svelte`)
- host `+page.server.d` uses vibe.0 **PostgreSQL**, **Redis**, and **JSON**
  (`connectDB` / `connectCache` / `serializeToJsonString`)
- Puppeteer/CDP platform (optional Chromium) rewrites console/pageerror stacks
- `/__svelte-d/overlay` names compile/LDC errors by the orig `.svelte`
- `/__svelte-d/ir` lists printed IR dests (read-only; does not execute)
- `/__svelte-d/wasm-names.json` joins wasm name-section symbols onto orig `.svelte`
- `KitRoutes` on `App`: `@entering` remounts `/admin` pages on the layout (`setVisible`); layouts stay

Live Postgres/Redis and browsers are optional. Offline hosts write `"skip"`;
missing Chromium/Firefox skips those smokes.

```
bun test
bun run dev          # debug wasm/host, vite, vibe.0 logs
bun run build        # release + strip-all + wasm-opt -Oz; print sizes
bun run dev --chrome
bun run dev --firefox
```

Browser `console.*` / `pageerror` and vibe.0 `logInfo`/`logWarn`/`logError`/`logTrace`
print on **this** bun prompt, rewritten through `debug-map.json`, colored unless
`NO_COLOR` is set.
