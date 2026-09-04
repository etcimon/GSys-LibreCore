# g6lc_bios — living plan

## 0. What this platform is

The BIOS **underlying platform is a rewrite**, not a port and not a vendor of
TempleOS or ZealOS. Those trees, checked out under [`../kernel-spec/`](../kernel-spec/),
are **specs**: they name services (Adam, HolyC, DolDoc, Gr, KStart, tasks) the
way `specs/riscv-spec.html` names ISA. First-party code in `crates/**` is MIT
and is generated or written against a BoardSpec. Nothing in `kernel-spec/` is
compiled, flisted, or linked.

Every inference drawn from TempleOS/ZealOS is **validated against the rest of
LibreCore architecture** before it becomes a BoardSpec field, a generated
`#define`, or an ELF byte. When the ancestor and LibreCore disagree, LibreCore
wins: RISC-V S-mode under OpenSBI, `CVA6Cfg` / BoardSpec parameterization,
PMA/PMP, PLIC, the CVA6/QEMU virt memory map, dual-hart SMT as `harts.count`,
AI-island exclusion at `0x40000000`, firmware-boot principles (not `bootrom.S`,
never Variane evidence). TempleOS ring-0-only x86 VGA is a spec of *intent*
(small kernel, Adam first task, HolyC CLI), not a layout to copy.

```
kernel-spec/TempleOS  ─┐
kernel-spec/ZealOS    ─┴─►  spec of services (read-only)
                              │  keep / rewrite / refuse  (ZEAL.md)
                              ▼
LibreCore architecture  ─►  validate inference
  AGENTS.md §0, firmware-boot-principles,
  DTS/PLIC/UART map, BoardSpec.check,
  g6lc_qemu virt vs soc, PMA/PMP
                              │
                              ▼
BoardSpec JSON  →  g6b-design / g6b-holyc / g6b-html / g6b-elf
                →  OpenSBI fw_dynamic -kernel g6lc_bios.elf
```

## 1. Current planning state (2026-09)

**Stage: B0–B49 landed.** Named BIOS profiles (`embedded`/`router` → `full`)
compile from UART+SPI flash up to browser-UI HTTPS + USB settings. USB FAT32
flash is always compiled; the USB-key file manager (FAT32/NTFS/ext4) is extra.
64-bit SMT2 / multi-core / multi-issue / stream / OoO / hypervisor / RVV
BoardSpecs infer setup menus; HolyC-UI and browser-UI share that tree.
HolyC kernel file server emits generated HTML/JS/WASM over HTTP or HTTPS
(`kernel.http.files`). OpenSBI next-stage ELF calls `TimerInit` (SBI TIME +
`rdtime`) before park, takes supervisor timer irq 5 with the scause interrupt
bit, and embeds display-proxy geom words. Every hart sets `sp`/`stvec` before
the park split; ELF `p_memsz` covers N stacks after the image. QEMU argv
includes `-smp` from BoardSpec (never `-netdev`). Host S-mode smoke (`g6b smoke`)
executes the ELF until park/UART and prints the boot log (QEMU stand-in, never
Variane). Boot log is UART0 ns16550 THR plus SBI putchar so QEMU `-nographic`
shows it. Host smoke takes supervisor timer irq 5 on `wfi` (SIE+STIE) and
`sret`s. Unexpected traps dump `TRAP-<scause>-<sepc>` over SBI and WFI (INT_FAULT
rewrite). S-mode PLIC (QEMU virt `0x0c000000` ctx1) enables UART/mbox and
claims/completes SEI. Hart 0 `HartStart` uses SBI HSM+IPI for extra harts; SSI
(irq 1) wakes `wfi`. `MboxInit` writes `G6MB` + irq_en at `loopback.base`
(default `0x10100000`); trap irq 3 services doorbell kicks (`View` → ST_RSP,
`Reboot`/`Shutdown` → SBI SRST). UART RX is PLIC irq 1 (`trap_uart` drains
ns16550 RBR into `__uart_line`; newline matches `View`/`Rebo`/`Shut`/`Wake` or
the first-letter shortcuts; `ViewSection("name")` prints `VIEW name`). Dual-band
UART1 enables `IER.ERBFI` and parks with `WFI` (not a busy poll). `GrInit` writes a `GR16` ident + geom header at `__gr_plane` after
the hart stacks, paints a 4bpp boot scanline, and blits 8×8 `G6LC` at (0,8)
(same font bits as `g6b-gr`; not VGA). QEMU virtio-gpu / host PPM scan that
plane out. When `kernel.proxy.gl`, KStart `jal ProxyScale` (scalar, or RVV /
ai-island when `proxy.accel` says so). When WASM or HTTP files are live,
`UiInit` writes a `G6UI` header at `__ui_blob` and the ELF carries
`bios-ui.wasm` in `.rodata` (`__ui_wasm`); UART/mbox `Ui` prints `UI`.
`FileServe` echoes `\0asm` at G6UI+24, publishes nfiles, and prints the `/ui/`
paths (HolyC `FileServe("/ui")` rewrite). UART/mbox `File` / `F` lists them.
`GetFile` is the HTTP GET of `/ui/ui.wasm`: UART prints `GET /ui/ui.wasm`
(and `HTTP/1.1 200` when `kernel.http` is on); mailbox kick `G` returns
`\0asm` + size in the RSP (not a netdev).
Green command: `python tools/g6b.py check`.

