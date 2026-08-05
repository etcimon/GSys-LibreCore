# Guide: SoC / tape-out readiness (cross-cutting)

This is the detailed expansion of **`AGENTS.md` section 0**, the prime directive. Unlike the four
domain guides (branch prediction, L2/L3, RAM, speculation), this guide is **cross-cutting**: it binds
*every* implementation change regardless of domain. Read `AGENTS.md` sections 0 and 4 first.

Governing idea: CVA6 is manufacturable IP. Functional correctness against the RISC-V spec (the rest of
`agents/`) is necessary but not sufficient. A feature is only complete when it also closes timing, is
config-optional, is verified + testable, is observable, is power/area/security-aware, and is documented.
**Treat every change as if the SoC tapes out in 3-6 months.** Repairing a badly integrated feature after
the SoC is frozen costs 3-10x and can move an MPW prototype from the ~$10-30k range into $100k+ and
multi-month delay.

---

## 0. The sanctioned seams (add features here, not inside a pipeline stage)

| Seam | Where | Use it for |
|---|---|---|
| **Config struct** | `core/include/config_pkg.sv` (`cva6_cfg_t`, `check_cfg`) + `core/include/cv{32,64}a6*_config_pkg.sv` | Making any feature optional and legal-checked |
| **CVXIF coprocessor** | `core/cvxif_fu.sv`, `core/acc_dispatcher.sv`, ports `core/cva6.sv:337-340` | Custom instructions / compute without touching the core pipeline or its verification |
| **Tech cells (PDK swap)** | `vendor/pulp-platform/tech_cells_generic/src/rtl/{tc_sram.sv,tc_clk.sv}`, `.../src/tc_pwr.sv` | All memory arrays, all clock gating, power/isolation cells |
| **NoC / memory port** | `noc_req_o/noc_resp_i` (`core/cva6.sv`), `core/cache_subsystem/*axi_adapter.sv`, `corev_apu/` | L2/L3, external memory, SoC integration |
| **Observability** | `core/cva6_rvfi_probes.sv`, `core/perf_counters.sv`, `core/trigger_module.sv` | Trace, PMU events, debug triggers |

Rule of thumb: if a change forces edits deep inside `issue_read_operands.sv`, `scoreboard.sv`, or a
cache controller, ask whether it could instead live behind CVXIF or a config gate. The core pipeline is
the most expensive place to re-verify.

---

## 1. Synthesizability & timing closure (highest priority)

**Code reality.**
- Single reset strategy: **asynchronous, active-low**, `always_ff @(posedge clk_i or negedge rst_ni)`
  — pervasive (131+ occurrences), canonical example `core/cva6_fifo_v3.sv:207-213`.
- Strict `always_ff` / `always_comb` separation is the house style; do not mix.
- The **only** sanctioned latch in the design is inside the ICG cell `tc_clk_gating`
  (`vendor/pulp-platform/tech_cells_generic/src/rtl/tc_clk.sv:47-49`). Do not introduce `always_latch`.
- Sim-only constructs (`initial`, `assert`, `$fatal`, delays) are fenced with `//pragma translate_off`
  / `//pragma translate_on` — e.g. `core/cva6.sv:1884-1889`, `tc_clk.sv:113-117`.

**Do.**
- Keep combinational cones short; pipeline complex new units (FPU-like, vector, accel) instead of
  extending a critical path. Note any new critical or high-activity net.
- Reuse `clk_i`/`rst_ni`. A new clock or async reset requires explicit CDC and reset-synchronizer
  analysis and review — it is not a casual addition.

**Don't.**
- No `initial`-block logic, `force`/`release`, `#delay`, or unbounded loops in the synthesizable path.
- No new `always_latch`; no combinational feedback; no gated clock built by hand (use `tc_clk_gating`).

---

## 2. Configuration & parameterization

**Code reality.** Every module elaborates against one `config_pkg::cva6_cfg_t CVA6Cfg`; feature bits
and enums (`cache_type_t`, `bp_type_t`, `vm_mode_t`) gate everything (see `AGENTS.md` section 4 table).
Legality lives in `check_cfg(...)`. 13 target packages instantiate concrete configs
(`core/include/cv{32,64}a6*_config_pkg.sv`).

**Do.**
- Add a `cva6_cfg_t` field for the feature; add a `check_cfg` assertion for its legal range and for
  mutual-exclusion with incompatible features (pattern: `CvxifEn` vs `EnableAccelerator`,
  `core/cva6.sv:850-852,1886`).
- Default the field **off** so minimal configs still elaborate and synthesize. Pass structural types
  via `parameter type ...` injection.
- Document the field's area/power/timing impact where it is declared.

**Don't.** Hard-code sizes, addresses, or feature enables in a module — it forces a full-core
re-verify and re-synth and defeats minimal-config builds.

---

## 3. Verification, compliance & DFT (in lockstep, never after)

**Code reality.** Verification tree under `verif/`: `verif/core-v-verif/` (UVM env + libs, incl.
`lib/sim_libs/cluster_clock_gating.sv`), `verif/regress/`, `verif/sim/`, `verif/tb/`, `verif/tests/`,
`verif/env/`. Scan/DFT is already threaded: register files take `test_en_i` (tied `1'b0` in-core,
`core/issue_read_operands.sv:924,940,986,1002`); FIFOs take `testmode_i` to bypass the clock gate
(`core/cva6_fifo_v3.sv:29`); the ICG cell exposes `test_en_i` (`tc_clk.sv:41`).

**Do.**
- Add directed tests and coverage for the feature; keep the RISC-V compliance regression green; update
  formal properties if the touched block has them.
- Propagate `test_en_i` / `testmode_i` through any new stateful logic so scan chains and ATPG coverage
  are preserved. Plan MBIST for any new SRAM instance.
