# Codegen philosophy — ASM IR, not string literals

ZealOS generation is **ASM IR first**. `format!(/* .s */)` and duplicated
`Vec<u32>` encodings are the old path. The generator **analyzes** BoardSpec
objects (hart, stack, trap, memcpy, UART1, reboot) into purpose-tagged IR
nodes, then **lowers** once to assembly text and machine words.

```
BoardSpec objects + purposes
        →  g6b-asm  analyze::objects / analyze::payload
        →  Module { Node { purpose, ops } }
        →  lower →  .S text  |  ELF words + rodata
```

This is a standing coding philosophy for `g6lc_bios` (prime directive 9 in
`AGENTS.md`). It sits beside KD0 and “generated, never typed”: XLEN, RVV, UART
base, hart count, and mailbox base/IRQ still come from BoardSpec; the *program*
those knobs emit is an analyzed IR, not a string template.

| Rule | Meaning |
|---|---|
| IR is the source of truth | `KStart.S`, `KInts.S`, `MemCpy.S`, and `g6b elf` words come from the same `Module` |
| Purpose is state | Each node names *why* a register/CSR/buffer exists (`HartId`→`tp`, `Stack`→`sp`, `TrapVec`→`stvec`) |
| Analyze, then emit | `analyze::objects` walks BoardSpec (`xlen`, `rvv_live`, `dual_band`, `harts`, `power`) and *decides* which nodes exist |
| Strings are payloads | Boot log / HolyC `Print` text is **rodata**, not the program |
| No x86 in the IR | `Op` is RISC-V (and gated RVV). Compiler `BackA` x86 is refused |
| One lower | `Module::to_asm` and `Module::to_words` share label resolution; do not re-encode in `g6b-elf` |

## State objects (homes)

