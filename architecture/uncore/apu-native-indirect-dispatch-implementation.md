# Bounded Native Indirect Dispatch

GSys LibreCore now replays `vkCmdDispatchIndirect` in the explicitly admitted
diagnostic compute profile. Default GPU refusal, transfer-only shader refusal
and zero Vulkan capsets remain unchanged. This is host reference-model work,
not stock Vulkan or hardware admission.

## Live Arguments And Ownership

Replay reuses pipeline/module/layout/descriptor/push validation, then validates
the indirect buffer generation, INDIRECT usage, logical12-byte range, alignment,
device and memory ownership. A before/after-pin guard rejects late binding/
size/usage changes. Buffer/parent and source-memory leases survive queue waits,
execution, faults and cancellation.

`IndirectArguments` retains an owned source, not copied parameter bytes.
Runtime construction validates the module/bindings but does not read arguments.
Execution reads exactly12 bytes once, after preceding operations, and charges
them to the poll I/O budget. Short reads, revoked I/O or retired contexts fail
before shader writes. The live dimensions update both scheduling and the
NumWorkgroups builtin before invocation initialization.

Each dimension is at most64; total local invocations across groups at most256.
Zero dimensions retire without shader work but do not bypass dimension limits.
Existing65536 instruction,16 dispatch/job, binding/operation/byte/poll bounds
remain. The argument extent adds12 bytes to the reserved job-byte budget.
An insufficient residual instruction-I/O allowance defers shader progress,
without re-reading arguments on the next poll.

Explicit compute scope now includes indirect-command stage/read access for
transfer/shader -> indirect dependencies. Transfer-only and image-shader/
indirect-image access remain refused. This does not admit graphics indirect
commands.

## Evidence

364 frozen checks pass14.006s from
`~/.cache/librecore/apu/native-execution.58nly0rc`;95 hashes unchanged and live
inputs match. Sixteen new cases cover live transfer/compute writes, exactly-once
reads, builtin values, zero work, count/invocation limits, short/revoked reads,
usage/alignment/range/generation, late-pin rollback, distinct backing,
cancellation, context retirement during read, poll budget and mode refusal.
The wire submit/fence path observes real stores; no eager golden SUBMIT/WAIT.

Six-source MIT tier/header/ASCII/syntax/whitespace audit passes. Native presence
files=93 and default-PGO DEV PREFLIGHT OK perform no installation/build/training/
tests. Frozen lanes, strict warning/timeouts and separate compiler/simulator
PGO policy remain.

## Review And Gates

Host-only: no functional RTL/config/ISA/CSR/DTS/discovery, clock/reset/SRAM/DFT/
PMU or timing-cone change. Hardware tables/ABI, spec-index statuses and upstream/
link sets stay; core/Storamic work is preserved. Uncommitted; no timing/area/
power, stock renderer, RTL/CTS or silicon promotion.

Bounded buffer descriptor arrays and other shader/image/graphics/specialization/
sync/stock feedback semantics remain open. RTL retained-unmap owner/alias/
capacity and full capability/software/hardware/CTS/formal/synthesis/physical/
WSI qualification remain independent.

Fixed native buffer descriptor arrays now follow
`apu-native-buffer-array-implementation.md`; runtime/image/sampler arrays and
the wider qualification gates remain open.
