# r75 — program: structural 8 FO4 for every file of the hyp8 redesign

Board of record: `boards/hyp8-core/analyze-r73-all.json` (r44 map, delay-v44,
`--all-modules --stages`, fo4_ps 20, target 5000 MHz, budget 8.0). 258 modules,
**182 over 8.0**. This document is the plan the user asked for: how each class of
module is brought to a structural 8 and in what order, with the latency
contracts that change. It supersedes `r64-program.md`/`r69-fo4-program.md`
for ordering; the measured facts in those files stay valid.

## 0. What 8 FO4 means for the RTL

At `fo4_ps = 20` the budget is 160 ps: roughly one 64-bit carry-select add, or
a 6-level mux tree, or a 64-bit equality compare plus two gate levels. Any cone
that composes two of these (address add + compare, select + encode, read mux +
bypass) is ≥ 2 stages by construction. Consequences that drive the plan:

1. **Every module above 16 needs at least one new register stage** on its
   limiting cone; above 24 at least two. Rank-0 rewrites (one-hot forms,
   hoists, late-select) are measured out on the top modules (r52–r74
   countercase ledger); they still matter *inside* each new stage to land it
   under 8, not instead of the stage.
2. **Latency contracts change.** The r44 latency table is replaced per item in
   §4 (column "contract"). Stage additions are config-gated (`*Stages` fields in
   `g6lc_user_cfg_t`, legality in `check_cfg`) so the 1-stage profile remains
   bit-identical and the 8-FO4 profile is a second package
   (`g6lc64_hyp8_8fo4_config_pkg.sv`).
3. **Measurement classes are resolved first** so the board shows cones, not
   bundles: `independent_lhs_bundle` → one `always_comb` per output family
   (kept only where the module max drops — load_unit was a countercase,
   island_top a win); `exclusive_case_mux` → unique-case over proven one-hot
   with a masked-OR body; `multi_cycle_tagged` (FPU/div) → `svt-pipe` latency
   contracts (A123/A128) and the unit's own stage dial, not a cone rewrite.
4. **Dead arms are excluded, not optimized**: PHYS_VALIDATE (`g6lc_lsq` 72.2,
   COH_OOO only), `g6lc_ptw_leg_decode`, `g6lc_shared_tlb`, `g6lc_slice_dispatch`,
   `g6lc_ai_exec`, HPDCACHE, `macro_decoder`, `copro_alu`, FPGA regfile — they
   get the same stage treatment only when a profile instantiates them.

## 1. Method per module (the loop that produced every retained result)

```
board(module) → classify limiter (plain / bundle / case / dense / multi-cycle)
  → caller search (sv-timing instances + cross_module_paths): who consumes the
    output in the same cycle, who may take it one cycle later (latency-tolerant)
  → choose: (a) representation (family split / one-hot) (b) rank-0 equivalent
    (c) stage at a registered seam (A106 snapshot, A40 cut) (d) caller-purpose
    segment (new module per consumer class)
  → edit one module → board → keep only on module-max drop, revert byte-exact
  → lint (local) → batch: closure + smokes (+ leaf for latency changes)
  → one Linux witness per batch of landed latency changes
```
Development-efficiency rules: one board per edit (≈1 min), no leaf for rank-0
equivalents (smokes only), leaf + witness only for contract changes; log every
countercase with its number so the pattern card learns.

## 2. Pattern card (what paid, what did not — measured on this tree)

| Pattern (card) | Paid | Lost |
|---|---|---|
| Caller-purpose dead-arm removal / specialization | shared_tlb 51→router 10.7; ptw legacy arm out 37.6→35.7; missunit live arm off output 47.4→44.9 | — |
| Hoist shared predicates out of sequential reads (A118) | ptw 35.7→27.4; dcache_ctrl 28.6→24.0; fe_override 30.3→24.9 | load_unit hoist (null) |
| One-hot masked-OR over proven one-hot (A104) | iq_legal 21.9→19.5; prf 34.1→30.6; lsq_reduce 29.9→15.1 (age matrix) | freelist encode 37→46 (48×6 narrow); iq_arb per-bank 32.9→34.2 |
| Registered snapshot of the input side (A106) | dcache_mem wbuf T1 33.3→28.4; missunit raw word 44.9→42.5 | — |
| Explicit select instead of `*k` indexed part-select (A118) | missunit 42.5→32.5 | — |
| Late-select arithmetic over a small count (A118/A120) | csr_counters 33.2→19.6 (wide add) | rename_read 49.6→62.6 (control candidates); g6lc_iq thresholds 101.7→102.9 |
| Per-output-family comb split (A140) | island_top 51.8→43.9 (apu) | load_unit 41→46 (dense control) |
| Deeper trees on already-balanced selects | — | iq_bank 32.3→42.5; alu shifter 27.9→48.1; tlb 30.9→48.6 |
| Circular-order compare from state (A118) | — | bp_ckpt 30.3→32.5 |

## 3. Tiers and order

- **T0 (now):** representation fixes on bundles/cases where the board drops;
  dead-arm exclusions listed in §0.4; `svt-pipe` contracts on fpnew/div/vfdsu.
- **T1 (next):** rank-0 patterns that have paid, applied to the remaining
  modules in §4 marked (a)/(b).
- **T2:** stage insertion at registered seams, one config field each, in the
  order of §4 (value per contract cost): LSU publish lane, D$ write buffer,
  issue select, rename recovery, TLB context, frontend cones, decode families,
  CSR seam, commit/ROB, misc.
