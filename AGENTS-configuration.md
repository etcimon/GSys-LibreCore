# AGENTS Configuration — Target SoC and Broader Coding Context

> **Purpose:** RTL decisions are not made in isolation. They are driven by the target SoC's physical,
> electrical, and system-level constraints. This document captures those constraints so that every
> code change can be evaluated against the real target, not just against functional correctness.
>
> **Usage:** When a new SoC target is adopted, edit this file to reflect its reality. Then propagate
> the deltas through `core/include/cv*a6*_config_pkg.sv`, `core/include/config_pkg.sv`, the relevant
> `agents/spec/*.html` sub-files, and the device tree. The coding philosophy in
> `AGENTS-coding-philosophy.md` references this file as the mandatory context for timing, power,
> area, and ecosystem decisions.

---

## 1. Target performance envelope

| Parameter | Why it matters for RTL coding | Philosophy reference |
|---|---|---|
| **Target frequency** (5 GHz nameplate = 8 FO4 per cycle @ TT 0.8 V) | Determines how much logic can sit between flip-flops and how aggressive pipelining must be. | "All new logic must close timing at or above the target frequency in the worst-case sign-off corner before it is considered complete." |
| **Voltage domains & DVFS** | Multiple voltage islands, dynamic voltage scaling, and retention cells affect clock gating, isolation cells, and reset strategy. | "Explicit CDC documentation and power-intent awareness (UPF or equivalent) are required for any change that crosses a voltage or clock domain." |
| **Power budget** (total SoC watts, core watts) | Forces decisions on leakage vs. dynamic power, clock-gating density, multi-Vt usage, and whether to use complex instructions or simpler multi-cycle ones. | "High-activity blocks (e.g. vector/matrix units) must include aggressive clock gating and be placed in a dedicated power domain when the budget requires it." |
| **Thermal envelope** (TDP, junction temperature) | Influences whether high toggle-rate structures are acceptable or low-power design patterns are required. | "Avoid structures known to create thermal hotspots (e.g. very wide parallel comparators) unless the performance gain is explicitly justified against the thermal budget." |

### 1.0 Target of record — **5 GHz nameplate / 8 FO4 per cycle** (`hyp8`, since 2026-10-20)

The frequency target of record is **8 FO4 of logic per cycle**, quoted as a **5 GHz nameplate at
the screening process input `fo4_ps = 20` with the standard 0.2 margin** (§1.0c has the budget
formula, the RTL location and the design rules). Every frequency number elsewhere in this file is
read against that budget; **no lower frequency or wider budget appears anywhere in this file.**

The *market* envelope below — a **fanless, low-power OpenWrt/Linux router SoC** — is still the
reference for everything that is not a clock: caches, memory, package, power class and software.
It is **inferred from shipping shelf silicon in exactly that market** (surveyed 2026-07-24). The
closest analogue is a real RISC-V part, which makes it the primary reference for those rows:

| Reference part | CPU | Node | Caches | DRAM | Board power | Source |
|---|---|---|---|---|---|---|
| **Siflower SF21H8898** (Banana Pi BPI-RV2) — *primary analogue, RISC-V + OpenWrt* | Quad-core 64-bit RISC-V + NPU | **TSMC 12nm FFC** | n/p | 512 MB DDR3 (DDR3/3L/4 supported) | PoE-class | Siflower/BPI product data |
| MediaTek MT7986A "Filogic 830" | Quad Cortex-A53 | **12 nm** | 32 KB L1I + 32 KB L1D per core, **512 KB unified L2** | 16-bit DDR3-2133 / DDR4-3200, 256 MB–2 GB | ~5 W idle, ~10.5 W peak (whole board) | MT7986A datasheet v1.15; BPI-R3 measurements |
| MediaTek MT7988A "Filogic 880" | Quad Cortex-A73 | 12 nm class | large internal cache | DDR4-3200 | — | MediaTek product page / datasheet |
| Qualcomm IPQ9574 (Networking Pro 1620) | Quad Cortex-A73 | **14 nm** | — | 16/32-bit DDR3L/DDR4 | 13 W board / 23 W with Wi-Fi | Qualcomm product brief 87-PW325-1 |

