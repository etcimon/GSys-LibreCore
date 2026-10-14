# `fragment-operations` — early fragment tests, occlusion queries with scissors (151 cases)

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass `vk-default/fragment-operations.txt`;
tests in `external/vulkancts/modules/vulkan/fragment_ops/vktFragmentOperations*.cpp`.
Owner W4 (rast ROP/early-Z, G3a-i late-Z, G3c stencil/queries). Gate CTS-2.
(Stencil/depth/blend state coverage lives in `pipeline.*` — cts-pipeline.md; this group
is the ordering of fragment tests relative to the shader.)

## Inventory

| prefix (`dEQP-VK.fragment_operations.`…) | cases |
|---|---:|
| `early_fragment` (early_fragment_tests_depth/stencil × discard/no-discard × test on/off × write on/off, `sample_count_*`, `early_fragment_tests_*_no_attachment`) | 54 |
| `occlusion_query` (precise/non-precise × scissor on/off × depth/stencil write/clear/test combinations) | 64 |
| transfer-queue/other small cases | 33 |
| **total** | 151 |

## Architectural logic

```text
LOGIC FO-L1 · Early vs late fragment tests are observable and ordered as specified
  CLAIM       Without `early_fragment_tests`, a fragment that fails the depth/stencil test
              still executes the shader (its side effects — SSBO atomics — are visible)
              and a discarded fragment never writes depth/stencil; with `layout(early_
              fragment_tests) in`, the tests run before the shader: failing fragments do
              not execute it and *depth/stencil are written even if the shader later
              discards*; FragDepth writes are ignored under early tests.
  SOURCE      fragment_operations.early_fragment.* (54: early_fragment_tests_depth,
              early_fragment_tests_stencil, their no_early_* counterparts, discard
              variants, sample_count variants, no_attachment);
              vktFragmentOperationsEarlyFragmentTests.cpp.
  MECHANISM   G3a-i: `fs_late` (FragDepth or kill) moves the test into the ROP; the
              EarlyFragmentTests execution mode (SPIR-V 9) must force the *early* path
              even when the shader kills/writes depth, with the side-effect semantics
              above (depth written before the shader, discard does not undo it, FragDepth
              ignored). shmod must record the mode (accepted today? — the mode list in
              shmod accepts 7/12/14/15/16/17; 9 must be added) and the rast must honour
              `fs_early` over `fs_late`.
  REQUIRES    Stencil (G3c, RAST-L3) for the stencil variants; atomics in FS (G3a-i) are
              the observable side effect.
  FORBIDS     Running the shader for early-test failures (the atomic counter would be
              wrong); undoing an early depth write on discard.
  CHECK       early_fragment.early_fragment_tests_depth_* first (CTS-2); engine vector:
              counter with early tests on/off over a failing fragment.
  COST        one mode bit in the draw record.
  FEEDS       PIPELINE depth/stencil cards, QUERY-POOL-L1; CTS-2.
  STATUS      not-run

LOGIC FO-L2 · Occlusion queries count samples that pass all fragment tests, within scissor
  CLAIM       An occlusion query counts (precisely with occlusionQueryPrecise, otherwise
              ≥ 1 if any) the samples that pass scissor, depth and stencil tests;
              depth/stencil writes disabled or clears inside the pass do not change the
              count rules; the count is available through vkGetQueryPoolResults /
              vkCmdCopyQueryPoolResults with the availability/64-bit/wait flags.
  SOURCE      fragment_operations.occlusion_query.* (64); vktFragmentOperationsOcclusion
              QueryTests.cpp (also cts-query-pool.md).
  MECHANISM   G3c: a per-query counter in the ROP incremented per passing sample between
              vkCmdBeginQuery/EndQuery records (query pool = device-private counters,
              reset by vkCmdResetQueryPool / host reset at 1.2); results copied by cmdexec.
  REQUIRES    Counting after the late test too (fs_late path); scissor-rejected samples
              are not counted (they never reach the ROP — already true).
  FORBIDS     Counting fragments instead of samples once MSAA exists; counting helper
              lanes.
  CHECK       occlusion_query.* (CTS-2); engine: known-count triangle with scissor.
  COST        one adder per ROP write path; query-pool storage in the private arena.
  FEEDS       QUERY-POOL-L1; CTS-2.
  STATUS      not-run
```

## Exceptions

```text
EXCEPTION FO-X1 · Features
  CONDITION   occlusionQueryPrecise false → the precise variants NotSupported (the
              non-precise ones still required); sample_count variants beyond 1 need
              MSAA (G3c) — NotSupported only for counts the framebuffer sample counts do
              not advertise (1 and 4 are required: those variants are obligations).
  RESULT      NotSupported / required accordingly.
  TRUTH       profile `framebufferColorSampleCounts = 1` today is *below* the required
              1|4 — not an exception, a required fix (RAST-L4 MSAA).
  MECHANISM   Profile ROM.
  CHECK       ledger.
  FORBIDS     Keeping sample counts at 1.
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| FO-H1 Early mode bit | CTS-2 | high | accept execution mode 9; `fs_early` precedence in rast | — |
| FO-H2 Queries | G3c | high | ROP sample counter + query pool records | — |

## Performance / area / scalability

Early-Z is also the main performance lever of forward rendering; keeping the early/late
decision per pipeline (not per draw) lets a tile engine schedule it. Hierarchical Z (W8)
must preserve the exact per-sample results these tests check.