- **T3:** caller-purpose segmentation producing new modules (dedicated lanes).
- **T4:** the 8-FO4 package: every `*Stages` field at its deep value; board,
  smokes, leaves, witness; latency table rewritten.

## 4. Per-module plan (active profile, board r73; X = excluded arm)

| Module | FO4 | Class | Mechanism (tier) | Stages to 8 | Contract |
|---|---:|---|---|---:|---|
| g6lc_iq (steer) | 101.7 | bundle (plain 97.6) | T2: register bank eligibility at the bank update edge (A134), lane 1 from a pre-rotated copy; T3: steer as its own module per lane pair | 3 | dispatch admission +1 |
| g6lc_decode_s3 / _s2 | 53.7 / 40.8 | bundle | T0 family split; T2: `DecodeStages` 3 (operand class / immediates / legality) | 2–3 | decode +1..2 |
| wt_dcache_wbuffer | 50.1 | plain makespan | T2: versioned entry writes (P8), separate L1/AXI obligation planners (caller split) | 3 | wbuf admit +1 |
| g6lc_rename_read | 49.6 | case | T2: `RenameReadStages` 2: ckpt slot/count in cycle 1, lane assembly cycle 2 (late-select failed as rank 0) | 2–3 | rename +1 |
| wt_dcache_missunit | 32.5 | plain | T2: formed result registered (AMO_RESULT +1) — **landed r75** | 2 | AMO result +1 |
| aes | 44.9 | plain | T2: round pipeline (`AesStages`) | 3 | crypto +2 |
| store_unit | 42.3 | plain (DTLB leg) | T2: `StoreTransStages` (P7) — registered PA before the store buffer | 2 | store post +1 |
| load_unit | 41.0 | bundle (plain 35) | T2/T3: exception completion lane as its own module (S1), publish payload registered | 3 | load WB +1 |
| csr_regfile | 37.4 | bundle | T0 split per CSR family; T2: read mux registered (`CsrReadStages`) | 2 | CSR read +1 |
| g6lc_freelist | 37.1 | plain | T2: pick from a registered per-bank candidate one-hot (A134), reservation applied next edge | 2 | rename alloc +1 |
| g6lc_rename | 35.0 | case | T2: kill pick registered; map read bypass stays | 2 | recovery +1 |
| g6lc_mmu | 33.6 | bundle | T0 split; T2: `TlbCtxStages` (S4) | 2 | translate +1 |
| g6lc_fe_redirect | 33.1 | bundle | T0 split (arbiter vs record) | 1–2 | — |
| g6lc_core (hang/prober) | 32.8 | dense | TB-only cone; exclude from clock rule | — | — |
| g6lc_iq_bank | 32.3 | plain | T2: `IqSelStages` (S2): select cycle 1, payload cycle 2 | 2–3 | issue +1 |
| g6lc_rename_recover | 31.8 | bundle | T2: two-edge recovery (S3) | 2 | flush +1 (absorbed) |
| g6lc_tlb | 30.9 | case | T2: context pre-match registered (S4) | 2 | — |
| g6lc_iq_arb / bp_ckpt / prf | 30.6 / 30.3 / 30.6 | plain | T2: IqArbStages 3; ckpt verdict registered; PRF read registered (`PrfReadStages`) | 2 | +1 each |
| issue_barrier / issue_read_operands / alu / mult | 28.4 / 28.0 / 27.9 / 27.0 | mixed | T2: operand select stage; `AluStages` 2 (shifter), `MultStages` 3 | 2–3 | exec +1 |
| frontend / instr_realign / instr_queue / icache / ftq | 25.5 / 27.6 / 45.1 / 22.0 / 18.4 | plain/case | T2: realign prefix as a stage (A110), queue push-gather registered, I$ tag compare stage | 2–3 | fetch +1..2 |
| controller / commit_stage / sb_* / rob | 25.1 / 21.5 / 22–25 / 24.4 | bundle/dense | T0 split; T2: commit verdict registered (`CommitStages` 2) | 2 | commit +1 |
| ex_stage / load_store_unit / lsu_* / stb_fwd / lsq_* | 19–26 | plain | T2: STB forward verdict registered (StbFwdStages), LSQ verdict window (P5) | 2 | LSU +1 |
| csr_counters | 19.6 | plain | T1 done (r74); T2: high-half increment registered | 2 | — |
| perf_counters / pmp* / bp_* / rrip / ghist | 17–24 | mixed | T1 one-hot forms; T2 one stage where > 16 | 1–2 | — |
| fpnew_* / div / vfdsu / serdiv | 141 / 72 / 67 / 53 | multi-cycle tagged | `svt-pipe` latency contracts + the units' own stage parameters (`PipeConfig`), not cone rewrites | n/a | FP latency per unit |
| X: hpdcache_*, macro_decoder, copro_alu, shared_tlb, ptw_leg_decode, slice_dispatch, ai_exec, regfile_fpga | 30–77 | — | same recipes when a profile instantiates them; excluded from the clock rule now | — | — |

## 5. Verification scheme (less testing, more gates)

- Rank-0 items: lint + 5 smokes (cycle counts must be identical).
- Stage items: lint + the module's existing leaf (`run_hyp8_memory.py` /
  `run_hyp8_control.py`) + smokes (cycle counts may move; recorded) + one Linux
  witness per batch (r46 lineage: both firmware layouts past every known
  barrier; the witness is the integration test).
- Board after each item; the `analyze-r75-*.json` series is the record.

## 6. Status

- r75 landed: missunit formed-result stage (§4) — see implementation-log r75.
- Everything else in §4 is planned, not done; the T2 items need the config
  fields first (one `check_cfg` block), which is the next commit.
