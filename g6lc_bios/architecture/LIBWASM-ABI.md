# libwasm host ABI — full surface and completion plan

**Status: this is mostly a plan document.** It inventories the *complete*
libwasm host-import surface, states exactly which parts the BIOS implements
today, and sequences the remaining work. Only stages marked **landed** in §8
are implemented; do not cite any other row as a capability.

Landed so far: **B61** (refcounted object table), **B62** (scalar
box/unbox for all signed/unsigned integer widths, `bool`, `f32`, `f64`, and
`int[]`/`uint[]` vectors), **B63** (object property map in `LibwasmValue`,
`libwasm_get__field` / `libwasm_get_idx__field` boxed lookup, a generic
`Host::object_getter` / `Host::object_call` model, full `Object_Getter__*` /
`Object_Call__*` ABI dispatch in `g6b-wasm::Runtime`, and the D/browser host
bindings: `g6b_kernel.d` exposes the core `Object_Getter__*` / `Object_Call__*`
family as host imports, `browser-ui/compiler/wasm-cell.ts` verifies their
signatures, and `browser-ui/src/kernel.ts` provides fail-closed JS handlers with
Bun tests), **B64** (`Optional!T` sret returns: `Object_Getter__Optional{Handle,
Uint, Double, String, Bool}` and `Object_Call_*__Optional{Handle, String}` wired
end-to-end in the Rust runtime, D imports, JS host, verifier, and the LDC 1.43
artifact), **B65** (bounded first-party JSON codec: `JSON_parse_string` /
`JSON_stringify` in `g6b-wasm::Runtime`, plus all twelve `Object_VarArgCall__*`
imports with an `argsdef` descriptor parser that supports `Optional!T`,
`SumType!(...)`, and scalar types; wired through the Rust runtime, D imports, JS
host, verifier, and the LDC 1.43 artifact), **B67's Lodash backend**
(command-buffer parser, `JsValue` evaluator, guest-iteratee dispatch), and
**B67/B68 Moment, getTimeStamp, typed-array and promise-combinator** host
imports. Open: the full Moment method set and `Object_VarArgCall__*`.

Scope boundary: the BIOS never compiles `kernel-spec/libwasm`. The compiled tree
is the **`g6lc_bios/libwasm` submodule on its `g6lc_bios` branch**
(`etcimon/libwasm`, branched from v0.11.1), built with `--config=g6lc-bios`.
That configuration sets `version(G6LC_G6B)`, which replaces the JS import table
with the g6b kernel boundary in `libwasm/source/libwasm/types.d`.

This supersedes the retired untracked clone at `browser-ui/libwasm`, which was
pinned at v0.9.0-11 (`02f21a6`) and had drifted from upstream without review.
The customizations are now commits on a branch of the real repository, so the
delta against upstream is diffable; see `kernel-spec/README.md` for the
submodule-versus-vendored policy and the exact list of changes.

### 0.1 Pinned compiler

The artifact is produced by exactly one upstream release, pinned in
`browser-ui/toolchains/ldc.lock.json`:

| | |
|---|---|
| release | `v1.43.0-beta1`, `github.com/ldc-developers/ldc` |
| frontend | DMD 2.113.0 — the version `libwasm/runtime-v1.43.0` targets |
| integrity | upstream `ldc2-1.43.0-beta1.sha256sums.txt` digest, checked before extraction |
| install | `bun scripts/install-ldc.ts` into `browser-ui/toolchains/<asset-dir>/` |
| DUB | bundled with the release, so the LDC/DUB pair is never mixed |

This is a correctness requirement, not convenience: `cellInputHash` in
`browser-ui/compiler/wasm-cell.ts` hashes the **compiler binary** along with
the D/runtime/adapter sources, so a different 1.43 build (for example a
host-compiled `1.43.0-git-<sha>`) yields a different `inputs` digest and marks
a shipped `out/bios-ui-libwasm.wasm` stale. `compiler/ldc.ts` therefore
prefers the pinned tree over any ambient toolchain, and `resolveToolchain()`
reports `pinned` so the build log states which compiler was used. The pinned
version is recorded in the artifact provenance
(`svelte-engine-ws/.svelte-d/wasm-artifact.json` `compiler` field).

The `addon-wasi` package is not pinned: the cell links `-defaultlib=` against
the carried `runtime-v1.43.0`, so no prebuilt WASI druntime/phobos is linked.
A host with no published LDC build is refused with that message; the
first-party `out/bios-ui.wasm` lane needs no D toolchain at all.

## 1. The surface, measured

`types.d` declares **116** distinct `extern(C)` host imports. Every one of the
684 files under `libwasm/source/libwasm/bindings/` is generated against that
one table — there is no second FFI. Family sizes:

| Family | Count | Shape |
|---|---|---|
| `Object_Call_*` | 26 | `(Handle recv, string method, …args) -> void\|Handle\|bool\|string\|Optional!T` |
| `libwasm_add__*` | 15 | box a D scalar/array/string/`{}` into the object table -> `Handle` |
| `libwasm_get__*` | 14 | unbox a `Handle` back to a D scalar/string |
| `Object_Getter__*` | 14 | `(Handle recv, string prop) -> T` |
| `ldexec_*` | 12 | Lodash chain execution (`§5`) |
| `Object_VarArgCall__*` | 12 | `(Handle, string method, string argsdef, string argsJSON) -> T` |
| typed arrays | 5 | `DataView_Create`, `{Uint8,Int8,Int32,Float32}Array_Create` over guest memory |
| timers | 4 | `setTimeout` / `setInterval` / `clearTimeout` / `clearInterval` |
| promise combinators | 3 | `libasync_promise_{all,any,allsettled}__promise` |
| `JSON_*` | 2 | `JSON_parse_string`, `JSON_stringify` |
| `Static_Call_*` | 2 | `(string ns, string method, …)` — no receiver |
| misc | 7 | `libwasm_copyObjectRef`, `libwasm_removeObject`, `libwasm_await__void`, `libwasm_set__function`, `libwasm_unset__function`, `doLog`, `getTimeStamp` |

Frequency of *use* across `bindings/**` (grep counts, not declarations) shows
where the value is concentrated:

```
2035  Serialize_Object_VarArgCall   (D template → Object_VarArgCall__*)
1332  Object_Getter__Handle          967  Object_Call_string__void
1134  Object_Getter__string          838  Object_Call_EventHandler__void
 838  Object_Getter__EventHandler    579  Object_Getter__bool
 447  Object_Call_Handle__void       431  Object_Getter__OptionalHandle
 425  libwasm_add__object            401  Object_Getter__uint
 384  Object_Getter__int             353  Object_Call_bool__void
 329  Object_Call__void              295  Object_Getter__double
```

Two conclusions follow, and they drive the whole plan:

1. **Eleven import names cover the overwhelming majority of all bindings.**
   `Object_Getter__{Handle,string,bool,int,uint,double}`,
   `Object_Call_{string,bool,int,uint,Handle,double}__void`,
   `Object_Call_string__Handle`, `libwasm_add__object`,
   `libwasm_removeObject`, `libwasm_copyObjectRef`. Implementing that core
   makes most of the 684 binding files *link*, independently of whether the
   named property exists.
2. **`Object_VarArgCall__*` is the single most-used path** and it is the one
   that requires a JSON codec on both sides. It is not optional if overload
   resolution with `Optional!T` / `SumType` arguments is wanted.

## 2. Lowered WASM signatures

These are the rules LDC applies to the `extern(C)` declarations; the host must
match them exactly or the module traps.

| D type | WASM lowering |
|---|---|
| `Handle` (`alias Handle = uint`, `types.d:23`) | one `i32` |
| `string` **parameter** | two `i32`: `(length, pointer)` — **length first** |
| `string` **return** | sret: a leading `i32` `rawResult` out-pointer; callee writes `{i32 length; i32 ptr}` |
| `Optional!string` return | sret; `{i32 length; i32 ptr}` payload plus a presence `bool` written at `rawResult + 4` by the host |
| `Optional!Handle/uint/double/bool` return | sret; payload at `rawResult`, presence flag after it |
| `bool` | `i32` (0/1) |
| `int`/`uint`/`short`/`ushort`/`byte`/`ubyte` | `i32` |
| `long`/`ulong` | `i64` |
| `float` | `f32`; `double` | `f64` |
| `T[]` slice parameter | two `i32`: `(length, pointer)` |
| `delegate` parameter | two `i32`: `(contextPtr, funcPtr)` |

The `(length, pointer)` order is the **opposite** of the first-party MVP
encoder's `(ptr, len)` convention. Both orders currently exist in
`g6b-wasm::call_import` and that is deliberate: `env.fetch`/`env.holyc` are
g6b-native imports, `libwasm_add__string` is libwasm-native. Any new import
added from this table takes the libwasm order.

Evidence for the delegate lowering is `types.d:329-349`: `jsCallback(uint ctx,
uint fun, Handle arg)` reconstructs a `void delegate(Handle)` by writing `ctx`
into `contextPtr` and `fun` into `funcPtr` of a union — so the host stores the
pair verbatim and hands both back.

## 3. The handle model

`Handle` is a `uint` index into a **host-owned** object table. D never holds a
JS pointer. `struct JsHandle` (`types.d:454-490`) makes ownership explicit:

- destructor calls `libwasm_removeObject(handle)` **when `handle > 2`**;
- copy construction calls `libwasm_copyObjectRef(rhs.handle)`;
- `opAssign` moves and zeroes the source.

So handles **1** and **2** are permanently-live roots that must never be freed
— in a browser those are `document` and `window`. This is explicit refcounting,
not garbage collection: a host that ignores `libwasm_copyObjectRef` will free
live objects, and a host that ignores `libwasm_removeObject` leaks. The current
g6b browser host allocates object handles from `0x0010_0000` and never frees;
that is a bounded-lifetime shortcut, not the libwasm contract.

svelte-engine is the spec: `{1: document, 2: window}`. The BIOS kernel is
**not** the type hook (`architecture/BROWSER-RUNTIME.md`). `JsExports` is
`window.__svelteD.ts`. The G6LC_G6B `getRoot() → 1` mount is transitional.

For the BIOS the two DOM-handle roots are **not** BoardSpec:

| Handle | g6b meaning |
|---|---|
| `1` | Spa mount (`#libwasm-root` stand-in) until LDC `getRoot` matches svelte-engine |
| `2` | first `createElement` (svelte-engine would have reserved this for `window`) |
| `libwasm_global("document"\|"window"\|"console")` | interned UI-thread objects at `OBJECT_BASE+` |

`version(G6LC_G6B)` replaces the JS import table with the g6b host boundary.
It does **not** mean handle 2 is BoardSpec. Bindings that want `window` must
call `libwasm_global("window")` (or, after the next LDC rebuild, use the
svelte-engine `{1,2}` roots).

## 4. Events

`alias EventHandlerNonNull = Any delegate(Event)` and
`alias EventHandler = Optional!(EventHandlerNonNull)`
(`bindings/EventHandler.d:37-38`). Registration is
`Object_Call_EventHandler__void(Handle recv, string prop, bool present, scope
EventHandlerNonNull cb)` — lowered to `(i32 recv, i32 len, i32 ptr, i32
present, i32 ctx, i32 funcPtr)`.

Delivery is the reverse: the host calls the WASM export
**`jsCallback(ctx, fun, argHandle)`** (`types.d:326-349`), where `argHandle` is
an object-table handle wrapping the `Event`. `libwasm_set__function(name, ctx,
ptr)` / `libwasm_unset__function(name)` are the named-callback variant used by
`exportDelegate`, dispatched through the same `jsCallback` export.

This is the seam that makes libwasm *reactive* rather than
initialization-only. **B91c** closes it on the BIOS host: after `_start`,
virtio-input / UI-hart events re-enter through `jsCallback` (or the
indirect table). Re-entry still serializes against an in-flight `_start`
rewind — GuestCellLive only delivers input after `_start` has finished.

## 5. Lodash and Moment

Neither is a second runtime. `lodash.d` builds a *command buffer* and ships it
through the twelve `ldexec_*` imports; `moment.d` is a thin `Lodash` wrapper
(`m_ld.defaultTo(Eval("moment"))` then `attempt`/`invoke`/`execute`). The
signature family is:

```
R ldexec_<InitType>__<R>(init…, string commandsJSON,
                         bool delegate() predicate,
                         void delegate(Handle) onError
                         [, bool mustEvalInitVal])
```

