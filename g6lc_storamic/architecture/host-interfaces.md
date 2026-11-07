# Host interfaces: native RAM and VirtIO-MMIO

Status: selected architecture with model RTL and selected-leaf evidence.
Native Linux, physical media and protected persistence still require their own
qualification gates; see [current development status](development-status.md).
The normative decision and sources are in [VirtIO-MMIO architecture](virtio-mmio.md).
That decision supersedes the former CXL 2.0 target and closes the transport choice
in favor of modern VirtIO-MMIO, pinned to VIRTIO 1.4 CS01 (8 April 2026).

Native RAM retains ordinary AXI/load-store access and the SoC coherence/ownership
contract. Flash uses one virtio-blk device per flash-bearing stick. Optional
virtio-mem manages reserved RAM windows; optional virtio-pmem requires separately
qualified byte-addressable backing and asynchronous flush durability. Queues do
not replace RAM loads/stores or a physical media interface.

Use stock Linux virtio_mmio/virtio_blk drivers for the first device profile.
Capacity is reported in 512-byte sectors; geometry, queues and physical channels
are independent controls. Filesystem aggregation remains md/LVM or supported
multi-device filesystems. No hardware filesystem or automatic RAID is supplied.

MMIO needs actual platform discovery, addresses, IRQs and coherent or DMA-API
cache-maintenance semantics. Neither a PCIe BAR nor a VirtIO feature flag grants
cache coherence. External-host transport is a separate, unselected contract.

All QEMU ingestion, models, generation, reference profiles, firmware/discovery
emission, launch and remote execution belong exclusively to g6lc_qemu/. The
pinned QEMU v10.0.0 does not supply the required MMIO memory-device support merely
by enabling virtio-mem/pmem. Preserve reference versus RTL-backed distinctions.

The OASIS Non-Assertion policy and its disclosed claims are described in the
linked decision. This is a protocol-dependency choice, not a blanket patent or
freedom-to-operate guarantee. First-party RTL and the GPL-out boundary remain.
