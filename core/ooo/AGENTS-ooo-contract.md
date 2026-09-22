# OoO + SMT2 architecture contract (`core/ooo`, `core/smt`, LSU seams)

This is the contract of record for the config-gated out-of-order backend and its path to
mixed-resident SMT2. It states structures, owners, the age key, kill identities, what may issue
out of order, what stays singleton, the timing cones of record and the exit of every tranche.
It is short on purpose. History is in `architecture/out-of-order/log-2026-09.md`; the step plan
is `AGENTS-ooo-plan.md`. A claim that is not in this file with an evidence pointer is not a claim.

Status words used below: **live** (elaborates and simulates behind `OoOEn`), **leaf-qualified**
(directed fixture with positive, negative and restored-defect mutation), **integrated** (full
core, independent reference), **open**. Nothing here is release-qualified; `OoOEn=0` remains the
protected default and the SMT2 OpenSBI anchor runs with `OoOEn=0`.

## 1. Structures and owners

| Structure | File | Owns | Status |
|---|---|---|---|
| Scoreboard | `core/scoreboard.sv` | slot allocation in program order, `trans_id`, in-order commit pointer, younger-than-branch cancel mask | live (in-order baseline) |
| Rename / RAT / free list | `g6lc_rename.sv`, `g6lc_rat.sv`, `g6lc_freelist.sv` | architectural→physical maps per hart, checkpoints per branch, busy bits | leaf-qualified (integer, FP class, NrHarts=2 maps) |
| Issue queue | `g6lc_iq.sv` | operand readiness, oldest-ready select up to `NrIssuePorts` | live; compacting; a load waits only on older **unresolved** stores unless its dispatch-time `may_bypass` verdict clears it; stores issue out of order; only fence/system CSR-class ops wait for the commit head (T2) |
| ROB | `g6lc_rob.sv` | completion-by-tid shadow of the scoreboard | live; not the commit authority |
| LSQ | `g6lc_lsq.sv` | load/store entries allocated at dispatch, live AGU addresses, store data, CAM/STL hazard verdict, alias validation (`mem_violation`) | leaf-qualified + formal; a store entry is the reservation of its speculative-queue slot and lives until commit; a completed load stays until no older store is unresolved (T2) |
| Store buffer | `core/store_buffer.sv` | speculative queue (age-sorted under OoO) and committed queue; byte-exact forward | live; committed entries exempt from age compare; speculative entries assert scoreboard liveness (T2) |
| Memdep predictor | `g6lc_memdep.sv` | store-set table queried at **dispatch** (port 0), trained on real violations by the violating load's PC | live under `MemDepPredEn`; without it no load bypasses an unresolved store |
| PRF | `g6lc_prf.sv` | write-through physical file, integer and FP classes | leaf-qualified |
| FU owner tables | `core/fpu_wrap.sv`, `core/mult.sv` | one live token per tid for FPnew and the serial divider; cancelled result suppression; flush clears | leaf-qualified (8/16 slots; 32 does not exercise overlap) |
| LSU tombstones | `core/lsu_bypass.sv`, `core/load_unit.sv` | pre-grant cancellation retention, post-grant response tombstones | leaf-qualified |
| CSR buffer | `core/csr_buffer.sv` | in order: depth-1 address hold (bit-identical); under `OoOEn`: two-entry per-tid address table looked up by the committing tid, credit gates only CSR issue | leaf-qualified (T2); the FLU no longer freezes on a pending CSR |
| Thread select | `core/smt/g6lc_thread_select.sv` | drained coarse handoff between harts | leaf-qualified sims + live-port synthesis |

## 2. Age

- Key: `trans_id` circular distance from the scoreboard commit pointer,
  `(a - commit_ptr) < (b - commit_ptr)` ⇒ `a` older than `b`.
- Soundness condition: every compared entry is **scoreboard-live**. Committed store-queue entries
  are never age-compared; they are older than any live instruction by construction.
