# Coverage completion — table-driven language suites

The next printer or live-test change should add a **row to a table**, not a new named expect per mix. G113 (`EACH_IF_CMP_CASES` + `ComboIfCmp`) is the pattern: one fixture, one case list, IR walks preds, live Flip walks boot/flip counts.

Official AST status stays in [svelte-language-coverage.md](svelte-language-coverage.md). This file is the **completion map** for how we prove it.

## How a suite is done

A suite is done when all four hold:

1. **Fixture** — one `.svelte` (or a named region of ComboNest) that enumerates the cases.
2. **Table** — `packages/svelte-kit-d/test/<suite>-cases.ts` with `id`, IR needles, `boot`, `flip` (or the action that applies).
3. **IR loop** — `dom.test.ts` `for (const c of TABLE)` on the printed `.d`.
4. **Live loop** — `lang-features.test.ts` counts `.fixture .id` at boot and after one host action; DevTools must stay clean.

No new `okRow`/`pickRow` fields. Snapshot a `Record<string, number>` from class prefixes (`ifcmp-`, `ifbool-`, `ifhost-`).

## Ten suites (completion order)

| # | Suite | Status | Fixture | Table | What “done” means |
|---|---|---|---|---|---|
| 1 | **Each-if bool** | **green (G114)** | ComboNest (existing lists) | `if-bool-cases.ts` | G95–G104 + G109–G112 boot/flip in one loop |
| 2 | **Each-if cmp** | **green (G113)** | `ComboIfCmp` | `if-cmp-cases.ts` | ops, host-first, `!on`, rhs≠0 |
| 3 | **Host `{#if}`** | **green (G115)** | `ComboIfHost` | `if-host-cases.ts` | `on`, `!on`, `&&`, `\|\|`, `n > 0`, `who == extra`, `on && !hide` |
| 4 | **Each else / empty** | **green (G116)** | `ComboCover` | `each-else-cases.ts` | empty host array, wipe to `[]`, `<ul>{#each}{:else}` Empty inside `ul`, undeclared seed |
| 5 | **Await** | **green (G116)** | `ComboCover` + ComboExpr/ComboOr | `await-cases.ts` | pending first, `wireAwait` then, no-job then, catch `{e}` |
| 6 | **Bind** | **green (G116)** | `ComboCover` | `bind-cases.ts` | value/group/checked/open/files; Flip or input writes host back |
| 7 | **Directives** | **green (G117)** | `ComboSurf` + ComboCss/Form/Next | `directive-cases.ts` | `class:`, `style:`, `on:\|mod`, `{...spread}`, `use:` |
| 8 | **Special elements** | **green (G117)** | `ComboSurf` + ComboNext/Wide/More | `special-cases.ts` | `svelte:element` static+dynamic, fragment, component, window/document/body |
| 9 | **Boundary / EH** | **green (G117)** | `ComboSurf` + ComboMedia | `boundary-cases.ts` | fail snippet, `throwBoundary`, Retry remounts Ok |
| 10 | **Cmp leftovers** | **green (G118)** | rows on `ComboIfCmp` | same `if-cmp-cases.ts` | `!(n > 0)`, empty `{#each}`, `n > lim` (item vs host) |

Seams stay out of these tables: Pegged mixin stack, named `[...rest]`, Binaryen asyncify on wasm-eh. Yield protocol is [AGENTS-D-IR-asyncify-wasm-eh.md](AGENTS-D-IR-asyncify-wasm-eh.md).

## Completion sequence (remaining)

Do these in order. Each row is one turn unless the printer already prints the pred.

The ten-suite map is closed. A new printer pred is a new row on an existing table, not a new suite.

## Batch rule

One turn implements **one suite** (or several rows on an existing table). Do not add a thirteenth ComboNest list with six one-off expects. If the printer cannot express a row, the table records `skip: 'printer'` and the suite stays open.

## Live contract

`lang-features.test.ts` remains the single Chrome/DevTools soak. New suites hook there as `if (page.$('.combo-if-host')) { … table … }`. `ensureWasm` does not rebuild; run `svelte-d wasm` after dest changes.

## Loci

`packages/svelte-kit-d/test/if-cmp-cases.ts` — first table  
`packages/svelte-d-kit-admin/src/devtools-sink.ts` — `ifCmp` / `nestRow` / `ifHost` records  
`packages/svelte-d-kit-admin/test/lang-features.test.ts` — live loops  
`packages/svelte-kit-d/test/dom.test.ts` — IR loops  
