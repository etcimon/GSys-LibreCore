# WASM-JIT — svelte-d UI on the g6b kernel

`kernel-spec/svelte-d` (MIT) is the **compiler spec**: Svelte syntax falls
through to a libwasm NodeDef graph and one wasm module. BIOS does **not**
compile that tree. `browser-ui/` is the first-party bun+TS consumer:

```
browser-ui/src/*.svelte
        │  svelte-d fall-through (not SvelteKit)
        ▼
browser-ui/svelte-engine-ws/     dub.sdl wasm-eh cell
        src-d/   mixin NodeDef / @prop / @child / mixin Spa!App
        src-ts/  jsExports + window.__svelteD.ts
        .svelte-d/wasm-ldc.json   LDC 1.43 pin (never PATH 1.41/1.42)
        │
        ├─ LDC 1.43 + dub --arch=wasm32-unknown-wasi
        │    libwasm = local clone browser-ui/libwasm (G6LC_G6B)
        │    public/bios-ui.wasm
        │
        └─ bun first-party MVP encoder → out/bios-ui.wasm
                 │
                 ▼
        g6b-wasm decode + KernelHost
                 ├─ set_inner_text → g6b-dom
                 ├─ fetch          → g6b-http::Router
                 └─ jit_riscv      → g6b-asm Purpose::WasmJit
        g6b-elf payload
                 ├─ `.rodata` `__ui_wasm` = out/bios-ui.wasm
                 ├─ BSS `__ui_blob` `G6UI` header (size/flags/ptr/`\0asm`/nfiles)
                 └─ KStart `jal UiInit` / `FileServe` / `GetFile` / `WasmJit` (`i32.add`)
        g6b-js AOT of g6b-ui::setup_script(BoardSpec)
                 └─ selected read-only fetch → same Router
        out/bios-ui.js remains an all-profile compiler demonstration
        /ui/app.js uses the native browser adapter instead
```

The local libwasm adaptation is **not** `kernel-spec/libwasm`.
`version(G6LC_G6B)` selects the BIOS kernel boundary. The LDC artifact uses
handle-based `env.createElement`, `appendChild`, `setProperty`, the
`__cpp_exception` tag, `env.libwasm_await__void`, and the libwasm await status /
object-string ABI (`libwasm_await_supported`, `libwasm_await_failed`,
`libwasm_await_error`, `libwasm_await_value`, `libwasm_note_await_fail`,
`libwasm_note_await_ok`, `libwasm_get__string`, `libwasm_add__string`),
not the MVP encoder's pointer/length text/fetch ABI.
Unsupported object/event/promise/libc operations must fail explicitly; reducing
an import list by returning invented values is not runtime implementation.
vibe.0 host cell remains refused (OpenSBI + mailbox).

`types.d` declares **116** distinct `extern(C)` host imports. The g6b-native
DOM/router/await set, the B61 object lifetime trio (`libwasm_add__object` /
`libwasm_removeObject` / `libwasm_copyObjectRef`), the B62 scalar box/unbox
families (`libwasm_add__*` / `libwasm_get__*`), the twelve B67 `ldexec_*`
Lodash imports, B68 promise combinators and typed-array / DataView `Create`,
and the B69 ES6 `Map` host surface (`libwasm_map_*`) are implemented. The interpreter accepts non-`i32` import
signatures for the B62 libwasm scalar imports and the B67 `ldexec_*` family;
wasm-local bodies remain an `i32` machine.
The rest are `assert(0)` stubs in `g6b_kernel.d`. The complete
inventory — lowered signatures, the refcounted `JsHandle` model, the
`jsCallback` event path, the `ldexec` Lodash command buffer, the ES6 posture,
and the staged B61–B69 completion sequence — is
[`LIBWASM-ABI.md`](LIBWASM-ABI.md). That file is a plan; do not read its
planned rows as capabilities.

