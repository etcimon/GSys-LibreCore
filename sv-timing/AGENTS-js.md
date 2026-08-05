# AGENTS-js — TypeScript Bun package (`js/`)

> Companion to [`AGENTS.md`](AGENTS.md). Detail: [`architecture/JS-TYPESCRIPT.md`](architecture/JS-TYPESCRIPT.md).

## Role

`sv-timing/js` is the **TypeScript** client and integration-test project for:

- Exported AST / analyze JSON  
- Debug export bundles  
- Auto-correct dry-run / emit JSON  

It is **not** a monorepo build-platform dependency. Hosts may path-import or copy types.

## Commands

```bash
python tools/svt.py js-test    # preferred
# equivalent:
cd js && bun install && bun run typecheck && bun test
```

## When editing

| Change | Update |
|---|---|
| CLI JSON fields | `js/src/types.ts` + `schemas/*.json` + connection tests |
| New CLI subcommand | `SvTimingClient` method + test |
| DTO only | Keep runtime deps at zero |

## Invariants

1. Sources are **TypeScript** (`.ts`) only under `js/src` and `js/test`.
2. Zero **runtime** npm dependencies.
3. Client must not reimplement FO4 / parse — only CLI/FFI.
4. Log progress in `AGENTS-todo.md`.
