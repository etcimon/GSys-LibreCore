# D IR memory management — memutils + libwasm fall-through

The next change that prints `new` for a click-handler temporary, stores a pool slice on a `compile!()` field, or skips `ScopedPool` around a Lodash/`execute!`/string-building method should read this and then emit **pool-correct** libwasm D.

**Guiding construction:** memutils is the allocator and container library. libwasm does not grow a second heap. D runtime allocation **falls through** to `libwasm/rt/memory.d` and `libwasm/rt/allocator.d`. When a **`ScopedPool` is on `PoolStack`**, pool-aware allocation (`alloc`, `_d_allocmemory`, `gc_malloc`, `allocString`) **takes that pool**. Language `new` does **not**. Heavy-allocating commands, functions, and methods are printed **inside** a `ScopedPool`. Data that must outlive the command is **copied** into `compile!()` struct fields or ThreadMem/`Array`/`Vector` containers — or the current pool is **`freeze`/`unfreeze`** so the nested allocation misses the pool. That is what “functionally memory-correct D IR” means.

Printed D is the **wasm** cell (`memutils-wasm`). Host `riscv-dev/memutils` is the same story with a GC fallback; do not print host-only fallbacks into `src-d/`.

```
.svelte handler / {#each} rebuild / Lodash execute / bindings string
    │  printer wraps the body
    ▼
auto scoped = ScopedPool(app.m_pool);   // or ScopedPool() throwaway
    │  alloc / _d_allocmemory / allocString  →  PoolStack.top
    │  language `new` / _d_newclass / _d_newarray  →  WasmAllocator bump (never recycled)
    ▼
copy survivors into compile!() fields / Array / Vector (ThreadMem)
    or scoped.freeze(); longLived = …; scoped.unfreeze();
    ▼
~scoped → PoolStack.pop → onDestroy dtors + rewind slabs
```

JSON under `ws/.svelte-d/ir/` does not allocate. Memory rules apply to **pretty-printed** `src-d/**/*.d` and to engine goldens (`app.d`, `router.d`) the printer must not unlearn.

## How control actually moves

### 1. memutils — what is provided

Two checkouts, one API:

| Tree | Used by |
|---|---|
| `riscv-dev/memutils` | host cell (svelte-d itself, vibe.0) |
| `riscv-compilers/libwasm/memutils-wasm` | wasm cell (printed D IR, svelte-engine) |

**Façades** (`utils.d`): `AppMem` (GC; wasm has no useful GC), `ThreadMem` (lockless freelist over `MallocAllocator`), `SecureMem` (zeroise). Callers use `ThreadMem.alloc!T` / `ThreadMem.free`, not raw `malloc`.

**Backends** (`memory.d`, `freelist.d`): `MallocAllocator` over-allocates and 16-byte-aligns. On wasm it calls `wasm_malloc` / `wasm_realloc` / `wasm_free` (`memutils-wasm/memory.d:19-64`). `wasm_free` zeros; it does **not** return the bump. `AutoFreeListAllocator` recycles twelve power-of-two slots (8 B–16 KiB) in front of that.

**Bump pool** (`pool.d`): `PoolAllocator` is a slab bump (default 64 KiB). `alloc` takes `alignedSize(sz)` from the first slab that fits. `realloc` grows in place only if the block is the last allocation in the current free slab. **`free` is a no-op** (wasm: optional `memset` when `must_zeroise`). Lifetime of pooled bytes is the **pool**, not the pointer. `onDestroy` records `void delegate()` so `freeAll` / pop runs destructors in reverse before rewinding `remaining = data`.

**Lifetime** (`scoped.d`, `refcounted.d`, `unique.d`, `helpers.d`):

| Type | Role |
|---|---|
| `ManagedPool` | `RefCounted!Pool` — a long-lived slab set. App and `URLRouter` each keep one (`64*1024`). |
| `ScopedPool` | RAII push of a `ManagedPool` (or a fresh pool) onto `PoolStack`. Destructor `pop`s. |
| `PoolStack` | Thread stack of live pools + a **freezer**. Wasm has **no fiber stack**. `initialize()` is required (`spa.d:126`). |
| `alloc!T` / `copy` | If `!PoolStack.empty`, allocate from `PoolStack.top` and register elaborate dtors. Host falls back to `new`. Wasm `alloc` for **classes is commented out**; structs (`T*`) and arrays remain. |
| `Vector!(T, ALLOC)` | Exclusive array. `opSlice` is a **borrow** — the pointer dies with the vector. |
| `Array!T` | `RefCounted` vector. Share this, not a raw `Vector`. Default `ALLOC` is `ThreadMem`. |
| `RefCounted` / `Unique` | Shared / exclusive ownership through `ObjectAllocator`. |
| `freeze` / `unfreeze` | Move the **top** pool off the active stack so nested code sees `PoolStack.empty`. |

