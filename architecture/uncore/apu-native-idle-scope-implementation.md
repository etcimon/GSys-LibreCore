# Native Queue And Device Idle Scope

GSys LibreCore now scopes native idle waits to the owned queue/device instead
of blocking both APIs on every context job. Default GPU refusal, diagnostic
compute admission and zero Vulkan capsets remain unchanged.

## Ownership And Continuation

- Native queue lanes are immutable `(device, family, index)` values. Queue
  aliases wait on their shared lane; an unrelated parked queue no longer holds
  an otherwise idle queue.
- Device idle checks all native lanes owned by that device, not other devices.
  Internal `lane=None` jobs remain context-wide ordering barriers. Legacy lanes
  lacking device metadata are conservatively included in device waits.
- Native idle checks run inside the continuation handler, not the generic
  context-wide replay blocker. A suspended wait retains its canonical handle
  and lane identity, rechecking both before resume. Raw-ID reuse or changed
  metadata fails closed rather than redirecting a wait.
- Context-scoped GPU loss returns LOST without waiting for unrelated queued
  cleanup. Explicit context reset cancels idle continuations and jobs. Prefix
  commands are not replayed when a wait resumes.

The scan is bounded by the existing128-job executor limit. No new guest-memory
read, polling thread, timer or hardware state is introduced. Existing reply
views, cancellation, leases and queue FIFO scheduling remain.

## Evidence

348 frozen checks pass15.110s from
`~/.cache/librecore/apu/native-execution.fozvkm4h`;94 hashes unchanged and live
inputs match. Ten new cases cover unrelated queue progress, aliases, own/foreign
device scope, internal barriers, generation/lane changes, reset, fault feedback
and prefix non-replay.

Five-source MIT tier/header/ASCII/syntax/whitespace audit passes. Native presence
files=92 and default-PGO DEV PREFLIGHT OK perform no installation/build/training/
tests. Frozen lanes, warning/timeouts and separate compiler/simulator PGO policy
remain.

## Review And Gates

Host-only: no functional RTL/config/ISA/CSR/DTS/discovery, clock/reset/SRAM/DFT/
PMU or timing-cone changes. Hardware tables/ABI and spec-index statuses remain;
upstream/link sets and core/Storamic changes are untouched. Uncommitted; no
timing/area/power, stock renderer, RTL/CTS or silicon promotion.

GPU loss remains conservatively context-scoped, not full multi-device Vulkan
fault isolation. Broader synchronization, indirect/shader/image/graphics/
specialization and stock feedback semantics remain open. RTL retained-unmap
owner/alias/capacity and full capability/software/hardware/CTS/formal/synthesis/
physical/WSI qualification remain independent.
