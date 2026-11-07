# Native Layout Identity And Lifetime

GSys LibreCore's native model now retains descriptor layout rows and compatibility
identity by value. Wire shader submission remains refused; default GPU refusal,
zero Vulkan capsets and hardware tables stay unchanged.

## Implemented

- Native set layouts retain immutable row snapshots and exact signatures:
  layout flags, sorted bindings/type/count/stage flags and immutable sampler
  state values. Legacy row hashes/packed records do not change.
- Allocated sets retain their own row/signature snapshot. Updates, copies,
  resolution and freeing no longer require live original layout storage.
  Pool generation/epoch checks still apply. Reusing a destroyed layout ID
  cannot redirect an old set.
- Native pipeline layouts retain set signatures and canonical push ranges,
  common device and stable context-owner identity. Prefix compatibility checks
  exact values, not raw IDs or the legacy hash. Flags outside the current
  profile reject. Push masks include core ALL; ranges cannot repeat a shader
  stage, exceed bounds or violate word alignment.
- Recorded bind/push commands retain the layout value even after the layout
  object is destroyed. This metadata does not enter the16-word RTL record.
- Unsupported reference-model specialization now becomes a bounded native
  StreamFault, not an escaping NotImplementedError or false pipeline success.

## Frozen Evidence

267 checks pass in13.820s from
`~/.cache/librecore/apu/native-execution.todbvh84`; all85 hashes remain unchanged
and live inputs match. Thirteen new cases cover layout destruction/reuse,
set free/update/copy, stage-sensitive signatures, equivalent handles, canonical
push order/bounds/masks, immutable sampler values, recorded identity, context
isolation and specialization refusal.

The first264-check run found two compatibility failures: temporary stream reply
views were used as owners. The fix anchors identity to the actual context owner;
the final cohort includes a cross-owner isolation regression.

Six-source MIT tier/header/syntax/whitespace audit passes. New code is ASCII;
existing golden Unicode remains. Native/default-PGO presence passes without
install/build/training. Strict warning/error/timeouts remain enabled.

## Review And Remaining Gates

Host-only: no functional RTL/config/ISA/CSR/DTS/discovery, clock/reset/SRAM/DFT/
PMU or timing-cone change. Hardware ABI/tables, upstream notices/link sets and
PGO policy stay; no spec-index/capability or timing/area/power promotion.
Core/Storamic work is preserved; changes remain uncommitted.

This is native subset identity/lifetime, not full Vulkan layout admission.
Pipeline/module snapshots and generation leases, shader entry/specialization
semantics, replayed descriptor/dynamic/push state and wire dispatch/fences remain.
Graphics/image/sync breadth, stock fault-feedback, RTL unmap owner/alias/capacity
and capability/software/hardware/CTS/formal/synthesis/physical/WSI/silicon
qualification stay separate/open.