| Layer | State |
|---|---|
| Spec forks | `kernel-spec/ZealOS`, `TempleOS`, `goja`, `lirx-dom`, `webidl/`, `svelte-d`, `botan`, `libwasm` (WASM druntime / fetch). Not Cargo members. |
| Rewrite surface | BoardSpec → generated `KMain.ZC` / `Adam.ZC` / `PostBoot.ZC` / `Loopback.ZC`; host HolyC subset; HTML+JS viewport; SSH+HolyC KVM face |
| Payload | `g6b elf` RV32/64 ET_EXEC: KStart rewrite (`tp`=hartid, `sp`, `stvec`, hart0 KMain, others WFI). Map: `KERNEL-RV.md` |
| QEMU | `g6q --loader bios` + UART1 `-serial tcp:127.0.0.1:2222`. No `-netdev`. Hypothesis only |
| Post-boot | `until-delegate` NIC then `LOOPBACK-MBOX` + PLIC IRQ 3 @ `0x10100000` → `/dev/g6lc-bios`. Immutable view-only; Reboot/Shutdown/Wakeup |
| Gr / proxy | `g6b-gr` 640×480×16 plane + display-proxy `fit`/`fill`/`dpi` to HDMI/DP / host-GL (30/60/120 fps, high DPI, up to 8K). OpenGL-ES2 listing. Docs: `DISPLAY.md` |
| Browser | `g6b-webidl` + `browser-ui` (svelte-d NodeDef + **FileMgr**, **not SvelteKit**) + `g6b-wasm` JIT on the g6b kernel. Fetch is live via kernel HTTP. `BROWSER.md` `USB.md` `WASM.md` `KERNEL-API.md` |
| TLS | `g6b-tls` SHA-256, AES-128, HMAC, RSA PKCS#1, ECDSA P-256, X.509; ClientHello rsa+ecdsa. Botan spec, not linked. `TLS.md` |
| HTTP / endpoints | `g6b-http` HTTP/1.1 + HTTP/2+HPACK; HolyC/JS register the same router; `/bios/{clocks,edk2,u-boot,bootloader,flash,update,settings,usb,files}` |
| File server | generated `/ui/index.html` `/ui/app.js` `/ui/ui.wasm`; HolyC `FileServe` / `HttpsServe`; TLS ServerHello. `FILE-SERVER.md` |
| USB | FAT32 flash always (`/bios/usb/ls`, `UsbFlash`); key FileMgr FAT32/NTFS/ext4 when `kernel.usb.key`. `g6b-fs` canned listings. `USB.md` |
| Profiles | `embedded` / `router` / `appliance` / `desktop` / `full` — compiled feature bundle; JSON overlay wins. `KERNEL-API.md` |
| Topology / uncore | `harts.cores×threads`, `core.{issue,ooo,stream}`, `extensions.h`/`v`; uncore CLINT/PLIC/DDR/PCIe/ETH/storage/HDMI inferred. `MENUS.md` |
| UIs | HolyC-UI (`HolycUi.ZC` `MenuCpu`) ⊥ browser-UI (svelte-d `Menu` + `fetch /bios/menu`). Same JSON. |
| Adapter ports | `net_expose.bios_https_port=443`, `ssh_holyc_port=2222` until `NET-DELEGATE`; then mailbox |
| ISel / codegen | `g6b-asm`: analyze BoardSpec objects → purpose-tagged IR → `.S` and ELF words. Timer = SBI TIME + `sie`/`sstatus`. Display-proxy geom in IR. Marker `ISEL-SCALAR` / `ISEL-RVV`. Philosophy: `CODEGEN.md` |
| Mailbox driver | Payload `MboxInit` + `trap_mbox` (View/Reboot). Generated `linux/g6lc_bios_mbox.c`: miscdevice + fops + PLIC irq + probe. Not a netdev. APU MMIO remains a REQUIREMENTS ask |
| Not yet | in-guest bind of that `.ko`, OpenSSH |

