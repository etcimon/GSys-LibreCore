# Bounded Internal Compute Foundation

GSys LibreCore's native diagnostic executor now has internal cooperative
compute operations. Wire shader/pipeline/descriptor replay remains refused;
default GPU refusal and zero Vulkan capsets stay. This is not a firmware
renderer, stock Vulkan backend or RTL/shader qualification.

## Internal Execution

- Immutable SPIR-V, buffer bindings, push words and group dimensions enter the
  existing executor with shared FIFO/lane/job/byte budgets and memory leases.
  Pipeline/descriptor object admission is not bypassed through this host API.
- Reuse the existing bit-exact shader reference model with an optional live
  memory adapter. Legacy vector initialization remains the default. No
  disconnected buffer snapshot or bulk post-execution copy is substituted.
- Bound modules to4096 words,16 buffer bindings/64KiB,32 push words,64 local
  invocations/256 total invocations and65536 total steps. Each turn runs at most
  32 instructions; each instruction has a4096-byte I/O ceiling. An instruction
  exceeding the profile fails terminally, without replaying partial effects.
- Buffer generation/extent/context permissions are checked; uniform bindings
  are not write capabilities. Workgroup barriers rendezvous cooperatively,
  robust OOB stores remain suppressed, and an explicit watchdog faults instead
  of treating exhausted execution as success.
- Compute shares transfer ordering and observes prior queued writes. I/O
  charges survive faults; cancellation drains runtime and owner leases.
  Read-callback reset cannot write into a retired context.

241 frozen checks pass in13.845s from
`~/.cache/librecore/apu/native-execution.0u098399`; all81 hashes remain unchanged
and live inputs match. Eleven new compute cases cover stores/order, instruction
quanta/watchdog, barriers/zero groups, robust bounds, permissions, I/O failure,
leases/admission rejection and reset during a live read.

Five-source MIT tier/header/syntax/whitespace audit passes. New code is ASCII;
existing shader Unicode remains. Native/default-PGO presence is no-build;
strict receipts/timeouts remain. Host duration is not simulator/PGO evidence.

Review: no functional RTL/config/ISA/CSR/DTS/discovery, clock/reset/SRAM/DFT/PMU
or timing-cone changes. Hardware tables, upstream notices/link sets, PGO policy
and spec-index statuses stay. Core/Storamic changes are preserved; uncommitted.

Next: wire compute pipeline/descriptor generation and extent admission into
this executor, then graphics/image breadth, full sync and stock fault/feedback.
Capability/software/hardware/CTS/formal/synthesis/physical/WSI/silicon gates stay.

## RTL Unmap Evaluation

No RTL change is made in this increment. `g6lc_apu_vgctl.sv` currently frees
guest backing and publishes UNBACKED (blob-owned unmap becomes lazy). Existing
`vc_hold` drains cmdexec/shader/xfer/raster, not the full frontend owner/alias
transaction. Merely changing `StUnmapPriv` to publish a private base is unsafe.

The required transaction must acquire/retain the owner generation, account for
all mapped aliases and context-independent blob lifetime, establish quiescence,
allocate private capacity before freeing source backing, copy with bounded
I/O, validate publication, then release old ownership. Capacity/read/write/
publication failures must preserve source ownership or fail closed/reset,
never fabricate retained bytes. Remapping must also move retained bytes back;
current plain-map/free behavior cannot stand in for that.

Memory-backed exports currently lack the complete owner-pin/alias contract
needed across context sweeps. The transaction must reconcile that rather than
only changing unmap's sentinel. Private allocator capacity, concurrent bind/CAS
publication, alias bases and per-context teardown remain explicit RTL gates.

Follow-up buffer provenance/resolution is implemented in
`apu-native-buffer-descriptor-implementation.md`; wire pipeline/descriptor
replay and the remaining admission/qualification gates are still open.

Follow-up RTL slice: the memory-backed `UNMAP_BLOB` owner-hold
(submission hold + engine drain + deferred extent free + UNBACKED
publish) is implemented and leaf-verified in
`apu-vgctl-unmap-hold-implementation.md`.  Alias accounting,
owner-generation acquisition, private retained bytes, capacity and
remap-move-back remain open as evaluated above.
