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
| **B53** Guest runtime JS/DOM integration, input/GPU scanout, executable JIT installation/trampolines/cache sync | host prerequisites advanced; bounded guest `_start`→`__ui_dom`→`DomPaint` lane + `Ui` re-dump + executed-plane PPM + `VioProbe`/`VioInit`/`VioScan` virtio-gpu path **verified on real QEMU 8.2 + OpenSBI 1.5** (`fixtures/g6lc64-qemu.json`, QMP screendump shows the guest-painted band **and the 1920×1080 high-res proxy scanout** — `FbExpand` scale-blit, centered `to_ppm` geometry); uncore `display`-engine seam (`DispPaint` + `G6FB` simplefb handoff, `fixtures/g6lc64-hdmi.json`, exec-modelled) + `qemu-args` `--vnc`/`--no-gl`/`virtio-gpu-gl-device` under `proxy.gl` landed; **virtio-input eventq (`InpInit`/`InpDrain`/`InpPoll` + `virtio-keyboard-device` argv) and WFI-driven ctrlq/eventq waits landed (exec-model verified)**; **absent-device tolerance for stock QEMU virt landed** (`trap_fault` recoverable probe windows for UART1/mbox — `g6lc64-virt.json` boots stock `virt`); runtime gates open |
| **B54** Real persistent settings/flash backends and authenticated production TLS; remove canned mutation acknowledgements only with backend implementation | open |
| **B55** Mutable per-run WASM memory (load/store/size/grow) + extended i32 lowering (bitwise/shifts/rotates/ordering) via `g6b-asm` | landed (host; RV32/RV64 differential machine-word tests) |
| **B56** Bounded nonblocking JS async: `await` fetch tokens, throw/catch, cancellation, stale/duplicate rejection, per-task/tick budgets | landed (host) |
| **B57** Transactional DOM (`DomTransaction` + native-browser DOM-kernel host); explicit libwasm ABI mount with startup verification | landed (host) |
| **B58** Cooperative RV32/RV64 task-switch IR, bounded scheduler/task services, DedicatedWorker compute protocol shared by browser/HolyC menus | landed (host IR + services; guest dispatch open) |
| **B59** LDC 1.43 + vendored `runtime-v1.43.0` libwasm cell: DUB workspace, provenance/ABI/startup-gated publication, Asyncify fail-closed, D particle exports + WebGL backdrop | landed (component-shell artifact; full Svelte tree open) |

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