Convergent shelf configuration: **quad-core 64-bit, 12–14 nm FinFET, 32 KB/32 KB L1
per core, 512 KB shared L2, 16-bit DDR4, ~17×17 mm BGA, single-digit-watt fanless board.**
MT7986A publishes its rails directly: **logic 0.85 V, CPU 1.023 V, I/O 1.8/3.3 V.**

The shelf parts are far shallower than the target of record. LibreCore's target is **8 FO4 per
cycle (5 GHz nameplate at `fo4_ps = 20`)**: the nameplate is a property of the budget, and the
silicon frequency is 8 FO4 × the node's measured inverter FO4 (`timings fo4-probe`), so the node
is chosen to make 5 GHz real rather than the budget relaxed to fit a node. The program buys
throughput with the deep pipeline *and* with MLP, SMT and cores (`architecture/router-core-upgrade-program.md`
§2); the IPC cost of the depth is the open question the `hyp8` tree exists to answer.

> **Status of these numbers:** *inferred from comparable shelf silicon, not from a signed-off PDK or
> an STA run.* They are good enough to size pipelines and reject bad ideas; they are **not** sign-off
> data. Any row marked `inferred` must be replaced with foundry/STA data before tape-out, and no
> "closes timing" claim may cite an inferred row.

### 1.0a Second target of record — GSys LibreCore AI card (`g6lc64_ai`)

**There are two SKUs and one clock target.** `g6lc_ai_island_cfg_pkg::AiIslandLatencyDefault.ClockKhz`
and the throughput figure `architecture/ai-matrix/scaling-100tops.md` §7 derives its TOPS from both
predate the target of record and must be re-anchored to it: **`ClockKhz = 5_000_000`** (5 GHz nameplate,
8 FO4), with every TOPS and GB/s figure recomputed from that clock. Every island TOPS number is a
product of MAC width **and** clock, so an unanchored clock makes the headline unfalsifiable — which is
exactly the failure `scaling-100tops.md` §2 exists to prevent. The 64-bit DRAM port moves 8
bytes/cycle; `DramGBps` is `noc_peak_gbps` of that port at the target clock.

The AI card is a **PCIe add-in card**, not a fanless gateway. Nothing in §1.1 transfers to it:
the power budget differs by ~25×, the thermal solution is active, and the memory class is
DDR4/LPDDR5 rather than a 16-bit DDR3 gateway bus.

| Item | Latency SKU | Throughput SKU | Confidence |
|---|---|---|---|
| Island clock | **5 GHz nameplate / 8 FO4** (`ClockKhz = 5_000_000`; code field to re-anchor) | **5 GHz nameplate / 8 FO4** | decided (program target) |
| Core clock | tracks §1.0/§1.1 (**5 GHz nameplate / 8 FO4**) — the cores are the same IP | 5 GHz nameplate / 8 FO4 | decided (program target) |
| Clusters × MAC/cycle | 1 × 512 live (`AI_LIVE_MACS`); 1–2 × 4096–8192 target | 8 × 4096 | decided |
| Peak dense INT8 | **5.12 TOPS** live nameplate (512 MAC × 2 × 5 GHz); 1–2 × 4096–8192 MAC → 41–164 TOPS | **327.7 TOPS** (8 × 4096 × 2 × 5 GHz) | derived from the target clock |
| Class-0 DRAM nameplate | **40 GB/s** (64-bit × 5 GHz, 8 bytes/cycle) | LPDDR5 400 GB/s nameplate | derived |
| DRAM class | DDR4-2400×64, `N × 19` GB/s (`DramChannels` ∈ {1,2,4,8}) | LPDDR5 ~400 GB/s (`DramClass=2`, not live) | decided |
| Card power | — | 60–80 W typical, 100–150 W peak (AI-S4) | inferred, **unmeasured** |
| Thermal | — | active; 75 W slot budget is insufficient, needs 8-pin aux | inferred |
| Process | 12 nm FFC class, as §2 | same | inferred |

