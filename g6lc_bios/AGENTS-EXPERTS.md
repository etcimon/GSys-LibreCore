# g6lc_bios — Expert Guider (whole-project mental model)

> **Purpose.** `AGENTS.md` carries invariants and planning state. This file
> carries the *mental model*: how the crates involve each other, how a `.svelte`
> file becomes a wasm `_start`, what the libwasm import ABI actually is, and
> which host implements it. Read this before adding a browser-UI feature or
> writing an end-to-end test (the pglite/btrfs/QEMU volume test is worked as the
> reference example in §9).
>
> Scope note: this is a **map, not a spec**. Where this file and the code
> disagree, the code wins and this file is stale — fix it in the same pass.

---

## 1. The one-paragraph version

A `.svelte` file is parsed by a **first-party** parser (never `svelte/compiler`)
into a flat list of `UiOp`s. Those ops are printed into **three** independent
lanes: a first-party MVP-wasm encoder, a D source tree compiled by LDC against
**libwasm**, and a TS/JS splice. The D lane's `_start` runs `App.onMount()`,
which issues DOM/fetch/HolyC/pglite operations as **host imports**. Those
imports are a bounded, named set defined in one file (`libwasm/source/libwasm/g6b_kernel.d`).
Two real hosts implement that set: the **Rust** `KernelHost` (in the BIOS/QEMU,
where pglite, lodash and `platform.*` are genuinely implemented) and the
**browser** `kernel.ts` host (where the store is a `fetch` proxy back to the
BIOS). A third, deliberately minimal host exists only to verify the artifact at
build time — most "stale libwasm" reports are about *that* host, not the cell.

---

## 2. Crate graph (who involves whom)

Dependency direction is strictly downward. `g6b-spec` is the root vocabulary
(`BoardSpec`): almost everything reads it, it reads nothing.

```
                      g6b-spec ──────────────────────── (BoardSpec; no deps)
                         │
   ┌─────────────────────┼──────────────────────┬────────────────┐
   │                     │                      │                │
g6b-pglite           g6b-asm                g6b-gr           g6b-fs
(SQL store)      (RISC-V payload asm)     (framebuffer)     (file svc)
   │                     │                      │
   │              ┌──────┴──────┐          g6b-ttf, g6b-img
   │              │             │
   │          g6b-wasm      g6b-design ── g6b-webidl, g6b-tls, g6b-ui
   │        (wasm JIT +         │
   │         Host trait)        │
   │              │             │
   └──────────────┴─────────────┴──── g6b-kernel ───────────────────┐
                                      (the integrator)              │
   g6b-dom ─ g6b-html ─ g6b-css ─ g6b-js ─ g6b-vfs ─ g6b-zealcli ───┘
                                            │
                                        g6b-elf  (bootable image)
                                            │
                                        g6b-cli  (`g6b` binary)
```

Read this as five bands:

| Band | Crates | Job |
|---|---|---|
| **Vocabulary** | `g6b-spec` | `BoardSpec` JSON → typed config. Every "is this feature compiled?" question resolves here. |
| **Leaf engines** | `g6b-vfs`, `g6b-pglite`, `g6b-tls`, `g6b-dom`, `g6b-webidl`, `g6b-doldoc`, `g6b-iframe` | Self-contained. `g6b-vfs` owns GPT/MBR + the four filesystems; `g6b-pglite` owns the SQL store. Neither knows about wasm. |
| **Middle** | `g6b-asm`, `g6b-wasm`, `g6b-js`, `g6b-html`, `g6b-css`, `g6b-gr`, `g6b-ttf`, `g6b-img`, `g6b-ui`, `g6b-http`, `g6b-fs`, `g6b-hw`, `g6b-holyc`, `g6b-design`, `g6b-zealcli` | One concern each. `g6b-wasm` is the **JIT + `Host` trait**; `g6b-js` is the lodash/JS AOT subset; `g6b-asm` emits the RISC-V payload *and* embeds the wasm artifacts. |
| **Integrator** | `g6b-kernel` | Implements `Host` (→ `KernelHost`), wires pglite to VFS volumes, owns `platform.*`, routes HTTP. **This is where libwasm meets the BIOS.** |
| **Emit** | `g6b-elf`, `g6b-cli` | Produce the ELF and the `g6b` CLI. |

**The two rules that keep this graph honest**

1. `g6b-js` must not depend on `g6b-pglite`. The AOT JS subset is a *language*
   subset; the store is a *service*. `print-ts.ts:115` states this: pglite
   reaches the store only via the LDC `_start` path or a `lang=ts mount()`.
2. `g6b-vfs` must not depend on `g6b-pglite` (or vice-versa). They are joined
   only in `g6b-kernel`, through the `StoreVolume` trait (§8).

---

## 3. The Svelte pipeline: one parse, three lanes

Everything lives in `browser-ui/compiler/`.

```
 src-svelte/*.svelte
        │
        │  parse.ts   ← first-party parser (spec: svelte-d submodule, Pegged).
        │              NOT svelte/compiler. Emits SvelteFile{ ops: UiOp[] }.
        ▼
   UiOp[] = TextOp | FetchOp | HolycOp | RegisterOp | VisibleOp | AwaitOp | PgliteOp
        │
        ├── emit-wasm.ts ──► out/bios-ui.wasm            (lane A: first-party MVP wasm)
        ├── print-d.ts  ──► src-d/*.d ──LDC/dub──► bios-ui-libwasm.wasm  (lane B)
        └── print-ts.ts ──► src-ts splice / jsExports / g6b-js subset    (lane C)
```

