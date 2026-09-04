# Open questions

Closing one is a note edit plus, if it affects a Key Decision, an edit to the long-form design doc.

## Closed by owner (2026-08-14)

- **Track** `riscv-dev/svelte-D/` as host LibreCore docs, **tier T / MIT**. Do **not** add `/svelte-D/` to `.gitignore`. Owner `git add`s later. This pass does not edit `.gitignore` or `AGENTS-todo.md`.
- **Default wasm cell = LDC 1.36 + asyncify** (`subConfiguration "libwasm" "ldc-1.36"`). Confirms K10. 1.42 stays a named alternate.
- **Capacitor / mobile is out of scope for v1.** SPA adapter output may still be fed to Capacitor later.
- **IR/D cache v1 = JSON files** under `<app>/.svelte-d/`, not SQLite. Confirms K6.

## Closed in the 2026-08-14 review pass

- **Package location (was #2):** `riscv-dev/svelte-D/packages/svelte-d/` (K15). Sibling `svelte-d/` rejected (Windows case-fold).
- **Svelte parse API (was #3):** `svelte` 5.x, `parse({ modern: true })`, no `analyze`, `compile({ generate: false })` diagnostics only (K16).
- **v1 language subset (was #4 in part):** reject-by-default list in the canonical design. `$props` is still out of v1. `{#await}` / `{#key}` / `<svelte:*>` / `$derived` / `$effect` are printed. `$state` scalars/`string[]` only.
- **Universal `load` (was #5):** forbid in v1.
- **Copied vs live slideshow3dai fixture:** copied `packages/svelte-d/fixtures/slideshow-app/`.
- **Incrementality:** reprint-skip + opposite-cell-skip + skip-fresh-wasm (G80). Per-`.o` wasm on the default cell (G107: `.svelte-d/o/` + `ldc2 -c` dirty `src-d` + relink libwasm `.a`). LTO cells still whole-program `dub`.

## Closed in the 2026-08-15 G125 / G126 pass

- **D ↔ TS crossing:** Lodash `callTs` / `callTsPromise` on `window.__svelteD.ts`; inverse `exportDelegate` + `setDRet`. Not a second FFI. [cross-calling.md](cross-calling.md).
- **Helper rewrite on splice:** `$lib` → `helpers/lib/…`; relative → dest helper; `.svelte` → `./<ident>.ts`. Closed the extensions.md open question.
- **dest npm fall-through:** declared range + **copy** of the project’s `node_modules/<pkg>` + dest `bun install` if missing. `file:` relativePath between two `node_modules` rejected (wrong path + bun EPERM).
- **Optional args:** variadic `ARGS...` thunks; omitted trailing parameters keep the callee default.

## Language and IR

1. `PassthroughD` import graph: regex vs D parser.
2. Whether `generated/**/*.d` is committable in apps. Recommendation: fixtures yes, apps no.
2a. Whether svelte-d **auto-inserts** `ScopedPool(m_pool)` around printed `@connect` / list helpers, or only matches goldens until a printer arm (v1: document in [AGENTS-D-IR-memory-management.md](AGENTS-D-IR-memory-management.md)). Whether `_d_newarray*` should prefer `PoolStack` is a libwasm seam.
2b. How printed structs hang under `Spa!App` (patch `@child` into golden `app.d` vs generated mixin). Whether children `@inject!"m_pool"`. `propagateOnUnmount` child walk is a libwasm seam ([AGENTS-D-IR-lifetime.md](AGENTS-D-IR-lifetime.md)).

## Runtimes (unverified facts — do not treat as closed)

5. vibe.0 `dub build` **has not been green** on this host (abs `libs-windows-*`, patched OpenSSL, Botan).
6. LDC 1.43 + **stock** Binaryen 123/132 `--asyncify` **fails** (`try_table` / Flatten.cpp UNREACHABLE). The etcimon fork (`binaryen/` `svelte-d`, tag `svelte-d-v0.2.0`) Flattens `try_table` and asyncifies kit-admin; EH probes stay 1. Setup pulls those `wasm-opt` triples from `wasm-opt-binaries` / the rolling release. Official 123/132 remain the `-Oz` fallback. See [AGENTS-D-IR-asyncify-wasm-eh.md](AGENTS-D-IR-asyncify-wasm-eh.md).
7. slideshow3dai `navbar.d` `Exception` + PgLite JSON vs 1.36 `--wasm-enable-eh` untested.
8. libwasm `yarn dev` / full browser cell marked unrun in that clone’s `open-questions.md`.
9. `wasm-opt` 132 vs vendored `asyncify.ts` agreement — slideshow3dai lists this as open; 1.42 cell was validated 2026-08-13.
10. **libwasm note drift** is recorded (spa.d three versions vs overview.md “Exactly 1.36” vs `dub.sdl` default 1.43). Who updates that clone’s notes is a libwasm pass, not svelte-D.
11. `setenv-wasm.ps1` add-local `0.9.0` vs live tag `v0.10.0`. Manifest records both; host-script bump is separate.

## Seams

12. True hydration vs SSR-then-replace. v1 = replace. When to schedule attach-to-DOM?
13. `locals`: fiber-local map vs vibe.0 request field (PR13b). v1 does not lower user `locals` in `load`.
14. Named rest params (`[...rest]`) in both routers.
15. HMR serialization of `List` / `HTMLArray` — **closed (G77)** `:l:N:[{item}…]` in `libwasm/hmr.d`. Existing items do not remount; `@prop` DOM may lag until a later `update`.
16. Prefetch / `goto` / navigation hooks in libwasm.
17. `handleFetch` / `fetch` in `load` — out of v1; vibe.0 client unread.
18. CSRF: generated origin check enough, or a vibe.0 helper?

## Product

3. bun HMR port `3579` vs stay on `3001`.
4. Replace Vite for slideshow3dai in PR11 or sit beside it.
5. Generated `Server` / `serverString` fingerprint.
6. `vibeVersionString` `"0.7.23"` vs git tag `1.2.1` — vibe.0’s question, not svelte-D’s.
7. PgLite / lodash / moment as optional app deps (recommended) vs compiler runtime.

## Analysis that was not done

- Line-walk of vibe.0 `web/web.d` beyond `registerWebInterface` entry, HTTP response write path, `http/client.d` second half, `websockets.d`.
- Line-walk of libwasm `dom.d` render/`update` beyond the UDA names used by slideshow3dai.
- Measuring slideshow3dai wasm/JS gzip sizes (dom-ts and todo-mvc sizes are from libwasm README only).
- Running either `setenv` script or any `dub build` in this design pass.

When a later pass runs a cell, move the fact from this file to the relevant note’s “how it works,” and leave a one-line pointer here.