**Binding rules, so the two SKUs cannot drift:**

1. **The island clock is a config field, never a literal.** `ai_island_cfg_t.ClockKhz` is the single
   source; the capability window publishes it at `CAP_OFF_CLOCK_KHZ` so software reads it rather
   than assuming. A TOPS figure quoted without naming the `ClockKhz` it used is not a figure.
2. **The core clock does not change between SKUs.** The cores are the same IP under both, so
   the §1.0 target (5 GHz nameplate / 8 FO4) and §1.1's sign-off corner apply unchanged. Raising
   the *island* clock is not permission to raise the *core* clock, and the island is **not** held
   to 8 FO4: it sits behind its own clock domain and keeps its own `ClockKhz`.
3. **Frequency is screened, not asserted.** See §1.0b.
4. **A number marked `unmeasured` may not gate a tape-out decision.** The card power row is
   AI-S4 and is explicitly open.

### 1.0b Raising the frequency target — the `sv-timing` → `--from-timing` loop

The target of record is the **8 FO4 budget: `--target-mhz 5000 --fo4-ps 20 --budget-margin 0.2`**.
(Earlier §2.8 screenings at wider budgets are superseded.) The screen is not STA, and the
distinction is load-bearing: the budget model is

```
budget_fo4 = (1000 / target_mhz × 1000 / fo4_ps) × (1 − margin)      # 5000 MHz, fo4_ps=20, margin=0.2 → 8.0
```

so `--target-mhz` *sets the budget* rather than proving anything about silicon; the silicon
frequency is 8 FO4 × the node's measured FO4 (`timings fo4-probe`).

The supported way to screen at the target, and to have the rest of the platform believe it:

```bash
# 1. Screen the real RTL at the target of record and emit a timing package.
cd sv-timing
python tools/svt.py monorepo-soak --target-mhz 5000 --profile sparse_ex \
       --correct --emit --allow-latency
# whole core (the hyp8 base emit): sv-timing correct --all-modules --target-mhz 5000 --fo4-ps 20 --budget-margin 0.2 …

# 2. Feed that package to the host gates, which then carry the target with them.
./build.sh timings validate --from-timing build-platform/workspace/build/sv-timing/monorepo-soak/sparse_ex
cva6-build test --ai --ai-ghz 5 --from-timing <fo4-pkg>        # island SKU × screened target
cva6-build diag run ai --from-timing <fo4-pkg>
# host compile of a flist at the target: timings compile --target <pkg> --all-modules --target-mhz 5000 --fo4-ps 20 --budget-margin 0.2
```

**What must be true before a raised target is written into this file:**

| Gate | Why |
|---|---|
| The sparse cones close at the new target **after** latency-neutral rewrites only | Buying closure with extra pipeline stages changes the micro-architecture, so it is a design decision, not a retune (§2.8 rule 6) |
| Residual exclusive/LSU cones are named, with their estimated ceiling | Those cones call for restructure, overlap or multi-cycle/T3 (`hyp_core_ws/analysis/cut_minimization.md`), not more FO4 credit |
| The island's `ClockKhz` and the core target are updated **together or explicitly not** | §1.0a rule 2 |
| `--from-timing` is passed to the suites that quote the number | Otherwise the suite is still quoting the old target |
| The row is marked `inferred (FO4 screen)` and not `closes timing` | §1.0's status rule: no closure claim may cite an inferred row |

**`fo4-v1` must not be retuned from synthetic fixtures** — only from real STA plus host
`retune-propose` (§2.8 rule 1). Screening harder is free; claiming closure is not.

### 1.0c Redesign target — `hyp8`: 5 GHz / 8 FO4 (experimental, 2026-10-20)

The timing-driven redesign program adopts an **8 FO4 logic budget per cycle**, i.e. a 5 GHz
nameplate at the screening process input `fo4_ps = 20` with the standard 0.2 margin:

```
budget_fo4 = (1000 / 5000 MHz × 1000 / 20 ps) × (1 − 0.2) = 8.0
```