| Purpose | Home | Live when | Spec rewrite |
|---|---|---|---|
| `HartId` | `tp` | always | `KStart64` CPU0 / `SET_GS_BASE` ← OpenSBI `a0` |
| `Dtb` | `s1` | always | OpenSBI `a1` (kept across KMain) |
| `Satp` | `satp` | always | bare + `sfence.vma`; not CR3 |
| `Stack` | `sp` | always | per-hart BSS after payload; `sp = stacks_end-(hartid+1)*0x8000` |
| `TrapVec` | `stvec` | always | `KInterrupts` — not an IDT |
| `BootLog` | `sbi+uart0` | always | UART0 8N1 THR + SBI putchar (QEMU `-nographic`) |
| `Uart1Repl` | `t0` = UART1 | `holyc.dual_band.tcp.enable` | SSH+HolyC chardev; linebuf `View`/`ViewSection("name")`/`Rebo`/`Shut`/`Wake` (not a poll, not a NIC). Modeled base `uart0+0x1000` → `uart0+0x2000` when `wants_virtio_gpu` (QEMU virt virtio-mmio occupies `0x10001000..0x10002000`) |
| `Park` | `wfi` | always | hart≠0 waits; hart0 after KMain (UART RX is irq-driven) |
| `Trap` | `scause` | always | irq 5 → SBI TIME; irq 9 PLIC (`trap_uart` irq 1 linebuf, `trap_mbox` irq 3); else dump `TRAP-<scause>-<sepc>` and WFI |
| `Timer` | `sie+sstatus+SBI-TIME` | always | KStart `jal TimerInit` before park; `rdtime` + interval; not PIT |
| `MemCpy` | `a0,a1,a2` | always | HolyC ISel; RVV iff `v=live` ∧ xlen=64 |
| `Reboot` | `a7=SRST` | postboot power / enable | SBI SRST, not a PC reset port |
| `DisplayProxy` | `gr-plane→scanout` | `kernel.gr` or `kernel.proxy` | `GrInit` `GR16` + 4bpp plane + 8×8 `G6LC` blit; scale 640×480 to HDMI/DP / host-GL |
| `GlAdapter` | `gles2` | `kernel.proxy.gl` | KStart `jal ProxyScale`; GLES2 listing; optional `proxy.accel` RVV `vsetvli` or ai-island 16×16 tiles (not mapping GR to `0x40000000`; not libGL) |
| `Tls` | `sha256+aes128` | `kernel.tls.enable` | first-party crypto |
| `Https` | `a0=url` | `kernel.tls.https` | HolyC `HttpsGet` via kernel → hw TCP + `g6b-tls` ClientHello |
| `WasmJit` | `wasm MVP` | `kernel.wasm.enable` | decode + host JIT; KStart `jal WasmJit` `i32.add` leaf when `wasm.jit` |
| `SvelteUi` | `nodedef` | `kernel.ui=svelte-d` | svelte-d construct catalog |
| `Rsa` | `a0=n,a1=e,a2=sig` | TLS enable | PKCS#1 limb `mul` |
| `Ecdsa` | `p256` | TLS enable | P-256 field add |
| `Cert` | `der` | TLS enable | X.509 length walk |
| `Hmac` | `sha256` | TLS enable | ipad/opad xor |
| `Http` | `h1+h2 parse` | `kernel.http.enable` | first-party HTTP/1.1 + HTTP/2; KStart `jal GetFile` GET `/ui/ui.wasm` |
| `Endpoint` | `router` | HTTP enable | HolyC/JS same table |
| `BiosParam` | `json /bios/*` | clocks/edk2/uboot/bootloader | compiled BIOS params |
| `Flash` | `spi-nor\|mailbox\|usb` | `kernel.flash.enable` | OpenWrt / BIOS self-update |
| `Settings` | `export/import` | `kernel.settings.enable` | UART/mailbox/USB key |
| `Usb` | `msc-fat32\|key-fm` | `kernel.usb.enable` | FAT32 flash always; key FileMgr extra |
| `Topology` | `cores×threads×issue` | SMT / multi-core / issue>1 / OoO / stream | `HartStart` SBI HSM+IPI; Adam on hart 0 |
| `Hypervisor` | `H/HS next-stage` | `extensions.h=live` ∧ xlen=64 | no HS entry from BIOS |
| `Uncore` | `clint\|plic\|ddr\|pcie` | inferred uncore | `PlicInit` S-mode ctx1 + SEI claim/complete |
| `Mailbox` | `mbox-mmio` | `loopback.enable` | `MboxInit` doorbell/status/irq_en; `trap_mbox` View/Reboot/Shutdown/Wakeup; not a netdev |
| `Menu` | `setup tree` | HTTP or HolyC fast init | one model, two UIs |
| `FileServe` | `g6ui+html\|js\|wasm` | `kernel.wasm` or `kernel.http.files` | `UiInit` `G6UI` header; `jal FileServe` echoes `\0asm` + `/ui/` listing; HolyC HTTPS file server on the host |
| `UiDom` | `__ui_dom→__gr_plane` | `kernel.wasm.jit` | `g6b-asm::dom` row store + `WasmStart` (from `g6b-wasm::jit::start_ops`) + `DomPaint` (`DOM| ` serial + `__font` glyphs) |
| `Virtio` | `vio-mmio` | `wants_virtio_gpu` | `VioProbe` slot scan for GPU DeviceID 16 + `VioInit` handshake/ctrlq/`GET_DISPLAY_INFO` + `VioCmd` submit-one + `VioScan` (`CREATE_2D`/`ATTACH_BACKING`/`SET_SCANOUT`/band-fill/`TRANSFER`/`FLUSH` at the `__disp`-latched output geometry) (`VIRTIO-GPU n`/`NONE`/`OK`/`INFO`/`SCAN`/`FAIL`); `__vio` BSS rings + `__scan_fb` (max-geometry shared surface); host-modelled + QEMU `screendump` captured (1920×1080) |
| `VirtioNet` | `vio-mmio-net` | `wants_virtio_net` (`kernel.hw.virtio_net`) | `VioNetProbe` DeviceID 1 (`VIRTIO-NET n`/`NONE`). Exec model slot 5. **Never** QEMU `-netdev`. Host TCP/UDP/NAT is `g6b-hw`; HTTP(S) fetch is kernel→hw TCP |
| `DispScan` | `disp-mmio` | `wants_disp_scan` (`display`-class peripheral) | `FbExpand`/`FbExpand1`/`DomPaint32` (shared blits, `Proxy::to_ppm` semantics, geometry from `__disp` at runtime via `divu`) + `DispPaint` — register-window commit + `G6FB` simplefb handoff at `__vio+0x400` (`architecture/uncore/hdmi-display.md`); `DISP-OK`/`DISP-FAIL` |
| `NativeService` | `boot-owned ABI frame + native RX image` | `g6b elf --native-manifest` | rustc `g6b-guest` callee; `Capabilities` / `Input` / `Poll` then `BootStatus`/`BootTrial` `NotReady` → `NATIVE-SERVICE-OK` / `NATIVE-POLL-OK` / `NATIVE-BOOT-HOLD`; copies the frame to `__native_abi`; `trap_timer` `NativePoll` → `NATIVE-TICK-POLL-OK` once. Clears `AUTO_ON`. Not firmware `_start`. [`KERNEL-RV.md`](KERNEL-RV.md) |
| `LinuxHandoff` | `satp=0 a0=hartid a1=fdt jalr Image` | `LinuxEnter` / `LinuxRelocate` / `LinuxLoadDisk` | UART `Lnx` loads LBA 40 after G6BH `InProgress`; else `LINUX-HOLD`. QEMU `LINUX-ENTRY-OK`. Not OpenWrt. [`KERNEL-RV.md`](KERNEL-RV.md) |

