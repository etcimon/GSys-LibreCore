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

**Slices.** T6b-1 config bit + drain gate seam, hart-tagged LSQ/store-buffer/IQ ordering,
`sb_head_pc`, leaf oracles (drain gate still on: every existing result must reproduce). T6b-2
recovery and frontend per-hart state (flush restart, inactive-hart redirects, per-hart filter),
commit-side per-hart interrupt/CSR/WFI. T6b-3 the `SmtDrainedHandoff=0` firmware gate with the
concurrent-work probe and the isolation negatives. T6b-4 (performance, after exit) partitioned
heads and PRF floors.

## Deferred

Linux/compliance/liveness, STA/DFT/power sign-off, CASQ, PMU residuals, coherence/hierarchy/snoop,
FP widths beyond `FLen <= XLEN`, four-wide retirement, adaptive scheduling policy, early-termination
root cause (re-examined only if it recurs with the non-destructive proxy).
