# Native Graphics Resource Requirements

GSys LibreCore now validates vertex/fragment resource declarations against the
retained pipeline layout before graphics pipeline allocation. This is requirement
metadata, not descriptor binding, push-value admission, live fetch or drawing.
Default GPU refusal, diagnostic gates and zero Vulkan capsets remain unchanged.

## Requirements And Profile

Each pipeline retains immutable per-stage binding requirements and occupied push
word indices. Descriptor set/binding decorations must be explicit. Layout rows
must match resource class, array count and selected-stage visibility.

UBO/SSBO fixed descriptor arrays are bounded to16 elements; dynamic layout types
are retained separately from shader resource class. Scalar samplers, combined
samplers, sampled images and storage images use the bounded non-depth/non-array
2D profile. Equivalent same-stage aliases share a requirement; incompatible
aliases refuse. Each stage is bounded to16 descriptor elements.

Exact Block/BufferBlock decorations are read without changing the shared scanner:
its packed flags intentionally alias decoration bits. Legacy Uniform BufferBlock
is classified as storage, not UBO; this does not admit its execution semantics.
Runtime descriptor arrays and missing/incompatible layout rows refuse.

One push block per stage is supported, limited to a flat Block struct with
explicit, nonoverlapping scalar/vector-member offsets within128 bytes. Every
occupied word requires matching layout stage/range coverage. Padding holes are
not treated as required values. Nested/array/matrix push shapes remain refused;
natural type size must not stand in for a strided memory footprint.

Requirements use specialized shader copies and by-value layout identity. Original
module provenance remains intact. All declared resources are conservatively
checked, not only CFG/static-use resources. This is not full SPIR-V validation,
descriptor operand resolution or a change to legacy tables/ABI.

## Evidence

516 frozen checks pass27.683s from
`~/.cache/librecore/apu/native-execution.rqsh4n2o`;116 hashes unchanged and all
live/alias inputs match. Seventeen new cases cover empty/shared stage requirements,
dynamic buffer arrays, image/sampler classes, type/count/visibility/set/binding
refusals, explicit decorations, push offsets/holes/shape/extent, legacy BufferBlock,
descriptor budgets, runtime arrays, specialization, aliases and layout reuse.
Negative subcases use fresh contexts and check no pipeline allocation/module
pins/backing work leases. Layout reuse destroys the old descriptor-set layout
before reusing its wire ID.

Four-source MIT tier/header/ASCII/syntax/whitespace audit passes. Native presence
files=114 and default-PGO DEV PREFLIGHT OK perform no installation/build/training/
tests. Frozen lanes, warning/timeout discipline and separate compiler/simulator
PGO policy remain.

## Review And Gates

Reference/software only: no functional RTL/config/ISA/CSR/DTS/discovery,
clock/reset/SRAM/DFT/PMU or timing-cone change. Hardware tables/ABI, upstream/
link sets and spec-index statuses remain; concurrent core/Storamic work is
preserved. Uncommitted; no timing/area/power, stock renderer, RTL/CTS or silicon
promotion.

Graphics descriptor/push binding state, live vertex/index fetch, ordered
clear/raster execution and transactional fault/retirement remain open. Wider
images/sync/stock feedback, RTL retained-unmap owner/alias/capacity and full
capability/software/hardware/CTS/formal/synthesis/physical/WSI gates remain
independent.
