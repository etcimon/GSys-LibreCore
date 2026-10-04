# OoO + SMT2 step plan (companion to `AGENTS-ooo-contract.md`)

Tranches run in order; each ends with the contract's exit row and a review point. Evidence names
the run tags under the C: artifact root and `/opt/testharness/runs/`. Anything marked open stays
open until its exit is met; nothing is promoted as a side effect of a passing run.

## Evidence baseline (2026-09-21)

- Protected in-order SMT2 anchor: `s0-repeat-ctl-r1..r5`, `s0-cert-safe-par-v1` — 12,765,628
  cycles, 333,635/8,932,406 retirements, strict stores, replay baseline `260456…9ea` (same model,
  not an independent oracle). PMP stop attributed to the omitted `split-counter.vlt` (3/3 noctl).
- Runner: compiler-control preflight refusal, streamed trace checks, structured non-pass outcomes,
  pre-launch invocation capture. Open: build-time recipe attestation for the pinned manifest.
- FPU and divider result ownership: `s2-fp-owner-*-v4`, `s2-div-owner-*-v2`, mutations
  `s2-*-owner-mut-*`; strict `-Werror-UNOPTFLAT` leaf blocked by pre-existing scoreboard/FPnew
  loops (`s2-fp-owner-strict-s32-v1`) — open structural gate; strict slang skipped on the builder.
- Leaf baselines all matched: dispatch, WB-owner, drop, LSQ, rename, FP/hart rename, store
  recovery, WFI, fetch queue, drain sims + synth, PMP sim/mutation/proof.
- Open defects and residuals: dispatch scenario 18 (id-only late result accepted); two anchor early
  terminations (unowned; destructive proxy pkill removed); LR `lsu_rmask` visibility; kill
  persistence never measured on the anchor; `replay_q` flush asymmetry; stage 34 layout co-factor;
  `NrCommitPorts=4` requested while commit is two-wide.

## T0 — split, archive, checkpoint

1. Move the session plan history and the README investigation sections verbatim into
   `architecture/out-of-order/log-2026-09.md`; README keeps status + reference tables + pointer.
2. This contract and plan exist; `AGENTS.md` §2 gains the `core/ooo` guide row.
3. One checkpoint commit (no push) of the verified worktree after review of message and file list.

## T1 — age namespace and memory-order validation

RTL: `g6lc_ooo_pkg::ooo_age_older(a,b,cp)`; replace inline compares in `g6lc_iq.sv` (store-age gate,
store admission), `g6lc_lsq.sv` (CAM/STL), `core/store_buffer.sv` (`ooo_older`, `spec_visible`,
insertion sort). Scoreboard exports its `issued` mask to the LSU seam; `translate_off` assertion:
no age compare on a non-live tid. LSQ alias validation: on store `addr_valid`, scan younger loads
with `addr_v` and byte-lane overlap that have already issued; raise `mem_violation` with the load
tid; scoreboard marks the slot `replay`; `commit_stage` on a `replay` head performs no
architectural write and asserts `flush_commit`; frontend adds a `replay` arch source that takes
`pc_commit` **without** the +4 increment (`g6lc_fetch_pkg::arch_src_sel`).

Verification: `core/ooo/formal/g6lc_ooo_age_props.sv` + `.sby` on a small LSQ/store_buffer bundle
(age order = allocation order for live entries; committed entries older than any live; violation
detection complete for one store/one load with symbolic addresses; negative witness when the scan
is removed). `tb_g6lc_rtl_review.sv`: wrap-around age across the window, committed-store forward
after tid recycle, violation → replay → correct value; negatives; mutations (drop the live
assertion; drop the violation scan). Gates: strict `-Werror-UNOPTFLAT` build of the new leaf;
`verify --lint --synth --remote` counts unchanged; `testlist_ooo_l3.yaml` on `g6lc64_ooo_int`.

### T1 result (2026-09-21)

Exit met; see the contract's exit table. Evidence tags: `t1-lsq-viol-v1` (36/36),
`t1-dispatch-regress-v1` (28/28), `t1-lsu-regress-v1` (32/32), `t1-lsu-regress-wfi-v1` (56/56),
`t1-lsu-regress-commit-v1` (3/3), `t1-age-sat-v2` (prove+cover), `t1-age-sat-mut-v2`,
`t1-age-sby-v3` (PASS, 74 asserts), `t1-rob-sby-v3` (PASS, 4 asserts),
`t1-ooo-int-fpreview-*-v1` (Spike rows identical; stages 32/33 still abort on the reverted
misalignment assertion, unchanged), `t1-anchor-inorder-v1` (pass), `t1-verify-v2` (8/54, 32/5).
Corrections made on the way: the first age SBY/sat runs were vacuous (no `-DFORMAL`) and used a
reset idiom slang rejects; the same defects made the pre-existing ROB task vacuous. Both fixed;
the builder has no native yices and z3 exhausts memory on these models, so abc bmc3 is the engine
of record. The uniform +3 cycles on integer-OoO ELFs (`bis-*-v1`, seven isolated builds) is the
price of the CSR-at-commit-head issue rule inside `48c729e51`: at the exit `csrw mstatus`,
younger ALU ops issue ahead of the waiting CSR, delaying its flush by two cycles plus a refetch.
Architecturally identical; T2's per-tid CSR table removes the wait together with the FLU wedge.
Pure parent `e64864263` fails stage 4 (894 cycles, wrong x15), so the 09-19/20 baselines came
from the pre-commit worktree.
Deferred to T2: store-buffer live-tid assertion (needs the LSU seam port), same-cycle
store/load address cases beyond two ports.

## T2 — leftover pipes and relaxed issue

CSR: small per-tid address table (depth 2–4, tid-tagged, looked up by the committing tid) replaces
the depth-1 `csr_buffer`; `csr_ready` (table full) gates only CSR issue and leaves `flu_ready`;
the IQ commit-head rule for CSR is dropped, since the CSR reads and side-effects already happen at
in-order commit and its write operand comes from the renamed file. This recovers the +3 cycles. Store: dispatch credit reserves a speculative-queue slot;
`check_cfg` asserts `DEPTH_SPEC >= LsqStoreEntries` under `OoOEn`; drop `older_unissued_st` from
select; keep PO drain and age forwarding. Memdep: prediction registered into the IQ entry at
dispatch (`may_bypass`); select gate `is_ld && older_unresolved_st && !may_bypass`; T1 replay is
the safety net. Tests: two-store/one-load matrix (orders × aliasing), CSR pairs with younger ALU
and branch work in flight, WFI/flush interplay, negatives, mutations (remove reservation; force
`may_bypass` without validation → caught by replay). Exit: leaf suite; Spike-ordered
`g6lc64_ooo_int` smoke (`ooo_mem_dep.S`, `ooo_ilp_chain.S`); PMU group-1 shows no FLU freeze on
CSR; `sparse_issue_lsu` FO4 not worse than T1.

### T2 result (2026-09-21)

Exit met; see the contract's exit table. Tags: `t2-csrbuf-v2`, `t2-iq-v1`, `t2-lsq-v1`,
`t2-dispatch-v4`, `t2-dispatch-mdp-v4`, `t2-dispatch-lateresult-v3`, `t2-lsu-v1`,
`t2-age-sat-v2`, `t2-age-sby-v2`, `t2-ooo-int-fpreview-*-v3/v4`, `t2-anchor-inorder-v3`,
`t2-verify-v2`. Design corrections made during the tranche: a completed load keeps its LSQ entry
while any older store is unresolved (otherwise the violation scan has no record to replay; frozen
stage 20 exposed it); the in-order `csr_buffer` expression is bit-identical to before and an
implementation attempt to relax it for a fixture was reverted — protected-path RTL is never
adapted to an oracle. Oracles that encoded the pre-T2 contract (dispatch 3/6/8/19) were rewritten
to the new one and their negatives retained. Cycle effects on the frozen ELFs: memdep 1060→1021,
s4 881→842, ILP 1112→1117 (the exit `csrw` no longer waits but its flush now discards younger
issued work; T4 measures before touching it). Deferred: the memdep query serves dispatch port 0
only (a same-group second load keeps `may_bypass=0`); stores still use one translation pipe.

## T3 — fetch kill by request token

`icache_dreq_t/drsp_t` gain a config-derived token; `g6lc_icache` returns the accepted token;
frontend kills by token and drops the VA-equality kill; demand, FDIP, loop buffer, hart switch,
same-VA refetch, same-cycle response/kill covered. Independent request/response ledger in the
fixture. Precise-misalignment properties replace the reverted antecedents (cause/PC/`TvalEn`-aware
tval, no destination write, no cancelled-work trap) with missing-exception and bad-completion
mutations. Exit: frozen failing layout ELF repaired; layout variants reproducible; in-order and OoO
arms; retire `G6LC_NO_KILL_PERSIST` after mutations are retained.

### T3 result (2026-09-21)

Exit met; see the contract's exit table. Tags: `t3-fetch-token-v2` (PASS, 4 asserts),
`t3-fetch-token-mut-v2` (FAIL at frame 4 on the killed-response assert), `t3-load-misalign-v7`
(60/60), `t3-load-misalign-mut-kill-v8` / `-ex-v8` (detected), `t3-fetch-regress-{queue,synth}-v1`,
`t3-ooo-int-fpreview-*-v2` (32/33/34 pass 869/899/869; others unchanged), `t3-anchor-inorder-v2`
(exact), `t3-verify-v2` (6/6 local incl. strict slang). Corrections during the tranche: the token
properties had to take stimulus through ports (an undriven internal `logic` is split into
independent free variables by the slang frontend, which made the ledger incoherent); my
misalignment fixture first modelled the D$ wrongly (`wt_dcache_ctrl` answers a killed request
with a dummy rvalid in the kill cycle) and an implementation attempt adapted protected
`load_unit.sv` to it — reverted, fixture corrected, RTL kept to the translate_off properties only.
Pre-existing findings, not T3-caused and reproduced on HEAD: `g6lc_fetch_hold.sby` fails (frame 4,
"request is the held target") and `g6lc_fetch_iq.sby` bmc fails (frame 3, I6 non-interference,
regression after the 09-15 instr_queue changes); both stay open with owners in T4 pre-work.
Remote `verify` still skips strict slang; the local gate covers it.

## T4 — issue-queue timing structure

Non-compacting ring with allocation-order age vector; oldest-ready select from registered age bits;
payload held in place. FO4 screen before/after; typed INT/MEM/FP split only if `sparse_issue_lsu`
still exceeds budget. Exit: identical directed results to T2; equal or fewer stall cycles; lint and
synth counts; FO4 delta recorded.

### T4 result (2026-09-21)

Exit met for the structural half; numbers in the contract's exit table and §5. Tags: `t4-iq-v1` /
`t4-iq-default-opt-v1` (64/64), `t4-dispatch-v1` + `-mdp-v1` (28/28), `t4-ooo-int-fpreview-*-v1`
(ten stages cycle-identical to T3), `t4-fo4-before` / `t4-fo4-after` (`sparse_ooo_issue`),
`t4-verify-v1`, `t4-anchor-inorder-v1` (exact; in-order model bit-identical to T3 since the smt2
flist does not carry `g6lc_iq`). Pre-work closed the two fetch proofs found failing in T3 on the
property side, each after reading the counterexample: `g6lc_fetch_hold` needed port-based stimulus,
the SMT ports connected under an explicit selector contract (`no restore while redirect_pend_q` —
the RTL exports only the trap case as `smt_trap_hold_o`; the general case is now an obligation in
AGENTS-todo), the same-cycle architectural supersede exempted from "request is the held target"
(I8 priority), and `redirect_accept` added as a release leg with a new assert that re-acceptance
keeps `redirect_pend_q`; `g6lc_fetch_iq` needed the two payloads constrained to agree on the CF
class per slot (`instr_queue.is_ctrl_instr`, mirrored in the props), which is the raw-opcode throttle
contract SPEC.md had left open. **T4b (same day)**: the rank popcount had replaced the payload mux as
the module max (27.0, +3 net); a cascaded oldest-first grant with per-port pool nets (a shared pool
array read as a false loop) brought the select cone to 16.0 with the rank kept sim-only as the
reference (`ooo_iq_grant_is_rank`); tags `t4b-iq-v3` 64/64, `t4b-dispatch-v1`/`-mdp-v1` 28/28,
`t4b-ooo-int-fpreview-*-v1` ten stages cycle-identical, `t4b-fo4-after`, `t4b-verify-v1`. Open: the
IQ cover task still times out under z3; `g6lc_ooo_dispatch` at 30.0 is the slice's worst cone.

## T5 — FP SKU (single hart)

`g6lc64_ooo`: rename + one FMA/cycle + commit-or-flags; cancelled-DIVSQRT mutation; Spike-ordered
FP suite (`ooo_fp_rename.S`); remove `!(OoOEn && FpPresent)` for `NrHarts==1` only. Two-hart FP
and lazy-FS wait for T6.

### T5 status (2026-09-21, partial)

Qualification build `g6lc64_ooo` + `G6LC_OOO_FP_QUALIFY` (the define exists only for this; both the
`check_cfg` assert and the dispatch `$error` stay for production, and multi-hart FP has its own
unconditional guard). Evidence: `t5-fh-fix-fp-v1` 13/13 FP positives Spike-identical, 10/10
negatives report their stage id, alias mutation detected on stage 4, owner mutation inert on
stages 1/9/10 (diag: 16 stale publishes on stage 10 all landed ~16 cycles before the slot's next
owner arrived — architecturally invisible at 32 scoreboard entries; the S2 leaf catches the same
needle). Found on the way: the FTQ replay defect (fixed, see contract) and its rare residual; the
smt2 anchor model run single-hart on a directed ELF replays the boot vector once (dual-hart model,
hart 1's boot — artifact, not a core fault, to confirm). A 16-entry-scoreboard qualification
variant (`NrScoreboardEntries=16` overlay, `t5-sb16-fp-*`) was tried to open the reuse window the
S2 leaf had shown: the window IS reached (17 stale returns, each ~13 cycles after the tag's new
owner was allocated) but every stale publish still lands on a slot the commit head has already
dropped ~4 cycles earlier, and the `fpu_wrap` gate's own `was_cancelled` layer masks it besides —
the mutation stays inert at core level. Decision pending: whether leaf-only detection plus this
two-layer structural argument meets the bar for removing the single-hart guard. **New finding**: on
the SB=16 variant, `ooo_fp_cancel_tid_reuse` (stage 9) stops retiring and times out at the 2M cap
on the unmutated model (fetch parked at `0x10040`); stage 1/10/11 pass there. A 16-entry
scoreboard is a legal configuration, so this is a qualification finding in its own right — open.

## T6 — mixed-resident SMT2

Per-hart commit heads (scoreboard/ROB), hart-tagged IQ/ROB/LSQ, per-hart STQ credits, shared PRF
with per-hart floors, per-hart cancellation; drained handoff retired only after peer squash/trap
isolation negatives pass; Phase 6 adaptive policy stays frozen. Guard removal is a separate decision.

### T6a status (2026-09-23): integration gate PASSED after two OoO-only fixes

The 14M-cycle flow trace located the failure: hart0's last real retirement at cycle 10,584,092 in
`prints`, then an empty scoreboard (`issue_ptr == commit_ptr`, `decoded=00`) and a garbage npc.
Two defects, both invisible in order: (1) a memory-order replay at commit and a younger branch's
stale-data mispredict resolved in the same cycle; the commit source won `arch_src` but the
mispredict still armed the target filter, so the replay window was rejected and fetch resumed at
the squashed target, skipping `0x8000a10e–0x8000a120` (`frontend.sv`: `is_mispredict` qualified
with `!misp_outranked`; `g6lc_fetch_hold` +1 property, PASS 8 asserts, gate-removed mutation fails
at frame 3); (2) a device load at the commit head waited for the *whole* store buffer, which under
OoO holds younger speculative stores until their own commit — a deadlock on the first UART poll
with a speculative store behind it (`load_unit.sv`: OoO waits on the committed queue only;
load leaf scenarios 14/15, 8/8, in-order unchanged 60/60). With both: the protected dual-hart
profile on `g6lc64_smt2_ooo_int` **passes strictDual in 10,696,498 cycles** (8,792,612 /
465,543; in order 12,765,628), `ooo_switch_drained` silent, and the protected in-order anchor is
**exact** (`f10a5a60…`, 12,765,628, 333,635 / 8,932,406, control attested). Guard decision for
integer multi-hart OoO is now the user's; the `G6LC_OOO_SMT_QUALIFY` seam stays until then.

#### Earlier T6a record (2026-09-22): integration gate FAILED (superseded above)

Design: with `drain_ready = sb_empty && no_st_pending && !flush` every switch happens with the
scoreboard (hence IQ/ROB/LSQ/CSR table/store buffer) empty and `g6lc_rename` already keeps per-hart
maps, so the hart-blind OoO structures are safe under this policy. Delivered: `ooo_switch_drained`
witness in `cva6.sv` (translate_off), the qualification-only package `g6lc64_smt2_ooo_int`
(`g6lc64_smt2` + `OoOEn=1`, `RVF/RVD=0`, `LsqStoreEntries=4`), Makefile derivation of
`G6LC_TB_OOO` from the target package (anchored field grep — `SliceOoOEn` aliases the naive one),
`EXPERIMENTAL_TARGETS` admission in `run_opensbi_source_review.py`, rename/dispatch cells for two
harts (rename nh2 10/10, fp-nh2 4/4, dispatch legal-smt 14/14 with the define, both illegal cells
refused). Integration: the protected dual-hart OpenSBI/HSM profile (same firmware `6b2bad99`,
same plusargs, 14M cap) on `g6lc64_smt2_ooo_int` **times out** — hart0 8,728,674 / hart1 458,082
retirements, hart1 parked in WFI at `0x8000f72e`, hart0 in M-mode at `0x8000a130` with the last
trap `mcause=3`; the `OoOEn=0` overlay of the same package **passes** (`strictDualPassed`,
333,402 / 8,931,687), so the FP-less profile is not the cause. A 700k-cycle flow-traced rerun shows
9,163 handoffs, every one with `empty=1 stores_clear=1` and the `ooo_switch_drained` witness
silent — the drain precondition holds; what fails is progress of the non-boot hart after the boot
hart's `sbi_hart_start`. That run also booted with the other hart winning the lottery (hart1 in C
init, hart0 waiting at `0x800002f6`) although only `+smt_flow_trace` differs from the 14M run —
a run-to-run divergence that has to be understood before the hang itself. Guards stay
(`G6LC_OOO_SMT_QUALIFY` seam only); the in-order anchor model is byte-identical to the last exact
anchor (`5608ef96…`) so the anchor result carries over; verify lint 8/54 and synth 32/5 unchanged.

### T6a closure (2026-09-23)

Guard lifted for integer multi-hart OoO (user decision): `check_cfg` keeps only the FP leg,
`gen_err_ooo_smt` is gone, `g6lc64_smt2_ooo_int` is a production package. The single-hart FP guard
stays (user decision). The SB=16 stage-9 stall was a third FTQ-path defect (control-flow hold armed
by an unpushed prediction) — fixed, pinned in the FTQD=4 token proof, `FtqDepth=0` byte-identical.

## T6b — mixed-resident SMT2: contract (design, 2026-09-23)

**Goal.** Both harts hold work in the OoO backend at once; the thread selector no longer waits for
`drain_ready` (the handoff becomes a fetch-slot policy, not a pipeline drain). **What must become
hart-aware, and how:**

| structure | today (drained) | T6b ownership rule |
|---|---|---|
| scoreboard / ROB | one `commit_pointer`, entries carry `hart_id` but the head is global | one circular window per hart (`commit_ptr[h]`, `issue_ptr[h]`) over a statically split entry range `[h*N/2, (h+1)*N/2)`; age key `{hart, dist_from_hart_head}`; cross-hart age is *undefined* and never compared — every age comparison site (`ooo_age_older/dist`, six sites from T1) receives entries of one hart only, asserted |
| IQ | hart-blind stationary entries, one age matrix | entries carry `hart`; the age matrix is masked per hart (`older_t[e][j] &= same_hart[e][j]`); select stays one cone (oldest-ready across both harts is allowed to be *any* ready entry of the other hart — fairness, not correctness); wakeup is by physical register, already hart-disjoint via rename |
| rename / PRF | per-hart maps, one pool, `flush_hart_i` tied off | `flush_hart_i[h]` driven by the per-hart recovery (below); per-hart **floors**: the pool refuses an allocation that would leave fewer than `PrfFloor` free registers for the *other* hart (`PRF_N - 31*NH - floors` is the shared slack); a hart at its floor stalls dispatch, never the peer |
| LSQ / store buffer | hart-blind, program order by tid distance from the one head; speculative queue slots reserved by LSQ store entries | LSQ entries carry `hart`; the unresolved-store mask, alias scan and forwarding are computed *within the hart* (a load never waits on, forwards from, or replays for the peer's stores — different address spaces are not assumed, so cross-hart same-address ordering is the memory model's, i.e. none until commit); the speculative store queue gets **per-hart credits** (`DEPTH_SPEC/NH` each) so one hart's unresolved stores cannot starve the peer's reservations; the committed queue drains in commit order across harts (commit is still one stream) |
| CSR table, FU owner tables | by tid | unchanged: tid is unique across harts (disjoint ranges) |
| cancellation / recovery | `flush_i` is global; branch mispredict cancels by tid range from the resolving branch | `flush` becomes per hart: a trap, replay or mispredict of hart h squashes only entries with `hart==h` (mask = `hart_of[e]==h`), restores rename for h alone (`flush_hart_i[h]`), and redirects only h's fetch stream; the frontend already keys redirects by hart (`redirect_for_hart`, `commit_for_hart`) |
| frontend | one active stream, PC bank per hart | two live streams need their own `bp_pend/redirect_pend` state per hart or a strict "one hart owns fetch per cycle with its own filter state" rule — T6b keeps **one fetch slot per cycle** (round-robin / policy) and duplicates only the redirect/target-filter registers per hart |
| memdep predictor | PC-indexed, shared | index with `{hart, pc}` or flush on hart switch — choose `{hart,pc}` hashing (no correctness dependence, so perf-only) |

**Oracles before RTL (lead-authored):** (1) dispatch leaf `HARTS=2` scenarios: two harts dispatch
interleaved; a mispredict of hart 0 squashes only hart-0 entries (hart-1 IQ/ROB/LSQ entries, PRF
mappings and store reservations untouched — checked through committed results); a trap on hart 1
likewise; a hart-0 load never forwards from a hart-1 store to the same address and never replays for
it; store-credit exhaustion by hart 0 leaves hart 1's reservation admissible; PRF floor: hart 0
allocating to the floor leaves hart 1 dispatching. (2) LSQ leaf: same-address stores from both harts
resident, each hart's loads see only their own; unresolved-store mask per hart. (3) Formal: the age
namespace proof extended with a hart bit — `ooo_age_older` is never evaluated on entries of
different harts (assume-guarantee on the callers). (4) Firmware: the protected dual-hart profile
with the drain gate *off* (`SmtDrainedHandoff=0` config bit, default 1) must pass strictDual; plus
a directed two-hart probe where one hart runs a mispredict/replay storm while the other runs a
Spike-compared checksum — the checksum hart must be cycle-insensitive and value-exact. (5)
Negatives: each isolation rule mutated (mask dropped) must be caught by (1)/(4).

**Exit.** Both harts perform checked work concurrently (4 passes), all isolation negatives caught,
anchor exact with the drain gate on (bit-identical path), lint/synth at baseline, FO4 screen within
budget for the per-hart masks (they enter the select cone only as an AND on the age matrix).

**Revision (2026-09-23, before implementation): shared ring first, partition later.** The
partitioned-window design above halves each hart's window even when one hart is resident and
rewrites commit. The legacy in-order SMT already ran both harts in *one* scoreboard ring with a
single in-order commit head (the younger-cancel is same-hart filtered for that reason), and that
is architecturally sufficient: each hart's instructions commit in its own program order, the
interleaving is free, and a slow head only costs the peer throughput (head-of-line blocking), not
correctness. T6b therefore keeps one ring and one commit head and makes the *ownership* rules
hart-aware; the partitioned ROB / per-hart heads and PRF floors become a performance tranche
after the exit. What is correctness-relevant with a shared ring:

- **LSQ / store buffer:** a load orders against, forwards from, and replays for stores of its own
  hart only; peer stores become visible at drain (commit queue), exactly like another core's. A
  speculative peer store must never be forwarded (it may be squashed). `st_unresolved_mask` is
  consumed by the IQ per hart (`st_hart_mask[h]`).
- **Recovery:** mispredict cancel is already same-hart. Trap/replay flush stays global; the
  *non-faulting* hart restarts fetch at the PC of its oldest squashed entry (`sb_head_pc[h]`,
  exported by the scoreboard), the faulting hart at its vector/replay PC.
- **Frontend:** one fetch slot per cycle (the existing switch, without the drain wait when
  `SmtDrainedHandoff=0`); a redirect/trap/replay for the hart that is *not* fetching updates its
  PC bank instead of being dropped; the mispredict target filter is per hart.
- **Commit-side per-hart state:** interrupt sampling and CSR bank by the *committing* hart; WFI
  parks the hart (thread select `hart_block`) instead of halting the core.
- **Config:** `SmtDrainedHandoff` (bit, default 1 = today's behaviour, bit-identical for every
  existing package); `0` legal only with `OoOEn && NrHarts > 1` and, until the T6b exit,
  only behind `G6LC_OOO_SMT_MIXED_QUALIFY`.

**T6b-1 status (2026-09-23): landed, drain gate on, every result reproduced.** `SmtDrainedHandoff`
exists in every package (default 1; `check_cfg` refuses 0 outside OoO multi-hart and, until the
exit, outside `G6LC_OOO_SMT_MIXED_QUALIFY`); the thread selector's `drain_ready` is the seam.
LSQ entries carry `hart`: unresolved-store wait, forwarding and the violation scan are same-hart
(`st_hart_mask_o[h]` partitions the live stores; the IQ ANDs it in front of the age gate);
`lsu_ctrl_t`/`fu_data_t` carry `hart` so the store buffer's *speculative* forwarding is same-hart
under `OoOEn && NrHarts > 1` (the committed queue is not filtered); the scoreboard exports
`sb_head_pc_o[h]`/`sb_head_valid_o[h]` (oldest issued entry per hart, scanned from the commit
pointer — a 32-deep serial scan; **it must be made incremental before T6b-2 consumes it**, it has
no consumer today so synthesis trims it). Evidence: LSQ 88 records (19 direct + 25 nh2, negatives),
dispatch n2/mdp 28+28, legal-smt 6 (D-A/D-B), store-recovery 36 incl. the new peer/own forward
cells, IQ 4 geometries, age formal PASS (5 asserts), frozen int ELFs + s11 cycle-identical, FP
suite cycle-identical, dual-hart profile strictDual 10,696,498 (17,138 handoffs all drained,
witness silent), anchor exact on the post-fix model `b08f9211…`, lint 8/54, synth 32/5, FO4
`g6lc_iq` 16.0 / `g6lc_lsq` 26→28 / dispatch 30.0 (budget 32). Caveat recorded: the three
functional models were built one inert one-line lint fix (`a_hart` default init) before the
anchor model; the anchor is post-fix.

**T6b-2 design (2026-09-23).** Reading `g6lc_smt_csr_bank`: commit, exceptions, CSR ops,
interrupt lines and WFI (`hart_halt_o[h]`) are *already* per bank keyed by the committing hart —
the in-order SMT needed that. What is keyed by the **active fetch hart** and therefore wrong under
mixed residency: (a) the architectural view exported to EX/LSU/MMU (`priv_lvl`, `ld_st_priv_lvl`,
`sum`, `mxr`, `satp_ppn`, `asid`, `en_ld_st_translation`) — a load of the non-fetching hart would
translate and permission-check in the peer's context, and TLB entries are not hart-tagged, so two
harts with equal ASIDs alias; (b) frontend redirects/traps/replays for the non-fetching hart are
dropped (`redirect_for_hart`, `commit_for_hart`) instead of updating its PC bank; (c) a global
flush does not restart the non-faulting hart. Slices: **T6b-2a** — incremental `sb_head_pc`
(tracked, not scanned), redirect/trap/replay of the non-fetching hart → its PC bank, global-flush
restart of the peer at `sb_head_pc[peer]` (or its frontier when it has no live entry), per-hart
mispredict target filter; oracles: frontend/hart-state leaf with two harts (a resolution for the
inactive hart lands in its bank and never disturbs the active stream; a flush caused by hart h
restores the peer's bank to its head PC), the hold/token proofs unchanged, drained results
reproduced. **T6b-2b** — per-access translation context: the CSR bank exports the LSU context per
hart, the LSU/MMU select by the request's hart, D-TLB/shared-TLB entries carry a hart tag compared
on lookup (or `SmtDrainedHandoff=0` is refused with `MmuPresent`); oracles: MMU leaf with two
contexts (same VA, different satp → different PA; same ASID does not alias across harts), the
existing MMU cells unchanged. Neither slice changes behaviour while `SmtDrainedHandoff=1`.

**T6b-2a status (2026-09-23): landed, drain gate on, every result reproduced.** `cva6.sv`: the
commit-side bank redirect is owned by the committing hart (eret/exception used the active hart),
a memory-order replay banks `pc` not `pc+4`, and — mixed residency only — an inactive hart's
mispredict retargets its own bank and a global flush restarts the peer at `sb_head_pc[peer]` or its
surviving frontier (`peer_restart_*`, second PC-bank write port, frontend `SRC_PEER` ranked below
COMMIT). `scoreboard.sv`: parallel per-hart head (rotate/find-first/rotate back) with the serial
scan kept as a translate_off equivalence reference — scoreboard cone unchanged (24.79 adj FO4).
Evidence: `sbhead` leaf 6/6, restart-bank leaf + negative + synth (0 latches), hold proof PASS,
token/redirect proofs PASS, dispatch/LSQ/IQ cells unchanged, frozen int + s11 and FP suite
cycle-identical, dual-hart profile 10,696,498 (unchanged), anchor exact (`6b06ac40…`), lint 8/54,
synth 32/5, FO4 unchanged in both screens.

**T6b-2b design notes.** Per-access architectural context: the CSR bank exports an LSU context set
(`en_ld_st_translation`, `ld_st_priv_lvl`, `ld_st_v`, `sum`/`vs_sum`, `mxr`/`vmxr`, `satp`/`asid`,
`vsatp`/`vs_asid`, `hgatp`/`vmid`, `mbe`) muxed by `lsu_hart_i` plus a `fet_*` copy muxed by
`active_hart_i`; `pmpcfg_o`/`pmpaddr_o` alone select by `lsu_chk_hart_i` because the PMP data check
runs one cycle after the request on the registered address. The MMU registers the whole request
context (`ctx_*_q`, every cycle alongside `lsu_req_q`) and replays it through `chk_*` in every
check-stage expression; lookup-side uses (DTLB hit/PPN, TLB stage-enable, `canonical_addr_check`,
PTW inputs) stay live. TLB entries carry a hart tag compared only when `NrHarts>1 &&
!SmtDrainedHandoff` (`HART_TAG`/`HART_CTX` localparams constant-fold elsewhere); flushes stay
global. **Unsupported in mixed residency:** differing `mbe` across resident harts (bank asserts all
banks agree) — the LSU formats data with the request hart's endianness while the drain path uses the
committing hart's. **Known pre-existing limitation (out of T6b scope):** under the drained handoff
(`SmtDrainedHandoff=1`) TLB entries are shared across harts with equal ASIDs — the tag compare
folds away and first-match behaviour is preserved by oracle. Interrupts are taken per fetch lane in
decode (`irq_ctrl_b_o`/`priv_lvl_b_o`/`v_b_o` per-hart arrays); there is no commit-stage interrupt
context (`irq_ctrl_commit_o` removed — no consumer). Under mixed residency `halt_csr_o=0` and a WFI
parks only the committing hart via `hart_halt_o[h]`; drained keeps the global halt. Oracles:
`csrbank` (context select + WFI, drained and mixed), `tlb`/`stlb` (hart isolation + drained
sharing), `mmuctx` (per-hart walks + check-stage skew incl. translation-enable) with
`G6LC_MUT_TLB_NO_HART_TAG`/`G6LC_MUT_MMU_LIVE_CTX` expected-failure cells.

**T6b-3a design notes.** The rule for every `active_hart_i`-keyed bank output: classify by *when
the consumer samples it* — decode-time → per lane by `fetch_entry_i[i].hart_id`
(`SMT_MIXED_DECODE`); LSU-time → `lsu_hart_i`; commit-time → `commit_instr_i.hart_id`;
frontend/fetch-time → `active_hart_i` (unchanged). Landed:

* **PMU (`perf_counters`).** The planted `gen_hart_attribution_check` fatal ("commits belong to
  the active hart") was the mechanism, not a check — deleted. Every event is now banked by its
  true owner: commit-derived events (int/fp/load/store/branch/call/ret, ex/eret by port 0's
  hart) land in the committing instruction's bank; resolved-branch events (and the FLU branch
  exception, which shares the resolving instruction — documented approximation) bank by
  `resolved_branch_i.hart_id`; frontend/structural events (I$/ITLB/DTLB/D$ miss, if_empty,
  stalls, L2/L3/PF, AI, write-buffer, `ooo_*`) stay on `hart_i` (active hart — documented
  approximation, they observe shared frontend state). Each bank owns its own `mhpmevent`
  selector copy (`event_group[h]`/`events[i][h]` per hart), so a counter can never count a
  peer's event; `mcountinhibit` and the Sscofpmf `minh/sinh/uinh` filter are per bank
  (`mcountinhibit_b_i`, `priv_lvl_b_i`). The HPM CSR access banks by `csr_hart_i` (=
  `commit_instr_i[0].hart_id`), matching the bank's `perf_*` mux — under drained/single-hart
  every select collapses onto the active hart and counts are identical.
* **Decode (`id_stage`).** `SMT_MIXED_DECODE` now selects `tvm/tw/vtw/tsr/hu/fs/vfs/vs/frm/
  debug_mode/mcbie/scbie/hcbie/mcbcfe/scbcfe/hcbcfe/mcbze/scbze/hcbze` per lane from the bank's
  new `*_b_o` arrays; `jvt` (Zcmt table base) follows the instruction's hart.
* **Remaining outputs classified:** `icache_en`/`dcache_en`/`acc_cons_en`/`ai_*` are global
  resources → active hart (documented); `rvfi_csr_o` is trace-only → active hart (documented);
  `mbe` stays request/commit-hart owned (differing endianness unsupported, asserted). **External
  debug under mixed residency is unsupported (T6b)** — the debug side-band
  (`debug_req_i`/`set_debug_pc`/`single_step`/triggers) is active-hart-owned; the bank asserts
  `debug_req_i` never arrives and `debug_mode` is never entered under `!SmtDrainedHandoff`.
  `switch_i` on the bank is a dead input (no consumer — switching lives in `smt_switch`); left
  wired, no behaviour. `pbmte` is a dead wire top-level (no consumer), unchanged.
* **T6b-3b probe.** `+smt_mixed_stats` (translate_off, `gen_smt_mixed_stats` in cva6.sv) prints
  at `$finish`: cycles with every hart holding a live scoreboard head, commits by non-active
  harts, and per-hart retired counts — the residency witness for the first real
  `SmtDrainedHandoff=0` run.

**T6b-3b design notes — partial-flush peer restart and the fetch frontier.** The first mixed
gate run (both_resident=59260, nonactive_commits=293066, 210k handoffs) died as
`cycle-budget` with a fully traced mechanism: a hart-0 commit-side full flush killed hart 1's
just-restored in-flight request for `0x80008c2e` (`addi sp,sp,-16`, the
`sbi_scratch_alloc_offset` prologue) at t=1,067,561; the peer restart fired
(`prh=1`) but its frontier resolved `0x80008c30` — the fetch-ahead NPC — because the
fetch-side candidate (`snap_pc`) substitutes the in-flight parcel only while
`smt_restore_i` is asserted, and the armed `redirect_pend` target was invisible to it.
The stream resumed one instruction late → +0x10 stack skew → `ld ra,40(sp)` from an
unwritten slot → `ret` to PC 0 → OpenSBI fatal path → `spin_lock(&console_out_lock)`
self-deadlock. Two defects, one family:

1. **Partial-flush peer restart (the briefed leg).** `flush_ctrl_if`/`flush_unissued` are
   global kills of *both* harts' pre-dispatch state (frontend in-flight, `instr_queue`,
   ID-stage issue registers). Scoreboard cancel and rename restore are correctly same-hart,
   but the T6b-2a peer restart required `flush_ctrl_id` — a peer's undispatched work killed
   by a mispredict (no full flush) was dropped with no refetch. `gen_peer_restart` now
   treats `(flush_if || flush_unissued) && !flush_ctrl_id && !smt_switch` as a peer kill:
   the owner is `resolved_branch.hart_id` (under fetch_B the only partial source is a
   mispredict — the E3 predicted-correct kill is compiled out; witnessed by
   `t6b3_partial_owner`), the peer restarts at its *pre-dispatch frontier only*
   (decode/queue entries plus the fetch-side candidate iff the peer is the active fetch
   hart), **never `sb_head`** — its scoreboard entries survive the same-hart cancel.
   Same-cycle routing: an inactive hart's mispredict banks its target on the primary port
   (new lowest-priority leg, dead under drained and whenever a commit redirect owns the
   port — `misp_outranked` semantics), the peer restart keeps the second port, and
   `peer_restart_active` reseeds the frontend via `SRC_PEER` when the peer is the fetch
   hart. Kill-set uniformity needs no force: every controller leg raising
   `flush_unissued` already raises `flush_if` under fetch_B (asserted:
   `t6b3_kill_set_uniform`). `smt_switch` is excluded — the outgoing hart's frontier is
   already transported by `gen_smt_restart_frontier`.
