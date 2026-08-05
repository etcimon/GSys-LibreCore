# `@sv-timing/js` — TypeScript client & integration tests

Bun-primary **TypeScript** package that talks to the Rust `sv-timing` CLI over **versioned JSON**.

| Concern | How |
|---|---|
| Exported AST / analyze | `SvTimingClient.analyze()` → `AnalyzeResult` (`schemas/analyze-result.v0.json`) |
| Debug dumps | `debugExport()` → `DebugExportResult` |
| Auto-correct | `correct()` dry-run / emit → `CorrectResult` |
| In-process FFI | Post-v1 (`preferNative`); same DTOs |

**Zero runtime npm dependencies** — only Bun built-ins + `devDependencies` (`typescript`, `@types/bun`).

## Setup

From `sv-timing/`:

```bash
# Rust toolchain + binary (Python-first)
python tools/svt.py setup
python tools/svt.py build

# TypeScript package
cd js
bun install          # devDeps only
bun test
bun run typecheck
```

Or from package root:

```bash
python tools/svt.py js-test
```

## Usage

```typescript
import { createClient } from "@sv-timing/js"; // or relative ./src/index.ts

const client = createClient();
const result = await client.analyze({
  filesFrom: "fixtures/filelist.txt",
  modules: ["comb_adder_cloud"],
  jsonOut: ".sv-timing-out/analyze.json",
  targetMhz: 1000,
});
console.log(result.ast.files_parsed, result.files);
```

## Layout

```
js/
  package.json
  tsconfig.json
  bunfig.toml
  src/
    index.ts      # public exports
    types.ts      # DTOs + type guards
    client.ts     # spawn CLI, rehydrate JSON
    paths.ts      # package root / contained cargo
  test/
    analyze.connection.test.ts
    debug.connection.test.ts
    autocorrect.connection.test.ts
```

## Architecture

See `../architecture/JS-TYPESCRIPT.md` and `../AGENTS-js.md`.