`ScopedPool.freeze` `enforce`s/`assert`s it is the highest on the stack. Nested freeze of a non-top pool is not supported. `PoolStack.disable` / `enable` freeze/unfreeze everything.

Host `ScopedPool` is `RefCounted!ScopedPoolImpl`. Wasm `ScopedPool` **is** `ScopedPoolImpl` (a value). Printed IR uses the wasm alias: `auto scoped = ScopedPool(m_pool);`.

Phobos `std.typecons.scoped!T()` is a **different** tool (stack-allocated class). It is not the pool. Do not print it as a substitute for `ScopedPool`. Do not document it as taking precedence over `PoolStack`.

### 2. libwasm — druntime falls through to `rt/memory.d`

`mixin Spa!App` injects `_start` (`spa.d:119-146`):

1. `alloc_init(heap_base)` — `WasmAllocator.init` (`rt/allocator.d:130-135`): bump from `__heap_base`, `end` = current wasm pages.
2. `PoolStack.initialize()` — empty stacks + empty freezer. **No default pool is pushed.**
3. `application.compile()` / `registerRoutes()` / `render`.

**WasmAllocator** (`rt/allocator.d:121-160`) grows in 64 KiB pages via `memory.grow`. `deallocate` returns `true` and does nothing. Comment: “we rely on memutils to deallocate stuff.”

**Language `new` does not see the pool.** `rt/memory.d` implements the C ABI the frontend emits:

| Frontend / runtime | Symbol | Backend |
|---|---|---|
| `new C()` | `_d_allocclass` / `_d_newclass` | `wasm_malloc` → WasmAllocator |
| `new T[]` | `_d_newarrayU` / `_d_newarrayT` | `wasm_malloc` |
| `arr ~= …` | `_d_arrayappendcTX` | **new** `wasm_malloc`, copy, abandon old |
| C `malloc` | `malloc` | `wasm_malloc` |
| C `free` | `free` | empty |
| | `wasm_free` | `WasmAllocator.deallocate` + `memset` |

Every one of those is a **process-lifetime bump**. Printing `new string[]` or `~=` on a Phobos array inside a click handler grows linear memory forever.

**Pool-aware fall-through** lives next door (`rt/allocator.d:190-232`):

```
allocString / _d_allocmemory / gc_malloc / gc_calloc / gc_qalloc
    if (!PoolStack.empty)  PoolStack.top.alloc(...)
    else                   FL_allocate → ThreadMem
```

Closures (`_d_allocmemory`) and JS-bound strings (`allocString`) therefore **join the live `ScopedPool`**. `gc_realloc` allocates a fresh block (pool or ThreadMem) and copies; it does not free the old one.

`ThreadMemAllocator` / `PoolStackAllocator` (`rt/allocator.d:234-279`) are the typed façades Lodash `FL_allocate` and pool callers use.

HMR `dumpApp` / `loadApp` **skip** `ManagedPool` fields. The pool is not serialized. List items allocate with `ThreadMemAllocator` + `Item.init` (not the pool).

### 3. How the engine already scopes

**App** (`svelte-engine/src-d/app.d:120-125`, slideshow3dai the same):

```d
ManagedPool m_pool;
void construct() { m_pool = ManagedPool(64 * 1024); }
```

The field is the long-lived slab owner. It is **not** on `PoolStack` until something constructs `ScopedPool(m_pool)`.

**URLRouter** (`router.d:181-186`, `:269`, `:380`, `:432`, `:459-463`, `:483`) is the canonical command scope:

