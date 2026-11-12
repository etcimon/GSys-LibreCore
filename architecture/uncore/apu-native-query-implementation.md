# Native Timestamp Query-Pool Replay

GSys LibreCore's opt-in native transfer profile now replays bounded
`vkCmdResetQueryPool`, `vkCmdBeginQuery`, `vkCmdEndQuery`,
`vkCmdWriteTimestamp`, `vkCmdWriteTimestamp2`,
`vkCmdCopyQueryPoolResults` and the indexed variants at index 0 as
ordered executor operations over occlusion, pipeline-statistics and
timestamp query pools, with `vkGetQueryPoolResults` host readback.
This is host-model execution, not hardware/profile admission. Default
GPU refusal and zero Vulkan capsets remain unchanged.

## Semantics

- `vkCreateQueryPool` admits `VK_QUERY_TYPE_OCCLUSION` (0),
  `VK_QUERY_TYPE_PIPELINE_STATISTICS` (1) and
  `VK_QUERY_TYPE_TIMESTAMP` (2) with no `pNext`/flags, zero
  pipeline-statistics flags on non-statistics pools, a statistics mask
  confined to `0x87` (input-assembly vertices/primitives, vertex and
  fragment shader invocations - the only counters the admitted draw
  stages produce; geometry/tessellation/clipping/compute bits refuse)
  and `queryCount <= 4096`.
  `VK_QUERY_TYPE_PIPELINE_STATISTICS` pools outside that mask and
  unknown types refuse with `VK_ERROR_FEATURE_NOT_PRESENT` before
  ObjTab allocation. The entry stores `size` (queryCount), a `qslots`
  list initialised to `None` (unavailable), the type in `aux[7:0]` and
  the statistics mask in `aux[31:8]`.
- `vkCmdResetQueryPool` validates `firstQuery + queryCount <= size` and
  emits one `QueryReset` op that clears the selected slots to `None` at its
  stream position. Empty ranges emit no op.
- `vkCmdBeginQuery`/`vkCmdEndQuery`/`vkCmdWriteTimestamp` validate the
  query index, refuse nonzero flags/spare immediates, and - for
  `vkCmdWriteTimestamp` - validate the stage mask through the barrier
  `scope()` rules for the active profile. Each emits one `QueryStamp` op.
- `vkCmdWriteTimestamp2` is the synchronization2 spelling: the decoder
  retains the u64 `stage` in `q[1]`, capture copies it into `imm[1:3]`
  beside `query` at `imm[0]`, and replay applies the same `scope()` check
  to the low word while refusing nonzero high bits (stage flags above
  bit 31 are outside the bounded profile). It emits the same `QueryStamp`
  op, so v1/v2 stamps order identically.
- `vkCmdCopyQueryPoolResults` copies ordered slot state into a pinned
  `VkBuffer` extent at its stream position. The decoder retains
  `dstOffset`/`stride` u64s in `q[3]`/`q[4]`, capture copies them into
  `imm[3:7]` beside `firstQuery`/`queryCount`/`flags` at `imm[0:3]`, and
  replay resolves the destination through `extent()` (generation/device/
  binding checked) before emitting one `QueryCopy` op. `flags` admits
  only `VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY`;
  `WAIT`, `PARTIAL_BIT` and unknown bits refuse. `stride` must be a
  multiple of 4 and at least the packed record size - result width times
  (1 + availability): 4 or 8 bytes for 32-bit results, 8 or 16 bytes for
  64-bit results, the availability word taking the result width (the spec
  widens both together: u32 availability for 32-bit, u64 for 64-bit);
  `dstOffset` must be 4-aligned
  and `dstOffset + (count-1)*stride + recordSize` must fit the buffer
  extent. `queryCount == 0` emits no op.
- `QueryCopyRuntime` validates the destination extent at enqueue (same
  `_extent` path as `Transfer`), pins the buffer owner for the job, and
  at its turn writes the packed little-endian records through the memory
  aperture: the honest value (`0` or the stamped slot) plus an
  availability word of the result width (u32 for 32-bit, u64 for
  64-bit results) when requested, stride-padded. Unavailable slots
  write value 0 with availability 0 - the same truthful ordered state
  `vkGetQueryPoolResults` exposes, never a fabricated timestamp.
