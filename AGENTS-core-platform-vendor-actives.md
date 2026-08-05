# AGENTS Core-Platform Vendor Actives — the corev_apu controller & PHY substructure

> **Scope:** the *substructure* of external **controllers and PHY** that make up the CVA6 **uncore**
> (the "surrounding die" around the core), how each one splits into **on-die controller** vs
> **board/analog PHY**, and where it lands in `corev_apu`. This is the **data view** that pairs with
> the **mechanism** in `AGENTS-vendor.md` and the **RTL outlines** in `architecture/uncore/`.

CVA6 (`core/`) is a CPU core. A motherboard-class part is core **plus** an uncore: memory, PCIe,
networking, storage, display, low-speed I/O, an interconnect, and the PHYs that touch the pins. This
document enumerates the actives the `build-platform` `vendor` catalog tracks, so the jump from "IP is
a CPU" to "IP is an SoC" is a **map**, not a guess. It is regenerated from
`build-platform/src/config/defaults.ts` → `vendor.controllers`; keep the two in agreement.

---

## 1. The controller/PHY split (read first)

For every subsystem the **digital controller** is on-die (soft RTL in the FPGA or hardened on the
ASIC), while the **PHY** is either an on-die hard macro or a separate board chip. This is the single
most important fact for planning the uncore:

- **Vendor a controller** = add RTL to the die (via the catalog).
- **PHY** = FPGA vendor hard block (MIG/EMIF/GT transceiver), ASIC foundry hard macro, or an external
  chip + connector on the board. **PHYs are not in the catalog** — they are a target/board decision.

So the catalog gives you controllers you can synthesize; the PHY column below tells you what still has
to come from the FPGA/ASIC vendor or the PCB.

---

## 2. Active catalog (grouped by domain)

Status legend: `planned` (catalogued) · `vendored` (checked out) · `integrated` (in a flist). Fetch
any row with `vendor sync <id>`; inspect with `vendor scan <id>` (see `AGENTS-vendor.md`).

### 2.1 memory — DRAM
| id | controller | license | on-die vs board/PHY | corev_apu seam | status |
|---|---|---|---|---|---|
| `litedram` | LiteDRAM DDR3/DDR4/LPDDR4 + PHYs | BSD-2-Clause | Controller soft RTL; **DDR PHY = FPGA MIG / Altera EMIF or ASIC hard macro**; DIMM + clocking on board | AXI memory-side / `corev_apu/fpga/src` | planned |

### 2.2 network — Ethernet
| id | controller | license | on-die vs board/PHY | corev_apu seam | status |
|---|---|---|---|---|---|
| `verilog-ethernet` | Forencich MAC (MII/GMII/RGMII/XGMII) | MIT | MAC on-die; **external PHY chip** (RTL8211/DP83867) + magnetics + RJ45 | `corev_apu/fpga/src` (AXI-Stream↔AXI) | planned |
| `liteeth` | LiteEth MAC + UDP/IP | BSD-2-Clause | MAC on-die; external PHY on board | `corev_apu/fpga/src` | planned |
| `corundum` | 10/25/100G NIC | BSD-2-Clause | MAC/PCS on-die; **high-speed SerDes PHY = vendor IP** | `corev_apu` (PCIe/AXI) — stretch | planned |
| `ariane-ethernet` | lowRISC RGMII 1G | SHL-0.51 | MAC on-die (FPGA); board RGMII PHY | `corev_apu/fpga/src/ariane_xilinx.sv` | **integrated** |

### 2.3 interconnect — PCIe (and thereby NVMe / GPU)
| id | controller | license | on-die vs board/PHY | corev_apu seam | status |
|---|---|---|---|---|---|
| `verilog-pcie` | Forencich PCIe DMA/host glue | MIT | Glue soft RTL; **PCIe SerDes+link = FPGA hard block or DesignWare-class ASIC IP** | `corev_apu` (AXI↔PCIe hard IP) | planned |
| `litepcie` | LitePCIe endpoint/DMA | BSD-2-Clause | Uses FPGA PCIe hard block + transceivers | `corev_apu` (AXI bridge) | planned |

> **NVMe and GPUs are not controllers to vendor** — they are **PCIe endpoints**. You provide a PCIe
> root complex (above) + IOMMU/BARs + a Linux driver (in-kernel NVMe; `nouveau`/`nvk` for NVIDIA,
> which has no RISC-V proprietary driver). See `architecture/uncore/pcie-root-complex.md` and
> `storage-controllers.md`.

### 2.4 storage — SATA / SD
| id | controller | license | on-die vs board/PHY | corev_apu seam | status |
|---|---|---|---|---|---|
| `litesata` | LiteSATA AHCI-style SATA | BSD-2-Clause | Controller on-die; **SATA SerDes PHY = FPGA GT / ASIC hard PHY** | `corev_apu` (AXI) | planned |
| `litesdcard` | LiteSDCard SD/eMMC | BSD-2-Clause | Controller on-die; SD slot + level-shift on board | `corev_apu` (AXI) | planned |