- `m_pool = ManagedPool(64*1024)` in `this()`.
- `register`, `navigateTo`, `iterate`, `handleLinkEvent`, `onPopState` each open `auto scoped = ScopedPool(m_pool);`.
- Persistent state is `Array!Route`, `Array!char` for URL/title — **ThreadMem `Array`**, not a pool slice.
- `handleLinkEvent` **nests** a throwaway `auto pool = ScopedPool();` around `Node` / `HTMLLinkElement` work so those bindings temps die even if the outer pool is reused.
- `new Route(...)` is a language-`new` class: it is meant to live on `m_routes`. Do not allocate a `Route` as a pool object.

At rest (`PoolStack.empty`) `gc_malloc` / `allocString` go to ThreadMem. That is correct for App-lifetime strings. It is **wrong** for a handler that concatenates, runs `Lodash.execute!T()`, or rebuilds a list — those must push a scope first.

### 4. Practices for memory-correct printed D IR

The AST is still NodeDef / `@child` / `@prop` / Slot / `@connect` / `@inject` / `UnorderedList` ([ast-ir.md](ast-ir.md), [udas.md](udas.md)). Those structs are **value fields on `App`**. `compile!()` does not heap-allocate the UI. Memory rules apply to **procedural** arms and to anything a method stores back onto that graph.

#### Precedence (construction)

1. If a `ScopedPool` is the `PoolStack` top, `alloc`, `_d_allocmemory`, `gc_*`, and `allocString` use it.
2. Else ThreadMem (`FL_allocate`).
3. Language `new` / `_d_newarray*` / Phobos `~=` always use WasmAllocator. They never join a pool.

Print (1) for transient work. Print (2) for App-lifetime containers (`Array`, `Vector`, `ManagedPool` itself). Do not print (3) for anything a handler can run more than once.

#### Scope every heavy-allocating command

Wrap the **body** of:

- `@connect` handlers (`go`, list-item slots, dock navigate)
- `{#each}` rebuild / `HTMLArray.put` / `assignEventListeners` helpers
- Lodash chains that `execute!T()` into strings or arrays
- bindings that materialise strings (`libwasm_get__string`, `el.href`, `location.pathname`)
- `this.update` paths that format or concatenate
- router entering/leaving (already wrapped in `router.d`; do not unwrap)

```d
@connect!"goButton.click"
void go()
{
    auto scoped = ScopedPool(m_pool);   // reuse App.m_pool
    auto tmp = execute!string(chain);   // pool (via allocString / _d_allocmemory)
    msg = tmp.idup;                     // or copy into Array!char / struct field
    this.update.msg;
} // ~scoped: temps gone; msg must not alias the pool
```

Prefer `ScopedPool(m_pool)` (reuse App / router slabs) over `ScopedPool()` (new 64 KiB set every call) unless the work must not collide with an outer reuse of `m_pool` — that is the `handleLinkEvent` nested-`ScopedPool()` pattern.

Do **not** wrap `construct`, `compile!`, `registerRoutes` wiring, or the `Spa` `_start` path in a throwaway pool: `@connect` delegates and `NamedNode` handles must outlive the command. Create `ManagedPool` **in `construct`**. Scope commands in `onMount` / `ready` / `@connect` / list rebuild. See [AGENTS-D-IR-lifetime.md](AGENTS-D-IR-lifetime.md) for which hook owns which lifetime.

#### Copy survivors into proper structures

A pool pointer is invalid after `~ScopedPool`. Copy **before** the scope ends:

| What must live | Copy into |
|---|---|
| Scalar shown in the UI | `@prop` / parent field on the NodeDef struct (`string` via `.idup` or `Array!char` assign, never a pool slice) |
| List contents | item **structs** (`UnorderedList!Item` / `HTMLArray.put` of values). Item fields are the IR. |
| Long-lived table / URL / title | `Array!T` or `Vector!(T, ThreadMem)` on the owning struct (router golden) |
| Delegate / Slot / EventEmitter | fields the `compile!()` walk already owns. Allocate those **outside** the pool, or `freeze` first. |
| JS `Handle` | already a uint; do not pool-allocate the handle table |

`Vector.opSlice` / `Array.opSlice` is a borrow. `val = data[]` then letting the vector die is a use-after-free (memutils README). Escape with `.idup`, `clone`, or assign into another `Array`/`Vector`.

`copy(arr)` in `scoped.d` copies **into the current pool**. That is for extending a temp, not for escaping one. Escape with ThreadMem / `.idup` / a field on a `compile!()` struct.