| svelte-d construct | BIOS |
|---|---|
| `mixin NodeDef!"tag"` | live HTML (`g6b-webidl`) |
| `@prop!"innerText"` / `{msg}` | `SetInnerText` |
| `{#if ident}` / `{:else}` | initial-boolean AOT `set_visible`, both JS and WASM; not reactive |
| `_start` / `mixin Spa!App` | export `_start`; `WASM-JIT` |
| `{#each}` / `UnorderedList` | stub |
| `{#await}` / Binaryen asyncify | build path — custom binaryen `wasm-opt --asyncify` with EH/bulk-memory; D `await`/`catch` lowering still open |
| `FileMgr` | **live** — kernel `fetch /bios/files/{fat32,ntfs,ext4}` |
| `Menu` | **live** — `fetch /bios/menu/{cpu,uncore}` |
| vibe.0 host cell | refused |
| SvelteKit `+page` / `load` / `handleFetch` | **refused** |

LDC discovery matches svelte-d `findLdc`: `SVELTE_D_LDC`,
`~/.svelte-d/toolchains`, `riscv-compilers/ldc2-build/bin` (this host:
`E:\cva6\riscv-compilers\ldc2-build\bin\ldc2.exe` 1.43.0-git). Full
`dub build` of the ws cell: `G6B_DUB_WASM=1 bun run build`. Asyncify post-link
with the custom binaryen: `G6B_DUB_WASM=1 G6B_WASM_ASYNCIFY=1 bun run build`.

## B52/B55: validated execution and widened structural parsing

`decode` and `validate` enforce bounded resource limits and byte-aligned
consumption. Section ordering/duplicates, full byte consumption, indices,
signatures, LEB overflow, declared-memory/data bounds, local types and
operand/control stacks are checked. `run`, `run_start`, `run_with_fuel` and
`jit_riscv` revalidate even manually constructed modules before effects.
Unsupported runtime paths fail closed.

The **decoder** now structurally accepts the real LDC 1.43 / libwasm
Asyncify artifact: i32/i64/f32/f64 value types and constants, all
load/store widths, `call_indirect`, `br_table`, bulk memory (`memory.copy`,
`memory.fill`, `memory.init`, `data.drop`, `table.init`, `table.copy`,
`table.fill`, `table.get/set/grow/size`), saturating float-to-int
conversions, legacy exception-handling opcodes (`throw`/`rethrow`/
`try`/`catch`/`catch_all`/`delegate`/`try_table`), `return_call`,
`call_ref` and unknown `0xfc`/`0xfd` prefixed opcodes. These are either
validated and, when executable, interpreted, or `run` fails closed with a
clear message. Tables, elements, globals, tags and multi-memory/table
metadata are decoded and validated.

The **interpreter** now executes i32 and i64 locals, parameters, globals,
memory, arithmetic, comparisons, shifts, loads and stores. f32/f64
constants, loads, stores and arithmetic are implemented too, with
WebAssembly NaN/propagation semantics delegated to the host `f32`/`f64`
operations. The public API remains `&[i32]` compatible, returning
`Vec<i32>` and converting non-i32 results to `0` until the callers are
widened.

`call_indirect`, `memory.copy` and `memory.fill` are now executable on a
per-runtime table and memory model (runtime table slots initialised from
`Element` segments; function type checked against the indirect `typeidx`).
Table state is mutable: `table.get/set/fill/copy/init/grow/size` and
`elem.drop` now execute with bounds and dropped-segment checks. `memory.init`
and `data.drop` execute on passive `DataSegment` data with dropped-segment
bounds checks. Legacy exception handling `try`/`catch`/`catch_all`/`throw`/
`rethrow` executes for single-payload tags; `try_table`, `delegate` and
`throw_ref` remain fail-closed. Reference types and multi-value blocks remain
parsed and validated but fail-closed at execution.
The libwasm D host imports (`env.createElement` with a `NodeType` enum,
`env.appendChild`, `env.setProperty` with D `(length, ptr)` string pairs,
`env.fetch`, `env.libwasm_await__void`, `env.holyc`,
`env.register_endpoint`) are dispatched to the `Host` trait.
`g6b-kernel::KernelHost` and `g6b-wasm::DomHost` now maintain a handle
 table (handle 1 = root, 2+ = created elements), so `_start` can build the
