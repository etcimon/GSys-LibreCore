# Native Timeline Queue Scheduling

GSys LibreCore's opt-in host transfer backend now supports bounded timeline
submit chains and per-queue progress. Default GPU submission remains refused;
zero Vulkan capsets remain advertised. These diagnostic queues are not new
advertised RTL queues or stock Vulkan/RTL qualification.

## Submission And Scheduling

- The native-only decoder profile admits `VkTimelineSemaphoreSubmitInfo`.
  Validate its exact chain, u64 arrays, declared counts, object generations and
  common device before admission. One semaphore-bearing batch, at most16 waits/
  signals and existing CB/job/byte limits remain explicit restrictions.
- Timeline waits can precede signal submission. Signal reservations must exceed
  current/reserved values and any same-batch wait on that semaphore. Values
  publish only after job/memory retirement; failures propagate without false
  increments. Host signals cannot overtake an already-reserved queue signal.
- Queue lanes use device generation/family/index, not caller object IDs.
  Aliases preserve FIFO. Bounded round-robin selection considers only each
  lane's head, so a blocked waiter cannot prevent another queue's producer or
  ready sibling from progressing.
- Internal transfer jobs retain context-wide FIFO and act as ordering barriers.
  Work positions, byte budgets, context fairness, cancellation and memory leases
  remain intact. Queue-head scanning is bounded by the128-job global limit;
  preparation performs no guest DMA.
- Binary re-signals also depend on prior token consumption. Claiming a wait is
  not sufficient to permit a second signal on another lane; mixed binary/
  timeline wait cases cover this ordering.
- Completion cleanup is registered before committing semaphore reservations,
  so exceptional commit failure still drains queue/semaphore leases through
  the existing context-fault path.

## Verification And Receipts

197 frozen checks pass in14.198s from
`~/.cache/librecore/apu/native-execution.xn7i05gj`; all74 frozen hashes remain
unchanged and current inputs match. Eleven new queue cases cover wait-before-
signal, aliases/FIFO, internal barriers, value ordering, failed admission,
same-batch constraints, actual recorded transfer I/O failure, cancellation,
cross-lane binary re-signal ordering, ready-lane fairness and commit faults.

Composed bridge fixtures now register cleanup on the owning test and close
streams even when teardown fails. The runner freezes itself and rejects
ResourceWarning/unraisable-finalizer diagnostics despite a zero child exit.
Four receipt regressions cover healthy, empty/failed, resource-warning and
unraisable outcomes. Earlier warning-bearing successes are not clean receipts.

Eleven-source MIT tier/header/ASCII/syntax/whitespace audit and native/default-
PGO presence checks pass without installation/build/training. Timeout receipt
`native-execution.m9ybt_sq` remains INCOMPLETE/exit4, not PASS. Frozen host tests
remain disjoint from live implementation; no simulator throughput is inferred.

## Review And Remaining Gates

Host-only changes: no functional RTL/config/ISA/CSR/DTS/discovery, clock/reset,
SRAM/DFT/PMU or timing-cone edits. Pinned RTL command/profile files, upstream
notices and link sets are untouched. No new physical queue, capability,
spec-index status or PGO policy is promoted. Core/Storamic changes are preserved;
all work remains uncommitted.

Remaining: broader/multi-batch and external synchronization profiles; bounded
shader/image execution; full barrier and stock Mesa execution-error/feedback
semantics; RTL unmap retention/capacity/alias reconciliation; truthful capability
admission. Stock-software/hardware, remote/aggregate/CTS/compliance/formal/
synthesis/physical/WSI/timing/area/power/silicon qualification remain open.
