# APU Immutable Sampler State

GSys LibreCore's Venus frontend retains sampler arrays supplied by descriptor
set layouts and snapshots implemented sampler state into the layout's ObjPay
extent. Descriptor allocation initializes standalone samplers without writes;
combined-image updates and copies retain destination-owned sampler bytes.
This is baseline Vulkan behavior, not a new optional Vulkan 1.4 capability.

The change inherits the existing Venus enable, reset and SRAM boundaries.
It adds serial control, not a new memory port, clock, ISA/CSR or DTS interface.
Array capture changes only immutable-sampler staging, not unrelated handle
arrays or the external Venus wire encoding.

Implementation format, selected RTL evidence, timing/DFT and licensing notes:
`architecture/uncore/apu-immutable-implementation.md`. Full CTS, complete layout
compatibility identity, lifetime/fault-injection and physical qualification
remain separate gates.

Empty layouts now initialize their existing sizing/hash metadata independently
of the preceding layout. The exact-capacity pool regression is generated and
lint-checked, not yet executed on RTL. Short testharness cohorts, offline
tools-source provisioning and their evidence limits are described in
`architecture/uncore/apu-dev-harness-implementation.md`.

The subsequent host-tool/model increment requires compiler-PGO receipts and
bounded unroll for APU testharness RTL leaves. It also adds optional guest-DMA
authorization to the native model boundary; legacy generator operation remains
byte-identical on nine selected artifacts. Neither compiler PGO nor model tests
qualify new hardware behavior. Details:
`architecture/uncore/apu-pgo-dma-increment.md`.