### 3.1 Why the parse is a flat op list

The parser does **not** build a general AST and the printers are **not** a
general backend. `parse.ts` recognises a bounded set of call shapes by regex and
records an op:

| Source shape (in `<script>`) | Op |
|---|---|
| `fetchBios("/x")` / `fetch("/x")` | `{kind:"fetch", url}` |
| `await …` immediately after a fetch | `{kind:"await"}` |
| `holycEval("…")` / `kernel.holyc("…")` | `{kind:"holyc", line}` |
| `registerEndpoint("/p","POST")` / `kernel.register(…)` | `{kind:"register", path, method}` |
| `pgliteOpen/pgliteExec/pgliteQuery/…` | `{kind:"pglite", method, arg1, arg2, bind, awaited}` |
| `{expr}` in markup, `{#if}` | `TextOp` (with optional `bind`/`field`), `VisibleOp` |

This is the single most important thing to understand before adding a feature:
**a new capability is a new op kind plus a printer arm in each lane you care
about** — not a new expression evaluator. `pgliteMethod()` (`parse.ts:203`) is
the allow-list of store verbs; a verb absent there is invisible to every lane.

### 3.2 Lane A — first-party wasm (`emit-wasm.ts`)

A hand-rolled WASM MVP encoder matching `g6b-wasm`. Exports exactly `memory`
and `_start`. **No LDC, no D, no toolchain.** This is why `python tools/build.py
browser` succeeds on a bare machine, and why the BIOS always has a UI cell even
when the optional LDC lane is unavailable. Artifact: `browser-ui/out/bios-ui.wasm`.

### 3.3 Lane B — the libwasm D cell (`print-d.ts`)

Prints a D module per `.svelte` file plus `mixin Spa!App`, which is what
provides `_start`. The interesting arms:

- Fetches become `auto pN = g6b_fetch("/bios/…");`, and a following `AwaitOp`
  becomes `libwasm_await__void(pN);` (`print-d.ts:146-152`).
- pglite ops become a **`PgLite` chain** (`printPgliteReady`, `print-d.ts:401`):
  `auto db = PgLite("memory://registry"); db.waitReady(); db.exec(…);
  auto rows = db.queryAsync(…);` — then `printPgliteBindTexts` paints the bound
  value into the DOM handle.
- Everything async is guarded by `if (libwasm_await_supported()) { … }`
  (`print-d.ts:162`), so the same cell runs on a host without asyncify.

Artifacts: raw `public/bios-ui-raw.wasm` → (optional `wasm-opt --asyncify`) →
`public/bios-ui.wasm` → shipped as `browser-ui/out/bios-ui-libwasm.wasm`.

> **Gap worth knowing.** `src-d/store.d` is a *stub* — `Store.svelte`'s
> `<script>` was not lowered into its own module. The real pglite chain is
> emitted into `src-d/app.d` (`app.d:858-862`). If you are hunting for "where
> did my Svelte script go", check `app.d` before concluding the compiler dropped it.

### 3.4 Lane C — lang=ts / JS (`print-ts.ts`)

Three outputs, all generated:

- `printGeneratedTs` — a per-file TS splice registering `fetchBios`,
  `holycEval`, `registerEndpoint` into `window.__svelteD.ts`, plus an
  `async mount()` that runs the pglite ops with real `await` (`printTsPgliteMount`).
- `printJsExports` — the `window.__svelteD` cross-calling registry (`ts` and
  `d` halves), per `svelte-d/architecture/cross-calling.md`.
- `printG6bJs` — the **AOT JS subset** consumed by `g6b-js`: `innerText`,
  `fetch`, `kernel.holyc`, `kernel.register`. Deliberately no pglite (§2 rule 1).

**So: a Svelte `<script>` may be D or JS/TS.** Same ops, different lane. D goes
through LDC→libwasm→`ldexec_*`/`Object_*` host imports; JS/TS goes through
`g6b-js` (AOT, in-BIOS) or the browser's own JS engine. Both converge on the
same **g6b-registered** host functions — `fetch`, `holyc`, `register_endpoint`,
`set_inner_text` — which is why a feature only has to be designed once.

### 3.5 The cell has to fit the JIT's decode budget

The BIOS runs the cell through the Rust JIT, which bounds what it will decode.
That bound is **size-proportional**, not fixed
(`g6b_wasm::instruction_budget`, `crates/g6b-wasm/src/binary.rs`):

```
budget = clamp(code_section_bytes, MAX_INSTRUCTIONS, MAX_INSTRUCTIONS_CEIL)
                                   = 131_072          = 262_144
```

The proportional term is an **exact upper bound, not a heuristic**: a wasm
instruction always consumes at least one body byte, so a module can never
decode to more instructions than its code section has bytes. Below the
ceiling the check therefore cannot fire — `MAX_INSTRUCTIONS_CEIL` (the
`Vec<Instr>` memory fence) and `MAX_MODULE_BYTES` (1 MiB) are the operative
bounds.

