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
| Issue queue | `g6lc_iq.sv` | operand readiness, oldest-ready select up to `NrIssuePorts` | live; **stationary entries with a DEPTH² age matrix and rank select (T4)** — no payload movement; a load waits only on older **unresolved** stores unless its dispatch-time `may_bypass` verdict clears it; stores issue out of order; only fence/system CSR-class ops wait for the commit head (T2) |
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

- Key: `trans_id` circular distance from the scoreboard **reclaim pointer** (`reclaim_ptr_o`, the
  oldest live slot), `(a - reclaim) < (b - reclaim)` ⇒ `a` older than `b`. Under legacy commit
  order (single hart, drained handoff) the reclaim pointer *is* the port-0 commit pointer, so the
  key is unchanged there; under mixed residency (T6b-4b) the two diverge — the committing port-0
  slot may be a younger privileged head — and only the reclaim pointer keeps every live distance
  inside one contiguous window `[reclaim, issue_ptr)`. Consumers: dispatch/IQ/LSQ `commit_ptr_i`,
  `store_buffer.oldest_live_tid_i`. The committing tid (`commit_tran_id_o`, CSR table lookup,
  store-buffer head match) is a different signal and is never used as an age anchor.
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
| Instruction-queue replay with an FTQ (T5 finding) | `replay_q` is a reseed like `bp_fire`: FTQ and FDIP flushed, the stale head not demanded, `seq_base` rewound to `replay_addr_q`; in-flight responses die by token | fixed 2026-09-21 in `frontend.sv`: before it, stale sequential FTQ entries were served ahead of the refused window and the per-slot instruction FIFOs lost alignment (one window skipped in OoO, livelock in order) on every `FtqDepth != 0` configuration — `g6lc64_smt2` (FtqDepth=0) was never exposed. The residual two-window loss had a second cause, also fixed the same day: an FDIP prefetch response was consumed as supply when the head's demand had been refused; the outstanding token now remembers it belongs to a prefetch (`want_pf_q`) and such a response only warms the I$. `ooo_fetch_head_reuse_int` passes Spike-identically on all three FtqDepth=4 models |
| Non-idempotent (device) load at the commit head (T6a finding) | waits for `dcache_wbuffer_not_ni` and, under OoO, for the **committed** store queue only (`no_st_pending`); in order it still waits for the whole store buffer | fixed 2026-09-23 in `load_unit.sv`: under OoO a younger store that issued early sits in the speculative queue until *its* commit, which cannot precede the older load's, so waiting for `store_buffer_empty` deadlocked the core on the first UART poll with a speculative store behind it (dual-hart OpenSBI profile: hart0 stopped retiring at cycle 10,584,092 in `prints`). Any OoO configuration with a device region was exposed; the integer firmware vehicle has none |
| Branch resolving in the cycle of an older architectural redirect (T6a finding) | `is_mispredict` is qualified with `!misp_outranked` (trap, eret, PC_COMMIT for this hart): the branch is younger than the redirect and squashed by it, so it must not arm `bp_pend/bp_tgt`, kill, or reseed | fixed 2026-09-23 in `frontend.sv`. With OoO issue a memory-order replay at commit and a younger branch's (stale-data) mispredict do coincide: the commit source won `arch_src` but the mispredict still armed the target filter, the replay window was rejected and fetch resumed at the squashed target — committed-path instructions `0x8000a10e–0x8000a120` skipped in the dual-hart profile, then a garbage npc and a silent frontend. In order the two never meet. `g6lc_fetch_hold` gained the property (8 asserts, PASS; removing the gate: counterexample at frame 3) |
| Prediction firing while the instruction queue is not ready (FtqDepth != 0; SB=16 finding) | the CF hold (`cf_hold_q`) is armed only when the target was actually pushed; an unpushed target stays in `npc_q` and is pushed when the queue is ready again | fixed 2026-09-23 in `frontend.sv`: the hold used to arm on every `bp_fire`, and with the FTQ flushed by the same prediction and the push refused, nothing was ever demanded again — the frontend fell silent forever (`ooo_fp_cancel_tid_reuse` on a 16-entry scoreboard, whose backpressure fills the queue at a predicted back-edge). FtqDepth=0 models are byte-identical. Pinned in the FTQD=4 token proof (5 asserts, PASS; old behaviour fails at frame 5) |
| Memory ordering across harts (T6b-1) | a load orders against, forwards from, and replays for stores of **its own hart** only (LSQ `hart` tags, `st_hart_mask_o[h]` into the IQ gate, store-buffer speculative forwarding same-hart under `OoOEn && NrHarts > 1`); committed stores are visible to every hart | landed 2026-09-23; inert under the drained handoff (one resident hart) and constant-folded for `NrHarts == 1`. Mixed residency itself stays refused (`SmtDrainedHandoff` must be 1 outside `G6LC_OOO_SMT_MIXED_QUALIFY`) |
| Fetch redirect (T3) | every accepted I$ request carries a 2-bit token (`icache_dreq_t.token`, echoed on `icache_drsp_t.token` by `g6lc_icache`); the frontend wants exactly one outstanding token (`want_valid_q/want_token_q`), forgets it on `kill_s1|kill_s2`, treats a request accepted in a kill cycle as unwanted, and takes a response only on token match | proven by `core/fetch_B/formal/g6lc_fetch_token.sby` against an independent I$ ledger (depth 10, 4 asserts; removed take gate → counterexample); frozen stage-32 layout pair passes; the VA-equality kill and `G6LC_NO_KILL_PERSIST` are retired |
| Memory-order violation | `g6lc_lsq` scan: a store address arriving after a younger load resolved overlapping bytes reports the oldest such load (`mem_violation_o`); the scoreboard marks the slot `cancelled + replay`; commit drops it, asserts `flush_commit`, and the frontend refetches `pc_commit` without increment (`mem_replay_pc`) | leaf-qualified (LSQ 12–17, formal) and exercised end-to-end on `g6lc64_ooo_int` since T2 (stage 35: `drop=1 replay=1` then clean retirement, Spike-identical) |
| Hart handoff | drained: no issued work crosses | T6 replaces drain with per-hart cancellation identity |
| Commit under mixed residency (T6b-4b) | one shared ring, **per-hart commit heads**: `head_slot[h]` is hart h's oldest live slot (rotate/find-first from the reclaim pointer); the reclaim pointer jumps each cycle to the oldest slot still live, so committed non-head holes are never allocatable (window accounting `free = NR − (issue_ptr − reclaim)`, popcount retired under `MixedSmt`). **Port 0** is the only side-effect port: it presents the ring-oldest *committable flush-capable-privileged* head (`sbe.ex.valid`, CSR-class fu — CSR/fence/sfence/hfence/WFI/xRET/ecall/ebreak —, replay/drop, AMO) when one exists, else the reclaim entry. **Port 1** presents the legacy same-hart `+1` slot only when both halves are complete (the pair can retire together); otherwise the other hart's head, which commits only if it is a complete `ALU/LOAD/CTRL_FLOW/MULT`, `!ex.valid`, `!replay`, its own hart's `dcsr.step` clear, no `halt`/`flush_dcache`, **not a full-flush cycle** (`flush_i`) and not a cycle in which port 0 acks a privileged entry. No FPU/FPU_VEC cross-hart (fflags is a port-0 bank channel); at most one commit per hart per cycle except the legacy pair | consumers made non-positional: `g6lc_rob` frees by tid; the store buffer commits a store only when it is the speculative-queue head (`spec_head_mismatch` stalls `commit_ready_o`); the CSR bank routes each port's ack by that port's hart (`commit_hart_i`) so `instret` and every banked ack land in the committing hart; RVFI/trace ids are the muxed port slots. Peer-restart frontier hazard found by the mixed probe (a cross-hart port-1 retire on a full-flush cycle was refetched and executed twice) is what the `flush_i` gate and `SBC_P1_FLUSH` pin |

