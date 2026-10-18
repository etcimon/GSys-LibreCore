# A139: module-driven pipeline designs

Status: **design proposals expressed in source comments**, October 2026.
This pass revisits the 53 editable modules in the earlier list of 56 modules
above 10 adjusted FO4. It changes documentation, not executable RTL. It runs
no simulation, synthesis, sv-timing transformation or OpenSTA analysis.
The 10-adjusted-FO4 value is the objective; no new delay, area percentage or
closure result is inferred from these comments.

The source blocks are the per-module designs. This document defines their
vocabulary, common obligations, expected structural effects and integration
order. They supersede the unlanded A139 draft's suggestions where those
suggestions assumed stale state was safe, omitted a bypass source, or
described logic that the source already implements.

## Comment vocabulary and scope

Each block starts with:

```systemverilog
// svt-plan: begin store_buffer status=proposal target=10-adjusted-FO4
```

It ends with `// svt-plan: end`. These are **design annotations**. They are
not executable `svt-pipe:` directives and do not grant a cut, enable a
configuration or instruct the existing emitter to insert registers.
Existing `svt-pipe:` contracts retain their meaning. In particular, a proposed
state-machine redesign does not revoke a `no-cut` on today's next-state logic.

Lines beginning `cone`, `reshape`, `boundary`, `carry`, `capacity`,
`ownership`, `visibility`, `conflict`, `bypass`, `recovery`, `alignment`,
`head`, `training`, `consumer`, `effect`, `cost`, `alternative` or `limit`
describe one facet of the design. Following ordinary comment lines continue
that facet until the next `svt-plan:` line. The bodies are engineering prose,
not a new expression language.

| Facet | Required meaning |
|---|---|
| `cone` | A dependency present in the inspected source; not a claim that it is the physically worst path. |
| `reshape` | Change the representation, selection tree or work distribution before choosing a register boundary. |
| `boundary` | Work on each side of a proposed register, including the operation that remains within each cycle. |
| `carry` | Data, control, ownership and alternative results needed to reconstruct the same operation. |
| Ownership-related facets | Acceptance event, reserved capacity, visibility, priority, cancellation, reuse and recovery rules. |
| `effect` | Conditional structural improvement: what serial dependency or large selection is removed. |
| `cost` | Added storage, latency, initiation interval, bandwidth pressure or policy loss. |
| `limit` | Remaining cone or unresolved integration obligation; what the proposal does not establish. |

Signal names without declarations for new state describe **proposed** fields.
For example, `slot+generation` specifies an ownership requirement; it does not
claim that every interface currently carries a generation number. The eventual
implementation must provide a sufficiently sized generation/epoch, retain an
owner until every response drains, or prevent reuse over that interval.
A wrapping epoch is insufficient if old work can still exist at wrap.

All staged designs require explicit configuration and consumer integration.
This pass defines neither new `CVA6Cfg` fields nor default stage counts.
Existing clocks, reset semantics, legal geometries and software interfaces
remain the starting constraints for that later implementation.

## How to infer improvement from the module

### Partition work, not only elapsed time

For a feed-forward chain with work A, B and C, a legal internal boundary
can replace a stage containing `A + B + C` with stages containing
`A` and `B + C`. The candidate maximum is bounded by the larger stage,
plus register, control, bypass and interconnect costs. Putting a register
*before* A leaves `A + B + C` intact.

Use this model to name expected changes without assigning invented FO4
numbers. A linear priority scan can become logarithmic selection levels.
An indexed read-modify-write can become row-local update plus write selection.
A carry-save boundary can defer carry propagation. None of these statements
specifies a cell delay or guarantees a particular adjusted-FO4 value.

For feedback, identify the next iteration's inputs. Pipelining the store
buffer's rank computation cannot let the following rank operate on stale
queue state. A divider microstep cannot overwrite the remainder before its
partial carry has completed. There are four explicit choices:

1. Keep the recurrence short and move only independent work out of it.
2. Stall the next dependent operation until the prepared result is installed.
3. Forward a bounded pending state representation and account for its cost.
4. Change the representation or algorithm so iterations become independent.

A deeper pipe is beneficial only if the remaining recurrence, bypass and
acceptance paths are also short. Initiation interval and latency are distinct:
two cycles per divider digit reduce per-cycle work while increasing total
division latency; two feed-forward response stages can still accept every
cycle if both have sufficient capacity.

