# Display-proxy — low-res ZealOS plane, high-res scanout

TempleOS/ZealOS Gr is **intent**: 640×480×16, 8×8 font. LibreCore never copies
VGA ports. The **display-proxy** keeps that low-res plane as the ZealOS
interface and scales it onto a generic high-DPI, high-resolution adapter.

```
ZealOS Gr 640×480×16  ──nearest scale + letterbox──►  HDMI / DisplayPort / host-GL
DOM + JS BIOS UI      ──OpenGL-ES2 adapter──────────►  compositor (same scanout)
                              ▲
                     fps = 30 | 60 | 100 | 120 | 144
                     from BoardSpec, or auto from EDID/DPCD
```

| Layer | Role |
|---|---|
| Low-res proxy | `g6b-gr::Frame` — kernel basics, HolyC `SysGrInit`, UART cells |
| High-res adapter | `g6b-gr::proxy` — DPI, mode, refresh; PPM on host |
| OpenGL adapter | `g6b-gr::gl` — GLES2 listing + software composite; not libGL, not Chromium |
| Optional accel | BoardSpec `kernel.proxy.accel`: `off` (default) \| `auto` \| `rvv` \| `ai-island`. RVV needs `isa.v` live + xlen=64 (`G6LC_PROXY_ACCEL_RVV`). AI-island tiles the blit; GEMM stays at `0x40000000` and is **not** the GR plane (`G6LC_PROXY_ACCEL_AI`). |
| Link | BoardSpec `kernel.proxy.link`: `uart` \| `virtio-gpu` \| `hdmi` \| `displayport` \| `host-gl` |

Refresh: if `fps` is 30/60/100/120/144 it is pinned; if `fps=0` (auto) pick
144 when detected ≥ 144 Hz, 120 when ≥ 90 Hz, 60 when ≥ 45 Hz, else 30.
HDMI/DP detection is an uncore EDID/DPCD ask
(`architecture/uncore/hdmi-display.md`); the BIOS records the number in
`detected_hz` rather than probing analog VGA.

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

## Display outputs and surface selection

Before B75 the low-res plane was the **only** scanout source: `FbExpand`
expanded the 4bpp `__gr_plane` into `__scan_fb` and every backend committed
that, so the upscaled ZealOS-intent plane *was* the HDMI/virtio-gpu picture.
There was no output arbitration at all — `wants_virtio_gpu()` /
`wants_disp_scan()` chose a transport at **generate** time.

Two orthogonal concepts now exist.

**Output** (`g6b_spec::OutputClass`) — where pixels go, in priority order:

| rung | class | gate | detection |
|---:|---|---|---|
| 3 | `pcie-linear-fb` | `pcie.scan_display` + ECAM + BAR window | class-0x03 config-space scan |
| 2 | `uncore-scanout` | `display` peripheral | `MAGIC == 'G6DS'` |
| 1 | `virtio-gpu` | `wants_virtio_gpu()` | virtio-mmio DeviceID 16 |
| 0 | `none` | always | the fallback that cannot fail |

The ladder is over **validated linear framebuffers, never over vendors**. A
PCIe display controller outranks the others only when it yields a usable
pre-initialized framebuffer; otherwise it is demoted with a diagnostic and the
next rung wins. `BoardSpec::display_outputs()` gives the declared candidate
set; presence is a boot-time fact, so the runtime `DispSel` mux does the actual
resolution.

**Surface** (`g6b_spec::Surface`) — what is rendered:

| surface | source | scaling |
|---|---|---|
| `vga` | 4bpp `__gr_plane`, 8×8 font, UART cells | proxy `fit`/`fill`/`dpi` + letterbox |
| `gpu` | **live BrowserSession DOM** at the output's own geometry (goosie Canvas32 → GLES2 `u_dom`) | none |

