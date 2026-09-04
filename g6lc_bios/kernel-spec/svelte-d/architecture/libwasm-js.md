# libwasm JS surface — Lodash, Moment, bindings

The next change that prints `eval("document.foo")` from JS, invents a second FFI, or emits Phobos ranges over a JS array should read this and then emit **libwasm D**.

The svelte→D IR does not talk to the browser. **Printed D does**. The **structure** of the UI is NodeDef / UDAs / `compile!()` ([udas.md](udas.md), [ast-ir.md](ast-ir.md)). Lodash, moment, and bindings are a **sparse procedural** surface inside methods — not the way a `<button>` or `{#each}` is represented. The only sanctioned talk is what already lives under `libwasm/source/libwasm/`:

| Layer | Module | What the printer emits |
|---|---|---|
| Typed WebIDL | `libwasm.bindings.*` (~680 files, generated from `webidl/`) | `Document`, `Window`, `fetch`, `MouseEvent`, `HTMLInputElement`, `Request`, … — methods are `Object_Call_*` / `Object_Getter_*` on a `Handle` |
| JS compute / collections | `libwasm.lodash` | `Lodash` chain: `defaultTo` / `attempt` / `invoke` / `map` / `filter` / `find` / … then **`execute!T()`**. `Eval` is truthy when `eval_str` is non-empty (`if (predicate)` / `if (iteratee)`). |
| Time | `libwasm.moment` | `moment(...)` — a `Lodash` wrapper (`m_ld.defaultTo(Eval("moment"))`) |
| Ad-hoc host objects | same Lodash pattern as `pglite.d` | `defaultTo(Eval("window.pglite"))` + `attempt("query", …).execute!JSON()` |
| `lang=ts` exports | `libwasm.bridge` | `callTs!T("ident.fn", args)` / `callTsPromise` — Lodash `defaultTo(eval("window.__svelteD.ts")).invoke`. Inverse: `exportDelegate` + `setDRet`. See [cross-calling.md](cross-calling.md). |
| DOM components | `node` / `dom` / `event` / `spa` | `@child` / `NodeDef` / `this.update` (see [frontend-libwasm.md](frontend-libwasm.md)) |

`import libwasm;` (`package.d:3-18`) already public-imports **bindings, lodash, moment, and bridge**. Printed client D starts with `import libwasm;` and then uses those names. It does **not** import TS, lodash npm, or moment npm — those stay in the workspace JS glue (`src-ts/modules/bindings.ts` installs `window._` and `window.moment`; `libwasm.ts` plants `window.__svelteD`).

## How the D syntax actually runs

**Bindings** (WebIDL → D, same generator svelte-d’s Pegged walker is modeled on):

```d
// libwasm/source/libwasm/bindings/Document.d:77+
struct Document {
  nothrow:
  libwasm.bindings.Node.Node _parent;
  alias _parent this;
  // getters/setters are Object_Getter__string / Object_Call_string__void
}
// Fetch: WindowOrWorkerGlobalScope.fetch → JsPromise!(Response)
```

A `Handle` is a `uint` index into the JS object table (`{1: document, 2: window}`). D never stores a JS pointer. `nothrow: @safe:` on every binding.

**Lodash** (`lodash.d:325`, public from `:698`): a command buffer of JS `_` calls. Chain methods return `Lodash`; **`execute!T()`** (`:5530`) ships the buffer through `ldexec_Handle__*` / `ldexec_string__*` imports and yields `T` (`string`, `long`, `double`, or a `Handle`-wrapping type such as `JSON`).

```d
auto n = Lodash(someHandle, VarType.handle, 256)
  .filter(/* iteratee */)
  .map(/* iteratee */)
  .execute!JSON();
```

`defaultTo` (`:5486`) and `attempt` (`:5217`) and `invoke` (`:4334`) are the escape hatches for “call this JS name with these D args.” That is how Moment and PgLite are written — **not** a second runtime.

**Moment** (`moment.d:10-72`):

```d
Moment moment();                          // Eval("undefined") → now
Moment moment(ARGS...)(auto ref ARGS args);
string format()(string fmt = null);       // invoke("format") + execute!string
```

Internally: `m_ld.defaultTo(Eval("moment")); m_ld.attempt(args);` then `invoke` / `save` / `execute`.

**PgLite** (`svelte-engine/src-d/pglite.d`) is the golden *host-object* wrapper. New JS libraries get the same shape: `initArgs` + `defaultTo(Eval("window.X"))` + `attempt`/`invoke` + `execute!T`. The printer may emit a thin wrapper module under `ws/src-d/` or inline the chain.

## What the IR / printer must do

Script `lang=d` is already D. The walker does **not** translate lodash/moment/bindings calls — it **keeps** them when they are already libwasm syntax, and **rewrites** only the Svelte-shaped leftovers.

