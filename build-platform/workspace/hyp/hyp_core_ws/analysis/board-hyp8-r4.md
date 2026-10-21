# board-hyp8-r4.md — fourth structural board of the hyp8 core tree (architectural round)

<!-- hyp8-status -->
> **Status: measured structural reading, indicative.** `sv-timing analyze --all-modules --stages
> --param-map inputs/param-map-hyp8.json --width-map inputs/width-map.json
> --target-mhz 5000 --fo4-ps 20 --budget-margin 0.2 --assume-xlen 64 --package-mode packages` on
> `inputs/hyp8-core.f` (delay-v44). Structural FO4 is the serial statement-order estimate
> deflated by path_class; it still over-reads sequential patch chains and NR:1 selects.
> Not STA. No simulation, STA, synthesis or boot has been run.
>
> **This round ran under the exact hyp8 parameter map** (`inputs/param-map-hyp8.json`;
> NrHarts=1, SmtDrainedHandoff=1, StoreFwdCycles=3, DecodeStages=3, TlbStages=3,
> MultStages=8, FreelistBanks=2, AluStages=2). Generate branches keyed on an
> unresolvable localparam/function were converted to inline exact config
> expressions so config-dead code no longer bills (r3→r4 note).

- Raw: `<prov>/boards/hyp8-core/analyze-r4.json`; emit:
  `<prov>/emit/hyp8-core-r4` (`correct --all-modules --stages --emit`,
  **272 edits**, latency-neutral only; the emit's own reading reports
  max_path 124.1→124.1, `post_closes=false`, dens=178).
- Modules with paths: **262**; over 8 structural FO4: **176**; failing
  paths (>8): **4958**; over 9.6 (8×1.2): **4551** (r3: 5438 / 4915).
- Worst: `g6lc_ai_exec` 283.0 (AS-IS accelerator, outside the redesign
  cone — not silently closed).

## Config-dead-branch guards (rank 0; no cycles added)

Generate guards that referenced localparams or package functions the
const-evaluator cannot resolve were rewritten to inline exact
`G6LCCfg`/`HypCfg` field expressions so parameter-map pruning applies:

| file | guard made resolvable | live branch for hyp8 | billing effect |
|---|---|---|---|
| `sb_commit_bundle.sv`, `sb_lifecycle.sv`, `scoreboard.sv` | `localparam MixedSmt` → `(G6LCCfg.NrHarts > 1) && !G6LCCfg.SmtDrainedHandoff` (r3) | legacy (single-hart) | CB 124.8→27.4, sb_lifecycle 52.0→28.9 |
| `store_buffer.sv` | `localparam LegacyFwd` → `(HypCfg.StoreFwdCycles == 0)` (r3) | staged F1–F3 forward | store_buffer 77.1→29.1 |
| `g6lc_thread_select.sv` | `localparam MixedSmt` → inline (r3) | single-hart | 88.1→13.0 |
| `multiplier.sv` | `MSTAGES = hyp_mult_stages(...)` → inline `(HypCfg.MultStagesOverride != 0) ? … : G6LCCfg.MultStages` (r4) | `gen_eight_stage` | the dead `gen_one_stage` atomic `*` (93.2) no longer bills |
| `trigger_module.sv` | `SDTRIG_MCH`/`SDTRIG_ICNT` → inline `G6LCCfg.SDTRIG && G6LCCfg.Mcontrol6` / `… && G6LCCfg.Icount` (r4) | mcontrol6+icount live, mcontrol dead | TMA match cone billed on live triggers only |

## Rework results (target list, r2 → r3 → r4)

