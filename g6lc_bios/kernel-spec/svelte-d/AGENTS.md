# svelte-D — Agent Guider

```
id: svelte-D
kind: original-design-workspace
purpose: SvelteKit-class D/vibe.0 compiler → Pegged IR → svelte-engine-ws → libwasm and/or vibe.0
status: Draft 2026-08-14 (D host)
green_command: bun install && bun test && bunx svelte-d version
does_not_change: slideshow3dai, LDC
seams_only: libwasm, vibe.0 (titled floor tags only: libwasm >=0.11.1, vibe-0 >=1.2.2, memutils >=1.0.12)
host_policy: tracked tier-T MIT (owner 2026-08-14); do not add /svelte-D/ to ../.gitignore; do not silently edit ../.gitignore or ../AGENTS-todo.md
```

**Is:** architecture notes + the **`svelte-d` bun package at this repo root** (D compiler under `packages/svelte-d/`: vibe.0 + Pegged + libdparse). `bun install` / `bun run build` produces the native CLI; `import … from 'svelte-d'` works in a SvelteKit bun project.  
**Is not:** a Svelte-to-JS wrapper, a second DOM/HTTP stack, or a sibling `../svelte-d/` directory.

**Guiding principles:**

1. **Fall-through.** Svelte / SvelteKit syntax in a svelte-d + bun project **falls through** to the corresponding **libwasm** / **vibe.0** equivalent in a **roughly equivalent structure** inside `svelte-engine-ws`. See [`architecture/fallthrough.md`](architecture/fallthrough.md).
2. **Accommodate in the engine.** All Svelte / SvelteKit syntactic and underlying features — and further development of them — are **accommodated by changes in `svelte-engine` / libwasm / vibe.0**. svelte-d does not grow a third runtime. An updated `svelte-engine` is **integrated as `svelte-engine-ws` at compile time** in the D IR format that engine already builds. bun + TS + svelte-d tests and projects are the proof surface. See [`architecture/bootstrap.md`](architecture/bootstrap.md).
3. **AST ≡ libwasm D IR.** Svelte is walked into an AST whose kinds **are** NodeDef / `@child` / `@prop` / Slot / `@connect` / `@inject` / `UnorderedList`. The printer pretty-prints that graph. Lodash / moment / bindings are **sparse procedural** leaves. Printed module, struct, and author names stay **representative** of the Svelte (`ClickField.svelte` → `struct ClickField`). See [`architecture/ast-ir.md`](architecture/ast-ir.md).
4. **Scoped pool precedence.** Printed D allocation falls through to `libwasm/rt/memory.d` / `rt/allocator.d`. A live `ScopedPool` is the precedent allocator for `alloc` / `_d_allocmemory` / `allocString`. Heavy methods are scoped; survivors are copied into `compile!()` fields or ThreadMem containers, or the pool is `freeze`/`unfreeze`. Language `new` never joins the pool. See [`architecture/AGENTS-D-IR-memory-management.md`](architecture/AGENTS-D-IR-memory-management.md).
5. **Spa / compile! lifetime.** The D IR uses libwasm’s built-in methods — `construct` (post-inject, pre-handle), `onMount` / `onUnmount`, App `ready` / optional `main`, `this.update`, `unmount` / `remount`. One `mixin Spa!App`; printed structs hang as `@child`. See [`architecture/AGENTS-D-IR-lifetime.md`](architecture/AGENTS-D-IR-lifetime.md).

Canonical long-form design (Key Decisions, alternatives, security, full PR plan): the design-pass document this folder was split from. If the two disagree, **update this folder** — it is the living surface.

## Navigate by intent