| Item | Value | Status |
|---|---|---|
| Logic budget per cycle | **8 FO4** (every single-cycle kernel ≤ 8 FO4; `--target-mhz 5000 --fo4-ps 20 --budget-margin 0.2`) | decided (program target) |
| Nameplate frequency | **5 GHz** at `fo4_ps = 20`; the same RTL is 3.3 GHz at 30 ps or 8.3 GHz at 12 ps — quote `fo4_ps` with every number | derived |
| Where the RTL lives | Manual output `out_rtl/` → `build-platform/workspace/hyp/` (`hyp_redesign_core_8fo4/`, `hyp_redesign_corev_apu_8fo4/`, `hyp_core_ws/`). Git tracks the symlink only. Functional drafts stay `core/` and `corev_apu/` | decided |
| Config package | `g6lc64_hyp8_config_pkg.sv` = `g6lc64_ooo` + `HypCfg` (`g6lc_hyp_pkg.sv`); `HypDefault` keeps every other package at today's behaviour | decided |
| Redesign set | every module instantiated by `g6lc64_hyp8` whose worst path exceeds 8 adjusted FO4 (measured adjusted where the board has the module, else structural); modules closing at 8 are copied from the sv-timing emit | decided |
| Design rule | **cut minimization**: per execution path, restructure → move the decision earlier → retime an existing register → overlap with gated publication → cut on a value path → cut on a dependent path (recorded). Dependent-path latencies are held: ALU add/logic → ALU 1 cycle (staggered halves), issue → operand read +0, store→load forward hidden under load-use, commit +0 on the common path; load-use pays the D$ `+2` | decided (`hyp_core_ws/analysis/cut_minimization.md`) |
| Uncore | the APU behind an `axi_cdc` seam is held to the **same 8 FO4** budget; the seam exists for domain isolation and reset ordering, not for a wider budget | decided |
| Verification | **none yet** — a correctness-seeking draft; no lint, simulation, STA or boot has been run; no closure or IPC claim may cite it. Measured caveat (delay-v44 calibration on the Nangate45 board, `sv-timing/architecture/PIPELINE-PRAGMA-REVIEW.md` A150b): the register-launch intercept is ~12 FO4 (0.26 ns at 21.4 ps), larger than the whole 8-FO4 cycle — the nameplate presumes a process whose flop overhead is a small fraction of the cycle; the structural budget is the design rule, the board decides | open |
| Draft vs redesign | `core/` and `corev_apu/` are the functional drafts (Vulkan 1.4, grouped CTS). Their present hierarchy is not the timing-sound structure. `out_rtl/` is where an sv-timing pass may carry corrected behavior onto a different structure. That carry is methodologically deferred: do not retune FO4, and do not implement CTS fixes inside `out_rtl/`, while a CTS group is still open on the drafts | decided |
| Boot target | OpenSBI then Linux on the hyp8 tree, from the hazard register `hyp_core_ws/notes/boot-hazards.md` | open |

§1.1's electrical envelope (corner, voltage, thermal class) applies to this target; `hyp8` is the
program that decides what the deeper machine costs in IPC. §1.0b's gates apply unchanged: the
nameplate enters a product row only with a measured board, and a row backed by the FO4 screen is
`inferred (FO4 screen)`.

### 1.1 Baseline — CVA6V-EC router core

