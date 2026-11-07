# Native Buffer Descriptor Provenance

GSys LibreCore now resolves bounded buffer descriptor operands for the internal
compute foundation. This does not enable wire pipeline/descriptor/dispatch
replay. Default GPU refusal and zero Vulkan capsets remain unchanged.

## Provenance And Resolution

- Native frontends opt into host-only descriptor provenance. Successful buffer
  writes capture the buffer and memory canonical generations, original binding,
  logical sizes/range and descriptor type. Native buffer objects retain usage.
- Descriptor copies propagate provenance; frontend record writes invalidate it
  before modifying bytes. Source-less copies cannot retain old destination
  provenance. Packed32-byte descriptor records and default golden mode stay.
- `vn_descriptor_operands.py` validates set/pool/layout epochs and generations,
  common device, originating buffer generation/binding, memory generation,
  type/usage, pinned alignment/range limits and logical (not page-rounded)
  bounds. Dynamic offsets apply only to dynamic rows.
- Reconcile actual memory record words with captured provenance. Recheck context,
  references and source/binding state after I/O so read-time mutation cannot
  publish a stale operand.
- Return an immutable ShaderBinding plus required canonical object references.
  This resolver does not itself pin or publish work: the future replay caller
  must transactionally retain all references/parents and memory through retire.

Descriptor arrays can be resolved elementwise; the current internal Compute
binding format still rejects duplicate binding rows/arrays. Native shader wire
submission stays refused. This is not complete descriptor/layout compatibility
identity, layout-destruction lifetime support or capability admission.

## Evidence

254 frozen checks pass in16.214s from
`~/.cache/librecore/apu/native-execution.xd4kd7ad`; all83 hashes remain unchanged
and live inputs match. Thirteen new cases cover actual compute through a wire
descriptor, copy/reuse/rebind, dynamic/WHOLE_SIZE bounds, unwritten/alignment,
record invalidation/tamper, pool reset, byte identity, source-less copy,
read-time mutation, usage and device ownership.

Five-source MIT tier/header/syntax/whitespace audit passes. New code ASCII;
existing golden Unicode preserved. Native/default-PGO no-build presence passes;
strict receipts and timeout policy remain. No RTL/CTS/stock-renderer evidence.

## Review And Remaining Work

Host-only: no functional RTL/config/ISA/CSR/DTS/discovery, clock/reset/SRAM/DFT/
PMU or timing-cone changes. Hardware tables, upstream notices/link sets, PGO
policy and spec-index statuses remain. Core/Storamic work is preserved;
uncommitted. No timing/area/power/silicon promotion.

Next: full pipeline/module/layout identity and lifetime admission, recorded
descriptor/push state and generation leases, then bounded wire dispatch/fence
retirement. Shader/image/graphics breadth, full sync/stock fault-feedback,
RTL unmap ownership/alias/capacity and independent capability/software/hardware/
CTS/formal/synthesis/physical/WSI gates stay open.

Native row/signature lifetime and pipeline-layout identity now follow
`apu-native-layout-lifetime-implementation.md`; wire shader admission remains
open and unchanged hardware identity is not promoted.