`commandsJSON` is a JSON array; each element is either
`{"local": name, "value": v}` (bind a temporary) or
`{"func": name, "params": [...]}` (a chain step). Parameter strings carry a
one-character type sigil: `=true` / `=false` / `=null` / `=undefined` /
`=123` / `=(...)` for a function expression, `\=` to escape a literal that
starts with `=`, and a bare string otherwise. `VarType` (`lodash.d:14-26`)
discriminates the chain's initial value; `mustEvalInitVal` says whether the
init string is a JS expression to evaluate rather than a literal.

**This is where ES6 enters. An earlier revision of this document got the
resolution wrong and the correction matters.**

The reference JS implementation of `ldexec` (`bindings.ts:1076-1229`) calls
`eval()` on `=(...)` parameters and on the init value, and resolves bare names
with `_.get(window, …)`. A BIOS cannot ship that. The earlier text concluded
"arrow functions are refused; Tier A still covers `map` / `filter` / `find`".
**That conclusion was false.** Read `lodash.d:606,614,621,628,635`: when a
Lodash iteratee is a D delegate, libwasm's own `putLocal` *emits an arrow
function* as the parameter —

```js
(o,s)=>{let hndl=ao(o);let str=es(0,s,null,true);return !!sifg(cbPtr)(cbCtx,str[0],str[1],hndl);}
```

So refusing arrow functions refuses every predicate-taking method, which is
most of Lodash's value. The two claims could not both hold.

The actual resolution is better than either. Those five strings are **fixed,
compiler-generated, and identical every time** — they are not user JavaScript,
and all five do the same thing: box the arguments, call the guest's
`__indirect_function_table` at `cbPtr` with `cbCtx`, coerce to `bool`. The host
therefore **recognises them by identity and dispatches into the guest**. The
iteratee executes in wasm, where the D delegate already lives.

That is the contract, and it is what "lodash pipes through a JS backend in
wasm" means concretely:

