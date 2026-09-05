# g6lc_bios — live todo

Green commands: `python tools/g6b.py check` (independence + Bun tests/build + fmt + clippy + workspace tests), then `python tools/g6b.py regress` (separate BIOS/transport regression).

| Stage | State |
|---|---|
| **B0** scaffold KD0 + schema + fixtures | landed |
| **B1** `g6b-design` Config.ZC / Connectors.ZC / linker | landed |
| **B2** DolDoc ToHtml | landed |
| **B3** UART HTML viewport + `g6q run --loader bios` wiring | landed |
| **B4** rewrite of Adam/KMain from TempleOS/ZealOS spec (`KMain.ZC`, `Adam.ZC`) | landed |
| **B5** fast HolyC init (`HOLYC-READY`) | landed |
| **B6** DOM+JS UI boot (`UI-BOOT`) | landed |
| **B7** HolyC dual-band UART + SSH-like TCP (QEMU `-serial tcp`) | landed |
| **B8** `bios-regress` (`tools/bios_regress.py`) | landed |
| **B8b** post-boot Linux access: immutable view-only, structural params, KVM power | landed |
| **B8c** sideband loopback (mbox+IRQ), NIC `until-delegate`, Linux misc stub | landed |
| **B8d** SSH+HolyC KVM face in addition to HTML+JS | landed |
| **B9** host-generated RV32/64 ELF (`g6b elf` → `out/g6lc_bios.elf`); `KStart64` rewrite | landed |
| **B9b** kernel-spec → RISC-V: `KStart.S` / `KInts.S` (no CR0/IDT/LAPIC) | landed |
| **B10** Gr / SysGrInit rewrite (`g6b-gr`, PPM, virtio-gpu argv) | landed |
| **B11** HolyC RISC-V ISel (`MemCpy.S`; RVV gated) + `g6b-asm` IR | landed |
| **B12** generated `/dev/g6lc-bios` miscdriver (fops, irq, probe; not a netdev) | landed |
| **B12b–B13** in-guest bind; optional real SSH | open |
| **B14** display-proxy + OpenGL-ES2 adapter (HDMI/DP 30/60/120) | landed |
| **B15** WebIDL live/stub BIOS browser (goja/lirx specs, not runtimes) | landed |
| **B16** HolyC HTTPS + SHA-256/AES-128 | landed |
| **B17** WASM-JIT + svelte-d UI catalog | landed |
| **B18** Botan-spec RSA/ECDSA/X.509 + adapter HTTPS/SSH ports | landed |
| **B19** Kernel HTTP/1.1+HTTP/2, JS↔HolyC endpoints, BIOS params, libwasm spec | landed |
| **B20** Profiles embedded→full; OpenWrt flash; settings ± USB key; HTTPS serve | landed |
| **B21** USB FAT32 flash always-on; USB-key FileMgr FAT32/NTFS/ext4; browser-UI notes | landed |
| **B22** 64-bit SMT2/multi-core/issue/stream/OoO/H/RVV topology; uncore menus; HolyC-UI ⊥ browser-UI | landed |
| **B23** HolyC kernel file server: HTML/JS/WASM over HTTP(S); TLS ServerHello; `http.files` | landed |
| **B24** RISC-V S-mode timer + trap dispatch (ASM IR); high-DPI/high-res proxy; QEMU virtio-gpu regress | landed |
| **B25** QEMU-runnable payload: `jal TimerInit` before park; scause interrupt-bit + `rdtime`; proxy_geom ELF words; boot log = `kstart_msg` | landed |
| **B26** Per-hart S-mode bring-up: stacks after payload; all harts `stvec` then hart≠0 WFI; ELF `p_memsz`; QEMU `-smp` | landed |
| **B27** Bare `satp`+`sfence.vma`; host S-mode ELF smoke (`g6b smoke`) | landed |
| **B28** UART0 ns16550 THR + SBI putchar; smoke secondary hart parks | landed |
| **B29** UART0 8N1 init; smoke IRQ_TIMER on `wfi` | landed |
| **B30** INT_FAULT: `TRAP-<scause>-<sepc>` then WFI; illegal-insn smoke | landed |
| **B31** S-mode PLIC `PlicInit` + SEI irq 9 claim/complete | landed |
| **B32** SBI HSM `hart_start` + IPI; trap SSI irq 1 | landed |
| **B33** `MboxInit` `G6MB` + irq_en at `loopback.base`; PLIC irq 3 | landed |
| **B34** `trap_mbox` View/Reboot/Shutdown/Wakeup doorbell kicks | landed |
| **B35** UART PLIC irq 1 RX (`trap_uart`); UART1 IER then WFI | landed |
| **B36** SysGrInit `GrInit` `GR16` header at `__gr_plane` | landed |
| **B37** 4bpp 640×480 plane + boot scanline (`KSTART-GR-PLANE`) | landed |
| **B38** 8×8 `G6LC` blit on the 4bpp plane (`KSTART-GR-FONT`) | landed |
| **B39** UART line buffer; newline View/Reboot/Shutdown/Wakeup | landed |
| **B40** UART 4-char prefixes `View`/`Rebo`/`Shut`/`Wake` | landed |
| **B41** `ViewSection("name")` quote walk → `VIEW name` | landed |
| **B42** `browser-ui` svelte-d → svelte-engine-ws → WASM; local libwasm g6b clone; `g6b-svelte` removed | landed |
| **B43** `g6b-ui` shared HolyC-UI ⊥ browser-UI (MENUS.md screens + settings/USB utilities) | landed |
| **B44** Kernel fetch paints `g6b-ui` DOM ids; `kernel.holyc` runs Menu*/Usb* via HolyC REPL | landed |
| **B45** Optional display-proxy GL accel `kernel.proxy.accel=off\|auto\|rvv\|ai-island` | landed |
| **B46** Guest `G6UI` blob + KStart `jal ProxyScale` / `UiInit`; ELF `p_memsz` +24 | landed |
| **B47** Embed `bios-ui.wasm` in ELF rodata; `jal WasmJit`; UART/mbox `Ui` command | landed |
| **B48** Guest `FileServe`: echo `\\0asm`, `/ui/` listing; UART/mbox `File` | landed |
| **B49** Guest `GetFile`: UART/mbox GET `/ui/ui.wasm`; RSP `\\0asm`+size | landed |
| **B50** Strict bounded JS AOT; Unicode/escape correctness; DOM attributes/selectors/local dirty tracking; non-destructive visibility; checked HTML and table-row painting | landed (host software; architecture limits apply) |
| **B51** Shared spec-derived menu rows, `kernel.browser.start_menu` and JS gates; host BrowserSession/Gr/proxy execution; native read-only browser navigation/WASM imports; bounded local HTTP framing | landed (host software; architecture limits apply) |
| **B52** Validated bounded i32 WASM control/locals/calls; fuel; RV32/RV64 numeric export lowering and differential machine-word tests | landed (host software; architecture limits apply) |
| **B53** Guest runtime JS/DOM integration, input/GPU scanout, executable JIT installation/trampolines/cache sync | host prerequisites advanced; guest gates open |
| **B54** Real persistent settings/flash backends and authenticated production TLS; remove canned mutation acknowledgements only with backend implementation | open |

B50–B52 verification (2026-09-05): `python tools/g6b.py check` passed
independence, 15 Bun tests/build, fmt, strict Clippy and 196 Rust tests;
`python tools/g6b.py regress` passed all 13 cases, including shared UI HTTP,
fragmented headers, idle preconnections, ELF smoke and framebuffer output.
Native WASM tests execute the emitted import/visibility ABI; numeric JIT tests
execute lowered RV32/RV64 machine words. Local HTTP page/app/menu endpoints
returned 200. Optional LDC wasm-eh execution was skipped; no RTL/silicon or
full guest-browser claim follows from these host results. MIT headers and
upstream reference boundaries were retained, with no external dependencies.

Priors: `architecture/PLAN.md` (rewrite-from-spec + conformity + current state),
`architecture/ZEAL.md`, `kernel-spec/`, host `g6lc_qemu` `--loader bios`.
