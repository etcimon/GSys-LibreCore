# D IR lifetime — compile! and Spa built-in methods

The next change that prints Svelte `onMount` as a JS import, puts DOM reads in `construct()`, hangs a printed struct beside `App` without `@child`, or wraps `_start` / `compile!` in a throwaway `ScopedPool` should read this and then emit **libwasm’s existing hooks**.

**Guiding construction:** the D IR is not only a NodeDef graph ([udas.md](udas.md)). It is that graph **plus the methods `compile!` and `mixin Spa!App` already call**. Those methods **are** the lifetime manager. svelte-d does not invent `componentDidMount`, a disposer stack, or a Svelte runtime `onMount`. It prints the hooks libwasm already dispatches, in the order `_start` actually runs them, and it puts pool-correct work ([AGENTS-D-IR-memory-management.md](AGENTS-D-IR-memory-management.md)) in the hook that owns that lifetime.

```
_start (spa.d:119-146)
  alloc_init → PoolStack.initialize          // empty stack; no default pool
  getRoot / GetCss
  App.main()            if present           // pre-graph; rare
  App.compile()         = compile!(App)      // inject → recurse → construct()
  setupRouter / App.registerRoutes()         // @entering / @leaving walk
  render(root, App)     = handles + @connect + propagateOnMount
  App.ready()           if present           // else router.navigateTo(pathname)
```

After boot, the graph lives until `unmount` / `removeChild` / `Updater` shrink. Mutation is `this.update`, `remount`, `setVisible`, `HTMLArray.put`. That is the whole lifetime surface.

## How control actually moves

### Spa `_start` — process lifetime

`mixin Spa!App` (`spa.d:113-146`) plants `__gshared Application application` and exported `_start(heap_base)`:

| Step | Method / call | When | What may run |
|---|---|---|---|
| 1 | `alloc_init` + `PoolStack.initialize` | always | bump + empty pool stack |
| 2 | `App.main()` | if `hasMember!(Application,"main")` | pre-`compile!`. No inject, no handles. Almost never print this. |
| 3 | `application.compile()` | always | `compile!` walk: `@inject`, recurse `@child`, then **`construct()`** on each struct |
| 4 | `setupRouter()` + `application.registerRoutes()` | always | CTFE/runtime walk of `@entering` / `@leaving` (`router.d:490-597`). Recurses `@child`. |
| 5 | `libwasm.dom.render(root, application)` | always | create JS handles, apply `@prop`/`@attr`/`@style`, `@callback` listeners, **`@connect .add`**, `appendChild`, **`propagateOnMount` → `onMount()`** |
| 6 | `App.ready()` | if present | first paint done. Default if **absent**: `router().navigateTo(location.pathname)` |

HMR (`spa.d:148-165`) is `dumpApp` / `loadApp` on the same `__gshared application`. JS reload *does* re-run `_start` on the new wasm, then `loadApp`. Lists serialize (`:l:N:[…]`); `ManagedPool` is still skipped ([hmr-debug.md](hmr-debug.md)).

`registerRoutes` is a **lifetime walk**, not a second compiler: it binds methods already on the compiled structs. Printed `@entering!"/foo/:slug"` methods are discovered here. Do not emit a second router table.

### `compile!` — graph lifetime (no handles yet)

`compile!(T)(t, ts)` (`dom.d:644-740`) is one pass over `T.tupleof`:

1. NamedNode fields (not `node`): `setChildFromParent` + `@inject` alias.
2. Other public fields: `setParamFromParent` + `@inject` (pointer or value).
3. Public aggregates that are not `DynamicArray`/`HTMLArray`: recurse `compile!(child)(child, params, t, ts)` — **parent is pushed onto `Ts`**.
4. After every field of `T`: **`t.construct()` if `hasMember!(T,"construct")`** (`dom.d:737-738`).

Consequences for printed IR:

- `construct()` runs **depth-first**: children `construct` before the parent. `App.construct` is last.
- Inject pointers are valid inside `construct`. JS handles are **not** — `render` has not run.
- `HTMLArray` / `DynamicArray` items are **not** compiled. List seed in `construct` uses `put` + item ctor (`navbar.d:62-65`).
- `@connect` is **not** wired here. It is wired in `renderIntoNode` (`dom.d:1064-1088`). Delegates stored in `construct` must be fields on the struct, not pool temps.

`compile!` does not allocate the UI. The structs are value fields on `__gshared App`. `construct` is where **App-lifetime** resources are created (`ManagedPool`, seeded lists, copied initial `@prop` values).

### `render` / `onMount` — handle lifetime

`render` / `renderBefore` (`dom.d:362-408`) call `renderIntoNode` (create handle, props, attrs, callbacks, **connect**), then `appendChild` / `insertBefore`, then `propagateOnMount` if not already `mounted`.

`propagateOnMount` (`dom.d:413-418`): children first, then `onMount()` if it is a function **and** `getNamedNode().mounted`.

`onMount` is the first moment a printed method may touch the NamedNode / bindings that need a live handle (`focus`, measured layout, `exportDelegate` that must see the node). It is **not** where `ManagedPool` is created (too late for `construct` consumers; handles exist but inject already ran).

