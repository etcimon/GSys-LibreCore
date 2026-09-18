# Remaining upgrade sequence — multi-core, hypervisor, AVX-like memcpy

Plan of record extension to `router-core-upgrade-program.md`. Ordered by **prerequisites** and
**perf/W for server/router Linux**. Detail: `server-math-hypervisor.md`.
All-feature enable + `NrCores` scale vs SMT fetch recover:
`multi-threading/soft-ladder/CONTRACT.md` §8 (named envelopes, union soak, no mega-package).

---

## 0. Done vs open (snapshot)

WIP snapshot (SMT2 / QEMU / 100 TOPS / PCIe vs OoO·H·RVV·stream):
[`current-stage.md`](current-stage.md). QEMU is never Variane evidence.

| Track | Status |
|-------|--------|
| U1–U4, multi-issue, U7ᵃ/ᵇ/ᶜ, U6.0–U6.2 integrated | **Done / partial** |
| **U6.1 dual-PC / CSR + follow-ons** | **Banks landed (fine-grain); product closeout open** — PC/CSR/RF/RAS/GHR banks; IF-only switch; *open:* dual-commit same cycle, banked BHT/BTB, FP reg banking, idle-thread clock gate, `Zawrs`/wait-for-peer, `SMT2` default SKU, boot-crutch retirement. |
| **U9.0 Hypervisor Sstc×H** | **Done** — `vstimecmp` + `henvcfg.STCE` + VSTIP |
| **U9.1 htimedelta** | **Done** — guest time = mtime + htimedelta; TIME under V |
| **U9.2 VS litmus / trap polish** | **Done** — virtual-instr STCE, VSTIP mip, VS mret litmus; G-stage paths present |
| **U10 server math package** | **C-light production** — HPDCACHE+HWPF+L2 auto, RVB/Zicbo*/H+Sstc, `server-math-tests` (optional) |
| U10ᵇ RVV / Ara attach | **Partial / live-lintable** — Ara vendored + attach + lint; purpose guide + DTS + directed tests; full cosim/SBI open |
| Multi-context PLIC | **Done** — 16 targets (8×M/S); harness fan-out per core |
| **U5 full OoO** | **Implemented/gated; qualification blocked** — live dispatch store self-blocking is reproduced; rename/LSQ/recovery/FP/hart and wide-retirement contracts remain open. In-order SMT2/stream8 passes do not qualify this path. |

---

## Broad RTL path review (2026-09-16)

This pass follows live control/data paths across issue/scoreboard/commit, OoO
rename/IQ/ROB/LSQ/PRF, speculative store forwarding, prediction/history recovery,
and shared L2/L3/invalidation. It is not a line-by-line proof of the repository,
vendored IP, firmware or every feature combination. Feature names, source presence
and old production labels are not substitutes for executed qualification.

### Continuation reassessment: contract and oracle review

This section supersedes conflicting closure language in the historical rows below.
Review basis: HEAD `1afd8d559` plus the uncommitted P0–P2 worktree, the active
`plan-ea69493e7a14829a.md`, coding philosophy, SMT2/OpenSBI reasoning workflow and
runtime-learning guidance. This is a path-based review, not an exhaustive proof.
No commit is made and no additional feature default is promoted.

**Oracle correction.** The overlap-v8 comparator admits PC/encoding sequences
with duplicate collapse or unordered retirement multisets. Local fault checks
show that these predicates hide within-hart reordering and lost duplicate
retirements; its operand digest also accepts empty/unrecognized input as an
empty digest. Therefore `review-int-overlap-v8` remains an executed diagnostic,
not proof that the overlap preserved every architectural instruction/value.
This does not establish that the RTL corrupted those workloads. It withdraws
the stronger preservation claim. `review-overlap-reassessment-v2` reclassifies
all 24 captured records as requiring independent validation: none preserves the
full ordered retirement rows with only cycle stamps removed. This is not a new
RTL run or a claim of 24 functional failures. The comparator now requires nonempty ordered
retirement rows (only the cycle column removed), exact operand traces when
captured, and nonempty cookie values. Timing/interleave/value differences need
an independent reference check rather than a relaxed digest. Old independent
analyses may not be rebound to different traces. Earlier byte-identical evidence
and independent formal/synthesis results retain their original scope.

**P1 checkpoint overflow repaired at leaf scope.** Stored snapshot count does
not include branches whose pushes overflowed. Emptying that storage cannot
re-establish the head-to-resolving-branch association. `g6lc_bp_ckpt` now retains
`desync` across ordinary drain until explicit restore/reset/flush. With the new
tests and old RTL, cases 5/6 fail `CKPT_DROPPED_OWNER`/`CKPT_EMPTY_POISON`.
`review-ckpt-after-20260916` passes seven positives and five expected-failure
controls. Leaf synthesis reports zero check problems and no latches. No new
state, stage, clock/reset, config, ISA or DTS field is added. This is not full
predictor integration qualification: replay/kill/hart-switch membership,
correct snapshot phase, out-of-order resolution and peer-bank flush collisions
still require faithful end-to-end checks. Older comments that equate stored
bank drain with resynchronization are superseded by this contract.