2. **Fetch frontier export (the observed instance).** The frontend exports
   `fetch_frontier_pc_o = redirect_pend ? redirect_pc : inflight ? inflight_addr : npc` —
   the oldest undelivered fetch position in stream order (an armed redirect target
   precedes every parcel issued after it; queued parcels are always fetch-order older, so
   `restart_frontier`'s decode > queue > transport ordering stays sound). The peer
   restart's transport uses it whenever the peer is the active hart, and the switch
   transport uses it under mixed residency (drained keeps `smt_npc_live` — constant-fold,
   bit-identical). This is what recovered `0x80008c2e`: `prpc` now lands the killed
   parcel, not the cursor past it.

**Flush-consumer audit (OoO build).** `flush_ctrl_if` kills — all global, all pre-dispatch:
frontend in-flight/FTQ/BP-pend, `instr_queue` + `id_stage` issue registers, `smt_hart_state`
miss bookkeeping, `smt_thread_select` (suppresses a same-cycle switch, resets the quantum —
scheduling only). `flush_unissued` — scoreboard allocation gate + same-hart-filtered
younger-cancel (selective), `g6lc_ooo_dispatch` `can_go`/`issue_valid` masking (stall only,
no state clear), `issue_read_operands` register kill (**global and post-dispatch, but
instantiated only in `gen_inorder_issue` — absent under `OoOEn` → not a defect here**),
`acc_dispatcher` and tracer/RVFI probes (accelerator + observability). `flush_ctrl_id` is the
only backend-clearing signal (scoreboard/ROB/IQ/LSQ/rename `flush_i`). No consumer outside
the pre-dispatch region reacts to `flush_unissued` under OoO — the second-defect class the
brief asked to rule out is absent in this configuration; `issue_read_operands` is flagged
for the in-order config. Hart-selective kill (restart only the faulting hart's frontier)
is deferred to T6b-4 as the performance form.

**T6b-3b gate result.** With both fixes in, the mixed-residency profile
(`SmtDrainedHandoff=0`, `+smt_flow_trace +smt_mixed_stats`) **passes strictDual**:
`*** SUCCESS *** (tohost = 0) after 10602826 cycles`, `both_resident_cycles=60711`,
`nonactive_commits=105303`, retiredByHart {0:356213, 1:8936471} — the first
`SmtDrainedHandoff=0` pass of the dual-hart OpenSBI profile (drained record:
10,696,498). Zero assertion hits across 10.6M cycles.

**T6b-3c design notes — the deep-queue frontier (pending FIFO).** Review found the
remaining hole in the same family: `instr_queue` is `NrFifo` per-slot `cva6_fifo_v3`
(DEPTH 8) with `hart` stamped per instruction, so both harts' entries interleave —
but `restart_frontier`'s queue view only reached the `NrIssuePorts` output
positions. Scenario: switch 1→0 while decode is stalled; hart-1 entries hold the
ports, hart-0 entries queue deeper; hart 1 (resident) mispredicts → `flush_if`
kills hart 0's deeper entries, hart 0's candidates are the hart-1 port entries and
`smt_fetch_frontier` (its fetch cursor, *past* the queued entries) → lost
instructions. Harmless in the spin-loop profile, fatal in real code; the T6b-2a
full-flush leg had the same hole when the peer had no scoreboard entry.

Fix (mixed-residency generate only, `NrHarts>1 && !SmtDrainedHandoff` — '0 tie
elsewhere): `instr_queue` keeps a per-hart *pending-address FIFO* in push order —
push `{pc}` per instruction push (pushed FIFOs are contiguous from `idx_is_q`, so
lane k of the push is `instr_data_in[(idx_is_q+k) mod NrFifo]`), pop once per
delivered instruction of that hart (`fire_prefix` per port — the queue's actual
pop; a bare `valid & ready` without the prefix pops nothing), flush on `flush_i`,
depth `NrFifo × IFifoDepth` (slots × per-slot depth — the queue's total
occupancy). Per-hart delivery order is push order (compact insertion is program
order, a packet is single-hart), so `queue_oldest_*_o[h]` — exported through
`frontend` to `cva6.sv` — is exactly hart h's oldest undelivered instruction;
asserted translate_off per firing port (ranked within same-hart deliveries). In
`gen_peer_restart` the queue-side candidate for the peer is now this head —
replacing the port view under mixed for BOTH the partial leg and the T6b-2a
full-flush leg — decode entries and the fetch frontier are unchanged. The
switch-transport frontier (`gen_smt_restart_frontier`) is deliberately
untouched: the queue is not flushed at a switch, so nothing is lost there.
Oracles: fetch-queue cell `IQ_OLDEST_H1`/`IQ_OLDEST_H1_ADV`/`IQ_OLDEST_H1_FULL`
(+`iq_oldest_neg` expected failure), restart leaf `RESTART_PEER_DEEP`
(+`mut_no_deep` expected failure). The per-hart-queue redesign — hart-selective
kill and no shared queue — stays T6b-4.

**T6b-3c gate result (new-source models, all rebuilt 0-warning):** mixed profile
on `work-ver-t6b3-mixed-v1` (sha `6fea4c9a`) `outcome=pass`,
`strictDualPassed=true`, `*** SUCCESS *** (tohost = 0) after 10602826 cycles`,
`both_resident_cycles=60711`, `nonactive_commits=105303`, retiredByHart
{0:356213, 1:8936471} — identical to the 3b gate (the deep-queue interleaving
never materialized in the spin-loop profile, as predicted; the leaf oracles are
the coverage). Drained dual `*** SUCCESS *** ... after 10696498 cycles` exact,
anchor `... after 12765628 cycles` exact, frozen int 11/11 cycle-identical
(s11=11256), FP 13/10, restart leaf positive + `mut_no_deep`/`mut_no_peer`
expected failures correct, fetch-queue cell 5/5 + `iq_oldest_neg` expected
failure, hold/token(FTQD0,FTQD4)/redirect proofs PASS, `g6lc_fetch_iq` bmc PASS
(cover task: z3 cover-mode on the two-instance self-composition cone — timed
out at 600s and 900s both with and without the pend FIFO in the envelope;
pre-existing cost, never completed in this campaign). `verify --lint --synth`
8/54 lint baselines, 32/5 synth clean. FO4 `sparse_ooo_issue`: unchanged by
construction — the fileset is 12 files / modules {g6lc_lsq, g6lc_memdep,
g6lc_ooo_dispatch, g6lc_prf, g6lc_rename, g6lc_rob, g6lc_iq}; no fetch_B source
is analyzed.

**T6b-3 exit — directed probe, the duplicate-`mret` defect, and the
switch-guard fix.**

*Probe (repo asset).* `verif/tests/custom/multicore/smt_mixed_probe.{S,_c.c}`,
build recipe `smt_mixed_probe_build.sh`, remote runner
`verif/regress/remote/run_smt_mixed_probe.py`. Hart 1 (checksum hart) runs in
S-mode on its own Sv39 root (data VA `0x4000_0000` → its private page) four
deterministic kernels — K1 store→load chain, K2 pointer chase, K3 ILP
multiply chains, K4 branchy accumulate — folding into a 64-bit checksum
compared against `EXPECT_CSUM=3287142068561700632`; it then loops
kernels + `misp_burst` + 512 `squash_burst` (speculative shared-word stores
through the `spec_pad8` RAS-mispredict pad) until `probe_done`. Hart 0 (storm
hart, M-mode bare) runs the LFSR mispredict storm, the store→load
pointer-chase replay storm, the shared-page ping-pong witness (4096-iter
pure reads; a nonzero read can only be a peer-speculative forward), the
CLINT timer interrupt witness, and its own S-mode TLB hart-tag excursion.
`+solo` parks hart 0 so hart 1's commit stream is the cycle-insensitive
reference; all flavours share one `.text` (the split is a `.data` branch on
`probe_solo`). Checksum provenance: recorded by the `+solo` run on the mixed
model (`t6b4-solo-mixed-v1`) and independently reproduced by the protected
in-order anchor model (`t6b4-probe-anchor-v1`) — reference-checked, not
self-referential.

*The duplicate-`mret` defect.* `instr_scan.sv:77-92` classifies `mret` (and
`sret`) via `is_xret` as `rvi_jump` with `rvi_imm=0` — a predicted
jump-to-self. The frontend therefore parks and re-requests the `mret`
parcel: every `mret` leaves 3–8 issued scoreboard copies that are normally
killed by the eret's commit-level flush before they can retire. On the
mixed-residency probe the first `mret` commit (hart 0, cycle 901081)
coincided with `smt_switch`: the controller raised the full flush, but the
U6.1 switch override (`controller.sv`) degraded it to `flush_if` +
unissued-only — the already-issued sibling copies were outside that kill
set. A second `mret` committed three cycles later with `mstatus.mpp`
already cleared to U → U-mode refetch → instruction access fault
(`mcause=12`). Mixed-only: drained serializes residency (no switch races a
commit) and single-hart never switches.

*Fix.* `controller.sv` computes `commit_flush` = every source that raises
`flush_id_o`/`flush_ex_o` above the switch block (ex_valid, eret, csr,
acc, fences, sfence/hfence, commit/replay flush, debug) and gates the
override with `!(MixedSmt && commit_flush)`, `MixedSmt = NrHarts>1 &&
!SmtDrainedHandoff` — drained and single-hart constant-fold to the previous
logic (bit-identical; the drained and anchor probe reruns are cycle-equal
to pre-fix). Mutation `G6LC_MUT_CTRL_SWITCH_DEGRADES` restores the old
override. Assertions (translate_off, `gen_t6b3_switch_flush_guard`):
mixed `smt_switch && commit_flush |-> flush_ctrl_id`
(`t6b3_switch_keeps_commit_flush`); drained `smt_switch |-> !commit_flush`
(`t6b3_drained_switch_no_commit_flush` — a latent-legacy detector only; if
it ever fires on the anchor/drained path the behaviour is pre-existing and
unchanged, report the cycle). Controller leaf `tb_g6lc_ctrl` /
`run_ctrl_leaf.py`: `eret_i && smt_switch_i` → mixed asserts
`flush_if && flush_id && flush_ex`; drained asserts `flush_id=0`
(unchanged); inverted negative `CTRL_SWITCH_ERET`; synth 15 cells / 0
latches / 0 SCCs.

*Two companion changes the un-degraded flush exposed.* (1) `frontend.sv`
`arch_src_sel` now takes `ex_valid_i`/`eret_i` through `commit_for_hart`
exactly as `set_pc_commit_i` already was: a trap or xret committed by the
hart that is *not* being fetched banks its redirect (T6b-2a) and must not
reseed the fetched hart's stream. This is not gated by `SmtDrainedHandoff`
(it applies to every `NrHarts>1` model); the protected anchor is exact, i.e.
the legacy fine-grain drain never commits a peer trap/xret while fetching
the other hart — the latent-legacy detector above also stayed silent. (2)
The peer-restart fetch-side candidate is `smt_npc_restore` when the flush
coincides with a switch (the incoming hart's frontier is its banked PC, the
frontend frontier still belongs to the outgoing hart).

*T6b-4 follow-up (noted, not implemented):* the `is_xret` jump-to-self
classification is config-independent — every `mret`/`sret` stockpiles 3–8
issued copies until its own flush arrives. Parking by *holding* the fetch
request (wait for the redirect) rather than re-requesting the same parcel
removes the pile-up; the switch-guard fix makes the residual correct, the
hold-request change is a robustness/performance item.

**T6b-3 exit matrix (all on post-fix models, v4 stimulus).** The v4 probe
extends `spec_pad8`'s speculative pad from one to two dependent divides —
the STB forwarding window now covers the observed offer-to-query gap.

| Lane | Result |
|---|---|
| mixed probe (`t6b4-probe-mixed-v4`) | **pass**, 3,101,269 cycles, RES0=RES1=pass, checksum exact (`0x2d9e464b9adce718`), `h0_pp=0`, `h0_tlb=0`, `h0_tmr=144` |
| solo reference (`t6b4-solo-mixed-v4`) | pass, 380,600 cycles; hart-1 commit stream == mixed stream for the first 64,998 records (49,310 strict-value records, 0 mismatches; divergence at the documented `probe_solo` mode boundary) |
| drained probe (`t6b4-probe-drained-v4`) | pass, 3,013,247 cycles |
| anchor probe (`t6b4-probe-anchor-v4`) | pass, 3,214,702 cycles; same checksum independently |
| `mut-stb-no-hart` | **fail** @3,102,950 — `RES0=0x5` (`RES_FAIL_PP`), `h0_pp=205` cross-hart speculative forwards observed |
| `mut-bank-active-lsu-ctx` | **fail** @130,457 — `RES0=0x3` (`RES_FAIL_TRAP`), `trap_mcause=15` (store page fault): hart-1's S-mode store resolved in hart 0's translation context |
| `mut-tlb-no-hart-tag` | **fail** @3,102,606 — `RES0=0x6` (`RES_FAIL_TLB`, `h0_tlb=512` aliased words) + `RES1=0x2` checksum corrupt |
| `mut-ctrl-switch-degrades` | **fail** @259,215 — `t6b3_switch_keeps_commit_flush` assertion fires ("switch degraded a commit-level flush under mixed residency") |
| `mut-lsq-no-hart` | **fail at leaf** — `tb_g6lc_lsq`/`run_lsq_leaf.py`: mutant hart-1 load stalls on hart 0's unresolved store (`LSQ_XHART_STALL stall=1`); inverted negative `LSQ_XHART_STALL stall=0`; positive `LSQ_HART_PASS`; synth 2,691 cells / 0 latches / 0 SCCs |
| `mut-decode-active-irq` | **fail at leaf** — `tb_g6lc_idstage`/`run_idstage_leaf.py`: mutant injects `ex.valid=1 cause=0x8000_0000_0000_0007` (M_TIMER) into a hart-1 entry (`DECODE_ACTIVE_IRQ`); inverted negative and `IDSTAGE_IRQ_PASS` both green |
| `mut-no-peer-restart` | **fail at leaf** — restart bank leaf `+mut_no_peer`: `RESTART_PEER_MISP hart1 bank got=7100 want=8c2e` |

*Why three negatives are leaf-level.* The probe stimulus was driven hard
enough to prove reachability bounds, and the remaining inertness is
structural, not a coverage gap to hide:
`LSQ_NO_HART` — `stl_data_o` is unconnected in `g6lc_ooo_dispatch.sv`
(`.stl_data_o()`), so cross-hart LSQ leakage can only manifest as
stalls/replays, never a data mismatch; clean and mutant runs show
identical replay counts (113). The leaf drives the exact seam.
`DECODE_ACTIVE_IRQ` — wrong-hart injection needs a peer instruction at a
decode lane while the active hart's context (`irq_ctrl_b[active_hart]`,
`irq_i[active_hart]`) has pending+enabled irq; 144 timer fires produced no
collision — the active hart's own entries dominate the decode ports and
vector within ~10 cycles, and its trap's commit-level flush kills the
peer's unissued lanes. The leaf presents both contexts directly.
`NO_PEER_RESTART` — needs a partial kill while the inactive peer holds
restart candidates; `peer_restarts_caused=0` on every run of the campaign
(3.1M-cycle probe, 10.6M-cycle OpenSBI, drained and anchor). The
`+mut_no_peer` plusarg lane of `tb_g6lc_restart` drops the same restart
leg and fails `RESTART_PEER_MISP` as designed.

*Regressions (post-fix models, all rebuilt 0-warning).* Mixed OpenSBI
profile on `work-ver-t6b4-mixed-v3` (`+smt_flow_trace +smt_mixed_stats`,
14M cap): `outcome=pass`, `strictDualPassed=true`,
`*** SUCCESS *** (tohost = 0) after 10606940 cycles` — vs 10,602,826
pre-fix (+4,114 cycles, the now-unmasked full flushes at the coincidence
cycles); retiredByHart {0:356074, 1:8936331}, `both_resident_cycles=60092`,
`peer_restarts_caused=0` on this profile too. Drained dual on
`work-ver-t6b4-drained-v2`: `*** SUCCESS *** ... after 10696498 cycles` —
exact, bit-identical (the `MixedSmt` gate constant-folds off the drained
path). Anchor on `work-ver-t6b4-anchor-v2`:
`*** SUCCESS *** (tohost = 0) after 12765628 cycles` — exact,
`protectedAnchor=true`. Frozen integer probes on `work-ver-t6b4-ooo-int-v1`:
11/11 pass cycle-identical (s11=11256, s4=842, s20=921, s32=869, s33=899,
s34=869, s35=918, s36=918, s37=852, ilp=1117, memdep=1021). FP suite on
`work-ver-t6b4-fp-v1`: 13 positives pass, 10/10 negatives detected.
`verify --lint --synth --remote`: lint 8/54 warnings at baseline, synth
32/5 clean — gate passed (the two strict-slang elaboration steps skip
environmentally: no standalone slang on the builder). On clean models
neither translate_off assertion fired anywhere in the campaign — the
mixed `t6b3_switch_keeps_commit_flush` saw zero
`smt_switch && commit_flush` coincidences outside the original defect,
and the drained `t6b3_drained_switch_no_commit_flush` stayed silent on
every drained and anchor run (no latent-legacy finding). On the
`G6LC_MUT_CTRL_SWITCH_DEGRADES` mutant the mixed assertion fired at
259,215 — the intended catch.

**T6b-4a measurement (`smt_mixed_probe` v4, `+smt_mixed_stats`).** v4's
double-divide speculative pad produces real residency overlap — 652k
both-resident cycles (21.0%) vs v2's 1.85% — so this table is the first
that exercises the mixed mode under contention.

| Metric | solo (mixed pkg, h0 parked) | drained | mixed | anchor (in-order) |
|---|---|---|---|---|
| total cycles | 380,600 | 3,013,247 | **3,101,269** | 3,214,702 |
| hart-1 kernel window (cyc) | 25,204 | 57,161 | 51,699 | 65,313 |
| hart-0 retired / active / IPC | — | 817,740 / 1,267,685 / 0.645 | 766,592 / 1,640,113 / 0.467 | 875,657 / 1,615,340 / 0.542 |
| hart-1 retired (1st pass) / act / IPC | 18,259 / 25,208 / 0.724 | 18,264 / 28,955 / 0.631 | 18,406 / 25,771 / 0.714 | 18,067 / 32,623 / 0.554 |
| total retired (h0+h1) / agg IPC | 192,590 / 0.506 | 1,714,424 / 0.569 | 1,892,225 / **0.610** | 1,578,539 / 0.491 |
| both_resident_cycles | 0 | 0 | 652,488 (21.0%) | 0 |
| nonactive_commits | 4 | 0 | 193,044 | 0 |
| HOL-blocking cycles | 0 | 0 | 390,763 (12.6%) | 0 |
| lsu_ctx_switches | 47,694 | 34,786 | 252,048 | 47,138 |
| sb_occ avg/max (h0, h1) | 0.00, 6.31 / 8, 8 | 2.05, 3.32 / 8, 8 | 2.20, 4.12 / 8, 8 | 0.64, 0.63 / 4, 6 |
| iq_occ avg/max (h0, h1) | 0.00, 3.06 / 4, 6 | 1.17, 1.55 / 7, 7 | 1.17, 1.93 / 7, 7 | — |
| lsq_occ avg/max (h0, h1) | 0.00, 1.97 / 3, 5 | 0.24, 1.09 / 8, 5 | 0.21, 1.35 / 8, 5 | — |
| rob_occ avg/max | 6.31 / 8 | 5.37 / 8 | 6.32 / 8 | — |
| prf_used avg/max | 66.50 / 71 | 66.01 / 71 | 66.55 / 71 | — |
| mispredicts (h0, h1) | 2, 5,457 | 28,750, 24,296 | 28,756, 31,094 | 28,730, 20,243 |
| peer_restarts_caused | 0, 0 | 0, 0 | 0, 0 | 0, 0 |
| stalls while peer ≥half sb (rob/iq/lsq/rename) | 0/0/0/0 | 0/0/0/0 | 0/0/77,570/77,689 | 0/0/0/0 |

Mixed vs drained: **+7.2% aggregate throughput** (0.610 vs 0.569
instr/cycle) and hart-1's kernel window 9.6% faster (51,699 vs 57,161
cycles — mixed lets hart 1 commit while hart 0 stays resident; drained
serializes it). The costs are now measurable: 193k non-active commits,
252k LSU context switches, **390,763 HOL cycles (12.6% of run)** where the
commit head waits while a peer's oldest entry is complete — the single
biggest T6b-4 performance target — and 77.5k+77.7k issue stalls taken
while the peer holds ≥half the scoreboard (lsq/rename attribution;
rob/iq attribution zero). `peer_restarts_caused=0` confirms the partial
-kill peer-restart leg stays cold under this scheduler. The ping-pong and
TLB witnesses stay clean (`h0_pp=0`, `h0_tlb=0`, `h0_tmr=144` correct).

### T6b-4b — per-hart commit heads over the shared ring (2026-09-24)

**Design (all new logic under `MixedSmt = NrHarts>1 && !SmtDrainedHandoff`;
drained/single-hart constant-fold to the legacy commit mux and stay
bit-identical — the drained 3,013,247 and anchor 3,214,702 probes are
cycle-exact).**

- `head_slot[h]` = oldest live entry of hart h (rotate/find-first over
  `issued` from the anchor, the `sb_head_scan` shape exported as a slot);
  `commit_pointer_q[0]` doubles as the **reclaim pointer** — each cycle it
  jumps in one step to the oldest remaining live slot (holes skipped).
  Window accounting `free = NR − ((issue_ptr − reclaim) mod NR)` with
  `issued_cnt==0` disambiguation replaces popcount, so a committed non-head
  hole inside `[reclaim, issue_ptr)` cannot alias as allocatable space.
- **Port 0** = ring-oldest *flush-capable-privileged* head when one exists
  (ex.valid, CSR fu, replay, drop-with-ex, AMO), else the reclaim entry —
  all exception/eret/CSR/store/fence machinery stays port-0-only.