`BIOS_UI_CELL_BUDGET = instruction_budget(g6b_asm::BIOS_UI_LIBWASM.len())` is
a `const` pre-compute over the embedded artifact — the trusted half of the
split, justified because the cell is compiled here and hash/ABI-pinned at
build time, so its size is known at compile time.

**If the Svelte tree outgrows the JIT, the test that should fail is
`binary::tests::cell_budget_covers_the_embedded_bios_ui`**, which reports the
actual numbers and requires 2× headroom to the ceiling. Historically this was
a flat `65_536` and the failure instead appeared as a bare
`"wasm instruction limit"` from three unrelated `g6b-elf` scanout smoke tests
— the cell measured 62,960 instructions before an `App.svelte` growth and
71,480 after, so the fixed bound sat exactly between the two. Full rationale:
`architecture/WASM.md` "The decoded-instruction budget is size-proportional".

### 3.6 Where the artifacts end up

`g6b-asm/src/lib.rs:532,538` embeds both lanes into the payload:

```rust
pub const BIOS_UI_WASM:    &[u8] = include_bytes!(".../browser-ui/out/bios-ui.wasm");
pub const BIOS_UI_LIBWASM: &[u8] = include_bytes!(".../browser-ui/out/bios-ui-libwasm.wasm");
```

Consequence: **the browser-UI build must run before the Rust build**, and a
missing/stale artifact is a Rust compile-time or provenance error, not a runtime
one. `tools/build.py test` sequences this correctly (browser-ui → ELF → QEMU).

---

## 4. libwasm: the runtime, the std library, and the bounded import set

`g6lc_bios/libwasm` is a **submodule** — etcimon/libwasm on the `g6lc_bios`
branch. It is not a DUB-registry dependency and must never be resolved from a
DUB cache (`runtimePreflight` enforces this, `compiler/ldc.ts:286`).

Three things live in there:

| Piece | Path | Role |
|---|---|---|
| **std/runtime** | `runtime-v1.43.0/` (`druntime-wasm-143`) | A carried druntime for `wasm32-unknown-wasi` under `version(CRuntime_LIBWASM)`. `-defaultlib=` — the stock runtime is never linked. |
| **std deps** | `memutils-wasm`, `fast-wasm`, `diet-wasm`, `optional-wasm` | Allocator/containers, formatting, templates, `Optional!T`. All path deps, all `ldc-master` config. |
| **bindings** | `source/libwasm/*.d` | `dom.d` (53k), `css.d`, `event.d`, `promise.d`, `router.d`, `spa.d`, `lodash.d` (148k), `pglite.d`, `moment.d`, `sumtype.d`, `types.d`. |

### 4.1 The `G6LC_G6B` substitution — the one file that defines the ABI

`types.d` routes on a version:

```d
version (G6LC_G6B) { public import libwasm.g6b_kernel; }
```

So **`libwasm/source/libwasm/g6b_kernel.d` *is* the g6b import contract.** Every
`extern(C)` declaration in it is either (a) a host import the BIOS/browser must
implement, or (b) an inert local definition (`assert(0)` / no-op) that exists so
druntime links without a JS harness. If you add a host capability, it is
declared here first; anything not declared here is unreachable from D.

`runtimePreflight` asserts the shape of this seam, which is why a plain upstream
libwasm checkout is rejected with a clear reason instead of a link error:
`configuration "g6lc-bios"` must exist and carry `druntime-wasm-143`,
`versions "G6LC_G6B"`, `--export=_start`, `-defaultlib=`; `g6b_kernel.d` must
declare `module libwasm.g6b_kernel;`; `types.d` must route to it.

### 4.2 The import families

Grouped as they appear in `g6b_kernel.d`. Rust side: the `Host` trait in
`crates/g6b-wasm/src/interp.rs:131`.

| Family | Examples | Notes |
|---|---|---|
| **g6b-registered** | `set_inner_text`, `fetch`, `holyc`, `register_endpoint`, `console_log`, `set_visible`, `getRoot` | The original BIOS seam. D wrappers: `g6b_fetch`, `g6b_holyc`, `g6b_register`, `g6b_listen`. |
| **generic getters** | `Object_Getter__string/Handle/int/uint/bool/float/double/ushort`, `…__Optional*` | `(handle, name) → typed value`. This is how D reads any host property without a per-property import. |
| **generic calls** | `Object_Call_{argtypes}__{ret}` — e.g. `Object_Call_string__Handle`, `Object_Call_double_double__void` | `(handle, method, args…)`. The arity/type matrix *is* the ABI; unusual shapes go through `Object_VarArgCall__*` with JSON-encoded args. |
| **scalar box/unbox** | `libwasm_add__{bool,int,uint,long,ulong,short,ushort,float,double,byte,ubyte,ints,uints}` / `libwasm_get__{…}` | i32/i64/f32/f64 widths dispatched through the typed import path (`binary.rs:606`). |
| **handle lifetime** | `libwasm_add__object`, `libwasm_removeObject`, `libwasm_copyObjectRef` | `struct JsHandle` is refcounted: copy → `copyObjectRef`, destruct → `removeObject`. Handles **1** (Spa mount) and **2** (BoardSpec/first element) are roots and are never freed. |
| **globals** | `libwasm_global(name)` | Browser-instance globals: `window`, `document`, `console`, `platform`. Returns **0** when unavailable — callers must check. Fail-closed by design. |
| **lodash** | `ldexec_{Handle,string,long}__{string,long,double,Handle}` | 12 imports. §5. |
| **asyncify** | `libwasm_await__void`, `libwasm_await_{supported,failed,error,value}`, `libwasm_note_await_{ok,fail}` | §6. |
| **JSON** | `JSON_parse_string`, `JSON_stringify` | |
| **Map / typed arrays** | `libwasm_map_{create,set,get,has,delete,clear}`, `{Int8,Int32,Uint8,Float32}Array_Create`, `DataView_Create` | Bounded ES6 surface. |
| **events / timers** | `add_event_listener`, `remove_event_listener`, `dispatch_event`, `setTimeout`, `setInterval`, `clear*` | `listener=0` is the BIOS tab/refresh protocol, **not** wasm function 0. |
| **cell exports** | `_start`, `allocString`, `__heap_base`, `jsCallback`, `jsCallback0`, `g6b_fx_{data,count,step,logo}` | The `lflags --export=` list in `engineDubSdl` (`wasm-cell.ts:501`). `verifyLibwasmAbi` checks each signature. |