- `QueryStamp` writes the honest value `0`: the bounded profile has no
  truthful clock/timestamp source (`timestampPeriod` is 0), so no clock
  reading is fabricated. Begin/End on a timestamp pool collapse to a
  stamp at the command's stream position - timestamp queries use
  `vkCmdWriteTimestamp`, so this is a bounded simplification, documented
  here.
- Occlusion pools pair `vkCmdBeginQuery`/`vkCmdEndQuery` (and the
  `*IndexedEXT` spellings with `index == 0`) into `QueryBegin`/`QueryEnd`
  ops. `QueryBeginRuntime` opens a per-context accumulator keyed by
  (pool,index); every fragment the bounded raster stages generate while
  open is added to all open accumulators at op retirement - the profile
  has no depth/stencil test, so every covered sample passes and the
  count is the honest generated-sample count. `QueryEndRuntime` publishes
  the accumulated count into `qslots` at its stream position. `flags`
  admits only `VK_QUERY_CONTROL_PRECISE_BIT` (the count is exact, so
  precise is always satisfiable). Replay tracks open (pool,index) pairs
  on the submit-batch `images` state: double-begin, end-without-begin and
  a query left open at submit end all refuse atomically; begin/end may
  span command buffers inside one submit batch (secondary buffers share
  the same tracking). `vkCmdResetQueryPool` and
  `vkCmdCopyQueryPoolResults` admit all three pool types; timestamp
  writes still require a timestamp pool.
- Pipeline-statistics pools pair `vkCmdBeginQuery`/`vkCmdEndQuery`
  (and the `*IndexedEXT` spellings with `index == 0`) exactly like
  occlusion pools - same pairing/refusal rules, same PRECISE-only flag
  gate. `QueryBeginRuntime` opens a per-context accumulator of
  `(enabled bit positions, [zero counters])` in spec bit order;
  `executor.statistics` is a sibling map to `executor.occlusion`, both
  dropped by `cancel_context`. At `DrawExec` retirement the executor
  adds the counters the draw stages actually produced:
  input-assembly vertices and vertex-shader invocations both equal the
  fetched vertex-record count (the admitted pipeline has no geometry
  amplification), input-assembly primitives equal the raster stage's
  iterated triangle count (culled/degenerate primitives were still
  assembled), and fragment-shader invocations equal the fragment
  records handed to the fragment-shade stage. A conditional-gated draw
  contributes zeros because no stage work ran. `QueryEndRuntime`
  publishes the counter list into `qslots` at its stream position.
- Statistics results are per-query counter arrays, not scalars:
  `vkGetQueryPoolResults` and `vkCmdCopyQueryPoolResults` size each
  record as `popcount(mask) * width` (+ an availability word of the
  result width when requested), counters packed as u64 (readback requires 64_BIT; copy
  admits 32/64-bit widths) in ascending bit order. Unavailable slots
  write zero counters with availability 0; `VK_NOT_READY`/`WAIT`
  semantics are identical to scalar pools.
- `_pool()` validates the canonical `VkQueryPool` handle through
  `remember()` (generation-qualified, device-checked, pinned for the job's
  lifetime), same-parent/device, admitted type, integer size within
  bounds and `qslots` length equal to size. Dead or foreign pools reject
  before pins; a dead pool handle also fails the record-time HANDLE LOOKUP
  and the command is dropped before reaching the executor.
- `vkDestroyQueryPool` joins the replay `blocked()` target set so
  destruction waits for executor-held pool leases.
- Query operations consume one operation-budget entry each; command,
  payload, object and operation budgets are unchanged.
- `vkGetQueryPoolResults` is admitted as a native host query through
  `NativeSubmissions.NAMES` (the same path as `vkGetFenceStatus` and the
  timeline host APIs; the wire act class stays `UNSUPPORTED`, so no
  decoder/RTL contract changes). The handler resolves device and pool
  through `_object()` (generation/device/context checked), reports
  `VK_ERROR_DEVICE_LOST` once the owning context has faulted (same
  `submissions.faults`/`gpu_lost` source as fence status), requires the
  timestamp profile, admits `VK_QUERY_RESULT_64_BIT` with optional
  `WAIT`/`WITH_AVAILABILITY`, and refuses 32-bit results, `PARTIAL_BIT`
  and unknown flag bits with `VK_ERROR_FEATURE_NOT_PRESENT`. `stride`
  must be a multiple of 4 and at least the record size (8 or 16 bytes
  packed for the admitted 64-bit results); `dataSize` must cover `queryCount * stride`; the pData blob
  count must equal `dataSize`. Out-of-range queries, undersized buffers
  and bad strides return `VK_ERROR_VALIDATION_FAILED`.