Conformity so far is **BoardSpec legality + `inferred_arch()` + bios-regress**.
RTL mailbox / DTS merge into `corev_apu` is an inference recorded in
`REQUIREMENTS.md`, not an in-tree core edit from this package.

## 2. Priority

| Stage | Intent | State |
|---|---|---|
| **B0–B8d** | Scaffold through dual-band, post-boot params, mbox loopback, SSH+HolyC face | landed |
| **B9** | Host-generated RV32/64 ELF as OpenSBI next stage (`KStart64` rewrite) | landed |
| **B9b** | Kernel-spec → RISC-V migration of KStart / KInts / Task (not x86) | landed |
| **B10** | Gr framebuffer when `G6LC_GR` (spec: `System/Gr`; UART cells or virtio-gpu PPM) | landed |
| **B11** | HolyC RISC-V ISel (RVV only if `extensions.v=live` ∧ xlen=64) + ASM IR (`g6b-asm`) | landed |
| **B12** | E-L Linux: NIC delegated, generated `/dev/g6lc-bios` miscdriver (fops/irq/probe); APU MMIO still a REQUIREMENTS ask | landed |
| **B12b** | In-guest bind of that driver on a live Linux (QEMU hypothesis, never Variane) | open |
| **B13** | Real SSH ident/kex on the HolyC backend (optional); still not a netdev after delegate | open |
| **B14** | Display-proxy (low-res ZealOS → high-res HDMI/DP / host-GL, 30/60/120 fps) + OpenGL-ES2 adapter | landed |
| **B15** | Lightweight BIOS browser: WebIDL live/stub, goja+lirx specs, DOM status on the GL plane | landed |
| **B16** | HolyC HTTPS + RISC-V SHA-256/AES-128 primitives | landed |
| **B17** | WASM-JIT + svelte-d UI (NodeDef live; `{#await}` stub; no LDC/Binaryen) | landed |
| **B18** | Botan-spec TLS: RSA/ECDSA/X.509 + RISC-V crypto IR; BIOS HTTPS / SSH+HolyC adapter ports | landed |
| **B19** | Kernel HTTP/1.1+HTTP/2; JS↔HolyC endpoints; BIOS clocks/edk2/u-boot params; libwasm spec; SvelteKit refused | landed |
| **B20** | Build profiles embedded→full; OpenWrt/self flash; settings import/export ± USB key; HTTPS serve | landed |
| **B21** | USB FAT32 flash always-on; USB-key FileMgr FAT32/NTFS/ext4; svelte-d FileMgr; browser-UI notes | landed |
| **B22** | 64-bit SMT2/multi-core/issue/stream/OoO/H/RVV topology; uncore menus; HolyC-UI ⊥ browser-UI | landed |
| **B23** | HolyC kernel file server: HTML/JS/WASM over HTTP(S); TLS ServerHello; BoardSpec `http.files` | landed |
| **B24** | RISC-V S-mode timer + trap dispatch in ASM IR; high-DPI/high-res proxy (`fit`/`fill`/`dpi`); QEMU virtio-gpu + proxy PPM regress | landed |
| **B25** | QEMU-runnable payload: `jal TimerInit` before park; scause interrupt-bit + `rdtime`; proxy_geom words in ELF; boot log = `kstart_msg` | landed |
| **B26** | Per-hart S-mode bring-up: stacks after payload; all harts `stvec` then hart≠0 WFI; ELF `p_memsz`; QEMU `-smp` | landed |
| **B27** | Bare `satp`+`sfence.vma`; host S-mode ELF smoke (`g6b smoke`) prints boot log via SBI putchar | landed |
| **B28** | UART0 ns16550 THR + SBI putchar; smoke secondary hart parks; QEMU `-nographic` console | landed |
| **B29** | UART0 8N1 init; smoke IRQ_TIMER on `wfi` (scause irq 5 → SBI TIME → `sret`) | landed |
| **B30** | INT_FAULT rewrite: `TRAP-<scause>-<sepc>` then WFI (no sret loop); illegal-insn smoke | landed |
| **B31** | S-mode PLIC: `PlicInit` + SEI irq 9 claim/complete (UART/mbox); not LAPIC EOI | landed |
| **B32** | SBI HSM `hart_start` + IPI; trap SSI irq 1 wakes `wfi` (MultiProc rewrite) | landed |
| **B33** | `MboxInit` writes `G6MB` + irq_en at `loopback.base`; PLIC irq 3 (not a netdev) | landed |
| **B34** | `trap_mbox` doorbell kick: View → ST_RSP/`VIEW`; Reboot/Shutdown → SBI SRST | landed |
| **B35** | UART PLIC irq 1 RX: `IER.ERBFI` + `trap_uart` drain; UART1 irq-driven WFI (not a poll) | landed |
| **B36** | SysGrInit in payload: `GrInit` `GR16` header at `__gr_plane` after stacks; ELF `p_memsz` | landed |
| **B37** | 4bpp 640×480 plane in BSS; `GrInit` paints scanline 0 (colour 1); `KSTART-GR-PLANE` | landed |
| **B38** | 8×8 `G6LC` blit on the 4bpp plane (same font bits as `g6b-gr`; not VGA) | landed |
| **B39** | UART line buffer: irq RX append; newline V/R/S/W (View/Reboot shared with mbox) | landed |
| **B40** | UART 4-char HolyC prefixes (`View`/`Rebo`/`Shut`/`Wake`); single-letter fallback | landed |
| **B41** | `ViewSection("name")` quote walk → `VIEW name` (HolyC REPL rewrite) | landed |
| **B42** | `browser-ui` svelte-d → WASM; local libwasm g6b clone; `g6b-svelte` removed | landed |
| **B43** | `g6b-ui` shared HolyC-UI ⊥ browser-UI (MENUS.md) | landed |
| **B44** | Kernel fetch paints `g6b-ui` DOM ids; `kernel.holyc` REPL | landed |
| **B45** | Optional display-proxy GL accel `off`/`auto`/`rvv`/`ai-island` | landed |
| **B46** | Guest `G6UI` blob; KStart `jal ProxyScale` / `UiInit` | landed |
| **B47** | Embed `bios-ui.wasm` in ELF; `jal WasmJit`; UART/mbox `Ui` | landed |
| **B48** | Guest `FileServe`: `\0asm` echo + `/ui/` listing; UART/mbox `File` | landed |
| **B49** | Guest `GetFile`: GET `/ui/ui.wasm`; mailbox RSP magic+size | landed |