---

## 5. lodash: how a D method chain becomes one host call

`libwasm/source/libwasm/lodash.d` builds a **JSON command buffer** instead of
calling the host per step. `struct Lodash` accumulates
`{func, params[…]}` entries; `.execute!T()` ships the whole chain through one
`ldexec_*` import whose name encodes *init type* and *result type*:

```
ldexec_<init>__<ret>       init ∈ {Handle, string, long}   ret ∈ {string, long, double, Handle}
```

Operands are `(init, commandsJson, cbCtx, cbPtr [, evalTail])`. The Rust side
decodes them into `Ldexec { init: LdexecInit, … }` (`interp.rs:2023-2093`) and
dispatches to `Host::ldexec_{string,long,double,handle}`.

Two details that matter:

- **`Eval("name")`** is a parameter with `VarType.eval` — a *host-name*
  reference, never JS source. The host interns it by name and refuses anything
  it does not recognise (`LodashError::EvalRefused`). There is no JS evaluator on
  either side, and `evalTail` is explicitly rejected. This is the security
  boundary: `=window.location`, `=alert(1)`, `=(()=>fetch('http://evil/'))()`
  are all refused **by name**, not sanitised.
- **Guest iteratees** — a D delegate passed as `cb` is dispatched *back* into the
  cell through `__indirect_function_table`, so predicates run in wasm. That is
  why no host JS engine is needed for `filter`/`map`-style chains.

`MAX_PARAMS` is 5, which is why `pglite.query` packs bind parameters into a
single JSON array string rather than spreading them.

---

## 6. asyncify: `await` without threads

The D cell is single-threaded and the store is async. The bridge is Binaryen
**asyncify** over one import:

```
wasm-opt --asyncify --pass-arg=asyncify-imports@env.libwasm_await__void
```

Protocol: the guest gets a promise/slot handle from a call, then invokes
`libwasm_await__void(handle)`. The host unwinds, settles, and rewinds; the guest
then reads `libwasm_await_failed()` / `libwasm_await_error()` /
`libwasm_await_value()`.

Capability is **queryable**, not assumed: `libwasm_await_supported()` returns 0
when the host has no async queue, and `print-d.ts` wraps the whole async block
in that check. In `kernel.ts` the import is a documented **no-op when asyncify is
off** (`kernel.ts:1136`, `// build/verification no-op`) — the same cell therefore
runs in a synchronous verification host. Remember this when reading §7.3.

---

## 7. The three hosts

The same cell, the same imports, three implementations with *deliberately
different* completeness. Most confusion about the libwasm lane is really
confusion about which host is running.

### 7.1 Rust `KernelHost` — the BIOS (this is the real one)

`crates/g6b-kernel/src/lib.rs:3318` (`impl Host for KernelHost`). Implements
`ldexec_*`, `fetch`, `fetch_post`, the object table, the scalar box/unbox family,
events, and — crucially — a **complete** lodash + pglite + `platform.*`
implementation. This is what runs under QEMU.

`HostDispatch::intern_name` (`lib.rs:3199`) is the `Eval` allow-list:

| Name | Result |
|---|---|
| `window.pglite` \| `pglite` | `ObjectKind::StoreFactory` handle — **but only if `spec.kernel.store.enable`**; otherwise `EvalRefused` |
| `window.platform` \| `platform` | `ObjectKind::Platform` handle |
| `window.hw` \| `hw` | `EvalRefused("hw is platform.hw, not a window global")` |
| `moment` \| `window.moment` | `UnsupportedMethod` |
| anything else | `EvalRefused` |

Then the store state machine:

```
Eval("window.pglite") ──► StoreFactory handle
        │ attempt(dataDir)            → factory_attempt  (lib.rs:2592)
        ▼
   Store handle {uuid}
        │ invoke(method, args…)       → store_method     (lib.rs:2640)
        ▼
   real SQL through g6b-pglite::StoreRegistry
```

`store_method` is genuinely implemented: `query`/`queryAsync`, `exec`,
`begin`/`commit`/`rollback`, `close`, `waitReady`/`stat`/`statAsync`, `dump`,
`load`, `listen`/`unlisten`/`notifies`, `export`. Only `sql`/`transaction`
return `NotImplemented("callback")`.