Svelte `onMount(() => { … })` maps to `void onMount()` on that struct. It is **Implemented-by-mapping**, not a rejected import. Do not print `import { onMount } from 'svelte'`.

### `unmount` / `onUnmount` — detach

`unmount` / `removeChild` (`dom.d:336-354`) release the JS handle, set `mounted = false`, then `propagateOnUnmount`.

`propagateOnUnmount` (`dom.d:421-427`) is specified to call `onUnmount()` when present. **As implemented**, the child walk calls `propagateOnMount` on children, then `t.onUnmount()`. Child `onUnmount` may not fire. Print `onUnmount` anyway; do not invent a disposer list. Fixing the child walk is a **titled libwasm seam**, not a svelte-d workaround.

Svelte `onDestroy(() => { … })` maps to `void onUnmount()`.

`{#if}` is `setVisible` / `remount` / `unmount` (`dom.d:1318-1329`, `remount` `:429-448`). The D struct stays; the handle goes. Re-show is `remount!(field)(parent)`, which `renderBefore`s in front of the next still-mounted `@child` sibling so order is preserved.

`Updater` (`array.d:98-178`) marks, `put`s replacements, `unmount`s leftovers, `shrinkTo`. List rebuilds must `assignEventListeners` again. Detach does **not** `EventEmitter` un-add ([udas.md](udas.md)).

### `this.update` — mutate without rebuild

`this.update.field = v` (`dom.d:1282-1307`) writes the struct field and pushes it to the live handle. That is how `{msg}` and `bind:value` stay one graph. It is not a lifetime hook; it is the **only** sanctioned mutation of a mounted `@prop`/`@attr`.

### Built-in methods (print these, nothing else)

| Method | Who may have it | Called by | Handles? | Pool? | Svelte / kit map |
|---|---|---|---|---|---|
| `main()` | **App only** | `_start` before `compile!` | no | stack empty | almost never; not `onMount` |
| `construct()` | any compiled struct | `compile!` after inject, before render | **no** | create `ManagedPool` here; do **not** `PoolStack.push` it for the process | field init, `{#each}` seed via `put`, copy initial props |
| `onMount()` | any NodeDef struct | `propagateOnMount` after first append | **yes** | `ScopedPool(m_pool)` if the body allocates. **No `.await` on wasm-eh** ([AGENTS-D-IR-asyncify-wasm-eh.md](AGENTS-D-IR-asyncify-wasm-eh.md)) | Svelte `onMount` |
| `onUnmount()` | any NodeDef struct | `unmount` / `removeChild` | dying | drop inject ptrs; do not free `App.m_pool` | Svelte `onDestroy` |
| `ready()` | **App only** | `_start` after `render` | yes | `ScopedPool` if it navigates with temps | first-load / `hooks.client` **partial**; if omitted, default `navigateTo` |
| `@entering` / `@leaving` | any `@child` in the App graph | `registerRoutes` then router iterate | yes | router already `ScopedPool(m_pool)` | kit page enter/leave; layouts stay mounted |
| `this.update.*` | any NodeDef | author / `@connect` | yes | wrap the **caller** | `{msg}`, `bind:value` |

Not hooks (do not invent methods with these names unless libwasm grows them): `onInit`, `dispose`, `componentWillUnmount`, `afterUpdate`. `~this` on a `compile!()` struct is not how detach works.

### Where the pool sits on this timeline

```
construct()     create ManagedPool on the struct (App / page / Main).
                navbar-style list seed: put(new Item(...)) after freeze
                  or put value items whose fields are copied (not pool slices).
                Do NOT PoolStack.push(m_pool) for the process
                  (dom-ts App.construct does; engine golden does not — follow the engine).

onMount/ready/
@connect/go()   auto scoped = ScopedPool(m_pool);
                heavy work; copy survivors onto fields; or freeze for a new Item/delegate.

onUnmount()     do not pop App.m_pool. Clear host* / pending. Handles are already released.

unmount(item)   graph detach. Item struct may still exist until the Array shrinks.
```

`compile!` / `_start` / `registerRoutes` themselves stay **unscoped**. A throwaway pool around them would free `@connect` delegates and `NamedNode` wiring.

### Logical structure of printed D IR (what svelte-d assembles)

One wasm program is **one** `mixin Spa!App` (engine `app.d:12`). Printed components are **not** a second Spa. They are `@child` fields on `App` (or on a layout that is already `@child` of `App`), at fall-through paths, with representative names ([ast-ir.md](ast-ir.md)). `<svelte:self>` is `@child Host* selfKid` (null until `new`). libwasm `compile!` / `registerRoutes` skip a null pointer and, when `ChildType == T`, recurse `compile!(T)(*p)` so `Ts` does not grow.

