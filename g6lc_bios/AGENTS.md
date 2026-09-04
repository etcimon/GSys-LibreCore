# g6lc_bios — Agent Guider (package root)

> **Scope:** Independent setup firmware. The **platform is a rewrite** of
> TempleOS / ZealOS, which are **specs** under `kernel-spec/` — not a port, not
> a vendor blob, not a Cargo dependency. Hosts (`g6lc_qemu`, `build-platform`)
> may *emit* a BoardSpec JSON; they never become crate dependencies.

| Artifact | Path | Role |
|---|---|---|
| This guider | `AGENTS.md` | Invariants + current planning state |
| Live todo | `AGENTS-todo.md` | Stage checklist |
| Living plan | `architecture/PLAN.md` | Rewrite-from-spec, conformity gate, B0–B49 |
| Licensing | `AGENTS-licensing.md` | MIT first-party; Unlicense `kernel-spec/` |
| Architecture | `architecture/` | PLAN, ZEAL, DESIGN, CODEGEN |
| Kernel spec | `kernel-spec/` | TempleOS + ZealOS reference forks (not compiled) |
| Green command | `python tools/g6b.py check` | independence + fmt + clippy + test + bios-regress |

## Current planning state

**B0–B49 landed.** Profiles `embedded`/`router` → `full` compile UART+SPI flash
up to browser-UI HTTPS and USB settings. USB FAT32 flash is always compiled;
the USB-key file manager (FAT32/NTFS/ext4) is extra. 64-bit SMT2 / multi-issue /
stream / OoO / hypervisor / RVV specs infer setup menus. HolyC kernel file
server emits generated HTML/JS/WASM over HTTP or HTTPS. HolyC-UI and browser-UI
share the menu tree. JS `fetch` and HolyC share one router. SvelteKit refused.
The OpenSBI ELF `jal`s `TimerInit` (SBI TIME + `rdtime`) before park and takes
supervisor timer irq 5 with the scause interrupt bit. Every hart sets `sp` and
`stvec` before the park split; stacks sit in BSS after the image. Display-proxy
geom is payload words; QEMU virt uses `-smp` + `virtio-gpu-device` (never `-netdev`).
`g6b smoke` runs the S-mode payload on the host (SBI putchar/TIME + UART0 THR)
until park. Hart 0 `wfi` takes irq 5 once (IRQ_TIMER). Secondary harts WFI after
`satp`/`sp`/`stvec` with no tick. Unexpected traps print `TRAP-<scause>-<sepc>`
and park (INT_FAULT), not an `sret` loop. `uncore.plic` runs `PlicInit` (S-mode
ctx1) and trap irq 9 claim/complete: UART irq 1 (`trap_uart` ns16550 RX) and
mbox irq 3. `harts>1` runs `HartStart` (SBI HSM + IPI); trap irq 1 (SSI) `sret`s.
`loopback.enable` runs `MboxInit` (`G6MB` + irq_en at `0x10100000`); trap irq 3
services doorbell kicks (`View` → ST_RSP, `Reboot` → SBI SRST). Dual-band UART1
sets `IER.ERBFI` and waits with `WFI` (not a busy poll, never a netdev). UART
RX appends `__uart_line`; a newline matches `View`/`Reboot`/`Shutdown`/`Wakeup`
(4-char prefix or first letter). `ViewSection("name")` prints `VIEW name`.
`GrInit` writes a `GR16` header at `__gr_plane` (after stacks), a 4bpp 640×480
plane with a boot scanline, and an 8×8 `G6LC` blit; QEMU still uses
`virtio-gpu-device` (never `-netdev`). `ProxyScale` runs when `kernel.proxy.gl`.
`UiInit` publishes a `G6UI` header at `__ui_blob`; the ELF carries
`bios-ui.wasm` in `.rodata`. UART/mbox `Ui` prints `UI`. `FileServe` echoes
`\0asm` and prints `/ui/` paths; UART/mbox `File` lists them. `GetFile` is GET
`/ui/ui.wasm` (mailbox RSP `\0asm`+size; not a netdev). `WasmJit` is the
`i32.add` leaf when `kernel.wasm.jit`.