| module | r2 | r3 | r4 | restructured this round | residual class |
|---|---|---|---|---|---|
| trigger_module | 129.4 | 136.0 | **79.2** | match cone now reads the registered `*_q` trigger-record state (tdata/tcontrol/tinfo/textra post-write-path registers) instead of mid-computation `*_d`; the serial write-through (csr→tdata_d→tdata_q) is the real remaining depth — a CSR write to a trigger register is now visible to matching one cycle later (fire +1 already registered at TAC; header records the trade-off) | real serial write-FSM fold (TWR 78.8 in-stage) + TMA match-chain prefix; rank-4 value — recorded |
| multiplier | 93.2 | 93.2 | **52.0** | atomic tile `a_u * b_u[..]` → explicit PP generation: S1 registers `a_q`/`b_q`/`corr_q`, S2 forms the 65 AND-rows `{AW{b_q[r]}} & a_q) << r` + `~corr`+1 (67 rows); LPS 2→3 compressor levels/stage (10 levels needed for 67 rows, extras park at 2); dead branches pruned | S1 17.6 (PP-gen+corr+reg); S2–S5 16.2 ea (3 CSA levels ≈ 5.4/level — real compressor depth); S7 18.5 (hi-half CPA); module worst 52.0 = unstaged clmul XOR cone. `MultStages` unchanged at 8 |
| g6lc_rename_read | 77.3 | 76.0 | **49.6** | banked picks: lane gp picks only from bank `gp % FL_BANKS` (`FL_BANKS=HypCfg.FreelistBanks=2`, plumbed through `g6lc_rename`); serial `taken_lt` chain → per-lane static masked-OR of earlier **same-bank** takes; `res_pick_mask_o`/`res_fpick_mask_o` = OR gather of actual takes; `stall_o` = per-lane bank-pool miss OR `br_over` | same-bank exclusion chain only remains when `NR_PORTS > FL_BANKS`; a lane stalls on an empty own bank (accepted). Residual = pick isolate + map/busy reads bundle |
| g6lc_decode_s3 | 55.8 | 55.8 | **53.7** | `exception_handling` split → `ex_assemble` (exception record: legality/ecall/ebreak + interrupt priority chain + debug override) and `out_assemble` (instruction_o fields + orig_instr_o) | interrupt priority chain is real serial last-writer depth; bundle bill marginally lower |
| sb_commit_bundle | 135.2 | 124.8 | **27.4** | (config pruning only — the 124.8 r3 reading was the dead MixedSmt path) | live legacy select: NR:1 gathers + min-tree, real serial chain |
| wt_dcache_wbuffer | 112.4 | 122.1 | **124.1** | — | W2 rtrn-id decode→record read→evict legality→merge; W3 coalesce split authorized, **deferred** |
| g6lc_iq_bank | 86.7 | 86.7 | 86.7 | — | SEL wakeup CAM/rearm decision depth; spec-wakeup cover re-verified |
| g6lc_rename_recover | 86.3 | 74.7 | 74.7 | — | independent-LHS bundle makespan (~25 lhs / 88 writes); registered `slot_of_level` restore table **deferred** |
| load_unit | 69.2 | 69.2 | **92.4** | — | FSM dep floor (L5 55.6 in-stage; into-L2/L4 readings from L5 feeds — billing-attribution drift vs r3) |
| csr_regfile | 66.6 | 66.6 | 66.6 | — | 160-lhs bundle makespan; per-bank comb split **deferred** |
| g6lc_lsq | 66.1 | 73.2 | **92.5** | — | alias/replay shared-cone merge billing (pmap reads it as one merged cone) |
| g6lc_iq_arb | 63.1 | 63.1 | 63.1 | — | age tournament — real decision depth; spec-wakeup cover re-verified |
| alu | 64.5 | 64.5 | **58.7** | — | A2 result-mux dep floor; A3 split (LAT_ALU_FULL→3) **deferred** — needs a third pipe register + forward-tap/wake-class rewiring (correctness-critical under lint-only) |
| store_buffer | 77.1 | 77.1 | **29.1** | (config pruning; legacy same-cycle forward is dead at StoreFwdCycles=3) | spec-fwd bundle floor |
| sb_lifecycle | 52.0 | 52.0 | **28.9** | (config pruning; MixedSmt `wdist` cone dead) | per-slot writer cone |
| g6lc_thread_select | 88.1 | 68.3 | **13.0** | (config pruning; MixedSmt drain path dead) | single-hart policy cone — near budget |
| instr_realign | 73.2 | 60.9 | **54.2** | — | carry-bank recurrence — real |
| instr_queue | 72.0 | 46.1 | **46.4** | — | gather-mux arm billing |
| g6lc_fe_nextline | — | 12.1 | **12.1** | — | near budget; read-ahead cover verified |