**`platform.*`** (`ensure_platform_global`, `lib.rs:2839`) is a lazily-interned
object tree, memoised on `window.platform`, emitting a
`WASM-JS-GLOBAL platform -> N` diagnostic:

```
platform
└── hw            (ensure_hw_global,  __role="root")
    ├── net ──┬── tcp
    │         └── udp
    └── display ── gl
```

Those `WASM-JS-GLOBAL …` lines on the serial log are the cheapest proof that the
cell reached the host at all.

### 7.2 Browser `kernel.ts` — a fetch proxy

`browser-ui/src/kernel.ts`, `createLibwasmHost` (line 349). DOM is real; the
store is **not** local. `installPgliteFactory` (line 1572) returns a factory
tagged `__g6bStore="factory"` whose instances (`newBiosStore`, line 1467) proxy
every method to the BIOS over HTTP:

```
/bios/store            POST   create by purpose
/bios/store/open       POST   open by dataDir URL
/bios/store/{uuid}/{open,stat,query,exec,begin,commit,rollback,close,dump,load,listen,unlisten,export}
```

This is the `fetch_post` seam — the browser never gets a Rust-only shortcut,
which is what the kernel test `a_libwasm_cell_posts_sql_through_fetch_post_to_a_btrfs_key`
pins.

**The sync/async tension.** lodash is synchronous; `newBiosStore` is `async`.
So `kernel.ts`'s lodash interpreter cannot service a store call inline and
substitutes a well-formed sentinel (`kernel.ts:573`):

```js
const ASYNC_STORE = JSON.stringify({ ok:false, error:"async", message:'NotImplemented("async")' });
```

`attempt`/`invoke` require `isStoreAcc(acc)` (line 574: identity with
`ctx.global("pglite")`, or `__g6bStore` ∈ {factory, instance}) and otherwise
**throw**. Real async store work in the browser goes through asyncify +
`newBiosStore`, or through `createPgliteWasm` (real Electric PGlite, bytes from
`/ui/pglite/*`) — not through the lodash sync path.

### 7.3 The build-time verifier — minimal on purpose

`browser-ui/compiler/wasm-cell.ts`: `verifyLibwasmAbi` (structural: signatures,
one exported memory, i32 `__heap_base`) then `verifyLibwasmStartup` (line 392)
instantiates against a tiny fake DOM and actually calls `_start`, then checks the
particle ABI. `checkCellArtifact` (line 444) additionally pins
schema/ABI/input-hash/sha256/import-manifest.

`cellInputHash` (line 358) hashes the workspace D+Svelte sources, `dub.sdl`, the
pinned `ldc2-wasm.conf`, **all of libwasm and its four sub-packages, the whole
carried runtime**, every compiler `.ts`, `kernel.ts`, `worker.ts`, and the `ldc`
and `dub` binaries. Any change to any of those flips the hash.

> **This is the actual meaning of "stale libwasm provenance:
> source/runtime/toolchain/ABI mismatch"** (line 446). It is *not* a compiler
> error and usually not a real defect — it means `wasm-artifact.json` was
> produced from different inputs than the ones now on disk (commonly: the cell
> was simply never built, so no manifest exists at all).
>
> **Diagnosing it** (in order):
> 1. `resolveToolchain()` + `runtimePreflight(tc)` — is LDC 1.43 pinned, is
>    `libwasm` the submodule, is the carried runtime intact? Empty array = fine.
> 2. Does `svelte-engine-ws/dub.sdl` byte-match `engineDubSdl(tc.libwasm)`?
>    If not, `buildWasmCell` refuses early (line 603) — the generated file is
>    generated, so hand-edits show up here.
> 3. Rebuild: `G6B_DUB_WASM=1 bun run build`.
>
> Known defect as of writing: `verifyLibwasmStartup` constructs the host with
> **no `context`**, so the cell's `Eval("window.pglite")` hits `ctx === null` and
> throws `libwasm lodash refuses host eval of "window.pglite"`. Supplying a
> context then exposes a second defect: `attempt` degrades `acc` to the
> `ASYNC_STORE` *string*, and the next chained `invoke` (from `db.exec`) fails
> `isStoreAcc` and throws `libwasm lodash method "invoke" is not implemented`.
> Both are verifier-side; the cell and the Rust host are correct. Fixing them
> means binding a store-shaped context **and** letting a degraded accumulator
> stay degraded instead of throwing mid-chain.

---

## 8. Store ⇄ volume: how SQL reaches a real filesystem

`g6b-pglite` knows nothing about disks. It declares a seam
(`crates/g6b-pglite/src/persist.rs:171`):

```rust
pub trait StoreVolume {
    fn write(&mut self, volume: &str, rel: &str, bytes: &[u8]) -> Result<(), String>;
    fn read(&mut self, volume: &str, rel: &str) -> Result<Option<Vec<u8>>, String>;
}
```

`g6b-kernel/src/vfs.rs` implements it over `g6b-vfs`. `volume` is resolved
either as a mount name or as a **filesystem kind** — "my key is the btrfs one"
(`vfs.rs:522-545`):

