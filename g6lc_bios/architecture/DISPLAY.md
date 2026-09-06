# Display-proxy — low-res ZealOS plane, high-res scanout

TempleOS/ZealOS Gr is **intent**: 640×480×16, 8×8 font. LibreCore never copies
VGA ports. The **display-proxy** keeps that low-res plane as the ZealOS
interface and scales it onto a generic high-DPI, high-resolution adapter.

```
ZealOS Gr 640×480×16  ──nearest scale + letterbox──►  HDMI / DisplayPort / host-GL
DOM + JS BIOS UI      ──OpenGL-ES2 adapter──────────►  compositor (same scanout)
                              ▲
                     fps = 30 | 60 | 120
                     from BoardSpec, or auto from EDID/DPCD
```

| Layer | Role |
|---|---|
| Low-res proxy | `g6b-gr::Frame` — kernel basics, HolyC `SysGrInit`, UART cells |
| High-res adapter | `g6b-gr::proxy` — DPI, mode, refresh; PPM on host |
| OpenGL adapter | `g6b-gr::gl` — GLES2 listing + software composite; not libGL, not Chromium |
| Optional accel | BoardSpec `kernel.proxy.accel`: `off` (default) \| `auto` \| `rvv` \| `ai-island`. RVV needs `isa.v` live + xlen=64 (`G6LC_PROXY_ACCEL_RVV`). AI-island tiles the blit; GEMM stays at `0x40000000` and is **not** the GR plane (`G6LC_PROXY_ACCEL_AI`). |
| Link | BoardSpec `kernel.proxy.link`: `uart` \| `virtio-gpu` \| `hdmi` \| `displayport` \| `host-gl` |

Refresh: if `fps` is 30/60/120 it is pinned; if `fps=0` (auto) pick 120 when
detected ≥ 90 Hz, 60 when ≥ 45 Hz, else 30. HDMI/DP detection is an uncore
EDID/DPCD ask (`architecture/uncore/hdmi-display.md`); the BIOS records the
number in `detected_hz` rather than probing analog VGA.

Scale (`kernel.proxy.scale_mode`):

| Mode | Blit |
|---|---|
| `fit` (default) | integer `min(sx,sy)` + letterbox |
| `fill` | nearest stretch to the high-res adapter (4K/1440p/1080p) |
| `dpi` | `max(1, dpi/96)` capped by `fit` |

High-res windows: 640×480 through 7680×4320. QEMU virt attaches
`virtio-gpu-device` as the scanout stand-in (still `-nographic`, no `-netdev`).
ASM IR `Purpose::DisplayProxy` emits `proxy_geom` **machine words** in the ELF
(low/high/dpi/fps/scale/accel) and a `GrInit` that writes a `GR16` header plus a 4bpp
640×480 plane at `__gr_plane` (BSS after per-hart stacks; first scanline filled
with colour 1; 8×8 `G6LC` blit at (0,8) using the same bits as `g6b-gr`). When
`kernel.proxy.gl`, KStart `jal ProxyScale` before park (scalar nearest, RVV
`vsetvli`, or ai-island tiles — GEMM MMIO stays `0x40000000`). QEMU
`virtio-gpu-device` / host-GL scale that plane. Not assembler-only `.word`
directives, not VGA.

## Executed UI versus guest bring-up (B51)

`g6b-kernel::boot`, `gr_ppm` and `proxy_ppm` consume an executed
`BrowserSession` DOM: checked HTML, gated AOT JS, bounded WASM when enabled,
router refresh and initial-menu selection precede painting. The proxy status
strip is read from the actual `status` node; it is not a hard-coded success
label. Render failures show `BROWSER-ERROR`. Hidden subtrees and script/style
content are omitted from UART/Gr output. `kernel.gr` geometry and existing
proxy DPI/scale/refresh/acceleration settings remain the display controls.

This fixes the former PPM path that painted HTML before JS/WASM. It does not
turn the guest's boot scanline/font demonstration into a complete interactive
virtio-gpu driver or prove display timing on RTL. Guest event routing and
framebuffer scanout integration remain separate work.