| Priority | Current source finding | Required discriminator / completion |
|---|---|---|
| P0 rename checkpoint lifetime | `ckpt_ptr` increments per branch and decreases only on mispredict/full flush; normal branch retirement cannot release a checkpoint. The new full gate can stop a correctly predicted branch stream. | More than `CKPT_DEPTH` correctly predicted branches, retire/reuse, and an older unresolved branch surviving younger resolutions. Add stable checkpoint lifetime identity, not a periodic flush. |
| P0 rename recovery | Checkpoint free-bit snapshots miss a physical register freed by an older commit and reallocated after the snapshot. Full flush reinstates identity maps although renamed committed values reside elsewhere in the PRF. | Commit/free/reuse/mispredict conservation plus committed-value preservation across architectural flush; retain hart/FP legality gates. |
| P0 rename checkpoint retirement — **repaired** | Checkpoints released only on mispredict/flush, so dispatch stalled permanently after `CKPT_DEPTH` correct branches. The pool is now a program-order ring retired at commit, with levels as ring slots and bounded retirement. `review-rename-ckpt-release-v1` 18 records, `review-rename-ckpt-fault-v1` reproduces the defect with retirement disabled, `review-dispatch-ckpt-release-v1` 14 records. | Leaf/fixture scope only. Committed-map recovery, checkpoint free-snapshot reuse, LSQ group credits and enabled-memdep feedback stay open; hart/FP legality gates remain. |
| P0/P1 memory issue — **group credits repaired; memdep open** | LSQ now exports free-entry counts and dispatch admits a group only if it fits, so a surplus allocation can no longer be discarded while the op stays live in ROB/IQ. `review-lsq-credit-dispatch-v2` 16 records, `review-lsq-credit-lsq-v1` 24, `review-lsq-credit-fault-v2` reproduces the defect with the old any-free term. | One fixture geometry (4/4 entries, two ports). |
| P0 committed-state recovery — **repaired** | A full flush reset the map to identity and freed 32..N-1, discarding every committed value (they live wherever their producers allocated) and reissuing the registers holding them. Rename now keeps an architectural map updated at commit; a flush restores it and rebuilds the free list from it. `review-rename-flush-fault-v1` reproduces the loss, `review-rename-flush-after-v1` 20 records, `review-flush-dispatch-v1` 16 records with latch/feedback fatal. | Leaf/fixture scope; depends on committed physical registers retaining values across flush. Checkpoint free-snapshot reuse across a flush is still open. |
| P0 enabled memdep — **loop removed; predictor does not gate issue** | `MemDepPredEn=1` had never elaborated: `review-memdep-before-v2` shows a real cycle (`md_stall` → IQ select → `issue_sbe_o` → memdep → `md_stall`), and the stall also blocked loads whose only pending stores were younger. The IQ age gate is the safety property, so `mem_stall_i` is tied off and the predictor only trains/reports. `review-memdep-after-v1` elaborates loop-free, 16 records. | A *relaxing* predictor (the only performance-positive version) needs an alias proof and a dispatch-time query; unbuilt. No full OoO closure follows. |
| P0 OoO latch inferences — **repaired** | The strict build exposed block-locals declared inside conditional/loop scopes in rename, LSQ, ROB and dispatch. All declared and defaulted at `always_comb` scope; `review-ooo-latch-v2` builds with latch and feedback errors fatal (16 records), suites re-pass 18/24/16. | Elaborator cleanliness only — no mapped synthesis, timing or area result. |
| P1 warm-fetch | Registered overlap is in the worktree; previous integration preservation claim is downgraded above. | Independent instruction/value checking, request/response/kill conservation, IQ pressure, split-target and hart-switch cases; recover supply-cap-v3 before new fixed-work comparison. |
| P2 sequential leaf regression — **restored** | The bench had been failing since the concurrent-fill rework because its memory model required fill ARs to carry the requester's id. Oracle corrected to the reserved-id contract; design unchanged. Passes RR0 4-way/latency-8 and RR1 2-way/stalls with bypass, ATOP, AMO/LR-SC, fill-error and replacement phases, plus the MSHR/data unit suite. | Still one outstanding request per requester in this bench; concurrency evidence comes from the HUM suite. No coherence, production-geometry or platform claim. |
| P2 fill accounting / install | Concurrent AR issue/R completion can overwrite same-cycle FIFO-retirement decrements. Tag write is asserted even when a data-bank conflict prevents installation. RR metadata writes use foreground rather than installed-fill context. | Concurrent-read fixture, event recurrence/count bounds, blocked-install safety and installed-way ownership. Repairs remain an incremental gate, not full nonblocking qualification. |
| P2 response order / channel ownership — **leaf repaired** | Five before-cases reproduce same-ID hit/bypass/waiter overtaking, A/B/A reordering and held-AR replacement. Existing MSHR IDs now gate unsafe service/merges; one hold bit retains fill-AR ownership. Different-ID hits and same-ID MLP remain live. Combined direct suite passes 54 records; MSHR regression 18. | Actual L2→L3 simulation is blocked by a packed-port UNOPTFLAT diagnostic; matching lowered synthesis graph has zero SCCs. Do not waive the simulator gate or infer stack qualification. See cache README for source-bound records. |
| P2 invalidation / ATOP — **transport lifetime repaired; coherence open** | The captured write now survives until B and required RLAST handshakes, with ID qualification and no fill-beat forwarding. Reserved-ID no-R stores release correctly. Three old-RTL failures reproduced; combined 54-record suite covers B-before-R beyond the old timer, R-before-B, simultaneous returns and backpressure. | HUM models response transport, not atomic arithmetic or memory updates. Main AMO/LR-SC regression, older-fill/write visibility, fill-install/invalidation races and simultaneous external/self-invalidation obligations remain open. |
| P2 L3 / prefetch integration — **stack simulated; prefetch ownership repaired** | L2 feeding a two-MSHR L3 across a vendor `axi_cut` register slice passes 34 records (`review-l2-stack-chain-v4`); the direct-abutment UNOPTFLAT gate is not waived and the matching lowered graph has zero SCCs. The prefetcher's latch, non-ID-qualified absorb/retire, blanket demand blocking and reserved-ID collision are each reproduced then repaired; `review-pf-after-v2` passes 8 records with clean fixture synthesis. | Zero-cut abutment stays unexercised. Prefetch accuracy/bandwidth unmeasured; the reserved-ID throttle awaits an ID-width decision. Inclusive invalidation, coherence and `ServerPrefetchEn` enablement remain open. |
| P2 replacement-metadata scheduling — **repaired** | One SRAM port served both the victim-pointer read and the install update, and the update won, so the accepted request's lookup read another set's pointer. The read now owns the port and a displaced update is held. Reaching it needed a phase sweep, because a saturated MSHR parks the front end and a continuous stream never collides. `review-l2-rr-fault-v3` `collide=1 lost=1`, `review-l2-rr-after-v3` `collide=1 lost=0`, `review-l2-rr-regate-v3` 60 records + RR0/RR1 synthesis. | Scheduling only — no replacement-policy benefit claim, no losing-case workload, no mapped cost. RR stays default-off. |
| P2 area/physical | Tag SRAM and IQ/checkpoint storage remain candidates; concurrent buffers add state/read-mux cost. | Prove lifetimes and port schedule first. Approved library/SRAM/corner/clock/activity inputs remain required for mapped area, STA, MBIST/DFT and power. Generic cells are screening only. |