```
mixin Spa!App;                    // golden; do not print a second _start

struct App {
  @child NavBar navbar;           // golden
  @child Main   content;          // golden
  @child Dock   dock;             // golden
  @child ClickField clickField;   // printed — hang here (T3 assemble)
  ManagedPool m_pool;
  void construct() { m_pool = ManagedPool(64 * 1024); }
  void ready() { /* optional; else default navigate */ }
}

// src-d/lib/ClickField.d  (printed)
struct ClickField {
  @child GoButton goButton;
  string msg;
  void construct() { msg = "…"; }           // no DOM
  void onMount() { /* focus / measure */ }  // handle live
  void onUnmount() { /* drop host* */ }
  @connect!"goButton.click"
  void go() {
    auto scoped = ScopedPool(/* App.m_pool via inject or package */);
    msg = surviving.idup;
    this.update.msg;
  }
  mixin NodeDef!"div";
}
```

`@inject!"m_pool"` / a package `appPool()` is how a child scopes against `App.m_pool`. Do not give every widget its own 64 KiB `ManagedPool` unless the golden already does (`Main` in dom-ts). Prefer one App pool.

Layouts stay mounted `@child`. A kit page swap is `unmount` old page + `render`/`remount` new page inside an `@entering` callback — not a new wasm module, not a new `Spa!`.

## Loci

`spa.d:104-146` — `mixin Spa`, `_start` order: `main` → `compile` → `registerRoutes` → `render` → `ready`  
`spa.d:148-165` — HMR exports; no re-`construct`  
`dom.d:336-354` — `unmount` / `removeChild`  
`dom.d:362-408` — `renderBefore` / `render` + `propagateOnMount`  
`dom.d:413-418` — `propagateOnMount` → `onMount`  
`dom.d:421-427` — `propagateOnUnmount` → `onUnmount` (child walk: see Did not close)  
`dom.d:429-448` — `remount!(field)`  
`dom.d:644-740` — `compile!` inject / recurse / **`construct()`**  
`dom.d:1064-1088` — `@connect` during **render**, not compile  
`dom.d:1282-1307` — `this.update`  
`dom.d:1318-1329` — `setVisible` → remount / unmount  
`array.d:91-95` — `HTMLArray.put` + `assignEventListeners`  
`array.d:98-178` — `Updater` unmount leftovers  
`router.d:490-597` — `registerRoutes` + `@child` recurse  
`router.d:181-186,269,432` — router `ManagedPool` + per-command `ScopedPool`  
`svelte-engine/src-d/app.d:12,120-125` — `mixin Spa!App`, `construct` creates pool only  
`svelte-engine/src-d/navbar.d:62-65` — `construct` seeds `UnorderedList`  
`libwasm/examples/dom-ts/src-d/app.d:68-71,157-160` — `construct` + handler `ScopedPool`; App also `PoolStack.push` (do not copy that)  
[udas.md](udas.md) — graph / connect / inject / detach  
[AGENTS-D-IR-memory-management.md](AGENTS-D-IR-memory-management.md) — pool precedence inside these hooks  
[ast-ir.md](ast-ir.md) — names; this note is how those structs **live**

## Invariants

- There is one `mixin Spa!App` and one `_start`. Printed files do not plant another. (construction)
- Printed components hang as `@child` (or `@child` of a layout that hangs on `App`). (construction of the IR)
- `construct()` runs after `@inject` and before `render`. It must not read a NamedNode handle. (construction of `dom.d:737` vs `:383`)
- `@connect` is wired in `render`, after every `construct` on the static tree. (construction)
- `onMount` / `onUnmount` are libwasm methods, not Svelte JS imports. (construction of the mapping)
- If `App` has no `ready()`, `_start` **will** `navigateTo` the current path. Printing an empty `ready()` suppresses that. (construction of `spa.d:141-145`)
- `registerRoutes` finds `@entering`/`@leaving` on the compiled graph, including nested `@child`. (construction)
- `ManagedPool` is created in `construct`, pushed only by `ScopedPool` in commands. Do not print a process-lifetime `PoolStack.push` in `construct`. (convention of svelte-engine; construction of pool rewind)
- `compile!` / `_start` / `registerRoutes` are not wrapped in a throwaway pool. (construction of delegate lifetime)
- `{#if}` is remount/unmount of an existing `@child`, not a new struct type. (construction)
- HMR does not re-run `construct` for skipped kinds (lists, pools). (construction of `hmr.d`)

## Extension points

A new Svelte lifecycle import is a row in this table or a titled libwasm seam — never a JS `onMount`. A new page in the kit tree is a new `@child` struct plus, if it is a route, an `@entering` method on that struct or on `App`. Auto-inserting `construct`/`onMount`/`ScopedPool` is a printer arm on this note, not a new IR kind.

## Did not close

- `propagateOnUnmount` child walk calls `propagateOnMount` (`dom.d:424`). Child `onUnmount` may not run. Seam, not a printer fake.
- Whether children `@inject!"m_pool"` or call `appPool()`. v1: inject or a single package helper; not a pool per widget.
- Whether svelte-d **patches** golden `app.d` to insert `@child ClickField clickField` or prints a sibling `generated/app_children.d` mixed into App. v1: patch/insert `@child` on App without rewriting navbar/dock.
- Whether `{#each}` initial items print inside `construct` as `put`, or wait for `onMount`. v1: `construct` + `put` (navbar golden).
- Whether a printed `ready()` should always be omitted so default `navigateTo` stays (probably yes unless the Svelte has first-load work).
