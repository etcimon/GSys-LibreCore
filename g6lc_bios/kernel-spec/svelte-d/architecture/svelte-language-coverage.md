# Svelte language coverage — official AST → svelte-d / libwasm

The next change that claims a `.svelte` construct is implemented updates this table in the same PR. The **spec of record for what a `.svelte` file may contain** is the official compiler AST in the reference checkout:

`riscv-compilers/svelte-ref-impl/packages/svelte/src/compiler/types/template.d.ts`

That tree is a **clone of https://github.com/sveltejs/svelte** (shallow `main` at `221dcae`). It is **not** linked, imported, or executed by svelte-d. Host git already ignores `/riscv-compilers/*/`. svelte-d still does **not** parse with `svelte/compiler`; Pegged `SvelteKit.Document` + the markup scan lower onto the **same** libwasm D IR ([ast-ir.md](ast-ir.md)). The clone is how we know the feature set is complete rather than guessed.

Statuses match [sveltekit-feature-map.md](sveltekit-feature-map.md):

| Status | Meaning |
|---|---|
| **Printed** | Printer emits a libwasm / vibe.0 construct; fixture exists |
| **Partial** | Some shapes print; listed gap is honest |
| **Mapped** | libwasm/vibe.0 idiom exists; printer arm not done |
| **Seam** | Needs a titled libwasm or vibe.0 change first |
| **Yield** | wasm-eh vs asyncify; see [AGENTS-D-IR-asyncify-wasm-eh.md](AGENTS-D-IR-asyncify-wasm-eh.md) |
| **Later** | Named, not this cell |

## Root / scripts / style (`AST.Root`)

| Official node | Svelte syntax | svelte-d | Accommodation |
|---|---|---|---|
| `Root.instance` | `<script>` / `<script lang="d">` | Printed | `lang=d` → `src-d`; `extern(C) export` peeled + `exportDelegate` (G125) |
| `Root.module` | `<script context="module" lang="ts">` | Printed | `jsExports` + `__svelteD.ts[<ident>_mod]` in `src-ts/modules/generated/` |
| `Root.css` | `<style>` | Printed | strip the block; `addCss` + `@style!".ident"`; `:global(.wide)` still yields `.wide` |
| `Root.options` | `<svelte:options>` | Printed | `// svelte:options name=value` on the host (`ComboRest.svelte`) |
| `Script` `lang=ts` | instance TS | Printed | splice + `registerTs(ident, name)`; same-file D thunks `callTs` / `callTsPromise`; npm imports fall through (G126) |
| `Script` runes | `$state` / `$derived` / `$effect` / `$props` | Partial | `$state`/`$derived` peel to the inner expr; `$effect` body → `onMount`; `$props` stripped (parent assigns `@child` fields) |

## Text and tags

| Official node | Svelte syntax | svelte-d | Accommodation |
|---|---|---|---|
| `Text` | raw text | Printed | `@prop!"textContent"` |
| `ExpressionTag` | `{ident}` | Printed | child field named `ident`; `construct` seeds `child.ident = ident` (**G85**); `this.update.x` → `child.update.x` |
| `HtmlTag` | `{@html expr}` | Printed | `@prop!"innerHTML"` on a wrapper `div`; `construct` seeds the host expr (`Combo.svelte` `rawHtml.raw = raw`) |
| `Comment` | `<!-- -->` | Printed | skipped |
| `ConstTag` | `{@const x = …}` | Printed | host field (`int`/`bool`/`string`) (`ComboMore.svelte`) |
| `DeclarationTag` | `{let` / `{const` | Printed | same host field as `{@const}` (`ComboRest.svelte`) |
| `DebugTag` | `{@debug x}` | Printed | `console.log("x")` in `onMount` |
| `RenderTag` | `{@render snippet()}` | Printed | walks the snippet body; `pair(who, extra)` assigns each param |
| `AttachTag` | `{@attach …}` | Printed | `onMount` call with `this.node.handle` (`ComboNext.svelte`) |

## Blocks

