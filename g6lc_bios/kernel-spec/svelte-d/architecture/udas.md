# UDAs, NodeDef, and compile!() — how a dynamic UI is one struct graph

The next change that invents a virtual DOM, a second event bus, or a connect path that is not a member path on the compiled struct should read this and then emit **idiomatic libwasm UDAs**.

A libwasm app is not a tree of heap widgets. It is a **value graph of structs**. `mixin NodeDef!"tag"` plants a compile-time **NamedNode** (typed HTML handle) on each struct. `libwasm.dom.compile!()` (`dom.d:644`) walks that graph once: it fills `@inject` pointers from the parent tuple, recurses into `@child` aggregates, then wires `@connect` delegates onto `Slot` / `EventEmitter` fields. `render` (`dom.d:383`) creates the JS handles and applies `@prop` / `@attr` / `@style` onto those NamedNodes. Dynamic UI is **mutating that graph** (`this.update.field`, `UnorderedList.put`, `unmount`) — not rebuilding a VDOM.

That graph is **App-lifetime**. Transient work inside `@connect` / list `put` / Lodash bodies is **not**: those arms run under a `ScopedPool` and copy survivors onto these fields (or `freeze` before planting a new item / delegate). Graph lifetime ≠ pool lifetime. See [AGENTS-D-IR-memory-management.md](AGENTS-D-IR-memory-management.md).

## NodeDef → NamedNode → typed HTML element

`mixin NodeDef!"button"` (`node.d:119-121`) expands to a field:

```
NamedNode!("button", "button") node;
```

`NamedNode!(name, tag)` (`node.d:110-117`) aliases `Element` through `TagHtmlElementMap` (`node.d:27-108`):

| `NodeDef` argument | `TagHtmlElementMap` member | Bindings type |
|---|---|---|
| `"button"` | `button` | `HTMLButtonElement` |
| `"input"` | `input` | `HTMLInputElement` |
| `"ul"` | `ul` | `HTMLUListElement` |
| `"li"` | `li` | `HTMLLIElement` |
| `"a"` | `a` | `HTMLAnchorElement` |
| `"p"` / `"div"` / `"span"` / `"section"` | same | matching `HTML*Element` |
| unknown / custom | `opDispatch` (`node.d:105-107`) | `HTMLElement` |

`alias node this` makes the struct a handle. `createNode` + `renderIntoNode` (`dom.d:908+`) assign the JS `Handle` into `node.node`. Two NodeDef overloads: `NodeDef!"name"` (name == tag) and `NodeDef!("name","tag")` when the field name and the HTML tag differ.

That is the **node reference** in the IR: not a separate `NodeRef` type. Printer output must keep one `mixin NodeDef!"tag"` per component struct, matching a `TagHtmlElementMap` key when the tag is known.

## @prop and @attr — compile-time DOM properties on that NamedNode

These are **libwasm UDAs** (`types.d:610-612`), not D `@property`.

| UDA | When applied | What `render` / `compile` does |
|---|---|---|
| `@prop` / `@prop!"textContent"` | field on a NodeDef struct | `setPropertyTyped!name` on the NamedNode (`dom.d:966-972`, `:1512`) |
| `@attr` / `@attr!"placeholder"` | field | `setAttributeTyped!name` (`dom.d:974-980`, `:1490`) |
| `@style!"cls"` | field or NodeDef | CSS class via `GetCss` / `changeClass` |

`child.update.foo = v` (`dom.d:1282`) is `opDispatch` that writes the struct field **and** pushes it to the live handle. Svelte `{msg}` lands as `@prop!"textContent" string msg` on the **child** NamedNode (`MsgSpan`); the printer rewrites author `this.update.msg` to `msgSpan.update.msg` (same shape as golden `heading.update.innerText`). `{#if ident}` is `ident = expr; setVisible!"child"(this, ident)`. Bare `@prop` (no name) is not a legal UDA (`struct prop(alias prop_name)`).

Pointer `@prop` / `@attr` dereference if non-null (`setPropertyTyped` `:1516-1519`). That is how an `@inject!"msg" string*` can feed the same named property.

## The UDA vocabulary (one graph)

