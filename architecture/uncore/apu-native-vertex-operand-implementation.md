# Native Vertex And Index Buffer Operands

GSys LibreCore now captures native vertex/index binding provenance and resolves
owned spans without admitting draw replay. Default GPU refusal, diagnostic gates
and zero Vulkan capsets remain unchanged.

## Capture And Ownership

The legacy recorder already retains buffer generations. Native metadata now also
retains device/context, memory generation, memory binding, logical buffer size,
usage and full64-bit binding offsets. Vertex first/count are checked before
legacy16-bit masking; counts/payloads must match exactly within16 bindings.

Index bindings admit only UINT16/UINT32, preserving type and full offsets.
Usage, same-device ownership, logical allocation extents and index alignment are
validated before recording. Null/missing/stale operands are not fabricated.
Binding memory must already exist; this does not add sparse or null binding.

The resolver checks recorded buffer/memory generations and immutable binding/
usage/size provenance. It returns an owner-relative span, references and a late
validation callback. Pending frees, context retirement, rebinding and handle
reuse fail closed. Explicit index byte lengths must match element alignment.
No vertex/index contents are read and no work/object leases are acquired.

Future replay must hold command-buffer/resource/backing leases transactionally,
rerun guards and consume live data after prior queued writes. Vertex format
alignment, fetch/index bounds, draw arithmetic and actual execution remain
separate. Existing legacy record/table ABI is unchanged.

## Evidence

474 frozen checks pass33.942s from
`~/.cache/librecore/apu/native-execution.zpmxff9i`;110 hashes unchanged and all
live/alias inputs match. Twelve new cases cover metadata/owned spans, multiple
bindings, index types, buffer reuse, rebinding, late usage mutation, logical
length/pending-free refusal, full first/count and64-bit offset bounds, alignment/
usage, retirement and explicit replay refusal.

Fresh-context negative subcases ensure stream faulting cannot hide later cases.
No pipeline/draw work or backing work leases are published.

Four-source MIT tier/header/ASCII/syntax/whitespace audit passes. Native presence
files=108 and default-PGO DEV PREFLIGHT OK perform no installation/build/training/
tests. Frozen lanes, warning/timeout discipline and separate compiler/simulator
PGO policy remain.

## Review And Gates

Reference/software only: no functional RTL/config/ISA/CSR/DTS/discovery,
clock/reset/SRAM/DFT/PMU or timing-cone change. Hardware tables/ABI, upstream/
link sets and spec-index statuses remain; core/Storamic work is preserved.
Uncommitted; no timing/area/power, stock renderer, RTL/CTS or silicon promotion.

Full shader/resources, dynamic/attachment state, transactional execution/fault/
retirement and broader graphics remain open. Wider images/sync/stock feedback,
RTL retained-unmap owner/alias/capacity and full capability/software/hardware/
CTS/formal/synthesis/physical/WSI gates remain independent.
