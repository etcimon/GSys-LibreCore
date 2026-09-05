# Kernel-spec → RISC-V (rewrite map)

TempleOS/ZealOS name **services**. This file is the RISC-V rewrite. x86 in the
spec forks is refused. Conformity: `PLAN.md` §3.

| Spec locus | Service | RISC-V rewrite | Refused (x86) |
|---|---|---|---|
| `ZealOS/src/Kernel/KStart64.ZC` `SYS_ENTER_LONG_MODE` | Become 64-bit | Already S-mode from OpenSBI; `KSTART-XLEN-{32,64}` from BoardSpec | CR0/CR3/CR4, EFER.LME, GDT far jump |
| `KStart64` CPU0 / `SET_GS_BASE` | Boot hart identity | OpenSBI `a0=hartid` → `tp`; `a1=dtb` → `s1`. No `csrr mhartid` (M-mode) | GS base, CPUID |
| paging / `CR3` | Address translation | All harts `csrw satp, x0` + `sfence.vma` (bare S-mode; Sv39 is Linux) | CR3, `invlpg` |
| `KStart64` `TaskInit` / `SET_FS_BASE` / `RSP` | Adam stack | **All harts:** `sp = stacks_end - (hartid+1)*0x8000` in BSS after the image; then `stvec`. Hart≠0 `WFI`. ELF `p_memsz` = aligned filesz + N×`STACK_BYTES` (+ `GR16` header + 4bpp plane when Gr/proxy live + UART line + 32-byte `G6UI` when WASM/files live). `bios-ui.wasm` is `.rodata`, not BSS | FS base, shared `MEM_ADAM_STK` |
| `KStart64` `JMP KMain` | First C/HolyC | Print `KMAIN` then generated `KMain` boot log: UART0 ns16550 8N1 THR **and** SBI putchar (QEMU `-nographic`) | COM1 `0x3F8` |
| `KStart64` `SYS_RAM_REBOOT` | Reset | SBI SRST later (`Reboot` HolyC); not `0xCF9` | IRET to 32-bit, `WBINVD` |
| `KMain.ZC` `SysGlobalsInit` | Globals | BoardSpec product/isa; no IDE letters | `CPUId`, `OutU8` PIT/VGA |
| `KMain.ZC` `SysGrInit` | Display | Payload `GrInit` writes `GR16` header + 4bpp 640×480 plane + 8×8 `G6LC` blit (same bits as `g6b-gr`). `jal ProxyScale` when `kernel.proxy.gl` (scalar / RVV / ai-island). Host PPM + QEMU `virtio-gpu-device`; not VGA ports | `VGAM_*`, `OutU8(VGAP_IDX)` |
| `KMain.ZC` `TimerInit` | Tick | S-mode `sie.STIE` + `sstatus.SIE` + `rdtime` + SBI TIME (`EID=0x54494D45`); KStart `jal TimerInit` after the boot log, before park/UART1 | `PIT_CMD` `0x43` |
| `KMain.ZC` `Reboot` | Power | SBI SRST / HolyC `Reboot` | `OutU8(0x64)`, port `0x92` |
| `KInterrupts.ZC` `IRQ_TIMER` / `INT_FAULT` | Traps | irq 5 → SBI TIME; irq 9 → PLIC (`trap_uart` irq 1 + `ViewSection("name")` → `VIEW name`; `Ui`/`U` → `UI`; `File`/`F` → `FileServe("/ui")`; `Get`/`G` → `GetFile("/ui/ui.wasm")`; `trap_mbox` irq 3 V/R/S/W/U/F/G); else `TRAP-<scause>-<sepc>` WFI | IDT, `IRET`, `LAPIC_EOI` |
| `KTask.ZC` `CTask` / `Fs`/`Gs` | Task + CPU | `tp` = hart; single Adam task on hart 0; other harts `wfi` | `Fs` as FS, `Gs` as GS |
| Multicore `mp_count` | Extra harts | Every hart sets `sp`/`stvec`; hart≠0 `WFI`. Hart 0 `HartStart`: SBI HSM `hart_start` + IPI; trap irq 1 (SSI) `sret`s (wake). Adam on hart 0 | LAPIC IPI |
| post-boot mbox | Sideband | `MboxInit` writes `G6MB` + irq_en at `loopback.base` (default `0x10100000`). `trap_mbox` on PLIC irq 3: doorbell=1 + CMD `V`/`R`/`S`/`W`/`U` → ST_RSP `VIEW`/`WAKE`/`UI` or SBI SRST. Not a netdev | HECI as NIC |
| svelte-d / libwasm UI | Browser-UI | `UiInit` writes `G6UI` (`0x49553647`) + size/flags/accel/ptr at `__ui_blob`. ELF `.rodata` `__ui_wasm` is `browser-ui/out/bios-ui.wasm`. `FileServe` echoes `\0asm` and prints `/ui/` paths. `jal WasmJit` is the `i32.add` leaf. Not a VFS, not wasmtime | host Chromium |
| `Compiler/Back*.ZC` | HolyC → machine code | `g6b-asm` IR (purpose-tagged nodes) → scalar `MemCpy` or RVV `vsetvli`/`vle8.v`/`vse8.v` iff `extensions.v=live` ∧ xlen=64 | x86 `BackA`/`RAX`, emitting RVV when `v` is not live, a second string encoder |

