# `sparse-resources` (19,078) and `protected-memory` (6,000) — sparse binding/residency, protected contexts

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass `vk-default/sparse-resources.txt`,
`vk-default/protected-memory.txt`; tests in `external/vulkancts/modules/vulkan/
sparse_resources/vktSparseResources*.cpp`, `protected_memory/vktProtectedMem*.cpp`. Owner W5
(plan: "hardware sparse residency" 0.85, "GPU VM / page faults" 0.91). Both feature sets
are optional in Vulkan; both NotSupported by truthful absence today. Gate CTS-4 (sparse),
protected memory not planned (a decision — see PM-X1).

## Inventory

| group | cases | sub-groups |
|---|---:|---|
| `sparse_resources` | 19078 | `image_sparse_residency` 4275, `shader_intrinsics` 3420 (sparse texture fetch residency codes), `image_sparse_binding` 2619, `device_group_image_sparse_binding` 2556, `image_block_shapes` 1498, `image_sparse_memory_aliasing` 848 (+ device-group twins 848/660/660), `mipmap_sparse_residency` 660, `image_rebind` 480, `aligned_mip_size` 236, `buffer` 177, `multisampled_*` 110, `queue_bind` 18, `transfer_queue` 13 |
| `protected_memory` | 6000 | `interaction` 4099, `ssbo` 1152, `buffer` 355, `image` 332, `attachment` 51, `workgroupstorage` 6, `stack` 5 |

## Architectural logic

```text
LOGIC SPARSE-L1 · Sparse binding and residency through page-granular device address spaces
  CLAIM       sparseBinding: buffers/images bound to memory in sparse blocks (block
              size reported, 64 KiB typical) via vkQueueBindSparse with semaphores;
              sparseResidencyBuffer/Image2D/3D/…: partially resident images with the
              standard block shapes per format class, mip tails, aliasing
              (sparseResidencyAliased), rebinding while in use with correct
              synchronisation; unbound regions read zero (residencyNonResidentStrict)
              or undefined-but-safe; `shader_intrinsics`: sparseTexture* return
              residency codes (sparseTexelsResidentARB).
  SOURCE      sparse_resources.* (all lists).
  MECHANISM   Plan W5.2/W5.4: a GPU page table per context (VA → device pages) with
              the sparse block as the page (or a multiple), TLB in the LSU/texture/Xfer
              address paths, non-resident reads returning zero + a residency bit the
              sampler surfaces to the shader; vkQueueBindSparse = page-table updates on
              the queue with semaphore ordering; mip tails = a packed region per the
              reported granularity.
  REQUIRES    The W5 VA model (also needed by BDA, ray tracing, DGC); page-table walk
              or TLB-miss handling without device loss.
  FORBIDS     Implementing sparse by allocating the whole resource (defeats the feature
              and misreports residency); crashing on non-resident access.
  CHECK       sparse_resources.buffer.*, image_sparse_binding.* first, then residency
              and shader_intrinsics (CTS-4).
  COST        TLBs on every address path — the W5 Pareto center.
  FEEDS       plan W5 (sampler feedback / residency), BM-L4; CTS-4.
  STATUS      not-run (NotSupported)

LOGIC PM-L1 · Protected memory (decision pending)
  CLAIM       protectedMemory: protected queues/command buffers/resources whose contents
              cannot be read by unprotected operations; interactions enumerated by the
              tests.
  SOURCE      protected_memory.*.
  MECHANISM   An isolation domain in the memory system (access control per page/queue).
              Not in the plan's feature matrix; DRM-class content protection is a
              product decision outside the UE/CS2 target.
  REQUIRES    a product decision.
  FORBIDS     —
  CHECK       —
  COST        access-control bits + a protected queue.
  FEEDS       —
  STATUS      not-run (NotSupported, not planned)
```

## Exceptions

```text
EXCEPTION SP-X1 · Not advertised
  CONDITION   all sparse* features; protectedMemory; device-group sparse variants.
  RESULT      NotSupported (25,078 cases).
  TRUTH       profile; sparse is a plan release feature (W5), protected memory is not.
  MECHANISM   Profile ROM.
  CHECK       ledger (0 fail).
  FORBIDS     Advertising sparseBinding without the page-table path.
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| SP-H1 One VA model | W5.2 | precondition | design the page table/TLB once for BDA, sparse, RT, DGC | — |
| SP-H2 Buffers before images | W5.4 | high | sparse buffers (no block shapes) end to end | — |

## Performance / area / scalability

Sparse residency is the mechanism behind streaming textures in UE (virtual texturing
can also be software); the TLB reach vs texel-rate trade-off is a W5 measurement.
Correctness-preserving: TLB invalidation on bind must drain in-flight accesses (plan
W5.4 "atomic mapping publication").
