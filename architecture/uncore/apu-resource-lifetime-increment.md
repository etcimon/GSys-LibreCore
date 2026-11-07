# T2 Resource Lifetime Follow-Up

GSys LibreCore's native verification backend now composes global guest-DMA
backing with independently revocable context access. This is a host-state
component, not a new guest protocol or a complete bridge implementation.
Storamic work remains untouched; no network, cleanup or commit is performed.

## Implemented Contract

- `vn_resource_lifetime.py` uses ResourceDma owner0 for global backing.
- Generated, identity-checked context and attachment capabilities reject
  forged, stale, detached and reused-ID references.
- Several contexts can access one backing without duplicate overlapping grants.
- Destroying a context revokes its access only; the backing survives even the
  last detach. Explicit resource unref revokes backing and every attachment.
- Attachment rights cannot enlarge the underlying per-region DMA permissions;
  full-transfer prevalidation prevents partial cross-resource writes.
- Passing ApertureState.guest_ram shares its sparse store without copying.

Callers serialize operations and drain work before teardown. These attachment
tokens are host access capabilities, not implementation of wire
CTX_ATTACH_RESOURCE or a new requirement imposed on stock applications.
Distinct resources still register disjoint backing; several Vulkan objects
aliasing one allocation must share its backing ownership.

## Relevant Existing Code

- vn_dma_resources.py ResourceDma(memory): initially deny-all GuestDma;
  register(context,rid,iterable DmaRegion)->immutable DmaLease, exact object
  capability, monotonically increasing generation. Global physical regions
  disjoint; per-resource scope. revoke/revoke_context prevalidate; rollback
  including BaseException interruption. Eight tests pass.
- vn_memory.py ApertureState: owns blobs dict and guest_ram SparseMemory,
  aperture allocator; optional dma_policy preserves raw legacy default.
- vn_golden.py TransportModel at6161 inherits ApertureState and owns ctxs,
  rings, reply. kill_ctx at6272 only retires rings without publication.
  Blob creation/unref still performed by nested generator helpers and
  trusted direct dictionary mutation, not reusable control dispatch.
- IMPORTANT lifetime contract: CTX_DESTROY does NOT unref blob-owned pages.
  vgctl blob object entries are GLOBAL ctx0 (vn_golden submit at6719);
  ctx entries belong to ctx. create_blob helper at6839 stores lazy,
  unmapped blob; create_blob_mem at6854 aliases VkDeviceMemory backing.
  Blob UNREF frees owned pages, memory-backed blobs do not own their extent.
  Existing transcript comments near10087 explicitly preserve blobs past ctx
  destroy. Do not simply call ResourceDma.revoke_context for global resources.

## Validation And Review

24 DMA/ownership/lifetime tests pass in0.002s from frozen snapshot
`~/.cache/librecore/apu/resource-lifetime-final.0w7I06`; seven copied Python inputs
hash identically before/after. Eight are new lifetime cases: sharing and
context destroy, detach, global unref/RID reuse, context reuse/forgery,
permissions, atomic writes, failed registration and malformed/duplicate input.
Presence-only default-PGO layout preflight also passes without compilation or
simulation. Validation runs separately from live implementation.

Timing/config review: native host model only; no functional RTL, ISA/CSR/DTS,
discovery, configuration, SRAM, clock/reset, DFT, PMU or timing-cone changes.
No silicon area/power claim. Legacy golden fixtures and TransportModel are
unchanged and do not import this component. No RISC-V spec-index status changes.
New model/test sources are MIT tier; upstream notices/link sets unchanged.

Remaining: decoded control dispatch and error mapping, VkDeviceMemory-backed
aperture ownership/pins, asynchronous in-flight retirement, bridge socket
framing and full T2 execution. This increment does not claim those or any new
RTL/CTS/aggregate/formal/physical qualification.

## Prior Completed Evidence / Policy (Keep Intact)

Simulator PGO explicitly exported default1 and forced for remote RTL including
synth; compiler PGO independent. Generated native generate/train/use builder:
verif/tb/apu/apu_sim_pgo.py, training adapters, immutable image cache, receipts.
Actual compiler PGO home ~/.cache/librecore/apu-verilator-pgo-v1, 132 profiles,
loop counts[3,3], compiler binary e9989b8927ac48b46d9bce3c8a41d6a33ea8c61f9cea384ff01c0755e217c252.
Do not touch four compiler-PGO recipe files unless necessary (16min rebuild).
Newest real frozen infrastructure model smoke:
~/.cache/librecore/apu/sim-pgo-identity.K5WPbG,
4 profiles, independently passed profile-use program, reuse auto-install0
0.08s. Binary4776c710fafff79de3c781b289168a9c95b0917cf690320dcd1e73898fde3baa.
112 checks pass:33 harness,39 model,40 selected proxy/gate.
Scoped MIT header/tier/attribution audit21 files, bash/diff checks pass.
No remote APU RTL, CTS/full aggregate qualification claimed.

Test workflow: immutable snapshot source/tooling, detached worker, implementation
mutable and concurrent; training not validation, launch-only exit4 INCOMPLETE
until collection. No actual remote launch this follow-up without approval.
Local infrastructure smoke allowed, but functional APU RTL suites routed
wholly through remote gateway, never shared cleanup.

Key docs: apu-simulator-pgo-implementation.md; AGENTS-todo.md final APU sections;
AGENTS-specs-to-tests.md / -impl.md; docs03 apu_simulator_pgo.md;
agents/guides/AGENTS-verilator-performance.md final section.
External plan: C:/Users/etcim/.devin/plans/plan-238c1f8407ad4c21.md.
