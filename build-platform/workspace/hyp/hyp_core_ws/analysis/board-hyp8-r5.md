# board-hyp8-r5.md — fifth structural board of the hyp8 core tree (the seven deferred items)

<!-- hyp8-status -->
> **Status: measured structural reading, indicative.** `sv-timing analyze --all-modules --stages
> --param-map inputs/param-map-hyp8.json --width-map inputs/width-map.json
> --target-mhz 5000 --fo4-ps 20 --budget-margin 0.2 --assume-xlen 64 --package-mode packages` on
> `inputs/hyp8-core.f` (delay-v44). Structural FO4 is the serial statement-order estimate
> deflated by path_class; it still over-reads sequential patch chains and NR:1 selects.
> Not STA. No simulation, STA, synthesis or boot has been run.
>
> This round implemented the seven step-4-deferred items under the
> correctness-seeking-draft policy: each keeps its original cone as a
> `// pragma translate_off` reference (or an equivalence assertion) beside
> the restructured form; contract changes are recorded as decisions rows
> and boot-hazards H33–H39. Silent-bug risk is acknowledged, not removed —
> only lint + structural evidence exists.

- Raw: `<prov>/boards/hyp8-core/analyze-r5.json`; emit:
  `<prov>/emit/hyp8-core-r5` (`correct --all-modules --stages --emit`,
  **275 edits**, latency-neutral only; emit's own reading reports
  max_path 124.1→124.1, `post_closes=false`, dens=178).
- Modules with paths: **262**; over 8 structural FO4: **176**; failing
  paths (>8): **4833**; over 9.6 (8×1.2): **4420** (r4: 4958 / 4551).
- Worst: `g6lc_ai_exec` 283.0 (AS-IS accelerator, outside the redesign
  cone — not silently closed).

## The seven items — implemented form, added cycles, r4→r5

| # | module | r4 | r5 | implemented form | added cycles | equivalence / assert location |
|---|---|---|---|---|---|---|
| 1 | g6lc_iq_bank (SEL) | 86.7 | **85.5** | Per-entry tag compare vs real-WB + xbar + spec-select tags is registered into `rsX_rdy`/`rsX_spec` at the clock edge (wakeup CAM stage). Spec wakeups for classes with L≥2 arm the countdown one cycle earlier so the registered bit lands on the publish cycle. Narrow same-cycle bypass kept for `LAT_ALU_LOW` only (`NTAKE` ALU-low tags). Replay re-arm uses the registered path. | real-WB wakeup +1 (value: PRF data already published); replay re-arm +1; spec-class select cycle unchanged (countdown −1); ALU-low bypass keeps distance 1 | translate_off reference + assertion in `g6lc_iq_bank.sv` (registered rdy vs same-cycle compute at the bypass cycle); `absorb SEL by=spec-wakeup` cond text updated and re-verified |
| 2 | g6lc_iq_arb (ARB) | 63.1 | **65.9** | Registered cross-bank age matrix `older_q[i][j]` (1 ⇒ i older than j): set for all live i when slot j allocates, cleared when a slot frees, all-zero at reset. Tournament is one-hot AND/OR over matrix bits; FP read-port reservation and hold-until-ack unchanged. | 0 (decision moved to allocation time) | assertion: `older_q[i][j] == ooo_age_older` whenever both candidates valid; same-hart circular-age order and cross-hart tie rule unchanged |
| 4 | g6lc_rename_recover | 74.7 | **47.9** | Per-checkpoint `slot_of_level`/`ckpt_sel_q` table written at push with `{hart, slot}` + ring index; mispredict restore is a one-hot select by checkpoint level (out-of-range clamps to slot 0 as before); pop/flush advances the table with ring head/count. | 0 | assertion: arithmetic `sel_level/sel_hart/sel_take` equals table selection on every `mispredict_i` |
| 6 | wt_dcache_wbuffer | 124.1 | **124.1** (W3 11.6 / W2 124.1) | W2 keeps evict/return decision, patch select, `rtrn_*`, `tx_stat_d`, evict legality; W3 does the coalesce byte-merge + `wbuffer_d` write. W3 pending record exported as the youngest pending entry (forward visibility preserved); a W3-pending wtag holds eviction (one compare). | +1 store acceptance→array visibility; forwarding +0 | translate_off reference: single-cycle W2 next-state on W3-aligned inputs equals the W3 write; H33 hazard row |
| 7 | alu (A3) | 58.7 | **71.1** (A2 30.9 / A3 28.1) | `LAT_ALU_FULL` → 3: A3 carries the second shifter level, compare finalize, and result mux for shifts/compares/SLT/min-max/bitmanip; add/logic finish at A2; A1-low forward unchanged. `hyp_lat_cycles`/class table, IQ countdown, WB reservation window, FLU lane records updated; `AluStages=3` semantics documented. | +1 shift/compare dependent distance (rank 5, recorded as H34) | assertion: original A2 result for shift/compare ops equals the A3 result one cycle later |
| 10 | csr_regfile | 66.6 | **66.6** | Two-phase writer preserving statement order: phase A split into 15 address-exclusive `csr_wr_*` always_comb blocks writing disjoint `*_w` nets (fp/dbg/trig/vs/ip/s/stc/mstat/envcfg/h/m/ctr/pmp/acc/dflt); sidebands bank-local + OR-merged. Phase B reads `*_w` and applies trap entry / xRET / interrupt / debug / counters / post-write overrides in original order. | 0 | original monolithic writer kept under translate_off as `csr_update_ref`; every `*_d` output asserted equal cycle-by-cycle |
| 11 | load_unit | 92.4 | **77.2** | 4-bit encoded FSM → 10-bit one-hot `state_q` (`LU_B_*` indexes, `LU_S_*` literals); per-state case arms and one-hot transition literals; request issue cycle unchanged; no registered-fact flags needed (FSM self-contained). | 0 | translated-off encoded reference `state_d` asserted equal to the one-hot decode every cycle; `$onehot` mutual-exclusion under the existing `ifndef` |

