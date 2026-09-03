# Uncore outline — DDR4 memory controller

**Domain:** memory · **Catalog id:** `litedram` · **Status:** vendored @ `3cf585a` (generate landed; class-1 N=1/2/4/8 opt-in; native wrap; `--sim` 256-beat stream **7858 milli-GB/s / 98% fabric**; 80% gate closed)
**Scaffold only** — see `architecture/uncore/README.md` contract.
**Channel stability (cores + multi-core + island):** [`dram-channel-scaling.md`](dram-channel-scaling.md).

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
- Live testharness: `g6lc_ai_dram_backend` on `master[ariane_soc::DRAM]` **after**
  `axi_riscv_atomics_wrap`. That is the **cluster** DRAM port (`g6lc_cluster` `mem_req_o` →
  xbar → DRAM). The island GEMM DMA is a second xbar master into the **same** slave — not a
  private island PHY. Multi-channel stripe (`g6lc_ai_dram_channels`) therefore serves I$, D$,
  PTW, L2/L3, prefetch, AMO, SMT2, stream/Zicboz, Ara, and GEMM together.
- Board wrapper + pin map + timing constraints in `corev_apu/fpga/src/` and
  `corev_apu/fpga/constraints/` behind the existing board `ifdef` (`GENESYSII`/`KC705`/…).
- Pairs with the memory-side cache work in `architecture/l2-l3-cache/` (block size / AXI width align
  with `config_pkg` cache parameters). **L2 line = 64 B = default `DramChanShift`.** A line or
  AXI burst must not straddle a stripe (`dram-channel-scaling.md` §5).

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

## 9. Island I3 (DRAM class vs I3-lite NoC)

The AI island's GEMM sequencer is a **second AXI master** on the same fabric as the core
(`g6lc_ai_island_top` DMA/GEMM mux). I3 is this controller, not a wider MAC array.

| Class (`CAP_OFF_DRAM_CLASS`) | Live? | Nameplate `DramGBps` | What it is |
|---|---|---|---|
| **0 sim AXI** | **Yes** (I3-lite) | **8** | Testharness AXI memory. Peak is the island **64-bit NoC** at 1 GHz. PMU measures achieved GB/s after GEMM. |
| **1 DDR4** | No | board DIMM class | LiteDRAM at the xbar (this outline). Island `DramClass` flips to 1 when the controller is on the flist. |
| **2 LPDDR5** | No | **400** SKU target | `AiIslandLatencySkuTarget` only. Do not put 400 in the live default. |

**Do not start I2 clusters** while class is 0. Growing MAC width on the 8 GB/s fixture is the
§11 failure mode. Island knobs stay in `g6lc_ai_island_cfg_pkg`, not `cva6_cfg_t`.

Class-1 bringup: keep AXI width/ID consistent with `ariane_axi_pkg`; CDC the DRAM clock
inside the wrap; drive `DramClass=1` from **`AiIslandDdr4Bringup`** (nameplate **19 GB/s**
= DDR4-2400×64 peak, `MaxAROut=8`), then a **measured** figure from bring-up PMU
(≥80% of `min(nameplate, fabric peak)`, not of 400, not from `2/T`). Do not put 400 in
class 1. `island_cfg_legal()` refuses a sim-AXI part whose nameplate is not the NoC
peak, refuses a DDR4 part that reuses the 8 GB/s NoC number or 400, and refuses an
LPDDR5 SKU that reuses the I3-lite NoC number. Testharness instantiates
`g6lc_ai_dram_backend` (`DramClass` from `AiIslandLatencyDefault` unless
`G6LC_AI_DRAM_CLASS1` / `G6LC_AI_DRAM_CHANS_2`). Class 0 is axi2mem+sram,
`init_done_o=1`. Class 1/2 **do not** fall back to SRAM — they `$error` unless
`G6LC_HAVE_LITEDRAM` and the generated core is on the flist.
`vendor.controllers.litedram` stays `enabled: false` until an explicit catalog
`vendor sync`; the gitlink may already be present. Guide:
`agents/vendor/AGENTS-vendor-litedram.md`. Generate contract:
`architecture/uncore/litedram-testharness.yml` (not on a flist).

**Channel count** is a SoC DRAM-slave knob (`DramChannels` in
`g6lc_ai_island_cfg_pkg`, power of two, max 8) — **not** a `cva6_cfg_t` field and
**not** I2 `Clusters`. Each channel is one `litedram_core` (`g6lc_ai_dram_channels`
+ 64-byte stripe at `DramChanShift`). DDR4 nameplate = `N × 19` GB/s
(`ddr4_nameplate_gbps`). Live SKU is **N=1**. Two-channel bringup:
`AiIslandDdr4x2Bringup` / `G6LC_AI_DRAM_CHANS_2`. Core pipelines stay
channel-oblivious and still **use** the channels because they already miss to
DRAMBase. `NrCores` adds concurrency, not PHYs. Max DDR4 (8ch) = **152 GB/s**,
which does not close 100 TOPS (195 GB/s at `T=512`); 400 GB/s stays class 2.
Stability / QoS / dual-port plan: [`dram-channel-scaling.md`](dram-channel-scaling.md).

LiteDRAM `--sim` generate has landed (`corev_apu/ai_island/generated/gateware/litedram_core.v`);
class 1 is still opt-in (`G6LC_AI_DRAM_CLASS1` + `G6LC_HAVE_LITEDRAM`), not the default.
Native wrap **PASS** id6 **1445 cy** (eight AR + eight AW live / 9th backpressure, mixed AW+AR). Wrap **NrArSlots/NrAwSlots=8**; AXI held until `init_done` (`ForceInitDone=1` in `--sim`).
Until class 1 is the live SKU, island GEMM can still see DDR4-class **command** latency
via `g6lc_ai_dram_timing` on the island AXI master (page hit = Cas, miss =
tRP+tRCD+Cas). Live SKU sets Cas=0 (passthrough, 83.7k cy identity). Opt-in
`+define+G6LC_AI_DRAM_TIMING` elaborates `AiIslandDdr4TimingSim` (class 0, nameplate
still 8 GB/s, Cas=14, MaxAROut=8) — rebuild `work-ver-ai-dt`, do not reuse
`work-ver-ai`. Bringup class-1 package is separate. This is **not** LiteDRAM and
does **not** delay the core's testharness SRAM. CAP `0x48` bit0 is `init_done`
(class 0 = 1; class-1 `--sim` is 1 via `ForceInitDone`; FPGA calib still waits on `core_init_done`). Standalone page-delay smoke:
`verif/tb/ai_island/run-dram-timing.sh`. Snapshot: `architecture/current-stage.md`.