live DOM under a real kernel session. With a no-op `TestHost` the real
`browser-ui/out/bios-ui-libwasm.wasm` `_start` export also runs to
completion under the default fuel budget, confirming structural decoding
and the i32/i64/f32/f64 + control-flow execution lanes.
A compiled LDC wasm-eh cell is not thereby supported by this bounded guest
engine.

| Budget | Bound |
|---|---|
| Encoded module / declared memory | 1 MiB / 16 × 64 KiB |
| Types, total functions, exports, data segments | 256 each |
| Imports / UTF-8 name bytes | 64 / 256 |
| Parameters / results | 32 / 0 or 1 |
| Parameters + locals / operand stack | 256 / 256 per function |
| Control frames / call depth | 64 / 64 |
| Instructions | 65,536 per module |
| Execution fuel | 100,000 default; caller-selectable up to 1,000,000 |
| Numeric JIT | 4,096 instructions; 256 combined slots; ≤1,024-byte aligned frame |

The import ABI now also covers the libwasm cell:
`env.createElement(i32) -> i32` (NodeType enum), `env.appendChild(i32,i32)`,
`env.setProperty(i32, i32, i32, i32, i32)` (handle, key_len, key_ptr,
val_len, val_ptr), `env.fetch(i32,i32) -> i32`, `env.holyc(i32,i32) -> i32`,
`env.register_endpoint(i32,i32,i32,i32) -> i32`,
`env.libwasm_await__void(i32)`, and the libwasm await/object-string ABI:
`env.libwasm_await_supported() -> i32`, `env.libwasm_await_failed() -> i32`,
`env.libwasm_await_error(i32 raw_result) -> ()`,
`env.libwasm_await_value(i32 raw_result) -> ()`,
`env.libwasm_map_create() -> i32`,
`env.libwasm_map_set(i32, i32, i32, i32, i32)`,
`env.libwasm_map_get__OptionalString(i32 raw, i32, i32, i32)`,
`env.libwasm_map_has(i32, i32, i32) -> i32`,
`env.libwasm_map_delete(i32, i32, i32)`,
`env.libwasm_map_clear(i32)`,
`env.libwasm_note_await_fail(i32 handle) -> ()`,
`env.libwasm_note_await_ok(i32 handle) -> ()`,
`env.libwasm_get__string(i32 raw_result, i32 handle) -> ()`,
`env.libwasm_add__string(i32 len, i32 ptr) -> i32`, and the B62 numeric
box/unbox set: `libwasm_add__*` and `libwasm_get__*` for `bool`, `int`/`uint`,
`long`/`ulong`, `short`/`ushort`, `float`, `double`, `byte`/`ubyte`, `ints`,
`uints`, plus `libwasm_get__field` / `libwasm_get_idx__field` stubs.
The original kernel-side imports (`env.set_inner_text`, `env.set_visible`,
`env.console_log`, `env.Object_Call_string__Handle`, `env.await`, `env.throw`,
`env.catch`) remain wired as the browser/await/throw/catch correlate. The host
interface is through the `g6b_wasm::Host` trait, not a JS object/Promise
table.

`jit_riscv(module, export, xlen)` produces an executable `g6b-asm::Module`
marked `Purpose::WasmJit`, for RV32IM or RV64IM. The supported straight-line
numeric export has at most three i32 parameters, zero/one result, constants,
locals, drop/nop, add/sub/mul, and/or/xor, shifts/rotates, signed/unsigned
ordering comparisons, eq/ne/eqz, select and terminal return/end.
Unsupported control flow/calls/trapping arithmetic are rejected, not silently
interpreted as native code. Stack slots use `sw/lw` to preserve exact i32
wrapping/sign-extension on RV64; the aligned frame is restored. The legacy
`jit_add_i32()` keeps its symbol but now also wraps/sign-extends correctly.
Machine-word differential tests execute both XLENs through the existing ASM
executor and compare the interpreter, including overflow and select results.
Nested branch/unreachable validation cases were additionally cross-checked
against native WebAssembly, including rejected cases and valid variants.

