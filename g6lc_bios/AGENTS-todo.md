# g6lc_bios — live todo

Green commands: `python tools/g6b.py check` (independence + Bun tests/build + fmt + clippy + workspace tests), then `python tools/g6b.py regress` (separate BIOS/transport regression).

Web-engine endpoint (one BrowserSession, one LDC cell, remaining B86–B91):
[`architecture/plan-endpoint.md`](architecture/plan-endpoint.md). Work tree
**`E:\cva6/g6lc_bios`**.

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
| **B53** Guest runtime JS/DOM integration, input/GPU scanout, executable JIT installation/trampolines/cache sync | host prerequisites advanced; bounded guest `_start`→`__ui_dom`→`DomPaint` lane + `Ui` re-dump + executed-plane PPM + `VioProbe`/`VioInit`/`VioScan` virtio-gpu path **verified on real QEMU 8.2 + OpenSBI 1.5** (`fixtures/g6lc64-qemu.json`, QMP screendump shows the guest-painted band **and the 1920×1080 high-res proxy scanout** — `FbExpand` scale-blit, centered `to_ppm` geometry); uncore `display`-engine seam (`DispPaint` + `G6FB` simplefb handoff, `fixtures/g6lc64-hdmi.json`, exec-modelled) + `qemu-args` `--vnc`/`--no-gl`/`virtio-gpu-gl-device` under `proxy.gl` landed; **virtio-input eventq (`InpInit`/`InpDrain`/`InpPoll` + `virtio-keyboard-device` argv) and WFI-driven ctrlq/eventq waits landed (exec-model verified)**; **absent-device tolerance for stock QEMU virt landed** (`trap_fault` recoverable probe windows for UART1/mbox — `g6lc64-virt.json` boots stock `virt`); runtime gates open |
| **B54** Real persistent settings/flash backends and authenticated production TLS; remove canned mutation acknowledgements only with backend implementation | open |
| **B55** Mutable per-run WASM memory (load/store/size/grow) + extended i32 lowering (bitwise/shifts/rotates/ordering) via `g6b-asm` | landed (host; RV32/RV64 differential machine-word tests) |
| **B56** Bounded nonblocking JS async: `await` fetch tokens, throw/catch, cancellation, stale/duplicate rejection, per-task/tick budgets | landed (host) |
| **B57** Transactional DOM (`DomTransaction` + native-browser DOM-kernel host); explicit libwasm ABI mount with startup verification | landed (host) |
| **B58** Cooperative RV32/RV64 task-switch IR, bounded scheduler/task services, DedicatedWorker compute protocol shared by browser/HolyC menus | landed (host IR + services; guest dispatch open) |
| **B59** LDC 1.43 + vendored `runtime-v1.43.0` libwasm cell: DUB workspace, provenance/ABI/startup-gated publication, Asyncify build path with custom binaryen, D particle exports + WebGL backdrop | landed (component-shell artifact; libwasm await status/object-string ABI, `g6b-wasm` dispatch and JS host `createLibwasmHost` landed; D `catch` rejection->wasm-EH throw and full Svelte tree still open) |
| **B59b** pinned LDC toolchain: `browser-ui/toolchains/ldc.lock.json` (upstream `v1.43.0-beta1`, per-host SHA-256), `scripts/install-ldc.ts` verify-then-extract installer, pin-first discovery in `compiler/ldc.ts` | landed (host; replaces ambient `1.43.0-git` discovery — see below) |
| **B82** Cut misleading UI lanes: svelte-d requires the LDC cell; live DOM is the raster; guest `WasmStart` is VGA glyphs only | landed (host) |
| **B83** `fetch` / `<img src>` through `/ui` files; GLES2 `u_dom` = CSS Canvas32 | landed (host) |
| **B84** libwasm types on the UI-thread Host, not the kernel; `KernelPort`; goosie `:hover` | landed (host) |
| **B85** Interactive UI: browser loads the LDC cell as `WasmUi`; tick/present_gl; live tab classList | landed (host docs + persistent instance) |
| **B86** Persistent `instance.call` without KernelHost reconstruct; event object coords / preventDefault; LDC `getRoot` host import | landed (host; shipped cell still inlines `getRoot()=1` until `G6B_DUB_WASM=1`) |
| **B87** Cell-owned tab/refresh/JSON: `on:click` → `g6b_listen`; host `Listener::Cell` preventDefault + fetch/select; Rust `select_menu` is default action only | landed (host; D emit ready, shipped cell uses host bind until `G6B_DUB_WASM=1`) |
| **B88** Live CSS `Engine::paint(&Node)`; DirtyFlag Style/Layout/Paint; goldens per tab + hover (no HTML round-trip) | landed (host; 4bpp `ui_ppm` still HTML; dirty tiles B90) |
| **B89** UI-thread `Role::Ui` / `ui_hart` runs `tick`; timer heap; fps 100/144; B66 timers implemented or ABI-verifier refused | landed (host) |
| **B90** Dirty-tile GLES2 + virtio-gpu TRANSFER/FLUSH; QMP tab screendumps vs `ui_ppm32` goldens; host blit of Canvas32 into modelled `__scan_fb` | landed (host; QMP tab shots remain `qemu_tab_shots.sh` / remote g6q) |
| **B91** Guest libwasm instance: same Host + compact DOM + dirty paint in S-mode. Do not grow `start_ops` to `Object_Call` | compact persist + dirty-tile `VioPaint` landed; **B91b** exec-model `guest_cell_scanout` / `smoke_cell` (same Host import set) **landed** |
| **S0** `g6b-pglite` submodule + npm pin; UUID store-instance architecture | landed (PR1; no crate yet). Identity: [`architecture/g6b-store-instances.md`](architecture/g6b-store-instances.md) |

B53 guest-DOM increment (2026-09): `g6b-asm` gained `Purpose::UiDom`,
`Addr::{WasmData,UiFont,UiDom}`, `Module.{wasm_data,font,dom_bytes}`, the
first-party 8x8 font (`font.rs`) and the guest DOM service (`dom.rs`:
`WasmUi`, `WasmStart` anchor, `WasmDomFind`/`WasmDomText`/`WasmDomVisible`,
`WasmFetch`/`WasmLog`, `DomPaint` with `DOM| ` serial + 4bpp `__gr_plane`
glyphs). `g6b-wasm::jit::start_ops` lowers the straight-line wasm `_start`
(`i32.const` + `env` import calls, fail-closed) onto the `WasmStart` anchor;
`jit::data_image` supplies `__wasm_data` (≤16 KiB `.rodata`). `g6b-elf`
merges both into one `payload_module` shared by ELF packing and host smoke;
`exec` covers `__ui_dom` BSS and captures `smoke.dom_rows`/`dom_pix0`.
`python tools/g6b.py check` green (independence, Bun tests/build, fmt,
clippy, workspace tests, 13/13 bios-regress incl. `elf_smoke`); new tests:
`start_ops` guest-IR execution on both XLENs (`DOM| UI-BOOT`, `dom_rows=1`),
fail-closed cases, `wasm_jit_smoke_runs_dom_imports` (gr paint),
`wasm_jit_smoke_serial_only_without_gr`. `g6b smoke` on `g6lc64-virt.json`
prints `DOM| ` menu text and `GET /bios/...` lines. This is a bounded
boot-time render lane — not guest JS execution, not arbitrary wasm, and not
virtio-gpu scanout evidence.

B53 follow-on (2026-09): `Purpose::Virtio` + `VioProbe` — bounded read-only
virtio-mmio slot scan (`0x10001000+0x200*i`, MagicValue `virt`, DeviceID 16)
printing `VIRTIO-GPU <slot>` / `VIRTIO-GPU-NONE`; gated by the new shared
`BoardSpec::wants_virtio_gpu` (same predicate emits `virtio-gpu-device` in
QEMU argv). Host exec models the slot-0 device (`run_module_no_gpu` covers
the absent path). Collision fix: modeled UART1 base moves `0x10001000` →
`0x10002000` when the GPU is attached (QEMU virt has no second ns16550; the
window is virtio-mmio). UART `Ui` now re-dumps the live DOM (`jal DomPaint`).
`exec::Smoke::gr_frame` + `g6b smoke --out f.ppm` export the executed
`__gr_plane` (GR16+4bpp) as PPM via `g6b-gr::plane_to_ppm`. Still open:
virtqueue setup, `RESOURCE_*`/`SET_SCANOUT`/`TRANSFER_TO_HOST_2D`/`FLUSH`,
input delivery, guest JS/runtime gates.

B53 follow-on 2 (2026-09): `VioInit` (`g6b-asm::vio`) — virtio 1.x handshake
(reset, ACK|DRIVER, `VIRTIO_F_VERSION_1`, FEATURES_OK readback, DRIVER_OK),
controlq setup (desc/avail/used in `__vio` BSS, `Op::Fence` before avail-idx
and notify), and one real `GET_DISPLAY_INFO` descriptor-chain round-trip
verified by `VIRTIO-INFO` (resp `0x1101`) vs `VIRTIO-GPU-FAIL`. The exec
virtio-mmio model now implements the register file (status/features/queue/
ISR/notify), walks chains out of guest RAM, writes the display-info response
+ used elems, and latches `vio_status`/`vio_last_cmd`/`vio_last_resp` into
`Smoke`. `smoke` on `g6lc64-virt.json` prints `VIRTIO-GPU 0` → `VIRTIO-GPU-OK`
→ `VIRTIO-INFO`.

B53 follow-on 3 (2026-09): `VioCmd` + `VioScan` (`g6b-asm::vio`) — the
submit-one virtqueue routine (desc0 OUT req / desc1 WRITE resp, avail
publish, `fence`, `QueueNotify`, bounded used poll, resp type in a0) drives
the full pixel sequence: `RESOURCE_CREATE_2D` → `RESOURCE_ATTACH_BACKING`
→ `SET_SCANOUT` → guest green-band fill of `__scan_fb` →
`TRANSFER_TO_HOST_2D` → `RESOURCE_FLUSH` → `VIRTIO-SCAN`. The exec model
tracks resources, bounds-checks the backing attach against `__scan_fb`,
latches the scanout rectangle, copies backing→device surface on transfer
and counts flushes (`Smoke::vio_scanout`/`vio_flushes`/`vio_fb*`);
`g6b smoke --out-vio f.ppm` exports the device surface
(`g6b-gr::x8r8_to_ppm`, `g6b_kernel::scanout_ppm`). `smoke` now ends
`vio=0xf/0x104/0x1100 scanout=true flushes=1`. Two defects fixed en route:
`slli/srli 16` on rv64 masks 48 bits, not 16, so avail-flags "preservation"
re-published a stale idx (avail jumped 1→3, replayed the CREATE chain);
and bare `sw(x0,t2,off);` statements in `scan_node` silently dropped the
rect/offset stores. Also corrected `RESP_OK_DISPLAY_INFO` = 0x1101 (was
0x1100 = `RESP_OK_NODATA`) and the 408-byte display-info response size,
and moved `VIO_REQ_OFF` 0x100→0x120 — the 8-entry used ring needs 72B from
0xC0, so ring index 7's `len` would have clobbered the request area on
wrap. Interrupt lane: the device now counts InterruptStatus bit-0
assertions (`Smoke::vio_irqs`, 6 per boot) and both completion paths read
InterruptStatus (0x60) and write it back to InterruptACK (0x64). Still
open: eventq/input, real PLIC irq delivery (the used-ring poll is bounded
but busy), QEMU-visible pixels — the modeled surface is host-side
protocol evidence only.