Entry convention (OpenSBI `fw_dynamic` next stage): **`a0` hartid, `a1` dtb**.
Hart 0 runs KStart→KMain. Others WFI.

`la` lowers to `auipc`+`addi` (PC-relative). RV64 `lui` of DRAM `0x8xxx_xxxx`
sign-extends to `0xFFFFFFFF8xxx_xxxx`, which is not QEMU virt physical DRAM.

Generated artefacts: `zeal/KStart.S`, `zeal/KInts.S`, `zeal/MemCpy.S`
(`g6b-design`) and `g6lc_bios.elf` (`g6b-elf`) all lower one `g6b-asm` `Module`
after `analyze::objects` tags each state's purpose and home (`CODEGEN.md`).
Host smoke: `g6b smoke` (`g6b-asm::exec`) runs hart 0 until WFI (UART RX is PLIC irq 1, not a busy poll).

## Cooperative integer task ABI and multicore policy

The ZealOS `Sched.ZC` contract supplies per-core round-robin readiness and
voluntary yield, not x86 register layouts or a justification for busy-waiting.
`g6b-asm::task` now emits executable **RV32/RV64 cooperative primitives** through
the existing IR/encoder. It does not replace the guest boot park loop yet.

`g6b_task_switch(a0=old, a1=next)` operates on aligned guest context images:

| XLEN-word slots | Saved state |
|---|---|
| 0–1 | ra, sp |
| 2–13 | s0–s11, following the RISC-V integer calling convention |
| 14 | sstatus.SIE mask, exactly 0 or 2 |
| 15 | immutable owner hart, compared against tp |

The image is little-endian, **64 bytes RV32 / 128 bytes RV64**, aligned to
16 bytes; stack tops are 16-byte aligned. Entry/return addresses are 4-byte
aligned in this uncompressed generated-code subset. `gp` and `tp` remain
hart-owned; no task TLS, satp, sepc or address-space change is implied. CSRRC
atomically masks local SIE before context access; it is restored after the
incoming registers/stack are ready. Nonzero FS/VS/XS state is rejected: this
is not an FP/vector/extension context switch. Caller-saved integer registers
follow normal call semantics; this is **not an interrupt-preemptive save frame**.

The switch validates pointer alignment, distinct context addresses, owner hart
and incoming/outgoing register state before stores. Rejection returns -1 and
restores the caller's SIE without modifying either context. `TaskLayout` also
checks complete extents, overlap, XLEN representability and initial-stack
ownership. These checks do not establish mapped memory or executable authority:
allocation, mapping and lifetime must be established by the eventual guest
allocator/dispatcher. An interrupt handler must preserve interrupted registers
and must not schedule while a context switch is in progress.

