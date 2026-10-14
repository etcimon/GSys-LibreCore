# `query-pool` — occlusion, pipeline statistics, timestamps, result copies (18,270 cases)

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass `vk-default/query-pool.txt`; tests in
`external/vulkancts/modules/vulkan/query_pool/vktQueryPool*.cpp`. Owner W4/W2 (ROP counters,
cmdexec result copy). Gate CTS-2 (occlusion), CTS-3 (statistics with host reset at 1.2;
timestamps), later (performance queries, maintenance7).

## Inventory

| `dEQP-VK.query_pool.` | cases | what |
|---|---:|---|
| `statistics_query` | 17769 | pipeline statistics: `reset_before_copy` 4501, `host_query_reset` 4500 (1.2), `reset_after_copy` 3004, `clipping_primitives`/`clipping_invocations` 1056 each, `vertex_only` 1008, `input_assembly_primitives` 666, `vertex_shader_invocations` 480, geometry 960, `fragment_shader_invocations` 240, tessellation 78+… |
| `occlusion_query` | 441 | precise/non-precise, 32/64-bit, wait/partial/availability flags, conservative, with scissor/discard |
| `discard` | 32 | queries with rasterizer discard |
| `frag_invocations` | 12 | fragment invocation counts under helper/MSAA |
| `performance_query` | 12 | KHR_performance_query |
| `concurrent_queries`, `maintenance7` | 2, 2 | |
| **total** | 18270 | |

## Architectural logic

```text
LOGIC QP-L1 · Occlusion queries end to end
  CLAIM       vkCmdBeginQuery/EndQuery bracket draws; the query counts passing samples
              (QP sees FO-L2); vkCmdResetQueryPool (and vkResetQueryPool at 1.2) resets
              availability; vkGetQueryPoolResults with 32/64-bit, WAIT, WITH_AVAILABILITY,
              PARTIAL flags returns values and availability per the spec's table
              (unavailable → not written unless PARTIAL; availability word 0/1);
              vkCmdCopyQueryPoolResults writes the same layout into a buffer with
              stride; queries across secondary command buffers (inherited occlusion
              queries) and with rasterizer discard (count 0).
  SOURCE      query_pool.occlusion_query.* (441), discard.*; vktQueryPoolOcclusionTests.cpp.
  MECHANISM   Query pool object with device-private storage (count × {value, available});
              Begin/End records set the active query id in the rast ROP (counter per
              active query); cmdexec writes results/availability at End; Copy results =
              Xfer-style write with stride/flags; host Get = Venus reads the pool through
              a reply (vkGetQueryPoolResults is a reply-carrying command → vnrep EXEC
              with WAIT semantics = poll availability before replying).
  REQUIRES    FO-L2 counting; the reply path for Get (today `vkGetQueryPoolResults` is a
              follow-up from increment 3).
  FORBIDS     Returning "available" before the draw's ROP work completed (the serialized
              completion queue orders it); counting helper lanes/fragments.
  CHECK       occlusion_query.basic_*, *_64bits, *_availability_bit (CTS-2).
  COST        pool storage in the arena; a counter in the ROP.
  FEEDS       FO-L2, MV (per-view counting rules); CTS-2.
  STATUS      not-run

LOGIC QP-L2 · Timestamps
  CLAIM       vkCmdWriteTimestamp(2) at a pipeline stage writes a device timestamp in
              units of timestampPeriod ns with timestampValidBits bits; monotonic within
              a queue; timestampComputeAndGraphics; host-visible via Get/Copy; calibrated
              timestamps (EXT) optional.
  SOURCE      pipeline.monolithic.timestamp.* (262); synchronization timestamp uses.
  MECHANISM   A free-running cycle counter in cmdexec, sampled when the record is
              reached (top-of-pipe = at issue, bottom-of-pipe = after the preceding
              work's completion through the done queue); period = 1/f_clk ns truthfully
              (timestampPeriod is one of the 7 audit findings — it must be set from the
              SoC clock, `AGENTS-configuration.md`).
  REQUIRES    the period constant per SKU; 64-bit counter (validBits ≥ 36 required).
  FORBIDS     A period that does not match the counter's actual rate.
  CHECK       pipeline.monolithic.timestamp.* (CTS-2).
  COST        a 64-bit counter.
  FEEDS       PIPE-L6; CTS-2.
  STATUS      not-run

LOGIC QP-L3 · Pipeline statistics queries
  CLAIM       pipelineStatisticsQuery (optional feature, requested by the plan matrix):
              input assembly vertices/primitives, vertex shader invocations, clipping
              invocations/primitives, fragment shader invocations, compute shader
              invocations (+ geometry/tessellation when present) counted exactly as the
              spec defines (e.g. clipping primitives = primitives reaching the clipping
              stage, fragment invocations ≥ fragments shaded, helper invocations do not
              count unless…).
  SOURCE      query_pool.statistics_query.* (17,769, most gated on the feature and on
              geometry/tessellation).
  MECHANISM   Counters in the primitive assembler, VS/FS dispatch (per lane, excluding
              helpers for fragment invocations — the spec says helper invocations *may*
              be counted? No: "fragment shader invocations" counts invocations, helpers
              included is implementation-defined? — the spec: helper invocations are
              counted — verify in vktQueryPoolStatisticsTests.cpp before implementing),
              rast setup (clipping), cmdexec dispatch (compute).
  REQUIRES    a W1 decision to advertise pipelineStatisticsQuery (the plan's "pipeline
              statistics / occupancy" row); `host_query_reset` (1.2 core) for the host
              reset variants.
  FORBIDS     Approximate counts.
  CHECK       statistics_query.vertex_only.*, input_assembly_primitives.*,
              fragment_shader_invocations.* once advertised (CTS-3).
  COST        counters at four points.
  FEEDS       plan "hardware pipeline statistics"; CTS-3.
  STATUS      not-run (NotSupported)
```

## Exceptions

```text
EXCEPTION QP-X1 · NotSupported by truthful absence
  CONDITION   pipelineStatisticsQuery false, occlusionQueryPrecise false (precise
              variants), hostQueryReset (1.2) absent, performance_query (KHR),
              maintenance7 (1.4), geometry/tessellation statistics.
  RESULT      NotSupported.
  TRUTH       profile lines; hostQueryReset becomes required at 1.2.
  MECHANISM   Profile ROM.
  CHECK       ledger.
  FORBIDS     —

EXCEPTION QP-X2 · Availability semantics
  CONDITION   Get without WAIT on an unfinished query.
  RESULT      VK_NOT_READY and untouched result words (unless PARTIAL); never a stale
              value marked available.
  TRUTH       spec table.
  MECHANISM   availability word written only from the done queue.
  CHECK       occlusion_query.*_availability_bit.*.
  FORBIDS     Treating record-time as completion.
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| QP-H1 Occlusion + results path | CTS-2 | high | pool object, ROP counter, End/Copy/Get with flags | — |
| QP-H2 Timestamps | CTS-2 | medium | counter + truthful period | — |
| QP-H3 Statistics | W1 decision | later | the four counters | — |

## Performance / area / scalability

Counters are free; the ordering point is the done queue (availability only after
completion). A tile engine must sum per-tile counters per query (CTS-P3: counts are
order-independent, sums are exact).