## Per-stage table (`--stages`; in-stage vs stage budget, into-stage)

| module.stage | cyc/win | worst in-stage | vs budget | worst into-stage (from) |
|---|---|---|---|---|
| alu.A1 | 1/0 | 13.2 | ! | 58.7 (A2) |
| alu.A2 | 1/0 | 36.9 | ! | — |
| branch_unit.B1 | 1/0 | 13.0 | ! | — |
| branch_unit.B2 | 1/0 | 23.8 | ! | — |
| csr_decode.C1 | 1/0 | 9.8 | ! | — |
| csr_read.C2 | 1/0 | 6.9 | ok | — |
| csr_write.C3 | 1/0 | 7.0 | ok | — |
| trigger_module.TWR | 1/0 | 78.8 | ! | — |
| trigger_module.TMA | 1/0 | 79.2 | ! | — |
| trigger_module.TAC | 1/0 | 3.5 | ok | — |
| id_stage.D1 | 1/0 | 8.0 | ok | — |
| id_stage.D2 | 1/0 | 0.0 | ok | — |
| id_stage.D3 | 1/0 | 7.0 | ok | 38.3 (-) |
| g6lc_rename_resolve.RR | 1/0 | 41.6 | ! | — |
| g6lc_iq_bank.SEL | 1/0 | 86.7 | ! | — |
| g6lc_iq_arb.ARB | 1/0 | 31.8 | ! | 58.1 (-) |
| g6lc_lsq_event.E | 1/0 | 29.0 | ! | — |
| g6lc_lsq_cam_bank.C | 1/0 | 40.8 | ! | — |
| g6lc_lsq_reduce.R | 1/0 | 38.2 | ! | — |
| g6lc_lsq_verdict.V | 1/3 | 24.6 | ! | — |
| g6lc_ooo_dispatch.ISS | 1/0 | 26.2 | ! | 27.3 (-) |
| load_unit.L2 | 1/0 | 5.0 | ok | 86.6 (L5) |
| load_unit.L3 | 1/0 | 2.8 | ok | — |
| load_unit.L4 | 1/0 | 7.4 | ok | 92.4 (L5) |
| load_unit.L5 | 1/0 | 55.6 | ! | 53.6 (-) |
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
| g6lc_bp_tage.P1 | 1/0 | 3.5 | ok | — |
| g6lc_bp_tage.P2 | 1/1 | 7.5 | ok | — |
| g6lc_fe_nextline.NL | 1/0 | 12.1 | ! | — |
| wt_dcache_wbuffer.W1 | 1/0 | 11.6 | ! | — |
| wt_dcache_wbuffer.W2 | 1/0 | 124.1 | ! | 21.2 (W1) |
| g6lc_tlb.T1 | 1/0 | 11.2 | ! | — |
| g6lc_tlb.T2 | 1/0 | 12.6 | ! | 32.8 (T1) |

Stage-budget pass/fail: in-stage ≤ budget **13/45** (r3: 12/45; +1 =
`trigger_module.TAC` joins the pass set on the same reading; `load_unit.L4`
now passes in-stage at 7.4 — attribution moved the prior L4 reading to an
into-path). Into-stage ≤ (1+window)×8: **0/11 measured** — every
into-reading is an unstaged `-` or cross-stage feed at window=0 (e.g.
L5→L2/L4 recirculation); no `window>0` stage carries a measured into-path
violation.

## Bubble-up verdicts (r4; absorb covers active)

34 stage rows: **30 covered, 4 absorbed, 0 drag.** No new `drag` verdict
was introduced; none of this round's new registers sits in a decision
cone (multiplier PP rows / trigger match copies are value-class).