| Official node | Svelte syntax | svelte-d | Accommodation |
|---|---|---|---|
| `IfBlock` consequent | `{#if cond}` | Printed | `@visible` + `setVisible`; `!cond`; `a && !b`; `(a && b)` / `a \|\| b`; `n > 0`; `who == extra`. Nested inside an element: UDA lives on that struct; flip is `owner.update.cond = cond` (**G83**). Host-root if stays `setVisible!"child"(this, cond)` and assigns `not_cond`. **G78** live Chrome: IfToggle + ComboMore `{#key}` + ComboExpr `a && b` + ComboNest `a && !b`; DevTools rewrite dest→orig |
| `IfBlock` alternate | `{:else}` | **Printed (this pass)** | second `@child` + inverted `setVisible` |
| `IfBlock` elseif | `{:else if}` | Printed | nested `IfBlock` in `elseKids`; multi-child `@visible` |
| `EachBlock` body | `{#each xs as x}` | Printed | `UnorderedList!X` + `put`; `{name}` / `[x, y]` destructure; item template found inside `{#if}`. `{#each}{#if cond}<li>` keeps the `ul` and unmounts each `li` (`sync_items_on`, **G94** ComboNest Flip). `{#each rows as row}{#if row.ok}` puts `bool ok` on the item, seeds first true, `sync_rows_ok` uses `it.ok`, Pin `fill_rows` sets the rest. App `ready` calls `wireEach` after render so the false item is unmounted with live handles (**G95**). `{#if pick.ok && on}` ANDs the item field with a host bool (`sync_picks_on`, Flip hides picks, ok-rows stay) (**G97**). `{#if hold.ok || on}` ORs the same pair (`sync_holds_on`, Flip leaves the first hold) (**G98**). `{#if !skip.ok}` negates the item field (`sync_skips_ok`, first seeded-true is hidden; Skip `fill_skips` clears the rest) (**G99**). `{#if !cut.ok && on}` ANDs that negation with a host bool (`sync_cuts_on`, Flip hides cuts, skip-rows stay) (**G100**). `{#if !keep.ok || on}` ORs the same negation (`sync_keeps_on`, Flip leaves the `!ok` keep) (**G101**). `{#if drop.ok && !on}` negates the host bool (`sync_drops_on`, hidden at boot, Flip shows the first drop) (**G102**). `{#if !both.ok || !on}` negates both sides (`sync_boths_on`, boot shows the `!ok` row, Flip shows both) (**G103**). `{#if !nand.ok && !on}` ANDs both negations (`sync_nands_on`, hidden at boot, Flip shows the `!ok` nand) (**G104**). `{#if hit.n > 0}` puts `int n` on the item, seeds first to `1`, `sync_hits_n` uses `it.n > 0`; Hit `fill_hits` sets the rest (**G109**). `{#if more.n > 0 && on}` ANDs that comparison with a host bool (`sync_mores_on`, Flip hides mores, hit-rows stay) (**G110**). `{#if lot.n > 0 || on}` ORs the same pair (`sync_lots_on`, Flip leaves the first lot) (**G111**). `{#if few.n > 0 && !on}` ANDs the comparison with a negated host bool (`sync_fews_on`, hidden at boot, Flip shows the first few) (**G112**). **G113** covers the next 10 mixes in `ComboIfCmp.svelte` via `EACH_IF_CMP_CASES`: `n > 0`, `n > 0 \|\| !on`, `n == 0`, `n != 0`, `n < 1`, `n <= 0`, `n >= 1`, `n >= 1 && on`, `on && n > 0` (host first), `n > 1`. IR and live Flip walk the table (boot/flip counts, including unseeded-item and rhs≠0 corners). `<ul>{#each}` **absorbs** the wrapper (`UnorderedList` is already `NodeDef!"ul"`). `{#each}` inside a non-`ul` element hangs on that parent |
| `EachBlock` fallback | `{:else}` on each | Printed | `@visible!"empty_*" bool list_empty`. Host `string[] xs;` / `= []` skips `put` and inits `xs_empty = true` (LangCoverage `voids` → `None`). `xs = []` → `shrinkTo(0)` + `setVisible` (**G89** Wipe). `<ul>{#each}{:else}` prints `ExtrasList` (`HTMLArray` + else `@child` + `NodeDef!"ul"`) so Empty hangs **inside** the `ul` (**G90**). Bare `{#each}{:else}` stays `UnorderedList` + sibling else. Undeclared lists still demo-seed (`one`/`two`) |
| `EachBlock` index / key | `(i)` / `(x)` | Printed | index → item field `int i` (not `@prop!"dataset"`; that property is a getter-only DOMStringMap); key → `@attr!"data-key"` |
| `AwaitBlock` | `{#await}` | Printed | pending/then/catch `@visible`; then `{v}` → `@prop` named after the binding. Host `JsPromise` starts pending. App `ready` (after render) calls `wireAwait`: `.await` + `libwasmAwaitFailed()` on the fork, else `job.then` / `.error` (**G93**). `{:catch e}` `{e}` is filled from `libwasmAwaitError()` after rewind; stock `.error` notes the Any handle first (**G121**). `{:then v}` `{v}` is filled from `libwasmAwaitValue()` the same way (**G122**). A second `{#await}` on the same struct keeps its own `await_*_<job>` flags and bind paths (**G123**). Two `{:catch e}{e}` uniquify to `eP` / `eP2` (**G124**). First job still uses `await_then` / `await_catch` so Combo Go/Fail rewrite. `this.update.await_then` still settles (Combo Go). No job: settle to `{:then}` at print time (**G87**). Do not wrap `.await` in `try` |
| `KeyBlock` | `{#key}` | Printed | `remount!"child"(this)` helper (`ComboMore.svelte`) |
| `SnippetBlock` | `{#snippet}` | Printed | stored; instantiated at `{@render}`; multi-param `{#snippet pair(a, b)}` |

