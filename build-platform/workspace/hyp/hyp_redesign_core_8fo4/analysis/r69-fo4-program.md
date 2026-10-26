# r69 FO4 program — worst modules of `analyze-r68`, by execution path and caller

Board of record: `boards/hyp8-core/analyze-r68.json` (+ `analyze-r68b-iqleg.json`), delay-v44, r44 map,
budget 8.0 structural FO4 (5 GHz nameplate at fo4_ps=20; the honesty gate of execution-path-plan §5
applies: a structural screening objective, never a physical claim). Method: sv-timing carry-over census
per module → path class → the ALGORITHMS-EXPERTS transform family that fits the class → rank
(0 = representation only, 1 = a register whose both-end ownership is written first, 2 = caller contract
change with a config knob + legality assert + latency table) → the caller(s) that consume the changed
promise. Development-efficiency ordering: rank-0 items first (one `analyze --stages` + the existing
equivalence reference is the whole verification), rank-1 next (leaf + smokes), rank-2 last (witness).

## 0. Census (module max, non-multicycle)

| # | Module | FO4 | Kind / class | Locus | Caller(s) |
|---|---|---|---|---|---|
| 1 | `g6lc_iq` | 182.4 | in→out plain | :216 first-fit steer (`steer_bank`/`asgn`) | `g6lc_ooo_dispatch` (`disp_ack_o` all-or-nothing) |
| 2 | `hpdcache_ctrl_pe` | 76.6 | in→out, 63-LHS bundle | :742 | hpdcache (not instantiated under hyp8 WT config) |
| 3 | `g6lc_lsq` | 72.2 | in→reg plain | :1206 slot update from verdict | `g6lc_ooo_dispatch`/`load_unit`/`store_unit` |
| 4 | `hpdcache_mshr` | 57.2 | reg→out | :282 | hpdcache (not instantiated) |
| 5 | `g6lc_decode_s3` | 53.7 | in→out, 58-LHS bundle | :275 | `id_stage` |
| 6 | `g6lc_ptw_leg_decode` | 53.0 | exclusive case, 15 arms | :174 `leg_state_d` | `g6lc_ptw` (PDEC=0 arm, excluded config) |
| 7 | `macro_decoder` | 52.9 | in→out, 236 writes | :398 | `id_stage` (Zcmp only) |
| 8 | `bht` | 52.5 | reg→out dense cone | :196 | legacy frontend (hyp8 uses `g6lc_bp_*`) |
| 9 | `g6lc_shared_tlb` | 51.2 | reg→out bundle | :581 | `g6lc_mmu` (UseSharedTlb=0 on hyp8) |
| 10 | `wt_dcache_wbuffer` | 50.1 | reg→out makespan, 7 cycles | :1290 | `wt_dcache_ctrl`/`wt_axi_adapter`/`load_unit` fwd |
| 11 | `g6lc_rename_read` | 49.6 | exclusive case, 20 arms, max_arm 46.6 | :292 `lane_o` | `g6lc_rename` |
| 12 | `wt_dcache_missunit` | 47.4 | reg→out plain | :508 | `wt_axi_adapter`, AMO path |
| 13 | `instr_queue` | 45.1 | exclusive case 26 arms | :450 | `frontend` → `id_stage` |
| 14 | `aes` | 44.9 | reg→out plain | :276 | `ex_stage` (unused by boot) |
| 15 | `store_unit` | 42.3 | reg→out plain | :333 `paddr_to_sb` | `load_store_unit` |
| 16 | `load_unit` | 41.0 | bundle L5 | :1360 publish pick | `load_store_unit` → scoreboard WB |

Rows 2, 4, 6, 8, 9 are **not elaborated** by `g6lc64_hyp8` (hpdcache, PDEC=0, legacy bht, shared TLB):
analyzer floor, not clock. They stay on the all-modules board and off the clock rule (r58b/r64 S6
convention). The live program is rows 1, 3, 5, 7, 10–16.

## 1. Rank 0 — representation only (no cycle, no contract)

**P1 `g6lc_iq` :216 steer (182.4).** Mechanism: `steer_bank[p][k] = (hint+k) % BANKS` then first-fit
over `bank_free` with lane-0-before-lane-1 masking — a `%` on a non-power-of-two expression is billed
as a divider (A146 §4: "parameter arithmetic in bounds" class), and the first-fit is a BANKS-deep
priority chain per lane. Transform: (a) `BANKS` is a power of two in every config → rotate the
`bank_free` one-hot by `hint` (A104 one-hot rotate; the modulo disappears), (b) first-fit as
lowest-set `x & -x` on the rotated vector, rotate back (A140 isolate form), (c) lane 1 excludes lane 0's
pick by a one-hot AND, not a sequential re-scan. Expected: 182 → ~20 (the `%` is most of the number).
Verification: existing dispatch leaf (`HYP8_DISPATCH_PASS`) + a translate_off equivalence of
`asgn`/`group_fits` vs the old form, A136 convention. Caller contract unchanged (`disp_ack_o`).

**P2 `g6lc_rename_read` :292 (49.6, `lane_o` 20 arms, max_arm 46.6).** The arm cost, not the mux,
is the limiter: one arm carries a 46.6 cone (a RAT read indexed by a renamed tag then a lane select).
Transform: A118 late-select — resolve the 20 arms' *select* from registered lane metadata while the
arm payloads (RAT rows) are read in parallel, then a balanced mux (A37); if the arm's inner cone is a
`rs == prev.rd` CAM, predecode `rd` one-hot at the record write (A120, as proposed for
`rename_resolve` :138 in execution-path-plan §5a item 1c). Expected ~49.6 → ~25. Verification:
`run_ooo_rename_prove/cover` + `hyp8_raw_window.S`.

