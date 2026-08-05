# Uncore outline — HDMI / display

**Domain:** display · **Catalog id:** `hdmi` · **Status:** planned
**Scaffold only** (see `architecture/uncore/README.md`).

## 1. Intent
Drive a local display: a framebuffer scanned out over an HDMI/DVI TMDS encoder, for a console or GUI.
Step-4 addition — after memory, PCIe, networking/storage.

## 2. Chosen controller
- **hdl-util/hdmi** — `https://github.com/hdl-util/hdmi` — **MIT**. Pure-SystemVerilog HDMI 1.4b TMDS
  transmitter (video + audio); clean, native SV (no Migen). DVI-only alternative: Digilent `rgb2dvi`.
- Fetch: `vendor sync hdmi` · Inspect: `vendor scan hdmi` (root: `src`).

## 3. Controller vs PHY split (decisive)
- **On-die:** the TMDS encoder (8b/10b, serialisation, video timing).
- **PHY:** the HDMI **connector + ESD protection / level-shift or re-driver** on the board
  (e.g. TPD12S016, SN65DP159); high pixel clocks may use FPGA OSERDES/GT primitives.
- **Board:** HDMI port and its clocking.

## 4. Integration seam (corev_apu)
- A framebuffer in DRAM read by a display DMA (AXI master, e.g. AXI-VDMA-style) feeding the TMDS
  encoder; config via AXI-Lite. Board wrapper + TMDS pin constraints in `corev_apu/fpga/src/` +
  `corev_apu/fpga/constraints/` (the `NEXYS_VIDEO` board already targets this class of output).
- Depends on `ddr4-controller.md` for framebuffer bandwidth.

## 5. Config gating & invariants
- Optional per board; pixel-clock domain crosses to the AXI domain via CDC (line buffer / async FIFO)
  — document it. Async-active-low reset; `tc_sram` for line buffers; DFT threaded.
- Registered outputs at the TMDS boundary to avoid fanout on the pixel datapath.

## 6. Verification + software
- Video-timing checker + a small pattern-generator test in `corev_apu/tb`.
- Device tree: a display/framebuffer node if exposed to Linux; cross-validate per
  `AGENTS-dts-validation.md`. Software: simple framebuffer console first; DRM/KMS is a larger effort.

## 7. Scan pointers
TMDS encoder + serialiser + video-timing modules under `src`; the audio path if used. Pin a SHA
before `vendored`.