## Native-browser particle presentation (B53 prerequisite)

`App.svelte` supplies extracted static CSS for translucent BIOS panels.
`printFxD` generates fixed-size particle physics and bouncing GSys LibreCore
wordmark coordinates compiled by LDC 1.43 into the optional libwasm module.
The browser reads the float32 buffers after each bounded step and renders a
cyan/violet spell-like vortex, point-sprite sparks and a locally generated
text wordmark texture with WebGL (OpenGL ES). This is separate from the
software Gr/PPM renderer and is not a guest OpenGL driver.

The existing `kernel.ui=svelte-d`, WASM/file/JS and proxy-enable/GL gates
control availability. `proxy.high_w/high_h`, DPI and resolved 30/60/120 Hz
refresh are emitted into HTML. Backing resolution is capped by configured
geometry, the GL viewport limits and 8,294,400 pixels; effective DPR is capped
by configured DPI and 4. No GPU readback or synchronous network operation is
performed in a frame. The simulation step clamps elapsed time to 50 ms, with
256 particles and a checked float-state buffer. Reduced motion renders one
static frame, hidden tabs stop scheduling, and the user can pause/resume.
Context loss or an invalid state stops the effect, frees resources and restores
opaque readable menus. WebGL context creation can use a software implementation;
hardware acceleration is not inferred from API availability.

## Acceptance ladder toward a QEMU-visible WASM interface

1. **Compiler/ABI:** isolated LDC 1.43 DUB build, runtime carry present,
   provenance and import/export checks, actual `_start` and particle stepping.
2. **Host kernel/served browser:** exact generated WASM bytes through the kernel
   router; BoardSpec/HolyC menu parity; rejected requests and trapping optional
   modules preserve setup; native WebGL scheduling/cleanup tests. Browser visual
   inspection is separate from mocked GL API tests.
3. **Guest execution:** persistent WASM memory/globals/tables, i64/floating-point,
   indirect calls and EH/continuation semantics; port required allocation/clock/
   transport primitives to the S-mode runtime. Current numeric JIT and Rust
   scheduler tests do not satisfy this gate. A bounded first step landed:
   `g6b-wasm::jit::start_ops` lowers the straight-line `_start`
   (`i32.const` + `env` DOM/fetch/log imports) onto the payload `WasmStart`
   anchor, and `g6b-asm::dom` executes it against a 48-row `__ui_dom` store
   (`DOM| ` serial + 4bpp glyph paint into `__gr_plane`) — verified by host
   `g6b-elf` smoke (`dom_rows`, `dom_pix0`), not a QEMU run.
