# Internal Compute Command Replay

GSys LibreCore now supports explicit internal
`replay.enqueue(context, buffers, compute=True)`. The default and transfer wire
path still refuse shader commands. Zero Vulkan capsets remain.

## Replay And Lifetime

- Bind canonical compute pipelines/modules and validate by-value descriptor
  layout compatibility, visibility, storage class and common device.
- Consume dynamic offsets in set/binding/element order, including unused
  dynamic rows. Validate exact record-local counts before resolving operands.
  Compatible lower-prefix binds preserve higher sets; incompatible binds disturb
  them. Shader descriptor arrays/images/samplers remain outside this profile.
- Snapshot push values with stage/range identity and partial-update preservation.
  Require initialized, compatible words for the declared push block rather than
  fabricating zero values for undefined input.
- Secondary buffers own fresh shader state; executing them invalidates primary
  shader state. Existing bounded recursion/repeated-buffer rules remain.
- Revalidate descriptor sources, bindings, pool epochs and even unused bound
  sets before/after object-pin acquisition. Transactional object/parent leases
  and executor memory-work leases survive dispatch/copy ordering through retire
  or cancellation. Pin failure restores CB state and original pin counts.
- Descriptor layout storage is not leased: native rows/signatures are retained
  by value. The descriptor resolver now returns five base references and a
  pre-publication validation guard. Canonical zombie shader modules can be
  leased while their owning pipeline remains held.
- Pending pipeline destruction, descriptor pool reset/destruction and descriptor
  updates/frees park. Descriptor mutation is conservatively serialized per
  context while any set lease exists; timeline/binary producers remain separate.

Dispatches append Compute operations to the same executor as transfers/images;
no shadow memory or eager golden SUBMIT/WAIT is used. Limit16 dispatches per job,
each with the existing65536-instruction bound (aggregate at most1048576),
existing256 invocation/16 binding/65536 binding-byte bounds, and32-byte
descriptor-read charges against the replay I/O/payload budget. Existing command,
operation, group, queue, memory and poll limits still apply.

## Evidence

299 frozen checks pass16.776s from
`~/.cache/librecore/apu/native-execution.jpnu4f79`;89 hashes unchanged and live
inputs match. Twenty-five new cases exercise real recording/dispatch, fill/
compute/copy ordering, lifetime destruction, parked mutation, cancellation,
dynamic order/counts, push words, stale generations/epochs, pin rollback,
secondary state, visibility/type checks, prefix disturbance and late poisoning.

The intermediate292 run found two fixture errors (missing secondary handle);
an explicit handle fixes those. The final cohort passes all cases. Six-source
MIT tier/header/ASCII/syntax/whitespace audit and native/default-PGO no-build
presence pass. Strict warning, receipt and timeout behavior remains.

## Review And Gates

Host-only: no functional RTL/config/ISA/CSR/DTS/discovery, clock/reset/SRAM/DFT/
PMU or timing-cone change. Hardware ABI/tables, upstream notices/link sets and
PGO policy stay; core/Storamic work is preserved. No timing/area/power, stock
software, RTL/CTS or silicon promotion. Changes remain uncommitted.

Next is separately admitted diagnostic wire dispatch with queue/fence/fault
tests, not capset admission. Broader shader/specialization/image/graphics/sync,
stock fault-feedback and hardware retained-unmap owner/alias/capacity remain.
Full capability/software/hardware/CTS/formal/synthesis/physical/WSI gates stay.

The separately gated queue/fence/bridge integration now follows
`apu-native-compute-submit-implementation.md`; default and transfer-only refusal
and zero capability advertisement remain.
