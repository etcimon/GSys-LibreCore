# Bounded Native Scalar Specialization

GSys LibreCore now admits bounded scalar specialization into native compute
pipeline snapshots. This remains the host reference/debug path; default GPU
refusal, transfer-only shader refusal and zero Vulkan capsets are unchanged.

## Root Cause And Implementation

The shared SPIR-V scanner routed specialization constants to its constant
handler, but the evaluator recognized only ordinary constant opcodes. Mapping
48/49/50/51 to their default-value counterparts fixes module creation and
default composite evaluation without changing hardware tables or wire layout.

`vn_specialization.py` reads each specialization record only between the actual
decoder-traced specialization pointer and layout field. It checks pointer/count/
array/data agreement, duplicate IDs, offset/range and record-local exhaustion.
Limits:32 entries,64 data bytes,4096 module words and4 pipelines per packet.
Entries use1/2/4-byte storage; known bool/int32/float32 constants require4 bytes.
Unaligned data offsets and overlapping ranges for distinct IDs are supported.
Unknown IDs are ignored; false is zero and any nonzero VkBool32 is true.

Original module words remain immutable. Each pipeline stores both source words
for canonical module/device/generation checks and separate immutable executable
words. Supported specialization constants become ordinary constants, SpecId
decorations are removed, and default composites fold through the normal scanner.
Batch pipelines sharing one module retain independent values. Module destruction
and raw-ID reuse cannot redirect existing specialized pipelines.

Only after full native validation does a specialization-free allocation record
reach the legacy frontend: that helper owns pipeline allocation/module pins,
not specialized execution. Original command/output handles remain unchanged.
Native replay uses the validated specialized code; no eager golden shader
SUBMIT/WAIT or temporary shared-module mutation is introduced.

Review also found null constants could materialize an arbitrarily large array
after specialization. The shared scanner now checks its existing16-word
constant capacity before allocating zeros, rather than relying on later limits.

## Evidence

325 frozen checks pass16.343s from
`~/.cache/librecore/apu/native-execution.x1pci2l5`;92 hashes unchanged and live
inputs match. Fifteen new cases cover defaults, raw float/bool values, composite
defaults, unaligned bytes, unused IDs, bounds/duplicates/counts, source identity,
batch independence, module reuse, actual internal/wire stores and oversized
null-array refusal. The earlier bounded-specialization-refusal test now checks
the required ignored-ID behavior.

Nine-source MIT tier/header/syntax/whitespace audit passes; new sources are
ASCII and existing scanner encoding is preserved. Native presence files=90 and
default-PGO DEV PREFLIGHT OK perform no installation/build/training/tests.
Frozen execution, warning/timeout checks and separate compiler/simulator PGO
policies remain.

## Review And Gates

Host-only: no functional RTL/config/ISA/CSR/DTS/discovery, clock/reset/SRAM/DFT/
PMU or timing-cone changes. No timing/area/power claim. Hardware ABI/ROM/profile
tables, spec-index statuses, upstream notices/link sets and core/Storamic work
are unchanged. Changes remain uncommitted.

The scalar operation subset now follows
`apu-native-specialization-op-implementation.md`; default hardware scanner
refusal remains. Wider/narrower scalar types, LocalSizeId and full specialization
semantics stay outside this profile. Other shader/descriptor/image/
graphics/sync and stock feedback work stays open. RTL retained-unmap owner/
alias/capacity and full capability/software/hardware/CTS/formal/synthesis/
physical/WSI/silicon qualification remain independent. These host receipts do
not establish stock Vulkan1.4 compatibility or a hardware renderer.
