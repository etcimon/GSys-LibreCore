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
   scheduler tests do not satisfy this gate.
4. **Guest display/input:** enumerate and drive virtio-gpu resources, transfer,
   flush and scanout; route input into a bounded normal-context event queue;
   advance/resume scripts independently of refresh. The existing GR16 boot
   pattern plus `virtio-gpu-device` argv is not a connected UI scanout.
5. **Acceptance:** capture QEMU scanout showing text actually mutated by WASM,
   then menu input, pending/rejected await and background frames concurrently;
   record framebuffer/event evidence, not just UART markers. Later hardware
   timing/PMA/PMP/cache/IRQ validation remains distinct from QEMU evidence.

Stages 3–5 remain open. Do not remove `-nographic` or claim a screenshot by
changing argv alone; connect and verify the actual guest scanout path first.

Conformity: HDMI TMDS / DisplayPort PHY stay in `corev_apu` / board (REQUIREMENTS).
This package emits timing metadata and a scaled framebuffer, not a TMDS encoder.
QEMU still uses `-nographic` plus optional `virtio-gpu-device`. No `-netdev`.