Archetypes: independent memory requests, release/acquire and atomic ownership,
and speculation recovery. Contracts preserve accepted identities, response order,
required writes and invalidation obligations without firmware/value exceptions.
The earliest checks are local handshake assertions and directed negative controls;
firmware is the final sufficiency gate. Visibility channels 1–4 and 6 require
explicit lifetime/order tests; channel 5 remains forbidden. Inferred 1.25 GHz
router targets are not timing sign-off. Remaining items are open until their own
source-bound tests pass; the table is not a declaration that P0–P2 are finished.

### Selected repairs and measured trade-offs

| Change | Mechanism and result | Promotion scope |
|---|---|---|
| OoO IQ readiness | Remove selection/issue-time false wakeup; retain actual WB wakeup and capture WB coincident with dispatch. Permit the final exactly fitting dispatch group. | Directed/random tests and watched-readiness formal; not complete OoO execution qualification. |
| MSHR merge lifetime | A full matching waiter queue cannot be hidden by another free slot; post-pop append order and post-append completion preserve newly accepted waiters. | Generic leaf fixed; current L2/L3 top remains serialized and has no waiter drain. |
| Inclusive invalidation acknowledgment | Only the selected source receives ready. Hub priority now masks inclusive ready per target. | Source-derived mux plus live inclusive-leaf checks; producer eviction retention still open. |
| TAGE decay period | Twelve-bit wrap implements the stated 4096 accepted-update period. | Latent contract repair; usefulness training is tied off and not used in allocation. Prediction-output equivalence passes, no accuracy/power claim. |

Matched generic fixtures (scope metadata excluded):
- IQ two ports/depth8/four-bit tags: 13,866→13,074 cells, 698→699 sequential cells.
- IQ four ports/depth16/seven-bit tags: 60,370→53,260 cells, 1,538→1,540 sequential cells.
- MSHR depth4/two waiters: 878→1,003 cells, 127 state cells unchanged.
- MSHR depth8/three waiters: 1,995→2,095 cells, 284 state cells unchanged.
- Inclusive mux N3: 180→183 cells, zero state.
- Small TAGE fixture: 587→584 generic cells, 89 state cells unchanged. The small
  mapping difference is not attributed to a new predictor performance benefit.

No new array, clock, reset, pipeline stage, ISA/DTS field or feature enable is added.
Existing configuration/type seams remain. IQ removes a quadratic comparison cone
but adds per-dispatch WB comparisons; MSHR ready now includes pop/index eligibility;
inclusive ready adds a per-target priority gate. These are timing-impact loci, not
STA/Fmax closure. Scan/storage strategy is unchanged; fixed-size source registers
and generic mapped sequential counts must not be conflated.

Evidence: `review-rtl-audit-after-v1` passes 54 positive/negative component records;
`review-rtl-audit-integrations-v1` matches all 24 protected depth-two SMT2/stream8
records against their immutable qualified baselines, including timing, retirement,
operand traces, ROI reports and the expected stream8 negative. Thus the prior
independent SMT2 reference analyses remain bound to byte-identical new traces.
OoO is off in these packages; no full-OoO/L3 release claim follows.

Formal evidence is split rather than collapsed into one PASS: IQ v5 proves watched
readiness/capacity/storage relations by reset base plus two-step induction under
stable witness inputs and uniqueness of the watched live TID, with wait/drain
covers; MSHR rest-v3 passes ten-step admission/count/uniqueness safety and three
covers; tail-v7 proves TAGE prediction-output equivalence by two-step induction
and the inclusive-source acknowledgment equation. Mutations are detected. Earlier
harness/container initialization, frontend symbolic-witness/lowering, induction
and automatic internal-equivalence failures remain archived; only the named
successful recipes qualify. The TAGE miter proves useful bits zero as assertions,
not assumptions, and does not require the intentionally changed decay signal to
match. Reused synthesis numbers come from frozen raw artifacts, not reruns.

### Remaining blockers and effort-ranked next checks

