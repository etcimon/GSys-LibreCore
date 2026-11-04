# Storamic: shared memory and modular storage

GSys LibreCore's Storamic architecture separates native SoC attachment, a reusable
first-party digital stack, physical media and Linux-visible services. Status:
M0 refusal foundation implemented with selected leaf evidence; aggregate,
physical memory and storage qualification remain open. The former CXL/Type-3
host target is retired; the settled transport is modern VirtIO-MMIO plus native
AXI RAM — see the [VirtIO-MMIO decision](../../g6lc_storamic/architecture/virtio-mmio.md).
The [general-purpose review](../../g6lc_storamic/architecture/general-purpose-review.md)
records a ten-caveat source audit; its items are proposals mapped to task owners,
not accepted capabilities.

## Ownership

| Location | Owns |
| --- | --- |
| `corev_apu/storamic/` | Native AXI/type adaptation, DMA attachment, configuration projection, interrupts |
| `g6lc_storamic/rtl/` | First-party protocol engines, VirtIO-MMIO/ring/DMA (planned), discovery, scheduling and media contracts |
| [Package architecture](../../g6lc_storamic/architecture/README.md) | Normative subsystem contracts |
| `g6lc_qemu/` | **All** QEMU generation, models, bridge emission, launch and remote QEMU execution |
| `verif/tb/storamic/` | RTL benches and simulator-side bridge peer, not QEMU launchers |
| `corev-mb/` | Eventually qualified board, connector, rails, routing and package bindings |

The standalone Storamic closure must contain no third-party RTL, including AXI
engines, FIFOs, arbitration or CDC. The inherited LibreCore CPU/fabric lies outside
that boundary. Technology-bound pads, SRAM, clocking and SerDes remain explicit;
calling a digital link controller a PHY does not exempt it from this rule.

## System topology

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

                     slot controllers
                     /              \
            passive chips      active serial stick
            RAM / flash        local RAM / flash
```

Native RAM keeps the existing CPU/coherence/AXI path; queues carry block IO and
optional memory-management requests, not ordinary CPU loads/stores. An external
host needs an explicit, separately selected physical transport contract; an MMIO
aperture alone grants no coherent system-RAM access. Neither an endpoint nor an
AXI bridge automatically provides coherence.

`StoramicEn` selects the primary-memory implementation at the existing DRAM
aperture, mutually exclusive with direct DDR4/LPDDR/simulation memory there.
Default-off retains the existing backend. Media behind Storamic may itself use
DDR technology without becoming another directly attached primary backend. A
**proposed, not implemented** `StoramicIoEn` would add the independent
peripheral/storage role so a flash-only stick can coexist with another primary
RAM backend; one controller/slot-owner instance serves both roles — enabling
both must not duplicate controllers or drive pads twice. Each new field needs
CVA6Cfg propagation, legality checks, schema/default-off tests and SoC/DTS
alignment.

## Capacity and software

RAM-only sticks contribute volatile memory. Flash-only sticks contribute block
capacity; they cannot boot a native CPU without independent boot RAM. Mixed
sticks may contribute both, but PMEM recovery space is not also writable block
capacity. No population automatically qualifies as PMEM.

Expose one virtio-blk device per flash-bearing stick, capacity in 512-byte
sectors, using stock Linux `virtio_mmio`/`virtio_blk` drivers. Software combines
drives through md/LVM and a filesystem or a supported multi-device filesystem.
No hardware filesystem or RAID is implied. Optional virtio-mem manages reserved
RAM windows; optional virtio-pmem requires separately qualified persistence.
See the [transport decision](../../g6lc_storamic/architecture/host-interfaces.md).

Map heterogeneous RAM through validated regions before adding interleaving of
equal-sized compatible extents. Never compact live memory on removal. Queue
count, ring depth and physical media channels are independent controls; a queue
is not a physical channel, and queue depth is not a bandwidth claim.

## AI scalability and measurement

Native masters share one map; do not create accelerator-private aliases.
Provide narrow demand and optional wide DMA ingress with bounded service, credits
reserved for responses, and maintenance progress. Channel count is independent of
core/cluster count. A width converter does not increase upstream bandwidth.

Useful bandwidth is bounded by the minimum of fabric, MMIO/DMA path, aggregate
stick links, media and persistence admission rates. Credits depend on bandwidth
times round-trip latency. Publish per-slot occupancy, errors, byte counts and
latency, distinguishing nameplate, model and measured results. No Storamic
profile inherits the AI class-2 400 GB/s target.

The executable work queue is [ST-001..ST-041](../../g6lc_storamic/architecture/implementation-tasks.md).
Start with isolated validation and native readiness, then an explicit one-region
model; VirtIO transport tasks ST-033..ST-041 follow, with ST-032 reassessing each
checkpoint. Retired ST-029/ST-030 transport epics are not prerequisites. Later
capability gates follow their actual dependencies rather than a strict waterfall.

## Promotion gates

| Gate | Obligation | Current claim |
| --- | --- | --- |
| M0 | Default-off skeleton, config/protocol/dependency checks | 37/37 configurations and joined readiness verified; aggregate/native qualification open |
| M1 | SRAM-backed executable model, burst routing and ownership | One-region standalone profile verified; heterogeneous routing/native ownership open |
| M2 | Passive RAM/flash interfaces, real identification and timing | Planned |
| M3 | Selected stock-Linux block interface (virtio-blk) and media durability | Planned |
| M4 | Protected PMEM (virtio-pmem), cache-to-domain ordering and interrupted recovery | Planned |
| M5 | Active serial sticks and measured QoS/scaling | Planned |
| M6 | Modern VirtIO-MMIO transport, split-ring/DMA/IRQ stack, Linux and platform gates | Planned |

The skeleton must not advertise usable RAM, block storage, PMEM or a VirtIO
device. Unsupported requests fail explicitly; no automatic SRAM fallback. The
APU analogy is its implementation-versus-advertisement discipline, not a claim
that either subsystem already implements its entire target standard.