Residual causes after the split: the r5 module worst for `csr_regfile`
(66.6) is now the verbatim phase-B trap-entry/xRET/interrupt override
cone (`csr_regfile.sv:3608` region — dense last-writer chain, real
serial depth, not the case arms); `wt_dcache_wbuffer` W2 keeps the
rtrn-id decode→record-read→evict-legality fold; `alu` worst is a
cross-stage billed path (A2→A1) at the A2 result mux; `iq_bank` SEL and
`iq_arb` ARB residuals are the decision cones themselves (covers
declared); `load_unit` residual is the FSM dependency floor (L5 55.6).

## r1 → r5 per-module history (target list)

| module | r1 | r2 | r3 | r4 | r5 | note |
|---|---|---|---|---|---|---|
| sb_commit_bundle | 128.4 | 135.2 | 124.8 | 27.4 | 27.4 | r4 drop = config pruning (MixedSmt dead) |
| trigger_module | 129.4 | 129.4 | 136.0 | 79.2 | 79.2 | serial write-FSM fold, real |
| wt_dcache_wbuffer | 146.8 | 112.4 | 122.1 | 124.1 | 124.1 | W3=11.6; W2 fold remains |
| multiplier | 132.6 | 93.2 | 93.2 | 52.0 | 52.0 | unstaged clmul cone is the worst |
| g6lc_thread_select | 88.1 | 88.1 | 68.3 | 13.0 | 13.0 | single-hart pruning |
| g6lc_iq_bank | 177.2 | 86.7 | 86.7 | 86.7 | 85.5 | registered CAM in place |
| g6lc_rename_recover | 86.3 | 86.3 | 74.7 | 74.7 | 47.9 | slot_of_level table |
| g6lc_rename_read | 77.3 | 77.3 | 76.0 | 49.6 | 49.6 | banked picks (r4) |
| store_buffer | 88.4 | 77.1 | 77.1 | 29.1 | 29.1 | StoreFwdCycles=3 pruning |
| instr_realign | 73.2 | 73.2 | 60.9 | 54.2 | 54.2 | carry-bank recurrence, real |
| instr_queue | 72.0 | 72.0 | 46.1 | 46.4 | 46.4 | gather-mux arm billing |
| load_unit | 69.2 | 69.2 | 69.2 | 92.4 | 77.2 | one-hot FSM; L5 floor 55.6 |
| csr_regfile | 66.6 | 66.6 | 66.6 | 66.6 | 66.6 | phase-B override cone remains |
| g6lc_lsq | 105.7 | 66.1 | 73.2 | 92.5 | 92.5 | merged-cone billing |
| alu | 64.5 | 64.5 | 64.5 | 58.7 | 71.1 | A3 added — module worst moved to a cross-stage billed path |
| g6lc_iq_arb | 146.9 | 63.1 | 63.1 | 63.1 | 65.9 | age matrix in place |
| g6lc_decode_s3 | 179.7 | 55.8 | 55.8 | 53.7 | 53.7 | interrupt priority chain, real |
| sb_lifecycle | 95.4 | 52.0 | 52.0 | 28.9 | 28.9 | per-slot writer + pruning |
| issue_read_operands | 79.5 | 48.9 | 48.9 | 34.5 | 34.5 | |
| g6lc_ooo_dispatch | 210.4 | 30.3 | 30.3 | 27.3 | 27.3 | |
| g6lc_tlb | 84.7 | 40.8 | 40.8 | 40.8 | 40.8 | |
| id_stage | 134.5 | 43.9 | 43.9 | 38.3 | 38.3 | |
| stb_fwd | 202.5 | 33.4 | 33.4 | 33.4 | 33.4 | |
| sb_head | 135.0 | 22.8 | 22.8 | 22.8 | 22.8 | |