- Readback is truthful ordered state: a slot is available only after its
  `QueryStamp`/`QueryReset` op retires in stream order. Without `WAIT`,
  any unavailable slot returns `VK_NOT_READY` while still writing
  available records (unavailable entries read value 0, availability 0).
  With `WAIT`, the command raises `RingBlocked` and retries until the
  ordered ops publish - matching fence-wait suspension semantics.
- The reply uses the generated reply program 73
  (`RTYPE, RRESULT, REXBUF(pData)`): exec words carry the byte count then
  packed little-endian records - u64 value plus a u64 availability word
  when requested (the spec widens availability to the result width),
  stride-padded.

## Evidence

668 frozen checks pass in 17.9s from remote cohort `native-statquery-01`
(cohort `native-execution.oyeoyvyu`, sources unchanged); all input
hashes remain unchanged and `sources_unchanged` is true.
Twenty-one cases cover in-order reset/stamp/begin/end execution,
range/flags/stage/bounds refusals, statistics/count refusal at create,
occlusion pool admission with honest generated-fragment counts (verified
end-to-end against `drawexec_stats` on a real draw plus host readback),
occlusion begin/end pairing refusals (double-begin, end-without-begin,
out-of-range index, flags beyond PRECISE, unclosed at submit end),
indexed-variant admission at index 0 and nonzero-index refusal,
occlusion copy/readback, wrong-type timestamp-write refusal, pool pin
release after retirement, dead-pool rejection (record-time LOOKUP drop
plus post-destroy replay safety), ordered readback with and without
availability, `VK_NOT_READY` before drain, `WAIT` suspension until stamp
retirement, flag/stride/dataSize validation refusals,
`VK_ERROR_DEVICE_LOST` propagation after a context fault, v1/v2
timestamp ordering, out-of-profile stage refusal, ordered buffer copy
with stride padding and availability, 32-bit packed records, copy
validation refusals and dead-pool copy rejection, statistics-pool
create admission/refusals (mask outside 0x87, stats flags on
non-statistics pools, unknown types), empty-region zero counters,
mask-subset single-counter results, unavailable-slot `VK_NOT_READY`
with zero-counter payload, counter-array copy with stride padding,
wrong-type timestamp-write refusal on statistics pools, and an
end-to-end draw whose published counters ([IA vertices, IA primitives,
VS invocations, FS invocations]) match the draw's actual stage work.
The decoder profile regenerated `g6lc_apu_vn_pkg.sv` (four new RECORD
programs total across the query lane, no new handle kinds); RTL leaf
verification is tracked separately.

## Boundaries

- Statistics pools are bounded to mask `0x87`: geometry/tessellation/
  clipping/compute statistic bits refuse at create because the admitted
  pipeline has no such stages (or cannot count them truthfully yet).
  Statistics counters cover `DrawExec` draws only - standalone stage
  ops and compute dispatches contribute nothing, which is truthful
  because those bits are refused and dispatch regions contain no draw
  stages. Transform-feedback indexed queries (`index != 0`),
  `vkCmdWriteTimestamp2` stage flags above bit 31,
  `vkCmdCopyQueryPoolResults` WAIT/PARTIAL flags, host
  `vkWaitForEvents` (absent from the pinned vk.xml) and
  `vkGetQueryPoolResults` 32-bit results remain outside the profile.
  Conditional rendering is implemented separately - see
  `apu-native-conditional-implementation.md`.
  Occlusion counts are generated samples: the bounded profile has no
  depth/stencil test, early-fragment tests or `rasterizerDiscard`
  interaction beyond what the raster stages already model, so counts
  are exact for the admitted draw subset but are not a CTS claim.
- No capset, CTS, stock-guest, RTL or physical qualification is claimed;
  zero capsets, host-model evidence only, uncommitted.