#### freeze / unfreeze when the nested alloc must outlive the scope

Use this when a scoped command must create a **long-lived** object (new list item, new `Route`, a delegate stored on a Slot, a `ManagedPool`-backed structure that is *not* this pool):

```d
auto scoped = ScopedPool(m_pool);
// … temps …
scoped.freeze();                    // PoolStack.empty → ThreadMem / language new
items.put(Item(copiedName, &this)); // compile! item + inject host; not a pool object
scoped.unfreeze();
// … more temps …
```

Rules:

- Freeze only the **top** pool (`ScopedPool.freeze` asserts `id == PoolStack.top.id`).
- Pair every `freeze` with `unfreeze` on the same scope object.
- After freeze, pool-aware alloc falls through to ThreadMem; language `new` still hits WasmAllocator. Prefer `Array` / `alloc` after freeze for recyclable long-lived data.
- Do **not** invent a TLS “bypass” flag. The freezer is that flag (`lifetime.md`).

`PoolStack.disable` / `enable` is the “freeze everything” form. Do not print it around a single handler.

#### What the printer must not emit

- `new T[]`, Phobos `~=`, or `_d_arrayappendcTX`-shaped growth in a handler.
- Storing `alloc!(char[])` / `allocString` results on `@prop` / `@child` without copying off the pool.
- `ScopedPool` around `compile!` / Slot wiring / item ctors that plant parent pointers — unless those allocations are then copied or the pool is frozen.
- Phobos `scoped!Widget()` as the component model. Components are **structs** with `mixin NodeDef`.
- Host-only `AppMem` / GC `new` as the wasm story.
- A second bump allocator or a JS-side arena.

#### Ownership picture for one printed component

```
struct ClickField {          // value on App; compile!() identity
  string msg;                // ThreadMem / .idup / field — NOT a pool slice
  @child GoButton goButton;
  ManagedPool* pool;         // or reach App.m_pool via inject / outer
  @connect!"goButton.click"
  void go() {
    auto scoped = ScopedPool(*pool);
    // heavy work
    msg = surviving.idup;
    this.update.msg;
  }
}
```

`compile!` / `unmount` attach and detach the **graph**. They do not free `m_pool`. Detach of a list item (`HTMLArray.remove`) must not leave a pointer into a popped pool; item data was copied into the item struct when it was `put`.

## Loci

**memutils (host, architecture of record)**  
`riscv-dev/memutils/architecture/{allocators,lifetime,containers}.md`  
`riscv-dev/memutils/source/memutils/pool.d:16-196` — bump, no-op `free`, `onDestroy`  
`riscv-dev/memutils/source/memutils/scoped.d:21-59` — `ScopedPool` / freeze  
`riscv-dev/memutils/source/memutils/scoped.d:61-152` — `alloc` / `realloc` / `copy`  
`riscv-dev/memutils/source/memutils/scoped.d:154-270` — `PoolStack`  
`riscv-dev/memutils/source/memutils/utils.d:40-98` — `ObjectAllocator` `PoolStack` branch  
`riscv-dev/memutils/README.md:11-26` — `alloc!T` + `ScopedPool` promise  

**memutils-wasm (what printed IR links)**  
`riscv-compilers/libwasm/memutils-wasm/source/memutils/scoped.d:16-49` — value `ScopedPool`, freeze  
`riscv-compilers/libwasm/memutils-wasm/source/memutils/scoped.d:70-133` — `alloc`/`copy` (class `alloc` commented out)  
`riscv-compilers/libwasm/memutils-wasm/source/memutils/scoped.d:135-215` — `PoolStack.initialize`, no fiber stack  
`riscv-compilers/libwasm/memutils-wasm/source/memutils/pool.d:42-117` — `alloc`/`realloc`/`free` (`must_zeroise`)  
`riscv-compilers/libwasm/memutils-wasm/source/memutils/memory.d:16-64` — `MallocAllocator` → `wasm_malloc`  
`riscv-compilers/libwasm/memutils-wasm/source/memutils/utils.d:84-154` — `ObjectAllocator` `PoolStack`  

