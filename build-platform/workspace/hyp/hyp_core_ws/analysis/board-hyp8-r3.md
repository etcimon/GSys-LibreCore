# board-hyp8-r3.md — third structural board of the hyp8 core tree (stage-guided rework)

<!-- hyp8-status -->
> **Status: measured structural reading, indicative.** `sv-timing analyze --all-modules --stages
> --target-mhz 5000 --fo4-ps 20 --budget-margin 0.2 --assume-xlen 64 --package-mode packages` on
> `core/Flist.g6lc_hyp8` (delay-v44). Structural FO4 is the serial statement-order estimate
> deflated by path_class; it still over-reads sequential patch chains, atomic `*` ops, and
> NR:1 selects. Not STA. No simulation, STA, synthesis or boot has been run.

- Raw: `<prov>/boards/hyp8-core/analyze-r3.json`; emit:
  `<prov>/emit/hyp8-core-r3` (`correct --all-modules --stages --emit`,
  **568 edits**, latency-neutral only; max_path 283.0→283.0 — the residual
  cones are dependency-floor / NR:1-select billed, not BalanceMux-shaped).
- `instr_realign`/`instr_queue`/`g6lc_rename_read`/`g6lc_rename_recover`/
  `g6lc_lsq` were re-measured into the final `analyze-r3.json` after the
  post-board lint repairs (the earlier realign-r3.json snapshot read 30.1
  while the carry-bank block was temporarily missing — final value 60.9).
- Modules with paths: 261; over 8 structural: **176**; failing paths
  (>8 FO4): 5438.
- Worst: `g6lc_ai_exec` 283.0 (AS-IS accelerator, outside the cone).

## Rework results (target list, r2 → r3)

