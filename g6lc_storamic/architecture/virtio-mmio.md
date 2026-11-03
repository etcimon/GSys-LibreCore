# Storamic VirtIO-MMIO architecture decision

Status: selected architecture, not an implemented device or conformance grant.
This decision supersedes the Storamic CXL 2.0/Type-3 target and the undecided
NVMe-versus-virtio block transport. The primary standard is **OASIS VIRTIO 1.4
Committee Specification 01, 8 April 2026** [1]. Implement a tested modern MMIO
device profile; do not equate the revision number with support for every optional
feature.

## What is being replaced

Remove the planned Storamic CXL.io/CXL.mem stack, HDM decoders, CXL mailbox,
CEDT discovery and Type-3 qualification from active dependencies. PCIe is not
required for the selected native MMIO profile. Other LibreCore PCIe consumers
are independent projects.

VirtIO specifies a software/device interface over registers, DMA queues and
interrupts. It supplies neither a cache-coherent wire protocol nor a RAM/flash
PHY. Native RAM therefore continues through the existing CPU/coherence/AXI
memory path. Queues carry block IO and optional memory-management requests,
not each ordinary CPU load/store.

An external PCIe host cannot acquire coherent system RAM merely by mapping a
VirtIO-MMIO register aperture into a BAR. An external-host product needs an
explicit physical transport, discovery, DMA addressing and ownership contract;
virtio-pci is a different transport and is not implicitly enabled here. No
external-host coherent-memory feature survives the retired target by renaming it.

```text
CPU caches / qualified coherence + AI/APU checked DMA
                    | native RAM AXI
                    v
             validated region router ------> RAM media channels

CPU MMIO --> per-device VirtIO-MMIO transport
                    | status, features, queue configuration, IRQ
                    v
          split-ring engine + bounded, protected AXI DMA
                    |
             virtio-blk request engine ------> block/media scheduler
                                               | flash channels / FTL
                                               | protected journal, if qualified

optional virtio-mem --> region lifecycle manager (data still uses RAM AXI)
optional virtio-pmem --> protected mapped range + persistence/flush engine
```

## Media and Linux interfaces

| Population / role | Data path and software interface | Required boundary |
| --- | --- | --- |
| RAM-only | Native addressable volatile RAM; optional virtio-mem lifecycle | Actual backing, PMA/cache/coherence, validated regions |
| Flash-only | One virtio-blk device per flash-bearing stick | Managed logical blocks; erase, bad-block/ECC/FTL policy below transport |
| Mixed | Separate RAM ranges and block device | No aliasing or double-counting of RAM, user flash and recovery space |
| Qualified protected memory | Optional virtio-pmem mapped range and asynchronous flush | Proven persistence domain and recovery, not bare NAND load/store |

Linux `virtio_mmio` plus `virtio_blk` is the first software target. Standard
md/LVM or supported multi-device filesystems may aggregate drives. Linux swap or
tiering on a block device is an explicit software policy; flash does not thereby
become low-latency RAM. Volatile RAM caches must not turn an acknowledged durable
write into a volatile-only copy.

Virtio-blk capacity and request sector offsets use **512-byte units**, even when
an optional logical/optimal block-size field reports another size. Validate
sector/count multiplication and addition before issuing IO. Implement IN, OUT,
GET_ID and the selected FLUSH contract; return the specified IOERR/UNSUPP status
where applicable. Preserve stable per-stick identity across allowed relocation.

Physical writable-block promotion requires a defined stable-storage boundary.
Offer FLUSH only with real semantics, including all previously completed writes
on all queues of that device. A volatile test backend is labeled as such and
cannot furnish power-loss evidence. Do not invent a virtio-blk FUA request bit:
the selected standard's block operations use FLUSH and cache-mode rules. OS FUA
requests must use the stock driver's supported translation and be tested at the
backend boundary. Multi-queue ordering is not a global FIFO by implication.

## Modern MMIO and queue mechanics