A cancelled instruction's late result must never complete, wake or supply data for the slot's next
owner. FPU and divider hold this; the dispatch leaf (scenario 18) still accepts an id-only late
result, so the remaining producers (pending stores, CSR/AMO commit path, CVXIF/accelerator) are open.

## 4. Issue legality

| May issue out of program order | Stays singleton / ordered | Reason |
|---|---|---|
| ALU, branch, multiply, FP (single hart) | fence/system CSR-class ops (SFENCE/HFENCE/FENCE/WFI/xRET): only at the commit head | their side effects are global; `ex_stage` snapshots fence operands at issue |
| — (T6b-4b) | a privileged head becomes port-0-eligible only once it is **committable** (`sbe.valid`, cancelled or replay-marked) | an un-issuable system op (still waiting on the IQ global-oldest gate) must not take port 0: it would park the port behind the reclaim entry whose commit is exactly what it waits on — observed as a hart-0 `mret` / hart-1 store-head deadlock during T6b-4b bring-up |
| CSR read/write/set/clear (T2) | — | two-entry per-tid `csr_buffer`; value read/written at in-order commit; write operand from the renamed file |
| Loads past **resolved** older stores (T2) | Loads wait on older **unresolved** stores unless `may_bypass` | the store buffer forwards byte-exactly from resolved stores; bypassing an unresolved one relies on the T1 violation scan + replay |
| Stores relative to each other (T2) | Stores drain to memory in program order | LSQ store entry = spec-queue slot reservation held to commit; `check`: `LsqStoreEntries <= DEPTH_SPEC` (`gen_err_ooo_st_credits`) |
| — | AMO buffer depth 1, CVXIF port 0 only; one store translation pipe | unchanged |