| UDA / mixin | Role in the graph |
|---|---|
| `mixin NodeDef!"tag"` | NamedNode of that HTML type |
| `@child` | field is a child component; `getChildren` (`node.d:5-18`); `compile!` recurses |
| `@prop` / `@attr` / `@style` | DOM property / attribute / class on **this** NamedNode |
| `@callback` / `@callback!"click"` | DOM event → method; `addEventListener` + `domEvent` (`event.d:14-38`) |
| `mixin Slot!("name", Params)` | `@eventemitter EventEmitter!Params name` (`event.d:163-165`) — fireable. `Slot!"click"` is `EventEmitter!()`; `add` **appends** (`~=`). Empty-Params used to assign (`cbs = del`) and did not compile against `Vector`. |
| `this.emit(slot, args)` | calls `EventEmitter` cbs **and** addr-cbs with `cast(size_t)(&t)` (`event.d:167-181`) |
| `@connect!"a.b"` | `t.a.b.add(&method)` — **member path**, dots stay dots (`dom.d:1077-1085`) |
| `@connect!("list.items","link.clicker")` | list form: `t.list.items.link_clicker.add(&method)` — second path **dots → underscores** (`dom.d:1071-1075`). First parameter of the method **must be `size_t`**. |
| `@inject!"parentField"` | `compile!` copies `&parent.parentField` (or the value) into the child (`dom.d:669-691`, `setParamFromParent` `:516`) |
| `@entering!"/path"` | libwasm `URLRouter` (not a DOM UDA; see [fallthrough.md](fallthrough.md)) |
| `@visible!"child"` | skip / remount that `@child` via `setVisible` (`dom.d:1318`). `{#if ident}` prints this UDA on `bool ident` of the **owner** struct (host, or the parent element when the if is nested). Author bool stays on the host. Nested flip is `owner.update.ident = ident` (libwasm `update` fires `setVisible` and writes the UDA field). Host-root if still emits `setVisible!"child"(this, ident)` and assigns `not_ident`. |

`@connect` and `@inject` paths are **identifiers on the compiled struct**, not SvelteKit file paths and not CSS selectors.

### @connect path resolution

- **One string** `@connect!("field.enter")` → mixin `t.field.enter.add(del)`. The string is a D member path (dots = field access). The terminal field must be an `EventEmitter` (`Slot`).
- **Two strings** `@connect!("menulist.items","link.clicker")` → mixin `t.menulist.items.link_clicker.add(del)`.
  - First path: the `HTMLArray!T` (usually `…items` inside `UnorderedList!T` / `List!(T,tag)`).
  - Second path: event path **on the item type** `T`. `extractEventPaths` (`array.d:14-36`) walks `@eventemitter` fields and `@child` recursively (`link.clicker`).
  - `ArrayItemEvents!T` (`array.d:48-64`) declares a **Slot on the array** named with **underscores**: `link_clicker`, plus `__link_clicker(size_t addr, Params)` that `emitIdx(getIndexInArray(addr), params)`.
  - That is why connect’s second argument is rewritten `replace!(b, '.', '_')`.

Golden: `navbar.d:67` `@connect!("menulist.items","link.clicker") void onEdit(size_t idx, string name)`.

### @inject path resolution

- **One identifier** `@inject!"host"` — not a dotted path.
- `compile!(Child)(child, parent, …)` searches the parent tuple `Ts` for a member named `host` whose type matches the field (or `T*`).
- If the child field is a **pointer**, it stores `&parent.host` (`dom.d:552-563`). That pointer is what a `@callback` uses to fire into the parent (`if (host !is null) host.onPicked(label)`).
- If the child field is a **NamedNode**, `setChildFromParent` (`dom.d:574`) aliases the parent’s node (shared handle), not a new element.

Inject is filled **only** for fields `compile!` walks. It does **not** walk `DynamicArray` / `HTMLArray` appenders (`dom.d:697-699`: “items in appenders need to be set via render functions”).

## How compile!() ties a new instance (and how detach works)

**Static tree** (`mixin Spa!App` → `application.compile()` in `_start`):

1. For each field: if it is a NamedNode (and not `node`), try `setChildFromParent` (name match) then `@inject`.
2. Else if public: `setParamFromParent` (same-name injection) then `@inject`.
3. Else if `@child` aggregate: `compile!(child)(child, params, t, ts)` — **parent is pushed onto `Ts`** so the child’s inject can see it (`dom.d:720-724`).
4. After all fields: `construct()` if present (`dom.d:737-738`). Handles do **not** exist yet.
5. `@connect` `.add(del)` is **not** this walk. It runs in `renderIntoNode` (`dom.d:1064-1088`) after every static `construct`.

Full hook order (`main` → `compile`/`construct` → `registerRoutes` → `render`/`onMount` → `ready` → `unmount`/`onUnmount`): [AGENTS-D-IR-lifetime.md](AGENTS-D-IR-lifetime.md).

**New dynamic instance** (list `put`, or a struct compiled after `_start`):

- `HTMLArray.put` (`array.d:91-95`) calls `assignEventListeners(*t)` then appends. That is **runtime** linking of item `Slot`s to `arr.__path` — it is **not** `compile!`.
- `assignEventListeners` (`array.d:66-73`): `item.<dot path>.add(&arr.__<underscore path>)`.
- `render` of the item creates the NamedNode handle and applies `@prop`/`@attr`.
- **`@inject` on a list item is not filled by `compile!(App)`.** The printer must either pass `&host` in `Item.this` / `put`, or the app must `compile!(*item)(*item, host)` when inserting. Prefer the constructor pointer: `items.put(new Item("one", &this))`.
- `Updater` / `update(range, list)` (`array.d:98+`) reuses slots, calls `assignEventListeners` again on replace (`array.d:150,173`).

**Detach:**

- `List.remove` / `shrinkTo` → `unmount` (`dom.d:336-341`) clears `mounted` and `propagateOnUnmount`. The JS handle is released; the D struct may still exist.
- `EventEmitter.add` **appends**; there is no un-add. Detached items must not emit. Do not keep inject pointers into a destroyed host.
- HMR `dumpApp`/`loadApp` serializes `HTMLArray` / `List` as `:l:N:[{item}…]` (`hmr.d`). After reload, `loadApp` shrinks/puts so dumped items win over `construct()` seeds.