**This pass:** `lang=d` that looks like libwasm (Lodash, `document()`/`window()`/`console`, `Handle`/`Eval`/`JSON`, `@entering`/`navigateTo`) is printed to the fall-through `src-d/` path. Kit `+page.svelte` files also emit `src-d/kit_router.d` (`[slug]` → `:slug`). Catalogs: live scan of `lodash.d` and `bindings/*.d`. Golden template `src-d/{app,dock,navbar,pglite,jshost,probe}.d` stay passthrough.

| Svelte / script leftover | Emit |
|---|---|
| markup / `@prop` / `this.update` | NodeDef SPA (frontend note) |
| `fetch(url)` / `document.` / `window.` if written as JS | `Window` / `Document` / `WindowOrWorkerGlobalScope.fetch` from **bindings** |
| `[].map` / `.filter` over a **JS handle** | `Lodash(h, VarType.handle, n).map(…).execute!T()` — not `std.algorithm` |
| D arrays / ints / strings | `import std.algorithm` / `std.range` / `std.conv` in `lang=d` (lifted to the printed module header; wasm Phobos, not stock `-Iimport`) |
| date math / `new Date` | `moment(...)` |
| `JSON.parse` of a JS value | `execute!JSON()` or binding `json()` on `Response` |
| same-file `lang=ts` export `greet` | module-level `greet(ARGS...)` thunk → `callTs` / `callTsPromise` ([cross-calling.md](cross-calling.md)) |
| unknown `window.foo` (not a `lang=ts` export) | new wrapper like `pglite.d`, or `Lodash().defaultTo(Eval("window.foo"))` — **never** a printed `import` of a TS helper in `src-d/` |
| `{#each}` of D structs | `UnorderedList!T` (DOM). `{#each}` of a JS collection first `.execute`s into D / handles, then the list |

IR node kinds (additions to [ir.md](ir.md)):

- `BindingCall` — typed `libwasm.bindings.<Type>` method, payload = type + method + args
- `LodashChain` — ordered `Command`s (`chunk`, `filter`, `invoke`, …) + `executeType`
- `MomentCall` — `moment` / `format` / `utc` / `startOf` / …
- `JsHostWrap` — pglite-style `Eval("window.X")` wrapper

These nodes are **wasm-cell only**. The host-cell printer (vibe.0) must reject them (secrets + wrong runtime).

v1 subset: emit bindings that already exist in `source/libwasm/bindings/` (lookup by WebIDL name). Missing API → diagnostic “add or regenerate binding in libwasm/webidl”, not a JS stub. Lodash methods that exist as `auto ref name(...)` on `struct Lodash` may be chained. Moment methods that exist on `struct Moment` may be called. Do not invent `_` or `moment` free functions.

## Loci

`libwasm/source/libwasm/package.d:3-18` — barrel (bindings + lodash + moment + bridge)  
`libwasm/source/libwasm/bridge.d` — `callTs` / `callTsPromise` / `setDRet`  
`libwasm/source/libwasm/lodash.d:14-26` `VarType`; `:325` `struct Lodash`; `:4334` `invoke`; `:5217` `attempt`; `:5486` `defaultTo`; `:5530` `execute!T`  
`libwasm/source/libwasm/moment.d:10-72` — `moment()` / `format` / `utc`  
`libwasm/source/libwasm/bindings/Document.d:77` — `struct Document`  
`libwasm/source/libwasm/bindings/Fetch.d` / `WindowOrWorkerGlobalScope.d:78` — `fetch`  
`libwasm/source/libwasm/types.d:23` — `alias Handle = uint`  
`libwasm/webidl/` — how bindings are generated  
`svelte-engine/src-d/pglite.d` — Lodash wrap of a JS host object  
`svelte-engine/src-ts/modules/bindings.ts:7-10` — `window.moment` / `window._`  

## Invariants

- Client D uses `Handle` + bindings + Lodash + Moment + `bridge.callTs`. No `extern(C)` JS one-offs unless a binding is missing and the seam is named. `extern(C) export` for TS to call is `exportDelegate`, not a new import table. (construction)
- `execute!T()` is the only way a Lodash chain becomes a D value. (construction of lodash.d)
- Moment and PgLite-style wrappers are Lodash. Do not emit a second JS bridge. (construction)
- lodash/moment **npm** stay in the workspace JS shell; D never `import`s them. (construction)
- Host-cell D (vibe.0) does not import `libwasm.lodash` / `libwasm.bindings`. (construction of the two cells)

## Extension points

New browser API: regenerate or hand-write `bindings/<Name>.d` in the libwasm tree, then the printer may emit it. New JS library (like PgLite): a `src-d/<name>.d` wrapper around `Lodash` + `Eval("window…")`, plus TS that assigns `window.<name>`. New Lodash iteratee shape: extend `VarType` / `Callback` in `lodash.d` (libwasm seam), do not fake it in svelte-d.

## Did not close

Whether `{#each}` over a Lodash `execute!(Handle[])` needs a helper. Whether `JSON` in `pglite.d` is `fast.json` or a bindings type (printer must match the template import). How much of Lodash’s 200+ methods the v1 subset checker allows (recommendation: allow any method that exists on `struct Lodash`; fail only on unknown names).
