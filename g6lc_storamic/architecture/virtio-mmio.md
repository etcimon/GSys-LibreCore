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
direct DDR/LPDDR/simulation-memory conflicts. `StoramicIoEn` (implemented in
ST-037C) enables the peripheral/storage role independently, so a flash-only
stick can coexist with another primary RAM backend. It is a derived field of
`cva6_cfg_t` (not `cva6_user_cfg_t`): `build_config_pkg` sets it from
`StoramicEn` or from the `G6LC_STORAMIC_IO` define, and `check_cfg` asserts
`StoramicEn ⇒ StoramicIoEn` plus the AXI geometry under either role. In
IO-only builds the harness still routes the native window and instantiates
the virtio transport, but the control bridge (`CtrlPageEn=0`) answers page 0
with DECERR and the backend's control request stays idle. Board wrappers
refuse either role. Each role requires CVA6Cfg propagation, legality checks,
host schema/default-off tests and SoC/DTS alignment.

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
The executable frontend failure recorded earlier (`storamic-96013e94fdae`) was a
bench timing artifact. Later profile runs, starting with
`storamic-7eea26e38385`, superseded it; see the task ledger.

## First standalone device profile (ST-033A, pinned)

This section pins the transport and register profile that ST-034 implements.
The role and native configuration fields (`StoramicIoEn`, aperture, IRQ, DTS)
are ST-033B and ST-037. Until then they remain proposals.

**Register window.** One 4-KiB window per device, little-endian. The offsets
are taken from the 1.4 CS01 MMIO transport section:

| Offset | Register | Access | Profile behaviour |
| --- | --- | --- | --- |
| 0x000 | MagicValue | R | `0x74726976` |
| 0x004 | Version | R | 2 |
| 0x008 | DeviceID | R | 2 (block) when the device is usable, otherwise 0 |
| 0x00C | VendorID | R | parameter `VendorId`; the value is an open ask (no copied ID) |
| 0x010 | DeviceFeatures | R | bank selected by DeviceFeaturesSel; bank 1 bit 0 = VIRTIO_F_VERSION_1 (32); every other bit 0 |
| 0x014 | DeviceFeaturesSel | W | banks > 1 read as 0 |
| 0x020 | DriverFeatures | W | banks 0 and 1 stored; writes to other banks are ignored |
| 0x024 | DriverFeaturesSel | W | |
| 0x030 | QueueSel | W | |
| 0x034 | QueueNumMax | R | 128 for queue 0, 0 for other queues |
| 0x038 | QueueNum | W | |
| 0x044 | QueueReady | RW | |
| 0x050 | QueueNotify | W | |
| 0x060 | InterruptStatus | R | bit 0 used buffer, bit 1 configuration change |
| 0x064 | InterruptACK | W | |
| 0x070 | Status | RW | |
| 0x080/0x084 | QueueDescLow/High | W | |
| 0x090/0x094 | QueueDriverLow/High | W | |
| 0x0A0/0x0A4 | QueueDeviceLow/High | W | |
| 0x0AC | SHMSel | W | no shared-memory regions: SHMLen reads all ones (as the spec requires for a missing region) and SHMBase reads 0 |
| 0x0B0–0x0BC | SHMLen/SHMBase | R | as above |
| 0x0C0 | QueueReset | RW | not offered (VIRTIO_F_RING_RESET off): reads 0, writes ignored |
| 0x0FC | ConfigGeneration | R | |
| 0x100+ | block configuration | R | `capacity` (le64, 512-byte sectors) at 0x100; other fields read 0 because their features are off |

**Offered features.** VIRTIO_F_VERSION_1 only. The following are not offered:
ACCESS_PLATFORM (no platform addressing contract), RING_PACKED, IN_ORDER,
ORDER_PLATFORM, NOTIFICATION_DATA, NOTIF_CONFIG_DATA, RING_RESET, ADMIN_VQ,
INDIRECT_DESC and EVENT_IDX. No block features are offered either: FLUSH needs
a real stable-storage boundary, and SIZE_MAX, SEG_MAX, GEOMETRY, RO, BLK_SIZE,
TOPOLOGY, CONFIG_WCE, MQ, DISCARD, WRITE_ZEROES, LIFETIME, SECURE_ERASE and
ZONED have no owners yet. Linux then treats the volatile model as write-through
without a cache flush. That is acceptable only because the labelled model is
not persistent.

