# board-hyp8-r2.md — second structural board of the hyp8 core tree (post-rework, stage-aware)

<!-- hyp8-status -->
> **Status: measured structural reading, indicative.** `sv-timing analyze --all-modules --stages
> --target-mhz 5000 --fo4-ps 20 --budget-margin 0.2 --assume-xlen 64 --package-mode packages` on
> `core/Flist.g6lc_hyp8` (delay-v44). Structural FO4 is the serial statement-order estimate
> deflated by path_class; it still over-reads sequential patch chains and NR:1 selects. Not STA.
> `r1` is the same measurement on the pre-rework tree (board-hyp8-r1). No simulation, STA,
> synthesis or boot has been run.

- Raw: `<prov>/boards/hyp8-core/analyze-r2.json`; emit: `<prov>/emit/hyp8-core-r2`
  (`correct --all-modules --stages --emit`, 564 edits, latency-neutral only).
- r2b re-run (`<prov>/boards/hyp8-core/analyze-r2b.json`, same flags) adds the
  four `svt-stage: absorb` covers — comment pragmas only; structural numbers
  unchanged.
- Modules with paths: 262; over 8 structural: **177**; at/under 8: 85
  (r1: 224 with paths, 157 over 8 — the r2 cone is wider because the stage pass
  attributes more nodes).
- Failing paths: 5168 (r1 5166); worst `g6lc_ai_exec.reg0/CP -> reg1/D` = 283.0 —
  accelerator module copied AS-IS, outside the hyp8 instantiation cone.
- `correct` emit changes max_path 283.0→283.0 (the remaining hot cones are
  dependency-floor / NR:1-select billed, not BalanceMux-shaped).

## Rework results (target list, r1 → r2)

| module | r1 | r2 | restructured | residual |
|---|---|---|---|---|
| g6lc_ooo_dispatch | 210.4 | **30.3** | per-lane issue capture, enum casts | boundary select |
| stb_fwd | 202.5 | **33.4** | F1/F2/F3 pairwise youngest-writer per byte | spec/win cone |
| g6lc_decode_s3 | 179.7 | **55.8** | parallel legal compares, balanced OR | legality cone |
| g6lc_iq_bank | 177.2 | **86.7** | one-hot wakeup trees, per-entry assigns | in-bank select |
| g6lc_iq_arb | 146.9 | **63.1** | port-select compare vectors | grant gather |
| wt_dcache_wbuffer | 146.8 | **112.4** | per-slot/per-field next-state, shared rtrn mid | tx_stat/sc patches |
| sb_head | 135.0 | **22.8** | 2-step lowest-set; serial fallback translate_off | — |
| id_stage | 134.5 | **43.9** | DS3 D1/D2/D3 split; rank+masked-gather compaction | fill cone |
| multiplier | 132.6 | **93.2** | compressor rows explicit (P10 handshake lock) | CSA recurrence |
| trigger_module | 129.4 | **129.4** | — | write-through FSM (see residuals) |
| sb_commit_bundle | 128.4 | **135.2** | per-field commit record, one-hot WB merge, head min-tree, narrow sl_* vectors | NR:1 selects billed |
| g6lc_lsq | 105.7 | **66.1** | per-tid gathers, per-entry compare vectors | replay mask cone |
| sb_lifecycle | 95.4 | **52.0** | per-slot event-mask next-state (alloc→wb→cancel→replay→free→flush) | dense_control_cone |
| g6lc_thread_select | 88.1 | 88.1 | — | untouched (residual) |
| g6lc_rename_recover | 86.3 | 86.3 | — | untouched (residual) |
| g6lc_tlb | 84.7 | **40.8** | parallel match/lookup compares | hit select |
| issue_read_operands | 79.5 | **48.9** | FU-valid per-bit decode; stall/forward accumulate masks | hazard mask cone |
| g6lc_rename_read | 77.3 | 77.3 | — | untouched (residual) |
| store_buffer | 88.4 | **77.1** | commit-queue ring youngest-writer → pairwise (A141, ring-distance = age) | spec_fwd cone |
| instr_realign | 73.2 | 73.2 | — | untouched (residual) |
| instr_queue | 72.0 | 72.0 | — | untouched (residual) |
| load_unit | 69.2 | 69.2 | — | untouched (residual) |
| csr_regfile | 66.6 | 66.6 | — | untouched (residual) |
| alu | 64.5 | 64.5 | — | untouched (residual) |
| g6lc_rename_resolve | 55.0 | 41.6 | compare + gather form | resolve cone |
| g6lc_lsq_cam_bank | 41.0 | 40.8 | per-entry event/match assigns | P10 lock (accepted) |