### Rank mechanisms by the dependency they remove

| Mechanism | Expected structural effect | Main counter-cost |
|---|---|---|
| Stationary payloads with narrow order metadata | Remove full-width queue permutation from insertion/cancellation. | Age selection, free-slot management and metadata maintenance. |
| Ordered associative byte merge | Replace a serial first/last-writer chain with a balanced tree. | Per-byte eligibility and data routing still exist. |
| Bank-local candidates followed by global selection | Reduce local CAM/mux fan-in and isolate global arbitration. | Candidate registers, exact global ordering and bank conflicts. |
| Row-local update | Eliminate indexed read → arithmetic → indexed write dependency. | Replicated local arithmetic and update-enable distribution. |
| Bounded accepted-event queues | Separate transport/decode from state update. | Reservations, bypass, owner lifetime and output bandwidth. |
| Segmented arithmetic / redundant representations | Bound carry or compressor levels per stage. | Extra partial state, latency and reconverging result alignment. |
| Early prediction with late correction | Remove full prediction work from the next-PC recurrence. | Wrong-path work, checkpoint capacity and precise token recovery. |
| Head/top caches or incremental summaries | Remove repeated indexed selection/reduction from a common path. | Exact update invariants, refill bandwidth and restore handling. |

For an ordered first-valid merge, combine adjacent candidate tuples by
choosing the left valid tuple, otherwise the right. That operation is
associative when leaf order and payload travel together. Apply it independently
per byte in `wt_dcache_mem`: a whole-word winner is incorrect when one
matching entry owns only a subset of bytes. For youngest-store forwarding,
eligibility and age must define a consistent total order for the query;
ring-slot index alone is not program age.

An issue bank supplying one winner is insufficient for exact multi-issue:
the globally oldest eligible second instruction may be in that same bank.
Carry enough ordered candidates per resource class, or explicitly document
the reduced issue policy. Do not hide policy changes inside a timing rewrite.

### Define one accepted operation and its visibility

For each reservation-backed interface, define:

```text
reserved_next = reserved + newly_accepted - uniquely_released
0 <= reserved_next <= capacity
```

Reservations include every prepared, buffered and in-flight item that owns
storage. A killed item is released when it can no longer write or return under
its old identity. A logical cancellation and physical response drain can occur
on different cycles.

The acceptance event is interface-specific. `store_buffer.ready_o` is used as
a next-cycle capacity promise by its caller; it is not a conventional
same-cycle acceptance predicate. `g6lc_prf` has no request ready and must absorb
all accepted write ports. Fixed-latency FU outputs cannot suddenly wait for a
new downstream ready without reserved completion storage.

For every pending item, state whether it is visible to reads, forwarding,
commit, empty/pending flags and fences. If an overlay restores same-cycle
visibility, include the overlay in the candidate critical path. Keeping every
old interface cycle by rebuilding the entire expensive next state as a bypass
can erase the proposed gain.

### Treat lifetime and recovery as local state

Prepared work must not apply to a different owner after a slot/TID is reused.
Carry identity, hart and any relevant address-space or fetch context. Keep
sticky cancellation or retained ownership when the external kill mask is
shorter-lived than the buffered operation.

For state snapshots, choose an explicit conflict rule: lock participating
entries, forward intervening updates, invalidate/replay the snapshot, or
revalidate generations before application. Replaying a token requires a
progress rule under repeated conflicts. A promise of
`candidate_state(t) = old_state(t-k)` is not justified merely by registering
some inputs while other writers and memory responses remain live.

For fetch recovery, a delayed branch can admit additional younger work.
Cancellation must cover that actual younger set. For memory, delaying a load
verdict after younger consumers have executed requires transitive recovery,
not just replaying the original load. For fences, completion follows actual
visibility/drain of invalidations, not the sweep cursor reaching its last row.

## Findings that changed the earlier plans