**Access rules.**
- Registers 0x000–0x0FF accept aligned 32-bit accesses. Any other access, and
  any access to an offset not listed, returns SLVERR without side effects.
- Device configuration (0x100 up to the end of the block configuration
  structure) can be read at any byte address. The response is the aligned
  32-bit word, so the CPU can extract a byte or halfword. Configuration writes
  are ignored with OKAY, because no writable field is negotiated.

**Status and negotiation.**
- Status bits are ACKNOWLEDGE 1, DRIVER 2, DRIVER_OK 4, FEATURES_OK 8,
  DEVICE_NEEDS_RESET 64 and FAILED 128. Driver writes store bits 1, 2, 4, 8
  and 128. DEVICE_NEEDS_RESET is set only by the device.
- A write that sets FEATURES_OK takes effect only if both conditions hold:
  1. the negotiated features are a subset of the device features;
  2. VERSION_1 is included.
  Otherwise FEATURES_OK reads back clear and the device can never reach
  DRIVER_OK.
- DRIVER_OK is accepted only after FEATURES_OK.
- Writing Status = 0 starts a device reset:
  - Status keeps reading its previous value until `dma_idle_i` reports that the
    ring engine has quiesced.
  - The device then clears every transport register and queue state, and
    advances an internal **reset epoch** that ST-035 tags DMA with.
  - Status reads 0 once the reset is complete.
  - Reset does not undo committed media writes.

**Queue setup.** The queue registers of the selected queue can be written only
while QueueReady = 0. Writes while ready, or to a queue other than 0, are
ignored with OKAY.
- Writing QueueReady = 1 succeeds only if all of these hold:
  1. Status has FEATURES_OK and not DRIVER_OK;
  2. QueueNum is a power of two from 1 to QueueNumMax;
  3. the descriptor table is 16-byte aligned, the driver (available) area is
     2-byte aligned and the device (used) area is 4-byte aligned;
  4. none of the three areas wraps past 2^64 for that QueueNum.

  Otherwise QueueReady stays 0.
- A QueueNotify for queue 0 is forwarded to the ring engine as one pulse only
  when DRIVER_OK is set, QueueReady = 1 and DEVICE_NEEDS_RESET is clear.
  Any other QueueNotify is ignored: no work is fetched early.

**Interrupts and configuration.**
- The device interrupt is the level OR of the InterruptStatus bits.
- InterruptACK clears the bits that are written. An event in the same cycle
  wins.
- A capacity change from the media side updates the configuration snapshot,
  increments ConfigGeneration and sets InterruptStatus bit 1.
- A device fault from the ring engine sets DEVICE_NEEDS_RESET and bit 1.

**Limits.** One device per window, one queue, at most one request in flight
(ST-035), and queue maximum 128. Everything else stays unadvertised until it
has its own tests. Passing ST-034 register tests is not VirtIO conformance or
OASIS certification.

### ST-034 implementation notes

Decisions the pinned profile left open, settled in
`g6lc_storamic_virtio_mmio.sv`:

- The device configuration window is the 96-byte `virtio_blk_config`
  (0x100–0x15F), byte-readable; 0x160–0xFFF is SLVERR.
- Reads of write-only registers return SLVERR (as do writes to read-only
  registers); QueueReset reads 0 and ignores writes.
- DriverFeatures banks 0 and 1 are stored; writes are frozen once FEATURES_OK
  is set, and banks above 1 are ignored.
- While a Status=0 reset is pending, every register write except another 0
  is ignored with OKAY; Status keeps reading its previous value until
  `dma_idle_i` completes the reset.

## Split-ring engine contract (ST-035, pinned)