- Run gate-level / power-aware checks after synthesis for anything non-trivial.

**Don't.** Merge RTL "to be verified later." Post-synthesis or on-silicon bugs are the most expensive
class of defect.

---

## 4. Physical-design / backend friendliness

**Code reality.** The PDK-swap boundary is `tech_cells_generic`: `tc_sram.sv` (SRAM macro), `tc_clk.sv`
(ICG/mux/buffer), `tc_pwr.sv` (power/isolation). The clock gate carries an `IS_FUNCTIONAL` parameter
(`tc_clk.sv:31-37`): `1` = required for function, `0` = power-only and may be mapped to a feedthrough.

**Do.**
- Route every memory array through `tc_sram` and every gate through `tc_clk_gating`; a foundry swaps
  these for compiled macros / library cells.
- Give large blocks (vector unit, matrix engine, accelerator) their own placement region, clock-gate
  enable, and power-domain plan. Keep hierarchy clean (sparing use of `keep_hierarchy`).
- Watch fan-in/fan-out; flag routing hotspots; establish an early synth→timing feedback loop.

**Don't.** Instantiate raw flop arrays for memories, bake a specific vendor cell into RTL, or create
wide high-fanout broadcast nets across the core.

---

## 5. Ecosystem & software compatibility

**Code reality.** The SoC-visible contract is the `.dts` ↔ config ↔ spec triple (`AGENTS.md` section 6).
CSRs live in `core/csr_regfile.sv`; ISA discovery is via config bits → `misa`/ISA string. Custom compute
belongs on **CVXIF** (`core/cvxif_fu.sv`, `core/acc_dispatcher.sv`).

**Do.**
- Give any new instruction/CSR a real encoding and a discovery mechanism; update the `.dts` bindings and
  note OpenSBI/Linux/toolchain (GCC/LLVM)/debugger impact.
- Keep new behavior behind a capability/config bit so existing binaries do not break.
- Prefer CVXIF for custom extensions; publish the opcode/behavior/discovery if it is bespoke.

**Don't.** Add opcodes or CSRs that silently change decode, or that require firmware/DT changes without
documenting them.

---

## 6. Debug, trace & observability

**Code reality.** RVFI probes `rvfi_probes_o` (`core/cva6.sv:336`) built by
`core/cva6_rvfi_probes.sv` / `core/cva6_rvfi.sv`; debug via `debug_req_i` (`core/cva6.sv:334`) and
`core/trigger_module.sv`; PMU in `core/perf_counters.sv`.

**Do.** Expose new architectural state to RVFI; make new units visible to debug triggers; add a PMU
event for the feature; keep exception and mispredict/flush paths precise.

**Don't.** Add hidden state that trace/debug cannot observe — it becomes un-diagnosable on silicon.

---

## 7. Power, area & security

**Do.** Budget area/power from early synthesis reports; add functional clock-gating (and power-only
gates with `IS_FUNCTIONAL==0`), retention/isolation cells via `tc_pwr` for new domains; honor the
protection model (PMP `core/pmp/`, PMA/region rules validated in `check_cfg`) whenever a change touches
memory permissions, address masking, or privilege.

**Don't.** Leave a new block always-on, or bypass PMP/PMA checks for a "fast path."

---

## 8. Documentation & reproducibility

**Do.** Update `docs/03_cva6_design/` (pipeline docs), this or the relevant `agents/guides/*` file, and
any synthesis/P&R constraints or scripts. Record the area/power/timing impact so physical-design,
software, and verification partners can integrate without rediscovery.

---

## Practical workflow when adding a feature

1. **Model first** — behavioral/FPGA prototype to lock semantics.
2. **Config-gate** — add the `cva6_cfg_t` field + `check_cfg` assert (default off).
3. **RTL at a seam** — implement behind the gate; prefer CVXIF/`tech_cells_generic`; keep `always_ff`/
   `always_comb` split and the async-active-low reset.
4. **Verify + DFT in parallel** — directed tests, compliance regression, coverage/formal; thread
   `test_en_i`/`testmode_i`; plan MBIST for new SRAM.
5. **Observe** — RVFI probes + PMU event + debug-trigger visibility.
6. **Synthesize early and often** — fix timing/area incrementally; note critical/high-activity nets.
7. **Ecosystem** — `.dts`/OpenSBI/Linux/toolchain in step; capability bit for new instructions.
8. **Document** — design docs, guide, constraints; record area/power/timing.

## Cost-driver quick reference

| Anti-pattern | Consequence |
|---|---|
| Hard-coded values vs `CVA6Cfg` | Full-core re-verify/re-synth; +30-100% eng time |
| Broken module boundaries / stage coupling | Timing-closure and floorplan pain, extra P&R spins |
| Verification/compliance/DFT skipped | Late (post-synth / silicon) bugs, very expensive |
| High fanout / long comb paths / no early synth | P&R respins, larger die, worse power, un-routable |
| New instr/CSR w/o encoding, discovery, docs | Breaks OpenSBI/Linux/toolchain; software delay |
| Over-scoped OoO / wide vector / heavy speculation | 3-10x effort, project risk |
| Advanced node without PDK access / analog plan | Mask cost blowup, design won't close |
| Undocumented changes | Communication overhead, repeated mistakes |

## Invariants (must remain true after any edit)

- Minimal configs still elaborate and synthesize; the feature is off by default.
- No new latch (outside `tc_clk_gating`), no new clock/async-reset without CDC review.
- All memory via `tc_sram`, all gating via `tc_clk_gating`; `test_en_i`/`testmode_i` preserved.
- Compliance regression green; new directed tests + a PMU event + RVFI visibility present.
- `.dts` ↔ config ↔ spec remain aligned; new instructions gated by a discoverable capability bit.