The modern transport's `Version` register is **2**, not 4 or 0x14. Its magic is
0x74726976. Each transport represents one device ID: block 2, memory 24, PMEM 27.
Mixed media can require multiple transport apertures; it is not one invented
composite VirtIO device. A vendor identifier must be justified, never copied from
QEMU or another vendor.

The device implements the standard feature selector banks, status handshake,
queue selection/geometry/address registers, notification, interrupt status/ACK
and configuration-generation mechanism. Control registers use aligned 32-bit
accesses; device-specific configuration accesses follow the specification's
separate rules. Device/queue configuration is little-endian.

Initialization is reset, ACKNOWLEDGE, DRIVER, feature negotiation, FEATURES_OK
validation, queue setup, then DRIVER_OK. Unknown or inconsistent feature choices
must not start DMA. Do not fetch work merely because QueueNotify was written
before DRIVER_OK and a valid ready queue. Device reset must quiesce outstanding
DMA and prevent old completions from reaching reused queue state before exposing
completed reset. Reset does not undo a committed media write.

First queue profile: split virtqueues, one queue per block device, one request
in flight per queue, proposed queue maximum 128. Descriptor tables and buffers
reside in shared addressable RAM. A descriptor is an address/length/flags/next
record; the driver publishes available heads and the device publishes used
entries. Validate every chain's indices, length, direction and complete address
range. Bound traversal to detect cycles and exhaustion. Reserve completion/status
storage before side effects. Never truncate a 64-bit address into local SRAM.

Publish payload and status before the used entry/index and notification, with
the ordering the platform and negotiated features require. Handle index wrap,
notification suppression and interrupt ACK races without lost work. A malformed
chain whose status location cannot be safely written requires a defined device
failure/reset path, not an unsafe DMA or fabricated completion.

Packed rings, indirect descriptors, EVENT_IDX, IN_ORDER, notification data,
queue reset, multiqueue, discard/write-zeroes, zoned commands and administration
features stay unadvertised until their own implementation and negative tests
exist. Unnegotiated features cannot affect the selected behavior. Full device
reset is still mandatory when per-queue reset is not offered.

MMIO uses a device interrupt covering used-buffer and configuration events.
Multiple queues do not imply independent MSI-X vectors. Device-specific
configuration snapshots use ConfigGeneration and configuration notifications;
register names alone are not an atomic snapshot implementation.

## DMA, ownership and native attachment

`g6lc_storamic/rtl/host/virtio/` owns the first-party register, ring and block
engines. Transport, DMA, region routing, block semantics and media timing remain
separate modules. Arrays cross the explicit SRAM/macro boundary. Pads, clocks,
analog PHYs and flash/RAM chips remain independently qualified bindings.

`corev_apu/storamic/` owns address decode, AXI type/width adaptation, DMA-master
attachment, interrupts, configuration projection and reset-domain integration.
Preserve full IDs, addresses, data, strobes and relevant attributes.

The SoC must establish either a coherent DMA path or a working Linux DMA API
mapping/cache-maintenance path. `VIRTIO_F_ACCESS_PLATFORM` is not a hardware
coherence switch; negotiate it only with the corresponding platform addressing
contract. Do not set DTS `dma-coherent` on an unproven path. CPU PMP alone does
not validate a device DMA master. Check the entire DMA extent against its
permitted RAM/IOVA domain, including ring/status writes and integer overflow;
exclude controller MMIO and unrelated masters' memory.

Keep the existing default-off `StoramicEn` primary-memory selection and its
direct DDR/LPDDR/simulation-memory conflicts. A **proposed, not yet implemented**
`StoramicIoEn` enables the peripheral/storage role independently, so a flash-only
stick can coexist with another primary RAM backend. Normalize both roles to one
controller/slot-owner instance; enabling both must not instantiate duplicate
controllers or drive the pads twice. Each new field requires CVA6Cfg propagation,
legality checks, host schema/default-off tests and SoC/DTS alignment.