| Priority/path | Established source contract or reproduced result | Next faithful check / constraint |
|---|---|---|
| ~~P0 OoO store issue~~ **repaired** | `mem_stall_i` gated STORE on `older_st`, which a store sets at dispatch, blocking its own issue→AGU→WB resolution. `g6lc_iq` now gates LOAD only. Four dispatch contracts pass at the supported optimisation level with live negative controls, corroborated by 54/54 component and 24/24 integration records and by the source mechanism. | Store lifetime still ends at WB; the age-aware gate below is what makes moving release to commit deadlock-free. |
| ~~P0 dispatch allocation-id plumbing~~ **not an RTL defect** | slang/yosys elaborates `g6lc_ooo_dispatch` with 0 errors/0 warnings and **proves** `alloc_ids[p] == dispatch_sbe_i[p].trans_id`. The zero-valued `i_lsq.alloc_id_i` seen in simulation is a Verilator artefact. `DISPATCH_STORE_WB_RETIRE` is retained as expected-fail to track the artefact only. `-O0` was tried as an arbiter and discarded: it flips even the isolated LSQ forwarding contract. | None on the RTL. If the artefact ever blocks work, re-host the affected check under slang rather than probing the simulator. |
| ~~P0 store commit released the wrong LSQ entry~~ **repaired** | Commit scanned for the lowest valid index while writeback had already released that store by id, so commit freed a **different, still-pending** store — an unresolved older store went invisible to load ordering (`LSQ_COMMIT_DOUBLE_FREE older=0`). Release is now by `trans_id` on every commit port, not just port 0 (a store retiring on a higher port never released its entry before). Idempotent. 6/6 isolated records with three live controls; dispatch suite unchanged. | Store-age ordering is repaired in the row below. |
| ~~P0 LSQ store age~~ **repaired** | `older_store_pending_o` reported *any* in-flight store, so a load could be blocked by a **younger** store — and would deadlock behind one once release moved to commit. Age now means the scoreboard's circular `trans_id` order anchored at `commit_pointer_q[0]` (dispatch is in-order, so SB slot order **is** program order): a store is older than a load iff `(st_id - commit_ptr) < (ld_id - commit_ptr)` mod 2^TRANS_ID_BITS. `g6lc_lsq` gained `commit_ptr_i`, a `st_live_mask_o` (live store tids, from the entry ids — **not** array indices, which reuse out of program order), age-filtered CAM ordering (youngest matching *older* store forwards; unresolved or data-less *older* stores stall; `store_pending_o` renamed since it now reports only ordering-relevant stores). `g6lc_iq` computes per-entry `older_st` from `st_live_mask_i`+`commit_ptr_i` and gates LOADs only; `g6lc_ooo_dispatch` wires mask+pointer both ways and feeds memdep; `issue_stage` connects `rvfi_commit_pointer_o`. Evidence split because of the known `alloc_id_i`→0 simulator artefact: **isolated LSQ suite 12/12** (age-forward, unresolved-older stall, cp=14 wraparound — all with live controls); **IQ gate formally proven** under slang/yosys (`iv ⟺ no older live store`, arbitrary ltid/cp/mask); integrated dispatch 14/14 — the `alloc_id_i`→0 artefact disappeared when the rename admission rework ungated `valid_i` from `can_go` (it was a comb-settle scheduling artefact, not a wiring bug — the slang elaborator had already proven the connection sound), so scenarios 6/7/8 now run as real passes with live controls and scenario 9 covers older-branch unwind. | Store release still ends at writeback; moving it to commit is now *possible* without the younger-store deadlock, but remains a separate change. |
| ~~P0 OoO rename admission~~ **repaired** | Confirmed as `UNOPTFLAT` circular logic `can_go -> i_rename.valid_i -> stall_c -> ren_stall -> can_go`: admission depended on its own result. Capacity is now computed in its own block from ungated intent and the registered free list, with state updates still gated by `enable_i`; and the redundant `& {NP{can_go}}` on `valid_i` was dropped since `can_go` already arrives via `enable_i`. **Elaborator now reports 2 loops -> 0**, dispatch suite unchanged 7/7. | Rename *recovery* (checkpoint identity, older WB/commit preservation) is a separate open item below. |
| ~~P0 STL data into the address operand~~ **repaired** | Second confirmed loop: `ld_qaddr -> LSQ CAM -> stl_fwd -> issue_op_a_o -> ld_qaddr`. The CAM query address was taken from the operand that the query's own forward overwrites. Address generation now uses `op_a_agu` (regfile + writeback bypass) and the forward is applied only to the issued operand. Also required splitting `always_comb` blocks in both `g6lc_lsq` and `g6lc_ooo_dispatch`, since dependency analysis is per block. Loops 2 -> 1; dispatch suite unchanged 7/7. | Byte coverage and a proper load-result forwarding contract are still open (P1 STQ item). |
| P0 LSQ allocation/age/STL | Full means no free entry, not sufficient group credits; freed-slot reuse breaks index-as-age; STL data feeds address operand A. | Multi-alloc saturation, younger/older store distinction, exact byte coverage and load-result forwarding tests before speculative memory enable. |
| ~~P0 rename recovery~~ **two defects repaired** (partial: identity/multi-branch open) | `review-rename-recovery-v2` (4/4, control live) on a directly-driven `g6lc_rename`: (a) `RENAME_OLDER_LOST got=1 want=32` — the checkpoint saves pre-group state, so a port-0 rename in the same group as a port-1 branch is discarded on mispredict, losing work *older* than the branch; (b) `RENAME_BUSY_RESURRECT rdy=0` — restoring the busy table re-marks a register whose writeback already happened, and it will never repeat, so the consumer waits forever. The same argument applies to `free_q`: commit frees after the checkpoint are discarded and those registers leak. Repaired by capturing the checkpoint after the first branch in the group renames, and by **repairing rather than reinstating** free/busy: the squashed set `ckpt_free & ~free` is exactly the post-branch allocations, so recovery returns only those and leaves post-checkpoint writebacks and commit frees intact. `ckpt_busy_q` is thereby unnecessary and deleted — a net state reduction of `PRF_ENTRIES x CKPT_DEPTH` flops (576 at PRF=72/CKPT=8). 6/6 records, three live controls, dispatch 7/7, still zero loops. Resolving-branch identity now has a mechanism: `mispredict_level_i` selects the checkpoint to unwind to, consuming it and discarding all younger ones in one step; out-of-range means "youngest", so tying it high reproduces the old behaviour exactly. Scenario 3 shows correct unwind at level 0 and reproduces the old defect via its control. 8/8 records, four live controls, dispatch 7/7, zero loops. **Both now closed.** Per-branch checkpoints: `do_ckpt`/`ckpt_slot_c`/`ckpt_id_o` are per-port, each branch captures the map/free state immediately after *its own* rename, `ckpt_ptr` advances by the group's branch count, and a group with more branches than free levels stalls rather than dispatch an unrecoverable branch. Branch-tag plumbing is closed via a dispatch-side `tid_ckpt_q` table — `bp_resolve_t.trans_id` already identifies the resolving branch, so `issue_stage` passes it as `mispredict_id_i`, dispatch looks up `tid_ckpt_q[mispredict_id_i]` and drives `mispredict_level_i` with the level that branch consumed. An older branch resolving therefore unwinds to its own checkpoint and discards all younger speculative state. Also repaired: `free_i` on a still-live register now clears `busy` as well as setting `free` — a freed reg is definitionally not awaiting a producer (its writeback landed before the overwriting instruction could commit), and leaving busy set violated `free&busy==0` exclusivity when the free raced a checkpoint restore (found by the abc-bmc3 prove at frame 3). Evidence: rename suite 14/14 incl. two-branch tag check, level-0 unwind with checkpoint reuse, capacity stall, and the exclusivity probe, all with live controls; dispatch suite 14/14 incl. scenario 9 older-branch unwind observed through the *issued* physical register (squashed reg returns to the free list and is reissued); rename prove PASS (12 frames, abc bmc3). Side effect of ungating `valid_i` from `can_go`: the `alloc_id_i`→0 Verilator artefact is gone — dispatch scenarios 6/7/8 now run as real evidence, no longer artefact-pinned. |
| ~~P0 OoO hart/FP domains~~ **gated; namespaces open** | `g6lc64_ooo_server_config_pkg.sv` configures `OoOEn=1` **with `NrHarts=2`, `RVF=1`, `RVD=1`, and 4 issue/commit ports**, so these are live combinations rather than hypothetical. `core/ooo/**` contains **zero** occurrences of `hart` — `g6lc_rename` has no hart input at all and keeps a single 32-entry architectural map, so hart 0's `r5` and hart 1's `r5` are the same map entry. Separately, `need_rd` excludes FP destinations from renaming, so with `RVF/RVD=1` FP results are neither renamed nor tracked in the busy table. `check_cfg` now **rejects** `OoOEn=1` together with `NrHarts>1` or `FpPresent` (translate-off, simulation-time): `g6lc64_ooo_server` trips it deliberately, and the 24/24 frozen-record gate is unchanged with `config_pkg.sv`+`scoreboard.sv` overlaid. | Proper per-hart map/free/busy namespaces and an FP register class remain open as a redesign; until then OoO is legal only in single-hart, FP-free configurations. |
| ~~P0 retirement width~~ **repaired + directed test** | `num_commit` special-cased `NrCommitPorts==2` and fell through to counting **only port 0** otherwise. The commit loop clears `issued` for every acknowledged port, so a four-port configuration retired up to four entries while advancing the commit pointer by at most one, desynchronising the scoreboard FIFO and re-presenting retired slots. This was reachable: `g6lc64_ooo_server` sets `NrCommitPorts=4`. Replaced with a width-generic popcount, and the port-1-only validity assertion generalised to all ports. Non-regression: `review-scoreboard-commit-v1` matches all 24 frozen SMT2/stream8 records with `core/scoreboard.sv` overlaid (13 cycle-identical, the rest architecturally identical). Directed four-port test landed: `review-commit4-v7` passes 3/3 records — ordering + payload markers, pointer wraparound with live wrapped entries, drain-to-empty via `still_issued`/`rvfi_commit==rvfi_issue`, and a live negative control. Two testbench workarounds for Verilator 5.008 were required: a `negedge`-captured packed snapshot of the wide unpacked `commit_instr_o` port plus `rvfi_issue` reads instead of `issue_instr` (top-level `__Vsampled`/`__Vilp` use-before-decl codegen bug), and `REVIEW_RTL_NOASSERT` to drop `--assert` for this kind only, since the in-DUT SVA is what forces the sampled cellout copy. | None open on retirement width. The SVA stays compiled and active in every other build of `scoreboard.sv`. |
| ~~P0 shared coherence: accepted-write invalidation loss~~ **repaired** | The hub built a write's invalidation combinationally from `aw_fire` and dropped it if the bus was not ready that cycle, so writes completed with no invalidation (`HUB_INV_LOSS`: three writes, two invalidations). Gating AW on `inv_ready` was rightly rejected — `inv_ready` is `aw_fire`-dependent, closing a loop. Instead a **registered retention slot** holds the obligation until the bus takes it, and admission consults only registered occupancy plus the incoming `aw.cache[1]`, so it stays loop-free; one slot suffices because admission is refused while occupied. 15/15 hub records with the negative control live; scenario 5 now passes. | Producer side closed separately below. |
| ~~P0 coherence producer admission~~ **repaired** | The inclusive leaf captured an eviction only when not pending and exposed no ready, so a second victim during a drain was silently dropped; `inv_busy_o` was unconsumed in the cluster. The leaf now drives `evict_ready_o = !pend_q` (tied high when disabled, `inv_busy_o` kept as observability). `g6lc_l2_top` gained `l2_evict_ready_i`: the `S_TAG` victim offer is already re-driven every stalled cycle, so gating the victim-commit transition on ready converts the pulse into a held handshake — with ready tied high the module is bit-identical to before. `g6lc_l3_top` propagates it; `g6lc_cluster` wires the leaf's ready to the active producer. Evidence: `review-incl-evict` 18/18 records over NC∈{1,3,4} incl. backpressure-assert and hold-producer scenarios with controls; `review-l2-evict-hold-v2` HUM scenario 7 holds a victim across a stalled drain without loss; `review-evict-hold-integration-v2` 24/24 frozen records. | Documented gap: under `L3En`, an L2's own evictions are not themselves a back-invalidation source for the L3-inclusive directory (L2 victims invalidate L1s but the L3 does not track L2 residency). |
| ~~P1 predictor context~~ **repaired** | Three ownership defects fixed: (a) base-table row index overlapped the column bits (`vpc_i[OFFSET+:IDX]` used slot position as column, so unaligned RVC windows misattributed entries; non-RVC trained only column 0) — row/column now come from each slot's own PC; (b) one tagged provider was broadcast to every fetch slot — each slot now gets its own index/tag/provider lookups; (c) tagged+ITTAGE updates hashed the *fetch-hart* fold — `g6lc_bp_ghist` gains `folded_train_o` over the resolve-hart bank, wired to new `folded_update_i` ports. Verified `review-tage-ctx-v2` 10/10 (opposing-branches window, update-fold ownership, unaligned base+ITTAGE, banked-ghist fold; all negatives live), decay non-regression 6/6, integration `review-tage-int-v1` 24/24 — smt2 cycle-identical (BPType=BHT, no TAGE fabric), stream8 matched with timingIdentical=false (expected: corrected predictions legitimately shift fetch timing; arch stream/cookies/reports identical, negative control intact). | Remaining gap is the predict-vs-resolve-time fold recency (needs prediction-time context carried to resolve — folded into P1 prediction checkpoints). Fetch/resolve-hart fold split is now correct. |
| ~~P1 prediction checkpoints~~ **repaired** | Reconciled push/pop with branch-correlated prediction-time snapshots: (a) push moved from resolve to predict — `bp_push_cf[i] = (is_branch|is_jump|is_jalr|is_return)[i] & instr_queue_consumed[i]` pushes one entry per consumed real-CF slot (decode type, not predicted cf — so push set == resolve set exactly), snapshotting the live fetch-hart GHR and RAS stack; (b) `g6lc_bp_ckpt` is now a per-slot multi-push FIFO with split push/pop harts — head is always the oldest in-flight CF and each resolve pops exactly its own snapshot (`pop_i = resolved_branch.valid && cf_type != NoCF`); (c) the same-cycle full push+pop double-head-advance bug is fixed — pop frees the slot push takes, count conserved exactly; (d) `restore_i` consumes the head (the *mispredicting* branch's own snapshot) and drops all younger wrong-path pushes, ending the bank empty; (e) overflow refuses tail pushes and raises `desync_o` until the bank drains — restore is then unqualified and callers fall back rather than apply a shifted context; (f) update folds now hash the resolving branch's prediction-time GHR snapshot (`fold_src` = ckpt head, falling back to the live train-hart bank when no ckpt is valid — the `BPCkptDepth==0` behaviour), closing the deferred recency gap without sbe plumbing; (g) arch-GHR semantics corrected — the bank only ever holds resolved outcomes, so the mispredicted branch's actual outcome shifts in unconditionally and the vestigial stale-head GHR restore is removed (was writing a *younger sibling's* snapshot); (h) RAS restore now receives the branch's own predict-time stack instead of a resolve-time stack polluted by wrong-path RAS ops. Verified `review-ckpt-v2` 8/8 (conservation+ordering, full push+pop single-advance, restore-drains-younger, overflow desync gating, cross-window ordering; CKPT_MULTI/DOUBLE_ADV/DESYNC_RV negatives live), TAGE/ghist regression `review-tage-ctx-v3` 10/10; integration `review-int-ckpt-v3` **24/24 matched** with `frontend.sv` + `g6lc_bp_ckpt.sv` overlaid — smt2 13/13 cycle-identical, stream8 11/11 matched with `timingIdentical=false` + `timingLegibleDivergence` (rdcycle-read values and spin-tail length shifted as predicted; PC/encoding stream, arch markers `load`/`store`/`data_req`, cookies identical). The comparator now splits a PC/encoding-only `retirementArchPC` digest from value-bearing arch digests, and splits report fields into arch-binding vs timing-legible (`roi_cycles`, cache-miss counters) so a legal predictor-timing change is classified, while a real instruction-stream divergence still fails. | Two documented residuals: a window shares one RAS snapshot (an older same-window CF's RAS op is absent from a younger sibling's snapshot — bounded over-restore, self-heals at the next correct-path mispredict); and a resolve whose predicted cf missed push classification (e.g. ZCMT decodes as non-CF at fetch but resolves JumpR) over-pops one entry — association re-forms at the next drain. |
| ~~P1 STQ/cancellation~~ **repaired** | Two competing forwards coexisted: the OoO LSQ injected store data into `operand_a` — the load's *base register*, so `vaddr = imm + operand_a` degenerated — and matched whole 8-byte groups with every store claiming an XLEN footprint (`agu_size=2'b11` hardcode, no load size at all). Reconciled: data forwarding lives solely in the LSU store_buffer (full PA + `st_fwd_be` byte-enables over spec+commit queues, commit handoff); the OoO LSQ is ordering-only — `stl_stall_o` = older unresolved-address store OR byte-lane overlap without data, now computed on real footprints (`extract_transfer_size(sbe.op)` both directions, new `ld_query_size_i`); `stl_forward_o`/`stl_data_o` remain as "fully-covered forward" observability (the store_buffer's own `st_fwd_covers` predicate). The single serial LSU pipe lands an older store in the buffer strictly before a younger load's PA compare, so the stall window is exactly dispatch→LSU-landing. `fwd_keep`/G1ao one-shot replay are `SuperscalarEn && NrHarts>1`-gated — unreachable under OoOEn (`check_cfg` rejects NrHarts>1) — so no second forwarder remains in OoO configs. Verified `review-lsq-be-v2` 24/24: byte-disjoint-no-stall, containment forward, partial-overlap stall/merge, cancel-by-tid, flush — all with live negatives; dispatch non-regression 14/14. | OoOEn=0 in both qualified configs → leaf-verified only; integration gate in flight (timing-identical expected). |
| ~~P1 cache refill errors~~ **repaired** | `S_MISS_R` dropped `mst_resp_i.r.resp` — a SLVERR/DECERR fill beat installed as valid data and the requester got hardcoded `RESP_OKAY`. `g6lc_l2_top` gains `fill_err_q`: accumulated over the whole refill (cleared on AR accept), it gates `tag_write`/data install at `S_MISS_INSTALL` and serves the saved code to the requester (and waiters it drains) at `S_HIT_RESP`; `bank_conflict` can't deadlock the path since `b_req` is gated off. Verified `l2-leaf` phase `fill_error_no_install`: SLVERR + DECERR cacheable fills → 4 misses / 4 fills / zero installs / retry clean, under 4w/rr1 and 2w/rr0+stall geometries; bench oracle counts error fills separately so the install-conservation invariant stays exact. | Residual: the bench is a single sequential master — a waiter merging into an *errored* fill is drain-propagated by construction but not yet concurrently exercised. |
| P1 warm fetch | `g6lc_fetch_dbg` `+fetch_supply` observer (translate_off bind, zero functional path) measured the warm window on locality-1024 (supply-cap-v2): **supply is binding** — 19791/19791 take cycles carried a refused request, every refusal with `iqrdy=1` and 19788/19791 with `iquse=0` (IQ empty and ready), accept-to-accept gap = 2 for 19751/19801 accepts (the structural II=2 cadence); whole-run split: `iq_stall=7`, `empty=13`, `be_stall=5`, `halt=0`. Implemented registered overlap in `g6lc_icache` (W1): the READ hit-response cycle asserts `dreq_o.ready` and stays in READ when `dreq_i.req` — `cl_index` keys off `vaddr_d`, so the accepted request's array read launches in the same cycle and returns one cycle later (warm II=1). `ready = f(cl_hit ∪ state)` reads only registered-state cones (SRAM `rdata_q`, `areq_i` translation of `vaddr_q`); the I4xi/I4xj loop (`vaddr_d`/`cl_index` → tag-compare → `ready`) stays cut because every `cl_hit` input is registered. Miss/flush/inval/kill/translation-wait stay serialized; way-pred `force_all_ways` re-reads remain correct through the `r_addr_q` same-index invariant. **Historical comparator match; architectural-preservation qualification withdrawn in the continuation review above.** `review-int-overlap-v8` recorded 24/24 matched under the weaker comparator: comparator binds PC+encoding sequence on ordered streams and the (pc,priv,encoding) multiset on merged-hart `trace_hart_*.dasm` (cross-hart interleave has no architectural order), per-hart `h`-split operand `ot-retire` digest with timing/allocation stamps stripped and consecutive duplicates collapsed, cookie values bound exactly while cookie timestamps are timing-legible — those normalizations do not guarantee detection of every wrong-path retire, drop, reorder or result corruption; they are diagnostic only. | supply-cap-v3 re-measurement in flight (early rows show `req&rdy&rsp&take` coincidence, `iquse`≈9–10 vs old ceiling ~4); residual: way-mispredict costs +1 re-read cycle (first reads are all-ways by construction), `dreq_i.spec` misattribution during READ pre-exists unchanged, IQ-pressure replays bound two-in-flight arrival |
| P2 real nonblocking L2/L3 | **Concurrent-fill candidate; partial leaf qualification.** The new queued-memory HUM bench demonstrates multiple outstanding fills and clean drain. Counter-retirement and blocked-install collisions are repaired and old-assignment mutations fail; `review-l2-hum-clean-v1` passes 22 records and small RR0/RR1 synthesis checks. Declaration/temporary/feedback warnings are repaired without adding state. Historical serial-service measurements are not comparable to the new memory model. | Same-ID ordering, held AR, nonadjacent merges, invalidation/write/ATOP lifetime, RR port scheduling, main leaf error/atomic regression, L3/server-prefetch ownership, production geometry and full integration remain open. L3 reuses this unfinished engine. See `l2-l3-cache/README.md`. |
| P2 area/physical | IQ compaction, tag flops and speculative checkpoints remain cost candidates. | Prove lifetimes first, then mapped macro/STA/power comparisons; no physical area from generic counts alone. |

### Follow-on pass: store-issue repair + L2 hit-under-miss

Both changes are qualified within the scopes stated in
`architecture/out-of-order/README.md` and `architecture/l2-l3-cache/README.md`.

Integration identity was re-established with `g6lc_l2_top` **actually overlaid** —
the earlier overlay list silently omitted it, so a first pass of this gate proved
nothing about the L2 change. `review-rtl-audit-integrations-v4`: 24/24 records,
every SMT2 and stream8 **cookie identical** to the frozen depth-two baselines, and
every architectural instruction stream identical. 13 records (all SMT2) are also
cycle-identical; the 11 stream8 records retire the same instructions 1-2 cycles
earlier during boot, which is the expected effect of a cache-timing change and was
confirmed by diffing the traces (80,667 identical lines, differing only in the
retirement-cycle column). The gate now requires cookie plus architectural
identity and records exact cycle identity separately, rather than being relaxed.

Because all cookies are unchanged, **no end-to-end SMT2 or stream8 speedup is
claimed** from hit-under-miss; the measured gain is confined to the leaf
shared-line stimulus. Full OoO remains unqualified: the store-issue repair removes
one deadlock, it does not close rename admission/recovery, LSQ age/forwarding,
hart/FP ownership or wide retirement.

The two-entry MSHR package promotion and prior fetch/predictor fixes remain intact.
No OoO, L3, replacement or cacheability option is newly enabled. Full source-bound
platform, firmware/ISA/FP/RVH/FPGA, DFT and physical qualification remain open.

## 1. Spec map (RISC-V identity of “AVX” + H)

| Server need | Spec | Implementation seat |
|-------------|------|---------------------|
| AVX-wide copy | RVV 1.0 | Ara / CVXIF vector; `RVV` + misa.V |
| `rep stos` / zero | Zicboz | U7ᶜ multi-beat `cbo.zero` |
| Stream copy | Zicbop + HWPF | Decode HINT + `HwPrefetchEn` |
| Bit munge | Zba/Zbb (`RVB`) | Config-gated |
| KVM host | H-ext + Sstc | U9.0 `vstimecmp`; HS CSRs under `RVH` |
| Guest timer | Sstc + H | `henvcfg.STCE` + VSTIP |

---

## 2. Sequence graph

```
U6.2 multi-core ──┬── U9.0 Sstc×H (vstimecmp) ✅
                  ├── U9.1 htimedelta + TIME under V ✅
                  ├── U9.2 VS litmus + STCE virtual-instr ✅
                  ├── multi-context PLIC (16 tgt) ✅
                  ├── U10 server package ✅ C-light (HPDCACHE+HWPF+L2 auto + tests)
                  ├── U10ᵇ RVV/Ara config scaffold ✅ (IP flist open)
                  └── U5 OoO (production gated; L3+server PF✅)
