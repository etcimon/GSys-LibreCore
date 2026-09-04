# svelte-kit-d

bun + svelte-d **consumer** project. Depends on `svelte-d` (`file:../svelte-d`) and imports the compiler:

```ts
import { compileWorkspace, dropWorkspace, mapKitPath } from 'svelte-d'
```

**Guiding principles:** kit syntax falls through to an equivalent ws tree. Kit features are accommodated in svelte-engine / libwasm / vibe.0; compile integrates the engine as the bootstrap. Tests: `test/import-library.test.ts`, `test/bootstrap.test.ts`.

1. `drop` — copy packaged `node_modules/svelte-d/svelte-engine` → project-root `svelte-engine-ws/` (`svelte-d.config.ts` `workspace`)
2. `compile` — Pegged + libdparse → `ws/.svelte-d/` (IR + `fallthrough.json`); `src-d/` is libwasm IR (PgLite passthrough)
3. `dev` — drop if needed, compile, wasm/host if dirty, `bunx vite` in the ws (HMR `:3001`). Starts vibe.0 `:8180` when `svelte-engine-server` exists (`--no-host` to skip). Watches `src-svelte` and reprints.
4. `adapt` — consume `ws/.svelte-d/manifest.json` and copy artifacts (`static` / `libwasm-spa` / `vibe0` / `vibe0-proxy`). No Node HTTP stack.

```bash
bunx svelte-d setup
bun install
cd packages/svelte-kit-d
bun test
bun src/cli.ts dev          # debug wasm/host
# bun run build in kit-admin is release + strip
```

The wasm frontend is `ws` `dub.sdl` (LDC wasm-eh). The host is `ws/webserver` (vibe.0). This package does not reimplement either cell.