The GPU surface is the interactive BIOS UI: the svelte-d LDC cell mutates a
live DOM on the UI thread, `g6b-css` rasters it (truth), and `g6b-gr::gl`
composites `u_dom` onto virtio-gpu / HDMI / DisplayPort / host-GL. See
[`BROWSER-RUNTIME.md`](BROWSER-RUNTIME.md). **B90:** `BrowserSession::tick`
blits dirty 64 px tiles of that Canvas32 into modelled `__scan_fb`
(X8R8G8B8) and records `TRANSFER_TO_HOST_2D` + `RESOURCE_FLUSH` of just
those rects. Skip-if-clean is no TRANSFER. `scanout_ppm` is the host
Main→CPU→Memory evidence against `ui_ppm32`. **B91:** guest `VioPaint`
TRANSFERs `__ui_cap` dirty tiles when `WEB_PRESENT` (host-packed Canvas32);
otherwise it stays a full-frame `FbExpandSel`. QMP tab screendumps stay
`tools/qemu_tab_shots.sh` on remote g6q (2D `virtio-gpu-device`; WSL2 has
no DRM render node) — they are not part of `g6b.py check`. Guest `DispSel`
still latches the first **present** rung at boot. On the **host
BrowserSession**, live scanout starts **VGA** until `g6b-hw` probes the
catalog (PCIe linear-fb → HDMI G6DS → virtio-gpu) **and** the kernel
announces the winner (`HW-DISP-SEL`); only then does it switch to `gpu`
when `display_ready()`. After that, **the low-res plane is never
upscaled onto a GPU-class output unless explicitly asked for**.
`kernel.proxy.surface` (`vga` \| `gpu`, empty = follow the class) forces it, and
the display-proxy toggle flips it at runtime. See [`g6b-hw.md`](g6b-hw.md). Two consequences on the host path:
`Proxy::to_ppm_gpu` **refuses** a canvas whose size disagrees with the output
rather than stretching it, and `bar_h` is `0` on the GPU surface because the
status is a real DOM node rendered natively — overlaying the synthetic low-res
strip there would reintroduce the artefact the split removes.

### The toggle

`/bios/display` is the single mechanism, shared by all three lanes:

| method | registered when | body |
|---|---|---|
| `GET` | always | active output, surface, `toggle` flag, and every candidate with its priority |
| `POST` | `surface_toggle()` only | the surface the flip switches to |

- **Browser lane** — `setup_html` emits `#disp-toggle` plus a `#disp-status`
  line, but only when `surface_toggle()`. The button is
  `position:absolute; top:0; right:0` with **no positioned ancestor**, so its
  containing block is the initial one — the viewport in a browser, the canvas in
  the CSS raster — putting it in the top-right corner in both lanes without
  pushing the in-flow menus down. `BrowserSession::dispatch_pointer` finds it
  through its own CSS hit box.
- **HolyC lane** — `DisplayPrint` prints the ladder and `KernelGet`s the same
  route; `DisplayToggle` calls the `DisplaySurface(vga|gpu)` builtin, which
  POSTs through the router.
- **Kernel state** — `BrowserSession::surface` and `BrowserSession::proxy()`
  keep the DOM, the router and `g6b_gr::proxy` on one decision.

Fail-closed at both ends: an unknown surface name is refused by the builtin, and
a board with no accelerated output registers **no POST route**, so the toggle is
neither rendered nor callable and `toggle_surface()` errors.

`position:absolute` was added to `g6b-css` for this, along with `top`/`right`/
`bottom`/`left`. `relative`, `fixed` and `sticky` are **refused** by the strict
parser and **survey-dropped-and-reported** by the lenient one — the BIOS UI's own
`App.svelte` uses `position:fixed`/`relative` for particle-canvas stacking, which
is correct for a real browser and simply has no equivalent in this raster. Two
related corrections landed with it: an out-of-flow box requires an explicit
`width`/`height` (shrink-to-fit needs intrinsic sizing, and guessing would
mis-place a right-anchored box), and `DrawText::No` now actually suppresses
glyphs — it had been threaded through every layout function and never read.

### Guest side: probe, mux, surface-gated blit

The ASM IR carries the same three concepts:

| routine | purpose | output |
|---|---|---|
| `PciProbe` | bus-0/fn-0 ECAM walk for base class `0x03`; BAR0 accepted only if it is a memory BAR, nonzero, and inside `pcie.mmio` | `PCI-GPU` / `PCI-GPU-DEMOTED` / `PCI-GPU-NONE` |
| `DispSel` | walk the candidate ladder, latch the first **present** rung into `__disp` | `DISP-SEL <class><surface>` (two hex digits) |
| `FbExpandSel` | pick the blit from the latched surface | — |

`proxy_geom` gained a `proxy_outputs` table after its eight legacy words:
a `{count, default_idx, default_surface}` header then one
`{class, priority, w, h, stride, surface}` record per candidate. The legacy
offsets are unchanged, so existing readers are unaffected.

`__disp` lives at `__vio + 0x600` (`DISP_SEL_*`) and holds the resolved class,
index, surface, geometry, framebuffer and HPD state, plus the `PciProbe`
result. `DispSel` runs after every probe and before anything paints.

**The surface field is a live latch, not a probe record.** `DispSel` stores the
rung's own default, and then the face that owns the plane rewrites it:
`CliInit` stores `vga` when the container claims the screen (the 4bpp plane
magnifies through `FbExpand` — the intended scaled-text look on a high-res
output), and `AutoPick`/`Ui` store `default_surface()` when the browser face
takes over (native `FbExpand1`/`DomPaint32`). `FbExpandSel` therefore always
follows the current owner, which is also why a run-end read of
`__disp.surface` reports who owns the plane, not what `DispSel` resolved —
`DISP-SEL <class><surface>` on serial is the record of the latch itself.