MMIO has no generic device discovery. Publish `compatible = "virtio,mmio"` with
the actual aperture and interrupt only when that device is usable. Reserve
structural slots in the design, but do not assume changing DeviceID from zero
will make Linux discover a newly inserted stick. Initial enumeration is at boot;
runtime device insertion needs a separately tested platform lifecycle.

## Capacity, channels and performance

Keep these independent:

| Class | Proposed controls | Meaning |
| --- | --- | --- |
| Fabrication / elaboration | MaxSticks, MaxMediaChannels, channel-to-slot allocation, bus widths | Pins, controller instances and routing resources |
| Bounded frontend resources | MaxQueuesPerDrive, QueueSizeMax, MaxInFlightPerQueue, MaxRequestBytes, DMA credits | Queue SRAM, fairness and completion capacity |
| Validated runtime state | Presence, identity, usable RAM regions, usable block sectors, health, generation | Installed usable resources within structural maxima |
| Operating policy | Requested RAM size, IO scheduling/weights, optional cache policy | Changes permitted only by lifecycle and negotiated semantics |

The current stick limit remains 1..8; initial model/queue implementations stay
single-region/single-channel until their scaling tests pass. Proposed controls
are not existing accepted configuration fields. Queue maxima must be legal for
the selected ring format and backed by actual storage; no unsupported geometry
is accepted merely because the standard permits it.

A queue is not a physical channel. The media scheduler arbitrates queues across
eligible channels while reserving progress for completion and maintenance.
Report bytes, latency distributions, occupancy/stall reasons, errors and fairness
per queue/channel. The useful bandwidth is bounded by the minimum of native/DMA
fabric, frontend service and aggregate eligible media bandwidth. Increasing
queue depth can cover latency; it cannot exceed that bottleneck. Measure changes
against the same workload, actual path and evidence identity.

Start with validated non-interleaved RAM regions. Runtime capacity growth never
changes live physical-address mappings or fabricated balls. Block growth uses
validated capacity, ConfigGeneration and a configuration event; filesystem growth
is separate software work. Initial policy forbids online block shrink. Removal
requires IO quiescence and OS-managed offlining; disappearance is a fault, not a
license to silently remap data.

## Optional memory lifecycle and persistence

Virtio-mem manages a fixed maximum address window with block_size, addr,
region_size, usable_region_size, plugged_size and requested_size. PLUG, UNPLUG,
UNPLUG_ALL and STATE use a control queue. A successful plug requires actual RAM
with the platform's ordinary RAM semantics; it cannot acknowledge nonexistent
capacity or expose arbitrary flash as RAM.

Do not also advertise that managed window as boot RAM in firmware/DTS. Keep boot
RAM separate. A smaller requested_size is a request: Linux may not be able to
offline pinned/in-use pages. Respect block/page/hotplug granularity and do not
remove backing until acknowledged offlining and required CPU/DMA/cache drainage.
Device reset and system reset are distinct; a VirtIO control reset must not
unplug or destroy still-live RAM. Unplugged-access behavior is feature-dependent.

Virtio-pmem exposes a genuinely byte-addressable mapped range and a separate
asynchronous flush queue. Completion must mean preceding writes reached the
declared persistence domain across reset and power failure. Host-page-cache
examples do not supply a bare-metal implementation. LIBNVDIMM, filesystem DAX
and Device DAX compatibility require separate kernel/platform tests; DAX alone
does not establish durability, transactional atomicity or CPU-cache coherence.

## Software and QEMU gates

The repository's current QEMU pin is v10.0.0. Its `hw/virtio/Kconfig` enables
memory-device support through PCI/CCW, **not MMIO** [6]. Consequently a stock
virtio-blk MMIO reference does not establish stock virtio-mem/pmem MMIO support.
Any required generated MMIO memory-device proxy, machine mapping or launch
configuration belongs exclusively to `g6lc_qemu/`; do not silently substitute a
PCI transport or a generic RAM aperture.