B55–B59 verification (2026-09): `python tools/g6b.py check` passed
independence, 42 Bun tests across 3 files (0 fail) including the actual LDC
cell startup against the explicit DOM ABI and an isolated LDC-compiled
particle-D run, `bun run build` emitting `out/bios-ui.wasm` plus a verified
fresh LDC component-shell artifact, fmt, strict Clippy and 276 Rust tests
(1 ignored: Node-native WebAssembly differential memory case). Asyncify /
`wasm-opt` is absent on this host and fails closed: requesting it or compiling
await-bearing Svelte sources returns status 3 and never ships an artifact.
`bios-regress` passed all 13 cases. No RTL/silicon, guest JIT, or full
guest-browser claim follows from these host results. MIT headers and upstream
reference boundaries were retained; the LDC runtime carry is vendored with its
upstream notices intact.

B53 follow-on 4 (2026-09) — **real QEMU execution**: the `g6lc_qemu`-built
OpenSBI 1.5 `fw_dynamic` + QEMU 8.2 `virt` booted `out/g6lc_bios-qemu.elf`
built from the new **stock-virt-faithful** `fixtures/g6lc64-qemu.json`
(`loopback` off — the mbox `0x10100000` is QEMU `fw_cfg`; `dual_band.tcp`
off — no second ns16550; `postboot`/`net_expose` never). Serial shows
`VIRTIO-GPU 7` → `VIRTIO-GPU-OK` → `VIRTIO-INFO` → `VIRTIO-SCAN` and a QMP
`screendump` PPM shows the guest-painted 64-row green band — real
guest→virtio-gpu→scanout evidence. Three QEMU-virt realities fixed en route:
(1) all 8 virtio-mmio transports always exist at `0x10001000+0x1000*i`
(0x200 regions, 0xE00 gaps fault) — `VIO_MMIO_STEP` was 0x200 and silently
truncated through the un-checked `addi` immediate to a zero step (all I/S
encoders now range-assert via `check_imm12`), and `-device` lands on the
last free bus (slot 7); (2) the transports default `force-legacy=1`
(Version=1), which ignores the v2 QueueDesc/Avail/Used/Ready registers —
`qemu-args` now emits `-global virtio-mmio.force-legacy=false`; (3) QEMU
services QueueNotify on an iothread, so `VIO_POLL_MAX` is `1<<22`, not a
few thousand iterations. The modeled UART1 moved to `uart0+0x9000` (above
the window) and `trap_uart`'s UART1 drain is emitted only when
`dual_band.tcp` — both were unmapped-MMIO reads on stock virt.

B53 follow-on 5 (2026-09): `VioPaint` (`g6b-asm::vio`) closes the
DOM→scanout lane on QEMU: palette-expand `__gr_plane` (4bpp, hi-nibble even)
into `__scan_fb` (X8R8G8B8) through the inline `vio_pal` table (same values as
`g6b-gr::PALETTE`), then full-frame `TRANSFER_TO_HOST_2D` + `RESOURCE_FLUSH`
via `VioCmd`. Boot order: `VioPaint` is `jal`ed after `WasmUi` (the last
`__gr_plane` painter) and re-runs on the `trap_uart` `Ui` path so the UART
`Ui` refresh also updates the QEMU scanout. It saves ra + t3..t6 itself —
the trap frame only covers t0..t2/a0..a2/a6/a7. **Verified**: QEMU
`screendump` after `VIRTIO-PAINT` shows the DOM/Gr plane (glyph pixels +
boot scanline) on the virtio-gpu console with a histogram identical to the
host-modelled `vio_fb`; `smoke` now reports `flushes=1+paints`,
`irqs=6+2*paints` and the test asserts the whole `vio_fb` equals the
expanded `gr_frame`. Host `STEP_LIMIT` raised 2M→12M for the real
w*h/2-iteration expand loop.

B53 follow-on 6 (2026-09): **PLIC irq completion verified on QEMU.** The
machine DTB (`qemu -M virt,dumpdtb`) gives virtio-mmio slot i → PLIC irq
`1+i` (GPU slot 7 → irq 8) and UART0 → irq 10 — the guest's `UART_IRQ`
was model-only 1 and would have matched the wrong source. `PlicInit` now
writes nonzero source priorities for every enabled irq (QEMU PLIC priority
resets to 0 → a 0-priority source never asserts), enables irqs 1..=8 +
UART(10) + mbox, and `trap_sei` resolves a claimed virtio irq from
`__vio+VIO_DEV_OFF` (`irq = 1 + (dev-0x10001000)/0x1000`) → `trap_vio`
reads InterruptStatus, writes InterruptACK (clears the device level — no
storm), and bumps `__vio+VIO_IRQF_OFF`. `VioInit` stores `dev_off` at
`vi2_dev` (before the first notify). QEMU `xp` shows `irqf == 8` after boot
— exactly the 6 scan + 2 paint completions — so used-buffer interrupts are
claimed through the real PLIC; `VioCmd` still polls `used.idx` as the
bounded fallback (the flag is evidence, not a gate). The UART command lane
is QEMU-verified too: `qemu-args` now always emits a bidirectional serial
(`-serial tcp:127.0.0.1:<port>,server,nowait`; `dual_band.tcp.host_port`
when set, else `G6B_UART_CONSOLE_PORT`=4567) — a `-serial file:` console is
output-only and strands `trap_uart` input. Verified on QEMU: writing
`View`/`Ui`/`File` to the TCP serial dispatches through PLIC irq 10 →
`trap_uart`; `Ui` re-ran `DomPaint`+`VioPaint` live on the virtio console.
Exec model: `vio_notify`
sets `plic_pending |= 1<<1` (slot-0 model → irq 1) and the uart injection
uses `UART_IRQ`; tests assert `sei_claims` covers the virtio claims. Still
open: eventq/input delivery, `wfi`-driven waits (the poll stays bounded),
full `g6lc64-virt.json` under QEMU (needs a custom mbox device model).

B53 follow-on 7 (2026-09): **high-res/high-DPI scanout + the uncore display
seam.** The scanout is now the proxy high-res target, not the Gr geometry:
`VioScan` creates/attaches/scanouts `gp.2×gp.3` (1920×1080 on
`g6lc64-qemu.json`; `VIO_FB_MAX` 4→16 MiB for the 8.3 MB surface) and the
blit was split — `FbExpand` is the shared, backend-agnostic scale-expand of
the 4bpp `__gr_plane` into `__scan_fb` with the *same semantics as
`g6b_gr::proxy::Proxy::to_ppm`* (`fit`/`dpi` = uniform `scale` in a
**centered** letterbox — ox=(hi_w−low_w·sc)/2, oy likewise; `fill` = bounded
per-axis integer stretch, exact for integral ratios), then `VioPaint` pushes
the whole high-res rect (TRANSFER+FLUSH) — **QEMU-verified**: `screendump`
is `P6 1920×1080` with the 640×480 DOM/Gr plane ×2 centered at (320,60),
letterboxes black, green band on top. Host test
`vio_paint_scale_expands_to_proxy_high_res` samples the scaled surface
against the plane nibbles. A `peripherals[]` `class:"display"` entry
declares the **native uncore engine** (HDMI/DP): `BoardSpec::display_ctrl()`
yields `wants_virtio_gpu` and `wants_disp_scan()` emits `DispPaint`
(`FbExpand` → register-window commit per
`architecture/uncore/hdmi-display.md` → `DISP-OK`) plus a `G6FB` descriptor
at `__vio+0x400` — the `simple-framebuffer`-shaped BIOS→Linux handoff (same
surface, no re-init). `exec` models the window (`disp_committed` +
`disp_desc`); `fixtures/g6lc64-hdmi.json` exercises it (smoke `DISP-OK`, no
VIRTIO lines). QEMU frontends: `qemu-args` emits `virtio-gpu-gl-device` +
`-display egl-headless,gl=on` when `proxy.gl` (virgl — needs a host DRM
render node; this WSL host has none → `opengl is not available`), `--no-gl`
falls back to `virtio-gpu-device` (identical guest commands), and `--vnc N`
appends `-vnc 127.0.0.1:N` — a host frontend over the QEMU console that
serves the BIOS scanout and a later Linux guest identically. Still open:
host render-node availability for real virgl (`egl-headless,gl=on` needs
`/dev/dri/renderD*` — `--no-gl` is the fallback; WSL2 confirmed the gate:
`egl: no drm render node available`). QEMU `sendkey` verification of the
input lane is **done** — see the follow-on-8 QEMU note below.

