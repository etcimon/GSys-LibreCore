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

### Continuation: overflow ownership correction

Stored FIFO occupancy is not the number of unresolved branches once pushes have
been dropped. Ordinary pop-to-empty must not clear desynchronization: a dropped
branch can still resolve and consume a later snapshot. `g6lc_bp_ckpt` retains its
existing desync bit until explicit restore/reset/flush. This supersedes the older
“until the bank drains” wording below and in historical source comments.

`review-ckpt-before-20260916` fails new cases 5/6 with
`CKPT_DROPPED_OWNER`/`CKPT_EMPTY_POISON`. The after run passes seven positives and
five expected-failure controls; default one-hart leaf synthesis has zero check
problems/no latches. No state, port, pipeline, clock/reset or ISA/DTS addition.
The clear condition changes a local control input, not the prediction datapath;
no mapped timing/area/power claim follows. Tests remain leaf-scoped. A consumed
CF is not automatically a future resolved CF across replay, kill and hart switch;
full snapshot membership/phase and out-of-order resolution remain open. The
integration comparator reassessment in `architecture/remaining-upgrade-sequence.md`
also supersedes unconditional preservation claims based on collapsed/multiset
traces. Architectural resolution is never filtered to accommodate a predictor.

### Broad-review counter repair and limits

`g6lc_bp_tage` now uses a twelve-bit decay counter for the documented 4096 accepted
updates. The old sixteen-bit counter missed the second scheduled decay. Directed
reset/debug/flush/update tests and prediction-output equivalence qualify this
latent contract fix. Useful writes remain tied off by `t_weak=0`, and allocation
does not consult usefulness; do not market the repair as an accuracy or physical
state saving. The small mapped fixture has unchanged state (89 cells).

The 2026-09-17 context-ownership pass resolved per-slot lookup-update
association and fetch-hart vs resolve-hart history use:

- `g6lc_bp_tage`/`g6lc_bp_ittage` hash each fetch slot's own PC
  (`vpc_i + i*instr_size`) for base row/column and tagged index/tag, so an
  unaligned RVC window no longer misattributes entries across slots, and a
  tagged hit predicts only its own slot rather than broadcasting to the whole
  window. The base-table row index previously overlapped the column bits and
  non-RVC updates always wrote column 0.
- `g6lc_bp_ghist` gained `folded_train_o`, the fold of the resolve/train
  hart's bank; `g6lc_bp_tage`/`g6lc_bp_ittage` consume it through a new
  `folded_update_i` port so update index/tag use the resolving branch's own
  history instead of the live fetch fold. `g6lc_bp_tage_table` lookup ports
  are per-slot arrays (`NR_LOOKUPS`).
- Directed evidence: `review-tage-ctx-v2` 10/10 (opposing-branch window,
  update-fold ownership, unaligned base and ITTAGE addressing, banked-GHR
  fold split) with live negatives; decay suite re-verified 6/6 across all
  three geometries.

The 2026-09-17 prediction-checkpoint pass made `g6lc_bp_ckpt` a true
prediction-time, branch-correlated snapshot FIFO:

- Push moved from resolve to predict: `bp_push_cf[i]` counts every consumed
  slot carrying a *decoded* CF (`is_branch|is_jump|is_jalr|is_return`, not the
  predicted cf_type), so the push set equals the resolve set and the FIFO head
  is always the resolving branch's own entry. `pop_i` is any CF resolve
  (`cf_type != NoCF`); `restore_i` (mispredict) consumes the head and drops
  every younger wrong-path push. Same-cycle full push+pop now advances the
  head exactly once — the pop frees the slot the push takes.
- The snapshot is `{live fetch-hart GHR, RAS stack}` at predict time. The TAGE/
  ITTAGE update folds hash it via `fold_src`/`folded_src_o` (ckpt head when
  valid, else the live train-hart bank — which is also the `BPCkptDepth==0`
  fallback), so `t_uindex`/`t_utag` now match the context the prediction used
  rather than the resolve-time fold. RAS restore receives the predict-time
  stack, so wrong-path RAS pushes/pops are actually undone.
- The arch-only GHR bank needs no restore — it only ever holds resolved
  outcomes, so the actual outcome shifts in on every branch resolve including
  mispredicts, and the old stale-head GHR write is gone.
- Overflow is honest: a full bank refuses the push and raises `desync_o` until
  it drains; restore is unqualified meanwhile and the fold falls back.
- Residuals: all slots of one window share the window-start RAS snapshot (an
  older same-window CF's own RAS op is absent from a younger sibling's entry —
  bounded over-restore, self-heals), and a CF whose fetch-time decode missed
  the `is_*` set but resolves non-NoCF (e.g. ZCMT) over-pops one entry until
  the next drain.
- Directed evidence: `review-ckpt-v2` 8/8 (conservation, full-window push+pop
  single head advance, restore-drains-younger, overflow desync, ordering; live
  negatives CKPT_MULTI/CKPT_DOUBLE_ADV/CKPT_DESYNC_RV).
- Integration evidence: `review-int-ckpt-v3` 24/24 — smt2 13/13 cycle-identical
  (BHT config, ckpt path inert), stream8 11/11 matched with
  `timingLegibleDivergence` (rdcycle reads and spin-tail length shift under
  better predictions; PC/encoding stream, `load`/`store`/`data_req` counts and
  cookies identical). The integration comparator now splits a PC/encoding-only
  `retirementArchPC` digest from value-bearing digests and splits report fields
  into arch-binding vs timing-legible (`roi_cycles`, cache-miss counters), so
  legal predictor-timing changes classify instead of fail — a real
  instruction-stream divergence still fails `matchedBaseline`.

### T21 (2026-10-10): checkpoints are addressed by the branch, not by order

The order-paired FIFO above is superseded (`core/ooo/AGENTS-ooo-plan.md` T21).
The out-of-order backend resolves a ready younger branch before an older one,
and the SMT drained handoff kills consumed-unissued CFs without `flush_bp`, so
"head == resolving CF" failed on 26.6 % of resolves and 55.9 % of restores on
the server boot core. `g6lc_bp_ckpt` now allocates per consumed CF slot and
returns a tag `{epoch, index}` that rides in `branch_predict.ckpt_idx`
(IQ → decoder → scoreboard → branch unit → `bp_resolve_t`); a resolve frees its
own entry and the TAGE/ITTAGE update folds *that* entry's GHR; a mispredict
restores from it and reclaims every younger entry; a non-mispredict IF flush
(`clear_i`) restores the fetch hart's RAS from the oldest live entry (the
restart frontier) and drops the bank; a full bank refuses the window
(`ckpt_v = 0`, fallback) instead of desyncing. `ras.sv` is a pointer stack whose
checkpoint is `{tos, cnt, ra[tos]}` with the resolving CF's own push/pop
re-applied on restore; an empty stack presents `ra = 0` (`ras_empty_zero`) —
the branch unit depends on it for an unpredicted return. Leaves
`REVIEW_RTL_CKPT` / `REVIEW_RTL_RAS`; integration witness `[ckpt] final`
(`pop_mismatch = restore_mismatch = 0`). The "out-of-order resolution remains
open" residual above is closed; the same-window residual (an unpredicted
indirect call's push missing from a younger sibling's snapshot) remains and
self-heals.

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