## Crate surface

| Item | Role |
|---|---|
| `g6b_asm::analyze::objects` | state inventory (purpose, live, why, home) |
| `g6b_asm::analyze::payload` | ELF body (`kstart` + `MemCpy` + boot-log rodata) |
| `g6b-elf::native` / `g6b-guest` | opt-in rustc callee PT_LOADs; not a second encoder for KStart |
| `g6b_asm::analyze::kstart` | `zeal/KStart.S` |
| `g6b_asm::analyze::kints` | `zeal/KInts.S` |
| `g6b_asm::analyze::libcalls` | `zeal/MemCpy.S` (`MemCpy` + `Reboot`) |
| `Module::to_asm` / `to_words` | the only lower |
| `g6b-gr::proxy` / `gl` | display-proxy PPM + GLES2 listing (not payload insns) |
| `g6b-fs` | canned USB FAT32 flash + key FileMgr listings (not payload insns, not a VFS) |

HolyC `g6b-holyc::isel` is a Target-shaped wrapper around that IR. It must not
grow a second encoder.

## Cooperative task library

`g6b-asm::task::{task_switch_ir,task_entry_ir}` generate Topology-purpose nodes
for the cooperative integer task ABI. The only added instruction operation is
CSRRC, lowered/formatted/executed through the same pipeline. Tests execute
repeated context alternations and handler/exit trampolines on RV32 and RV64;
the executor's RV32 logical right shift now masks its operand to XLEN first.

The display-geometry pass added `Op::Divu` (RVM `divu`) so the `FbExpand`
family can derive the integer scale from `__disp` at runtime instead of baking
the gen-time proxy geometry, and fixed the host executor's RV32 effective
address: the register file keeps sign-extended values, so loads/stores/`jalr`
at `0x8xxx_xxxx` must truncate `rs1 + imm` to 32 bits before the bounds check
(`eff_addr`).

`g6b-kernel::TaskServices` exposes the primitive modules and constructs validated
XLEN-specific initial context bytes tied to scheduler hart ownership and the
BoardSpec stack budget. These are a **library seam**, not a second encoder,
and are not silently appended to or invoked by the default guest boot path.
Guest runqueue/allocator/dispatch integration is still required. See
`KERNEL-RV.md` for register, SIE, FS/VS/XS, lifetime and SMP contracts.

## Review checklist (codegen)

- New generated instruction? Add an `Op`, a `Purpose` (or attach to an existing
  one), and a node in `analyze` — not a `format!("\t…")` in `g6b-design`.
- New BoardSpec knob that changes the payload? Gate it in `objects()` (`live`)
  so state management stays inspectable.
- `.S` and ELF must not diverge: both lower the same `Module`.
- Comments in generated listings must not contain refused x86 needles (`CR0`,
  `EFER`, `LAPIC`, `IRET`, `CF9`, `RAX`) — tests grep for their absence.
