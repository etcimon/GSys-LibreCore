# `descriptor-indexing` — non-uniform indexing, update-after-bind, lifetimes (110 cases)

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass `vk-default/descriptor-indexing.txt`;
tests in `external/vulkancts/modules/vulkan/descriptor_indexing/vktDescriptorSetsIndexingTests*.cpp`.
Owner W2/W5 (BM-L4). Gate CTS-3 (1.2 core `descriptorIndexing` feature; VK_EXT_descriptor_
indexing before that). All 110 are NotSupported by truthful absence at apiVersion 1.1.

## Inventory

For each descriptor type — `sampler`, `sampled_image`, `combined_image_sampler`,
`storage_image`, `uniform_buffer(_dynamic)`, `storage_buffer(_dynamic)`,
`uniform_texel_buffer`, `storage_texel_buffer`, `input_attachment` — the variants
`<type>`, `_after_bind`, `_in_loop`, `_with_lod`, `_lifetime`, `_minNonUniform`,
`_no_runtime_array`, and their combinations; plus `non_uniform_atomics`. 110 cases.

## Architectural logic

```text
LOGIC DI-L1 · Non-uniform dynamic indexing of descriptor arrays
  CLAIM       shaderSampledImageArrayNonUniformIndexing (and the storage/uniform/texel/
              input-attachment counterparts): an index that differs per invocation,
              decorated NonUniform, selects the right descriptor; runtime-sized arrays
              (runtimeDescriptorArray); `_minNonUniform` uses the minimal NonUniform
              decoration placement the spec requires.
  SOURCE      descriptor_indexing.<type>{,_in_loop,_with_lod,_minNonUniform,
              _no_runtime_array}.
  MECHANISM   F5/5b already fetch the record per lane by dynamic index (the 5b LSU
              record path is per-lane) — non-uniformity is natural in a lane-serial LSU;
              the texture path fetches the record per lane too. Runtime arrays = the
              binding's count comes from the set's variable count (W2.3).
  REQUIRES    The record cache keyed by {set,binding,index} must not merge lanes with
              different indices (it does not today — it is per record); runtime arrays
              need the variable descriptor count at allocation.
  FORBIDS     Assuming wave-uniform indices anywhere in a future parallel LSU (CTS-P3).
  CHECK       the per-type base cases (CTS-3).
  COST        none today; a parallel LSU must keep per-lane record fetch.
  FEEDS       BM-L4; CTS-3.
  STATUS      not-run (NotSupported at 1.1)

LOGIC DI-L2 · Update-after-bind and partially-bound sets, descriptor lifetime
  CLAIM       descriptorBindingUpdateAfterBind*: a set bound to a command buffer may be
              updated until submission (and, for update-unused-while-pending, while
              pending if the descriptor is not used); partiallyBound: unused descriptors
              need not be valid; `_lifetime` variants destroy the backing resource of
              unused descriptors before submission.
  SOURCE      descriptor_indexing.*_after_bind*, *_lifetime*.
  MECHANISM   Records are read at use, so update-after-bind is the natural behaviour —
              the hazard is our update-time validation: a destroyed resource in an
              *unused* record must not poison the set (today any invalid element sets
              the set's poison bit → DEVICE_LOST on use). Poison must become per-record
              (the 32-byte record's valid flag) and only a *used* invalid record is
              undefined.
  REQUIRES    Per-record validity instead of per-set poison; the record cache invalidated
              by updates ordered before the use (BM-X1).
  FORBIDS     Set-level poison; validating at bind time.
  CHECK       *_after_bind_lifetime (CTS-3); engine negative: destroy an unused image
              view after bind → draw succeeds.
  COST        none (flag already in the record).
  FEEDS       ROBUSTNESS (nullDescriptor); CTS-3.
  STATUS      not-run

LOGIC DI-L3 · Non-uniform atomics
  CLAIM       Atomics through non-uniformly indexed storage buffers/images are per-lane
              correct.
  SOURCE      descriptor_indexing.non_uniform_atomics.
  MECHANISM   G3a-i lane-serial atomic RMW through the per-lane record path.
  REQUIRES    nothing beyond DI-L1.
  FORBIDS     —
  CHECK       the case (CTS-3).
  COST        none.
  FEEDS       CTS-3.
  STATUS      not-run
```

## Exceptions

```text
EXCEPTION DI-X1 · NotSupported at 1.1
  CONDITION   descriptorIndexing (1.2) / VK_EXT_descriptor_indexing not advertised.
  RESULT      NotSupported for all 110.
  TRUTH       profile; flips to required at 1.2 (INFO-L2).
  MECHANISM   Profile ROM.
  CHECK       ledger.
  FORBIDS     Advertising the feature before DI-L2's per-record validity exists.
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| DI-H1 Per-record validity | BM-X3 / 1.2 ladder | high | replace set poison with record valid + "used invalid record ⇒ robust zero or device-lost per feature" | — |
| DI-H2 Variable counts | 1.2 ladder | medium | variable descriptor count at allocation (pool accounting) | — |

## Performance / area / scalability

Per-lane descriptor fetch is already the design; the cost is the record cache's hit
rate under non-uniform indices (W1.5 counter). A future coalescing LSU must keep the
per-lane key (CTS-P3).