**What remains open:** guest runtime compilation/dispatch, executable-memory
permissions and installation, instruction-cache synchronization, host-import
trampolines, full guest DOM/UI execution, and broader WASM proposals. The
ELF's existing bring-up `WasmJit` leaf is not replaced by an on-guest general
compiler in this pass. `WASM-INTERPRETER _start` identifies host UI execution;
`WASM-JIT-RV numeric-leaves; UI host interpreter` does not claim the UI was
natively compiled. Native browser tests use the browser engine, with bounded
imports but without the Rust fuel mechanism.

## B53 prerequisite increment: LDC, continuations and display

The front end is first-party **Bun/TypeScript**, not an LDC-built Svelte compiler
executable. DUB compiles its generated D workspace with **LDC 1.43** and the
local carried `libwasm/runtime-v1.43.0` (generated from druntime). The workspace
uses an isolated `ldc2-wasm.conf`, empty default libraries and only local runtime
imports. Ambient DFLAGS/DC/DMD are replaced/cleared; older/newer unmatched
compiler/runtime pairs are rejected. The carried runtime is a selected library
surface, not a general Phobos or stock WASI port.

The generated App explicitly opts into `g6bStaticDom`: one `Spa!App`, component
NodeDefs and properties, but no D router construction or browser callback
registration. Native setup navigation continues through the shared kernel
router. Unsupported libwasm object getters, event/Promise registration and
unimplemented libc/GC paths trap; this increment must not call them and must
not replace them with invented successful results. Complete Svelte tree,
reactivity, routes and lifetime support are still prerequisites.

The LDC lane exports `_start(i32 heap_base)`, `memory`, `__heap_base`, and the
particle state ABI `g6b_fx_data()`, `g6b_fx_count()`, `g6b_fx_logo()` returning
i32 pointers/counts, plus `g6b_fx_step(f32 seconds)`. Particle positions,
velocities, lifespan and the bouncing wordmark are calculated in D/WASM using
fixed arrays (256 particles, deterministic xorshift initialization and bounded
vortex/gravity integration). Rendering delegates to the native browser WebGL
adapter; there is no new WASM GL import and no guest GL implementation implied.
CSS is extracted from App.svelte into `out/bios-ui.css`; CSS is not WASM code.

Published artifacts are content-hashed against generated D/Svelte, compiler,
adapter, local runtime/dependencies and toolchain binaries. Requested DUB
failures return nonzero and invalidate the optional published bytes. Ordinary
Bun builds keep only a provenance/ABI-verified current artifact; stale/missing
artifacts become an empty optional file, not a silent old UI. `build.json` and
`bios-ui-libwasm.json` distinguish the two lanes. See `FILE-SERVER.md` for serving.

### Async and exception contract — separate mechanisms

| Mechanism | Current boundary |
|---|---|
| Rust `g6b-js::compile_async` / `AsyncScheduler` | Explicit bounded continuation subset: standalone await-fetch, string throw, sequential nonnested try/catch, catch logging/rethrow, await inside catch. Not general Promises/async functions. |
| Kernel `BrowserSession::poll_async` | One bounded scheduler turn; selected read-only BoardSpec router requests complete afterward, and scripts resume only on a subsequent poll. Navigation cancels old tasks. No network wait or busy-drain loop. |
| Catchable errors | Explicit throw and rejected request. DOM host errors/resource exhaustion remain noncatchable traps in this subset. |
| Native browser | Promise-based fetch and frame callbacks are separate; optional LDC startup begins independently of pending MVP kernel reads. Frame updates never await network reads. |
| LDC WASM EH | Compiler-generated exception-tag ABI; not proof of full D runtime exception/cleanup correctness. Unsupported stubs and WASM traps are not ordinary catchable exceptions. |
| Binaryen Asyncify |  `g6b-wasm::Asyncify` recognizes the five asyncify exports and `__asyncify_state` / `__asyncify_data` globals; `run_start` drives a bounded step/resume loop for asyncified modules. `libwasm_await__void` now sets the asyncify state/data so the instrumented wasm unwinds, and `KernelHost` records/slot+resolve the Promise handle. Full D `await`/`catch` Promise continuations and generated D lowering are still open. |
| RISC-V JIT | Numeric leaves only; await, native EH unwinding and continuation frames are not lowered. The Rust scheduler is host-tested native software, not installed in the S-mode payload. |

