# AGENTS corev_apu — the uncore & surrounding die

> **North star:** `core/` is the CPU. `corev_apu/` is everything *around* it that turns a core into a
> chip — the **uncore** and the **surrounding die**: interconnect, memory/PCIe/network/storage/display
> controllers, low-speed peripherals, boot, debug, and the board wrappers that reach the pins. This
> file is the **coding-philosophy counterpart to `AGENTS-coding-philosophy.md` for the uncore**: the
> SystemVerilog **preconditions** any controller/wrapper must satisfy before it is wired into a
> `corev_apu` flist. It is a **standing workflow rule** for uncore/integration changes.

It sits beside `AGENTS-coding-philosophy.md` (core RTL discipline), `AGENTS-vendor.md` (how uncore IP
is fetched), `AGENTS-core-platform-vendor-actives.md` (which controllers/PHY exist and where they
attach), and `architecture/uncore/*` (per-domain RTL outlines). Where it conflicts with `AGENTS.md`
§0 (the SoC prime directive), §0 wins.

---

## 1. What corev_apu is (today)

- `corev_apu/src/ariane.sv` — the core wrapper: instantiates `cva6` and exposes the AXI/NoC memory
  side (`noc_req_o`/`noc_resp_i`), parameterised by `config_pkg::cva6_cfg_t CVA6Cfg`.
- `corev_apu/fpga/src/ariane_xilinx.sv` — the Xilinx FPGA top-level; **narrows per board** with
  `` `ifdef GENESYSII / KC705 / NEXYS_VIDEO / VCU118 / … `` blocks that list each board's DDR/Ethernet/
  pins, plus board `*.svh` defines and `corev_apu/fpga/constraints/` XDC.
- `corev_apu/fpga/src/ariane-ethernet/`, `apb_uart`, `apb_timer`, `gpio`, `rv_plic`, `riscv-dbg`,
  `axi2apb`, `axi_slice`, … — the existing uncore peripherals (submodules) on the AXI/APB fabric.
- `corev_apu/altera/`, `corev_apu/tb/`, `corev_apu/bootrom/` — Altera flow, testbenches, boot + DTS.

The desktop-class additions (DDR4, PCIe, NIC, SATA/SD, HDMI) sit **beside** these on the same fabric,
fetched by the `build-platform` `vendor` command and outlined in `architecture/uncore/`.

## 2. The uncore contract (how a controller attaches)

Everything is an **AXI citizen**. The uniform pattern:

```
core/cva6 ─ AXI/NoC (ariane.sv) ─ xbar ─┬─ DDR ctrl ─ [DDR PHY macro] ─ DIMM (board)
                                        ├─ PCIe glue ─ [PCIe hard IP] ─ slot ─ NVMe/GPU
                                        ├─ Eth MAC ─── [ext PHY] ─ RJ45
                                        ├─ SATA/SD ─── [SerDes/level-shift] ─ drive/card
                                        ├─ HDMI TMDS ─ [re-driver] ─ HDMI port
                                        └─ APB: UART/SPI/I2C/GPIO/timer/PLIC/debug (existing)
