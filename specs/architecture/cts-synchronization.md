# `synchronization` (64,871) and `synchronization2` (81,616) — fences, semaphores, events, barriers, queue ordering, cross-instance

Source: `specs/VK-GL-CTS` @ `f6a29701`; must-pass `vk-default/synchronization.txt`,
`vk-default/synchronization2.txt`; tests in
`external/vulkancts/modules/vulkan/synchronization/vktSynchronization*.cpp`. Owner W2
(cmdexec fences/semaphores/events — plan W2.4). Gates CTS-1 (`basic`, `smoke`, `op.single_queue`
core subsets), CTS-3 (`timeline_semaphore` at 1.2, `synchronization2` at 1.3, `op.multi_queue`
when more than one queue exists), later (`cross_instance` external handles, W9).

## Inventory

| `dEQP-VK.synchronization.` | cases | what |
|---|---:|---|
| `cross_instance` | 31306 | external semaphore/fence/memory across instances (opaque fd, sync fd, dma-buf) — W9 |
| `op` | 20131 | `single_queue` 7324 / `multi_queue` 12807: every (write op, read op) pair over every resource type synchronised by barrier / event / semaphore / fence / timeline |
| `signal_order` | 7640 | semaphore signal/wait ordering across submissions and queues |
| `timeline_semaphore` | 2880 | 1.2 timeline semaphores (device/host signal, wait-before-signal, max difference) |
| `win32_keyed_mutex` | 1964 | Windows — NotSupported |
| `implicit` | 512 | implicit ordering guarantees (same queue, submission order) |
| `global_priority_transition` | 396 | KHR_global_priority |
| `basic`, `smoke`, `internally_synchronized_objects` | 29, 11, 2 | fences/semaphores/events basics; thread-safe objects |
| `synchronization2.*` | 81616 | the same families through vkQueueSubmit2 / vkCmdPipelineBarrier2 / events2 / timestamps2 (1.3 core) |

## Architectural logic

```text
LOGIC SYNC-L1 · Fences, binary semaphores, events and barriers order work exactly as submitted
  CLAIM       vkQueueSubmit batches with wait/signal binary semaphores and a fence
              execute in submission order per queue; semaphores signalled by one
              submission are waited by a later one (same or another queue); fences
              observe completion of the whole batch (host wait/reset/status); events
              (vkCmdSetEvent/ResetEvent/WaitEvents, host vkSetEvent) gate execution;
              pipeline barriers with stage/access masks make every (write op, read op)
              pair across buffers/images/attachments visible — copy, clear, blit,
              dispatch, draw, indirect, index/vertex/uniform/storage/sampled/attachment
              accesses; implicit guarantees (host writes before submit, same-queue
              order) hold; `signal_order` (semaphore signals observed in order).
  SOURCE      synchronization.{basic,smoke,implicit,op.single_queue,signal_order,
              internally_synchronized_objects}.*; synchronization2 counterparts.
  MECHANISM   cmdexec: submit FIFO, serialized execution, fences via the publication
              path (3c-ii); needs: *semaphores* as objects (binary: signalled by
              completion of batch N, waited by batch M — in a single serialized queue a
              wait on a semaphore signalled by an earlier batch is satisfied by order; a
              wait on a semaphore signalled by a *later* batch from another queue must
              block — with one queue family it cannot happen except via host signals of
              timeline semaphores), *events* (device set/reset as records; host set via
              a command path; WaitEvents blocks the executor until set — needs a
              non-blocking park so other queues/host progress, like vnpump's park),
              barriers as explicit records that, today, complete trivially (MEM-L2's
              documented argument) and in W5 drive cache maintenance.
  REQUIRES    Venus semantics: Mesa's vn_queue implements semaphores/fences largely
              guest-side over the renderer's fence/seqno model (ring seqno waits,
              `vkWaitSemaphoresMESA`-class commands) — the wire-level obligations must
              be re-read from vn_queue.c at the pin: which semaphore operations reach
              the renderer (timeline signals/waits do; binary semaphores are often
              folded by Mesa into submission order). W2.4 owns this analysis.
  FORBIDS     Treating a wait as satisfied by record order when the signaller is a
              host-side or cross-queue operation; completing a fence before memory
              visibility of the batch's writes.
  CHECK       basic.*, smoke.*, implicit.*, op.single_queue.* (CTS-1) — the single-
              queue op matrix is the big first target (7324).
  COST        semaphore/event objects (small); the park mechanism.
  FEEDS       MEM-L2, W5 caches, QP (availability); CTS-1.
  STATUS      not-run

LOGIC SYNC-L2 · Timeline semaphores (1.2 core) and synchronization2 (1.3 core)
  CLAIM       Timeline semaphores with monotonically increasing 64-bit values, device
              and host signal/wait, wait-before-signal across queues/host,
              maxTimelineSemaphoreValueDifference; synchronization2's submit2 batches
              with per-semaphore stage masks, pipeline barrier2/events2 with 64-bit
              stage/access masks, vkCmdWriteTimestamp2, and the new NONE/HOST stages.
  SOURCE      synchronization.timeline_semaphore.* (2880), synchronization2.* (81616
              — mostly the same op matrix).
  MECHANISM   A timeline semaphore = a 64-bit counter object in device memory with a
              wait list (batches parked until value ≥ target — same park mechanism);
              host signal = a Venus command writing the value and waking parked
              batches; sync2 = decode rows for the new structures mapping onto the same
              records (masks are wider but the serialized engine ignores stage
              granularity today — documented).
  REQUIRES    1.2/1.3 ladder; Zink's floor requires timeline semaphores.
  FORBIDS     Implementing wait-before-signal by failing the submit; signalling out of
              value order.
  CHECK       timeline_semaphore.* (CTS-3), synchronization2.basic/op.single_queue.*.
  COST        counters + park list.
  FEEDS       Zink, UE (timeline semaphores are UE's default on Vulkan ≥ 1.2); CTS-3.
  STATUS      not-run (NotSupported)

LOGIC SYNC-L3 · Multiple queues and cross-instance synchronisation
  CLAIM       op.multi_queue: the same pairs across queues of different families
              (requires ≥ 2 queue families or ≥ 2 queues — we have one universal queue;
              the tests are NotSupported with one queue); cross_instance: external
              semaphores/fences (opaque fd, sync fd) and external memory across two
              VkInstances/devices — the W9 dma-buf/sync-fd story.
  SOURCE      synchronization.op.multi_queue.*, cross_instance.*.
  MECHANISM   Multiple queues = plan W8.7 (async compute/transfer queues with
              arbitration); external sync = W9 (sync_fd through virtio-gpu fences /
              drm syncobj — stock Venus maps external semaphores to renderer sync
              objects).
  REQUIRES    the queue architecture decision (one universal queue is legal; two queues
              in one family also satisfy many multi_queue variants).
  FORBIDS     Faking a second queue that serializes behind the first *without* honouring
              the independence the tests check (that is legal, actually — a second queue
              may be implemented by time-slicing; but priorities/ordering across them
              must then still be correct).
  CHECK       at W8/W9.
  COST        queue scheduling; external fence plumbing.
  FEEDS       W8.7, W9; CTS-4/5.
  STATUS      not-run (NotSupported)
```

