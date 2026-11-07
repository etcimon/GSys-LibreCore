# T2 Native Control Dispatch And Queue

GSys LibreCore's native verification backend now connects bounded control
packets to the resource/context lifetime layer. This completes a control
lifecycle slice, not the full model-in-the-loop device or a Vulkan renderer.

## Implemented Path

`ControlQueue.process(decoded buffers)` -> explicit GuestDma authorization ->
request snapshot -> ControlDispatcher -> ResourceState -> scattered reply.

- `vn_control.py` decodes the existing little-endian24-byte control header.
  Supported commands: CTX_CREATE, CTX_DESTROY, CTX_ATTACH_RESOURCE,
  CTX_DETACH_RESOURCE and RESOURCE_UNREF. Replies use existing response IDs
  and vgctl's fence/context/ring header construction.
- Known truncated packets and invalid create parameters return PARAMETER;
  unknown operations return UNSPEC, missing resources/contexts map explicitly,
  and the context budget returns OOM. Headerless requests cannot fabricate
  fence metadata and are rejected without a reply.
- Complete reply capacity and bounded packet length are checked before any
  state mutation. Default host budgets:256 contexts,4096 packet bytes.
  Internal host exceptions propagate; they are not converted into fake success.
- Context destruction invalidates access without dropping global backing.
  Attach/detach is idempotent; explicit unref invalidates every attachment.
  Wire IDs resolve only to current generated host capabilities.
- `vn_control_queue.py` takes already-decoded buffers, not raw vring entries.
  It bounds descriptor count (default16), types/ranges and request bytes.
  Every request read and every actual reply write is authorized before
  dispatch. A late denied reply segment cannot retire a context/resource.
- Explicit GuestDma is required; its default remains deny-all. Request bytes
  are gathered before replies are scattered, preserving partial words and
  snapshot semantics. The caller serializes mappings and commands.

The queue emits separate request/reply byte counts. Its `used_bytes` helper
retains the existing G6LC vector contract (consumed+written); standard
virtqueue written-byte accounting must use reply_bytes instead. No used ring
or interrupt is published yet. These host budgets/checks do not establish
complete RTL negative-case or cycle equivalence.

## Scope And Open Gates

Backing registration remains trusted host setup. Guest commands cannot mint
DMA grants. CREATE_BLOB, MAP/UNMAP_BLOB, capsets, SUBMIT_3D and Venus streams
are NOT implemented here and never acknowledged as supported.

Raw vring walking/loop and indirect-descriptor checks, MMIO state, async
DMA/bus-fault handling, used-ring/IRQ publication, socket framing and T2
command execution remain open. Blob-owned versus VkDeviceMemory-owned aperture
allocation, relocation/pins and in-flight retirement must precede blob dispatch.
ControlQueue currently targets synchronous sparse-memory DMA, not a remote
bus where a preauthorized write can fail after dispatch.

## Evidence

40 tests pass in0.012s from frozen snapshot
`~/.cache/librecore/apu/native-control-queue.4TlMk4`.
Eleven Python inputs retain matching before/after hashes. Sixteen new cases
cover wire errors/metadata, truncation, reuse/teardown, capacities, budgets,
scatter/gather, denied late DMA and end-to-end unref invalidation. The prior
control-only snapshot independently passes32 cases.

Default-PGO layout presence preflight passes without installation, compilation,
training or simulation. Tests run from frozen source independently of live
development. Training is not validation, sampling does not narrow baseline
Vulkan compatibility, and no new remote RTL/CTS run is claimed.

## Integration Review

Host verification only: no functional RTL, ISA/CSR/DTS/config/discovery,
SRAM boundary, clock/reset, DFT, PMU or timing-cone changes. No silicon
timing/area/power or conformance claim; RISC-V spec-index statuses unchanged.
Legacy golden generators, fixtures and user Storamic code remain untouched.
Compiler/simulator PGO policies and cached compiler recipes are unchanged.
New code/tests are MIT tier; no upstream header or RTL link-set changes.
Scoped tier/header/attribution, ASCII, syntax and whitespace audit passes all
four new source files; tracked documentation diff checks also pass.
Full aggregate, compliance/formal, synthesis and physical qualification remain
separate gates.
