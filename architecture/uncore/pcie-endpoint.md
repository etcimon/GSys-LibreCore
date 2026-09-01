# Uncore outline — PCIe endpoint (compute card)

**Domain:** interconnect · **Catalog ids:** `verilog-pcie`, `litepcie` · **Status:** planned RTL;
**virtual stand-in live** (EDK2 GPEX = host RC, `virt_ai_card` = endpoint; transport **unpinned**)
**Scaffold only** (see `architecture/uncore/README.md`). Snapshot: `architecture/current-stage.md`.

## 1. Intent
Make LibreCore the **endpoint** of a PCIe link rather than the root — i.e. a plug-in **CPU+AI card**
enumerated by a host, running its own Linux, reachable over IPv6, and accepting pushed workloads.
This is the transport half of `architecture/ai-matrix/README.md`.

**This is the opposite direction from `pcie-root-complex.md`,** which makes LibreCore the *host* that
enumerates NVMe/GPU/NIC endpoints. The two outlines share DMA/TLP RTL and the AXI bridge; they differ
entirely in config-space ownership, BAR handling and enumeration role. Do not merge them.

## 2. Chosen controllers
- **verilog-pcie** — `https://github.com/alexforencich/verilog-pcie` — **MIT**. DMA + TLP glue over
  vendor PCIe hard IP; includes endpoint-side paths. *Recommended primary.*
- **litepcie** — `https://github.com/enjoy-digital/litepcie` — **BSD-2-Clause**. Endpoint/DMA; Migen.
- Fetch: `vendor sync verilog-pcie` · Inspect: `vendor scan verilog-pcie` (root: `rtl`).

## 3. Controller vs PHY split (decisive)
- **On-die:** BAR decode, config-space *target* logic, MSI/MSI-X generation, DMA engines, AXI bridge,
  virtio queue backing.
- **PHY + link layer:** a **vendor hard block** — Xilinx/Intel Integrated PCIe block on FPGA, or a
  DesignWare-class controller+SerDes PHY on ASIC. **Open RTL does not provide the SerDes.**
- **Board:** card edge connector, reference clock, power (incl. 12 V aux if beyond slot budget),
  thermal solution.

### 3.1 Power and thermal envelope (AI SKU)
Estimates only — see `architecture/ai-matrix/scaling-100tops.md` §10; none of these are measured.

- A 100-TOPS-class card lands near **60–80 W typical, 100–150 W peak**. **The 75 W ×16 slot budget is
  not sufficient**: plan a 150 W-class card with one 8-pin aux connector.
- **Boot-time power negotiation is mandatory.** The card must come up inside 75 W and stay there until
  aux power is confirmed present, because the host enumerates before it can be told otherwise.
- **A power-capping loop is a requirement, not an optimisation:** island DVFS or per-cluster clock
  throttling from a thermal sensor, an MSI on threshold crossing, and separately documented burst and
  sustained clocks. An uncapped part either exceeds its envelope or silently misses its throughput
  number.
- Per-cluster power gating keeps the low-load regime (batch-1 decode, `scaling-100tops.md` §5) cheap.

## 4. BAR layout (proposed)

| BAR | Size | Contents |
|---|---|---|
| BAR0 | 64 KB | management registers: reset, boot mode, health/temperature/power, power cap, doorbells, MSI-X table, **AI island capability window** (`architecture/ai-matrix/scaling-100tops.md` §8) |
| BAR2 | 1 MB | virtio-pci queues (net, console, blk, vsock) |
| BAR4 | 256 MB–4 GB, **resizable BAR** | window into card DRAM — bulk weight/tensor push at link bandwidth |

## 5. Transport: virtio, not a bespoke netdev
Expose the card as a multi-function virtio-pci endpoint so the **host needs no custom data-path
driver** — in-kernel `virtio_net`, `virtio_console`, `virtio_blk` and `vsock` do the work. Only a thin
`g6lc_mgmt` driver is custom (reset, firmware update, telemetry, resizable-BAR setup).

| Device | Role |
|---|---|
| `virtio-net` | host gets a `g6lc0` netdev; card takes a ULA IPv6 address → **SSH, Ray, gRPC work unchanged** |
| `virtio-vsock` | control plane that works before the card's network is up and survives IP misconfiguration |
| `virtio-console` | early boot / panic log |
| `virtio-blk` | rootfs image served from the host; no on-card flash needed for development |

**Bulk path bypasses the netdev.** Large tensors move via BAR4 `mmap` or the DMA engine, exposed as
`card.upload(tensor)`. Pushing tens of GB of weights through a virtio-net socket wastes most of the
link on copies; the split control/bulk path is the reason for the design.

Card-side device implementation: a firmware thread on one core acting as the virtio backend is the
simplest P5 option, at the honest cost of one core and ~5–15 µs latency — acceptable for control,
never for bulk. A hardware queue engine is the later optimisation.

**Multi-card:** cards are Ray/Dask nodes over their IPv6 addresses. Card↔card peer-to-peer DMA depends
on host root-complex support — treat as an optimisation, not a requirement.

## 6. Integration seam (corev_apu)
- Bridge PCIe hard-IP AXI/AXI-Stream to the `corev_apu` fabric: **slave** for BAR/config accesses from
  the host, **master** for card→host DMA. Route MSI/MSI-X generation from card to host.
- Reuse the wide-AXI merge pattern already used by the accelerator attach
  (`corev_apu/src/g6lc_axi_2to1_mux.sv`).
