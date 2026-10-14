# `memory` — allocation, mapping, binding, barriers, requirements (6,279 cases)

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass `vk-default/memory.txt`; tests in
`external/vulkancts/modules/vulkan/memory/vktMemory*.cpp`. Owner W2 (3d-c/3d-d memory
model: two heaps, lazy guest backing, `MAP_BLOB` relocation). Gate CTS-1.

## Inventory (`cts_ledger.py tree --group memory --depth 3 --min-cases 30`)

| prefix (`dEQP-VK.memory.`…) | cases |
|---|---:|
| `mapping` (`dedicated_alloc` 2844, `suballocation` 1622) | 4466 |
| `zero_initialize_device_memory` (`image_transition` 432, `clear_buffer` 64) | 496 |
| `binding` (`maintenance6` 168, `priority` 56, `priority_dynamic` 56, `regular` 42) | 336 |
| `allocation` (`basic` 102, `random` 100) | 202 |
| `device_group_allocation` (`basic` 102, `random` 100) | 202 |
| `pageable_allocation` (`basic` 102, `random` 100) | 202 |
| `pipeline_barrier` | 104 |
| `requirements` | 77 |
| `decompression` (`direct` 36, `indirect` 36) | 72 |
| `device_memory_report` / `address_binding_report` | 43 / 41 |
| **total** | 6279 |

## Architectural logic

```text
LOGIC MEM-L1 · Allocation and mapping over every memory type, any size, any pattern
  CLAIM       vkAllocateMemory succeeds up to maxMemoryAllocationCount allocations and
              the heap budget, for each type; vkMapMemory/UnmapMemory with offsets and
              sizes (incl. VK_WHOLE_SIZE), flush/invalidate of mapped ranges at
              nonCoherentAtomSize granularity, re-mapping, random sequences of map/write/
              flush/invalidate/read, and sub-allocation of many buffers in one allocation
              all observe the data written by the host and by the device, in both
              directions, exactly.
  SOURCE      memory.mapping.{dedicated_alloc,suballocation}.* (4466: full/sub ranges,
              random, flush/invalidate variants), memory.allocation.{basic,random}.*,
              memory.requirements.*; vktMemoryMappingTests.cpp, vktMemoryAllocationTests.cpp.
  MECHANISM   Heap 1 (guest span, HOST_VISIBLE|HOST_COHERENT, lazy — backed only by
              MAP_BLOB) and heap 0 (private, DEVICE_LOCAL); Venus maps through the
              blob/aperture path (RESOURCE_MAP_BLOB with kernel-chosen offsets, 3d-b),
              3d-d bind-time backing + relocation; the APU reads guest RAM through the
              DMA window with the stock non-coherent DMA contract (CMO/uncached aperture).
  REQUIRES    HOST_COHERENT means no device-side cache sits between the CPU mapping and
              the DMA path (true today: no device cache; W5.6 must keep host-visible
              memory uncached or snoop it); flush/invalidate are no-ops for coherent
              types but the tests use them — accept; maxMemoryAllocationCount (4096
              minimum) honoured by the ObjTab/vgpages capacity.
  FORBIDS     Copy-on-map that misses device writes after the map (the 3d-d relocation
              design moves the backing once, before use — keep that invariant under
              concurrency, W2.1); silently aliasing two allocations in one aperture range.
  CHECK       memory.mapping.suballocation.full.* first, then random.* (CTS-1); engine:
              the 3d-d vkmem session + the relocation vectors.
  COST        page-table granularity (4 KiB) and the aperture size (32 MiB today → the
              W5.3 indirection) bound total host-visible memory; mapping cost = kernel
              MAP_BLOB round trips.
  FEEDS       API-L3, SSBO/UBO; CTS-1.
  STATUS      not-run

LOGIC MEM-L2 · Binding rules and pipeline barriers
  CLAIM       vkBind{Buffer,Image}Memory(2) at any legal offset/alignment, re-binding
              rules (one bind per resource), memory priority (EXT, optional),
              maintenance6 bind-status variants; vkCmdPipelineBarrier memory barriers
              make writes visible to subsequent reads for every stage/access pair the
              test enumerates (host→device, transfer→shader, shader→transfer, …).
  SOURCE      memory.binding.{regular,priority*,maintenance6}.*, memory.pipeline_barrier.*
              (104: host_write_*, transfer_*, …); vktMemoryBindingTests.cpp,
              vktMemoryPipelineBarrierTests.cpp.
  MECHANISM   vnfront BIND with the wrap-safe range check; barriers are no-ops in the
              serialized single-engine executor *today* — the claim holds only while
              there is no device cache and one engine at a time; W5 (caches, multiple
              engines) turns the barrier record into real cache maintenance and
              engine fences (plan W2.4 explicit proof per cache/observer).
  REQUIRES    A documented statement per release config of why each barrier is
              satisfied (RT-P1: name the instrument); priority = NotSupported unless the
              EXT is advertised.
  FORBIDS     Keeping barriers as no-ops after any cache or second engine exists.
  CHECK       memory.pipeline_barrier.* (CTS-1 now; re-run as a fails-if-removed control
              when W5 adds a cache — the first test to go red when a barrier is missing).
  COST        none now; W5's cache maintenance cost later.
  FEEDS       SYNCHRONIZATION-L*; CTS-1, W5.
  STATUS      not-run

LOGIC MEM-L3 · Zero-initialised device memory (1.4-era) and reports (EXT)
  CLAIM       VK_EXT_zero_initialize_device_memory: newly allocated memory reads as zero
              after an image transition / buffer clear; device memory report and address
              binding report callbacks (EXT) enumerate allocations.
  SOURCE      memory.zero_initialize_device_memory.*, device_memory_report.*,
              address_binding_report.*, pageable_allocation.* (EXT_pageable_device_local
              _memory), decompression.* (NV).
  MECHANISM   Not advertised; zero-init would be a vgpages clear on ALLOC (cheap, and a
              good default for security of the private arena).
  REQUIRES    decision when 1.4 extensions are pinned.
  FORBIDS     —
  CHECK       ledger (NotSupported).
  COST        clear bandwidth on allocation.
  FEEDS       W5.
  STATUS      not-run (NotSupported)
```

