# svelte-d

D compiler (vibe.0 + Pegged + libdparse) that turns SvelteKit-shaped sources into libwasm/vibe.0 D inside a dropped **svelte-engine-ws**. Builds as an **importable library**: TypeScript (`ts/index.ts`) over `bin/svelte-d` (exe) and `lib/svelte-d` (dll/so, bun:ffi).

A consumer machine is a bun project plus LDC 1.43 from `bunx svelte-d setup`. There is no `riscv-dev` tree on that machine. libwasm and vibe-0 come from DUB (git / registry). Optional live checkouts are `dub add-local`’d when present.

**Guiding principles:** kit syntax falls through to an equivalent libwasm / vibe.0 tree in the ws (`mapKitPath`). Kit features and further development are accommodated in **svelte-engine / libwasm / vibe.0**; `compile` integrates the current engine as `svelte-engine-ws`.

```bash
bunx svelte-d setup
bun install                          # prepare builds this CLI
bunx svelte-d drop-ws --force        # overlay; never deletes dest
bunx svelte-d compile --project .
bunx svelte-d wasm --debug           # IR work
bunx svelte-d build                  # IR + wasm/host release + strip
```

A bun project depends on `"svelte-d"` and `import { compileWorkspace, dropWorkspace, mapKitPath, adaptWorkspace } from 'svelte-d'`. The package **ships `svelte-engine/`**. After `bun install`, drop copies `node_modules/svelte-d/svelte-engine` → the dest from **`svelte-d.config.ts`** (`workspace: './svelte-engine-ws'` at the project root by default). `compile` then ingests the project's `src/`. Adapters call `adaptWorkspace` and write `out/adapter.json`.

See `../../architecture/` (fallthrough.md, pegged-grammar.md, workspace.md, compiler-host.md).