### 2.5 display — HDMI
| id | controller | license | on-die vs board/PHY | corev_apu seam | status |
|---|---|---|---|---|---|
| `hdmi` | hdl-util/hdmi HDMI 1.4b TMDS | MIT | TMDS encoder on-die; **connector + ESD/re-driver on board** (TPD12S016/SN65DP159) | `corev_apu/fpga/src` (framebuffer/VDMA↔TMDS) | planned |

### 2.6 already present (low-speed peripherals, for the complete map)
Managed by `.gitmodules`, not the catalog: `apb_uart`, `apb_timer`, `apb_node`, `axi2apb`,
`axi_slice`, `gpio`, `rv_plic`, `riscv-dbg`, `register_interface`, `axi_mem_if`. These are the
existing UART/timer/GPIO/PLIC/debug uncore in `corev_apu/` — the desktop-class additions above sit
beside them on the same AXI fabric.

---

## 3. How the actives attach to corev_apu

All of these are **AXI citizens**. The integration pattern is uniform and matches how `corev_apu`
already wires peripherals:

```
                 ┌────────────────────────── corev_apu (uncore) ──────────────────────────┐
   core/cva6  ── AXI/NoC ── xbar ─┬─ DDR ctrl ── [DDR PHY macro] ── DIMM (board)
   (noc_req/resp, ariane.sv)      ├─ PCIe glue ── [PCIe hard IP/SerDes] ── slot (board) ── NVMe/GPU
                                  ├─ Eth MAC ──── [ext PHY chip] ── RJ45 (board)
                                  ├─ SATA/SD ctrl ─ [SerDes/level-shift] ── drive/card (board)
                                  ├─ HDMI TMDS ── [re-driver] ── HDMI port (board)
                                  └─ APB: UART/SPI/I2C/GPIO/timer/PLIC/debug (existing)
```

- **Reusable controller RTL** → `vendor/<org>/<name>` (catalog submodule) or `corev_apu/<block>/`.
- **Board-specific wrappers, pinouts, PHY instantiation, constraints** → `corev_apu/fpga/src/` +
  `corev_apu/fpga/constraints/` + board `*.svh` (the existing `ifdef GENESYSII/KC705/NEXYS_VIDEO/…`
  pattern in `ariane_xilinx.sv`).
- **Software view** → device tree (`corev_apu/…/*.dts*`) + Linux driver, cross-validated per
  `AGENTS-dts-validation.md`.

Detailed per-domain RTL notes (top module, bus, parameters, PHY, verification, DTS) live in
`architecture/uncore/`.

---

## 4. Progressive path toward the OoO objective

The uncore is built **in parallel** with the core roadmap in
`architecture/Architecture-research-todo-drafts.md`; a controller is only worth integrating when the
core/memory system can feed it. Suggested ordering (each step gated by SoC-readiness):

1. **Memory first** — `litedram` behind the existing AXI memory-side seam. Nothing else matters until
   DRAM bandwidth exists. Pairs with the L2/L3 extension point (`architecture/l2-l3-cache/`).
2. **PCIe root complex** — `verilog-pcie`/`litepcie`. Unlocks NVMe, GPU, and extra NICs via one seam;
   the highest-leverage single addition for "desktop-class".
3. **Networking + storage** — `verilog-ethernet` (or reuse `ariane-ethernet`), `litesata`/`litesdcard`.
4. **Display** — `hdmi` for local console/GUI.
5. **High-end** — `corundum` NIC; multi-lane PCIe; only once the OoO core + coherent multi-core
   (`architecture/multi-core/`) can sustain the traffic.

Reaching a UR-DP1000-class part (8-wide-ish OoO, RVH, DDR4-ECC, 24-lane PCIe 4.0, UEFI/ACPI) means
**both** the core roadmap *and* this uncore substructure land — the controllers here are the uncore
half of that end goal.

---

## 5. Keeping this document honest

- Regenerate the tables from `vendor.controllers` whenever the catalog changes (add/remove/re-pin).
- Update `status` in lockstep with `vendor status` reality and flist integration.
- When a controller becomes `integrated`, add its row to `AGENTS-specs-to-impl.md` (ISA-visible parts)
  and its outline in `architecture/uncore/`.
- Each active should carry a per-vendor **code-agent** guide at `agents/vendor/AGENTS-vendor-<id>.md`
  (create on-fetch, refresh on-update, finalize on-integrate) — the `AGENTS.md`-equivalent for that
  checked-out tree, governed by `AGENTS-vendor-code-agents.md`.
- Never invent a PHY as a "controller": if it is analog/SerDes/hard-macro, it is a target/board line
  item, documented in the PHY column, not a catalog entry.