`g6b_task_entry` invokes the registered integer handler with an opaque a0
argument, then invokes a nonreturning exit hook with its a0 result. An exit
hook that returns masks SIE and parks. It must switch away before reclaiming
its own stack. Five-switch machine-word tests cover both XLENs, stack locals,
callee-saved state, opaque values, gp/tp and SIE; malformed contexts and active
FS/VS/XS are rejected. This is executor evidence, not a QEMU scheduler run.

### Kernel policy and HolyC handler interface

`g6b-kernel::tasks::Scheduler` supplies bounded, pinned-hart ready/running/
blocked/finished/cancelled states. UI tasks belong to `ui_hart`; Main/Worker
placement uses other physical cores before SMT siblings, including the UI
core's sibling last. On one hart all roles time-slice. This is thread isolation,
not exclusive ownership of a physical core/cache. Harts are currently modeled
as contiguous SMT siblings (`core = hart / threads_per_core`).

One task may run per hart. Dispatch handles include scheduler identity, slot
generation and dispatch epoch. Yield/readiness reserves capacity; sleep uses
caller-supplied monotonic ticks and retries wakeup under backpressure. Cancelling
a running task retains its hart/stack reservation until a safe-point response.
Results are one-shot and terminal descriptors are reclaimed only when reaped.
The Rust policy API is serialized by exclusive ownership; local SIE masking
alone is **not** an SMP queue lock or cross-hart memory-publication protocol.

`TaskServices`, enabled by `kernel.tasking.enable`, prepares registered HolyC
handlers and isolated digest/numeric-WASM jobs. `dispatch(hart)` returns an
owned `Work`: release scheduler/UI ownership before `Work::run`, then submit
its `WorkResponse` to `accept`. HolyC runs at most 64 handler steps per turn;
Yield retains its owned continuation. WASM jobs are no-import i32 modules with
16,384 fuel and isolated memory. `native_wasm_ir` offers the existing numeric
RISC-V lowering; host job execution still uses the interpreter. Digests use
first-party SHA-256, **not encryption**. The browser's AES-GCM path is separate.
Every dispatched ticket must return or be explicitly aborted by its executor;
there is no unsafe forced reclamation of a potentially running task.

```text
U0 Compute(U64 argument) { Print(argument); Yield(); Sha256("abc"); }
ThreadCreate("Compute", 42);
```

`Program::prepare_handler` validates the entire reachable task-only call graph
before admission. Supported calls are Print, Yield, Throw, Sha256 and registered
handlers; kernel mutation builtins are rejected. `BrowserSession::holyc_request`
handles ThreadCreate and returns the real queued slot/generation/hart. Standalone
`Program::repl` does not independently spawn tasks. Handler arguments, call
depth, lifetime steps, code and results are bounded; Throw becomes a failed
completion. Main/UI APIs can translate completion Results into the existing
continuation/exception boundary without retaining a DOM borrow across execution.

### Remaining guest integration and saturation gates

`TaskServices::native_primitives` and `initial_context` expose the actual ASM
ABI, but the default ELF does not yet allocate guest task stacks or invoke this
scheduler. Required next: registered native handler addresses and allocator,
per-hart dispatcher/idle loop, SMP release/acquire or atomic runqueue protocol,
SBI IPI wakeup/error handling, IRQ-to-normal-context event delivery, guest
JS/WASM continuation installation, and FP/vector save policy if those tasks
are admitted. W^X/PMP, lifetime and fence.i/multihart code-cache synchronization
remain mandatory for executable JIT installation. Never clear FP state merely
to bypass the integer ABI restriction.

Host tests exercise 1/2/4/8-hart policy, actual OS-thread execution of owned jobs,
and independent UI operations while work is outstanding. They establish neither
on-guest parallelism nor all-core saturation. Saturation needs guest per-hart
completed-work counters and a reproducible workload, plus UI frame/input latency,
IRQ/idle behavior and throughput measurements; worker count alone is not evidence.
