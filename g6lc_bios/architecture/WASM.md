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
handle-based `env.createElement`, `appendChild`, `setProperty` and the
`__cpp_exception` tag, not the MVP encoder's pointer/length text/fetch ABI.
Unsupported object/event/promise/libc operations must fail explicitly; reducing
an import list by returning invented values is not runtime implementation.
vibe.0 host cell remains refused (OpenSBI + mailbox).

| svelte-d construct | BIOS |
|---|---|
| `mixin NodeDef!"tag"` | live HTML (`g6b-webidl`) |
| `@prop!"innerText"` / `{msg}` | `SetInnerText` |
| `{#if ident}` / `{:else}` | initial-boolean AOT `set_visible`, both JS and WASM; not reactive |
| `_start` / `mixin Spa!App` | export `_start`; `WASM-JIT` |
| `{#each}` / `UnorderedList` | stub |
| `{#await}` / Binaryen asyncify | stub |
| `FileMgr` | **live** — kernel `fetch /bios/files/{fat32,ntfs,ext4}` |
| `Menu` | **live** — `fetch /bios/menu/{cpu,uncore}` |
| vibe.0 host cell | refused |
| SvelteKit `+page` / `load` / `handleFetch` | **refused** |

LDC discovery matches svelte-d `findLdc`: `SVELTE_D_LDC`,
`~/.svelte-d/toolchains`, `riscv-compilers/ldc2-build/bin` (this host:
`E:\cva6\riscv-compilers\ldc2-build\bin\ldc2.exe` 1.43.0-git). Full
`dub build` of the ws cell: `G6B_DUB_WASM=1 bun run build`.

## B52: validated execution and real numeric lowering

`decode` and public `validate` enforce an **i32-only, single-result subset**.
Section ordering/duplicates, full byte consumption, indices, signatures,
LEB overflow, declared-memory/data bounds, local types and operand/control
stacks are checked. `run`, `run_start`, `run_with_fuel` and `jit_riscv`
revalidate even manually constructed modules before effects. Unsupported
standard/extension sections and instructions fail closed.

Interpreter support includes zero-initialized locals and parameters,
local.get/set/tee, internal calls, return, drop, nop, select, unreachable,
block/loop/if/else, br/br_if, i32 arithmetic, trapping division/remainder,
comparisons, bitwise operations, shifts and rotates. UTF-8 pointer/length
imports are bounds checked. `set_visible` preserves the DOM subtree.
Supported binary sections are custom/type/import/function/memory/export/code
and active data. Instance-local mutable memory supports i32 loads/stores at
8/16/32-bit widths, signed/unsigned narrow loads, unaligned little-endian
access, `memory.size` and `memory.grow`. Nested calls and host string reads
see the same memory; independent runs start from the module's initialization
image. Address-plus-offset arithmetic does not wrap; stores validate the whole
range before writing. Growth respects both declared maximum and the 16-page
runtime cap, returns -1 on failure, and zeroes added pages. A declared maximum
up to the WASM32 limit is accepted without allocating that maximum.
Standard start sections, globals, tables, elements, non-i32 types, multi-value,
bulk memory and exception proposals remain unsupported. A compiled LDC
wasm-eh cell is not thereby supported by this VM.

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

The import ABI remains side-effect-only: `env.set_inner_text(i32,i32,i32,i32)`,
`env.set_visible(i32,i32,i32)`, and `env.console_log`, `env.fetch`,
`env.Object_Call_string__Handle` with two i32 arguments, all returning void.
It does not provide a general JS object/Promise handle table.

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
| Binaryen Asyncify | **Not enabled.** Await-bearing Svelte or explicit Asyncify requests fail the current DUB cell rather than silently ignoring suspension. No validated transform/runtime pairing yet. |
| RISC-V JIT | Numeric leaves only; await, native EH unwinding and continuation frames are not lowered. The Rust scheduler is host-tested native software, not installed in the S-mode payload. |

Async defaults are 16 tasks, 64 KiB source/program text per task, 4,096 compiled
steps, 8,192 execution steps per task, 16 KiB completion text and 64 steps per
tick. Pending-only ticks do zero work. Tokens are one-shot, scheduler-local;
stale/duplicate/canceled completions are discarded. No DOM borrow survives a
suspension. Handles in static DOM transactions remain compile-local.

Before enabling D await: pin a compatible Binaryen/EH transform, enumerate
async imports, reserve/check unwind storage, implement unwind/rewind exports,
root suspended allocations/handles, prohibit reentrant resume, and test rejection,
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
