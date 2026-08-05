# genesys2 — development target (reference, implemented)

Digilent Genesys 2 (Xilinx Kintex-7 `xc7k325t`). This is the **reference** CVA6
board target: it mirrors the shipped `corev_apu/fpga/src/ariane_xilinx.sv`
(`GENESYSII` branch), so it is fully described *and* selectable
(`corev-mb/boards/genesys2/board.json`).

- Contract: `AGENTS-mb-genesys2.md` · Spec: `corev-mb/boards/genesys2/board.json` · Workflow: `AGENTS-motherboard.md`

## 1. Intent

Give the `mb` flow a known-good, buildable target that reproduces the existing FPGA bring-up
without touching core/uncore RTL. Everything else in `corev-mb` is validated against this board.

## 2. Reference feature set

| Interface | Detail |
|---|---|
| DDR3 | 1 GB SODIMM via Xilinx MIG-7 |
| Ethernet | 1 GbE, RGMII, Realtek RTL8211E PHY |
| UART | USB-UART console (FTDI FT2232HQ) |
| microSD | SD-over-SPI (Xilinx AXI Quad SPI) |
| GPIO | LEDs + switches (AXI GPIO) |
| Debug | JTAG DMI → core `debug_req_i` |

## 3. Core preconditions

`cv64a6_imafdc_sv39` — XLEN 64, `rv64imafdc`, Sv39 MMU, debug enabled. Config package:
`core/include/cv64a6_imafdc_sv39_config_pkg.sv`.

## 4. Uncore mapping (controller ↔ PHY)

| Interface | Controller (on-die) | PHY (board) |
|---|---|---|
| DDR3 | Xilinx MIG-7 | MIG-7 hard PHY + SODIMM |
| Ethernet | `ariane-ethernet` RGMII MAC (integrated) | RTL8211E |
| UART | APB UART | FT2232HQ bridge |
| microSD | AXI Quad SPI | SD slot |

`ariane-ethernet` is already an integrated submodule (see
`AGENTS-core-platform-vendor-actives.md`), so `board.json` marks it `enable:false` — selection
requests no vendor fetch.

## 5. PHY plan

PHYs are board parts owned by Digilent; on this third-party board we only **document** them
(`board.json.phys`) with pcbparts.dev queries for traceability (e.g.
`jlc_search "RTL8211E gigabit ethernet rgmii phy"`). No routing is authored (`skidl=omitted`).

## 6. Gaps vs CVA6 today

None material — this target is defined *by* the current FPGA build. It is the baseline the other
targets are measured against.

## 7. Promotion gates

Already **integrated** (the RTL top exists). The only ongoing gate is keeping `board.json` in
sync with `ariane_xilinx.sv` and the `.dts` (`AGENTS-dts-validation.md`).