## How a dynamic UI is the same graph

```
Svelte                         libwasm struct IR
─────────────────────────────────────────────────────────────
<div class="box">              mixin NodeDef!"div"; @style!"box"
  <button on:click={go}>       @child Btn;  Btn: NodeDef!"button"
                               mixin Slot!"click";
                               @callback!"click" onClick → emit(click)
  </button>                    @connect!"btn.click" void on_btn() { go(); }
  <span>{msg}</span>           @child Sp; Sp: NodeDef!"span"; @prop string textContent
</div>                         go() { this.update.sp.textContent = … }

{#each items as item}          @child UnorderedList!Item items;
  <li on:click={pick}>         Item: NodeDef!"li"
    {item}                     @prop!"textContent" string label
  </li>                        mixin Slot!("picked", string)
{/each}                        @callback!"click" → emit(picked, label)
                               @inject!"host" Host* host   // ctor, not compile! of App
                               @connect!("items.items","picked")
                                 void onPick(size_t idx, string name)
```

`UnorderedList!T` is `List!(T,"ul")` (`array.d:202-233`): `mixin NodeDef!"ul"` + `@child HTMLArray!(T) items`. Connect’s first path is therefore `field.items`.

dom-ts golden: `examples/dom-ts/src-d/app.d` — `mixin Spa!App`, `NodeDef!"input"` + `@prop value` + `@callback onKeyPress` + `Slot!"enter"` + `@connect!("field.enter")`. Navbar golden: `svelte-engine/src-d/navbar.d:60-67` — `UnorderedList` + two-arg `@connect`.

## What svelte-d must print

- Interactive Svelte markup → one struct per file, `mixin NodeDef` per element type, `@child` nesting, `@prop`/`@attr`/`@style` on the NamedNode that owns them.
- `on:click={h}` → child `Slot` + `@callback!"click"` + parent `@connect!"child.click"` (one-arg).
- `{#each}` → `UnorderedList!Item` + item `Slot` + `@connect!("list.items","slot")` with **`size_t` first** + `HTMLArray.put` / `assignEventListeners` (not a hand-rolled listener table).
- Parent pointer into a list item → `@inject!"host"` **and** `this(…, Host* host)` because `compile!` skips appenders.
- Do not emit `extern(C)` `addEventListener` or a second handle table.

## Loci

`node.d:27-125` — TagHtmlElementMap, NamedNode, NodeDef  
`types.d:609-617` — child, prop, attr, callback, connect, inject, entering  
`dom.d:644-738` — compile! inject + recurse + construct  
[AGENTS-D-IR-lifetime.md](AGENTS-D-IR-lifetime.md) — Spa `_start` + built-in methods  
`dom.d:908-980` — render NamedNode, @prop, @attr  
`dom.d:1064-1088` — @connect path rewrite  
`dom.d:516-572` / `:574` — inject pointer vs NamedNode  
`dom.d:1282-1307` — this.update  
`event.d:14-38` — domEvent  
`event.d:137-190` — EventEmitter, Slot, emit, emitIdx  
`array.d:14-96` — extractEventPaths, ArrayItemEvents, assignEventListeners, HTMLArray  
`array.d:202-233` — List / UnorderedList  
`examples/dom-ts/src-d/app.d` — Input / Main / App  
`svelte-engine/src-d/navbar.d:54-89` — list connect golden  

## Invariants

- One NamedNode per NodeDef; tag must be a `TagHtmlElementMap` key or it becomes `HTMLElement`. (construction)
- `@prop`/`@attr` live on the struct that owns the NodeDef they update. (construction)
- `@connect` paths are struct member paths. List form’s second path is item event path; the Slot name on the array uses underscores. (construction)
- List-connect handler’s first parameter is `size_t`. (construction of `dom.d:1074`)
- `compile!` does not inject into `HTMLArray` / `DynamicArray` items. New items link via `assignEventListeners` + ctor/`compile!(item, host)`. (construction)
- Detach is `unmount` / `remove`; do not assume EventEmitter un-subscribe. (convention of array.d)
- `@prop` / item-struct / `Array` fields do not alias a popped `ScopedPool`. Copy or freeze before `put` / assign. (construction; [AGENTS-D-IR-memory-management.md](AGENTS-D-IR-memory-management.md))

## Extension points

A new HTML tag: add it to `TagHtmlElementMap` in libwasm (or accept `HTMLElement` via opDispatch). A new event name: `@callback!"name"` if `toEventType` knows it (`event.d:71+`). A new list container: same `HTMLArray` + `ArrayItemEvents` pattern, not a new listener table.

## Did not close

Whether svelte-d should emit `compile!(*item, host)` inside `put` wrappers, or only ctor-pointer inject (v1: ctor-pointer). Whether `@prop` on a parent field can live-update an injected child pointer without `this.update.child.prop` (v1: parent `this.update.child.textContent`).
