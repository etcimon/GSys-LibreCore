# Uncore outline — PCIe root complex

**Domain:** interconnect · **Catalog ids:** `verilog-pcie`, `litepcie` · **Status:** planned
**Scaffold only** (see `architecture/uncore/README.md`).

## 1. Intent
Add a **PCIe root complex** — the single highest-leverage uncore block. One PCIe seam unlocks NVMe
SSDs, discrete GPUs, extra NICs, and capture/expansion cards, all as **endpoints** behind the same
controller + a Linux driver. This is **step 2** of the uncore roadmap (right after DRAM).

> **Role check.** Here LibreCore is the **host** that enumerates other devices. For the inverse — a
> LibreCore plug-in card enumerated *by* a host — see `pcie-endpoint.md`. The two share DMA/TLP RTL
> and the AXI bridge but differ entirely in config-space ownership, BAR handling and enumeration role.

## 2. Chosen controllers
- **verilog-pcie** — `https://github.com/alexforencich/verilog-pcie` — **MIT**. Hand-written Verilog
  DMA/host glue over vendor PCIe hard IP; pairs with verilog-ethernet/Corundum. *Recommended primary.*
- **litepcie** — `https://github.com/enjoy-digital/litepcie` — **BSD-2-Clause**. Endpoint/DMA; Migen.
- Fetch: `vendor sync verilog-pcie` · Inspect: `vendor scan verilog-pcie` (root: `rtl`).

## 3. Controller vs PHY split (decisive)
- **On-die:** DMA engines, TLP handling, BAR/config glue, AXI bridge.
- **PHY + link layer:** a **vendor hard block** — Xilinx/Intel Integrated PCIe block on FPGA, or a
  **DesignWare-class controller+SerDes PHY** on ASIC (the UR-DP1000 uses exactly Synopsys DesignWare).
  Open RTL does **not** provide the SerDes.
- **Board:** the PCIe slot(s), reference clock, and power.

## 4. NVMe / GPU are endpoints, not controllers
- **NVMe:** provide the root complex + the in-kernel Linux NVMe driver; no NVMe RTL to vendor.
- **GPU (e.g. NVIDIA):** a PCIe endpoint needing large BARs, MSI/MSI-X, and an IOMMU for safe DMA.
  There is **no RISC-V NVIDIA proprietary driver**; open `nouveau`/`nvk` support is limited and may
  need signed firmware. Treat GPU bring-up as a software/ecosystem project, not an RTL one.

## 5. Integration seam (corev_apu)
- Bridge PCIe hard-IP AXI/AXI-Stream to the `corev_apu` AXI fabric as master (DMA) + slave (config);
  route MSI/MSI-X to the interrupt controller.
- Add an **IOMMU/ATS** stage for endpoint DMA isolation (RISC-V IOMMU — open cores exist but are not
  integrated in CVA6; note as a dependency).
- Board wrapper + transceiver constraints in `corev_apu/fpga/src/` + `corev_apu/fpga/constraints/`.

## 6. Config gating & invariants
- PHY/hard-IP is a board/ASIC decision; keep the whole block optional. Address windows/BARs sized in
  the SoC address map, aligned with `config_pkg` regions and PMA/PMP rules.
- CDC across the PCIe core clock; async-active-low reset; `tc_sram` for DMA buffers; DFT threaded.
- DMA and speculative traffic must honour AXI ordering and the memory model; no non-recoverable
  speculative allocation.

## 7. Verification + software
- Root-complex enumeration + DMA loopback test in `corev_apu/tb` (model an endpoint).
- Device tree: a `pcie@…` node (ranges, interrupt-map, `#address-cells`) — cross-validate per
  `AGENTS-dts-validation.md`. Linux: DWC/`pcie-designware`-style or generic host bridge driver.

## 8. Scan pointers
DMA + TLP + AXI bridge modules, BAR/config space, MSI logic. Confirm which FPGA hard-IP wrappers ship.
Pin a SHA before `vendored`.