Async defaults are 16 tasks, 64 KiB source/program text per task, 4,096 compiled
steps, 8,192 execution steps per task, 16 KiB completion text and 64 steps per
tick. Pending-only ticks do zero work. Tokens are one-shot, scheduler-local;
stale/duplicate/canceled completions are discarded. No DOM borrow survives a
suspension. Handles in static DOM transactions remain compile-local.

With the pinned Binaryen/EH transform in the build pipeline, the remaining D
await work is: enumerate all async imports (currently `env.libwasm_await__void`),
reserve/check unwind storage, implement the JS host unwind/rewind driver, root
suspended allocations/handles, prohibit reentrant resume, and test rejection,
nested cleanup, cancellation and memory growth during suspension. A native
RISC-V alternative must preserve PC/locals/operand/control/exception state,
validate imports before effects, and restore the same semantics across yields.
Both require a bounded normal-context ready queue fed by IRQ/transport events;
DOM or D callbacks must never execute directly in an interrupt handler.
Executable installation additionally requires W^X/PMP policy, code-cache lifetime
and instruction-cache synchronization on every consuming hart.

Validation added: 105 memory cases cross-checked against native WebAssembly;
1,358 JIT differential cases on each XLEN (2,716 machine executions); async
fulfillment/rejection/throw/cancel/budget tests; actual LDC-compiled deterministic
particle-state stepping. These do not constitute guest UI, RTL or GPU evidence.

## B53 guest lane: `_start` lowering -> `__ui_dom` -> `DomPaint`

When `kernel.wasm.jit` is live, `g6b-elf::payload_module` replaces the
`WasmStart` anchor (emitted as a `ret` stub by `g6b-asm::dom::nodes`) with
`g6b_wasm::jit::start_ops` output: the guest ISel of the MVP wasm `_start`.
The supported form is straight-line: `i32.const`, i32
`local.get`/`local.set`/`local.tee` (≤4 locals), `drop`, and `call` to the
known `env` imports — including a single i32 call result — ending in
`end`/`return`. Live values live in a bounded s2..s5 register pool
(locals claim `s2+i`, call results and re-set locals claim a fresh pool
reg — SSA-style, so a pushed `local.get` keeps its value); pool
exhaustion fails closed, as do other instructions, non-`env` calls, local
calls, arity/signature mismatch and leftover operands. This is not an
on-guest general compiler, and `jit_riscv` remains the separate
numeric-leaf lane.

Import mapping (pointer args resolve as `__wasm_data + i32 offset`; the data
image is `jit::data_image`, the module's initialized linear memory trimmed to
its last non-zero byte, 4-aligned, capped at 16 KiB of `.rodata`):

| `env` import | Guest stub | Args | Effect |
|---|---|---|---|
| `set_inner_text` | `WasmDomText` | id ptr/len, text ptr/len | find-or-insert `__ui_dom` row; sets visible+text |
| `set_visible` | `WasmDomVisible` | id ptr/len, on | flag flip only; row and text retained |
| `fetch` / `Object_Call_string__Handle` | `WasmFetch` | url ptr/len | `GET <path>` over serial (same shape as `GetFile`) |
| `console_log` | `WasmLog` | ptr/len | `LOG <text>` over serial |
| `await` | `WasmAwait` | `()->i32` | claim a bounded pending slot → `AWAIT pending N` + `await.N` = `"pending menu"`, returns the slot; all `AWAIT_SLOTS`=4 pending → `AWAIT-REJ full`, returns -1 |
| `throw` | `WasmThrow` | `(i32)->()` | reject slot `a0` when pending (`a0`<0 -> the newest pending) -> `AWAIT-THROW` + `await.N` = `"rejected menu"`; non-pending -> `AWAIT-THROW none` |
| `catch` | `WasmCatch` | `(i32)->i32` | return 1 iff slot `a0` is rejected (state 3); 0 for idle, pending or resolved slots, and for out-of-range/negative indices. Query-only; does not consume the rejection. | `a0` when pending (`a0`<0 → the newest pending) → `AWAIT-THROW` + `await.N` = `"rejected menu"`; non-pending → `AWAIT-THROW none` |