| Earlier assumption | Source-driven revision |
|---|---|
| Insert a rank/gather register and compare against a two-cycle-delayed queue. | `spec_rewrite` is a recurrence with multiple writers. Prefer stationary store payloads, narrow ordering and explicit pending ownership; any retained snapshot needs conflict handling. |
| Move fixup supersession masking to acceptance. | T47 already clears bytes at acceptance. A prepared write must also handle later coalesces, stores and invalidations through grant. |
| Wbuffer forwarding is a single LZC-selected word. | That read is under `G6LC_MUT_WBUF_FWD_ONE_HOT`; production merges byte owners across all matches. Balance the byte merge or snapshot complete winners. |
| PRF reads are registered. | `g6lc_prf` reads combinationally with current write-through. Preserve priority: current writes, pending writes, stored data. |
| Architectural RF has the same write-through contract. | `ariane_regfile_ff` lacks the PRF's explicit current-write overlay. Preserve its edge-visible timing. |
| A fourth multiplier stage follows automatically from the parameter. | The source implements tiled three-stage arithmetic. A new depth needs real registers, all companion paths and matching wrapper liveness. |
| Small multiplier slices are still full-width by nine. | AB=16, SB=8 tiling already exists in the three-stage branch. Repartition compressor levels/final carry work, not an obsolete product shape. |
| An IQ load miss can use LSQ replay to repair speculative wakeup. | Wrongly woken transitive consumers need their own recovery mechanism. Restrict early wake to guaranteed accepted producers until that exists. |
| Delayed head/CSR trace outputs are harmless hints. | Head ownership and RVFI retirement alignment are contractual. CSR architectural reads/writes remain synchronized with context and commit. |
| A refill-address CAM can replace `!lu_hit_o` directly. | Lookup/refill arbitration, overlap and context must first be reconciled; the substitution can change install behavior. |
| Yesterday's FU ready can acknowledge today's operation. | Only a retained reservation makes old availability a valid credit. |
| A serial divider cannot be pipelined without changing radix. | Its arithmetic can use multiple microsteps per digit, at a stated latency/throughput cost. |

## Per-module inventory and expected next residual

All paths below are relative to `core/`. Active fetch supply is `fetch_B/`;
shared predictors remain in `frontend/`. Frozen/oracle and formal source
copies are not alternate edit targets.

### Queues, issue, retirement and register files

| Source | Preferred mechanism | Remaining constraint |
|---|---|---|
| `store_buffer.sv` | Stationary payloads; narrow order and banked byte candidates. | Commit identity, age merge and pending visibility. |
| `ooo/g6lc_rename.sv` | Reserve/read → dependency resolve → publish rename group. | Inter-group bypass and per-branch logical checkpoint. |
| `ooo/g6lc_iq.sv` | Banked multi-candidate selection after wakeup. | Dependency latency and resource-compatible global order. |
| `ooo/g6lc_ooo_dispatch.sv` | Accepted metadata records with complete read bypass. | Shared capacity decision and TID reuse. |
| `scoreboard.sv` | Local lifecycle metadata and decoded WB events. | Exact live/head/cancel visibility. |
| `ooo/g6lc_lsq.sv` | Address events → local dependence candidates → verdict. | Publication and transitive replay. |
| `issue_read_operands.sv` | Extend existing execution packet; reserve FU capacity. | Operand bypass and completion scheduling. |
| `ooo/g6lc_rob.sv` | TID-to-slot directory and local lifecycle events. | Unique frees and head/count feedback. |
| `ooo/g6lc_prf.sv` | Buffered writes, bank-local decode, complete overlay. | Current-write priority and no-ready interface. |
| `ariane_regfile_ff.sv` | Write staging with edge-correct overlay; bank reads. | Architectural read timing and port collision order. |
| `ooo/g6lc_memdep.sv` | Row-local training; optional accepted training packets. | Authoritative LSQ dependence checks. |
| `lsu_bypass.sv` | Local kill/live bits and event-based occupancy. | Empty-only ready and sticky killed owners. |
| `csr_buffer.sv` | Registered free selection and reserved address records. | Commit lookup by TID. |
| `cva6_fifo_v3.sv` | Head cache / banked read; direct occupancy events. | Fall-through, zero-depth and simultaneous events. |
| `commit_stage.sv` | Read-only preparation before live commit eligibility. | Atomic architectural side effects and precise traps. |

### Execute and architectural control

