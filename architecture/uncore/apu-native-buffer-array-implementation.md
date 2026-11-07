# Bounded Native Buffer Descriptor Arrays

GSys LibreCore now admits one fixed descriptor-array dimension of buffer blocks
in explicit native compute replay. Default GPU refusal, transfer-only shader
refusal and zero Vulkan capsets remain unchanged.

## Representation And Lifetime

- Shader bindings carry an element index. Runtime keys are
  `(set, binding, element)`; existing record aux low bits carry that index.
  Sort rows by set/binding/element before building model records so interleaved
  internal inputs cannot overwrite another binding's descriptor slot.
- Replay unwraps one fixed ARRAY of STRUCT, checks shader visibility and layout
  count, and resolves every element's provenance, generation, range and dynamic
  offset. Total admitted rows remain at most16 and binding bytes at most65536.
  Existing sorted Vulkan dynamic-offset consumption includes unused rows.
- Each element contributes its validation guard and references to the existing
  transactional admission. Shared objects/backing are pinned once and retained
  through queued execution, retirement or cancellation.
- UBO reads remain readonly. The shared SPIR-V reference LSU now faults stores
  through raw uniform descriptor kinds6/8 before physical memory permissions:
  an overlapping writable SSBO cannot lend permission to a readonly descriptor.
  This closes a reference-model permission bypass, not an RTL qualification.

Runtime-sized/nested descriptor arrays and image/sampler arrays stay refused.
Scalar bindings retain element0. No hardware profile, descriptor record ABI or
pipeline/module provenance change is made.

## Evidence

374 frozen checks pass17.179s from
`~/.cache/librecore/apu/native-execution.li3bc79b`;96 hashes unchanged and live
inputs match. Ten new cases cover wire second-element stores, per-element
dynamic offsets, UBO reads, missing/stale second elements, layout/row budgets,
readonly alias faults, interleaved rows, cancellation and two-element copies.

An intermediate run exposed a fixture using16-byte offsets although the pinned
storage alignment is256; corrected test offsets respect the profile. A message
regex mismatch was also corrected without relaxing rejection. The final full
cohort passes.

Six-source MIT tier/header/syntax/whitespace audit passes; new sources ASCII and
existing reference-model Unicode retained. Native presence files=94 and
default-PGO DEV PREFLIGHT OK perform no installation/build/training/tests.
Frozen lanes, strict warnings/timeouts and separate compiler/simulator PGO
policy remain.

## Review And Gates

Reference/software only: no functional RTL/config/ISA/CSR/DTS/discovery,
clock/reset/SRAM/DFT/PMU or timing-cone change. Hardware tables/ABI, upstream/
link sets and spec-index statuses remain; core/Storamic work is preserved.
Uncommitted; no timing/area/power, stock renderer, RTL/CTS or silicon promotion.

Broader specialization/shader/image/graphics/synchronization and stock feedback
semantics remain open. RTL retained-unmap owner/alias/capacity and full
capability/software/hardware/CTS/formal/synthesis/physical/WSI qualification
remain independent.
