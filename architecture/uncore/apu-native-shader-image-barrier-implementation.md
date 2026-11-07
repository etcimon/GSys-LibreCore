# Coherent Native Shader Image Barriers

GSys LibreCore now admits bounded compute image shader scopes and read-only
image layouts in native replay. Default GPU refusal, transfer-only shader
refusal, the two diagnostic compute opt-ins and zero Vulkan capsets remain.

## Scope And Ownership

Image barriers allow shader read/write only in explicit compute mode, using
compute or all-commands stage compatibility. Image scopes do not borrow buffer
uniform/indirect access permissions. Shader writes require GENERAL and storage
usage; shader reads require GENERAL or SHADER_READ_ONLY and sampled/storage
usage. Read-only layouts require sampled usage even without a shader access
mask and accept only shader-read/generic memory-read access.

SHADER_READ_ONLY is admitted as an old/new layout only in compute mode.
Transfer-only mode continues to refuse both shader access and that layout.
Existing color-format/subresource bounds, ignored queue-family requirements,
recorded generations, command-buffer device ownership and backing leases remain.
Unsupported depth, ownership-transfer and stage/access combinations fail closed.

The coherent linear model performs no cache or format/layout conversion.
Typed zero-byte operations retain image backing until ordered retirement.
This does not track per-subresource current layouts or establish full Vulkan
synchronization semantics. Queue/semaphore ordering remains the existing path.

## Evidence

417 frozen checks pass15.207s from
`~/.cache/librecore/apu/native-execution.s1k9b66c`;100 hashes unchanged. All live
inputs match, including the two frozen helper aliases mapped to their original
bridge client/header sources.

Nine new cases cover wire storage dispatch/barrier/readback/fence, upload to
read-only sampled fetch, barrier-only lifetime and return transitions,
transfer-only refusal, incompatible layouts, stage/access/ownership/aspect
refusal, image usage, cancellation and recorded-generation reuse.
The old compute-image refusal test now specifically names its missing-usage
reason. Runtime image operands are also explicitly required by presence preflight,
not merely discovered by the tool glob.

Four-source MIT tier/header/ASCII/syntax/whitespace audit passes. Native presence
files=98 and default-PGO DEV PREFLIGHT OK perform no installation/build/training/
tests. Frozen lanes, warning/timeout discipline and separate compiler/simulator
PGO policy remain.

## Review And Gates

Reference/software only: no functional RTL/config/ISA/CSR/DTS/discovery,
clock/reset/SRAM/DFT/PMU or timing-cone change. Hardware tables/ABI, upstream/
link sets and spec-index statuses remain; core/Storamic work is preserved.
Uncommitted; no timing/area/power, stock renderer, RTL/CTS or silicon promotion.

Broader layouts/subresources, arrays/depth/graphics/synchronization and stock
feedback remain open. RTL retained-unmap owner/alias/capacity and full capability/
software/hardware/CTS/formal/synthesis/physical/WSI qualification remain independent.
