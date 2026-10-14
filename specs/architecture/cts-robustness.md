# `robustness` — robust buffer/image access, robustness2, null descriptors, pipeline robustness (96,843 cases)

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass `vk-default/robustness.txt`; tests in
`external/vulkancts/modules/vulkan/robustness/vktRobustness*.cpp`. Owner W3 (LSU bounds),
W4 (vertex fetch), W2 (descriptors). Gate CTS-1 (`buffer_access`, `vertex_access`,
`index_access` under robustBufferAccess = true, already advertised), CTS-3 (`robustness2`,
`image_robustness`, `pipeline_robustness` when adopted).

## Inventory

| `dEQP-VK.robustness.` | cases | what |
|---|---:|---|
| `robustness2` | 81844 | VK_EXT_robustness2: `bind` 46538 / `push` 34944 / `64b_indexing` 360: robustBufferAccess2 (tight bounds, OOB reads zero exactly), robustImageAccess2, nullDescriptor |
| `image_robustness` | 11880 | VK_EXT_image_robustness (1.3 core robustImageAccess): OOB image loads return zero/zero-alpha-rules, stores dropped |
| `buffer_access` | 1212 | core robustBufferAccess: OOB UBO/SSBO/texel reads return 0 or in-buffer values; writes dropped or in-buffer; vertex/fragment/compute |
| `pipeline_robustness`, `pipeline_robustness_buffer_access` | 911, 240 | VK_EXT_pipeline_robustness (1.4 core) |
| `descriptor_heap_buffer_access` | 612 | heap extension |
| `vertex_access`, `robustness1_vertex_access`, `index_access`, `bind_index_buffer2`, `non_robust_buffer_access` | 90, 4, 7, 41, 2 | vertex/index OOB, maintenance5 bind-index-buffer-2 |
| **total** | 96843 | |

## Architectural logic

```text
LOGIC ROB-L1 · Core robustBufferAccess
  CLAIM       With robustBufferAccess, out-of-bounds buffer reads (UBO/SSBO/texel/vertex)
              return zero, or any value within the buffer, or (for vectors) a mix per
              component; OOB writes are discarded or hit within the buffer; the bounds
              are the descriptor's range rounded up to the alignment the spec allows
              (robustBufferAccess allows rounding to 16 B / the element size); no fault,
              no device loss; index buffer OOB vertex indices yield robust vertex reads.
  SOURCE      robustness.buffer_access.* (1212), vertex_access.*, index_access.*,
              robustness1_vertex_access.*.
  MECHANISM   4a `robustBufferAccess` in the LSU (record {base,size} bounds; zero on OOB,
              store dropped, robust count); rast index OOB → index 0 (legal: "any value
              within the buffer" — index 0 is within); attribute OOB → zero.
  REQUIRES    Per-component bounds for vector loads straddling the end (the test
              accepts in-buffer or zero per component — current whole-vector zeroing is
              legal as long as each component is zero or in-buffer… verify: a vector
              whose first components are in bounds may return zero for all? The spec
              permits "returns zero or in-buffer values" per *access*, with the vec
              possibly treated as one access; CTS accepts both — confirm in
              vktRobustnessBufferAccessTests.cpp's verifier).
  FORBIDS     Device loss or a fault on OOB; reading beyond the memory object (the
              aperture window check already refuses it — that is the fault that must
              never be reached by a robust access).
  CHECK       buffer_access.*.compute (CTS-1), vertex_access.* (CTS-2).
  COST        comparators already present.
  FEEDS       DI-L2 (nullDescriptor); CTS-1.
  STATUS      not-run

LOGIC ROB-L2 · robustness2 (tight bounds, zero exactly, null descriptors) and image robustness
  CLAIM       robustBufferAccess2: OOB reads return exactly zero (no rounding latitude
              beyond 4 B/… per the EXT's rules), OOB writes discarded; robustImageAccess
              (1.3) / robustImageAccess2: OOB texel fetches/loads return (0,0,0,0) or
              (0,0,0,1) per format rules, OOB stores dropped, invalid LOD/sample handled;
              nullDescriptor: a VK_NULL_HANDLE buffer/image/view descriptor reads as
              zero (size 0) and writes are dropped — including vertex buffers.
  SOURCE      robustness.robustness2.{bind,push,64b_indexing}.*, image_robustness.*,
              bind_index_buffer2.*.
  MECHANISM   The 4a bounds are already tight (no rounding) → robustBufferAccess2 is
              nearly free; image robustness = coordinate/LOD/layer bounds in the sampler
              fetch (5b checks in-image — verify sample index and LOD); nullDescriptor
              = the zero/invalid record already means "zero-size buffer" (F5: loads 0,
              stores dropped) — exactly the required behaviour, so the BM-X3 poison
              semantics must distinguish "null descriptor written deliberately" (robust
              zero) from "invalid update" (per-record invalid; with nullDescriptor also
              robust zero rather than device loss).
  REQUIRES    1.3 ladder for robustImageAccess; the EXT for robustness2 (UE enables
              nullDescriptor when present).
  FORBIDS     Clamping an OOB index to the last element (returns in-buffer data, which
              robustness2 forbids — must be zero).
  CHECK       robustness2.bind.*.reads.* first (CTS-3); image_robustness.*.
  COST        none.
  FEEDS       DI-L2, BM-X3; CTS-3.
  STATUS      not-run (NotSupported)

LOGIC ROB-L3 · Pipeline robustness (1.4 core)
  CLAIM       Per-pipeline robustness overrides (disabled/default/robust/robust2 for
              storage/uniform/vertex/image accesses).
  SOURCE      robustness.pipeline_robustness*.*.
  MECHANISM   A per-pipeline mode word consulted by the LSU/sampler bounds logic (the
              checks exist; the mode selects zero vs in-buffer vs none).
  REQUIRES    1.4 ladder.
  FORBIDS     —
  CHECK       at 1.4.
  COST        mode bits.
  FEEDS       INFO-L2 ladder.
  STATUS      not-run
```

## Exceptions

```text
EXCEPTION ROB-X1 · NotSupported by truthful absence
  CONDITION   robustness2.*, image_robustness.* (until 1.3), pipeline_robustness.*
              (until 1.4), descriptor_heap_buffer_access.*, bind_index_buffer2 (1.4
              maintenance5), non_robust_buffer_access (needs the feature *off* — we
              always advertise robustBufferAccess, so the device may still be tested
              with it disabled at device creation: the test disables it and expects no
              crash on in-bounds accesses only).
  RESULT      NotSupported / Pass.
  TRUTH       profile lines.
  MECHANISM   Profile ROM.
  CHECK       ledger.
  FORBIDS     —

EXCEPTION ROB-X2 · Robust access is not device loss
  CONDITION   Any OOB access under a robust feature.
  RESULT      Defined robust value; the `robust_q` counter is diagnostic only.
  TRUTH       spec.
  MECHANISM   LSU/sampler/rast bounds.
  CHECK       every ROB card.
  FORBIDS     Promoting a robust read into DEVICE_LOST "to be safe" (it is the opposite of
              the spec's intent).
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| ROB-H1 Verify the verifier | CTS-1 | high | read the buffer_access verifier's accepted outcomes before changing vector-OOB behaviour | — |
| ROB-H2 Null descriptor semantics | DI-L2 | high | per-record validity with robust zero (one change serves descriptor indexing and robustness2) | — |
| ROB-H3 Image bounds audit | 1.3 ladder | medium | sample/LOD/layer bounds in the fetch | — |

## Performance / area / scalability

Bounds checks are per access and already in the LSU; a coalescing LSU must keep per-lane
bounds (CTS-P3). No knobs.