`g6lc_storamic/rtl/host/virtio/g6lc_storamic_virtio_ring.sv` serves queue 0
of one ST-034 transport. It walks split-virtqueue chains and hands each
validated request to a backend. It owns no media semantics; virtio-blk
decoding is ST-036.

**Inputs from ST-034:** `queue_ready`, `queue_num`, `queue_desc`,
`queue_driver`, `queue_device`, `driver_ok`, `notify` (pulse),
`reset_pending`, `reset_epoch`. **Outputs to ST-034:** `dma_idle`,
`used_event` (pulse) and `ring_fault` (pulse).

**DMA seam.** The engine has its own single-beat 64-bit request port:
- `dma_req_o`, `dma_we_o`, `dma_addr_o` (64-bit, 8-byte aligned),
  `dma_wdata_o`, `dma_be_o`, handshaking with `dma_gnt_i`;
- responses on `dma_rvalid_i`, `dma_rdata_i` and `dma_err_i`;
- at most one request outstanding.

Adapting this port to an AXI master, and sharing it with the backend, belongs
to the device wrapper (ST-036/ST-037). Little-endian sub-word fields are
extracted from the aligned beat. 16-bit ring fields are written with byte
enables, never with a read-modify-write of driver-owned bytes.

**DMA window.** The integration supplies `dma_base_i`/`dma_size_i`.
- Every engine access must lie entirely inside the window. The check uses
  65-bit arithmetic and covers the descriptor table, available ring, used ring
  and each segment handed to the backend.
- A violation raises `ring_fault` (the transport sets DEVICE_NEEDS_RESET) and
  the engine issues no further DMA until reset.

**Processing, one request in flight:**
1. **Wake-up.** Idle until `notify` or a remembered pending notify. Work
   starts only while `driver_ok && queue_ready && !reset_pending`.
2. **Find work.** Read `avail.idx` at `driver+2`. If it equals the internal
   `last_avail`, go idle. Otherwise read the head index at
   `driver + 4 + 2*(last_avail mod N)`.
3. **Walk the chain.** For each descriptor, read 16 bytes at `desc + 16*i`
   (two beats) and check:
   - `i < N`, and at most N descriptors are visited (cycle bound);
   - INDIRECT (4) is not set, since it is not negotiated;
   - every device-readable descriptor precedes every device-writable one;
   - `len != 0`;
   - the buffer lies inside the window.

   A chain may have at most `MaxSegs` descriptors (parameter, default 8).
   Without SEG_MAX, Linux virtio-blk uses at most 3 per request.
4. **Fault on any violation.** A violation, or a chain longer than `MaxSegs`,
   raises `ring_fault` with no used entry. The profile has no safe place to
   report a malformed chain, so it never fabricates a completion.
5. **Hand off.** Pass the segment table (`addr`, `len` and `write` for each
   segment, plus `head`) to the backend with `req_valid`/`req_ready`. The
   backend answers `rsp_valid` with `written_len`, the bytes it wrote into
   device-writable buffers. The engine issues no DMA while the backend owns
   the request.
6. **Publish completion, in this order:**
   1. Write the used element `{id = head (le32), len = written_len (le32)}` at
      `device + 4 + 8*(used_idx mod N)` and wait for its response.
   2. Then write `used.idx = used_idx + 1` (le16) at `device + 2` and wait for
      its response.
   3. Then pulse `used_event`.

   Then increment `last_avail` and `used_idx` modulo 2^16 and go back to step 2.
   Re-reading `avail.idx` there catches requests posted without another
   notify.
7. **Interrupt policy.** Without EVENT_IDX the engine always raises
   `used_event`. Ignoring `VIRTQ_AVAIL_F_NO_INTERRUPT` is permitted (it is a
   SHOULD), and Linux tolerates the extra interrupt. `used.flags` is never
   written, so it stays 0 and the driver keeps notifying.
8. **Reset.** On `reset_pending` the engine issues no new DMA, completes and
   discards the outstanding response, abandons any backend request, and then
   asserts `dma_idle`. Indices return to zero when the transport completes the
   reset and advances `reset_epoch`. A response arriving under an old epoch is
   dropped.

