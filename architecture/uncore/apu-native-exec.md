# APU native execution cluster

**Domain:** graphics uncore · **Status:** default-off arithmetic/control prototype

`g6lc_apu_exec.sv` time-multiplexes one FPnew FP32/integer lane over four
lockstep invocation contexts. It consumes native words, not EGL/GLES or TGSI.
Trusted graphics microprograms run here, never on the resident service hart.
The lane architecture remains the area-first starting point, not a promise
that the current 16-word/eight-register prototype can implement GLES2.

## Actual implementation

| Property | Current RTL |
|---|---|
| Gating | `ApuCfg.Enable && ExecEn`; `ApuHarness.ExecEn=0` |
| Storage | 16-word IMEM, four sets of eight scalar registers, configurable local DMEM |
| Arithmetic | Integer add/sub/logic/compare; FPnew FADD/FSUB/FMUL/FMADD; FNEG; LDI/LDC |
| Control | Shared PC, predication, SETMASK/CMPLT, uniform BR, HALT |
| Quad exchange | `QUADX` snapshots rs1 before exchanging 0↔1 and 2↔3 |
| Local memory | Word-aligned LD/ST, shader limited to low half; privileged microjob sees whole DMEM |
| Observation | RF peek and DMEM peek; no resource-backed framebuffer |

**Storage correction:** RF, IMEM and DMEM are resettable RTL arrays, not
`tc_sram` instances. The old description of this leaf as local SRAM was an
intent, not implemented macro-friendly storage. Move program/register/tile
backing behind registered macro seams before scaling. `testmode_i` is
currently consumed as unused, not a demonstrated scan/MBIST path.

## Decode safety review

The review adds admission checks in Fetch for every instruction: shader
`priv=1`, undefined opcodes, and high register-index bits are faults before
any instruction side effect. This includes BR/NOP/HALT, which previously
bypassed the Issue-stage privilege check. Unsupported encodings must not
write zero or alias r8 onto r0. Directed tests first reproduced 26 failures;
current results are in the root test/evidence maps.

This is a small decode cone before existing Fetch/Issue registers, no new
clock/CDC, FPnew change or API grant. Faulted jobs require discarded output;
a later valid local job can start. It does not establish context isolation.

## Remaining execution contract

- Enabled configurations name the implemented file: 4 threads, 8 registers,
  16 instruction words, and 64 data words. The instruction index is 4 bits,
  the debug register index is 3 bits, and the DMEM debug index is 6 bits.
  `apu_cfg_legal` rejects every other count on an enabled device. The arrays
  are those constants. A disabled device is still legal with other stored
  counts, because it builds no file. Remote 2026-09-22:
  `tb_g6lc_apu_exec_geom` 5 cases / 43 checks / 9 clocks, errors=0. Register
  7 accepts a poke and register 0 stays zero. DMEM words 0 and 63 read as
  zero after reset. Bind lint matches the same index widths. Fixture synth
  has no latches. Enable=0 is ports only. Enable=1 is 25,430 cells / 3,888
  flip-flops, the same screen as the earlier exec cluster.
- Validate fall-through PC bounds and instruction versus LDC payload slots;
  define program length, instruction budget, fault metadata and cancellation.
  Infinite/backward branches need bounded service progress, not timeout-success.
- BR takes `|mask`; this is not divergent control/reconvergence. Quad contexts
  are invocations, **not RGBA components**. Define vec4 values/write masks,
  helper invocations, discard, derivatives, indirect accesses and per-context
  state initialization/scrubbing before accepting general TGSI programs.
- Preserve separate IN/OUT/CONST/TEMP semantics, register spilling and realistic
  program capacity; the pinned Mesa assumptions exceed this prototype.
- Integrate a protected resource LSU with memory/exec scheduling, mapping pins,
  errors and cancellation. No raw host addresses or debug-port DMA.
- One-sample top-left coverage is `g6lc_apu_cover`. Vertex fetch, clipping,
  interpolation, texture filtering/wrap/mip/LOD, fragment execution,
  depth/stencil/blend and format-correct output are still open. Dedicated
  sampler/raster units are optional optimizations, not omitted semantics.
- Validate numerical precision/invariance and fused versus unfused arithmetic;
  a single exact FMADD case is not shader conformance.

## Evidence boundary

Historical baseline includes TID/IADD, mask, FP32 arithmetic, LDC, quad exchange,
BR, local LD/ST and a scanline-shaped loop writing `1.0f` to four DMEM words.
That loop redundantly runs over invocation contexts; it is not coverage,
interpolation, packed RGBA8 output or Linux `glReadPixels`.

