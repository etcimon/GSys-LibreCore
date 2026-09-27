# Extension point: L2 / L3 cache + server prefetch

**RTL:** `../../corev_apu/l2_cache/`, `../../corev_apu/l3_cache/`. Playbook:
`../../agents/guides/AGENTS-l2l3-cache.md`.

## Intent
Cache levels below L1 to cut DRAM traffic for multi-core + speculative server workloads,
without editing L1 files or weakening RVWMO.

## Hierarchy

```
cores ──► coherence hub ──► L2 ──► L3 (opt) ──► server prefetcher (opt) ──► DRAM
                                                                      │
                         island GEMM DMA (xbar master) ───────────────┘
                                      DRAM = N-channel stripe (I3)
```

DRAM channels are **not** an L2 feature. The stripe (`DramChannels`, default 64 B =
L2 line) sits on the SoC DRAM slave so L2/L3 miss fills, the server prefetcher, and
the island DMA share one map. L2 data-bank selection is
`(set * associativity + way) % banks`, not `addr[7:6]`. At eight ways/four banks
this is effectively way-based, so there is no one-bank/one-channel guarantee.
Do not let a line or AXI burst straddle `2^DramChanShift`.
Detail: [`../uncore/dram-channel-scaling.md`](../uncore/dram-channel-scaling.md).

| Level | Module | Config |
|-------|--------|--------|
| L2 | `g6lc_l2_top` | `L2En`, size/assoc/MSHR/banks; default-off `L2RoundRobinEn` experiment |
| L3 | `g6lc_l3_top` (wraps L2 engine) | `L3En` (requires `L2En`) |
| Prefetch | `g6lc_server_prefetcher` | `ServerPrefetchEn`, streams, distance |

## P2 read-response ownership increment

`review-l2-read-order-before-v1` reproduces four response-data/order failures
(same-ID miss followed by hit/bypass, nonadjacent A/B/A merge, and a pending
waiter's ID followed by another request) plus replacement of a stalled master
AR. Different-ID hit-under-miss, adjacent same-ID merging and eight same-ID
independent fills are passing controls. The bench now queues accepted requests
per ID instead of overwriting expected data with the newest offered request;
its AR driver also holds VALID/payload until actual acceptance.

The repair queries primary/waiter IDs from existing MSHR state, including killed
entries that still owe responses. Hits/bypasses wait for older same-ID responses;
a merge cannot leapfrog a later fill carrying the same ID. The existing serve
interrupt drains dependencies and resumes the captured read class. Independent
misses still allocate concurrently, including all-ones IDs used by an upper cache.
One new hold bit preserves fill-AR ownership until handshake; the issue pointer
and existing captured metadata retain its payload without another full AXI buffer.

`review-l2-read-order-after-v1` passes all 20 positives and 18 data-oracle negatives
(38 records), with master/slave AR and slave R stability assertions active.
Small RR0/RR1 synthesis checks remain check/latch clean; runtime dependencies bind
to the private corrected header. The default simulation geometry is 4 KiB/four
ways/four MSHRs/two banks; synthesis is 512 B/two ways/two MSHRs/two banks. No full
AXI/formal/production-geometry or L3-stack qualification follows. This adds ID
comparisons and a FIFO-order scan to read admission, not a pipeline stage or new
clock/reset/ISA/DTS/default. Mapped timing/area/power remains unmeasured.

Still open after the read increment: invalidation/write races, RR metadata-port
scheduling, L3/server-prefetch integration, and the main sequential leaf regression.
Atomic B/R transport lifetime is addressed by the separate increment below.

### Atomic B/R transport lifetime

`review-l2-atop-before-v2` reproduces three failures: a reserved-ID atomic R is
consumed despite requester backpressure after B releases the context; a late
non-reserved-ID R deadlocks behind a newer bypass read; a no-R atomic store never
releases the reserved-ID trail. The five R-before-B, simultaneous-B/R and plain
write controls pass. The response delay exceeds the old sixteen-cycle settling
window; a timeout is an expected failure here, never a successful transaction.

`wr_r_pending` and `wr_b_done` now retain the captured write context until B and
all required R beats have handshaken. R forwarding is ID-qualified, requires a
live write response obligation, and excludes fill-collector beats. B is forwarded
once with matching ID. No-R writes clear the reserved-ID trail; returning atomics
clear it only on accepted RLAST. The conservative settling timer remains, but it
no longer substitutes for ownership. Two state bits are added; no new pipeline,
clock/reset, configuration default or ISA/DTS capability.

`review-l2-atop-after-v1` passes all 28 positives and 26 data-oracle negatives
(54 records), plus the same small RR0/RR1 synthesis checks with no check problems
or latches. This is **transport lifetime only**: the HUM write model emits B/R
but does not perform atomic arithmetic or update backing memory, and tests never
read the written location. AMO arithmetic, LR/SC, older-fill/write visibility,
invalidation and full cache-stack qualification remain separate obligations.

### Cache-stack verification boundary

`CHAIN_L3=1` in the HUM fixture connects the real 4 KiB/four-way/four-MSHR L2
through a 2 KiB/two-way/two-MSHR `g6lc_l3_top`. The default-off path is direct
wiring and `review-l2-stack-direct-v1` passes all 54 records after that fixture
change. `review-mshr-id-query-regress-v1` passes the existing 18 MSHR records
across depth/waiter geometries 2/1, 4/2 and 8/3 with explicit unused-port ties.

Directly abutting the two controllers fails Verilator's UNOPTFLAT gate
(`review-l2-stack-chain-v1`): each side's response drives the other's request
combinationally through the packed AXI structs. The matching lowered synthesis
fixture reports zero combinational SCCs and no check problems
(`review-l2-stack-scc-v1`, `REVIEW_L2_HUM_SCC=1`), so the aggregate diagnostic is
coarser than the bit-level graph — but a zero-latency cache-to-cache abutment is
also not the intended integration. The stack fixture therefore places a vendor
`axi_cut` register slice between L2 and L3, matching a real pipelined cache
crossing at the inferred 1.25 GHz target. No gate is waived.

`review-l2-stack-chain-v4` then runs and passes 34 records across MLP and
scenarios 12–27 (positives plus data-oracle negatives) with the full data, ID,
last, B and stability oracles live and two L3 MSHRs backpressuring four L2 fills.
`review-l2-stack-direct-v2` re-confirms 54 records and both RR0/RR1 synthesis
checks after the fixture change.

**Inclusion was not exercised at all** by the first version of this fixture: it
left the outer cache's victim output unconnected, so an L3 eviction never reached
the L2's back-invalidation port. The fixture now arbitrates that port exactly as
the cluster does — the directed stimulus owns it while driving, otherwise the
outer victim does — and counts accepted victims so the scenario cannot pass
without one. Scenario 31 fills three lines mapping to the same two-way outer set,
so the third evicts the first, then re-reads the evicted line and requires the
inner cache to refetch rather than hit. `review-l2-inclusion-v1` passes 40 records;
`review-l2-inclusion-fault-v1` disconnects the victim (the original wiring) and the
scenario fails with a stale hit and no refetch.

This is mechanism engagement, not a coherence proof: with a single master the
stale copy still holds correct data, so the discriminator is the refetch, not the
returned value. Directory precision (the L3 does not track L2 residency, so it
back-invalidates on every eviction) and multi-master coherence remain open.

Two further scope limits: the zero-cut abutment remains unexercised in simulation, and
scenario 20/21's end-to-end atomic-R backpressure assertion applies only to the
direct seam, because a register slice may legitimately buffer one accepted beat.
Single-cache collision scenarios 9–11 stay on the direct path since their stimulus
aligns to one cache's own refill boundary. Inclusive invalidation, server
prefetching, coherence, ISA and physical qualification remain open.

### Production geometry does not elaborate for synthesis (open, not waived)

Putting the uncore under the gate (`corev_apu/Flist.cluster` +
`g6lc_cluster_lint_top`) immediately produced a failing synthesis result that no
leaf fixture could have shown, because every fixture used a small geometry.

At the production L2 configuration — 262144 B, 8-way, 64 B line, so **512 sets**
— the tag module's reset and maintenance loops (`for s < NUM_SETS` nested over
`SET_ASSOC`, e.g. `g6lc_l2_tag.sv:105`) exceed the slang frontend's unroll budget:
`Build failed: 2 errors` / `Design elaboration failed`, with `loop contributes to
unroll tally` naming the tag loops. Remote lint (Verilator) passes the same
geometry; only the synthesis frontend refuses it.