| Item | Baseline value | Where it drives code |
|---|---|---|
| Target frequency | **5 GHz nameplate = 8 FO4 per cycle** (TT, 0.80 V, 25 °C; `fo4_ps = 20`, margin 0.2) | Pipeline stage budgets (≤ 8 FO4 per kernel), critical-path limits, latch/clock choices |
| Sign-off corner | **SS 0.72 V / 125 °C** (setup), FF 0.88 V / −40 °C (hold) | What "closes timing" must mean in a PR |
| Voltage domain | Single **0.80 V** core logic domain; 1.8/3.3 V I/O | Level-shifter/isolation-cell needs, retention strategy |
| DVFS | **Two OPPs**: 5 GHz @ 0.80 V (forwarding) and a 0.65 V idle OPP whose frequency follows the library's FO4 at that voltage (TBD, Power) | Clock/enable timing assumptions; WFI + `Zawrs` idle behaviour |
| Core power budget | **TBD at 5 GHz** (re-derived from the 8-FO4 design's activity; owner Power) | Clock-gating density, multi-Vt choices, unit sizing |
| Thermal design power | **TBD at 5 GHz** (fanless class is the market reference; owner Thermal) | Toggle-rate limits, predictor/L2 gating |
| Junction temperature | 0–125 °C (industrial gateway) | Corner set, leakage budget |

> **Note:** CVA6 ships with many target-specific RTL config packages
> (`core/include/cv*a6*_config_pkg.sv`). Those packages encode the *core's* view of the world
> (cache sizes, MMU mode, extensions, PMA regions). This file encodes the *SoC's* view
> (frequency, voltage, power, process, package, software). Both must agree.

---

## 2. Process technology & library constraints

| Parameter | Why it matters | What to capture |
|---|---|---|
| **Target node** (e.g. 22nm, 12nm, 7nm, Sky130, GF180) | Determines wire delay, leakage, DFM rules, and which standard cells and memories are available. | Record the node and any open-PDK name here. |
| **Standard-cell library variants** (high-density / high-performance / low-power) | Some constructs map well to high-density cells; timing-critical paths may need high-performance cells. | List the available libraries and the default synthesis target. |
| **Vt flavors and channel lengths** | Multi-Vt usage affects leakage and timing closure. | Document which Vt flavors are permitted and when each is preferred. |
| **Memory compiler limitations** | SRAM sizes, read/write latency, and power characteristics constrain cache and FIFO sizing. | List supported SRAM geometries and latency assumptions. |

### 2.1 Philosophy guidance

> "All RTL must be written with awareness of the target library's strengths and weaknesses. Prefer
> library-friendly constructs over clever but cell-unfriendly code."

A library-friendly construct example: a balanced binary mux tree in `always_comb` is usually friendlier
than a deep priority encoder on a critical path. A cell-unfriendly construct example: a wide
arithmetic shift built out of cascaded ternaries may infer a slow, area-hungry netlist.

### 2.2 Baseline — process/library

| Item | Baseline value | Confidence |
|---|---|---|
| Process node | **12 nm FinFET (TSMC 12FFC class)** — the node both the RISC-V (SF21H8898) and ARM (Filogic 830) router analogues ship on | inferred |
| Open-PDK study path | Sky130 / GF180 for **flow bring-up only** — they cannot reach the target; never quote their timing as the target | decided |
| Standard-cell library | 9-track **HD** default; **HP** cells reserved for the wakeup/select, PRF-read and predictor-provider paths | inferred |
| Vt flavors | **SVT** default; **HVT** for always-on / leakage-dominant blocks; **LVT** only on a named critical path, with justification | inferred |
| SRAM compiler | Single-port **1RW**, pipelined read (≥ 2 cycles at 8 FO4); depth 64–4096, width 32–128 b; dual-port only for the register file | derived |
| SRAM cut boundary | Everything through `tc_sram`; per-instance chip-enable gating via `tc_clk_gating` | decided |

---

## 3. SoC-level integration constraints

| Parameter | Why it matters | What to capture |
|---|---|---|
| **Number of harts / coherency** | Affects the cache subsystem, AXI ID width, interrupt/PLIC wiring, and memory-model implementation. | Record the hart count, cache-coherency protocol, and interconnect topology. |
| **Memory subsystem** (L1/L2 sizes, policies, DRAM bandwidth/latency) | Determines cache-line size, write-buffer depth, outstanding-transaction limits, and memory-ordering choices. | Record L1/L2 sizes, cache policy (WB/WT/HPDCACHE), and DRAM controller latency. |
| **Peripheral and I/O subsystem** | Influences interrupt controller choice, IOMMU presence, DMA requirements, and MMIO PMA regions. | Record PLIC/CLINT, IOMMU, DMA engines, and fixed peripheral address map. |
| **Package and pin limitations** | Power pins, signal integrity, and bump pitch constrain pad ring, power-grid, and high-speed I/O placement. | Record package type, power pin count, and any pin-assignment restrictions. |

### 3.1 Philosophy guidance

> "Changes to the core must not break SoC-level timing budgets or introduce new top-level critical paths."

Before adding a new top-level port, clock, or interrupt, verify that it fits the existing pad/pin plan
and does not force a package or PCB change.

### 3.2 CVA6-relevant integration loci

| Concern | Core-side knob | SoC-side consumer |
|---|---|---|
| D$ type | `DCacheType` in `core/include/config_pkg.sv` (`WT`, `HPDCACHE_*`) | AXI/L15 adapters in `core/cache_subsystem/` or external L2 in `corev_apu/` |
| AXI bus width | `Axi{Addr,Data,Id,User}Width` in `config_pkg.sv` | SoC interconnect and memory controller |
| PMA regions | `CachedRegionAddrBase/Length`, `NonIdempotentRegionAddrBase/Length` | DT `memory@` nodes, SoC address map |
| Hart count / ID width | Derived from `core/cva6.sv` integration | PLIC/CLINT routing in `corev_apu/` |

---

## 4. Ecosystem & software requirements

| Parameter | Why it matters | What to capture |
|---|---|---|
| **Target OS** (Linux, Zephyr, bare-metal) | Determines which privilege modes, CSRs, device-tree bindings, and SBI functions are required. | Record the OS and minimum SBI version. |
| **Toolchain expectations** | Vector intrinsics, psABI compliance, and custom-instruction encoding must match the compiler/assembler. | Record supported GCC/LLVM versions and any custom ISA extensions. |
| **Debug and trace** | JTAG, trace port bandwidth, and trigger-module requirements affect `core/cva6_rvfi.sv`, `core/trigger_module.sv`, and the debug module. | Record trace width, trigger count, and JTAG requirements. |
| **Security profile** | PMP/ePMP, pointer masking, secure boot, and crypto extensions determine security logic and CSR set. | Record required security features and boot flow. |

### 4.1 Philosophy guidance

> "New features must include the necessary hooks for software discovery and control (CSRs, DT bindings,
> SBI calls)."