- Board wrapper in `corev_apu/fpga/src/`, transceiver + refclk constraints in
  `corev_apu/fpga/constraints/`.
- Boot order: card must be link-trainable and answer config reads **before** its own Linux is up, or
  host enumeration fails. Management logic therefore sits in an always-on power/reset domain,
  independent of core reset.

## 7. Config gating & invariants
- Whole block optional; PHY/hard-IP choice is a board/ASIC decision. BAR sizes belong to the SoC
  address map, aligned with `config_pkg` regions and PMA/PMP rules.
- CDC across the PCIe core clock; async-active-low reset; `tc_sram` for DMA/queue buffers; DFT
  (`test_en_i` / `testmode_i`) threaded.
- **Host-initiated DMA into card memory must be address-checked** (IOMMU stage or region-check unit).
  A host-writable window that reaches arbitrary card physical memory defeats the card's own PMP/PMA.
- DMA and speculative traffic honour AXI ordering and RVWMO; no non-recoverable speculative allocation.
- FLR, surprise-removal and link-down must leave the card in a recoverable state; the management
  domain must survive core reset.

## 8. Verification + software
- `corev_apu/tb`: host-side root-complex model performing enumeration, BAR sizing, config read/write,
  MSI delivery, DMA loopback, and an address-check **rejection** test.
- Device tree: PCIe endpoint topology + `g6lc,ai-matrix` sibling node where present; cross-validate per
  `AGENTS-dts-validation.md`.
- Host software: stock virtio drivers + `g6lc_mgmt`; `card-list` / `card-run` / `card-cp` wrappers over
  vsock + virtio-net. `g6lc_mgmt` also exposes the power cap, thermal telemetry and the AI capability
  window so a host scheduler can size work without a card-side round trip.
- Card software: existing bootrom → OpenSBI → Linux flow, plus `sshd` and the AI runtime
  (`architecture/ai-matrix/README.md` §6).

## 9. Licensing note
This outline is tier **T** (`architecture/**`, MIT, no inline header). Vendored `verilog-pcie` /
`litepcie` are tier **U** — preserve verbatim. Card-side glue that is generic PCIe/virtio plumbing is
tier **R**; anything that is AI-specific (descriptor rings feeding the matrix engine) is **also tier
R** — the AI plane rides the open path, so no glob here is withheld and nothing blocks creating files.
See `architecture/ai-matrix/README.md` §7.

## 10. Hostless virtual board (`virt-ai-pcie`)

Before a real FPGA/ASIC card exists, CI uses a **virtual** motherboard board that models the same
BAR/virtio/SSH/BAR4 roles over localhost TCP and a soft UIO/eventfd userspace driver (no kernel, no
PCIe PHY):

- Board: `corev-mb/boards/virt-ai-pcie/board.json` (`class: virtual`, `skidl: omitted`)
- Target doc: `corev-mb/architecture/virt-ai-pcie/README.md`
- Driver: `ai-tensor/tools/virt_ai_card/` · smoke: `monorepo-soak/run-virt-ai-card.sh`
- Host contract: `architecture/ai-matrix/board-uio-eventfd.md` §7

Promotion to a physical card keeps connector ids and switches soft-sticky → live UIO + endpoint IP.

The host-side EDK2 witness (`g6lc-virt` GPEX + FD Shell) currently delivers a packed `DESC.BIN`
(ingested `desc_layout` OP_GEMM image) as a **FAT file** on the virtio-blk ESP, not as a BAR4 write.
The card stand-in (`ai-tensor/tools/virt_ai_card/`) accepts the same image as BAR4 name `DESC` and
via `mmio_wr` into the existing 4 KiB UIO window at ingested `desc_base`. CAP words are readable
with `mmio_rd`. The host rings UIO DOORBELL and claims DONE the same way. Packed `ptr_a`/`ptr_b`/`ptr_c`/`ptr_done`
stay **0** (ABI null): bulk tensors ride BAR4 names `A`/`B`/`C`, and the completion word is MMIO
`CPL`, not a DMA write to an invented address. Descriptor `flags[2]` is the ingested IRQ bit
(`isa-encoding.md` §7); the stand-in `FLAG_IRQ` is `1<<2`. Packed `ld_ab` is `k|(n<<16)` from the
GEMM shape, not an address. Dense INT8 is `dtype=00`/`ew=00`/`sp24=0` (no INT4 in the 100-TOPS
headline). Doorbell qid maps to a cluster via ingested `queue_cluster_map` and to a QoS class via
`qid % qos_classes`. The stand-in GEMM `k` is checked against ingested `work_quantum_k`
(`within_quantum`); fence/priority bits stay clear (`isa-encoding.md` §7.1). The card rejects a packed `ld_ab` that does not match `n,k`, a doorbell `qid >= queues`, and a
descriptor `version` other than 1 (stand-in `ST_ERR`; the ingested package publishes `ST_OK` only).
Unknown `op` completes stand-in `ST_BAD_OP`; a doorbell while CTL.enable=0 completes `ST_DISABLED`;
setting CTL.enable=1 again restores `ST_OK` (`reenable_ok`).
That is layout agreement over TCP, not a pinned BAR map. `contracts.ai_host_transport` stays unpinned.

## 11. Scan pointers
Endpoint config-space/BAR target logic, MSI-X table, DMA engine, AXI bridge, and which FPGA hard-IP
wrappers ship. Confirm endpoint (not just root-complex) coverage before vendoring. Pin a SHA before
`vendored`.
