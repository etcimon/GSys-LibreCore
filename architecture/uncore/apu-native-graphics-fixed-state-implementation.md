# Bounded Native Graphics Fixed State

GSys LibreCore now validates a bounded fixed-state profile from original wire
fields before graphics pipeline allocation. Identity snapshots retain typed
state in addition to original wire/parked words. This is not drawing or shader
interface/operand/execution admission. Default GPU refusal and zero capsets stay.

## Admitted Values

The profile is triangle-list fill, single-sample, unblended color, dynamic
viewport/scissor, explicit cull/front-face and color write masks. Non-null
vertex/input-assembly/viewport/raster/multisample/color/dynamic state is required.
Tessellation/depth-stencil, primitive restart, depth clamp/bias, raster discard,
non-fill polygons, non-unit line width, sample masks/shading/alpha coverage/alpha
one and logic/blend enable remain refused.

Color count matches the retained subpass. Dynamic viewport/scissor values must
be distinct and complete; static state and additional dynamic states remain
outside this increment. Cull/front-face, blend enums and write masks are bounded.
Inactive bias factors, minimum sample shading and blend constants are not treated
as executable features.

Vertex declarations retain up to16 unique bindings and8 unique attribute
locations with explicit binding references, input rates, native formats and
offset bounds. Strides obey the pinned maxVertexInputBindingStride2048 as well
as the legacy16-bit storage bound; oversized values cannot silently truncate.
Specialization-map offsets are excluded from vertex field collection.

Validation precedes legacy allocation/pins. It returns immutable metadata, not
vertex memory operands, viewport values, shader-interface validation or work.
No unsupported field is enabled merely because the legacy keep stream omitted it.

## Evidence

450 frozen checks pass21.578s from
`~/.cache/librecore/apu/native-execution.gsm1yosb`;106 hashes unchanged and all
live/alias inputs match. Eight new cases include typed baseline/vertex/cull
state, ignored multisample fields, raster/topology, dynamic duplicates/counts,
logic/blend/color count and vertex truncation/alias refusal.
Negative subcases use fresh contexts and verify no pipeline, module pins or
backing work leases are published. Existing independent stage-specialization
tests continue to pass with scoped field collection.

Four-source MIT tier/header/ASCII/syntax/whitespace audit passes. Native presence
files=104 and default-PGO DEV PREFLIGHT OK perform no installation/build/training/
tests. Frozen lanes, warning/timeout discipline and separate compiler/simulator
PGO policy remain.

## Review And Gates

Reference/software only: no functional RTL/config/ISA/CSR/DTS/discovery,
clock/reset/SRAM/DFT/PMU or timing-cone change. Hardware tables/ABI, upstream/
link sets and spec-index statuses remain; core/Storamic work is preserved.
Uncommitted; no timing/area/power, stock renderer, RTL/CTS or silicon promotion.

Shader interfaces, vertex/index/attachment operands, dynamic state capture,
execution/fault/retirement and broader graphics states remain open. Wider
images/sync/stock feedback, RTL retained-unmap owner/alias/capacity and full
capability/software/hardware/CTS/formal/synthesis/physical/WSI gates remain.

Bounded specialized I/O declaration/link checks now follow
`apu-native-graphics-interface-implementation.md`; full shader/resources and
draw execution remain separate.