## Per-stage table (`--stages`; in-stage vs stage budget, into-stage)

| module.stage | cyc/win | worst in-stage | vs budget | worst into-stage (from) |
|---|---|---|---|---|
| alu.A1 | 1/0 | 18.7 | ! | 64.5 (A2) |
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
| g6lc_lsq_verdict.V | 1/0 | 24.6 | ! | — |
| g6lc_ooo_dispatch.ISS | 1/0 | 19.2 | ! | 30.3 (unstaged) |
| load_unit.L2 | 1/0 | 5.0 | ok | 69.3 (L5) |
| load_unit.L3 | 1/0 | 2.8 | ok | — |
| load_unit.L4 | 1/0 | 10.0 | ! | 69.3 (L5) |
| load_unit.L5 | 1/0 | 44.7 | ! | 45.2 (unstaged) |
| multiplier.S1 | 1/0 | 69.5 | ! | 78.3 (unstaged) |
| multiplier.S2_5 | 1/0 | 9.9 | ! | — |
| multiplier.S6 | 1/0 | 3.5 | ok | — |
| multiplier.S7 | 1/0 | 18.5 | ! | — |
| multiplier.S8 | 1/0 | 7.9 | ok | — |
| sb_commit_bundle.CB | 1/0 | 135.2 | ! | — |
| scoreboard.RDY | 1/0 | 0.0 | ok | — |
| stb_fwd.F1 | 1/0 | 22.0 | ! | — |
| stb_fwd.F2 | 1/0 | 24.3 | ! | — |
| stb_fwd.F3 | 1/0 | 33.4 | ! | — |
| g6lc_bp_tage.P1 | 1/0 | 3.5 | ok | — |
| g6lc_bp_tage.P2 | 1/1 | 7.5 | ok | — |
| g6lc_fe_nextline.NL | 1/0 | 11.5 | ! | — |
| wt_dcache_wbuffer.W1 | 1/0 | 9.0 | ! | 21.4 (unstaged) |
| wt_dcache_wbuffer.W2 | 1/0 | 28.0 | ! | 112.4 (unstaged) |
| g6lc_tlb.T1 | 1/0 | 11.3 | ! | — |
| g6lc_tlb.T2 | 1/0 | 12.6 | ! | 32.8 (T1) |

## Bubble-up verdicts (stage registers through reference search, r2b)

After the `svt-stage: absorb` declarations (r2b board,
`analyze-r2b.json`): 26 covered, **0 drag**, **4 absorbed**. The four
decision-class stages each carry a declared architectural cover — the
readers are still listed verbatim, and each cover's precondition was
checked against the IR (`unverified-cover` is a finding, not a waiver;
the cover mechanism is real RTL, the check just cannot see across the
module boundary).

| stage | verdict | extra | readers / decision readers | cover | finding |
|---|---|---|---|---|---|
| g6lc_fe_nextline.NL | **absorbed** | 1 | 14 — `fetch_frontier_pc_o`, `ftq_push_vaddr`, `icache_dreq_o`, `inflight_addr_q`, `redirect_*`, `want_*` | `read-ahead` — "line table read one cycle ahead; redirect record applies next cycle" | **verified** — `line_taken_q <= ltaken_q[rd_idx]` / `line_target_q <= ltarget_q[rd_idx]` are registers whose D indexes a stage register (the table read runs one cycle ahead). |
| g6lc_iq_bank.SEL | **absorbed** | 1 | 6 — `disp_ack_o`, `asgn`, `found`, `tot`, `used`, `wr_entry` | `spec-wakeup` — "producer latency class fixed; LAT_NONSPEC producers wake on real WB; replay re-arms" | **verified** — `hyp_lat_class_e`/`LAT_NONSPEC` gating + `wake_cnt`/`wake_cy` countdown visible in-module. |
| g6lc_iq_arb.ARB | **absorbed** | 1 | 6 — `blk_flu`, `blk_fpu`, `blk_div`, `blk_dliv`, `blk_in`, `stall_p` | `spec-wakeup` — "registered candidate replaces the operand latch; ack addresses the held candidate" | `unverified-cover` — the latency-class countdown machinery lives in the sibling `g6lc_iq_bank`, not in the arbiter IR; cover recorded, precondition asserted by declaration. |
| g6lc_ooo_dispatch.ISS | **absorbed** | 1 | 3 — `issue_instr_o`, `issue_instr_hs_o`, `_unused` | `spec-wakeup` — "registered candidate replaces the operand latch; ack addresses the held candidate" | **verified** — re-arm/replay state (`rp_mask_q`, LSQ/LSU replay merge) is visible in-module. |