**The blit is surface-gated.** `FbExpand` (upscale + letterbox) and `FbExpand1`
(scale 1, centred) are two specialisations of one generator; `FbExpandSel`
reads `__disp.surface` and calls the right one, and `VioPaint`, `DispPaint`
and `PciPaint` all go through it. That is the concrete fix for "the low-res
plane is magnified onto the GPU display": while the browser face owns the
plane on a GPU-class output the 640×480 plane is placed 1:1 at (640, 300) of
a 1920×1080 scanout instead of being blown up ×2.

**Output geometry is runtime.** `DispSel` latches the winning output's
`w`/`h`/`stride` into `__disp`, and every downstream consumer reads them there
rather than reusing the gen-time `g6b_spec_proxy` default: `FbExpand`/
`FbExpand1` compute the integer scale (`Op::Divu` for `fit`/`fill`/`dpi`,
clamped to 1..=64), the centred letterbox and the right-row pad from the latched
mode; `DomPaint32` clears `w*h` words and addresses glyph rows by the latched
stride; `VioScan` sizes CREATE_2D/TRANSFER/FLUSH from `__disp`; `DispPaint`
programs the engine registers and the `G6FB` descriptor from it. So a rung that
declares a different mode than the proxy default is honoured end-to-end without
a per-output jump table — and `VioScan`/`VioPaint`/`DispPaint`/`PciPaint`
additionally gate on `__disp.class`, so a backend never commits a surface it
did not win. The **destination** is runtime too: `__disp.fb`
(`DISP_SEL_FB_LO`) is nonzero only on the `pcie-linear-fb` rung, so the blits
write the accepted BAR in place and `__scan_fb` is the shared fallback for
outputs without their own linear window.

`DomPaint32` is the native-resolution 32bpp glyph paint. It reads the live
`__ui_dom` rows at `DOM_Y0`, fetches 8×8 glyph bytes from `__font`, and writes
foreground/background B8G8R8X8 pixels directly into the latched output
framebuffer (`__disp.fb`, else `__scan_fb`) at the output's native geometry.

**High-DPI text.** `DomPaint32` derives the *same* uniform scale `N` and centred
letterbox as `FbExpand` — `N = min(W/low_w, H/low_h)`, capped at `dpi/96` in
`dpi` mode, clamped to 1..=16, with `ox=(W-low_w*N)/2, oy=(H-low_h*N)/2` — and
paints each font pixel as an `N`×`N` block on a `8N` pitch starting at
`(ox, oy + DOM_Y0*N)`. It previously hardcoded an 8px cell at the framebuffer
origin, so on the `g6lc64-virt` proxy output (1920×1080, dpi 192, `scale_mode:
"dpi"`) `PROXY-INIT` reported `scale=2` while the text was painted 1:1 in the
corner: a measured 839×183 ink box in a 1920×1080 frame, about 4% of the panel.
With the shared derivation the same content measures 1276×366 at `x=322..1597,
y=108..473`, i.e. exactly `ox=320`/`oy+DOM_Y0*2=108` and four times the area.
`fill` is deliberately treated as `fit` here — stretching glyphs by unequal
per-axis integers makes them illegible and the 8×8 font has no non-square form —
while the plane blit still honours `fill`.

Duplicating the *derivation* rather than the *value* is the point: the earlier
defect was precisely that the two paths disagreed, one scaling and one not.
`FbExpandSel` picks `DomPaint32` on a GPU-class surface when DOM rows are
populated, `FbExpand1` when the GPU surface has no DOM content, and
`FbExpand` (upscale + letterbox) on a VGA-class surface. `VioPaint`,
`DispPaint` and `PciPaint` all call `FbExpandSel`, so the same surface logic
covers the virtio-gpu, uncore and PCIe-linear-fb transports.

The `FbExpand1` path is **not** native DOM rendering — it only places the old
640×480 8×8 4bpp plane at scale 1 in the center of the scanout. The
`DomPaint32` path is what produces more text at native resolution: each glyph
fills its own 8×8 cell in the 32bpp framebuffer instead of being encoded into a
4bpp nibble and then expanded.

The host exec model copies the final `__scan_fb` into `Smoke::scan_fb` and the
test `g6b_wasm::jit::tests::dom_paint32_paints_native_32bpp_text_on_gpu_surface`
asserts native B8G8R8X8 pixels for the first glyph row. It uses the uncore
`display`-class peripheral path (`DispPaint` → `FbExpandSel` → `DomPaint32`) so
the test runs without the virtio input eventq and stays within the step budget.
Three companion tests in the same `g6b-wasm::jit::tests` module cover the
surface dispatch ladder: `dom_paint32_empty_dom_falls_back_to_fbexpand1`
verifies the 1:1 centred plane when no DOM rows are set;
`dom_paint32_vga_surface_stays_magnified` verifies the `kernel.proxy.surface`
`"vga"` override still runs `FbExpand` (upscale) and reports `disp_sel.1 == 0`;
`dom_paint32_paints_native_32bpp_text_on_gpu_surface_rv32` verifies the same
native glyph paint on RV32.