A new ISA extension without an `misa`/ISA-string update and a `.dts` `riscv,isa` property is not
merge-ready. A new power-management feature without a CSR or SBI call is not usable by the OS.

### 4.2 Baseline — software stack

| Item | Baseline value |
|---|---|
| Primary OS | **OpenWrt** on Linux ≥ 6.6 (RISC-V port). Every shelf reference above lists OpenWrt as its supported OS. |
| Secondary OS / RTOS | bare-metal bring-up; Zephyr not required |
| SBI version | **OpenSBI ≥ 1.4** — required for `Sstc` detection and for the PMU SBI extension backing `Sscofpmf` |
| Toolchain | GCC ≥ 13 / LLVM ≥ 17, RVA20 baseline, moving toward RVA22 |
| ISA string target | `rv64imafdc_zicsr_zifencei_zba_zbb_zbs_zbc_zknd_zkne_zknh_zicbom` (+ `sstc`, `sscofpmf`, `zicboz`, `svpbmt`, `zawrs` as U7 lands) |
| Debug | RISC-V External Debug + JTAG, 4 triggers (`core/trigger_module.sv`), RVFI trace for bring-up |
| Security | PMP + **Smepmp**; secure boot from OTP; `Zkn` used by WireGuard/IPsec datapaths |

---

## 5. Verification, DFT, and manufacturability

