# Package — bun install produces the svelte-d CLI

The next change that publishes a second package name, or that expects `bun add svelte-d` to work without a native `ldc2`/`dub` host cell, should read this.

**This repository root is the `svelte-d` package** (`package.json` `name`, and root `dub.sdl` for code.dlang.org). A Svelte / SvelteKit bun project includes it with `bun add github:etcimon/svelte-d`. `bun install` / `bun run build` runs `scripts/build-cli.ts`: pack `svelte-engine` if needed, then `dub build --config=application` into `packages/svelte-d/bin/svelte-d` (`.exe` on Windows). The bun bin `bin/svelte-d.ts` forwards `bunx svelte-d …` to that native compiler.

DUB versions come from **git tags** (`v0.2.3` → `0.2.3`). Root `dub.sdl` must not contain a `version` field: the registry reads `package.json` when no `dub.sdl` is present, and then `~master` fails because npm’s `"version"` is a semver, not `~master`. npm still keeps `"version"` in `package.json`.

`import { compileWorkspace, dropWorkspace } from 'svelte-d'` resolves to `packages/svelte-d/ts/index.ts`. Drop copies packaged `packages/svelte-d/svelte-engine` (or the `svelte-engine/` submodule) to the dest from **`svelte-d.config.ts`** (`workspace: './svelte-engine-ws'` at the project root by default). `compile` ingest the app `src/routes` when cwd is a kit project.

## Build

One LDC 1.43+ (`bunx svelte-d setup` finds or downloads it). The same `ldc2` builds the CLI, the vibe.0 host, and wasm. See [engine-setup.md](engine-setup.md).

```
bun install          # prepare → build-cli (skips if exe already present)
bun run build        # always rebuild CLI + pack engine if missing
bunx svelte-d version
bun test             # package-engine + import-library + bootstrap
```

GitHub Actions: `.github/workflows/ci.yml` (checkout submodules, Bun, LDC, `bun install`, `bun test`).

## Invariants

- The published name is `svelte-d` at the **repo root**. Do not add a second npm name for the same compiler. Root `dub.sdl` has no `version` field; tags do. (construction)
- `bun install` must leave a runnable CLI when `ldc2` and `dub` exist. (construction)
- App builds stay in `svelte-engine-ws`, never in the packaged `svelte-engine/`. (construction)
- One LDC 1.43+ compiles the CLI, host, and wasm. Wasm vs host objects still do not mix ([engine-setup.md](engine-setup.md)). (construction)
