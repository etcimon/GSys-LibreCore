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

- `ExecRegs` legality currently allows 8..32 but the implementation fixes
  eight registers and three-bit debug indices. DMEM debug indexing has six
  bits while configuration permits larger memories. Make parameters truthful
  or reject unsupported geometries; no silent truncation is allowed.
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
- Implement vertex fetch/shading, clipping/setup, top-left coverage and
  interpolation, texture filtering/wrap/mip/LOD, fragment execution,
  depth/stencil/blend and format-correct output as real APU work. Dedicated
  sampler/raster units are optional optimizations, not omitted semantics.
- Validate numerical precision/invariance and fused versus unfused arithmetic;
  a single exact FMADD case is not shader conformance.

## Evidence boundary

Historical baseline includes TID/IADD, mask, FP32 arithmetic, LDC, quad exchange,
BR, local LD/ST and a scanline-shaped loop writing `1.0f` to four DMEM words.
That loop redundantly runs over invocation contexts; it is not coverage,
interpolation, packed RGBA8 output or Linux `glReadPixels`.

`APU_EXEC=1 APU_SYNTH=1 bash verif/tb/apu/run-virtio-mmio.sh` runs native,
mailbox and firmware diagnostics remotely. Review rerun generic exec synthesis:
25,430 cells / 3,888 sequential bits, zero when disabled. The earlier 23,329
cell count is historical, not the current screen. No STA, physical area,
conformance or renderer claim follows.
See `apu-fw-exec.md`, `apu-tgsi.md` and `apu-resident-fw.md` for the remaining
compiler/runtime/composition gates.
