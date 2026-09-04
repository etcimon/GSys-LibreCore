# Development — next passes

Green for this slice:

```powershell
cd riscv-dev
. .\setenv.ps1
cd svelte-D\packages\svelte-d
dub build --config=application --compiler=ldc2
dub build --config=library --compiler=ldc2
cd ..
bun install
cd svelte-kit-d
bun test
```

Import surface: `import { compileWorkspace, mapKitPath, accommodateFeatures, verifyBootstrap } from 'svelte-d'`.

Guiding principles: kit syntax → equivalent ws tree ([fallthrough.md](fallthrough.md)); kit features land in svelte-engine / libwasm / vibe.0 and compile integrates the engine ([bootstrap.md](bootstrap.md)).

To add a kit feature: (1) show the idiom in `svelte-engine` using libwasm or vibe.0, (2) titled seam in libwasm/vibe.0 only if a new primitive is required, (3) feature-map row, (4) fall-through + printer arm, (5) `bun test` in svelte-kit-d plus the coverage / kit-app consumer packages.

Lodash in `lang=d` is already libwasm D (`Lodash` + `execute!T()`). Bindings (`document`/`window`/`console`), types (`Handle`/`Eval`/`JSON`), and kit routes (`[slug]` → `:slug` on `URLRouter`) print the same way. Svelte walks an AST that **is** the libwasm D IR ([ast-ir.md](ast-ir.md)). Interactive markup prints `mixin NodeDef` → NamedNode, `@connect` / `@inject`, `UnorderedList` ([udas.md](udas.md)). Names stay representative (`ClickField.svelte` → `struct ClickField` / `goButton`). Lodash/bindings stay procedural. Heavy procedural arms are `ScopedPool` + copy-out / freeze ([AGENTS-D-IR-memory-management.md](AGENTS-D-IR-memory-management.md)). Lifetime is libwasm’s hooks: `construct` / `onMount` / `ready` / `unmount` ([AGENTS-D-IR-lifetime.md](AGENTS-D-IR-lifetime.md)). Default wasm-eh cell: D `try`/`catch`, no `.await`. Asyncify cells: `.await`, no landing pads in that function ([AGENTS-D-IR-asyncify-wasm-eh.md](AGENTS-D-IR-asyncify-wasm-eh.md)). Wasm cell (T6/G20) and host cell (T7/G21) both build **inside** svelte-engine-ws (`svelte-d wasm --ws`, `svelte-d host --ws`). `bun src/cli.ts dev` drop/compiles, builds dirty cells, starts Vite `:5173` (HMR `:3001`), and starts vibe.0 `:8180` if the host exe exists. T12 adapters (G76) package `manifest.json`. G77–G79 language IR. G80 skips the wasm link when printed dests are unchanged. G107 compiles dirty `src-d` to `.svelte-d/o/` and relinks; LTO cells stay on `dub`.

One thesis per pass. Do not parse with `svelte/compiler`. Do not mutate the `svelte-engine` template.