`WasmAwait`/`WasmThrow`/`WasmCatch` are the same routines the UART `Await`/`Throw`
commands `jal` — the `env` import and the serial command are two entries
into one bounded queue. `Throw` accepts an optional slot digit (`Throw 2`
rejects slot 2; plain `Throw` is `a0=-1` → newest pending). `DomAwait`
resolves at most **one** pending slot per call (bounded O(1) interrupt
work): the `trap_timer` tick calls it once, while the `Ui`/`Keys` polls
call it `AWAIT_SLOTS` times to drain (`AWAIT-GET /bios/menu` → `await.N` =
`"resolved menu"`). One-per-quantum also makes the UART burst race
deterministic — `Throw` can't lose to a drain-all tick.

`__ui_dom` is a bounded BSS table (`UI_DOM_BYTES` = 32 + 48x32): a header
(count, dirty, painted watermark, `npend` pending-await count, the four
`AWAIT_SLOTS` u32s) plus 48 rows of `{id_ptr, text_ptr, id_len, text_len,
flags}`.
Bounds: id <= 96 bytes (longer ids dropped), <= 48 rows (overflow dropped),
96 printed bytes per `GET`/`LOG`, 72 characters per painted row, rows painted
from `DOM_Y0` (y=24) while they fit the plane. `DomPaint` emits `DOM| <text>`
on SBI serial and, when Gr/proxy is live, blits glyphs from `__font`
(`g6b-asm::font`, first-party 8x8, `0x20`-`0x7E` with `a-z` folded to `A-Z`,
box fallback) into the 4bpp `__gr_plane`. The boot log gains
`KSTART-WASM-UI` and `KSTART-DOM` markers; the hart-0 call order ends
`... jal WasmJit; jal WasmUi; park`.

`g6b_asm::exec` models `__ui_dom` (`smoke.dom_rows`) and the first painted
word at the DOM origin (`smoke.dom_pix0`); `payload_memsz` covers the DOM BSS.
`g6b-elf` smoke on `kernel.wasm.jit` specs shows `DOM| ` lines carrying the
generated menu text and nonzero `dom_pix0`. The same `payload_module` feeds
ELF packing and host smoke, so the assembled payload cannot diverge from what
the host executes.

**Still open and not implied:** arbitrary wasm control flow or indirect calls,
guest-native JS execution, a second `WasmStart` invocation after boot (the DOM
lane runs once from KStart), input delivery, virtio-gpu resource/scanout
commands (the `DOM|` serial transcript is the observable channel until that
exists), asyncify continuations and EH unwinding on guest code.

## Asyncify and EH in the guest (g6b-wasm / g6b-asm)

The libwasm cell is currently built for the browser host. Running it in the
guest kernel through `g6b-wasm` / `WasmJit` requires implementing the Binaryen
asyncify runtime and the WebAssembly proposals it depends on.

### What the Binaryen `--asyncify` pass produces

- Two globals: `__asyncify_state` (0=normal, 1=unwinding, 2=rewinding) and
  `__asyncify_data` (pointer to an `{ i32 pos, i32 end }` descriptor in linear
  memory). `asyncify_get_state()` returns the state.
- Four exports:
  - `asyncify_start_unwind(data)` — set state to unwinding and store the data
    pointer.
  - `asyncify_stop_unwind()` — set state to normal.
  - `asyncify_start_rewind(data)` — set state to rewinding and store the data
    pointer.
  - `asyncify_stop_rewind()` — set state to normal.
- Instrumentation around every call that may suspend (direct/indirect inside
  the call graph of `env.libwasm_await__void`):
  - In normal state, execute the call. If the call returns, continue.
  - If the call returns while the state is now `unwinding`, save locals to the
    asyncify stack, push the call index, and return to the host.
  - In `rewinding` state, restore locals from the asyncify stack, check the
    call index, and either skip to the next call or resume the saved
    continuation.
