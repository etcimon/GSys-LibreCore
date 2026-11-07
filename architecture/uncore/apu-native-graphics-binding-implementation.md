# Native Graphics Binding-State Operands

GSys LibreCore now resolves recording-scoped graphics descriptor/push binding
state into per-stage owned operands. This is an internal planning helper, not
queue integration, shader invocation or draw replay. Default GPU refusal,
diagnostic gates and zero Vulkan capsets remain unchanged.

## State And Ownership

The helper requires a generation/context/device/epoch-checked recording identity
and consumes that recording's records in order. Graphics pipeline binds retain
canonical pipeline identity; compute bind-point operations do not replace
graphics state. Other commands return unhandled for a future outer compiler.

Descriptor binds validate retained layout signatures and pool generations,
assign dynamic offsets in binding/element order and apply prefix-compatible
layout disturbance. Set/offset changes are staged before commit. Push updates
validate exact record-local bytes, per-word stage/range coverage and retain
stage-specific values with their by-value push layout. Failed updates do not
partially define earlier state. Compute-only push updates leave graphics values
unchanged.

Resolution follows immutable per-stage pipeline requirements through the existing
buffer/image descriptor resolvers. Required push words must be defined using a
compatible retained push layout. The result retains immutable per-stage bindings
and push values, object references and a late validation callback.

References cover pipeline/modules/device, command buffer/pool and resolved
descriptor resources. Late guards cover recording reset, pool/descriptor changes,
resource provenance and the original pipeline snapshot. Later builder binds
cannot redirect a previously resolved result. Existing pipeline pins may retain
destroyed shader modules; their provenance remains valid.

Descriptor headers are read for validation; vertex/index/image contents are not.
No work/object leases, writes, fence transitions or queued operations are added.
The caller still must validate executable command-buffer state, compose active
pass/dynamic/vertex/index state and secondary semantics, acquire all resource
and backing leases transactionally, rerun guards and execute in order. Legacy
tables/ABI and the existing compute executor are unchanged.

## Evidence

536 frozen checks pass31.259s from
`~/.cache/librecore/apu/native-execution.o7ilrpmm`;118 hashes unchanged and all
live/alias inputs match. Twenty new cases cover per-stage UBO/image operands,
array dynamic offsets, push/compute isolation, missing resources, rewrites,
pool/CB reset, record ordering, disturbance, atomic failed bind/push updates,
prior-result identity, module lifetime, read-time pipeline retirement,
alignment, local payload bounds and explicit GPU replay refusal.

Three-source MIT tier/header/ASCII/syntax/whitespace audit passes. Native presence
files=116 and default-PGO DEV PREFLIGHT OK perform no installation/build/training/
tests. Frozen lanes, warning/timeout discipline and separate compiler/simulator
PGO policy remain.

## Review And Gates

Reference/software only: no functional RTL/config/ISA/CSR/DTS/discovery,
clock/reset/SRAM/DFT/PMU or timing-cone change. Hardware tables/ABI, upstream/
link sets and spec-index statuses remain; concurrent core/Storamic work is
preserved. Uncommitted; no timing/area/power, stock renderer, RTL/CTS or silicon
promotion.

Full draw-state composition, live vertex/index fetch, ordered clear/raster
execution and transactional fault/retirement remain open. Wider images/sync/
stock feedback, RTL retained-unmap owner/alias/capacity and full capability/
software/hardware/CTS/formal/synthesis/physical/WSI gates remain independent.
