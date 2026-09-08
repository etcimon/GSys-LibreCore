# Uncore display engine — BIOS scanout contract

> Status: **contract + guest routine + host model landed**; the SoC-side
> engine (TMDS/PHY bring-up, EDID, clock tree) is board/vendor IP — this
> document defines the register-level seam the BIOS programs, which is what
> `g6lc_bios` owns and what `g6b-asm`'s exec model verifies.

## Why this exists

`BoardSpec.kernel.gr.backend` / `kernel.proxy.link` accept `hdmi`,
`displayport`, `host-gl`, `virtio-gpu`. On QEMU the only real display
transport is virtio-mmio (`wants_virtio_gpu()`). On real hardware there is
no virtio-mmio — the uncore carries a scanout engine behind an HDMI/DP PHY.
Declaring a `display`-class peripheral selects the native path:

```json
{ "id": "hdmi0", "class": "display", "model": "g6lc-scanout",
  "base": "0x40003000" }
```

`BoardSpec::display_ctrl()` returns the window base; `wants_disp_scan()`
gates the guest code; `wants_virtio_gpu()` **yields** to a declared native
engine (a `display` peripheral + an `hdmi`/`displayport` link means "native
port", not "virtio stand-in").

## Register contract (64-byte window at `peripheral.base`)

| off | name | access | meaning |
|---|---|---|---|
| `0x00` | `MAGIC` | RO | `'G6DS'` (`0x53443647`) — presence detect; absent ⇒ silent bail |
| `0x04` | `REV` | RO | contract revision (`1`) |
| `0x08` | `CTRL` | RW | bit0 enable |
| `0x0c` | `FB_LO` | RW | framebuffer physical address, low 32 |
| `0x10` | `FB_HI` | RW | framebuffer physical address, high 32 |
| `0x14` | `WIDTH` | RW | scanout width (the `__disp`-latched output mode) |
| `0x18` | `HEIGHT` | RW | scanout height |
| `0x1c` | `STRIDE` | RW | bytes per row (`width*4`) |
| `0x20` | `FORMAT` | RW | `1` = X8R8G8B8 little-endian |
| `0x24` | `COMMIT` | WO | write nonzero → latch + go live |
| `0x28` | `STATUS` | RO | `1` = scanout live after COMMIT |

The framebuffer is the shared `__scan_fb` BSS surface — the same buffer the
virtio-gpu `TRANSFER_TO_HOST_2D` path pushes, filled by the shared `FbExpand`/
`FbExpand1`/`DomPaint32` blits (`g6b_gr::proxy::Proxy` semantics: `fit`/`dpi` =
uniform integer scale, centered letterbox; `fill` = per-axis integer stretch).
Scale, letterbox and row addressing read `__disp` w/h/stride at runtime, so the
committed mode is whatever `DispSel` latched, not a compile-time default.
One blit, two transports.

## `G6FB` handoff descriptor (Linux handoff)

`DispPaint` also writes a descriptor at `__vio + 0x400`:

```
u32 magic 'G6FB'; u64 fb_base; u32 width; u32 height; u32 stride; u32 format;
```

This is the `simple-framebuffer`-shaped handoff: a device-tree
`simple-framebuffer` node (`reg=<fb_base len>`, `width`, `height`, `stride`,
`format="x8r8g8b8"`) can be generated straight from this block, so a Linux
`simplefb`/`simpledrm` console inherits the BIOS-drawn scanout **without
re-initializing the display engine** — the same surface serves the BIOS and
the OS. The engine keeps scanning the buffer after handoff until Linux's
real DRM driver takes over.

## QEMU side — VNC frontend

QEMU has no `g6lc-scanout` device; on QEMU the scanout is the virtio-gpu
console. `g6b qemu-args --vnc N` appends `-vnc 127.0.0.1:N` (VNC on
`5900+N`): a host-side frontend over the QEMU console — it exports whatever
the emulated console shows, so it serves the BIOS boot screen **and** a
later Linux guest identically, with zero guest-side change. It composes with
`-nographic` (the command console stays on the TCP serial backend) and is
independent of `proxy.gl`.

`proxy.gl:true` selects `virtio-gpu-gl-device` + `-display
egl-headless,gl=on` in `qemu-args` (virgl host-GL composite). That requires
a host DRM render node; on hosts without one (`qemu-system-riscv64: egl: no
drm render node available`) QEMU refuses the device — use `qemu-args --no-gl`
for the 2D `virtio-gpu-device` fallback (identical guest commands).

## Evidence model

- Host model: `exec` models the register window (`MAGIC`/`REV`/`STATUS` RO,
  RW file, `COMMIT` → `disp_committed` + `STATUS=1`) — `smoke` prints
  `DISP-OK`/`DISP-FAIL`; `Smoke.disp_desc` exposes the latched
  `{fb,w,h,stride,format}`.
- Fixture: `fixtures/g6lc64-hdmi.json` (native `hdmi` backend + `display`
  peripheral at `0x40003000`; no virtio transport).
- Not modeled: TMDS/PHY link training, EDID/DPCD reads, pixel-clock PLL,
  hotplug IRQ — those live in the SoC uncore, not this BIOS package.

## REQUIREMENTS ask — HPD + EDID for output selection (open)

`architecture/DISPLAY.md` "Display outputs and surface selection" ranks this
engine above virtio-gpu, but the ladder can only ask *"is the engine present"*
(`MAGIC == 'G6DS'`), never *"is a cable connected"*. The 64-byte window has no
hot-plug or mode information, so a display-proxy that switches output when an
HDMI cable is plugged in is **not implementable against contract revision 1**.

Proposed revision 2 additions, behind a bumped `REV` so revision-1 boards keep
working unchanged:

| off | name | access | meaning |
|---|---|---|---|
| `0x2c` | `HPD` | RO | bit0 sink connected; bit1 HPD-change latched (write-1-clear) |
| `0x30` | `EDID_W` | RO | preferred-mode width from EDID/DPCD, 0 = unknown |
| `0x34` | `EDID_H` | RO | preferred-mode height, 0 = unknown |
| `0x38` | `EDID_HZ` | RO | preferred refresh in Hz, 0 = unknown |
| `0x3c` | `IRQ` | RW | bit0 raise a PLIC interrupt on HPD change |

Until that exists the BIOS must treat a declared engine as *possibly*
disconnected: `DispSel` accepts it on `MAGIC` alone and reports
`DISP-SEL ... hpd=unknown`, and `kernel.proxy.detected_hz` stays a
human-authored BoardSpec field rather than a probe result. Do not describe the
current behaviour as hot-plug detection.
