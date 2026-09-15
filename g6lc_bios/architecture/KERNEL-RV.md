# Kernel-spec → RISC-V (rewrite map)

TempleOS/ZealOS name **services**. This file is the RISC-V rewrite. x86 in the
spec forks is refused. Conformity: `PLAN.md` §3.

| Spec locus | Service | RISC-V rewrite | Refused (x86) |
|---|---|---|---|
| `ZealOS/src/Kernel/KStart64.ZC` `SYS_ENTER_LONG_MODE` | Become 64-bit | Already S-mode from OpenSBI; `KSTART-XLEN-{32,64}` from BoardSpec | CR0/CR3/CR4, EFER.LME, GDT far jump |
| `KStart64` CPU0 / `SET_GS_BASE` | Boot hart identity | OpenSBI `a0=hartid` → `tp`; `a1=dtb` → `s1`. No `csrr mhartid` (M-mode) | GS base, CPUID |
| paging / `CR3` | Address translation | All harts `csrw satp, x0` + `sfence.vma` (bare S-mode; Sv39 is Linux) | CR3, `invlpg` |
| `KStart64` `TaskInit` / `SET_FS_BASE` / `RSP` | Adam stack | **All harts:** `sp = stacks_end - (hartid+1)*0x8000` in BSS after the image; then `stvec`. Hart≠0 `WFI`. ELF `p_memsz` = aligned filesz + N×`STACK_BYTES` (+ `GR16` header + 4bpp plane when Gr/proxy live + UART line + 32-byte `G6UI` when WASM/files live + `__ui_dom` rows when `kernel.wasm.jit`). `bios-ui.wasm`, `__wasm_data` and `__font` are `.rodata`, not BSS | FS base, shared `MEM_ADAM_STK` |
| `KStart64` `JMP KMain` | First C/HolyC | Print `KMAIN` then generated `KMain` boot log: UART0 ns16550 8N1 THR **and** SBI putchar (QEMU `-nographic`) | COM1 `0x3F8` |
| `KStart64` `SYS_RAM_REBOOT` | Reset | SBI SRST later (`Reboot` HolyC); not `0xCF9` | IRET to 32-bit, `WBINVD` |
| `KMain.ZC` `SysGlobalsInit` | Globals | BoardSpec product/isa; no IDE letters | `CPUId`, `OutU8` PIT/VGA |
| `KMain.ZC` `SysGrInit` | Display | Payload `GrInit` writes `GR16` header + 4bpp 640×480 plane + 8×8 `G6LC` blit (same bits as `g6b-gr`). `jal ProxyScale` when `kernel.proxy.gl` (scalar / RVV / ai-island). Host PPM + QEMU `virtio-gpu-device`; not VGA ports | `VGAM_*`, `OutU8(VGAP_IDX)` |
| `KMain.ZC` `TimerInit` | Tick | S-mode `sie.STIE` + `sstatus.SIE` + `rdtime` + SBI TIME (`EID=0x54494D45`); KStart `jal TimerInit` after the boot log, before park/UART1 | `PIT_CMD` `0x43` |
| `KMain.ZC` `Reboot` | Power | SBI SRST / HolyC `Reboot` | `OutU8(0x64)`, port `0x92` |
| `KInterrupts.ZC` `IRQ_TIMER` / `INT_FAULT` | Traps | irq 5 → SBI TIME; irq 9 → PLIC S-mode context `2*tp+1` (`trap_uart` irq 10 (QEMU virt ns16550; virtio-mmio slot i → irq 1+i → `trap_vio` ISR ack + count) + `ViewSection("name")` → `VIEW name`; `Ui`/`U` → `UI`; `File`/`F` → `FileServe("/ui")`; `Get`/`G` → `GetFile("/ui/ui.wasm")`; `trap_mbox` irq 3 V/R/S/W/U/F/G — only when `loopback.enable`; the UART1 drain runs only when `dual_band.tcp` since stock virt has no second ns16550); else `TRAP-<scause>-<sepc>` WFI | IDT, `IRET`, `LAPIC_EOI` |
| `KTask.ZC` `CTask` / `Fs`/`Gs` | Task + CPU | `tp` = hart; single Adam task on hart 0; other harts `wfi` | `Fs` as FS, `Gs` as GS |
| Multicore `mp_count` | Extra harts | Every hart sets `sp`/`stvec`; non-handoff harts `WFI`. The **OpenSBI handoff hart** (`a1≠0` at `_start`, any hart id) runs init and `HartStart`: SBI HSM `hart_start` for the others + IPI; trap irq 1 (SSI) `sret`s (wake). Adam on the handoff hart — QEMU's boot-hart lottery is not always hart 0 | LAPIC IPI |
| virtio-mmio window | Display/GPU transport | QEMU virt instantiates **8 transports always**, `0x10001000 + 0x1000*i` (each region 0x200; the stride gaps fault on access); `-device` backends attach to the last free bus (observed slot 7). Transports are legacy (Version=1) unless `-global virtio-mmio.force-legacy=false` — legacy ignores QueueDesc/Avail/Used/Ready. `VioProbe`/`VioInit`/`VioScan` scan with early-out; QueueNotify is iothread-async so the used-ring poll is `1<<22` iterations | fixed slot-0 assumption, `0x200` stride, legacy QueuePFN |
| post-boot mbox | Sideband | `MboxInit` writes `G6MB` + irq_en at `loopback.base` (default `0x10100000`). `trap_mbox` on PLIC irq 3: doorbell=1 + CMD `V`/`R`/`S`/`W`/`U` → ST_RSP `VIEW`/`WAKE`/`UI` or SBI SRST. Not a netdev | HECI as NIC |
| svelte-d / libwasm UI | Browser-UI | `UiInit` writes `G6UI` (`0x49553647`) + size/flags/accel/ptr at `__ui_blob`. ELF `.rodata` `__ui_wasm` is the LDC cell when live. `FileServe` echoes `\0asm` and prints `/ui/` paths. Host `BrowserSession` runs that cell (no MVP fallback). `jal WasmJit` is the numeric `i32.add` worker; `jal WasmUi` is the VGA glyph face (`__ui_dom` + `DomPaint`), not the web engine. Not a VFS, not wasmtime | host Chromium |
| `Compiler/Back*.ZC` | HolyC → machine code | `g6b-asm` IR (purpose-tagged nodes) → scalar `MemCpy` or RVV `vsetvli`/`vle8.v`/`vse8.v` iff `extensions.v=live` ∧ xlen=64 | x86 `BackA`/`RAX`, emitting RVV when `v` is not live, a second string encoder |