## Per-stage table (`--stages`; in-stage vs 8-FO4 budget)

| module.stage | cyc/win | worst in-stage | vs budget | worst into-stage (from) |
|---|---|---|---|---|
| alu.A1 | 1/0 | 13.2 | ! | 71.1 (-) |
| alu.A2 | 1/0 | 30.9 | ! | — |
| alu.A3 | 1/0 | 28.1 | ! | 30.9 (-) |
| branch_unit.B1 | 1/0 | 13.0 | ! | — |
| branch_unit.B2 | 1/0 | 23.8 | ! | — |
| csr_decode.C1 | 1/0 | 9.8 | ! | — |
| csr_read.C2 | 1/0 | 6.9 | ok | — |
| csr_write.C3 | 1/0 | 7.0 | ok | — |
| g6lc_bp_tage.P1 | 1/0 | 3.5 | ok | — |
| g6lc_bp_tage.P2 | 1/1 | 7.5 | ok | — |
| g6lc_fe_nextline.NL | 1/0 | 12.1 | ! | — |
| g6lc_iq_arb.ARB | 1/0 | 65.9 | ! | — |
| g6lc_iq_bank.SEL | 1/0 | 85.5 | ! | — |
| g6lc_lsq_cam_bank.C | 1/0 | 40.8 | ! | — |
| g6lc_lsq_event.E | 1/0 | 29.0 | ! | — |
| g6lc_lsq_reduce.R | 1/0 | 38.2 | ! | — |
| g6lc_lsq_verdict.V | 1/3 | 24.6 | ! | — |
| g6lc_ooo_dispatch.ISS | 1/0 | 26.2 | ! | 27.3 (-) |
| g6lc_rename_resolve.RR | 1/0 | 41.7 | ! | — |
| g6lc_tlb.T1 | 1/0 | 11.3 | ! | — |
| g6lc_tlb.T2 | 1/0 | 12.7 | ! | 32.8 (-) |
| id_stage.D1 | 1/0 | 8.0 | ok | — |
| id_stage.D2 | 1/0 | 0.0 | ok | — |
| id_stage.D3 | 1/0 | 7.0 | ok | 38.3 (-) |
| load_unit.L2 | 1/0 | 5.0 | ok | 71.5 (-) |
| load_unit.L3 | 1/0 | 2.8 | ok | — |
| load_unit.L4 | 1/0 | 7.4 | ok | 77.2 (-) |
| load_unit.L5 | 1/0 | 55.6 | ! | 60.5 (-) |
| multiplier.S1 | 1/0 | 17.6 | ! | 24.9 (-) |
| multiplier.S2 | 1/0 | 16.2 | ! | — |
| multiplier.S3 | 1/0 | 16.2 | ! | — |
| multiplier.S4 | 1/0 | 16.2 | ! | — |
| multiplier.S5 | 1/0 | 16.2 | ! | — |
| multiplier.S6 | 1/0 | 3.5 | ok | — |
| multiplier.S7 | 1/0 | 18.5 | ! | — |
| multiplier.S8 | 1/0 | 8.9 | ! | 8.9 (S7) |
| sb_commit_bundle.CB | 1/0 | 27.4 | ! | — |
| scoreboard.RDY | 1/0 | 0.0 | ok | — |
| stb_fwd.F1 | 1/0 | 25.6 | ! | — |
| stb_fwd.F2 | 1/0 | 24.3 | ! | — |
| stb_fwd.F3 | 1/0 | 33.4 | ! | — |
| trigger_module.TAC | 1/0 | 3.5 | ok | — |
| trigger_module.TMA | 1/0 | 79.2 | ! | — |
| trigger_module.TWR | 1/0 | 78.9 | ! | — |
| wt_dcache_wbuffer.W1 | 1/0 | 12.4 | ! | — |
| wt_dcache_wbuffer.W2 | 1/0 | 124.1 | ! | 21.9 (W1) |
| wt_dcache_wbuffer.W3 | 1/0 | 11.6 | ! | — |