**Formal obligations:**
- no DMA outside the window;
- no new DMA without `driver_ok && queue_ready && !reset_pending`;
- at most one outstanding request;
- the `used.idx` write is issued only after the used-element response;
- `used_event` occurs only after the `used.idx` response;
- the walk count never exceeds N;
- `dma_idle` implies nothing is outstanding.

Covers:
- one request completed with `used_event`;
- a fault on a cyclic chain;
- a reset during a walk.

**Limits.** One queue, one request in flight, no INDIRECT, EVENT_IDX, packed
ring or IN_ORDER, and no notification suppression. Linux compatibility is
asserted only by the ST-038 RTL-in-the-loop gate.

## virtio-blk backend contract (ST-036, pinned)

`g6lc_storamic/rtl/host/virtio/g6lc_storamic_virtio_blk.sv` executes one
request handed over by the ST-035 engine (segment table plus `head`) and
answers with `written_len`, or with `fault` when no safe status location
exists.

**Ports:**
- its own single-beat DMA port, with the same shape as ST-035's and checked
  against the same window;
- a block-store seam, the same shape as the frontend `mem_*` seam: 64-bit
  words at byte offset `sector*512 + 8*k`, with request/grant/we/be and
  rvalid/rdata/error;
- `capacity_i` in 512-byte sectors;
- `serial_i[159:0]`, the 20-byte ID string, supplied by the integration from
  the stick's validated identity and never fabricated;
- `store_ready_i`.

**Request layout:**
- Segment 0 must be device-readable and at least 16 bytes long. It holds the
  header: `type` (le32), `reserved` and `sector` (le64), at any byte
  alignment.
- The last segment must be device-writable and at least 1 byte long. Its
  first byte is the status.
- If either rule fails, the backend raises `fault`: there is no safe status
  location, so the engine faults the device and fabricates nothing.
- The segments in between carry the data.

**Commands:**

| `type` | Name | Data segments | Action | `written_len` |
| --- | --- | --- | --- | --- |
| 0 | IN | device-writable | read the store into the buffers | data bytes + 1 |
| 1 | OUT | device-readable | write the buffers into the store | 1 |
| 8 | GET_ID | one writable segment of at least 20 bytes | write `serial_i` | 20 + 1 |
| other (including FLUSH = 4, which is not offered) | — | — | status UNSUPP (2) | 1 |

**IOERR (status 1), with no store side effect,** when any of these holds:
- a data direction mismatch;
- total data length not a multiple of 512;
- a data segment address not 8-byte aligned (a profile limit; the Linux block
  layer aligns data buffers to at least 512 bytes);
- `sector + len/512 > capacity_i` (65-bit arithmetic);
- `store_ready_i` is low;
- a data segment is empty, or does not lie entirely inside the DMA window
  (the ring engine already refuses these; the backend checks again);
- the store reports an error.

**DMA coherence (native binding).** A device write completes only after the
64-byte block holding it has been invalidated in every L1 (and L2/L3 tags)
through the cluster CMO engine, so the driver may read device-written memory
with ordinary loads once it observes the completion. Device reads are not
snooped: the driver's stores must already be in memory, which the
write-through L1 provides; a write-back L1 configuration would also need a
clean before each device read.

The DMA window end is clipped at 2^64 and beat addresses are formed in 65
bits, so no accepted beat wraps to a low address. A GET_ID buffer must hold
its three 8-byte beats inside the window, or the status is IOERR.

All checks complete before the first store write, so a refused OUT never
modifies the store. A store error during a transfer still yields IOERR. The
bytes already written are not rolled back; this is recorded for durability.

**Ordering.** Data DMA and store writes complete before the status byte is
written. The status byte is written with a single byte enable, and its write
response arrives before `rsp_valid`.

**Persistence.** The first binding is a volatile, labelled model store.
- An OUT completion means the data is in the volatile store, not on durable
  media.
- FLUSH stays unoffered until a qualified persistent store exists (ST-019/20).

**Formal obligations:**
- no store write for a refused request;
- the status write happens after every data write;
- `rsp_valid` comes after the status write response;
- no DMA outside the window.

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
