# AGENTS-mb-genesys2 — Digilent Genesys 2 (Kintex-7) board contract

Per-board contract that tethers Genesys 2 board work to CVA6 core/uncore
development. Machine truth lives in `corev-mb/boards/genesys2/board.json`; the
development target lives in `corev-mb/architecture/genesys2/README.md`; the
governing workflow is `AGENTS-motherboard.md`.

- **Status:** `reference` · **Class:** `fpga` · **SKiDL:** `omitted` (third-party dev board — no in-tree PCB)
- **Core target:** `cv64a6_imafdc_sv39` (XLEN 64, `rv64imafdc`)
- **RTL top of record:** `corev_apu/fpga/src/ariane_xilinx.sv` (`GENESYSII` branch)

> This board is the **reference**: its `board.json` is written to match the shipped Xilinx
> bitstream, so `mb select genesys2` reproduces exactly the core/uncore configuration the
> existing FPGA flow expects. Because Digilent owns the PCB, `skidl=omitted` — there is no
> schematic to author, only the RTL/config target to lock in.

---

## 1. CPU preconditions (what the core must provide)

| Field | Required | Source of truth |
|---|---|---|
| `soc.coreConfig` | `cv64a6_imafdc_sv39` | `core/include/cv64a6_imafdc_sv39_config_pkg.sv` |
| `soc.xlen` | `64` | " |
| extensions | `i m a f d c zicsr zifencei` | " |
| MMU | Sv39 | config pkg (`MmuPresent`, `ModeSv39`) |
| Debug | enabled (JTAG DMI) | `dmi_jtag` in `ariane_xilinx.sv` |

`mb check genesys2` fails if the active `.config.ts` diverges; `mb select genesys2` adapts it
through the gitignored overlay.

## 2. Uncore / APU enables

| Interface | Controller | On-die vs board | Notes |
|---|---|---|---|
| DDR3 SODIMM | `xlnx_mig_7_ddr3` (Xilinx MIG) | controller = FPGA hard IP; PHY = MIG hard PHY | 1 GB SODIMM; AXI-attached in `ariane_xilinx.sv` |
| 1 GbE | `ariane-ethernet` (RGMII MAC) | MAC on-die; PHY on board | already integrated via `.gitmodules`; **not re-fetched** |
| UART | (APB UART) | bridge on board (FTDI) | USB-UART console |
| microSD | `xlnx_axi_quad_spi` | controller on-die; slot on board | SD over SPI |
| GPIO | `xlnx_axi_gpio` | on-die | LEDs + switches |
| JTAG debug | `dmi_jtag` | on-die | feeds core `debug_req_i` |

`apu.controllers` marks `ariane-ethernet` with `enable:false` because it is already integrated —
`mb select` therefore requests **no** vendor fetch for this board (nothing to do), which is correct.

## 3. Board PHYs (documented, not authored)

| Ref | Interface | MPN | Vendor | pcbparts query |
|---|---|---|---|---|
| `eth_phy` | RGMII 1G | `RTL8211E-VL` | Realtek | `jlc_search "RTL8211E gigabit ethernet rgmii phy"` |
| `usb_uart` | UART | `FT2232HQ` | FTDI | `jlc_search "FT2232HQ USB UART bridge"` |
| `ddr3_sodimm` | DDR3 | 204-pin SODIMM | (module) | electrical PHY = MIG-7 hard PHY |

PHYs are **board** decisions. They are recorded here + in `board.json` for traceability; on a
third-party board we do not select or route them.

## 4. Workflow checklist

- [ ] `mb select genesys2` → overlay adapts config; board package generated.
- [ ] `mb check genesys2` → core compatible; no vendor fetch required.
- [ ] `build --iss verilator` (target `cv64a6_imafdc_sv39`) elaborates.
- [ ] `mb test genesys2` → tandem feature set reported; `--run` verilates.
- [ ] FPGA bitstream via existing `make fpga BOARD=genesys2` (Vivado) — unchanged by this flow.

## 5. SoC-readiness gates (this board)

- Core/uncore RTL untouched by selection (config + generated package only).
- Ethernet MAC/PHY split preserved (`ariane-ethernet` MAC on-die; RTL8211E on board).
- `.dts` ↔ config alignment for DDR/UART/Ethernet/SD nodes (`AGENTS-dts-validation.md`).
- Licensed vendor docs (Digilent manual, Xilinx PG150, Realtek/FTDI datasheets) are **cited**
  in `board.json.references.vendorDocs`, never copied in-tree.

## 6. Cross-references

- Machine spec: `corev-mb/boards/genesys2/board.json`
- Target: `corev-mb/architecture/genesys2/README.md`
- Workflow: `AGENTS-motherboard.md`
- Uncore: `AGENTS-corev-apu.md`, `AGENTS-core-platform-vendor-actives.md`