```rust
"fat32" => fs.starts_with("fat"),
"ntfs"  => fs == "ntfs",
"ext4"  => fs.starts_with("ext"),
"btrfs" => fs == "btrfs",
```

Selection is refused when ambiguous (two FAT32 volumes) rather than guessed.

### 8.1 Filesystem capability matrix — read this before promising a r/w test

All four filesystems **can** write; what differs is *how much*. Every driver
answers `edit_budget(path)` up front (B102) so a save is refused before the
work is typed, and `Probe::summary()` renders the honest status line. The
authoritative table is `architecture/g6b-vfs.md` "Editing: the filesystem's
terms"; condensed:

| FS | Terms | Write ceiling |
|---|---|---|
| **fat32** | `fat32 rw` | creates, grows, shrinks; ceiling is the file's own clusters plus free ones, **counted**, not taken from the advisory FSInfo hint |
| **ext4** | `ext4 rw` | in-place overwrite + tail growth by block allocation; file and directory creation; sparse mid-hole writes refused |
| **btrfs** | `btrfs rw` | in place inside existing extents (csum tree refreshed); inline extents replaceable ≤2048 B; create lands data inline |
| **ntfs** | `ntfs rw <=N B in place` | **resident `$DATA` only**, `can_grow: false`; MFT record rewritten and `$LogFile` re-stamped clean; **non-resident and new files refused**, and a missing/dirty `$LogFile` refuses the write outright |

Two things that are easy to get wrong:

- **NTFS is not read-only.** `ntfs::mount(dev)` takes no `rw` parameter, which
  makes it *look* read-only next to the other three, but there is a real
  bounded write path (B107). Reading the signature alone gives the wrong answer.
- `mount(dev, rw)` treats `rw` as a **request**. The returned filesystem
  reports what it actually got. Trust `summary()`, not the argument.

### 8.2 The matrix, and what each filesystem actually does

One entry point — `g6b_vfs::fixture_image_named(name)` over
`FIXTURE_KINDS` — because the per-driver fixtures have different shapes
(`fat32::fixture(sectors)`, `ntfs::fixture::image()`,
`btrfs::fixture::image(with_data)`, `ext4::tests_image_with_os_release()`) and
a matrix caller should not need to know any of them. Surfaced as
`g6b vfs emit-fs --fs <kind>` and `build.py test --fs <kind>`.

| FS | Fixture | Store outcome |
|---|---|---|
| fat32 | 2 MiB, `G6LCTEST` | full round trip: insert → query → export → fresh registry imports off the medium → query |
| ext4 | 512 KiB, `g6lcroot` + `/etc/os-release` | same, within the guarded write path |
| btrfs | 16 MiB, `G6LCBTRFS` | same; depends on the 16 KiB-nodesize leaf headroom |
| **ntfs** | 128 KiB (one resident file, `bootmgr`) | **refused on the first `CREATE TABLE`** |

The NTFS result is stronger than "export is refused", and the reason is worth
internalising: with `persist.usb` armed the store writes
`/stores/<purpose>/<uuid>.g6bstore` on **every statement**, so a driver that
cannot create a file cannot back a persisted store *at all* — the refusal lands
on the first statement, not at export. The refusal must be *named*
(`volume write: …`) or an operator cannot distinguish it from a broken store
engine.

Guards: `every_fixture_kind_probes_and_mounts_as_itself` (g6b-vfs) keeps every
advertised fixture mountable; `the_store_matrix_insert_and_query_per_filesystem`
(g6b-kernel) pins the per-fs outcomes above.

**Read the QEMU matrix narrowly.** A green `build.py test --fs X` proves
guest-side *detection and store liveness* (`<fs>-OK`, `USB-FILES-OK`,
`Store-OK`, `SVELTE-LIVE-OK`, `JS-FETCH-OK`). It does **not** prove an export
succeeded inside the guest — that is what the host-side Rust tests are for.

---

## 9. Worked example: inferring the pglite-on-btrfs QEMU test

This is the reference pattern for "test a browser-UI feature against real
virtual storage". Follow the seams top-down.

**1 — Is the feature compiled?** Everything is `BoardSpec`-gated, so the fixture
is the first artifact, not an afterthought:

```json
{ "kernel": {
    "usb":   { "key": true, "fs_btrfs": true },
    "http":  { "enable": true, "proxy_js": true },
    "store": { "enable": true, "persist": { "usb": true, "volume": "btrfs" } } } }
```

`store.enable` is exactly what `intern_name` checks before handing out a
`StoreFactory` (§7.1) — with it false, the cell's `Eval("window.pglite")` is
refused and the test can only ever fail.

**2 — Does the Svelte source produce the ops?** `Store.svelte` uses
`pgliteOpen` / `pgliteExec` / `pgliteQuery`, each on the `pgliteMethod`
allow-list, so `parse.ts` emits `PgliteOp`s, `print-d.ts` prints the `PgLite`
chain into `app.d`, and `_start` will run it.

**3 — Pin the semantics with a Rust test first.** `crates/g6b-kernel/src/vfs.rs`
already carries `a_store_round_trips_through_btrfs` and
`a_libwasm_cell_posts_sql_through_fetch_post_to_a_btrfs_key`. They establish the
contract: mount rw → create table → insert → export JSON to the volume → fresh
registry imports it → query returns the rows, with the browser seam going
through `fetch_post`. **The QEMU test should print the same phases**, not grep
for a bare substring like `BTRFS`.