- **Port 1** = (a) the legacy same-hart `port0+1` slot only when **both**
  halves can actually retire — `p1_leg_ok` requires the +1 slot live,
  same-hart, *and* both it and the port-0 entry complete/cancelled (an
  incomplete port-0 head makes the +1 a dead presentation that parks the
  peer's complete head — the rework that doubled cross-hart commits);
  else (b) the other hart's live head, restricted to complete simple
  `ALU/LOAD/CTRL_FLOW/MULT`, `!ex.valid`, `!replay`, `!halt`,
  `!flush_dcache`, per-port-hart step clear, `!flush_i` (full-flush cycles
  park the port-1 cross commit so the peer-restart frontier never samples
  a pre-retire head — the v1/v2 duplicate-retire bug), and no port-0
  privileged ack that cycle. Single-resident streams never set the
  cross-hart leg, so `SBC_LEGACY_EQUIV` holds by construction.
  FPU/FPU_VEC never cross-hart on port 1 (fflags is a single bank channel).
- **Anchors:** `commit_ptr_i` (dispatch/IQ/LSQ age), `store_buffer.
  commit_trans_id_i`, and the IQ system-CSR gate take `reclaim_ptr_o`;
  `commit_tran_id_o`/`csr_commit_tid_i` stay the port-0 slot;
  `rvfi_commit_pointer_o[p]` and the smt-flow trace id = the muxed port
  slot.
- **Consumers fixed:** `g6lc_rob` frees by transaction id (positional
  `head_q+r` freed the wrong entry under out-of-order commit); the CSR
  bank/regfile ack path gains a per-port hart vector (`commit_ack_g[h][p] =
  ack[p] && hart[p]==h`) so a hart-B port-1 ack no longer increments
  hart-A `instret`; store commits require `tid == speculative-queue head`
  (one comparator in `store_buffer`, stat `store_head_mismatch_stall_
  cycles`); scoreboard frees the *muxed* slot on the raw ack.
- **Assertions (translate_off, MIXED):** port presents a per-hart head or
  the legacy +1; per-hart commit order monotone; reclaim ≤ live <
  issue_ptr; no privileged on port 1; `commit_ack[1] && cross-hart |->
  !port0_flush_capable`; `issue_full` ⇔ window_free < i+1; no dispatch
  overwrite of a live slot.

- **HOL metrics (sim-only, `cva6.sv`).** `hol_residual` = cycles where
  some hart's head is complete, non-privileged and **not presented on any
  commit port** (`commit_sel_slot[p] != hs` for all p) — the port-
  availability measure. `hol_presented_unacked` = presented-but-unacked
  heads (store-buffer backpressure, halt, flush-cycle parking land here).
  Both print on the `[smt-mixed]` line under `translate_off`.

**Leaf oracles (all remote, sources.json verified == repo per file):**
`t6b4b-sbcommit-v9` **7/7** scenarios + `G6LC_MUT_SB_POPCOUNT_FREE` caught
by `SBC_NO_OVERWRITE` (interleaved alloc, cross-hart hole, reclaim jump,
full-ring no-overwrite, CSR/exception/replay port-0 routing,
`SBC_LEGACY_EQUIV` cycle-exact, plus scenario 6: the both-complete
port-1 rule — B0 head commits while A0/A1 incomplete, then the legacy
A0,A1 pair retires on one cycle); `t6b4b-storebuf-v11` 38/38
`STB_HEAD_STALL`; `t6b4b-rob-v2` tid-keyed free + positional-free
mutation caught; `t6b4b-rob-sby-v3` formal **PASS** (11 `$check` cells,
4 FLAVOR-assert); `t6b4b-csrbank-v5` 14/14 `CSRBANK_ACK_PORT`;
`t6b4b-dispatch-v4` 28/28 n2. Runner hardening: all three leaf runners
(`run_sbcommit_leaf.py`, `run_rob_leaf.py`, `run_rtl_audit_review.py`)
use the deterministic deepest-path `pick()` — a reused run dir's stale
top-level copies previously shadowed fresh sources via `rglob` order
(and `output/source` mkdir is now `exist_ok`-safe). `g6lc_rob`'s head
re-anchor is a fixed-trip `for` over `ROB_ENTRIES` (synthesizable), same
report-only semantics as the retired `while`.

**The duplicate-retire fix.** The first mixed model (`mixed-v1`, same for
v2 — the remote mirror had not been re-synced) failed the probe with
`RES1=0x2` and a wrong hart-1 checksum: a cross-hart port-1 commit landed
on the same cycle as a full flush, the peer-restart frontier sampled the
scoreboard head before the retire was visible, parked the already-committed
PC `0x8000020a`, and refetched it on resume (double execution → checksum
corruption). Fix: `commit_stage.flush_i` input; the cross-hart port-1
eligibility gains `&& !flush_i`; new translate_off assertion
`SBC_P1_FLUSH` (no cross-hart port-1 ack on a flush cycle). Mixed probe v3
then passed bit-exact.

**T6b-4b measurement (`smt_mixed_probe`, `+smt_mixed_stats`, models
`work-ver-t6b4b-*`; mixed column is the post-`p1_leg_ok` v4 probe —
hart-1 checksum `0x2d9e464b9adce718` exact, drained/anchor cycle-exact).**

| Metric | solo | drained | mixed | anchor |
|---|---|---|---|---|
| total cycles | 380,600 | 3,013,247 | **3,102,032** | 3,214,702 |
| hart-1 kernel window (cyc) | 25,204 | 57,161 | 51,691 | 65,313 |
| hart-0 retired / active / IPC | — | 817,740 / 1,267,685 / 0.645 | 774,775 / 1,639,882 / 0.472 | 875,657 / 1,615,340 / 0.542 |
| hart-1 retired / act / IPC | 18,259 / 25,208 / 0.724 | 18,264 / 28,955 / 0.631 | 18,410 / 25,768 / 0.714 | 18,067 / 32,623 / 0.554 |
| total retired / agg IPC | 192,615 / 0.506 | 1,714,424 / 0.569 | 1,892,225 / **0.610** | 1,578,539 / 0.491 |
| both_resident_cycles | 0 | 0 | 410,053 (13.2%) | 0 |
| nonactive_commits | 4 | 0 | 192,011 | 0 |
| hol_residual (head not presented) | 0 | 232 | **26,215** (0.8%) | 938 |
| hol_presented_unacked | 0 | — | 1,341 | — |
| cross_hart_port1_commits | 0 | 0 | **24,086** | 0 |
| store_head_mismatch_stall | 0 | 0 | 0 | 0 |
| lsu_ctx_switches | 47,694 | 34,786 | 252,084 | 47,138 |
| stalls peer ≥half sb (rob/iq/lsq/rename) | 0 | 0 | 0/0/40,872/40,974 | 0 |
| peer_restarts_caused | 0,0 | 0,0 | 0,0 | 0,0 |

vs T6b-4b pre-rule (v3): the `p1_leg_ok` both-complete preference doubled
cross-hart port-1 commits **12,096 → 24,086** and cut total cycles
3,104,000 → 3,102,032 (−0.06%); aggregate IPC holds 0.610, hart-1 window
51,691 identical. The reworked `hol_residual` (complete simple head not
presented on any port) reads 26,215 — versus 453,979 under the old
unacked-head definition — and `hol_presented_unacked` adds only 1,341, so
residual HOL is now almost entirely *head-not-yet-complete* upstream work,
not commit-port availability; it stays the T6b-4 performance target.
`store_head_mismatch_stall_cycles=0` — the head-comparator costs nothing
on this trace.

**FO4 — the mixed-commit screen is `sparse_smt_mixed_commit`
(`t6b4b-fo4-mixed-v1`, param map `g6lc64_smt2_mixed_xlen64.json`,
NrHarts=2/SmtDrainedHandoff=0/OoOEn=1).** The mixed cone is live in this
screen: the scoreboard's three worst adjusted paths are the reclaim scan
(`live_first`/`reclaim_n`, line 647, **19.00**, raw 83), the privileged-head
select (`priv`/`hdist`, line 319, 16.5) and the window accounting (`wdist`,
line 183, 15.9); the analyzed IR lists `MixedSmt`, `head_slot`,
`commit_sel_slot` among the module's elaborated names. `commit_stage`'s worst
path stays the legacy AMO `wdata` mux (line 209, **16.00**, raw 155) — the
cross-hart gate is not the module's critical cone. Per-module adjusted FO4 vs
the 32-FO4 budget @1250 MHz/20 ps: scoreboard **19.00**, commit_stage
**16.00**, store_buffer **17.46** (raw 202), g6lc_rob **22.00** (raw 84) —
profile primary 22.0, closes=True. Geometry caveat: the screen runs the
`g6lc64_smt2` ring (`NR_SB_ENTRIES=8`); the rotate/find-first head scan and
the reclaim scan grow by ~log2 mux levels per ring doubling, so a 32-entry
mixed configuration must be re-screened before it is called
timing-qualified. **The `sparse_issue_lsu` screen folds
`MixedSmt` to 0** (`cv64a6_imafdc_sv39` param map → single-hart) — its
scoreboard/commit_stage numbers measure the legacy mux only, not
T6b-4b logic; rerun on the final RTL: primary 39.5 / worst 66.0 /
closes=False @1012.7 MHz, 241 paths, unchanged — the pre-existing
store_unit↔store_buffer bridge still dominates, out of scope.
`sparse_ooo_issue` rerun (g6lc_rob changed): primary 30.0, closes=True.
Two front-end-strictness fixes landed for the screens: `!|live_rot` →
`live_rot == '0` (sv-parser and yosys-slang both reject the stacked
unary) and the `MixedSmt` localparam moved above its first use (slang
declaration-order rule) — semantics-identical.

**Firmware/regressions (post-rework models `work-ver-t6b4b-{mixed-v4,
drained-v3,anchor-v3,ooo-int-v3,fp-v3}`):** probes `t6b4b-probe-mixed-v4`
3,102,032 cyc / `t6b4b-probe-drained-v3` **3,013,247 exact** /
`t6b4b-probe-anchor-v3` **3,214,702 exact** / `t6b4b-solo-mixed-v4`
380,600 — hart-1 checksum `0x2d9e464b9adce718` everywhere, solo↔mixed
hart-1 stream identical for 64,998 records (49,310 strict-value, 0
mismatches; `PASS-WITH-MODE-BOUNDARY` at the documented `probe_solo`
edge). OpenSBI dual-hart: `t6b4b-firmware-mixed-v3` **10,606,940** (=
T6b-3 exact), `t6b4b-firmware-drained-v4` **10,696,498 EXACT**,
`t6b4b-firmware-anchor-v3` **12,765,628 EXACT** — all strictDualPassed.
OpenSBI-mixed stats: cross_hart_port1 4,944, hol_residual 1,340 /
presented_unacked 536, store_head_mismatch 0. Int suite 11/11
cycle-identical to v2b; FP 14 pass + 10/10 negatives detected;
`verify --lint --synth --remote --allow-skips` lint 8/54 baselines,
synth 32/5 clean (`t6b4b/verify-remote-t6b4b-v2.txt`).

**Slices.** T6b-1 config bit + drain gate seam, hart-tagged LSQ/store-buffer/IQ ordering,
`sb_head_pc`, leaf oracles (drain gate still on: every existing result must reproduce). T6b-2
recovery and frontend per-hart state (flush restart, inactive-hart redirects, per-hart filter),
commit-side per-hart interrupt/CSR/WFI. T6b-3 the `SmtDrainedHandoff=0` firmware gate with the
concurrent-work probe and the isolation negatives. T6b-4 (performance, after exit) partitioned
heads and PRF floors.

## T7 — integrated OoO coherence continuation (2026-09-24; partial)

Dependency order is the contract's §8: validated observation → transport/refill conservation →
compact signatures and credit sizing → physical-load validation → whole-core coherence gates.
The in-order path and every existing FP/mixed-SMT guard remain protected. No completion or
production promotion follows from the leaf results below.

1. **Observation and shared defects.** The mixed-probe classifier now requires transport success,
   one early completion, checked RES/checksum words and no assertion errors; solo mode comes from
   ELF data. `SMP_REASSESS_DIR` reclassifies a frozen run without executing the model and stamps
   the input log/ELF hashes. The optimizer kernels gained release/acquire fences, bounded peer
   waits, nonzero timeout results and independent ALU work anchored to the start-counter result.
   Assembly ROI is unmeasured; the old 904-AU incomplete source report remains historical.
2. **Transport and L2.** Hub atomic completion owns both B and RLAST in either order; response-ID
   bounds use an extra bit. Old sources fail OT1/OT4 atomic and OT16 ID-space tests, candidates
   pass. L2 installation loses to a same-edge matching invalidation. Its memory requests are
   independent of conflict-dependent completion, avoiding an UNOPTFLAT cycle exposed during the
   repair. `FAIR_WRITES` provides bounded arbitration opportunities for a pending write and is
   selected by `OoOEn` for L2/L3; its state does not exist on the disabled path. The 64-record
   HUM suite, negative controls and small RR0/RR1 synthesis pass with fairness enabled.
3. **Signature implementation, not promotion.** `COH_OOO` selects a separate hub generate branch
   and `g6lc_ooo_snoop_filter`: one-port, one-cycle `tc_sram`; one byte per core in padded 32-bit
   words; monotone presence; an explicit `NR_ENTRIES`-cycle cold sweep; acquisition backpressure
   during the lookup; and saved AW ownership until acceptance. The first envelope is integer OoO,
   multiple WT cores, equal I/D L1 line widths and L2. WT word writes do not allocate new tags;
   AR records every possible read acquisition, including speculative reads. `check_cfg` and the
   cluster refuse unqualified use without `G6LC_OOO_COH_QUALIFY`. No production package enables it.
   The signature branch requires at least two hub credits so a write-owned lookup cannot monopolize
   the sole request slot; cluster credits stay at four. Verilator 5.008 downgrades static `$error`
   under `-Wno-fatal`, so the new guard test uses `-Werror-USERERROR`; invalid/unqualified modes
   also have simulation-fatal backstops. This is not a proof authorizing MSHR-depth reduction.
   The reduced two-core/two-index ten-frame proof, reached alias cover, three-core simulation,
   dropped-write mutation and three-core hub/negative seam checks are separate scoped evidence.
4. **Measured area.** `ooocoh-signature-area-20260924-v2`: N2/E128 tagged→signature is
   45,626→1,287 generic cells and 7,168→274 sequential cells; N4/E256 is 95,541→4,537 and
   14,592→1,046. Logical signature bits are 256/1,024 but SRAM port storage is 4,096/8,192 bits
   after byte/word padding. The implementations have different latency and initialization; no
   cycle benefit, whole-hub saving or physical area follows. Do not substitute these counts for
   `area_au` in an optimizer series. Matched fixed-work cycles are still owed.
5. **Next ownership boundary, open.** The WT return decoder could acknowledge a D-cache R beat
   while delivering only an external invalidation. Ready now excludes that collision; the actual
   source-extracted decoder passes combinational proofs with RVA off/on and failing negatives.
   This is not a full-adapter/fill-lifetime proof. Before wiring replay, export the accepted tag/
   check-stage PA with its owner: existing `load_paddr_o` is a virtual STQ key, and current LSQ
   entries can disappear at WB. Define same-cycle snoop/retirement, store-forwarded loads,
   physical aliases, sibling-hart committed writes and TID reuse. An enqueue ack is not an
   applied-invalidation ack. Unequal outer/L1-line inclusion also remains open.
6. **Verification route.** User selected immutable run-local snapshots, not shared-mirror rsync
   deletion. `run_ooo_coherence_gate.py --prepare <fresh.zip>` captures native generated lint/synth
   scripts and their source/header closure; remote execution only substitutes the isolated source
   and output roots, retaining hashes before/after. Default-target snapshots retain lint 8/54 and
   synth 32/5; these are not whole-cluster simulation or standalone-slang passes. The historical
   hub quality harness now pairs the archived hub with its archived dependency interfaces rather
   than a hybrid of old/new port names; bounded reservation proofs, covers and synthesis pass.

Credit-bound MSHR reduction, accepted-physical-address validation through retirement, applied-snoop
visibility, full multicore integration, PMU/FO4/physical gates and final promotion remain unfinished.
Artifacts are under the approved C: root with prefix `ooocoh-`; exact scopes are in the tests map.

### T7b — physical validation and WT fill lifetime (candidate, not promoted)

The grant/tag boundary now supplies an independent physical event (PA, TID, hart, size).
A successor LSU head cannot rename the prior grant's event; cancellation/fault/flush suppress it.
The old `load_paddr_o` remains a virtual STQ key. The new mode disables that uncertified forward
shortcut rather than treating its width as proof of translation. `ooocoh-load-physical-before-20260924-v1`
reproduces a forward completion before translation is certified. Twelve new producer outcomes,
60 legacy load/cancellation outcomes, and address/owner/cancel/forward mutations are captured
under `ooocoh-load-*`. This trades early STQ-forward performance for a sound initial envelope;
restoring a physical-qualified shortcut is a separate, measured optimization.

The physical event traverses LSU/EX/core/issue/dispatch to the existing LSQ records. In `COH_OOO`,
AGU addresses do not certify them; early dependency checks use page offsets conservatively. A
load's record survives WB until its architectural release or cancellation. Store/load aliases train
memdep; late older-load aliases and modifications only replay. The masks retain every affected
TID across harts, and PMA-defined non-idempotent loads are excluded from replay. A registered-state
pending mask and a modification-cycle retirement hold feed the scoreboard; replay/cancellation
becomes sticky before the existing precise drop path frees the slot. Exceptions are not stranded.

`ooocoh-lsq-physical-v3` has 22 matched positive/negative outcomes; the legacy LSQ has 88.
`ooocoh-retire-physical-v1` exercises the actual scoreboard plus commit_stage (8 outcomes), with
pending/modification suppression mutations detected. `ooocoh-physical-ledger-formal-v1` proves
occupancy, pending certification, live-owner and modification replay obligations to 12 frames with
four transaction identities/two load entries, reaches a completed-load/snoop witness, and detects
a checker negative. `ooocoh-physical-retention-mutation-v1` restores WB-time release and fails.
These are bounded/leaf scopes, not full-core memory-model qualification.

Enabled-core synthesis initially found 53 commit/flush loops: pending-valid suppression depended
on flush, while pending fed commit validity. The correction separates pending into a registered-state
only cone. `ooocoh-active-core-gate-v2` passes lint and synthesis (24/1 warnings). This is a single
`cva6` top with the candidate ACTIVE, not multicore simulation: the snapshot privately overrides
NrCores to two and policy to `COH_OOO`, records original/effective hashes and defines the existing
qualification macro. No checked-in production package is modified. Default target checks retain
8/54 lint and 32/5 synthesis baselines; input-default syntax rejected by Verilator 5.008 was removed
and callers explicitly tie inactive ports rather than waiving the error.

The WT fill fixture reproduces both invalidation-during-fill stale installation and invalidation
lost to the flush array port. A fill-owned kill bit now prevents installation without losing the
original response or byte offset; a subsequent fill starts clean. Invalidation wins over flushing
while the scan retains its current index and cannot terminate on a diverted last-index write.
The repair applies to multicore WT independently of issue policy, plus the `COH_OOO` candidate;
the single-core legacy case is preserved. `ooocoh-wt-fill-after-v2` has 32 expected outcomes,
including full sweep coverage and a last-index collision. The fixture uses live extracted bus types
and a private packed-field `split_var` control to keep UNOPTFLAT fatal without altering RTL.

The new core event is a delivery/apply-stage observation, not an end-to-end write-completion ack.
Still open: simultaneous external/atomic self-invalidation conservation, local-CAS notification
coverage, write visibility versus applied invalidations, full-stack MMU/permission and multicore
execution, the protected OpenSBI anchor, capacity proof, and PMU/FO4/DFT/physical qualification.
The production guard and unchanged MSHR depths are intentional until those gates close.

### T7c — production-request review: not promoted

The interrupted invalidation-delivery work is preserved. Its sequence counters, retained B payloads
and fixed apply settling were not sufficient release evidence. New failing controls exposed lost
upper PA bits in retained atomic invalidations, changing B payload under backpressure, and younger
same-original-ID B responses bypassing older invalidation-blocked Bs. The retained address is now
PLEN-wide; the index is a projection only. Per-core offered-slot ownership locks B through its
handshake, and per-slot predecessor masks preserve B order for each core/original-ID key.
Dependencies retire on core B acceptance, including B-before-R atomics, not on memory B capture.

Atomic R now shares the invalidation qualification of B; a valid but blocked atomic cannot fall
through the malformed-ID drain. AW cache[1], ATOP or lock use one invalidation predicate. Cache0
atomic coverage is a generic-interface obligation: the actual core axi_shim emits CACHE_MODIFIABLE.

Evidence: `ooocoh-self-pa-after-r1` has six-frame source-extracted state/apply proof, negative and
cover, with truncation restored in `ooocoh-self-pa-mutation-r1`. Hub cases 19/20/24 have before,
after and restored-omission evidence (`ooocoh-b-*-r1`). `ooocoh-atomic-order-after-r1` has six
positive/negative records for atomic publication exclusion and same-ID order plus a signal-driven
hub synthesis pass. `ooocoh-lifetime-review-r2` has 42 records across 1/4/16 credits;
`ooocoh-hub-regression-review-r1` retains 16 original outcomes; the three-core signature seam and
its synthesis pass in `ooocoh-signature-review-r1`. The old lifetime cases now begin after the
invalidation settle interval because cache0 atomics acquire an obligation; their ownership checks
remain intact, and distinct publication cases enforce the exclusion window.

Fresh default and active single-core-top archive gates (`ooocoh-production-review-default-r1`,
`ooocoh-production-review-active-r1`) pass at 8/54 and 32/5 default lint/synth warnings and 24/1
active warnings. These are not cluster simulations. The first new hub synthesis wrapper had an
unqualified enum name; it failed, was corrected, and its failed artifact was retained.

**Composition result (T7d):** a standalone AXI slave permitting reads during delayed writes can
refill old data after an AW-time invalidation and still see the writer's B later; scenario 23
preserves this generic counterexample. `tb_g6lc_coherence_l2` composes the unchanged hub with the
actual `g6lc_l2_top`: the L2 refuses the reader's AR for the entire stalled-write window
(`blocked=14..33`), admits it one cycle after the memory B, and the refill returns the new value
in the small, modifiable-only, stalled and 256 KiB/2-MSHR geometries, each with a negative oracle;
`USE_L2=0` reproduces the stale refill and disconnecting the L2 self-invalidation restores it.
A signal-driven Yosys `scc` check proves the composed graph loop-free. On this evidence the
rights holder accepted the review and promoted `g6lc64_ooo_int2` (guard removed); the deferred
items below stay open for unrestricted release. Do not reinterpret the generic-slave test as a
demonstrated failure of the serialized L2, nor the composition result as coverage of other slaves. Neither moving the command to buffered WLAST acceptance alone nor
adding arbitrary settle cycles is a proof of global visibility. FIFO-admission acknowledgements
with unbounded consumer delay (HPDCACHE retain path) also cannot use fixed WT application latency
as proof. Full CAS notification coverage, R-ID ordering, credit bound and multicore/firmware/
compliance/PMU/DFT/FO4/physical gates remain open. No production package or qualification guard
was changed.

Timing/area note: added B order state is OT_MAX squared control bits, plus NC times (1+OT_W)
offer-lock bits; the default four-credit geometry is small but the quadratic parameter scaling
must be checked. The dependency reduction and selection predicates are in the B-valid cone.
No new clock/reset domain, ISA/DTS capability or permission rule was added. Existing reset/scan
integration is preserved structurally, not newly signed off. Generic synthesis and directed tests
do not establish foundry area, STA, power, useful-work speedup or production readiness.

### T7e — deferred items closed after promotion (2026-09-24)

**Per-ID R ordering.** Every AR is re-tagged with its slot index toward memory, so two reads
from one core with the same original id become distinct downstream ids and the L2's
hit-under-miss path may legally answer the younger one first; AXI still owes the core same-id
R order. The hub now masks a core's AR request while an older AR slot of the same
(core, original id) is live (`ar_same_id_live`), so the younger read is admitted only after
the older R completes; another core with the same id and the same core with another id are
not held. Scenario 25 `same_id_r_order` holds the younger AR for six cycles, admits the two
non-conflicting reads, releases on the older RLAST and drains all three in order; the negative
oracle and the restored defect (`REVIEW_HUB_B_FAULT=r-order`, guard removed) both fail with
`HUB_R_ID_ORDER` (`ooocoh-r-order-after-r1`, `ooocoh-r-order-mutation-r1`). Lifetime set is
now 46 records at 1/4/16 credits (`ooocoh-r-order-lifetime-r1`), original regression 16,
three-core signature seam and hub synthesis pass, composed hub+L2 4/4, promoted cluster gate
lint 24 / synth 7 warnings, 0 errors (`ooocoh-r-order-int2-r1`).

**Structural FO4 screen (sv-timing, fo4_ps=20 ps, 1250 MHz, margin 0.2, budget 32.0 FO4).**
Host adapter run over `core/Flist.cva6` plus `Flist.cluster` minus the two lint tops
(`workspace/build/sv-timing/ooocoh-fo4-r{1,2,3}`). Hub worst 32.0 (three at-budget
handshake-lock paths at the AR grant), signature filter 3.0, LSQ 24.0, WT miss unit 22.0,
WT adapter 18.5, L2 top 20.5 — all within budget. `g6lc_inval_bus` started at 57.0: the
`% DP` pointer advances were charged as dividers and the per-core loop body was summed
serially. Replacing the modulo with wrap-compare increments (37.0) and hoisting `tail_m1` to
one continuous assignment per core (33.5) leaves a residual 1.5 FO4 over budget attributed
to the two independent 8-bit sequence-counter increments summed in statement order
(`add_sub` 10.0 each). That is a `plain`-class screening artifact of independent non-blocking
assignments, recorded here as a package-first follow-up for sv-timing's path classification,
not as an RTL closure claim; STA sign-off remains open. Both inval-bus rewrites are
behaviour-preserving and re-verified: leaf 10/10 (`ooocoh-inval-hoist-r1`), lifetime 46,
regression 16, composed 4/4, promoted gate lint 24 / synth 7 warnings, 0 errors
(`ooocoh-inval-hoist-int2-r1`).

### T7f — remaining deferred items worked (2026-09-24)

**Local AMO/CAS notification coverage.** `verif/tb/uncore/tb_g6lc_wt_amo_apply.sv` drives the
real `wt_axi_adapter` under the `g6lc64_ooo_int2` configuration: AMO_SWAP, Zacas AMO_CAS1 and
AMO_LR each return a `DCACHE_INV_REQ` for the AMO index and raise `inval_apply_valid_o` with the
full AMO PA (the `mem_mod_valid[0]` source of the physical-load checker); with an external
invalidation coincident with the AMO grant the external event is applied first, `inval_ready_o`
stays low while the self-invalidation is retained, and the AMO event follows. Negative oracle
(`WT_AMO_APPLY`) and a mutation that exempts AMO_CAS1 from `invalidate` (`WT_AMO_INV_MISSING`)
both detect (`ooocoh-amo-apply-r6`, `ooocoh-amo-apply-mutation-r1`, `REVIEW_WT_AMO_APPLY=1`).

**PMU.** Group 2 gains event 5 (L1 coherence invalidation applied, WT return path) and event 6
(COH_OOO load marked for replay by a modification event), wired `issue_stage.ooo_phys_replay_o`
/ `inval_apply_valid` → `perf_counters`. Indices are stable once published. Perf leaf 8/8
(`ooocoh-pmu-perf-leaf-r1`); int2 gate lint 24 / synth 7; default 8/54 and 32/5; the active
target showed 5 pre-existing `LATCH` lint warnings from an unassigned local in the LSQ alias
block under `PHYS_VALIDATE=0`, fixed by a default assignment (gate re-run recorded below).

**Credit-bound MSHR sizing.** `tb_g6lc_coherence_credits` (hub 4 credits + real L2, eight
distinct-line reads from two cores, DRAM latency 8) with the hard bounds `ar_live <= 4` and
`fills <= 4` never violated: depth 2 → `max_fills=2 max_ar_live=3 mshr_stall_cycles=51
drain=92`; depth 4 → `max_fills=4 max_ar_live=4 mshr_stall_cycles=0 drain=77`. The hub's credits
bound L2 fills, so the credit-consistent depth equals the hub slot count; `g6lc64_ooo_int2` moves
`L2MshrDepth` 2 → 4. The 16-MSHR figure of the refused `g6lc64_ooo_server` remains a recommendation
(4 per hub credit set), not a change.

**DFT/MBIST plan.** The signature SRAM now carries `ImplKey("g6lc_coh_signature")`;
`corev_apu/coherence/g6lc_ooo_snoop_filter.tech-spec.md` records geometry, binding rules
(port/latency equivalence, no reliance on SRAM reset, cold sweep as the initialization contract,
BIST ownership while `ready_o` is low) and the scan/observability notes. The technology pass stays
unarmed (`optimizationPass=false`).

Still deferred: matched multicore firmware/anchor/compliance runs, foundry macro selection,
MBIST controller insertion, STA/power/area sign-off, and any cycle/area gain claim. The earlier
claim that multicore execution required shared-mirror synchronization is superseded by the
isolated execution route in T7g. L1 application acknowledgement on non-WT consumers is outside
the `COH_OOO` envelope (`DCacheType == WT` is a legality condition). T7f's perf test compiles
zero-tied new event inputs; it is not directed event-count verification or hub/RVFI connectivity
closure. The eight-read capacity experiment is not a general occupancy/lifetime proof, and the
SRAM binding plan is not MBIST insertion.

### T7g — secondary reset/boot observation repair (2026-09-25)

**Method and scope.** Read the coding philosophy, both SMT reasoning/procedure guides, the
firmware heuristics and runtime-learning guide in full. Followed the legacy reset/restore
references without re-enabling `fetch_A/smt_legacy` (retired, not a current interchangeable
oracle). Contract: delayed clock release must preserve reset initialization and the first boot
address. Candidate owners were reset observation, boot-address wiring and redirect arbitration;
the first boundary probe distinguished them before any production RTL edit.

**Evidence correction.** r1–r3's early primary-only boot print did not establish a bootrom hang.
The per-core RVFI files show primary program execution and the CLINT hart-2 MSIP store, while
core 1 faults at PC zero. The time-200000 end of `[commit-dbg]` comes from its print condition,
not a change in clock-release behavior. These runs also used the installed runtime hash
`8c408609...`, not the private corrected header `dfbc2c4a...`; dependent interpretations needed
revalidation. No earlier leaf/formal/synthesis result is invalidated solely by that discovery.

**Discriminator.** `ooocoh-boot-reset-r1` rebuilds identical generated model C++ against the
validated runtime and changes only a copied driver's reset stimulus/optional observer. Without
an assertion edge, the gated core's `npc_rst_load_q` and both PC banks remain zero during reset.
With an actual reset transition they are initialized before release. On the identical release
probe ELF, the secondary changes from 0 retirements / 3605 instruction-access faults to 8700
retirements / 0 such faults at the 20k-cycle bound. Primary retirement hashes remain identical;
observer-on/off hashes match for both cores. This deliberately endless probe is a reset/liveness
witness, not a completed firmware PASS.

**Repair and local test.** `Makefile` adds `--x-initial-edge` alongside `--x-initial 0`.
`REVIEW_MC_RESET_LEAF=1` in `run_mc_int2_review.py` checks real `rstgen`, `tc_clk_gating` and
`g6lc_smt_pc_bank` with gated/ungated clocks, both hart banks and two boot addresses. Its six
records include the failing original flag setting, explicit-reset controls, positive initial-edge
handling and a negative expected-address control (`ooocoh-boot-reset-leaf-r1`). No production
RTL, bootrom or reset net was changed; hardware timing, DFT and DTS/ISA behavior are unchanged.
The builder uses a per-model tool wrapper and retains the selected runtime include path in VPATH.

**Full-model check and residual.** `ooocoh-boot-initial-edge-r1` rebuilds the frozen source with
the fixed Makefile and validated runtime, without the diagnostic driver or reset prelude. The
release-probe retirement hashes exactly match the explicit-reset control. The identical
`mc_shared_line_cross_core` ELF now runs on both cores with no instruction-access faults, but
reports exit code 2 at cycle 80512 (raw tohost 5 / READY timeout). The publisher trace records
SEED and READY stores; that is not proof of their global visibility. Memory publication/load
observation must be traced next; changing polling bounds or calling this boot failure is not a
repair. Sibling-only/single-core completion controls still report 127 under the all-core verdict
because the other physical core remains intentionally held. They remain incomplete, not PASS.
The runner's ten classifier controls reject missing/duplicate banners, cap exits, incomplete-core
runs, failing exit codes and unvalidated cycle encoding. No new optimization-series entry is
justified by this work.

**Completion probe remains red.** `mc_smt2_boot_release.S` isolates reset/release from cacheable
handshake words by using CLINT MSIP acknowledgements from all four software harts. In
`ooocoh-boot-release-r2`, both positive and negative programs time out at 1000013 cycles; both
physical cores retire and traces show all four hart IDs. The secondary records a clear of its
release MSIP while primary loads continue to report it set. This is a retained post-boot
publication/observation reproducer, not a passing boot-completion test. The r1 attempt stopped
at compilation because the draft runner repeated `a` in its ISA string; the integer-only
`rv64imac_zicsr` / `lp64` invocation now selects the configured RISC-V compiler explicitly.
A transient host GNU-Make preflight failure occurred before r2 reached the remote and produced
no RTL result. Neither failure was recategorized as a pass.

### T7h — post-boot MMIO freshness and CLINT lanes (2026-09-25)

**Boundary evidence.** `ooocoh-visibility-r1` observes accepted core/hub/L2 AXI traffic,
CLINT register updates and WT load returns in an isolated copied source. For the CLINT probe,
observer-off/on retirement hashes match. At time 695 the secondary's write clears MSIP[2];
at 736 the peripheral, L2 and hub all return zero to the primary, but the WT load return is
one at 737. The defect is downstream of the hub response, not a lost CLINT store. The same
observer's shared-line runs have unequal retirement hashes; that comparison is inconclusive
and retained, not silently treated as observer-independent evidence.

**Uncached fixup lifetime.** A post-ACK cache-repair entry must not retain an uncached write as
a forwarding source. The old queue kept it waiting for a tag hit that cannot occur, overwriting
new device reads with stale acknowledged bytes. `wt_dcache_wbuffer.sv` now captures `miss_nc_o`
in each accepted transaction and excludes that transaction from fixup allocation and full-queue
ACK holds. The attribute belongs to the accepted TX, not the current cache-enable signal.
Cacheable repair behavior and the zero-depth branch are preserved.

`run_wt_fixup_review.py` with `WT_FIXUP_NC=1` reproduces the defect before repair. Its expanded
24-record positive/negative matrix at depths 0/2/4 covers MMIO, disabled-cache writes, cache-enable
changes between acceptance and ACK, and an uncached ACK behind a full fixup queue
(`ooocoh-fixup-nc-after-r2`). Removing both exclusions detects stale retention and the ACK hold
(`ooocoh-fixup-nc-mutation-r2`, 12 matched records). The existing 16-record cacheable freshness
suite passes unchanged (`ooocoh-fixup-regression-r1`). These are port-driven lowered-RTL runs,
not unbounded proofs.

**CLINT lane contract.** With stale forwarding removed, the unchanged completion program sees
MSIP[2] clear but reads zero from MSIP[1]. CLINT had returned every 32-bit MSIP at bit zero of
its 64-bit AXI bus; an odd MSIP address selects the upper data lane. The read decoder now places
the bit according to address bit 2, independent of the CPU's XLEN. A real-CLINT/AXI-interface
bench detects the original error for both RV32 and RV64 on a 64-bit bus, checks all four slots,
set/clear independence, returned IDs and stalled R stability, and detects the restored low-lane
fault (`ooocoh-clint-lane-{before,after,mutation}-r1`). Timer-register behavior is not changed.

**Composed completion.** `ooocoh-nc-clint-int2-r1` uses the frozen, unchanged ELF hashes from
`ooocoh-boot-release-r2`. The four-hart boot/release program completes at cycle 775 with the
positive verdict; its negative control reports the intended failure at 775. Both physical cores
retire, with zero instruction-access faults. NC-only integration had already exposed the second
lane defect; that failed intermediate remains `ooocoh-fixup-nc-int2-r1`. No polling bound was
extended and no liveness check was waived. The cacheable shared-line test still reports READY
timeout and remains a separate open coherence obligation. This is not stock OpenSBI/Linux or
compliance completion.

**Rechecks and next boundary.** Isolated current-tree archive gates pass: int2 lint 24 / synth 7
warnings, default lint 8/54 / synth 32/5, all zero errors (`ooocoh-nc-clint-gate-{int2,default}-r1`).
CLINT's signal-driven synthesis and `scc -expect 0` pass in `ooocoh-clint-lane-synth-r2`; r1 was
a wrapper configuration-literal type error, corrected without weakening RTL or assertions.

`ooocoh-visibility-single-r1` rebuilds the observer with one simulation thread; both CLINT and
shared-line observer-off/on retirement hashes now match. It reconfirms the CLINT completion.
In the shared-line capture, the primary repeatedly receives the old READY value without issuing
an AR for that word. The peer's READY AW/W/B complete at times 942/944/945 without a matching
invalidation to the primary. The OoO signature's acquisition input is currently `ar_fire` only,
whereas the legacy filter accepts `aw_fire | ar_fire`. Post-ACK cacheable fixup data can therefore
become a retained copy without the writer being recorded through that path. This was the next
ownership/lifetime hypothesis; T7i confirms and repairs it (writer acquisition and retained-copy
invalidation qualified together, without disabling the filter or removing the queue). The earlier
12-thread observer mismatch remains recorded.

**Impact.** One NC bit per existing write-transaction record; capture and exclusion use existing
handshakes/reset and add no cache-hit datapath stage or new clock/reset/scan control. CLINT changes
only combinational read-lane routing. Existing `WtDcacheFixupDepth` controls the affected queue;
no new ISA/config/DTS capability, memory-map or hart-count change. Existing license notices are
preserved. Physical timing/power/area and broader parameter qualification remain open.

### T7i — writer acquisition and retained-copy lifetime (2026-09-25)

**Mechanism (confirmed, not hypothesised).** `ooocoh-visibility-single-r1` shared-1: the primary's
own `sd zero, READY` (line never resident) is acknowledged as a checked-miss and enters the WT
post-ACK fixup queue, whose tag-miss path retains the word "until a refill". Every poll hits
`wbuffer_all`, `wbuffer_fwd_hit_o` suppresses the refill, so the copy has no lifetime bound. The
peer's `READY=1` AW/W/B (942/944/945) targets no one: the OoO signature acquired presence only on
`ar_fire`, so a core whose first contact with a line is a write was never a recorded sharer. Even
a delivered invalidation would not have helped — the wbuffer only cleared `checked` and paused the
fixup tag check; no path dropped a retained copy. A third, latent defect surfaced while reading
the queue: a same-cycle push-allocate and retire-pop each assigned `fixup_cnt` (+1, then −1, last
assignment wins), hiding the newest entry and later overwriting a live slot.

**Repairs.**
- Hub (`g6lc_coherence_hub.sv`, `gen_ooo_coherence`): the signature acquires on `ar_fire | aw_fire`
  with the AW address/core when a write fires. Port exclusivity holds by construction —
  `sig_start` needs `!ar_hold_q`, `coh_block_ar` blocks AR grants from the lookup cycle through
  `aw_fire`, and `sig_start` is 0 while the lookup is pending, so `alloc_ready` is 1 at `aw_fire`;
  a sim-only `HUB_SIGNATURE_ALLOC_CONFLICT` check pins the premise.
- WT (`wt_dcache_wbuffer.sv`, `wt_dcache.sv`): new `wr_cl_inv_i` = way enables without valid bits
  (external/self/CAS invalidation or flush; refills and NC returns are not). (1) An invalidation
  clears the bytes of every fixup entry at its index (dead entries export no forwarding, a dead head
  is popped without a tag check, dead bypass/RETIRE/CHECK entries fall back to PEND, a later same-word
  ACK revives only the new bytes). (2) Each write transaction records a sticky `inv` when an
  invalidation hits its index while in flight; such an ACK creates no fixup entry, holds no return
  FIFO, and writes no L1 word (`rtrn_inv`, current-cycle inclusive) — its data is not provably newer
  than the invalidating write, memory is. A TX allocated in the invalidation cycle keeps its copy
  (its write is ordered after the peer's). (3) `fixup_cnt` takes the net alloc − pop delta.
  Refill hazards are unchanged: a refill (`wr_cl_inv_i=0`) still re-checks and repairs; the
  index-based drop matches the miss unit's index-based fill-kill.

**Evidence** (all `C:\Users\etcim\AppData\Local\Temp\cva6-artifacts\<tag>`):
- Hub scenario 26 `writer_acquisition` (OOO, NC=3): writer-only sharer, second writer's
  invalidation targets the first writer only, reader-acquisition control; positive/negative
  (`ooocoh-hub-signature-r2` 4/4 with scenario 12); `writer` mutation restores AR-only acquisition
  and fails 26 while 12 stays green (`ooocoh-hub-writer-fault-r1`). Lifetime 46/46, regression
  16/16, publication 21/22 ±, hub synth (no latch/loop), composed hub+L2 4/4, credits 2/2
  (`ooocoh-hub-lifetime-r1`, `-regression-r1`, `-pub21-22-r2`, `-synth-r3`, `ooocoh-composed-r3`,
  `ooocoh-credits-r3`). Standalone scenario 23 remains the documented open counterexample
  (`ooocoh-hub-publication-r1`); it elaborates `COH_BROADCAST`, so this change is not in its cone.
- WT leaf `run_wt_fixup_review.py WT_FIXUP_INV=1`: drop-after-ACK + revive, other-index keep,
  allocation-cycle wins, in-flight suppression + TX progress, same-cycle suppression, refill repair
  control, and the push/retire coincidence (setup-asserted, non-vacuous); 32/32 with negatives at
  depths 0/2/4 (`ooocoh-wt-inv-r4`). Mutations: `drop` fails only `inv_drop`, `retain` only
  `inv_inflight`/`inv_same_cycle`, `count` only `count_keep` (18/18 each, `ooocoh-wt-inv-*-r1`).
  Unchanged suites: copy 16/16, NC 24/24 + fault 12/12, tag formal 6/6 and sim 10/10 (the sim arm
  now writes its `lzc` split control from the tree).
- Isolated int2 route with overlay wbuffer/wt_dcache/hub/clint (`ooocoh-mc-initial-r1`):
  `mc_shared_line_cross_core` **SUCCESS at 1098 cycles**, both cores retired; `boot_release` 775
  SUCCESS / `boot_negative` 775 FAILED(1) unchanged. Observer run (`ooocoh-mc-visibility-r2`):
  retirement hashes equal observer-off/on for both probes; shared-1 shows `inv addr=…8009010` at
  943 to core 0 and core 0's `core ar … 80090100` at 950 — the copy is dropped and the load refills.
  Pre-existing red controls unchanged: `release_probe` (0x7fffffff), `mc_shared_line_sibling_hart`,
  `mc_boot_sanity`, `mc_hart1_alive` (tohost 127, only core 0 retires) — not investigated here.
- Archive gates: int2 lint 24 / synth 7, defaults 8/54 and 32/5, zero errors, identical warning
  texts (`ooocoh-gate-int2-r1`, `ooocoh-gate-default-r1`). Structural FO4 unchanged
  (`ooocoh-fo4-r4`, same single 33.5 inval-bus path as r3).

**Impact and limits.** Two sticky bits per write transaction, per-entry index comparators and a
net-delta counter; one hub alloc mux. No new clock/reset/latch/scan control; no ISA/config/DTS
change. In-order WT configurations see the same rules: their only invalidations are flush (entered
with an empty write buffer and idle MSHR) and AMO/CAS self-invalidation (sequentialised), so
`rtrn_inv` never fires there and dropped fixup copies are re-read from memory that already holds
them — values are unchanged, but the in-order DI/anchor suites have not been re-run through the
isolated route and remain an obligation. Writer acquisition is conservative (more invalidations,
index aliasing unchanged). The signature still has no clear; the fixup queue's tag-miss retention
is now bounded by invalidation, not by time.

### T7j — precise held-secondary verdict; SMT2/OpenSBI re-qualified on the current tree (2026-09-25)

**Verdict precision.** The testharness multi-core verdict assumed every core runs the bootrom
at reset; on multi-core SMT targets `g6lc_cluster` clock-holds secondary cores until an IPI or
200000 cycles, so single-core-scope programs (`mc_boot_sanity`, `mc_hart1_alive`,
`mc_shared_line_sibling_hart` — hart 1 is core 0's sibling) were forced to exit 127 and their
own verdicts were hidden. `ariane_testharness.sv` now probes the cluster's release signal for
each secondary (`gen_hold_probe`, only elaborated under the cluster's own `BOOT_HOLD` condition):
a test ending while every silent core is still held exits **125** with a `[mc_verdict] HELD`
line; a released-but-silent core keeps 127 and 126 stays for a core that stopped; the program's
own exit code is always printed. `run_mc_int2_review.py` classifies `held-secondary` and passes
a subset-scope program only when its program exit is 0, its expected cores retired and none of
them is held (self-test 14 cases). `+mc_verdict_fault` on the cross-core program still yields
127/`incomplete` (`cross_core_fault_control`), so 125 cannot be produced by injected silence.
`release_probe` is declared a probe with no completion path: expected `timeout`, both cores
retired, zero hart-2 faults.

`ooocoh-mc-initial-r2` (int2 rebuilt with the testbench change, all 8 expectations matched):
cross-core shared line pass 1098; sibling-hart/boot-sanity/hart1-alive pass via HELD with
program exit 0 at 741/339/393; fault control `incomplete` 127; boot_release pass 775,
boot_negative fail(1) 775; probe timeout with both cores retired. `ooocoh-mc-visibility-r3`:
observer-off/on retirement hashes equal, causal chain unchanged.

**SMT2/OpenSBI on the current tree (isolated, experimental label).** `run_mc_int2_review.py
REVIEW_MC_BUILD_ONLY=1` builds any target from the seed + overlay at `--threads 1` with the
pinned `split-counter.vlt` control, records original/review source hashes (956 SV files
identical to HEAD) and the C++/bootrom hashes against the local tree (`local_hashes.py`), and
writes the manifest `run_opensbi_source_review.py` accepts for an experimental model. The
frozen `opensbi-source-dual-v3-20260919` strict-dual profile then ran on both current-tree
models:

| Model | Result | Cycles | retired h0 / h1 | Prior green |
|---|---|---:|---:|---|
| `g6lc64_smt2` (`ooocoh-smt2-osbi-r1`) | pass, strictDual | 12,764,538 | 333,591 / 8,932,410 | 12,765,628; 333,635 / 8,932,406 |
| `g6lc64_smt2_ooo_int` (`ooocoh-smt2ooo-osbi-r1`) | pass, strictDual | 10,704,402 | 8,792,688 / 465,559 | 10,696,498; 8,792,612 / 465,543 |

Both are `experimentalModel: true, protectedAnchor: false` — the anchor claim stays with the
proxy-attested mirror build. Cycle/retirement deltas are ≤0.07 %; the anchor's hart-0 trace
first differs from the prior anchor at line 1,504,570 as a hart interleaving shift of the same
instruction block, not a different instruction stream. This re-covers the in-order WT
(`g6lc64_smt2`) path after the T7i fixup-lifetime change with a full OpenSBI boot, though the
DI mini suite itself has not been re-run.

**Two-core OpenSBI profile (prepared).** `corev_apu/bootrom/ariane-ooo-int2.dts` (4 `cpu@`,
cpu-map core0/core1 × thread0/1, 4-hart CLINT/PLIC, L2 node, integer ISA, zawrs unadvertised;
`dts_to_dtb.py` plat_hc 4, binding validator FAIL=0), an N-hart strict payload block
(`G6LC_STRICT_HARTS`), and a shape-parameterized `run_opensbi_source_review.py` (harts/cores/
DTS/config/ISA, per-core progress scopes, all-cores verdict, wall up to 4 h for cores>1; unit
tests added). The first `g6lc64_ooo_int2` firmware run is recorded in T7k.

### T7k — first two-core OpenSBI run: platform enumerates, coldboot lands on core 1 and corrupts (open)

`ooocoh-int2-osbi-r2` (current-tree `g6lc64_ooo_int2` model `ooocoh-int2-build-r1`, fresh
firmware profile: `ariane-ooo-int2.dts`, `-DG6LC_STRICT_HARTS=4`, `rv64imac_zicsr_zifencei`,
OpenSBI 455de672 with the recorded platform patches): **timeout at the 24 M-cycle cap**, no
tohost, `retiredByHart` 0:464,113 1:643,876 2:12,197,822 3:405,231, both cores retired.

What the traces establish (the per-core `trace_rvfi_hart_*.dasm` interleave both SMT harts, so
only memory-anchored facts are used): hart 0 won the fw_base relocation lottery (its `amoadd`
on `_relocate_lottery` returned 0) and zeroed BSS; `fw_platform_init`'s parse of the four-cpu
FDT took longer than the 200000-cycle boot hold, so core 1 woke by timeout, its harts joined
`_wait_for_boot_hart`, and **hart 2 won `coldboot_lottery`** (core 1's `amoswap` returned 0,
core 0's returned 1). Hart 2 ran `init_coldboot` through `wake_coldboot_harts` (store of 1 to
`coldboot_done`), so harts 0, 1 and 3 entered the warm `sbi_hsm_init` hart-wait loop
(`0x8000f20e`, all three parked there at the end). Hart 2 then continued the cold path and took
`LD_ADDR_MISALIGNED @ fdt_find_match+0x22` (`c.ld a2,16(s1)` with a corrupted `s1`), after which
`_trap_handler` re-traps forever: `csrr t0,mstatus` at +0x08 succeeds, the same encoding at
+0x42 (after a `c.sdsp` through a garbage `sp`) raises ILLEGAL_INSTR — 653,461 times. `ipi_dev`
was never set (cold IPI init not reached), so no HSM start could follow and the payload never
executed on any hart.

Reading: the two-core platform contract holds (4 harts enumerated, both cores boot, coherence of
the shared boot flags works — the warm harts observed `coldboot_done`), and the first defect is a
register/CSR-state corruption on core 1 while its sibling spins in hart-wait — a pattern the
single-core SMT2-over-OoO target survives, so the difference is core 1 itself (hart-id base 2,
boot-hold release, hub-side traffic). Secondary observation: the boot hold's timeout fallback is
shorter than a four-cpu FDT walk, so the hold no longer keeps coldboot on core 0; the IPI path is
the robust release, the constant is not. Next step (in flight): a hart-tagged `[smt-flow]`
retire/wb/alloc stream (`scope=%m` added to the sim-only display lines in `scoreboard.sv`) to
find where `s1` acquired its value and why the second CSR read is illegal. No RTL, firmware or
DTS change is made on this evidence alone.

### T7l — root cause: a store ACK's L1 word write is dropped when the array port is busy (repaired)

**Localization.** The hart-tagged stream (`ooocoh-int2-osbi-flow-r1`, `[smt-flow]` with
`scope=%m`) showed the corrupted `s1` was *loaded from the stack*: `c.ldsp s1,24(sp)` at
`fdt_node_offset_by_compatible+0x8a` returned 0x2 although the prologue's `sd s1,24(sp)` had
written 0x80022af0 to 0x80047e58 ~650 instructions earlier, and the neighbouring word
0x80047e50 read back its pre-store value too — the whole L1 line was stale. The mem-watch
probe (`run_mem_watch_probe.py`, `+smt_mem_watch=80047e58`, `ooocoh-int2-memwatch-r1`) then
gave the memory-side sequence on core 1: store `0x2` (line not resident, checked-miss ACK),
refill brings the line in with `raw=0x2`; store `0x80022af0` (line resident, loads forward from
the wbuffer meanwhile); **ACK at cycle 1567417: `wt_word idx=e5 off=8 ways=01 ack=0 denied=0`,
`wt_ack ... checked=1 hit=01 ack_active=1 wr_req=01 wr_ack=0 fix_push=0`** — the word write was
requested, the array granted nothing (a cacheline write — refill or coherence invalidation of
any index — owned the port that cycle), no invalidation and no fixup entry followed, and the
return FIFO popped; the next load hit L1 with `raw=0x2`. The CSR anomaly in the trap handler is
downstream: the handler ran with a stack pointer restored from the same stale frame.

**Mechanism.** `wt_dcache_wbuffer.sv` `p_tx_stat` wrote a checked-hit ACK word into L1
"best-effort" — `wr_req_o` raised, TX freed and return FIFO popped whether or not `wr_ack_i`
was granted (a deliberate departure from upstream, which waits for the grant, made to avoid a
`tx_rdwr_collision` stall). `wt_dcache_mem.sv` `p_bank_req` grants nothing in a
`wr_cl_vld_i & |wr_cl_we_i` cycle (the read-collision case, `wr_denied`, still invalidates the
line and is safe). A lost write leaves a *valid* stale line: the write-through invariant "L1
never holds an older copy of a written word" is broken. Single-core WT sees this only when a
refill lands in the ACK cycle; the two-core cluster adds one array-port cycle per delivered
coherence invalidation, which is why the promoted target exposed it first.

**Repair** (`wt_dcache_wbuffer.sv`): `ack_wr_sel`/`ack_wr_lost` — a selected ACK-time word
write that did not own a granted port this cycle (port busy, or taken by a fixup/VoidKeep write)
keeps its TX slot and return-FIFO entry and is offered again next cycle; the entry stays
checked so the direct path is taken. The hold is bounded by consecutive cacheline-write or
fixup cycles; unchecked/missing words still pop immediately (memory holds them; the fixup
queue retains a copy), and `rtrn_inv` during a held cycle drops the word correctly.

**Evidence.** `WT_FIXUP_INV` scenario 7 (`ack_hold`, `ack_landed`: checked-hit ACK while the
port is withheld for six cycles; the word must remain in the wbuffer and land once the port
frees) passes at depths 0/2/4 with negatives (`ooocoh-wt-ackhold-r1`, 38/38); the `besteffort`
mutation (drop restored) fails exactly scenario 7 at every depth and nothing else
(`ooocoh-wt-ackhold-mut-r1`, 21/21 matched).

**Second defect found by the repaired bench: phantom fixup retires.** With the ACK held instead
of coalesced, copy-suite scenario 3 (`latest_word`) failed: after the fixup queue had drained,
its state machine kept tag-checking and "retiring" the stale array slot at `fixup_head`
(`fixup_rd_req` had no non-empty guard; `fixup_pop` then wrapped `fixup_cnt` below zero), so an
old retained word was rewritten into L1 every few cycles whenever its line was resident — over
the newer word the direct ACK path had just written. The waveform of the *previous* passing run
shows the same endless 0x13/0x12 retire cycle; it passed only because the head had coalesced
the newer word. This is pre-existing (the SL-W queue's introduction), independent of
coherence, and a second stale-L1 mechanism: any later store to a word the queue once held is
overwritten by the phantom unless it happens to coalesce. Repair: `fixup_active_valid`
(bypass valid or count non-zero) gates `fixup_rd_req` and `fixup_pop`, and CHECK/RETIRE fall
back to PEND when the entry is gone. Evidence: copy suite 20/20 with a new `no_phantom_retire`
assertion in every scenario and a new scenario 4 (VOID ACK coalescing into the head in the very
cycle its retire is granted — the race the `retire` control needs now that a checked-hit ACK
can no longer coalesce mid-retire); mutations `phantom` (guard forced true) and `retire`
(coalesce guards removed) fail exactly their scenario; `capacity`/`bytes`/`export` controls
still fail as before. Inv suite 38/38 with `drop`/`retain`/`count`/`besteffort` each failing
only their scenario; NC suite 24/24 (`ooocoh-wt-{inv,nc,copy}-final-*`).

**Integration.** `ooocoh-int2-osbi-r4` (ACK hold only, phantom still present): the stale stack
line no longer occurs and hart 0 becomes the coldboot hart (15.8 M retirements, console lock
traffic), but core 0's hart 1 later traps in the same `_trap_handler+0x42` loop with a garbage
`sp` (the phantom mechanism writing an old stack word is the candidate) and both core-1 harts
stop inside the `coldboot_lottery` `amoswap` (an AMO that never returns — exit 126). The final
models (`ooocoh-int2-build-r4`, `ooocoh-smt2-build-r4`, `ooocoh-smt2ooo-build-r4`) carry both
repairs; `ooocoh-int2-osbi-r5` on the int2 one reproduces r4 exactly (identical retirement
counts), so the remaining hang is independent of the fixup queue — recorded in T7m.

### T7m — third defect: an atomic issued out of order deadlocks the store unit (repaired)

**Localization.** The stuck-handshake instrument added to the visibility model (`+mc_vis_stuck=N`
reports any AXI/invalidation channel, wbuffer hold, denied word write, miss-unit drain or
commit head held for N cycles, once) showed no memory-side stall at all on core 1
(`ooocoh-int2-stuck-r1/r2`); the core-level report (`ooocoh-int2-stuck-r3`, t=1,642,519) is
exact: commit head 0 = `sd a5,-32(s0)` @`atomic_xchg+0x10`, `valid=0` (never executed), head 1 =
the younger `ld a5,-32(s0)` already `valid=1`; the store unit's one-entry AMO buffer is full
(`amo_buffer_ready=0`) with the still-younger `amoswap.d.aqrl` (`amo_addr=0x80042000`,
`coldboot_lottery`), `amo_valid_commit=0`, `no_st_pending=1`, write buffer empty. The issue
queue issues stores out of program order (T6 design: the LSQ hold-to-commit reservation replaced
the program-order store rule), so the AMO — whose operands were ready first — entered the store
unit ahead of the older store; `st_ready = store_buffer_ready & amo_buffer_ready` then refuses
the older store, which can never execute, so the AMO never reaches commit and the buffer never
drains. Both core-1 harts stop in `atomic_xchg`; the same shape can hit any target with the OoO
issue queue, the single-core boots merely never met the timing.

**Repair** (`core/ooo/g6lc_iq.sv`): an AMO (`fu==STORE && is_amo(op)`) issues only at the
commit head, the rule fence-class system ops already follow. At commit the AMO waits for the
drained store buffer anyway, so the head rule adds no wait it would not already pay; plain
stores keep out-of-order issue. Evidence: IQ review scenario 10 `IQ_AMO_HEAD` (AMO withheld
until `commit_ptr` reaches it, plain store unaffected) with its `+oracle_negative` arm in all
four IQ geometries, 114/114 (`ooocoh-iq-amohead-r3`); the gate-removed mutation fails scenario 10
first (`ooocoh-iq-amohead-mut-r1`).

**Structural check caught by the single-core gate.** The active-target synthesis
(`g6lc64_smt2_ooo_int`, `check -assert`) reported 18 combinational loops after the ACK hold:
`wr_ack_i → evict → fixup_push → same-cycle forwarding export → wt_dcache_mem hit → ctrl →
rd_req → rd_ack → wr_ack_o`. The int2 cluster gate had passed the same check, so the loop was
only visible on the `cva6` top. Cut: the fixup candidate decision and the forwarding export are
keyed on `evict_base` (grant-independent), the queue push itself on `evict` — a held ACK then
neither pushes nor starves a retiring head (the first attempt, pushing on `evict_base`, livelocked
copy scenario 3: every retry re-coalesced into the head and suppressed its pop). Gates after the
cut: active lint 24 / synth 1 with `0 problems`, int2 24/7 with `0 problems`
(`ooocoh-loopfix-gate-*`); WT leaf suites unchanged (`ooocoh-wt-*-loopfix-r2`, copy 20/20, inv
38/38, nc 24/24, mutations `besteffort`/`export`/`retire`/`phantom` each caught).

**Firmware after the AMO rule** (`ooocoh-int2-osbi-r6`, IQ rule + pre-cut wbuffer, behaviour
identical to the cut): the coldboot lottery completes, both cores run (hart 2 17.6 M, hart 0
3.1 M retirements) and the payload issues `sbi_hart_start`. The remaining stop is a single
mechanism: the `ecall` enters `_trap_handler` with sane `sp`/`tp`/`mscratch`, `csrr mstatus`
(+0x8), `csrrw mscratch` (+0x38) and `csrr mepc` (+0x3c) succeed, and `csrr t0, mstatus` at
`+0x42` raises ILLEGAL_INSTR (tval `0x300022f3`, priv M). Each re-entry lowers `sp` by 0x148, so
the handler frames walk down through the scratch areas into BSS (`0x800420e8` receives the
handler PC), which is what later made hart 0's `generic_extensions_init` load misaligned — the
garbage-`sp` traces of r2/r4/r5 were this walk, not their cause.

### T7n — fourth defect: the OoO CSR-buffer credit ignored the allocation in flight (repaired)

**Discrimination.** CSR-side probes (`csr_regfile` exception flags, `csr_buffer` allocation /
commit / table view, issue-port view; `ooocoh-int2-csrprobe-r2/r3`) at the failing commit
(t=17,738,401, core 1): the CSR regfile receives **address 0x000** (`read_access_exception`,
priv M, not a decode illegal); the buffer has no entry for the committing tid, and
`csr_commit_i` is not asserted for an excepting op, so the existing "commit without entry"
`$error` could not fire. The issue-side trace shows three CSR acks in consecutive cycles
(`csrrw mscratch` tid 7, `csrr mepc` tid 0, `csrr mstatus` tid 2) with `csr_ready=1` for all
three, then `CSRALLOC tid=2 ... ready=0 tab={tid7 valid, tid0 valid}` — the third allocation
finds both entries taken and is dropped. Cause: `csr_ready_o = free(tab_q) + commit_release
>= 1` is read by the issue decision one cycle before the acked op's `csr_valid_i` reaches the
table, so the op acked in cycle N is still allocating (`csr_valid_i` high, not yet in `tab_q`)
when cycle N+1's decision reads the credit; with one free entry both are acked. A bare M-mode
replay of the prologue (`mc_csr_prologue.S`, 4000 iterations, `ooocoh-csr-prologue-r1`) does not
reproduce the failure. That does not establish that trap context is necessary: the causal
condition is consecutive pipelined admissions exhausting the table while retirement is delayed.
Earlier single-core boot passes do not qualify this credit boundary.

**Repair** (`core/csr_buffer.sv`): `csr_ready_o = free + commit_release >= 1 + csr_valid_i`
(the in-order depth-1 branch already counted `csr_valid_i`; the OoO branch did not), plus a
sim-only `$error` when a presented CSR finds no entry. Evidence: csrbuf review scenario 5
`CSRBUF_PIPE` (A allocating with the table empty leaves one credit; B allocating with A resident
leaves none; both then commit their own address) with its negative arm, and the reverted-credit
mutation failing scenario 5 (`ooocoh-csrbuf-pipe-r1`: 12/12 expected outcomes;
`ooocoh-csrbuf-pipe-mut-r1`: scenarios 0–3 pass, scenario 5 fails `CSRBUF_PIPE`).

**Review and boundary validation.** The required inequality is `free + matched_commit >=
arriving + 1`: reserve the arriving request before promising capacity to next cycle's request.
Cancellation credit is conservatively delayed until registered; flush clears both stored entries
and the current arrival. No table expansion, new state, ISA/DTS change or firmware workaround
is required. The ready cone gains the registered CSR-valid input; full timing closure remains
unmeasured. The existing commit-only assertion cannot detect this loss when the resulting CSR
exception suppresses commit, so the allocation-loss assertion is retained.

`ooocoh-csrbuf-boundary-r1` passes 20/20 expected outcomes with the unchanged repaired RTL
(SHA256 `94fa4776c977717afa7dcc7b369e2d0d229a29fb169ce9044d198856caa90a7f`).
Added scenarios 6–9 cover same-cycle commit/allocation, cancellation/allocation,
flush/full-table arrival, and unmatched commit credit, each with a negative oracle.
The in-order identity test passes unchanged.

**Interrupted qualification, not success.** Retrieved `ooocoh-csrbuf-gate-{int2,active}-r1`
artifacts contain that same CSR source hash. Lint passes at 24 warnings each; synthesis child
rc=143 makes both synthesis verdicts false despite zero reported errors. Defaults complete at
lint 8/54 and synth 32/5. `ooocoh-int2-osbi-r7` on `ooocoh-int2-build-r7` stops at 3,534,013
cycles, before the former failing sequence; the strict runner records `outcome=incomplete`,
`strictDualPassed=false`, and unknown termination. Its tohost-zero banner is not firmware
completion evidence. Full four-hart completion and finished OoO synthesis remain open.

### T7o — source-contract review and resumed four-hart qualification

The coding philosophy (623 lines), SMT2 development logics (688), firmware heuristics (867),
reasoning-pattern workflow (693), and runtime-learning guide (586) were read in full before
further qualification. The legacy comparison is evidence about failed approaches, not a reason
to re-enable A: `core/fetch_A/smt_legacy/frontend.sv` contains CSR-slot exceptions and instruction
fabrication; active `core/Flist.fetch_B` selects B, and `SMT-LEGACY.md`'s 2026-09-18 boundary
forbids retired paths in the active source list. Current PC banking is retirement/redirect owned
under B, unlike A's switch-time snapshot/fallback. The historical guide's A/B blame table is
therefore a hypothesis-ranking aid, not a current routing proof or permission to compile A.

The source obligation behind the CSR failure is independent of firmware: each accepted request
must retain its identity and reserved capacity until completion or cancellation. OpenSBI's
`TRAP_SAVE_AND_SETUP_SP_T0` and `TRAP_SAVE_MEPC_MSTATUS` witness closely spaced CSR operations
around a delayed stack access. The captured instruction and immediate remain correct through
issue; allocation loss at the CSR table, not realignment or privilege decoding, is the observed
first broken promise. The repaired credit and its restored-defect control check that promise
before the firmware gate. A passing bare prologue does not eliminate the missing pipelined-credit
cofactor. No PC, register-value filter, trap suppression or firmware workaround is introduced.

Capacity preflight: 12 CPUs (affinity 0–11), about 114 GiB available RAM and 112 GiB disk free.
Independent archive gates ran alongside the pinned single-thread four-hart model; matched SMT2
models compiled with eight workers, serially relative to one another. Full-model simulations stay
serialized under the overlap guard; compilation parallelism is not simulator threading. The new
SMT2 models are `ooocoh-smt2-build-r6` and `ooocoh-smt2ooo-build-r7`, both rc=0 and qualification-only.

Gate retry r2 exposed a wrapper contract mismatch: `shell --timeout 0` still selects the 60-second
default, despite the help text. Those attempts remain recorded. With explicit `--timeout 5400`,
`ooocoh-csrbuf-gate-int2-r3` completes lint 24 / synth 7 and
`ooocoh-csrbuf-gate-active-r3` completes lint 24 / synth 1, zero errors. These reuse the immutable
captured source archives; the active-core archive retains its documented qualification overrides.
The 75-test proxy/strict-verdict suite passes under WSL; native Windows invocation fails when its
Bash fixtures receive Windows temporary paths, so that invocation is not oracle evidence.
Four-hart DTS validation remains FAIL=0, WARN/GAP=1 for the deprecated CLINT compatible string.
The unchanged repaired model's strict firmware run is `ooocoh-int2-osbi-r8`; its final verdict
and the matched SMT2 firmware results must be recorded before closing qualification.

### T7p — completed secondary-core payload was not routed to testbench termination

`ooocoh-int2-osbi-r8` on the repaired CSR model reports four harts and reaches the natural
OpenSBI console/domain/HSM path. Both physical-core traces contain all four S-mode `strict_seen`
stores, and hart 2 writes success (`1`) to the shared tohost address. Its tracer reports completion
at 17,777,952 cycles, but the outer harness continues to the 24,000,000-cycle cap; the strict
runner correctly retains `outcome=timeout`. The repeated `_trap_handler+0x42` illegal is absent.
Final `mcause`/`mtval` values retain feature-probe history; they are not evidence of a new illegal
at the `mepc` that OpenSBI has since set for supervisor entry.

The owning interface is tracer→testbench completion, not the core. Core 0 alone drives
`tracer_exit`; secondary RVFI tracers were intentionally observer-only when that logic was
introduced. That policy is insufficient for a shared tohost written by an arbitrary elected
boot hart. Source-extracted leaf `ooocoh-exit-before-r1` passes core-0 completion and fails
core-1 completion (`MC_EXIT_ROUTE got=0`). The testbench now collects per-core completion words
and selects a valid done word, with failure preferred over simultaneous success. The existing
held/silent/hung verdict gates still qualify the selected completion. Spike tandem retains its
original primary-core path. Historical observer-only comments describe the prior policy;
this section records the new non-tandem shared-tohost contract.

`ooocoh-exit-after-r1` passes 60/60 expected outcomes at 1/2/4 physical cores, including both
failure-priority directions, ignored code bits without done, no completion, and held/silent/hung
controls. `mc_smt2_boot_release.S` gains an `EXIT_ON_SECONDARY` test variant, leaving its default
behavior unchanged. `ooocoh-int2-build-r8` builds with 24 warnings / zero errors; comparing its
956 source entries against build-r7 changes only `corev_apu/tb/ariane_testharness.sv`. Model hash:
`5e01f24ecf523cbe39ae165bda5992caaa0977069b5e9affaf7b22ff28ec8fe5`.
This is simulation termination routing, with no synthesized-core state, clock, DFT, PMU, ISA,
DTS or firmware change. The old timeout is preserved; qualification requires a fresh strict run
that terminates before the cap, not a relaxed classifier or a retroactive pass label.

The full-model secondary-publisher pair times out at 10,013 cycles before the fix
(`ooocoh-exit-secondary-before-r1`); after the fix, success and intentional failure both terminate
at 814 cycles (`ooocoh-exit-secondary-after-r1`). The primary pair stays at 775 cycles
(`ooocoh-exit-primary-after-r1`). The separately linked secondary ELFs have different file hashes
but identical disassembly; they are source-equivalent controls, not a same-ELF claim. Firmware r9
uses the same frozen ELF as r8 and will compare trace prefixes through termination.

Matched repaired-core firmware: `ooocoh-smt2ooo-osbi-csr-r1` strictly passes at 10,701,925 cycles
(retirements 8,792,864 / 465,559); `ooocoh-smt2-osbi-csr-r1` strictly passes at 12,761,165
(333,591 / 8,932,382). These are the rebuilt single-core models recorded in T7o, before the
multicore testbench routing change; the single-core completion identity is separately covered
by the exit leaf. Both retain experimental/qualification-only provenance, not protected-anchor
replacement status.

### T7q — strict four-hart source-profiled OpenSBI qualification complete

`ooocoh-int2-osbi-r9` on `ooocoh-int2-build-r8` passes the unchanged strict runner:
`outcome=pass`, `strictDualPassed=true` (the field retains its historical name for N harts),
rc=0, tracer termination, before the 24M cap at **17,777,964 harness cycles**. The RVFI tracer
counter reports 17,777,952; these are distinct counters, not different trials. Global hart
retirements are **472,120 / 652,285 / 14,942,663 / 412,622** for harts 0–3. Boot hart 2 reaches
S-mode, starts every peer via HSM, observes every `strict_seen` flag, and writes success tohost.
The runner requires all four supervisor marks, the success store, per-hart progress, both
physical-core traces, normal process status and before-cap termination; none was relaxed.

Firmware SHA256 remains `9b832700dc109bc5d5f8d92b2eb990b26343c535181cfccd666d9200746da014`;
model SHA256 is `5e01f24ecf523cbe39ae165bda5992caaa0977069b5e9affaf7b22ff28ec8fe5`.
The 956-entry model source comparison changes only the testbench versus build-r7. Both physical
core RVFI traces match their r8 prefixes byte-for-byte through final completion: 128,663,792
bytes for core 0 and 1,772,143,971 bytes for core 1. The difference is termination, not an altered
retirement stream. The local run artifact includes `retirement-prefix-review.json`; the raw
remote/local traces and strict `results.json` remain the evidence of record. The strengthened
exit-leaf oracle (`ooocoh-exit-after-r2`) matches 60/60 outcomes with scenario-specific failure
markers.

This closes the requested firmware milestone for `g6lc64_ooo_int2`: 2 cores × 2 harts, integer
OoO, drained SMT handoff, WT + L2 + COH_OOO, fetch B, seed 1, one simulation thread, the validated
private Verilator runtime and pinned split-counter control. It is natural source-profiled
OpenSBI v1.5 with the documented platform/toolchain adaptations and frozen strict payload,
not unrestricted stock-platform/compliance or Linux qualification. The model stays
`experimentalModel=true`, `modelQualificationOnly=true`, `protectedAnchor=false`. No guards,
assertions, firmware paths or production policies were weakened. Matched two-hart results and
completed archive gates are recorded in T7o/T7p; foundry/MBIST/STA/power/area and broader ISA,
RVWMO, mixed-residency and parameter-envelope obligations remain deferred.

## T8 — L3 under COH_OOO: allocation, non-inclusive L3, SRAM tags, geometry, SMT2 boot

Approved scope (2026-09-26): new `g6lc64_ooo_int2_l3` and `g6lc64_smt2_l3` packages with a
cfg-selected non-inclusive L3; the WT boundary emits allocate attributes (also enabled in
`g6lc64_ooo_int2`, re-qualified); the L2/L3 tag arrays move behind `tc_sram`; geometry and
performance are measured under a pipelined DRAM-latency model; strict SMT2 boot is re-run on
every changed or new target while `g6lc64_smt2` and `g6lc64_smt2_ooo_int` stay byte-identical.
Linux boot, STA/power and PDK binding are out of scope. Working plan of record:
`~/.devin/plans/plan-9f0fd4941a162312.md` (mirrored here as the phases land).

### T8a — the enabled L2 was a bypass for every WT target (measured)

`core/axi_shim.sv` tags every AR/AW `CACHE_MODIFIABLE`; `g6lc_l2_pkg::l2_is_cacheable` requires
an allocate bit, so every WT-core request took the `S_BYPASS_*` path. Only HPDCACHE targets
(stream8, server_math, ooo_server, ai) ever allocated. Observer-only `[mc_cache]` counters in
the testbench (final block; l2 hit/bypass read hierarchically under `gen_mc_cache_l2`, l3 from
the cluster outputs) measured it on the frozen four-hart boot: `ooocoh-p0-osbi-d0-r1` (model
`532d0bb5…`) reproduces r9 exactly — 17,777,964 cycles, same `retiredByHart`, both RVFI traces
byte-identical — with **948,230 L2 requests and 0 hits**. Directed boot/release 775 unchanged.

### T8b — WtAxiAllocEn and the int2 re-qualification (commit f73e4db18)

`wt_axi_adapter` routes the shim output through `p_axi_alloc_attr`: cacheable requests get
`BUFFERABLE|MODIFIABLE|RD_ALLOC|WR_ALLOC`, nc/lock/ATOP keep `MODIFIABLE` (AMO/LR/SC arrive
with nc=1 from the miss unit), a 4-bit sideband mux with no new state; `WtAxiAllocEn=0` is
bit-identical. `config_pkg` gains `WtAxiAllocEn`, `L3InclusiveEn`, `L2TagSramEn`,
`L2WriteUpdateEn` (all 0 by default; consumers of the last three land in T8c–T8e) and
`check_cfg` asserts for L3 MSHR/banks/assoc power-of-two, inclusion needing `L3En` and
`L3ByteSize >= L2ByteSize`, and the three enables needing `L2En` (allocation also needs WT).
`check_cfg` evaluates the built configuration, so auto-inferred sizes are not refused.

Evidence: attribute leaf `ooocoh-p1-wt-attr-r1` 36/36 (9 scenarios × ALLOC 0/1 × ±), the
nc-ignoring mutation fails `WT_ATTR_NC`; AMO apply 8/8 with its mutation; composed hub+L2
scenarios 2 (sub-line service: one 64 B fill, three hits, per-beat data) and 3 (post-B
re-read refetches with the new value) in small/target geometry ± negatives, `mod-only`
identity control, self-invalidation fault fails scenario 3, 0 SCCs; `check_cfg` refusals
`ooocoh-p1-cfgrefusal-r3` 10/10; gates int2 lint 24 / synth 7, active 24 / 1, defaults 8/54
and 32/5, `check -assert` 0 problems; FO4 screen unchanged (adapter 18.5). Identity controls
on rebuilt models: `g6lc64_smt2` 12,761,165 cycles with the reference trace matched
18,531,957/18,531,957 lines; `g6lc64_smt2_ooo_int` 10,701,925 with 18,516,857/18,516,857.

`g6lc64_ooo_int2` with allocation: four-hart strict **pass** at **18,675,595** cycles
(`ooocoh-p1-osbi-d0-r1`, model `a8523a16…`), `retiredByHart` 482,404 / 15,160,465 / 428,669 /
428,627 (boot hart moved to 1 — interleaving, not identity), L2 hit 48,649 / miss 64,015 /
bypass 847,353. At zero DRAM latency this is **+5.0 %**: a miss fetches an 8-beat line where
the bypass fetched 2 beats. Directed boot/release 887 (was 775), shared-line 1284 (was 1098),
both with `l2_hit > 0`; observer-off/on equal.

### T8b′ — the "delay 40" instrument was defective; replaced

The first latency runs drove `axi_delayer_intf` `FIXED_DELAY_OUTPUT`. `stream_delay` is a
single-slot, per-handshake delay (every R beat is held and the next beat is only accepted
after the previous leaves) and its counter is 4 bits wide, so 40 became 8: the runs modelled
"8 cycles per beat, serialized", which penalizes 64 B fills 4× more than 16 B bypasses.
`ooocoh-p0-osbi-d40-r1`, `ooocoh-p1-osbi-d40-r1` and the 1387-cycle directed run are
retained and **not** valid latency comparisons.

Replacement (testbench only): `corev_apu/tb/g6lc_tb_dram_latency.sv` between the delayer and
the DRAM backend — every accepted AR earns a deadline `Latency` cycles out and only the first
R beat of its burst is held (valid/ready gated together), later beats stream; B is held
`Latency` after the last W beat; first-beat id order is checked (`DRAM_LAT_ORDER`);
`Latency==0` is pure wires. Leaf `ooocoh-p1b-dramlat-r7` 20/20 at 0/7/40 (exact first-beat
offsets, consecutive beats, backpressure, order fatal). Identity at 0 on the full model:
887/1284 cycles and counters exact.

Corrected latency-40 measurements (`DramLatency=40`, 24M cap; the no-alloc arm is a
measurement control built from a `WtAxiAllocEn=0` package copy, model `b565c0ea…`):

| Configuration | L0 cycles | L40 result |
|---|---:|---|
| int2, no allocation | 17,777,964 pass | timeout at 24M; ≈2.90M instructions retired; 522,957 bypasses each paid the latency |
| int2, allocation | 18,675,595 pass | timeout at 24M; ≈9.94M retired (**3.4× the progress**); L2 hit 54,461 / miss 52,907 |
| directed boot/release | 887 | alloc **1098** vs no-alloc **2071** |

Neither arm finishes the boot inside 24M cycles at latency 40 (extrapolated ≈40M for the
allocating L2, ≈135M without); the cap is a qualification bound, not a measurement bound, so
completed L40 boots are a T8e measurement item with an explicitly larger cap.

### T8c — non-inclusive L3 packages: `g6lc64_ooo_int2_l3`, `g6lc64_smt2_l3`

Cluster: the inclusion policy is `INCL = INCLUSIVE_L3 || CVA6Cfg.L3InclusiveEn` (the
testbench and lint top now pass `INCLUSIVE_L3=0`, so packages own the policy;
`g6lc64_ooo_server` keeps its inclusive behaviour through `L3InclusiveEn=1`). The L2 tag
back-invalidation is qualified by the L3 victim **accept** edge (`l3_evict_v && l3_evict_rdy`)
instead of the held offer, and `l3_evict_rdy` ANDs the inclusive-inv accept with the L2's
`l2_back_inval_ready` — a prerequisite for the multi-cycle tag invalidate of T8d. No default
package changes behaviour (int2 gate stays 24/7; defaults 8/54 and 32/5).

Packages: `g6lc64_ooo_int2_l3` = int2 + `L3En`, 1 MiB / 16-way / 64 B / MSHR 4 / 4 banks,
`L3InclusiveEn=0`, `L2TagSramEn=1` (consumed by T8d); `g6lc64_smt2_l3` = smt2 + the same L3
block + `WtAxiAllocEn=1` (single core, no hub). DTS `ariane-ooo-int2-l3.dts` and
`ariane-smt2-l3.dts` add `l3-cache` (level 3, 1 MiB, 1024 sets) chained from the L2 node;
registered in `dts_to_dtb.py`, the validator list, tiers/REUSE, the branding test and the
build platform (cluster lint top; measured lint baselines **int2_l3 25**, **smt2_l3 5**;
synth 11 and 39 warnings, 0 errors, `check -assert` 0 problems — `ooocoh-p2-gate-*-r1`).

Evidence: composed hub→L2→`axi_cut`→L3 stack (`USE_L3`) scenarios 0–3 ± negatives in small
and 1 MiB/16-way geometry, `l3_miss == dram_ar` per scenario; new scenario 4 evicts a line
from a small L2 and re-reads it — `dram_ar=9, l3_hit=1, l3_miss=9`, the L3 installs and
serves (negative `COH_L3_PROBE`); L3-side self-invalidation fault fails scenario 3
`COH_L2_STALE_VALUE`; 0 SCCs through the stack; credits with the L3 stage: `max_l3_fills=4,
max_ar_live=4`, MSHR 4 and 16 identical service (drain 106) — 16 only burns entries;
CHAIN_L3 HUM 40/40 control; refusals 12/12 with both packages as legal baselines.

Firmware profiles `ooocoh-p2-fw-int2-l3-r1` (fw `a4effb5c…`) and `ooocoh-p2-fw-smt2-l3-r1`
(fw `3c8bf623…`) built from the new DTS/packages. Strict boots at DRAM latency 0:

| Target | Run | Cycles | Retired by hart | L2 hit / miss / bypass | L3 hit / miss |
|---|---|---:|---|---|---|
| `g6lc64_ooo_int2_l3` (model `d3d5db80…`) | `ooocoh-p2-osbi-int2l3-L0-r1` **pass** | 19,341,802 (+3.6 % vs int2-alloc) | 667,710 / 15,303,296 / 439,579 / 439,616 | 25,365 / 50,086 / 861,272 | **0** / 50,080 |
| `g6lc64_smt2_l3` (model `b1024a23…`) | `ooocoh-p2-osbi-smt2l3-L0-r2` **pass** (20M cap; the 14M default cap timed out) | 14,300,834 (+12 % vs smt2) | 512,289 / 9,491,835 | 26,752 / 27,545 / 555,896 | 0 / 27,545 |
| `g6lc64_ooo_int2_l3` at latency 40 | `ooocoh-p2-osbi-int2l3-L40-r1` timeout at 24M | ≈9.82M retired (int2-alloc: ≈9.94M) | | 13,633 / 50,535 / 376,288 | 0 / 50,521 |

Directed int2_l3: boot/release 1022 (alloc-L2 887), shared-line 1454 (1284), `l3_miss` 3/15.

**Finding:** in every system run `l3_hit = 0` and `l3_miss ≈ l2_miss`. The mechanism is
proven at the leaf (scenario 4), so this is workload, not defect: the boot footprint fits the
256 KiB L2, and every write-through self-invalidates the line in L2 *and* L3, so an L2 miss
is either first-touch or post-write — neither can hit a non-inclusive L3. The serialized L3
FSM therefore only adds per-miss latency here (+3.6 % / +12 % at L0, no L40 gain). An L3
benefit needs either a footprint above the L2 (T8e stride/scan kernels) or written lines that
stay resident (`L2WriteUpdateEn`, T8e); both are measurement items, not assumptions.

### T8d — L2/L3 tags behind `tc_sram` (`L2TagSramEn`), flop path retained

`g6lc_l2_tag` gains `TAG_SRAM`: under 0 the flop array is unchanged verbatim (`row_valid_o=1`);
under 1 the valid bits stay in async-reset flops and the tags live in one 1R1W `tc_sram`
(`NUM_SETS` words × `SET_ASSOC×TAG_WIDTH`, `ByteWidth=TAG_WIDTH` so the byte enable is the way
select, `ImplKey "g6lc_l2_tag"`). The parent launches the row read whenever its next state is
`S_TAG` (`tag_launch = state_d==S_TAG`, index `idx_of(addr_d)`), which covers the S_IDLE accept
edge, every held S_TAG cycle and the S_SERVE→S_TAG interrupt return, so the compare still
completes on the first S_TAG cycle; the S_TAG body is gated by `row_valid_o`. An inval-match
read has port priority and commits its clear one cycle later against the row and the set's
valid bits **snapshotted in the read cycle**; a same-index install in the launch cycle is
forwarded into the compared row. `l2_back_inval_ready_o` stays constant 1 and has no
combinational dependence on the valid (the cluster ANDs it into the L3 victim accept).
`g6lc_l3_top`/`g6lc_cluster` pass `CVA6Cfg.L2TagSramEn`. Spec: `g6lc_l2_tag.tech-spec.md`.

**Defect found and fixed before landing (T8d′).** The first SRAM build compared the deferred
inval-match against the *live* valid bits: a fill installing tag T2 into a way whose stale tag
T equalled the matching write's line (same cycle) was spuriously invalidated. The four-hart boot
diverged by −259 cycles (the lost line cost one hart ~40 cycles and handed SMT slots to its
sibling, so the sibling read `time` 8 ticks earlier — a "faster" symptom of a lost line). An
observer `+l2_trace` (per-event L2/L3 log; plusarg allow-listed in `g6lc_tb.cpp`/`ariane_tb.cpp`)
pinned it: `L2 cyc=5078240 install idx=07c way=1 tag=…10001` with `inv idx=07c tag=…10009` in the
same cycle, then `hit` (flop) vs `miss` (SRAM) on `…80009f10` at `cyc=5078258`; no stale hit
anywhere, 0 port steals. Fix: `inv_valid_q <= valid_q[inval_match_index_i]` in the read cycle.
HUM scenario 41 reproduces it (buggy fails `HUM_TAG_STALE_CLEAR`), the tag miter corner catches
the buggy RTL (`L2TAG_MITER_CORNER`). After the fix the four-hart run is **byte-identical** to the
flop path: 19,341,802 cycles, same `retiredByHart` and counters, identical 8,362,654-event L2/L3
trace and RVFI traces (`ooocoh-p3b-osbi-int2l3-ts1-trace-r3` vs `…-ts0-trace-r1`).

Evidence (fixed RTL): leaf sim/units/synth both paths; HUM 78/78 both paths with identical
metrics; CHAIN_L3 40/40; composed stack small/target and fault 2/2 on the SRAM path; credits
L3 MSHR 4/16; SCC 0; size review 32/32 identical functional records, `macroCells` 2→3 (the tag
store). **Flop-vs-SRAM equivalence is a deterministic dual-simulation** (`L2TB_EQ_TAGS`): both
builds emit a per-cycle signature of every DUT output; cycle-exact match at 512 B, 1, 2, 4, 8 KiB
(17,221–49,555 cycles), inverted-hit negative diverges. A Yosys miter does not close because the
two tag stores are unpaired state with different init (flop array resets, SRAM contents are
don't-care) — 503 unproven cells at `-seq 2`, a `-seq 16` SAT instance of ~62M variables; formal
closure needs an init/valid assumption and stays open. Gates: int2 24/7 (flop path, unchanged),
int2_l3 lint **24** / synth **13**, smt2_l3 **4** / **41**, `check -assert` 0; the lint
`WIDTHCONCAT` widths 802,816 and 204,800 (tag reset) disappear on the SRAM path, leaving only the
16,384-bit valid array. FO4 identical both paths (`g6lc_l2_top` 20.5, `g6lc_l2_tag` 9.0, closes
at the 32-FO4 budget). Area (analytic): flop bits removed 200,704 (L2) / 786,432 (L3) per
instance, valid flops kept 4,096 / 16,384, macro 512×392 / 1024×768 b; `g6lc_l2_tag` generic
cells 8,901→6,800 at the reduced synth geometry. Full models: int2 887/1284 exact (identity),
int2_l3 1022/1454 exact, smt2_l3 strict pass **14,300,834 exact**.

**Red lane recorded, not waived.** The legacy `L2TB_MODE=equiv` ladder (current engine vs the
pinned pre-RR reference) fails with 531 unproven cells at the 512 B/4-way fixture — the
reference predates the self-invalidation retention (`wr_inval_pend_q`) and kill-on-invalidation
repairs, so `tag_match_inval`/`wr_self_inval`/MSHR `alloc_id_i`/`merge_block_i` differ by
construction. A whitelist that turned it green was reverted before landing; the lane stays red
until the reference is re-cut from the post-retention flop engine (todo).

### T8e — measurements: where an L3 helps, and what write-through invalidation costs

Observability: `inval_match_hit_o` on `g6lc_l2_tag` (one pulse per inval-match that clears a live
way) surfaces as `l2_selfinv`/`l3_selfinv` in `[mc_cache]`; the SRAM path's valid snapshot now
also folds in the deferred clear in flight for the same set, so back-to-back matches see the
dying bit as 0 like the flop array. HUM 78/78 both paths with an identical metric hash, int2
gate 24/7 unchanged. Three directed kernels (hart 0 runs, others park; negative arms fire):

| Kernel / footprint | Target | L0 cycles | L40 cycles | L2 hit / miss | L3 hit / miss | selfinv |
|---|---|---:|---:|---|---|---|
| stride scan 128 KiB (fits L2) | int2 | 65,844 | 225,594 | 2,010 / 2,049 | — | 0 |
|  | int2_l3 | 92,462 | 252,239 | 2,008 / 2,049 | 0 / 2,049 | 0 |
| **stride scan 512 KiB** (L2 < footprint < L3) | int2 | 308,691 | 1,132,648 | 3,599 / 12,802 | — | 0 |
|  | **int2_l3** | 424,380 | **1,063,540 (−6.1 %)** | 3,597 / 12,802 | **4,609 / 8,193** | 0 |
| stride scan 2 MiB (> L3) | int2 | 1,340,887 | 5,077,098 | 3,599 / 61,953 | — | 0 |
|  | int2_l3 | 1,994,139 | 5,209,131 | 3,600 / 61,952 | 12,288 / 49,664 | 0 |
| write/read 128 KiB × 4 | int2 | 195,760 | 821,733 | 11 / 8,072 | — | 6,060 |
|  | int2_l3 | 292,646 | 926,763 | 19 / 8,072 | — / — | 6,060 (L3 6,060) |

Reading: the L3 pays off only when the footprint exceeds the L2 **and** memory latency exists
(−6.1 % at latency 40 on the 512 KiB scan; at latency 0 its extra lookup stage costs cycles); a
footprint inside the L2 or beyond the L3 gains nothing. The write/read kernel is the write-policy
discriminator: 6,060 resident lines purged by their own stores, ~0 L2 hits on read-back, every
read-back paying DRAM latency (4.2× cycles at latency 40). PMU group-2 cross-check
(`mc_pmu_l3.S`, selectors 0x40/0x41/0x44 confirmed in `perf_counters.sv`): counter deltas over
the scan window are 4,609 / 8,191 / 12,799 against TB totals 4,610 / 8,194 / 12,804 — bounded
by the pre-window setup traffic, negative arm fires.

Geometry sweep (`run_cache_sweep_review.py`, composed stack, SRAM tags, fixed five-phase
workload): L2 {128 K, 256 K, 512 K} × L3 {512 K, 1 M, 2 M} all elaborate (lint 23–24 warnings,
0 errors); larger L3 monotonically raises L3 hits and lowers cycles (256 K/512 K 1,226,372 →
256 K/1 M 1,113,220 → 256 K/2 M 1,099,908), L2 hits scale with L2 capacity (1,792 / 3,584 /
7,168). Analytic bit budgets per point recorded in the run (`results-sweep.json`); e.g. L3 1 MiB =
786,432 tag + 8,388,608 data bits + 16,384 valid flops, L3 2 MiB = 1,540,096 + 16,777,216 +
32,768.

Four-hart boots at DRAM latency 40 to completion (**measurement cap 60M**, not a qualification
bound): int2 (allocating L2) **46,909,150** cycles, L2 hit 110,135 / miss 103,380 / bypass
785,360 / **selfinv 91,594**; int2_l3 **48,403,596**, L2 hit 31,987 / miss 101,435, L3 hit **0** /
miss 101,421, selfinv 89,793. Both strict-pass. The boot never profits from the L3 (footprint
inside the L2), and ~90 k of its ~100 k L2 misses follow a write-through purge — the case for
`L2WriteUpdateEn` (T8f) is this number, not an assumption.

### T8f — `L2WriteUpdateEn`: merge a write-through into a resident line (2026-09-27)

Write-through on a resident line used to purge the line; under `L2WriteUpdateEn` the write
merges in place and the line stays valid while memory still receives the data. `g6lc_l2_top`
gains `parameter bit WRITE_UPDATE` (pass-through on `g6lc_l3_top`, driven from
`CVA6Cfg.L2WriteUpdateEn` in `g6lc_cluster`, default 0). The mechanism: a write's old
self-invalidation did two things — clear the tag and kill same-line in-flight fills; those are
now split (`tag_match_inval` vs `kill_match`). At AW acceptance the tag row for `addr_d` is
launched (`tag_launch` extended into the S_IDLE→S_BYPASS_AW edge) and, for an *eligible* write
(cacheable, no ATOP, no lock, burst stays inside the line), a non-counting tag lookup decides
`wu_hit_q`/`wu_way_q` once; the invalidation stream is suppressed only on that confirmed hit —
a stale row, miss, or ineligible write keeps today's invalidate-and-kill path verbatim.
`kill_match` still fires on update hits so a racing fill is killed and cannot stale-merge.
The merge itself runs in S_BYPASS_W: each forwarded W handshake writes data port A
(`data_a_be` = `w.strb` shifted by the beat offset); port A always lands on a bank conflict —
the fill installer is the side that retries. The FSM only reaches S_IDLE after B, so no reader
can be served merged bytes before memory's acknowledge; the composed bench's
`late_ar >= mem_b` contract keeps holding under WU=1. Observability: `l2_wupdate_o` /
`l3_wupdate_o` pulses, counted hierarchically as `l2_wupd`/`l3_wupd` in `[mc_cache]`. On in
`g6lc64_ooo_int2`, `g6lc64_ooo_int2_l3`, `g6lc64_smt2_l3`; `g6lc64_smt2` and
`g6lc64_smt2_ooo_int` keep 0 (their frozen traces still match bit-exact, T8g).

Evidence: HUM `tb_g6lc_l2_hum` keeps the identical 78/78 metric hash under WU=0 on both tag
paths; WU=1 adds directed cases (a)–(i) — partial-strobe merge with memory read-back,
multi-beat in-line write, non-resident write (no allocation, later read gets memory's new
data), ATOP/locked/non-cacheable writes still invalidate-or-bypass, write racing a same-line
fill kills it (read after B returns new data), the composed scenario-0 admission contract
under WU=1, and stack scenario 4 with a store before the re-read (L3 retains the line and
serves the new data on the L2-capacity miss). Fault controls: disconnecting the data merge
fails case (a) with the stale value; a separate tag fault fails its own case. The Phase-4
`inv_clr` snapshot fold is guarded by `L2TAG_MITER_CORNER2` — the mutation fails without it.
Flop-vs-SRAM dual simulation (`L2TB_EQ_TAGS`) stays byte-exact: WU=1 512 B 17,187/17,187 and
4 KiB 32,102/32,102; WU=0 512 B 17,221/17,221 baseline-identical; the mutation control
diverges. Gates: int2 24/7, int2_l3 24/13, smt2_l3 4/41, defaults 8/54 + 32/5, all zero
errors with `check -assert` clean; SCC through the stack. FO4 `g6lc_l2_top` worst path
**28.5 at both WU=0 and WU=1 (~1403 MHz)** — the merge is a byte-enable shifter and a
port-A write mux in the bypass states only, nothing enters the S_TAG hit compare.

### T8g — Phase 5 qualification on the write-update tree (2026-09-27)

All runs single-threaded except the marked experiment; strict = four/two-hart profile with
tracer termination; model hashes in each run's `build-manifest.json`.

| Lane | Run tag | Cycles | vs reference | Notes |
|---|---|---:|---:|---|
| int2 L0 four-hart strict | `ooocoh-p5-osbi-int2-L0-r1` | **17,993,674** | 18,675,595 (−3.7 %) | `l2_miss` 103,380→1,532, `l2_selfinv` 91,594→189, `l2_wupd`=817,606 |
| int2_l3 L0 four-hart strict (ts1) | `ooocoh-p5-osbi-int2l3-L0-r1` | **18,244,344** | 19,341,802 (−5.7 %) | `l2_wupd`=`l3_wupd`=832,758 (L3 output is the forwarded L2 pulse in this stack) |
| int2_l3 L0 ts0 (flop-tag identity) | `ooocoh-p5-osbi-int2l3ts0-L0-r1` | **18,244,344** | identical | all four trace files **byte-identical** to ts1 (rvfi 31,928,475 + 1,730,930 lines) |
| smt2_l3 two-hart strict | `ooocoh-p5-osbi-smt2l3-L0-r1` | **13,814,448** | 14,300,834 (−3.4 %) | `l2_wupd`=`l3_wupd`=530,843 |
| smt2 strict + frozen trace | `ooocoh-p5-osbi-smt2-L0-r1` | **12,761,165** | exact | 18,531,957 matched lines; WU counters 0 (package keeps 0) |
| smt2_ooo_int strict + frozen trace | `ooocoh-p5-osbi-smt2ooo-L0-r1` | **10,701,925** | exact | 18,516,857 matched lines; WU counters 0 |
| int2 L40 measurement (60M cap) | `ooocoh-p5-osbi-int2-L40-60M-r1` | **41,508,827** | 46,909,150 (−11.5 %) | `l2_hit` 209,318, `l2_wupd`=765,630 |
| int2_l3 L40 measurement (60M cap) | `ooocoh-p5-osbi-int2l3-L40-60M-r1` | **42,004,100** | 48,403,596 (−13.2 %) | **`l3_hit`=1** — the boot workload's first L3 hit; `l2_wupd`=770,656 |

Directed kernels on the rebuilt WU=1 models: `mc_l2_write_read` at L40 — int2
821,733→**526,714**, int2_l3 926,763→**559,492** (−36 % / −40 %), `l2_selfinv` 6,060→**0**,
`l2_wupd`=6,135, `l2_hit` ≈6,040 (was ~15); the 512 KiB scan is cycle-identical to the
pre-WU run (424,380 / 1,063,540 — no resident-line writes, so the path is silent);
shared-line coherence keeps passing with the two former purges now counted as `wupd`=2;
every negative arm still fires.

**Thread-degree experiment (throughput, not qualification).** The same int2 strict profile
on a `--threads 4` model (`ooocoh-p5-osbi-int2-L0-t4-r1`, admitted via
`SOURCE_REVIEW_ALLOW_THREADS=4`) is **not byte-identical**: all traces match until
`trace_rvfi_hart_00.dasm` line 31,194,870 (~97.7 %), where the t4 run retires one
instruction earlier at a timing-sensitive boundary and finishes at 17,991,980 vs
17,993,674 cycles; counters differ by ≤112 events. Wall 1,266.1 s vs 2,459.8 s (1.94×),
build 98.3 s (ccache) vs 361.9 s. Conclusion: `--threads>1` models are measurement-only;
qualification stays on `--threads 1` (the runner enforces it; the opt-in env records
`modelThreads` in provenance).

Linux/compliance/liveness, STA/DFT/power sign-off, CASQ, PMU residuals, coherence/hierarchy/snoop,
FP widths beyond `FLen <= XLEN`, four-wide retirement, adaptive scheduling policy, early-termination
root cause (re-examined only if it recurs with the non-destructive proxy).

### T9a — M1a: CBO end-to-end, eWT config flips, legality and hub credits (2026-09-27)

**Defect.** On WT targets a `cbo.inval/clean/flush` decoded as `STORE` with `rs2=x0` and a
one-byte enable (`decoder.sv:533-535`): the WT write buffer treated it as an ordinary store
and the store buffer waited on a `data_rvalid` the WT cache never asserts
(`store_buffer.sv:468-487` / `wt_dcache_wbuffer.sv`) — one zero byte was written to the
target address and the hart hung. HPDCACHE targets mapped CBOs to CMO ops and responded,
but the CMO never reached L2/L3, so `cbo.inval` could not evict a peer copy below L1.

**Design — CMO sideband.** `cva6`/`ariane` expose `cmo_valid_o`, `cmo_op_o` (0 inval,
1 clean, 2 flush), `cmo_addr_o`, `cmo_ready_i`, `cmo_done_i`; new cfg `L2CmoEn` (default 0,
`check_cfg` requires `L2En`). With `L2CmoEn=0` (e.g. `g6lc64_ooo_int`, `L2En=0`) the core
completes the CBO locally: `inval` goes through the L1 `inval_addr` mux, `clean`/`flush`
wait for write-buffer drain. In the WT subsystem a store-port request with
`cbo_op != CBO_NONE` is not forwarded to the write buffer: it is granted, its address
captured, the CMO issued once the buffer is empty, and exactly one `data_rvalid` is
answered on `cmo_done_i` (the store-buffer `wait_rvalid` path retires the CBO). HPDCACHE
keeps its own CMO handling (L1 invalidate/flush + response) but the adapter emits the
sideband and holds that CMO response until `cmo_done_i`. The new
`corev_apu/coherence/g6lc_cmo_engine.sv` round-robins the NC cores, one CMO in flight:
`inval` broadcasts L1 invalidations to every core through a second
`g6lc_l3_inclusive_inv #(InclusiveEn=1)` merged into `inv_to_core` at lowest priority
(hub > inclusive victim > cmo), match-invalidates the L2 through `l2_back_inval_*`
(arbitrated against the inclusive-victim source — victim wins, cmo holds) and the L3
through new `l3_back_inval_*`; `clean`/`flush` complete once `l2_write_idle_o` and
`l3_write_idle_o` report no unacknowledged write. `cbo.zero` keeps one speculative
store-buffer entry and one commit-queue entry and drains multiple `CBO_ZERO`-tagged write
beats, each with its own grant/`rvalid`, retiring only after the final beat.

**Legality.** `check_cfg` now rejects `NrCores > 1` with `DCacheType` in
`{WB, HPDCACHE_WB, HPDCACHE_WT_WB}` — the WB-L1 multi-core hole; no shipped package
changes legality. New cfg `CohMaxOutstanding` (default 4) drives the hub
`MAX_OUTSTANDING`; legal range 2–14 (4-bit id space, `FILL_ID='1`, one spare), and OoO
signature-filter packages must carry at least two transaction credits.

**Package flips.** `WtAxiAllocEn=1`, `L2WriteUpdateEn=1`, `L2CmoEn=1` in `g6lc64_smt2`
and `g6lc64_smt2_ooo_int` — anchors re-baselined by decision (new frozen traces below);
`L2CmoEn=1` in int2/int2_l3/smt2_l3; `L2WriteUpdateEn=1` + `L2CmoEn=1` in `stream8`,
`server_math`, `server_math_v`, `ai`, `ooo_server`.

**Credits measurement.** `tb_g6lc_coherence_credits` (hub + real L2/L3), all lanes
positive+negative matched (`ooocoh-m1a-credits-*-r3`): the eight-read burst reaches
`max_ar_live`=8 under OT8 vs a capped 4 under OT4 (drain 141 both — the burst is
latency-bound at L0, but the extra service is used); the mixed read+write bursts pay
`wr_stall_cycles`=12 at OT4 (drain 183) vs 0 at OT8 (drain 165) — four-hart shape
identical; the L3 stack drains 194→186 with `max_fills`/`max_l3_fills` 4→8.
`CohMaxOutstanding=8` therefore chosen for `g6lc64_ooo_int2`/`g6lc64_ooo_int2_l3` with
`L2MshrDepth=8` (`L3MshrDepth=8` on int2_l3); signature-filter proofs re-run at OT8.

**Evidence.** Leaf oracles: `tb_g6lc_cmo_engine` (arbiter fairness, broadcast with
per-core-ready backpressure, L2/L3 back-inval handshake including collision with the
inclusive-victim source, clean waits for write-idle; negatives: dropped core, dropped
level, early done), the WT subsystem leaf (the CBO never reaches the wbuffer — the
forwarding mutation lets the byte write be observed — and exactly one `rvalid`), and the
HPDCACHE adapter response-hold leaf. Composed `tb_g6lc_coherence_hub` CMO scenario: a
resident line is invalidated at every level and the next read misses at L2 and L3
(counters); the negative arm fails. Directed `mc_cbo_ewt.S` (harness `+mem_poke` writes
DRAM behind the caches at a fixed cycle): positive pass and negative-arm matched failure
on int2, int2_l3, smt2, smt2_l3, smt2_ooo_int, stream8 and server_math (r6 lanes,
~120k cycles each, `PEER_HART=1` on the two-hart packages).

**Regression: the parked ATOP R.** The same-line ordering fix that closed
`HUB_STALE_REFILL_PUBLICATION` (invalidation held while a same-line fill is outstanding)
deadlocked against a pre-existing behaviour: an ATOP R was *withheld* from the shared
memory R channel until `slot_applied()`, while the invalidation it waited on could not be
delivered until the same-line fill's R landed — a beat queued *behind* the withheld ATOP
R on that channel. Seen as `mini_amocas_w` failures (stream8, server_math, and a WT int2
reproduction ending in a held core) and int2/int2_l3 strict-boot hangs. The fix parks the
beat exactly like the B path already does: the hub consumes the ATOP R into the owning
AW slot (`r_held` + captured payload), keeps `r_ready` asserted so the fill's R passes,
and replays the parked beat — with priority over a fresh R to the same core — once
`slot_applied()`; the slot frees only after the replayed R handshakes and B is done.
Leaf oracle: hub scenario 27 `atop_parked_r` builds the shape (target-core same-line
fill outstanding, early ATOP R) — pass at OT4 and OT16 (`k=0`), negative arm
`HUB_ATOP_R_WITHHELD` matched, lifetime lane `ooocoh-m1a-hub-lifetime-park-r1` 50/50
matched. Directed confirmation on the rebuilt p8 models: `mini_amocas_w/d/q` and
`mini_stream_plane` pass on stream8/server_math; all seven `mc_cbo_ewt` lanes matched
both arms; the int2/int2_l3 strict boots below now complete (they hung pre-fix).

**Strict boots (threads=1, p8 fixed-hub models, `SOURCE_REVIEW_ALLOW_CONCURRENT`).**
smt2 and smt2_ooo_int now carry the eWT flips, so their previous frozen traces
(12,761,165 / 10,701,925 on the alloc/WU-off packages) are retired; the runs below are
the new anchor references from now on.

| Lane | Run tag | Cycles | Notes |
|---|---|---:|---|
| int2 L0 four-hart strict | `osbi-int2-r6` | 17,928,441 | vs 17,993,674 M0 (−0.4 %, OT=8 + CMO on); `l2_wupd`=820,345, `l2_miss`=1,522 — hung pre-fix |
| int2_l3 L0 four-hart strict | `osbi-int2l3-r6` | 18,244,150 | vs 18,244,344 M0 (−194); `l2_wupd`=`l3_wupd`=832,773 — hung pre-fix |
| smt2_l3 L0 two-hart strict | `osbi-smt2l3-r6` | 13,814,448 | byte-stable vs T8g (WU already on); `l2_wupd`=`l3_wupd`=530,843 |
| smt2 L0 two-hart strict — NEW anchor | `osbi-smt2-r6` | 12,867,172 | `l2_wupd`=502,702, `l2_selfinv`=164; rvfi hart_00 sha256 `0611f9fa160593b0` (18,538,109 lines) |
| smt2_ooo_int L0 strict — NEW anchor | `osbi-smt2ooo-r6` | 10,809,010 | `l2_wupd`=497,296; rvfi hart_00 sha256 `560b14fd1e909350` (18,560,141 lines) |

### T9b — M1b: posted writes and bypass-read tracking in the L2/L3 engine (2026-09-28)

**Design.** New cfg `L2PostedWriteEn` (default 0; `check_cfg`: `L2PostedWriteEn → L2En`),
`L2WriteTrackDepth` (default 4, pow2 2..8) and `L2ReadTrackDepth` (default 4); `g6lc_l2_top`
parameters `POSTED_WRITES`/`WTRK_DEPTH`/`RDTRK_DEPTH` pass through `g6lc_l3_top` and the
cluster. `corev_apu/l2_cache/g6lc_l2_wtrk.sv` (tier R) holds `{valid, id, line_addr,
blocking}` in AW-issue order; **every** accepted write takes an entry so B routing is
uniform. A postable write (`atop=='0 && !lock && id != FILL_ID`) returns to `S_IDLE`
after the last forwarded W beat — memory's B is routed to the oldest tracker entry of
its id and popped on the slave's `b_ready`; ATOP/lock/FILL_ID-alias writes keep the
blocking `S_BYPASS_B` path on their entry. NC/lock bypass reads post through a read
tracker and an atomic slave-R arbiter (an in-progress burst holds the channel to `last`;
round-robin among ready sources). Ordering rules per `ewt-caching.md`: R1 read miss to a
tracked line holds until the entry's B; R2 a different-id same-line AW is held; R3 a
write into an in-flight fill still invalidates and kills; R4 uniform per-id oldest-entry
B routing; R5 a same-id hit response or fill serve waits for the tracked read to pop;
R6 `CohMaxOutstanding` bounds fills + write-tracker + read-tracker entries.
`l2_write_idle_o`/`l3_write_idle_o` now mean "tracker empty and no write state" — the
CMO `clean`/`flush` wait consumes it. Under `L2PostedWriteEn=0` the netlist folds to the
M1a datapath (identity verified by metric hash below).

**HUM identity + directed.** POSTED=0 metric hash is byte-identical to the M1a hash on
**every** WU × TAG_SRAM combination (`ooocoh-m1b-hum-p0-*-r1`): WU0 = `e0c8313b…ecdc0`,
WU1 = `c485eca3…a1b9c` — each identical for flop and `tc_sram` tags. POSTED=1 runs all
matched: WU0 92/92 records both tag paths (hash `a5ba46bc…a41a4b`), WU1 108/108 both tag
paths (hash `de33d621…3c561`). Scenarios 49–59 are the posted directed contract —
(a) same-line read miss holds until B; (a2/sc50, WU+posted only) resident-line hit
serves merged bytes; (b) different-id same-line AW holds under `+mem_reorder_ids`;
(c) same-id back-to-back writes proceed, B order preserved; (d) full tracker
backpressures AW (`l2_wtrk_full` counted, no loss); (e) per-id B routing with
interleaved ids; (f) NC reads interleaved with hits/fills — slave-R bursts stay atomic;
(g) same-id hit holds behind a tracked read; (h) ATOP/lock writes take the blocking path;
(i) postable write racing a same-line fill kills it; (j) `l2_write_idle` waits for the
tracker to drain (the CMO clean wait). Mutation arms all fired on defective builds:
`pw_r1` drops the R1 hold → `HUM_R1_FILL_LAUNCHED` (sc49); `pw_r2` drops the R2
admission → `HUM_R2_AW_ACCEPTED` (sc51, memory ends with the older value);
`pw_r5` drops the R5 hold → `HUM_DATA` per-id order violation (sc56)
(`ooocoh-m1b-hum-fault-pw-{r1,r2,r5}-r1`).

**Bounded formal** (`verif/tb/l2/formal/`, SymbiYosys/yices — z3 was dropped after it
OOM-crashed WSL; yices proves the same models in seconds). Free-init-state
counterexamples are excluded by an `f_past_valid` reset-entry pattern.

| Task | Result | Property |
|---|---|---|
| `g6lc_l2_wtrk prove` (d20) | PASS | P1 no two valid entries share a line with different ids; P2 B conservation safety |
| `g6lc_l2_wtrk live` (d60) | PASS | P2 liveness: every posted entry gets its B within the age bound |
| `g6lc_l2_wtrk cover` | PASS | posted-entry lifecycle reachable |
| `g6lc_l2_wtrk mut_p1` | intended FAIL (step 4) | R2 admission assumption is load-bearing |
| `g6lc_l2_top prove` (d48) | PASS | P3 FSM never in `S_BYPASS_B` for a posted write |
| `g6lc_l2_top mut_p3` | intended FAIL (step 5) | posted-guard drop detected |

**Composed + credits.** `tb_g6lc_coherence_hub` POSTED=1 (L2 and L2+L3 stacks):
`ooocoh-m1b-composed-{small,modonly,stacksmall,stackfault}-wu1-r1` — 12+4+12+2 records
matched including CMO sc6/sc7; parked-ATOP-R sc27 is a hub-leaf scenario (no L2 instance, no POSTED knob) and was re-run on this tree at OT4/OT16 — `ooocoh-m1b-hub-lifetime-r1` 50/50 matched, `HUB_ATOP_R_WITHHELD` arm fires; the `late_ar >= mem_b` contract
holds (posted B is still memory's B); SCC 0 through hub+L2 and hub+L2+L3
(`ooocoh-m1b-composed-scc{,-l3}-wu1-r1`). Credits (`ooocoh-m1b-credits-*-r{1,2}`):
`fills + wtrk + rdtrk ≤ credits` held on every lane — eight-read burst `max_ar_live`
4@OT4 / 8@OT8 (drain 141); mixed bursts `wr_stall_cycles` 22→0 at OT8 (drain
154→147), `max_aw_live` 1→2 when the L3 stack is present (drain 270, `max_fills` 5,
`max_l3_fills` 4); every negative arm failed with `COH_CREDIT_DATA`. OT8 stays
`CohMaxOutstanding=8` on int2/int2_l3 — the trackers at depth 4+4 are covered.

**Gates + timing.** `L2PostedWriteEn=1` in every L2 package (all `g6lc64_*` L2
configurations; cv32/cv64 upstream packages keep the field at default 0 — they are not
eWT targets). Lint/synth `check -assert` all green, 0 errors (see table below); SCC
through the composed stack clean (above). FO4 `g6lc_l2_top`: worst path
`reg0/CP → reg1/D` **28.5 FO4** — identical to the pre-M1b screen (the 4-entry CAMs sit
on registered request fields; the R arbiter adds one mux level on the slave R data
path; nothing enters the S_TAG hit compare), ~1403 MHz vs the 1250 MHz budget. Hub
unchanged — its 32.0 FO4 screen stands.

| Target | Gate tag | lint w/e | synth w/e |
|---|---|---|---|
| g6lc64_ooo_int2 | `ooocoh-m1b-gate-ooo_int2-r1` | 24/0 | 11/0 |
| g6lc64_ooo_int2_l3 | `ooocoh-m1b-gate-ooo_int2_l3-r1` | 24/0 | 17/0 |
| g6lc64_smt2 | `ooocoh-m1b-gate-smt2-r1` | 4/0 | 31/0 |
| g6lc64_smt2_l3 | `ooocoh-m1b-gate-smt2_l3-r1` | 4/0 | 41/0 |
| g6lc64_smt2_ooo_int | `ooocoh-m1b-gate-smt2_ooo_int-r1` | 24/0 | 1/0 |
| g6lc64_stream8 | `ooocoh-m1b-gate-stream8-r1` | 7/0 | 36/0 |
| g6lc64_server_math | `ooocoh-m1b-gate-server_math-r1` | 7/0 | 36/0 |
| g6lc64_server_math_v | `ooocoh-m1b-gate-server_math_v-r1` | 3/0 | 36/0 |
| g6lc64_ai | `ooocoh-m1b-gate-ai-r1` | 7/0 | 36/0 |
| g6lc64_ooo_server | `ooocoh-m1b-gate-ooo_server-r2` | 7/0 | pending — r1 synth hit the 5400 s stage cap mid-opt (infrastructure timeout, not an error) |
| defaults (cv64) | `ooocoh-m1b-gate-defaults-r1` | 8/0 + 54/0 | 32/0 + 5/0 |

**Directed** (`run_queue` m1b-queue-r1, POSTED=1 models, every arm matched): the L40
write/read kernel drops below its M0 numbers as predicted — `mc_l2_write_read`
int2 L0/L40 = 135,526 / **518,507** (M0: 135,528 / 526,714); int2_l3 = 160,122 / **543,093** (M0: 160,120 / 559,492); `scan512k` int2_l3 424,374 / 1,046,973 (vs Phase-4 424,380 / 1,063,540); `mc_cbo_ewt` pos+neg matched on all four
int2/int2_l3 L0/L40 lanes plus stream8/server_math; boot/release and shared-line
matched on all four lanes; the posted counters (`l2_posted`, `l2_rdtrk`) appear in
`[mc_cache]` lines; all negative arms fired. HPDCACHE directed suites:
`mini_amocas_w/d/q` and `mini_stream_plane` pass on stream8 and server_math.

**Strict boots (threads=1, concurrent, ≤11 remote threads).** int2/int2_l3 four-hart and smt2_l3 two-hart runs all strict; the two anchor lanes re-freeze below.

| Lane | Run tag | Cycles | Notes |
|---|---|---:|---|
| int2 L0 strict | `osbi-int2-r1` | 17,903,402 | vs M1a 17,928,441 (−0.1 %); `l2_posted`=841,717, `l2_line_hold`=372,982 |
| int2 L40 60M | `osbi-int2-L40-60M-r1` | 40,712,259 | vs M1a 41,508,827 (−1.9 %); `l2_posted`=778,465, `l2_line_hold`=13.6 M |
| int2_l3 L0 strict | `osbi-int2l3-r1` | 18,905,079 | vs M1a 18,244,150 (+3.6 % — L3-latency line holds); `l2_posted`=855,600, `l2_line_hold`=744,907 |
| int2_l3 L40 60M | `osbi-int2l3-L40-60M-r1` | 41,946,955 | vs M1a 42,004,100 (−0.1 %); `l2_posted`=793,008, `l2_line_hold`=14.4 M |
| smt2_l3 L0 | `osbi-smt2l3-r1` | 13,691,686 | vs M1a 13,814,448 (−0.9 %); `l2_posted`=552,843 |
| smt2 L0 — FINAL anchor | `osbi-smt2-r1` | 12,406,273 (−3.6 % vs M1a) | rvfi hart_00 sha256 `e0858842b829e5e2` (18,522,309 lines) |
| smt2_ooo_int L0 — FINAL anchor | `osbi-smt2ooo-r1` | 10,702,679 | rvfi hart_00 sha256 `7e228d3acf599373` (18,557,085 lines) |

The smt2/smt2_ooo_int runs above are the **final re-frozen anchors for the eWT tree**
(PostedWriteEn now on; all earlier anchors retired).

**Reading (lead).** Posting converted the FSM's blocking wait into R1/R2 holds without
removing the wait for the boot's dominant pattern: at latency 40 the four-hart boots spend
13.6 M (int2) and 14.4 M (int2_l3) of ~41 M cycles in `l2_line_hold`, i.e. a same-line
access follows a write before that write's B roughly a third of the time, and on int2_l3
at latency 0 the longer B path through the L3 makes the holds cost more than posting
saves (+3.6 %). The gain therefore lands on the non-same-line traffic only (−1.9 % int2
L40, −3.6 % smt2). Two follow-ups, to be decided on data: (1) split the hold counter into
R1 (read miss behind a tracked write — the store→load-to-a-new-line pattern) and R2
(different-id same-line write — every hub slot is a new id, so two consecutive writes
from one core to one line collide); (2) if R1 dominates, `L2WriteAllocEn` (write miss
allocates a fill and merges the pending bytes at install, so the following read merges
into the MSHR instead of holding) removes the hold at the cost of a per-MSHR 64 B +
mask buffer; if R2 dominates, either the hub keeps a per-core same-line write on one
id or R2 is relaxed behind a documented downstream same-address write-order guarantee.
Neither is assumed; both are measured first (M1c).

### T9c — M1c: posted-write hold split — measurement only (2026-09-28)

**Instrumentation (no policy change).** `g6lc_l2_top`: `l2_hold_r1_o` = the R1
level (`S_TAG` cacheable read miss whose line has a live write-tracker entry),
`l2_hold_r1_wu_o` = the R1 subset whose tracked entry was a write-update hit
(resident line), `l2_hold_r2_o` = the R2 level (`S_IDLE`, AW offered, tracker
not full, same-line entry with a different id); `l2_wtrk_line_hold_o` remains
the aggregate (R1 | R2 | ATOP-load guard, which has no split field).
`g6lc_coherence_hub`: `hub_aw_sc_collide_o` = a level asserted while a core
offers an AW whose line a live AW slot of the **same core** already holds —
the hub-side view of the same-core R2 share (the L2 cannot see slot→core).
`[mc_cache]` gains `l2_hold_r1 l2_hold_r1_wu l2_hold_r2 hub_aw_sc_collide`
appended at the end of the line; both parsers
(`run_mc_int2_review.py`, `run_opensbi_source_review.py`) accept them as an
optional trailing group so older lines still parse (`None` fields).
New isolator `verif/tests/custom/multicore/mc_store_load_new_line.S`:
hart 0 stores then loads 4,096 fresh lines (fence between — without it the
store buffer forwards the load and no L2 read is ever issued); tohost
1/3/5, peers park. All counter fields are levels summed by the TB into
cycle counts.

**Directed lanes** (all records pos+neg matched; single-hart → no cross-id
traffic, so every hold counter is 0 — the boots below are the authoritative
source): `mc_l2_write_read` int2 135,526 / L40 518,507, int2_l3 160,122 /
543,093; `mc_l3_stride_scan` 512 KiB int2_l3 424,374 / 1,046,973;
`mc_store_load_new_line` int2 147,827 / 467,295, int2_l3 205,169 / 545,090 —
4,096 posted writes + 4,095 load misses each, `l2_hold_r1` = **0** on all
four: the core's own store→dependent-load ordering waits for the posted
write's B before the load's miss reaches the L2, so the single-hart isolator
cannot create the overlap the R1 arm guards.

**Strict-boot split** (threads=1, four-hart source-profile OpenSBI; models
`ooocoh-m1c-*-build-*-r2`, modelSha256 int2-L0 `7d26a562…`, int2-L40
`a6cea01e…`, int2l3-L0 `5f6ebd46…`, int2l3-L40 `9de35340…`):

| Config | Lat | Tag | Cycles | `l2_line_hold` | `l2_hold_r1` | `l2_hold_r1_wu` | `l2_hold_r2` | `hub_aw_sc_collide` |
|---|---:|---|---:|---:|---:|---:|---:|---:|
| int2 | 0 | `ooocoh-m1c-osbi-int2-L0-r2` | 17,903,402 | 372,982 | 1 | 0 | 372,981 | 429,790 |
| int2 | 40 | `ooocoh-m1c-osbi-int2-L40-60M-r2` | 40,712,259 | 13,647,144 | 127 | 0 | 13,647,017 | 7,599,674 |
| int2_l3 | 0 | `ooocoh-m1c-osbi-int2l3-L0-r2` | 18,519,467 † | 730,556 | 4 | 0 | 730,552 | 624,532 |
| int2_l3 | 40 | `ooocoh-m1c-osbi-int2l3-L40-60M-r1` | 41,946,955 | 14,385,949 | 155 | 0 | 14,385,794 | 7,993,992 |

† deviation: this rerun was launched against the **int2** profile
(`ooocoh-int2-osbi-r2`) rather than the int2-l3 one
(`ooocoh-p2-fw-int2-l3-r1`) — still a strict four-hart OpenSBI boot on the
int2_l3 model, so the counters are valid measurement data, but its cycle
count is not comparable with the M1b int2_l3-L0 boot (18,905,079). The L40
int2_l3 lane used the correct l3 profile and reproduces the M1b cycle count
exactly, as does int2 at both latencies — counters are observation-only.

**Readings.**
- **R2 is ~100 % of the hold bill** at every point: R1 totals 1–155 cycles
  (≤ 0.001 % of holds); every R1 event is a **write-around**
  (`l2_hold_r1_wu` = 0 everywhere), i.e. the "store to a resident line then
  read-miss it" shape never occurs — consistent with the isolator: the
  core-side store→load ordering already serializes that shape before the
  L2 can hold it, so R1 exists only for cross-agent races the boot almost
  never hits.
- **R2 same-core share**: `hub_aw_sc_collide`/`l2_hold_r2` = 55.6 %–55.7 %
  on the L40 boots (the regime where holds cost ~34 % of the boot),
  85.5 % int2_l3-L0, and >100 % int2-L0 (the hub-visible collision window
  is wider than the cycles the L2 charges — an AW can be counted while
  still in transit or while a *blocking* entry holds the line — so the
  same-core figure is best read as a ≥55 % floor at L40, not an exact
  ratio). The mechanism: each hub AW slot is a fresh outstanding id, so a
  core's *own* consecutive writes to one line serialize at the L2 for a
  full B round-trip each (~80 cycles at L40).
- `l2_wtrk_full` = 0 on every boot — tracker depth 4 never bound; the
  stalls are ordering, not capacity.

**Recommendation (measurement only — decision is the lead's).**
- Option 1 (`L2WriteAllocEn` + per-MSHR pending-write merge) targets R1 —
  measured at ≤0.001 % of holds. **Not justified by the data**; the 64 B +
  mask buffer buys nothing on these workloads.
- Option 2 (keep a core's same-line writes on one hub id) removes the
  measured dominant share — ≥55 % of R2 cycles at L40 — with a contained
  hub change (id allocation keyed by (core, line) instead of per-slot).
  **Recommended first lever.** Extending the reuse to a shared id for
  same-line writes from *different* cores would cover most of the
  remainder but complicates B attribution back to the right core's slot —
  worth evaluating only if the same-core fix leaves a meaningful residual.
- Option 3 (relax R2 behind a downstream same-address-order guarantee)
  would remove all R2 but requires proving the memory path preserves
  write-write order to one address across different AXI ids — not a
  property AXI generally provides. **Do not adopt** without that proof;
  a silent write-order inversion is the failure mode.

**Infra deviations.** `ooocoh-m1c-osbi-int2-L40-60M-r1` (pre-fix
`ooocoh-m1c-int2-build-L40-r1`, `napot_canonical_chk` absent) died on the
`pmp_entry.sv` NAPOT translate_off assert at cycle 40,542,906 — the same
delta-cycle hazard recorded in T9d; rerun on the fixed build is the r2 row
above. `osbi-int2-L0-r1` hit a `profile changed during execution`
identityError while the profile was being rebuilt; r2 is clean. The r1
int2l3-L40 build likewise predates the assert fix but the assert never
tripped there — observation-only counters, result stands.

### T9d — M2: mixed-residency promotion on `g6lc64_smt2_ooo_int` (2026-09-28)

**Change.** `core/include/g6lc64_smt2_ooo_int_config_pkg.sv`:
`SmtDrainedHandoff: bit'(0)` (comment cites the T6b evidence and this
milestone). `core/include/config_pkg.sv` replaces the
`ifndef G6LC_OOO_SMT_MIXED_QUALIFY`-gated "mixed residency is
qualification-only" block with the define-free
`assert (Cfg.SmtDrainedHandoff || Cfg.NrCores == 1)`; the define now gates
only multi-core (`NrCores > 1`) mixed residency. `cva6.sv` and
`core/ooo/g6lc_ooo_dispatch.sv` comments that called mixed residency
qualification-only are aligned. `int2` / `int2_l3` stay drained
(`SmtDrainedHandoff=1`). What stays gated: multi-core mixed residency and
FP+mixed (the `OoOEn && FpPresent` legs are unchanged).

**Assertion-side fix carried.** `core/pmp/src/pmp_entry.sv` — the NAPOT
`assert (size > 2)` legality check sampled `trail_ones`, whose driving `lzc`
instance evaluates a delta cycle after the per-hart PMP bank mux moves
`conf_addr_i`/`conf_addr_mode_i`; under mixed residency (and, in fact, on
in-order four-hart boots — see T9c) the check could see a stale non-canonical
value and `$stop`. The check now recomputes the trailing-one count locally
inside the `// synthesis translate_off` block (named block, automatic
variables); the functional NAPOT match path is untouched, zero netlist
impact. First seen on the M2 mixed probe at cycle 609; same signature killed
the pre-fix M1c int2/int2_l3 L0 boots at ~17.9 M / ~18.9 M cycles in the PTW
PMP instance.

**Probe matrix** (`run_smt_mixed_probe.py`, threads=1, post-fix r2 models;
`smt_mixed_probe*.elf` sha256 `5bc9059e…e148e9cb` / `a0e8c8fd…` /
`10666c82…`):

| Lane | Tag | Result | Cycles | Notes |
|---|---|---|---:|---|
| mixed | `ooocoh-m2-probe-mixed-r2` | SUCCESS | 3,103,699 | RES0=RES1=0x1; `h0_pp`=0, `h0_tlb`=0, `h0_tmr`=144; `both_resident_cycles`=410,929, `cross_hart_port1_commits`=21,977, `hol_residual`=25,993; retired h0=891,486 / h1=1,000,739 (matches the T6b-4b pass counts exactly) |
| solo | `ooocoh-m2-probe-solo-r2` | SUCCESS | 388,025 | RES1=0x1; `both_resident`=0 (control) |
| drained overlay | `ooocoh-m2-probe-drained-r2` | SUCCESS | 3,018,235 | RES0=RES1=0x1; `h0_pp`=0, `h0_tlb`=0; `both_resident`=0 (draining witnessed) |
| anchor `g6lc64_smt2` | `ooocoh-m2-probe-anchor-r2` | SUCCESS | 3,221,052 | RES0=RES1=0x1; `h0_pp`=0, `h0_tlb`=0 |

**Isolation mutations / negatives.**

| Lane | Tag | Expected | Observed |
|---|---|---|---|
| `mut-stb-no-hart` | `ooocoh-m2-probe-mut-stb-no-hart-r2` | fail | **fail** @3,105,561 — `RES0=0x5` (`RES_FAIL_PP`), `h0_pp`=213 cross-hart speculative forwards witnessed (the shared-page ping-pong witness fires; T6b-3 saw 205 on the pre-eWT tree) |
| `mut-ctrl-switch-degrades` | `ooocoh-m2-probe-mut-ctrl-switch-degrades-r2` | fail | **fail** @193,987 — `t6b3_switch_keeps_commit_flush` assertion ("switch degraded a commit-level flush under mixed residency") |
| `mut-lsq-no-hart` | `ooocoh-m2-lsq-leaf-r4` | leaf fail | re-run (not hash-gated — `g6lc_lsq.sv` changed in `781a25215`/`5a19fb1bb`): `LSQ_HART_PASS`, inverted negative `LSQ_XHART_STALL stall=0` and mutant `stall=1` both fire; synth 2,691 cells / 0 latches / 0 SCC |
| `mut-decode-active-irq` (idstage leaf) | hash-gated | — | file set unchanged since `81111b653` (T6b-3 exit): `core/id_stage.sv`, decoder family (`fedf3f2b7`/`8a2df2987`/`5b694633a`/`2ef1c1b1f`, all pre-T6b-3), `tb_g6lc_idstage.sv`, `run_idstage_leaf.py`; only `config_pkg.sv` metadata moved (87dd183d6) |
| `mut-no-peer-restart` (restart leaf) | hash-gated | — | file set unchanged since `e3ec6e00a`/`5a826bfe4` (T6b-3/T6b-2a): `core/fetch_B/g6lc_fetch_pkg.sv` `5f623771…`, `core/smt/g6lc_smt_pc_bank.sv` `ae2c9f0c…`, `tb_g6lc_restart.sv` `94643d78…`, `run_restart_bank.py` `43d3e503…` |

**Strict boots** (threads=1, source-profile OpenSBI, post-fix r2 models):

| Lane | Tag | Result | Cycles |
|---|---|---|---:|
| mixed | `ooocoh-m2-osbi-smt2ooo-mixed-r2` | strictDual pass | **10,556,456** (vs drained 10,702,679, −1.4 %; vs T6b-4b mixed 10,606,940, −0.5 %) |
| drained overlay | `ooocoh-m2-osbi-smt2ooo-drained-r2` | strictDual pass | **10,702,679 — exact match to the final anchor**; rvfi hart_00 sha256 `7e228d3acf5993735838…`, 18,557,085 lines (identical hash and line count) |

`+smt_mixed_stats` on the mixed boot (lane `ooocoh-m2-osbi-smt2ooo-mixed-r3`,
identical 10,556,456-cycle run): `both_resident_cycles`=60,914,
`cross_hart_port1_commits`=4,851, `hol_residual`=1,488, retired
h0=8,810,200 / h1=462,035 — the harts are resident together ~0.6 % of the
boot, matching T6b-4b's observation that the mixed speedup comes from a
small shared window, not permanent dual residency.

**Gates + timing.** `g6lc64_smt2_ooo_int`: `ooocoh-m2-gate-smt2_ooo_int-r1`
lint **28/0**, synth **2/0** (`check -assert` clean; the +4 lint / +1 synth
warnings vs M1b are the `smt_mixed_stats` display-block width notes and the
M1c counter-port notices — all `%Warning` class). Defaults
(`ooocoh-m2-gate-defaults-r1`): lint 8/0 + 54/0, synth 32/0 + 5/0 — at the
M1b baselines.
FO4 `sparse_smt_mixed_commit` at ring 8 (`m2-fo4-mixed-commit`, param map
`g6lc64_smt2_mixed_xlen64.json`): worst **31.0 FO4** (`store_buffer`
reg→reg, slack 1.0, ~1290 MHz vs 1250 MHz budget) — within the ≤32 bound;
cones: scoreboard 30.5, commit_stage 30.0, store_buffer 31.0, `g6lc_rob`
8.0, `g6lc_smt_csr_bank` 6.0.

### T9e — M1d: reserved downstream write id `WR_ID` (2026-09-28)

**Decision rationale.** T9c measured `l2_line_hold` ≈ 100 % R2 (different-id
same-line AW), with the same-core share ≥55 % at L40. Of the three options
the measurement supported, the chosen fix is neither a hub-id scheme nor an
unproven downstream-order assumption: the L2/L3 engine puts **every postable
write it forwards on one reserved downstream write id**,
`WR_ID = AXI_ID_WIDTH'('1) - 1` (14; `FILL_ID` = 15 keeps the bypass trail).
AXI same-id ordering then guarantees memory applies the L2's posted writes in
the L2's acceptance — merge — order for every same-line pair, same-core or
cross-core, with no integration assumption and no hub change. R2 disappears
for posted-vs-posted entirely (the ~45 % cross-core share too, not just the
measured ≥55 %).

**Change.** `g6lc_l2_wtrk` entries split the recorded id: `ent_id_q` (slave
id, for the slave-visible B) and `ent_dsid_q` (downstream id, for memory-B
matching and the R2 line probe). `g6lc_l2_top`: postable writes
(`atop=='0 && !lock && id != FILL_ID`) forward with `mst_req_o.aw.id = WR_ID`;
ATOP/lock/FILL_ID-alias writes keep their original id on the blocking path.
Memory B matches `ent_dsid_q` oldest-first (pure FIFO on `WR_ID`); the slave B
carries `ent_id_q`. R2 compares downstream ids: a same-line AW holds only when
the two downstream ids differ — posted-vs-posted never holds,
posted-vs-blocking and blocking-vs-posted still do. R1 and R3–R6 are
unchanged (AR vs AW is unordered in AXI regardless of id, so the read-miss
hold stays). Legality: ids 14/15 are reserved, `CohMaxOutstanding <= 14`
stands; a postable slave write arriving already on `WR_ID` is an integration
violation (sim assert, parameter `SLV_WRID_OK` — 0 at the hub-facing L2, 1 on
the inner L3 engine which receives L2-retagged `WR_ID` writes by design and
re-tags them to its own identical `WR_ID`). `check_cfg` comments updated.
New `[mc_cache]` field `hub_ar_hold` (`hub_ar_wr_hold_o`: a core AR offered
but ineligible because `ar_wr_line_live` — the next candidate bottleneck,
measured on the same boots); tied 0 in the single-core path. Parsers treat it
as an optional trailing field; older lines still parse.

**Formal** (`verif/tb/l2/formal/`, yices): P1 is now "no two valid entries
share a line with different *downstream* ids"; `push_dsid_i` added and the R2
admission assumption compares downstream ids.
`g6lc_l2_wtrk_{prove,live,cover}` PASS, `mut_p1` intended-FAIL;
`g6lc_l2_top_prove` PASS, `mut_p3` intended-FAIL.

**HUM** (`ooocoh-m1d-hum-*`, 12 lanes): full WU{0,1}×TAG_SRAM{0,1}×POSTED{0,1}
matrix — POSTED=0 contract hash **byte-identical to M1b (= M1a)** on all four
combinations; POSTED=1 94/94 (wu0) and 110/110 (wu1) records matched. sc51 is
reworked: two posted writes to one line from different slave ids under
`+mem_reorder_ids` now pass with **no R2 hold** (memory sees a single id — the
reorder knob has nothing to reorder). New sc60 probes that contract (final
memory = second write, `l2_hold_r2` = 0) and sc61 holds a posted write behind
a same-line ATOP (different downstream ids). Fault controls:
`pw_r1`→`HUM_R1_FILL_LAUNCHED`, `pw_r2` retargeted to sc61→`HUM_ATOP_AW_ACCEPTED`,
`pw_r5`→`HUM_DATA`, `pw_wrid` (posted writes forwarded on original ids while
the tracker records `WR_ID`) → the fail-fast B-routing assertion
"no live write-tracker entry" fires before the `HUM_WID_DRAIN` watchdog.

**Composed + credits.** All six composed lanes (`ooocoh-m1d-composed-*-wu1-r1`:
small, mod-only, stack-small, stack-fault, SCC, SCC+L3) matched with
`late_ar >= mem_b`; SCC 0 through hub+L2 and hub+L2+L3, `check -assert` clean.
Six credit lanes (`ooocoh-m1d-credits-*-r1`) byte-matched the M1b metrics —
reads-only `max_fills`/`max_ar_live` 4@OT4 / 8@OT8, mixed `wr_stall` 22→0 at
OT8, `max_aw_live` 1, L3 stack `max_fills`=5/`aw`=2/drain 270 — `WR_ID` does
not change hub slot usage (`fills + wtrk + rdtrk ≤ credits` stands).

**Gates + timing.** FO4 `g6lc_l2_top` (`m1d-fo4-l2top`): worst **28.5 FO4**
(reg0/CP→reg1/D, ~1403 MHz vs 1250 budget) — identical to the M1b screen.
Lint/synth `check -assert` (all `passed`, 0 errors):
`ooocoh-m1d-gate-ooo_int2-r1` 24/0 + 7/0,
`ooocoh-m1d-gate-ooo_int2_l3-r1` 24/0 + 13/0,
`ooocoh-m1d-gate-smt2-r1` 4/0 + 31/0,
`ooocoh-m1d-gate-smt2_l3-r1` 4/0 + 41/0,
`ooocoh-m1d-gate-smt2_ooo_int-r1` 28/0 + 2/0,
`ooocoh-m1d-gate-defaults-r1` 8/0 + 54/0 lint, 32/0 + 5/0 synth — at the M1b
baselines (int2 synth drops to 7 because the lint tops now tie the hold-split
taps).

**Directed** (int2/int2_l3, L0/L40 — `run_mc_int2_review.py`, pos+neg):
`mc_l2_write_read` L40 518,507 (int2) / 543,093 (int2_l3) — identical to M1b;
`mc_l3_stride_scan` 512K, `mc_store_load_new_line`, `mc_cbo_ewt` (±),
`mc_smt2_boot_release`, `mc_shared_line_coherence` (PEER_HART=2, negatives
fire) — all records matched.

**Strict boots** (threads=1, `ALLOW_CONCURRENT`; counters + cycles vs M1c):

| Lane | Tag | Cycles (M1c) | `l2_hold_r1` | `l2_hold_r1_wu` | `l2_hold_r2` | `hub_aw_sc_collide` | `hub_ar_hold` | `l2_posted` |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| int2 L0 | `ooocoh-m1d-osbi-int2-L0-r1` | **17,870,562** (17,903,402, −0.18 %) | 1 | 0 | **0** | 418,054 | 0 | 842,872 |
| int2 L40 60M | `ooocoh-m1d-osbi-int2-L40-r1` | **40,024,648** (40,712,259, −1.69 %) | 164 | 0 | **0** | 388,923 | 285 | 779,312 |
| int2_l3 L0 | `ooocoh-m1d-osbi-int2l3-L0-r1` | **18,389,755** (18,905,079, −2.73 %) | 2 | 0 | **0** | 440,181 | 1 | 860,049 |
| int2_l3 L40 60M | `ooocoh-m1d-osbi-int2l3-L40-r1` | **40,405,333** (41,946,955, −3.68 %) | 82 | 0 | **0** | 392,774 | 243 | 791,031 |
| smt2_l3 L0 | `ooocoh-m1d-osbi-smt2l3-L0-r1` | 13,691,686 (unchanged) | 4 | 0 | 0 | 0 | 0 | 552,843 |
| smt2 L0 (anchor) | `ooocoh-m1d-osbi-smt2-L0-r1` | **12,406,273 — byte-identical anchor** | 0 | 0 | 0 | 0 | 0 | 519,730 |
| smt2_ooo_int mixed L0 (anchor) | `ooocoh-m1d-osbi-smt2ooo-L0-r1` | **10,556,456 — byte-identical mixed anchor** | 0 | 0 | 0 | 0 | 0 | 510,325 |

`l2_line_hold` collapses from 372,982 / 13,647,144 / 730,556 / 14,385,949 to
1 / 164 / 2 / 82 — the whole R2 bill is gone; the residual is a handful of
genuine R1 events (all write-around, `l2_hold_r1_wu` = 0 everywhere).
`hub_aw_sc_collide` still counts the hub slot-level same-core same-line AW
offers (~390–440 k) — that upstream hold is the remaining same-core cost and
is now the largest single stall source, though far cheaper than the old L2 R2
round trips. `hub_ar_hold` measures the AR-behind-write hold at 0–285 cycles
per boot — negligible; the anticipated next bottleneck is not one.

**Final anchors (replace M1b's).** smt2 L0: 12,406,273 cycles, rvfi hart_00
sha256 `e0858842b829e5e244d1297df1f95fc916c745079444455c48946a8ca9199810`,
18,522,309 lines — **identical hash and count
to the M1b anchor** (single-core posted-write order is unchanged). smt2_ooo_int
mixed L0: 10,556,456 cycles, rvfi hart_00 sha256 `6fd35592317c21393d6465e0d795766f14a05db977542ae7adb18bd54fc7c5a9`,
18,544,481 lines (mixed residency per T9d; `+smt_mixed_stats`:
`both_resident_cycles`=60,914, `cross_hart_port1_commits`=4,851,
`hol_residual`=1,488, retired h0=8,810,200 / h1=462,035 — byte-identical to
the M2 measurement).

### T9f — M3: frontend/window uplift measured on `g6lc64_ooo_int2_l3`/`g6lc64_smt2_ooo_int` — **measured, not adopted** (2026-09-28/29)

**Scope.** Both production OoO targets ran `NrScoreboardEntries = 8` (inherited
from `g6lc64_smt2`); the scoreboard ring is the real in-flight window
(`TRANS_ID_BITS = clog2(NR_SB_ENTRIES)`). The M3 uplift (ring 32, TAGE_LITE,
DeepSpec/memdep, LSQ 16/8, FTQ 8/FDIP/loop buffer) was built, gated, measured —
and **every candidate knob regresses the strict four-hart boot**, so both
qualification packages stay at the M1d geometry (ring 8, BHT, `BPCkptDepth=0`).
What remains landed: the frontend switch-safety fix the work exposed, its
formal/leaf evidence, the bp-leaf hart-isolation evidence, and the
`+misp_stats` recovery probe.

**Landed: frontend switch safety.** A directed counterexample surfaced first:
`ooocoh-m3-wr-int2l3-L0-r3` double-committed the window at
`0x80000040`/`0x80000044` on an SMT hart switch. Root cause was not a missing
flush (`controller.sv` asserts `flush_if_o` on every `smt_switch_i`, and the
frontend's `smt_restore_flush` terms already cover FTQ/loop-buffer/FDIP
state): in `frontend.sv` the `SRC_RESTORE` case reseeded the FTQ at `arch_pc`
with `arch_step = 1'b0`, so `npc_q` stayed on the restore PC and the next
sequential `if_ready` re-pushed the same window. Fix: `arch_step = FtqEn`
(`core/fetch_B/frontend.sv`, ~line 566). Evidence on the fixed RTL: bounded
formal `core/fetch_B/formal/g6lc_fetch_restore.sby` (bmc, yices, depth 16,
NrHarts=2/FtqDepth=8/LoopBufEn=1) **PASS**; directed leaf
`verif/tb/core/tb_g6lc_fetch_restore.sv` **PASS** (restore window demanded
exactly once; `G6LC_MUT_FETCH_RESTORE_NOFLUSH` fails `FETCH_RESTORE_STALE` as
designed); bp leaf `tb_g6lc_rtl_review.sv` NR_HARTS=2 hart-isolation holds and
`mut-shareghr` is detected. `g6lc64_smt2` identity: byte-exact boot
(12,406,273 cycles, rvfi sha `e0858842b829e5e2` — the `arch_step` term is
inert at `FtqDepth=0`).

**Measured result — NOT adopted.** Uplifted `g6lc64_ooo_int2_l3` strict boot
22,376,701 (+21.7 % vs the 18,389,755 anchor) and `g6lc64_smt2_ooo_int` mixed
boot 13,603,015 (+28.9 %); `mc_branchy` +36.7 %.

**Recovery mechanism (from source — quoted).** A resolved mispredict does
**not** flash-free younger state; it *marks and drains*:

- `core/scoreboard.sv` (`bmiss` loop): every same-hart entry younger than the
  branch is marked `mem_n[i].cancelled = 1'b1` but keeps `sbe.valid` — the
  slot stays occupied.
- `issue_pointer` only advances by the allocation count
  (`issue_pointer_n = issue_pointer[num_issue]`); it is **not** rolled back —
  new correct-path allocations land *after* the dead entries in the ring.
- `commit_drop_o[i] = mem_q[commit_sel_slot[i]].cancelled` — cancelled entries
  retire through the in-order commit head as drops at commit width (2/cycle).
- `core/ooo/g6lc_rob.sv`: `cancelled_mask_i` marks younger ROB entries
  *complete* so in-order retire can drain them; freed by tid on the normal
  retire path — the ROB head does not jump.
- `core/ooo/g6lc_rename.sv`: rename map + free list **are** restored in one
  cycle to the branch's checkpoint (`map_d[ckpt_hart_q[level]]`,
  `free_d |= squashed`) — checkpoint restore is already fast; occupancy drain
  is the slow part.
- IQ/LSQ/LSU (`g6lc_iq.sv`, `g6lc_lsq.sv`, `load_store_unit.sv`) drop
  cancelled entries combinationally via `cancelled_mask_i` — they do not
  wait for the drain.

**`+misp_stats` probe** (translate_off, `core/scoreboard.sv`): per mispredict —
cycles from `resolved_branch_i.is_mispredict` to the first post-resolution
correct-path commit (allocation-epoch tagged, per-hart filtered) and the
in-flight issued-uncommitted count at resolution; mean/max/histogram plus
per-hart `bptrain`/`miss` at `final`.

**Ablation — each knob isolated** (package overlays of
`g6lc64_ooo_int2_l3`, the package itself never edited; L0, `PMU_G1`,
`+misp_stats`):

| Lane | Knobs over M1d | `mc_branchy` | `mc_l2_write_read` | `ooo_ilp_chain` | `ooo_mem_dep` | Boot L0 (anchor 18,389,755) |
|---|---|---:|---:|---:|---:|---:|
| M1d | — | 3,603,094 | 160,187 | 1,587 | 1,897 | **18,389,755** pass (exact anchor) |
| A0 | **ring 32 only** (ckpt 0) | 3,603,094 | 159,666 | 1,493 | 1,812 | **24,000,000 cap — timeout** |
| A | ring 32 + ckpt 32 | 3,603,094 | 159,615 | 1,493 | 1,821 | **24,000,000 cap — timeout** |
| B | TAGE_LITE + ITTAGE/loop/statcor + ckpt 32 | 3,604,260 | 160,198 | 1,584 | 1,895 | **24,000,000 cap — timeout** |
| C | FTQ 8 + FDIP 2 + loop buffer 8 | **4,919,262 (+36.5 %)** | **176,637 (+10.3 %)** | 1,583 | **2,026 (+6.8 %)** | 19,192,298 (+4.4 %) pass |
| D | DeepSpec + memdep + LSQ 16/8 + stores 8 + ckpt 32 | 3,603,094 | 159,615 | 1,493 | 1,819 | **24,000,000 cap — timeout** |
| E | ring 16 + ckpt 32 | 3,603,094 | 159,615 | 1,493 | 1,819 | **24,000,000 cap — timeout** |

Mispredict counts (PMU; `mc_branchy`): M1d/A/A0/D/E 98,111 · B 97,924 · C
98,111 — all flat. `iqStall` = 0 everywhere. Model SHAs: m1d `a513ce30`,
A0 `737a1682`, A `b8f541f9`, B `39ce12ad`, C `b70f827f`, D `a3a278f9`,
E `9f8fd530`. All lanes `ooocoh-m3abl-*-r3`.

**Reading — four independent costs, not one.**

1. **`NrScoreboardEntries > 8` alone breaks the boot.** The clean ring-32
   lane (A0, `BPCkptDepth=0` — proven legal: every `check_cfg` ckpt assert is
   `ckpt != 0 → …`) timed out at the 24 M cap, as did ring-16 (E) and
   ring-32+ckpt (A): all three show only ~7 k branch mispredicts (vs M1d's
   131 k) but doubled recovery means (A 17.4 / E 17.5 / A0 17.2 cycles vs M1d
   8.3) with a new tail at 88–124 cycles — deep drains are real when the ring
   holds > 8. A/E additionally log ~18.3 M retirements on the dominant hart
   vs M1d's 15.46 M — ~2.8 M *extra* commit events, i.e. squashed/replayed
   work draining through commit. **Mechanism hypothesis (unrooted — M3b must
   confirm):** the drained handoff serializes every hart switch on the ring
   being empty; a 2–4× window multiplies per-switch drain work on a
   switch-heavy boot, and/or flush-adjacent replays scale with occupancy.
   Kernels never see it because they run one active hart.
2. **TAGE_LITE thrashes on the boot stream:** lane B logged 622,336 branch
   resolves marked mispredict vs M1d's 130,923 (+375 %) — the 3×64-entry
   tables alias destructively. On `mc_branchy` it was neutral because LFSR
   data-dependent branches are uncorrelatable for any predictor. Per-hart
   banking is correct (`bptrain_h1`/`miss_h1` track the second hart), so this
   is a table-size/correlation limit, not a training-path bug.
3. **DeepSpec/memdep is boot-poisonous at ring 8:** lane D made the least
   progress of any timeout lane (~7.1 M retirements at the cap) —
   speculation replays dominate, not branch recovery.
4. **FTQ/FDIP/loop buffer is the only bounded-but-real frontend tax:** C is
   +4.4 % on the boot and +36.5 % on `mc_branchy` with a flat mispredict
   count and identical 7.0-cycle recovery mean — the cost lands on
   *correct-path* control transfers (~+2 cycles × ~720 k resolves ≈ the
   +1.32 M delta), i.e. the FTQ redirect walk / FDIP bandwidth, hidden under
   L40 memory latency (the M3-full wr-L40 lane was −0.1 %).

**Recovery scaling verdict (M3b justification).** At ring 8 every lane shows
mean ~7–8.5 cycles resolved→first-commit, dominated by the 4-cycle
front-end-refill bucket — drain-at-commit-head is real in the source but
hidden under refill while infl ≤ 8. At ring ≥ 16 the boot probes show
infl_max 16–17, mean doubling to ~17–19, and a drain tail at 88–124 cycles —
recovery *does* scale with in-flight depth once the window fills. The M3b
fast-squash sketch stands for deep-window work, but the measured blocker is
upstream of it.

**Decision (applied):** no lane satisfies "≤ M1d boot **and** ≤ M1d
`mc_branchy`" — nothing is adopted; `g6lc64_ooo_int2_l3` and
`g6lc64_smt2_ooo_int` stay at the M1d geometry. `g6lc64_smt2` identity
byte-exact (above).

**M3b candidate — fast squash (design sketch, NOT implemented).** Goal:
one-cycle invalidation of same-hart younger entries instead of
drain-at-commit-head.

- **Scoreboard**: reuse the existing bmiss younger-than+same-hart mask to
  drive `sbe.valid=0` directly (instead of sticky `cancelled` + drain),
  restore `num_free`, and roll `issue_pointer` back to branch+1 (the branch
  itself retires normally).
- **Tid-reuse hazard**: a freed slot can be reallocated while a killed load's
  WB is still in flight — either tag slots with a generation/epoch bit
  checked on WB/complete returns, or keep the LSU `cancelled_mask_i` kill
  authoritative and suppress WB to freed tids.
- **Commit head / ROB**: jump the head past the cancelled run (the head
  selection already scans `commit_sel_slot`); ROB frees masked entries
  instantly rather than via per-entry retire acks; no `commit_drop` is
  produced for entries that never reach the head (no double-free, since the
  rename checkpoint already returned their registers).
- **Rename**: unchanged — checkpoint restore already returns map + free list
  in one cycle.
- **IQ/LSQ/LSU**: unchanged — `cancelled_mask_i` drops them combinationally.
- **Mixed residency (T6b)**: the ring is shared and `issue_pointer` is
  global — peer-hart entries younger than the branch must survive, so the
  pointer cannot roll back past them. Fast squash applies to drained
  (`SmtDrainedHandoff=1`: ring holds only the resolving hart at switch time)
  and single-hart packages; `smt2_ooo_int` (mixed) keeps the drain path
  unless the ring becomes a per-hart free list.
- **FO4 estimate**: the younger-than mask exists combinationally today; the
  delta is a `valid`-clear fan-out (~1 FO4), a `num_free` popcount (~2–3 FO4
  at 32), pointer/head muxes (~1 FO4) → ≈ +2–4 on the issue/commit cones.
  `sparse_smt_mixed_commit` was 31.0 at ring 32 — must re-screen; drained
  targets have headroom.

**M3b pre-work (recorded, not scheduled):** root-cause the ring>8 boot
pathology before any window uplift — A0 (pure ring 32, ckpt 0) shows it is
*not* a checkpoint-depth effect; per-switch drain or flush-adjacent replay is
the suspect. TAGE needs bigger tables or a different boot profile before it
can earn its area. DeepSpec needs a replay-rate counter to tune.

**Legality note**: `RobEntries = max(NrScoreboardEntries, NrIssuePorts·16)` →
floor 32 on int2_l3; `BPCkptDepth` is only constrained when non-zero
(`OoOEn && ckpt != 0 → ckpt ≥ RobEntries`), so `ckpt=0` is legal at any ring —
used by lane A0 to separate ring depth from checkpoint depth.

**Artifacts**: `ooocoh-m3abl-*-r3` (ablation), `ooocoh-m3-*` (uplift runs).

### T9g — M4: FP on the OoO path — single-hart and drained-handoff legal (2026-09-29)

**Scope.** Enable and qualify RVF/RVD on `g6lc64_ooo_int2_l3` (2c×2h, WT,
`COH_OOO`, non-inclusive L3, drained handoff) and lift the FP legality guards
for `NrHarts == 1 || SmtDrainedHandoff`. Mixed-residency FP stays refused.

**What changed.**

- `core/fpu_wrap.sv` — per-slot owner table (`owner_live_q`,
  `owner_cancelled_q`): an FP request is accepted only onto a free/uncancelled
  slot; a result may drive `fpu_valid_o`/writeback only while its `trans_id`
  still owns the slot; flush and cancellation clear ownership. The
  `G6LC_MUT_FP_NO_OWNER_LIVE` mutation drops the owner-live compare.
- `core/include/config_pkg.sv` — `check_cfg`: the
  `ifndef G6LC_OOO_FP_QUALIFY` leg now reads
  `!(OoOEn && FpPresent && NrHarts > 1 && !SmtDrainedHandoff)` (was
  `!(OoOEn && FpPresent)`); `!FpPresent` is dropped from the `COH_OOO`
  legality term.
- `core/ooo/g6lc_ooo_dispatch.sv` — `gen_err_ooo_fp_mh` narrowed to the same
  `&& !SmtDrainedHandoff` term (mixed + FP stays a hard elaboration error).
- `core/include/g6lc64_ooo_int2_l3_config_pkg.sv` — `CVA6ConfigRVF=1`,
  `CVA6ConfigRVD=1`, FPU/XF fields aligned with the `g6lc64_smt2` package.
- `corev_apu/bootrom/ariane-ooo-int2-l3.dts` — `riscv,isa` →
  `rv64imafdc_zba_zbb_zbs_zicbom_zicboz_zacas` (f/d added to the existing
  zacas/zicbo* set; `smt,fp-register-banking=<0>` kept — the drained handoff
  switches the whole FS context).
- `verif/tb/g6lc_cluster_lint_top.sv` — the pre-M4 workaround
  `if (c.FpPresent) c.OoOEn = 0` narrowed to the still-refused
  mixed/non-drained shape (it had been making the FP-enabled `COH_OOO` target
  illegal at the gate).
- `verif/regress/remote/run_ooo_fp_review.py` — multi-hart model support:
  per-hart rvfi trace handling (`FP_REVIEW_ACTIVE_TRACE`), the `mc_verdict`
  held-secondary fold (`FP_REVIEW_HELD_OK` — program exit from the
  `[mc_verdict] program exit code` line, not tohost 125), and the
  `FP_REVIEW_PARK_FILTER` mixed 16/32-bit park-loop detector.

**Legality result.** `g6lc64_ooo` is legal single-hart FP;
`g6lc64_ooo_int2_l3` is RV64GC+B under the drained handoff; `g6lc64_ooo_server`
is no longer refused by the generic multi-hart FP leg (it is drained) but
stays an opt-in/unqualified target — its `COH_FILTERED` coherence has no M4
qualification evidence. FP under mixed residency (`!SmtDrainedHandoff`)
remains refused by both the `check_cfg` leg and `gen_err_ooo_fp_mh`.

**Evidence.**

- *Owner proof*: `core/ooo/formal/g6lc_ooo_fp_owner.sby` — `bmc` PASS
  (depth 24 ≥ S2 reuse window), `cover` PASS (normal completion, cancellation
  suppression, reallocation, held-input cancellation, flush), `mut_owner`
  expected-FAIL at step 2.
- *S2 leaf witness*: `tb_g6lc_review_fp_lifetime` rerun
  (`ooocoh-m4-s2-fplife-r4`) — all scenarios matched (normal/delayed reuse/
  cancel-reuse/flush/same-cycle replacement); mutation rerun
  `ooocoh-m4-s2-fplife-mut-r5` detected (`FP_OWNER_CANCELLED_RESPONSE`,
  rc=SIGABRT, `retention-mutation-detected`).
- *FP suite on the int2_l3 FP model* (model sha `20d3d08f…`,
  `ooocoh-m4-fp-*-r2`): 13 positives + 13 negatives all
  `retirementsMatch: true`, `qualified: true`; program exits exact
  (positives 0, negatives 1–11).
- *Four-hart directed* `mc_fp_smt` (`ooocoh-m4-fpsmt-r1`): positive pass
  (tohost 0, 3,774 cycles, all harts retired); negative detected
  (tohost 1, 961 cycles).
- *SB=16 stage-9*: `ooo_fp_cancel_tid_reuse` on the `g6lc64_ooo` SB=16
  overlay (`ooocoh-m4-sb16-s9-r1`, model `0ab95827…`) — the historical T5
  hang does not reproduce: pass in 5,279 cycles, Spike retirements exact,
  `qualified: true`. (Link to T9f: ring ≥ 16 *strict boots* time out under
  the drained handoff — a different pathology than this stage-9 hang, which
  was a fetch-park defect already fixed in T5.)
- *FPU synth delta* (`ooocoh-m4-fpusynth-r5`, leaf stat, generic cells):
  owner-live tracking costs **+454 cells / +454 wire bits** (66,558 vs
  66,104); both variants `check -assert` + `scc -expect 0` clean.
- *Gate* (`ooocoh-m4-gate-int2l3-r2`): lint 23 warnings / 0 errors, synth
  43 warnings / 0 errors, `check -assert` clean — FP-enabled `COH_OOO`
  elaborates define-free.
- *Firmware*: `ariane-ooo-int2-l3.dts` → DTB OK (4 cpu nodes =
  NrCores·NrHarts; validator FAIL=0, the pre-existing dual-CLINT-binding
  GAP unchanged); OpenSBI profile `ooocoh-m4-fw-int2l3-r2` built with
  `rv64imafdc_zicsr_zifencei`.
- *Strict boot*: `ooocoh-m4-osbi-int2l3-L0-r1` — **PASS, 18,419,779
  cycles** (tohost 0, strictDual, tracer-terminated; +30,024 / +0.16 % vs
  the 18,389,755 M1d anchor — inside the allowed FPU decode/CSR movement).
  Model `20d3d08f`, profile `ooocoh-m4-fw-int2l3-r2`, dtb `ecbcffb7`,
  payload `3bcb66ab`, firmware `20cf5b51`.
- *int2 identity*: `ooocoh-m4-osbi-int2-L0-r3` — **PASS, 17,870,562
  cycles, byte-identical to the M1d int2 anchor** on the restored frozen
  profile (remote dir re-primed from the pinned local artifact,
  payload/firmware sha re-verified before the run). The shared M4 core
  files are inert at `FpPresent=0` — the boot, not a file-set hash, is
  the evidence.

**Remaining.** Mixed-residency FP (hart-tagged lazy-FS audit);
`g6lc64_ooo_server` qualification; the T5 s11 residual note is superseded by
the r2 Spike-exact suite run.

### T9h — M5: L2 stream/stride prefetcher — landed, default off (2026-09-29)

**Scope.** Tier-R demand-miss-trained L2 prefetcher
(`corev_apu/l2_cache/g6lc_l2_pf.sv`) behind `L2PrefetchEn` (default 0),
`L2PfStreams` (4), `L2PfDistance` (2 lines), `L2PfStrideEn` (1),
`L2PfMshrReserve` (1). `L3PrefetchEn` shares the fields and stays off at the
L3 instance.

**Design.** Trained on demand misses at S_TAG miss commit; streams tracked by
4 KiB region tag; next-line and stride detection (two consecutive equal
deltas); at most one candidate per cycle; never crosses a 4 KiB page.
Candidates allocate a PF-flagged MSHR/fill entry (no waiter, fills install
like demand fills, killed/failed fills take `install_discard`, same
`kill_match` as demand). Demand allocation wins and PF may allocate only
while `L2PfMshrReserve` entries remain for demand. A candidate matching a
resident line, an in-flight MSHR line, or a tracked write is dropped, never
held — tracker ordering rules and R1 are unchanged. `pf_useful` counts a
demand hit on a way marked `pf_installed`. Observability: `l2_pf_issue_o`,
`l2_pf_useful_o`, `l2_pf_drop_o`; `[mc_cache]` counters of the same names;
PMU group-2 selectors 9 (`l2_pf_issue`) and 10 (`l2_pf_useful`; sel 2 stays
the server-PF counter). Timing note in `g6lc_l2_top.sv`: the PF probe is one
extra S_IDLE-cycle candidate compare against tags/MSHR/write-tracker and
shares the existing miss-allocation mux — no new pipeline stage.

**Evidence.**

- *Leaf* `verif/tb/l2/tb_g6lc_l2_pf.sv` (`L2TB_MODE=pf`): train/issue,
  stride, 4 KiB page boundary, MSHR reserve, drop-on-resident,
  drop-on-tracked-write all pass (`RTL_REVIEW_PASS l2_pf`, sample metrics
  issue=8/useful=2/drop=8); `+oracle_negative` fails as designed;
  `L2TB_PF_MUT=noreserve` removes the reserve term and is detected
  (`L2PF_RESERVE`/`L2PF_NO_FILL_AR` — a PF takes the last MSHR and the
  eighth demand stalls).
- *HUM pf-off identity* (`ooocoh-m5-hum-p0-wu1-ts0-r2`): 110 records,
  0 unmatched — `L2PrefetchEn=0` changes no existing record.
- *HUM pf-on* (`ooocoh-m5-hum-pf1-wu1-ts1-r4`): 114 records, 0 unmatched;
  new directed scenarios 62-64 (useful hit after a stream, same-line write
  kills the in-flight PF, R1 respected) pass pos+neg. Scenario 30 is
  excluded under PF only: it synchronizes on the exact `mem_ar_count`, and
  PF ARs legitimately increment that counter — a bench limitation, kept for
  the pf-off identity lane.
- *SCC* (`ooocoh-m5-hum-scc-{ts0,ts1}-r2`, `ooocoh-m5-hum-scc-pf1-ts{0,1}-r3`):
  `Found 0 SCCs in module g6lc_l2_fixture` at PF=0 and PF=1.
- *Gates*: `ooocoh-m5-gate-defaults-r1` lint 9/55 warnings, 0 errors, synth
  5/32 warnings, 0 errors; `ooocoh-m5-gate-int2-r3` lint 25/0, synth 7/0;
  `ooocoh-m5-gate-int2l3-r3` lint 24/0, synth 43/0 (43 = the M4 count — the
  PF cone adds no synth warnings).
- *FO4* `g6lc_l2_top` (`m5-fo4-l2`): worst cone 30.5 FO4 (reg-to-out) vs the
  32 budget — closes; `failing_paths: 0`.

**Kernels** (`g6lc64_ooo_int2_l3` models `d7a54392`/`e2c0e9f1`/`2cde927d`/
`a3c5655b`; pos arms matched, neg arms detected):

| Kernel | PF off | PF on | Delta |
|---|---:|---:|---:|
| 512 KiB stride scan, L0 | 424,488 | 382,498 | **-9.9 %** |
| 512 KiB stride scan, L40 | 1,047,138 (prior base) | 961,451 | **-8.2 %** |
| `mc_l2_write_read`, L0 | 160,187 | 139,184 | **-13.1 %** |
| `mc_l2_write_read`, L40 | 542,715 (prior base) | 500,378 | **-7.8 %** |
| `mc_chase`, L0 | 459,241 | 459,180 | -0.01 % (neutral) |
| `mc_chase`, L40 | 942,584 | 942,495 | neutral (3 issues) |

PF counters confirm the mechanism: scan L0 issue 2,366 / useful 3,761 /
drop 17,219; wr L0 1,183/1,183/384; chase 3/3/1.

**Strict boots** (int2_l3, `ooocoh-m4-fw-int2l3-r2` profile, strictDual):

| Boot | Cycles | vs anchor |
|---|---:|---|
| int2_l3 L0, **PF off** (`ooocoh-m5-osbi-int2l3-pf0-L0-r2`) | 18,419,779 | **byte-exact M4 anchor** — the M5 tree is inert at PF=0 |
| int2_l3 L0, PF on (`ooocoh-m5-osbi-int2l3-pf1-L0-r1`) | 18,471,075 | +51,296 (+0.28 %) |
| int2_l3 L40, PF on (`ooocoh-m5-osbi-int2l3-pf1-L40-r1`) | 40,540,375 | +135,042 (+0.33 %) vs 40,405,333 |

Boot PF traffic is tiny (L0: 226-230 issued / 176-184 useful / ~50 dropped)
yet the delta is real and prefetcher-caused: the pf0 control boot reproduces
the anchor exactly, so the ~0.3 % is ~230 extra fill ARs shifting demand
arbitration, not model drift.

**Decision — not enabled.** The adoption bar was "boot and scan both improve
or are neutral". The scan improves (-9.9 % / -8.2 %) but both boots cost
+0.3 %, so `L2PrefetchEn` stays **0 in every shipped package** and no int2
boot was run (the int2_l3 condition failed). The feature is a proven
config-gated candidate: reclaiming the residual needs the PF to yield
harder under bursty demand (candidate-throttling / deeper reserve), which is
post-M5 work.

**Remaining.** `L3PrefetchEn` never qualified; drop-count vs useful ratio on
the scan (~4.6x drops per issue) suggests distance-2 fires past the demand
window under no latency — a tuning note, not a correctness defect (drops are
cheap: candidate discarded at admission).

### T9i — M6: in-order non-inclusive L3 packages — landed (2026-09-29)

**Scope.** Two in-order qualification packages carrying the M1b/M1c
non-inclusive L3 stack on the HPDCACHE_WT in-order core:
`g6lc64_stream8_l3` and `g6lc64_server_math_l3`
(`core/include/g6lc64_{stream8,server_math}_l3_config_pkg.sv`). Both are
NrCores=2 / NrHarts=1-per-core copies of their base packages with
`L3En=1, L3InclusiveEn=0, L3ByteSize=1 MiB, L3SetAssoc=16,
L3LineWidth=512, L3MshrDepth=4, L3DataBanks=4, L2TagSramEn=1`; eWT flags
as the base (write-update, posted writes, CMO on). `WtAxiAllocEn=0` on
both — the knob belongs to the classic-WT adapter and `check_cfg`
refuses it off `DCacheType==WT`; HPDCACHE_WT emits allocate attributes
directly. DTS: `corev_apu/bootrom/ariane-{stream8,server-math}-l3.dts`
(L2→L3 `next-level-cache`, plat_hc 2, one hart per core;
validator FAIL=0 with the same two pre-existing stream8 GAPs).
Build-platform targets registered in `build-platform/src/config/defaults.ts`
(cluster flist, `g6lc_cluster_lint_top`).

**Evidence.**

- Gates r1 (remote lint + synth `check -assert`): both targets 9w/0e lint,
  46w/0e synth.
- Composed hub+L2+L3 bench at the stack target: all scenarios matched,
  including scenario 7 (HPDCACHE attribute stream, `l2_wupd=3`, L3
  stacked). Credits bench at 4 with the L3 stack: matched.
- Remote directed suites on both models (`ooocoh-m6-*-r2`, model SHAs
  s8l3 `8a3a6abf4e3d`, sml3 `a09ea3fceee8`): `mini_amocas` W 543 / D 702 /
  Q 978 cycles pass, `mini_stream_plane` 2026 pass, `mc_cbo_ewt` positive
  pass (~120,490) with the negative arm detected as designed (~120,170).
  All 10 queue lanes `passed`.
- Strict OpenSBI two-core boots: first in-order strict-boot profiles
  built from the `smt2_l3` mechanism (`SOURCE_REVIEW_HARTS=2`,
  `SOURCE_REVIEW_CORES=2`, per-package DTS+config overrides via the new
  `SOURCE_REVIEW_DTS`/`SOURCE_REVIEW_CONFIG_PKG`/`SOURCE_REVIEW_ISA` env
  seams; both targets admitted to `EXPERIMENTAL_TARGETS`). Result —
  **PASS on the first attempt**, the first in-order two-core strict
  boots: `ooocoh-m6-osbi-s8l3-r1` `*** SUCCESS *** (tohost = 0)` after
  11,691,278 cycles on model `8a3a6abf4e3d`; `ooocoh-m6-osbi-sml3-r1`
  after 11,691,235 cycles on model `a09ea3fceee8` (both
  `strictDualPassed`, not timed out, platform ISA
  `rv64imafdc_zicsr_zifencei`, pinned OpenSBI `455de672`).

**Status.** Qualification-only in-order L3 packages; `L2PrefetchEn` stays
0 per the M5 decision. Open: L3 benefit measurement on these packages,
physical closure.

### T9j — M7: 4-issue overlay — not promoted, blocked on M3b (2026-09-29)

**Decision.** The M7 4-issue overlay is **not promoted**: a wider issue
width needs a wider window to pay off, and the M3 ablation showed every
ring > 8 times out the four-hart strict boot under the drained handoff
while mispredict recovery is mark-and-drain (younger entries retire
through the commit head at commit width, `issue_pointer` never rolls
back). No i4 overlay was built; no RTL changed.

**Reopen preconditions** (both, in order): (1) M3b — fix the
stuck-drain hole found in T10d/N1b (a pending drain waits on
`wait_sb` unboundedly when the resident hart never empties the
scoreboard — the ring-32 24M boot timed out on exactly this, ~6.06 M
cycles; ring 16 merely never hit it on the measured lanes) and land the
fast-squash design sketched in T9f (age/cancel-mask `sbe.valid` clear +
`issue_pointer` rollback + commit-head jump, hart-scoped); (2) re-run
the T9f ablation shape on the fixed recovery path — a 4-issue candidate
is only worth building if a wider window is first proven boot-neutral
at L0.

### T10b — N3: L2 prefetcher burst throttling — measured, still off (2026-09-29)

**Change.** `g6lc_l2_pf` gains `L2PfMaxOutstanding` (default 1 PF fill in
flight per stream), `L2PfQuiet` (default 8-cycle no-issue window after a
demand miss) and a confidence gate (PF issue requires >= 2 confirmed
hits on the stream). `L2PfMshrReserve` unchanged. Build defaults:
`L2PfMaxOutstanding=1`/`L2PfQuiet=8` when the field is 0; `check_cfg`
rejects `L2PrefetchEn`/`L3PrefetchEn` with `L2PfMaxOutstanding=0`. The
L3 instance in `g6lc_cluster` shares the same fields (params threaded
through `g6lc_l3_top`).

**Leaf.** Positive `L2PF_METRICS issue=7 useful=2 drop=5` + `RTL_REVIEW_PASS`;
`+oracle_negative` fails. Mutation controls all detected: `maxcap`
(`L2PF_EXTRA_CAND`), `noreserve` (`L2PF_RESERVE`), `noquiet`
(`L2PF_QUIET_BREAK`), `earlyarm` (`L2PF_EARLY_CAND` — the mutation
sustitutes `train_hit` for the confidence compare; a literal
`conf >= 2'd0` was constant-folded by Verilator).

**Measurements on `g6lc64_ooo_int2_l3`, PF on, tuned knobs.**

- 512K scan: L0 385,988 / L40 962,623 cycles (vs pf0 424,488/1,047,138 —
  -9.1 % / -8.1 %, i.e. the gain holds).
- write/read: L0 140,942 / L40 500,949 (vs 160,187/~542,715).
- PF efficiency: scan L0 `issue=2,878 useful=5,398 drop=9,116`; L40
  `issue=3,837 useful=7,197 drop=8,157` — roughly half the M5 issue
  volume at the same gain (quiet+cap cut the speculative supply).
- **Strict L0 boot `ooocoh-n3-int2l3-pf1-osbi-L0-r1`: SUCCESS after
  18,479,834 cycles — +60,055 (+0.33 %) vs the 18,419,779 anchor** with
  only `l2_pf_issue=64 useful=56 drop=4` for the whole boot. The +0.3 %
  cost is therefore not prefetch-supply interference; it rides on the
  candidate path itself (arbiter mux / candidate presence on the MSHR
  offer), and throttling cannot remove it.

**Decision.** Adoption rule was boot <= anchor AND scan keeps >= half
its gain. Boot fails (+0.33 %). `L2PrefetchEn` stays 0 in every package;
`L3PrefetchEn` stays 0. The knobs ship as tuned defaults; a future
candidate-path repair (remove the candidate from the demand arbitration
timing) could re-open adoption — scan/write gains are proven.

### T10c — N4: `hub_aw_sc_collide` is an observation, not a stall (2026-09-29)

**Question.** `hub_aw_sc_collide` counts AW offers colliding with a live
same-core same-line AW slot. T9e recorded "~390-440 k, largest remaining
same-core stall". Verify whether the hub ever *holds* an AW for it.

**Code read.** `aw_grant` in `g6lc_coherence_hub` requires
`!aw_ot_full && aw_have_free && !w_busy_q && !(aw_may_invalidate && inv_pend_valid_q)`
(+ OOOSF signature gating). The same-line collide is not a term — a
collide alone can never produce a hold.

**New counters** (`hub_aw_hold_slot_o`/`hub_aw_hold_other_o`, folded
into `[mc_cache]` as `hub_aw_hold_slot`/`hub_aw_hold_other`): cycles a
core-port AW is `valid && !ready`, split into slot-table-exhausted vs
everything else.

**Measurement** (int2_l3 L0 boot `ooocoh-n3-int2l3-pf1-osbi-L0-r1`, and
the N1 6M runs): `hub_aw_sc_collide=444,641`, **`hub_aw_hold_slot=0`**,
`hub_aw_hold_other=929,874` (~1.08 per posted write), `hub_ar_hold=2`,
`l2_wtrk_full=0`. Not one AW was ever held for slot reasons.

**Verdict.** `hub_aw_sc_collide` is an offer-level observation (an upper
bound on would-be R2 serialization), not a stall. The largest measured
residual stall at the hub is the AW serialization counted by
`hub_aw_hold_other` — one write-data channel at a time plus downstream
`!aw_ready`, ~1 hold cycle per posted write. Docs retitled
(`AGENTS-todo.md` M1d line corrected; ewt-caching/l2 README status
notes added).

### T10a — N1: ring>8 drained-handoff timeout — refuted for pure depth (2026-09-29)

**Probe.** `+smt_stats` observer in `core/cva6.sv` (translate_off,
`NrHarts > 1 && SmtDrainedHandoff`): per-core drain requests/switches/
aborts, drain-cycle totals, max, not-ready cause split
(`wait_sb`/`wait_st`/`wait_flushid`/`wait_peer`/`wait_hold`/`wait_trap`/
`wait_flush`), duration histogram, per-hart retired, `commit_drop`;
prints every 1M cycles and at `final` on `[smt-drain]`; plusarg
allowlisted in `corev_apu/tb/g6lc_tb.cpp`.

**Runs** (int2_l3 L0 four-hart, threads=1): 6M-cap progress boots
`ooocoh-n1-int2l3-{r8,r16}-6M-L0-r4` and the ring-16 full boot
`ooocoh-n1-int2l3-r16-24M-L0-{r1,r2}`. Models `250fa966` (ring 8) /
`b32c1fa3` (ring 16) — build manifests verified to differ in exactly
one field: `NrScoreboardEntries` 8 vs 16.

**Numbers.**

- Drains are healthy: `switches == req`, `aborts = 0`, `commit_drop = 0`
  in both geometries; max drain 109–146 cycles (r16 max is *lower* than
  r8). Wait split: ~100 % `wait_sb` (scoreboard not yet empty — issue is
  not held while a drain pends); `wait_flushid`/`wait_peer`/`wait_hold`/
  `wait_trap`/`wait_flush` all exactly 0.
- Per-drain cost grows modestly: mean drain 16.3 vs 13.7 cyc (core 0)
  and 15.9 vs 11.4 (core 1); total drain overhead +50 k/+81 k cycles per
  core — ≈1 % of elapsed.
- **All handoff switching ends by ~2M cycles in BOTH geometries** — the
  drained handoff is an early-boot (hart-sync) phenomenon; after ~2M the
  counters freeze and each core runs its dominant hart solo.
- 6M progress is identical (r8 hart0 4,417,197 vs r16 4,443,939 retired;
  ~0.9 M instr/M-cycle on both) — no early divergence, no starvation.
- **Full ring-16 boot completes — but nondeterministically.** r1:
  SUCCESS after 17,250,251 cycles (record terminated `wall-budget`: the
  sim printed SUCCESS as the 3600 s wall limit fired). r2: SUCCESS after
  **18,297,381**, `strictDualPassed`, `timedOut: false`. Both under the
  24M cap — ring 16 vs the ring-8 anchor 18,419,779 is neutral-to-faster,
  not a timeout.

**The anomaly that matters: the ring-16 runs are not reproducible.**
Same model (`b32c1fa3`), same seed, same ELF: the 6M run and r1 agree
(`req` 23,150/20,769, drain totals identical), but r2 diverged
(23,672/21,133 requests, dominant-hart retired 15.46 M vs 14.70 M,
cycles 18,297,381 vs 17,250,251). Ring-8 anchors have always been
byte-identical. Caveat: Verilator evaluation is deterministic per
binary+inputs, so a pure delta-cycle RTL race would *repeat* across
launches — divergence means either an uncontrolled input reached the
sim (uninitialized/seeded reset state, host-fed value — none found in
`g6lc_tb.cpp`: `random_seed` is vestigial, `rtc_i` is cycle-driven, no
`rand()` consumers) or an evaluation-order sensitivity the build maps
differently per process. Mechanism unrooted — the discriminator is a
trace diff at first divergence (`smt_sched_trace`/`smt_flow_trace`, or
the per-hart `.dasm`) between an agreeing and a diverging launch: the
first differing cycle names the input path. **Resolved in T10d/N1b:
r1 was a 3600 s wall kill whose SIGTERM path printed a fake SUCCESS —
no RTL nondeterminism exists; r2/r3/r4 are byte-identical.**

**Verdict.** The drained-handoff timeout hypothesis is refuted for ring
depth alone: drains are bounded, wait only on the scoreboard (issue is
not held while a drain pends — the measured cause, but a ~1 % cost),
and the handoff phase is done by ~2M cycles regardless; pure ring-16
boots at-or-faster than ring 8 **in two of two completions** (r1
17,250,251 — record marked `wall-budget` as the 3600 s limit fired with
the SUCCESS line; r2 18,297,381 `strictDualPassed`). Mechanism (c):
the recorded limit is the mark-and-drain recovery cost from T9f plus
the reproducibility anomaly above — a pathological interleave/input
path that ring depth widens, consistent with the M3 lanes timing out
sporadically-by-construction rather than deterministically. No
issue-stage drain hold is implemented — the numbers do not support it.

### T10e — N3b: prefetcher idle demand-path cost is zero; the +0.3 % rides on live issues only (2026-09-29)

**Question.** T10b: the strict boot pays +0.33 % with only 64 PF fills,
so either the demand path itself carries a structural cost when
`L2PrefetchEn=1` (tag-port steal for the candidate lookup, MSHR-alloc
arbitration cycle, S_TAG miss-commit change), or the cost attaches to
the live offers/issues themselves.

**Discrimination build** `ooocoh-n3b-int2l3-pfq-build-L0-r2`:
`L2PrefetchEn=1` with `L2PfQuiet=1048575` — a ~1 M-cycle quiet window
that never lapses, so the prefetcher trains, performs the resident/MSHR
candidate lookups on every demand miss, but can never issue.
(`L2PfMaxOutstanding=0` was not usable as the never-issue seam —
`build_config_pkg` defaults 0 to 1; the `check_cfg` reject lives inside
`translate_off`, so the quiet overlay is a sim-only probe config, not a
shippable combination.)

**Result.** `ooocoh-n3b-int2l3-pfq-osbi-L0-r1`: SUCCESS after
**18,419,779 cycles — byte-identical to the PF-off anchor**,
`l2_pf_issue=0 l2_pf_useful=0 l2_pf_drop=0`. With PF enabled but never
issuing the boot pays nothing: the stream table, per-miss candidate
lookups and S_TAG miss-commit path are all live in this model and cost
zero cycles. There is no idle structural cost to repair.

**Verdict.** The +0.33 % is attached to the live offer/issue path —
the ~64 issued fills and the arbitration cycles in which a candidate
offers (drops included), not to the engine running idle. No RTL change
warranted; `L2PrefetchEn`/`L3PrefetchEn` stay 0. Adoption remains
blocked on making live PF issues demand-neutral, which is a policy/arb
problem, not an idle-cost problem.

### T10d — N1b: ring-16 "divergence" was a harness wall-kill artifact; ring 16 adopted (2026-09-29)

**Static audit** (ring-16 int2_l3 model `b32c1fa3` and the r16c smt2
model): no `--x-initial`/`--x-assign` overrides — Verilator pins X-initial
state to 0 and there are no `VL_RAND_RESET` sites; `threads=1`; no
`$urandom`/`rand()`/`random_seed` consumer exists in `g6lc_tb.cpp`
(`--seed` is accepted and unread); `+verilator+seed+`/`+verilator+
rand+reset+` have no compiled-in machinery to perturb — the requested
seed probes cannot discriminate and were skipped on that evidence.
`misp_stats` is fully `translate_off` (no RTL fan-in).

**Root cause.** The r1-vs-r2 "divergence" was a harness artifact, not
RTL: r1 hit the 3600 s wall budget; the pre-fix `g6lc_tb.cpp` SIGTERM
handler ran `dtm->stop()` then fell through to the success printer,
emitting `*** SUCCESS *** after 17,250,251 cycles` with truncated
`[smt-drain]` counters — hence the "different" drain/retire numbers.
Harness fix: `sigterm_seen` flag → a wall kill now prints
`*** TERMINATED (SIGTERM) ***` and exits 124, so a truncated run can
never again masquerade as a pass.

**Determinism proof.** r2/r3/r4 (identical model+seed+ELF launches) all
complete byte-identical at **18,297,381** cycles, `strictDualPassed`,
identical `[smt-drain]` totals (core0 req 23,672 / core1 21,133). No
reset gap, no read-before-write; the RTL reset/read audit items
(scoreboard `mem_q`, cancel/age masks, rename checkpoints, LSQ age
vectors) are moot given three identical full-boot traces.

**Adoption evidence (ring 16 = `NrScoreboardEntries 16`, `BPCkptDepth`
deriving 16 via `build_config_pkg`).**

- int2_l3 strict boot L0 (24M cap): **18,297,381 ≤ anchor 18,419,779**
  (−0.66 %), three identical completions.
- `mc_branchy` L0: **3,603,094 = M1d exactly**, neg arm detected;
  `ooo_ilp_chain` 1,493 / `ooo_mem_dep` 1,812 (M1d: 1,587 / 1,897).
- `sparse_smt_mixed_commit` FO4 at ring 16: **worst 31.0 ≤ 32**, slack
  1.0, ~1,290 MHz vs the 1,250 target — closes.
- `smt2_ooo_int` mixed boot `ooocoh-n1b-smt2ooo-r16-osbi-L0-r5`: **PASS
  10,459,588 cycles**, `strictDualPassed` (vs ring-8 10,556,456,
  −0.92 %); `sb_occ_max=16`, `both_resident_cycles=97,358`,
  `cross_hart_port1_commits=11,879`, `hol_residual=2,734`.
- Lint+synth `check -assert` gates on a HEAD+adoption export
  (`ooocoh-n1b-gate-{int2l3,smt2int}-r16`): int2_l3 lint 29w/0e, synth
  43w/0e; smt2_ooo_int lint 29w/0e, synth 2w/0e — all `check -assert`
  clean.

**Adopted.** `CVA6ConfigNrScoreboardEntries = 16` on
`g6lc64_ooo_int2_l3` and `g6lc64_smt2_ooo_int` (one localparam each;
`TRANS_ID_BITS`→4 and `BPCkptDepth`→16 derive in `build_config_pkg`).
`g6lc64_ooo_int2` (ring-8 anchor 17,870,562) and the drained smt2
package (anchor 12,406,273) are untouched — anchors still valid.

**Ring 32** (overlay: SB=32 with ROB 32 / PRF 72 / IQ 24 / LSQ 16+8 /
FTQ 8 / DeepSpec / memdep / MaxOutstandingStores 8): `mc_branchy`
3,603,094 = M1d, ilp 1,493 / memdep 1,821 pass — but the 24M four-hart
boot `ooocoh-n1b-int2l3-r32-24M-L0-r3` **timed out at the cap**
(`outcome=timeout`, `timedOut`). The `[smt-drain]` FINAL lines show the
mechanism — an instance of the N1 hypothesis-(b) livelock: on core 0 a
drain request was still pending at the cap (`req=23,488` vs
`switches=23,487`, `aborts=0`), having accumulated **6,059,894 wait
cycles, ~100 % `wait_sb`** — the resident hart's scoreboard never
reached empty for ~6 M cycles while both of core 0's harts retired
almost nothing after ~18 M (`ret={663,545, 489,197}`; core 1's dominant
hart completed the boot-side work at 18,269,699). The drain protocol
has no timeout/force path and issue is not held while a drain pends, so
a resident hart that parks (wfi/idle) or stalls holding scoreboard
entries starves the pending drain indefinitely — consistent with the
M3-era "ring > 8 times out" observations now that the harness artifact
is eliminated. **Ring 32 fails the ≤-anchor bar and is not adopted**;
the stuck-drain mechanism is the recorded residual (an r16 model can in
principle expose the same protocol hole — drain waiting on a
non-emptying scoreboard has no bound at any depth — but ring 16 is
proven deterministic and faster on every gate we ran: three identical
boots + the mixed boot + kernels + FO4).

### T10f — N1c: bounded-drain force landed; ring-32 boot shows it never arms; ring 32 rejected (2026-09-30)



`SmtDrainForceCycles` (256, 0=never, pow2-or-0 in `check_cfg`) with the
force FSM, hart-scoped controller flush, PC-bank restore, `[smt-drain]`
`force`/`force_wfi` counters, PMU group-3 events, the SymbiYosys
bounded-switch property + noforce mutation, and the never-commits review
leaf — all committed and green (89158748). Gates all pass (int2_l3
29w/43w, smt2_ooo_int 29w/2w, smt2 10w/31w, defaults 9+55w/5+32w, zero
errors); FO4 `sparse_smt_mixed_commit` at ring 32 = 31.0 ≤ 32 and
`g6lc_thread_select` alone = 23.0.



**Inert paths are byte-identical (the adoption-preserving evidence).**
Ring-16 `int2_l3` strict boot PASS at 18,297,381 (`strictDualPassed`,
force=0 both cores; RVFI hart00 `3a865954…` / hart02 `d7c2f025…`
byte-identical to N1b). `smt2_ooo_int` mixed ring-16 boot PASS at
10,459,588, force-inert, RVFI `9eada327…` byte-identical. `g6lc64_smt2`
in-order anchor boot PASS at 12,406,259, force=0, RVFI `e0858842…`
byte-identical — the shared `g6lc_thread_select` change does not perturb
any adopted profile.



**Ring 32 — the bound did not fire.**
`ooocoh-n1c-int2l3-r32-24M-L0-r3` (model `39cb6d28`): `timedOut`,
`outcome=timeout` (the `SUCCESS after 24000000 cycles` line is the
firmware cap print, not strict dual completion). `[smt-drain]` FINAL:
core 0 `req=23,610 / switches=23,610`, `force=0`; core 1 `req=20,771 /
switches=20,770` — one drain pending from ~17.73 M, `drain_cyc=6,068,793`
(~100 % `wait_sb`, `wait_st=356`), `force=0`, `force_wfi=0`, core-1 harts
frozen at `ret={430,924, 429,949}` from ~20 M on.



**Why the force never armed (mechanism, from code + counters).** The
counter saturates at `DF_MAX` and core 1 retired nothing for the last
~4 M cycles, so the no-commit threshold was armed the whole time; what
held it off was the head/killable conjunction, not the count. Two
structural masks are verified reachable and both produce exactly this
signature (which one applied needs an instrumented run): (a) the fire leg
`head_wfi_i || (cnt==MAX && head_plain_i)` — both head terms require
`commit_instr_i[0].valid`, and under `COH_OOO` the commit head's valid is
masked by `phys_pending_i[slot]` (an LSQ load whose address never
resolved), `phys_mod_i && fu==LOAD`, or a `cancelled` entry; a wedged
uncommittable head keeps `wait_sb` high (the entry is still `issued`)
while both head terms read 0 forever. The frozen hart's RVFI tail ends
mid-`sbi_hsm` park sequence at 0x8000e9f6 (an `add`, i.e. the head after
it never committed), consistent with this. (b) `smt_drain_safe` requires
`sb_head_valid[smt_active_hart]` — if the scoreboard's remaining issued
entries belong to the *other* hart (orphans), `killable`=0 forever.
Secondary weakness regardless: `commit_i` resets the counter, so a
resident hart polling in a commit loop can hold the bound off
indefinitely — the counter is conditional, not absolute. The formal
envelope ties `commit_i=0`, `drain_killable_i=1`, `head_plain_i=1`; the
bounded-switch property is therefore proven only inside that caller-side
contract, and the failing boot sits outside it. **N1c's "bounded by
construction" claim does not hold in production integration; fix sketched
below (next dispatch), not landed.** Ring 32 stays rejected.



**Ring-32 kernel numbers** (positive runs, directed lanes):
`mc_branchy` 3,603,094 — exactly the M1d bound (negative arm 3,603,102
detected); `ooo_ilp_chain` 3,285 and `ooo_mem_dep` 3,505 pass but roughly
double ring-16 (1,493 / 1,812). Hypothesis for T10f/M3b: at ring 32 every
branch mispredict pays mark-and-drain recovery over a 32-deep window plus
32-slot rename-checkpoint pressure; these kernels are branch-dominated
and recovery-bound, so the deeper window doubles the penalty. That is a
mechanism hypothesis, not measured proof — but it is exactly the cost the
M3b fast-squash work would target, so M3b should include a ring-16-vs-32
recovery-cycle delta on these kernels before any re-evaluation.



**Decision (brief rule applied).** Ring 32 on `int2_l3` requires boot
≤ 18,297,381 AND branchy ≤ 3,603,094: branchy is equal but the boot
timed out — **ring 32 not adopted**. The ring-32 `smt2_ooo_int` mixed
boot was conditional on that adoption and was not run. Ring 16 remains
the production geometry on both packages.



**Next step (sketch, not implemented).** Fire the timeout leg on
`cnt==DF_MAX && drain_killable_i` without a head-class requirement
(head_valid or not), restart the hart from `sb_head_pc[active]` when a
live head exists else the banked NPC (the `|npc_alt_i` guard already
tolerates a zero head PC); make the timeout absolute (drop the commit
reset) or add a second absolute counter so a committing poll loop cannot
starve the bound; and expose `killable/head_valid/head_wfi/head_plain/
cnt` in `[smt-drain]` so the next stall print discriminates mask (a)
from (b) directly. Then re-run the ring-32 24M boot — it must complete
with `smt_drain_force>0`, and all ring-16/anchor boots must stay
byte-identical with force=0. **Implemented in T10g (below).**

### T10g — N1d: ring-32 wedge root causes (LSU/IQ/STB) + construction-grade drain bound (2026-09-30/10-01)

**Question.** T10f left two open items: *why* the ring-32 four-hart
boot parks a resident hart with an uncommittable head (`wait_sb` ~6 M
cycles, `force=0`), and how to make the N1c bound hold in production
integration. N1d attacks both — the causes first (so the force is a
safety net, not the mechanism the boot relies on), then the bound.

**Instrumentation (all `translate_off`, `+smt_stats`, bounded to 8 dumps
+ final).** `core/cva6.sv` `[smt-stall]`: when the resident hart retires
nothing for 65,536 cycles while a drain pends, dump the drain gate
fields (`kill/headv/hwfi/hplain/fcnt/forced`), the commit-head
classification (slot, pc, op/fu, `cvld/sbev/issued/canc/exv/repl`,
`ppend/pmod`, per-hart issued counts), load/store unit + LSU commit
handshake, WT miss-unit/wbuffer/adapter state, the speculative store
queue with per-entry owner/tid/cancel/live/page-offset match, and (OoO
targets only, own generate scope) dispatch/IQ occupancy + `csr_buffer`
table. `corev_apu/coherence/g6lc_coherence_hub.sv` `[coh-stall]` and
`corev_apu/l2_cache/g6lc_l2_{top,wtrk}.sv` `[l2-stall]` birth-stamp
AR/AW slots, MSHR fills, write/read tracker entries and the L2 FSM and
dump on a 65,536-cycle age. slang rejects task calls in `final`, so the
dump bodies are `function automatic void`.

**Root causes found (three, each with its own leaf + mutation).**

1. *Shared PTW fault kills a surviving load* (`core/load_unit.sv`,
   `core/cva6_mmu/cva6_mmu.sv`, `core/load_store_unit.sv`). At SEND_TAG
   `ex_i` is this load's own fault only when it comes from the MMU's
   registered-request path (misaligned / permission / PMP on
   `lsu_req_q`); the PTW-error branch (`ptw_active && !walking_instr &&
   ptw_error`) is broadcast to whoever is listening — a walk started by
   an entry that was since cancelled (no flush under OoO cancel) or by
   the other LSU client faults while a DTLB-hit load sits in SEND_TAG.
   The old unconditional kill dropped that load silently (bypass entry
   already popped, no result, no `phys_valid`, no cancel) and
   `phys_pending` masked the commit head forever. Fix: `cva6_mmu`
   exports `lsu_exception_ptw_o`; the load unit kills on
   `ex_i.valid && (!ex_ptw_i || flush_i || cancelled)` — own faults kill
   and write back exactly as upstream, a foreign PTW fault neither
   kills nor attaches (`ex_o.valid` at SEND_TAG is gated `!ex_ptw_i`).
   `phys_valid_o` publishes on any delivered tag. **The first N1d cut
   (uncommitted) had dropped the kill for every live load and weakened
   leaf scenario 20 to pass — that would have lost a live load's own
   page fault (Linux demand paging); reverted here.** New assertion
   `send_tag_kill_rvalid` pins the dummy-rvalid contract the exception
   writeback relies on; `offset_misaligned` now covers FLD/FLW/FLH and
   the HLV loads the LSU actually flags misaligned.
2. *csr_buffer credit circle* (`core/ooo/g6lc_iq.sv`). Two younger CSR
   ops could take both `csr_buffer` credits ahead of an older CSR still
   waiting on its operand (the OpenSBI CSR probe burst at `0x8000e9fa`);
   the older one can then never issue (`csr_ready_i` low), its
   `sbe.valid` never sets, the head never validates, and the buffered
   youngers can never commit. Rule: a CSR issues only when no older CSR
   is resident in the IQ (`older_csr_iq`, age matrix), pinned by the
   `ooo_iq_csr_order` assertion.
3. *Speculative-store stall circular with an unpublished head*
   (`core/store_buffer.sv` + `head_phys_pending` plumbed
   issue_stage→cva6→ex_stage→load_store_unit→store_unit). A younger load
   parked in WAIT_PAGE_OFFSET behind an older speculative store occupies
   the load unit; the head load cannot publish its PA through the same
   LSU, so the store can never commit and the load can never leave.
   While the port-0 head is `phys_pending`, the speculative
   page-offset stall terms are released (`spec_stall_futile`); the
   committed-queue and sticky terms still gate. Soundness: the released
   load publishes its PA at SEND_TAG and `g6lc_lsq` replays it against
   any older same-hart store already resolved on the physical channel
   (LSQ leaf scenario 36 pins that path). Constant 0 outside `COH_OOO`.

**Bound made construction-grade (T10f next step)** — `core/cva6.sv`,
`core/smt/g6lc_thread_select.sv`. (a) `smt_head_plain`/`smt_head_wfi`
classify the head *entry* (`sb_head_valid[active]` + op/fu/ex class),
not the masked `commit_instr[0].valid`, so a phys-pending/phys-mod/
cancelled head no longer holds the force off. (b) A second, absolute
counter (`DF_ABS_MAX = 16 * SmtDrainForceCycles`, derived localparam,
disabled with the knob) counts every `pending && !ready` cycle, is not
reset by `commit_i`, and fires the force at the bound while the head
is plain — a committing poll loop can no longer starve the relative
leg. (c) One force pulse per pending drain (`drain_issued_q`): the new
`abs` proof produced a real counterexample — under a sustained commit
stream the P1b race clause dropped `drain_forced_q` every pulse cycle
and the force re-fired every other cycle, re-pulsing `flush_ctrl_id`
so `drain_ready` could never rise. `drain_force_abs_o` → `[smt-drain]`
`force_abs` + PMU group-3 event 8; the 1M/final prints now carry
`kill/headv/hwfi/hplain/fcnt/acnt`.

**Also repaired (HEAD lint, not N1d):** `g6lc_ooo_dispatch`
`commit_is_fpr`/`commit_arch` used before declaration; `g6lc_cluster`
`core_sb_gnt` likewise; `g6lc_ai_enq_arb.sv` missing from
`Flist.cluster` and the ten `verif/tb/apu/run-cva6-*.sh` compile lists;
five unconnected `ai_*` pins on `g6lc_cluster_lint_top`.

**Local evidence.** Lint 0 errors (Verilator + slang) on
`g6lc64_ooo_int2_l3`, `g6lc64_smt2`, `g6lc64_smt2_ooo_int`,
`cv64a6_imafdc_sv39`. Leaves (WSL Verilator, runner recipes):
load-cancel 13,16–24 pos/neg + `G6LC_MUT_LSU_EXKILL`→`LOAD_EXKILL_TAG`;
IQ 0–11 at (2,8)/(2,16) incl. scenario 11 `IQ_CSR_ORDER`; store-recovery
0–9 + `G6LC_MUT_STB_NO_HEAD_GATE`→`STB_HEAD_GATE`; LSQ physical 25–36
(36 negative → `LSQ_PHYSICAL`); `smt_drainforce` 0–3 + noforce →
`SMT_DFORCE_TIMEOUT`; `smt_drain` 4 geometries × 2. Formal
`core/smt/formal/g6lc_thread_select.sby`: `prove`, `cover`, `abs`
(bounded within `16·FORCE + K` under free commits), `abs_cover` PASS;
`mut_noforce` and `abs_noforce` FAIL as designed.

**Remote evidence (tags `ooocoh-n1d-*`, logs `remote-runs/<tag>/output`).**

- *Gates* (lint + synth `check -assert`, 0 errors): int2_l3 31w/43w,
  smt2_ooo_int 29w/2w, smt2 11w/31w, defaults 9+55w/5+32w — T10f +2/+1
  SELRANGE from the extended `[smt-drain]` print (`ss_retired[2..3]` on
  two-hart cores); the observer array is now padded to four entries
  (local lint 0e on int2_l3/smt2); remote re-gate owed with the reruns.
- *Leaves* (runner-native): `leaf-phys` 18/18 (load-cancel 16–24
  pos+neg), `leaf-exkill` mutation detected, `leaf-full` 60/60,
  `iq-default` 122/122 (IQ 80 incl. scenario 11), `iq-csrorder` 31/31,
  `stb-review` 44/44 incl. `STB_HEAD_GATE`, `stb-mut` detected,
  `lsq-phys` 24/24 (25–36, scenario 36 pos+neg), `lsqhart` PASS,
  `drainleaf` PASS + noforce detected, `ageformal` prove/cover matched.
  Remote sby could not run (no `yices`; z3 starves) — the local WSL
  verdicts stand.
- *Anchors unchanged*: `smt2_ooo_int` mixed r16 **10,459,588** (RVFI
  `9eada327…` byte-identical); `g6lc64_smt2` **12,406,259** (RVFI
  `e0858842…` byte-identical, `force=0 acnt=0`); `g6lc64_ooo_int2`
  17,870,562 (RVFI hart00 `22ed7d44…` byte-identical to M4; the +1 in
  the SUCCESS print is the `+smt_stats` observer's final-block
  ordering, not retirement).
- *FP (FP-1)*: FP suite on the int2_l3 FP r16 model **11 positives +
  11 negatives all `qualified` / `retirementsMatch`** (the suite's .S
  defines stages 1–11; T9g's "13" counted two `#error` stages);
  `mc_fp_smt` positive 3,777 (anchor 3,774) / negative detected 961.
- *Directed*: `mc_branchy` r16 3,603,105 (+11 vs M1d, negative arm
  detected); `ooo_ilp_chain` 1,345 (−148 vs 1,493); `ooo_mem_dep` 1,759
  (−53 vs 1,812) — attribution in the addendum below.
- *FO4* (sv-timing, budget 32): `sparse_ooo_issue` **24.0** (was 30.0 —
  the dispatch cone, not the new `older_csr_iq` scan, dominates);
  `sparse_issue_lsu` **32.0** closes (the pre-existing store_unit↔
  store_buffer bridge screened 39.5/66.0 open before); `sparse_smt_mixed_
  commit` r16 31.0 (unchanged); `g6lc_thread_select` alone 23.0
  (unchanged — the absolute counter adds no FO4).
- *Boots*: see the addendum.

**First boot pass (r8/r3) and the WFI-leg correction.** With
`smt_head_wfi` also read from the unmasked entry, the ring-32 24M boot
**PASSED at 18,338,093 cycles** (`strictDualPassed`, T10f: timeout) with
`force=4`, all `force_wfi`, `force_abs=0` — but the ring-16 boot also
fired `force_wfi` 3× and landed at 18,297,719 (+338, RVFI no longer
`3a865954…`/`d7c2f025…`). A WFI head is never phys-masked and the drain
resolves on its own once it commits, so the early force was gratuitous;
the WFI leg went back to the completed-head form (`commit_instr[0].valid`)
and only the plain leg classifies the unmasked entry. **Owed at this
checkpoint (not yet run):** ring-32 int2_l3 24M rerun on the corrected
tree (`…-r32-24M-L0-r9`; a pass with `force=0` proves the three
root-cause fixes alone resolve the T10f wedge, a pass with
`force_abs>0` proves the bound), ring-16 int2_l3 byte-identity rerun
(`…-r16-24M-L0-r4`, expect 18,297,381 / `3a865954…` / `d7c2f025…`),
and the `G6LC_MUT_STB_NO_HEAD_GATE` kernel control that attributes the
`ooo_ilp_chain` −148 / `ooo_mem_dep` −53 / `mc_branchy` +11 deltas.
Ring 32 remains **not adopted** until r9 lands; ring 16 stays the
production geometry.

**Addendum — reruns on the WFI-corrected tree.**

- *r9/r4 (WFI leg on the completed head, 9162ea506):* ring-32 PASS at
  **18,338,093** again — bit-identical cycles, `[smt-drain]` and
  retirement vectors to r8 — and ring-16 at 18,297,733 with the same 3
  `force_wfi`. So the E1 class change was not what fired the WFI leg.
  Root cause: the T10g gate restructure had dropped `!commit_i` from the
  WFI leg (N1c: `!commit_i && (head_wfi || …)`), so a WFI committing in
  that very cycle — after which the hart halts and the drain resolves
  by itself — was force-flushed. `!commit_i` restored on the WFI and
  relative legs; the absolute leg alone is commit-independent.
- *Kernel attribution (`G6LC_MUT_STB_NO_HEAD_GATE` r16 model
  `068678dc`):* `mc_branchy` 3,603,095 with the mutant vs 3,603,105 N1d
  → the +11 vs M1d is the store-buffer head-gate release (a liveness
  release, kept); `ooo_ilp_chain` 1,345 and `ooo_mem_dep` 1,759 are
  unchanged by the mutant → the −148/−53 improvements come from the
  other N1d paths (CSR age order / kill / LSQ), not the head gate.
- *r10/r5 (`!commit_i` restored on the WFI leg; models r16 `c5ef0059`,
  r32 `92a39816`):* **ring-32 int2_l3 24M PASS at 18,338,328,
  `strictDualPassed`, `force=0 force_wfi=0 force_abs=0 acnt=0` on both
  cores** — the three root-cause fixes alone resolve the T10f wedge;
  the drain bound is a never-firing backstop on this workload (the
  absolute counter never approached its limit). Ring-16 int2_l3 PASS
  at **18,297,379** (−2 vs the N1b anchor 18,297,381), `force=0` both
  cores, RVFI hart00 `5056e553…` / hart02 `c3406211…`. Byte-identity
  with N1b is **not expected**: the CSR age-order rule reorders issue
  on every OpenSBI CSR burst and the head gate releases real stalls, so
  the fixes are not inert on this boot (−2 cycles, retirement reorders
  and one interrupt-service block shifted in a 31.9 M-line trace;
  instruction streams otherwise identical). The ring-16 anchor is
  **re-baselined to 18,297,379 / `5056e553…` / `c3406211…`**
  (determinism of the tree: the r3/r4 pair on the previous cut was
  byte-identical). The `smt2_ooo_int`, `smt2` and `int2` anchors
  remain byte-identical (above). Local sby all tasks PASS / noforce×2
  FAIL after the gate change; lint 0e; remote int2_l3 lint 29w/0e.

**Decision.** Ring 32 now *boots* but at 18,338,328 > 18,297,379
(+0.22 %) it still fails the ≤-anchor bar, and T10f's ring-32 kernel
numbers (ilp/memdep ~2× ring 16) stand until M3b lands fast-squash —
**ring 32 not adopted; ring 16 stays the production geometry.** The
M7/M3b reopen preconditions (T9j) are unchanged except that the
"stuck-drain hole" precondition is now closed by T10g.

**Store unit note (audit, not fixed).** `store_unit` consumes `ex_i`
whenever `state_q != IDLE` without provenance; the PTW-broadcast
exposure is not reachable there today (a store translating holds the
bypass head, so no other data walk can be pending), but the seam is
recorded for the mixed-residency work.

### T11 — FP-2: FP under mixed residency — the hart-tagged FP context (2026-10-01)

**Scope.** Close the M4 residual "mixed-residency FP (hart-tagged lazy-FS
audit)" and decide the `G6LC_OOO_FP_QUALIFY` guard.

**Audit (what already held).** Decode selects `fs`/`vfs`/`frm` per lane
hart (`SMT_MIXED_DECODE`, T6b-3a); `dirty_fp_state` and `fflags` are routed
by the committing hart (`g6lc_smt_csr_bank` `commit_sel`); the FPU never
retires cross-hart on commit port 1 (T6b-4b); `g6lc_rename` keeps per-hart
FP maps/pools/checkpoints (Phase 4). **The one defect:** the FPU's dynamic
rounding mode and Xf precision were the ACTIVE hart's — `ex_stage.fpu_frm_i`
← bank `frm_o`, `fpu_prec_i` ← `fprec_o` — while `fpu_wrap` latches
`fpu_rm_d = fpu_frm_i` for `rm == DYN` at issue. Under mixed residency the
issuing op's hart may differ from the active hart, so a peer's `DYN` op was
rounded with the wrong `frm`. Inert on every production package (single
hart, or drained handoff ⇒ issuing hart == active hart).

**Fix.** `issue_read_operands` registers `fpu_hart_o` next to `fpu_rm_o`
(the hart of the FPU op accepted); `g6lc_smt_csr_bank` exports `fprec_b_o`
beside `frm_b_o`; `ex_stage` selects
`FPU_HART_CTX ? fpu_frm_b_i[fpu_hart_i] : fpu_frm_i` (same for `fprec`) with
`localparam FPU_HART_CTX = FpPresent && NrHarts > 1 && !SmtDrainedHandoff`,
so the mux constant-folds away wherever FPU ops can belong to only one
hart. Review mutation `G6LC_MUT_FPU_ACTIVE_FRM` restores the active-hart
scalar. Timing: `sparse_ex` screen (ex_stage/fpu_wrap/issue_read_operands,
`FPU_HART_CTX` live) worst FO4 **31.5 → 31.5** at budget 32 (+6 paths: the
3/7-bit hart mux and the `fpu_hart` register).

**Directed witness** `verif/tests/custom/multicore/mc_fp_mixed.S` (one
core × two co-resident harts): hart 0 `frm=RTZ`, hart 1 `frm=RUP`, both
loop `fadd.d(1.0, 2^-60, DYN)` ≥128× (exact 1.0 vs 1.0+ulp); fflags
isolation (hart 0 holds NX, hart 1 clears and reads 0); FS isolation
(hart 1 `FS=Off` → exactly one illegal-instruction trap, back to Clean with
no FP op, while hart 0 ends Dirty with no trap). Distinct codes per
hart/phase; `ORACLE_NEGATIVE` arm.

**Evidence (mixed FP model = `g6lc64_smt2_ooo_int` + RVF/RVD + int2_l3
FP/XF fields, tags `ooocoh-fp2-*`).**

- `mc_fp_mixed` positive **PASS 6,143 cycles**, `ORACLE_NEGATIVE` detected
  (code 3, 801 cycles); on `G6LC_MUT_FPU_ACTIVE_FRM` **FAILS code 7**
  (hart-1 rounding, 930 cycles) — the mutation detection is also the
  co-residency witness (hart 1's RUP ops issued inside hart 0's window).
  Identical results (6,143 / code 7 @ 930) on the define-free model after
  the guard lift (`…-nodef-r2`, `…-nodefmut-r1`).
- FP suite on the mixed FP model (`…-fpsuite-r1`): stages 1–10 positives
  retirement-exact, 11/11 negatives detected. **Stage 11 positive fails
  (`tohost=11`, 21,798 cycles) — pre-existing on the integer
  `g6lc64_smt2_ooo_int`**, not FP and not N1d: the same stage fails
  identically (22,020 cycles) on the pre-N1d baseline `3ef1a0789` and on
  HEAD, while it passes on `int2_l3`. s11 is the integer twin of stage 10
  (fence / LCG branch / wrong-path `divu` / 64 adds) built to partition a
  fetch-side committer-window loss; it is a mixed-residency finding owed
  its own ticket (`AGENTS-todo.md`). The rest of the frozen integer probe
  set (s4/s20/s32–s37, ilp, memdep) is **cycle-identical baseline vs
  HEAD** on `smt2_ooo_int` — the N1d tranche is cycle-inert on the
  single-core mixed profile.
- Mixed strict OpenSBI boot on the FP model (`…-smt2intfp-osbi-r4`,
  `rv64imafdc_zicsr_zifencei`): **`strictDualPassed`, 10,463,110 cycles**
  (+3,522 / +0.03 % vs the integer anchor 10,459,588 — FPU decode/CSR
  movement); `both_resident_cycles=97,405`,
  `cross_hart_port1_commits=11,879`, `hol_residual=2,740`.
- `mc_fp_smt` cannot run on this model (hard-coded four harts); it stays
  green on the four-hart `int2_l3` FP model (`ooocoh-n1d-fpsmt-r1`,
  3,777 cycles).
- Inertness: int2_l3 ring-16 24M boot **18,297,379 / `5056e553…` /
  `c3406211…` byte-identical**, `force=0`; local lint 0e on int2_l3,
  smt2_ooo_int, smt2, ooo; remote lint int2_l3 29w/0e, smt2_ooo_int
  29w/0e; synth `check -assert` clean (43w / 2w).

**Decision — guard lifted.** The `ifndef G6LC_OOO_FP_QUALIFY` leg of
`check_cfg` and `gen_err_ooo_fp_mh` in `g6lc_ooo_dispatch` are removed: FP
under mixed residency is legal on single-core packages (multi-core mixed
residency keeps `G6LC_OOO_SMT_MIXED_QUALIFY`, unchanged). No production
package carries mixed FP yet — `g6lc64_smt2_ooo_int` stays integer; an FP
variant is an adoption decision, not a legality one. The ten frozen
`core/*/formal/*/src/config_pkg.sv` snapshots still carry the old leg
(pinned evidence copies, deliberately untouched).

**Remaining FP-OoO.** `g6lc64_ooo_server` qualification (a COH_FILTERED /
four-core / 4-issue program, not an FP item — FP there is the drained leg
already legal; first findings in T12); the T5 core-level owner-mutation bar (the retention
mutation is caught by the S2 leaf and the `g6lc_ooo_fp_owner` proof; the
core-level inertness is structural at 32 scoreboard entries — recorded as
the bar); `ai-chain14` FP suite rerun on the clean tree (AI program).

### T12 — FP-3: `g6lc64_ooo_server` brought back to elaboration and to a drained handoff that holds (2026-10-01/02)

**Scope.** First look at the server profile (4 cores × 2 harts, 4-issue /
4-commit, `HPDCACHE_WT`, `COH_FILTERED`, `L3En=1`, drained handoff) since
the N1/FP work. Goal: establish where it stands, not to qualify it.

**Finding 1 — the target did not elaborate (pre-existing).** The N1
`[smt-stall]` dump (`252c698e8`, 2026-09-29) referenced
`gen_cache_wt.*` unconditionally inside `gen_smt_stats`; `gen_cache_wt`
exists only for `DCacheType == WT`, so every HPDCACHE drained target failed
with 10 `Can't find definition of 'gen_cache_wt'`. The server has been
lint-broken since, unnoticed because it is opt-in (`verify --target
g6lc64_ooo_server`). Fix: the WT miss-unit/wbuffer/adapter line moved into
its own `gen_wt_stall_probe` scope driven by the same `ss_dump_id` ticket as
`gen_ooo_stall_probe`. Lint 0e on the server (288v) and unchanged on the
anchors; the int2_l3 ring-16 `+smt_stats` boot prints the `dmu` line the
same number of times as before (11 `[smt-stall]` lines) at **18,297,379**.
Consequence recorded honestly: every "server" Verilator result that
predates `252c698e8` (the I4dp 200M harness green in `AGENTS-todo.md`) was
measured on a tree that no longer existed as a model.

**Finding 2 — `ooo_switch_drained` fired at the first non-cooperative
switch** (`[1300]`, reason `starve`, `forced=0`) on the server I4dp boot.
Bisect by package overlay (`ooocoh-fp3-server-ovl{a,b}-*`): 2-issue /
2-commit server still asserts identically (cycle 1362) — **not** the port
width; server with `DCacheType=WT` (`HwPrefetch` off, required by
`check_cfg`) runs 1,664 switches to the 50k cap with no assertion — **the
d-cache backend is the differentiator**. The failure-branch display
(`[ooo-switch-drained] … sbem=1 sbn=0 stp=0 lsqb=0 rob=0 iq=0 …`, read in
the reactive region) and the new `+smt_stats` tail counters
(`tail lsq=0 rob=0 iq=0 any=0` over 6 M server cycles and 24 M int2_l3
cycles) pin the conjunct: not the ROB/IQ/LSQ tail — they never outlive
`sb_empty` on either backend — but `no_st_pending_commit`, i.e.
`wbuffer_empty`. Mechanism (hpdcache_ctrl: `wbuf_write_o` is a **st1**
action, the wbuf entry is valid from the st1→st2 edge): a store granted on
the store port at N leaves the store-buffer commit queue at N→N+1 while
`wbuf_empty_o` stays 1 through N+1 — a one-cycle window in which the store
is in no monitor. WT has no window (the wbuffer registers at grant). The
drained-handoff decision landed in that window; the switch pulse one cycle
later saw the store.

**Fix (two seams).**
- `cva6_hpdcache_wrapper.sv`: `st_skid_q` registers
  `dcache_req_valid[store port] & ready`; `wbuffer_empty_o = wbuf_empty &
  ~st_skid_q`. Covers the st0→st1 skid exactly; a store parked in the
  replay table is ordered by the cache itself and is not a core-visible
  pending store. Also tightens `fence`/`fence.i` completion by that cycle on
  every HPDCACHE package (upstream `cv64a6_imafdc_sv39_hpdcache` lints
  261w/0e; the slang stage has 3 pre-existing Zacas index errors from
  `3801e8218`, unrelated).
- `drain_ready_i` gains `ooo_drained_id` (`g6lc_ooo_dispatch.ooo_drained_o =
  rob.empty_o && iq.empty_o && !lsq_busy`, constant 1 off the OoO path):
  the T6a contract is now stated at the seam the selector consumes rather
  than only in the witness assertion. Redundant on every measured
  workload (tail counters 0) but cheap (two `count_q == 0` compares already
  present, one AND) and it makes the contract construction-grade. FO4
  screens over the selector cone unchanged (23.0 → 23.0, mixed_r16 31.0 →
  31.0).
- *Rejected on the way*: an emission-time re-check inside
  `g6lc_thread_select` (`drain_emit_i`, suppressed-pulse rollback of
  `active_q`, a formal fairness **assumption**). It made the server boot
  by rejecting **every** drain at the emission edge (core 0: 1,772
  requests, 0 switches, 1,772 aborts; cores 1–3: ≈207 k each) — a
  selector that never switches is not a fix — and it weakened the
  `g6lc_thread_select` proofs with an assumption. Reverted; the selector
  and its sby/props are byte-identical to T10g.

**Evidence (`ooocoh-fp3*`).**
- Server I4dp 8-hart OpenSBI (`fp3e-server-i4dp-r2`, `+smt_stats`, 6 M
  cap): **`*** SUCCESS *** (tohost=0)` at 6,000,000 cycles, zero
  `ooo_switch_drained` assertions**; core 0 `req=1772 switches=1772
  aborts=0 force=1` (plain `SmtDrainForceCycles` expiry; `force_wfi=0`,
  `force_abs=0`), cores 1–3 ≈207,150 requests each, all switched, `force=0`;
  reason mix quantum 622,199 / starve 1,021 / miss 0 / yield 0; tail
  `0/0/0/0` on all cores. The 200 M-cycle I4dp cap is **not** re-run: the
  8-logical-hart model runs ≈640–1,100 cycles/s on the builder (24 M
  int2_l3 took 4,015 s), so 200 M is days — the 6 M evidence is what is
  recorded; the old 200 M green stands only as a historical note.
- Inertness: int2_l3 ring-16 24 M **18,297,379 / `5056e553…` /
  `c3406211…` byte-identical** (WT — the wrapper is not elaborated),
  `force=0`; local lint 0e on server / int2_l3 / smt2_ooo_int / smt2 / ooo;
  remote lint int2_l3 29w/0e, server 36w/0e; remote synth int2_l3
  `check -assert` clean 43w. Leaves: `smt_drain` 8/8, `smt_drainforce`
  4/4, `review_iq` 80/80, `tb_g6lc_rob` (+mutant caught), dispatch TBs
  36/36; sby `g6lc_thread_select` prove/cover/abs/abs_cover PASS,
  noforce ×2 FAIL as designed; `g6lc_ooo_rob` PASS.
- Server synth: `run_cluster_synth_review.py` 10/10 uncore tops pass
  (coh_hub 2,151 c, snoop 582 c, l2_top 4,699 c, l3_top 7,787 c; 0
  latches) in 255 s — this runner never elaborates the cva6 subtree, so it
  is not core evidence; the core-level server synthesis is still owed.
- Build note: Verilator 5.008 mis-splits `__Vilp` loop variables across
  `DepSet` chunks on this model (58 TUs); the remote builds patch the
  generated C++ (`static IData __Vilp;`) and compile `__Syms.cpp` at -O1.
  Generated-code workaround only, no RTL/config change; a `.vlt`/make-level
  form is owed if the server becomes a routine target.

**FP on the server model (not qualified).** `mc_fp_smt` positive
`held-secondary` (harts 4–7 parked under `BOOT_HOLD`; the test is written
for four harts), negative detected. FP suite s1/s4 positives pass
functionally but **`retirementsMatch=false` at index 2** — root cause is
an RVFI probe gap, not FP: `cva6_rvfi.sv` stages `issue_q` instruction
encodings for ports 0 and `NrIssuePorts-1` only, so on a 4-issue model
dispatches on ports 1–2 carry `instr=0` (≈38 % of `trace_rvfi_hart_00.dasm`
rows). Retirement qualification cannot pass on any `NrIssuePorts > 2`
model until the probe is widened (tracked in `AGENTS-todo.md`). s9/s10
hit the 2 M cap without a verdict; negatives not run.

**Status.** `g6lc64_ooo_server` elaborates, lints, and runs its 8-hart
firmware boot to 6 M cycles with the drained handoff holding by
construction. It remains **opt-in / unqualified**: owed are the core-level
synthesis, the RVFI 4-issue probe, a server-sized FP/`mc_fp_smt` variant
(8 harts), the `COH_FILTERED` qualification program, and a Linux-class
boot on a faster host or FPGA.

**T12 addendum (2026-10-02) — probe and harness follow-through.**

- *RVFI instruction capture is per-port now.* `cva6_rvfi.sv` modelled
  id_stage's ID→issue register with a two-slot shuffle written for
  `NrIssuePorts == 2`; on the 4-issue server ≈38 % of RVFI rows carried
  `instr=0` and Spike retirement comparison failed at index 2. The encoding
  and RVC flag now ride inside id_stage's `issue_struct_t` (`rvfi_instr`,
  `rvfi_is_compressed`, set at every fill/splice, RVFI-only → pruned in
  synthesis) and reach the probe issue-aligned (`rvfi_instr_o`); the RVFI
  shuffle model is deleted. Equivalence: int2_l3 ring-16 24 M **18,297,379,
  RVFI `5056e553…`/`c3406211…` byte-identical** — the new capture equals the
  old model wherever the old one was right. Server FP suite s1/s4:
  **`retirementsMatch=true`, `qualified=true`** (`ooocoh-rvfi-server-fpsuite-r1`).
- *`mc_fp_smt` on eight logical harts.* `-DMC_FP_SMT_NHARTS=8` releases
  harts 4–7 like the inner four and parks them, so the all-cores-retired
  verdict is reachable on the server: positive **pass 7,062 cycles**, all
  four cores retired, negative detected (`ooocoh-rvfi-server-fpsmt8-r2`).
  Default-4 image byte-identical.
- *`mc_fp_smt` anchor re-baselined 3,777 → **3,831** on the int2_l3 FP
  model.* Attributed to the FP-3 `ooo_drained` conjunct in `drain_ready_i`
  (the FP-3e model, pre-RVFI, already gives 3,831; the RVFI change is
  cycle-neutral). On this directed test the ROB/IQ/LSQ tail does outlive
  `sb_empty` at some drained switches — the OpenSBI boots showed none — so
  the conjunct is not purely redundant; which term, and how often, is the
  next data point (`+smt_stats` tail counters on the test).
- *Slang Zacas index errors* (`issue_read_operands.sv` CASQ pair-high
  `raddr_pack[2]`/`rdata[2]` on two-operand regfiles) clamped by
  `CASQ_HI_IDX` under the existing `OPERANDS_PER_INSTR == 3` guard;
  `cv64a6_imafdc_sv39_hpdcache` slang stage passes.
- *`ai-chain14` rerun on the clean tree* (`ai14-suite-r1`, HEAD
  `e905b07c7`, `work-ver-ai` rebuilt): **34/36 pass**, controls valid, the
  nine cycle-15 deaths of the void run **do not reproduce**. Two real
  fails, both pre-existing trap-loops (`cause=2` illegal instruction):
  `mini_ai_dual_issue` @ `0x8000007a` (also failed in chain9) and
  `ai_illegal_when_off` @ `0x8000003c`. Seven-format cold decode
  (`ai14-bench-r2`) 7/7, fmt0 33,880 … fmt7 134,425 cycles, width-scaled.
  AI-program items from here.
- *Core-level server synthesis, one attempt.* `verify --synth --remote
  --target g6lc64_ooo_server` first dies in slang (`g6lc_iq.sv:238` unroll
  limit 4000 — `NR_SB_ENTRIES=64` × IQ depth; tool limit); with
  `--unroll-limit=262144` elaboration, `hierarchy -check` and `proc` are
  clean, then `opt -fast` dedup converges at ≈16 cells/min from 291,859
  cells and was cut at 5.9 h before `check -assert`/`stat`. The cluster
  top is not a practical synth unit for this profile; a core-only top (or
  a per-block budget) is the owed form.
- *s11 on `g6lc64_smt2_ooo_int` — mechanism located, fix pending.* Stock
  mixed profile FAIL (`tohost=11`, 22,020 cycles, RTL retires 5,495 vs
  Spike 5,263); the same ELF **passes on the drained overlay**
  (`SmtDrainedHandoff:1`, 21,763 cycles, retirement-exact) and on
  single-hart `g6lc64_ooo` (11,170). First divergence at index 50: RTL
  **re-retires** `remu @0x80000258` plus the six `c.addi` at
  `0x8000025c–0x80000266` — a 16-byte window, exactly one fetch parcel —
  and Spike continues at `0x80000268`. ≈95 backward-PC replay windows
  (64 `remu` retirements vs 32 `divu`), switches alternating every ≈66
  cycles (reason `starve`). Already-retired instructions re-fetched and
  re-executed on the non-drained path only: the mixed-residency restart
  frontier (hart switch beat and/or peer restart on a partial flush) names
  a parcel that was in fact delivered. Root cause and fix are T13.

### T13 — mixed-residency restart authority: switch-out frontier, not last retirement (2026-10-02)

**Defect.** `g6lc_smt_pc_bank` under `G6LC_FETCH_B` fed every hart's bank
from *retirements* (pc+4 / predicted target) and ignored the switch-time
frontier (`npc_live_i`, computed by `gen_smt_restart_frontier`, was a dead
input). Under the drained handoff that is exact: the scoreboard is empty at
every switch, so the last retirement's successor is the next architectural
instruction. Under mixed residency the switch kills IF/ID but the outgoing
hart's scoreboard entries survive; if the hart is re-activated while it
still holds live entries, the bank names the successor of its *last
retirement* and the frontend refetches its still-live tail. s11 is the
exact shape: a 64-cycle `divu` at the commit head stalls hart 0 → the
selector switches away (`starve`) → the `divu` retires → hart 0 is
re-activated with bank = `divu+4` while `remu` and six `c.addi` are live →
all seven retire twice (T12 addendum: 64 `remu` vs 32 `divu`). A
correctness defect on the production mixed profile `g6lc64_smt2_ooo_int`,
masked on OpenSBI by its instruction mix.

**Fix (three seams).**
- *Bank authority* (`g6lc_smt_pc_bank.sv`): drained keeps the retirement
  authority; mixed banks the switch-out frontier on `switch_i` and never
  lets an inactive hart's retirements move it; redirects (own trap/set_pc,
  inactive-hart mispredict and peer restart on port 2, N1c `npc_alt`) still
  win. Review mutation `G6LC_MUT_PCBANK_RETIRE_MIXED` restores the old
  writes under mixed.
- *Instruction-granular tail* (`cva6.sv` `gen_switch_tail`): the
  window-aligned fetch frontier (redirect pend / in-flight parcel / NPC
  cursor) is not a legal restart PC — it can land inside a window-crossing
  instruction (m34–m36 restarted at `0x80000200`/`0x800007c0`, `cause=2`).
  The mixed frontier is therefore the next PC after the hart's youngest
  *dispatched* instruction (`bp.predict_address` for a CF with
  `bp.cf != NoCF`, else `pc + ilen`), re-armed by commit-side redirects and
  resolved mispredicts, invalidated by a full flush (the commit redirect
  already in the bank then owns the restart until the next dispatch). The
  oldest undelivered pre-dispatch entry of the outgoing hart (per-hart
  pending-FIFO head `queue_oldest_pc`, then the ID ports) overrides it,
  and a same-cycle mispredict of the outgoing hart overrides both. The
  not-taken-CF gate is the m33 fix: a not-taken `bnez` carried a stale
  `predict_address` (`0x8000010a`, the peer's park loop) and armed hart 0's
  tail with the peer's code.
- *Fetch response ownership* (`fetch_B/frontend.sv`): identity is now
  token **+ requester hart + requested window**, all registered at accept
  (kill-cycle accepts included) and used both for `kill_drop` and for
  discharging the want. The hart conjunct kills a response that crossed a
  switch (that stream is dead: the restart frontier assumes nothing of it
  survives pre-dispatch); the window conjunct defeats a 2-bit token alias.
  Strictly tighter than the old token-only rule; `[fetch-own] drop` is the
  translate_off leak witness. **Zero drops on every run below** — the
  operative m33 failure was the tail arm, not an observed ownership leak;
  the triple rule is defence in depth and is provably inert on the anchors.

**Evidence (`ooocoh-t13c-*`, smt2_ooo_int models from this tree).**
- s11 **PASS 18,444 cycles, retirement-exact vs Spike**; on
  `G6LC_MUT_PCBANK_RETIRE_MIXED` it **fails `tohost=11` at 22,020** again.
- Frozen integer set all PASS: m4 2,015 / m20 1,941 / m32 1,914 /
  **m33 1,957** (was 2,020) / m34 1,915 / m35 1,926 / m36 1,926 /
  m37 1,921 / ilp 1,243 / memdep 1,152 (ilp/dep +18 vs T12 — restart
  frontier moved by the tail rule; retirement-exact).
- Mixed FP model: FP suite **22/22** (s11 included); `mc_fp_mixed`
  6,143 / negative detected. T6b mixed probe `RES0=0x1 RES1=0x1` at
  3,064,005; negative detected.
- `smt2_ooo_int` strict OpenSBI `+smt_mixed_stats`: **`strictDualPassed`,
  10,459,588 — cycle-exact with the pre-T13 anchor** (`both_resident_cycles`
  97,358, `cross_hart_port1_commits` 11,879, `[fetch-own]` 0) — the boot
  never re-activated a hart with a live tail, which is why it never showed
  the defect.
- Drained inertness (bank authority unchanged; ownership rule live):
  int2_l3 ring-16 24 M **18,297,379 / `5056e553…` / `c3406211…`
  byte-identical**; `g6lc64_smt2` strict **12,406,273** = the contemporary
  N1d reference run (`…-smt2-osbi-L0-r6`; the 12,406,259 figure is the
  older anchor — that +14 predates T13). `[fetch-own]` 0 on both.
- Leaves/formal: `tb_g6lc_restart` mixed scenarios (frontier banked on
  switch-out, inactive retirements ignored, redirect2 wins, same-cycle
  primary redirect wins, drained unchanged) PASS and the mutation arm
  fails; `g6lc_fetch_restore` / `g6lc_fetch_hold` PASS,
  `g6lc_fetch_smt` prove + cover PASS; lint 0e on smt2_ooo_int, smt2,
  int2_l3, ooo_server, ooo, `cv64a6_imafdc_sv39`.
- Side data point (FP-3 follow-through): `mc_fp_smt` `+smt_stats` on the
  int2_l3 FP model — `tail lsq=0 rob=0 iq=0 any=0`, `wait_sb` 312–334
  vs `wait_st` ≤ 3: the 3,777 → 3,831 delta is the store-buffer drain leg
  of the full `drain_ready` contract, not the `ooo_drained` conjunct.

**Timing.** The tail is one per-hart VLEN register written from the issue
ports (NrIssuePorts-way mux) and the bank's switch-out write replaces a
retirement write of the same width; the ownership rule adds a hart compare
and a window compare to `kill_drop` (both registered operands). No screen
changed; the frontier/bank path is not on a screened cone.

**T14 (2026-10-02) — server synthesis tooling, honest result.** `verify
--synth` gained per-target synth tops and `read_slang` arguments
(`synthTopByTarget`, `synthSlangArgsByTarget`; `g6lc64_ooo_server` →
core-only `cva6`, `--unroll-limit=262144`). With them the server elaborates,
`hierarchy -check` and `proc` are clean, and `opt -fast` converges… at
≈11 merges/min inside `4.2 OPT_MERGE` from 273,783 cells — cut at the 6 h
cap before `check -assert`/`stat`, exactly as the 292 k-cell cluster top
was. The dedup wall is in the per-core structure of this profile (64
scoreboard entries × 4 issue ports), not in cluster replication, so the
server's core-level synthesis closure needs a different pass recipe (skip
`opt_merge` for this target, or a per-block budget), not a smaller top.
`g6lc64_ooo_int2_l3` synth is unchanged (43 w, 1,329 s). The Verilator
5.008 `__Vilp` split-cfuncs workaround used for every server model is now
a documented helper, `verif/regress/remote/patch_vilp.sh`.

**T15 (2026-10-02/03) — server smoke policy, first COH_FILTERED evidence, AI trap-loops.**

- *Server synthesis smoke.* `verify.synthPassesByTarget` replaces the pass
  tail per target. On `g6lc64_ooo_server` even `proc; opt_clean; check
  -assert` is infeasible on the 125 GB builder: the full check on the
  un-merged 287 k-cell netlist falls back to the bit-level loop `TopoSort`
  and is **OOM-killed at 118 GB** (17,188 s). The server smoke is therefore
  `proc; opt_clean; stat; check -latchonly -assert` — **286,763 cells,
  `$dlatch` 0, `$sr` 0, latch check clean, 2,934 s, 99.5 GB peak**; the
  loop/driver check for this profile is owed on a larger host. int2_l3 is
  unchanged (43 w clean, default passes).
- *First `COH_FILTERED` directed evidence* (server model
  `ooocoh-coh4-build-r1`, 4 cores × 2 harts, ≈930 cycles/s): cross-core
  `mc_shared_line_coherence` with `PEER_HART` 2 / 4 / 6 (cores 1–3 under
  the filter) **pass, negatives detected** (1,563 cycles each; sibling
  `PEER_HART=1` 1,340); `mc_cbo_ewt` cross-core pass/neg (120,448 /
  120,168); `mc_cas_lock_handoff` pass (16 AMOCAS); `mc_store_load_new_line`
  pass/neg; `mc_hart1_store_visible`, `mc_shared_line_quiet`,
  `mc_two_inval_backpressure`, `mc_inval_bp_stress` pass — but these four
  have no peer knob and so exercise the SMT sibling (shared L1), not the
  hub. Harness note: `REVIEW_MC_DIRECTED_MASK=11` means "all cores" on a
  four-core model (mask width), use `0011`.
- *New server defect — the fourth consumed L1-missing load never retires.*
  `mc_l2_write_read`, `mc_l3_stride_scan` and `mc_shared_line_resident`
  **hang** (exit 126, no exception, no tohost) at the 4th consecutive
  L1-missing load whose result is consumed: l2wr `ld @0x8000004c` →
  `0x801000c0` after `0x80100000/40/80` completed (cycle 14,954); l3scan
  the same addresses at 49,769; slres `ld @0x800000ec` → `0x800a0bc0`
  after `0x800a0000/940/280` (323,560). Reproducible 3/3 at 800 k and
  6 M cycles; the same walk with dead loads (`mc_inval_bp_stress`, 4,096
  misses) passes, and l2wr/l3scan pass on int2_l3. Bisection axes are the
  int2_l3 → server deltas: `HPDCACHE_WT` (vs WT), `NrLoadBufEntries 24` /
  `DcacheIdWidth 5`, `HwPrefetchEn` (4 streams), `NrIssuePorts 4`.
  Tracked in `AGENTS-todo.md`; T16.
- *AI-island trap-loops explained and fixed (test-side).*
  `ai_illegal_when_off` and `mini_ai_dual_issue` took their *expected*
  illegal-instruction trap, but `trap_vec:` followed a 2-byte `c.j .`
  under `-march=rv64imafdc_zicsr`, landing on an odd halfword; `mtvec`
  drops bit 1 (`csr_regfile.sv`: `{wdata[XLEN-1:2], 1'b0, …}`), so the
  trap vectored into the preceding self-loop forever. `.balign 4` before
  `trap_vec:` in both: `ai_illegal_when_off` **SUCCESS 491 cycles**,
  `mini_ai_dual_issue` **SUCCESS 1,116 cycles** (A/B on the same model;
  unfixed arms spin at `0x80000088` / `0x800000b8`). Not an AiCfg or core
  defect; `ai-chain14` is 36/36 modulo this fix.

### T16 — HPDCACHE MSHR geometry: non-power-of-two set count misrouted refills (2026-10-03)

**Defect.** `cva6_hpdcache_subsystem.sv` derived `mshrSets = NrLoadBufEntries/2`
and `mshrWays = 2` for `NrLoadBufEntries ≥ 16`; the server's 24 entries gave
**12 sets**. HPDcache indexes the MSHR with `nline[0 +: $clog2(sets)]` (4 bits)
and sizes its RAM at exactly `sets` words, so every line whose low nline bits
are 12..15 — one 64 B line in four — allocated a set that does not exist: the
entry write was dropped and the refill ack read RAM word 0 (set 0's entry),
i.e. another miss's tid. With two misses outstanding, the younger load retired
with the older load's line and the older never completed. Bisect (`ooocoh-t16-v*`,
`mc_l2_write_read`): WT PASS; prefetch-off HANG (cycle-identical — the stride
engines are tied off anyway); 2-issue HANG (cycle-identical); `NrLoadBufEntries`
8 → PASS, 32 → PASS (power-of-two set counts); int2_l3 + HPDCACHE (8 entries,
1×8) PASS. Anatomy (`+ld_trace`, `ooocoh-t16-probe`): 4th load tid 20 →
`alloc_set=12` → `MEM-RD id=12`; 5th load tid 26 → set 0; `MSHR-ACK id=12`
reads word 0 → `REFILL-RSP tid=3` → the 5th load writes back with the 4th's
data; slot 0 (tid 20) valid forever, SB head `pc=0x8000004c` never retires,
hpdcache `mshr_empty=1`. Verilator 5.008 returns element 0 on an out-of-range
read (5.020 returns 0 — would have hung differently, not passed). No HPDcache
assertion guards the geometry.

**Fix.** `mshrSets = 2 ** $clog2(NrLoadBufEntries / 2)` (server → 16 × 2;
`MEM_TID_WIDTH` 8 ≥ clog2(32)+1), `mshrSetsPerRam` follows, and a generate-time
`gen_err_mshr_geometry` `$error` refuses non-power-of-two sets or ways
(negative check: old formula + guard → slang exit 5 at the guard). Upstream
HPDCACHE packages (`NrLoadBufEntries=8` → 1 × 8) are untouched (lint A/B
identical, 260w/4s). A `+ld_trace` load round-trip anatomy probe
(translate_off, plusarg-gated) stays in `cva6.sv`.

**Evidence (`ooocoh-t16fix-*`, server model from this tree).**
- Former hangs **pass**: `mc_l2_write_read` **126,744** (= the 32-entry
  variant exactly), `mc_l3_stride_scan` **213,063**, `mc_shared_line_resident`
  **324,255**. COH4 sweep cycle-identical to T15 except two retirement-exact
  interleaving shifts (`mc_cas_lock_handoff` 4,262 vs 4,707 — lock-spin
  iterations; `mc_inval_bp_stress` 267,527 vs 267,759).
- FP suite s1/s4 `retirementsMatch=true`; `mc_fp_smt` 8-hart 7,061 / neg
  1,805 (RVFI multisets identical).
- **Correction to T12/FP-3e:** the 8-hart I4dp "`*** SUCCESS *** (tohost=0)`
  at the 6 M cap" was a **hung boot masked by the harness cap** — hart 1 (the
  lottery boot hart) took `cause=2` at cycle 54,100 from a non-text pc
  (`0x80046e40`, a corrupted load — this defect) inside `fw_platform_init`
  and parked in `_start_hang`; its retire count sat at 5,144 from 1 M to 6 M
  while the other seven harts spun in `_wait_for_boot_hart`. On the fixed
  model the boot hart is alive the whole run (848,809 retirements, ≈141 k per
  1 M, still in the libfdt DTB walk at 6 M, IPC ≈ 0.14 sharing core 0),
  **no trap, `force=0` on all cores**, tail 0/0/0/0. 6 M is simply too short
  for eight harts; a 24 M run (`ooocoh-t16fix-i4dp-24M`) was left running on
  the builder (≈8–10 h) — the result belongs in this section when harvested.
- Lint 0e: server 288w/4s, `cv64a6_imafdc_sv39_hpdcache{,_wb}` 260w/4s,
  int2_l3, smt2; remote int2_l3 29w/0e, server 36w/0e. The remote warning
  baselines are raised to 29 / 36 (the N1d `+smt_stats` dump WIDTH*
  warnings; the server count predates its elaboration break).

**Lesson for the record.** "tohost = 0 at the cycle cap" is not a boot
result; every server boot cited before this section must be read as
"did not fail before the cap", and the harness verdict text now has to be
checked for per-hart retirement progress before it is quoted.