Kernel-spec RISC-V map: [`KERNEL-RV.md`](KERNEL-RV.md). Generated `zeal/KStart.S`
and `zeal/KInts.S` match `g6b-elf` because both lower `g6b-asm` IR
([`CODEGEN.md`](CODEGEN.md)).

## 3. Conformity — how an inference is allowed

Before a TempleOS/ZealOS service becomes code, it must pass this gate. Failures
are BoardSpec `check()` errors or `REQUIREMENTS.md` asks, never silent defaults.

| Ancestor claim | LibreCore check |
|---|---|
| Ring-0-only kernel | **Rewrite:** S-mode payload; OpenSBI stays M-mode (`AGENTS.md` BIOS directive 5) |
| x86 `KStart16/32/64` | `KERNEL-RV.md`: `tp`=hartid, `sp`, `stvec`; load `dram_base+text_offset`. No CR0/EFER |
| VGA 640×480×16 | `kernel.gr` BoardSpec; UART until `G6LC_GR`; virtio-gpu only on `g6lc-virt` |
| Multicore tasks | `harts.count`; `postboot.enable=mgmt-hart` needs ≥ 2; SMT topology is SoC, not Adam |
| HolyC JIT / compiler | `g6b-holyc` subset + `g6b-asm` ISel; no x86 backend copy |
| DolDoc / Adam first task | generated `Adam.ZC`; display is HTML+JS + SSH+HolyC, not a host browser |
| Direct hardware ports | Connectors from BoardSpec (`sbi`, `uart`, `mbox`); no typed `0x3F8` |
| Memory map | UART `0x10000000` irq 1, SPI `0x20000000` irq 2, timer `0x18000000`, mailbox **`0x10100000` irq 3** — must not collide with AI island `0x40000000` or virtio-mmio |
| Networking | TempleOS has none. ZealOS `Home/Net` is **not** the OS NIC after Linux. `net_expose=until-delegate` then mbox |
| `/Apps`, oracle, God | **Refuse** (`ZEAL.md`) |
| RVV / wide copies | Only if BoardSpec `extensions.v=live` and `xlen=64` |

`BoardSpec::inferred_arch()` is the written form of this gate. A new service
that would need a clock, reset, or AXI slave is an architecture ask (core/APU),
not a silent `#define`.

## 4. Two KVM faces (not one)

Server-KVM shape is **two backends on the same management instantiation**:

