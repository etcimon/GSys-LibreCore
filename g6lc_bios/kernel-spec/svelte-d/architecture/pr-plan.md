# PR plan

Independently reviewable. First PRs are the **D** package at `packages/svelte-d/`, Pegged parse, workspace drop, then print into `svelte-engine-ws`. Not a bun skeleton. Not a SvelteKit clone.

| # | Title | Files / components | Depends on | Description |
|---|---|---|---|---|
| PR0 | **docs: svelte-D architecture** | `riscv-dev/svelte-D/**` | — | Living notes (this folder). |
| PR1 | **feat(svelte-d): vibe.0 CLI + drop-ws + compile** | `packages/svelte-d/` | PR0 | `drop-ws` / `parse` / `compile`. IR JSON + libwasm `src-d` passthrough (pglite). |
| PR1b | **feat(svelte-kit-d): bun test + bun dev** | `packages/svelte-kit-d/` | PR1 | bun harness; Vite HMR in the ws. |
| PR2 | **feat(svelte-d): Pegged SvelteKit grammar** | `grammar/sveltekit.peg`, `svelte_d/grammar/` | PR1 | Same pattern as `libwasm/webidl/webidl-grammar`. `parse` dumps `ParseTree` for `src-svelte` goldens. |
| PR3 | **feat(svelte-d): libdparse on lang=d / +server.d** | `svelte_d/parse/dlang.d` | PR2 | Script bodies and host D. serve-d not linked. |
| PR4 | **feat(svelte-d): IR hasher + kit-fs** | `svelte_d/ir/`, `parse/kit_fs.d` | PR2 | Content-addressed nodes; walk `src-svelte/routes`. |
| PR5 | **feat(svelte-d): client printer into ws/src-d** | `svelte_d/print/client.d` | PR4 | Emit libwasm structs matching template `src-d/`. Snapshot vs svelte-engine goldens. |
| PR6 | **feat(svelte-d): wasm cell driver in the ws** | `svelte_d/cells/wasm.d` | PR5 | `dub build` **inside** `svelte-engine-ws` using that `dub.sdl`. |
| PR7 | **feat(svelte-d): server printer + host cell** | `print/server.d`, `cells/host.d` | PR4 | vibe.0 handlers into `ws/webserver/source/generated/`. |
| PR8 | **feat(svelte-d): manifest + incremental watch** | `link/`, `dev/` | PR6, PR7 | Reprint-skip + opposite-cell-skip; whole-program relink in the ws. |
| PR9 | **feat(svelte-d): vibe.0 serve + HMR WS** | `app.d` listenHTTP | PR8 | dumpApp/loadApp compatible. |
| PR10 | **feat(svelte-d): +page.server load / actions / env** | printers | PR7 | v1 subset only. |
| PR13a/b | optional libwasm / vibe.0 seams | those trees | notes | Own green cells. |

## Review bar

- Feature-map row updated if a SvelteKit feature moved.
- Pegged/libdparse never enter the wasm `dub.sdl`.
- Builds run in `svelte-engine-ws`, not the template.
- No GPL in either link line.