The four stages remain the design's own pipeline-boundary registers — the
OoO pipeline's architectural issue depth — not registers inserted for
timing. The covers record *why* the register is not a bubble between
dependent decisions: dependents are woken from the producer's SELECT with
the latency countdown (spec-wakeup), or the address is produced one cycle
ahead of its use (read-ahead).
| alu.A1/A2 | covered | 1 | 119 / 44 | value pipe — OoO covers the wait |
| branch_unit.B1/B2 | covered | 1 | 34 / 6 | value pipe |
| csr_decode.C1, csr_write.C3 | covered | 1 | 11 / 0 | value |
| g6lc_bp_tage.P1/P2 | covered | 1/2 | 2 / 3 | predictor value path |
| g6lc_lsq_event.E | covered | 1 | 43 | event capture |
| g6lc_lsq_cam_bank.C | covered | 1 | 0 | CAM value |
| g6lc_lsq_reduce.R | covered | 1 | 8 | reduction value |
| g6lc_lsq_verdict.V | covered | 4 | 4 | verdict wait ≤4 — covered by OoO issue |
| id_stage.D1/D2 | covered | 1 | 3 / 5 | decode value |
| multiplier.S1..S8 | covered | 1 | 5–14 each | FU value pipe |
| stb_fwd.F1/F2/F3 | covered | 1 | 13 / 6 / 8 | store-forward value |
| wt_dcache_wbuffer.W1/W2 | covered | 1 | 24 / 83 | write-buffer value |
| g6lc_tlb.T1/T2 | covered | 1 | 22 / 58 | TLB value |

## Residuals (all billing-class, structural estimate only)

- **trigger_module 129.4** — `write_path` serial write-through FSM: trigger
  match logic reads mid-computation `_d` records and accumulated globals
  (`e_matched_d`, `debug_from_trigger_d`, hit/pending flags read fold-prefix
  state). Faithful per-element restructure needs the serial fold's prefix;
  deferred. Deflated field depth 28.0 vs billed makespan 129.4.
- **sb_commit_bundle 135.2** — NR_SB_ENTRIES:1 selects (`sl_*` vectors +
  `sel_mem`) billed as full-record muxes in front of the head min-tree and
  the per-port WB merge; the cones are already min-tree/one-hot form.
- **wt_dcache_wbuffer 112.4** — `tx_stat_d` + scalar patches in
  `p_tx_stat`/`p_buffer_sc` (independent_lhs_bundle floor).
- **multiplier 93.2** — CSA recurrence billed as one chain; the handshake
  pulse/index path is P10-locked (no register may move); explicit rows done.
- **Untouched this round** (each one remaining restructure pass available):
  g6lc_thread_select 88.1, g6lc_rename_recover 86.3, g6lc_rename_read 77.3,
  instr_realign 73.2, instr_queue 72.0, load_unit 69.2, csr_regfile 66.6,
  alu 64.5, g6lc_iq_bank 86.7 (residual in-bank select), g6lc_iq_arb 63.1,
  g6lc_decode_s3 55.8, store_buffer 77.1 (spec_fwd cone), sb_lifecycle 52.0
  (dense_control_cone), issue_read_operands 48.9.
- **Outside the redesign set / not in the cone:** g6lc_ai_exec 283.0,
  fpnew_fma_multi 133.4, fpnew_* / pa_* / ct_* vendored FPU, hpdcache_*.

## Verilator status

`--lint-only` (verilator_bin 5.008 WSL, repo -Wno-* set):
`g6lc_core` — 0 errors / 439 warnings; `g6lc_soc` (APU tree) — 0 errors.
Trees elaborate end-to-end; warning classes per bringup-log.
