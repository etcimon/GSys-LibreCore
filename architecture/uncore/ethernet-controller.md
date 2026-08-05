# Uncore outline — Ethernet MAC

**Domain:** network · **Catalog ids:** `verilog-ethernet`, `liteeth`, `corundum`, `ariane-ethernet`
**Status:** `ariane-ethernet` integrated; others planned · **Scaffold only** (see `README.md`).

## 1. Intent
Provide networking: an Ethernet MAC + DMA on the AXI fabric, from 1G RGMII (already present) up to a
10/25/100G NIC (stretch). Networking is a step-3 addition — after DRAM and PCIe.

## 2. Chosen controllers
- **verilog-ethernet** — `https://github.com/alexforencich/verilog-ethernet` — **MIT**. Hand-written
  Verilog MAC (MII/GMII/RGMII/XGMII); clean AXI-Stream; the base of Corundum. *Recommended primary.*
- **liteeth** — `https://github.com/enjoy-digital/liteeth` — **BSD-2-Clause**. MAC + UDP/IP; Migen.
- **corundum** — `https://github.com/corundum/corundum` — **BSD-2-Clause**. Full 10/25/100G NIC; heavy.
- **ariane-ethernet** — lowRISC RGMII 1G — **SHL-0.51** — already wired in `ariane_xilinx.sv`.
- Fetch e.g. `vendor sync verilog-ethernet` · Inspect `vendor scan verilog-ethernet` (root: `rtl`).

## 3. Controller vs PHY split (decisive)
- **On-die:** the MAC (framing, FCS, DMA, AXI-Stream/AXI bridge).
- **PHY:** an **external Ethernet PHY chip** (RTL8211E, DP83867, KSZ9031) over MII/RMII/RGMII/GMII;
  10G+ needs a **SerDes/PCS PHY** = FPGA transceiver or ASIC hard IP.
- **Board:** the PHY chip, magnetics, and RJ45/SFP.

## 4. Integration seam (corev_apu)
- Bridge the MAC's AXI-Stream to AXI in `corev_apu/fpga/src/`; expose registers via AXI-Lite; route an
  interrupt to the PLIC (`corev_apu/rv_plic`).
- MDIO + RGMII pin map + constraints per board (`corev_apu/fpga/constraints/`, board `ifdef`).
- Reuse the existing `ariane-ethernet` seam in `ariane_xilinx.sv` as the reference wiring.

## 5. Config gating
- Board selects PHY interface (RGMII vs SGMII/XGMII) and MAC variant; keep it optional so configs
  without networking still elaborate.

## 6. Invariants
- CDC between the PHY RX/TX clocks and the core/AXI domain via async FIFOs — document it.
- Async-active-low reset; `tc_sram` for packet buffers; `tc_clk_gating` for gating; DFT `test_en_i`.
- Speculative/DMA writes must respect AXI ordering; interrupt is level-clean into the PLIC.

## 7. Verification + software
- Add a MAC loopback / packet-injection test in `corev_apu/tb`.
- Device tree: an `ethernet@…`/MAC node + PHY handle + interrupt; cross-validate against the upstream
  Linux binding + a reference DTS per `AGENTS-dts-validation.md`.
- Linux: map to an in-tree driver (e.g. the MAC's existing driver) — avoid a bespoke driver if a
  mainline one fits.

## 8. Scan pointers
MAC top + AXI-Stream interface + FIFO/CDC modules + MDIO. For Corundum, scan `fpga/common/rtl`. Pin a
SHA before `vendored`; note the license per controller in the actives table.
