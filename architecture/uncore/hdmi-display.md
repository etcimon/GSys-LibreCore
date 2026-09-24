# Uncore outline — HDMI / display

**Domain:** display · **Catalog id:** `hdmi` · **Status:** simple-framebuffer byte model recorded; no booted guest
**Default-off scanout plus the Linux node that names its bytes** (see `architecture/uncore/README.md`).

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
- `verif/tb/hdmi/tb_g6lc_hdmi_scanout.sv` checks `HdmiEn=0` is quiet and that
  640×480 `r5g6b5` pixels leave the scanner in line order for two patterns.
  `verif/tb/hdmi/tb_g6lc_hdmi_linebuf.sv` feeds that scanner from one 64-bit
  INCR burst per line (length 159, size 8, 160 beats, stride 1280). Remote
  `run-hdmi-scanout.sh` rc=0: scanout **8 checks / 307200 pixels / errors=0**;
  line buffer **4 checks / 307200 pixels / errors=0**. The disabled line
  buffer issues no AR. Not a board PHY, not STA, not HDMI certification.
- Screening synth, no SRAM macro, so lanes become flip-flops. `HdmiEn=0`:
  both modules are ports only (scanout 14 ports / 111 bits, line buffer 18
  ports / 198 bits). `HdmiEn=1` scanout: 328 cells / 42 flip-flops.
  `HdmiEn=1` line buffer: 67133 cells / 32846 flip-flops (32768 of them the
  eight 256×16 lanes, plus 78 control). No latches. Each lane is 256 deep
  so the read mux is fully driven; beats use addresses 0..159 only. The
  pixel port is one sample per clock, returned on the next clock.
- `g6lc_hdmi_tmds` turns that pixel into three 10-bit symbols. Blanking
  carries HSYNC/VSYNC. Each active line is preceded by eight video-preamble
  characters (CTL0=1) and two video guard characters. No audio and no data
  island. `tb_g6lc_hdmi_tmds` drives the same framebuffer through the line
  buffer: **6 checks / 307200 pixels / errors=0**, including the first 16
  symbols of line 0. `HdmiEn=0` is 11 ports / 59 bits and no cells.
  `HdmiEn=1` is 1597 cells / 324 flip-flops, no latches.
- `g6lc_hdmi_ser` shifts each symbol on a bit clock. `load_i` is one pulse
  per symbol; bit 0 leaves on that pulse, then bits 1..9. The pins are
  single-ended. `tb_g6lc_hdmi_ser` checks the framebuffer through that
  shift: **4 checks / 307200 pixels / 384044 words / errors=0**. `HdmiEn=0`
  is 9 ports / 36 bits and no cells. `HdmiEn=1` is 60 cells / 30
  flip-flops, no latches. No PLL and no differential pair. Not a board PHY.
- Linux node, one reserved DRAM region, no custom KMS. The opt-in fragment
  is `corev_apu/hdmi/g6lc-simplefb.dtsi`. No board DTS includes it.

```
framebuffer@8ef00000 {
    compatible = "simple-framebuffer";
    reg = <0x0 0x8ef00000 0x0 0x96000>; /* 640*480*2 */
    width = <640>;
    height = <480>;
    stride = <1280>;
    format = "r5g6b5";
};
```

  The region is a `no-map` carve-out of the existing 256 MiB DRAM window,
  below the AI operand pool at `0x8f000000`. It is not a new MMIO aperture.
  `verif/tb/hdmi/simplefb_model.py` checks the node and that byte
  `base + y*stride + x*2` is the little-endian `r5g6b5` pixel the line
  buffer bursts: **16 checks / 307200 pixels / errors=0**. A format other
  than `r5g6b5`, a short stride, or a short region is rejected. This is
  not a booted simpledrm and not fbcon.

`CONFIG_DRM_SIMPLEDRM` (or fbdev simplefb) is the driver that binds the
node. The 3D pipe, when it exists, writes this buffer. It does not get a
second scanout format. `HdmiEn` is independent of `ApuOff`, `ExecEn`, and
`MatrixEn`.

## 7. Scan pointers
TMDS encoder + serialiser + video-timing modules under `src`; the audio path if used. Pin a SHA
before `vendored`.