B53 follow-on 8 (2026-09) — **virtio-input eventq + WFI waits + absent-device
tolerance.** `VIO_DEV_INPUT` (DeviceID 18) is scanned on the virtio-mmio
slots: `InpInit` performs the virtio 1.x handshake on the probed input slot,
sets up the *eventq* (queue 0 — 8 posted `virtio_input_event` buffers in
`__vio+INP_*`, `VIO_BSS` → 0x600) and notifies; the exec model's
`host_inp_kick` stands in for QEMU `sendkey` (canned `EV_KEY` KEY_A press →
used elem → InterruptStatus → PLIC irq `1+slot`). `trap_inp` acks the device
ISR and `jal`s `InpDrain`, which pushes each `EV_KEY` event as
`(code<<8)|value` into the bounded 16-entry `INP_KQ` key queue (serial
marker `INP`) and re-posts every consumed buffer so the device never runs
dry. UART `Keys`/`K` (`CMD_KEYS`) and the mailbox `K` doorbell both run
`InpPoll` → `KEY <8-hex>` dump per queued entry (mbox answers
`RSP = "KEYS"`); the model feeds `Keys\n` after the canned keypress and the
smoke prints `KEY 00001e01` — the full sendkey→eventq→irq→queue→command
loop is exec-verified. **DOM-input bridge:** `DomKey` (`kernel.wasm.jit`
gated — `WasmDomText` lives on that lane) mirrors the newest `INP_KQ`
entry into an `inp.last` DOM row (`"key <8hex>"` in `INP_KEYTXT` scratch),
called from `trap_inp` after `InpDrain` and after `InpPoll` in the `Keys`
paths — dirty-marks the row like a browser input event; the repaint stays
on the explicit `Ui`/refresh path (a per-keypress `VioPaint` is not the
irq's job and would blow the bounded step budget). `Smoke::dom_lastkey`
walks `__ui_dom` for the row; `vio_input_eventq_delivers_key` asserts it
plus `KEY 00001e01`, and the `Ui` repaint echoes `DOM| key 00001e01` —
input→eventq→irq→queue→DOM→paint is exec-verified end to end.
**Menu navigation (`DomNav`, jit-gated):** the canned kick is now a
3-event `sendkey` burst (`a` + `down` + `ret`) — DomNav walks `INP_KQ`
from a `NAV_SEEN` watermark (non-destructive; `Keys` still dumps the ring)
and press events drive the spec-derived menu tree: UP/LEFT sel-1,
DOWN/RIGHT sel+1 (wrap over `spec.menus()`), ESC reset, ENTER → open latch
+ serial `NAV <name>`; the `nav.sel` row shows `nav <name>`/`open <name>`
from its own `NAV_TEXT` scratch (WasmDomText stores the text *pointer* —
rows can never share a scratch buffer). `Smoke::dom_nav`/`dom_navtext`
walk `__ui_dom` — `vio_input_eventq_delivers_key` asserts
`NAV cpu` + `open cpu` + the three `KEY` lines; **QEMU-verified**:
`sendkey a/down/ret/down/up` → `INP`×10 → `NAV cpu` → `Ui` repaint echoes
`DOM| key 00006700` + `DOM| nav cpu`. `qemu-args` emits `-device virtio-keyboard-device` under
`BoardSpec::wants_virtio_input()` (= `wants_virtio_gpu && kernel.wasm.enable`).
**WFI-driven waits:** `VioInit`'s used-ring wait and `VioCmd`'s completion
wait insert `wfi` between a poll miss and the loop-back when `uncore.plic`
armed SEIE — the iteration bound still caps wake-check cycles and the
periodic timer keeps wakes coming, so a silent device degrades to the
bounded timeout rather than hanging (exec model completes synchronously:
the first check exits before `wfi`; QEMU exercises the irq-wake path).
**Absent-device tolerance for stock QEMU virt:** unmapped MMIO loads/stores
raise load/store access faults (scause 5/7, `stval` = fault address) in the
exec model when `stvec` is armed, and `trap_fault` treats `stval` inside the
UART1 or loopback-mbox probe window as device-absent — sets the
`__uart_line` flag and resumes at `sepc+4` — so `g6lc64-virt.json` boots on
stock `virt` (no g6lc-bios mailbox, no second ns16550) instead of parking on
`TRAP`. `MboxInit` additionally readback-checks the doorbell write
(`MBOX-NONE` when `G6MB` does not echo — covers QEMU's mapped-but-foreign
`fw_cfg` at `0x10100000`, which absorbs writes without faulting). Ordering
fix: `uart1_node`'s probe now runs before `PlicInit` arms the UART irq — a
trap-context `uart1_drain` read on an absent UART1 would otherwise take a
*nested* access fault and clobber `sepc`; `trap_mbox`/`uart1_drain` gate on
the absent flags. Exec model: `is_uart1` is presence-gated, the input device
is modelled at slot 1 (transport regs + eventq buffer latch +
`host_inp_kick`), and `run_module_bare` is the stock-QEMU shape (no mbox /
no UART1) — `stock_qemu_absent_devices_recover` asserts `MBOX-NONE` +
`UART1-NONE` + `VIRTIO-GPU-OK` + `VIRTIO-INPUT-OK` + `INP` with no `TRAP-`
and a `Wfi` halt; `vio_input_eventq_delivers_key` covers the eventq round
trip. `48/48` exec tests, `python tools/g6b.py check` green.
**QEMU-verified (2026-09, WSL2 QEMU 8.2.2 + bundled OpenSBI 1.3
fw_dynamic, stock `-M virt`):** `g6lc64-virt.json` boots end to end —
OpenSBI → `KSTART-*` → `UART1-NONE` + `MBOX-NONE` (QEMU's fw_cfg at
`0x10100000` correctly rejected) → `VIRTIO-GPU 7`-`OK` → `INFO` → `SCAN` →
`PAINT` (QMP `screendump` = P6 1920×1080 with nonzero guest pixels →
`out/g6b_qemu_screen.ppm`) → `VIRTIO-INPUT-OK` → monitor `sendkey a`/`b`
→ `INP` ×4 → serial `Keys` → `KEY 00001e01`/`1e00`/`3001`/`3000` (exact
Linux codes) → `Ui` → `DOM| key 00003000` (the `inp.last` row on the
live DOM) → `VIRTIO-PAINT`. Virgl attempt confirmed the documented host
gate: `egl: no drm render node available` (WSL2 has no `/dev/dri`; the
d3d12 WSLg driver is not a DRM render node) — `--no-gl`/`virtio-gpu-device`
is the verified path. Runner script: `out/g6b_qemu_run.sh`.

**Bounded await + background frames (2026-09, stage-5 remainder):**
- **`Await`/`A` UART command** (`CMD_AWAI`, jit-gated): claims the first
  non-pending slot of `AWAIT_SLOTS`=4 u32s at `__ui_dom` header +16
  (0 idle / 1 pending / 2 resolved / 3 rejected; +12 `npend` is the
  pending-count fast test) and renders the `await.N` row `"pending menu"`
  → `AWAIT pending N`. All four pending → `AWAIT-REJ full` (bounded
  capacity, fail closed); a resolved slot is reusable. `DomAwait` is the
  kernel poll: drains every pending slot — `AWAIT-GET /bios/menu`
  (deferred router fetch marker) → `await.N` → `"resolved menu"` →
  dirty-marks the DOM. **`Throw`/`T`** (`CMD_THRO`) rejects the newest
  pending slot — `AWAIT-THROW /bios/menu`, `await.N` → `"rejected menu"`,
  `npend`--, slot reclaimable — the thrown/caught transition (state 3,
  now exercised); nothing pending → `AWAIT-THROW none`, not an abort.
  The slot logic lives in **`WasmAwait`/`WasmThrow`** (`dom.rs`; the UART
  handlers are thin `jal`s) and the same routines are the **`env.await`/
  `env.throw` guest imports** (`jit::import_stub`) — a lowered wasm
  `call env.await`/`call env.throw` claims/rejects a slot on the guest
  code path (exec-verified, both xlens — `jit::tests::
  start_ops_executes_await_throw_imports` and the new
  `start_ops_catch_reveals_a_rejected_row`). Signatures: `env.await`
  `()->i32` returns the claimed slot (-1 when full); `env.throw` `(i32)`
  rejects *that* slot when pending (a0<0 → the newest pending — the
  default). A third guest import, **`env.catch(i32)->i32`**, returns 1
  when the requested slot is rejected (state 3) and 0 for idle, pending
  or resolved slots, including out-of-range indices. `WasmCatch` (`dom.rs`)
  is a leaf query over `__ui_dom[AWAIT_SLOT_OFF + a0*4]`. The browser host
  (`kernel.ts createWasmHost`) now binds all three imports. `start_ops` now lowers i32 `local.get`/`local.set`/
  `local.tee`/`drop` and single-i32 call results: locals and call results
  live in a bounded s2..s5 pool (`local.set` repoints rather than copies —
  a pushed `local.get` keeps its value), results materialize into a fresh
  pool reg so the next call's arg loads cannot clobber a0. The UART
  `Throw N` parses an optional slot digit (`__uart_line[6]`); plain
  `Throw` keeps `a0=-1`. `DomAwait` resolves **at most one** pending slot
  per call (bounded O(1) IRQ work; the `Ui`/`Keys` polls call it
  `AWAIT_SLOTS` times to drain) — QEMU-deterministic: a UART command burst
  can no longer out-race the whole queue inside one tick. The **shipped**
  `bios-ui.wasm` uses it: `await fetchBios("/bios/menu")` in `App.svelte`
  parses to a fetch op + an `AwaitOp`, `emit-wasm.ts` imports `env.await`
  (`()->i32`) and emits `call env.await; drop` — the guest `_start`
  claims `AWAIT pending 0` at `Ui` and a tick resolves it. The browser
  host (`kernel.ts createWasmHost`) binds `env.await`/`env.throw`/
  `env.catch` against bounded `Set`s of pending and rejected slots
  (`await()` returns the index, `throw(slot)` rejects it, `catch(slot)`
  queries it, `drain()` resolves all); the interpreter `Host` gained
  default `await_op`/`throw_op`/`catch_op` and `binary.rs` accepts the
  `(0,1)`/`(1,0)`/`(1,1)` signatures.
- **Poll points:** `trap_timer` (the periodic tick) and `Ui`/`Keys` — the
  timer tick drains pending await slots asynchronously (all 4) and flushes
  a **background repaint** (`DomPaint` + `VioPaint`/`DispPaint`) gated on
  the `DOM_PAINTED` dirty-watermark, so input/nav/await mutations reach
  the scanout without a `Ui` command and without per-irq repaints.
- **Trap-frame correctness fix (found via real QEMU):** the trap entry
  frame now saves `ra` + `t0..t6` + `a0..a7` (16 slots, 128B rv64) — it
  previously saved only 8 regs, so a trap-time `jal` (DomPaint/VioPaint/…)
  destroyed the interrupted context's `t3..t6`/`a3..a5`/`ra`; a timer irq
  landing inside a normal-context `VioCmd` `wfi` resumed `vqc_poll` with a
  clobbered `t5` → load-access fault. `s0..s11`/`gp`/`tp` stay callee-saved
  per the ABI (`DomPaint`/`DomNav` already frame them).
- **`VIO_BUSY` ctrlq re-entrancy guard** (`__vio+0x5f0`): `VioCmd` sets it
  for the transaction and clears on every exit; `VioPaint` silently skips
  while set — a trap-time paint can never interleave on the shared ring
  mid-transaction.
- **Exec model:** in-trap `wfi` (SIE masked, SPIE latched) is a bounded
  poll pause, never a halt — the outer loop's kick+SEI path can never fire
  there, so halting would abort mid-trap. `sei_claims` bound 64→128 (the
  per-byte UART claims + repaint irqs + input burst + margin) and the timer
  budget gains a second post-input tick to exercise the dirty-check
  repaint. `STEP_LIMIT` 16M→24M covers the extra repaint.
- **TRAP format:** `trap_fault` now prints `TRAP-<scause>-<sepc>-<stval>`
  (the faulting address — how the `t5` clobber was diagnosed).
- **Evidence:** exec `vio_input_eventq_delivers_key` asserts
  `AWAIT pending 0..3` + `AWAIT-REJ full` + `AWAIT-THROW` + `AWAIT-GET`×3
  + `rejected menu` + ≥3 `VIRTIO-PAINT` (incl. the timer-driven repaint).
  **QEMU-verified:** serial `Await`×4 → `AWAIT pending 0`..`3` → `Throw`
  → `AWAIT-THROW /bios/menu` (slot 3 rejected) → the next timer tick
  drains the remaining three (`AWAIT-GET`×3 → `DOM| resolved menu`×3 +
  `DOM| rejected menu` → `VIRTIO-PAINT`), a post-resolve `Await` reuses
  freed slots, input `NAV cpu` intact, zero `TRAP` — a real multi-slot
  await with resolve+reject that paints concurrently with DOM events,
  bounded and nonblocking. (`AWAIT-REJ full` is exec-verified; on QEMU
  the tick resolves slots between sends so the bound never fills.)
- Still open within B53: guest-side JS `Promise`/`catch` object semantics
  (the slot queue is now a wasm import the shipped `_start` calls — a JS
  `await`/`throw` lowers to it, but there is no JS-visible `Promise`
  object or guest JS runtime yet), and the `wfi`-inside-trap hardware
  semantics differ per implementation (QEMU wakes on masked-pending; the
  model treats it as a poll pause).

B53 follow-on 9 (2026-10) — **native 32bpp DOM text paint (`DomPaint32`).**
`g6b-asm::dom` gained `DomPaint32`, a bounded native-resolution 32bpp glyph
painter that reads live `__ui_dom` rows and the 8×8 `__font` table and writes
B8G8R8X8 pixels directly into `__scan_fb` at the output's native geometry
(`g6b_spec_proxy` `hi_w`/`hi_h`), plus a full-frame clear. `FbExpandSel` now
dispatches GPU + DOM rows → `DomPaint32`, GPU + empty DOM → `FbExpand1`, and
VGA → `FbExpand`. `VioPaint` and `DispPaint` both call `FbExpandSel`, so the
same surface logic covers virtio-gpu and the uncore display engine. A
DOM-dirty watermark update at the top of `FbExpandSel` prevents nested timer
re-entry while the long native clear is running, and the `trap_timer` dirty
watermark check keeps background repaints bounded.

- `g6b-asm` gained `Module::scan_fb_addr()` and `exec::Smoke::scan_fb` so
  regression tests can inspect the native 32bpp surface.
- `g6b-wasm::jit::tests::dom_paint32_paints_native_32bpp_text_on_gpu_surface`
  asserts the first row of the first glyph (`U` from `UI-BOOT`) in native
  1920×1080 B8G8R8X8, and `DISP-OK`/`disp_committed` on a `display`-class
  uncore peripheral (`wants_disp_scan`) to avoid the virtio-input eventq and
  stay within `STEP_LIMIT`. It passed on both the focused `cargo test` and the
  full `python tools/g6b.py check` (independence, Bun tests/build, fmt,
  clippy, workspace tests, 13/13 `bios-regress`).
- Follow-on tests added for the three-way surface dispatch:
  - `dom_paint32_empty_dom_falls_back_to_fbexpand1` proves an empty
    `__ui_dom` on a GPU-class output lands the 640×480 plane 1:1 at
    `(640,300)` using `FbExpand1` instead of `DomPaint32`.
  - `dom_paint32_vga_surface_stays_magnified` proves `kernel.proxy.surface`
    `"vga"` forces `FbExpand` (×2 for 1920×1080 dpi=192) and reports
    `disp_sel.1 == 0`.
  - `dom_paint32_paints_native_32bpp_text_on_gpu_surface_rv32` proves the
    same native glyph paint on RV32 when a low entry (`0x0001_0000`) keeps
    the scanout address below the sign bit.
  - `g6b-wasm::binary::encode_empty_ui_module` is the tiny empty `_start`
    helper used by the fallback test.
- The 4bpp `__gr_plane` / `DomPaint` path remains intact for VGA-class output
  and for the legacy UART `Ui` re-dump.
- Hardware support claims remain as documented in `architecture/DISPLAY.md`:
  no AMD/NVIDIA modesetting, no PCIe BAR assignment, no HDMI hot-plug, the
  guest GPU path is not the Rust CSS engine or WebGL.

B50–B52 verification (2026-09-05): `python tools/g6b.py check` passed
independence, 15 Bun tests/build, fmt, strict Clippy and 196 Rust tests;
`python tools/g6b.py regress` passed all 13 cases, including shared UI HTTP,
fragmented headers, idle preconnections, ELF smoke and framebuffer output.
Native WASM tests execute the emitted import/visibility ABI; numeric JIT tests
execute lowered RV32/RV64 machine words. Local HTTP page/app/menu endpoints
returned 200. Optional LDC wasm-eh execution was skipped; no RTL/silicon or
full guest-browser claim follows from these host results. MIT headers and
upstream reference boundaries were retained, with no external dependencies.

B53-catch verification (2026-09-06): added guest `env.catch(i32)->i32`;
`g6b-wasm` `start_ops_catch_reveals_a_rejected_row` and
`compile.test.ts` "env.catch reports rejection without consuming it and
throw handles negative slot" passed; `bun test` 41 pass / 2 skip;
`cargo test -p g6b-wasm -p g6b-asm` green. `env.catch` is a query over the
same `AWAIT_SLOTS` state and does not consume the rejection. Host/browser
catch remains bound; compiler/parse.ts does not yet emit `{#await}`
`{:catch}` reactivity (no source pattern uses it).

Priors: `architecture/PLAN.md` (rewrite-from-spec + conformity + current state),
`architecture/ZEAL.md`, `kernel-spec/`, host `g6lc_qemu` `--loader bios`.

B60: `g6b-wasm::Asyncify` now drives a real step/resume loop: `run_start`
reserves an asyncify data region above `__heap_base`, `libwasm_await__void`
sets `__asyncify_state`/`__asyncify_data` so the instrumented wasm can unwind,
and `KernelHost` records the slot and implements `take_slot`/`resolve_slot`.
`Asyncify::new` correctly maps function-export indices to the body table when
imports are present, fixing the live LDC 1.43 / libwasm
`browser-ui/out/bios-ui-libwasm.wasm` path. `call_import` is now a
`Runtime` method with access to live globals, enabling host imports to mutate
asyncify state. A minimal asyncified module now sleeps and resumes through the full
`Asyncify::step`/`resume` loop in `g6b-wasm` tests. Still open: full D
`await`/`catch` Promise continuation lowering, `libwasmAwaitFailed` /
`libwasmAwaitError` rejection hooks, and `resolve_slot` performing actual
kernel/router I/O and writing the resolved value back to the guest. The
bounded guest engine still does not claim full guest-browser / JS Promise /
complete Asyncify rewind semantics.

B61-B68 (planned, 2026-09-06): the complete libwasm host ABI was measured
rather than estimated. `browser-ui/libwasm/source/libwasm/types.d` declares
**116** distinct `extern(C)` host imports and its declaration set is
byte-identical to the reference checkout, so the target is exact. Of those 116,
**3** are implemented (`libwasm_await__void`, `libwasm_get__string`,
`libwasm_add__string`); the remaining 113 are `assert(0)` stubs in
`g6b_kernel.d`, which is the correct fail-closed state. Usage across the 684
generated `bindings/**` files concentrates in eleven names plus
`Object_VarArgCall__*` (2,035 call sites through the
`Serialize_Object_VarArgCall` template).

The staged sequence is recorded in `architecture/LIBWASM-ABI.md`: B61
refcounted object table (`libwasm_add__object` / `removeObject` /
`copyObjectRef`, roots 1 = staging DOM, 2 = BoardSpec scope); B62 scalar
box/unbox, which requires refactoring `g6b-wasm::call_import` off its
i32-only operand coercion; B63 property get/set behind an allow-listed
per-receiver property registry; B64 `Optional!T` sret returns (landed; presence
flag offset verified from the `optional.d` source and the LDC 1.43 artifact); B65 a
bounded first-party JSON codec extending `g6b-spec::json` for
`Object_VarArgCall__*` (landed; `JSON_parse_string` / `JSON_stringify`, all twelve
`Object_VarArgCall__*` signatures, and an `argsdef` descriptor parser supporting
`Optional!T` and `SumType!(...)` are wired through `g6b-wasm`, `browser-ui/src/kernel.ts`,
`compiler/wasm-cell.ts`, and `libwasm/g6b_kernel.d`); B66 event handlers / timers / named
`libwasm_set__function` (re-entry guarded by committed DOM state and asyncify state); B67
a no-eval allow-listed Lodash/Moment interpreter; B68
typed-array views and promise combinators.

B61-B66, `getTimeStamp`, B67 Moment core, B68 promise combinators, and B68 typed
array / DataView `Create` are implemented. Still open: full Moment method set.
Permanently refused: `eval` in any form
(including the Lodash `=(...)` iteratee path that the reference `ldexec` JS
evaluates), the WebGL/WebGPU/RTC/XUL/Payment/SubtleCrypto binding families, and
any reading of a linking LDC artifact as evidence of a browser. B66 is now
guarded by committed DOM state and asyncify state; real re-entry from host
events/timers only fires when safe.

B61 verification (2026-09-06): the refcounted libwasm object table landed.
`crates/g6b-wasm/src/objects.rs` is a shared bounded `ObjectTable<T>` (4,096
live objects, slot freelist, explicit refcounts) used by `KernelHost` and the
g6b-wasm `TestHost`; `createLibwasmHost` mirrors it in TypeScript.
`libwasm_add__object` / `libwasm_removeObject` / `libwasm_copyObjectRef` are
declared in `g6b_kernel.d` (their `assert(0)` stubs removed), dispatched in
`Runtime::call_import`, and checked by the `wasm-cell.ts` ABI verifier, so a
shipped LDC artifact importing them is validated at build time. `copyObjectRef`
returns the same handle and increments; release frees only at zero; handles 1
and 2 are protected roots. Hosts that do not implement the trio return `Err`
from the trait default rather than fabricating a handle.

Two defects were found by the new tests rather than by inspection. The browser
`libwasm_get__string` silently returned `""` for a freed handle, which is the
use-after-free the design says must fail closed; it now raises. The `TestHost`
object vector allowed a handle to be reused after removal because it never
tracked frees at all; it now uses the real table.

Verified: `cargo test -p g6b-wasm` 51 pass / 1 ignored (5 new `objects` unit
tests plus 2 new interpreter dispatch tests, including a `Bare` host asserting
the fail-closed defaults); `bun test` 49 pass / 2 skip / 0 fail with 7 new
cases covering refcount, slot reuse, six parametrised lifetime violations and
the budget; `G6B_DUB_WASM=1 G6B_WASM_ASYNCIFY=1 bun scripts/build.ts` produced
a `fresh` verified asyncified LDC 1.43 artifact against the widened ABI;
`python tools/g6b.py check` and `regress` green.

Still open and unchanged: 110 of the 116 stock libwasm imports. The DOM handle
space and the object handle space remain separate (they merge in B63), and an
allocated object carries no properties until the B63 property registry exists.
Nothing here is a Promise/event/JS-runtime claim.

B62/B67 verification (2026-09-06): scalar box/unbox and the Lodash lane are
wired end to end, and a documented contract was found to be wrong and corrected.

The correction first. `architecture/LIBWASM-ABI.md` previously said arrow
functions were refused and that a no-eval "Tier A" still covered
`map`/`filter`/`find`. Both cannot hold: `lodash.d:606,614,621,628,635` shows
libwasm's own `putLocal` emitting an arrow function as the parameter whenever a
Lodash iteratee is a D delegate, so refusing arrow functions refuses every
predicate-taking method. The resolution is that those five strings are fixed
and compiler-generated, and all five merely call the guest indirect function
table; the host recognises them by identity and dispatches into wasm. `eval`
stays absent without costing the iteratee half of the library. The doc now
states this, and the ES6 table no longer claims arrow functions are refused
outright.

B62 landed: `LibwasmValue` in `crates/g6b-wasm/src/values.rs` models the boxed
scalar and vector shapes, and `g6b-wasm::Host` exposes typed `add_*`/`get_*`
methods. `Runtime::call_typed_import` decodes typed operands ahead of the
all-i32 table; `validate` admits the numeric libwasm add/get signatures;
`invoke` allows non-i32 signatures for imports while wasm-local bodies stay an
i32 machine. The 15 `libwasm_add__*` and 14 `libwasm_get__*` scalar/array
imports are declared in `g6b_kernel.d`, dispatched in `g6b-wasm`, mirrored in
`browser-ui/src/kernel.ts`, and verified in `wasm-cell.ts`.

B67 backend: `crates/g6b-js/src/lodash.rs` is a bounded command-buffer parser
(the `lodash.d:417-475` sigil convention), a `JsValue` model and an evaluator
over 37 methods, with `Iteratee` for guest dispatch. All twelve `ldexec_*`
imports are declared in `g6b_kernel.d`, dispatched in `g6b-wasm`, ABI-verified
in `wasm-cell.ts`, and mirrored in `browser-ui/src/kernel.ts`. Budgets: 256
commands, 64 KiB buffer, 5 params, 4,096 elements.

Lane difference, deliberate and documented: the browser host dispatches the
guest iteratee through `__indirect_function_table`; `KernelHost` cannot re-enter
a running instance, so a predicate chain fails closed with
`CallbackUnavailable` rather than computing a wrong answer without the
predicate. Closing that is B66, not B67.

One divergence was caught by test rather than inspection: `Object.create(null)`
has no `toString`, so the browser lane threw `TypeError: No default value`
where the Rust backend returned `"[object Object]"`. A shared `jsString` helper
now makes the two lanes agree.

Verified: `cargo test -p g6b-js` 55 pass (10 new lodash tests: sigil decoding,
all five boilerplates recognised as callbacks, hostile JS refused by name,
value chains, guest dispatch once per element, throw propagation, unsupported
method and budget failures, truncation fuzz, and an assertion that every
advertised method is reachable); `cargo test -p g6b-wasm` 53 pass / 1 ignored
(includes a new B62 scalar round-trip test proving i32/u32/i64/f64/bool/byte
round-trips and width preservation through `libwasm_add__*` / `libwasm_get__*`);
`bun test` 52 pass / 2 skip / 0 fail (new B62 scalar round-trip test in
`compile.test.ts`); fresh verified asyncified LDC 1.43 artifact;
`python tools/g6b.py check` and `bios-regress` green.

The B61–B62–B67 libwasm host surface is implemented. B63 is landed: the
`g6b-wasm::Runtime` typed `Object_Getter__*` / `Object_Call__*` dispatch, the
D host imports in `browser-ui/libwasm/source/libwasm/g6b_kernel.d`, the
signature verifier in `browser-ui/compiler/wasm-cell.ts`, and the fail-closed JS
handlers in `browser-ui/src/kernel.ts` are all in place with Rust and Bun tests.
The shipped asyncified LDC 1.43 artifact now uses the B63, B64, and B65 families when
D code imports them. B67 Moment core, B68 typed arrays / DataView Create are now wired.

**B59b (2026-09-08)** — the optional libwasm cell now has a **pinned**
compiler instead of an ambient one. `browser-ui/toolchains/ldc.lock.json`
names upstream `v1.43.0-beta1` (DMD 2.113.0, matching the carried
`runtime-v1.43.0`) and carries the upstream
`ldc2-1.43.0-beta1.sha256sums.txt` digest and byte size for each of the five
published host assets. `bun scripts/install-ldc.ts` downloads the asset for
the running host, checks size and SHA-256 **before** extracting, extracts into
`browser-ui/toolchains/<asset-dir>/`, re-reads `ldc2 --version` and deletes the
tree unless it is exactly the pin, then writes `toolchains/installed.json`.
Only `.gitignore` and the lock file are tracked, so the ~220 MB tree is
reproducible from the pin rather than vendored. `compiler/ldc-pin.ts` is the
sole reader and validates schema, 1.43-ness, tag/version agreement and the
upstream repository; a host with no published build (`windows-arm64`) is
refused with that message rather than downgraded.

`compiler/ldc.ts::findLdc` now prefers the pinned tree over every ambient
toolchain (only the `SVELTE_D_LDC`/`LDC`/`WASM_LDC`/`SVELTE_D_WASM_LDC`
env escape hatch outranks it), and `resolveToolchain().pinned` reports which
won. This is a correctness fix, not ergonomics: `cellInputHash` hashes the
compiler **binary content**, so the previously discovered host-built
`1.43.0-git-1218a47` produced an `inputs` digest nobody else could reproduce —
which is exactly why every build reported
`artifact=stale ... source/runtime/toolchain/ABI mismatch` and shipped a
zero-byte `out/bios-ui-libwasm.wasm`. With the pin installed,
`G6B_DUB_WASM=1 bun scripts/build.ts` produces a verified `fresh` 37,253-byte
artifact whose provenance records `LDC - the LLVM D compiler (1.43.0-beta1):`,
and subsequent plain builds keep it fresh from cache. The release bundles DUB,
so the LDC/DUB pair can no longer be mismatched. The `addon-wasi` package is
deliberately not pinned: the cell links `-defaultlib=` against the carried
runtime, so no prebuilt WASI druntime/phobos is used.

Two tests that had never actually executed were corrected rather than left
aspirational. `actual full LDC cell starts with the explicit DOM ABI` had a
frozen four-import list and a hand-written stub env; it now derives both from
the module and additionally checks that the provenance manifest matches the
bytes and names the pinned compiler. `executes the shipped LDC cell through
the actual host` asserted `UI-BOOT`/`CPU`/`Settings` text and >10 nodes — that
was only ever green because the artifact was empty. The shipped cell is the
component **shell** plus the kernel boundary: it mounts one `<main>` and drives
18 `/bios/...` GETs, one `holyc` line and one `register_endpoint` call through
`createLibwasmHost`'s fail-closed URL/method validation, and builds no setup
tree. The test now asserts that, so the gap cannot be silently misread as
implemented. Verified: `bun test` 96 pass / 2 skip / 0 fail; with
`G6B_TEST_LDC_CELL=1 G6B_TEST_LDC_FX=1` the two real-compiler probes run and
pass for the first time (14/14 in `build.test.ts`); `cargo test --workspace`
green; `python tools/g6b.py check` and `bios-regress` OK. No RTL/silicon,
guest JIT or guest-browser claim follows.

**B72 (2026-09-07)** — browser instance: `createBrowserContext` in
`browser-ui/src/kernel.ts` owns the `console`/`window`/`document` singletons,
with a bounded pollable console ring and `renderConsoleInto(el)` for a devtools
panel. Shape follows `kernel-spec/goosie` `internal/browsercontrol/types.go`
(`ConsoleEntry{level,data,timestamp}`, `ConsolePage{contextId, pageRevision,
entries, dropped}`) and `internal/js/runtime.go` levels
(log/info/warn/error/debug; `table` refused, no table renderer).

**Engine-agnostic by construction** — nothing in `createBrowserContext`
references WebAssembly, libwasm or the object table. The contract is
`bindings()` (allow-listed `name -> object`) + `global(name)` + `consolePage()`.
libwasm consumes it via ONE new import, `libwasm_global(name) -> handle`
(`g6b_kernel.d`, `wasm-cell.ts` `127,127->127`, `interp.rs` kernel lane returns
0); with the handle the existing `Object_Call_string__void(h,"log",msg)` reaches
members, so there is no console ABI. Plain JS and the devtools panel use the
singletons directly. Adding a second engine must not edit the context.

Honest properties: bounded ring reports `dropped` **and** `missed` (a poller
whose cursor fell behind is told, never silently skipped); instances are
isolated by `contextId` so a frame cannot interleave into its parent; rows are
`textContent` so logged markup is displayed not parsed; unknown globals are
`undefined`/handle 0, never a stub that swallows writes; singletons are
protected roots the guest cannot free; formatting is `String()`-per-arg with a
4 KiB cap and `[uncloneable]` for cycles — no `%s` mini-language. 17 Bun tests.

Boundary: a frame gets *its own* instance. It does **not** get to read a
cross-origin frame's console or DOM — same-origin policy forbids that
independently of this design, so no amount of local plumbing enables it.

**B73 (2026-09-07)** — golden-image PPM harness wired into `bios_regress.py`.
New `g6b css-render` and `g6b ppm-diff` CLI commands; `g6b-gr::canvas` adds a
pixel-accurate 16-colour canvas, PPM parser and per-pixel diff with tolerance;
`g6b-css::render` implements the first layout pass (block-flow children, margin
edge stacking, background-colour fill, border-width outlines, content-box vs
border-box, percent widths, display:none) and a colour-name/hex allow-list mapped
to the 16-colour BIOS palette. Shorthand expansion for `margin`, `padding`, and
`border` added to the parser, with `border-style` dropped (not rendered) and
`border-color` as a new property.

Five fixture families under `fixtures/render/` with committed goldens:
`box_basic`, `border_box`, `stacked`, `margin_collapse`, `percent_width`. The
`css_golden` `bios_regress.py` case renders each and runs `ppm-diff`; all pass.
The `margin_collapse` fixture intentionally documents the *current* non-collapsing
behaviour (gap = sum) so a future margin-collapse change must update the golden
and be reviewed. `percent_width` uses `w=64,h=32`. The renderer refuses unknown
colours rather than defaulting them; a test asserts a box with `chartreuse` and
`aquamarine` stays transparent/white.

Honest limits: no inline/inline-block/flex/grid, no margin collapse, no text
rendering (the canvas is box-only), no float, no font metrics, no CSS shorthand
for `border-*` or `background`, and `margin_collapse` golden would change if/when
margin collapse is added.

**B71 (2026-09-07)** — render debugging facilities. Three layers, documented as
methodology in `AGENTS.md` §"Render debugging methodology" with `kernel-spec/goosie`
`internal/css` + `internal/renderer` cited as the rendering-logic ancestor:
`g6b_css::parse_survey` (what CSS is missing — returns the sheet plus the sorted
unsupported-property list instead of refusing, for growing
`fixtures/css-features.json`); `g6b_css::inspect::explain` (why a value won —
DevTools-shaped trace keeping overridden candidates visible with
`!important`/specificity/source-order reasons, plus the resolved box;
`to_text()` and `to_json()`); and `createRenderInspector` in
`browser-ui/src/kernel.ts` (`diff` an `explain` JSON against the host browser's
`getComputedStyle`/`getBoundingClientRect`, whole-pixel tolerance on lengths
only; `describe` dumps the host view). 26 Rust + 10 Bun tests.

Design points worth keeping: `explain` reads the winner out of `cascade` rather
than recomputing it, so the debugger cannot disagree with the engine it
describes; the strict `parse` still refuses everything `parse_survey` tolerates,
so a survey cannot widen the render path; and a host without
`getComputedStyle` throws rather than reporting a pass. The browser diff is an
**external** oracle for computed values (legitimate evidence), unlike a
recognition score or a self-answered `supports()` — `RENDER-VALIDATION.md` §1,
§6. It compares computed values and one rect, not pixels; pixel truth stays the
golden PPM diff, still unwired into `bios_regress.py`.

**B70 (2026-09-07)** — render validation groundwork: `kernel-spec/goosie`
(MIT, `1039ae6`, tier U in `.licensing-tiers`) added as the read-only spec for
CSS cascade / box model / display list, per prime directive 1 (rewrite, do not
port). New `crates/g6b-css`: bounded CSS subset parse, specificity-ordered
cascade (`!important` > specificity > source order), and content-box/border-box
box model, 18 tests. `architecture/RENDER-VALIDATION.md` defines the two-track
methodology and `fixtures/css-features.json` the track-A backlog.

Two boundaries recorded because both are easy to get wrong:
1. `@browserscore/supports` and `browserscore.dev` measure feature
   **recognition**, not rendering correctness (upstream states this). A
   recognition score is therefore a backlog, never a correctness gate, and a
   self-reported score from our own engine is circular — a `supports()` that
   returns `true` for everything scores 100% while rendering nothing.
2. `goosie/AGENTS.md` and `svelte-d/AGENTS.md` are upstream tier-U artifacts,
   **not** governance here. Goosie's file mandates a Playwright + Chromium
   comparison gate, which prime directive 6 forbids; our gate is the golden PPM
   diff. Precedence is stated in `kernel-spec/README.md`.

Still open: golden-image harness wiring into `bios_regress.py`, inheritance
pass, shorthand expansion, and rasterising `color`/`background-color`. No
rendering engine is claimed — no float, flex, grid, or text shaping.

**B69 (2026-09-07)**: generic DOM method bindings (`setAttribute`/`getAttribute`/`removeAttribute`
and `classList.add`/`remove`/`toggle`/`contains` through `Object_Call`/`Object_Getter`) and a
bounded ES6 `Map` host surface (`libwasm_map_create`/`set`/`get`/`has`/`delete`/`clear`) are wired
across `g6b-wasm`, `g6b_kernel.d`, `wasm-cell.ts`, `kernel.ts`, and `compile.test.ts`. Rust and Bun
tests pass; QEMU execution was skipped because `qemu-system-riscv64` is not installed in this
environment. Still open: full Moment method set, D `Map` wrapper, and `Set`.
Value-returning iteratees remain impossible because the generated delegate ABI
is `bool`-only. None of this is a JS engine.

**B72 (2026-09-07)** — DOM event model and TTF font display unit foundations.
`g6b-dom::event` lands `Event`, `EventInit`, `addEventListener`,
`removeEventListener`, `dispatch_event` with capture/bubble propagation,
`stopPropagation`, `preventDefault`, and `EventHost` callback indirection so
`Node` stays `Clone`. 8 Rust tests pass. `g6b-ttf` is added as a first-party
wrapper around the pinned `fontdue = "0.8.0"` crate: `BiosFont::from_bytes`,
`render`, `metrics`, and `blit_glyph` into `g6b-gr::Canvas`. `check_independence.py`
is taught an explicit `_ALLOWED_EXTERNAL` set so pinned crates do not violate KD0.
Architecture updates in `BROWSER.md` (event model) and `DISPLAY.md` (TTF unit).
`g6b-cli` gains `css-paint` to render `g6b-ui::setup_html` through
`g6b_css::render_ui_to_canvas` with approximate colour mapping and text layout.
Still open: `g6b-js` AOT event-listener ops, `libwasm`/`browser-ui` event ABI,
CSS-rendered hit boxes for pointer/keyboard dispatch in `BrowserSession`, and
using `g6b-ttf` to replace the 8×8 built-in font in the CSS text path.

**B73 (2026-09-07)** — TTF font integration, CSS hit boxes, and host event
boundary. The OFL Inconsolata font is bundled under `fixtures/fonts/` and loaded
through `g6b-ttf::default_bios_font`; `g6b-css::render` uses `BiosFont` metrics
and `blit_glyph` for the CSS text cursor when `DrawText::Yes`, with 8×8 fallback.
`g6b-css` now produces `RenderOutput { canvas, hit_boxes }`: each painted block
gets a `HitBox` carrying DOM path, `id`, tag, and bounding rect. `BrowserSession`
gains `BrowserEventHost`, `hit_boxes`, `add_event_listener`, `remove_event_listener`,
`dispatch_pointer`, and `dispatch_key` using `Node::dispatch_event`. `g6b-wasm`
adds `addEventListener`/`removeEventListener`/`dispatchEvent` to the `Host` trait
and `call_import` dispatch. `BrowserSession::listeners_run` executes AOT listeners
through `g6b_js::run` with `{detail}` substitution and re-enters libwasm by
cloning the module and calling `g6b_wasm::run_with_fuel_mut` with an event object
handle. `KernelHost` collects pending libwasm listeners during `_start` and
`BrowserSession` persists `wasm_module`, `wasm_objects`, and `wasm_handles` for
re-entry. D event imports added to `browser-ui/libwasm/source/libwasm/g6b_kernel.d`,
JS event stubs added to `browser-ui/src/kernel.ts` for both wasm hosts, and the
libwasm ABI verifier in `browser-ui/compiler/wasm-cell.ts` accepts the new
signatures. `g6b.py check` and `bios-regress` green.

**B74 (2026-09-08)** — CSS pointer-hit dispatch tests and propagation. The
`g6b-css::render` `Cursor` was missing its `canvas` reference, so nested block
painting and hit-box collection were silently disabled; `paint_block` now sets
`cursor.canvas = Some(canvas)`. CSS hit-box tests added: `hit_boxes_record_block_ids_and_paths`,
`hidden_and_display_none_are_excluded_from_hit_boxes`, and
`hit_boxes_support_reverse_lookup_by_coordinate`. `g6b-kernel` adds
`browser_session_pointer_dispatch_uses_css_hit_box` and
`browser_session_pointer_dispatch_propagates_capture_then_bubble`, proving
`BrowserSession::dispatch_pointer` finds the CSS hit target, routes through
`Node::dispatch_event`, and fires capture/target/bubble listeners in order.
`path_to_id` returns a `<body>`-relative path matching the CSS hit-box convention.
`g6b.py check` and `bios-regress` green.

**B75 (2026-09-08)** — display outputs split from the VGA surface (P1+P2 of the
display-output plan). Root cause found first: `FbExpand` sourced the 4bpp
`__gr_plane` unconditionally, so the upscaled ZealOS-intent plane *was* the
HDMI/virtio-gpu picture, and `wants_virtio_gpu()`/`wants_disp_scan()` chose a
transport at generate time with no runtime arbitration at all.
`g6b-spec` gains `OutputClass` (`pcie-linear-fb` > `uncore-scanout` >
`virtio-gpu` > `none`), `Surface` (`vga`/`gpu`), `DisplayOutput`, `Pcie`,
`display_outputs()`, `default_output()`, `default_surface()`, `surface_toggle()`
and `wants_pci_scan()`. The ladder is over **validated framebuffers, never
vendors**. `g6b-gr::proxy::Proxy` gains `outputs`/`active`/`surface`,
`select_output`, `set_surface`, `toggle_surface`, `select_line` (`DISP-SEL`) and
`to_ppm_gpu`, which **refuses** a canvas that is not native geometry rather than
upscaling it; `bar_h` is 0 on the GPU surface because the status is a real DOM
node there. `/bios/display` GET/POST is the single toggle mechanism for the
browser (`#disp-toggle`, absolutely positioned top-right), HolyC
(`DisplayPrint`/`DisplayToggle` + the new `DisplaySurface` builtin) and the
kernel (`BrowserSession::surface`, `toggle_surface`, `proxy()`).
`g6b-css` gains `position:absolute` + `top`/`right`/`bottom`/`left` with a
containing-block model, an out-of-flow drain pass so absolutes paint on top
without moving the flow, and value-level survey reporting so the real
`position:fixed`/`relative` stacking CSS drops-and-reports instead of failing the
sheet. Two latent bugs fixed en route: `DrawText::No` never actually suppressed
glyphs, and `Cursor` was missing its canvas so nested blocks were measured but
never painted (B74). `check_display()` refuses a `pcie.mmio` window that swallows
any peripheral, `dram_base` or the ECAM base — QEMU virt's 32-bit PCIe window is
`0x40000000..0x80000000`, exactly the ai-island GEMM block, so the two cannot
coexist. REQUIREMENTS now state the AMD AtomBIOS/DCN + NVIDIA GSP refusal and the
HPD/EDID contract-revision ask (drafted as revision 2 in `hdmi-display.md`).
`g6b.py check` and `bios-regress` green.

**B76 (2026-09-08)** — guest-side display mux and the surface-gated blit (P3+P4
of the display-output plan). New ASM IR purposes `PciScan` and `DisplayMux`.
`PciProbe` walks bus-0/fn-0 ECAM for base class `0x03` and accepts BAR0 only if
it is a memory BAR, nonzero and inside `pcie.mmio` (`PCI-GPU` /
`PCI-GPU-DEMOTED` / `PCI-GPU-NONE`); it never assigns a BAR and never mode-sets.
`DispSel` walks the candidate ladder, latches the first **present** rung into
`__disp` (`__vio+0x600`) and prints `DISP-SEL <class><surface>`; an explicit
`kernel.proxy.surface` overrides the rung default so guest and host agree.
`proxy_geom` gained a `proxy_outputs` table (header + one 6-word record per
candidate) after its eight legacy words, so existing offsets are unchanged.
`FbExpand` was generalised into `expand_node_named`, yielding `FbExpand1` (scale
1, centred) alongside it, with per-copy loop labels and a single shared
`vio_pal`; `FbExpandSel` picks between them from the latched surface and both
`VioPaint` and `DispPaint` now route through it. **This is the concrete fix for
the original complaint**: on a GPU-class output the 640×480 plane lands 1:1 at
(640,300) of a 1920×1080 scanout instead of being magnified ×2, proven by
`gpu_surface_places_the_plane_1to1_instead_of_magnifying_it`; the ×2 upscale is
still proven on the VGA surface by the existing test, now explicitly pinned with
`"surface":"vga"` rather than being allowed to become unreachable.
Exec model gains a read-only PCIe ECAM window, a modelled stdvga-shaped
controller, `Smoke::disp_sel`/`pci_fb`, and `Module::vio_bss_addr`. Two real
bugs found: the interpreter never decoded `sltu` (added to the IR, encoder and
model — the BAR range check needs a genuine unsigned compare, not the signed
sign-bit tricks used elsewhere), and `DispSel` initially ignored the surface
override. HPD is read only at contract revision 2 and reported `HPD_UNKNOWN` on
revision 1 — the model reports rev 1, so nothing claims hot-plug detection.
New fixture `fixtures/g6lc64-pcie-gpu.json` plus `disp_sel_pcie` and
`disp_sel_vga` regression cases; `disp_scan` now also asserts `DISP-SEL 21`.
`DomPaint32` is now implemented (see B53 follow-on 9 above). Still open:
the per-output geometry jump table, which is unnecessary until EDID reports
differing modes.
`g6b.py check` and `bios-regress` green.

B76 follow-on (2026-09-08) - **runtime `__disp` geometry.** The scanout path
no longer reuses the gen-time `g6b_spec_proxy` default: `DispSel` latches the
winning rung's `w`/`h`/`stride` into `__disp` and every consumer reads them
there. `FbExpand`/`FbExpand1` compute the integer scale from the latched mode
(new IR op `Op::Divu`, clamped 1..=64) plus the centred letterbox and
right-row pad - the mode (`fit`/`fill`/`dpi`) is still a gen-time pick between
divide forms, but the operands are runtime. `DomPaint32` clears `w*h` words and
addresses glyph rows by the latched stride. `VioScan` runs *after* `DispSel`
(it was emitted inside the earlier virtio call block), gates on
`__disp.class == VirtioGpu`, and sizes CREATE_2D/TRANSFER/FLUSH from `__disp`;
`DispPaint` gates on `UncoreScanout` and programs the engine + `G6FB`
descriptor from the latch, so a backend never commits a surface it did not win
(previously `DispPaint` painted whenever the engine MAGIC was present, even
when PCIe won the ladder). `__scan_fb` is sized as the max across
`display_outputs()` so every rung's mode fits. Per-output jump table retired
entirely: the runtime scale covers differing output modes, and EDID (contract
rev 2) can land without codegen changes. Encoder/executor gained `s8`/`s9`.
Two host-model bugs found: `VioScan` ran before `DispSel` could not have read
the latch (fixed by the reorder), and the executor never truncated effective
addresses on RV32 - `la`/`auipc` at `0x8xxx_xxxx` sign-extended into the u64
register file and every load/store/`jalr` bounds-check missed. `eff_addr`
now wraps `rs1 + imm` at 32 bits for xlen=32. New exec tests:
`fb_expand_follows_the_disp_latch_not_the_gen_time_proxy` (poked 1280x720,
both xlens), `fb_expand_sel_dispatches_per_output_geometry` (one latched
1600x1200, `vga` surface -> scale-2 fit at (160,120), `gpu` surface -> 1:1 at
(480,360)), and `dom_paint32_uses_the_disp_latch_geometry` (`FbExpandSel` ->
`DomPaint32` at a poked 800x600, pixel-checked glyph cells at the latched
stride). The PCIe-linear-fb paint path is now closed: `DISP_SEL_FB_LO`
doubles as the blit destination pick - nonzero means the latched output has
its own linear window (the pcie rung's accepted BAR), so `FbExpand`/
`FbExpand1`/`DomPaint32` write it in place and `PciPaint` is just
`FbExpandSel` + `fence` + `PCI-PAINT` (gated on `__disp.class ==
PcieLinearFb` and `DISP_PCI_FB != 0`; no doorbell, the BAR is the display
memory). The exec model keeps a `VIO_FB_MAX`-sized BAR shadow
(`Smoke::pci_fb_img`) - the aperture is device-sized because the read-only
probe cannot size BARs. `PciPaint` is also wired into the `Ui` repaint lane
and the timer tick beside `VioPaint`/`DispPaint` (each self-gates on
`__disp.class`); `Ui` deliberately still skips `DispPaint` - the uncore
repaint is covered by the timer's dirty-DOM watermark and a second full
`FbExpandSel` inside UART IRQ context would double the frame cost.
`pci_probe_accepts_a_linear_bar_and_wins_the_ladder`
asserts `PCI-PAINT`, nonzero BAR pixels at the 1:1 offset, and an all-zero
`__scan_fb` (proving the fallback was not painted); the demoted case stays
quiet and falls through to virtio. `g6b.py check` and `bios-regress` green.

B77 (2026-09-09) — modern RGBA render lane (`g6b-css::render32`) completed and
wired into the host tool-chain. `g6b-gr` Canvas32 surfaces, `g6b-img` PNG/SVG/
icon assets, `g6b-ttf` bundled fonts, `g6b-css` `rgba()`/opacity/rounded-corners/
images/SVG/icons/font-properties all pass focused tests. The `render32` parser
now uses `parse_survey` so real-world stylesheets with unsupported properties
fail closed per-property, not per-page. `g6b-html` `to_uart_lines` emits `img`
`alt` text and skips `svg`/`canvas` for the UART fallback lane. `g6b-cli`
`css-render` gained `--modern` and `--assets DIR` to exercise the new lane from
the command line. `g6b-kernel` exposes `ui_ppm32`/`ui_ppm32_output` (track-A true-
colour setup-page PPM) and a regression test proving the setup page renders a
non-empty RGBA PPM. `g6b-css` re-exports `AssetMap`/`FontSet` so callers can use
`render32` without extra crate deps. Still open: `g6b-spec` `files.assets` flag +
`g6b-http` asset mount, `g6b-ui`/`browser-ui` modern CSS (80s BIOS look + icons/
logo) and render32 goldens in `bios_regress`. `g6b.py check` and `bios-regress`
green.

B78 (2026-09-09) — high-definition 80s BIOS look applied to the browser UI and
static setup page. `browser-ui/src/App.svelte` now emits a dark navy/cyan/amber
color scheme with rounded corners, Inconsolata typography, translucent panels and
a clear status strip. The generated `out/bios-ui.css` is embedded into
`g6b_ui::setup_html` and picked up by `g6b-kernel::ui_ppm32`; both `g6b-ui` tests
and the `ui_ppm32_renders_setup_page` regression pass. Unsupported properties are
ignored by `g6b-css::parse_survey` and apply only in real browsers. Still open:
`g6b-spec` `files.assets` flag + `g6b-http` asset mount and render32 goldens in
`bios_regress`. `g6b.py check` and `bios-regress` green.

B79 (2026-09-09) — tabbed BIOS setup UI, and the three layout defects that were
blocking it. Rendering the real page at the virtio-gpu scanout geometry showed
a full-width column, table cells stacked one per line, and tabs that could only
ever be coloured words. All three were `g6b-css` gaps, fixed against the
`kernel-spec/goosie` `internal/renderer/layout.go` algorithms (rewritten, not
ported) and documented in `architecture/RENDER-VALIDATION.md` §8:
(1) `max-width`/`min-width` clamp the used width and CSS 2.1 §10.3.3 solves the
`auto` horizontal margins, so `margin: 0 auto` centres;
(2) the inline formatting context was split — `inline_children` appends into the
caller's run instead of recursing into `children_layout`, whose trailing
`flush_items` used to end the line after **every** inline element, which is why
`<th>A</th><th>B</th>` stacked; `is_block_for` also honours `display`;
(3) automatic table layout (`table_columns` max-content measurement +
`distribute`, `row_layout` two-pass with a shared row height) and
`display: inline-block` as an atomic inline that keeps its own background,
border, padding and radius. No colspan/rowspan/`table-layout: fixed`/border
collapse.
UI: `g6b_ui::setup_html` now emits a tab strip (`role="tablist"`, per-tab
`role="tab"`/`tabindex`/`aria-selected`, `.bios-tab`/`.bios-tab-active`) directly
under the banner, a status bar beneath it, panelled sections and a keyboard hint
footer; the chrome CSS lives in `setup_html` because `g6b-css` matches only
element/`#id`/`.class` selectors, while `browser-ui/src/App.svelte` keeps only
browser-side effects (hover, focus ring, zebra rows, scanline wash). New CLI
`g6b display-proxy-32` and `g6b ui-ppm32`, `g6b_kernel::proxy_ppm32` +
`Proxy::to_ppm32` (GPU surface renders at the scanout geometry instead of
upscaling the 640x480 plane), and `tools/ppm2png.py` as a stdlib-only viewing aid.
Real bug found in the harness: `tools/bios_regress.py` decoded BIOS stdout with
the Windows locale codepage, so the first non-cp1252 UTF-8 byte in the new
keyboard hint killed six cases with a `UnicodeDecodeError`; it now decodes
`utf-8` explicitly. `g6b.py check` and `bios-regress` green.

B80 (2026-09-10) - the generated libwasm cell now builds the real setup tree and
fills it from BoardSpec JSON, and the guest engine was corrected to accept what
LDC actually emits. Four defects, in the order they surfaced:
(1) `compiler/parse.ts` pushed every non-self-closing element onto its parent
*and* onto the stack, so each node was emitted twice and every close re-emitted
the whole subtree - `App.svelte`'s 81-node chrome lowered to 1,020 `createElement`
calls. Only the pop appends now.
(2) `compiler/print-d.ts` emitted bare `setProperty`/`appendChild`; they are
qualified through `libwasm.dom` and the startup verifier's `Element` double in
`compiler/wasm-cell.ts` grew the attribute/property methods `_start` actually
calls.
(3) `printReady` now keeps every fetch handle and, behind
`libwasm_await_supported()`, awaits `/bios/menu/<id>`, parses the response with
`parseJSON!ThreadMemAllocator` (fast-wasm takes the allocator as its first
template argument) and appends label/value/access rows into the matching
`menu-<id>-body`. Data retrieval stays JSON/text only; Svelte still owns the HTML.
(4) `g6b-wasm` refused the resulting artifact twice over. `0xc0..=0xc4` - the
sign-extension proposal, which LDC 1.43 emits for D `byte`/`short` casts - is now
decoded, validated and interpreted as a unary conversion (`i32.extend8_s` etc.),
with `0xc5` still rejected. `MAX_FUNCTIONS` 256 -> 1,024 and `MAX_LOCALS`
256 -> 4,096, because the real cell declares 942 functions; module bytes, memory
pages, operand stack, control depth, instruction count and fuel are untouched, so
the byte/memory/time envelope is unchanged. `architecture/WASM.md` records both.
The shipped artifact is `via=dub artifact=fresh verified asyncified LDC artifact
(wasm EH + asyncify)`; a new `compile.test.ts` case instantiates it through the
real host with a mock `/bios/` fetch and asserts the injected rows are present.
`bun test` 97 pass / 2 skip, `g6b.py check` and `bios-regress` green.

B81 (2026-09) - the libwasm LDC cell is now the source for the host CSS
scanout path. `g6b-kernel::KernelHost` was already able to run `_start` against
a fresh mount under `#libwasm-root`; this pass added `dom_to_html` (with hidden
skip, text/attribute escaping, void-tag and style/script handling), immutable
`find_node_by_id`/`first_descendant_by_name`, and `renderable_setup_html`.
`ui_ppm`, `ui_ppm_output`, `ui_ppm32`, `ui_ppm32_output` and `ui_ppm32_output_at`
now: (1) run `BrowserSession` when the libwasm lane is live, (2) extract the
libwasm `<main>` from `#libwasm-spa`, and (3) wrap it in a self-contained
`<html><head><style>` document so the CSS raster paints the Svelte-built tree
without duplicating the static `#bios-ui` shell. The old debug
`probe_libwasm_import_types` test was removed, Clippy warnings in the libwasm
host were fixed, and `python tools/g6b.py check` stays green (independence, Bun
tests/build, fmt, strict Clippy, workspace tests, 13/13 bios-regress cases
including `dom_js_ui_boot`). Real QEMU screendump is the next verification step
and depends on the separate `g6lc_qemu` build.

**B82 (2026-09)** — cut misleading UI lanes (web-engine PR 1). Host
`BrowserSession` no longer falls back to the MVP encoder wasm when the LDC
cell fails or is absent: `kernel.ui=svelte-d` requires the libwasm artifact
and `_start` errors are session failures (`BROWSER-ERROR`), not a second
module. Hit boxes and `ui_ppm*` serialize the **live** Svelte tree
(`live_render_html`). `/ui/ui.wasm` (host HTTP and guest `__ui_wasm`) is the
LDC cell when live. `setProperty(..., "style")` writes the same style
attribute as `element.style`. `WasmJit` / `WasmStart` remain the VGA glyph
face (MVP `start_ops`); they are documented as not the web engine.
`LIBWASM-ABI.md` B70 now names the real hole (persistent instance, live CSS,
frame present) instead of claiming callback execution is pending.

**B83 (2026-09)** — Svelte `fetch()` and `<img src>` through the D cell and
`/ui` file server. `g6b_fetch` (print-d) already emits `env.fetch`; the kernel
host now serves local `/ui/…` files from the same router as `/bios/…` menu
JSON. `setProperty("src")` is allowed for `/ui/*.svg|png|jpg|ico` (remote /
`javascript:` refused). `HttpFiles.assets` mounts `fixtures/ui-assets/g6lc.svg`
as `/ui/g6lc.svg`. `ui_ppm32` loads those files into the CSS `AssetMap` so
render32 paints `<img>`. GLES2 listing documents `u_dom` as the wasm-mutated
Canvas32 (`composite_ppm32`). App.svelte carries `#bios-mark`. The LDC cell
picks the img up on the next `G6B_DUB_WASM=1` rebuild; host HTTP and CSS
assets do not wait on that.

**B84 (2026-09)** — g6b-kernel is the wrong place to hook libwasm types.
`libwasm_global` no longer returns 0 with a "kernel cannot host window"
comment; the UI-thread `Host` interns `window` / `document` / `console`.
`KernelPort` (`g6b-kernel::RouterPort`) is the only kernel I/O the wasm
cell may call. `Host::get_root` / `add_css` match svelte-engine `spa.ts`.
goosie `:hover` is live (`data-hover` + `g6b-css`). `BrowserSession::tick`
presents GLES2 `u_dom` when the DOM is dirty. Handle 2 is still the first
`createElement` until the LDC cell's `getRoot()` is rebuilt.

**B85 (2026-09)** — architecture names the interactive UI as a browser that
loads the svelte-d LDC cell (`WasmUi`) on a UI thread and presents goosie
Canvas32 through GLES2 `u_dom` onto virtio-gpu / HDMI / host-GL. The cell is
not a kernel type and not guest `WasmStart`. `BrowserSession` keeps one
persistent instance (module, object table, interned window/document,
`JsExports`) so live DOM mutation and JS exports survive `tick` and pointer
dispatch. Tab clicks restyle `bios-tab-active` on the live tree.

**B86 (2026-09)** — `WasmUi::call` / `call_listener` re-enter the persistent
cell without empty KernelHost reconstruct. Interned `Event` objects carry
`type`/`target`/`detail`/`clientX`/`clientY`/`cancelable`/`defaultPrevented`.
`preventDefault` on that object skips the Rust tab default action. D
`getRoot` is now an `env.getRoot` host import (svelte-engine
`querySelector('#root')`); the shipped LDC blob still inlines `return 1`
until `G6B_DUB_WASM=1`.

**B87 (2026-09)** — cell-owned tab/refresh/JSON. `App.svelte` `on:click`
lowers through print-d to `g6b_listen(id, "click")` (listener 0). The host
maps that to `Listener::Cell`, which `preventDefault`s and runs `select_menu`
+ `/bios/menu/{id}` fetch (or `refresh()`). Rust `select_menu` is the default
action only. The shipped LDC cell has not emitted `g6b_listen` yet;
`bind_cell_clicks` covers tabs and `#refresh` until `G6B_DUB_WASM=1`.

**B88 (2026-09)** — live CSS. `g6b-css::Engine::paint(&Node)` rasters the
Svelte tree without HTML serialize/parse. `DirtyFlag` is Style/Layout/Paint
on `g6b-dom::Node`; skip-if-clean walks `dirty_union`. Goldens:
`ui_tab_cpu_ppm32`, `ui_tab_hover_ppm32`, `ui_tick_skips_clean_frame`.
Track-B 4bpp `ui_ppm` still uses `live_render_html`. Dirty tiles landed in B90.

**B89 (2026-09)** — UI hart + timers. When `kernel.tasking` is on,
`Role::Ui` / `Job::Ui` on `ui_hart` is the `BrowserSession::tick` body.
`TimerHeap` implements B66 `setTimeout`/`setInterval`/`clear*` and a
bounded `requestAnimationFrame` (ids start at 1, never 0). Due callbacks
re-enter through `WasmUi::call`. BoardSpec `kernel.proxy.fps` admits 100
and 144 (auto picks 144 when `detected_hz >= 144`). Skip-if-clean stays
the present budget.

**B90 (2026-09)** — Dirty-tile present. `Engine` records a pixel bbox
(`DirtyRegion::from_diff`) and splits it into 64 px tiles (collapse to one
rect past 64 tiles). `tick` paints then `present_scanout`: blit those tiles
of Canvas32 into modelled `__scan_fb` (X8R8G8B8, flatten over white) and
emit `TRANSFER_TO_HOST_2D` + `RESOURCE_FLUSH` of just those rects
(`SCAN-TRANSFER` / `SCAN-FLUSH`). Skip-if-clean is `SCAN-SKIP` / no
TRANSFER. GLES2 listing documents `glTexSubImage2D` per tile. Check
evidence is host-modelled `scanout_ppm` vs `ui_ppm32` (`ui_scan_fb_matches_css_ppm32`,
`ui_tab_cpu_dirties_scanout_tiles`). QMP Main→CPU→Memory tab shots stay
`tools/qemu_tab_shots.sh` on remote g6q (2D `virtio-gpu-device`; WSL2 has
no DRM). Guest `VioPaint` is still full-frame unless `__ui_cap` WEB_PRESENT.

**B91 (2026-09)** — Guest dirty-tile present + compact persist. `__ui_cap`
(`G6CP`) holds a live node count and ≤64 dirty rects. When the exec model
packs `GuestWebPresent` (BrowserSession Canvas32 + tiles), `VioScan` skips
the green band fill and `VioPaint` TRANSFERs those tiles then consumes
them (`VIRTIO-PAINT-SKIP` on a later `Ui`). VGA `start_ops` / 48-row
`__ui_dom` / glyph `FbExpandSel` stay the text face. The LDC cell is not
JIT’d in S-mode; do not grow `start_ops` to `Object_Call`.

## Remaining web-engine schedule (plan-endpoint)

Do these on `E:\cva6/g6lc_bios` in this order. Do not grow guest `start_ops`
into `Object_Call`. B12b–B13 and B54 are a different axis.

| Next | Depends | Work |
|---|---|---|
| **B86** | B85 | **landed** — `WasmUi::call` / `call_listener`; Event `clientX`/`clientY`/`preventDefault`; D `getRoot` is a host import. Shipped cell still `return 1` until `G6B_DUB_WASM=1` |
| **B87** | B86 | **landed** — `on:click` → `g6b_listen`; host `Listener::Cell`; Rust `select_menu` is default action. Shipped cell uses host bind until `G6B_DUB_WASM=1` |
| **B88** | B86 | **landed** — `g6b-css` `Engine::paint(&Node)`; DirtyFlag Style/Layout/Paint; goldens `ui_tab_cpu_ppm32` / `ui_tab_hover_ppm32` / `ui_tick_skips_clean_frame`; 32-bit session path no longer serializes HTML |
| **B89** | B86 | **landed** — `Role::Ui` on `ui_hart` runs `tick`; `TimerHeap` for `setTimeout`/`setInterval`/rAF (id > 0); BoardSpec `fps` 100/144; skip-if-clean |
| **B90** | B87–B89 | **landed** — dirty-tile GLES2 `u_dom` + virtio-gpu `TRANSFER_TO_HOST_2D`/`FLUSH`; host blit of Canvas32 into modelled `__scan_fb`; check vs `ui_ppm32`. QMP tab shots: `qemu_tab_shots.sh` / remote g6q |
| **B91** | B90 | **landed** — `__ui_cap` compact persist + dirty-tile `VioPaint` of host-packed Canvas32. `start_ops` not grown. |
| **B91b** | B91 | **landed** — exec-model S-mode stand-in: `guest_cell_scanout` runs the LDC cell on `KernelHost` (same Host imports as `BrowserSession`), `smoke_cell` packs `__ui_cap`. Not a RISC-V interpreter of the cell; `start_ops` unchanged. |
| **B92** | B88–B89 | **later** — BIOS windowing, Firefox-like tabs, iframe sessions; URL is a local app path (`app:files`, `/ui/…`) or remote `http(s):` (adapter/mailbox, never `-netdev`). New session re-populates JS (no mix with the shell cell / HolyC). Native KernelPort only for the shell and registered local apps; local paths may later elevate via a HolyC-derived BIOS chrome prompt (`once`/`page`/`session`/`origin`/`persistent`). Session may bind a UUID store instance (`drop_on_close` for ephemeral memory). [`architecture/plan-iframe.md`](architecture/plan-iframe.md) [`architecture/g6b-store-instances.md`](architecture/g6b-store-instances.md) |
| **S0** | — | **landed (PR1)** — `etcimon/pglite` submodule on `main` + npm dist pin; UUID-led store instances, purpose-based BIOS UI, deletable memory, USB key import/export (crate in later PRs). |