| Payload | Host behaviour |
|---|---|
| a value sigil (`=true`, `=null`, `=42`, `\=literal`, bare string) | decoded to a `JsValue` |
| one of the five generated iteratee boilerplates, or `=cb` | bound to the guest function table — **executed in wasm** |
| `=window.pglite` / `=pglite` / `=moment` / `=window.moment` | `Param::HostName` — interned **before** `step` via `HostDispatch::intern_name` (never eval'd). `pglite` is `ObjectKind::StoreFactory` when `kernel.store.enable`; `moment` is still `UnsupportedMethod` |
| any other `=(…)`, `=name`, or `…;` | **refused** — `LodashError::EvalRefused` |
| a `VarType.eval` chain seed | **refused** — there is no host evaluator (`window.__svelteD.ts` is the one special-cased seed) |

`eval` is still absent. What changed is that its absence no longer costs the
iteratee half of the library.

Moment then works without a date library: `format` / `utc` / `startOf` /
`add` / `diff` lower to `invoke` steps that a first-party host implements
against `getTimeStamp()` and a fixed strftime-shaped formatter. `getTimeStamp`
itself is the SBI `rdtime`-derived clock in the guest lane and `Date.now()` in
the browser lane. Neither is implemented yet.

## 5b. The three hosts, and the pglite chain through them

The same cell, the same imports, **three** implementations with deliberately
different completeness. Most confusion about this ABI is really confusion
about which host is running, so name it first.

| Host | Where | Store | Completeness |
|---|---|---|---|
| `KernelHost` | `g6b-kernel/src/lib.rs` (`impl Host`) — the BIOS, under QEMU | **real** `g6b-pglite` | lodash, pglite and `platform.*` genuinely implemented |
| `createLibwasmHost` | `browser-ui/src/kernel.ts` — the browser | `fetch` proxy to `/bios/store/*` | DOM real; sync lodash path degrades the store |
| `verifyLibwasmStartup` | `browser-ui/compiler/wasm-cell.ts` — build time | degraded | minimal **on purpose**: proves ABI + that `_start` completes |

### The `Eval` allow-list is the security boundary

`HostDispatch::intern_name` (`g6b-kernel/src/lib.rs`) resolves a host *name*;
it never evaluates anything:

| Name | Result |
|---|---|
| `window.pglite` \| `pglite` | `ObjectKind::StoreFactory` handle — **only if `spec.kernel.store.enable`**, else `EvalRefused` |
| `window.platform` \| `platform` | `ObjectKind::Platform` handle |
| `window.hw` \| `hw` | `EvalRefused("hw is platform.hw, not a window global")` |
| `moment` \| `window.moment` | `UnsupportedMethod` |
| anything else | `EvalRefused` |

`platform.*` is a lazily-interned tree memoised onto `window.platform`, and
it emits a `WASM-JS-GLOBAL platform -> N` diagnostic — the cheapest available
proof on a serial log that the cell reached the host at all:

```
platform
└── hw              (__role="root")
    ├── net ──┬── tcp
    │         └── udp
    └── display ── gl
```

### The store state machine

`libwasm/source/libwasm/pglite.d` never calls a store method directly. It
builds a `Lodash` chain and ships it through `ldexec_*`:

```
PgLite(dataDir)                 -> Lodash(); defaultTo(Eval("window.pglite")); attempt(dataDir)
   │
   ├─ intern_name("window.pglite")  ──►  StoreFactory handle
   ├─ attempt(dataDir)              ──►  factory_attempt  ──► Store handle {uuid}
   └─ invoke(method, args…)         ──►  store_method     ──► real SQL via StoreRegistry
```

`store_method` implements `query`/`queryAsync`, `exec`,
`begin`/`commit`/`rollback`, `close`, `waitReady`/`stat`/`statAsync`, `dump`,
`load`, `listen`/`unlisten`/`notifies` and `export`. Only `sql` /
`transaction` return `NotImplemented("callback")`.

Note the re-entry detail, because it caused a real bug: `PGLite.save()`
*interns the chain result as a handle* and starts the next chain from it
(`m_ld = Lodash(m_saved, VarType.handle)`). So a degraded result is the
accumulator for every subsequent call in the same session.

### Degradation must be idempotent

`kernel.ts`'s lodash interpreter is synchronous and `newBiosStore` is async, so
it cannot service a store call inline. It substitutes a well-formed sentinel:

```js
const ASYNC_STORE = JSON.stringify({ ok:false, error:"async", message:'NotImplemented("async")' });
```

Because of the `save()` re-entry above, `isStoreAcc` **must** also accept that
sentinel. Treating it as "not a store" made the *second* store call in a chain
throw `libwasm lodash method "invoke" is not implemented`, aborting `_start`
halfway through a chain the guest had written correctly. Degradation is now
idempotent: a degraded accumulator keeps answering `NotImplemented("async")`
and the cell runs to completion. Real async store work goes through Asyncify +
`newBiosStore`, or `createPgliteWasm`, never through the sync path.

The build-time verifier is subject to exactly the same rule, and must bind a
context or the cell's `Eval("window.pglite")` is refused outright. It binds
the **first-party** `createBrowserContext` (which wires `pglite` into
`bindings()` itself) rather than a mock, with a non-`main` `contextId` so a
build step never reassigns the module-level `pglite` export, and with no
`fetchFn` so a reachable fetch fails closed. `libwasm_await__void` is already
documented as a no-op when Asyncify is off (`kernel.ts`,
`// build/verification no-op`), which is what lets one cell run in a
synchronous verification host.

## 6. ES6 / JavaScript posture

`g6b-js` is a **goja-shaped ES5 subset compiled ahead of time** — bounded
statements over the BIOS DOM, plus the `compile_async` await/throw/catch
scheduler. It has no functions, no loops, no general numeric evaluation, no
arbitrary objects and no `eval`. That is a deliberate boundary, and this plan
does not move it.

What "ES6" means here is therefore precise and narrow:

| ES6 feature | BIOS position |
|---|---|
| `Promise` / `async` / `await` | **partial, in progress** — bounded slots + Asyncify (`WASM.md`); not the full job-queue/microtask model |
| `let` / `const` block scope | planned for the Lodash evaluator; `var` only today |
| template literals | planned, lowered to concatenation at compile time |
| arrow functions | not *evaluated* anywhere. The five generated Lodash iteratees are recognised by identity and dispatched to the guest (§5); any other arrow function is refused |
| classes, generators, modules, proxies, symbols | **refused** |
| `Map`/`Set`/typed arrays | `Map` host surface landed (B69) — `Map<string,string>` only, no iteration; `Set` planned; typed arrays only as views over guest memory (`*Array_Create`) |
| `JSON.parse` / `JSON.stringify` | **landed (B65)** — first-party `g6b-spec::json` codec; needed for `Object_VarArgCall__*` |

The honest summary: the BIOS is getting a **bounded object/property/event
bridge with a JSON codec and a no-eval Lodash interpreter**, not a JavaScript
engine. Any text that implies otherwise is wrong.

## 7. What exists today

Implemented in `g6b-wasm::call_import` + `g6b-kernel::KernelHost` +
`browser-ui/src/kernel.ts` + `libwasm/source/libwasm/g6b_kernel.d`:

| Import | Origin | Lane |
|---|---|---|
| `createElement`, `appendChild`, `setProperty` | g6b-native (replaces the libwasm DOM path) | host + browser |
| `fetch`, `holyc`, `register_endpoint` | g6b-native, kernel router | host + browser |
| `set_inner_text`, `set_visible`, `console_log` | MVP encoder ABI | host + browser |
| `await`, `throw`, `catch` | g6b-native bounded slots | host + guest ELF |
| `libwasm_await__void` | **libwasm** | host + browser (Asyncify) |
| `libwasm_get__string`, `libwasm_add__string` | **libwasm** | host + browser |
| `libwasm_add__object`, `libwasm_removeObject`, `libwasm_copyObjectRef` | **libwasm** (B61) | host + browser |
|| the 15 `libwasm_add__*` scalar/array box imports and 14 `libwasm_get__*` unbox imports | **libwasm** (B62) | host + browser |
|| `JSON_parse_string`, `JSON_stringify` | **libwasm** (B65) | host + browser |
|| `Object_VarArgCall__*` (12 overloads) | **libwasm** (B65) | host + browser |
| the 12 `ldexec_*` Lodash imports | **libwasm** (B67) | host + browser; guest iteratees dispatch in the browser lane only |
| `libwasm_await_{supported,failed,error,value}`, `libwasm_note_await_{ok,fail}` | g6b extension of the libwasm await contract | host + browser |
| `__cpp_exception` tag | wasm-EH | host + browser |

So of the 116 stock libwasm imports, the g6b-native DOM/router/await set, the
B61 object-lifetime set, the B62 scalar box/unbox set, the B63 typed
property/get/call set (`libwasm_get__field` / `libwasm_get_idx__field`,
`Object_Getter__*` and `Object_Call__*` in the `g6b-wasm` runtime, the D
imports in `g6b_kernel.d`, and the JS handlers in `kernel.ts`), the B64
`Optional!T` getter/call set, the B65 JSON codec and `Object_VarArgCall__*`
set, the B66 named delegate / timer / event set, the B67 Lodash set, the B67
first-party `getTimeStamp` / Moment core, the B68 promise-combinator and
typed-array / DataView `Create` set, and the B69 generic DOM method / ES6 `Map`
set are implemented and tested. `Static_Call_*` and the full Moment method set
remain `assert(0)` stubs or are absent from the wasm import list — the correct
fail-closed state, not a gap to paper over with invented return values.

### The guest-JIT lane adapts the same ABI onto `__dom` (B112)

A fourth consumer exists beside host/browser/verifier: the **in-payload JIT**
(`kernel.wasm.guest_jit`, `g6b-asm::jitr` + `g6b-asm::domt`). The shipped cell
executes `_start` as generated RISC-V and its `env.*` imports land on a fixed
`jit_ext_tab` of `Lw*`/`Domt*`/`Wasm*` routines over the `__dom`/`__dom_str`/
`__dom_id` arena — the same names, but a *generated-code* calling convention
(raw `a0..a5` and linear-memory offsets, not a Rust `Host` trait). The ABI
details that differ and must not be conflated with the host table:

- **Handle = `node_index + 1`.** `getRoot`→`1`, `createElement`→`2,3,…`;
  `0` is invalid. `createElement` takes a `NodeType` ordinal (stored biased by
  `TAG_LW` so `N_TAG!=0` keeps the node live), not a string tag.
- **String order is not uniform.** `setProperty` is `(handle, nameLen, namePtr,
  valLen, valPtr)` — len-before-ptr; `add_event_listener` is `(targetPtr,
  targetLen, eventPtr, eventLen, cb, capture)` — ptr-before-len.
- **`add_event_listener` targets an id string,** not a handle: `LwFindId`
  resolves it over the `__dom_id` side-table that `setProperty(el,"id",v)`
  populates. `N_LISTEN` is a three-band selector: `0` is the BIOS protocol
  (`g6b_listen` — the host runs fetch/select), `LSN_DEMO`(`1`) is the builtin,
  and a nonzero `cb` funcidx is biased to `0x100+idx` so `DomtKey` can route it
  back into the cell through `JitCall(funcidx,[ev])` — filling `__ev_obj` first.
  So `listener=0` still latches `N_LEV` with `N_LISTEN=0`, while a real delegate
  latches `N_LISTEN >= 0x100` and re-enters the cell on dispatch. Dispatch is
  two lanes over one `__ev_obj` record: `DomtKey` focus-fires `EV_KEYDOWN`
  (`code`=keycode) and `DomtPtr`+`DomtHit` point-fires `EV_CLICK` off the
  tablet `PTR_*` scratch (`clientX`/`clientY`=display-px, `target`=handle).
- **The `__ev_obj` record is readable through `Object_Getter__*`.** `ext_id`
  routes the i32-returning getters (`int`/`uint`/`ushort`/`bool`/`Handle`,
  `(handle,len,ptr)`) to `EXT_EVGET`→`LwEvGet`, which name-matches the property
  via `LwNameEq` and `lw`s the `__ev_obj` field — `clientX`/`clientY`/`code`/
  `detail`/`value`/`target`/`type`/`defaultPrevented` (+common aliases), with
  `cancelable`/`bubbles`/`isTrusted` constant-1. The no-arg-void
  `Object_Call_…__void` shape routes to `EXT_EVCALL`→`LwEvCall`, which sets the
  `EVO_PD` bit on `preventDefault` — read back as `defaultPrevented`. Bounded
  to the live event object (`handle` must be `&__ev_obj`); the *string* getters
  (`type`,`key`) and `float`/`double`/`Optional*` remain unmapped (`TRAP_EXT`).
- **Linear-memory offsets, not absolutes.** `fetch`/`puts`/`add__string` get the
  `__wasm_mem` base added (`LwFetch`/`LwAddStr`); the legacy `jit.rs` path
  already resolves `Addr::WasmData` absolutes, so the shim lives only in the
  `jit_ext_tab` entries.
- **`await` is resolved-sync, not a guest asyncify suspension.**
  `libwasm_await_supported`→`1`: `LwFetch` resolves every BIOS read
  synchronously off the packed `__kget` route table (`KernelGet` scans it for
  the URL), returning the entry index +1 as the promise handle;
  `libwasm_await__void`/`libwasm_await_value` then resolve that slot to the
  body string — correct semantics because the fetch is already resolved.
  `await_failed`/`await_error` stay fail-closed.
- **The Stage-3 op-coverage gate is `op_coverage`.** `g6b_wasm::op_coverage`
  lowers the whole module (shared `lower_one`, the same records `encode`
  packs) and walks the re-entrable set — `_start` + func exports +
  element-table funcs — reporting `TRAP_UNSUP`/`TRAP_EXT`/`TRAP_BADFUNC` as
  `OpGap`s. With cross-function wasm-EH now lowered (below), the shipped cell
  is **fully clean**: 252 funcs, 239 reachable, **zero** blocking gaps.
  `shipped_cell_op_coverage_report` asserts `cov.clean()`.
- **Cross-function wasm-EH unwinds through the call boundary.** A `throw` that
  escapes its function is no longer `TRAP_UNSUP`: `R_THROW` stores the tag to
  `OFF_EXCTAG`, sets `OFF_EXC`, folds its frame (`s10=s11`; `ld ra,8(sp)`;
  `ld s11,0(sp)`; `sp+=16`; `jalr ra`) and returns into the caller's post-call
  `R_EXCCHK`. That check — emitted after every `call`/`call_indirect` — reads
  `OFF_EXC` and, when set, either jumps to the statically-resolved innermost
  enclosing `catch` head (an `R_EXCCLR` that clears `OFF_EXC`) or re-emits the
  frame-fold tail to propagate the unwind up a frame (`a=u32::MAX`). A `throw`
  that escapes the *entry* frame surfaces at `jit_after`/`jit_call_done` as
  `jit_trap(TRAP_EXC)` (`WASM-JIT-TRAP 11 <tag>`), which consumes `OFF_EXC`
  before resuming so the continuation can't re-fire. Gates:
  `guest_jit_cross_func_throw` (callee `throw` → caller `catch_all` → result),
  `guest_jit_uncaught_throw` (top-frame `throw` → `TRAP_EXC`). Bounded: the
  first `catch`/`catch_all` wins regardless of tag (no tag dispatch — the
  shipped cell's `catch_all` lane is unaffected).

Exec-model evidence (`guest_jit_executes_shipped_cell`): 252 funcs translate,
`_start` completes, `domt_next=56 live=56 ids=47 listen=8`, and `DomtRaster`
paints the cell's own tree into `__scan_fb` with no `DomtBoot` fallback. QEMU
verification landed in B118 (input→`H_WST`→`DlPaint`→scanout on real
virtio-gpu); listener re-entry landed in B114–B116 and was **real-QEMU-verified
in B120** — `jit_cell="delegate"` (`delegate_key_cell`) registers a `keydown`
funcidx listener on the root (default `H_FOCUS`), and a `send-key` press
re-entered the cell through `DomtKey`→`JitCall`, growing `__dom` and repainting
a new row (14,713 px scanout delta, no traps). The pointer/click lane
(`DomtPtr`→`JitCall`) is identical machinery but not QEMU-driven: `-display
none` can't steer `virtio-tablet` reliably (see the B120 todo entry).

## 8. Completion plan

Each stage is independently landable and independently verifiable with
`python tools/g6b.py check` + `regress`. Stages are ordered by
bindings-unblocked per unit of risk.

### B61 — object table with real lifetimes — **landed**

`crates/g6b-wasm/src/objects.rs` is the shared `ObjectTable<T>`: bounded at
4,096 live objects, refcounted, with a slot freelist. `KernelHost` and the
g6b-wasm `TestHost` both use it; `createLibwasmHost` mirrors it in TypeScript.
`libwasm_add__object`, `libwasm_removeObject` and `libwasm_copyObjectRef` are
declared in `g6b_kernel.d`, dispatched in `call_import`, and verified by
`wasm-cell.ts`.

Semantics, matching `struct JsHandle`:

| Operation | Behaviour |
|---|---|
| `add` | new slot, refcount 1; reuses a freed slot before growing |
| `copyObjectRef(h)` | refcount + 1, returns **the same handle** |
| `copyObjectRef(root)` | identity, unrefcounted |
| `removeObject(h)` | refcount − 1; releases and frees the slot at zero |
| `removeObject(root)` | error — `handle N is a protected root` |
| double free / use-after-free | error — `on freed handle N` |
| 4,097th live object | error — `object budget exceeded` |

A host that does not implement these returns `Err` from the trait default
rather than a fabricated handle. In the browser every violation traps, and a
trap poisons the staged DOM transaction so nothing partial can commit.

Two things this stage did **not** do. The DOM handle space (`1, 2, 3…` from
`createElement`) and the object handle space (`0x0010_0000+`) are still
separate; they merge in B63. And `Object::Empty` / `Object.create(null)` carry
no properties — an object allocated here is an identity, not a bag of fields,
until the B63 property registry exists.

*Unblocks:* every `struct` in `bindings/**` can be constructed and destructed.

### B62 — scalar box/unbox — **landed**

`crates/g6b-wasm/src/values.rs` adds `LibwasmValue`, the host-side scalar and
vector representation. `g6b-wasm::Host` exposes typed `add_*`/`get_*` methods
for `bool`, `byte`/`ubyte`, `short`/`ushort`, `int`/`uint`, `long`/`ulong`,
`float`, `double`, and `int[]`/`uint[]` vectors. `Runtime::call_typed_import`
decodes typed operands before the all-`i32` table, and `validate` accepts the
numeric libwasm signatures while still rejecting unsupported host types.
`TestHost` and `KernelHost` now use `ObjectTable<LibwasmValue>`; the kernel
converts boxed values to `g6b_js::JsValue` for Lodash execution.

Browser parity is in `browser-ui/src/kernel.ts` (numeric box/unbox and the
`libwasm_get__field` / `libwasm_get_idx__field` property-map lookups), the
libwasm D kernel imports are declared in
`libwasm/source/libwasm/g6b_kernel.d`, and the verifier manifest in
`browser-ui/compiler/wasm-cell.ts` accepts the B62 and B63-scaffold signatures.

Verified: `cargo test --workspace`, `bun test`, `bun run build` with LDC 1.43
producing a fresh asyncified `out/bios-ui-libwasm.wasm`, and the full
`python tools/g6b.py check` plus `bios-regress` pass.

*Unblocks:* all scalar property round-trips.

### B63 — property get/set core — **landed in runtime, D imports, and browser host**

`libwasm_get__field` and `libwasm_get_idx__field` are now dispatched through
the object-table property map: a named or indexed property is cloned, boxed as
a new `LibwasmValue` handle, and returned to the guest, with unknown properties
failing closed. The `LibwasmValue::Object` variant carries an `ObjectKind` and
an allow-listed `HashMap<String, LibwasmValue>` property map; `ObjectKind::Empty`
is used for objects created by `libwasm_add__object`, and hosts may tag DOM or
scope objects with `Element` / `Scope` as the registry grows.

The generic `Host::object_getter` / `Host::object_call` methods, plus
`Runtime::object_getter_dispatch` / `Runtime::object_call_dispatch`, now handle
all `Object_Getter__*` and `Object_Call_*__*` signatures (Handle/string/bool/int/
uint/ushort/float/double/void, plus multi-arg string/string and double/double,
i64 long/ulong args, and sret string returns). The runtime parses the import
name, reads method/argument strings from linear memory, and marshals the typed
result. `TestHost` demonstrates a bounded method registry (`double`, `concat`,
`echo`, `name`).

The same family is now wired end-to-end: `libwasm/source/libwasm/g6b_kernel.d`
declares the core `Object_Getter__*` / `Object_Call__*` imports, the verifier in
`browser-ui/compiler/wasm-cell.ts` accepts their signatures, and
`browser-ui/src/kernel.ts` provides fail-closed JS handlers that resolve object
and DOM handles, convert scalar/float/string/Handle results, and trap on unknown
properties, methods, or handles. Bun tests exercise the positive and fail-closed
paths. VarArgCall/EventHandler/JSON/Timer remain `assert(0)` for B65+.

Backed by a **property registry**, not a general object model: each host object
kind (DOM node, BoardSpec menu, kernel router, settings blob) declares an
allow-listed property/method table. An unknown property fails closed with the
receiver kind and the name in the error. This is the mechanism that keeps 684
generated binding files from becoming 684 attack surfaces.

*Unblocks:* the bulk of `Element`, `Node`, `HTMLElement`, `Document` for
properties the BIOS actually models.

### B64 — `Optional!T` sret returns — **landed**

`Object_Getter__Optional{Handle,String,Uint,Double,Bool}` and
`Object_Call_*__Optional*` (`OptionalHandle` and `OptionalString`) are now
implemented end-to-end. The D `optional.d` layout (`T _value; bool defined;`)
was verified from the source (value at `raw`, presence flag at
`raw + sizeof(T)`), and the same layout is now exercised by the LDC 1.43
artifact through the full chain:

- `g6b-wasm::Runtime::write_optional` writes the value and the `defined` flag
  for `Handle`/`uint`/`double`/`string`/`bool` inner types, and treats a missing
  property or a `null`/`undefined` method result as `None` (defined = 0).
- `browser-ui/src/kernel.ts` mirrors the layout in `writeOptional` and adds
  `Object_Getter__Optional*` and `Object_Call_*__Optional*` handlers.
- `libwasm/source/libwasm/g6b_kernel.d` declares the imports instead
  of stubbing them, and `browser-ui/compiler/wasm-cell.ts` verifies their
  signatures.
- Rust and Bun tests cover present and missing/null `Optional` properties and
  method calls.

### B65 — JSON codec and `Object_VarArgCall__*` — **landed**

The 12 varargs imports plus `JSON_parse_string` / `JSON_stringify` are now
implemented end-to-end. The guest already serializes with `fast.json`
(`types.d:353-383`); the host uses the first-party `g6b-spec::json` parser and a
new `g6b-wasm::json` descriptor reader.

- `g6b-spec::json` gained `stringify_json`, F64 fallback for integer overflow,
  and canonical scientific notation for whole-number floats, so large values
  like `1e20` round-trip safely without overflowing `i64`.
- `g6b-wasm::Runtime::json_dispatch` implements `JSON_parse_string` (returns a
  `LibwasmValue` object/array/scalar handle) and `JSON_stringify` (writes a D
  string sret).
- `g6b-wasm::json::vararg_from_json` parses an `argsdef` descriptor grammar
  (`;`-separated tokens, `Optional!T`, `SumType!(...)`), converting flat JSON
  tuple arrays into typed `LibwasmValue` arguments.
- `g6b-wasm::Runtime::vararg_call_dispatch` implements all twelve
  `Object_VarArgCall__*` overloads (`void`, `bool`, `int`, `uint`, `short`,
  `ushort`, `long`, `ulong`, `float`, `double`, `Handle`, `string`), dispatching
  to `Host::object_call` and converting the result.
- `browser-ui/src/kernel.ts` mirrors the same dispatch in JS, with bounds
  checking, budget limits, and fail-closed descriptor handling.
- `browser-ui/compiler/wasm-cell.ts` verifies the new import signatures and
  `libwasm/source/libwasm/g6b_kernel.d` declares them as imports.
- Rust and Bun tests cover JSON parse/stringify round-trips, `Optional!T` and
  `SumType!(string,Handle)` vararg decoding, and fail-closed behavior on unknown
  descriptors and arity mismatches.

*Unblocks:* the single most-used call path (2,035 sites), and therefore
overload-resolving methods with `Optional!T` / `SumType` parameters.

### B66 — events and re-entry — **landed**

`Object_Call_EventHandler__void`, `Object_Getter__EventHandler`,
`libwasm_set__function`, `libwasm_unset__function`, and the
`setTimeout`/`setInterval`/`clearTimeout`/`clearInterval` timer imports are
now host imports. The browser kernel stores named delegates and per-node event
handlers and only dispatches them when the DOM transaction is `committed` and,
when asyncify is present, the asyncify state is `0` (no unwind/rewind). Timer
callbacks are gated by `opts.events` (defaulting to `!!asyncify`), so
non-asyncified cells and the build verifier get fail-closed no-op timers
while the real libwasm asyncified SPA can schedule. The kernel lane's
default `Host` still issues a non-zero no-op id. The UI-thread
`KernelHost` (B89) owns a `TimerHeap` and re-enters through `WasmUi::call`.

**B91c (landed):** after `_start`, virtio-input / UI-hart events re-enter
registered D delegates. `Object_Call_EventHandler__void` stores `(ctx, ptr)`
and becomes `Listener::Delegate` on the live node id. Delivery is export
`jsCallback(ctx, fun, eventHandle)` (`types.d:336-358`); if that export is
absent the host uses `__indirect_function_table.get(ptr)(ctx, handle)`.
Named `libwasm_set__function` / `exportDelegate` entries whose name is an
input event (`click`, `onclick`, `keydown`, …) fire on
`dispatch_pointer` / `dispatch_key` (the GuestCellLive virtio path). The
shipped LDC cell still has no `jsCallback` and keeps `Listener::Cell` /
`g6b_listen` until `G6B_DUB_WASM=1`. `start_ops` is not this path.

*Unblocks:* reactive UI — the transition from "initialization-only" to a real
component bridge.

### B67 — Lodash backend — **landed**; Moment core wired

All twelve `ldexec_*` imports are declared, dispatched and ABI-verified.
`crates/g6b-js/src/lodash.rs` is the backend: a bounded command-buffer parser
(the sigil convention of `lodash.d:417-475`), a `JsValue` model, and an
evaluator over the 37 methods in `LODASH_SUPPORTED`. `attempt` / `invoke` are
**not** in that list: they are fail-closed `HostDispatch` hooks so `g6b-js`
stays store-ignorant. `KernelHost` implements them against `StoreRegistry`
(BrowserSession-complete). Native `kernel.ts` identity-checks the interned
shell BINDINGS `pglite` factory and returns
`{ok:false,error:"async",message:"NotImplemented(\"async\")"}` rather than a
Promise. `browser-ui/src/kernel.ts` mirrors the value methods, and the two
agree on coercions — including that `libwasm_add__object` stringifies as
`"[object Object]"`, which plain `String()` cannot do for a null-prototype
object. `libwasm/source/libwasm/pglite.d` is the D wrap (`query(sql, params_json="[]")`,
`exec` / tx / `close` / `waitReady` / `dump` / `load`); the live LDC cell does
not contain it until `G6B_DUB_WASM=1`.

Iteratee dispatch differs by lane, and the difference is the honest part:

| Lane | Guest iteratee |
|---|---|
| browser (`createLibwasmHost`) | **dispatched** — `__indirect_function_table.get(cbPtr)(cbCtx, …)`, with the boxed element released after the call |
| kernel (`KernelHost`) | **fails closed** — the Rust interpreter cannot yet re-enter a running instance, so a predicate chain returns `CallbackUnavailable` rather than a wrong answer computed without the predicate |

That kernel gap is the same re-entrancy seam as B66 and is fixed there, not
here. Budgets: 256 commands, 64 KiB buffer, 5 parameters, 4,096 elements.

A first-party `Moment` core is wired: `libwasm_moment_now`,
`libwasm_moment_from_millis`, and a minimal `libwasm/moment.d` that uses the
existing `Object_Call_string__*` getter/call ABI to read `getTime`, `getFullYear`,
`getMonth`, `getDate`, etc. The browser host backs handles with JS `Date`; the
kernel lane returns a fail-closed zero handle. Still open: the full Moment
method set (startOf, endOf, utc, localisation, timezone support, etc.);
value-returning iteratees (the generated delegate ABI is `bool`-only, so `map`
yields the predicate's result); and `Object_VarArgCall__*`, which shares the
JSON codec but is B65. `getTimeStamp` is now implemented: browser `Date.now()`
and kernel `SystemTime` both return a `long` (i64) millisecond-since-epoch value.

### B68 — typed arrays and promise combinators — wired

`libasync_promise_all__promise`, `libasync_promise_any__promise`, and
`libasync_promise_allsettled__promise` are wired: the browser host creates real
`Promise.*` combinators over handle arrays, and the kernel host returns a
fail-closed zero handle because it cannot re-enter a running instance.

`DataView_Create`, `{Uint8,Int8,Int32,Float32}Array_Create` take a D slice
(`len`, `ptr`) and return a handle to a live view over guest linear memory. The
browser host creates a `DataView` / typed-array backed by the wasm memory buffer;
`libwasm_get__field` can read `length` / `byteLength` and `libwasm_get_idx__field`
can read individual elements. The kernel lane returns a fail-closed zero handle.

### B69 — generic DOM methods and bounded ES6 Map — landed

The generic `Object_Call`/`Object_Getter` machinery is sufficient for the most
common DOM surface expansion: `setAttribute` / `getAttribute` / `removeAttribute`
and `classList` (`add` / `remove` / `toggle` / `contains`) are exercised on real
browser nodes through `Object_Call_string_string__void`,
`Object_Call_string__OptionalString`, `Object_Call_string__void`,
`Object_Call_string__bool`, and `Object_Getter__Handle`. No new WebIDL module is
required because the D code can call these methods through the existing property
and call families.

The first bounded ES6+ host object is `Map`: `libwasm_map_create`,
`libwasm_map_set`, `libwasm_map_get__OptionalString`, `libwasm_map_has`,
`libwasm_map_delete`, and `libwasm_map_clear` are declared in `g6b_kernel.d`,
verified in `wasm-cell.ts`, dispatched in `g6b-wasm`, and implemented in
`browser-ui/src/kernel.ts`. The browser host creates a real JS `Map`; the kernel
lane returns fail-closed placeholders because it cannot host a live JS object.

### B70 — DOM event listener host boundary — landed

`g6b-dom::event` (capture/bubble, `preventDefault`, `stopPropagation`) is wired to
`BrowserSession` through `BrowserEventHost`. `BrowserSession::dispatch_pointer`
and `dispatch_key` perform CSS `HitBox` lookup and call `Node::dispatch_event`.
The libwasm host imports `addEventListener`, `removeEventListener`, and
`dispatchEvent` are declared in `g6b-wasm` and dispatched in `call_import`.
`g6b-kernel/src/lib.rs` defines the `Listener` enum covering both AOT
(`g6b_js::Op` programs) and libwasm (`function_index` / `handle`) callbacks.
`listeners_run` already re-enters the interpreter (`g6b_js::run` / `run_with_fuel_mut`).
The remaining hole is not the listener enum: there is not yet a persistent
`WasmInstance` (tables are reconstructed per event), no live-tree CSS
invalidation, and no UI-thread frame present onto virtio-gpu.

### Permanently refused

Host `eval` in any form — including a `VarType.eval` chain seed, a bare
`=name` window lookup, and any `=(…)` that is not one of the five generated
iteratee boilerplates (§5); the WebGL / WebGPU / RTC / XUL /
Payment / SubtleCrypto binding families (they are declared in the tree but no
BIOS surface backs them, and a stub that returns a handle is worse than an
`assert(0)`); `window`/`document` semantics that differ from the two g6b roots
in §3; and any claim that a linking LDC artifact constitutes a browser.

## 9. Which bindings are actually reachable

The core modules pull in a small closure, which bounds the realistic target:

| Core module | `libwasm.bindings.*` imported |
|---|---|
| `dom.d` | `Document`, `HTMLElement`, `Window` |
| `types.d` | `Console`, `EventHandler`, `Window` |
| `router.d` | `Console`, `Event`, `EventHandler`, `History`, `HTMLLinkElement`, `Location`, `MouseEvent`, `Node`, `Window` |
| `spa.d`, `promise.d` | `Console` |
| `node.d`, `event.d`, `lodash.d`, `moment.d`, `pglite.d`, `bridge.d`, `array.d`, `css.d` | none |

So a compiling, *useful* cell needs roughly a dozen binding modules, not 684.
The remaining ~670 are reachable only if application D imports them by name,
and the property registry in B63 is what makes that reach fail closed.

## 10. Verification gates

No stage is complete without all of:

- `cargo test --workspace` and strict Clippy green;
- `bun test` in `browser-ui/` green, with a test that drives the new import
  through the *actual* `createLibwasmHost`, not a mock;
- the ABI verifier in `browser-ui/compiler/wasm-cell.ts` extended with the new
  signatures, so a shipped LDC artifact importing something unimplemented is
  rejected at build time rather than trapping at runtime;
- `G6B_DUB_WASM=1 G6B_WASM_ASYNCIFY=1 bun scripts/build.ts` producing a
  `fresh` verified artifact;
- `python tools/g6b.py check` and `python tools/g6b.py regress`;
- a matching row added to `AGENTS-todo.md` distinguishing what was verified
  from what remains open.

## Loci

`libwasm/source/libwasm/types.d:23` `alias Handle`;
`:326-349` `jsCallback`; `:353-383` `Serialize_Object_VarArgCall`;
`:454-490` `struct JsHandle`; `:182-269` the host import table.
`libwasm/source/libwasm/bindings/EventHandler.d:37-38` handler aliases.
`libwasm/source/libwasm/lodash.d:14-26` `VarType`; `:325` `struct Lodash`.
`libwasm/source/libwasm/pglite.d` S3 D wrap of interned `window.pglite`.
`libwasm/source/libwasm/g6b_kernel.d` the g6b substitution and stubs.
`crates/g6b-wasm/src/objects.rs` the B61 refcounted `ObjectTable`.
`crates/g6b-js/src/lodash.rs` the B67 command parser, `JsValue` and evaluator.
`crates/g6b-wasm/src/interp.rs` `Host` trait, `call_import`,
`call_typed_import`, `Ldexec` / `LdexecInit` / `GuestFn`.
`crates/g6b-kernel/src/lib.rs` `KernelHost`.
`browser-ui/src/kernel.ts` `createLibwasmHost`.
`browser-ui/compiler/wasm-cell.ts` `LIBWASM_ABI` verifier.

Related: [`WASM.md`](WASM.md), [`BROWSER.md`](BROWSER.md), [`PLAN.md`](PLAN.md).