## Exceptions

```text
EXCEPTION MEM-X1 · Allocation failure
  CONDITION   Heap exhausted (private arena or guest span pages), or
              maxMemoryAllocationCount reached.
  RESULT      VK_ERROR_OUT_OF_DEVICE_MEMORY (heap 0) / VK_ERROR_OUT_OF_HOST_MEMORY as
              Venus maps it; never a later fault.
  TRUTH       The tests size allocations from the reported heap sizes; the reported
              sizes must be the real capacities (two-heap truthfulness, 3d-c).
  MECHANISM   vgpages FULL → vnfront result mapping.
  CHECK       memory.allocation.random.* (allocates until failure deliberately in
              some variants); engine ue_cneg_evict_full_1.
  FORBIDS     Reporting a heap larger than the backing.

EXCEPTION MEM-X2 · NotSupported by truthful absence
  CONDITION   device_group_allocation.* beyond one device (the one-device group variants
              must pass — DG-L1), pageable_allocation.*, decompression.*,
              device_memory_report.*, address_binding_report.*, binding.priority*,
              binding.maintenance6 (1.4), zero_initialize_device_memory.*.
  RESULT      NotSupported.
  TRUTH       profile lines; maintenance6 flips at 1.4.
  MECHANISM   Profile ROM.
  CHECK       ledger.
  FORBIDS     —
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| MEM-H1 Mapping first | CTS-1 | high | `mapping.suballocation.full.*` + `random.*` — the 3d-d acceptance | — |
| MEM-H2 Barrier control | first cache/second engine | precondition | keep `pipeline_barrier.*` in every CTS-1+ run as the fails-if-removed control | — |
| MEM-H3 Requirements/invariance | api.invariance red | medium | stable requirements per (usage, flags) | — |

## Performance / area / scalability

Host-visible memory is bounded by the aperture (32 MiB, `APU_SHM_BYTES`) until W5.3
replaces copy-on-map with hardware indirection; the page allocator scales (proven at
65,536 pages). Knobs: aperture size, page size, private arena split. Correctness-
preserving: relocation must drain all engines that may reference the moving range (the
`map_hold` interlock) — a parallel engine design must keep that drain.
