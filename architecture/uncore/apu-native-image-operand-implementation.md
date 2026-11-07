# Native Image Descriptor Ownership

GSys LibreCore now captures typed image/view/sampler descriptor provenance and
resolves bounded owned operands. This increment does not admit shader-image
execution. Default GPU refusal, diagnostic compute opt-ins and zero Vulkan
capsets remain unchanged.

## Generations And Values

Native image views retain the source image's canonical generation, not only
its slot. Descriptor updates capture view/image/memory/sampler generations,
binding and image/view metadata, sampler words and descriptor layout. Stale
image reuse beneath an old view poisons the update rather than redirecting it.
Buffer provenance retains its existing representation and validates its type.

Descriptor copies preserve source provenance independently of source-set
lifetime. Immutable destination sampler words replace sampler provenance;
immutable sampler-only descriptors are seeded by value at allocation. Neither
sampler-ID nor set-layout storage reuse redirects those retained values.
Native cross-type descriptor copies poison the destination instead of mixing
unrelated provenance representations. Default hardware reference behavior stays.

The resolver checks set/pool epoch, retained layout, device ownership, generations,
binding/range, packed-record integrity and mutation during descriptor reads.
Returned references/validation callbacks do not acquire leases or publish work.
Callers must perform transactional object/backing lease acquisition before use.

The admitted operand profile is single-mip/single-layer 2D color views, including
bounded mip/layer subviews, and sampler/combined/sampled/storage descriptor kinds.
Storage descriptors require GENERAL; sampled descriptors allow GENERAL or
SHADER_READ_ONLY. Image footprint, pitch, format, usage and owned allocation
must agree. Depth, wider views and other unsupported shapes fail closed.

## Evidence

398 frozen checks pass19.826s from
`~/.cache/librecore/apu/native-execution.3u4m0xvv`;98 hashes unchanged and live
inputs match. Sixteen new cases cover owned resolution without pins, sampled/
combined/storage kinds, generation reuse, immutable sampler/layout reuse and
updates, immutable copies, source-set free, subviews, layout/range metadata,
rebinding, packed bytes, mid-read mutation, pool reset and executor refusal.

Five-source MIT tier/header/syntax/whitespace audit passes; new sources ASCII.
Native presence files=96 and default-PGO DEV PREFLIGHT OK perform no installation/
build/training/tests. Frozen lanes, warnings/timeouts and separate compiler/
simulator PGO policy remain.

## Review And Gates

Reference/software only: no functional RTL/config/ISA/CSR/DTS/discovery,
clock/reset/SRAM/DFT/PMU or timing-cone change. Hardware tables/ABI, upstream/
link sets and spec-index statuses remain; core/Storamic work is preserved.
Uncommitted; no timing/area/power, stock renderer, RTL/CTS or silicon promotion.

Bounded compute image execution and leases now follow
`apu-native-compute-image-implementation.md`. Shader image barriers and
broader graphics/sync/stock feedback remain open. RTL retained-unmap owner/alias/
capacity and full capability/software/hardware/CTS/formal/synthesis/physical/
WSI qualification remain independent.
