# Pegged grammar — Svelte / SvelteKit, same split as libwasm webidl

The next change that adds a Svelte syntax production or “just calls `svelte/compiler` from Node” should read this and then not add a JS parse dependency.

libwasm already owns this pattern. `webidl/webidl-grammar/generator/source/app.d` feeds a PEG string to Pegged `asModule("webidl.grammar", "../source/webidl/grammar", …)`. The generated module is a D library (`webidl-grammar/dub.sdl`, Pegged `~>0.4.4`, Boost). `webidl/source/app.d` walks `ParseTree` in `webidl.binding.generator` and **prints D + JS**. svelte-d does the same thing for `.svelte` / SvelteKit **file contents**, then prints libwasm D into `svelte-engine-ws`.

**Pegged (Boost) is the parser-development framework.** It is a DUB dependency of the **compiler** (host cell), never of the wasm cell. Do not vendor `svelte/compiler` (K16 is superseded). A JS parse would put the compiler back on bun/Node; this pass is a D program.

## Two grammars, two walkers

| Input | Parser | Why |
|---|---|---|
| `.svelte`, `<script lang="d">` **markup** / `{#if}` / `{#each}` / `on:` / `{ident}` | Pegged `SvelteKit:` in `packages/svelte-d/grammar/sveltekit.peg` (mixin or `asModule`, same as WebIDL) | Svelte is not D. Pegged is how this repo already turns a published grammar into a `ParseTree`. |
| `<script lang="d">` **body**, `+page.server.d`, `+server.d`, `src-d/**/*.d` | **libdparse** (Boost 1.0, dlang-community) | D already has a lexer/parser. Do not write a Pegged D grammar. |
| IDE / outline / diagnostics on those D files | **serve-d** (MIT, Pure-D) | Language server that already sits on libdparse + D-Scanner + dfmt. **Not** a compile-time dependency of svelte-d. Point the workspace `svelte-engine-ws` at serve-d; do not link serve-d into the compiler. |

SvelteKit **routing** is not a PEG. It is a filesystem walk of `src-svelte/routes/` (`+page.svelte`, `+layout.svelte`, `+page.server.d`, `+server.d`, `(groups)`, `[param]`, `[...rest]`). Pegged parses **each file**; kit-fs assigns `Route` / `Layout` / `Endpoint` IR nodes.

## WebIDL analogy (do not invent a third pattern)

```
webidl-grammar/generator  asModule  →  source/webidl/grammar.d
webidl/source/app.d       ParseTree →  D bindings + JS glue

svelte-d/grammar/sveltekit.peg  asModule/mixin →  svelte_d.grammar.sveltekit
svelte-d parse + print          ParseTree      →  svelte-engine-ws/src-d/*.d
```

`grammar/generator/app.d` runs Pegged `asModule!(Memoization.no)` → `source/svelte_d/grammar/sveltekit.d`. **Do not `mixin(grammar)`** — that overflowed LDC 1.42 + Pegged 0.4.9. `Spacing` must be `<-` (not `<`) or Pegged wrapAround left-recurses and overflows at runtime. `SvelteKit.Document(src)` is the file start rule; `SvelteKit.MarkupDoc` is the markup start rule. `parse/markup.d` `unwrapRule` peels `or!`/`and!`/`wrapAround` until a `SvelteKit.*` name with no `!`. Attr `{go}` must not become a text child. `parseMarkupEx` tries MarkupDoc first and names the outcome: `pegged` when the walker is enough; `scan-thin` / `scan-else` / `scan-construct` / `scan-fail` when the scan path fills in. Printed IR carries `parse=` on the file `//# svelte-d-ir` line. Scan is not silent.

## v1 productions (reject-by-default)

The PEG must accept the svelte-engine examples (`src-svelte/routes/+page.svelte`, `src-svelte/lib/Dock.svelte`) and reject everything else with a named production. Minimum:

- `Document` = optional `ScriptBlock` + optional `StyleBlock` + `Markup`
- `ScriptBlock` = `<script` attrs `>` body `</script>`; require `lang="d"` or fail
- `StyleBlock` = `<style>` … `</style>` → IR `Style` → `@styleset` / `addCss`
- `Element` = tag, attrs (`class`, `id`, `on:click={ident}`, `bind:value={ident}`), children
- `Mustache` = `{ident}` only (no `{@html}`, no `{#await}`)
- `{#if ident}` / `{#each ident}` as named blocks
- HTML comments

`on:click={() => …}` is **out**. Handlers are D identifiers (Dock.svelte `on:click={onHome}`).

After Pegged succeeds, libdparse runs on `ScriptBody`. Failed D parse is a compiler diagnostic with file:line from the script offset, not a Pegged failure.

libdparse will see `moment`, `Lodash`, `Document`, `fetch` as ordinary D identifiers. The **subset checker** (not the PEG) requires those names to resolve to `libwasm.moment` / `libwasm.lodash` / `libwasm.bindings.*` when the file is wasm-cell. See [libwasm-js.md](libwasm-js.md).

## Loci

`libwasm/webidl/webidl-grammar/README.md` — Pegged WebIDL  
`libwasm/webidl/webidl-grammar/generator/source/app.d:1-8` — `asModule`  
`libwasm/webidl/dub.sdl:7-8` — pegged 0.4.4  
`libwasm/webidl/source/app.d:113-120` — read definitions → IR  
`libwasm/webidl/source/webidl/binding/generator.d:1-5` — `ParseTree` walker  
`packages/svelte-d/grammar/sveltekit.peg` — svelte-d grammar (this tree)  
`../svelte-engine/src-svelte/` — first golden inputs  
`../svelte-engine/architecture/script-lang-d.md` — inference table the walker must implement  

## Invariants

- Pegged and libdparse are **host-cell** DUB deps of `svelte-d`. They never appear in `svelte-engine-ws` wasm `dub.sdl`. (construction)
- serve-d is not a DUB dependency of svelte-d. (construction)
- `lang` other than `d` is a hard fail. (construction of script-lang-d)
- Grammar changes bump `SCHEMA_VERSION` / `PRINTER_VERSION` the same way an IR node kind does. (construction)

## Extension points

New Svelte syntax → production in `sveltekit.peg` + walker arm + fixture, or a diagnostic. New D syntax in scripts → libdparse already accepts it; the **subset checker** (not the parser) rejects what the printer cannot emit. Generating `grammar.d` via `asModule` belongs in `grammar/generator` when mixin time is a problem.

## Did not close

Whether to pin Pegged `0.4.4` (webidl) or current `~>0.4.9`. Recommendation: `~>0.4.4` until a parse mismatch is shown. Exact Svelte 5 rune tokens in the PEG (v1 still rejects `$derived` / `$effect` in the subset checker even if libdparse sees them as D).
