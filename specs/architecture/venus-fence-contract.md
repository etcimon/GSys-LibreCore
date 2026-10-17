# Venus fence / submission contract — what Mesa 25.2.8 actually does

Evidence basis: guest driver is the **stock Ubuntu package**
`mesa-vulkan-drivers 25.2.8-0ubuntu0.24.04.4` (`dpkg -l` in the run
logs; the harness installs it with `apt-get`, there is no project
patch), read against upstream `src/virtio/vulkan/` at tag
`mesa-25.2.8`. The ring alive-status watchdog (`vn_relax`:
`MESA-VIRTIO: debug: stuck in fence wait with iter at N` /
`aborting on expired ring alive status`) is upstream Venus
behaviour and is what bounds every wait described below. Line refs
are to the upstream tag.

## A. vkQueueSubmit is asynchronous — there is no per-submit reply

- `vn_QueueSubmit` → `vn_queue_submit` → the default path is
  `vn_submit_vkQueueSubmit` (`vn_queue.c:1073-1085`): the encoded
  command is written to the ring shmem and the tail advanced
  (`vn_ring.c` `vn_ring_submit_internal`: `vn_ring_write_buffer` +
  `vn_ring_store_tail`, `:436-460`). **No reply is awaited** —
  `reply_size` is 0 for queue submits (`vn_ring_submit_command`,
  `vn_ring.c:690-735`), so execution results can never reach the
  `vkQueueSubmit` return value.
- The only synchronous failure is a *ring-level* rejection:
  `!ring_submit.ring_seqno_valid` → `vn_error(instance,
  VK_ERROR_DEVICE_LOST)` (`vn_queue.c:1081-1084`). A renderer-side
  malformed-record rejection cannot surface through this return —
  it has already returned VK_SUCCESS.
- `VN_PERF(NO_ASYNC_QUEUE_SUBMIT)` swaps in `vn_call_vkQueueSubmit`
  (a synchronous ring call, `:1057-1068`) — not enabled in the guest
  (no `VN_PERF` env in the harness), so the async path is what runs.

## B. Fence/event waits are host-side polls of a feedback slot

- Fences created on this device get a feedback slot
  (`fence->feedback.slot`, `vn_queue.c:1441-1496` — the slot is an
  8-byte region in a host-coherent feedback buffer,
  `vn_feedback.c` `vn_feedback_pool_alloc`, `:245-273`).
- `vn_queue_submission` **appends a Mesa-generated feedback command
  buffer** to the submission (`vn_queue.c` struct comment `:60-72`:
  "if last batch, a single cmd for ffb"; accounting at
  `vn_queue_submission_count_batch_feedback` `:427-495`). The CB is
  `vkCmdPipelineBarrier` + `vkCmdFillBuffer(slot, 4, VK_SUCCESS)` +
  flush barrier (`vn_feedback.c` `vn_feedback_cmd_record`,
  `:437-523`) — it is an ordinary CB in the stream; the renderer
  must execute it like any other.
- `vn_GetFenceStatus` reads `*slot->status` directly
  (`vn_queue.c:1616-1631`, `vn_feedback.h:101-104`); on success it
  additionally fires an async `vkWaitForFences` so the renderer
  retires the real fence.
- `vn_WaitForFences` loops `vn_GetFenceStatus`/`vn_remove_signaled_
  fences` with `vn_relax` until the slot holds a terminal value
  (`vn_queue.c:1703-1740`). A negative VkResult in the slot exits
  the wait with that error — the renderer may therefore write an
  error status (e.g. `VK_ERROR_DEVICE_LOST`) into the slot and the
  guest surfaces it instead of hanging.
- `vkQueueWaitIdle` = `vkQueueSubmit(0 batches, wait_fence)` +
  `vkWaitForFences` (`vn_queue.c:1380-1409`): an *empty* submission
  still carries the ffb CB, so even a zero-batch submit must reach
  the executor.

**Consequence (the array-frag wedge):** if the renderer abandons a
submission mid-stream on an execution fault, the trailing ffb CB
never runs, the slot never leaves `VK_NOT_READY`, and the guest
hangs in `vkWaitForFences` — observed verbatim as
`MESA-VIRTIO: debug: stuck in fence wait with iter at 16384 /
aborting` (the upstream `vn_relax` watchdog) in
`.cache/apu-guest/out-g3aii-cts-g3aii-tex-frag/serial-venus.log`,
while `server-run-venus.log:308292` shows the tail `QueueSubmit`
(cmd 0x12) answered `result=0xfffffff3` (VK_ERROR_UNKNOWN) and the
engine already idle — the feedback fill simply never executed.

## C. Device loss surfacing

- Ring `VK_RING_STATUS_FATAL_BIT_MESA`: the next
  `vn_ring_submit_internal` calls `abort()` outright
  (`vn_ring.c:455-458`) — stock Mesa crashes the process on the
  submit after FATAL, it does **not** return DEVICE_LOST there.
- The wait loops (`vn_ring_wait_seqno` `:180-202`,
  `vn_ring_wait_space` `:222-244`, and the fence-relax loop) carry
  **no FATAL check** — on stock Mesa a dead renderer hangs those
  paths forever. The upstream `vn_relax` watchdog (the alive-status
  watchdog inside `vn_relax`) is what turns them into a bounded
  `abort`.
- `vn_error(instance, VK_ERROR_DEVICE_LOST)` is the synchronous
  API-visible loss report — only reachable for calls that still
  have a reply in flight (ring submit rejection, sync ring calls).

## D. Contract this fixes on the renderer side (A1.1)

| fault class | required renderer behaviour | guest-visible result |
|---|---|---|
| execution-time fault (shader `DONE_*`, rast/xfer fault) inside a work item | finish the work item with undefined results, **continue the remaining records and command buffers** so the appended ffb CB runs; fence signals; QueueSubmit stays VK_SUCCESS; record a per-context sticky fault | none — pass-or-fail verdict only |
| submit-time rejection (malformed record / dead handle in vnfront) | unchanged DEVICE_LOST path — but the rejected submission's ffb CB must still execute **or** the wait terminates via the alive watchdog; a silent drop hangs stock Mesa | depends — never a hang |
| engine never returns (per-work-item watchdog in cmdexec) | set ring `FATAL` status, drain, context unusable until `CTX_DESTROY` | guest abort (FATAL on next submit / alive watchdog) — honest loss |

`QueueSubmit` can never report an execution fault — it returned
VK_SUCCESS before the work ran; only the feedback slot and the ring
status word are observable. The sticky per-context fault register is
therefore the diagnostic channel (debug tap + bridge `stats()`),
surfaced into run records as `device_faults=N`.
