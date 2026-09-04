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

Conformity: HDMI TMDS / DisplayPort PHY stay in `corev_apu` / board (REQUIREMENTS).
This package emits timing metadata and a scaled framebuffer, not a TMDS encoder.
QEMU still uses `-nographic` plus optional `virtio-gpu-device`. No `-netdev`.