**P3 `g6lc_iq_legal` :122 (19.5 after r68b).** The pairwise `ooo_age_older` frontier matrix is two
5-bit subtracts + a compare per (b,bb) pair. Store the age key `tid - commit_ptr` with the bank
frontier report (the frontier is registered one level up in the bank: A134 "cache the state-only side
at its update edge"; commit_ptr moves at most by `NrCommitPorts` per cycle, so the key is refreshed
from the registered pointer and a bank-side subtract is one adder off the merge cone). Expected
19.5 → ~12. Verification: `g6lc_t1_iqleg_oh`/`_eq` references already recompute the old form.

**P4 `g6lc_decode_s3` :275 / `macro_decoder` :398 (53.7 / 52.9, independent-LHS bundles).** Bundle
makespans with `max_field` ≪ total: analyzer floor from one `always_comb` writing 58/19 LHS. Rank-0
only as hygiene: split the block per output family (A22 parallel arms) so each LHS bills alone; no
depth change expected on the real cone. Low priority; do after P1–P3.

## 2. Rank 1 — a register with both-end ownership written first

**P5 `g6lc_lsq` :1206 (72.2 in→reg).** Verdict tournament → slot update in one cycle (the
execution-path-plan §5 row). The r52 age matrix removed the rank popcounts (lsq_reduce 29.9 → 15.1);
what remains is CAM bank result → reduce → verdict → slot write. Design: register the per-bank
reduce (`g6lc_lsq_reduce` outputs) before `g6lc_lsq_verdict` — the verdict then starts from registers
(A118 "remove serial control before adding cycles" is exhausted here; PL-P2 reservation-before-state
applies). Contract: `ld_checked` for the affected load moves one cycle later; `sb_commit_bundle`'s
`ld_checked_i` gate already tolerates late checks (a load is merely not committable one cycle longer);
`g6lc_memdep` replay identity must carry the generation across the extra edge (Batch C obligation).
Knob: `HypCfg.LsqVerdictStages ∈ {1,2}`; latency table `ld_checked` +1. Expected 72 → ~40 (then
the CAM bank at 40.8 in→reg is the next limiter: §5a item 2's `be`-at-write-edge rewrite, rank 0).
Verification: `HYP8_LSQ_PASS` leaf (G1/G2a/G2b) + a generation-reuse case; smokes; one witness.

**P6 `load_unit` :1360 (41.0, L5 publish pick) — r64 S1 as designed.** Dedicated exception
completion lane (`NrWbPorts+1`, `we=0`, `ex.valid=1`): the publish pick loses its `ex_pend` arms.
Callers: scoreboard (`NrWbPorts` is parametric), `sb_commit_bundle` (exception merge pairs by
trans_id on any lane — unchanged), rvfi probes (+1 port), `g6lc_flu_reserve` (lane is
exception-only, reserves nothing). Expected 41 → ≤ 25.

**P7 `store_unit` :333 (42.3, `paddr_to_sb` / FSM reg→out).** The r42-T R6 classification stands:
the launch is the DTLB PPN mux inside the MMU (paddr_i) → cbo.zero align → store buffer. Rank-1
form: register `paddr_i` at the SU with its `trans_id_q` (the `LsuAguStages==2` seam already exists
for the AGU side; this is the translation side) — `st_valid` then presents one cycle after
translation. Contract: `page_offset_matches`/`st_fwd` consumers see the store's address one cycle
later → a load that would have matched in that cycle must stall or replay (the T33 `spec_only`
mechanism exists). Knob `HypCfg.StoreTransStages`. Lower priority than P5/P6: the store→load forward
path is latency-sensitive (`StoreFwdCycles=3`).

**P8 `wt_dcache_wbuffer` :1290 (50.1, 7-cycle makespan, 15 deps).** The A146 dependency floor:
coalesce compare → bypass-allocate → post-push supersede. Only the Batch E design closes it
(per-entry versioned pending writes; admission/coalesce/dispatch/return/invalidate as separate
state). Rank 2 in effort though rank 1 in latency (drain unchanged). Schedule after P5/P6.

## 3. Rank 2 — caller-contract changes (knob + legality + latency table + witness)

**P9 `g6lc_iq_bank` 32.3 / `g6lc_iq_arb` 30.6 — r64 S2 `IqSelStages`.** Register `cand0/1_oh`
(+ the ready snapshot used by the kill sweep) at a SEL/PAY edge; wakeup tables +1 for every class
exactly as `IqArbStages` did; r47 sticky kill must cover the new edge. +1 issue latency on every
instruction — do it only once P1–P6 have moved the board, and measure IPC on the smokes (cycle counts
must change, instruction counts must not).

**P10 `instr_queue` :450 (45.1, 26-arm exclusive)** and **`g6lc_rename_recover` 31.8 (S3)** —
frontend/recovery items: the 26-arm `instr_data_in` select is the realigner→queue parcel placement;
rank 0 as a one-hot placement (A104) first, then S3's two-edge recovery window if still over.

## 4. Order, gates and what is deliberately not implied

Order: **P1 → P3 → P2 → P4 (rank 0, one board each, no sim beyond the existing leaves)** → **P5 →
P6** (rank 1, leaf + smokes + one witness each) → **P7 → P8 → P9 → P10**. Each item records: the
operation protocol crossing the new boundary (`svt-pipe` lines), measured in→reg / reg→reg / reg→out
separately, the consumer tolerance the stage window represents, and the paired placed/unplaced
reading only for a retained rank-1 candidate (A137/A138). No stage count is claimed from
`ceil(D/8)`; no physical frequency is quoted without `fo4_ps`; nothing here is a boot result.
