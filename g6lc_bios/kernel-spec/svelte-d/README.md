# svelte-d

**Compile a bun(nodejs) svelte/svelte-kit into a tight wasm frontend and exe server based on D.**

[![CI](https://github.com/etcimon/svelte-d/actions/workflows/ci.yml/badge.svg?branch=master&event=push)](https://github.com/etcimon/svelte-d/actions/workflows/ci.yml)
[![Docs](https://github.com/etcimon/svelte-d/actions/workflows/docs.yml/badge.svg?branch=master&event=push)](https://github.com/etcimon/svelte-d/actions/workflows/docs.yml)
[![wasm-opt](https://github.com/etcimon/svelte-d/actions/workflows/wasm-opt.yml/badge.svg?branch=master&event=push)](https://github.com/etcimon/svelte-d/actions/workflows/wasm-opt.yml)
[![GitHub Pages](https://img.shields.io/badge/docs-GitHub%20Pages-222?logo=github)](https://etcimon.github.io/svelte-d/)

The browser cell is **libwasm** (LDC 1.43 `try_table` wasm-eh). The server cell is **vibe.0**. There is no Svelte-to-JS wrap and no second DOM or HTTP stack. One **LDC 1.43+** builds the CLI, the wasm module, and the host exe. `{#await}` prints `wireAwait`: `.await` on a fork-asyncified module, then D fills `{:then}` / `{:catch}` **after** rewind (`libwasmAwaitValue` / `libwasmAwaitFailed` / `libwasmAwaitError`). A `try` never wraps the import.

## Getting Started

```bash
bun add github:etcimon/svelte-d
bunx svelte-d setup
bunx svelte-d drop-ws --force
bunx svelte-d compile --project .
bunx svelte-d build
```

[Read more](https://etcimon.github.io/svelte-d/getting-started): LDC 1.43, forked `wasm-opt`, `svelte-d.config.ts`, debug vs release, code-d / VS Code, and the first `.svelte` file.

## What you get

| Output | What it is | Kit-admin ship size |
|---|---|---|
| `public/svelte-engine.wasm` | libwasm SPA (NodeDef graph, no React) | **0.93 MiB** / **224 KB** gzip (`wasm-opt -Oz`) |
| `webserver/svelte-engine-server` | vibe.0 host exe | **10.85 MiB** release |

Debug keeps symbols (12.64 MiB wasm, 14.08 MiB host). `bun run dev` is debug. `bun run build` / `svelte-d build` is release + `lflags -strip-all`, then the fork `wasm-opt` asyncifies (so `.await` waits and D can fill `{:then}` / `{:catch}` after rewind) and `-Oz`s. See [sizes](https://etcimon.github.io/svelte-d/advanced/sizes).

## Use in a bun + SvelteKit project

```bash
bun add github:etcimon/svelte-d
bunx svelte-d setup          # LDC 1.43 + pull CI wasm-opt for this triple (no CMake)
```

```ts
// svelte-d.config.ts  (project top-level)
export default { workspace: './svelte-engine-ws' }
```

```ts
import { dropWorkspace, compileWorkspace, workspaceDir } from 'svelte-d'

const ws = workspaceDir()
dropWorkspace({ dest: ws, force: true }) // overlay; never deletes dest
compileWorkspace({ ws, project: process.cwd() })
```

```bash
bunx svelte-d drop-ws --force
bunx svelte-d compile --project .
bunx svelte-d wasm --debug     # symbols for IR work
bunx svelte-d build            # IR + wasm/host release
```

`drop-ws` overlays the packaged **svelte-engine** template onto `svelte-engine-ws` and never `rmdir`s that folder. `--force` overwrites template-owned files only. A consumer machine does not need a `riscv-dev` tree: `setup` (and `wasm` / `build` if the binary is missing) pull LDC and the matching `wasm-opt-<triple>.tar.gz` from release `wasm-opt-svelte-d`. A successful pull does not cmake-rebuild Binaryen. DUB fetches libwasm / vibe-0 / openssl.

`<script lang="d">` prints libwasm D. `<script lang="ts">` splices into `src-ts/modules` `jsExports` and `__svelteD.ts`. Same-file D may call those exports by the simple name (`callTs` / Lodash). D `extern(C) export` is `exportDelegate` for `callNative`. npm imports on `lang=ts` fall through from the project onto dest `package.json` (declared range) and dest `node_modules/<pkg>` (copy of the project’s install). See `docs/pages/language/cross-calling.mdx` and `architecture/cross-calling.md`.

`{#await job}` is a host `JsPromise` plus `@visible` pending / then / catch children. `App.ready` calls `wireAwait` once per job. When the etcimon Binaryen fork asyncified the module, that is sequential `job.await`; after rewind D reads `libwasmAwaitFailed()` and fills `{:then v}` from `libwasmAwaitValue()` or `{:catch e}` from `libwasmAwaitError()`. Stock Binaryen 123/132 cannot `--asyncify` `try_table`; `wireAwait` then keeps `.then` / `.error`, notes the Any handle (`libwasmNoteAwaitOk` / `libwasmNoteAwaitFail`), and reads the same strings. The first job keeps `await_then` / `await_catch`; later jobs use `await_*_<job>`. Two `{e}` / `{v}` bindings uniquify to `eP` / `eP2`. Do not wrap `.await` in `try/catch` — `{#await}` catch is Svelte visibility after rewind, not D EH across the import. `throwBoundary` stays a same-function landing pad off that import.

## This repository

```bash
git clone --recurse-submodules https://github.com/etcimon/svelte-d.git
cd svelte-d
bunx svelte-d setup
bun install                    # prepare → pack engine + dub build → packages/svelte-d/bin/svelte-d
bunx svelte-d version          # prints 1
bun test
bun run docs                   # local Nextra site (empty basePath)
```

Submodules: [`svelte-engine`](https://github.com/etcimon/svelte-engine) (drop source) and [`binaryen`](https://github.com/etcimon/binaryen) (Flatten `try_table` fork, branch `svelte-d`). CI (`.github/workflows/wasm-opt.yml`) compiles that fork for **darwin-arm64**, **darwin-x86_64**, **linux-x86_64**, **linux-aarch64**, and **windows-x86_64** and publishes each `wasm-opt-<triple>.tar.gz` on the `wasm-opt-svelte-d` release (and the `wasm-opt-binaries` branch). `setup` / `wasm` / `build` download the matching triple into `binaryen-build/<os-arch>/` (Apache-2.0 `LICENSE` next to the binary) and `~/.svelte-d/toolchains/binaryen-svelte-d`. That pull is enough on Apple Silicon and every other CI host; cmake is not required. `SVELTE_D_BUILD_WASM_OPT=1` opts into a source rebuild. Official Binaryen 123/132 *parse* `try_table` and remain the fallback `-Oz` path.

## How it compiles

Svelte / SvelteKit syntax **falls through** into an equivalent `svelte-engine-ws` tree (`+page.svelte` → `src-d/` + `src-svelte/`; `+page.server.*` → `webserver/source/`). svelte-d **prints** libwasm / vibe.0 D IR. Kit features are **accommodated** in svelte-engine, libwasm, and vibe.0 — not by inventing a third runtime.

- `svelte-d wasm --debug` / `svelte-d host` / `bun run dev` — debug
- `svelte-d wasm` / `svelte-d host --release` / `svelte-d build` / `bun run build` — release

Docs: [https://etcimon.github.io/svelte-d/](https://etcimon.github.io/svelte-d/). Language pages walk every interactive `.svelte` construct and the D IR it prints. Agent notes: [`AGENTS.md`](AGENTS.md), [`architecture/`](architecture/).

## License

MIT. LDC, libwasm, vibe.0, Svelte, Binaryen (`binaryen-build/LICENSE`), and Google `asyncify.ts` keep their own terms. See [`LICENSE.md`](LICENSE.md).
