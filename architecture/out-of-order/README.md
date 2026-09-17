# Extension point: out-of-order execution (production path)

Program: `../router-core-upgrade-program.md` (U4 / U5).

**Status: config-gated implementation; full architectural qualification blocked.**
`OoOEn=1` routes the live dispatch/IQ/rename/LSQ/PRF path, but routing and component
passes do not establish a shipping backend. The 2026-09-16 broad RTL review
reproduces an accepted store that cannot issue; other recovery/ordering contracts
below remain unresolved. Minimal/default packages keep `OoOEn=0`. Passing SMT2 and
stream8 regressions exercise that protected in-order path, not full OoO.

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

`review-rtl-dispatch-fix-v2` passes six records on the live rename/ROB/LSQ/PRF/
memdep/dispatch/IQ path: the ALU control, the repaired store, two stores both
issuing, and an ordering guard in which a load must not issue while an older
store's address is unresolved. Injected `DISPATCH_ID` and `DISPATCH_LOAD_ORDER`
controls both fail as required, so neither check is vacuous.

**Reproduced, NOT repaired — id-matched LSQ updates never land.** Scenario 6 of
the dispatch reproducer (`review-rtl-store-wb-v3`, recorded as a known-red
expected failure) dispatches one store, waits for it to issue, then writes back
that store's own `trans_id`. `older_store_pending_o` stays asserted:
`DISPATCH_STORE_WB_RETIRE older_st=1`. The check is observed purely at the top
level and its negative control is live, so it is not vacuous.

Registered-state evidence from the same fixture: the allocated entry holds
`id == 0` instead of the dispatched `trans_id`, and `addr_v`/`data_v` remain 0
after the store issues. Every LSQ update that matches on id — writeback retire
(`st_q[i].id == complete_id_i`), AGU address (`addr_id_i`) and store data
(`st_data_id_i`) — therefore fails to find its entry. Consequences to assume
until this is fixed: store-to-load forwarding can never fire, store addresses are
never learned, and store entries are only ever released by the commit-time
"free the oldest valid store" path or by cancellation.

**Bisected: the LSQ itself is correct.** `tb_g6lc_review_lsq`
(`review-lsq-direct-v2`, kind `lsq`) drives `g6lc_lsq` directly with an explicit
`alloc_id_i`, bypassing dispatch entirely. Four records pass: allocating a store
with id 1 and completing with id 1 **does** retire the entry, and an id-matched
address followed by id-matched data **does** produce `stl_forward_o` with the
right payload. Both injected controls (`LSQ_WB_RETIRE`, `LSQ_STL_DATA`) fail as
required.

So the fault is in the **dispatch-side allocation plumbing**, not in the LSQ:
`alloc_id_i` arrives as 0 instead of the dispatched `trans_id`. The source line
`alloc_ids[p] = dispatch_sbe_i[p].trans_id` reads correct, and the neighbouring
`tid_is_st_d[dispatch_sbe_i[p].trans_id]` write does index the right bits, so the
disagreement is not yet explained by inspection. One hypothesis not yet tested:
`st_alloc[p]` asserting on a port whose `dispatch_valid_i` is low would allocate a
spurious entry carrying an unset `trans_id`, which would also keep
`older_store_pending_o` asserted after the real store retires.

Note for whoever continues: hierarchical `$display` reads of the dispatch port
arrays are **unreliable** here — they report 0 while the design behaves otherwise,
an artefact of Verilator optimisation, and that cost several wrong turns. Use a
VCD or a bound probe module; only registered state proved trustworthy.

An earlier hypothesis that writeback and commit *double-free* a store entry was
tested and is **wrong**: because the id never matches, writeback frees nothing,
so the commit-time free is currently the only release path.

Also still required before wider memory speculation: `older_store_pending_o` is
not age-aware, and commit only drains through port 0. Moving the release point to
commit without a monotonic age would introduce a *new* deadlock — an older load
blocked by a younger store that cannot commit until that load retires. Age,
byte-coverage, load-result forwarding and the LSU store-buffer handoff must be
settled together.

**Source-derived risks requiring separate reproducers/design:**
- Rename admission depends on `can_go`, while `can_go` depends on rename stall;
  exhaustion can form ready/enable feedback. Capacity must be computed from
  ungated intent, with state updates committed separately.
- Multi-alloc LSQ full signals expose only zero free slots, not whole-group
  capacity, and physical slot indices are treated as age despite freed-slot reuse.
- STL data replaces load operand A, which also forms the AGU address; byte coverage,
  youngest-older ordering and the no-forward stall path are not an integrated
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