## Exceptions

```text
EXCEPTION SYNC-X1 · NotSupported by truthful absence
  CONDITION   timeline_semaphore.* (1.2), synchronization2.* (1.3), op.multi_queue.*
              (one queue), cross_instance.* (external sync handles not advertised),
              win32_keyed_mutex.*, global_priority_transition.* (KHR_global_priority).
  RESULT      NotSupported.
  TRUTH       profile lines / version ladder / queue count.
  MECHANISM   Profile ROM.
  CHECK       ledger.
  FORBIDS     —

EXCEPTION SYNC-X2 · Barriers in the serialized engine
  CONDITION   Every pipeline barrier today.
  RESULT      Correct by construction (one engine, no cache) — stated, not assumed; the
              fails-if-removed control is MEM-L2's pipeline_barrier family plus
              op.single_queue.* when W5 adds any cache or concurrency.
  TRUTH       RT-P1 (name the instrument): the statement is tied to the configuration
              "no device cache, serialized executor, write-through DMA".
  MECHANISM   cmdexec records.
  CHECK       MEM-L2.
  FORBIDS     Carrying the statement into a configuration where it no longer holds.
```

## Implementation-order heuristics

| Heuristic | Trigger | Priority | Smallest useful action | Reject / defer when |
|---|---|---:|---|---|
| SYNC-H1 Read vn_queue at the pin | before W2.4 | precondition | list which semaphore/fence/event operations reach the renderer wire | — |
| SYNC-H2 Single-queue op matrix | CTS-1 | high | semaphore/event objects + park; run op.single_queue | — |
| SYNC-H3 Timeline | 1.2 ladder / Zink | high | 64-bit counter objects + host signal | — |
| SYNC-H4 Second queue | W8 | later | time-sliced second queue first (legal), real arbitration after measurement | — |

## Performance / area / scalability

Synchronisation is where throughput architectures lose correctness (CTS-P3): every
concurrency feature (multiple engines, async queues, caches) must re-run `op.*` and
`memory.pipeline_barrier`. Knobs: queue count, in-flight batches, park list depth.
