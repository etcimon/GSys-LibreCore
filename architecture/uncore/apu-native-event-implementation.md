# Native Command-Buffer Event Synchronization

GSys LibreCore's opt-in native transfer profile now replays bounded
`vkCmdSetEvent`, `vkCmdResetEvent` and `vkCmdWaitEvents` records as ordered
executor operations. This is host-model execution, not hardware/profile
admission. Default GPU refusal and zero Vulkan capsets remain unchanged.

## Semantics

- Event objects are the same ObjTab entries the guest path uses: `state` bit 0
  is the signaled flag. Host `vkSetEvent`/`vkResetEvent`/`vkGetEventStatus`
  already flow through the frontend EVENT class and needed no change;
  `vkWaitForEvents` remains outside the decoder profile.
- `vkCmdSetEvent`/`vkCmdResetEvent` records carry a canonical event handle in
  `handle[0]` plus a stage mask. Replay resolves the handle through the shared
  `remember()` path (generation-qualified, device-checked, pinned for the
  job's lifetime) and validates the stage mask with the barrier `scope()`
  rules for the active profile.
- `vkCmdWaitEvents` records carry `eventCount`, src/dst stage masks and a
  payload of canonical event handles followed by retained
  memory/buffer/image barrier words. The decoder keep list for the command
  stages `pEvents` plus the shared `BARRIER_FIELDS` member paths, so the
  wire record now retains `[2*eventCount event-id words][mem*2][buf*10]
  [img*13]` barrier words in decode order. `capture_barrier` runs with the
  event-word base offset and canonicalizes embedded buffer/image handles
  exactly like `vkCmdPipelineBarrier`; the record-time payload builder
  emits the canonical event handles then the barrier words verbatim.
  Replay requires the exact retained length (`eventCount + barrier words`),
  at most 16 events, a zeroed spare immediate, and valid stage masks; the
  barrier tail then replays through the shared `vn_image_barriers.replay`
  path via a synthetic PipelineBarrier-shaped record with the payload
  offset past the event words, so stage/access/layout/usage validation and
  typed `Transfer('barrier')` retention are identical. `eventCount == 0`
  with nonzero barriers is admitted as a pure barrier record (no
  `EventWait` op). LOOKUP-resolved buffer/image handles may appear in
  `record['handle']`; payload words remain the authoritative validated
  operands.
- `EventSignal` and `EventWait` are runtime operations in the shared
  executor: signal ops flip `state` bit 0 once when reached; wait ops return
  no progress until every listed entry is signaled, then complete. Ordering
  is the job's in-order operation stream, so a wait stalls only subsequent
  ops in the same job while other contexts/lanes keep polling. A never-set
  event blocks indefinitely, matching `vkCmdWaitEvents` semantics; the host
  `vkSetEvent` path releases it.
- `vkDestroyEvent` now joins the replay `blocked()` target set so destruction
  waits for executor-held event leases, like buffers/images/pools.
- Host event feedback reports `VK_ERROR_DEVICE_LOST` once the owning
  context faults: `NativeSubmissions.EVENT_NAMES` (`vkGetEventStatus`,
  `vkSetEvent`, `vkResetEvent`) bypass the NAMES dispatch because the
  golden frontend owns event state, so `LinearExecution._command`
  intercepts them through `NativeSubmissions.lost()` - which resolves the
  canonical `ExecutionContext` (command views are `replace()` copies, so
  `id(view)` never matches the faults set) - and replies `VK_ERR_LOST`
  without touching event state. The same `lost()` source now backs the
  fence, query-results, idle and timeline host paths.

## Device-command DEVICE_LOST surface (follow-up)

Stock Mesa issues device-state commands during and after device loss;
reporting `VK_OK` there would let stale objects publish. The host
feedback surface is now extended from the sync commands to every
VkResult-returning device-state act class:

- `NativeSubmissions.LOST_CLASSES` = `ALLOC`, `BIND`, `POOL_RESET`,
  `CB_BEGIN`, `CB_END`, `CB_RESET` - object creation
  (`vkCreate*`/`vkAllocateMemory`/`vkGetDeviceQueue*`), memory/image
  binding, descriptor/command-pool resets and command-buffer state
  transitions. `LinearExecution._command` routes them through the same
  `lost()` check as `EVENT_NAMES` and replies `VK_ERR_LOST` without
  running `frontend.step`, so no object entry, binding or command-buffer
  state is published for a faulted context.
- Deliberately live after loss: `RETIRE` (void destroys - post-loss
  cleanup must still run), `RECORD` (void `vkCmd*` - recording cannot
  execute because `vkQueueSubmit` already reports lost), `QUERY`
  (instance/physical-device properties are device-independent),
  `MAP`/`UPDATE`/`NOP_OK` (void or always-success semantics) and
  `TRANSPORT`/`WAIT`/`SUBMIT` (already covered by their own paths).
- Ordering: `blocked()`, `validate_command()` and the capture passes
  still run first, so stale-handle and payload-validation errors keep
  precedence over the lost report; the interception sits at the same
  dispatch point as the event names.

Evidence: three `SubmissionTests` cases cover create/allocate/bind/
fence-create reporting `VK_ERROR_DEVICE_LOST` with the created object
absent from the frontend table, recovery to `VK_OK` after the fault
clears, and `vkDestroyBuffer` (RETIRE) still executing post-loss.
147 adjacent submit/event/timeline/query/transfer/replay/draw/compute
tests pass locally; remote frozen cohort `native-lostdepth-01`
(`native-execution.qdan5ugk`) reports 675 tests PASS in 18.8s with
`sources_unchanged: true` (+3 over the 672 gated-commands cohort).

## Evidence

652 frozen checks pass in 18.985s from remote cohort `native-eventlost-01`
(56 modules, 141 hashes); all input hashes remain unchanged and
`sources_unchanged` is true. Twelve event cases cover in-order
set/wait/reset, host-release of a blocked wait, multi-event waits, host
reset, retained memory/buffer/image barrier payloads executing as ordered
ops, barrier-only records, atomic refusals for bad stages/accesses/layouts
and dead images, dead-handle rejection before pins, pin release at
retirement, and `VK_ERROR_DEVICE_LOST` propagation to `vkGetEventStatus`
with host set/reset leaving event state untouched after a context fault.
Six-source MIT tier/header/ASCII/LF/whitespace/syntax audit
passes (`vn_golden.py` retains its pre-existing non-ASCII comment style;
all added lines are ASCII).

Host-only: no functional RTL/config/ISA/CSR/DTS/discovery, clock/reset, SRAM/
DFT/PMU or timing-cone change. Pinned hardware tables, upstream notices, link
sets and PGO policy are untouched; no spec-index or capability promotion.
Core/Storamic work is preserved and changes remain uncommitted.

Still open: `vkWaitForEvents` host waits (absent from the Venus wire xmls —
a protocol boundary, not a decoder gap), semaphore-based cross-queue
event equivalence, `vkCmdWaitEvents2`/dependency-flag payloads (the
profile does not decode `dependencyFlags`), and
every capability/CTS/physical qualification gate. Truthful capset
admission and software/hardware/CTS/aggregate/formal/synthesis/physical/
WSI/timing/area/power/silicon qualification remain separate gates.