`g6lc_apu_cover` answers one sample against one triangle. Coordinates are
signed 16-bit, +x right and +y up. The weights are the integer edge
functions and sum to the signed area. A zero weight is inside only on a
top edge (horizontal, directed left) or a left edge (vertical, directed
down) of the counterclockwise winding. A zero area misses. The color
word is copied onto the fragment record and does not change when a vertex
moves. `CoverEn` defaults to 0 on every profile and does not make virgl
legal. The unit is not on the testharness flist. Remote 2026-09-22:
`tb_g6lc_apu_cover` 9 cases / 78 checks / 40 clocks, errors=0. Fixture
synth, no latches: Enable=0 is 8 ports and no cells; Enable=1 is 22,506
cells / 174 flip-flops. This is not a framebuffer, a shader surface load,
or `glReadPixels`.

`g6lc_apu_frag` stores one covered sample as RGBA8. Byte 0 is red, then
green, blue, and alpha. The address is `y * stride + x * 4`. Each channel
is `(w0*c0 + w1*c1 + w2*c2) / area`, rounded half up after the signs are
folded positive. A miss and a fault leave stored bytes unchanged. The
color word carried on the coverage record is not the pixel. The local
image is 4 by 2. On the test triangle, sample `(1,1)` with red, green,
and blue vertices is `32'hFF404080` at `(1,0)`, and a solid red triple is
`32'hFF0000FF` at `(0,0)`. The other six pixels stay 0. `FragEn` defaults
to 0 and does not make virgl legal. The unit is not on the testharness
flist and is not the HDMI scanout buffer.

A covered sample can store the one RGBA8 texel at `(0,0)` instead of the
weighted color. `tu,tv` other than 0 is a fault. A coverage miss does not
fetch. There is no filter and no wrap. The texel `32'hFF80FF40` lands at
surface `(2,0)` and leaves the blend and solid pixels unchanged. `TexelEn`
defaults to 0 and does not make virgl legal. The TEX opcode still returns
`-26`. Remote 2026-09-22, same testbench with the texel cases included:
`tb_g6lc_apu_frag` 12 cases / 58 checks / 331 clocks, errors=0. Fixture
synth, no latches: Enable=0 is 12 ports and no cells; Enable=1 is 22,141
cells / 559 flip-flops.

`use_image` copies one covered sample from a packed resource image at
the same address. The image must hold `width * height * 4` bytes and
the stride must be `width * 4`. Sample `(1,0)` of the 4×2 ramp is
`32'hA7A6A5A4`. The solid pixel at `(0,0)` and the texel at `(2,0)`
stay. A miss and a fault leave that pixel unchanged. Asking for the
image and the texel together is a fault. Remote 2026-09-22, same
testbench with the image cases included: `tb_g6lc_apu_frag` 17 cases /
79 checks / 358 clocks, errors=0. Fixture synth, no latches: Enable=0
is 13 ports and no cells; Enable=1 is 24,803 cells / 559 flip-flops.
The CVA6 cookie was not re-run. The TEX opcode still returns `-26`.

`use_prog` stores the color of one `LDC` immediate, the same
`0xAA000000` plus FP32 word the TGSI compiler emits for a splat of
0, 0.5, or 1. Those three immediates are opaque black `32'hFF000000`,
gray `32'hFF808080`, and white `32'hFFFFFFFF`. Replacing 1.0 with 0.5
changes sample `(1,0)` from white to gray and leaves the solid pixel
at `(0,0)`. An immediate of 2.0, a non-`LDC` word, a coverage miss, and
`use_prog` together with `use_image` leave the gray pixel unchanged.
The surface ceiling is 64×64. Sample `(32,0)` stores the same gray
and `(63,31)` stores white on the 64×32 image. On the full image,
`(0,32)` stores that gray and `(63,63)` stores white. `y = 64` leaves
the row in place. The resource image is a byte memory. Remote
2026-09-23: `tb_g6lc_apu_frag` 46 cases / 196 checks / 529 clocks,
errors=0. Fixture synth, no latches: Enable=0 is 16 ports and no
cells; Enable=1 is 2,384,119 cells / 262,456 flip-flops. The CVA6
cookie was not re-run. The TEX opcode still returns `-26`.

`g6lc_apu_vgpu_rdb` copies those bytes to guest memory, 32 bytes per
beat. The 64×64 surface lands at `64'h8800_C000`, with gray at
`(0,32)` and white at `(63,63)`. Remote 2026-09-23:
`tb_g6lc_apu_vgpu_rdb` 52 cases / 1,169 checks / 9,024 clocks,
errors=0. See `apu-resident-fw.md`.

`APU_EXEC=1 APU_SYNTH=1 bash verif/tb/apu/run-virtio-mmio.sh` runs native,
mailbox and firmware diagnostics remotely. Review rerun generic exec synthesis:
25,430 cells / 3,888 sequential bits, zero when disabled. The earlier 23,329
cell count is historical, not the current screen. No STA, physical area,
conformance or renderer claim follows.
See `apu-fw-exec.md`, `apu-tgsi.md` and `apu-resident-fw.md` for the remaining
compiler/runtime/composition gates.