## Elements and components

| Official node | Svelte syntax | svelte-d | Accommodation |
|---|---|---|---|
| `RegularElement` | `<div>` / `<button>` | Printed | `mixin NodeDef!"tag"`; **nested `@child`** on the parent element (`<option>` under `<select>`, table rows under `<table>`). `{#if}`/`{#await}` kids hang on that parent (`@visible` + `setVisible(owner)`); `<ul>{#each}` absorbs as `UnorderedList`. SVG/media; MathML (`math`/`mi`); `dialog`/`audio`/`progress`/`canvas`/`iframe`; custom `my-widget` |
| `Component` | `<ClickField>` | Printed | PascalCase → `import lib.ClickField;` + `@child ClickField clickField` |
| `SlotElement` | `<slot>` | Printed | `mixin Slot!("name")` + fallback; named `<slot name="aside">` (`ComboOr.svelte`) |
| `TitleElement` | `<title>` | Printed | `document().title("…")` in `onMount` (handle 1) |
| `SvelteHead` | `<svelte:head>` | Printed | `document()` + walks `<title>` kids |
| `SvelteWindow` / `SvelteDocument` / `SvelteBody` | `<svelte:window>` etc. | Printed | `window()` / `document()` + `on:`; `bind:scrollY`/`scrollX` → `window().scrollY()` |
| `SvelteElement` | `<svelte:element>` | Printed | static `this="section"` → `NodeDef!"section"`; dynamic `this={tag}` → `div` + `@attr!"data-tag"`; construct seeds `data_tag`; `createNode` uses `createElement(string)`; `applyTag` `document().createElement` + `replaceChild` + handle steal (`this.update.tag` re-applies) |
| `SvelteComponent` / `SvelteSelf` | `<svelte:component>` / `self` | Printed | static `this={ClickField}` → `@child`; `svelte:self` → `@child Host* selfKid` (null until `new`) + body `@child SelfDiv`. libwasm `compile!` / CSS style-sets / `registerRoutes` skip same-type T* (no CTFE recursion) |
| `SvelteFragment` | `<svelte:fragment>` | Printed | walk kids; no wrapper NodeDef |
| `SvelteBoundary` | `<svelte:boundary>` | Printed | body `@visible` `boundary_ok=true`; `{#snippet failed}` `@visible` `boundary_failed=false`. `this.update.boundary_failed` hides body / shows failed; `this.update.boundary_ok` resets (**G91**). `{#snippet failed(error, reset)}` + `onerror` emit `failBoundary` / `resetBoundary`; Retry is the snippet `reset` (**G96**). `throwBoundary` does same-function `throw`/`catch` (navbar EH path, exception does not escape `nothrow`) and calls `failBoundary` (**G105** ComboMedia Trip). |
| `SvelteOptions` | `<svelte:options>` | Printed | `// svelte:options …` comments (no second compile!) |