QEMU `--loader bios` is hypothesis, never Variane evidence.

## Prime directives

1. **Rewrite, do not port.** Read `kernel-spec/ZealOS` (prefer) or
   `kernel-spec/TempleOS`, then write first-party MIT in `crates/**`. Do not
   compile, link, or copy x86/VGA/ring-0/oracle/`/Apps` from the forks.
2. **Conformity.** Every inference from the spec forks must agree with LibreCore:
   OpenSBI M-mode, this payload S-mode, BoardSpec parameterization, PMA/PMP,
   DTS UART/PLIC/SPI/timer map, no AI-island clash at `0x40000000`, firmware-boot
   principles. When ancestor and LibreCore conflict, **LibreCore wins**.
3. **KD0.** `cargo test --workspace` succeeds with only this tree + `fixtures/`.
   `kernel-spec/` is not a crate.
4. **Generated, never typed.** XLEN, RVV, UART base, hart count, mailbox base/IRQ
   come from BoardSpec.
5. **Display is HTML+JS in the kernel**, painted on the BIOS Gr/UART viewport.
   The other KVM face is SSH+HolyC (ZealC CLI), not a replacement.
6. **No Go goja *runtime*, no Chromium, no puppeteer bus.** `kernel-spec/goja`
   is a semantic spec (like TempleOS). Never `import` it, never `go build` it.
7. **OpenSBI stays M-mode.** This package is an S-mode payload.
8. **Post-boot access is parameterized.** After Linux, immutable sections stay
   viewable and write-disabled. The OS NIC may carry gateway/web/SSH only until
   `LinuxHandoff` (`until-delegate`); then the mailbox + PLIC IRQ (`/dev/g6lc-bios`)
   is the loopback — never a netdev.
9. **ASM IR, not string literals.** Generated RISC-V (`KStart.S`, `KInts.S`,
   `MemCpy.S`, ELF words) is lowered from `g6b-asm` after an analysis pass that
   names each object's purpose and architectural home. Do not add a second
   `format!(.s)` / `Vec<u32>` encoder. See `architecture/CODEGEN.md`.

## Daily commands

```
python tools/g6b.py check
python tools/g6b.py design-compile --spec fixtures/g6lc64-virt.json --out out
python tools/g6b.py boot --spec fixtures/g6lc64-virt.json
python tools/g6b.py qemu-args --spec fixtures/g6lc64-virt.json
python tools/g6b.py holyc-serve --spec fixtures/g6lc64-virt.json --port 2222 --once
python tools/g6b.py http-serve --spec fixtures/g6lc64-virt.json --port 0 --once
python tools/g6b.py loopback --spec fixtures/g6lc64-virt.json --port 0 --once
python tools/g6b.py elf --spec fixtures/g6lc64-virt.json --out out/g6lc_bios.elf
python tools/g6b.py smoke --spec fixtures/g6lc64-virt.json
python tools/g6b.py gr --spec fixtures/g6lc64-virt.json --out out/setup.ppm
python tools/g6b.py display-proxy --spec fixtures/g6lc64-virt.json --out out/proxy.ppm
python tools/g6b.py regress
```

Navigate: plan of record `architecture/PLAN.md`; keep/refuse map `architecture/ZEAL.md`;
codegen philosophy `architecture/CODEGEN.md`; display-proxy `architecture/DISPLAY.md`;
browser `architecture/BROWSER.md`; USB `architecture/USB.md`; menus
`architecture/MENUS.md`; file server `architecture/FILE-SERVER.md`; TLS
`architecture/TLS.md`; kernel HTTP `architecture/KERNEL-API.md`; spec checkouts
`kernel-spec/README.md`.
