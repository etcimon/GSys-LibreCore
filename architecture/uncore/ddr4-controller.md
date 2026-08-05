# Uncore outline — DDR4 memory controller

**Domain:** memory · **Catalog id:** `litedram` · **Status:** planned
**Scaffold only** — see `architecture/uncore/README.md` contract.

## 1. Intent
Give the SoC real off-chip DRAM bandwidth: a DDR3/DDR4/LPDDR4 controller on the AXI memory-side seam,
replacing the simulation memory / on-chip scratchpad with a path to gigabytes of board DRAM. This is
**step 1** of the uncore roadmap — nothing else (PCIe, NIC, display) is worth integrating until DRAM
bandwidth exists.

## 2. Chosen controller
- **LiteDRAM** — `https://github.com/enjoy-digital/litedram` — **BSD-2-Clause**.
- Migen-generated Verilog; DDR3/DDR4/LPDDR4 cores + FPGA PHYs; proven in the LiteX ecosystem.
- Fetch: `vendor sync litedram` · Inspect: `vendor scan litedram` (roots: `litedram/core`, `litedram/phy`).

## 3. Controller vs PHY split (decisive)
- **On-die:** the DDR controller (bank/rank state machines, refresh, arbitration, AXI front-end).
- **PHY:** an **FPGA vendor hard block** (Xilinx MIG / Intel EMIF) or an **ASIC foundry DDR PHY hard
  macro** — never soft flops. LiteDRAM ships FPGA PHYs; an ASIC needs a licensed DDR4 PHY + I/O ring.
- **Board:** DIMM/SO-DIMM slots or soldered DRAM, VREF/termination, and the DDR reference clock.
- DDR5 is far less mature in open RTL than DDR3/DDR4 — treat DDR5 as a licensed controller+PHY.

## 4. Integration seam (corev_apu)
- Attach at the **AXI memory-side** the core already drives (`ariane.sv` `noc_req_o/noc_resp_i`,
  `corev_apu` xbar). Present the controller as an AXI4 slave; adapt AXI-Lite for its config/status.
- Board wrapper + pin map + timing constraints in `corev_apu/fpga/src/` and
  `corev_apu/fpga/constraints/` behind the existing board `ifdef` (`GENESYSII`/`KC705`/…).
- Pairs with the memory-side cache work in `architecture/l2-l3-cache/` (block size / AXI width align
  with `config_pkg` cache parameters).

## 5. Config gating
- Board/target selects the PHY (FPGA MIG vs ASIC macro) — a board-config decision, not core RTL.
- Keep AXI width/ID/addr consistent with `ariane_axi_pkg` / `config_pkg` so minimal configs still
  elaborate with the existing memory model when the controller is absent.

## 6. Invariants
- Asynchronous-active-low reset only; the DRAM clock domain crosses into the core domain through
  **explicit CDC** (async FIFO) — document it (`AGENTS-coding-philosophy.md` §4.1).
- Arrays via `tc_sram`; gating via `tc_clk_gating`. No raw vendor cells in reusable RTL.
- Preserve AXI ordering + response integrity; no reordering that violates the memory model.

## 7. Verification + software
- Extend `corev_apu/tb` with an AXI DRAM model; add a directed read/write/refresh test.
- Device tree: a `memory@…` node with the correct base/size; cross-validate per
  `AGENTS-dts-validation.md`. Linux uses the generic path — no custom driver for plain DRAM.
- Add a PMU/bandwidth counter where useful; keep timing-impact notes for the AXI front-end.

## 8. Scan pointers (`vendor scan litedram`)
Top AXI wrapper, the DDR4 core FSM, the PHY directory (to see which FPGA PHYs ship), and the
generated timing/config parameters. Pin `ref` to a commit SHA before moving to `vendored`.
