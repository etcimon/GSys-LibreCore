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
- Predictor struct types: `core/frontend/frontend.sv:71-91` (`bht_update_t`, `btb_prediction_t`, `btb_update_t`, `ras_t`).
- Registered last-cycle predictions: `core/frontend/frontend.sv:104-105`; prediction arrays `139-143`.
- RVC unaligned prediction shifting: `core/frontend/frontend.sv:180-197`.
- Control-flow classification: `core/frontend/frontend.sv:210-221` — branch->BHT, call/return->RAS, immediate jump resolved inline, `jalr`->BTB.
- Prediction selection/priority (lower-most wins): `core/frontend/frontend.sv:236-294`; RAS push/pop only when instruction consumed `261,290`.
- Mispredict detect: `core/frontend/frontend.sv:308` (`resolved_branch_i.valid & .is_mispredict`); BHT/BTB update `324+`.
- Predictor modules: `core/frontend/bht.sv` (bimodal), `core/frontend/bht2lvl.sv` (PH_BHT, private-history 2-level), `core/frontend/btb.sv` (BTB), `core/frontend/ras.sv` (RAS).
- Resolution source: `core/branch_unit.sv` computes taken/target -> `resolved_branch_i` (EXECUTE).
- Flush/redirect: `core/controller.sv` on mispredict.

## 3. Config knobs (`core/include/config_pkg.sv`)
- `bp_type_t` enum `39-42` (`BHT`, `PH_BHT`); selected by `BPType` `251`.
- `BTBEntries` `249`, `BHTEntries` `253`, `BHTHist` `255`, `RASDepth` `247`.
- `RVC` changes `INSTR_PER_FETCH` and the prediction-shift path.
- Legality: `check_cfg` `448-450` (`RASDepth>0`; `BTBEntries`/`BHTEntries` power-of-two or 0).

## 4. Feature-addition playbook
To add a predictor (for example gshare or TAGE), the change is config-first. Extend `bp_type_t` in
`core/include/config_pkg.sv` with the new kind, add sizing fields, and add matching `check_cfg`
assertions; then set the value in the per-target packages under `core/include/cv*_config_pkg.sv`.
Implement the predictor as a new module in `core/frontend/` mirroring the port shape of
`core/frontend/bht2lvl.sv`, instantiate it in `core/frontend/frontend.sv` under a `generate` gated on
`CVA6Cfg.BPType`, and drive the existing `bht_prediction`/`btb_prediction` arrays
(`frontend.sv:139-143`) so the downstream selection logic (`236-294`) is untouched. Feed training
from the resolution path (`resolved_branch_i` at `frontend.sv:48`) into the update logic (`324+`).
The classification stage (`210-221`) is predictor-agnostic and should not change. Keep every new
structure elaboration-gated so a zero-sized predictor still compiles.

## 5. `.dts` linkage
Branch prediction is not device-tree visible: it is pure microarchitecture and changes no
architectural state. It appears only implicitly through the CPU node's `compatible`/model and, if a
CTR log is exposed, through the `#smctr`-related privileged CSRs rather than a DT property. Do not
add DT nodes for it.

## 6. Invariants and pitfalls
The transparency invariant is absolute: a prediction must never alter an architectural result;
divergence is corrected only by `resolved_branch_i` plus a `controller.sv` flush. Watch the RVC
unaligned case (`180-197`) where the upper prediction of the previous fetch is reused; the RAS is
corrupted if push/pop fire on non-consumed instructions (guarded at `261,290`); and BTB/BHT sizes
must stay powers of two or the `check_cfg` assertion trips.
