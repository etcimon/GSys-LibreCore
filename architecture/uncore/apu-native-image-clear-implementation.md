# Bounded Native Color Clears

GSys LibreCore's opt-in native transfer profile now replays recorded color-image
clears with bounded texel patterns. Default GPU refusal and zero Vulkan capsets
remain; this is host-model evidence, not shader/stock-renderer/RTL admission.

## Clear And Payload Boundary

- Validate GENERAL/transfer-destination layouts, color aspects, bounded ranges,
  explicit/REMAINING mip and layer counts, descriptor/binding generations and
  duplicate subresources before enqueue.
- Reuse the pinned format conversion rules for UNORM/BGRA/sRGB, half/fp32 and
  integer texels. Preserve row padding and unaffected mip/layer data under the
  existing64-byte pitch ABI.
- Retain only a1/2/4/8/16-byte immutable texel pattern per row operation, not a
  whole expanded image. Pattern phase survives chunks/budget leftovers smaller
  than a texel. Row/job/byte/lease/cancellation limits remain shared.
- Record the exact staged payload length as host metadata. Replay validates
  every read against that record's extent, including update-buffer subpayload
  offsets. Inconsistent counts cannot consume neighboring record words.
- The added metadata does not enter `sess_rec_words` or change the16-word RTL
  record ABI; a directed packing regression checks this.

1D/2D raw color images and existing native coherent barriers are supported.
3D/depth/stencil, blits/resolves, broader synchronization and shaders remain
outside this increment. No layout-validation-layer or full renderer claim.

## Frozen Evidence

230 checks pass in30.925s from
`~/.cache/librecore/apu/native-execution.jkyhmbrg`; all79 hashes remain unchanged
and live inputs match. Ten new cases cover padded UNORM clears, half and128-bit
integer values, BGRA/sRGB conversion, remaining mip/layer ranges, partial-texel
chunks, malformed clear/update payloads, fixed record packing and duplicate/
malformed pattern rejection.

Six-source MIT tier/header/syntax/whitespace audit passes; new code ASCII,
existing golden Unicode preserved. Native/default-PGO presence passes without
install/build/training. Strict warning/error and timeout receipt rules remain
enabled. Host duration is not simulator throughput or PGO evidence.

## Review And Open Gates

Host-only tooling; no functional RTL/config/ISA/CSR/DTS/discovery, clock/reset,
SRAM/DFT/PMU or timing-cone change. Pinned hardware profile/tables, upstream
notices, link sets and PGO policy remain untouched. No spec-index/capability
promotion. Core/Storamic work is preserved; changes remain uncommitted.

Remaining: broader image and shader execution; full required synchronization
and stock execution-error/feedback retirement; RTL unmap ownership/capacity/
alias reconciliation; truthful capability admission. Software/hardware/CTS/
aggregate/formal/synthesis/physical/WSI/timing/area/power/silicon qualification
remain separate/open gates.
