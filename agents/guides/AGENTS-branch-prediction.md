# Guide: Branch Prediction

Feature-addition playbook for control-flow speculation in the CVA6 frontend. Read `../../AGENTS.md`
first. Spec summaries live in `../spec/` (see `../spec/INDEX.md`).

## Table of contents
1. Spec grounding (why it is microarchitectural)
2. Code map (`file:line`)
3. Config knobs
4. Feature-addition playbook
5. `.dts` linkage
6. Invariants and pitfalls

## 1. Spec grounding
Branch prediction has **no normative section**; the ISA fixes only control-transfer *results*. The
relevant anchors are therefore indirect: `specs/riscv-spec.html#rv32` (2.1, JAL/JALR/branch
semantics the predictor must reproduce), `#ext:zifencei` (4.1, FENCE.I — after self-modifying code
the predictor/fetch must observe new instructions), `#unpriv-cfi` (4.17) and `#priv-cfi` (6.9, CFI
landing pads / shadow stacks interact with call/return prediction), and `#smctr` (6.8, Control
Transfer Records — a taken-branch/call/return log that a predictor's classification aligns with).
Sub-files: `../spec/riscv-spec-I-2.1-rv32i.html`, `-I-4.1-zifencei.html`, `-I-4.17-cfi.html`.

## 2. Code map
- Live frontend: `core/fetch_B/frontend.sv`; `core/fetch_A` is historical, not the feature-edit target.
- Predictor structs: `frontend.sv:95+`; prediction arrays and saved carry hints `154+`.
- Current response transaction: `realigner_vaddr` / `realigner_data` at `248+`.
- RVC hint shifting: `gen_prediction_shifted` at `318+`; a carried first half uses saved `bht_q`/`btb_q`.
- Control-flow classification and lower-most prediction priority: `330+`, `350+`.
- Resolution-driven BHT/BTB training: `864+`; ownership routing does not suppress architectural resolution.
- Lookup PC phase and provider selection: `1027+`; BHT, GSHARE and TAGE use `vpc_bht`, BTB/ITTAGE use `vpc_btb`. The PH_BHT port retains its separate registered-PC connection.
- Predictors: `core/frontend/{bht,bht2lvl,btb,ras}.sv`, `g6lc_bp_{top,tage,gshare,loop,ittage,statcor,ckpt,ghist}.sv`.
- Resolution source: `core/branch_unit.sv`; architectural flush control: `core/controller.sv`.
- Current contracts and scoped evidence: `architecture/core-fetch/SPEC.md` §6 and `architecture/core-fetch/README.md`.

## 3. Config knobs (`core/include/config_pkg.sv`)
- `bp_type_t` (`BHT`, `PH_BHT`, `GSHARE`, `TAGE_LITE`); selected by `BPType`.
- `BTBEntries`, `BHTEntries`, `BHTHist`, `RASDepth`, and the optional `BP*` fabric fields.
- `BPStatCorEn` gates the statistical corrector; `FpgaEn`/`FpgaAlteraEn` determine existing lookup phase.
- `RVC` changes `INSTR_PER_FETCH` and the prediction-shift path.
- Legality remains in `check_cfg`, including supported RAS depth and power-of-two/zero table sizes.

## 4. Feature-addition playbook
To add a predictor (for example gshare or TAGE), the change is config-first. Extend `bp_type_t` in
`core/include/config_pkg.sv` with the new kind, add sizing fields, and add matching `check_cfg`
assertions; then set the value in the per-target packages under `core/include/cv*_config_pkg.sv`.
Implement the predictor as a new module in `core/frontend/` mirroring the existing port shape,
instantiate it in `core/fetch_B/frontend.sv` under a `generate` gated on `CVA6Cfg.BPType`,
and drive the existing prediction arrays without adding opcode-specific downstream exceptions.
Match lookup metadata to the transaction being classified and training metadata to the resolving
instruction, including ownership and lifetime. State whether learned values represent absolute
outcomes, relative errors or confidence; consuming one as another is a semantic defect. Keep every
new structure elaboration-gated so disabled/minimal configurations still compile. Preserve the
legacy FPGA phase unless a separate memory-interface change is explicitly validated.

### Broad-review counter repair and limits

`g6lc_bp_tage` now uses a twelve-bit decay counter for the documented 4096 accepted
updates. The old sixteen-bit counter missed the second scheduled decay. Directed
reset/debug/flush/update tests and prediction-output equivalence qualify this
latent contract fix. Useful writes remain tied off by `t_weak=0`, and allocation
does not consult usefulness; do not market the repair as an accuracy or physical
state saving. The small mapped fixture has unchanged state (89 cells).

Next accuracy work must resolve per-window/per-slot lookup-update association,
fetch-hart vs resolve-hart history use, and prediction-time checkpoint ownership.
Source presence of TAGE/loop/SC/ITTAGE does not qualify their combined semantics.
Keep matched branch-pattern/alias controls and the protected SMT2 baseline.

## 5. `.dts` linkage
Branch prediction is not device-tree visible: it is pure microarchitecture and changes no
architectural state. It appears only implicitly through the CPU node's `compatible`/model and, if a
CTR log is exposed, through the `#smctr`-related privileged CSRs rather than a DT property. Do not
add DT nodes for it.

## 6. Invariants and pitfalls
The transparency invariant is absolute: a prediction must never alter an architectural result;
divergence is corrected only by `resolved_branch_i` plus a `controller.sv` flush. Watch the RVC
unaligned case where a carried instruction reuses a saved prediction; the RAS is corrupted if
push/pop fire on non-consumed instructions; and table sizes must satisfy `check_cfg`.

The 2026-09-16 corrector repair uses the same three-bit absolute-outcome counters:
0/1 overrides to not-taken, 6/7 to taken, and 2..5 defers. Invalid predictions are
preserved, flush wins over training and counters saturate. Aliased indices share
state intentionally; passing these semantics does not prove prediction accuracy
or per-hart isolation. `verif/tb/core/tb_g6lc_bp_statcor.sv` independently checks
these rules, with an injected-error control and multiple slot/RVC geometries.

Qualification includes an extracted-selector SAT check with a wrong-PC negative,
SMT2 RVI/mixed-C integer reference checks, broader stream8 work and full-core
synthesis smoke. The corrector costs 99 additional generic leaf cells with no
state growth; physical timing/power and broader firmware/ISA qualification remain
open. A throughput gain is workload-scoped, not a claim of whole-core PPA sign-off.