**4 — Make the image.** `g6b vfs emit-btrfs --out out/btrfs-key.img` writes the
`g6b_vfs::btrfs::fixture::image(false)` 16 MiB image. Verify host-side with
`g6b vfs scan --disk …` — but note this only proves *image recognition*, never
guest access.

**5 — Boot it.** `tools/build.py test` orchestrates browser-UI → ELF → image →
QEMU (WSL on Windows, `/mnt/<drive>/…` path conversion) with the image attached
as `virtio-blk-device`, and scans the serial log.

**6 — Read the serial log correctly.** The payload writes every character
**twice** (SBI putchar *and* the UART0 THR). De-double before matching:

```
sed 's/\(.\)\1/\1/g'          # tools/qemu_zealcli.sh
re.sub(r"(.)\1", r"\1", text) # tools/build.py
```

Skipping this produces a false negative on every marker — the single most common
wasted debugging hour in this repo.

**7 — Drive the guest.** The BIOS boots to a picker or a prompt, not into your
test. Either disable the picker in the fixture (`cli.boot="cli"`,
`cli.autoboot.enable=false`) or send keystrokes; `tools/build.py test --keys`
does both (serial text + monitor `sendkey`), with `{esc}`/`{ret}`/`{spc}` tokens.

**8 — Assert on markers that mean something.** Useful ones and what they prove:

| Marker | Proves |
|---|---|
| `KSTART-*`, `G6LC-BIOS`, `ZEALCLI-READY` | payload booted, CLI up |
| `WASM-JS-GLOBAL platform -> N` | the cell reached `KernelHost` (§7.1) |
| `WASM-INTERPRETER _start` | `_start` is executing |
| `USB-FILES fat32/btrfs` | the volume-kind selector saw the fs |
| `SVELTE-LIVE Store` | the Svelte store component is live |
| `JS-FETCH /bios/store 200` | the store HTTP seam answered |

What those do **not** prove: that a row was inserted and read back *inside* the
guest. Distinguish host-side fixture scanning from guest-side mount/insert/query
and print per-phase markers (create / insert / query / export / import /
restored-query) if you need the strong claim.

---

## 10. Toolchain & submodules

| Dependency | Kind | Resolution | Installer |
|---|---|---|---|
| **LDC 1.43.0-beta1** | downloaded release | env override → **pinned** `browser-ui/toolchains/` (`toolchains/ldc.lock.json`) → ambient (`findLdc`, `ldc.ts:149`) | `bun scripts/install-ldc.ts` |
| **dub** | ships with LDC | next to `ldc2`, then seeded dirs, then PATH | — |
| **libwasm** | **git submodule** (`g6lc_bios/libwasm`, branch `g6lc_bios`) | `LIBWASM_ROOT` → `…/libwasm`, `…/g6lc_bios/libwasm` (`findLibwasmCheckout`) | `git submodule update --init` |
| **svelte-d** | **git submodule** (`g6lc_bios/svelte-d`) | spec of record; also hosts the binaryen fork | `git submodule update --init` |
| **wasm-opt** | **forked**, in `toolchains/` like LDC | `compiler/binaryen.ts` `resolveWasmOpt()`, 6 providers in order (below) | `bun scripts/install-wasm-opt.ts`; ensured automatically by `tools/build.py` |

`wasm-opt` must be the **fork**, not a stock build: upstream cannot `--asyncify`
a module containing `try_table`, which is exactly what the wasm-EH cell emits.
The fork carries the Flatten pass that makes `try_table` asyncifiable, so
`resolveWasmOpt()` reports *which* provider it found and whether it is forked —
a stock `wasm-opt` on PATH is accepted last and **flagged unforked**
(`binaryen.ts:8-21`):

```
1. SVELTE_D_WASM_OPT / WASM_OPT                    ← explicit override
2. browser-ui/toolchains/binaryen-svelte-d/        ← install-wasm-opt.ts
3. svelte-d/binaryen-build/<variant>/              ← svelte-d's own layout
4. ~/.svelte-d/toolchains/binaryen-svelte-d/       ← bunx svelte-d setup
5. svelte-d/binaryen/{build,out}/bin/              ← a local cmake build
6. PATH                                            ← last, flagged unforked
```

`wasm-opt` is a **toolchain on the same footing as the compiler**, not an
optional nicety, and it lives beside LDC:

```
browser-ui/toolchains/
├── ldc2-1.43.0-beta1-windows-x64/bin/ldc2.exe
└── binaryen-svelte-d/bin/wasm-opt.exe
```

`tools/build.py ensure_wasm_opt()` runs for any libwasm-lane build (mirroring
`ensure_ldc()`), escalating so a fresh clone needs no manual step:

1. `--check` — resolvable **and** it really asyncifies `try_table`
2. default — download the fork's CI binary for this host variant
3. `--from-source` — cmake the `svelte-d/binaryen` submodule

Step 2 falls back to step 3 internally when the fork source is present, so a
network failure, a rate-limited release, or a host with no CI asset is
recoverable without changing flags. A working **out-of-tree** fork (e.g. from
`bunx svelte-d setup` in `~/.svelte-d`) is *adopted by copy* into
`toolchains/` rather than re-downloaded — same verified binary, no network,
and the build then resolves the same path on every host.

