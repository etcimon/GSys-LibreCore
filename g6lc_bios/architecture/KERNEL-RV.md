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
