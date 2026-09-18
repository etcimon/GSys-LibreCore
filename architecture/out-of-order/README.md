# Extension point: out-of-order execution (production path)

Program: `../router-core-upgrade-program.md` (U4 / U5).

**Status: config-gated implementation; full architectural qualification blocked.**
`OoOEn=1` routes the live dispatch/IQ/rename/LSQ/PRF path, but routing and component
passes do not establish a shipping backend. The 2026-09-16 broad RTL review
reproduces an accepted store that cannot issue; other recovery/ordering contracts
below remain unresolved. Minimal/default packages keep `OoOEn=0`. Passing SMT2 and
stream8 regressions exercise that protected in-order path, not full OoO.

## Continuation review: lifetime closure remains open

### Checkpoint retirement (repaired, leaf-verified)

Rename checkpoints were allocated per branch and released only by mispredict or
flush, so the capacity gate stalled dispatch permanently after `CKPT_DEPTH`
correctly predicted branches. Checkpoints are taken in program order and commit is
in program order, so the pool is now a ring: allocate at the tail, retire at the
head on commit. A checkpoint level is a ring slot, and its age is its distance from
the head, so an older branch still unwinds to its own level and consumes every
younger one; a level outside the live window falls back to the youngest. Retirement
is bounded by what is live, so a stale strobe cannot advance the head past the tail.

`g6lc_ooo_dispatch` derives the retire strobes from `commit_ack_i` and the per-tid
checkpoint tag, writes that tag unconditionally at dispatch so a reused slot cannot
retire a checkpoint it never took, and clears the resolving branch's tag on
mispredict because the unwind already consumed it.

`review-rename-ckpt-release-v1` passes 18 records (9 positives, 9 injected-oracle
negatives), including reuse of the retired slot and preserved recovery after a
retirement. `review-rename-ckpt-fault-v1` disables retirement and the new scenario
fails as contracted, so it is the discriminator for the original defect.
`review-dispatch-ckpt-release-v1` passes 14 records with the new wiring. This is
leaf and dispatch-fixture evidence: it does not close full OoO, and the hart/FP
legality restrictions stay.

### LSQ group credits (repaired, leaf-verified)

Admission asked only whether *any* load/store entry was free, but dispatch is
all-or-nothing across the group, and a surplus allocation is silently discarded by
the queue's placement loop — leaving that memory op live in the ROB/IQ with no queue
entry to order or forward it. `g6lc_lsq` now exports free-entry counts and dispatch
compares them against the group's memory-op count. The counts come from registered
state and the group size from ungated intent, so admission still cannot feed back
through `can_go`.

`review-lsq-credit-dispatch-v2` passes 16 records and `review-lsq-credit-lsq-v1`
passes 24; `review-lsq-credit-fault-v2` restores the any-free-entry term and the new
group-credit scenario fails as contracted. Scope: one geometry
(`LsqLoadEntries=LsqStoreEntries=4`, two issue ports) at fixture level.

### The hart/FP restriction is now an elaboration refusal, not a simulation warning

The per-hart-namespace and FP-register-class gaps remain **open redesigns** (see the
plan below). What changed is the strength of the gate. `config_pkg::check_cfg` sits
under `pragma translate_off`, so the assertions that reject `OoOEn` with
`NrHarts > 1` or `FpPresent` only fire in simulation: an unsound configuration still
elaborated *and synthesised*, silently aliasing architectural registers.

`g6lc_ooo_dispatch` now carries two generate-scope elaboration guards — the same
`$error` idiom as `cva6.sv`'s `gen_err_xif_and_acc` — so those configurations refuse
to build. `review-ooo-illegal-smt-v4` and `review-ooo-illegal-fp-v4` each confirm the
refusal, checked without `-Wno-fatal` (which would demote the error to a warning and
defeat the point) and matched against the specific guard message.
`review-p0-guard-regate-v1` confirms the legal configuration still passes 66 records.

Two false positives were caught and fixed while establishing this: a fixture
parameter named `FPU` collided with an enum item, and the runner compared against
the wrong guard message because the configuration loop rebinds `kind`. Either would
have reported a refusal that had nothing to do with the guard.

Remaining work for these two items, in order:
1. **Per-hart namespaces.** Rename needs a hart-indexed map and architectural map,
   physical-register ownership per hart, and per-hart flush. That ripples into
   IQ/ROB/LSQ/memdep entry tagging and cancel masks — `core/ooo/**` contains no hart
   signal today — plus per-hart checkpoint pools. This is a multi-module redesign,
   not an increment, and needs a full-core SMT2 gate to validate.