## Directives and attributes

| Official node | Svelte syntax | svelte-d | Accommodation |
|---|---|---|---|
| `Attribute` static | `type="button"` | Printed | `@attr!"type"`; valueless `disabled` → `@attr!"disabled" bool = true` |
| `Attribute` class | `class="a b"` | Printed | `@style!"a"` per token on the element's `NodeDef` (not the first `@child` — G88) |
| `Attribute` mustache | `id={x}` | Printed | `@attr!"id"` field `id_` (never the host ident — `bind:value={tone}` + `id={tone}` cannot share a field); `construct` seeds |
| `SpreadAttribute` | `{...props}` | Printed | `applySpread(string)` `k=v` `setAttribute`; `applySpread(Handle)` interned `applyObjectSpread` (class/style/bool); leftover string bag stays `@attr!"data-spread"` |
| `OnDirective` | `on:click={fn}` | Printed | `Slot` + `@callback` + `@connect`; component `on:done={go}` → `@connect!"panel.done"`. Author `mixin Slot!("name", T)` is not re-emitted from `this.emit(name)`. `<form on:submit>` uses `nodeHandle` (HTMLFormElement.opDispatch is not a template) |
| `OnDirective` modifiers | `on:click\|preventDefault` | Printed | `preventDefault` / `stopPropagation` / `once` / `trusted` (`isTrusted`) / `self` comment; several `on:` |
| `BindDirective` `value` | `bind:value` | Printed | `@prop!"value"` named after the host ident; `construct` seeds; `input` Slot writes the host field back (ComboForm) |
| `BindDirective` others | `bind:this` / `group` / `checked` / `innerHTML` / `open` / `paused` / `volume` / `files` | Printed | `bind:this` on elements **and** components; `bind:group` seeds `checked` from the host + `change` writes back; `bind:checked`/`open` seed + `change`; `bind:files` → `Handle`; number `value` → `double`. `bind:clientWidth` is a field (not `@prop`); libwasm skips getter-only assigns (`dataset`, `paused`, layout metrics) |
| `ClassDirective` | `class:x={y}` | Printed | `@style!"x" bool y` on the element; parent `this.update.y` syncs the child |
| `StyleDirective` | `style:color={c}` | Printed | one `@prop!"style"`; `onMount` concats `color:` (+ `!important`) |
| `UseDirective` | `use:action` | Printed | `onMount` `action(child.node.handle)` (`ComboNext.svelte`) |
| `TransitionDirective` | `transition:` / `in:` / `out:` | Printed | CSS-only `@style!"name"` |
| `AnimateDirective` | `animate:` | Printed | CSS-only `@style!"name"` |
| `LetDirective` | `let:` | Printed | `string name; // let:name` on the slot / element |

## How to add the next construct

1. Find the node in `template.d.ts` (and the analyze visitor under `phases/2-analyze/visitors/`).
2. Pick the libwasm / vibe.0 idiom ([udas.md](udas.md), [frontend-libwasm.md](frontend-libwasm.md), [backend-vibe0.md](backend-vibe0.md)). If none, that is a **titled seam**, not a svelte-d runtime.
3. Lower Pegged / scan onto an existing `MkNode` kind or a new kind that `compile!()` already walks.
4. Print representative names. Add a `.svelte` fixture under `svelte-engine/src-svelte/`.
5. Update this table and [sveltekit-feature-map.md](sveltekit-feature-map.md).

Do not vendor `svelte/compiler` into the wasm or host link set. The clone is read-only reference.

## Combinations (generic, not one fixture per node)

`svelte-engine/src-svelte/lib/Combo.svelte` stacks many official nodes in one tree: `{#if}` + `{:else if}` + `{:else}` with **several** consequent children (`<p>`, `{@html}`, `{#each}`), each item taken from the real `<li>` (class: + static attr + `{item}` + index), `<slot>` fallback, `{#await}` pending/then/catch, `<ClickField msg="hi" />` props, and `bind:value` + `class:` + `id={}` + `name=` on one input. The printer walks **every** walkable child (not only the first) and attaches every new `@child` to the same `@visible` bool. `{#each}` seed `put`s and component prop assigns share one `construct()`.