## 5. Timing cones of record (FO4 screen, not STA)

`sparse_ooo_issue` (IQ wakeup→ready→rank→grant, unresolved-store scan, LSQ CAM, rename, dispatch),
`sparse_issue_lsu` (in-order issue, scoreboard, LSU), `sparse_ex` (FLU mux, owner-table lookups).
Budget ≈ 32 FO4 at 1.25 GHz / `fo4_ps=20` / margin 0.2. Every tranche records the screen before and
after; a screen never closes timing. T4 removed the IQ payload compaction (23.97 → 14.97 adj FO4);
T4b replaced the per-entry rank popcount with a cascaded oldest-first grant, bringing the select
cone from 27.0 back to **16.0** (IQ module max 16.0, from 23.97 before T4). `g6lc_ooo_dispatch` at
30.0 is the slice's worst cone and the next timing owner; `g6lc_lsq` CAM 26.0, `g6lc_rob` 22.0.
T6b-4b added `sparse_smt_mixed_commit` (`g6lc64_smt2_mixed_xlen64.json`: NrHarts=2,
SmtDrainedHandoff=0, OoOEn=1, 8-entry ring) because `sparse_issue_lsu` binds `cva6_cfg_empty` and
folds `MixedSmt` to 0 — its scoreboard/commit numbers measure the legacy mux only. Mixed screen:
scoreboard **19.0** (reclaim scan), commit_stage 16.0 (legacy AMO wdata mux), store_buffer 17.46,
g6lc_rob 22.0; closes at the 32 budget. Re-screen before any mixed configuration with a larger ring.

## 6. Configuration guards and the evidence that removes each

| Guard (`config_pkg::check_cfg` + `g6lc_ooo_dispatch` `$error`) | Removal evidence |
|---|---|
| `!(OoOEn && FpPresent)` (single hart, `ifndef G6LC_OOO_FP_QUALIFY`) | T5: Spike-ordered FP suite passes on the qualification build; the FPU owner-retention mutation is unobservable at core level (SB=32 and SB=16) and caught only by the S2 leaf — **kept** by user decision 2026-09-23 |
| ~~`!(OoOEn && NrHarts > 1)`~~ **removed 2026-09-23** | T6a: under the drained handoff (thread selector switches only on `sb_empty && no_st_pending`, witnessed by `ooo_switch_drained`) the protected dual-hart profile passes strictDual on `g6lc64_smt2_ooo_int`; two-hart rename/dispatch cells; anchor exact. Mixed residency remains excluded by the drain gate until T6b |
| `!(OoOEn && NrHarts > 1 && FpPresent)` (`gen_err_ooo_fp_mh`) | T6b: hart-tagged lazy-FS |
| `!(OoOEn && FpPresent && FLen > XLEN)` | not planned; documents a pre-existing bus width |
| `SliceOoOEn ⊕ OoOEn` | permanent |

## 7. Exits