```

- **Reusable controller RTL** → `vendor/<org>/<name>` (catalog submodule) or `corev_apu/<block>/`.
- **Board-specific wrappers, pin maps, PHY instantiation, constraints** → `corev_apu/fpga/**` behind
  the board `ifdef`.
- **Software view** → device tree + Linux driver (`AGENTS-dts-validation.md`).

---

## 3. SystemVerilog preconditions (the gate)

Every new controller, wrapper, or peripheral in `corev_apu` must satisfy these **before** it enters a
flist. They extend `AGENTS-coding-philosophy.md` to the integration layer; confirm each or state why
it does not apply.

### 3.1 Clock & reset
- **Asynchronous-assert, synchronous-deassert, active-low reset** only:
  `always_ff @(posedge clk_i or negedge rst_ni)`. No new async reset without analysis.
- Every off-core clock (DDR, PCIe, SerDes, pixel, PHY RX/TX) is a **new clock domain**: cross it with
  an explicit CDC primitive (async FIFO / 2-flop sync) and **document the crossing**. No ad-hoc CDC.
- Clock gating only via `tc_clk_gating` (`vendor/pulp-platform/tech_cells_generic/src/rtl/tc_clk.sv`);
  no new `always_latch` outside the sanctioned ICG.

### 3.2 Sequential/combinational hygiene
- Strict `always_ff` (state) / `always_comb` (logic) separation; every `always_comb` output has a
  default (no inferred latches); no simulation-only constructs in the logic path
  (`//pragma translate_off` for sim/debug only).

### 3.3 Configurability (no hard-coding)
- Feature presence is **optional** and parameterised. Core-visible knobs go through
  `config_pkg::cva6_cfg_t` + `check_cfg` (`core/include/config_pkg.sv`); board/peripheral selection
  goes through board `*.svh` / a board-config package — **never** hard-coded inside reusable IP.
- Structural types enter modules via `parameter type …` injection (as `ariane.sv` already does).
- Minimal configs must still elaborate with the controller **absent** (fall back to the sim memory /
  no-op).

### 3.4 Bus & interconnect standardization
- Reusable controllers expose **AXI4 / AXI4-Lite** (or AXI-Stream bridged to AXI) using the existing
  `ariane_axi_pkg` / `ariane_axi_soc_pkg` types. No ad-hoc bus protocols; no bypassing the xbar
  without a timing/architectural note. Interrupts route to the PLIC/APLIC cleanly (level-correct).

### 3.5 Backend-friendly memory & power
- Arrays (packet/DMA/line buffers, FIFOs) go through the SRAM boundary `tc_sram`; power cells through
  `tc_pwr.sv`. **No raw vendor cells in reusable RTL** — vendor primitives live in board wrappers
  under `corev_apu/fpga/**`.
- Large blocks (NIC, PCIe DMA, display) get a placement / clock-gate / power-domain note.

### 3.6 PHY & analog separation (decisive)
- `corev_apu` reusable RTL is **digital controllers only**. High-speed analog PHY / SerDes / RF /
  hard macros (DDR PHY, PCIe SerDes, USB PHY, HDMI re-driver, Ethernet PHY chip) are **board/target**
  items — instantiated in `corev_apu/fpga/**` wrappers or treated as external chips, never soft-coded
  into a portable controller. The on-die/board split for each block is in
  `AGENTS-core-platform-vendor-actives.md` and the `architecture/uncore/*` outlines.

### 3.7 Testability (DFT)
- Propagate `test_en_i` / `testmode_i` through new stateful logic; preserve scan/ATPG observability;
  keep memories scannable through the `tc_sram`/`tc_clk_gating` testmode paths.

### 3.8 Observability
- Make new blocks visible to RVFI/trace where relevant (`core/cva6_rvfi*.sv`), add a **PMU event**
  (`core/perf_counters.sv`) per feature, and keep exception/interrupt paths precise. Add debug-trigger
  hooks where appropriate.

### 3.9 Timing & hierarchy
- No new long combinational path across the fabric; register controller outputs at the block boundary
  to bound fanout; pipeline complex units. Keep IP hierarchical (own placement region) — do not
  flatten reusable IP into the board top. Attach a timing-impact note for wide/high-activity nets.

### 3.10 Flist & build integration
- New reusable files enter the relevant flist (`corev_apu/fpga/Makefile` / Bender manifest / the
  OpenPiton `Flist.ariane` as applicable). Board-specific files are selected by the build target, not
  always compiled. Prefer `generate if` / parameters over heavy `ifdef` in **reusable** IP (board
  `ifdef` stays in the board top).

### 3.11 Verification & software
- Add a directed test (`corev_apu/tb` or `verif/`) + a device model. Update the device tree
  (`corev_apu/**/*.dts*`) with base/size/interrupts and **cross-validate against the upstream Linux
  binding + a reference DTS** (`AGENTS-dts-validation.md`). Point at a mainline Linux driver; avoid
  bespoke drivers where a mainline one fits. Update `AGENTS-specs-to-impl.md` /
  `AGENTS-specs-to-tests.md` for ISA-/DT-visible changes.

### 3.12 Vendoring & licensing
- Fetch controllers through the catalog (`vendor sync <id>`), **scan** them at the required lifecycle
  events (`AGENTS-vendor.md` §5), and pin `ref` to a commit SHA before integration. Vendored upstream
  keeps its own license verbatim (recorded in the catalog); new `build-platform`/wrapper **code** is
  LicenseRef-Proprietary © the active contributor per `.licensing-policy` (`AGENTS-licensing.md`). These docs are out of
  scope.

---

## 4. Board extensibility & narrowing

`corev_apu` is designed to be **extended and narrowed per board**: `ariane_xilinx.sv` `ifdef` blocks +
board `*.svh` defines + per-board `constraints/` already do this for DDR3/Ethernet across
GENESYSII / KC705 / NEXYS_VIDEO / VC707 / VCU118 / Agilex7. A new DDR4/PCIe/HDMI board adds a `*.svh`,
an `ifdef` branch listing its pins, a conditional controller instantiation, XDC constraints, and DTS
entries — the controller RTL itself stays board-agnostic (precondition §3.6).

## 5. Progressive path toward the OoO objective

The uncore lands **in step with** the core roadmap (`architecture/Architecture-research-todo-drafts.md`)
— a controller is only worth integrating when the core + memory system can feed it. Ordering:
**DRAM → PCIe → networking/storage → display → high-end NIC/multi-lane**, each behind its
SoC-readiness gate. Matching a UR-DP1000-class part means the OoO core roadmap **and** this uncore
substructure both land.

## 6. See also
- `AGENTS-vendor.md` — vendor fetch/update/scan mechanism.
- `AGENTS-core-platform-vendor-actives.md` — controller/PHY substructure + on-die/board split.
- `architecture/uncore/*` — per-domain RTL outlines · `architecture/README.md` — core extension points.
- `AGENTS-coding-philosophy.md` — core RTL discipline · `AGENTS.md` §0 — SoC prime directive.
