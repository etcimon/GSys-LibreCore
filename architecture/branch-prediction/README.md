# Extension point: branch prediction

Authoritative playbook: `../../agents/guides/AGENTS-branch-prediction.md`. Spec grounding:
`../../agents/spec/` (`riscv-spec-I-2.1-rv32i.html`, `-I-4.1-zifencei.html`, `-I-4.17-cfi.html`).

## Intent
Grow predictors without disturbing the fetch/classification datapath: gshare, TAGE, loop, ITTAGE,
statistical corrector, checkpoints; improve BTB/RAS accuracy; observability.

## Current state (codebase — U1 landed)
| Component | Path | Config |
|-----------|------|--------|
| Legacy bimodal / 2-level | `core/frontend/bht.sv`, `bht2lvl.sv` | `BPType=BHT` / `PH_BHT` |
| BTB / RAS | `btb.sv`, `ras.sv` | `BTBEntries`, `RASDepth` |
| **U1 fabric** | `g6lc_bp_top.sv` + `cva6_bp_{gshare,tage,tage_table,loop,ittage,statcor,ghist,ckpt}.sv` | `BPType=GSHARE` \| `TAGE_LITE`, `BPGhistLen`, `BPTage*`, `BPLoopEn`, `BPIndirectEn`, `BPStatCorEn`, `BPCkptDepth` |
| Orchestration | `core/frontend/frontend.sv` | keeps `bht_prediction` / `btb_prediction` port contract |
| Resolve | `core/branch_unit.sv` → `resolved_branch_i` | |

Primary Linux target enables **TAGE_LITE** (and related knobs). `BPCkptDepth` supports U4 recovery.

## Sanctioned seam
Config-first: extend `bp_type_t` / sizing in `config_pkg.sv` + `check_cfg`, then modules under
`core/frontend/` behind `generate` on `CVA6Cfg.BPType`. Do not rewrite control-flow classification.

## Invariants
Prediction is transparent; only mispredict + `controller` flush correct architectural state.
Sizes power-of-two or 0; RAS only on consumed instructions.

## Status vs scaffold
**No longer scaffold-only for U1** — RTL is in `core/frontend/`. This directory remains the *map*
for further predictor growth (e.g. full TAGE-SC, multi-level BTB).
