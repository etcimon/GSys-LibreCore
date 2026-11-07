# Native Graphics Draw-State Plans

GSys LibreCore now composes nonexecuting per-draw plans from recording-scoped
graphics state. This is an internal planning helper, not queue integration,
vertex/index fetch, rasterization or draw replay. Default GPU refusal,
diagnostic gates and zero Vulkan capsets remain unchanged.

## Composition

`GraphicsDraws` consumes a generation/context/device/epoch-checked command
recording in order, delegating graphics pipeline/descriptor/push records to the
binding-state resolver and tracking viewport/scissor, vertex/index bindings and
the active render pass itself. Compute bind-point records return unhandled.

A `vkCmdDraw`/`vkCmdDrawIndexed`/`vkCmdDrawIndirect`/
`vkCmdDrawIndexedIndirect` record produces an immutable `DrawPlan` only inside
an active render pass with viewport and scissor state. The plan retains the
pipeline snapshot, per-stage descriptor/push operands, the begin-pass identity,
framebuffer color-attachment operands, raw viewport/scissor words, per-attribute
guarded vertex spans, the typed index span or the indirect argument span, object
references and a late validation closure.

Indirect draws are bounded to one 16-byte (draw) or 20-byte (indexed) argument
record at a 4-byte-aligned offset inside an INDIRECT-usage buffer; drawCount 0
is a recorded no-op matching the golden work-item rule. Indexed indirect draws
still require a bound index buffer. Vertex/index spans resolve through the
existing provenance guards without reading element data; the raster contract
already defines robust out-of-range attribute reads.

The plan's late guard revalidates the recording epoch, every operand
provenance/retirement check, descriptor contents, framebuffer attachments and
the original pipeline snapshot. Later binds cannot redirect an earlier plan.
No work/object leases, memory writes, fence transitions or queued operations
are added; descriptor headers and attachment metadata are read for validation.

## Interop Fix

`vkCmdPushConstants` carries no bind point, so graphics binding state now
consumes it only when stageFlags are a nonempty subset of vertex|fragment
(0x11). Compute-stage pushes return unhandled for the compute resolver instead
of being silently swallowed with empty staged state.

## Evidence

553 frozen checks pass17.947s from
`~/.cache/librecore/apu/native-execution.ybg764m8`;120 hashes unchanged and all
live/alias inputs match. Seventeen new cases cover direct/indexed/indirect plan
fields, vertex-attribute spans, typed indices, signed vertexOffset bits,
missing pass/dynamic/binding refusals, render-pass compatibility, per-draw
operand independence, compute-push isolation, indirect profile bounds,
record-order enforcement and explicit GPU replay refusal.

Four-source MIT tier/header/ASCII/syntax/whitespace audit passes. Native
presence files=118 and default-PGO DEV PREFLIGHT OK perform no
installation/build/training/tests. Frozen lanes, warning/timeout discipline
and separate compiler/simulator PGO policy remain.

## Review And Gates

Reference/software only: no functional RTL/config/ISA/CSR/DTS/discovery,
clock/reset/SRAM/DFT/PMU or timing-cone change. Hardware tables/ABI, upstream/
link sets and spec-index statuses remain; concurrent core/Storamic work is
preserved. Uncommitted; no timing/area/power, stock renderer, RTL/CTS or
silicon promotion.

Live vertex/index fetch, ordered clear/shader/raster execution, transactional
lease/fault/retirement composition, secondary command-buffer semantics,
broader image/sync/stock feedback, RTL retained-unmap owner/alias/capacity and
full capability/software/hardware/CTS/formal/synthesis/physical/WSI gates
remain open.