Runtime-geometry coverage lives in `g6b-asm::exec::tests`: a driver pokes
`__disp` with a geometry *no* declared output carries, so the gen-time proxy
would either paint the wrong pixels or store-fault past `__scan_fb`.
`fb_expand_follows_the_disp_latch_not_the_gen_time_proxy` runs `FbExpand` at a
latched 1280×720 (fit collapses to scale 1 at (320,120) instead of the proxy's
scale 2 at (320,60)); `fb_expand_sel_dispatches_per_output_geometry` drives the
same latched 1600×1200 through both surfaces — `vga` → `FbExpand` scale 2 at
(160,120), `gpu` → `FbExpand1` scale 1 at (480,360);
`dom_paint32_uses_the_disp_latch_geometry` runs `FbExpandSel` → `DomPaint32` at
a latched 800×600 and checks the runtime-stride glyph cells pixel-for-pixel — at
that geometry `N` collapses to 1 but the origin is still the letterbox (80,60),
so the case pins the offset independently of the scale. The two
`dom_paint32_paints_native_32bpp_text_on_gpu_surface*` tests assert every device
pixel of each `N`×`N` block at `N=2`, which is what makes them scale assertions
rather than offset ones, and additionally assert the old 1:1 origin is now clear.
All three run on RV32 and RV64. The low-res `__gr_plane` / `DomPaint` path
remains intact for VGA-class output. Host `ui_ppm` is a 16-colour downsample
of the live Engine canvas, not a second HTML CSS raster.

### Guest web paint: `__web_dl` display list → `DlPaint`

The browser face's pixels reach `__scan_fb` two guest ways, both under
`WebPaint`. `__web_pk` is a host-rendered Canvas32 packed into `.rodata`;
`WebBlit` RLE-decodes it row-by-row (the `xlen-31` literal-count funnel keeps
the RV64 `lw` sign-extension out of the run count). `__web_dl` is the same
scene recorded as a **display list**: `Canvas32` runs an opt-in recorder
inside `blend_rect`/`fill_rounded_rect`/`stroke_rounded_rect`/`blend_coverage`,
`g6b-kernel::dl_pack` serializes per-menu `{FILL, FILLR, STRKR, COV, TILEPX,
TREF}` records plus a content-dedup'd glyph atlas and the hit boxes, and
`DlPaint` replays them into the latched framebuffer. `TREF` resolves live
`__dom` text through `__dom_id` → `DlFindId`, so a value the JS cell edits
later repaints without a fresh pack; it still carries the packed fallback text
for when the node is absent. `WebPaint` is `DlPaint` then `WebBlit` on an
absent or malformed list, and both stamp `__ui_cap` WEB so `VioPaint` hands
the frame to the plane exactly as `GuestWebPresent` does — the CLI stays the
power-on owner until `AutoPick` flips `FACE_OWNER`.

`DlPaint` keeps a whole-frame replay inside the exec-model step budget by
decomposing `inside_rounded` rather than scanning each bounding box: `FILLR`
is three solid spans plus the four `r×r` corner squares (the only pixels where
`cx` and `cy` are both nonzero), and `STRKR` is just the four corner squares —
`stroke_rounded_rect` paints corner arcs because the `cy==0`/`cx==0` clause
keeps the straight bands *inside* the inner rect, so no edge spans exist to
emit. Inside pixels feed `DlBlendPx`; opaque rects take a `sw` span loop.
`tools/qemu_web_autoboot.sh` on `virtio-gpu-device` (no GL) shows the full
1920×1080 svelte-d scene through `WEBDL`, with `WEBPK` the recorded fallback
on an absent or invalid list.

Local plan-review gates now compare all packed menu states, at both 640×480
and 1920×1080, against independently host-rendered RGB pixels with zero
tolerance after guest `DlPaint` → `VioPaint`. The full guest-JIT picker handoff
has a separate completed-frame equality gate. See `RENDER-VALIDATION.md`
§Guest display-list parity for commands and evidence boundaries. The blue
`setup.ppm`/`proxy.ppm` outputs are legacy text diagnostics; their font is now
printable-ASCII-complete, not evidence of a broken web or virgl frame.
Remote g6q/QEMU-GL validation is ongoing in a separate session and was not run
or modified by this local pass.