`svelte-engine/src-svelte/lib/ComboMore.svelte` stacks the next official batch: `{#snippet}` + `{@render}`, `bind:this` (`Handle` + `onMount`), `bind:group` radios, `{@const}` / `{@debug}`, `{#key}` `remount!`, `<svelte:window on:keydown|preventDefault>`, and `$state` / `$derived` / `$effect` rewritten onto fields + `onMount`.

`svelte-engine/src-svelte/lib/ComboNext.svelte` stacks special elements and remaining directives: static `<svelte:element this="section">` + `use:` + `transition:` + `{...props}`, `<svelte:fragment>`, `<svelte:component this={ClickField}>` with a snippet **site**, `{@attach}`, `in:`/`out:`/`animate:`, and `<svelte:boundary>` fallback kids.

`svelte-engine/src-svelte/lib/ComboRest.svelte` stacks the remaining official rows that still fall through: `<svelte:options>`, `<svelte:head><title>`, `{let extra = 3}`, `{#each rows as row, i (row)}` (index + key), `<slot let:item>`, and `<svelte:self>` as `@child ComboRest* selfKid` plus body `@child SelfDiv`.

`svelte-engine/src-svelte/lib/ComboCss.svelte` stacks CSS and leftover rows: `<style>` → `addCss` + `@style!".box"`, `style:color` + `style:background|important` live-concat on one `@prop!"style"`, dynamic `<svelte:element this={tag}>` → construct `data_tag` + `createElement(string)` at `createNode` + `applyTag` `document().createElement`/`replaceChild`, `{...rest}` → `applySpread` `k=v` `setAttribute`, and `{...extra}` `Handle` → `applyObjectSpread`.

`svelte-engine/src-svelte/lib/ComboForm.svelte` stacks form/bind/event leftovers: `<textarea>` / `<select>` + `<option>` `bind:value`, `bind:innerHTML`, `<details bind:open>`, valueless `disabled`, `class:on` shorthand, and `on:click|once` plus `on:keydown` on the same button.

`svelte-engine/src-svelte/lib/ComboMedia.svelte` stacks SVG/media/ARIA: `<svg>`/`<circle>`, `<video bind:paused bind:muted>`, `<a href aria-label>`, `disabled={off}`, `on:click|self|trusted`, `<img>`, and `<svelte:boundary>` + `{#snippet failed}`.

`svelte-engine/src-svelte/lib/ComboWide.svelte` stacks wider HTML + inverted if: `{#if !off}`, `<math>`/`<mi>`, `<dialog bind:open>`, `<audio bind:paused bind:volume>`, `<progress bind:value>`, `<canvas>`, `<iframe>`, custom `<my-widget>`, and `<svelte:document>` / `<svelte:body>` events.

`svelte-engine/src-svelte/lib/ComboExpr.svelte` stacks expressions and more HTML: `{#if ready && ok}`, `{#await job then v}` with `{v}`, `{#snippet greet(name)}` + `{@render greet(who)}`, `{#each rows as {name}}`, `<form on:submit|preventDefault>` (`SendForm` listeners via `nodeHandle`, not UFCS `.handle` on `HTMLFormElement`), `<label for>`, `<table>`/`thead`/`th`/`td`, and `bind:clientWidth`.

`svelte-engine/src-svelte/lib/ComboOr.svelte` stacks `{#if left || right}`, `{#await}` then `{v}` + catch `{e}`, named `<slot name="aside">`, `<svelte:window bind:scrollY on:resize>`, `<picture>`/`<source>`, `<fieldset>`/`<legend>`/`<meter>`/`<time>`, `<optgroup>`, and `:global(.wide)` via `addCss`.

`svelte-engine/src-svelte/lib/ComboMisc.svelte` stacks `{#if n > 0}`, `bind:files`, `datalist`/`output`/`ruby`/`rt`/`map`/`area`/`track`/`caption`/`colgroup`/`tfoot`/`template`/`abbr`, `style:--accent={tone}`, and `on:dragstart`.