4. **Guest display/input:** enumerate and drive virtio-gpu resources, transfer,
   flush and scanout; route input into a bounded normal-context event queue;
   advance/resume scripts independently of refresh. `DomPaint` writes into the
   existing `GR16` boot plane (`__gr_plane`, `DOM_Y0` rows), which is still not
   a connected UI scanout — the plane has no virtio-gpu backing yet and the
   `virtio-gpu-device` argv alone is not evidence. Progress on stage 4: the
   payload runs `VioProbe` (Purpose `virtio`) — a bounded read-only scan of
   the QEMU-virt virtio-mmio window (`0x10001000 + 0x1000*i`, 8 slots; QEMU
   instantiates all 8 transports at a 0x1000 stride and attaches `-device`
   backends to the last free bus — observed slot 7) for
   MagicValue `virt` + DeviceID 16, printing `VIRTIO-GPU <slot>` or
   `VIRTIO-GPU-NONE` — followed by `VioInit`: the virtio 1.x handshake
   (reset, ACK|DRIVER, `VIRTIO_F_VERSION_1`, FEATURES_OK readback,
   DRIVER_OK), controlq (queue 0) with desc/avail/used rings in `__vio` BSS,
   and one real `GET_DISPLAY_INFO` descriptor-chain round-trip —
   `VIRTIO-INFO` on `RESP_OK_DISPLAY_INFO` (`0x1101`), else
   `VIRTIO-GPU-FAIL`. `VioScan` then runs the pixel command sequence through
   the shared `VioCmd` submit-one routine: `RESOURCE_CREATE_2D` (resource 1,
   `B8G8R8X8`, the **high-res** proxy target `high_w×high_h`) →
   `RESOURCE_ATTACH_BACKING` (`__scan_fb`, `high_w*high_h*4`) →
   `SET_SCANOUT` (scanout 0, the full high-res rect) → a guest-filled green
   band (`0x0000AA00`, first 64 rows) → `TRANSFER_TO_HOST_2D` →
   `RESOURCE_FLUSH`, printing `VIRTIO-SCAN` when every response is
   `RESP_OK_NODATA` (`0x1100`).
   **Verified on real QEMU 8.2 + OpenSBI 1.5** (`fixtures/g6lc64-qemu.json`,
   `qemu-system-riscv64 -M virt -nographic -global
   virtio-mmio.force-legacy=false -device virtio-gpu-device`): serial shows
   `VIRTIO-GPU 7` → `VIRTIO-GPU-OK` → `VIRTIO-INFO` → `VIRTIO-SCAN`, and a QMP
   `screendump` PPM shows the 64-row green band (`0x00AA00`) — actual guest
   pixel→scanout evidence, not a host artifact. Two QEMU-virt realities the
   code now encodes: (a) the default `virtio-mmio` transports are legacy
   (Version=1) which silently ignores the v2 queue registers — `qemu-args`
   therefore emits `-global virtio-mmio.force-legacy=false`; (b) QEMU
   services `QueueNotify` on an iothread, so `VIO_POLL_MAX` is `1<<22`, not a
   few thousand iterations.
   The host executor models the same slot-0 device under
   `BoardSpec::wants_virtio_gpu` (shared with argv emission): status/feature/
   queue registers, notify doorbell, chain walk, response write, used-elem
   publish, ISR, and now resource/scanout state — attach validates the
   backing pointer/len against `__vio_fb`, set_scanout latches the bound
   rectangle, transfer copies backing→device surface at the given offset,
   flush counts (`Smoke::vio_flushes`, `vio_scanout`, `vio_fb*`), and each
   used publish asserts InterruptStatus bit 0 — the guest reads it and
   writes it back to InterruptACK after every command (`Smoke::vio_irqs`
   counts the assertions, 6 per boot). Both present and absent
   (`exec::run_module_no_gpu`) paths are exercised.
   `FbExpand` (emitted when a scanout backend ∧ a Gr/proxy plane exists)
   palette-expands the 4bpp `__gr_plane` into the X8R8G8B8 `__scan_fb`
   surface (inline `vio_pal` table, same values as `g6b-gr::PALETTE`) with
   the **display-proxy scale semantics** — `fit`/`dpi` use the resolved
   uniform `scale` in a *centered* letterbox (same `ox/oy` math as
   `Proxy::to_ppm`), `fill` does a bounded per-axis integer stretch — all
   gen-time constants, branch-free bounded nest. `VioPaint` then submits a
   full-frame `TRANSFER_TO_HOST_2D` + `RESOURCE_FLUSH` of the high-res
   surface; it runs after the boot painters (`DomPaint` inside `WasmUi`, or
   `GrInit`) and again on the UART `Ui` re-dump (`VIRTIO-PAINT` /
   `VIRTIO-PAINT-FAIL`; silent bail when no device bound). **QEMU-verified**
   at the real high-res geometry: `screendump` is `P6 1920×1080` with the
   640×480 DOM/Gr plane ×2 (dpi=192 → scale 2) centered at (320,60) — DOM
   glyphs and the boot band land exactly where `to_ppm`'s content window
   puts them; letterboxes black. `VIO_FB_MAX` is 16 MiB so the 8.3 MB
   1080p surface fits. Completion is
   interrupt-driven too: QEMU virt maps virtio-mmio slot i to PLIC irq
   `1+i` (GPU slot 7 → irq 8); `PlicInit` gives every enabled source a
   nonzero priority (QEMU resets them to 0) and enables irqs 1..=8 +
   UART(10), and `trap_vio` claims the used-buffer irq, acks the device
   ISR, and bumps `__vio+VIO_IRQF_OFF` — QEMU `xp` reads `irqf == 8`
   (6 scan + 2 paint completions). `VioCmd`'s completion wait and `VioInit`'s
   used-ring wait are **WFI-driven** when `uncore.plic` armed SEIE: a poll
   miss sleeps until the used-buffer irq (or any enabled source — the
   iteration bound still caps wake-check cycles and the periodic timer keeps
   wakes coming, so a silent device degrades to the bounded timeout).
   **virtio-input landed**: `InpInit` probes the slots for DeviceID 18
   (`virtio-keyboard-device` in `qemu-args` under `wants_virtio_input()`),
   handshakes, sets up the eventq (queue 0) with 8 posted
   `virtio_input_event` buffers in `__vio+INP_*` and notifies; `trap_inp`
   (PLIC irq `1+input slot`) acks the ISR and `InpDrain` pushes each
   `EV_KEY` as `(code<<8)|value` into the bounded `INP_KQ` queue (serial
   `INP`) and re-posts the buffer; UART `Keys`/`K` dumps the queue via
   `InpPoll` (`KEY <hex>`) and `DomKey` (`kernel.wasm.jit`) mirrors the
   newest entry into the `inp.last` DOM row — a keypress dirty-marks the
   row like a browser input event; the repaint stays on the explicit
   `Ui`/refresh path rather than flushing a frame per keypress.
   **QEMU 8.2 verified** on `g6lc64-virt.json`: monitor `sendkey a` /
   `sendkey b` each deliver press+release → `INP` ×4, and a serial `Keys`
   reads `KEY 00001e01` / `KEY 00001e00` / `KEY 00003001` / `KEY 00003000`
   (Linux codes 30/48, value 1/0) — the exact exec-model values on real
   QEMU. The following `Ui` repaint echoes `DOM| key 00003000` — the
   `inp.last` row holds the last event and is painted to the virtio-gpu
   scanout (`VIRTIO-PAINT`), input→DOM→display verified end to end on the
   emulator.
   **Absent-device tolerance**: unmapped MMIO faults (scause 5/7) inside the
   UART1/mbox probe windows are recoverable — `trap_fault` reads `stval`,
   marks the `__uart_line` absent flag and resumes at `sepc+4`, so
   `g6lc64-virt.json` boots on stock `virt` (no g6lc-bios mailbox, no second
   ns16550) instead of parking on `TRAP`; `MboxInit` also readback-checks the
   doorbell so a mapped-but-foreign region (QEMU `fw_cfg` at `0x10100000`)
   reports `MBOX-NONE` rather than absorbing the magic write. The `uart1`
   probe runs before `PlicInit` arms the irq, and `trap_mbox`/`uart1_drain`
   gate on the absent flags — a trap-context MMIO read on a missing device
   would take a nested fault and clobber `sepc`. `exec::run_module_bare` is
   the stock-QEMU shape (no mbox, no UART1) and
   `stock_qemu_absent_devices_recover` asserts the `MBOX-NONE`/`UART1-NONE`
   path with the GPU/input lanes still live.
   Host-side inspection exists: `exec::Smoke::gr_frame` carries the executed
   plane and `g6b smoke --out f.ppm` renders it via `g6b-gr::plane_to_ppm`;
   `g6b smoke --out-vio f.ppm` renders the device-side `vio_fb` scanout
   surface via `g6b-gr::x8r8_to_ppm`/`g6b_kernel::scanout_ppm` — both are
   host-executed artifacts, not QEMU scanout captures.
