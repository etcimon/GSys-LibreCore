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
hart 1's boot — artifact, not a core fault, to confirm). Decision pending: whether leaf-only
detection plus the structural argument meets the bar for removing the single-hart guard.

## T6 — mixed-resident SMT2

Per-hart commit heads (scoreboard/ROB), hart-tagged IQ/ROB/LSQ, per-hart STQ credits, shared PRF
with per-hart floors, per-hart cancellation; drained handoff retired only after peer squash/trap
isolation negatives pass; Phase 6 adaptive policy stays frozen. Guard removal is a separate decision.

## Deferred

Linux/compliance/liveness, STA/DFT/power sign-off, CASQ, PMU residuals, coherence/hierarchy/snoop,
FP widths beyond `FLen <= XLEN`, four-wide retirement, adaptive scheduling policy, early-termination
root cause (re-examined only if it recurs with the non-destructive proxy).