- T1 (2026-09-21): one function, `g6lc_ooo_pkg::ooo_age_older/ooo_age_dist`, used at all six
  sites (`g6lc_iq.sv` ×2, `g6lc_lsq.sv` CAM, `core/store_buffer.sv` `ooo_older` which feeds
  `spec_visible` and the insertion sort). IQ and LSQ entries assert `sb_live_i[tid]` (scoreboard
  `issued`) under `translate_off`; the store-buffer copy of that assertion waits for T2, which
  plumbs the LSU seam anyway. Proof: `core/ooo/formal/g6lc_ooo_age.sby` (abc bmc3, depth 14,
  74 asserts) and the yosys-sat harness `run_ooo_fault_review.py FAULT_REVIEW_AGE_FORMAL=1`
  (prove SUCCESS depth 14, cover of a reachable violation, removed-scan mutation FAIL with
  witness). `{gen,tid}` widening was not needed.

## 3. Kill identities

| Event | Identity | Who must not forget |
|---|---|---|
| Branch mispredict | scoreboard `cancelled_mask` (sticky per slot + same-cycle window) | IQ, ROB, LSQ, PRF write gate, FU owner tables, LSU pre-grant queue |
| Full flush (exception, fence, CSR side effect, WFI under OoO) | `flush_i` | FPnew and serdiv discard in-flight work, so owner tables clear; LSU tombstones stay |
| Fetch redirect (T3) | every accepted I$ request carries a 2-bit token (`icache_dreq_t.token`, echoed on `icache_drsp_t.token` by `g6lc_icache`); the frontend wants exactly one outstanding token (`want_valid_q/want_token_q`), forgets it on `kill_s1|kill_s2`, treats a request accepted in a kill cycle as unwanted, and takes a response only on token match | proven by `core/fetch_B/formal/g6lc_fetch_token.sby` against an independent I$ ledger (depth 10, 4 asserts; removed take gate → counterexample); frozen stage-32 layout pair passes; the VA-equality kill and `G6LC_NO_KILL_PERSIST` are retired |
| Memory-order violation | `g6lc_lsq` scan: a store address arriving after a younger load resolved overlapping bytes reports the oldest such load (`mem_violation_o`); the scoreboard marks the slot `cancelled + replay`; commit drops it, asserts `flush_commit`, and the frontend refetches `pc_commit` without increment (`mem_replay_pc`) | leaf-qualified (LSQ 12–17, formal) and exercised end-to-end on `g6lc64_ooo_int` since T2 (stage 35: `drop=1 replay=1` then clean retirement, Spike-identical) |
| Hart handoff | drained: no issued work crosses | T6 replaces drain with per-hart cancellation identity |

A cancelled instruction's late result must never complete, wake or supply data for the slot's next
owner. FPU and divider hold this; the dispatch leaf (scenario 18) still accepts an id-only late
result, so the remaining producers (pending stores, CSR/AMO commit path, CVXIF/accelerator) are open.

## 4. Issue legality

| May issue out of program order | Stays singleton / ordered | Reason |
|---|---|---|
| ALU, branch, multiply, FP (single hart) | fence/system CSR-class ops (SFENCE/HFENCE/FENCE/WFI/xRET): only at the commit head | their side effects are global; `ex_stage` snapshots fence operands at issue |
| CSR read/write/set/clear (T2) | — | two-entry per-tid `csr_buffer`; value read/written at in-order commit; write operand from the renamed file |
| Loads past **resolved** older stores (T2) | Loads wait on older **unresolved** stores unless `may_bypass` | the store buffer forwards byte-exactly from resolved stores; bypassing an unresolved one relies on the T1 violation scan + replay |
| Stores relative to each other (T2) | Stores drain to memory in program order | LSQ store entry = spec-queue slot reservation held to commit; `check`: `LsqStoreEntries <= DEPTH_SPEC` (`gen_err_ooo_st_credits`) |
| — | AMO buffer depth 1, CVXIF port 0 only; one store translation pipe | unchanged |

## 5. Timing cones of record (FO4 screen, not STA)

`sparse_issue_lsu` (IQ select, store-age scan, LSQ CAM), `sparse_ex` (FLU mux, owner-table
lookups). Budget ≈ 32 FO4 at 1.25 GHz / `fo4_ps=20` / margin 0.2. Every tranche records the screen
before and after; a screen never closes timing. Compaction of the IQ each cycle is the known cost
T4 removes.