5. **Acceptance:** QEMU scanout evidence now exists for the guest-painted
   band **and** for the DOM/Gr plane — `VioPaint` transfers the
   palette-expanded `__gr_plane` (which `DomPaint` mutates from the WASM
   lane's `__ui_dom` rows) to the virtio-gpu scanout; the QMP `screendump`
   histogram matches the host-modelled framebuffer exactly. Remaining: menu
   input, pending/rejected await and background frames concurrently —
   record framebuffer/event evidence, not just UART markers. Later hardware
   timing/PMA/PMP/cache/IRQ validation remains distinct from QEMU evidence.

Stage 5 remains open; stage 3 (virtio-input) is now **QEMU-verified**
(`sendkey` → `INP` → `KEY`/`DOM| key` on `g6lc64-virt.json`, stock virt +
`virtio-keyboard-device`), and stage 4 is QEMU-verified for probe → handshake →
controlq → resource/scanout/flush **at the high-res proxy geometry**
(1920×1080 scanout, centered ×2 content; QMP `screendump` P6 with nonzero
guest pixels). `g6lc64-virt.json` boots clean on stock QEMU virt —
`MBOX-NONE`/`UART1-NONE` are reported, not parked. Do
not remove `-nographic` or claim a screenshot by changing argv alone.

### Output backends — QEMU and the uncore port

The scanout surface is backend-agnostic: `__scan_fb` is a linear
X8R8G8B8 high-res buffer; `FbExpand` is the only blit; the transport is
selected by BoardSpec:

- **QEMU / virtio-mmio** — `wants_virtio_gpu()`: `VioScan`+`VioPaint` drive
  the ctrlq commands (verified on `qemu-system-riscv64 -M virt`).
- **Uncore HDMI/DisplayPort** — a `peripherals[]` entry with
  `class:"display"` declares the native engine and *disables* the virtio
  transport for proxy links (`wants_virtio_gpu` yields). `DispPaint` expands
  the plane into `__scan_fb`, programs the engine register window
  (`MAGIC/FB/W/H/STRIDE/FORMAT/COMMIT/STATUS`), and writes the `G6FB`
  handoff descriptor at `__vio+0x400` — the `simple-framebuffer`-shaped
  surface a Linux `simplefb`/`simpledrm` node inherits, so the same scanout
  serves the BIOS **and** the OS. Contract and evidence model:
  `architecture/uncore/hdmi-display.md`; fixture `fixtures/g6lc64-hdmi.json`
  (exec-model verified: `DISP-OK`, `disp_committed`, descriptor
  `1920×1080` x8r8g8b8).
- **VNC** — `g6b qemu-args --vnc N` appends `-vnc 127.0.0.1:N`: a host-side
  frontend on the QEMU console that shows the BIOS scanout and any later
  guest identically (BIOS and Linux share the QEMU console → one VNC serves
  both). No guest change.
- **Host GL** — `proxy.gl:true` emits `virtio-gpu-gl-device` +
  `-display egl-headless,gl=on` (virgl). **Requires a host DRM render node**
  (`/dev/dri/renderD*`, readable EGL/GLES driver): `egl-headless` is
  surfaceless EGL, *not* software GL — on a host without a render node
  (containers, WSL without GPU passthrough, headless servers) QEMU refuses
  the device (`egl: no drm render node available` — confirmed on WSL2 QEMU
  8.2.2, whose d3d12/WSLg driver is not a DRM render node). Use
  `qemu-args --no-gl` for the 2D
  `virtio-gpu-device` fallback. The guest command stream is identical either
  way — virgl only accelerates host-side composite; the BIOS does not emit
  3D commands. `GL-ADAPTER`/ProxyScale RVV is a *guest-side* scale accel
  listing, not QEMU virgl — do not equate them.

Conformity: HDMI TMDS / DisplayPort PHY stay in `corev_apu` / board (REQUIREMENTS).
This package emits the register contract, timing metadata and the scaled
framebuffer, not a TMDS encoder. QEMU still uses `-nographic` plus
`virtio-gpu-device` (or `virtio-gpu-gl-device` under `proxy.gl`) with
`-global virtio-mmio.force-legacy=false` (the virt machine's mmio transports
default to the legacy v1 interface, which ignores the v2 queue registers).
No `-netdev`.