### Refusals, stated rather than implied

- **No AMD/NVIDIA modesetting.** AMD needs AtomBIOS/DCN and modern NVIDIA needs
  GSP devinit firmware; neither is carried here, and writing one is a DRM
  driver, not a BIOS package. A PCIe adapter is used only as a framebuffer some
  earlier agent (EFI GOP handoff, legacy VGA/VBE, QEMU `stdvga`/`virtio-vga`)
  already initialized.
- **No PCIe BAR assignment.** Enumeration is read-only; only BARs firmware
  already programmed are accepted, and only inside the declared `pcie.mmio`
  window.
- **No HDMI hot-plug yet.** `hdmi-display.md` has no HPD or EDID register, so
  "an HDMI cable was connected" is not observable. It is a contract-revision
  REQUIREMENTS ask on the SoC uncore, listed by `inferred_arch()`.
- **The guest GPU surface is not the Rust CSS engine and not WebGL.** Those
  live in the host/browser lanes.

### Address-map hazard, enforced

QEMU virt's 32-bit PCIe MMIO window is `0x40000000..0x80000000` (ECAM
`0x30000000`, size `0x10000000`) — exactly where the ai-island GEMM block sits.
Every scanned BAR would land on top of it, so `BoardSpec::check_display()`
**refuses** any peripheral, `dram_base`, or the ECAM base itself falling inside
`pcie.mmio`. This is a spec error, not a runtime surprise.

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

## TTF font display unit

`g6b-ttf` is a first-party wrapper around the pinned `fontdue` crate. It loads
a single TrueType/OpenType font up to `2 MiB`, rasterizes one glyph at a time
with a `px` size between `1` and `64`, and blits the coverage bitmap into a
`g6b-gr::Canvas` with a 16-colour foreground threshold. It does **not** shape,
Kern, hint, subset or cache beyond `fontdue`'s internal tables; complex scripts
and colour/CFF fonts are not in scope. The 8×8 built-in font remains the
fallback for guest text/Gr planes; TTF is used for the CSS-raster host UI path
and for any font file embedded in the HTML/CSS/WASM/JS payload.

The CSS renderer also emits `HitBox` records (path, bounding rect, `id`/`name`)
for every block it paints. `BrowserSession` keeps the hit boxes from the most
recent `Engine::paint` and uses them for reverse lookup in `dispatch_pointer`.
Track-B `ui_ppm` is a 16-colour downsample of that same canvas. This is how
CSS output, DOM nodes, and pointer/keyboard events stay linked.

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
   emulator. `DomNav` (same jit gate) adds **menu input**: it walks the
   queue with a `NAV_SEEN` watermark (non-destructive — `Keys` still dumps
   the ring), and press events navigate the spec-derived menu tree —
   UP/LEFT sel-1, DOWN/RIGHT sel+1 (wrap over `spec.menus()`), ESC reset,
   ENTER sets the open latch + serial `NAV <name>`; the `nav.sel` DOM row
   shows `nav <name>` / `open <name>` in its own `NAV_TEXT` scratch
   (`WasmDomText` stores the pointer — never share scratch between rows).
   QEMU-verified: `sendkey down`/`ret`/`up` → `NAV cpu` + `DOM| nav cpu`
   on the `Ui` repaint.
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
   histogram matches the host-modelled framebuffer exactly. **Menu input is
   QEMU-verified** (`DomNav`: `sendkey` arrows/enter → `NAV <menu>` serial +
   `nav.sel` DOM row + repaint). **The bounded await lane and background
   frames are QEMU-verified** (`Await`×4 → `AWAIT pending 0..3` → `Throw`
   → `AWAIT-THROW` rejects the newest pending → the timer tick drains the
   rest — `AWAIT-GET`×3 + `DOM| resolved menu`×3 + `DOM| rejected menu`
   repaint; resolved/rejected slots are reusable; all-pending is the
   bounded `AWAIT-REJ full`, exec-verified) — see "Async frames and
   IRQ-context paint safety" below. Later hardware timing/PMA/PMP/cache/
   IRQ validation remains distinct from QEMU evidence.

Stage 5 remains open; stage 3 (virtio-input) is now **QEMU-verified**
(`sendkey` → `INP` → `KEY`/`DOM| key` on `g6lc64-virt.json`, stock virt +
`virtio-keyboard-device`), and stage 4 is QEMU-verified for probe → handshake →
controlq → resource/scanout/flush **at the high-res proxy geometry**
(1920×1080 scanout, centered ×2 content; QMP `screendump` P6 with nonzero
guest pixels). `g6lc64-virt.json` boots clean on stock QEMU virt —
`MBOX-NONE`/`UART1-NONE` are reported, not parked. Do
not remove `-nographic` or claim a screenshot by changing argv alone.