| stage | verdict | cover | finding |
|---|---|---|---|
| g6lc_fe_nextline.NL | absorbed | read-ahead | verified — `line_taken_q <= ltaken_q[rd_idx]` |
| g6lc_iq_bank.SEL | absorbed | spec-wakeup | verified — LAT_NONSPEC gating + wake_cnt visible |
| g6lc_iq_arb.ARB | absorbed | spec-wakeup | `unverified-cover` — countdown lives in sibling iq_bank |
| g6lc_ooo_dispatch.ISS | absorbed | spec-wakeup | verified — re-arm/replay state in-module |
| all others | covered | — | value-class waits absorbed by OoO issue |

## Residuals (billed chain; artifact vs real classification)

- **Real serial dependency**: `trigger_module` TWR 78.8 / TMA 79.2
  (serial write-through + match prefix — the write-visible-next-cycle
  trade-off removed the _d coupling but the write FSM fold remains);
  `sb_commit_bundle` CB 27.4 (decode→gather→min-tree→legality→record);
  `wt_dcache_wbuffer` W2 124.1 (rtrn select→record read→evict legality);
  `g6lc_iq_bank` SEL 86.7, `g6lc_iq_arb` ARB 31.8 (decision cones — no
  register allowed, covers declared); `g6lc_rename_resolve` RR 41.6;
  `load_unit` L5 55.6 (FSM dep floor); `g6lc_decode_s3` 53.7 (interrupt
  priority last-writer chain — real).
- **Compressor / CPA depth (real arithmetic depth, value-class)**:
  `multiplier` S1 17.6, S2–S5 16.2 (3 CSA levels per stage — reaching ≤8
  needs ~1 level/stage ⇒ ~10+ stages; `MultStages` held at 8 pending a
  latency-class decision), S7 18.5 (hi-half carry-propagate), S8 8.9;
  module worst 52.0 is the unstaged clmul XOR cone.
- **Bundle makespans (billing artifacts over independent LHS)**:
  `csr_regfile` 66.6, `g6lc_lsq` 92.5, `g6lc_rename_recover` 74.7,
  `store_buffer` 29.1, `sb_lifecycle` 28.9, `stb_fwd` F1–F3.
- **Out of cone / vendored**: `g6lc_ai_exec` 283.0, `fpnew_*` 91.6–133.4,
  `hpdcache_*`, `g6lc_bp_ckpt` 61.8, `g6lc_shared_tlb` 54.0,
  `macro_decoder` 52.9, `serdiv` 52.8, `bht` 52.5, `g6lc_lsq_slot` 50.1,
  `g6lc_iq` 121.0 (wrapper billing over bank cones).

## Deferred authorized items (with reason)

- `wt_dcache_wbuffer` W3 coalesce split (+1 store→array visibility) —
  pending-record export widening not yet done.
- `alu` A3 (LAT_ALU_FULL→3) — requires a third ALU pipeline register and
  IQ wake-class/forward-tap rewiring; silent-bug risk under lint-only.
- `g6lc_iq_bank` SEL registered-wakeup CAM, `g6lc_iq_arb` registered age
  matrix — decision-cone contract changes; deferred.
- `g6lc_rename_recover` `slot_of_level` registered restore table;
  `csr_regfile` per-bank comb split; `load_unit` one-hot FSM — deferred.

## Verilator status

- `g6lc_core` (top `g6lc_core`, Flist_core.vlt, verilator 5.008, repo
  `-Wno-*` set): **0 errors / 444 warnings**
  (WIDTHEXPAND 220, LITENDIAN 121, WIDTHTRUNC 54, IMPLICIT 18, LATCH 11,
  CMPCONST 7, UNSIGNED 5, WIDTHCONCAT 4, SELRANGE 2, SYMRSVDWORD 1,
  PINMISSING 1; MULTIDRIVEN 0).
- `g6lc_soc` (top `g6lc_soc`, Flist_apu.vlt): **0 errors / 31 warnings**.
- Lint repair this round: `multiplier` per-row `always_ff` for `rr_q`
  (BLKLOOPINIT once NOPS=67 no longer unrolls); `g6lc_decode_s3`
  `exception_t` module type-parameter reference.

No simulation, STA, synthesis or boot has been run; all FO4 figures are
the delay-v44 structural estimate only.