**libwasm fall-through**  
`source/libwasm/rt/memory.d:26-153` — `alloc_init`, `_d_allocclass`, `_d_newarray*`, `wasm_malloc`, empty `free`  
`source/libwasm/rt/allocator.d:121-160` — `WasmAllocator` bump + grow  
`source/libwasm/rt/allocator.d:190-232` — `allocString`, `_d_allocmemory`, `gc_*` **prefer `PoolStack.top`**  
`source/libwasm/spa.d:119-146` — `alloc_init` + `PoolStack.initialize`  
`source/libwasm/router.d:181-186,269,380,432,459-463,483` — `ManagedPool` + per-command `ScopedPool`  
`source/libwasm/hmr.d:31-32,220-221` — skip `ManagedPool`  
`architecture/js-events-memory.md` — handle table + bump (does not restate pool precedence)  

**Engine goldens the printer must match**  
`svelte-engine/src-d/app.d:120-125` — `App.m_pool`  
`slideshow3dai/src-d/app.d:103-108` — same  

**svelte-D**  
[ast-ir.md](ast-ir.md) — AST ≡ D IR (structure; this note is the allocator for procedural arms)  
[udas.md](udas.md) — compile! / detach (graph lifetime ≠ pool lifetime)  
[frontend-libwasm.md](frontend-libwasm.md) — Spa boot; already notes “pools, not `new` trees”

## Invariants

- A live `ScopedPool` is the **precedent** allocator for `alloc` / `_d_allocmemory` / `gc_malloc` / `allocString`. (construction of `rt/allocator.d:195-213` and `memutils.scoped.alloc`)
- Language `new` / `_d_newarray*` / Phobos array append **never** join `PoolStack`. They bump `WasmAllocator` and are not recycled. (construction of `rt/memory.d`)
- `PoolAllocator.free` does not recycle bytes. Exiting the `ScopedPool` is the free. (construction)
- `PoolStack.initialize()` runs once in `_start` before any `ScopedPool`. (construction of `spa.d:126`)
- `App.m_pool` / `URLRouter.m_pool` exist as `ManagedPool(64*1024)` and are pushed only by `ScopedPool(m_pool)`. (convention of engine goldens; construction once the printer emits them)
- Data that outlives a command is not a pointer/slice into that command’s pool. Copy into a `compile!()` field, `Array`/`Vector` (ThreadMem), or allocate after `freeze`. (construction of functional correctness)
- `Vector`/`Array` `opSlice` is a borrow. (construction; use-after-free if stored)
- `ScopedPool.freeze` applies only to the top pool. (construction)
- Fiber vs thread stacks do not exist on wasm; do not print fiber-pool APIs. (construction of `memutils-wasm`)
- HMR does not dump `ManagedPool`. (construction of `hmr.d`)
- wasm `alloc!T` for classes is not available; printed long-lived classes use language `new` (intentionally bump) or are avoided in favour of structs. (construction of `memutils-wasm/scoped.d`)
- Two cells stay two cells: host memutils may `new` when the stack is empty; printed wasm IR must not rely on that fallback. (construction)

## Extension points

- A new **heavy method** the printer emits (Lodash helper, `{#each}` rebuild, bindings fetch) gets a `ScopedPool` at the function entry and an explicit copy-out. Do not add a global “always-on” pool in `_start`.
- A new **long-lived container** on a component is `Array!T` / `Vector!(T, ThreadMem)` / a field on the NodeDef struct, not a pool slice.
- A new **libwasm allocation hook** (`gc_*`, string export, closure) must check `PoolStack.empty` the same way `allocString` does. Do not send it only to `wasm_malloc`.
- Changing slab size is `ManagedPool(n)` at App/router construct, not a hard-coded printer constant elsewhere.
- Host-cell vibe.0 printers may use host memutils `ScopedPool` the same way; they still copy survivors out. They may fall back to `new` when no pool is pushed.

## Did not close

Whether svelte-d should **auto-insert** `ScopedPool(m_pool)` around every printed `@connect` / list helper, or only document the pattern until T3 grows a printer pass (v1: document + match goldens; auto-wrap is a later printer arm). Whether `App.m_pool` is injected into child structs (`@inject!"pool"`) or children call a package-level `appPool()`. Whether list `put` should freeze by default (safer for item ctors) or require the author to copy fields first. Whether `_d_newarray*` should be taught to prefer `PoolStack` (that is a **libwasm seam**, not a svelte-d invention).
