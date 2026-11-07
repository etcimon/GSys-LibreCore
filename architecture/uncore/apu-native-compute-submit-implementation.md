# Diagnostic Native Compute Wire Submission

GSys LibreCore now exposes a separately gated diagnostic compute path through
the existing native queue/fence/bridge transport. This is a host reference model,
not a firmware renderer, stock Vulkan admission or hardware qualification.
Default GPU refusal and zero Vulkan capsets remain unchanged.

## Modes And Queue Contract

`--compute-submit` requires `--transfer-submit`. Both options default false;
transfer-only mode still rejects shader replay. Programmatic mode arguments
must be bool and obey the same dependency, before decoder/device side effects.
The native CLI labels this mode `COMPUTE-DEBUG Vulkan-capsets=0`.

Compute uses the existing bounded replay/executor and binary/timeline queue
dependencies. No eager golden SUBMIT/WAIT path is enabled. Queue and command
buffer devices must match before leases/reservations are published. Fences
report completion only after object/memory retirement, including cancellation.
Finite/zero/infinite wait behavior is unchanged.

Runtime failure marks context-scoped GPU loss while leaving host query/control
operations usable. Fence status/wait and later submits report loss; reset of a
fence does not clear device loss. Already queued GPU work faults before later
writes, including parked timeline work, and drains leases/fences. Explicit
context/device reset retains cancellation semantics, not failure retirement.
This conservative context scope is not full multi-device Vulkan fault isolation.

## Evidence

310 frozen checks pass18.933s from
`~/.cache/librecore/apu/native-execution.3k9b_vc0`;90 hashes unchanged and live
inputs match. Eleven new cases cover explicit modes, transfer-only refusal,
actual compute/fence ordering, sticky faults/queued-work failure, reset, binary/
timeline chains, cross-device rejection, CLI preflight and real local IPC.

The real existing bridge client drives the native subprocess through context/
blob allocation, wire pipeline/descriptor recording, memory export/relocation,
asynchronous compute submit and fence wait; shared backing contains the shader
store. The subprocess is not RTL. Endpoint features/capsets are not promoted.

An intermediate309 run found a timeline regression: loss drained waiters as
cancelled rather than faulted. Separating loss retirement from reset cancellation
restores the existing failure contract; the final full cohort passes.

Eight-source MIT tier/header/ASCII/syntax/whitespace audit passes. Native
presence files=88 and default-PGO DEV PREFLIGHT OK perform no install/build/
training/tests. Frozen lanes, strict warning/timeouts and separate compiler/
simulator PGO receipts remain.

## Review And Remaining Gates

Host-only: no functional RTL/config/ISA/CSR/DTS/discovery, clock/reset/SRAM/DFT/
PMU or timing-cone changes. Hardware tables/ABI, upstream notices/link sets and
spec-index statuses stay. Core/Storamic and concurrent documentation changes
are preserved; uncommitted. No timing/area/power/silicon promotion.

This is bounded scalar-buffer compute, not full Vulkan compatibility. Nonempty
specialization, descriptor arrays/images/samplers, shader/graphics/image/sync
breadth and stock fault-feedback are open. RTL retained-unmap owner/alias/
capacity and full capability/software/hardware/CTS/formal/synthesis/physical/
WSI/silicon gates remain independent. A stock loader/Mesa/Venus/Zink endpoint
must not be advertised from these diagnostic native receipts.

Bounded scalar specialization now follows
`apu-native-specialization-implementation.md`; broader specialization remains
outside the debug profile, with all stock/hardware gates unchanged.

Coherent compute memory/buffer scope validation now follows
`apu-native-compute-barrier-implementation.md`; shader-image and broader sync
semantics remain open.