| Face | Spec ancestor | Transport |
|---|---|---|
| **HTML+JS** | DolDoc ToHtml + setup viewport | UART/Gr before boot; mailbox `ViewSection` after delegate |
| **SSH+HolyC** | ZealC CLI / Adam command line | `holyc-repl` on port 2222 *before* delegate; `/dev/g6lc-bios` *after* |

`postboot.backends` lists them (`html-js`, `ssh-holyc`). Access `kvm` means both
unless the spec drops one. HTML+JS is not replaced by SSH.

## 5. NIC until delegate, then sideband

Windows MEI/HECI and IPMI BT, and macOS SMC, split the same way: optional
shared MAC until the OS driver binds, then a mailbox + IRQ that is **not** a
netdev. TempleOS has no NIC; that absence is the spec. The adapter is a
LibreCore *optional* pre-delegate face, not a ZealOS copy.

| Phase | Who owns the adapter | BIOS exposure |
|---|---|---|
| Pre-boot / pre-delegate | BIOS (`net_expose=until-delegate`) | Optional gateway/web **and** SSH+HolyC |
| `LinuxHandoff` | **Delegated** to Linux | `NET-DELEGATE` |
| Post-boot | Linux only | `LOOPBACK-MBOX` @ `0x10100000` irq 3 → `/dev/g6lc-bios` |

`net_expose=always` is legal **only** with `postboot.enable=bmc-island`.
QEMU BIOS argv never includes `-netdev` / `virtio-net`.

## 6. BoardSpec fields (customisation surface)

| Field | Meaning |
|---|---|
| `net_expose.mode` | `never` \| `until-delegate` \| `always` (bmc-island only) |
| `net_expose.web` / `ssh_holyc` | pre-delegate adapter faces |
| `net_expose.bios_https_port` | BIOS HTTPS on the adapter (default 443) until `NET-DELEGATE` |
| `net_expose.ssh_holyc_port` | SSH+HolyC on the adapter (default 2222) until `NET-DELEGATE` |
| `kernel.tls.{enable,https,rsa,ecdsa,certificates}` | Botan-shaped web TLS; first-party rewrite, not linked |
| `kernel.http.{enable,http1,http2,proxy_js}` | compiled HTTP stack + JS fetch proxy |
| `kernel.params.{clocks,edk2,uboot,bootloader}` | BIOS JSON endpoints |
| `kernel.ui` | `html-js` \| `svelte-d` (**not** `sveltekit`) |
| `profile` | `embedded` \| `router` \| `appliance` \| `desktop` \| `full` |
| `kernel.flash.{enable,openwrt,self_update,backend,image}` | SPI/mailbox/USB image flash |
| `kernel.settings.{export,import,uart,mailbox,usb_key}` | settings blob ± USB key |
| `kernel.usb.{enable,flash_fat32,key,fs_fat32,fs_ntfs,fs_ext4}` | USB host: FAT32 flash always; key FileMgr extra |
| `kernel.proxy.scale_mode` | `fit` / `fill` / `dpi` blit of the 640×480 plane onto high-res |
| `harts.{count,cores,threads}` | logical harts = cores × threads (SMT2 = 1×2) |
| `core.{issue_ports,ooo,stream}` | multi-issue / OoO / stream plane |
| `isa.extensions.h` | hypervisor; BIOS stays S-mode |
| `uncore.{clint,plic,ddr,pcie,ethernet,storage,hdmi}` | setup probes + HolyC connectors |

| `kernel.http.files.{enable,html,js,wasm,https,root}` | kernel file server for generated UI files |
| `kernel.tls.serve` | TLS 1.2 ServerHello for HTTPS file serve |
| `kernel.http.serve` | BIOS HTTP(S) serve on adapter until delegate |
| `loopback.enable` | post-delegate mbox (default on when `postboot.enable≠never`) |
| `loopback.{base,irq,chardev}` | MMIO + PLIC + `/dev/g6lc-bios` |
| `postboot.backends` | `html-js` and/or `ssh-holyc` |

## 7. Refused

Copying x86/VGA/ring-0 TempleOS into the payload; compiling `kernel-spec/`
(including Botan D, svelte-d, goja, lirx-dom, libwasm); Go goja runtime; Chromium;
SvelteKit as BIOS UI; puppeteer; linking Botan/OpenSSL; RVV when `v` is not `live`; linking QEMU/OpenSBI
into `g6lc_bios`; treating QEMU as Variane evidence; a BIOS **netdev** after
Linux owns eth/wifi; replacing HTML+JS with SSH (both stay); a Linux VFS or
on-disk NTFS/ext4 decoder in the BIOS (`g6b-fs` is canned listings). QEMU BIOS
argv never grows `-netdev`.
