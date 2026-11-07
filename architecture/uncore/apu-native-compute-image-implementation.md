# Owned Native Compute Images

GSys LibreCore now integrates bounded owned image operands with diagnostic
compute replay and executor retirement. Default GPU refusal, transfer-only
shader refusal and zero Vulkan capsets remain unchanged.

## Admission And Execution

`Compute.allow_images` defaults to false. Native compute replay explicitly
admits scalar UniformConstant image/sampler variables, resolves typed operands
and retains their validation callbacks and generation references. Array/depth
image variables remain refused. The existing two wire submission opt-ins still
apply; no new default or capability advertisement is introduced.

Runtime validates single-mip/single-layer 2D color metadata and emits marked
image rows using existing aux bit24 and five metadata words. Owned image
backing joins the same transactional memory leases as buffer operands;
sampler-only rows carry values/references without a memory owner. Existing
16-row,65536 binding-byte, instruction, dispatch and poll-I/O limits remain.

Storage image load/store, sampled fetch and combined/separate explicit-LOD
sampling operate on live backing shared with transfer commands. Image-kind
permissions are checked before physical alias grants. Pending regular sampler
and image-view destruction parks until references retire; immutable sampler
values need no live sampler lease. Cancellation and failed pin acquisition
release all acquired references.

The shared reference constructor previously converted explicit sampler kind0
into legacy buffer kind7. Preserve zero when aux bit24 marks an image/sampler
row; unmarked legacy rows keep their old default. This is a reference-model
correction, not proof of RTL equivalence.

Tests use GENERAL images, existing transfer-scope image transitions and validated
global transfer/compute memory scopes. Compute-aware image-barrier scope now
follows `apu-native-shader-image-barrier-implementation.md`; broader layout
handling remains separate.

## Evidence

408 frozen checks pass18.899s from
`~/.cache/librecore/apu/native-execution.yo0w8bew`;99 hashes unchanged and live
inputs match. Ten new cases cover storage read/write/readback, upload/fetch,
combined/separate sampling, view/sampler lifetime, immutable values, rollback,
I/O loss, readonly alias protection and transfer-only refusal.

The first run exposed the sampler-kind constructor bug. Expanded tests also
corrected two fixture expectations: fault retirement sets signaled/lost bits
together but wire fence status reports LOST; transfer-only mode may reject a
shader barrier before its pipeline command. No implementation was weakened.

Six-source MIT tier/header/syntax/whitespace audit passes; new source ASCII and
existing model Unicode retained. Native presence files=97 and default-PGO DEV
PREFLIGHT OK perform no installation/build/training/tests. Frozen lanes, strict
warnings/timeouts and separate compiler/simulator PGO policy remain.

## Review And Gates

Reference/software only: no functional RTL/config/ISA/CSR/DTS/discovery,
clock/reset/SRAM/DFT/PMU or timing-cone change. Hardware tables/ABI, upstream/
link sets and spec-index statuses remain; core/Storamic work is preserved.
Uncommitted; no timing/area/power, stock renderer, RTL/CTS or silicon promotion.

Broader image barriers/layouts, arrays/depth/graphics/synchronization and stock
feedback remain open. RTL retained-unmap owner/alias/capacity and full capability/
software/hardware/CTS/formal/synthesis/physical/WSI qualification remain independent.