Entry convention (OpenSBI `fw_dynamic` next stage): **`a0` hartid, `a1` dtb**.
The handoff hart (`a1≠0`) runs KStart→KMain; secondary SBI HSM entries
(`a1==0`) WFI. QEMU's boot-hart lottery can hand off on any hart.

**Stock-QEMU-virt fixture:** `fixtures/g6lc64-qemu.json` boots the ELF under
OpenSBI 1.5 + QEMU 8.2 end-to-end (`VIRTIO-SCAN` + QMP screendump evidence —
see DISPLAY.md). It disables `loopback` (the mbox `0x10100000` collides with
QEMU `fw_cfg`) and `dual_band.tcp` (no second ns16550) and sets
`postboot.enable=never`/`net_expose.mode=never`; `g6lc64-virt.json` remains
the custom-board spec for a QEMU device model that provides them.

`la` lowers to `auipc`+`addi` (PC-relative). RV64 `lui` of DRAM `0x8xxx_xxxx`
sign-extends to `0xFFFFFFFF8xxx_xxxx`, which is not QEMU virt physical DRAM.

Generated artefacts: `zeal/KStart.S`, `zeal/KInts.S`, `zeal/MemCpy.S`
(`g6b-design`) and `g6lc_bios.elf` (`g6b-elf`) all lower one `g6b-asm` `Module`
after `analyze::objects` tags each state's purpose and home (`CODEGEN.md`).
Host smoke: `g6b smoke` (`g6b-asm::exec`) runs hart 0 until WFI (UART RX is PLIC irq 10 — QEMU virt's ns16550 line — not a busy poll; virtio-mmio completions are claimed through the PLIC too).

## Recovery protocol and native-service ABI groundwork

The first recovery-program increment adds two independent, safe `no_std`
libraries without changing the active boot path:

- `g6b-runtime-abi`: 64-byte little-endian `G6SR` version-1 requests. Header
  length/version/reserved bits, operation IDs, nonzero request IDs and caller
  context slot/generation are checked before accepting input/output spans.
  Spans must fit the caller's declared memory window without overflow; output
  cannot overlap input or the request header. Decoding a request does not grant
  permission to perform its operation; native dispatch/authorization is pending.
- `g6b-bootctl`: 128-byte `G6BT` attempt tickets and two 4096-byte `G6BH`
  journal slots. Both encode explicit version/length and CRC32C, not Rust memory
  layouts. Tickets bind domain, sequence, nonzero nonce, device/partition IDs
  and image digest. CRC detects corruption, not authenticity; image validation,
  CSPRNG provenance and Linux readiness are obligations of the future producers.

Journal initialization is explicit and refuses nonblank media. State transitions
write the other slot, flush and read back before returning a handoff ticket.
Any uncertain I/O poisons the live writer until reload. A missing/corrupt newer
copy cannot restore an older record's permission to boot: degraded journals
inhibit autoboot and reset reconciliation persists the hold. Conflicting equal
generations or discontinuous copies fail closed. Generation exhaustion never
wraps. Linux acknowledgement requires the exact in-progress attempt and root,
service and watchdog readiness; it cannot acknowledge the firmware domain or
silently clear an operator/recovery inhibit. A successful trial and explicit
re-enable are separate operations.

`g6b-kernel::bootctl::JournalStorage` adapts a declared VFS device region to the
slots, rejecting invalid extents, read-only devices and transports without a
declared durable flush. `FileBlock` uses OS `sync_all`; `SubDev` forwards the
capability, while the default and memory-only device do not claim durability.
The adapter's exclusive borrow is not cross-process locking: callers must own
and serialize the metadata region for the complete read/modify/flush/readback
transaction. Native ownership and Linux process locking remain integration work.
File reopen tests and torn-write models are not physical storage qualification.

Verification:

```text
cargo test -p g6b-bootctl -p g6b-runtime-abi
cargo test -p g6b-kernel bootctl::tests
cargo check -p g6b-bootctl -p g6b-runtime-abi --target riscv64imac-unknown-none-elf
```

The cross-check uses Rust 1.85.0; it proves library portability. Native guest
**link/entry** is a separate increment (below). `g6b-boot-health` is the Linux-generic helper core plus a file-based
OpenWrt adapter; it acknowledges the exact pending G6BH attempt and
cannot enable autoboot. Watchdog ownership requires a `nowayout=1` stamp;
keepalive or magic-close of a disarmable watchdog is not an acknowledgement. `g6b-boot-health::bundle` refuses squashfs/UBI as kernels and requires a
complete RISC-V Image bundle before any future jump. `LinuxEnter` is the
S-mode entry ABI (`satp=0`, `a0=hartid`, `a1=FDT`, `jalr`); exec canary
`LINUX-ENTRY-OK`. `LinuxRelocate` copies Image+FDT into reserved `__linux_load` BSS and
refuses overlapping source/destination. `LinuxLoadDisk` requires a G6BH `InProgress` slot or prints `LINUX-HOLD`.
UART `Lnx` on QEMU virt after `g6b arm-disk` prints `LINUX-ENTRY-OK`. The
canary FDT carries `/firmware/g6b-boot-health` (`LINUX-HEALTH-OK`);
`g6b-boot-health --dtb`/`--dt-root` opens that journal window.
`g6b-boot-health::volume::scan` classifies GPT/MBR partitions (Image vs
squashfs/UBI rootfs vs FDT) and lists `/boot` files on mountable
filesystems; `--scan` is read-only and does not jump. A file-backed
`/dev/watchdog` mock applies Linux open/keepalive/magic-close/nowayout
without `ioctl(2)`. `LinuxEnter` arms a platform `mtime` WDT (`G6WD`)
that fires `LINUX-WDT-FIRE` even when `sie=0`. Live OpenWrt VM, real
kernel, TLS/management and flashing a full inactive firmware image
remain open. No RTL/ISA/DTS/DFT change is part of this increment.

## Native service-callee ELF (not bootable firmware)

The rustc image is labelled `native-service-callee-not-bootable-firmware` in
`out/native/native-manifest.json`. It is **not** OpenSBI `_start`. Build:

```text
python tools/g6b.py native --load-address 0x84000000 --out out/native
python tools/g6b.py elf --spec fixtures/g6lc64-native-services.json \
    --native-manifest out/native/native-manifest.json \
    --out out/native/g6lc_bios-native.elf
```

Contract (Python `guest_native.validate_image` and `g6b-elf::native::Image::parse`
must agree):

- ELF64 LE SYSV, EM_RISCV, ET_EXEC, integer calling convention (e_flags bit 0 only)
- PT_LOAD is RX (`PF=5`) or R (`PF=4`), page-aligned, `p_filesz == p_memsz`
- no W, no WX, no BSS, no PT_DYNAMIC / PT_INTERP / PT_TLS / GNU_RELRO
- PT_RISCV_ATTRIBUTES / GNU_STACK / NOTE / PHDR are ignored
- `e_entry` of the **composed** BIOS ELF is the generated ASM payload
  (`dram_base+text_offset`); the callee's entry is a later RX PT_LOAD
- C ABI: `a0` points at one exclusively owned 256-byte frame; `a0` returns status

`Purpose::NativeService` is inserted before `Park`. It zeros a 256-byte
frame on the BIOS stack, then:

1. Masks SIE and `jalr`s `Capabilities` (initializes the 128-byte core at
   frame offset 128). Prints `NATIVE-SERVICE-OK`.
2. Still masked, `Input` enqueues a watchdog IRQ then a slow-I/O IRQ
   (enqueue only — no TLS/wasm/slow work).
3. Restores SIE and `jalr`s `Poll`. `Poll` always takes watchdog before
   slow jobs, under a small quota. Prints `NATIVE-POLL-OK` when the
   watchdog bit is set.
4. Failure prints `NATIVE-SERVICE-FAIL` and parks.

Implemented operations: `Capabilities`, `Input`, `Poll`, `Cancel`,
`BootStatus`, `BootTrial`. The last two return `NotReady` until a durable
`SlotStorage` exists; `written` stays 0 so Ok cannot be forged. `Cancel`
checks context generation. `g6b-runtime-abi::Bump` is a fail-closed
cursor over caller-owned backing (workspace forbids `unsafe`, so not a
Rust `GlobalAlloc`). After `NATIVE-BOOT-HOLD` the probe copies the
256-byte frame to `__native_abi`; `trap_timer` `jal NativePoll` and
`jalr`s the callee (SIE still masked). First successful tick prints
`NATIVE-TICK-POLL-OK` once. Absent `--native-manifest` the stub
returns immediately and keeps the legacy single RWX PT_LOAD.

After `NATIVE-POLL-OK` the probe requires `BootStatus`/`BootTrial`
`NotReady`, stores 0 to `AUTO_ON`, and prints `NATIVE-BOOT-HOLD`.

QEMU 8.2.2 `-M virt -kernel` serial: `NATIVE-SERVICE-OK`, `NATIVE-POLL-OK`,
`NATIVE-BOOT-HOLD`. Host `g6b smoke` does **not** map extra PT_LOADs.
The callee stays RX/R. Host `AutoBoot::with_decision(Stay)` will not
countdown. Guest `BlkWrite`/`BlkFlush` exist for LBA 8..24 with `F_FLUSH`.
`JrnLoad`/`JrnCommit` rewrite an 8-sector `G6BH` slot and read it back;
the production boot path does not call them. Host
`JournalStorage::on_bios_window` is that same window. QEMU 8.2.2 UART `Jrn` on a writable virtio-blk scratch disk prints
`JRN-LOAD-OK`/`JRN-COMMIT-OK` and leaves a CRC-valid G6BH record.
Firmware A/B stubs occupy LBA 24 and 32 (`FirmwareLayout::BIOS`); journal
I/O must not overwrite them. `FwStage` may rewrite inactive B only
(`G6FS`); recovery A is `FW-RANGE`. `FwCommit` writes all 8 declared
sectors of B, flushes, and readbacks first/last. `FwSelect` nominates staged B (`G6SL` at B+8) only when first and last
sectors match `G6FS`/`G6FE`; a torn slot is `FW-HOLD`. Inhibit and
autoboot stay untouched. Do not arm unattended Linux handoff.

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

## Guest WASM-DOM lane (`Purpose::UiDom`)

`kernel.wasm.jit` extends the payload with a bounded lirx-dom-shaped DOM
store plus the `g6b-wasm::jit::start_ops` lowering of the wasm `_start`
(`WASM.md` B53 guest lane). New `Addr` selectors: `WasmData` (`__wasm_data`
.rodata = decoded data image), `UiFont` (`__font` = `g6b-asm::font` 8x8
table), `UiDom` (`__ui_dom` BSS after `__ui_blob`, `UI_DOM_BYTES` = 16 +
48x32 in `p_memsz`). New IR surface: `Purpose::UiDom` and register aliases
`s0`/`s2`-`s6`, `t3`-`t6`, `a3`-`a5` (the encoder already named x8-x31).

| Routine | Contract |
|---|---|
| `VioProbe` | leaf, t-regs only: scans 8 virtio-mmio slots (`0x10001000+0x200*i`) for MagicValue `virt` + DeviceID 16; prints `VIRTIO-GPU <slot>`/`VIRTIO-GPU-NONE`. Enumeration only — no virtqueue/DMA/scanout |
| `VioInit` | leaf, t-regs only: virtio 1.x handshake (reset→ACK|DRIVER→`VIRTIO_F_VERSION_1`→FEATURES_OK readback→DRIVER_OK), ctrlq rings in `__vio` (desc@0, avail@0x80, used@0xC0, req@0x120, resp@0x180), one `GET_DISPLAY_INFO` chain → `VIRTIO-INFO`/`VIRTIO-GPU-FAIL`. `fence` orders ring writes before notify; InterruptStatus is read and written back to InterruptACK after each completion |
| `VioCmd` | leaf, t-regs only: submit-one chain — desc0 = OUT req (len a0), desc1 = WRITE resp (a1 = expected resp type, a2 = request size), publish avail idx, `fence`, `QueueNotify` (virtio-mmio+0x50), bounded used-idx poll, ISR read+ack (0x60→0x64), a0 = resp type from `__vio` |
| `VioScan` | leaf (saves s0..s2): runs after `DispSel`, exits unless `__disp.class == VirtioGpu`; `RESOURCE_CREATE_2D`(res 1, B8G8R8X8, `__disp.w×h`) → `RESOURCE_ATTACH_BACKING`(`__scan_fb`) → `SET_SCANOUT`(0, res 1, `__disp` rect) → guest-fill `__scan_fb` (0x0000AA00 green band, min(64, h) rows) → `TRANSFER_TO_HOST_2D` → `RESOURCE_FLUSH` → `VIRTIO-SCAN`/`VIRTIO-GPU-FAIL`. QEMU `screendump` captured at 1920×1080 |
| `FbExpand` / `FbExpand1` | leaf (saves t3..t6 + s0..s2): shared scanout blit — 4bpp `__gr_plane` → X8R8G8B8 `__scan_fb` with `g6b_gr::proxy::Proxy` semantics (`fit`/`dpi` uniform scale, centered letterbox; `fill` per-axis integer stretch; `FbExpand1` pins scale 1). Scale, letterbox and row pad are computed from `__disp` w/h/stride at runtime via `Op::Divu` (clamp 1..=64), so the latched output mode drives the blit, not the gen-time proxy default |
| `FbExpandSel` | `__disp.surface`: gpu → `DomPaint32` (DOM live) or `FbExpand1`; vga → `FbExpand` |
| `VioPaint` | exits unless `__disp.class == VirtioGpu`; if `__ui_cap` `WEB_PRESENT`, `TRANSFER_TO_HOST_2D` of dirty tiles then `RESOURCE_FLUSH` (`VIRTIO-PAINT` / `VIRTIO-PAINT-SKIP`); else `jal FbExpandSel` then full-frame TRANSFER+FLUSH. Runs after the plane painters and on UART `Ui` |
| `DispPaint` | exits unless `__disp.class == UncoreScanout`; `jal FbExpandSel` then the uncore display-engine commit (`architecture/uncore/hdmi-display.md`): MAGIC detect → FB/W/H/STRIDE/FORMAT/CTRL from `__disp` → `G6FB` descriptor at `__vio+0x400` (simplefb-shaped BIOS→Linux handoff) → COMMIT→STATUS (`DISP-OK`/`DISP-FAIL`); live when a `display`-class peripheral exists (`wants_disp_scan`, virtio transport yields) |
| `PciPaint` | exits unless `__disp.class == PcieLinearFb` and `DISP_PCI_FB != 0`; `jal FbExpandSel` writes straight into the accepted BAR (the destination pick reads `DISP_SEL_FB_LO`, 0 = `__scan_fb`), then `fence` — the BAR is the display memory, there is no doorbell (`PCI-PAINT`); live on `pcie.scan_display` boards |
| `DomPaint32` | native 32bpp glyph paint into `__scan_fb`: clears `__disp.w × h` words and addresses glyph rows by the latched stride — the same runtime geometry as the blits |
| `WasmUi` | `jal WasmStart` (lowered `_start`) then `jal DomPaint`; returns |
| `WasmStart` | `g6b-wasm::jit::start_ops` output; `i32.const` -> `La __wasm_data`+off / `li` -> `jal` import stubs; prologue saves `ra` |
| `WasmDomFind` | a0=id_ptr, a1=id_len -> row index or -1 (byte-compare, 48-row bound) |
| `WasmDomText` | `env.set_inner_text`: find-or-insert, stores ptr/len, sets visible+text flags |
| `WasmDomVisible` | `env.set_visible`: flag flip; row and text retained |
| `WasmFetch` / `WasmLog` | `GET <path>` / `LOG <text>` on SBI serial, <= 96 bytes |
| `DomPaint` | `DOM| <text>` serial per visible row + 8x8 glyph blits into `__gr_plane` (4bpp) |

All rows/id lengths/printed bytes/painted characters are bounded; malformed
calls drop rather than trap. The UART `Ui` command additionally `jal`s
`DomPaint`, so the live `__ui_dom` transcript can be re-dumped on demand
after boot. Host smoke captures `dom_rows`, `dom_pix0` and the full executed
`__gr_plane` (`Smoke.gr_frame`); `g6b smoke --out f.ppm` exports it as a P6
PPM (`g6b-gr::plane_to_ppm`, `g6b_kernel::frame_ppm`). `g6b smoke --out-vio
f.ppm` likewise exports the device-side virtio-gpu scanout surface
(`Smoke.vio_fb`, B8G8R8X8 → `g6b-gr::x8r8_to_ppm`, `g6b_kernel::scanout_ppm`).
QEMU `screendump` capture at the high-res geometry is landed (1920×1080,
centered scale — `architecture/DISPLAY.md`); input delivery and
reentrant `WasmStart` remain B53 gates.