Stage-budget pass/fail: in-stage ≤ budget **13/47** (r4: 13/45 — the
two new stages A3 28.1 / W3 11.6 do not pass yet; W3 is near-budget).
Into-stage ≤ (1+window)×8: **0/11 measured** — every into-reading is an
unstaged `-` or cross-stage feed at window=0; no `window>0` stage
carries a measured into-path violation.

## Bubble-up verdicts (r5; absorb covers re-verified after the registered CAM)

36 stage rows: **32 covered, 4 absorbed, 0 drag.** Requirement "0 drag"
met. The A3 and W3 stage additions are value-class and report `covered`.

| stage | verdict | cover | finding |
|---|---|---|---|
| g6lc_fe_nextline.NL | absorbed | read-ahead | verified — `line_taken_q <= ltaken_q[rd_idx]` |
| g6lc_iq_bank.SEL | absorbed | spec-wakeup | **verified after the registered CAM** — cond: "registered wakeup CAM (rsX_rdy/rsX_spec): producer latency class fixed and countdown shifted −1 so the registered rdy lands on publish; LAT_ALU_LOW keeps the same-cycle distance-1 arm; LAT_NONSPEC producers wake on the registered real-WB capture (+1); replay re-arms" |
| g6lc_iq_arb.ARB | absorbed | spec-wakeup | `unverified-cover` — countdown lives in sibling iq_bank (unchanged) |
| g6lc_ooo_dispatch.ISS | absorbed | spec-wakeup | verified — re-arm/replay state in-module |
| all others (32) | covered | — | value-class waits absorbed by OoO issue |

## Residuals (billed chain; artifact vs real classification)

- **Real serial dependency**: `trigger_module` TWR 78.9 / TMA 79.2
  (serial write-through + match prefix); `wt_dcache_wbuffer` W2 124.1
  (rtrn select→record read→evict legality fold); `csr_regfile` phase-B
  override cone 66.6 (trap-entry/xRET/interrupt last-writer chain —
  the case-arm split did not touch it, and ordering forbids splitting
  it further); `load_unit` L5 55.6 (FSM dep floor); `sb_commit_bundle`
  CB 27.4; `g6lc_decode_s3` 53.7; `g6lc_rename_resolve` RR 41.7;
  `instr_realign` carry-bank recurrence 54.2.
- **Decision cones (no register allowed, covers declared)**:
  `g6lc_iq_bank` SEL 85.5, `g6lc_iq_arb` ARB 65.9, `g6lc_ooo_dispatch`
  ISS 26.2.
- **Compressor / CPA depth (real arithmetic)**: multiplier S1 17.6,
  S2–S5 16.2, S7 18.5, S8 8.9; module worst 52.0 = unstaged clmul.
- **Cross-stage billed path**: `alu` module worst 71.1 is an A2→A1
  attributed path at the A2 result mux (the A3 split moved the module
  maximum from A2's 58.7 to this cross-stage reading).
- **Bundle makespans / merged-cone billing**: `g6lc_lsq` 92.5,
  `g6lc_iq` 121.0 (wrapper over bank cones), `stb_fwd` F1–F3,
  `store_buffer` 29.1, `sb_lifecycle` 28.9.
- **Out of cone / vendored**: `g6lc_ai_exec` 283.0, `fpnew_fma_multi`
  133.4, `fpnew_fma` 102.6, `fpnew_cast_multi` 91.6, `hpdcache_ctrl_pe`
  76.6, `norm_div_sqrt_mvp` 66.8, `g6lc_bp_ckpt` 61.8, `g6lc_shared_tlb`
  54.0, `macro_decoder` 52.9, `serdiv` 52.8, `bht` 52.5, `g6lc_ptw` 43.1.

## Verilator status (both trees, final RTL)

- `g6lc_core` (top `g6lc_core`, Flist_core.vlt, verilator 5.008, repo
  `-Wno-*` set): **0 errors / 444 warnings** — same total as r4
  (WIDTHEXPAND ~218, LITENDIAN 121, WIDTHTRUNC 54, IMPLICIT 18,
  LATCH 11, CMPCONST 7, WIDTHCONCAT 4, UNSIGNED ~5, SELRANGE 2,
  SYMRSVDWORD 1, PINMISSING 1; MULTIDRIVEN 0).
- `g6lc_soc` (top `g6lc_soc`, Flist_apu.vlt): **0 errors / 31 warnings**.
- Warning count returned to the r4 baseline of 444 after repair of the
  transient additions (csr malformed decls / missing `rf_*`, load-unit
  enum literals, ref-region width casts); LATCH count unchanged at 11
  with the CSR PMP `index` warnings renamed to match.

No simulation, STA, synthesis or boot has been run; all FO4 figures are
the delay-v44 structural estimate only. The equivalence assertions are
lint-parsed only — they have not been simulated.