| Source | Preferred mechanism | Remaining constraint |
|---|---|---|
| `multiplier.sv` | Bounded compressor groups and segmented final carry. | Tile depth, CLMUL/correction alignment. |
| `mult.sv` | Owner-qualified result storage and reserved completion. | Divider drain and exact multiplier depth. |
| `alu.sv` | Class partition; segmented carry/shift work. | FLU scheduling and branch comparison alignment. |
| `aes.sv` | Substitution/XOR preparation → linear completion. | AES/SHA/key-schedule alternatives and result bandwidth. |
| `branch_unit.sv` | Target/link preparation → resolve comparison. | Recovery covers newly admitted younger work. |
| `serdiv.sv` | Normalize/result staging; optional segmented digit microsteps. | Recurrence latency and corner-case semantics. |
| `fpu_wrap.sv` | Extend decoded request hold and owner-qualified return queue. | Vendor handshake and long-lived owners. |
| `ex_stage.sv` | Explicit completion reservation/response arbitration. | Finite FLU bandwidth and wakeup schedule. |
| `csr_regfile.sv` | Banked decode and commit-qualified prepared access. | Live privilege/events and CSR visibility. |
| `perf_counters.sv` | Segmented counters with exact carry summaries. | Writes, overflow and exact event cycle. |
| `cva6.sv` | Handshake-owned local CMO/invalidation descriptors. | Completion after visibility, not request preparation. |

### Fetch and prediction

| Source | Preferred mechanism | Remaining constraint |
|---|---|---|
| `fetch_B/frontend.sv` | Early next-block prediction and late token correction. | Checkpoint/epoch recovery and response capacity. |
| `fetch_B/instr_queue.sv` | Packet rank preparation before reserved publication. | Partial leftovers and precise replay point. |
| `fetch_B/instr_realign.sv` | Existing prefix/rank → gather boundary. | Per-hart carry state and packet consumption. |
| `frontend/g6lc_bp_ckpt.sv` | Per-hart post-free summaries and reclaim stage. | Clear-side restore and epoch-safe reuse. |
| `frontend/g6lc_loop_buffer.sv` | Bounded low address addition with prepared high alternatives. | Carry/wrap, arm/fill/consume priorities. |
| `frontend/ras.sv` | Per-hart top/next-top cache. | Repeated-pop refill and exact restore snapshots. |
| `frontend/g6lc_bp_loop.sv` | Row-local training feedback. | Lookup selection and same-row update order. |
| `frontend/g6lc_bp_statcor.sv` | Bank lookup/correction; retain existing row-local update. | Delayed correction token and decay priority. |
| `frontend/g6lc_bp_ittage.sv` | Hash preparation and table-response boundary. | Query versus training history snapshot. |
| `frontend/g6lc_bp_tage.sv` | Table candidates → balanced provider selection. | Base/alternate alignment and history update. |
| `frontend/g6lc_bp_ghist.sv` | Balanced folds / incremental per-hart summaries. | Atomic history+fold restore. |
| `frontend/g6lc_ftq.sv` | Head cache and separate speculative peek stage. | Flush+push reseeding and exact demand head. |
| `frontend/g6lc_fdip.sv` | PMA candidate before current demand/ready arbitration. | Prefetch usefulness and stale-candidate discard. |
| `id_stage.sv` | Parallel predecode/ranks; optional expanded packet. | Macro progress and partial issue acceptance. |

### Memory, translation and transport

| Source | Preferred mechanism | Remaining constraint |
|---|---|---|
| `cache_subsystem/wt_dcache_wbuffer.sv` | Versioned prepared fixup writes with live byte masks. | Coalescing, supersession and invalidation through grant. |
| `cache_subsystem/wt_dcache_mem.sv` | Ordered per-byte merge tree and complete snapshots. | Cache/refill overlay and load visibility point. |
| `cache_subsystem/wt_dcache_missunit.sv` | Refill install descriptors. | Invalidation order and MSHR release. |
| `store_unit.sv` | Reserved translated store/AMO packets. | Shared readiness and distinct AMO commit semantics. |
| `load_unit.sv` | Owned permission/hazard verdict and aligned response packet. | Early tag protocol and memory publication. |
| `cache_subsystem/g6lc_icache.sv` | Hit/miss response descriptor after tag/data read. | Fetch tokens, flush/refill races and miss capacity. |
| `cache_subsystem/g6lc_way_predictor.sv` | Row-local way decode / optional query packet. | Authoritative tag check and hint timing. |
| `cva6_mmu/cva6_tlb.sv` | Bank-local matches → translation selection. | Page/context overlap and refill policy. |
| `cva6_mmu/cva6_mmu.sv` | PTE snapshot → permission/address response. | Held context and exception ownership. |
| `cva6_mmu/cva6_ptw.sv` | PTE classification → leaf/next-level action. | Walk latency and obsolete-refill suppression. |
| `cva6_mmu/cva6_shared_tlb.sv` | Flush-match packets → accepted invalidation writes. | Fence completion after pipeline drain. |
| `cache_subsystem/wt_axi_adapter.sv` | Accepted bus return → coherence/return event. | Self-invalidation ordering and pending flags. |
| `axi_shim.sv` | Independent elastic channel descriptors and beats. | AXI stability, burst association and response ownership. |