| Parameter | Why it matters | What to capture |
|---|---|---|
| **Required test coverage** (stuck-at, transition, path-delay) | Determines the fault model and the scan/test compression architecture. | Record target fault coverage and ATPG tool assumptions. |
| **Scan architecture** | Defines how `test_en_i` / `testmode_i` are used and how many scan chains exist. | Record scan chain count, scan mode clocking, and compression ratio. |
| **Yield and DFM rules** | Foundry-specific rules (e.g. metal-density, via doubling) affect physical design, not directly RTL, but large regular structures (arrays, crossbars) influence them. | Record DFM constraints that affect large arrays or wide buses. |
| **MCMM sign-off** | Multi-corner multi-mode analysis requires the RTL to be robust across process, voltage, and temperature corners. | Record sign-off corners and operating modes. |

### 5.1 Philosophy guidance

> "Every non-trivial change must be accompanied by updated verification collateral and a DFT impact assessment."

New state that is not in the scan chain or not observable via `test_en_i`/`testmode_i` is a DFT
defect. New logic without a directed test or formal property is a verification gap.

### 5.2 CVA6 DFT loci

| Mechanism | File / knob |
|---|---|
| Scan enable | `test_en_i` tied to `1'b0` in-core; propagated through new stateful logic |
| Test mode (clock-gate bypass) | `testmode_i` in `core/cva6_fifo_v3.sv:29` |
| Clock gating | `vendor/pulp-platform/tech_cells_generic/src/rtl/tc_clk.sv:47-49` |
| SRAM macro boundary | `vendor/.../tech_cells_generic/src/rtl/tc_sram.sv` |

---

## 6. How to document and use this configuration in practice

### 6.1 Configuration reference table

The table below is the single source of truth for the *current* target. When the project spins a new
SoC, copy this file, update the values, and review every `CVA6Cfg` field that is affected. If a value
is unknown or intentionally unbounded, write `TBD` and the name of the owner who must resolve it.

**Confidence column:** `inferred` = derived from comparable shelf silicon (§1.0), replace with
foundry/STA data before tape-out. `decided` = a project choice, already binding on code.

| Category | Parameter | Current target value | Confidence | Owner |
|---|---|---|---|---|
| Performance | Target frequency | **5 GHz nameplate = 8 FO4 per cycle** at `fo4_ps = 20`, margin 0.2; every kernel ≤ 8 FO4 (§1.0, §1.0c) | decided (program target); no closure claim | Core arch / SoC/PD |
| Performance | Worst-case corner | **SS 0.72 V / 125 °C** setup; FF 0.88 V / −40 °C hold | inferred | STA |
| Performance | Core voltage | **0.80 V** logic (1.8/3.3 V I/O) | inferred | Power |
| Performance | DVFS operating points | 5 GHz @ 0.80 V; idle OPP at 0.65 V (frequency TBD from library FO4) | decided / TBD | Power |
| Performance | Core power budget | **TBD at 5 GHz** | TBD | Power |
| Performance | Thermal design power | **TBD at 5 GHz**, fanless class, 0–125 °C junction | TBD | Thermal |
| Process | Node / PDK | **12 nm FinFET (12FFC class)** | inferred | PD |
| Process | Default standard-cell library | 9-track HD; HP on named critical paths | inferred | PD |
| Process | Vt strategy | SVT default, HVT always-on, LVT by exception | inferred | PD |
| Process | SRAM compiler / latency | 1RW single-port, **pipelined read (≥ 2 cycles at 8 FO4)**, 64–4096 deep, 32–128 b wide | derived | Memory |
| Integration | Hart count | **2** (SMT2 → dual core, program U6); shelf parts are quad | decided | SoC arch |
| Integration | L1 caches | **32 KB I + 32 KB D, 4-way, 64 B lines** (matches MT7986A exactly) | decided | Core |
| Integration | L2 cache | **512 KB shared, 8-way, 64 B lines**, memory-side in `corev_apu/` | decided | SoC arch |
| Integration | D$ type | **`HPDCACHE_WT`** — non-blocking + stride prefetch, write-through keeps coherence simple | decided | Core/SoC |
| Integration | Coherency / interconnect | AXI4 (`NOC_TYPE_AXI4_ATOP`); inclusive L2 with invalidation into the WT D$ | decided | SoC arch |
| Integration | DRAM type / width | **16-bit DDR4-2400**, 512 MB–2 GB (DDR3L fallback) | inferred | SoC arch |
| Integration | Package | ~17×17 mm BGA, fanless | inferred | PD |
| Software | Target OS | **OpenWrt / Linux ≥ 6.6** | decided | Software |
| Software | SBI version | **OpenSBI ≥ 1.4** | decided | Software |
| Software | Toolchain / profile | GCC ≥ 13 / LLVM ≥ 17; RVA20 → RVA22 | decided | Software |
| Software | Debug / trace / security | JTAG + RISC-V debug, 4 triggers, RVFI; PMP + Smepmp + OTP secure boot | decided | Software/Security |
| DFT/Sign-off | Fault model / coverage | Stuck-at ≥ 98 %, transition ≥ 90 % | inferred | DFT |
| DFT/Sign-off | Scan architecture | 8 chains + ~20:1 compression; `test_en_i`/`testmode_i` threaded | inferred | DFT |
| DFT/Sign-off | MCMM corners | TT/0.80/25, SS/0.72/125, SS/0.72/−40, FF/0.88/−40 | inferred | STA |

