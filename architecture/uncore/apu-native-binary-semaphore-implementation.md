# Native Binary Semaphore Scheduling

GSys LibreCore's opt-in host transfer profile now preserves binary semaphore
dependencies instead of rejecting all semaphore arrays. This is host-model
execution, not RTL/CTS, stock-software qualification or Vulkan capset admission.
Default GPU submission remains refused; both modes advertise zero capsets.

## Ownership And Ordering

- Plain binary semaphore creation is validated before frontend allocation:
  correct sType/pointers, zero flags and empty pNext. Only admitted binary
  generations enter the registry. Timeline/external chains do not silently
  become binary objects.
- A submission reserves only an already-submitted, unclaimed signal. Duplicate
  waits/signals, including raw-ID/internal-handle aliases, reject. Device and
  context ownership match the queue; all referenced generations stay pinned.
- Tokens are claimed only after complete job admission. Queue/memory/pin budget
  rejection leaves prior signals unclaimed and rolls back acquired leases.
  Wait-plus-resignal uses distinct input/output tokens.
- The executor's bounded prepare callback consumes all input signals before any
  job bytes execute. Output signals become available only after completion and
  memory retirement. Failed producers propagate failure, never fabricated
  success, to admitted consumers.
- Pending destruction parks. Completed unconsumed signals are removed on
  destruction; object-ID reuse cannot inherit them. Reset/context retirement
  drains pins, tokens and admitted-generation registry entries.

The diagnostic scheduler serializes queues within a context and requires prior
signal submission. It is not a general multi-queue or timeline scheduler.
Semaphore-bearing submissions currently allow one batch with at most16 waits/
signals; stage arrays must match and masks must be nonzero. Existing four-batch
no-semaphore submissions remain supported. These restrictions reject explicitly.
Per-queue diagnostic scheduling and binary re-signal consumption dependencies
now follow `apu-native-timeline-queue-implementation.md`; the internal transfer
API retains context FIFO. No additional hardware queue is advertised.

Token storage is bounded by live semaphore objects and the bounded pending-job
queue, not an unbounded history. Consumed tokens are discarded. Terminal jobs
clear their prepare callbacks; destroyed/context-retired generations are removed.

## Frozen Verification

170 checks pass in14.423s from
`~/.cache/librecore/apu/native-execution.kb924k4c`; all68 frozen hashes remain
unchanged and current inputs match. Eleven binary cases use actual Venus
creation/submission decode and test token ordering, wait/resignal, aliases,
double signals, unsubmitted waits, budget/pin rollback, stale-ID reuse,
timeline/flag rejection, producer I/O failure and teardown.

Seven-source MIT tier/header/ASCII/syntax/whitespace audit and presence-only
native/PGO preflight pass. No tool install, RTL build, training, remote run,
generated-simulator throughput or stock-renderer evidence is claimed.

## Review And Remaining Work

Host-only tooling: no functional RTL/config/ISA/CSR/DTS/discovery, clock/reset,
SRAM/DFT/PMU or timing-cone change. Optional admission remains the existing
explicit diagnostic flag. No upstream notices/link sets or core/Storamic work
changed; no spec-index promotion. Sources remain uncommitted.

Queue timeline/external APIs and multi-batch semaphore scheduling remain open, as do
shader/image work, full barriers, Mesa execution-error feedback, RTL unmap
retention/capacity/alias reconciliation, truthful capset admission and full
stock-software/hardware/CTS/formal/synthesis/physical/WSI qualification.

Host timeline creation/query/signal/wait follow-up is now implemented under
`apu-native-timeline-host-implementation.md`. Queue timeline submit chains and
external operations still reject; this does not widen hardware admission.
