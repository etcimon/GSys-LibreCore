# Native Timeline Host API Boundary

GSys LibreCore's explicit transfer-debug backend now implements timeline
semaphore creation, counter queries, host signals and host waits. This is
host-model tooling, not wire GPU timeline submission, RTL qualification or
Vulkan capability admission. Default GPU refusal and zero capsets remain.

## Decoder And Lifetime

- `load_decoder(native_timeline=True)` adds three core timeline commands and
  `VkSemaphoreTypeCreateInfo` chain admission to an in-memory profile copy.
  The pinned command-set/profile files and generated RTL tables are untouched.
  The default decoder remains unchanged; legacy wire/reply IDs, object kinds,
  roles and slot layouts are checked against the extended model. Host ROM
  addresses can differ; no byte-identical extended assembly is claimed.
- Before frontend allocation, native creation validates exactly the admitted
  type chain, flags, pointers and initial u64 counter. Binary and timeline
  generations enter distinct registries; external/additional chains reject.
- Counter replies preserve full u64 values and the actual Venus pointer/reply
  framing. Host signals must increase the counter. Null outputs, wrong types,
  stale objects and cross-device operations fail closed.
- Host waits validate at most16 semaphore/value pairs and all/any flags. Zero
  and finite timeout return VK_TIMEOUT; infinite waits cooperate with later
  host signals. Saved deadlines do not restart on poll. Resumed waits compare
  captured generations before observing readiness, preventing object-ID reuse
  from falsely satisfying old waits.
- Destroy/reset removes counters and suspended tasks. The same generation
  capture fixes stale-ID reuse in native fence waits.
- Timeline host commands report `VK_ERROR_DEVICE_LOST` through
  `NativeSubmissions.lost()` once the owning context faults - counter
  queries return no payload on the lost path, signals do not mutate
  counters, and waits preempt the per-semaphore failure check with the
  stronger context-level result. The canonical-context resolution inside
  `lost()` matters because command views are `replace()` copies whose
  `id()` never matches the faults set.

## Frozen Evidence

182 checks pass in12.467s from
`~/.cache/librecore/apu/native-execution.fzuriueh`; all70 frozen hashes remain
unchanged and current inputs match. Eleven timeline cases cover creation,
full-width counters/signals, monotonic rejection, all/any/zero/finite/infinite
waits, type/output validation, object reuse, teardown, decoder ID compatibility
and default refusal. One additional fence-generation regression covers the
shared lifetime hazard.

Eight-source MIT tier/header/ASCII/syntax/whitespace audit and native/default-PGO
presence preflight pass. Presence does not install, build or train. Host timings
are not simulator throughput or compiler/simulator PGO evidence.

## Open Gates

Queue timeline submit chains remain rejected. Implement bounded queued value
reservations and wait-before-signal progress without violating per-queue FIFO;
the current context-serialized binary scheduler cannot stand in for that work.
This gate is now implemented in the host diagnostic lane under
`apu-native-timeline-queue-implementation.md`; pinned RTL admission stays closed.
External semaphore import/export, broader multi-batch scheduling, shader/image
execution, full barriers and deeper Mesa fault-propagation paths beyond the
host sync surface (events, fences, timelines, queries, idle) remain open.

RTL unmap ownership/capacity/alias reconciliation, truthful profile/capset
admission and stock-software/hardware/CTS/aggregate/formal/synthesis/physical/
WSI/timing/area/power/silicon qualification remain separate gates.

Review: host-only tooling; no functional RTL/config/ISA/CSR/DTS/discovery,
clock/reset/SRAM/DFT/PMU or timing-cone change. No upstream notices or link-set
edits. Compiler/simulator PGO policy and spec-index statuses are unchanged.
Core/Storamic work is untouched; changes remain uncommitted.