Verification is **by behaviour, not by version string**: `asyncifiesTryTable`
builds a tiny `try_table` module and requires the tool to asyncify it, so a
stock Binaryen is refused even if its version looks new enough. The result is
recorded in the cell's provenance as `asyncifyTool` (`"132 browser-ui/toolchains (fork)"`),
which is informational only — deliberately **not** part of `inputs` and not
compared by `checkCellArtifact`, because the output bytes are already pinned
exactly by `sha256` and making the tool a staleness trigger would report a
perfectly good committed artifact as stale on any machine that has not
installed the gitignored toolchain.

`findLibwasmCheckout` **rejects** a `kernel-spec/` or `riscv-compilers/` path and
any DUB cache: the cell must build from the reviewable submodule, so a drifted
local fork cannot silently become the source of truth
(`runtimePreflight`, `ldc.ts:294`).

The pin deliberately **wins over an ambient 1.43** because `cellInputHash`
covers the compiler binary: a host-built `1.43.0-git` snapshot is a *different*
compiler and would invalidate the shipped artifact on every machine
(`ldc.ts:8-13`).

Cross-platform notes: `wasm-opt` may be an ELF binary on a Windows host, so
`runWasmOpt` (`wasm-cell.ts:473`) re-invokes it through WSL and converts
`E:\…` → `/mnt/e/…`. The same conversion is used for QEMU in `tools/build.py`.
`cellEnv` (`wasm-cell.ts:542`) **clears** `DFLAGS`/`DC`/`DMD`/`LDC`/`LDC_FLAGS`/`LDFLAGS`
and re-sets only `-conf=…/ldc2-wasm.conf`, so an ambient LDC 1.41 on PATH can
never leak into the cell.

Generated-file hygiene: `svelte-engine-ws/dub.sdl` and `.svelte-d/*` are
**generated** (`engineDubSdl`, `pinWasmLdc`). Hand-edit them and the build
refuses with "generated dub.sdl does not match the pinned local libwasm cell".
A stale `dub.selections.json` pointing at a retired `browser-ui/libwasm` is
detected and deleted (`wasm-cell.ts:613-623`).

---

## 11. Adding a feature — the checklist this model implies

1. **Spec first.** Add the `BoardSpec` field + `check_cfg`-style legality so the
   feature is compile-gated and minimal profiles still build.
2. **Op second.** New `UiOp` kind in `parse.ts` + the allow-list entry (e.g. a
   new verb in `pgliteMethod`). No op, no feature.
3. **Printers.** Arms in `print-d.ts` (D lane) and/or `print-ts.ts` (JS lane) and
   `emit-wasm.ts` if the first-party lane must carry it.
4. **ABI.** Declare the import in `g6b_kernel.d`; extend `verifyLibwasmAbi`'s
   expected signature map; add the `--export=` if it is a cell export.
5. **Hosts.** Implement in Rust `KernelHost` (real) and decide the browser
   story in `kernel.ts` (real, proxy, or explicit refusal). **Never leave a
   silent stub** — refuse by name like `intern_name` does.
6. **Tests.** Rust test pinning semantics → `bun test` for the compiler/host →
   `tools/build.py test` for the QEMU end-to-end.
7. **Docs.** Update `AGENTS.md` invariants, `AGENTS-todo.md`, the relevant
   `architecture/*.md`, and this file if the model changed.

Gates: `cargo fmt --all --check`, `cargo clippy --workspace --all-targets -- -D warnings`,
`cargo test --workspace`, `bun test`, `bun run build`, `bunx tsc --noEmit`,
`python tools/build.py check`.

---

## 12. Pointers

| Topic | File |
|---|---|
| Invariants, planning state, build commands | `AGENTS.md` |
| Stage checklist | `AGENTS-todo.md` |
| libwasm host ABI + completion plan | `architecture/LIBWASM-ABI.md` |
| Browser runtime (cell on a UI thread, GLES2) | `architecture/BROWSER-RUNTIME.md` |
| Browser subset/config | `architecture/BROWSER.md` |
| Render validation + CSS methodology | `architecture/RENDER-VALIDATION.md` |
| VFS / btrfs / zealcli | `architecture/g6b-vfs.md`, `architecture/g6b-btrfs.md`, `architecture/g6b-zealcli.md` |
| Kernel HTTP endpoints | `architecture/KERNEL-API.md` |
| File server, TLS, USB, menus | `architecture/FILE-SERVER.md`, `TLS.md`, `USB.md`, `MENUS.md` |
| Plan of record / codegen philosophy | `architecture/PLAN.md`, `architecture/CODEGEN.md` |
| Svelte-D spec of record | `svelte-d/` submodule — `svelte-d/architecture/cross-calling.md`, `svelte-d/packages/svelte-d/ts/platform.ts` |

> **Stale path warning.** Several compiler comments still say
> `kernel-spec/svelte-d/...` (`parse.ts:3`, `print-ts.ts:5`, `ldc.ts:4`). The
> spec now lives in the **`svelte-d/` submodule** at the package root;
> `kernel-spec/` holds TempleOS, ZealOS, libwasm, goja, goosie, lirx-dom, botan
> and webidl only. Read `svelte-d/architecture/` for the real thing.