```

### Phase B — Hypervisor

| Step | Content | Status |
|------|---------|--------|
| B0 | `vstimecmp`, `henvcfg.STCE`, legalize `Sstc&&RVH`, VSTIP | **done** |
| B1 | `htimedelta` + guest `time` under V | **done** |
| B1b | VS entry litmus + STCE virtual-instr + HVIP mask | **done** |
| B2 | G-stage (two-stage + G-only) | **present** (KVM stress open) |
| B3 | HFENCE/HLV/HSV | decoder+commit present |
| B4 | PLIC multi-context (16 targets, per-core M/S) | **done** |

### Phase C — AVX-like / math

| Tier | Content | Status |
|------|---------|--------|
| C-light | Full-line `cbo.zero`, Zicbop HINT, RVB, HWPF, HPDCACHE server pkg | **done** |
| C-heavy | RVV package + Ara attach + guide/DTS/tests | **partial**; full cosim / OpenSBI V open |

---

## 3. Enable (operator)

```
# Server / KVM / math host profile (select as active cva6_config_pkg):
core/include/cv64a6_server_math_config_pkg.sv
  → H=1, Sstc=1, RVB, Zicbo*, L2, NrCores=2, dual-issue, HWPF
  → RVV=0 until Ara is linked

# When Ara is on the flist:
core/include/cv64a6_server_math_v_config_pkg.sv  # VExtEn=1, CvxifEn=0
# See architecture/ara-vector-attach.md