Linux v6.18's Kconfig includes RISC-V in VIRTIO_MEM's supported architectures and
requires MEMORY_HOTPLUG, MEMORY_HOTREMOVE, CONTIG_ALLOC and EXCLUSIVE_SYSTEM_RAM
[7]. This is a researched reference, not a changed repository kernel pin or a
boot result. Check the actual kernel, SBI, DMA/cache and platform configuration.
Older distribution kernels must not inherit that support claim.

Keep stock software reference, native model and RTL-in-the-loop artifacts
distinct. For RTL-backed tests, relevant MMIO, queue DMA, data/status writes,
interrupts and reset must cross the declared bridge. A deliberate RTL defect
must alter the guest outcome. The package remains independent, with text-only
GPL emission and no GPL headers/libraries linked into first-party RTL/tooling.

## IPR and source provenance

The VIRTIO TC uses OASIS **Non-Assertion Mode**, not an assertion that no patents
exist [2,3]. The public disclosure list includes patents potentially relevant
to queues and shared memory [4]. This choice removes the planned CXL-specific
protocol dependency; it is not a freedom-to-operate opinion for all chips,
PHYs, flash algorithms or third-party claims. Apply the policy's scope and
conditions to the implemented conforming portions and retain the release IPR
review. Copyright and patent permissions are separate.

Author the digital engines first-party against the pinned specification.
Do not import Linux/QEMU driver source into the RTL closure. Preserve the
repository's CERN-OHL-S/commercial RTL and MIT tooling boundaries and upstream
notices. Do not claim OASIS certification or standards conformance from a register
stub, simulator model or passing subset alone.

## Implementation order and evidence

1. Finish ST-005..ST-007's media-neutral executable memory seam and byte oracle.
2. ST-033 pins the negotiated VirtIO profile and config/lifecycle contracts.
3. ST-034 implements modern MMIO state/queue configuration; ST-035 adds the
   bounded split-ring engine, DMA protection and reset/ordering checks.
4. ST-036 binds a labeled block model, then qualified media; ST-037 supplies
   native DMA/IRQ/DTS and primary/peripheral role integration.
5. ST-038 checks stock Linux with the package-owned RTL bridge.
6. ST-039 adds virtio-mem only after mapping/offlining gates; ST-040 adds
   virtio-pmem only after persistence and software support gates.
7. ST-041 scales queues/channels from measured results. ST-032 reassesses each
   checkpoint; the retired ST-029/ST-030 transport epics are not prerequisites.

No new MMIO address, IRQ, capacity, feature bit or boot support is granted by
this decision. The current M0 safe pads and error responses remain unchanged.
The unselected executable frontend is under test: `storamic-96013e94fdae`
failed a write-response oracle check; it is not a passing model milestone.

## Sources

1. [VIRTIO 1.4 CS01](https://docs.oasis-open.org/virtio/virtio/v1.4/cs01/virtio-v1.4-cs01.html):
   basic facilities, initialization, MMIO transport, block, memory and PMEM devices.
   [Authoritative source](https://docs.oasis-open.org/virtio/virtio/v1.4/cs01/tex/).
2. [VIRTIO TC IPR](https://www.oasis-open.org/committees/virtio/ipr.php).
3. [OASIS IPR policy](https://www.oasis-open.org/policies-guidelines/ipr/).
4. [TC disclosures](https://github.com/oasis-tcs/virtio-admin/blob/master/IPR.md).
5. [Linux memory hotplug](https://www.kernel.org/doc/html/latest/admin-guide/mm/memory-hotplug.html);
   [QEMU virtio-pmem](https://www.qemu.org/docs/master/system/devices/virtio/virtio-pmem.html).
6. [QEMU v10.0.0 transport configuration](https://github.com/qemu/qemu/blob/v10.0.0/hw/virtio/Kconfig).
7. [Linux v6.18 VirtIO configuration](https://github.com/torvalds/linux/blob/v6.18/drivers/virtio/Kconfig).