### Async frames and IRQ-context paint safety

- **Poll points, not blocking waits.** The periodic timer irq
  (`trap_timer`) runs `DomAwait` (drain the `AWAIT_SLOTS`=4 pending slots
  at `__ui_dom+16` — each pending → `AWAIT-GET /bios/menu` → `await.N`
  row → dirty) and then flushes a repaint only when the DOM dirty counter
  moved past the `DOM_PAINTED` watermark (`__ui_dom+8`). `Ui` and `Keys`
  poll `DomAwait` too. This is the "doesn't block on DOM events" half:
  input, navigation and await mutations happen on their own irqs; frames
  flush on the tick.
- **Trap frame preserves the interrupted context.** The trap entry saves
  `ra` + `t0..t6` + `a0..a7` (16 slots). An irq landing mid-`VioCmd` (its
  completion `wfi`) must not corrupt the in-flight transaction's
  registers — before the fix a timer tick resumed `vqc_poll` with a
  clobbered `t5` and took a load-access fault (diagnosed via `stval`).
  `s0..s11`/`gp`/`tp` remain callee-saved per the ABI.
- **`VIO_BUSY` guards the ctrlq** (`__vio+0x5f0`): `VioCmd` sets it for
  the transaction and clears on every exit; `VioPaint` skips while set.
  Register save/restore alone cannot protect shared ring state — a
  trap-time paint interleaving mid-transaction would corrupt descriptors
  and the avail index.
- **In-trap `wfi` is a bounded poll pause.** The exec model treats `wfi`
  with `sstatus.SIE` masked (in-trap, `SPIE` latched) as a loop-back, not
  a halt — a pending kick can never take an SEI there, so halting would
  abort mid-trap. QEMU wakes `wfi` on masked-but-pending interrupts, so
  the same instruction also keeps the `vqc_poll` wait irq-driven on real
  hardware.

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
- **PCIe linear framebuffer** — `pcie.scan_display` + an accepted BAR:
  `PciPaint` runs `FbExpandSel` with the destination resolved from
  `__disp.fb` (`DISP_SEL_FB_LO`), so the blit lands **directly in the device
  BAR** — `__scan_fb` is only the fallback for outputs without their own
  linear window, and a `fence` orders the (possibly WC) stores. No doorbell,
  no modeset: the BAR is display memory already scanned by the adapter's own
  refresh. `PCI-PAINT` marks the commit; exec-modelled via a bounded BAR
  shadow (`Smoke::pci_fb_img`).
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
  `virtio-gpu-device` fallback. `GL-ADAPTER`/ProxyScale RVV is a
  *guest-side* scale accel listing, not QEMU virgl — do not equate them.
  **M4 (guest virgl composite — B124, hardware-verified):** on a `proxy.gl`
  board `VioInit` accepts `VIRTIO_GPU_F_VIRGL` in the driver-features word,
  and `VioVirgl` — scheduled **after `VioPaint`** so the committed frame is
  resident — drives a real virgl bring-up over the ctrlq:
  `GET_CAPSET_INFO`/`GET_CAPSET` (virgl capset) → `CTX_CREATE`(ctx 1) →
  `RESOURCE_CREATE_3D`(`RES_RT` offscreen render target with
  `Y_0_TOP`, `RES_VBO` vertex buffer) → `CTX_ATTACH_RESOURCE`(RES_RT,
  RES_VBO, **RES_SCAN** — the 2D scanout resource `VioScan` created and
  `VioPaint` filled via `TRANSFER_TO_HOST_2D`) → `SUBMIT_3D` carrying the
  `__virgl_cmd` execbuffer → `SET_SCANOUT(RES_RT)` → `RESOURCE_FLUSH(RES_RT)`.
  The execbuffer (`crates/g6b-asm/src/virgl.rs`, byte-exact against
  virglrenderer 1.0.0 `virgl_protocol.h`/`vrend_decode.c`, 24 commands /
  ~960 B at 640×480) creates surface/shaders/vertex-elements/sampler-view/
  sampler-state/blend/DSA/rasterizer objects, binds them, inline-writes a
  fullscreen triangle-strip vertex buffer, sets scissor/viewport/
  framebuffer, `CLEAR`s and `DRAW_VBO`s. Its **sampler view binds
  `RES_SCAN`** — the draw resamples the *committed display frame* through
  the GPU into `RES_RT`, which the trailing `SET_SCANOUT`+`FLUSH` then
  presents: the displayed image is GPU-rastered, not a guest copy — the
  canonical virgl compositor dataflow. Shaders travel as **TGSI text**
  (the `tgsi_dump` form `tgsi_text_translate` parses — the binary-token
  wire was retired in virglrenderer 0.9.0): a `VERT` passthrough and a
  `FRAG` `TEX …, 2D` sampler; UV follows clip XY without an extra V flip
  when both resources are `Y_0_TOP` (P0 replay below). `SUBMIT_3D` is a three-descriptor chain
  (32-byte `cmd_submit` OUT + execbuffer OUT + resp WRITE); the exec model
  gathers *all* OUT descriptors before dispatch (`vio_exec_chain`).
  **M4b (guest readback):** `VioVirgl` `sw`-builds
  `RESOURCE_ATTACH_BACKING`(`RES_RT`→`__virgl_out`, an `Addr::VirglOut` BSS
  region) + `TRANSFER_FROM_HOST_3D` — `entries[0].addr` carries the
  resolved `La VirglOut` address, which a static `__virgl_req` record
  cannot hold, so the readback pair is codegen'd rather than tabled.
  `Smoke::virgl_out` snapshots the guest buffer via
  `csr.virgl_backing[RES_RT]`; `Smoke::virgl_scanout`/`virgl_flushes` record
  the RES_RT present.
  Exec-model verification: `virgl_submit_composites_scanout_frame` (asserts
  `virgl_out == virgl_fb` byte-exact — the composite lands in guest RAM;
  `virgl_src` snapshots the sampled `vio_fb` at composite time since a
  later DOM repaint may rewrite it), `virgl_exec_composites_scanout_texture`,
  `virgl_texture_byte_kill_test`, `virgl_transfer_requires_attached_backing`,
  plus the negotiated-feature gate (`virgl_live` = `vio_gl` *and* the
  accepted `VIRTIO_GPU_F_VIRGL` bit).
  **Historical execbuffer-only check (`out/virgl/vhw`, B124):** `g6b virgl-dump` writes the
  byte-exact execbuffer; a dlopen harness feeds it to the *real*
  `libvirglrenderer.so.1` on WSLg's surfaceless EGL over the D3D12 gallium
  driver (Intel Arc — no `/dev/dri` needed; the EGL device is the paravirt
  GPU itself). Result: `submit → 0`, `transfer_read(RES_RT) → 0`,
  **307,200/307,200 pixels byte-exact** against the uploaded scanout
  texture — the guest's virgl stream rasterizes verbatim on hardware.
  **Honest bound:** the QEMU `egl-headless,gl=on` path still needs a host
  DRM render node (absent on WSL2) — the harness proves the *stream* on a
  real GPU, while an end-to-end `virtio-gpu-gl-device` boot remains
  untestable here. `SAMPLE`-form shaders fail `vrend_convert_shader` on
  this backend (`Illegal shader`); the emitted `TEX …, 2D` form is the
  accepted canonical variant.