The tool limit is the symptom. The cause is that the tag array is **flops**, not an
SRAM macro: 512 sets x 8 ways of tag+valid state elaborated as a flat register
array. That is the anti-pattern `AGENTS.md` 0.1/0.4 forbids ("arrays via `tc_sram`
... do not instantiate raw flops for arrays"), and it is why the P2 area row lists
the tag SRAM as the first candidate.

Raising the frontend's unroll limit was refused: it would make the result green
while leaving a flop tag array in the production build. Two separable causes were
then isolated.

**Cause 1 — an unnecessary elaboration blocker, fixed.** The reset was a nested
per-set/per-way loop; a whole-array clear is behaviourally identical and is not
unrolled per set. That error is gone. It does not make the array cheaper: the tags
are still flops, which remains the open cost item.

**Cause 2 — the behavioural SRAM model, a flow boundary.** With the tag error gone,
the remaining failure is in the vendored generic `tc_sram` model
(`tc_sram.sv:130`): at production cache size its reset construct is rejected as an
asynchronous load pattern. That is the documented PDK-swap seam — a real flow binds
a compiled macro there — so it is a tooling boundary rather than an RTL defect.
The synthesis smoke therefore reduces the cache geometry **under `SYNTHESIS` only**
(lint keeps the production geometry), which checks the hierarchy's synthesizability
and latch-freedom and claims nothing about area or production-geometry closure.

**Now quantified.** The uncore lint reports the replication width of the whole-array
tag reset at production geometry: `g6lc_l2_tag.sv:112` is **3,080,192 bits** in the L3
instance (`gen_l3.i_l3.i_l3_as_l2`) and **401,408 bits** in the L2 (`gen_l2.i_l2`) —
about 3.4 Mbit of tag state held in flip-flops rather than SRAM. Those two WIDTHCONCAT
warnings are deliberately left in place: they are the cheapest standing signal of this
cost, and silencing them would hide it.

Still open: the tag array must move behind `tc_sram` before any mapped area, STA or
power claim, and production-geometry synthesis needs an approved macro. The affected
target is opt-in, so default gate runs are unchanged.

### Replacement-metadata port scheduling

One SRAM port serves both the victim-pointer read (for the request being accepted)
and the pointer update (for the fill being installed), and the update won. The read
cannot be repeated — the accepted request reaches its lookup the next cycle — so the
lookup used another set's pointer.

Reaching it required care. A continuous miss stream never collides: while fills are
outstanding the MSHR saturates and the front end parks in its lookup state, so
installs land while no request is being accepted. Scenario 30 therefore sweeps the
phase between a fill's issue and a second request's acceptance. Both the collision
count and the lost-read count are measured structurally at the RAM interface, and the
test fails as inconclusive if no collision occurred rather than passing vacuously.

With the original schedule: `collide=1 lost=1`. After the repair — the read takes the
port and a displaced update is held in one pending slot, with a later install
overwriting a held one because the pointer means "past the most recently installed
way" — `collide=1 lost=0` with all 48 requests returning correct data
(`review-l2-rr-fault-v3` / `review-l2-rr-after-v3`). The default suite re-passes 60
records with RR0/RR1 synthesis (`review-l2-rr-regate-v3`), and the sequential bench's
independent RR policy oracle passes at `RR_EN=1`.

This is a scheduling/ownership result. It is **not** a replacement-policy benefit
claim: no representative losing-case workload or mapped cost is measured, and RR
remains default-off.

One runner defect was found and fixed while doing this: a new `rr` mode variable
collided with the synthesis loop's `for rr in (0, 1)`, which rebound it to 1 and
silently narrowed the plan to a single scenario. Two "regate" runs recorded one
record instead of sixty; both are superseded by `review-l2-rr-regate-v3`.

### Invalidation source ownership

External back-invalidation and write-through self-invalidation share one tag match
port, and the external source won unconditionally, so a same-cycle snoop discarded
the write's self-invalidation and left the written line cached — the exact stale-hit
the self-invalidation exists to prevent. `review-l2-inval-before-v1` reproduces it:
with a snoop held on an unrelated line across the write, the following read is
served from the stale line and issues no refill (`HUM_SELF_INVAL_LOST ar=1`). The
kill-on-invalidation control (invalidation during an active fill still serves the
attached requester, installs nothing, and forces a refill) passes before and after.

A displaced self-invalidation is now held in one pending bit plus its address and
retired on the first cycle the match port is free; no new request is accepted while
it is pending, so no lookup can hit the line in between. External ordering is
unchanged — the snoop still wins the port. `review-l2-inval-after-v2` passes 58
records with RR0/RR1 synthesis, `review-l2-stack-chain-v6` passes 38 through the
L3 stack, and the sequential regression still passes.

Refill checks are counted at the L2 master boundary rather than at memory, because
an outer cache legitimately absorbs the refill. Limits: a permanently asserted
snoop would defer the self-invalidation indefinitely (the port is always ready, so
the source is expected to drop it), and this covers invalidation *ownership*, not
directory or multi-master coherence.

### Sequential leaf regression against the changed engine

The main sequential bench had been failing since the concurrent-fill rework: its
memory model still required a fill AR to carry the requester's id, while fills
deliberately issue under the reserved id so their beats can be routed to the
collector. The oracle now expects the reserved id for cacheable unlocked fills and
the requester's id for bypasses; the design was not changed to satisfy it. The
leaf-unit bench also needed named ties for the new MSHR outputs, since that build
promotes empty-pin and width warnings to errors.

With those corrections the sequential regression passes at 4 KiB/four ways/RR0 with
8-cycle memory and at 4 KiB/two ways/RR1 with stalls: warm, capacity, thrash,
hot-scan, write-through, non-cacheable, pseudo-random, reset-fill, all-ways-hit,
protected-hot, masked-invalidation, exclusive, bypass-backpressure, all three ATOP
schedules, post-ATOP fill, short-last guard, fill-error-no-install and
replacement-hole, plus AMO add/swap/CAS-hit/CAS-miss and LR-SC success/failure
(1520 reads, 95 writes, no MSHR-full or bank-conflict anomalies). The MSHR/data
leaf-unit suite also passes. This is the regression evidence that the read-order
and atomic-lifetime repairs did not disturb the bypass, atomic, error and
replacement paths the concurrent bench does not reach.

### Server-prefetch response ownership

The prefetcher was unsound at the response seam and is now repaired at leaf scope
(`verif/tb/l2/tb_g6lc_pf.sv`, `verif/regress/remote/run_pf_review.py`). Findings on
the pre-change RTL, each reproduced with a distinct discriminator
(`review-pf-diagnose-v1`, `review-pf-before-v3`):

- A loop-local stride variable was conditionally assigned, so the module failed
  the latch gate before any test could run. Fixed by hoisting and defaulting it.
- The outstanding-prefetch flag was retired by *any* last beat, so a demand
  burst cleared it and the prefetch beat was then forwarded upstream as a foreign
  response (`PF_UNEXPECTED_ID`, scenarios 0 and 1).
- The absorb path swallowed every beat while a prefetch was outstanding,
  regardless of ID, so demand data could be consumed.
- All demand ARs were blocked while a prefetch was outstanding, including IDs
  that cannot alias it (`PF_DEMAND_BLOCKED`).
- A prefetch could be injected while an upstream read already owned the reserved
  all-ones ID — the same value L2/L3 uses as `FILL_ID` (`PF_ID_COLLIDE`).

Injection, absorption and retirement are now qualified by the reserved ID, and a
small counter of upstream reserved-ID reads keeps at most one such transaction
outstanding. Only aliasing demand ARs are held. `review-pf-after-v2` passes 4
positives and 4 data-oracle negatives with latch/feedback errors fatal, and the
fixture synthesis reports no check problems, no latches and zero SCCs.

Scope: this is response ownership only. Prefetch accuracy, coverage, timeliness
and any bandwidth/latency effect are unmeasured, the reserved-ID throttle limits
prefetch under reserved-ID demand traffic pending an ID-width decision at the
cache boundary, and `ServerPrefetchEn` remains off in every shipped package.

## P2 concurrent-fill continuation: qualified leaf increment

The worktree now has decoupled per-entry fills rather than only same-line
hit-under-miss. This remains an **unfinished nonblocking candidate**, not an
L2/L3 release. The concurrent-reader bench `tb_g6lc_l2_hum.sv` now accepts up to
16 memory read jobs, counts outstanding accepted ARs through RLAST, preserves
FIFO/same-ID memory response order, and holds R under backpressure. Scenario 8
requires at least two outstanding fills and a clean eight-request drain.
It does not yet reorder different IDs or model concurrent atomic writes.

Three repaired contracts are exercised at their exact collision boundaries:

- Fill issue/collection increments compose with same-cycle served-entry retirement
  decrements; they no longer overwrite those decrements with registered-count +1.
- Tag publication requires the data-bank install to succeed; a bank conflict
  leaves the fill pending and cannot publish a tag for unwritten data.
- RR metadata writes use the installed fill's set/way, not the foreground request.
  RR read/write-port scheduling and policy behavior under concurrency stay open.

`review-l2-hum-collision-v2` passes 22 records. Isolated source mutations restoring
old collector, issue and tag-write assignments fail respectively with
`HUM_COLLECT_RETIRE_COUNT`, `HUM_ISSUE_RETIRE_COUNT`, and `HUM_TAG_WITHOUT_DATA`
(`review-l2-hum-fault-{collect,issue,install}-v1`). The first issue-collision
stimulus deadlocked itself by queuing the second request after stalling the serve
FSM; the corrected test queues it during the first fill. That failed test is
retained, not attributed to an RTL defect.

Strict slang then exposed declaration-before-use of `fill_kill_q`. Moving the
declaration, separating victim selection from the probe-consuming FSM, using
registered MSHR lookup rather than alloc-qualified merge feedback, and removing
an unnecessary waiter-index temporary resolves the elaboration failure and all
reported LATCH/UNOPTFLAT warnings in this leaf. `review-l2-hum-clean-v1` passes all
22 simulation records plus RR0/RR1 synthesis at 512 B, two ways, two MSHRs and two
banks. Both synthesis checks report zero problems and no latch cells; unchanged
`tc_sram` unreset-read-output warnings remain, as do benign-width warnings in the
simulation build. The runner now treats LATCH/UNOPTFLAT as errors;
`review-l2-hum-gated-v1` repeats all 22 records successfully with those gates.
Compiler dependency files bind the model to the pinned private corrected runtime.
This is not
all-width/production-geometry, mapped physical area, STA, power or MBIST evidence.

No state capacity, clock/reset, ISA/DTS or configuration default is added by these
repairs. The timing-relevant cones are victim select/probe, install bank-conflict
qualification and fill-counter arithmetic; no Fmax claim follows from lint/synth.
No throughput gain is attributed to the repairs: the earlier serial-memory and
new queued-memory fixture timings are not a matched performance comparison.

Still required: same-ID miss/hit/bypass and nonadjacent-merge response ordering;
held fill AR stability across bypass arbitration; invalidation/install/write
races; exact delayed ATOP-R lifetime; L3/server-prefetch demand ownership; the
main `tb_g6lc_l2.sv` model's serial/ID assumptions and its error/atomic regression;
MSHR unit/formal requalification; source-bound integration; production geometry
and physical gates. `../remaining-upgrade-sequence.md` records these prerequisites.

## Completion plan after methodology review (2026-09-15)

The active implementation order is the 2026-09-16 E1–E6 efficiency review in
`../../AGENTS-todo.md`; F0–F5 are retained as qualification gates, not another
sequence of policy features. Preserve the RR metadata SRAM and existing
AXI/SRAM interfaces; fix instruction-supply correctness in its owning RTL
before measuring policy benefits. Prefer fewer ranking/mux/state costs where
an accepted-stream invariant can replace recovery heuristics. Do not change
SMT scheduling or production execute/cacheability regions to make a benchmark
pass.

A single-worker checked-work PASS on the SMT2 package does not close SMT2:
two-active-hart progress/isolation, release/acquire and atomic controls plus
natural firmware are separate gates. Historical `7e6c19c54` index skew was
fixed in `9fbab3044`; current-tree failure attribution remains open. The fetch
formal review found impossible hart-range assumptions, so their previous PASS
labels cannot support promotion. All old RR-specific livelock claims below
are historical and superseded, not evidence of a replacement-policy defect.

Compare each candidate at identical geometry, tool, clock constraints and
workload: checked results, ROI cycles, L1/L2 traffic, storage bits, mapped cells
and critical path. Include workloads where RR loses. Generic synthesis and
structural timing are screening only; macro area/MBIST, STA and power remain
physical gates. Production-geometry blackbox equivalence is a controller/port
result, not a full-memory proof.

## Efficiency-first next discriminators (2026-09-16)

**Cacheability precedes replacement policy.** There are two distinct paths:
`g6lc64_stream8` uses HPDCACHE_WT, whose load adapter ORs executable-region
membership into uncacheability; that package's execute window covers its
cached DRAM window. `g6lc64_smt2` uses WT, whose `axi_shim` supplies
`CACHE_MODIFIABLE` without allocation bits, while `l2_is_cacheable` requires
an allocation bit. Zero L2 policy sensitivity does not establish that either
hierarchy is optimally used. This is not a claim that WT L1 itself is uncached.

The first HPDCACHE experiment is now complete: a byte-identical A/B of the
existing `mini_hpd_2jr.S` on the current fetch and corrected runtime, with only
the execute-region load exemption removed in an isolated diagnostic source copy.
Keep production regions, workload bytes, geometry and RR policy fixed.
`mini_hpd_2jr_data.S`, `_pad.S` and `_fencei.S` are controls, not interchangeable
ELFs or proof that only layout changes between their sources. Confirm the
actual linked instruction/table placement. Log accepted loads, physical
addresses/PMA, grants/aborts, response IDs/data and retirement around the second
indirect dispatch. A repeated failure must identify the first broken boundary;
a PASS must also demonstrate real cacheable allocation/hit activity before it
can retire the old workaround. Natural firmware, cacheable stores/fences,
MMIO/exclusive bypass and concurrent invalidation remain follow-up gates.
Historical SIGSEGV-based negatives do not prove RTL failure on the corrected
runtime. Do not repeat register/opcode-specific fetch cuts from the S4 ledger.

The WT path needs its own attribute contract before any edit: classify accepted
L1 refills, uncached accesses, writes and exclusive/ATOP operations, then relate
their AXI attributes to L2 tag admission. Do not globally mark WT traffic as
allocating or relax `l2_is_cacheable`; either can pull MMIO/ROM/exclusive traffic
into a line-fill path. Changing only RR is not a discriminator for this path.

### Executable-data witness result (2026-09-16)

`review-cacheability-pair-20260916` builds fresh stream8 observer-capable models
from the validated circular-IQ snapshot. Baseline `2c222402…` retains the
execute-region load exemption; candidate `b970be74…` uses cached-region PMA only.
Configuration, IQ, typed observer and cache observer hashes match, with the
private runtime `dfbc2c4a…` verified in compiler dependencies. The candidate
adapter exists only in the isolated run tree; production RTL/regions/AXI/RR
remain unchanged. All eighteen records pass: original witness off/on/on plus
three controls off/on under each policy. Repeated traces and observer off/on
retirement/cookie fingerprints match within each model. The common 10,240-cycle
cookie poll is not a performance measurement.

The linked original witness retains `lw` at `0x80000090`, indirect dispatch at
`0x80000094`, table at `0x800000a8`, and targets `0x80000096` / `0x8000009e`.
The table words are -18 / -10 relative to the table base. Raw cache and typed
operand traces show:

| Boundary | Execute-uncached baseline | Cached-PMA-only candidate |
|---|---|---|
| First table read | Uncached request for `0x800000a8`, no D-cache installation | Cacheable fill for line `0x800000a0`, installed at t=447 |
| Second table read | Request t=495, response t=500; `uc=1`, `hit=0` | Request t=521, response t=522; `uc=0`, `hit=1` |
| Architectural value/target | Sign-extended -10, target `0x8000009e`, expected result 3 | Same checked value/target/result |
| PASS store request | t=555 | t=573 |

This shows real cache use and no recurrence of the historical jump-table hang
in the checked envelope, not merely cookie agreement. It does not identify
which intervening fix removed the old symptom. The warm load is faster, but
the first phase/stack cold reads take longer and the candidate PASS-store
boundary is later. No aggregate speedup or production exemption-removal decision
follows; a complete per-cycle cost attribution is still open. The larger controls below reuse
these models and existing byte-identical checked-work/hot-scan ELFs without a
new model build, observer enablement or RR change.

`run_checked_work_review.py` with `REVIEW_CACHEABILITY=1` creates the pair and
observation-only cache wrapper. `REVIEW_CACHEABILITY_WORK=1` reuses the pair for
the larger controls, reporting stable PMU samples with source/model/ELF hashes.
The original typed reference checker is not claimed to cover all compressed
load/store and CSR instructions in these minis; the table-value/target checks
above are scoped trace review against the linked symbols and instruction bytes.
Natural firmware, store/fence/error/invalidation/atomic qualification and the
separate WT attribute contract remain open. Artifacts are on the approved C:
path, with remote source trees and raw traces retained.

### Larger cacheability controls and priority correction (2026-09-16)

`review-cacheability-work-20260916` reuses the exact pair above. Two serial
trials of each model/workload give eight PASS records, with matching per-case
retirement, cookie and reported-counter fingerprints. Source/ELF/model/runtime
hashes are rechecked; no model is rebuilt. Checked-work ELF `57c9e51f…` passes
at cookie polls 167,936 / 174,080 (baseline/candidate), not precise completion
latencies. Hot-scan ELF `69ef15f4…` also passes; its stable reported deltas are:

| Warm+scan report | Execute-uncached | Cached-PMA-only |
|---|---:|---:|
| Cycles | 275,593 | 374,177 |
| L2 miss events | 4 | 18,788 |
| L1D miss events | 0 | 19,370 |
| Load events | 20,483 | 20,483 |
| Store events | 7 | 7 |
| Data-request events | 20,492 | 20,524 |
| I-cache miss events | 17 | 79 |

These deltas include cache warm-up and scan/report boundaries but exclude the
initial data fill. Final repeated host samples agree; the total sample counts
also include pre-report zeros and are not counts of independent measurements.
Do not sum duplicated shared-cache counters across cores or interpret request
level events as distinct accepted memory transactions.

**Decision:** the candidate uses 98,584 more ROI cycles (+35.77%) in this
workload. Restoring cache use is a functional/workaround-retirement candidate,
not an established performance improvement. Keep it isolated and retain RR=0.
The jump-table warm hit is genuinely faster, but that does not predict the
streaming/conflict workload's aggregate result. The I-cache event increase also
means the entire delta must not be assigned to D-cache replacement alone.

Next high-information work: compare a repeated cache-resident working set with
the existing conflict/scan control, then measure accepted refill service and
I/D arbitration under stated memory latency/backpressure. Use one fixed baseline
and vary one dimension per experiment. The serialized L2 controller and cheap
uncached returns in the short trace are grounded mechanisms to investigate,
not a completed causal decomposition of these ROI cycles. Do not grow MSHRs,
change RR, weaken execute-region permissions or claim DRAM/physical performance
to obtain a favorable number. Store/fence/invalidation/error/atomic and natural
firmware gates still precede production removal of the exemption.

### Reassessment: memory efficiency and multicore prerequisites (2026-09-16)

The retained IQ/predictor gains do not authorize a cacheability or RR default
change. Next comparisons must use a matched post-predictor baseline and state
whether imposed CPU-visible delay affects command acceptance, first response or
each beat. The island-only timing flag is not a CPU DRAM-latency experiment.

Before increasing multicore traffic, reproduce the shared-path source scenarios:
held AR/AW payload/ID changes when arbitration or free-slot selection changes,
AW eligibility with one free slot and no competing AR, accepted writes without
invalidation credit, coalescing for one target while another is full, and
acknowledgment of an unselected inclusive source. The multiple-target hub case
needs N≥3; inclusive conflicts require the L3-enabled path. Two invalidation-leaf
cases are now reproduced and repaired (`architecture/multi-core/README.md`).
Five isolated hub failures are subsequently reproduced in `review-hub-before-20260916`
(held AR/AW, held ID, one-slot AW credit and accepted-write notification loss).
The held-address/ID and phantom-credit cases are subsequently repaired with
owner/slot reservations (`review-hub-reservations-20260916`); accepted-write
notification loss remains open. These are not end-to-end failures reproduced in
the passing SMT2/stream8 controls; inclusive-source tests and integration
qualification remain separate. A finite invalidation
queue cannot make coherence best effort.

A cheaper serial-L2 control screen can precede nonblocking design: prove maximum
live demand occupancy, then compare current MSHR depth with 4 and 2 at unchanged
latency, geometry and interfaces. Depth 1 is not assumed safe: public MSHR ports
use `$clog2(DEPTH)-1:0`, and a one-entry table changes full-event behavior. Before
merging/concurrency, also check merge-full admission and bind saved request IDs,
not a live AR bus sampled after acceptance.

For the 256 KiB/eight-way/64-byte/64-bit-address case, tag storage represents
200,704 tag bits plus 4,096 validity bits. Study SRAM payload plus controlled
validity initialization at the existing memory boundary; no physical savings
are inferred from the bit count. A one-cycle SRAM read may fit accepted-AR/S_TAG
scheduling, but lookup/probe/install/invalidation ports and producer backpressure
must be solved together. Current unconditional back-invalidation readiness cannot
be silently replaced by a stall. Do not combine this conversion, concurrency and
replacement policy in one experiment. Detailed ordering is in `AGENTS-todo.md`.

### Serialized-MSHR sizing measurements (2026-09-16)

`review-l2-size-20260916` compares depths 16/8/4/2 at fixed 4 KiB, four ways,
two data banks, 64-byte lines, RR off and the same existing independent leaf
reference. Memory-service profiles are first-beat delay 6 with no periodic stall,
and delay 24 with a 1-in-3 beat stall. No production RTL/config is changed.

Across all depths, every phase and the complete timestamped accepted-transaction
trace match byte-for-byte within each service profile. Each profile completes
1,516 reads, 95 writes, 143 hits, 1,348 misses and 1,243 evictions, with peak live
MSHR occupancy one and 1,348 allocations/completions. Total cycles are **31,108**
and **61,659** respectively, independent of depth. This is no measured speedup
and no measured slowdown. Observer off/on/repeat agree; all eight occupancy
mutations are detected (24 positive and eight negative runs).

| MSHR depth | 512 B / two-way fully mapped generic cells | Sequential cells | 4 KiB / four-way logic with fixed data macros excluded | Sequential cells outside data macros |
|---|---:|---:|---:|---:|
| 16 | 23,953 | 7,202 | 33,647 | 5,143 |
| 8 | 21,221 | 6,704 | 30,897 | 4,645 |
| 4 | 19,890 | 6,454 | 30,000 | 4,395 |
| 2 | 18,913 | 6,328 | 28,840 | 4,269 |

Depth16→2 removes **874 sequential cells** in either fixture. Generic-cell
reductions are **21.04%** and **14.29%**, respectively. These are not percentages
of a production 256 KiB L2 or whole-core physical area. The large-fixture report
keeps the two unchanged `tc_sram` data macros (32,768 storage bits) outside the
logic count; tags and MSHRs are real/mapped. Both reports exclude `$scopeinfo`
metadata. Raw Yosys totals, cell types and macro counts remain in the artifacts;
`review-l2-size-assessment-20260916` derives the presentation from frozen data
without rerunning synthesis. No latches/check problems are reported; existing
width warnings in the source/vendor fixture are not relabeled as clean lint.

`review-l2-occupancy-v2-20260916` proves the live controller's one-MSHR invariant
by two-step binary induction at depths 16 and 2 in a 512 B/two-way/two-bank fixture,
with no input assumptions. It checks count/state correspondence, only slot zero
live, no extra waiters and zero allocation/completion indices. Live and completion
covers are reached within 16 steps, and an allocation-index checker mutation fails.
This is an occupancy/lifecycle proof, not a general bus-data equivalence or full
memory-order proof. A first attempt hit a frontend enum-reference error; the
successful harness uses source-validated numeric state encodings, not weaker
assumptions or a modified DUT.

**Promotion assessment:** depth two is the strongest measured area candidate for
the current serialized service. Do not select depth one blindly: its public index
widths and full-event behavior have separate concerns. Keep the generic multi-MSHR
leaf intact for future nonblocking work. Before changing named defaults, qualify
256 KiB/eight-way/four-bank geometry and matched SMT2/stream8 source/config/runtime
integrations; the protected SMT2 depth remains 16 and stream8's zero field still
auto-resolves to eight. Preserve current hub repairs in both A/B builds and retain
the independent dual-hart checks. Physical timing/area, full platform verification
and coherence release qualification remain separate. No cacheability/RR/clock or
SMT scheduling policy is promoted by this result.

Reproduction: `run_l2_size_review.py` runs the existing leaf with opt-in
`+mshr-observe`, `+mshr-trace` and `+mshr-negative`; `REVIEW_L2_SIZE_PROOF=1`
selects the occupancy proof. The static fixture's new `MSHR_DEPTH` parameter
defaults to four, preserving earlier equivalence/synthesis behavior.

### Production-shaped depth-two qualification and scoped promotion (2026-09-16)

The next leaf run uses real 256 KiB/eight-way/four-bank tag/data RTL, not the small
fixture. Depths 16/8/2 match all 17 phase reports and full timestamped accepted
transactions at memory latency6/stall0. Each completes 31,704 reads, 591 writes,
30,822 allocations/completions and 668,512 cycles, with peak one MSHR. Nine
positive observer controls and three injected-occupancy negatives pass.

The initial synthesis stage hit the frontend's 4000-iteration limit for 4096 tag
entries. The retry raises that frontend limit to16384 and reuses the completed
simulation evidence rather than rerunning it. `review-l2-production-area-20260916`
measures only mapped controller/MSHR/bank logic, with one unchanged tag module and
four unchanged data macros blackboxed. Its counts exclude those five blocks and
scope metadata; they are **not whole-cache or physical area**:

| Depth | Mapped-portion generic cells | Sequential cells in that portion |
|---|---:|---:|
| 16 | 15,539 | 1,625 |
| 8 | 12,727 | 1,127 |
| 2 | 10,844 | 751 |

Thus the measured incremental reductions are 4,695 cells/874 state cells from16,
or 1,883/376 from8. No timing/energy percentage follows from this partial area model.

`review-l2-occupancy-production-v2-20260916` passes two-step occupancy induction
for depths16/8/2 at the production dimensions, with live/completion covers and a
checker negative. Tag-hit and bank-conflict are explicit unconstrained formal
cutpoints, so the controller invariant must hold for arbitrary cache outcomes.
This is a compositional control proof, not tag/data correctness or bus-data
equivalence. The earlier 180-second attempt stalled in preprocessing before the
cutpoints; moving them before preparation preserves the predicates and budget.

`review-l2-size-integrations-20260916` completes both matched integrations on
fresh copies with current IQ/predictor/hub/invalidation RTL pinned on both sides.
Elaboration-time probes check effective depth, geometry and core/hart counts.
SMT2's16→2 pair passes all13 execution records per side with identical cookies,
retirement/operand traces and independent reference results. The dual-active RVI
and mixed-C references retain 13699/14203 retirements,25774 operand checks and1025
known loads each (one peer-flag value remains unchecked). Both48 KiB/hart workloads
and redirect-chain controls pass. Stream8's8→2 pair passes ten positive workload
records plus the expected negative per side; all reports, cookies and retirement
traces match. Hot-scan remains262740 ROI cycles; locality remains147470/147470/
147467 for1/8/64 KiB. These are preserved benefits, not a new speedup.

The source-delta audit permits only the selected package's MSHR value and the
private observer-path/geometry-check differences, normalizes those exact edits,
and requires all other consumed inputs to match. Full child logs/manifests/traces
are retrieved in `review-l2-integration-evidence-20260916`; completed jobs were
not rerun for capture. Four model builds pass, with unchanged warning levels within
each pair (SMT2 two; stream8 twelve), not a warning-free or full-platform claim.

**Scoped promotion:** `g6lc64_smt2` changes L2MshrDepth16→2 and `g6lc64_stream8`
changes its zero/auto-eight field to explicit2. Retained package hashes exactly
match tested candidates: `b61109d7…` and `f2c564c9…`. The generic MSHR leaf and all
other packages/default inference are unchanged, preserving the future multi-miss
seam. No new RTL stage, reset, clock, buffer, ISA/DTS field or software interface.
Smaller CAM/selection logic is an area/timing-cone improvement candidate, not STA
or power sign-off. Cache geometry, RR/cacheability and SMT scheduling stay fixed.

Candidate model identities: SMT2 `f6697765…` (baseline `6623fe63…`); stream8
`af3503d9…` (baseline `d410b552…`). The prior measurements' unchanged-default
flags remain historical records, not rewritten as promotion evidence. Full
source-bound platform verification, physical implementation, broader ISA/FP and
coherence/visibility qualification remain open; the hub invalidation-loss test
still fails and is not waived by these matched results.

### Same-line hit-under-miss (first nonblocking increment)

**Starting state.** `g6lc_l2_top` was strictly single-transaction: `S_IDLE`
accepted one request and a miss ran `S_TAG → S_MISS_AR → S_MISS_R →
S_MISS_INSTALL → S_HIT_RESP → S_IDLE`. The controller is only ever in `S_TAG`
when no fill is outstanding, so `mshr_merged` could never be true and
`waiter_pop_i` was hardwired to `1'b0`. That is why MSHR depth measured
irrelevant earlier: peak occupancy was structurally one.

**Change.** While a fill is outstanding (`S_MISS_AR/R/INSTALL` only), a further
cacheable, non-locked read to the **same line** is accepted and parked as an MSHR
waiter; after install each waiter is popped and served from the filled line with
its own AXI id and its own beats. MSHR completion moved from `S_MISS_INSTALL` to
the end of the response so the entry stays valid while waiters drain. Merges are
refused during the drain, which bounds the waiter list and makes termination
trivial. `g6lc_l2_mshr` gained a per-waiter payload channel (`META_WIDTH`,
`alloc_meta_i`, `waiter_meta_o`) that shifts in lockstep with the waiter ids and
is excluded from every admission, ordering, occupancy and completion equation.

The payload stores only the in-line **offset** plus len/size, not the full
address: a waiter is on the primary's line by construction. Storing the whole
address first cost **+634 flops at depth 2** versus **+170** for the offset form —
about 4x, for no added capability.

**Measured (leaf fixture, 4 KiB/4-way/2-bank, memory latency 8).**

| Stimulus | Baseline | Candidate |
|---|---:|---:|
| 8 readers of one shared line | 50 cycles, 1 fill | **42 cycles**, 1 fill, 4 merges |
| 8 readers of 8 distinct lines | 176 cycles, 8 fills | **176 cycles**, 8 fills, 0 merges |

The gain is the removal of request-acceptance serialisation behind an in-flight
fill. It is **not** a DRAM-traffic reduction: the baseline already absorbed later
same-line readers as post-install hits, so the fill count is 1 either way. The
different-line control is unchanged, confirming no regression where merging
cannot apply.

Area for the mapped controller/MSHR/bank portion:

| MSHR depth | Cells before → after | Flops |
|---|---:|---:|
| 2 (production default) | 32,609 → **32,910** | 4,281 → 4,451 |
| 8 | 33,899 → 38,106 | 4,693 → 5,367 |
| 16 | 37,323 → 44,394 | 5,239 → 6,585 |

Cost scales with `depth × MAX_WAITERS`; at the promoted depth of two it is +301
generic cells and +170 flops, which does not undo the earlier depth-two saving.

**Evidence.** `review-l2-hum-v3`: seven contract scenarios and five injected-error
controls pass — same-line merge with observed merge count (engagement proven
directly, not inferred), waiters with a different len/size/offset than the
primary, one more same-line reader than there are waiter slots, refusal of
different-line/non-cacheable/locked requests during the fill, and primary-then-
attach-order service. `review-l2-hum-baseline-v3` reproduces `HUM_NOT_ENGAGED` on
the pre-change build, so the contract test is not vacuous.
`review-l2-hum-regress-v5` vs `review-l2-hum-baseline-v1`: all 32 existing L2
records over depths 16/8/4/2 and both memory profiles are **phase-identical**,
compared against a matched baseline build rather than a figure from an older
harness revision. `review-rtl-audit-mshr-meta-v1` re-runs the MSHR proofs
unchanged and they still pass, which is the evidence that the payload channel is
non-intrusive.

**Still not nonblocking.** Only one line fill is outstanding at a time; misses to
*different* lines still serialise (8 distinct-line readers remain 176 cycles with
8 fills and no memory-level parallelism). Multiple concurrent DRAM fills with
response routing/reordering, waiter response-error handling, and write
interleaving remain the open P2 work. No end-to-end speedup is claimed: every
SMT2 and stream8 cookie is unchanged (below).

### Generic MSHR merge/retention repair (broad RTL review)

The live generic leaf previously advertised ready for a matching full waiter queue
when some other entry was free, but could not retain the accepted waiter. A
simultaneous completion and same-line merge could also leave a waiter on an invalid
entry. Admission now selects matching-entry capacity rather than ORing unrelated
free capacity; pop precedes append, append uses the post-pop index, and completion
checks post-append occupancy. Concurrent allocation at another slot preserves count.
No state or interface is added; completion still frees only after waiters drain.

Depth/waiter combinations2/1,4/2,8/3 pass directed controls and oracle mutations,
including full+pop+merge and complete+merge. Ten-step symbolic checks cover count,
entry uniqueness, waiter bounds and admission; full-tail/joint/retained cases are
reachable. Standalone16-bit-address/four-bit-ID synthesis grows878→1003 cells at
D4/W2 and1995→2095 at D8/W3, with127/284 state cells unchanged. This is a measured
correctness cost, not an area win.

The current L2/L3 top is still serial and ties waiter pop low. Fresh SMT2/stream8
models with the repaired leaf match all24 frozen depth-two records, including
cycle/cookie, retirement/operand trace and ROI identity. That preserves the prior
named-package behavior; it does not establish nonblocking L2/L3 operation or new
physical-area numbers for the earlier sizing promotion. Waiter response/data
routing, refill error handling, eviction retention and coherence remain separate.

Evidence: `review-rtl-audit-before-v2`, `review-rtl-audit-after-v1`,
`review-rtl-audit-quality-rest-v3` and `review-rtl-audit-integrations-v1`.

### Checked locality probe (2026-09-16)

`mini_l2_hot_scan.S` adds an opt-in `G6LC_LOCALITY_PROBE` path. Its default
hot-scan instruction bytes remain identical to HEAD when compiled with the same
linker/toolchain (`.text` SHA256 `a75aac75…`, local cross-compile only). The probe
initializes a ring `next(i)=(i+37)&(N-1)`, checks every loaded pointer, warms N
loads, then measures exactly 8,192 loads. It captures PMU endpoints in registers
before report stores and checks the reported load count and zero ROI stores.
Working sets are 1/8/64 KiB (128/1,024/8,192 nodes); the predicate and measured
work are fixed, and each ELF is byte-identical across the two existing models.

The first diagnostic link failed because `.data` overlapped the report inside
`.tohost`; `locality.ld` now places `.data` at `0x80001100` while report remains
`0x80001080`. The failed run is retained, not classified as RTL failure.
`review-cache-locality-v2-20260916` completes twelve positive trials (two per
case/model) plus two correctly detected negative controls. Negative records keep
cookie 3 / functional FAIL and a separate `matchedExpected=true`; they are not
relabeled as workload PASS. The models/runtime are reused without rebuilding.

| Working set | Execute-uncached / PMA-only ROI cycles | PMA-only L1D miss events | I-cache miss events, both policies |
|---|---:|---:|---:|
| 1 KiB | 213,009 / 213,009 | 0 | 8,195 |
| 8 KiB | 213,009 / 213,009 | 0 | 8,195 |
| 64 KiB | 213,006 / 213,006 | 4,567 | 8,196 |

All cases report 8,192 loads, zero stores and 8,192 data-request events; L2 miss
report is one. Each positive pair repeats identically. ROI excludes initialization
and warm-up, unlike the earlier warm+scan report, so these absolute cycle totals
are not interchangeable with that report. The loop's validation arithmetic also
provides independent work between dependent loads and can hide short memory
latencies; this is checked-work throughput, not a pure load-latency measurement.

**Preliminary mechanism analysis:** the unexpectedly high I-cache count is about
one per loop iteration despite a tiny instruction footprint. Competing accounts
are genuine repeated instruction refills versus an event/measurement association
problem; neither is settled by aggregate PMU data. E2 therefore next observes
accepted I-cache requests, tag comparison, refill/kill/install and PMU pulses on
the same ELF. A new observer must preserve its baseline retirement/cookie trace.
Do not change data cache policy, RR or pipeline timing before that distinction.

**Validated instruction-refill observation:** `review-locality-icache-trace-v2-20260916`
reuses the observation-only model `aab9ad4b…`. Its off/on/on runs preserve the
baseline cookie and byte-identical retirement streams, with repeated enabled
traces identical. The first attempt's control comparison was a Python tuple/list
normalization error, not an execution difference; the model was reused rather
than rebuilt. Capture is a bounded first-30,000-tick prefix, not a full trace.

The large I-cache count reflects genuine wrong-path requests. For example,
at t=2774 the not-taken pointer check at `0x80000164` predicts its FAIL target
`0x80000134`; at t=2776 the I-cache accepts a miss for line `0x80000130`.
Resolution at t=2777 correctly selects `0x80000168`, kills the miss, and its
response drains at t=2782 without installation. The same sequence repeats.
The loop's own lines hit; this is not evidence of insufficient I-cache capacity
or inclusive L2 eviction. The repeated wrong-path fetch also explains why a
low L2 miss count can coexist with many I-cache miss events.

**Next candidate, isolated until checked:** align asynchronous predictor lookup
with the current response transaction. Source review shows instruction bytes
are scanned from `realigner_vaddr`, but ASIC `vpc_bht`/`vpc_btb` still select the
previous response's `icache_vaddr_q`; training uses the resolving instruction PC.
This can leave the current branch falling back to a wrong static prediction.
The pilot changes only ASIC lookup PC selection, retains the FPGA phase rules,
and does not change predictor capacity, I-cache kill/install semantics, cache
policy or pipeline depth. `review-predictor-response-pc-20260916` preserves the
checked instruction prefix and passes off/on/on controls, but reports 213,012
ROI cycles and the same 8,195 I-cache miss events. A few early predictions improve;
steady-state misprediction returns. The PC-alignment candidate is therefore
NOT a sufficient optimization and remains unpromoted.

The next isolated discriminator concerns `g6lc_bp_statcor`: training increments
for taken and decrements for not-taken, but a low counter inverts the incoming
prediction. An absolute outcome counter is not an inversion-error counter. Test
a consistent absolute interpretation (confident low selects not-taken, confident
high selects taken, middle defers) atop the response-aligned candidate. This is
not permission to rewrite predictor training or add state without evidence.
`review-predictor-absolute-sc-20260916` validates this combined pilot on the same
1 KiB ELF: 147,470 ROI cycles versus 213,009 baseline (65,539 fewer, -30.77%),
with I-cache miss events 3 versus 8,195. All three off/on/on records agree;
each reports 8,192 loads, zero stores and one L2 miss. The untimed core-0
instruction prefix through the checked-work exit boundary matches the baseline,
and the program's per-pointer and load-count checks pass. Post-exit polling
spins are deliberately outside that instruction-prefix comparison; full timed
traces match within the candidate's observer controls. Captured branch events
show the not-taken check remaining correctly predicted after training rather
than reverting to persistent misprediction. No claim is made that this check
is a complete ISA reference model.

The initial candidate used copied run trees through `REVIEW_PREDICTOR_CANDIDATE=1`
plus `REVIEW_SC_ABSOLUTE=1`. Subsequent qualification retained its functional
changes in `core/fetch_B/frontend.sv` and `core/frontend/g6lc_bp_statcor.sv`.
PC-alignment alone remains a recorded insufficient candidate, not a claimed win.
Cacheability and RR are unchanged; no state capacity or pipeline stage is added.

**Qualification and retention:** the independent corrector bench first fails
on the original inversion and then passes six slot/RVC/table geometries, with
negative controls, saturation, alternating/bursty outcomes, alias sharing,
concurrent read/update and reset/flush priority. A symbolic 64-bit selector check
proves ASIC current-transaction selection and preservation of FPGA selector
expressions; its wrong-PC control fails. It is not a full stateful frontend or
FPGA-memory proof. Full-core SMT2 and stream8 synthesis smoke report zero check
problems. Matched corrector leaf synthesis is 1,261 → 1,360 generic cells (+99),
with 192 state bits unchanged; no physical area/STA/power claim.

Fresh SMT2 integration passes all 13 records, including independent RVI/mixed-C
references (13,699/14,203 retirements; 25,774 operands and 1,025 known loads each),
negative controls and both 48 KiB/hart cases. One peer-flag value remains unchecked.
Broader stream8 replay passes eight positives plus one expected negative:

| Unchanged-cache-policy control | Baseline ROI | Retained predictor ROI |
|---|---:|---:|
| Hot-scan warm+scan | 275,593 | 262,740 (-4.66%) |
| 8 KiB checked locality | 213,009 | 147,470 |
| 64 KiB checked locality | 213,006 | 147,467 |

Reports and retirement fingerprints repeat within each model. Hot-scan still
reports 4 L2 / 0 L1D / 17 I-cache miss events, 20,483 loads and 7 stores;
locality reports exactly 8,192 loads and zero stores. The ordinary checked-work
cookie poll remains 167,936, not an exact ROI performance measurement.

Artifacts: `review-statcor-contract-v2-20260916`, `review-predictor-smt2-20260916`,
`review-predictor-work-20260916`, `review-predictor-synth-20260916`,
`review-predictor-pc-proof-20260916`, `review-predictor-promotion-20260916`.
Retained non-comment source matches the tested prototype. Default minimal-target
lint/strict elaboration and explicit SMT2/stream8 checks pass. The separate
PH_BHT registered port is unchanged and outside the repaired selector scope.
Mapped timing/power, natural firmware and broad ISA/FP/ordering remain open.
IQ ordering subsequently passes unbounded induction and all twelve covers in its
reduced formal envelope; broader IQ geometries/FPGA/RVH remain separate. No
cacheability or replacement-policy promotion is implied.

Source review also limits the latency claim: the default CPU memory backend is
class-0 AXI-to-SRAM, and the testharness delayer has zero added delay. The
`G6LC_AI_DRAM_TIMING` model delays island DMA, not CPU requests. I-cache requests
enter a one-entry holding FIFO before a fixed-priority I/D arbiter; index zero
(I-cache) has priority, and a stalled grant is held. The connected L2 still
serializes through its final response. These are mechanisms to instrument, not
an attribution of all observed cycles. Any future latency/backpressure experiment
must operate on the CPU-visible path and name the imposed service model; it is
not DDR or physical timing qualification.

**Area follow-up:** `g6lc_l2_tag` has resettable flop tags/valids and asynchronous
indexed lookup, whereas `g6lc_l2_data` uses one-cycle `tc_sram` banks. At the
256 KiB/eight-way/64-byte/64-bit-address envelope, the tags plus valid bits are
204,800 logical storage bits. This is a size calculation, not a mapped-area
measurement. A tag-SRAM study must resolve lookup, victim probing, install and
address-match invalidation ports; the current always-ready back-invalidation
contract cannot be preserved by simply replacing the array declaration.
Obtain approved SRAM/library views, timing constraints and MBIST/test access in
parallel; no physical saving or hit-latency guarantee exists yet.

**Concurrency follow-up:** retain the current serialized top while measuring
it. The presence of multiple MSHRs and data banks does not provide overlapping
miss service; merged waiters are not drained. Nonblocking control and smaller
supported serialized geometry are alternatives to evaluate from actual stall
and mapped-cost evidence, not changes to combine with tag SRAM and RR in one
candidate. See E1–E6 in `../../AGENTS-todo.md` for priority and retained gates.

## Evidence compartments (do not mix)

| Lane | Files | Purpose |
|------|--------|---------|
| L2 RTL | `corev_apu/l2_cache/g6lc_l2_{top,tag,data,mshr,pkg}.sv` | Cache engine; `RR_EN` generate is default-off |
| Leaf sim | `verif/tb/l2/tb_g6lc_l2.sv`, `run-l2-tb.sh` `L2TB_MODE=sim`, proxy `l2-leaf --mode sim` | Replacement/bypass/AMO-arith at the L2 pin |
| Leaf units | `verif/tb/l2/tb_g6lc_l2_units.sv`, `--mode units` | MSHR merge/full/waiter + data bank-conflict only |
| Leaf synth | `run-l2-tb.sh` `L2TB_MODE=synth`, `--mode synth` | Generic `$mem_v2` / cell counts; not STA |
| Equiv | `run-l2-tb.sh` `L2TB_MODE=equiv`, proxy `l2-equiv` | RR-off vs pinned pre-RR; map/collect/bbox |
| Isolated overlay | `verif/regress/isolated-config-overlay.py` | Copies one package; allowlist `L2RoundRobinEn` only |
| Cluster CRT | `mini_amocas_{w,d,q}.S`, `mini_stream_plane.S`, `qualify-stream8-minis.sh` | Zacas/stream functional; not L2 ROI |
| Isolated core | `mini_checked_work.S`, `mini_l2_hot_scan.S` | Fill/verify and hot+scan; not CRT minis |
| SMT2 | `g6lc64_smt2`, `qualify-soft-ladder-osbi.sh` | Cookie soak; do not pair RR-on until fetch is approved |
| OoO formal | `core/ooo/formal/g6lc_ooo_rename.sby` (+ cover, path-check only) | Rename BMC vs covers; remote z3 cover TIMEOUT; not an L2 gate |

Proxy kinds stay split: `rtl-leaf-diagnostic`, `rtl-leaf-units`, `rtl-leaf-synth`, `rtl-leaf-equivalence`. Generic synth is not physical area.

## Server-ready smart prefetch

`g6lc_server_prefetcher.sv` on the L3→DRAM (or L2→DRAM) AXI edge:

1. **Next-line** at `ServerPfDistance` on demand miss  
2. **Multi-stream stride** train (up to `ServerPfStreams`)  
3. **Demand always wins** AR arbitration; PF injects only when AR idle  

Complements L1 HPDCACHE stride (`HwPrefetchEn`) — L1 for tight loops, L3 edge for
LLC-friendly server streams (packet buffers, page copy, KVM guest memory).

## U6.0 L2 (implemented)
MSHR line-merge, banked data (`tc_sram`), NC bypass, WT+RA, parallel tags.
Exclusive `AR.lock` (LDEX) is captured and forwarded on the memory-side AR and
never takes the tag-hit path — otherwise `g6lc_axi_lrsc` never arms and
`sc.d` returns 1. `AW.lock` / ATOP were already preserved.

## Invariants
RVWMO; PMA (MMIO uncached via NC bypass); CBO end-to-end; 64 B lines with `Zic64b`
(equals default `DramChanShift=6`). Demand miss wins AR over prefetch **and** must
keep winning over island GEMM when both share the DRAM slave.

## Status
L2, L3 and server PF RTL are **present/config-gated**, not release-qualified.
The L2 top FSM serializes requests through fill and response; multiple MSHR
entries and data ports do not establish hit-under-miss, merged-response service,
or multiple outstanding misses at this boundary. PMU group 2 is **wired**
(cluster → core); do not sum duplicate shared-cache views across cores.
Inclusive paths are **present/config-gated**, with concurrency qualification open:
- L3 (or L2) victim → **L1** via `g6lc_l3_inclusive_inv` (policy `CVA6Cfg.L3InclusiveEn`; the cluster's `INCLUSIVE_L3` parameter is a bench override and the testbench passes 0)
- L3 victim → **L2 tag match-inval** via `l2_back_inval_*` / `inval_match_*` on `g6lc_l2_tag`
DT: `dts-l3-prefetch.md`. Stream×multicore suite: `mc-stream-tests` (`g6lc64_ooo_server`).
Open: Ara live vector on sim flist (IP vendored + `Flist.ara` ready).

### L3 under COH_OOO, WT allocation and SRAM tags (2026-09-26)

Record of decision and evidence: `core/ooo/AGENTS-ooo-plan.md` T8a–T8d.

- **WT targets never allocated in the L2.** `core/axi_shim.sv` emits `CACHE_MODIFIABLE` only and
  `l2_is_cacheable` requires an allocate bit, so `g6lc64_smt2`, `g6lc64_smt2_ooo_int` and
  `g6lc64_ooo_int2` ran a serializing bypass: 948,230 requests, 0 hits on the four-hart boot
  (measured with the new observer `[mc_cache]` counters). `WtAxiAllocEn` (default 0) makes
  `wt_axi_adapter` emit `BUFFERABLE|MODIFIABLE|RD_ALLOC|WR_ALLOC` for cacheable requests; nc/lock/
  ATOP stay modifiable-only. On in `g6lc64_ooo_int2` and the two L3 packages; the two SMT2
  targets that keep 0 re-ran bit-identical to their frozen traces.
- **Inclusion is a package policy.** `L3InclusiveEn` replaces the testbench `INCLUSIVE_L3=L3En`
  hardwire (`g6lc64_ooo_server` keeps 1); the L2 tag back-invalidate is qualified by the L3
  victim accept edge and the accept waits on the L2's back-inval ready.
- **Packages** `g6lc64_ooo_int2_l3` and `g6lc64_smt2_l3`: non-inclusive 1 MiB / 16-way / 64 B L3,
  MSHR 4 (same service as 16 against the hub's four credits), `L2TagSramEn=1`; DTS
  `ariane-ooo-int2-l3.dts`, `ariane-smt2-l3.dts`. Strict SMT2 boots pass at DRAM latency 0
  (19,341,802 and 14,300,834 cycles). In every system run so far `l3_hit = 0`: the boot fits the
  L2 and write-through self-invalidation purges written lines from both levels, so the L3 adds
  per-miss latency (+3.6 % / +12 %) — the mechanism is proven at the leaf (stack scenario 4), the
  benefit case is a footprint/write-policy measurement (T8e).
- **Tags behind `tc_sram`** (`L2TagSramEn`, `g6lc_l2_tag.tech-spec.md`): valid bits in flops, a
  1R1W row store launched one cycle ahead (`state_d == S_TAG`), inval-match read with port
  priority and a deferred clear against snapshotted valids. A live-valid compare in the first
  build dropped a freshly installed line (found with `+l2_trace`, HUM scenario 41); after the fix
  the four-hart boot is byte-identical to the flop path. Flop-vs-SRAM equivalence is a
  deterministic dual simulation (`L2TB_EQ_TAGS`, cycle-exact at 512 B–8 KiB); a Yosys miter does
  not close on the unpaired tag-store init and stays open. FO4 identical; the 802,816/204,800-bit
  tag-reset widths leave the lint on the SRAM path.
- **DRAM-latency instrument.** `axi_delayer`'s `stream_delay` serializes each beat and truncates
  its delay to 4 bits (40 → 8) — unusable for latency experiments. `corev_apu/tb/
  g6lc_tb_dram_latency.sv` (`DramLatency` parameter) delays only the first beat of each burst.
  At 40 cycles the allocating L2 retires 3.4× the instructions of the bypass in the same 24M
  cycles; neither finishes the boot inside that cap.
- **Red lane, not waived.** The legacy `L2TB_MODE=equiv` ladder (pinned pre-RR reference) fails
  with 531 unproven cells because the reference predates the self-invalidation retention and
  kill-on-invalidation repairs; a whitelist was rejected. Re-cut the reference from the current
  flop engine before citing that lane again.

### Write-through update (`L2WriteUpdateEn`) and Phase-5 qualification (2026-09-27)

Record of decision and evidence: `core/ooo/AGENTS-ooo-plan.md` T8f/T8g.

- **Resident-line writes merge in place.** `L2WriteUpdateEn` (default 0; `WRITE_UPDATE` on
  `g6lc_l2_top`, passed through `g6lc_l3_top`) splits the write's self-invalidation into a
  tag clear (`tag_match_inval`) and a fill kill (`kill_match`); on a confirmed resident-line
  hit by an eligible write (cacheable, no ATOP, no lock, burst inside the line) the tag clear
  is suppressed and each forwarded W beat merges bytes through data port A. The fill kill
  still fires, so a racing fill can never stale-merge. Merged bytes are visible only after
  memory's B — the FSM leaves the bypass states via S_BYPASS_B — so the composed bench's
  `late_ar >= mem_b` admission contract holds under WU=1. A write to a non-resident line,
  or an ineligible write, takes the invalidate-and-bypass path verbatim. On in
  `g6lc64_ooo_int2`, `g6lc64_ooo_int2_l3`, `g6lc64_smt2_l3`; off — and bit-identical — on
  `g6lc64_smt2` / `g6lc64_smt2_ooo_int` (frozen traces re-verified: 12,761,165 /
  10,701,925 cycles, exact).
- **Boot numbers (strict pass).** Four-hart int2 at latency 0: 17,993,674 cycles (was
  18,675,595), `l2_miss` 103,380→1,532, `l2_selfinv` 91,594→189, `l2_wupd` 817,606.
  int2_l3: 18,244,344 (was 19,341,802), flop-tag `L2TagSramEn=0` build byte-identical to
  the SRAM-tag run. smt2_l3: 13,814,448 (was 14,300,834). Latency-40 measurement boots:
  int2 41,508,827 (−11.5 %), int2_l3 42,004,100 (−13.2 %) with the boot workload's first
  `l3_hit` — written lines now stay resident in the L3 instead of being purged.
- **Directed.** `mc_l2_write_read` (128 KiB × 4 iterations): `l2_selfinv` 6,060→0,
  `l2_wupd` 6,135, read-backs hit the L2 (~6,040 hits vs ~15), latency-40 cycles
  821,733→526,714 on int2 / 926,763→559,492 on int2_l3. The 512 KiB scan is
  cycle-identical (its stores never find a resident line). Every negative arm fires.
- **Gates.** HUM 78/78 identical metric hash under WU=0; `L2TB_EQ_TAGS` byte-exact at
  WU=1 (512 B 17,187; 4 KiB 32,102) and WU=0 (17,221); merge/tag fault controls fail as
  designed; int2/int2_l3/smt2_l3 lint-synth zero errors, default counts unchanged; FO4
  `g6lc_l2_top` worst 28.5 at both WU values — the merge lives only in the bypass states.
- **Open.** Posted-write merges and CBO-on-WT are M1; `--threads>1` Verilator models
  diverge late (~97.7 % identical) and are measurement-only, not qualification.

## Default-off replacement experiment (2026-09-14)

`L2RoundRobinEn` flows through both config structs, `build_config`, and
`g6lc_cluster` into `g6lc_l2_top.RR_EN`. All 27 explicit target literals,
including deprecated/UVM variants, set it to zero. `check_cfg` requires L2
enabled and power-of-two associativity of at least two. L3 inherits the
unchanged `RR_EN=0` default and has no policy enable of its own.

The experiment retains lowest-invalid-way priority. For all-valid sets it
uses a per-set pointer, advanced past the installed way only when installation
completes. A one-port, one-cycle `tc_sram` in `gen_rr.i_metadata` reads on
cacheable, non-exclusive AR acceptance, alongside the existing request capture.
The result is available in `S_TAG`; neither hits nor misses gain an FSM stage.
Tag reset invalidates all ways, and invalid-first installs initialize each set
before the pointer can be used for all-valid replacement. No SRAM reset sweep
or resettable per-set flop array is required. Reset/invalidation tests exercise
this rule. This relies on the current serialized controller; nonblocking work
must redesign metadata ownership/read timing rather than reuse it blindly.

**Timing/backend/DFT:** additional control is an accepted-AR read enable, set
address mux, and installed-way increment; no new clock or reset domain. Logical
metadata is 512×3 = 1,536 bits at 256 KiB/eight ways/64 B. Actual macro width,
periphery, test access/MBIST, scan integration, mapped area, power and the
1.25 GHz target remain unqualified. `tc_sram` is the macro seam, not evidence
that a foundry macro or DFT hookup exists. Existing hit/miss/victim ports provide
leaf observability; no new architectural PMU event/CSR or software ABI is claimed.
DTS sizes, line widths, memory map, ISA discovery, SMT scheduling, issue and
retirement are unchanged. Structural/default-off equivalence is still a gate;
matching test counters alone is not a netlist proof.

### Diagnostic evidence, not production qualification

Run `bash verif/tb/l2/run-l2-tb.sh`; the runner does not clean prior outputs.
Each invocation creates a fresh `run-*` child under `L2TB_OUT` and copies its
closed input set into `source/`, checking source consistency before compilation.
It compiles the copy, not the live worktree, and preserves logs, hashes and
`run.args`. Simulation always enables the bypass and ATOP follow-up regressions.
`L2TB_OUT` selects an artifact parent, `L2TB_RR_EN=0|1` selects policy,
and `L2TB_EXTRA` accepts geometry overrides. `L2TB_MODE=config` checks the
`TARGET_CFG` package, propagation and legal enable; `+bad-cfg=1|2|3` must fail
for no L2, one way, and non-power-of-two ways. `L2TB_CONFIG_LINT=1` limits that
mode to elaboration. `L2TB_MODE=synth` runs Yosys/slang with live AXI ports,
memory-count and no-latch assertions. These runs are local diagnostics under
the AGENTS exception; they emit no strict `G6LC_EVIDENCE` and prove no SMT/core
or multicore configuration. Source/executable hashes and logs accompany final
simulation runs; remote source/build/run binding remains separate.

The original 13-phase checked suite uses independent requested-write and backing-memory
models, response ID/length/data checks, stalled-response assertions, exact
accepted/completed-work accounting, unique misses, installed fills and external
traffic. It covers cold/all-way hits, full-line responses, conflict traces,
masked WT stores, quiescent back-invalidation, reset, NC and exclusive bypass.
Zero MSHR-full/bank-conflict counts at the serialized top are **coverage gaps**,
not concurrency passes. `L2TB_MODE=units` instantiates `g6lc_l2_mshr` and
`g6lc_l2_data` directly; remote Verilator 5.008 PASS
`l2-leaf-20260915T020340-df5db8e21fd8` (`mshr_full=1 merge=1 merge_full=1
waiter=1 bank_conflict=1 bank_ok=1`). The top still leaves `merge_full_o`
unconnected and ties `waiter_pop_i` to 0.

Verilator 5.020, 4 KiB/four ways/64 B, memory latency 6, seed `0x600df00d`:

| Phase | Legacy cycles | RR cycles | Interpretation |
|---|---:|---:|---|
| hot_scan | 12,096 | 9,024 | 192 RR hits vs zero legacy hits |
| lfsr | 9,840 | 8,640 | 99/446 RR hits vs 24/446 legacy hits |
| protected_hot | 1,152 | 1,920 | RR regression: 48 vs 96 hits; legacy protects nonzero ways |
| Entire diagnostic | 30,315 | 26,811 | 1,493 completed reads, 83 writes each; workload-specific only |

Artifacts: `remote-runs/l2-sram-final-rr{0,1}/`. Despite the directory name these
are **local** diagnostics. Zero initial memory latency with one bubble every
three cycles passes both policies (`l2-sram-stall-rr{0,1}`); an eight-way RR
fixture with bubbles every five cycles also passes (`l2-sram-8way-rr1`). The
old random-mix numbers used an incorrectly converted seed and are superseded.

Yosys/slang generic 4 KiB/four-way screening (`l2-synth-rr{0,1}`) passes:
two vs three pre-map memories, 120,844 vs 121,015 post-map generic cells, no
latches and zero `check -assert` problems. Memory mapping expands data SRAMs
to generic gates/flops, so this is **not** a physical-area percentage. Verilator
`LATCH`/`UNOPTFLAT` diagnostics remain narrowly waived by signal for this bench;
they did not establish physical latches or loops in the synthesized fixture.
Vendor SRAM read-output reset warnings remain visible in synthesis logs.

### Bypass-R correctness follow-up (2026-09-14)

The recorded `+bypass-backpressure` failure was reproduced from a fresh copied
baseline (`remote-runs/l2-drain-before/run-30YFmOGc`), then repaired independently
of replacement policy. `S_BYPASS_R` now retains the slave's ready signal rather
than being overridden by the common drain block. The AR outstanding flag clears
only on `RVALID && RREADY && RLAST`; the existing short-last guard for line fills
is retained. This is an unconditional AXI correctness correction inside the
existing enabled L2 engine (also reused by L3), **not** a new optional feature.
It adds no state, SRAM, clock/reset domain or pipeline stage. The restored
slave-to-master ready path and last-handshake qualification are the timing
change; physical STA is still required. No ISA/DTS/config geometry change or
new PMU event is needed for this handshake repair. Scan/MBIST state is unchanged.

The regression extension checks five bypass requests / thirteen accepted R
beats: single/burst stalls including the final beat, exclusive EXOKAY and
SLVERR/DECERR forwarding. Three synthetic ATOP response schedules check R before
B, R held across B, and delayed R after B, including ID/data/user stability and
exact completion counts. A following full-line miss/hit checks return to normal
service; a deliberately injected early short-last checks the existing fill
guard. These are **AXI seam/robustness tests**, not actual AMO arithmetic or
reservation-monitor verification. Cacheable fill errors and a new request
racing an as-yet-unoffered delayed ATOP response remain outside this coverage.

Local Verilator 5.020 four-way RR off/on suites pass, now 16 measured phases
plus three ATOP forwarding cases: 1,501 accepted reads / 86 writes each,
30,689 / 27,185 cycles. The original 13 phases retain their previous counts and
cycles. Eight-way RR with latency=0/stall-every=3 also passes. Generic leaf
synthesis passes with 120,846 / 121,017 cells (+2 per policy vs before the fix),
two/three pre-map memories, no latches and no check problems. Artifacts:
`l2-drain-after-rr0/run-w3tXDS1s`, `l2-drain-after-rr1/run-XPrW1XDa`,
`l2-drain-stall-8way/run-h6RTCnpq`, and `l2-drain-synth-rr{0,1}/run-*` under
`remote-runs/` (these named artifacts are local).

**Remote isolation:** `testharness_proxy.py l2-leaf <snapshot-source-dir>
--rr-en 0|1` copies only ten allowlisted inputs into a fresh remote `runs/l2-leaf-*`
directory, checks uploaded hashes, executes the expanded suite, pulls logs and
emits `leaf-result.json`. It never calls shared-repository sync, cleanup, or
stranded-harness killing. It can also snapshot the repository root; source
changes during upload fail remote checksum validation. Failure/missing logs
cannot become success. This record explicitly sets `strictQualification=false`;
it is not the core/SMT `G6LC_EVIDENCE` contract. The initial remote attempt
correctly failed on a Verilator-version-incompatible warning name; the runner
now probes warning-name support and uses the vendor-scoped WIDTH alias, without
disabling assertions. Pinned Verilator 5.008 subsequently passes both policies:
`l2-leaf-20260914T234313-4bd9099b1be4` (off) and
`l2-leaf-20260914T234448-fec52bccce2d` (on), with source hashes and pulled logs.

The bypass defect is **fixed at the tested leaf boundary**, but promotion still
requires real ATOP/AMO/SMT controls and cluster integration. Concurrent
invalidations, cacheable fill errors, MSHR merging/full, bank conflicts, formal
non-vacuity, production geometry, paired core workloads and physical
qualification remain open. RR default-off equivalence must use the corrected
AXI baseline; the repaired stalled-bypass behavior intentionally differs from
the defective baseline. Performance promotion is **NOT QUALIFIED**.

### Independent policy model and scoped equivalence

The bench now maintains independent line addresses, valid bits and per-set
next-victim pointers from accepted requests, completed installs, writes and
quiescent invalidations. It checks hit/miss classification, install set/way,
victim validity/address and nonempty coverage. A separate reset/fill test
invalidates way one, fills that hole first, then checks the subsequent full-set
victim. Expected victim addresses can be deliberately corrupted with
`+policy-oracle-negative`; this fails the checker rather than emitting PASS.
The model covers the serialized/quiescent test envelope, not simultaneous
install/invalidation arbitration or MSHR concurrency.

Remote 5.008 results (17 phases plus three ATOP schedules):

| Profile | Checked lookups | Installs | Evictions | Victim-way mask | Run |
|---|---:|---:|---:|---|---|
| Four-way, RR off | 1,484 | 1,341 | 1,243 | `1` | `l2-leaf-20260915T001658-72af040d10a6` |
| Four-way, RR on | 1,484 | 1,122 | 1,013 | `f` | `l2-leaf-20260915T001701-554d8da2815c` |
| Eight-way RR, latency0/stall3 | 1,432 | 1,058 | 952 | `ff` | `l2-leaf-20260915T001821-86549ac21b77` |

The four-way runs complete 1,507 reads and 86 writes each. These checks validate
policy execution, not just a favorable miss-count change. The proxy requires
positive consistent counters and the correct policy-specific victim mask;
missing cases, duplicate PASS records, wrong masks and failing return codes
are rejected. Its environment explicitly fixes geometry, seed and empty extra
overrides. The original workload trade-off remains; no new speedup is claimed.

`L2TB_MODE=equiv bash verif/tb/l2/run-l2-tb.sh` runs a separately bounded Yosys
check. Its default is a **512-byte/four-way/two-set fixture**, not production
cache geometry. `L2TB_BYTE_SIZE` and `L2TB_SET_ASSOC` override it;
`L2TB_EQ_TIMEOUT` defaults to 120 seconds. Missing inputs, tool failures,
timeouts or unproven points fail. The local Git store must contain reference
blob `5be075b1a01ff754da384c3dd129fd58c33733fa` (override via
`L2TB_EQ_BASE_BLOB` only with an independently reviewed reference). The runner
copies this pre-RR engine and applies only the two-line bypass fix, refusing
a reference already containing RR or lacking the expected patch anchor.
Original/corrected reference hashes, blob ID, copied current sources and the
Yosys script are retained in the fresh run directory. No worktree RTL is
rewritten to construct the golden model.

The fixture has live AXI inputs and all observation outputs. Both sides use the
same current tag/data/MSHR primitives, 512-bit lines, four MSHRs and two banks;
this tests the top-level replacement delta, not historical primitive changes.
The flow maps memories, normalizes asynchronous resets at clock boundaries,
requires a nonempty comparison set, merges identical cells, and runs
`equiv_simple -short -undef -seq 2` plus `equiv_status -assert`. It does not
ignore unknown cells or waive unproven points. This is scoped clock-boundary
sequential equivalence under the matching-state/reset model, not electrical
reset/CDC or whole-SoC verification.

Yosys 0.68+1 (`c30457480`) proves:
- 256 B/two-way fixture: **9,151 proven, zero unproven**
  (`l2-equiv-short/run-p9hU86oH`).
- 512 B/four-way fixture: **11,675 proven, zero unproven**
  (`l2-equiv-4way-small/run-GC6b0TBD`).
- `L2TB_EQ_NEGATIVE=1` inverts only the gate hit output and must fail;
  `l2-equiv-short-negative/run-YSRsaZAE` leaves exactly that output unproven.

The final default-mode rerun also passes (`l2-equiv-final/run-1blQPZgt`);
`l2-equiv-final-negative/run-ZG0cGREl` fails on the inverted hit output.

Earlier full-cone and alternative-preprocessing trials timed out; a structural
matching trial produced invalid internal matches and was rejected. The
4 KiB **mapped** check also exceeded the 120-second SAT budget. None is counted
as a proof or used to justify RTL changes.

### Larger-geometry equivalence and real AMO controls (2026-09-15)

`L2TB_EQ_MEM=bbox` keep-hierarchy blackboxes slang-uniquified
`g6lc_l2_tag*` / `g6lc_l2_data*` / `g6lc_l2_mshr*` / `tc_sram*` so flop
tags do not enter SAT. That is **controller/port** RR-off equivalence
against the pinned bypass-corrected pre-RR engine, not a tag-flop netlist
proof. Yosys 0.33: 4 KiB/4-way 2054/0 (`run-ChPtb8Vc`); 16 KiB/4-way PASS
(`run-kLWpIH6I`); 256 KiB/8-way 2057/0 (`run-zisQrCl4`,
`--unroll-limit=16384`). Inverting `hit_o` leaves exactly that output
unproven. Collect 4 KiB/4-way **13828/0** (`run-DIR7V5Rx`, 275 s); the
earlier collect timeout is superseded. Mapped
flop-tag RR-off vs bypass-corrected pre-RR: 1 KiB/4-way **16670/0**
(`run-CpQ2EFZ1`); 2 KiB/4-way **26625/0** (`run-lOd2ZWuD`); 4 KiB/4-way
**46468/0** (`run-n4dThvgT`, 300 s); 8 KiB/4-way **86023/0**
(`run-76BAyumg`, 490 s). The earlier 4 KiB mapped 120 s miss is
superseded, not waived. Default ladder includes 1 KiB/2 KiB map plus
4 KiB/16 KiB bbox; 8 KiB map is opt-in (600 s). Proxy `l2-equiv --mem
map|bbox`. Isolated equiv must set `YOSYS` to testharness
`toolchains/formal/bin/yosys`. 1 KiB mapped hit-inversion leaves exactly
`hit_o` unproven (`run-eYUjh1hE`, 16670/1). Collect 16 KiB timed out at
900 s (`l2-equiv-...T072626-2597c1ae5355`) — incomplete, not waived.

`+amo-arith` (always enabled by the runner) is a **real** memory-side AMO
model: ADD/SWAP/CAS.W arithmetic, exclusive LR EXOKAY reservation, SC
EXOKAY success and OKAY failure, then a cacheable read that must observe
the computed value after WT self-inval. Remote Verilator 5.008 PASS
`l2-leaf-20260915T012151-99c14472e3e2` (RR off). Synthetic ATOP R/B
forwarding remains; it does not replace this. Cluster AMOCAS W/D/Q and SMT
cookie soaks stay the named-package controls (`qual-stream8-minis`,
`qual-soft-ladder-osbi`). Isolated stream8 RR-on now ran the four cluster
minis with **identical** cycles vs production RR-off (AMOCAS.W 550, D 704,
Q 998, stream_plane 2138). `mini_l2_hot_scan.S` (512 L2 sets, 16 scan
rounds, hot checksum PASS) is also **384,179 / 384,179** cy. Paired leaf A/B (amo-arith PASS both). 4-way/4 KiB: RR-off **31,108** cy
vs RR-on **27,604** cy (`hot_scan` 12,096→9,024; `protected_hot` 1,152→1,920).
8-way/4 KiB: RR-off **26,256** cy (`...T080935-67c68349c896`) vs RR-on
**26,080** cy (`...T081003-a0436a16ea1d`, mask=ff) — mix ~0.7%; hot_scan
6,720→4,928 cancelled by protected_hot 1,792→3,584. Core+L1+WT still 0
delta. Best area/perf in this tranche: keep RR default-off. ~~SMT2 RR-on remains
a fetch livelock~~ — retracted 2026-09-15: a Verilator vthreads=12 model
artifact (see below); smt2 traffic never reaches the L2 tag path anyway.
No RR default-on and no performance promotion.

**Renewed current-fetch controls (2026-09-15):** after replay-loop and redirect
completion repairs, VT1 byte-identical N1 checked-work passes on SMT2 RR0/RR1
(cookie polling at 137,216 on both) and stream8 RR0/RR1 (167,936 on both).
Production-cacheability hot+scan passes on both stream8 legs at 464,896 cookie
polling cycles. Its warm+scan counter report is identical: 275,593 cycles,
4 L2 misses, 0 L1D misses, 20,483 load events, 7 store events, 20,492 data requests
and 17 I-cache misses. These report deltas exclude the initial data fill and
include the stated warm-up/report boundary; they are not whole-kernel timing.
Only `L2RoundRobinEn` changes in the overlays; no execute-region narrowing.
The zero L1D allocation/miss count is consistent with the existing cacheability
restriction, not a representative cacheable-data replacement-policy test.
No benefit or default-on decision follows. Artifacts:
`remote-runs/review-renewed-rr-controls-20260915/output/` (`results.json`,
`models.json`, `payloads.json`, overlays, disassembly and raw trace reports).
All are diagnostic, not strict qualification. Subsequent dual-hart repairs and
runtime revalidation are recorded below; physical qualification still lacks
its PDK/library/corner/constraint inputs.

**Final paired renewal:** the restart-frontier, redirect-owner and split-target
repairs pass the activated integer witnesses. Rebuilding the matched RR models
exposed a Verilator 5.008 `VL_CONSTHI_W_*X` host out-of-bounds zero-fill in
stream8 RR1, not an RR policy result. A user-approved private runtime copy fixes
the absolute-index/shifted-pointer mismatch; its guarded canary gives 18
mismatches before and zero after. No installed tool, RTL or workload changed
for this correction. All generated C++ objects were rebuilt against the same
corrected header (SHA256 `dfbc2c4a…`). All six controls now pass and reproduce
the timings/counters above, including 275,593 ROI cycles and four L2 misses on
both stream8 legs. Source/model/ELF/runtime records and logs are in
`/opt/testharness/runs/review-private-runtime-rebuild-20260915/output/`, copied
locally to the approved C: artifact directory. Older native results remain
historical; use the corrected-runtime identities for renewed evidence.
RR remains default-off; no physical or representative cacheable-data gain is claimed.

Isolated core overlays (`verif/regress/isolated-config-overlay.py`) may
flip only allowlisted fields (`L2RoundRobinEn`, `ExecuteRegionDramLen`) in
a copied package and derived flist. `SOFT_LADDER_OVERLAY` fields are
comma-separated. `SOFT_LADDER_ISOLATED=1` refuses production Mdir basenames
(`work-ver-stream8`, `work-ver-smt2-fw64-B`, …) even when the path is
absolute. `mini_checked_work.S` is a 48 KiB checked fill/verify with DRAM
markers; N=2 is experimental.

**2026-09-15 — execute-region/cacheability overlap (the real "high miss"
finding).** `cva6_hpdcache_if_adapter.sv` marks a load uncacheable when its
paddr is inside an *execute* region (the S4/2jr workaround), and every
shipped config maps `ExecuteRegion[all-DRAM] = 0x8000_0000+0x4000_0000` ⊇
the whole cached region. On HPDCACHE targets **all DRAM data loads are
uncached**: L1 never allocates (`l1m=0` over ~544 KiB), uncached reads emit
`AxCACHE=0010`, `l2_is_cacheable` fails, and the L2 only ever sees I$
refills. The earlier "0 cycle delta" stream8 pairings measured that quirk,
not the L2 policy. With an isolated `ExecuteRegionDramLen=8000` overlay
(the buffer made cached-non-execute), `mini_l2_hot_scan_pmu` shows real
traffic: l1m=18,857 / l2m=18,787 (rr0) vs l2m=13,318 (rr1), cyc
374,177→**325,980 (−12.9%)** — RR keeps the hot line resident under the
all-set scan. Single RR-favorable workload: evidence a win exists, not
promotion. Narrowing the execute region in production configs is a product
decision (it was a deliberate hang workaround); do not silently change it.

Isolated RR-on candidate (2026-09-15): Mdir `iso-stream8-rr1`, overlay
`L2RoundRobinEn` 0→1, exe `ec650f20…` vs production `7e27de94…`. Same
N=2 ELF as the RR-off control: kernel `tohost=1` after 154,170 cycles
(`checked-work-stream8-n2-rr1`). Cycle match is expected for sequential
fill/verify; it is not a replacement-policy speedup. Production defaults
stay RR-off.

SMT2 pairing (same overlay, named package not merged): isolated
`iso-smt2-rr1` elaborates `i_l2.gen_l2.gen_rr.i_metadata` (real RR-on).
Production N=1 uncompressed-tohost CONTROL PASS
(`checked-work-smt2-n1-norvc`, 129,455 cy, `tohost=1`; fully
uncompressed body 135,616 cy). Isolated RR-on **livelocks** in verify
at 400k and 2M cy (`tohost=0`): SMT2 I=2 fetch dual-issues the two loop
addis and never the `bnez`. Uncompressing the loop and inserting a nop
only moved the stuck pair. Stream8 I=1 RR-on still completes. Not L2
data corruption (never `tohost=3`). Fetch dual-issue repair is
follow-on. Not a pass and not promotion.

**2026-09-15 correction — the SMT2 "livelock" is a Verilator vthreads
artifact, not RTL.** smt2 emits `AxCACHE=0010` on every channel (WT path),
so `l2_is_cacheable` rejects all traffic and the RR netlist is functionally
dead there — rr0/rr1 can only diverge through the simulator. Rebuilt
same-tree pair: vthreads=12 iso-smt2-rr1 froze at the `0x78/0x7c` pair
(800k, twice, deterministic), while vthreads=12 iso-smt2-rr0 instead hit
`Active region did not converge` at t=287. Both iso-smt2 verlibs rebuilt
with `SOFT_LADDER_VERILATOR_THREADS=1` (rr0 and rr1) **pass identically at
22,964 cy**. Determinism-before-attribution applies: RR never caused it.
Treat smt2 vthreads=12 model behavior as suspect; qualify at vthreads=1.

MSHR merge/full/waiter and same-bank vs different-bank conflict are now
leaf-covered (`L2TB_MODE=units`). Isolated stream8 RR-on checked-work is a
functional envelope (`iso-stream8-rr1`, 154,170 cycles, `tohost=1`), not
promotion. Production-geometry mapped equivalence, candidate-on SMT
pairing, and physical gates remain open. Rename allocation/exhaustion/ckpt
covers reached locally with yices (`g6lc_ooo_rename_cover.sby`); they are
not a testharness formalTasks gate. The separate core lint command passed its budget (278 warnings) and strict
elaboration; the unbounded core synthesis attempt was cancelled incomplete.
This tranche changes verification/tooling and the leaf TB memory model
only: no new silicon state, clock, reset, PMU event, ISA/DTS exposure or
enabled production replacement policy.

## Uncore synthesis evidence: 10 of 10, and why the cluster route cannot finish

The whole-cluster synth target does not finish (cut at 900 s, exit 137 at ~994 s, exit 255
at 2412 s against a 2400 s budget — slow, not crashing; the builder has 12 cores and
125 GiB, so an earlier "OOM" claim here was wrong).
`verif/regress/remote/run_cluster_synth_review.py` therefore synthesises the uncore tops
**separately and in parallel** — ten yosys processes at once. Yosys is single-threaded, so
this is the only way to use more than one core; one cluster target never can.

Modules whose ports are typed through `parameter type axi_req_t = logic` cannot be a
synthesis top with that default (`invalid member access for type 'axi_resp_t' (aka
'logic')`), so `verif/tb/g6lc_uncore_lint_tops.sv` supplies typed tops — the same device as
`g6lc_cluster_lint_top`, applied per module so a failure names one module rather than the
whole cluster.

| Module | Cells | Peak RSS | Time | Latches |
|---|---|---|---|---|
| `g6lc_l3_top` (32 KiB under `SYNTHESIS`) | **7640** | **2.0 GB** | **278 s** | 0 |
| `g6lc_l2_top` (16 KiB under `SYNTHESIS`) | **4660** | 682 MB | 46 s | 0 |
| `g6lc_coherence_hub` (NR_CORES=2, SF on) | 1236 | 213 MB | 5.4 s | 0 |
| `g6lc_snoop_filter` (NR_CORES=2, enabled) | 582 | 186 MB | 14.6 s | 0 |
| `g6lc_server_prefetcher` | 368 | 70 MB | 0.3 s | 0 |
| `g6lc_inval_bus` (NR_CORES=2) | 250 | 70 MB | 0.2 s | 0 |
| `g6lc_axi_2to1_mux` | 80 | 71 MB | 0.2 s | 0 |
| `g6lc_lr_sc_tracker` | 49 | 70 MB | 0.2 s | 0 |
| `g6lc_inval_retain` | 31 | 69 MB | 0.2 s | 0 |
| `g6lc_l1_inv_adapter` | 3 | 68 MB | 0.2 s | 0 |

**10 / 10, zero inferred latches anywhere.** Wall time is set by the slowest module rather
than the sum — ~5 minutes for the whole suite, against a cluster route that never finished
in 40.

### These numbers explain the cluster failure

`g6lc_l3_top` alone takes **2.0 GB and 278 s at a shrunk 32 KiB geometry**, and `g6lc_l2_top`
682 MB at 16 KiB. The cluster instantiates both *plus* two full cores in one elaboration —
so the deadline overruns are not mysterious, and they are not a toolchain defect. They are
the direct cost of ~3.4 Mbit of tag state built from flip-flops. That is the strongest
argument yet for the standing `tc_sram` migration item: it is not only an area concern, it
is why the uncore has no whole-cluster synthesis evidence.

### Two vacuous passes, both mine, both caught by the same metric

The count went 6 → 3 → 7 → 10, and the corrections matter more than the final number:

1. **`rc=0` with zero cells.** Three modules exited successfully having synthesised
   *nothing*: at `NR_CORES = 1` the hub, the invalidation bus and the snoop filter collapse
   to their degenerate path. So `cells > 0` became part of the pass criterion, and the count
   dropped from 6 to 3.
2. **Tie-offs delete the design.** My first typed wrappers tied every input to a constant
   and left the outputs dangling, on the theory that a synthesis smoke only needs the module
   elaborated. `opt` removed everything as unreachable: `stat` showed wires and ports and
   **no cells**, while the run reported rc 0 and no latches — a vacuous pass manufactured by
   the harness rather than found in the RTL. The wrappers now re-export the DUT interface
   with concrete types.

In the second case the discriminating evidence was the resource measurement: 213 MB / 5.4 s
for the hub against 64 MB / 0.12 s for a run that genuinely did nothing. That is what the
`/usr/bin/time` wrapper is for.

`cells > 0` is a weak criterion — it cannot tell a correctly synthesised module from a
partly optimised one — but it is exactly strong enough to catch "this proved nothing".

### What these runs do and do not establish

They establish that every uncore module elaborates and synthesises to generic gates with no
inferred latches, individually. They do **not** establish that the assembled cluster does,
because cross-module elaboration is what they skip. And the L2/L3 runs use reduced geometry
because the behavioural `tc_sram` model cannot elaborate at production size in the synthesis
frontend — so **no cell count here is an area figure**, and none of it is closure evidence
at production geometry.

## The tag array is not a "swap to tc_sram" job — it is a pipeline change

This item has been carried as a P2 area task ("move the tag array behind `tc_sram`").
Reading `g6lc_l2_tag.sv` against what an SRAM macro can actually do says otherwise, and the
re-scoping matters more than the area number.

**The blocking property is the read contract, not the array declaration.** The lookup is
*combinational*:

```systemverilog
hit_way[w] = lookup_i && tags_q[index_i][w].valid && (tags_q[index_i][w].tag == tag_i);
```

`hit_o` is valid in the same cycle as `index_i`, and the module's own header advertises
"single cycle". An SRAM read is registered — data arrives the cycle after the address. So
the swap is not transparent: it inserts a pipeline stage into the L2 lookup path and
changes the latency the parent is built around.

Three further properties have to be resolved before any macro can be bound:

* **`probe_tag_o` / `probe_valid_o`** are a second combinational read, at an arbitrary way
  and independent of the lookup index — a second read port, or an arbitrated one.
* **`inval_match_i` is content-associative**: it compares the tag against *all* ways of a
  set and clears the matches, reading and writing the same set in one cycle. Against an
  SRAM that becomes a multi-cycle read-modify-write which must not race the lookup.
* **`write_i` and `inval_i` are independent `if`s in one `always_comb`**, so both can
  update in the same cycle at different indices — two write ports, or serialisation.

The standard split — valid bits in flops, tags in SRAM — is necessary (it is what removes
the whole-array reset) but is **not** where the area is: valid is one bit of a 48-bit
entry, **2.0 % of the L2 array and 2.1 % of the L3**. The tags are the cost, and they are
exactly the part that needs the registered read.

### The recorded figure is correct — my challenge to it was wrong

I questioned the long-standing **3,080,192 + 401,408 ≈ 3.4 Mbit** figure, deriving 1.78 Mbit
from the geometry and noting a suspiciously uniform 1.96x factor. **That challenge was
wrong, and the retraction is more useful than the doubt was.**

The error was mine: I used the *default* geometry (256 KiB L2, 2 MiB L3) instead of the
configured one. `build_config` scales the caches with core count — L2 is
`max(256 KiB, NrCores x 128 KiB)`, L3 is `max(2 MiB, NrCores x 1 MiB)` — and
`g6lc64_ooo_server` sets `NrCores: 4`, so the real geometry is **512 KiB L2 and 4 MiB L3**.
Recomputed:

| | size | assoc | sets | TAG | entries | storage | recorded |
|---|---|---|---|---|---|---|---|
| L2 | 512 KiB | 8 | 1,024 | 48 | 8,192 | **401,408** | 401,408 |
| L3 | 4 MiB | 16 | 4,096 | 46 | 65,536 | **3,080,192** | 3,080,192 |

Both match to the bit. The array is **3.48 Mbit of flip-flops**, exactly as recorded, and
the "uniform 1.96x" I found suspicious was simply the ratio between two geometries that
differ by 2x in size — doubling the sets doubles the entries while removing one tag bit.

Two things worth keeping from the detour. The valid-bit fraction is unchanged and still
small (1 bit of 49, **2.0 %**), so the conclusion that the valid/tag split does not address
the area stands. And a lint-warning width turned out to be a *reliable* measurement here —
the instinct to distrust it was reasonable, the arithmetic that appeared to support the
distrust was not, and the fix was to check the configured parameters rather than the
defaults.

**Consequence for planning:** this is not a contained P2 array swap. It is a
micro-architectural change to the L2 lookup — a new pipeline stage, a second read port or
its arbitration, and a serialised content-associative invalidate — and it invalidates the
timing assumptions of a module that already carries extensive leaf suites
(`review-l2-read-order-*`, `review-l2-atop-*`, `review-l2-inclusion-*`). It should be
planned and qualified as such, not attempted as a declaration change.