### 6.2 Decision framework

For every proposed RTL change, ask:

1. **Timing:** Does it close timing at the target frequency in the worst-case sign-off corner?
2. **Power/Area:** What is the incremental power and area cost? Does it fit the core and SoC budgets?
3. **Clock/Power Domains:** Does it require new power domains, level shifters, isolation cells, or CDC paths?
4. **DFT/Yield:** How does it affect scan coverage, ATPG, and DFM?
5. **Software/Ecosystem:** Is the ISA/CSR/DT impact documented and acceptable?
6. **Verification:** Is there a directed test, formal property, or compliance test that exercises it?

If the answer to question 1 is "no" or "unknown," the change is not ready for merge.

### 6.3 Change impact template

Every significant PR must include a short **SoC impact** section. Copy this template and fill it in:

```markdown
## SoC impact (from `AGENTS-configuration.md`)

- Target frequency: `<name>` — new logic closes at the 5 GHz / 8 FO4 target with `<Y>` ps slack (`<corner>`).
- Voltage/power domain changes: none / `<describe>`.
- Power/area delta: `<estimate>` (simulation and/or synthesis based).
- DFT impact: scan chain updated? `test_en_i`/`testmode_i` propagated? `<yes/no/describe>`.
- Software impact: new CSRs / ISA-string / `.dts` / SBI changes? `<describe>`.
- Verification: tests added/updated? `<list>`.
- Config package(s) affected: `<e.g. cv64a6_imafdc_sv39_config_pkg.sv>`.
```

---

## 7. Why this broader view is essential

Without this document, developers tend to optimize locally — "this new instruction is cool" — while
ignoring global SoC realities — "it destroys timing on the L1 cache path and adds 15% power."
`AGENTS-configuration.md` exists to prevent that disconnect. It is the bridge between the core RTL
config (`CVA6Cfg`) and the SoC target. When a new target is adopted, update this file first; the
deltas then drive the RTL config, the `.dts`, the verification plan, and the physical-design
constraints. In this way, the project stays on a realistic path to silicon.

---

## 8. Relationship to other AGENTS files

| File | Role |
|---|---|
| `AGENTS.md` | Main guider; references this file in the substructure map. |
| `AGENTS-coding-philosophy.md` | Defines the thought patterns for code changes; every timing/power/ecosystem decision must use this configuration as context. |
| `AGENTS-licensing.md` | Contributor-licensing policy; orthogonal but equally mandatory for code changes. |
| `agents/guides/AGENTS-soc-readiness.md` | The eight-pillar SoC/tape-out playbook; this file supplies the target-specific numbers for those pillars. |
| `core/include/config_pkg.sv` and `core/include/cv*a6*_config_pkg.sv` | The RTL-level concrete configuration. This file's SoC parameters must be reflected in those packages. |

---

*This is a living document. Update it whenever the target SoC, process node, power budget, software
stack, or verification/DFT strategy changes.*