Conformity: HDMI TMDS / DisplayPort PHY stay in `corev_apu` / board (REQUIREMENTS).
This package emits the register contract, timing metadata and the scaled
framebuffer, not a TMDS encoder. QEMU still uses `-nographic` plus
`virtio-gpu-device` (or `virtio-gpu-gl-device` under `proxy.gl`) with
`-global virtio-mmio.force-legacy=false` (the virt machine's mmio transports
default to the legacy v1 interface, which ignores the v2 queue registers).
No `-netdev`.

## API-neutral APU: P0 wire audit (2026-09-14)

**Status: partial protocol groundwork, not APU RTL or unchanged-driver GLES2
completion.** The intended separation is external EGL/GLES clients → unchanged
Mesa virgl / Linux virtio-gpu → a standard virtio device → resident control
firmware → an API-neutral hardware graphics engine. HDMI/DP scanout remains a
separate consumer of completed surfaces. Firmware may compile/manage commands;
vertex, raster, sampler, fragment and output work must execute on the APU.

### Pinned references and corrected wire fields

`pins.toml [graphics_wire]` records immutable reference revisions: virglrenderer
1.0.0, Mesa 24.3.4, Linux 6.6 and the published virtio 1.3 specification. They are
external references, not Cargo dependencies, installed software claims or a
license to advertise a complete renderer.

The package-local `g6b-asm` `p0_` tests independently pin these wire values:

| Field | Correct value | Previous failure |
|---|---|---|
| `VIRTIO_GPU_F_RESOURCE_BLOB` / `CONTEXT_INIT` | bits 3 / 4 | bits 10 / 11 |
| `RESOURCE_CREATE_3D.bind` render target / vertex buffer | `VIRGL_BIND_*` bits 1 / 4 | current Gallium-style bits 0 / 3; QEMU forwards the wire bind unchanged |
| `CLEAR.buffers` color target 0 | bit 2 | bit 0 selected depth |
| Virgl capset 1 | version 1, 308-byte payload | six-word marker placeholder |
| `GET_CAPSET` response capacity | 332 bytes including header | 48 bytes truncated a real reply |