| Tranche | Exit (positive + negative + mutation + structural) |
|---|---|
| T0 | history archived verbatim; this contract and the plan exist; checkpoint commit reviewed |
| T1 | **met 2026-09-21**: age function at all six sites; IQ/LSQ live-tid assertions; `g6lc_ooo_age.sby` PASS (74 asserts, depth 14) + sat prove/cover/mutation; LSQ scenarios 12–17 positive/negative; dispatch 28/28, LSU 32/32, WFI 56/56, commit 3/3 unchanged; integer-OoO frozen ELFs Spike-identical; protected in-order anchor 12,765,628 / 333,635 / 8,932,406; lint 8/54, synth 32/5 unchanged. Found and fixed: `g6lc_ooo_rob.sby` had proved zero assertions (no `-DFORMAL`, `dist` keyword, hierarchy flag); now abc bmc3 PASS with 4 asserts. Attributed: +3 cycles on every integer-OoO ELF versus the 09-19 baselines is the CSR-at-commit-head issue rule inside `48c729e51` (younger ALU ops pass the waiting `csrw` at the exit epilogue); T2 removes it |
| T2 | **met 2026-09-21**: csrbuf 10/10 (OoO + in-order identity); IQ 10 scenarios × 4 geometries; LSQ 19+19; dispatch 28/28 on n2 and mdp1 (`-Werror-UNOPTFLAT`); store-recovery/WFI/commit unchanged; age formal PASS (74 asserts) + sat/mutation; `g6lc64_ooo_int` frozen ELFs Spike-identical with stage 35 showing `replay=1` drop then clean retirement, stages 36/37 pass, negatives fail 3/3/1; ILP 1117 (from 1112 — the CSR wait is gone but the exit `csrw` now flushes younger issued work; T4 measures), memdep 1021 (from 1060), s4 842 (from 881); protected in-order anchor 12,765,628 / 333,635 / 8,932,406; lint 8/54, synth 32/5; FO4 screen unchanged (sparse cones exclude IQ/LSQ). Found on the way: completed loads must stay in the LSQ while an older store is unresolved or the violation scan has nothing to replay (stage 20 caught it). Open: dispatch scenario 18 (unchanged since T1) |
| T3 | **met 2026-09-21**: token kill with the ledger proof and mutation witness; frozen s32 layout pair 869/868 pass; stages 32/33/34 pass Spike-compared (869/899/869) where they aborted before; `load_unit.sv` misalignment assertions replaced by precise-delivery properties (`misaligned_entry_excepts/no_data/tval`), leaf scenario 13 with kill/ex mutations detected; `G6LC_NO_KILL_PERSIST` retired; anchor exact; verify 6/6 locally incl. strict slang (lint 263/58, synth 32/5). Found pre-existing: `g6lc_fetch_hold` fails at frame 4 and `g6lc_fetch_iq` bmc at frame 3 on HEAD too — open formal regressions, owner T4 pre-work |
| T4 | **met 2026-09-21** (T4 + T4b): stationary IQ with age matrix and cascaded oldest-first grant (rank popcount kept sim-only as `ooo_iq_grant_is_rank`); IQ 64/64, dispatch 28/28 ×2, ten frozen ELFs cycle-identical in both passes, anchor exact, lint/synth unchanged; FO4 §5: IQ module max 23.97 → 16.0 (payload 14.97, select 16.0). Store-age scan and FP `rs3` remain inside the select predicate — costed at 16.0, not removed. Fetch proofs repaired on the property side: hold 7 asserts PASS, IQ non-interference 9 asserts PASS. Open: IQ cover task timeout; `g6lc_ooo_dispatch` 30.0 cone |
| T5 | **partial 2026-09-21**: on the qualification build (`G6LC_OOO_FP_QUALIFY`, single hart) 13 FP positives pass Spike-identically and all 10 negatives report their stage; the LSQ alias mutation is caught by stage 4; the FPU owner-retention mutation is **inert at core level** on every stage tried (1, 9, 10) — with 32 scoreboard entries and drop-at-commit-head every stale return lands on a dead or not-yet-reallocated slot (detected only by the S2 leaf fixture). **The production guard stays** (`ifndef` seam only; `verify --target g6lc64_ooo` still refuses). The suite also exposed the FTQ replay defect (§3). Still owed: the owner-mutation bar, the s11 residual, the guard decision |
| T6 | **T6a gate PASSED 2026-09-23** (plan): after the outranked-mispredict and device-load fixes above, the protected dual-hart profile passes strictDual on `g6lc64_smt2_ooo_int` in 10,696,498 cycles (in order 12,765,628), every switch drained, two-hart rename/dispatch cells pass, anchor exact. The earlier "lottery divergence" was a misreading (the boot hart's bss/relocation loops sit in fw_base.S; boot hart 0 in every OoO run). **Guard lifted 2026-09-23** (user decision): `g6lc64_smt2_ooo_int` is a production package (define-free build passes the same profile identically, 10,696,498 cycles); the single-hart FP guard stays. **T6b-1…T6b-3 landed 2026-09-23/24** (hart-owned memory ordering, per-hart recovery, per-access translation/privilege/PMP context, isolation negatives 7/7, first `SmtDrainedHandoff=0` dual-hart OpenSBI pass; see plan). **T6b-4b met 2026-09-24**: per-hart commit heads over the shared ring (§3 row) — sbcommit leaf 7/7 + `G6LC_MUT_SB_POPCOUNT_FREE` caught by `SBC_NO_OVERWRITE`; store-buffer head gate 38/38 (`STB_HEAD_STALL`); ROB tid-keyed free leaf + `G6LC_MUT_ROB_POSITIONAL_FREE` caught, `g6lc_ooo_rob.sby` PASS with 4 elaborated asserts; CSR bank `CSRBANK_ACK_PORT` 14/14; dispatch 28/28; mixed probe hart-1 checksum exact with `cross_hart_port1_commits` 24,086 and `hol_residual` 26,215 (0.8%); drained/anchor probes cycle-exact (3,013,247 / 3,214,702); OpenSBI dual-hart mixed 10,606,940 (= T6b-3), drained **10,696,498 exact**, anchor **12,765,628 exact**; 11 integer ELFs cycle-identical, FP 14 + 10 negatives; lint 8/54, synth 32/5; mixed FO4 screen closes (§5). Found on the way: a cross-hart port-1 retire on a full-flush cycle was refetched by the peer-restart frontier and executed twice (fixed by the `flush_i` gate, pinned by `SBC_P1_FLUSH`); an un-issuable privileged head taking port 0 deadlocked against the reclaim entry (committable qualification, §4). Mixed residency remains qualification-gated (`G6LC_OOO_SMT_MIXED_QUALIFY`); T6b-4 performance (hart-selective kill, per-hart fetch queues, PRF/LSQ floors) is open |

Standing gates for every tranche: `verify --lint --synth --remote`, leaf audit cells with
negatives and mutations, protected SMT2 anchor unchanged, traceability records updated,
licensing tier check on every code edit.

## 8. OoO coherence continuation (2026-09-24; implementation gates open)

The authorized continuation preserves the in-order implementation and all existing FP/mixed-SMT
qualification guards. Its invariant is conservation of owned memory obligations from admission
through response, invalidation, architectural validation and retirement. Queue acceptance is not
invalidation completion; virtual AGU addresses are not physical snoop addresses; instruction
cancellation does not remove a cache's possible sharership.

The dependency chain is measurement validity → shared transport/refill correctness → conservative
sharer signatures and credit-bound sizing → physical-load validation → matched multicore integration.
Each stage retains its own positive, negative and restored-defect controls. A later passing stage
cannot waive an earlier failure. New coherence behavior remains default-off until its complete
configuration envelope passes. No physical area or STA claim follows from logical storage counts.

The first proposed filter stores monotone per-index core-presence signatures. Empty-cache reset,
complete acquisition coverage, concurrent updates and no unqualified clear are mandatory premises.
Complete acquisition includes writers: any retained copy that can serve a load (write buffer,
post-ACK repair entry) makes its core a sharer, so presence is acquired on AW as well as AR, and
the L1 must drop or refuse such copies when the line is invalidated (plan T7i).
Its abstract finite-state check is not an RTL proof. L2 sizing must prove the current concurrent-fill
lifetime against hub credits; the historical serialized-controller occupancy proof is inapplicable.

The OoO validation boundary must use accepted physical addresses and retain instruction identity
through retirement/cancellation and late responses. It must cover remote modifications and relevant
sibling-hart committed stores without relying on the active fetch hart. Existing LSQ virtual-address
hazard checks remain separate. New validation cannot be enabled merely by adding a hub selector.

**Current implementation boundary:** `COH_OOO` has an SRAM-backed signature branch and explicit
WT/integer/multicore legality checks, but `G6LC_OOO_COH_QUALIFY` is still mandatory. The SRAM
uses byte writes in padded 32-bit words, not a bit-write-only macro. The lookup and initialization
latencies are part of its cost. Leaf simulations, a reduced ten-frame proof, a reached conflict
cover, dropped-update and observation negatives, and generic synthesis are recorded in T7 of the
plan. These first-stage results do not alone close the physical-address/retirement or
applied-invalidation contract above.

**Physical validation candidate (continuation):** the load grant/tag boundary now exports the
checked PA with a saved TID, hart and size; exception, flush and cancellation suppress that event.
The legacy virtual `load_paddr_o` remains unchanged. `COH_OOO` disables its uncertified early STQ
forward shortcut; physical cache/write-buffer forwarding is unchanged. Store-buffer admission
exports its actual PA/owner. These events run through LSU/EX/core/issue/dispatch to the existing
LSQ address storage, which is physical in this mode and retained until retirement or cancellation.
The early issue query is only a conservative page-offset screen. Store/load physical aliases train
the existing predictor; load/load ordering and external/local modifications replay without pretending
to be store-predictor training. PMA-defined non-idempotent loads are never replay candidates.

A modification event holds load retirement for its validation cycle; matching instructions receive
sticky cancellation/replay on the following edge, then use the existing precise drop/restart path.
This gives LSU tombstones a cycle to observe cancellation before the scoreboard slot is freed.
Faults and already-cancelled entries still progress. The commit-facing PA-pending mask is derived
only from registered LSQ state: clearing it combinationally on flush caused a real commit/flush
loop in enabled-core synthesis and was rejected. WT return-decoder invalidation delivery and a
registered committed-cache-write event feed the checker. Full publication ordering, atomic/local-CAS
notification coverage, and multicore integration remain qualification obligations, not inferred
from these wires or the leaf results.

**Reduced promotion stage, authorized by the user (2026-09-24):** accept the current RTL as the
integration baseline and continue verification without redesigning it merely to cover every generic
endpoint. Integration acceptance is a separate milestone from unrestricted silicon production.
For this milestone, use the existing two-source WT-style AXI path, `COH_OOO`, four hub credits,
128 signature entries, L2 enabled and L3 disabled. Preserve source identity and require scoped
positive, negative and counterfactual/mutation checks for write/refill publication, delivery and
response stability. Check both modifiable-only traffic emitted by the current WT shim and
allocate-enabled DRAM traffic; do not claim a cache-fill result from non-allocating transactions.
A modeled WT invalidation consumer is transaction-path evidence, not a full-core/L1 proof.

Generic slaves with L2 bypassed, arbitrarily buffered/non-WT invalidation consumers, broad parameter
coverage, unbounded proofs, full firmware/compliance, PMU/DFT and physical sign-off are deferred
for this integration milestone. Preserve their failures and obligations explicitly; deferral is not
a pass or a claim of support. No assertion, result oracle, security/licensing control, or hardware
qualification guard is weakened. Production defaults and `G6LC_OOO_COH_QUALIFY` remain unchanged;
the existing opt-in mechanism is the way to exercise this accepted integration baseline.

**Integration acceptance and promotion (2026-09-24, rights-holder decision):** the composed
hub+L2 bench (`tb_g6lc_coherence_l2`, `REVIEW_HUB_L2_COMPOSED=1`) drives the unchanged `COH_OOO`
hub into the actual `g6lc_l2_top` with a modeled WT invalidation consumer. With the L2 present the
reader's AR is refused for the whole stalled-write window, admitted only after the memory B, and
the refill returns the written value; the standalone-slave counterexample (scenario 23) is thereby
excluded by the L2 admission rules for this composition. Evidence: small, modifiable-only (the
current axi_shim attribute), stalled (W/B/invalidation/R/B holds) and target (256 KiB, 8-way,
2 MSHR, 4 banks) profiles pass with their negative oracles; `-GUSE_L2=0` reproduces the stale
refill; disconnecting the L2 self-invalidation restores `COH_L2_STALE_VALUE`; a signal-driven
Yosys `scc -expect 0` proves the composed graph loop-free (Verilator's struct-granular UNOPTFLAT
across the seam is therefore treated as a warning in that bench only).

On that basis the rights holder accepted the review and promoted the RTL for the reduced envelope:
`core/include/g6lc64_ooo_int2_config_pkg.sv` (two cores, two harts each, integer OoO, WT, equal
128-bit lines, L2 on, L3 off, `COH_OOO`, 128 signature entries, two-deep invalidation queue) is a
first-class target, and the `G6LC_OOO_COH_QUALIFY` requirement was removed from `check_cfg` and
the cluster. The `COH_OOO` legality assert, `gen_bad_ooo_coherence`, default-target packages and
all production defaults are unchanged. Promotion is a configuration-availability decision: the
deferred obligations below remain open and are not implied to be satisfied.

**Envelope amendment (2026-09-26, plan T8):** the promoted package now allocates in its L2
(`WtAxiAllocEn=1`; before it the WT shim's modifiable-only attribute made the L2 a bypass, measured
as 0 hits on the four-hart boot) and was re-qualified with allocation (strict pass). The
qualification-only variants `g6lc64_ooo_int2_l3` / `g6lc64_smt2_l3` add a **non-inclusive** L3
below the L2 (`L3InclusiveEn=0`, `L2TagSramEn=1`). The hub never observes the L3: the coherence
envelope (signature acquisition on AR/AW, WT retained-copy invalidation, physical-address load
validation) is unchanged, and the composed stack bench extends the stalled-write/self-invalidation
scenarios through hub→L2→L3. The L3 packages are not promoted; no L3 performance benefit is
claimed (`l3_hit = 0` on the boot workload).

**Production promotion review (2026-09-24):** do not promote from B-delay leaf tests alone.
The retained WT atomic invalidation now keeps its full PA, not merely an index widened to an
address; only its cache-index output is sliced. Hub B offers retain their selected slot under
backpressure, and per-slot predecessor masks preserve B completion order for a shared
(core, original-ID) key. Dependencies clear on core B acceptance, not memory B capture; atomic
slots whose B already completed do not hold younger Bs behind a late R. Atomic R is now subject
to the same invalidation qualification as B. Potentially invalidating AW classification includes
ATOP and locked writes even when cache[1] is zero.

These repairs do not finish the publication contract. A legal standalone AXI slave can accept a
read after an AW-triggered invalidation but before delayed W data, permitting an old refill with
no later invalidation. Scenario 23 records this counterexample. The current L2 admission rules
may exclude that schedule: prove the composed hub/L2/L1 contract rather than treating a generic
hub test as an observed cluster failure or silently assuming the schedule impossible. WLAST
acceptance into a buffer alone is not proof of global visibility. Fixed settling after a bus pop
also cannot qualify an endpoint that acknowledges FIFO admission (notably the HPDCACHE retain
path) with unbounded application delay. Full applied acknowledgement/visibility, local-CAS
coverage, per-ID R ordering and multicore architectural qualification remain open obligations
for unrestricted silicon release; the composed-L2 evidence above closes the scenario-23 question
only for the accepted envelope. (Superseded on the guard: see the integration acceptance entry.)

**Carry-over checklist:** configuration and source-level synthesis gates are present; no new clock,
reset domain, latch or permission/address-masking rule was introduced. Existing scan/clock-test
paths are unchanged. Signature SRAM lookup adds a registered admission dependency and the cold
sweep costs `NR_ENTRIES` cycles; L2 install matching adds address comparisons. Both are timing/
power review obligations, not closure claims. Existing hub filter/stall pins provide leaf observability;
full PMU/RVFI integration, SRAM MBIST/ATPG binding, physical timing/power and the protected full-model
identity/compliance gates remain open. No instruction, CSR, ISA string, memory map or DTS-visible
cache capacity changed. Generic area and raw SRAM port geometry are recorded separately from
physical area. The production guard cannot be removed on the strength of the current checkpoint.
