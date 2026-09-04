# AST → libwasm D IR — one graph, representative names

The next change that invents a third IR (neither Svelte source nor libwasm structs), or prints `el_0` / `Button3` where the Svelte file had a name, should read this and then stop.

**Guiding construction:** Svelte / SvelteKit syntax is walked into an **AST whose node kinds are the libwasm D IR** already described in [udas.md](udas.md) and [frontend-libwasm.md](frontend-libwasm.md). The printer pretty-prints that AST. It does **not** lower Svelte to a private JSON component model and then invent D. Pegged / the v1 markup scan and libdparse are *front ends* onto the same graph. `svelte-engine-ws/src-d/` must stay **representative** of the Svelte that produced it: same kit path, same module/struct/variable names (D-legal), so a reader can go `ClickField.svelte` → `src-d/lib/ClickField.d` / `struct ClickField` / `go` / `msg` without a lookup table.

```
.svelte (kit path, names)
    │  Pegged / markup scan + libdparse
    ▼
AST ≡ libwasm D IR
    Element      → mixin NodeDef!"tag"  (NamedNode / TagHtmlElementMap)
    @child nest  → @child Field
    {ident}      → @prop on that NamedNode (name = ident)
    on:click={h} → Slot + @callback!"click" + @connect!"hButton.click"
    {#each xs}   → UnorderedList!X + HTMLArray + ArrayItemEvents
    {#if ident}  → @visible!"child" bool ident + remount/unmount (same @child)
    lang=d proc  → methods / fields on the same struct (sparse Lodash / moment / bindings)
                   heavy arms: ScopedPool + copy-out / freeze  (see AGENTS-D-IR-memory-management.md)
    +page.server → vibe.0 (host cell)
    │  pretty-print
    ▼
svelte-engine-ws/src-d/…   names and folders still read as the Svelte
```

JSON under `ws/.svelte-d/ir/` is a **cache key** of those AST nodes, not a second language.

## Sparse procedural surface (Lodash / moment / bindings)

The **structure** of the UI is NodeDef / `@child` / `@prop` / `@callback` / `@connect` / `@inject` / `UnorderedList`. That is what `compile!()` walks.

Lodash, moment, and `libwasm.bindings` appear only in **procedural** arms — a `void go()` body, a `load` helper, a PgLite query — when the script already wrote that libwasm D. They are not the component model. Do not print a `Lodash` chain to represent a `<button>`. Do not wrap a `{#each}` in `_.map`. Bindings (`document()`, `window()`) stay Handle-table calls inside methods. See [libwasm-js.md](libwasm-js.md). Those arms **allocate**: wrap them in `ScopedPool`, copy survivors onto the struct / `Array`, or `freeze`/`unfreeze`. See [AGENTS-D-IR-memory-management.md](AGENTS-D-IR-memory-management.md).

## Naming equivalence

| Svelte | D in svelte-engine-ws |
|---|---|
| `src-svelte/lib/ClickField.svelte` | `src-d/lib/ClickField.d`, `module lib.ClickField`, `struct ClickField` |
| `src-svelte/routes/+page.svelte` | `src-d/routes/page.d`, `struct` from the route folder (kit `+` is not a D identifier) |
| `src-svelte/routes/[slug]/+page.svelte` | `src-d/routes/_slug_/page.d`, module `routes._slug_.page` (dest dirs cannot keep `[` — LDC Windows globMatch) |
| `on:click={go}` | `@child GoButton goButton`; `@connect!"goButton.click"` calls `go()` |
| `{msg}` | parent field `msg` (from lang=d) + child `MsgSpan` `@prop textContent` |
| `{#each items as item}` | `@child UnorderedList!Item items`; item struct named from the **alias** |
| `+page.server.d` | `webserver/source/generated/routes/page_server.d` |

D-legal sanitizing is allowed only where the language forbids a character (`+`, `[`, `-`). Do not lowercase a whole file to invent `clickfield.d`. Do not number anonymous widgets (`Button0`) when a handler or mustache name exists.

`lang="d"` identifiers (`go`, `pick`, `msg`) are **kept**. The printer adds wiring (`goButton`, `@connect`) around them; it does not rename the author’s methods.

## Loci

`packages/svelte-d/source/svelte_d/parse/markup.d` — v1 AST (until Pegged `asModule`)  
`packages/svelte-d/source/svelte_d/print/dom_print.d` — pretty-print to NodeDef IR  
`packages/svelte-d/source/svelte_d/fallthrough.d` — kit path → dest path (names preserved)  
[udas.md](udas.md) — compile! / connect / inject / NamedNode  
[AGENTS-D-IR-memory-management.md](AGENTS-D-IR-memory-management.md) — ScopedPool precedence, copy-out, freeze  
[AGENTS-D-IR-lifetime.md](AGENTS-D-IR-lifetime.md) — `construct` / `onMount` / `ready` / hang under `Spa!App`  
[ir.md](ir.md) — cache / hash of these nodes  

## Invariants

- The AST’s structural kinds are libwasm’s (`Element`/`NodeDef`, `EachBlock`/`UnorderedList`, `IfBlock`/`@visible`, `Slot`, `Connect`, `Inject`). A kind that cannot be `compile!()`’d is a diagnostic, not a JS fallback. (construction)
- Lodash / moment / bindings are procedural, not structural. (construction)
- Printed module, struct, and author-facing variable names are a D-legal spelling of the Svelte names. (construction of representativeness)
- Golden `src-d/app.d` / `dock.d` / `navbar.d` stay the Spa root; printed files sit beside them at fall-through paths and hang as `@child` of `App`. (construction; [AGENTS-D-IR-lifetime.md](AGENTS-D-IR-lifetime.md))

## Extension points

Pegged `asModule` replaces `markup.d` **in place** — same AST kinds, same printer. A new Svelte construct is a new AST kind that already has a libwasm UDA (or a titled seam).

## Did not close

Whether `+page.svelte`’s struct is `Page` or the parent folder name (`Home`, `Slug`). v1: `Page` at `routes/page.d`, folder kept on disk. Whether Windows case-fold requires a second `clickfield.d` alias (no — one `ClickField.d`).