- The asyncify stack is stored in a reserved linear-memory region pointed to by
  `__asyncify_data`. The region is above `__data_end` / `__heap_base` and grows
  upward from `pos` toward `end`.

### How the host/kernel drives it

1. Guest calls `env.libwasm_await__void(handle)`. The kernel's libwasm host
   looks up the `Promise` for `handle`.
2. If the Promise is pending, the host calls `asyncify_start_unwind(data)` and
   lets the call return. The instrumented wasm unwinds the stack to `_start`
   and returns to the kernel.
3. The kernel stops unwind (`asyncify_stop_unwind()`), stores the asyncify data
   and the Promise on the await queue.
4. When the await queue slot resolves (or rejects), the kernel calls
   `asyncify_start_rewind(data)` and then re-invokes `_start`.
5. The instrumented wasm rewinds the stack, restores locals, returns from
   `libwasm_await__void`, and `await` returns the resolved value or throws a
   wasm exception caught by D `catch`.

### Current g6b-wasm status

- `decode` and `validate` structurally accept the real LDC 1.43 / libwasm
  Asyncify artifact and fail closed on unsupported opcodes.
- Execution: i32 numeric opcodes, `i64`/`f32`/`f64` constants and loads/stores
  (the `Value` stack carries all four width classes), legacy exception handling
  (`try`/`catch`/`catch_all`/`throw`/`rethrow`), bulk memory and table
  operations, and `call_indirect` with type checking.
- `try_table`, `delegate`, `throw_ref`, reference types and multi-value blocks
  remain parsed and validated but fail closed at execution.
- `g6b-wasm::Asyncify` recognizes the five asyncify exports, `__asyncify_state`
  and `__asyncify_data` globals, and the `run_start` bounded step/resume loop.
  `libwasm_await__void` now sets the asyncify state/data so the instrumented
  wasm can unwind; `KernelHost` records the slot and implements `take_slot` /
  `resolve_slot`.
- `g6b-wasm::Host` exposes `await_supported`, `await_failed`, `await_error`,
  `await_value`, `note_await_fail`, `note_await_ok`, `add_string`, `get_string`
  and the object table (`object_base` = `0x0010_0000`) for fetch results and
  error/reason strings. `Runtime::call_import` dispatches all of these, and
  `Runtime::string_pool_next` writes guest-visible strings into bounded memory.
- `KernelHost` uses the router for `fetch` and records await settlement in
  `last_await_failed`/`last_await_error`/`last_await_value`. `resolve_slot` is
  wired to `Router`-backed resolution and writes the resolved value or error as
  a guest-visible string/object handle.
- `browser-ui/kernel.ts` `createLibwasmHost` now provides the same status/note
  and object/string imports, plus a `writeString` helper that bounds-checks the
  sret pointer, allocates UTF-8 payload memory (via `allocString` or a fallback
  page growth), and writes a D `(length, ptr)` string struct.
- `browser-ui/libwasm/source/libwasm/g6b_kernel.d` exposes the new imports as
  `extern(C)` declarations, keeps `libwasm_get__string`/`libwasm_add__string` as
  host imports, and adds the B62 scalar box/unbox set (`libwasm_add__*` /
  `libwasm_get__*`). The property `libwasm_get__field` / `libwasm_get_idx__field`
  stubs remain `assert(0)` until B63.
- `crates/g6b-wasm/src/values.rs` defines `LibwasmValue`, the host-side scalar
  and vector representation used by `TestHost` and `KernelHost`.
- `browser-ui/compiler/wasm-cell.ts` accepts the B62 numeric signatures in its
  `LIBWASM_ABI` import manifest.
- `bun run build` with `G6B_DUB_WASM=1 G6B_WASM_ASYNCIFY=1` and LDC 1.43 produces
  a fresh verified asyncified `out/bios-ui-libwasm.wasm`.
- Still open: full D `await`/`catch` Promise continuation lowering to the
  `libwasmAwaitFailed`/`libwasmAwaitError` D helpers, propagation of the
  rejection into a D `catch` via `__cpp_exception`.
