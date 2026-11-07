# Native Coherent Compute Barriers

GSys LibreCore now retains and validates coherent memory/buffer barriers for
explicit diagnostic compute replay. Default GPU refusal, transfer-only shader
refusal and zero Vulkan capsets remain. This is host reference-model evidence,
not stock Vulkan or hardware admission.

## Scope And Ownership

Inspection refined the plan's hypothesis: image barriers already checked
transfer scopes, but memory-only barriers discarded access masks. The native
host decoder now retains memory, buffer and image rows in wire order. Its
private keep extension does not change pinned hardware ROM/profile/record ABI.
Unretained memory access masks now fail closed rather than being silently
treated as coherent no-ops.

- Check exact counts/payload exhaustion and no pNext/dependency flags; at most
  16 combined rows. Payload reads charge the existing replay I/O budget.
- Capture every buffer/image generation before command append, including
  nonfinal array elements and mixed payload offsets.
- Transfer/host/generic scopes retain the coherent subset. Explicit compute
  adds compute stage and uniform/shader read/write access; per-side masks must
  be compatible with their stages. ALL_COMMANDS does not bypass mode checks or
  imply host stage access.
- Buffer ranges use logical extents, including bounded WHOLE_SIZE. Reject zero/
  overflow/out-of-bounds ranges, queue-family ownership transfer and foreign
  command-buffer devices. Barrier-only work retains buffer/backing/parent
  leases through retirement/cancellation without writing bytes.
- Memory barriers need no physical cache operation in this serial coherent
  model. Recorded dispatch -> barrier -> copy stays in executor order; fences
  follow actual work retirement.
- Mixed image rows retain their transfer/general layout/range rules and
  backing leases. Compute mode does not enable shader-image access.

## Evidence

338 frozen checks pass16.120s from
`~/.cache/librecore/apu/native-execution.918yfinf`;93 hashes unchanged and live
inputs match. Thirteen new cases cover wire dispatch/barrier/copy/fence order,
buffer-only leases/cancellation, transfer-only refusal, stage/access agreement,
range/family/device/generation checks, mixed rows, record-local counts and
unretained default-decoder masks.

The intermediate325 run caught a legacy submit fixture manually toggling GPU
admission after constructing the default decoder. Its memory-barrier check now
explicitly constructs the native profile; validation was not relaxed. The final
full cohort passes.

Six-source MIT tier/header/ASCII/syntax/whitespace audit passes. Native presence
files=91 and default-PGO DEV PREFLIGHT OK perform no installation/build/training/
tests. Frozen lanes, strict warning/timeouts and separate compiler/simulator
PGO policy remain.

## Review And Gates

Host-only: no functional RTL/config/ISA/CSR/DTS/discovery, clock/reset/SRAM/DFT/
PMU or timing-cone changes. Hardware tables/ABI, upstream notices/link sets and
spec-index statuses stay; core/Storamic changes are preserved. Uncommitted;
no timing/area/power/RTL/CTS/silicon promotion.

Broader synchronization and queue/device idle scope, shader/image/graphics/
specialization breadth and stock fault feedback remain open. RTL retained-
unmap owner/alias/capacity and full capability/software/hardware/CTS/formal/
synthesis/physical/WSI qualification remain independent.

Native queue/device idle ownership now follows
`apu-native-idle-scope-implementation.md`; broader synchronization is still open.

Compute-only indirect stage/read access now follows
`apu-native-indirect-dispatch-implementation.md`; graphics/image indirect
capabilities remain unadvertised.

Bounded compute shader-image scopes and read-only layouts now follow
`apu-native-shader-image-barrier-implementation.md`; transfer-only refusal remains.