| If the next change is about… | Open |
|---|---|
| Human docs site (Svelte → D IR, admin example) | [`docs/`](docs/) |
| What svelte-D is / is not / host git policy | [`README.md`](README.md) |
| bun package, CLI build, include in a SvelteKit app | [`architecture/package.md`](architecture/package.md), [`README.md`](README.md) |
| One LDC 1.43 (CLI + vibe.0 + wasm) on Windows/macOS/Linux | [`architecture/engine-setup.md`](architecture/engine-setup.md) |
| Third-party Svelte / SCSS / jQuery / lang=ts splice | [`architecture/extensions.md`](architecture/extensions.md) |
| lang=d ↔ lang=ts calling; dest npm fall-through | [`architecture/cross-calling.md`](architecture/cross-calling.md) |
| License of this work **and** of D/LDC/libwasm/vibe.0/Svelte/Binaryen/asyncify | [`LICENSE.md`](LICENSE.md), [`architecture/licensing.md`](architecture/licensing.md) |
| End-to-end compile + runtime journey | [`architecture/overview.md`](architecture/overview.md) |
| IR, hashes, `.svelte-d/` cache, incremental cones | [`architecture/ir.md`](architecture/ir.md) |
| Svelte AST ≡ libwasm D IR; representative names | [`architecture/ast-ir.md`](architecture/ast-ir.md) |
| Official `.svelte` AST coverage (svelte-ref-impl) | [`architecture/svelte-language-coverage.md`](architecture/svelte-language-coverage.md) |
| memutils + libwasm pools; ScopedPool / freeze / copy-out | [`architecture/AGENTS-D-IR-memory-management.md`](architecture/AGENTS-D-IR-memory-management.md) |
| compile! / Spa lifetime hooks; hang printed structs under App | [`architecture/AGENTS-D-IR-lifetime.md`](architecture/AGENTS-D-IR-lifetime.md) |
| asyncify vs wasm-eh; `.await` vs D catch | [`architecture/AGENTS-D-IR-asyncify-wasm-eh.md`](architecture/AGENTS-D-IR-asyncify-wasm-eh.md) |
| Kit path → equivalent ws cell (guiding principle) | [`architecture/fallthrough.md`](architecture/fallthrough.md) |
| Accommodate features in engine/libwasm/vibe.0; compile-time bootstrap | [`architecture/bootstrap.md`](architecture/bootstrap.md) |
| Mapping Svelte client features onto libwasm | [`architecture/frontend-libwasm.md`](architecture/frontend-libwasm.md) |
| NodeDef / NamedNode / @connect / @inject / compile!() | [`architecture/udas.md`](architecture/udas.md) |
| Lodash / Moment / WebIDL bindings in printed D | [`architecture/libwasm-js.md`](architecture/libwasm-js.md) |
| Mapping SvelteKit server features onto vibe.0 | [`architecture/backend-vibe0.md`](architecture/backend-vibe0.md) |
| D/vibe.0 host, file graph, manifest, two cells | [`architecture/compiler-host.md`](architecture/compiler-host.md) |
| Pegged Svelte grammar (webidl analogy) | [`architecture/pegged-grammar.md`](architecture/pegged-grammar.md) |
| svelte-engine template vs svelte-engine-ws drop | [`architecture/workspace.md`](architecture/workspace.md) |
| dumpApp/loadApp, maps, overlay, `mixin(Trace)` | [`architecture/hmr-debug.md`](architecture/hmr-debug.md) |
| Exhaustive SvelteKit feature statuses | [`architecture/sveltekit-feature-map.md`](architecture/sveltekit-feature-map.md) |
| Phased program / one-thesis passes | [`architecture/development.md`](architecture/development.md) |
| What slideshow3dai already proves | [`architecture/slideshow3dai-reference.md`](architecture/slideshow3dai-reference.md) |
| Unclosed questions | [`architecture/open-questions.md`](architecture/open-questions.md) |
| Independently reviewable PRs | [`architecture/pr-plan.md`](architecture/pr-plan.md) |

## Invariants (this folder)

- Do not edit libwasm, vibe.0, slideshow3dai, or LDC from a svelte-D pass unless the PR is an explicitly titled **seam** against that tree. **svelte-engine may be updated** — that is how a new kit feature is accommodated. The next compile integrates it as `svelte-engine-ws`.
- Do not claim a SvelteKit feature works if the feature map marks a seam or out-of-scope.
- One LDC 1.43+ for CLI, vibe.0, and wasm. Wasm vs host stay different *targets* (no shared objects / `DFLAGS`).
- Notes stay specific: cite `file:line` in the existing trees. If unverified (vibe.0 green, 1.43 asyncify), say so.
- Construction vs convention: if the next change can break it silently, write which one it is.
- Kit syntax falls through to libwasm / vibe.0 in an equivalent `svelte-engine-ws` tree. Do not invent a third layout.
- Kit features are accommodated in svelte-engine / libwasm / vibe.0. svelte-d only prints that D IR. Compile integrates the engine as the ws bootstrap.
- Printed wasm D is pool-correct: `ScopedPool` precedes `alloc`/`_d_allocmemory`/`allocString`; language `new` is bump-only; survivors are copied off the pool or allocated after `freeze`.
- Printed D uses libwasm lifetime hooks (`construct` / `onMount` / `onUnmount` / App `ready`). One `Spa!App`. No Svelte JS `onMount`.
- Stock Binaryen 123/132 cannot `--asyncify` `try_table`. The **etcimon/binaryen** fork (`binaryen/`, branch `svelte-d`) Flattens and asyncifies LDC wasm-eh. CI publishes those `wasm-opt` triples; `bunx svelte-d setup` downloads them into `binaryen-build/` like LDC 1.43. `run-probes.mjs` must keep `svelte_engine_eh_probe == 1` on that ship module. Printed EH IR is same-function `try`/`catch` (`throwBoundary`). `{#await}` `.await` must not be wrapped in `try`; catch is `libwasmAwaitFailed()` after rewind, and `{:catch e}` is filled from `libwasmAwaitError()`.

## Next change

Queue: [`AGENTS-todo.md`](AGENTS-todo.md). Coverage suites 1–10 green. Next printer pred is a row on an existing table.
