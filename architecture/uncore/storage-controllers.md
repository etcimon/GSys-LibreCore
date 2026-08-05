# Uncore outline — storage controllers (SATA / SD, + NVMe over PCIe)

**Domain:** storage · **Catalog ids:** `litesata`, `litesdcard` (NVMe via `pcie-root-complex.md`)
**Status:** planned · **Scaffold only** (see `architecture/uncore/README.md`).

## 1. Intent
Provide block storage: SD/eMMC for boot media and SATA for disks, plus NVMe **through the PCIe root
complex**. Step-3 addition (with networking).

## 2. Chosen controllers
- **litesata** — `https://github.com/enjoy-digital/litesata` — **BSD-2-Clause**. AHCI-style SATA.
- **litesdcard** — `https://github.com/enjoy-digital/litesdcard` — **BSD-2-Clause**. SD/eMMC.
- **NVMe:** no RTL — it is a protocol over PCIe (see `pcie-root-complex.md`); the Linux NVMe driver
  runs on top of the root complex.
- Fetch: `vendor sync litesata litesdcard` · Inspect: `vendor scan litesata`.

## 3. Controller vs PHY split (decisive)
- **On-die:** the SATA/SD controller (link/transport FSM, DMA, AXI front-end).
- **PHY:** SATA needs a **SerDes PHY** (FPGA transceiver / ASIC hard PHY); SD needs only I/O + a
  **level shifter** on the board.
- **Board:** SATA connector, SD/eMMC slot, and (for SATA) the reference clock.

## 4. Integration seam (corev_apu)
- AXI slave (registers) + AXI master (DMA) into the `corev_apu` fabric; interrupt to the PLIC.
- Board pin map + transceiver/level-shift constraints in `corev_apu/fpga/src/` +
  `corev_apu/fpga/constraints/`.

## 5. Config gating & invariants
- Optional per board/target. CDC across the SATA SerDes clock; async-active-low reset; `tc_sram` for
  buffers; DFT `test_en_i`/`testmode_i`. AXI ordering + interrupt cleanliness preserved.

## 6. Verification + software
- Directed sector read/write test with a device model in `corev_apu/tb`.
- Device tree: an AHCI/`sdhci`-style node + interrupt; cross-validate per `AGENTS-dts-validation.md`.
- Linux: mainline AHCI / SDHCI / NVMe drivers — avoid bespoke drivers where a mainline one fits.

## 7. Scan pointers
Controller top + DMA + AXI bridge; for SATA, the transport/link FSM and the transceiver wrapper. Pin a
SHA before `vendored`.
