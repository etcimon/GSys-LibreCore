# Native Compute Pipeline Snapshots

GSys LibreCore now validates native compute-pipeline operands without enabling
wire dispatch. Default GPU refusal/zero Vulkan capsets remain.

The existing decoder's bounded trace locates actual module/layout/stage/name
fields without changing ROM. Validate counts/flags, selected entry, compute
stage, common device/layout and4096-word code bound. Store immutable code,
layout, context-owner and canonical module snapshots. Nonempty specialization
remains explicitly unsupported, never approximated.

Resolution accepts the pipeline's pinned canonical zombie module after shader
module destruction, not a new object using the same wire ID. Check parked module
association/code/device and return three required references; no lease or work
publication occurs here. Pipeline layout destruction cannot redirect the saved
value. Caller replay must acquire object/parent/memory leases transactionally.

274 frozen checks pass18.256s from
`~/.cache/librecore/apu/native-execution.0i3uftok`;87 hashes unchanged and live
inputs match. Seven cases cover selected entry, module/layout destruction and
reuse, wrong entry/stage, pipeline generation and code tamper.
Four-source MIT tier/header/ASCII/syntax/whitespace audit passes. Presence checks
remain no-build; PGO/unroll and strict receipt/timeout policies stay.

Review: host-only, no functional RTL/config/ISA/CSR/DTS/discovery, clock/reset/
SRAM/DFT/PMU or timing cone changes. Hardware tables/ABI, upstream/link sets and
spec-index statuses stay. No timing/area/power/stock/RTL/CTS promotion; core/
Storamic work is preserved and changes uncommitted.

Next: descriptor/dynamic/push replay, generation leases and bounded asynchronous
wire dispatch/fences. Specialization, broader shaders/images/graphics/sync and
stock fault-feedback remain. RTL retained-unmap owner/alias/capacity and full
capability/software/hardware/formal/synthesis/physical/WSI/silicon gates stay.

Bounded scalar specialization now follows
`apu-native-specialization-implementation.md`; source provenance and specialized
execution code are retained separately. Full specialization remains open.

Internal generation-leased replay now follows
`apu-native-compute-replay-implementation.md`; wire shader submission remains
refused until its own queue/fence/fault checks are integrated.

Bounded native graphics stage/layout/render-pass identity now follows
`apu-native-graphics-identity-implementation.md`. This does not admit drawing.
Diagnostic compute wire admission is recorded separately in
`apu-native-compute-submit-implementation.md`; default GPU refusal remains.