2. **FP register class.** A second 32-entry map, register-class tagging on rename,
   wakeup and writeback, PRF read/write paths for FP operands, and commit-side
   class awareness. Contained to one hart but still spans dispatch, PRF and
   `issue_read_operands`.

### Checkpoint recovery returns the right registers (repaired, leaf-verified)

Recovery computed the squashed set as "free at the checkpoint and no longer
free". A free-list snapshot cannot express what recovery actually needs. A
register that was *live* at the checkpoint, freed afterwards by an **older**
instruction committing, and then reallocated to younger work is absent from the
snapshot, so recovery never returns it: it is left neither mapped nor free and
leaks permanently. Repeated often enough this exhausts the free list and dispatch
stalls for good.

Each checkpoint level now carries a mask of registers allocated **after** it,
cleared when the level is taken (so the branch's own rename is excluded) and set
by every later allocation, including one made earlier in the same group. Commit is
in order, so nothing allocated after a checkpoint can have committed before that
branch resolves, and every register in the mask is safe to return. This replaces
the snapshot rather than adding to it, so the storage is unchanged.

Scenario 10 builds exactly that case and requires the register to be reissued
after recovery. The fault control has to restore *both* halves of the old
behaviour — seed the mask with the free list **and** drop the accumulation —
because seeding alone lets the accumulation re-add the register and the scenario
passes; my first attempt at this fault was not faithful and was corrected.
`review-rename-leak-fault-v3` fails as contracted, `review-rename-leak-after-v2`
passes 22 records, `review-p0-dispatch-regate-v1` 16 and
`review-p0-core-regate-v1` 66.

### Committed-state recovery on full flush (repaired, leaf-verified)

A full flush reset the rename map to identity and freed physical registers
32..N-1. That claims architectural register *i* lives in physical register *i*,
which is false as soon as anything has committed: committed values live wherever
their producers allocated. Every committed value was therefore discarded at the
first exception, fence or CSR side effect, and the registers holding them were
handed back to the free list.

Rename now keeps an architectural map updated at commit from the destination and
the physical register the committing instruction owns (younger port wins within a
cycle; a non-renamed destination carries physical 0 and is filtered). A flush
restores that map and rebuilds the free list as everything the map does not
reference. `g6lc_ooo_dispatch` supplies the commit triple from `commit_ack_i`,
the retiring instruction's `rd`, and its recorded physical register.

Scenario 9 allocates a rename for `r1`, writes it back, commits it, flushes, and
requires the mapping to survive *and* the committed register not to be reissued.
`review-rename-flush-fault-v1` restores the identity-map flush and the scenario
fails as contracted; `review-rename-flush-after-v1` passes 20 records and
`review-flush-dispatch-v1` passes 16 with latch and feedback errors fatal.

Scope: leaf and dispatch-fixture. The PRF is not reset by a flush, so this
depends on committed physical registers retaining their values — true here, but
the interaction with the architectural register file at full-core level is not
covered. Checkpoint free-snapshot reuse across a flush remains open.

### Enabled memory-dependence prediction (loop removed; predictor no longer gates issue)

`MemDepPredEn=1` had never been elaborated. With the dispatch fixture built at
`MemDepPredEn=1` and feedback promoted to an error, Verilator reports a genuine
combinational cycle (`review-memdep-before-v2`):

```
md_stall -> g6lc_iq select -> issue_sbe_o -> g6lc_memdep -> md_stall
```

The predictor's query *is* the selected load, so feeding its stall back into
selection closes the loop. The stall was also wrongly conservative:
`store_pending` is global, so it blocked a load whose only pending stores are
younger and cannot alias it.

Safety at issue comes from the IQ's per-entry age gate, which already blocks a load
behind every older live store, so the predictor is not required for correctness. The
IQ's `mem_stall_i` is therefore tied off in `g6lc_ooo_dispatch`, and the predictor
continues to train and report. A predictor that *relaxes* the age gate — the only
version that buys performance — needs an alias proof and a dispatch-time query keyed
by the dispatching load, not by the selected one; that remains open and unbuilt.
`review-memdep-after-v1` elaborates loop-free and passes 16 records at
`MemDepPredEn=1`.

### Latch inferences across the OoO path (repaired)

The same strict build exposed latch inferences in `g6lc_rename`, `g6lc_lsq`,
`g6lc_rob` and `g6lc_ooo_dispatch`: block-locals declared inside conditional or loop
scopes are unassigned on the paths that skip the scope. All are now declared and
defaulted at their `always_comb` scope. `review-ooo-latch-v2` builds with
`-Werror-LATCH` and `-Werror-UNOPTFLAT` and passes 16 records; the rename, LSQ and
dispatch suites re-pass 18/24/16 afterwards. This is elaborator-level cleanliness,
not a mapped-synthesis or timing result.

`../remaining-upgrade-sequence.md` records the remaining source-backed gaps behind
the earlier repaired-leaf rows. Checkpoint free snapshots do not include later old-commit
frees subsequently reallocated to younger work; full flush resets the map to
identity rather than a committed map. Directed commit/free/reuse/recovery tests
must settle these contracts before another rename-area optimization.

LSQ admission still advertises any-free-entry rather than enough credits for the
whole dispatch group, and enabled memdep still queries the selected load while
its result gates IQ selection. These are source findings, not newly observed
firmware failures. More-than-depth branch progress, multi-alloc saturation,
MemDepPredEn-on liveness, committed values across flush, and delayed wrong-path
WB reuse need their own tests. Keep OoO hart/FP legality restrictions. In-order
SMT2/stream8 or the corrected predictor-checkpoint leaf cannot close this backend.

## Pipeline (OoOEn=1)

```
decode → scoreboard (in-order alloc + commit)
              │
              ▼
     g6lc_ooo_dispatch
        multi-port rename (g6lc_rename)  ── freelist 32+ pool
        free+busy+map ckpt (recovery contract open)
        age-ordered IQ + writeback-qualified wakeup + multi-grant
        ROB multi-WB complete (by trans_id)
        LSQ multi-alloc + live AGU + CAM/STL + memdep
        PRF write-through + WB bypass → IRO operands
        mispredict: SB cancelled_mask → squash younger IQ/ROB/LSQ + gate PRF WB
              │
              ▼
     issue_read_operands  (PRF cutover when ooo_renamed)
              │
              ▼
            EX → WB → commit
```

**OoOEn=0:** identity (no dispatch module). **SliceOoOEn ⊕ OoOEn.**

Rename BMC (`g6lc_ooo_rename.sby`) is in `verify.formalTasks`. Cover
(`g6lc_ooo_rename_cover.sby`) is local yices only: testharness z3 timed
out 90 s with zero traces (`rename-cover-z3-2`). Do not mix this lane
with L2 RR or SMT2 pairing.

## Intended mechanisms and component work

The table records mechanisms present or intended in the source. The integration
blockers below supersede any implied claim of verified end-to-end precision.

| Bottleneck | Mitigation |
|------------|------------|
| Rename WAW/WAR multi-issue | Single-cycle multi-port rename; later ports see earlier allocs |
| Mispredict recovery | Precise map+free+busy checkpoint; **SB cancel mask** squashes younger IQ/ROB/LSQ; PRF WB gated |
| Wakeup latency | Busy-table clear on WB + IQ tag wakeup same cycle |
| Operand availability | IQ readiness now waits for actual WB; speculative producer-selection wakeup was unsafe and removed |
| PRF read latency | Write-through PRF + same-cycle **WB bypass** into issue operands |
| Issue width | IQ grants up to `NrIssuePorts` oldest-ready; mem_stall only blocks LD/ST |
| Mem dependence | Store-set predictor + LSQ CAM; stall only unknown/match-no-data |
| STL | Live AGU (`imm+rs1`) + store data at issue; youngest match forwards into load op A |
| LSQ capacity | Full `LsqLoad/StoreEntries` (no hard-8 cap); multi-port alloc |
| ROB complete | Multi-WB complete by scoreboard `trans_id` |
| Arch RAW stalls | IRO skips scoreboard RAW stall when `ooo_renamed` |
| Dual/multi commit free | Commit ports free old phys regs |
| Observability | PMU group 1 events 0–7 (rename/IQ/ROB/LSQ/STL); phys tags on `scoreboard_entry_t` |

## Modules (`core/ooo/`)

| File | Role |
|------|------|
| `g6lc_rename.sv` | Multi-port RAT + free pool + busy + full-state branch ckpt (any port) |
| `g6lc_iq.sv` | Compacting IQ, chain wakeup, multi-grant ready select + cancel squash |
| `g6lc_rob.sv` | ROB with multi-WB complete-by-tid + cancel complete |
| `g6lc_lsq.sv` | Multi-alloc LSQ + live addr CAM + STL + cancel drop |
| `g6lc_memdep.sv` | Store-set |
| `g6lc_prf.sv` | Multi-port PRF with write-through |
| `g6lc_ooo_dispatch.sv` | Glue + AGU + PRF operand outs + PMU probes |

`scoreboard_entry_t` carries `p_rs1/p_rs2/p_rd/ooo_renamed` (zero when off). RVFI/commit sees tags via the SBE.

## Configured profiles (not release evidence)

| Package | Role |
|---------|------|
| `g6lc64_ooo_server_config_pkg.sv` | **Configured server**: 4-issue, 4c×2h, L2/L3 auto, `DeepSpecEn`, `MemDepPredEn` |
| `g6lc64_ooo_config_pkg.sv` | **Configured dual-issue lite**: 2-issue OoO + DeepSpec (bring-up / area-lean) |
| Default `cv64a6_imafdc_sv39` etc. | `OoOEn=0` identity (still production in-order) |

ROB/IQ/LSQ/PRF depths 0 → scaled from issue width in `build_config_pkg`.

## Tests

| Suite | Path |
|-------|------|
| Directed list | `verif/tests/testlist_ooo_l3.yaml` |
| Regress | `verif/regress/ooo-l3-tests.{sh,ps1}` (`DV_TARGET=g6lc64_ooo_server`) |
| ILP / rename | `verif/tests/custom/ooo/ooo_ilp_chain.S` |
| Memdep / STL | `verif/tests/custom/ooo/ooo_mem_dep.S` |
| L2/L3 stream | `verif/tests/custom/l3/l3_stride_stream.S` |

`build-platform` suite id: **`ooo-l3-tests` (optional / lengthy)** — not in
default `verify.targets` or `defaultSuites` (runtime cost, not maturity).

```
cva6-build test --suite ooo-l3-tests
cva6-build verify --target g6lc64_ooo_server
cva6-build verify --target g6lc64_ooo
```

## PMU group 1 (`mhpmevent[7:5]==1`)

| Idx | Event |
|-----|-------|
| 0 | SB full \| rename stall \| ROB full |
| 1 | Issue stall \| IQ full |
| 2 | Branch mispredict |
| 3 | Load commit |
| 4 | Store commit |
| 5 | LSQ / memdep / STL stall |
| 6 | STL forward hit |
| 7 | Rename/freelist stall alone |

## Formal (optional CI)

| Artifact | Role |
|----------|------|
| `core/ooo/formal/g6lc_ooo_freelist_props.sv` | freelist/busy mutex + index bounds |
| `core/ooo/formal/g6lc_ooo_rob_props.sv` | ROB count/head/tail bounds |

## Related

- Recovery ordering: [`recovery-timeline.md`](recovery-timeline.md)
- FSE depth plane: `architecture/speculative-execution/` (`DeepSpecEn`, STQ, PMU g3)
- Slice MLP (U4): still off by default; mutually exclusive with U5

## Combinational loops in the OoO path (objective compiler evidence)

Both were reported as `UNOPTFLAT` "circular combinational logic" by the
elaborator, so neither is a matter of interpretation.

**1. Store-to-load forward into the address operand — FIXED.**
```
ld_qaddr -> g6lc_lsq CAM -> stl_fwd -> issue_op_a_o -> ld_qaddr
```
The load's CAM query address was built from `issue_op_a_o[0]`, which is itself
overwritten by the forwarded data returned by that query. The forward carries a
load *result*, not an address base, so the fix separates them: `op_a_agu` (register
file plus writeback bypass) feeds address generation, and the forward is applied
only to the issued operand.

Two structural points were needed, because dependency analysis is **per
`always_comb` block**, not per signal:
- `g6lc_lsq` computes `older_store_pending_o`/`lsq_busy_o` in their own block, so
  they no longer appear to depend on `ld_query_*`. Sharing a block with the STL
  outputs closed a second path `ld_qaddr -> LSQ -> older_store_pending ->
  mem_stall -> issue_valid -> ld_qaddr`. (The occupancy output has since been
  renamed `store_pending_o` — it reports only ordering-relevant stores.)
- `g6lc_ooo_dispatch` computes `op_a_agu`/`op_b_pre` in a block that does not read
  `stl_*`, and applies the forward in a separate block.

Result: the elaborator now reports one loop instead of two, and the dispatch suite
is unchanged at 7/7.

**2. Rename admission — FIXED.**
```
can_go -> i_rename.valid_i -> capacity/stall_c -> ren_stall -> can_go
```
Admission depended on its own result. Two things closed it, and the reported
example path had to be read at each step rather than guessed:
- Rename computed exhaustion inside the allocation loop, which is gated by
  `enable_i` (= `can_go`). Capacity is now computed in its own block from
  **ungated intent** and the registered free list: whether a group *fits* is a
  property of the group, not of whether it is currently permitted to proceed.
  State updates remain gated by `enable_i`, so behaviour is unchanged.
- The instantiation also passed `valid_i = dispatch_valid_i & {NP{can_go}}`. That
  gating was redundant, because `can_go` already arrives via `enable_i`, and it
  re-closed the loop through the new capacity block. Rename now receives ungated
  `dispatch_valid_i`.

**Result: the elaborator reports no circular combinational logic (2 loops -> 0),
with the dispatch suite unchanged at 7/7.** Note the same block-granularity
lesson applied three times over: `older_store_pending_o`, `ld_full_o`/`st_full_o`
and `op_a_agu` each had to be moved into their own `always_comb`, because a
signal computed from registered state still inherits its *block's* dependencies.

## Rename recovery: two defects reproduced and repaired

`tb_g6lc_review_rename` drives `g6lc_rename` directly — it is package-free by
design — and observes recovery only through its ports: `prs1_o` reveals the map,
`rs1_ready_o` reveals the busy table, and which register an allocation picks
reveals the free list. `review-rename-recovery-v2` records 4/4, with the basic
allocation contract passing, its injected control firing, and both defects below
captured as expected failures.

**1. Renames older than the mispredicting branch are discarded.**
`RENAME_OLDER_LOST got=1 want=32`. The checkpoint saves `map_q`/`free_q`/`busy_q`,
i.e. state from *before* the group renamed. When the branch sits at port 1 and an
older instruction at port 0 allocated a destination, restoring that checkpoint
reverts port 0's mapping to the architectural register. Recovery must restore the
state *after* the branch renamed, retaining the branch and everything older.

**2. Restoring the busy table resurrects a completed producer — a deadlock.**
`RENAME_BUSY_RESURRECT rdy=0 prs1=32`. A physical register whose writeback
happened *after* the checkpoint is marked busy again by the restore. That
writeback will never repeat, so any consumer of that register waits forever.
By the same argument, restoring `free_q` discards commit-time frees that occurred
after the checkpoint, leaking those physical registers permanently.

**Repair.** Both follow from one principle: recovery must not reinstate a raw
snapshot, because post-checkpoint writeback and commit effects are real progress.

- *Capture point.* The checkpoint is now taken immediately after the **first
  branch in the group has renamed**, rather than before the group. Pre-group
  capture discarded older siblings' renames; post-group capture would wrongly
  retain younger ones.
- *Restore.* The map is restored, but free/busy are **repaired, not reinstated**.
  The squashed set is `ckpt_free & ~free`: exactly those registers that were free
  at the checkpoint and are no longer free, i.e. every allocation made after the
  branch. Recovery returns only those (`free |= squashed`) and clears busy only
  for those (`busy &= ~squashed`). Commit frees therefore stay freed and a busy
  bit already cleared by a writeback stays cleared.
- *Consequence.* The busy snapshot is no longer needed at all, so `ckpt_busy_q`
  is deleted — `PRF_ENTRIES x CKPT_DEPTH` flops removed (576 at the production
  PRF=72/CKPT=8 geometry). The repair is a net state **reduction**.

`review-rename-recovery-fix-v1` passes 6/6 with all three injected controls
firing, and the integrated dispatch suite stays 7/7 with still no combinational
loops.

**3. Resolving-branch identity — plumbed end-to-end.**
`mispredict_i` carried no identity, so recovery always popped the *youngest*
checkpoint. When an older branch resolves that restores state which still contains
work younger than the resolver, and the intervening checkpoints leak.

Rename takes `mispredict_level_i`, the checkpoint level to unwind to; any value
at or above the current depth means "youngest". Restoring level `k` consumes
checkpoint `k` and discards every younger one in one step, so nothing is left
behind. The tag travels without any frontend/ex-stage interface change:
`bp_resolve_t.trans_id` already identifies the resolving branch, `issue_stage`
forwards it as `mispredict_id_i`, and `g6lc_ooo_dispatch` keeps a
`tid_ckpt_q[trans_id]` table — written with the `ckpt_id_o` level rename emitted
when that branch dispatched — so `mispredict_level_i = tid_ckpt_q[mispredict_id_i]`
selects exactly the resolving branch's own checkpoint.

**4. Per-branch checkpoints.** `do_ckpt` was a single bit, so a two-branch group
checkpointed once — the younger branch's own recovery point was never captured.
Checkpointing is now per-port: each branch in a group captures the map/free state
immediately after *its own* rename and exposes its level on `ckpt_id_o[p]`;
`ckpt_ptr` advances by the group's branch count. A group containing more branches
than free levels stalls (`RENAME_CKPT_FULL`) — a branch must never dispatch
without a checkpoint, since it could never be unwound.

**5. Commit-free vs checkpoint-restore race (formal find).** `free_i` on a
register whose `busy` bit was still set left it both free and busy when the free
raced a restore — the reg landed in `free_d` before the squashed-set computation,
was skipped by `busy_d &= ~squashed`, and kept its stale busy bit. A freed
register is definitionally not awaiting a producer (its writeback landed before
the overwriting instruction could commit), so `free_i` now clears `busy` as well
as setting `free`. Found by the abc-bmc3 prove at frame 3
(`RENAME_EXCLUSIVE free=1 busy=1`); the fix holds the invariant under all
reachable input traces rather than relying on an environment assumption.

Evidence: rename suite 14/14 including the two-branch tag check
(`ckpt_id[0]=0, ckpt_id[1]=1`), level-0 unwind with checkpoint reuse, the
capacity stall, and the exclusivity probe — every record paired with a live
control. Dispatch suite 14/14 including scenario 9's older-branch unwind observed
through the *issued* physical register: the squashed reg returns to the free list
and is reissued to the next allocation (`DISPATCH_TAG_REUSE` control fires when
the wrong level is selected). Rename prove PASSes 12 frames under abc bmc3.

## Remaining integration blockers and hardening

1. Associative IQ / FU-class split queues when area allows  
2. ~~Expand formal to live freelist / ROB / multi-port rename~~ **done** (`core/ooo/formal/`)  
3. Inclusive L3 back-inval polish  
4. Optional default-on for selected server board packages only  
5. Retirement width: `g6lc64_ooo_server` requests `NrCommitPorts=4` but `scoreboard`/`commit_stage` still implement two-port commit. Four-wide issue is not four-wide retirement.  

## Status

**Live path behind `OoOEn`, with unresolved architectural contracts.**
`OoOEn=0` remains the protected default. The earlier production wording and
capability table are not evidence of complete `OoOEn=1` qualification.

## Broad RTL review and bounded IQ repair (2026-09-16)

The review traced `issue_stage` → `g6lc_ooo_dispatch` → rename/IQ/ROB/LSQ/PRF →
`issue_read_operands`, plus scoreboard/commit, predictor recovery and cache-side
handoffs. It is an integration-path audit, not an exhaustive proof of every file.

**Reproduced and repaired in the IQ:** ready producers previously woke dependent
instructions before a result existed, including variable-latency loads; accepting
a producer also persisted that false readiness. The IQ now wakes only from
supplied dispatch readiness or actual WB, including WB concurrent with insertion.
The full flag now permits a whole group when it exactly fits. No FU result-chain
bypass is inferred from readiness alone. Independent queue-model tests cover
1/2/4 issue ports, stalls, delayed WB, dispatch/WB coincidence, cancellation,
flush and exact-capacity boundaries, with checker negatives.

| Matched generic IQ fixture | Cells before / after | Sequential before / after |
|---|---:|---:|
| Two ports, depth8, four-bit phys tags | 13,866 / 13,074 | 698 / 699 |
| Four ports, depth16, seven-bit phys tags | 60,370 / 53,260 | 1,538 / 1,540 |

These reduced metadata fixtures demonstrate removal of the quadratic false-wakeup
logic, not whole-core area or measured OoO throughput. Declared storage widths,
clock/reset and interfaces are unchanged; synthesis mapping yields the small
sequential-cell differences shown. Precise data-qualified ALU chaining is future
work and must respect FU latency and physical tags.

**Store-issue deadlock: reproduced and repaired.** `review-rtl-dispatch-contract-v1`
accepted one store in the live dispatch glue and observed no issue in eight cycles
while the ALU control passed. Mechanism: `mem_stall_i` is `md_stall || older_st`,
`older_st` is the LSQ's any-valid-store flag, and a store allocates its LSQ entry
at **dispatch** — so gating STORE on it blocked the store's own
issue→AGU→writeback path, which is the only way that entry is ever resolved and
freed. The first store therefore deadlocked permanently.

`g6lc_iq` now applies `mem_stall_i` to **LOAD only**; stores are never blocked by
memory pressure. The load-side gate is deliberately unchanged: loads still block
on any in-flight store, which is what currently covers `stl_stall` being excluded
from issue select to avoid a combinational loop (`g6lc_ooo_dispatch` 268-279).

`review-rtl-dispatch-fix-v2` passes records on the live rename/ROB/LSQ/PRF/
memdep/dispatch/IQ path: the ALU control, the repaired store, two stores both
issuing, and an ordering guard in which a load must not issue while an older
store's address is unresolved. Injected `DISPATCH_ID` and `DISPATCH_LOAD_ORDER`
controls both fail as required, so neither check is vacuous.

**Weight of that evidence:** these records hold at the supported optimisation
level and their negative controls are live, so they do support the repair. They
are corroborated independently by 54/54 component records and 24/24 integration
records against the frozen baselines, and by the mechanism being unambiguous in
source. See the note below on why `-O0` disagreement does **not** undermine them.

> **`-O0` is not a usable reference in this environment — do not treat it as an
> arbiter.** An attempt to use the simulator's optimiser-disabled build to tell
> an RTL defect from a tooling artefact failed, because `-O0` changes results
> even for the *simplest* fixture here: the isolated, directly-driven
> `tb_g6lc_review_lsq` with a free-running clock passes its forwarding contract
> at default optimisation and fails it at `-O0` (`LSQ_STL_FORWARD fwd=0`). A
> reference that disagrees with itself on trivial stimulus cannot adjudicate
> anything, so an earlier conclusion that the dispatch fixture "cannot separate
> RTL from toolchain behaviour" is **withdrawn** — it rested on that invalid
> reference. `REVIEW_RTL_NOOPT=1` is kept only to reproduce this observation.
>
> The operative evidence is therefore the default optimisation level, which is
> the supported configuration. The fixtures were additionally rewritten to use a
> free-running clock with defined drive/sample points (stimulus on the falling
> edge, combinational handshakes sampled just before the rising edge, since the
> rising edge itself consumes `issue_valid_o`). That rewrite left every
> default-optimisation result unchanged, which is mild evidence the original
> stimulus was not in fact racing.
>
> **The unifying explanation was first refuted, then partly vindicated.** The
> OoO path did contain two genuine combinational loops, and when they were first
> removed neither symptom changed — scenario 6 stayed red and `-O0` still failed
> scenario 0 — so the loop hypothesis was recorded as refuted. The *later*
> rename admission rework told the fuller story: ungating `valid_i` from
> `can_go` removed a third circular settle (`can_go -> valid_i -> stall_c ->
> ren_stall -> can_go` had already been broken on the capacity side, but
> `valid_i & can_go` still fed the admission cone), and with it the
> `alloc_id_i`→0 artefact — the phantom zero was a product of how the simulator
> ordered that feedback cone, not of any wiring defect (as the slang proof had
> already established). The `-O0` divergence on trivial fixtures remains a
> separate, still-unexplained simulator issue.
>
> **Resolved — twice.** First by an independent elaborator:
> `review-dispatch-tid-formal-v1` elaborates `g6lc_ooo_dispatch` under
> slang/yosys with 0 errors and 0 warnings and *proves*
> `alloc_ids[p] == dispatch_sbe_i[p].trans_id` (`SAT proof finished - no model
> found: SUCCESS!`), establishing that the zero-valued `i_lsq.alloc_id_i` was a
> **Verilator artefact, not an RTL defect**. Then the artefact itself
> disappeared: ungating rename's `valid_i` from `can_go` (the loop repair above)
> removed the circular comb settle whose scheduling produced the phantom zero,
> and the dispatched `trans_id` now reaches `alloc_id_i` unimpaired — scenario 6
> retires its store by genuine id match. Scenarios 6–8 are therefore **real
> passes with live controls**, no longer artefact trackers.

**Store commit released the wrong entry — reproduced and repaired.** Because the
independent proof above establishes that id matching is sound in RTL, the
simulator's zero id had been masking a real defect that the isolated fixture can
see. `g6lc_lsq` released a committed store by scanning for the *lowest valid
index* while writeback had already released that store by id — so commit freed a
**different, still-pending** store. `tb_g6lc_review_lsq` scenario 2 allocates
stores 1 and 2, completes and commits store 1, and observed
`LSQ_COMMIT_DOUBLE_FREE older=0` while store 2 was still pending and unresolved:
an unresolved older store had become invisible to load ordering.

Release is now by `trans_id`, on **every** commit port rather than only port 0 (a
store retiring on a higher port previously never released its entry at all). The
operation is idempotent: if writeback already released the entry, nothing
matches. `review-lsq-commitfix-v2` passes 6/6 with all three injected controls
failing as required, and the dispatch suite is unchanged at 7/7.

**Simulator artefact — resolved.** The `alloc_id_i`→0 symptom is gone: ungating
rename's `valid_i` from `can_go` (removing the admission comb settle) also
removed the scheduling artefact that zeroed the id. Scenario 6 now retires its
store by genuine id match, and scenarios 6–8 run as real passes with live
controls. The isolated LSQ suite and the `iq-age` formal check remain as
independent corroboration of the age gate.

The record of failed diagnoses is kept so the dead ends are not retried:

Hierarchical `$display` reads of the dispatch/LSQ/ROB signals in this fixture
were **not dependable** under the artefact. They first suggested the LSQ entry
carried `id == 0` while a sibling `always_comb` read the same `trans_id` as 1,
and then that the ROB latched the correct tid where the LSQ did not — which would
have isolated the fault to the LSQ connection. That second reading **reversed**
(ROB tid went from 1 to 0) purely because an unrelated extra reader of
`rob_alloc_tid` was added, with no change to the ROB or its inputs. Values that
move when an observer is added are artefacts of Verilator's optimisation, not
evidence, so both diagnoses are withdrawn. The probes were removed rather than
left in place to mislead.

Refuted hypotheses, kept so they are not retried: writeback and commit
double-free an entry (writeback frees nothing when no id matches);
`st_alloc[p]` fires on a port whose `dispatch_valid_i` is low to create a
spurious entry (`is_st[p]` is gated by `dispatch_valid_i[p]`); the id is
computed twice and one copy is wrong (sharing a single signal changed nothing,
and that edit was reverted). The structural proof that `alloc_ids[p] ==
dispatch_sbe_i[p].trans_id` (slang/yosys `dispatch-tid`, `SAT proof finished -
no model found: SUCCESS!`) stood throughout and is now corroborated by the
simulation itself.

**Store-age ordering — repaired.** The gate is now age-aware rather than
any-store: age is the scoreboard's circular `trans_id` order anchored at
`commit_pointer_q[0]` (in-order dispatch ⇒ SB slot order = program order), so a
store is older than a load iff `(st_id - commit_ptr) < (ld_id - commit_ptr)`
mod 2^TRANS_ID_BITS. `g6lc_lsq` exposes `st_live_mask_o` (live store tids) and
applies the same age filter in its CAM — only the youngest matching *older*
store forwards, and unresolved or data-less *older* stores stall; younger
stores can neither forward nor block. `g6lc_iq` gates LOADs on
`st_live_mask_i`+`commit_ptr_i`; `issue_stage` supplies the commit pointer.
Evidence: isolated LSQ suite 12/12 (age-select, unresolved-older stall, cp=14
wraparound, controls live); IQ gate formally proven (`issue ⟺ no older live
store`); integrated dispatch 9/9. Commit also drains on all ports now, so the
release point can move from writeback to commit without the younger-store
deadlock — still a separate change.

Still required before wider memory speculation: byte-coverage, the load-result
forwarding contract and the LSU store-buffer handoff must be settled together.

**Source-derived risks requiring separate reproducers/design:**
- Rename admission depends on `can_go`, while `can_go` depends on rename stall;
  exhaustion can form ready/enable feedback. Capacity must be computed from
  ungated intent, with state updates committed separately.
- Multi-alloc LSQ full signals expose only zero free slots, not whole-group
  capacity. (Age no longer uses slot indices: ordering is by circular
  `trans_id` distance from the commit pointer.)
- STL data no longer feeds the AGU address (the `ld_qaddr` loop is repaired);
  byte coverage and the no-forward stall path still lack an integrated
  load-result forwarding contract.
- Rename/PRF maps have no hart namespace; FP destinations avoid allocation but
  PRF/TID bookkeeping and bypass need bank/class auditing. Do not infer SMT/FP
  isolation from the in-order packages' passing checks.
- Rename restores pre-group snapshots without a resolving-branch identifier;
  older WB/commit updates and full-flush committed-map preservation need proof.
- ROB return data is not the commit authority; sparse allocation/retirement and
  cancellation must agree with scoreboard TIDs. Four-port commit configuration
  also falls through scoreboard's one-port count branch, while commit logic is
  still two-port oriented. Wider declarations do not establish wider retirement.

No OoO/L3 defaults are enabled by these repairs. Fresh protected SMT2/stream8
models match their frozen depth-two baselines across 24 execution records;
this is off-path preservation, not full-OoO promotion. See
`architecture/remaining-upgrade-sequence.md` for the cross-feature ranking.