# Router low-power remains default imafdc packages (H=0, NrCores=1).
```

---

## 4. Next concrete work

1. ~~`vendor sync ara` + `Flist.ara`~~ **done**  
2. ~~L3 victim → L2 tag inval~~ **done**  
3. ~~p6 stream plane × multicore suite~~ **done** — `mc-stream-tests` lint gate green  
4. ~~Ara flist + typed lint top for `cv64a6_server_math_v`~~ **done** (`extraFlistsByTarget`,
   `cva6_ara_lint_top`, suite `ara-vector-path` PASS)  
5. ~~Ariane EnableAccelerator + attach + live Ara (`CVA6_ARA_ATTACH=1`)~~ **done** (Verilator lint
   green with `vendor/ara/cva6_shim/*` + expanded Flist.ara deps)  
6. ~~Strengthen formal vs **live** freelist / ROB / multi-port rename~~ **done**
   (`verify.formalTasks` 4× `.sby`; cancel remains policy model)  
7. ~~R2a dual-hart payload + DTB + R3a OpenSBI `fw_payload.elf` on Windows~~ **done**
   (managed xPack + Cygwin OpenSBI wrap → `workspace/smt2-linux/fw_payload.elf`)  
8. ~~R3 dual-hart payload cosim (`cva6.py` + Verilator on WSL)~~ **done** (Variane SUCCESS
   ~6.5M cycles on `fw_payload.elf`); Spike via WSL managed install; **R3b Linux `Image`**
   still external (cva6-sdk / kernel build)
9. U10ᵇ software contract: ~~purpose guide + DTS `v` + directed vector tests~~ **done**
   (`AGENTS-vector.md`, `ariane-server-math-v.dts`, `testlist_ara_vector.yaml`); next =
   OpenSBI VRF context + `cva6.py` cosim of `v_memcpy_lmul` under live Ara
10. ~~Zacas AMOCAS.W/D + multicore spo/CF directed + Spike soak~~ **done** (`RVZacas`,
    `testlist_mc_stream`, `mc-spo-soak` / `mc-spo-spike`); ~~RTL mini hard CAS~~ **done**
    (`mc-mini-veri`); ~~full CRT `mc-spo-veri`~~ **done** (imafdc + server_math 9/9); ~~AMOCAS.Q~~ **done**
11. ~~Structural FO4 residual close sparse_ex/frontend @ 2.5 GHz~~ **done** (screening;
    S3b-lab real-STA retune still open)

**Live next (authoritative ordered list + file priors):**
[`AGENTS-todo.md`](../AGENTS-todo.md) — **Current phase** and **Practical next**.
The **2026-09-16 stability-balanced reassessment** in `AGENTS-todo.md` and the
user-local `plan-ea69493e7a14829a.md` supersedes RR-first sequencing. E1–E6 are
work families, not a rigid queue: retained IQ/predictor gains are the foundation;
next measure warm-fetch supply and reproduce shared-path correctness scenarios,
then screen serialized-MSHR right-sizing and matched CPU-visible memory service.
Tag-SRAM feasibility/physical inputs proceed in parallel. Scheduler, concurrency,
width and policy growth require their own bottleneck evidence.
F0–F5 remain qualification gates, not a serial queue of historical experiments.
Technology/library/SRAM/constraint acquisition starts in parallel, not after RTL.
The IQ now also passes binary-state temporal induction and all twelve cover
predicates in its reduced formal envelope. The twelve-frame BMC remains historical
evidence; wider/FPGA/RVH and full-pipeline qualification are still separate.
Executable-data cacheability A/B now passes its short and larger controls, but
hot-scan ROI rises 275,593 to 374,177 cycles (+35.77%). Keep that candidate
isolated: checked locality subsequently identifies a repeated wrong-path
instruction-refill bottleneck rather than a cache-capacity explanation. A
response-aligned predictor lookup plus consistent absolute-corrector repair is
now retained after independent leaf/selector checks, SMT2 integration, broader
stream8 controls and synthesis. Locality ROI improves about 30.77%; unchanged-policy
hot-scan improves 4.66%. The corrector adds 99 generic leaf cells, no state bits.
Mapped timing/power and broader release qualification remain open; do not
automatically remove the cacheability workaround or tune RR.

The demonstrated restart, redirect-owner and split-target integer failures are
repaired and independently revalidated with the private corrected runtime.
NWORKERS=1 is still not a dual-active SMT pass; the two activated integer
encodings do not close natural firmware, FP isolation, ordering or physical
qualification. The old RR-specific livelock attribution and vacuous formal
PASS labels remain withdrawn. Do not repeat obsolete bisects to justify a new
optimization; use the current accepted-stream and cacheability contracts.

Preserve completed leaf and mapped equivalence through 8 KiB at their scope;
16 KiB collect and production mapped/physical gates remain incomplete. The
cacheability-overlay stream8 hot+scan recorded 374,177→325,980 ROI cycles, but
it is one RR-favourable experiment, not a production default decision. Named
stream8 and SMT2 controls remain separate. RR remains default-off.
Stage map: [`current-stage.md`](current-stage.md) (parallel envelopes, not one serial queue).
Host residual §1–§10 largely **done**; lab FO4/STA + stream8 optional growth open.
QEMU firmware ladder (U-Boot/EDK2 virt+soc) is **green as hypothesis**; E4 pflash and soc Shell
remain. 100 TOPS next is **I3 measure then I2**, gated by `RTL_FEEDBACK.md` F9–F14, not by KVM or
full OoO. PCIe host transport stays **unpinned**.

Quick spine for those open items:

| Next | Open these |
|------|------------|
| ~~Suite catalog~~ **done** | `mc-mini-veri` + `mc-spo-veri` in `defaults.ts`; `AGENTS-specs-to-tests.md` |
| ~~CRT RTL residual~~ **done** | imafdc + server_math L2 9/9 · `mc-spo-veri.sh` |
| ~~H-edge~~ **done** (Spike+RTL 3/3) | `kvm-h-spike` · `architecture/server-math-hypervisor.md` |
| ~~Stability / dual-ISS / dual-hart host~~ **done** | `stability-regress` · `dual-iss-regress` · `dual-hart-ci` |
| ~~AMOCAS.Q~~ **done** | `zacas-policy` · `architecture/zacas-amocas-q.md` |
| R3b Linux Image | soft gate `r3b-linux-image` · Image external |
| Ara live cosim / VRF | `ara-vector-cosim` · lab when `_v` TB + Image |
| Lab FO4/STA | `s9-lab-gate` · real STA / OpenROAD still lab |
| ~~Stream8-class package~~ **promoted + CRT 9/9 + H-edge 3/3** | `g6lc64_stream8` · `mc-spo-veri` · `kvm-h-veri` |
| QEMU E4 / soc Shell | `u-boot-edk2-boot-architecture.md` · no 32 MiB pflash on Variane; soc StartImage hang |
| 100 TOPS I3→I2 | `scaling-100tops.md` §4.2–§11 · `uncore/dram-channel-scaling.md` · `RTL_FEEDBACK.md` F9–F14 · shared DRAM slave (cores + `NrCores` + island) · do not grow clusters before measured BW |
| PCIe transport pin | `pcie-endpoint.md` · keep GPEX RC ≠ virt_ai_card EP until `ai_host_transport` |