| module | r1 | r2 | r3 | restructured this round | residual class |
|---|---|---|---|---|---|
| sb_commit_bundle | 128.4 | 135.2 | 124.8 | one-hot sl_* vectors (r2) | NR:1 selects billed — real serial chain (decode→min-tree→gather→legality→tree→record) |
| trigger_module | 129.4 | 129.4 | 136.0 | TWR/TMA/TAC split (r2) | write-to-match coupling; TMA into-stage 136.0 from TWR — real serial dependency |
| wt_dcache_wbuffer | 146.8 | 112.4 | 122.1 | 13 `tx_stat_q[rtrn_id]` + 28 `wbuffer_q[rtrn_ptr]` dynamic reads hoisted to `rtrn_tx`/`rtrn_wb`; `use W2 on=` attributes the rtrn/evict cone to W2 honestly | real depth: rtrn-id decode→record read→evict legality→merge (W3 split authorized, deferred) |
| multiplier | 132.6 | 93.2 | 93.2 | S2_5 unrolled → explicit S2/S3/S4/S5 stage regions; clmul serial XOR fold → balanced pairwise XOR tree | S1 tile product `a_u * b_u[..]` billed atomic (model can't decompose `*`); one-stage `gen_one_stage` mul is config-dead for hyp8 |
| g6lc_thread_select | 88.1 | 88.1 | **68.3** | RR scan → per-candidate compare vectors + first-set one-hot + masked-OR gather + pairwise strict-`>` argmax tournament; `% NH` → conditional wrap; composed writer → p_policy/p_gate/p_drain/p_sel + per-field assigns | real serial priority chain (policy→uniss→t0→trap_hold→drain→hold); decision-class, no register allowed |
| g6lc_iq_bank | 177.2 | 86.7 | 86.7 | (already rank-0/1 maxed in r2) | wakeup compare→hit-OR→arm→cnt-select→entry update — real decision-cone depth |
| g6lc_rename_recover | 86.3 | 86.3 | **74.7** | clamped-level dynamic reads of `ckpt_hart_q`/`ckpt_head_q`/`ckpt_cnt_q` → one-hot `lvl_oh` decode + `mis_hart_g`/`head_m`/`cnt_m` masked-OR gathers over transposed columns | residual = independent-LHS bundle makespan 74.7 (wrap/clamp/`ckpt_slot` arithmetic remains a real serial chain) |
| g6lc_rename_read | 77.3 | 77.3 | **76.0** | pick chain → per-port `lone_p`/`taken_lt` one-hot links; per-lane always_comb; stall/reductions as independent cones; res_br_inc/res_pick as per-hart/per-port countones | real serial free-list allocation (each lane's pool excludes earlier lanes' takes); rank-parallel allocator possible next round |
| store_buffer | 88.4 | 77.1 | 77.1 | — | spec_fwd cone, independent-LHS bundle floor 68.9 |
| instr_realign | 73.2 | 73.2 | **60.9** | h→k nested match → per-(slot,halfword) crossbar `rl_sel` + masked-OR gathers; split→carry via last-set one-hot `rl_coh` | carry-bank recurrence cone (line 279, `carry_addr_bank_q`→`carry_next_bank_q` — a real recurrence) |
| instr_queue | 72.0 | 72.0 | **46.1** | `gen_fifo_input` serial last-writer select + serial rank popcount → last-match one-hot `fsel_oh` + masked-OR field gathers + `$countones(valid & below_m)`; preserved the no-hit→slot-0 read and modulo-free mask | gather mux arms billed ~15–46 (exclusive_case_mux, max arm 12.9) |
| load_unit | 69.2 | 69.2 | 69.2 | — | FSM next-state `state_d` unique-case: dep floor makespan 69.2 (real serial FSM decode) |
| csr_regfile | 66.6 | 66.6 | 66.6 | — | independent-LHS bundle floor: 160 lhs / 540 writes (the CSR comb writer); exception-entry field chain |
| g6lc_lsq | 105.7 | 66.1 | 73.2 | store-side event select/byte-enable hoisted out of the l×s pair scan (`s_sev/s_skn/s_addr/s_size/s_be` once per entry; `lbe`/`ev0_be` per-l/global) | phys-alias replay-mask cone — physically shallower (shared compute) but the merged cone bills +7 under the path model (cross-term compare stack remains real depth) |
| alu | 64.5 | 64.5 | 64.5 | — | exclusive-case `result_d` arms ≤26.0 (shifter) + dep floor 64.5; A3 split for LAT_ALU_FULL authorized, deferred (changes wakeup distance) |
| g6lc_iq_arb | 146.9 | 63.1 | 63.1 | (rank-0/1 done r2) | age-compare tournament depth — real |
| g6lc_decode_s3 | 179.7 | 55.8 | 55.8 | — | independent-LHS bundle over 69 lhs — bundle billing |
| sb_lifecycle | 95.4 | 52.0 | 52.0 | — | dense_control_cone: MixedSmt window accounting (wdist arithmetic chain) |

## Per-stage table (`--stages`; in-stage vs stage budget, into-stage)

| module.stage | cyc/win | worst in-stage | vs budget | worst into-stage (from) |
|---|---|---|---|---|
| alu.A1 | 1/0 | 18.7 | ! | 64.5 (-) |
| alu.A2 | 1/0 | 36.9 | ! | — |
| branch_unit.B1 | 1/0 | 13.0 | ! | — |
| branch_unit.B2 | 1/0 | 23.0 | ! | — |
| csr_decode.C1 | 1/0 | 9.8 | ! | — |
| csr_read.C2 | 1/0 | 6.9 | ok | — |
| csr_write.C3 | 1/0 | 7.0 | ok | — |
| id_stage.D1 | 1/0 | 8.0 | ok | — |
| id_stage.D2 | 1/0 | 0.0 | ok | — |
| id_stage.D3 | 1/0 | 7.0 | ok | 43.8 (unstaged) |
| g6lc_rename_resolve.RR | 1/0 | 41.7 | ! | — |
| g6lc_iq_bank.SEL | 1/0 | 86.7 | ! | — |
| g6lc_iq_arb.ARB | 1/0 | 31.8 | ! | 58.2 (unstaged) |
| g6lc_lsq_event.E | 1/0 | 34.0 | ! | — |
| g6lc_lsq_cam_bank.C | 1/0 | 40.8 | ! | — |
| g6lc_lsq_reduce.R | 1/0 | 38.2 | ! | — |
| g6lc_lsq_verdict.V | 1/3 | 24.6 | ! | — |
| g6lc_ooo_dispatch.ISS | 1/0 | 19.2 | ! | 30.3 (unstaged) |
| load_unit.L2 | 1/0 | 5.0 | ok | 69.3 (L5) |
| load_unit.L3 | 1/0 | 2.8 | ok | — |
| load_unit.L4 | 1/0 | 10.0 | ! | 69.3 (L5) |
| load_unit.L5 | 1/0 | 44.7 | ! | 45.2 (-) |
| multiplier.S1 | 1/0 | 69.5 | ! | 78.3 (-) |
| multiplier.S2 | 1/0 | 21.1 | ! | — |
| multiplier.S3 | 1/0 | 21.1 | ! | — |
| multiplier.S4 | 1/0 | 21.1 | ! | — |
| multiplier.S5 | 1/0 | 21.1 | ! | — |
| multiplier.S6 | 1/0 | 3.5 | ok | — |
| multiplier.S7 | 1/0 | 18.5 | ! | — |
| multiplier.S8 | 1/0 | 8.9 | ! | 8.9 (S7) |
| sb_commit_bundle.CB | 1/0 | 124.8 | ! | — |
| scoreboard.RDY | 1/0 | 0.0 | ok | — |
| stb_fwd.F1 | 1/0 | 22.0 | ! | — |
| stb_fwd.F2 | 1/0 | 24.3 | ! | — |
| stb_fwd.F3 | 1/0 | 33.4 | ! | — |
| g6lc_bp_tage.P1 | 1/0 | 3.5 | ok | — |
| g6lc_bp_tage.P2 | 1/1 | 7.5 | ok | — |
| g6lc_fe_nextline.NL | 1/0 | 11.5 | ! | — |
| trigger_module.TWR | 1/0 | 112.3 | ! | — |
| trigger_module.TMA | 1/0 | 102.0 | ! | 136.0 (TWR) |
| trigger_module.TAC | 1/0 | 3.5 | ok | — |
| wt_dcache_wbuffer.W1 | 1/0 | 9.0 | ! | 19.6 (-) |
| wt_dcache_wbuffer.W2 | 1/0 | 122.1 | ! | 28.9 (-) |
| g6lc_tlb.T1 | 1/0 | 11.3 | ! | — |
| g6lc_tlb.T2 | 1/0 | 12.6 | ! | 32.8 (T1) |

Stage-budget pass/fail: in-stage ≤ budget: **12/45 stages**; into-stage ≤
(1+window)×8: **0/13 measured** — every into-path with a reading exceeds
the windowless 8-FO4 bound (all into-readings are unstaged `-` or
cross-stage flows feeding the region; no declared `window=` path carries
a measured into-stage violation since V/P2 have no into-path).

## Bubble-up verdicts (r3; absorb covers active)

30 stages: **26 covered, 4 absorbed, 0 drag.** No new `drag` verdicts were
introduced by this round's restructures.

| stage | verdict | cover | finding |
|---|---|---|---|
| g6lc_fe_nextline.NL | absorbed | read-ahead | verified — `line_taken_q <= ltaken_q[rd_idx]` |
| g6lc_iq_bank.SEL | absorbed | spec-wakeup | verified — LAT_NONSPEC gating + wake_cnt visible |
| g6lc_iq_arb.ARB | absorbed | spec-wakeup | `unverified-cover` — countdown lives in sibling iq_bank |
| g6lc_ooo_dispatch.ISS | absorbed | spec-wakeup | verified — re-arm/replay state in-module |
| all others (alu.A1/A2, B1/B2, C1–C3, D1–D3, E/C/R/V, F1–F3, L2–L5, S1–S8, T1/T2, W1/W2, P1/P2, RR, TWR/TMA/TAC, CB, RDY) | covered | — | value-class waits absorbed by OoO issue |

## Residuals (billed chain; artifact vs real classification)

- **Real serial dependency** (rank-0 cannot reach 8; splitting = new
  register, allowed only for value stages — deferred or forbidden):
  `trigger_module` 136.0 (TWR write-through into TMA match — real);
  `sb_commit_bundle` 124.8 (decode→gather→min-tree→legality→record chain);
  `wt_dcache_wbuffer` W2 122.1 (rtrn select→record read→evict legality);
  `g6lc_thread_select` 68.3 (6-level priority gate chain, decision-class —
  register forbidden); `g6lc_rename_read` 76.0 (serial free-list picks);
  `g6lc_rename_recover` 74.7 (wrap/clamp/`ckpt_slot` chain after the
  gather rework);
  `load_unit` 69.2 (FSM dep floor); `g6lc_lsq` 73.2 (alias compare stack;
  shared-cone merge billed +7 vs r2).
- **Billing artifacts / model limits**: `multiplier` S1 69.5 (atomic `*`
  op; real tile-mul is a small Wallace cone) and `gen_one_stage` 93.2
  (config-dead `MultStages==1` branch); `alu` 64.5 (dep-floor incl. operand
  cone; A3 split authorized, deferred); `csr_regfile` 66.6 (160-lhs bundle
  makespan — needs a per-region split pass); `g6lc_decode_s3` 55.8 /
  `store_buffer` 77.1 / `sb_lifecycle` 52.0 (bundle/dense-cone makespans);
  `g6lc_iq_bank` SEL 86.7 (wakeup CAM+rearm cone — real decision depth,
  cover declared); `g6lc_iq_arb` ARB 63.1 (age tournament — real).
- **Untouched this round / out of cone**: `g6lc_ai_exec` 283.0, fpnew_*,
  pa_*/ct_* vendored, hpdcache_*, `g6lc_bp_ckpt` 61.8, `g6lc_shared_tlb`
  54.0, `macro_decoder` 52.9, `serdiv` 52.8, `bht` 52.5, `g6lc_ptw` 50.4.

## Verilator status

`--lint-only` (verilator_bin 5.008 WSL, repo -Wno-* set), after the r3
restructures + enum/peephole repairs: `g6lc_core` — **0 errors** /
441 warnings (WIDTHEXPAND 218, LITENDIAN 121, WIDTHTRUNC 54, IMPLICIT 18,
LATCH 11 — down from 22, CMPCONST 7 — constant-folded genvar compares,
WIDTHCONCAT 4, UNSIGNED 4, SELRANGE 2, SYMRSVDWORD 1, PINMISSING 1 —
`pc_commit_i` draft seam; MULTIDRIVEN **0** — down from 5);
`g6lc_soc` (APU tree) — **0 errors** / 31 warnings (WIDTHEXPAND 18,
LITENDIAN 7, PINMISSING 3 `clk_uncore` legacy wrappers, WIDTHTRUNC 2,
MODDUP 1 module-vs-package `g6lc_soc`). Trees elaborate end-to-end.

Repairs this round (no design impact; logged in bringup-log step 3):
`instr_queue` cf gather `|=` on an enum LHS → logic-domain OR + `cf_t'`
cast (ENUMVALUE); `g6lc_rename_read` `int'($countones(...))`/`int'()` mixes
inside compare expressions tripped a Verilator 5.008 V3DfgPeephole
internal error → `$countones` hoisted to named signals and compare
operands kept in the original `int`/`int unsigned` shapes.