## 6. Configuration guards and the evidence that removes each

| Guard (`config_pkg::check_cfg` + `g6lc_ooo_dispatch` `$error`) | Removal evidence |
|---|---|
| `!(OoOEn && FpPresent)` | T5: Spike-ordered FP suite + cancelled-DIVSQRT mutation on `g6lc64_ooo`, single hart |
| `!(OoOEn && NrHarts > 1)` | T6: hart-tagged IQ/ROB/LSQ, per-hart commit heads/credits, peer-isolation negatives |
| `!(OoOEn && FpPresent && FLen > XLEN)` | not planned; documents a pre-existing bus width |
| `SliceOoOEn ⊕ OoOEn` | permanent |

## 7. Exits

| Tranche | Exit (positive + negative + mutation + structural) |
|---|---|
| T0 | history archived verbatim; this contract and the plan exist; checkpoint commit reviewed |
| T1 | **met 2026-09-21**: age function at all six sites; IQ/LSQ live-tid assertions; `g6lc_ooo_age.sby` PASS (74 asserts, depth 14) + sat prove/cover/mutation; LSQ scenarios 12–17 positive/negative; dispatch 28/28, LSU 32/32, WFI 56/56, commit 3/3 unchanged; integer-OoO frozen ELFs Spike-identical; protected in-order anchor 12,765,628 / 333,635 / 8,932,406; lint 8/54, synth 32/5 unchanged. Found and fixed: `g6lc_ooo_rob.sby` had proved zero assertions (no `-DFORMAL`, `dist` keyword, hierarchy flag); now abc bmc3 PASS with 4 asserts. Attributed: +3 cycles on every integer-OoO ELF versus the 09-19 baselines is the CSR-at-commit-head issue rule inside `48c729e51` (younger ALU ops pass the waiting `csrw` at the exit epilogue); T2 removes it |
| T2 | **met 2026-09-21**: csrbuf 10/10 (OoO + in-order identity); IQ 10 scenarios × 4 geometries; LSQ 19+19; dispatch 28/28 on n2 and mdp1 (`-Werror-UNOPTFLAT`); store-recovery/WFI/commit unchanged; age formal PASS (74 asserts) + sat/mutation; `g6lc64_ooo_int` frozen ELFs Spike-identical with stage 35 showing `replay=1` drop then clean retirement, stages 36/37 pass, negatives fail 3/3/1; ILP 1117 (from 1112 — the CSR wait is gone but the exit `csrw` now flushes younger issued work; T4 measures), memdep 1021 (from 1060), s4 842 (from 881); protected in-order anchor 12,765,628 / 333,635 / 8,932,406; lint 8/54, synth 32/5; FO4 screen unchanged (sparse cones exclude IQ/LSQ). Found on the way: completed loads must stay in the LSQ while an older store is unresolved or the violation scan has nothing to replay (stage 20 caught it). Open: dispatch scenario 18 (unchanged since T1) |
| T3 | **met 2026-09-21**: token kill with the ledger proof and mutation witness; frozen s32 layout pair 869/868 pass; stages 32/33/34 pass Spike-compared (869/899/869) where they aborted before; `load_unit.sv` misalignment assertions replaced by precise-delivery properties (`misaligned_entry_excepts/no_data/tval`), leaf scenario 13 with kill/ex mutations detected; `G6LC_NO_KILL_PERSIST` retired; anchor exact; verify 6/6 locally incl. strict slang (lint 263/58, synth 32/5). Found pre-existing: `g6lc_fetch_hold` fails at frame 4 and `g6lc_fetch_iq` bmc at frame 3 on HEAD too — open formal regressions, owner T4 pre-work |
| T4 | non-compacting IQ; same directed results; FO4 delta recorded |
| T5 | FP guard removed for `NrHarts==1` only |
| T6 | both harts perform checked work concurrently; drained handoff retired only after peer-isolation negatives |

Standing gates for every tranche: `verify --lint --synth --remote`, leaf audit cells with
negatives and mutations, protected SMT2 anchor unchanged, traceability records updated,
licensing tier check on every code edit.
