# TypeScript / Bun client (`sv-timing/js`)

> Companion to [`DESIGN.md`](DESIGN.md) § Bun interaction and [`AUTO-CORRECT-CORE-API.md`](AUTO-CORRECT-CORE-API.md).  
> Package: **`@sv-timing/js`** under `sv-timing/js/` — **TypeScript-only** sources and tests.

## Purpose

Provide a **first-class TypeScript** surface that:

1. Spawns the Rust `sv-timing` CLI (contained cargo or built binary).
2. Rehydrates **versioned JSON** into typed DTOs (exported AST stub → full IR later).
3. Exercises **analyze**, **debug-export**, and **auto-correct** connections in `bun test`.
4. Stays independent of monorepo `build-platform` (hosts may copy or path-import).

## Layout

```
sv-timing/js/                 # Bun + TypeScript project
  package.json                # @sv-timing/js, zero runtime deps
  tsconfig.json               # strict, noEmit, .ts extensions
  bunfig.toml
  src/
    index.ts                  # public exports
    types.ts                  # AnalyzeResult, CorrectResult, DebugExportResult, …
    client.ts                 # SvTimingClient
    paths.ts                  # package root + .tools/cargo
  test/
    analyze.connection.test.ts
    debug.connection.test.ts
    autocorrect.connection.test.ts
  README.md

sv-timing/schemas/
  analyze-result.v0.json      # JSON Schema for AnalyzeResult
```

## Contracts

| Rust CLI | TypeScript | Schema / guard |
|---|---|---|
| `analyze --json-out` | `AnalyzeResult` | `schemas/analyze-result.v0.json`, `isAnalyzeResult` |
| `correct --json-out` | `CorrectResult` | `isCorrectResult` |
| `debug-export --json-out` | `DebugExportResult` | `isDebugExportResult` |
| `status --json-out` | `StatusResult` | optional |

All use `schema_version: "0"` until IR lower promotes to `v1`.

## Data flow

```text
TypeScript (Bun test / host)
    │  SvTimingClient.analyze / correct / debugExport
    ▼
Rust CLI (sv-timing-cli)
    │  parse / measure stubs / pass driver / debug_snapshot_pass
    ▼
JSON files under .sv-timing-out/
    │
    ▼
Typed DTOs in TS (ast, edits, debug file list)
```

Post-v1 optional path: Bun `dlopen` FFI loads the same logical objects without changing DTO shapes.

## Running tests

```bash
# From sv-timing/
python tools/svt.py setup && python tools/svt.py build
python tools/svt.py js-test          # bun install (dev) + bun test + typecheck

# Or manually
cd js && bun install && bun test && bun run typecheck
```

## Agent rules

- **All new JS-side code is TypeScript** (`.ts`); do not add `.js` sources.
- Prefer extending `types.ts` + schema when Rust JSON grows.
- Do not add runtime npm dependencies to `js/package.json`.
- Keep connection tests green when changing CLI JSON field names.