The model now returns a complete v1-shaped capset **without a GLSL grant**,
rejects unsupported capset IDs/versions, and no longer describes that same blob
as virgl2. The handwritten quad model is still not an implementation of general
shader semantics. The client requests version 1 and reserves the full response;
this does not implement runtime capability-based renderer selection.

Existing TGSI-text, shader-stage, command-length and state-binding corrections
are preserved and regression-pinned. Independent runtime probing of installed
`libvirglrenderer1 1.0.0-1ubuntu2` confirms capset 1 is version 1 / 308 bytes.
The initial `out/virgl/vhw-p0` diagnostic pre-created its source texture without
QEMU's `Y_0_TOP` flag. It is not the current full-sequence oracle: replaying the
real resource flags exposed an extra V flip (all 480 rows inverted), now fixed
without changing expected pixels. The tracked runner is
`python tools/bios_regress.py --virgl-reference <virgl-dump-directory>` (Linux,
Python 3.11+, external libvirglrenderer). It replays 11 request records, validates
response capacities, waits for submit/readback fences 1 and 2, attaches readback
storage and checks all pixels. Both llvmpipe and explicit `GALLIUM_DRIVER=d3d12`
(Intel Arc 140V) return **307,200 exact pixels / zero differences** at 640×480.
Reports under `out/virgl/p0-sequence{,-d3d}/reference-report.json` identify the
actual renderer and input/output hashes. Scanout is headless metadata validation;
this is not a full virtqueue/SG transport, unchanged-Linux-driver or RTL test.

The `p0_` tests now also cover full 64-bit fence echo/checking, response extents,
invalid/cyclic descriptors, split OUT payloads and truncated submissions, first-error
termination, 16-bit queue-index wrap on RV32/RV64, and Y_0_TOP UV orientation.
The client fences SUBMIT_3D before scanout and readback before consumption; error
responses no longer lead to a false success marker.

OpenWrt boot/probe through `g6lc_qemu` is now green: the existing 24.10.2 image
boots on project QEMU 10.0.0 through OpenSBI 1.5, reaches a shell using a temporary
ttyS0 inittab overlay, and discovers virtio device `0x0010`. The guest image has
no active DRM/virtio-gpu driver or Mesa packages; project QEMU has OpenGL disabled
and no virgl GPU device. A graphics-enabled guest/emulator and modern virtio-mmio
are the next prerequisites, separate from host render-node availability. Details:
[g6lc_qemu guider](../../g6lc_qemu/AGENTS.md).

### The effective stock-driver contract is larger than a small capset

Mesa 24.3.4 `src/gallium/drivers/virgl/virgl_screen.c` unconditionally reports
fragment derivatives/LOD, NPOT textures and swizzles. Its shader limits include
256 temporaries and control-flow depth 32; missing texture-size fields select
large defaults rather than zero capability. A four-invocation quad with 256
vec4 FP32 temporary registers already requires 16 KiB of logical register
storage before constants, shader code, pipeline state or spill memory.

Therefore P0 is not closed by a successful fullscreen quad. Before freezing APU
geometry, enumerate the **effective** driver capabilities and compiler-generated
instructions, including implicit requirements, and prove every reported feature.
Use parameterized temporal sharing and SRAM-backed state to reduce hardware,
not false limits or a patched driver. Do not derive grants from the current
zero-capability execution-model fixture.

Remaining P0 gates:

- [ ] Capture and validate actual shader/state streams from the pinned unchanged
      Mesa/Linux client; the BIOS quad is not a substitute.
- [ ] Validate full resource/SG transfers, asynchronous fencing, response failure
      handling and context reset/lifetime against the independent backend.
- [ ] Freeze the truthful effective capset, shader ISA/limits and resource ABI.
- [ ] Establish a protected firmware-hart/domain and cache/DMA contract; shared
      physical DRAM is not automatic coherency.
- [ ] Resolve the package-wide autoboot UI test failure before claiming full
      package verification. The picker arm-order race is fixed. With `proxy.gl=false`,
      a diagnostic rerun clears the live row table and produces 8,294,400 correct
      UI bytes in RAM, but has not transferred them to scanout when the unchanged
      48-million-step limit stops in `jit_em`. The historical UART row dump is not
      evidence of the new pixel surface; the original test remains failing.

Verification for this pass: `cargo test -p g6b-asm p0_`, targeted Clippy and
format checks pass; `python tools/g6b.py regress` passes. Full
`python tools/g6b.py check` passes independence, Bun tests/build, fmt and workspace
Clippy but fails at `g6b-elf::picking_bios_ui_replaces_the_picker_rows`. No RTL,
ISA, DTS, clock/reset, DFT or synthesis change occurred; no silicon timing or
RISC-V compliance claim follows.
