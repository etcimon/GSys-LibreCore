# Bounded Native Image Region Copies

GSys LibreCore's opt-in native transfer backend now replays buffer-to-image,
image-to-buffer and same-format image-to-image region copies. This is host-model
data movement, not shader execution, a stock Vulkan renderer or RTL admission.
Default GPU submission remains refused; zero Vulkan capsets remain advertised.

## Implemented Boundary

- Consume actual recorded region payloads under existing snapshot/record/job/
  byte budgets. Expand regions into at most256 shared row operations, rejecting
  oversized row/layer work before looping or acquiring leases.
- Validate image, parent and memory-binding generations; image dimensions,
  format, type, mip/layer counts, layer size and logical allocation bounds must
  agree with the pinned descriptor ABI.
- Use the existing64-byte row pitch, packed mip offsets and array-layer size.
  Supported raw color texels retain their bytes; padding is not copied or
  overwritten. 1D/2D color images, mip levels and array layers are handled.
- Validate buffer row length/image height/offset, color aspects, rectangles,
  source/destination enum layouts and all physical cross-region overlap before
  enqueue. Copies execute in command order against live memory.
- Retain image/buffer/parent and executor memory leases. Native image binding,
  rebinding and destruction park while relevant work is pending. Relocation,
  cancellation, reset and fence retirement use the existing bounded executor.

Only GENERAL/transfer enum layouts are accepted for copy operands. Image
barrier/layout-transition implementation is still open; these isolated region
tests are not complete valid stock Vulkan rendering traces. Image barriers are
not silently accepted as no-ops. 3D, depth/stencil, cross-format copy, clear,
resolve and blit work remain rejected by this profile.

Follow-up: bounded coherent image barriers are now implemented under
`apu-native-image-barrier-implementation.md`; broader image/layout/synchronization
semantics and stock/hardware admission remain open.

## Frozen Evidence

210 checks pass in12.023s from
`~/.cache/librecore/apu/native-execution.b8434dfq`; all76 frozen hashes remain
unchanged and current inputs match. Thirteen new cases exercise actual wire
recording, buffer/image round trips, pitched padding, array/mip addressing,
image subrectangles, late invalid regions, operation budgets, stale bindings,
alias overlap, bad layouts/aspects/strides, pending destruction/relocation,
reset, byte texels, depth refusal and opt-in submit/fence ordering.

Four-source MIT tier/header/ASCII/syntax/whitespace audit and native/default-PGO
presence checks pass without installation/build/training. Existing strict
receipt/timeout behavior remains enabled. No generated-simulator throughput,
RTL/CTS, stock-renderer equivalence or conformance is claimed.

## Review And Next Work

Host-only tooling: no functional RTL/config/ISA/CSR/DTS/discovery, clock/reset,
SRAM/DFT/PMU or timing-cone change. Pinned hardware profile/command tables,
upstream notices/link sets and PGO policy remain unchanged. No spec-index or
capability promotion. Core/Storamic work is preserved; changes are uncommitted.

Next: validated image barriers/layout handling, broader image operations and
bounded shader execution; stock fault/feedback retirement and broader required
synchronization; RTL unmap ownership/capacity/alias reconciliation. Truthful
capset admission and stock-software/hardware/CTS/aggregate/formal/synthesis/
physical/WSI/timing/area/power/silicon qualification remain separate/open.