The other three names in the historical over-budget set are vendored
`exp_backoff`, `rr_arb_tree` and `fpnew_top`. Their source is outside this
comment-edit pass. Wrapper-level candidates are, respectively, preparing
backoff eligibility without changing retry sequence/fairness; local candidate
arbitration with exact grant/lock handling; and coordinated FPU configuration
with the `fpu_wrap` lifetime contract. These are ownership boundaries, not
claims that a wrapper can shorten the vendor module's internal path.

## Integration order

1. **Remove avoidable logic depth first.** Per-byte balanced forwarding,
   row-local predictor/memdep updates, explicit local decode, bounded address
   arithmetic and balanced selection can improve structure without creating
   new response protocols. Preserve priority and already-present optimizations.
2. **Establish ownership and credits.** Completion queues in `ex_stage`,
   pending table-write overlays, cache install descriptors and translation
   response context make later internal stages usable. They are not
   independently sufficient for a 10-FO4 design.
3. **Redesign the largest recurrences.** Stationary STQ payloads, banked IQ
   selection, rename group publication and next-line fetch with late
   correction require changes across producer and consumer together.
4. **Partition remaining arithmetic.** Compressor levels, carry-prefix
   groups, S-box/linear crypto work and divider microsteps need real
   intermediate representations and a published availability schedule.

This is a dependency order, not a predicted percentage-speedup ranking.
Maximum clock improvement and maximum useful throughput are different goals.
Extra branch/load latency, lower issue bandwidth, added clock load or repeated
snapshot replay can outweigh a shorter local cone.

## Landed from these plans

| Pass | Source | Plan facet | Result |
|---|---|---|---|
| A140 | `cache_subsystem/wt_dcache_mem.sv` | `reshape` ordered per-byte merge | balanced first-valid tree; SAT-equivalent; placed 3.154 → 2.333 ns, area +31.0% (AND-OR alternative recorded) |
| A140 | `frontend/g6lc_bp_loop.sv` | `reshape` row-local training | equivalence + model; placed 1.911 → 1.459 ns, area -12.3% |
| A140 | `branch_unit.sv` | `split` target add vs resolve compare | carry-free sum-equals test SAT-proven but board-neutral (worst path is the redirect adder); reverted, kept as a trial patch for the frontend late-correction design |
| A140 | `scoreboard.sv` | `reshape`/`split` head-scan (absolute-order search, prefix-OR isolate) | SAT-equivalent at 5 geometries; isolated pair −71% unbuffered / −3.9% placed; board inside noise |
| A140 | `frontend/g6lc_loop_buffer.sv` | `reshape` bounded low add + prepared high alternative | sbs + miter; placed 1.824 → 1.507 ns, area +5.3% |

Evidence and the whole-core reading live in
`sv-timing/architecture/PIPELINE-PRAGMA-REVIEW.md` (A140). The corresponding
`svt-plan` blocks stay in the sources as the record of the remaining facets.

## Review record

This pass adds one proposal block to each of the 53 sources and links this
methodology from the architecture index and development guides. Source review
used the active filelists and nearby implementation, rather than copying plans
to duplicate/oracle sources. Static diff review checks that executable source
and the existing `svt-pipe:` directives are unchanged.

Licensing: original notices and SPDX expressions remain intact; existing
Etienne Cimon attribution is retained, with modification notices added where
needed. No file is relicensed. There is no new link set, clock, reset, latch,
state element, config field, PMU event, DFT path, encoding or device-tree
capability in this documentation pass. ISA/spec-map status consequently does
not change.

Tests and timing tools were intentionally omitted at the user's request.
Future executable work must replace proposal assumptions with explicit RTL
and consumer contracts; the comments themselves establish neither
functional correctness nor physical 10-adjusted-FO4 closure.
