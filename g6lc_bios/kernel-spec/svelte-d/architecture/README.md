# svelte-D architecture notes

Each note is addressed to the **next change**. They assume the reader will open the cited files; they do not restate the full design doc.

```
draft:          2026-08-14
runtimes:       libwasm live HEAD 64a97ce / v0.10.0 (AGENTS.md header 02f21a6 lags; setenv-wasm add-local 0.9.0);
                vibe.0 eb51b27 / v1.2.1 (matches);
                slideshow3dai worktree files (no .git; AGENTS.md 0b130ee unverifiable)
cells:          wasm = setenv-wasm.ps1 / LDC 1.36; host = setenv.ps1 / LDC 1.42
unverified:     vibe.0 green; LDC 1.43 + Binaryen 132 asyncify
```

| Note | Next change it is for |
|---|---|
| [overview.md](overview.md) | Anyone about to add a pipeline stage or a third cell |
| [ir.md](ir.md) | IR schema, hasher, cache directory, invalidation |
| [ast-ir.md](ast-ir.md) | Svelte AST ≡ libwasm D IR; sparse Lodash/bindings; representative names |
| [AGENTS-D-IR-memory-management.md](AGENTS-D-IR-memory-management.md) | memutils + libwasm fall-through; ScopedPool precedence; copy-out / freeze |
| [AGENTS-D-IR-lifetime.md](AGENTS-D-IR-lifetime.md) | compile! / Spa hooks: construct, onMount, ready, unmount; hang under App |
| [AGENTS-D-IR-asyncify-wasm-eh.md](AGENTS-D-IR-asyncify-wasm-eh.md) | asyncify vs wasm-eh; LDC/Binaryen catch breakage; no `.await` on EH cell |
| [frontend-libwasm.md](frontend-libwasm.md) | Client printer, glue templates, router subset |
| [udas.md](udas.md) | NodeDef → NamedNode, @prop/@attr, @connect/@inject paths, compile! / detach, HTMLArray |
| [svelte-language-coverage.md](svelte-language-coverage.md) | Official Svelte AST (`svelte-ref-impl`) → svelte-d / libwasm status |
| [coverage-plan.md](coverage-plan.md) | Table-driven live/IR suites; when a language family is done |
| [libwasm-js.md](libwasm-js.md) | Lodash / Moment / bindings as the svelte→D JS surface |
| [backend-vibe0.md](backend-vibe0.md) | Server printer, SSR string builders, URLRouter lowering |
| [compiler-host.md](compiler-host.md) | svelte-d (D) + svelte-kit-d (bun), manifest, cells |
| [package.md](package.md) | Repo-root bun package; `bun install` builds the CLI; SvelteKit include |
| [engine-setup.md](engine-setup.md) | LDC 1.43 for svelte-engine-ws wasm; never host 1.42 |
| [extensions.md](extensions.md) | npm Svelte packages, SCSS/jQuery, `<script lang="ts">` splice |
| [cross-calling.md](cross-calling.md) | lang=d ↔ lang=ts via Lodash `callTs` / `exportDelegate`; dest npm copy |
| [pegged-grammar.md](pegged-grammar.md) | Pegged Svelte grammar; libdparse; serve-d |
| [fallthrough.md](fallthrough.md) | **Guiding principle:** kit syntax → equivalent libwasm/vibe.0 tree in the ws |
| [bootstrap.md](bootstrap.md) | **Guiding principle:** accommodate kit features in svelte-engine / libwasm / vibe.0; compile integrates the engine |
| [workspace.md](workspace.md) | svelte-engine template vs svelte-engine-ws drop |
| [hmr-debug.md](hmr-debug.md) | WS protocol, dumpApp/loadApp limits, maps, overlay, Trace |
| [admin-debug.md](admin-debug.md) | Admin kit tree, debug-map, Puppeteer rewrite, vibe.0 PG/Redis/JSON |
| [sveltekit-feature-map.md](sveltekit-feature-map.md) | Claiming or implementing a SvelteKit feature |
| [licensing.md](licensing.md) | Copying glue, emitting NOTICE, adding a dependency |
| [development.md](development.md) | Choosing the next phase / green command |
| [slideshow3dai-reference.md](slideshow3dai-reference.md) | Touching the golden fixture or “rewriting” that app |
| [open-questions.md](open-questions.md) | Closing or adding an unknown |
| [pr-plan.md](pr-plan.md) | Opening a PR |

## How a note is built

Prose first (how control actually moves). Then **Loci** into existing trees. Then **Invariants** tagged *construction* (the compiler or runtime will not elaborate if broken) or *convention* (silent if broken). Then **Extension points**. Then **Did not close**.