`svelte-engine/src-svelte/lib/ComboSem.svelte` stacks `{(ready && ok)}`, `{#if who == extra}`, `{#snippet pair(a, b)}` + `{@render pair(who, extra)}`, `<ClickField bind:this>`, `input type="number"`, semantic landmarks (`article`/`nav`/`main`/`figure`/`dl`/`mark`/`kbd`/`noscript`/`hr`/`br`), and `pointer`/`focus`/`wheel`/`touch` events.

`svelte-engine/src-svelte/lib/ComboNest.svelte` stacks `{#if on && !hide}`, `{#each}` whose `<li>` is inside `{#if}`, `{#each pairs as [x, y]}`, `bind:indeterminate`, `ol reversed`, `object`/`embed`/`bdi`/`cite`/`wbr`, and `on:copy`/`scroll`/`contextmenu`.

`NavBar.svelte` is the live chrome (G70/G106): DaisyUI start/center/end, `{logo}`, desktop Item 1/2, burger `{#if open}` + `{#each links}` mobile menu, end Button keeps handwritten-golden `throw`/`catch` + `PgLite().query`. `src-d/navbar.d` stays the EH/PgLite passthrough and is not edited.

`Panel.svelte` + `AppShell.svelte` is a **multi-file** official tree: `{#if ready}<Panel bind:this title on:done />{/if}` + `{#each}`, child `emit(done)` → `mixin Slot!"done"`, parent `@connect!"panel.done"`. Covered by the bun package `packages/svelte-d-coverage` (`import { … } from 'svelte-d'`).

`src-svelte/routes/board/` is a **nested kit tree** (not another Combo fixture): `+layout.svelte` (`svelte:head` + `{#if}` + `<slot>`), `+page.svelte` (`{#if}`-wrapped `<AppShell />` + `{#await}`), `+error.svelte`, `board/[id]/+page.svelte` (`svelte:head` + `{#if}`-wrapped `<Panel />` + await trio), `+page.server.d` → `BoardPageServer`, `+server.d` POST → `BoardServer`. Host class names are dest-unique (`classFromHostDest`) so `assembleHostRoutes` keeps every route. `assembleAppChildren` is `src-d/lib/` only. T5 hangs `@child KitRoutes` on `App` and remounts pages inside `@entering`. Covered by `packages/svelte-d-coverage` (`route-board.test.ts`) and `packages/svelte-d-kit-app`.

`src-svelte/routes/(app)/` is the **filesystem-routing** tree: `(groups)` never appear in `kit_router` patterns; `docs/[[lang]]/+page.svelte` expands to `/docs` and `/docs/:lang` (`kitToPatterns`); `+layout.server.d` → `AppLayoutServer`; `shop/+page.svelte` is `{#if}`-wrapped `<ClickField />` + await. Covered by `packages/svelte-d-kit-fs`.

`hooks.server.d` + `files/[...path]` + `inbox/` is the **host-cell** tree: `[...path]` prints `@entering!"/files/*"` (named rest is still a vibe.0 seam); `handleError` hangs on `HTTPServerSettings.errorPageHandler` and is **not** `registerWebInterface`'d; inbox `+page.server.d` `post`/`postSave` → `InboxPageServer`. Covered by `packages/svelte-d-kit-host`.

`$app` / `$env` are generated D enums (not a third runtime): wasm `src-d/kit/app_environment.d` (`browser=true`), `app_paths.d` (`base`/`assets`), `env_static_public.d` (`PUBLIC_*` from `.env`); host mirrors under `webserver/source/generated/kit/` plus `env_static_private.d`. Wasm importing private is a compile graph error. `account/+page.svelte` imports the wasm enums + `{#if}`-wrapped `<Panel />`; `account/+page.server.d` uses `req.cookies` / `res.redirect` / `res.headers` / `res.setCookie` + `SECRET_TOKEN`. Covered by `packages/svelte-d-kit-env`.

The **engine ships inside svelte-d** (`templates/engine`) and is **dropped** into the workspace. Application SvelteKit trees live in the bun project (`compile --project`). `packages/svelte-d-kit-admin` is that pattern: admin layout/dashboard/users/logs ingested onto the drop; host files call vibe.0 `connectDB` / `connectCache` / `serializeToJsonString`; `debug-map.json` + `rewriteStack` trace printed D back to `.svelte`. See [admin-debug.md](admin-debug.md) and [workspace.md](workspace.md).
