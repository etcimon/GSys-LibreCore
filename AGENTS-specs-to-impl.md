# AGENTS-specs-to-impl.md — RISC-V spec ⇄ CVA6 RTL map

This is the **living cross-reference from the RISC-V specification to the SystemVerilog that implements
it**. When you change `core/**` (or `corev_apu/**`) RTL that affects ISA-visible behavior, update the
matching row here so the spec→code answer stays one hop away.

- Spec of record: `specs/riscv-spec.html` (anchors) with summaries in `agents/spec/*.html` (indexed by
  `agents/spec/INDEX.md`).
- Feature playbooks: `agents/guides/AGENTS-*.md`. Master narrative: `AGENTS.md` §5.
- Companion docs: `AGENTS-specs-to-tests.md` (what tests exercise each chapter) and
  `AGENTS-specs-coverage.md` (status-only summary, derived from this file + the tests map).

> **This file is a standing discipline (see `AGENTS.md`).** It is co-equal with keeping
> `agents/spec/INDEX.md` current and logging todos: an edit that changes ISA-visible RTL is not "done"
> until its row here (and the derived `AGENTS-specs-coverage.md`) is updated.

---

## Precise misalignment and fetch recovery — open stability contracts

`core/load_unit.sv` currently retains the original grant-time offset assertions and plain fatal
messages. The earlier alignment-qualified antecedent edit was reverted and must not be restored
as-is: for a three-bit RV64 offset, word alignment implies offset0/4 (<5), and half alignment
implies offset0/2/4/6 (<7), making those checks tautological. The prior claim that detection
strength was preserved is withdrawn. Under this core's declared misalignment policy, verify the
precise cause/PC/configured tval, absence of destination or forbidden device effects, and cancellation
of wrong-path exceptions. A valid replacement checker needs independent bad-completion and
missing-exception/kill mutations; no checker weakening is approved here.

A load-reserved reads memory and registers a reservation; it performs no store (`#ext:zalrsc`).
`core/cva6_rvfi.sv` clears `lsu_wmask` for `AMO_LRW`/`AMO_LRD` because LR is dispatched down the
STORE path with the other atomics, so the tracer previously emitted a write the architecture never
performs. A full protected dual-hart boot confirms the effect at the first LR retirement
(`lr.d.aqrl` at pc `0x80008662`): the older retained reference carries the phantom zero store and
current traces do not. This is trace-visibility only; no architectural store behaviour changed. The
failed-SC clause of the same repair suppresses the mask at commit where the outcome is known, and is
a separate obligation not exercised by that observation.

`core/fetch_B/frontend.sv` contains an unqualified kill-persistence candidate. It remembers one
killed VA, clears it on a replacement request and gates response acceptance by equality. Local
frozen-ELF evidence does not prove overlapping request/response ownership, same-address refetch,
FDIP or cross-hart/context safety. Review the full transaction contract with
`core/cache_subsystem/g6lc_icache.sv`; its READ path permits response/new-request overlap and
its killed translation/miss states already own cancellation duties. An independent observer must
not use DUT kill_owed state as its cancellation oracle. Preserve fetch_B and all configuration
legality guards. See the active S0-S4 plan for the implementation/verification change sets.

## OoO issue queue without compaction (2026-09-21, T4)

No ISA-visible behaviour changes. `core/ooo/g6lc_iq.sv` keeps entries stationary and records
relative age in a DEPTH×DEPTH matrix; issue selection ranks the ready entries by that matrix
(oldest-ready first, `NrIssuePorts` grants), removal clears the entry's row and column, dispatch
takes the lowest free slot with port order breaking same-cycle ties. The issue predicate (operand
readiness, unresolved-older-store gate, dispatch-time bypass, fence/system head rule) is unchanged,
and every frozen firmware probe retires cycle-identically. Timing: the DEPTH-wide payload mux tree of
the compacting layout is gone (23.97 → 14.97 FO4 on the sparse OoO slice); the select cone now
carries a per-entry popcount and is the module maximum at 27.0 of a 32 budget (T4b owns it).

## Fetch-response ownership by token and precise misalignment (2026-09-21, T3)

Precise control-flow recovery requires that a redirected or flushed fetch never delivers its
window to decode. `core/cva6.sv` adds a 2-bit `token` to `icache_dreq_t`/`icache_drsp_t`;
`core/cache_subsystem/g6lc_icache.sv` latches it with the accepted address and echoes it on the
response; `core/fetch_B/frontend.sv` wants one outstanding token, drops it on any kill and takes a
response only on token match, replacing the VA-equality kill persistence (and its
`G6LC_NO_KILL_PERSIST` seam). This is on the in-order path too. Precise load misalignment
(`#ld_st_misaligned` behaviour under the trap policy): `core/load_unit.sv` no longer asserts on the
captured offset (a misaligned request is legitimately granted before its exception is known); it
now asserts, under `translate_off`, that a misaligned load-buffer entry completes once with
`LD_ADDR_MISALIGNED` and a killed request, never retires with data, and carries tval according to
`TvalEn`. No functional RTL changed in `load_unit.sv`.

## OoO CSR table, store reservation and load bypass (2026-09-21, T2)

CSR accesses (`#csrinsts`) take their read value and apply their write at in-order commit, so
their issue order is free: under `OoOEn` `core/csr_buffer.sv` becomes a two-entry per-tid address
table looked up by the committing tid (`csr_commit_tid_i`), cancelled entries drop, and
`core/ex_stage.sv` keeps `csr_ready` out of `flu_ready`; `core/issue_read_operands.sv` marks only
the CSR unit busy on `csr_ready_i`. The in-order path is bit-identical. `g6lc_iq.sv` head-gates
only fence/system CSR-class ops. Memory ordering (`#memorymodel`): an LSQ store entry is the
reservation of a store-buffer speculative slot and lives until commit (`g6lc_lsq.sv`;
`g6lc_ooo_dispatch.sv` refuses `LsqStoreEntries > DEPTH_SPEC`), so stores issue out of order and
drain in order; a load waits only on older stores whose address is unresolved
(`st_unresolved_mask_o`), and a dispatch-time store-set verdict (`g6lc_memdep.sv`, trained by the
violating load's PC) may let it bypass those too, with the T1 violation scan and commit replay as
the safety net. A completed load holds its entry while an older store is unresolved. In-order
configurations tie every new signal low. Timing: the unresolved-store scan replaces the live-store
scan (same width); the CSR table adds a two-entry tid compare on issue and commit.

## OoO age key and memory-order replay (2026-09-21, T1)

Precise memory ordering under speculation (`#memorymodel`) needs one sound program-order key and
a way to undo a load that read before an older store's address was known. `g6lc_ooo_pkg` now
holds `ooo_age_older/ooo_age_dist` (circular `trans_id` distance from the commit pointer, sound
only for scoreboard-live operands); `g6lc_iq.sv`, `g6lc_lsq.sv` and `core/store_buffer.sv` call
it instead of inlining the compare, and IQ/LSQ entries assert liveness against the scoreboard
`issued` mask. `g6lc_lsq.sv` scans resolving store addresses against younger resolved loads and
reports the oldest overlapping load; `core/scoreboard.sv` marks that slot cancelled + `replay`;
`core/commit_stage.sv` drops it with `flush_commit`; `core/controller.sv` raises `mem_replay_pc`;
`core/fetch_B/frontend.sv` refetches `pc_commit` without the +4. Nothing bypasses an older store
yet, so the full-core path is inert; the leaf contract is proven (`core/ooo/formal/g6lc_ooo_age.sby`,
sat harness) and directed. In-order configurations tie every new signal low. Timing: the scan is a
bounded `NR_UPDATE × LD_ENTRIES` lane compare on registered load state; no new clock, reset or port.

## OoO cancelled FP result ownership (2026-09-21)

Precise recovery requires that a cancelled instruction's late result never completes, wakes or
supplies data for the scoreboard slot's next owner. `core/fpu_wrap.sv` now keeps a per-slot
ownership table under `OoOEn`: a live FPnew token owns its transaction ID until the raw result
handshake drains; cancellation (`cancelled_mask_i`) or a full flush marks that token cancelled
instead of forgetting it; a cancelled token's result is suppressed at `fpu_valid_o`; a replacement
request for a still-live ID is held in the existing protocol-inversion buffer, and a cancelled held
request is discarded. Because FPnew clears its pipeline valids on a full flush, the table clears on
flush too; a flushed token never drains, so retaining it would block the next same-ID operation.
`core/mult.sv` applies the same contract to the serial divider (`div_owner_*`, `div_idle_q`), gating
acceptance and the divider's FLU-port result; the single-cycle multiplier result cannot outlive
scoreboard reuse and is untouched. `core/ex_stage.sv` forwards the existing scoreboard mask to both.
In-order configurations reduce combinationally to the previous behaviour. Evidence is a real
FU/controller/scoreboard boundary fixture with pre-fix stale completion at8/16 slots, mutation
detection, replacement, flush-then-replacement and older-survivor controls; the strict UNOPTFLAT
structural gate remains open, and full-core FP/MULT+OoO qualification is not claimed. Timing: the
added path is a registered lookup of one mask bit and one table bit on accept/complete; no new
clock, reset or memory port.

## OoO cancelled-load lifetime before grant (2026-09-20)

Base-ISA load semantics and precise recovery require cancellation to remain attached
to an accepted instruction until every potential completion source has relinquished
it. `core/lsu_bypass.sv` now retains exact cancelled-TID membership for queued loads
under `OoOEn`; `core/load_unit.sv` discards a cancelled head without a memory grant,
forwarded result or synthetic completion. Correct-prediction release of a waiting
speculative load is preserved; only broad mispredict-based cancellation is replaced
by the exact mask. `core/load_store_unit.sv` carries that mask to the queue.
Post-grant response tombstones remain in
place; older tag/response obligations are not dropped. This closes a reproduced
pre-grant TID-reuse violation, not general FU or cross-hart lifetime qualification.
No new architectural interface, state array, pipeline stage, clock or reset; the
existing per-entry miss bit is reused. Cancellation lookup timing still needs STA.

## OoO load/store memory ordering (2026-09-20)

| Architectural obligation | Implementation seam | Qualified boundary |
|---|---|---|
| A load returns the value of the latest store preceding it in program order (`#memorymodel`, RVWMO same-address rules) | `core/store_buffer.sv` hazard + `st_fwd_merge`, keyed by circular trans_id distance from `commit_trans_id_i`; load identity added as `load_trans_id_i` via `load_unit`/`load_store_unit`/`store_unit` | Speculative entries are age-filtered; commit-queue entries stay exempt because they are architecturally older and their tids may be recycled. Directed same-word cases only. |
| Same-address stores are coherence-ordered in program order | `core/store_buffer.sv` speculative queue insertion | Arrivals are placed by program order rather than appended in issue order, so the commit handoff and memory see program order. |
| Forward progress under in-order commit | The same age filter on the hazard term | An older load must not stall on a younger store: that store cannot commit until the load retires. Verified by a directed case that previously hung. |
| Forward progress at queue capacity | `core/ooo/g6lc_iq.sv` store admission: a store is not selected while an older store is still unissued | Younger stores cannot fill the commit-drained speculative queue ahead of an older store that has yet to post. Loads still issue out of order. Verified by a ten-store directed case that previously hung. |
| Forward progress after LR (`#ext:a`) | `core/issue_read_operands.sv` LR/SC pair window, bounded under `OoOEn` by the LR's own `still_issued` lifetime | The window that blocks intervening non-SC stores closes when the LR retires or is cancelled, so an LR never paired with an SC — legal RISC-V — cannot block later stores forever. In-order behaviour unchanged. |
| Forward progress with a shared fixed-latency unit | `core/ooo/g6lc_iq.sv`: a CSR is issued only when it is the oldest live instruction | `csr_buffer` is depth-1 and holds `csr_ready` low until commit, and `flu_ready = csr_ready & mult_ready` marks every FLU unit busy for both harts. Gating on the commit head restores the buffer's depth-1 assumption instead of weakening it. Unblocks two-hart mutual exclusion. |
| A failed SC performs no memory write (`#ext:a`) | `core/cva6_rvfi.sv` `mem_wmask` suppressed at commit when an SC reports failure | Trace-visible only; the architectural behaviour was already correct. Without it the tracer reports a write the machine never performed. |

All of it is gated on `CVA6Cfg.OoOEn`; the in-order path is unchanged and re-booted.
No ISA, CSR, DTS, clock, reset or memory-port surface changes. The added comparators
sit on the store write path and still need STA before promotion.

## FP/CSR/WFI and guarded hart ownership (2026-09-19)

| Architectural obligation | Implementation seam | Qualified boundary |
|---|---|---|
| FP f0 and FP register lifetime (`#ext:f`, `#ext:d`) | `core/ooo/g6lc_prf.sv` configurable zero behavior; dispatch FP committed-map update | FP instance retains physical zero; full flush restores committed FP state |
| Architectural CSR/AMO results (`#ext:zicsr`, `#ext:a`) | `g6lc_ooo_dispatch.sv` late-result metadata and commit-time wakeup; `g6lc_iq.sv` wakeup-port count | Execution completion remains separate from usable operand data; no extra PRF data-write port |
| Per-hart architectural state | `g6lc_rename.sv` FP ownership/reclaim and post-allocation owner checks; dispatch SBE hart plumbing | Shared pools with separate maps; coarse-handoff probes, not mixed-residency closure |
| WFI / precise restart | `core/commit_stage.sv`, `core/controller.sv` | Accepted OoO WFI discards younger work before parking; existing next-PC mechanism; cancelled/faulting/invalid/stalled entries do not flush |
| No speculative-store architectural effects (`#memorymodel`) | `core/store_buffer.sv`, `LEGACY_SMT_KEEP` | OoO full flush discards speculative stores while preserving committed queue; cancelled stores cannot survive through legacy keep/replay state |

Existing config fields gate behavior; no ISA/CSR/DTS surface, clock/reset or pipeline
stage is added. Metadata/mux/wakeup fanout changes require physical timing/power and
DFT review. Production FP/hart refusals remain. Broader memory ordering and late-ID
reuse are still open; named evidence and limits are in the architecture record.

## OoO issue/recovery conservation (2026-09-19)

Base-ISA control-flow and precise-recovery obligations require every surviving
instruction to execute exactly once. `core/ooo/g6lc_ooo_dispatch.sv` now suppresses
FU offers on full/unissued flush and qualifies the IQ's consume mask by the visible
offer. A younger branch redirect previously let IRO acknowledge an older ready
instruction while clearing its FU-valid, permanently losing that instruction.
Scoreboard allocation, FU issue, WB and retirement are distinct contracts.

Existing OoOEn/NH1 envelope, hart/FP guards and issue width are unchanged. The IQ
store-age gate and selective cancelled-TID policy remain intact. No new state,
clock/reset, macro, scan path, software interface or DTS capability; only flush/valid
qualification in the existing issue cone. Physical timing/power and full ISA
qualification remain open. Contract tests and named core evidence are in the
companion test map and out-of-order architecture record.

## Issue-group program-order repair (2026-09-18)

Base-ISA dynamic instruction order is independent of numerical PC order.
`core/smt/g6lc_issue_barrier.sv` now compares issue-lane age (`o < p`) for its
same-group stack-pointer dependency, retaining valid and same-hart qualification.
This prevents a younger low-address target-path operation from blocking its older
call, and retains the dependency when an older producer has the higher PC.
Shared SMT modules were first relocated byte-for-byte from the excluded legacy
path; fetch_B remains the only instruction supply. No state, port, clock/reset,
ISA/DTS field or configuration default changed. A wide PC comparison is removed
from the issue-valid cone; no physical timing/power claim follows. Directed
positive/mutation controls and live-port leaf synthesis pass; full SMT/OpenSBI
completion remains a separate gate.

## WT cache response-tag ownership (2026-09-18)

Same-hart load/store visibility depends on preserving tag-lookup identity across
its response cycle. `core/cache_subsystem/wt_dcache_wbuffer.sv` now selects the
normal lookup's registered tag with `check_en_q`, not the current `|tocheck` request
set. Previously the final normal response could use the fixup tag after the normal
queue became checked, overwrite a real hit with a miss, and discard forwarding
without updating the resident line. The observed store queue handed over the new
bytes correctly; the stale reload was downstream of that seam. This changes an
existing mux selector only: no new state, latency, reset, config/default, ISA or
DTS change. Bounded directed ownership checks are qualified separately from full
WT cache/coherence and SMT2 firmware completion; physical timing is unmeasured.

## Reset eligibility and coarse SMT handoff (2026-09-19)

For fetch_B, `core/cva6.sv` passes enabled/non-halted hart readiness to the scheduler
without the legacy boot-PC, fixed-time or unseen-until-IPI masks. Reset-time software
rendezvous must not require an interrupt from a peer that is itself waiting for entry.
`core/smt/g6lc_thread_select.sv` now registers a switch request/target/reason, quiesces
admission, and waits for the scoreboard plus committed store/write-buffer paths to
empty. `scoreboard.sv` exports occupancy-based `sb_empty_o` through `issue_stage.sv`.
Admission stays blocked over the delayed switch pulse and while an SMT hart is halted.
This prevents an outgoing AMO's whole-scoreboard flush from deleting incoming work,
and prevents post-WFI work from blocking the drain. Quantum comparison avoids overflow
at a one-entry quantum. Single-hart scheduling remains the constant-zero identity.

Trade-off: this is conservative coarse scheduling, not overlapping in-flight harts.
D-cache miss overlap is reduced; throughput and physical timing are not qualified.
New small control state uses the existing asynchronous-active-low reset; no clock,
memory macro, ISA encoding or DTS change. Existing switch PMU outputs retain actual
handoff timing. Cancelled-transaction, privilege and FP breadth remain separate gates.

## Architectural SMT resume PC (2026-09-19)

With a drained handoff, the next architectural instruction is the restart authority,
not an I-cache request/continuation address. `core/smt/g6lc_smt_pc_bank.sv` reuses its
existing per-hart storage to track non-dropped retirements. `core/cva6.sv` supplies
sequential PC+instruction length or the resolved control-flow successor, plus
architectural redirects with frontend-consistent priority (trap, eret, commit,
debug). `core/scoreboard.sv` retains resolved branch targets for SMT independently
of debug enable. A speculative transport cursor no longer overwrites the bank on
switch. Multi-port updates preserve retirement order and hart ownership; zero PCs
remain representable. Single-hart behavior is inert.

This introduces retirement-to-bank mux/adder activity and may retain branch metadata
otherwise pruned in debug-disabled SMT configurations. PC-bank storage is reused;
no new clocks, resets, ISA or DTS fields. Physical timing/power and macro/privilege
breadth remain unqualified. Directed cases, mutation controls and live-port bank
synthesis pass; natural firmware now progresses past the former invalid resume but
still exposes a separate shared-data visibility failure.

## WT retained-copy freshness (2026-09-19)

RVWMO load-value obligations outlive the normal write-buffer entry. A newer
acknowledged store must refresh an older same-word fixup even at full capacity or
on a checked cache hit. `wt_dcache_wbuffer.sv` adds an address-qualified existing-copy
match, byte-mask-preserving coalescing, and a coalescing/retirement interlock. Its
same-cycle forward export updates a matching slot or uses a free slot rather than
hiding an unrelated valid copy at slot0. This repairs the observed zero returned
from a retained copy after a peer's acknowledged 0x80 initialization store.

Configuration: existing WtDcacheFixupDepth gate, unchanged zero-depth branch/defaults;
no new state, clock, reset, SRAM, ISA, DTS, permission or scan-control change. Existing
fixup PMU events include refresh activity. Timing risk: added word-address comparisons,
byte merges and slot selection on the ACK/forwarding cone; no physical STA/power
qualification. Preserve upstream notices. Broader cache/coherence qualification is
not implied by the directed same-word checks.

## AMO result availability at issue (2026-09-19)

The A-extension result must reach a dependent instruction only when its architectural
value is available. AMO execution writeback makes an entry eligible for commit, but
`commit_stage.sv` selects the real value from `amo_resp_i` later. In
`issue_read_operands.sv`, both scoreboard and same-cycle WB candidates are now excluded
from operand forwarding when the producer is an AMO. Dependents wait until retirement
removes the producer and the committed RF value is visible. CSR handling, ordinary
load/ALU forwarding and LR reservation/flush behavior are unchanged.

Existing RVA configuration gate; no new state, clock/reset, memory, encoding, DTS,
permission or scan-control change. Timing impact is an opcode-class decode and gate
on forwarding readiness per scoreboard entry. Dependent AMO consumers wait for commit
rather than consuming the placeholder; no physical STA/power claim. This qualifies
the architectural scoreboard path in the directed in-order SMT2 tests, not general
OoO/PRF or full ISA coverage.

## OoO result and retirement ownership (2026-09-19)

Precise architectural effects require a surviving owner; completion is not permission
to consume data or update committed state. `g6lc_ooo_dispatch.sv` now uses one data-
valid predicate for rename busy clearing, IQ wakeup, PRF writes and operand bypass,
rejecting cancelled/exception WB. ROB completion/exception handling stays separate.
It also derives architectural retirement from commit_ack and the existing cancellation
mask: map updates, old-physical frees, checkpoint release and LSQ store commit reject
cancelled slots while raw ROB retirement still drains them. No new state, interface,
clock/reset, memory or ISA/DTS field; existing OoOEn/hart/FP guards remain.

Timing: validity/cancellation gating fans out across wake/bypass and commit-side
controls. One live-port integer fixture reports91,242->88,501 cells for WB ownership,
then86,824 with cancelled-retirement qualification, state6,250 bits unchanged,
zero latches/SCCs. These are generic cells, not mapped area/power or target timing.
LSQ byte masks use constant XLEN lane bounds with predicated bits, preserving the
prior mask while permitting synthesis. Late CSR/AMO PRF result delivery, TID epoch
closure, per-hart namespaces and FP register classes remain separate open work.

## Status vocabulary

| Status | Meaning |
|---|---|
| `implemented` | Always present in the core pipeline (not config-gated off in any normal target). |
| `config` | Present behind a `cva6_cfg_t` bit in ≥1 shipped target; **verify in the per-target package** (`core/include/cv*_config_pkg.sv`). |
| `partial` | Incomplete, hint-only (e.g. executed as a NOP), or a subset of the extension. |
| `absent` | Not implemented in any shipped config. |
| `n/a` | Non-normative or microarchitectural (no dedicated ISA RTL). |

**Caveat**: statuses describe the *maximal capability across shipped configs*. Almost everything is
per-target — always confirm against the target's `core/include/cv*_config_pkg.sv` before relying on a row.
Line numbers are cited only where stable/known; otherwise the file is cited at module granularity.

---

## P0–P2 continuation recovery review

`core/frontend/g6lc_bp_ckpt.sv` keeps desync across ordinary stored-entry drain:
a branch whose checkpoint was dropped may still resolve, so count zero cannot
re-establish snapshot ownership. Explicit restore/reset/flush clears the existing
bit; no ISA, DTS, clock/reset, stage, state-capacity or config addition. This
microarchitectural recovery repair is leaf-tested, not full SMT2/OoO precision.
`architecture/remaining-upgrade-sequence.md` records reopened rename normal-release,
committed-map/free/reuse and LSQ-group/memdep contracts, plus the unfinished
concurrent L2/L3 ordering/install/invalidation/ATOP paths. Those source findings
prevent full P0–P2 closure. The overlap-v8 comparator's weaker preservation claim
is superseded; independent prior results retain their source/trace-bound scope.

In `corev_apu/l2_cache/g6lc_l2_top.sv`, fill issue/collection increments now compose
with served-entry retirement, tag writes wait for successful data-bank install,
and RR metadata writes use fill set/way. Victim selection is separated from its
probe-consuming FSM and fresh allocation uses registered lookup rather than
alloc-qualified feedback. `g6lc_l2_mshr.sv` uses the post-pop waiter count directly
as its append index. Directed collision/negative controls and small synthesis
checks pass; the remaining response-order/coherence/atomic contracts keep L2/L3
partial. No new clock/reset, capacity, ISA/DTS field or product default is added.

## Instruction-supply review (2026-09-15)

Base ISA instruction order and C-extension supply: `core/fetch_B/instr_queue.sv`
now compacts sparse valid slots into consecutive FIFO positions and maps
`consumed_o` back to the originating slots. Within-packet sequence ranking uses
slot order, not VLEN-wide PC comparisons. This repairs a reproduced dual-issue
skip of an older instruction hidden behind a selected FIFO head. Existing
`CVA6Cfg` geometry and module ports are unchanged; no clock/reset/state/stage or
ISA/DTS capability is added. The correction is unconditional inside the live
queue, not a new optional feature.

Independent remote leaf tests cover 2/4/8-slot envelopes, stalls, sparse masks,
flushes and predicted branch metadata. Generic four-slot/two-issue synthesis
is 25,618→22,354 cells with 5,954 sequential cells unchanged, no latches and
zero check problems. No physical area or STA claim. A second repair in `core/fetch_B/frontend.sv` uses the current response's
expected PC (registered pending target or response address) for current-cycle
slot filtering instead of the previous response's register. Fresh full-core
RVC and verified-norvc N1 checked-work now pass; two-active-hart cases still do
not complete. This is not full SMT2 qualification. See `architecture/core-fetch/README.md` and the F0–F5
plan in `AGENTS-todo.md` for scoped evidence and remaining obligations.

Follow-up: `frontend.sv` registers retry feedback (VLEN+1 state bits) to break
three combinational replay/cache-valid loops, aligns IQ exception/retry metadata
with current bytes, and completes architectural redirects on current IQ
acceptance. The redirect-chain witness now passes and full-core synthesis
reports zero check problems. An IPI-started dual-active diagnostic still fails;
no boot gate or scheduler was changed. Bounded realigner BMC and non-vacuity
covers pass in the recorded aligned-input reduced envelope; full SMT2 remains
unqualified.

The typed-trace follow-up demonstrates that fetch-transport PC is not the
restart boundary when ID/IQ tokens are discarded. `cva6.sv` now supplies the
metadata-selected `restart_frontier` to `g6lc_smt_pc_bank`; valid zero PCs are
represented explicitly. Recovery and controller flushes route by branch owner,
with inactive redirects written to that owner's bank. Original resolution still
feeds scoreboard/LSU and predictor training. The first corrected workload cookie
was insufficient: independent retirement checking exposed a second ownership
loss. Owner routing passes the RVI reference trace; mixed C/I then exposed a
split-target completion bug. `accepted_target` now completes on the consumed
instruction PC rather than its response window. Final RVI and mixed C/I
reference traces pass at the stated integer diagnostic scope; this is not
natural-firmware or complete SMT qualification.

### Circular IQ implementation follow-up (2026-09-16)

`core/fetch_B/instr_queue.sv` now selects heads by circular logical position
and advances the existing head by the fired prefix count. Compact insertion
makes timestamp arbitration redundant in the tested envelope; `push_seq`
remains diagnostic and is pruned from the generic synthesized functional path.
No depth/port/latency/config/scheduler/ISA/DTS change is introduced. Matched
four-slot/I2/H2 synthesis is 22,354 to 20,085 generic cells, with sequential
cells 5,954 to 5,426; not a physical or full-core area measurement.

The independent acceptance/metadata tests pass before and after; a fresh
corrected-runtime SMT2 model preserves both independent integer references,
the redirect-chain control and both 48 KiB/hart encodings. Expanded independent
IQ twelve-frame safety is preserved as historical bounded evidence. Asserted
storage/pointer and live-CF target relations subsequently enable binary-state
two-step induction and all twelve covers within 28 steps. This is unbounded
ordering safety in the reduced four-slot/two-hart/two-issue/32-bit ASIC envelope,
not all production widths, FPGA/RVH or full SMT2 qualification. Current priority is E1–E6 in
`AGENTS-todo.md`, with F0–F5 qualification requirements retained. Evidence and
limits: `architecture/core-fetch/README.md`, circular IQ section.

## How to use

1. Identify the spec chapter/`X.y` (via `agents/spec/INDEX.md`) your change touches.
2. Jump to the row below → open the **primary RTL loci** and the **config knob**.
3. For microarchitecture with no normative section (branch prediction, caches, speculation), use the
   "Microarchitectural map" section and the matching `agents/guides/` playbook.
4. After the RTL edit, refresh this row + the tests map + coverage.

---

## Part I — Unprivileged Architecture

### Base integer, memory model, fences
| Spec (anchor) | Status | Primary RTL loci | Config knob |
|---|---|---|---|
| RV32I / RV64I base (`#base`, `#rv32`, `#rv64`) | implemented | `core/decoder.sv`, `core/alu.sv`, `core/issue_read_operands.sv`, `core/commit_stage.sv`, `core/ariane_regfile_ff.sv` | `XLEN` (target pkg) |
| Address space / memory (1.4, `#sec:intro-memory`) | implemented | `core/load_store_unit.sv`, `core/cva6_mmu/`, `core/cache_subsystem/axi_adapter.sv` | `Axi*Width` |
| Traps / exceptions (1.6, `#trap-defn`) | implemented | `core/commit_stage.sv`, `core/csr_regfile.sv`, `core/controller.sv` | — |
| RVWMO memory model (3.1, `#memorymodel`) | implemented | `core/load_unit.sv`, `core/store_buffer.sv`, `core/lsu_bypass.sv`, `core/amo_buffer.sv` | `NrLoadBufEntries`, `MaxOutstandingStores` |
| Ztso total store order (3.2, `#ext:ztso`) | absent | — | — |
| Zifencei / FENCE.I (4.1, `#ext:zifencei`) | implemented | `core/controller.sv`, `core/fetch_A/frontend/frontend.sv`, `core/csr_regfile.sv` | `DcacheFlushOnFenceI` |

### Scalar integer extensions (ch4)
| Spec (anchor) | Status | Primary RTL loci | Config knob |
|---|---|---|---|
| Zicsr (CSRs) | implemented | `core/csr_regfile.sv`, `core/csr_buffer.sv` | — |
| Zihintpause (PAUSE) | implemented; **drives an SMT yield hint since 2026-09-19** | `core/decoder.sv` folds PAUSE into a NOP; `core/id_stage.sv` recovers the 0x0100000F encoding and pulses `smt_pause_hint_o` per hart; `core/smt/g6lc_thread_select.sv` holds a sticky yield request (cleared on that hart's next activation) and hands the core to an unpaused ready peer. Advisory only: ranked below anti-starvation, requires an unpaused peer, never gates readiness. Measured: lock holder 2.1618x -> 1.3719x; bit-identical behaviour when software never issues PAUSE. | `ZihintpauseEn`, `NrHarts` |
| Zicntr / Zihpm (counters) | implemented; **per-hart banks repaired 2026-09-19** | `core/perf_counters.sv` banks generic_counter/mhpmevent/OF/MINH/SINH/UINH by `hart_i` (dimensioned from `CVA6Cfg.NrHarts`, NH=1 identical to before) and emits per-hart scountovf/lcofi; `core/smt/g6lc_smt_csr_bank.sv` routes element h to CSR bank h instead of broadcasting. Previously ONE shared block aliased mhpmeventN/mhpmcounterN across harts. Discriminating probe `SMT_PMU`: shared signature (2,1) before (smt2-pmu-ownership-20260919), banked signature (1,0) after (smt2-pmu-banked-v2-20260919), each with the other polarity as a failing control. Zicntr mcycle/minstret were already banked (minstret gated by `commit_instr_i.hart_id`); mcycle counts elapsed cycles in every bank, so it is not per-hart service. Events remain core-wide signals attributed to the active hart. Also repaired the RV32 user-mode `hpmcounterNh` read: the range test used `>` (so 0xC83 never matched) and the index subtracted the machine base 0xB83 from a user address, indexing outside the counter array; live in `cv32a6_imac_sv32` (XLEN=32, PerfCounterEn=1, RVZihpm=1), which now lints clean. RV64 unaffected — the branch body is `riscv::XLEN == 32` guarded and its only other statement sets the dead internal `read_access_exception`. | `PerfCounterEn`, `NrHarts` |
| ↳ `mhpmeventN` selector encoding | implemented | 8-bit WARL, split `[7:5]`=group / `[4:0]`=index (`core/include/ariane_pkg.sv` `MHPMEvent*`); group 0 is the legacy 5-bit encoding unchanged; groups 1–7 reserved for feature upgrades (`core/perf_counters.sv`) | `MHPMCounterNum` |
| M / Zmmul (mul/div) | implemented | `core/mult.sv`, `core/multiplier.sv`, `core/serdiv.sv` | `RVM`/`Zmmul` (target pkg) |
| Zicond (cond. zero) | config | `core/alu.sv`, `core/decoder.sv` | `RVZicond` |
| Ziccif fetch atomicity (4.9) | implemented | `core/frontend/`, `core/cache_subsystem/cva6_icache.sv`, `core/instr_realign.sv` | `Icache*` |
| Ziccid I/D coherence (4.10) | implemented | `core/controller.sv` (FENCE.I), cache flush policy | `DcacheFlushOnFenceI` |
| Zicclsm misaligned (4.14) | partial | `core/load_store_unit.sv`, `core/load_unit.sv`, `core/store_unit.sv` | target-dependent |
| Zic64b 64-byte blocks (4.15) | config | `core/cache_subsystem/*` | `Dcache*LineWidth`/`Icache*LineWidth` |
| CFI — Zicfilp/Zicfiss (4.17, `#unpriv-cfi`) | absent | — | — |
| Zihintntl (4.18) | partial | `core/decoder.sv` (hint→NOP) | — |
| Zihintpause (4.19) | **implemented (config)** | `core/decoder.sv` (PAUSE→NOP when `ZihintpauseEn`) | `ZihintpauseEn` |
| CMO — Zicbom/Zicboz/Zicbop (4.20, `#cmo`) | **partial→Zicboz full-line** | Zicbom: decoder/store/HPDCACHE; **U7ᶜ Zicboz multi-beat** (`CBOZ_WAIT`/`ISSUE`); Zicbop: PREFETCH HINT→NOP; server package enables all three | `RVZiCbom`, `RVZiCboz`, `RVZiCbop` |
| Server math / AVX-like (U10) | partial (C-light + `_v`) | `cv64a6_server_math{,_v}`; HPDCACHE+HWPF+L2 auto; `server-math-tests`; `_v` enables RVV for Ara | `RVB`, `RVZiCbo*`, `HwPrefetchEn`, `RVH`, `RVV` |
| Ara / RVV attach (U10ᵇ) | **partial / live lintable** | Same as Vector V row: `ariane` gen_acc + `cva6_ara_attach` + `cva6_axi_2to1_mux`; `CVA6_ARA_ATTACH=1` Verilator green; `vendor/ara/` + shims; suite `ara-vector-path`. Spec sub-file `agents/spec/riscv-spec-I-9-vector.html` | `RVV`, `EnableAccelerator` |
| KVM/H stress + H-edge | directed green (Spike+RTL 3/3) | `verif/tests/custom/kvm_h/*`, suites `kvm-h-spike` / `kvm-h-tests` | `RVH`, `SstcEn` |
| L3 DT / inclusive | **implemented (gated)** | L3/L2 victim→L1 (`cva6_l3_inclusive_inv`); L3→L2 tag match-inval (`l2_back_inval_*` / `inval_match_*`); TB `INCLUSIVE_L3=L3En` | `L3En`, cluster `INCLUSIVE_L3` |
| Stream plane × multicore (U6/p6) | **implemented (gated)** | `cva6_server_prefetcher` + `NrCores` packages; suite `mc-stream-tests` | `ServerPrefetchEn`, `NrCores`, `L2En`/`L3En` |
| PMU group 2 L2/L3/PF | implemented | `perf_counters` g2; cluster→ariane→cva6 ports | `L2En`/`L3En`/`ServerPrefetchEn` |
| OoO formal | **live freelist+ROB+rename** | `core/ooo/formal/`: freelist→`cva6_freelist` (prove); ROB→`cva6_rob` via yosys-slang (BMC d=16); rename→`cva6_rename` multi-port free/busy/bypass (BMC d=12, PRF=40); cancel policy model; `verify.formalTasks` (4 tasks). Cover task `g6lc_ooo_rename_cover.sby` is path-check only: local yices PASS (alloc/dual/exhaust/ckpt); testharness z3 timed out | `OoOEn` |
| Fetch formal (live modules) | **REOPENED — 2026-09-15 non-vacuity review** | Two live harnesses had `hart_i < 1'(2)` and undriven internal stimulus. Hart bounds are widened, stimulus promoted to top-level ports, and separate cover tasks added. Prior PASS is not proof of the live contracts. The following historical description is superseded where it claims complete proof:  `g6lc_fetch_realign.sby` instantiates the real `instr_realign` and proves **I1/I2** no-fabricate (each emitted halfword == `data_i` at that slot's own address) and **I4** per-hart carry isolation (NH=2), in the smt2 configuration. `g6lc_fetch_iq.sby` proves **I6 clause 2** by self-composition: two live `instr_queue` copies with identical control and different raw `instr_i` must agree on `ready_o`/`consumed_o`/`replay_*`/`fetch_entry_valid_o`/`.address` — "head selection must not depend on opcode/rd/FU" is an information-flow claim, so no single-trace assertion can witness it. **I6 clause 1 (issue order is program order) is now implemented in `core/fetch_B/instr_queue.sv` (O7p): a 16-bit `push_seq` counter, a per-entry PC-rank stamp, and a greedy oldest-first output selection. A 4-wide push `shamt` width bug was fixed so pseq no longer collides. The `g6lc_fetch_iq.sby` self-composition still proves clause 2. A dedicated clause-1 live-queue BMC is in `core/fetch_B/formal/g6lc_fetch_iq_order.sby`. FIFO insertion order + control self-composition is `cva6_fifo_v3_order.sby` **PASS** (BMC d=12, in the default remote suite 12/12; stimulus must be top-level ports — read_slang was tying undriven internals to per-instance `1'x`). That discharges the old `push_seq_range_ok` assume. `g6lc_fetch_iq_order.sby` asserts `pseq_monotone` without that assume and is not in the default suite until it PASSES. Residual SL-W: `mini_fdt_next_tag_lbu` **PASS**; `mini_stq_flush_fwd` next (`wbuffer_fwd_hit_o` treats a complete XLEN wbuffer/fixup word as a hit so a miss refill cannot overlay stale DRAM; miss-unit mask not re-landed).** | smt2 pkg (FW=64, T=2, RVC, NI=2) |
| Fetch formal (L2 rung) | **PROVEN — gate 9/9 (2026-08-31)** | `core/fetch_B/formal/`, all `mode prove` k-induction: `g6lc_fetch_align` I3/I5 leftover; `g6lc_fetch_order` I2/I7 packet (at the `N=8` geometry **ceiling**, which subsumes every narrower `INSTR_PER_FETCH`); `g6lc_fetch_redirect` I8 total order incl. restore-never-outranks-trap; `g6lc_fetch_smt` **R1/I4 `packet_hart`, I8 `commit_for_hart`, I10 `snap_pc`** (`en_restore`/`en_smt` free ⇒ T=1 and T>1 in one run); `g6lc_fetch_geo` **I12 + the window algebra swept over 6 envelope points** (FW 32/64/128/256 × RVC, 64/128 without). Self-contained (`config_pkg` + `g6lc_fetch_pkg` + props via `read_slang`); `verify.formalTasks` + `diag-fetch-formal-paths`. Ladder map: `core-fetch/SPEC.md` §10 | `FETCH_WIDTH`, `FETCH_ALIGN_BITS`, `RVC`, `NrHarts`, `NrIssuePorts` — all swept or freed, none re-soaked |
| Formal toolchain (host) | **implemented (cross-platform)** | `build-platform/scripts/install-formal.sh` + `recipes.ts installFormal`: source-builds Yosys (CMake/Ninja, `-j` cores) with the **integrated sv-elab/slang** frontend plus SymbiYosys into `workspace/tooling/formal`; adopts an existing install when it already has `read_slang`. Windows delegates to WSL (`platform/wsl.ts`), matching the Spike pattern. Distro Yosys is unusable here: 0.33 rejects `ai_cfg_t'(0)` in `config_pkg.sv` and rejects package-to-package `import`. `eda.ts` resolves oss-cad → managed → PATH, detects integrated-vs-plugin slang from the artifact, and runs tasks concurrently (`sby -j` × task pool, `--formal-jobs`/`--formal-tasks`) | `toolchain.versions.yosys` (>= v0.67), `verify.formal.{jobs,taskJobs,workdirRoot}` |
| ISA red lines mechanized | **live veto** | `firmware-boot-principles.md` §E as `diag-isa-red-lines` (commit value filter, cancelled writeback, forward-by-value, resolve-by-PMA, squash exemption list) + `diag-fw-accommodation` (firmware/bootrom comment naming an RTL mechanism). New `source-scan` diagnostic kind in `build-platform/src/{config/schema.ts,tooling/diagnostics.ts}`; recorded pre-existing debt is waived-with-note, not hidden | runs in `core` (a default compartment) |
| SMT topology bound (L1 rung) | **implemented** | `core/include/config_pkg.sv`: `CVA6_MAX_SW_HARTS=8` + `assert (NrCores * NrHarts <= CVA6_MAX_SW_HARTS)`. Bounding the two factors separately left the product unchecked, so `NrCores=8, NrHarts=2` elaborated cleanly against a 16-context PLIC. Both operands are compile-time constants, so the check belongs at elaboration, not at Linux boot | `NrCores`, `NrHarts` |
| Fetch layer contracts (L3 rung) | **implemented** | `core/fetch_B/g6lc_fetch_dbg.sv` (bound into `frontend`, `translate_off`): I1 bytes==memory, I2 slot pc-step + no slot hole, I8 restore-never-outranks-trap, kill_s1 legality, accept⇒same-window — plus new I3/I2/I5 **emission** contracts now that the bind carries the realigner carry state (`leftover_valid`, `leftover_pc`, and `carry_instr_q` observed hierarchically). Enables are not re-checked here: the realigner builds them from the `g6lc_fetch_pkg` functions the L2 formal proves. I23 hold bound is a latched `$warning` — observed, never released (`NEGATIVE.md` §1) | `NrHarts`, `NrIssuePorts` via `fetch_geo_t`/`fetch_en_t` |
| Hart-count contract (R11 / I25) | **implemented (build time)** | `software/smt2-linux/scripts/dts_to_dtb.py`: the `cpu@` count OpenSBI would tally must equal `NrCores × NrHarts` of the owning package. Counting rules mirror `platform/generic/platform.c:172-184` (parseable `reg`; `hartid < SBI_HARTMASK_MAX_BITS`=128; `fdt_node_is_enabled`). `platform.hart_count` is the FDT walk's only durable output, so a mismatch is invisible to firmware. `DTS_CONFIG_PKG` pairing + `--check-all-harts` sweep. Caught a live `ariane-ai.dts` (1 cpu@) vs `g6lc64_ai` (`NrCores=2`) mismatch | `NrCores`, `NrHarts`; DTS ↔ config ↔ spec triple |
| SMT / multi-hart (U6.1) | implemented (fine) | `core/smt/*` + banked RAS/GHR; IF-only switch; CSR commit by `hart_id`; `smt2-bringup.md` | `NrHarts`, `SmtPolicy` |
| Full OoO (U5) | **partial (gated; integration blocked)** | 4-issue rename/IQ/ROB/LSQ; cancel-mask mispredict squash; PRF WB gate; PMU g1; `cv64a6_ooo` + `cv64a6_ooo_server` | `OoOEn`, `DeepSpecEn`, `NrIssuePorts`, `RobEntries`, `MemDepPredEn` |
| Full speculative execution (FSE) | implemented (config; S0–S6) | Arch+plan under `architecture/speculative-execution/`; depth plane; recovery; LSU younger cancel; SMT-tagged cancel; **S6** `spec-deep-tests` + RVWMO/A directed + security residual | `DeepSpecEn`, `SpeculativeSb`, `BPCkptDepth`, `NrHarts`, `NrLoadBufEntries`, `MaxOutstandingStores` |
| L3 + server prefetch | implemented (gated) | `corev_apu/l3_cache/*`; DT notes `dts-l3-prefetch.md`; PMU grp1 proxies | `L3En`, `ServerPrefetchEn` |
| Multi-core cluster + L1 inv (U6.2) | partial | `corev_apu/src/cva6_cluster.sv`, `cva6_l1_inv_adapter.sv`; core `l1_inval_*` ports → WT D$ | `NrCores`, `Coh*` |

### Atomics (ch5)
| Spec (anchor) | Status | Primary RTL loci | Config knob |
|---|---|---|---|
| A extension (5.1, `#ext:a`) | config | `core/amo_buffer.sv`, `core/load_store_unit.sv`, `core/store_buffer.sv` | `RVA` (target pkg) |
| Zalrsc LR/SC (5.2) | config | `core/load_store_unit.sv`, D$ reservation in `core/cache_subsystem/*` | `RVA` |
| Zawrs wait-on-reservation (5.5) | **partial (config)** | `core/decoder.sv` (WRS.NTO/STO→WFI path), `core/csr_regfile.sv` WFI stall | `ZawrsEn` |
| Zacas compare-and-swap (5.9, `#ext:zacas`) | **implemented (W/D/Q gated)** | `RVZacas`; decode `AMO_CASW/D/Q` (`core/decoder.sv`); third-op + Q pair RF gather; `amo_req` hi/`is_quad`/`dual_we`; HPDCache multi-beat `CASD_*` (+Q HI beats); dual WB in `commit_stage`; pkgs `server_math{,_v}` / `ooo_server` / `imafdc_sv39`. **Hard RTL golden** `mc-mini-veri` + `zacas-policy` (`mini_amocas_{w,d,q,q_illegal}`); plan `architecture/zacas-amocas-q.md`. Spike has no zacas (not a golden). Spec sub-file `agents/spec/riscv-spec-I-5.9-zacas.html` | `RVZacas` (⇒ `RVA`) |
| Za128rs/Za64rs/Zabha/Zaamo/Zalasr (5.3-5.10) | partial | (subset via A) `core/amo_buffer.sv` | — |

### Floating point, compressed, bitmanip, vector, crypto, matrix
| Spec (anchor) | Status | Primary RTL loci | Config knob |
|---|---|---|---|
| F / D floating point (ch6, `#zf`) | config | `core/fpu_wrap.sv`, `core/cvfpu/` | `RVF`, `RVD`, `FpuEn` |
| Q quad / Zfh half | absent / config | `core/cvfpu/` (Zfh only) | `RVZfh` |
| C compressed (ch7, `#zc`) | config | `core/compressed_decoder.sv` (identity `c.li`; SMT+SS G1ba leftover-RVI mash recover), `core/instr_realign.sv`, `core/fetch_A/frontend/instr_scan.sv` | `RVC` |
| Zcmt (table jump) | config | `core/zcmt_decoder.sv` | `RVZCMT` |
| Zcb / Zcmp | config / partial | `core/compressed_decoder.sv`, `core/macro_decoder.sv` | target-dependent |
| Zba / Zbb / Zbs bitmanip (ch8, `#bits`) | config | `core/alu.sv`, `core/decoder.sv` | `RVB` |
| Zbc / Zbk* (carry-less / crypto bitmanip) | partial | `core/alu.sv`, `core/aes.sv` | target-dependent |
| Vector V / Zve* (ch9, `#vector`) | **partial (Ara attach)** | No in-core VRF; U10ᵇ Ara: `core/acc_dispatcher.sv`, `core/cva6.sv` `gen_accelerator`, `misa.V` in `core/csr_regfile.sv`; SoC `corev_apu/src/cva6_ara_attach.sv` + `cva6_axi_2to1_mux.sv`; vendor `vendor/ara/{upstream,Flist.ara,cva6_shim/}`; package `cv64a6_server_math_v_config_pkg.sv`. Mutually exclusive with `CvxifEn`. Live Verilator lint under `CVA6_ARA_ATTACH=1`. Software contract: `agents/guides/AGENTS-vector.md`, DTS `corev_apu/bootrom/ariane-server-math-v.dts`, directed `verif/tests/testlist_ara_vector.yaml`. Full RVV cosim / OpenSBI VRF still open | `RVV`, `EnableAccelerator` (`CVA6ConfigVExtEn`) |
| Packed SIMD (ch10, `#zp`) | absent | — | — |
| Scalar crypto Zkn (AES) (ch11, `#crypto`) | partial | `core/aes.sv` | target-dependent |
| Vector crypto Zvk* | absent | (not part of Ara attach baseline) | — |
| Matrix (ch12, `#matrix`) | absent | — | — |

---

## Part II — Privileged Architecture

| Spec (anchor) | Status | Primary RTL loci | Config knob |
|---|---|---|---|
| Privilege levels M/S/U (ch1) | implemented | `core/csr_regfile.sv`, `core/commit_stage.sv` | `PRIV`/mode support (target pkg) |
| CSRs (ch2, `#priv-csrs`) | implemented | `core/csr_regfile.sv`, `core/csr_buffer.sv`, `core/smt/g6lc_smt_csr_bank.sv` (G1dz: `csr_rdata`/`csr_exception` mux by commit hart) | — |
| Reset (3.4, `#reset`) | implemented | `core/cva6.sv`, `core/csr_regfile.sv` (reset values) | — |
| NMI (3.5, `#nmi`) | partial / config | `core/csr_regfile.sv`, `core/controller.sv` | `Smrnmi` |
| PMA — physical memory attributes (3.6, `#pma`) | implemented | region rules in target pkg + `core/cva6.sv`, checked in `check_cfg`. smt2 I4ag + `_v` S4: execute is `.text` (`0x1e000`) + payload `@0x80200000` (4 KiB smt2 / 32 MiB `_v`), not 1 GiB DRAM — I4v then refuses JALR into FDT/stack (`0x80046f2c`). S4 HPD: D$ loads of execute-region are uncacheable (`cva6_hpdcache_if_adapter` load PMA) so a `.text` jtab HIT cannot race I$ of the same 64 B L2 line | `Nr{Cached,Execute,NonIdempotent}RegionRules` |
| PMP — physical memory protection (3.7, `#pmp`) | implemented | `core/pmp/` | `NrPMPEntries` |
| Sv32 (4.3) | config | `core/cva6_mmu/` | `vm_mode_t` |
| Sv39 (4.4, `#sv39`) | config | `core/cva6_mmu/` | `vm_mode_t` (`ModeSv39`) |
| Sv48 (4.5) | config | `core/cva6_mmu/` | `vm_mode_t` (`ModeSv48`) |
| Sv57 (4.6) | absent | — | — |
| SFENCE.VMA / supervisor instr (4.1-4.2) | implemented | `core/cva6_mmu/`, `core/controller.sv`, `core/csr_regfile.sv` | — |
| Hypervisor H (ch5, `#hypervisor`) | partial (U9.0–U9.2) | `csr_regfile.sv` (HS CSRs + **vstimecmp/STCE/VSTIP/htimedelta** + TIME under V + virtual-instr STCE + HVIP mask), `cva6_mmu/` 2-stage+G-only PTW, HLV/HSV/HFENCE; PLIC 16-ctx | `RVH`, `SstcEn` |
| Smepmp (6.3) | config | `core/pmp/`, `core/csr_regfile.sv` | `Smepmp` |
| Smstateen (6.1) | config | `core/csr_regfile.sv` | `RVS`/stateen bits |
| Smrnmi (6.5) | partial / config | `core/csr_regfile.sv` | `Smrnmi` |
| Smctr / priv-CFI (6.8, 6.9) | absent | — | — |
| Svnapot (7.1) | **implemented (config)** | `cva6_ptw.sv`, `cva6_tlb.sv`, `cva6_shared_tlb.sv` (`is_napot_64k`) | `SvnapotEn` |
| Svpbmt (7.2) | **partial (config)** | PTE `pbmt` in `cva6_mmu.sv`; PTW legality; `menvcfg.PBMTE` / `pbmte_o` in `csr_regfile.sv` (LSU PMA force TBD) | `SvpbmtEn` |
| Svadu / Svinval (7.3–7.4) | partial / absent | A/D mostly SW; no Svinval | — |
| Sstc supervisor timer (8.8) | **implemented (config)** | `stimecmp` + `rtc_time_i` compare + STIP in `csr_regfile.sv`; CLINT mtime SoC-side | `SstcEn` (+ `rtc_time_i`) |
| Sscofpmf (8.9) | **implemented (config); per-hart OF/LCOFI since 2026-09-19** | `perf_counters.sv` OF/LCOFI now banked per hart and routed to the owning CSR bank only (previously broadcast, so an overflow was visible to both harts and either could clear it); `scountovf` in `csr_regfile.sv`; 8-bit mhpmevent (U8ᵃ). MINH/SINH/UINH filtering uses the active hart's privilege, which is the hart the events are attributed to. | `SscofpmfEn`, `NrHarts` |
| Sh hypervisor extensions (ch9) | partial / config | `core/csr_regfile.sv`, `core/cva6_mmu/` | `RVH` |
| Privileged listings / rationale (ch10, appA) | n/a | — | — |

---

## Part III — Profiles

Profiles (`#vol:profiles`) are checklists of mandated extensions, not RTL. A given CVA6 target satisfies
a profile iff its config package enables the required rows above. Status is therefore **config-dependent**;
check the target package against the profile.

| Profile (anchor) | Status | Notes |
|---|---|---|
| RVI20 (`#_rvi20_profiles`) | config | Base integer targets satisfy it. |
| RVA20 (`#_rva20_profiles`) | partial / config | RVA-class 64-bit targets approximate it (verify F/D/C/A/Sv39/counters). |
| RVA22 (`#_rva22_profiles`) | partial / config | Adds Zic*/Sv* mandates — verify per target. |
| RVA23 (`#_rva23_profiles`) | absent / partial | Requires V + newer Ss*/Sm* not in-core. |
| RVB23 (`#_rvb23_profiles`) | absent / partial | As RVA23 (bitmanip-oriented). |

---

## Microarchitectural map (no normative spec section)

These are **integration/micro-arch**, constrained by the ISA only indirectly (they must stay transparent
to architectural results, coherence, ordering, precise traps). See `AGENTS.md` §5 and the guides.

| Feature | Status | Primary RTL loci | Config knob | Guide |
|---|---|---|---|---|
| API-neutral APU transport (not ISA-visible) | **partial: register/queue control with opt-in diagnostic attachment; no live virtqueue GPU service or renderer** | `corev_apu/apu/g6lc_apu_{top,virtio_mmio}.sv`, `corev_apu/apu/include/g6lc_apu_pkg.sv`, `corev_apu/include/g6lc_apu_cfg_pkg.sv`; modern virtio-mmio, validated split-queue geometry, stop/reset acknowledgement, queue-enable qualification, full fence/context debug metadata, interrupts/config generation | Separate `apu_cfg_t`, default `ApuOff`; `ApuP1Transport` grants VERSION_1/RING_RESET only. No change to `cva6_cfg_t` or MatrixEn dependency. `apu_soc_legal` rejects single-core/SMT firmware reservations and is enforced by the optional AXI wrapper; full SoC routing remains open. | `AGENTS-todo.md` P1 transport review owns sideband/quiescence and timing contract; external driver requirements in `g6lc_bios/architecture/DISPLAY.md`. Remote directed/lint and generic synthesis pass; SoC protection, DMA integration, shader/raster/sampler/output and scanout remain unimplemented. |
| APU private control / AXI-Lite boundary | **partial: standalone tested enforcement; no trusted SoC source/domain routing** | `corev_apu/apu/g6lc_apu_axi_lite.sv`, `g6lc_apu_control.sv`, `include/g6lc_apu_bus_pkg.sv`, `Flist.apu_axi`; two unchanged PULP bridges carry captured authorization/epoch, separate apertures, atomic queue/completion snapshots, software plus hardware drain acknowledgements | `ApuCfg.Enable`, independent `ControlBase/ControlLength`, explicit firmware reservation and `CoreCfg` admission check. External AW/AR grants must come from a trusted integrator, never guest PROT. | `AGENTS-todo.md` P1 AXI/control follow-up defines ABI and teardown/retry contracts. Remote 318-check suite plus on/off lint/synthesis pass. Physical protection, DMA and software boot integration remain open; disabled endpoint retains AXI response state. |
| APU bounded resource DMA read leaf | **partial: checked AXI read leaf, connected as SG/memory child; protected lifecycle/SoC path incomplete** | `corev_apu/apu/g6lc_apu_dma_read.sv`, native DMA types/checker in `include/g6lc_apu_pkg.sv`, AXI types in `include/g6lc_apu_bus_pkg.sv`; snapshot request/mapping, context/permission/epoch/extent admission, byte-exact narrow head/tail, 4 KiB/burst splitting, registered stream and completion, cancellation drain and protocol-fault quarantine | `ApuCfg.Enable && DmaReadEn`, default read-off; `DmaWindowBase/Bytes`, `DmaReadMaxBytes`, `DmaReadBurstBeats`. One outstanding burst, non-coherent only; window excludes configured MMIO/control/firmware RAM. | `AGENTS-todo.md` P1 DMA handoff contract: mapping is trusted and pinned until idle, partial data is provisional, protocol faults require coordinated fabric reset. Remote burst=1/16/256 and high-address suites plus lint/synthesis pass; disabled zero cells. SG/read-write child tests exist; cache ownership, handle-only lifecycle and renderer proof remain open. |
| APU bounded resource DMA write leaf | **partial: checked AXI write leaf with SG/used-ring consumers; no protected production SoC path** | `corev_apu/apu/g6lc_apu_dma_write.sv`; shared admission checker and write aliases in `include/g6lc_apu_pkg.sv`. Write-authorized mapping snapshot, validated packed chunks, naturally aligned single-beat stores, independently held AW/W, B-ordered completion, cancellation drain and bad-B quarantine | `ApuCfg.Enable && DmaWriteEn`, default write-off; own `DmaWriteMaxBytes`, common protected-window/non-coherent requirements. One outstanding write; no multi-beat aggregation. | `AGENTS-todo.md` write lifetime contract: strobed-byte count is not a commit guarantee on error, no rollback, backing pinned through idle, partial destinations not published. Two 298-case memory-model profiles and enabled/disabled lint/synthesis pass. SG/storage consumers exist; protected table lifecycle, coherence, formal, rendered output and SoC qualification remain open. |
| APU bounded SG walker | **partial: standalone list walk + fragment lease remotely tested; not attached to virtqueues** | `corev_apu/apu/g6lc_apu_sg.sv`, `Flist.apu_sg`; 16-byte guest list fetch through the read leaf into `tc_sram` Latency=1, overlap/empty/backing checks, logical-to-physical fragments, child DMA lease until idle | `ApuCfg.Enable && SgEn`, requires `DmaReadEn`; `SgMaxEntries` 64..4096 power-of-two | `AGENTS-todo.md` P1 SG walker. Runner `APU_SG=1`. No renderer. |
| APU mapping table + immutable command SRAM | **partial: mailbox-bound table/snapshot; hardware reset validity and lease retirement incomplete** | `corev_apu/apu/g6lc_apu_storage.sv`; resource insert/lookup/invalidate, one command snapshot, `apu_xfer_check` box/stride helper, optional `tc_clk_gating` on SRAM clocks | `MaxResources` / `MaxCmdBytes` power-of-two enables; default 0 in `ApuP1Transport` | `AGENTS-todo.md` P1 storage. Runner `APU_MEM=1`. Snapshot is not virgl decode. |
| APU firmware memory backend | **partial: mailbox-bound map/used/CMD_DMA/SG operations; not combined with exec or protected SoC traffic** | `corev_apu/apu/g6lc_apu_mem.sv`; instantiates storage, SG, DMA read/write and queue; 2R/2W AXI mux with registered AR grant; idle aggregation | `Enable` plus any of MaxResources/MaxCmdBytes/SgEn/DmaReadEn/DmaWriteEn | `AGENTS-todo.md` P1 backend. Runner `APU_MEM=1` includes `tb_g6lc_apu_mem` (7 cases / 12 checks). `g6lc_apu_sys` binds it behind AXI-Lite mailbox, but raw mappings/held request fields are not handle-only protection and MemEn suppresses ExecEn. |
| APU used-ring publisher | **partial: standalone elem-then-idx DMA; not transport-sideband** | `corev_apu/apu/g6lc_apu_queue.sv`; writes `virtq_used_elem` then `used.idx` through the write leaf. Idx store is publication. | `ApuCfg.Enable && DmaWriteEn` | `AGENTS-todo.md` P1 queue. Does not pulse `used_valid`. No SoC attach. |
| APU firmware RAM window | **partial: AXI4 SRAM/fills; read/write error drain and lane strobes corrected; not protected boot RAM** | `corev_apu/apu/g6lc_apu_fwram.sv`; idx 12, `0x90000000` / 256 KiB; full ARLEN+1 error responses and AWLEN+1 rejected-write drain on/off; malformed WLAST quarantines until fabric reset | `+define+G6LC_APU`; `ApuHarness`; no new config/capability grant | `architecture/uncore/apu-firmware-ram.md`. Follow-through 49 cases / 5,699 checks / 5,372 clocks; enabled/disabled 4-KiB lint/synthesis and retained-memory assertion pass. Upper-PA aliases, source protection, narrow/atomic policy, recovery integration and real loading remain open. Separate AXI4-Lite bridge errors are not fixed by this leaf. |
| APU testharness load compositor | **partial: rules/boot/AXI hex fetch + cluster through DRAM-hole map + idle DMA export + OpenSBI-visible 14-rule map + ExecEn bind; not OpenSBI firmware boot** | `g6lc_apu_th_load.sv` wraps xbar+fwram; `g6lc_apu_sys` `gen_exec`; `tb_g6lc_apu_th_fetch.sv` / `tb_g6lc_apu_dma_init.sv` / `tb_g6lc_apu_th_osbi.sv` / `tb_g6lc_apu_th_exec.sv` | `+define+G6LC_APU`; `ApuHarness` `DmaReadEn=0` `ExecEn=0` | `architecture/uncore/apu-testharness-load.md`. Remote th_load 3/21/16; th_fetch 14/283; dma_init 10/19; th_osbi 27/4; th_exec 38/271/1,601. |
| APU DMA initiator | **partial: compositor export + DRAM-lo read; not testharness xbar slave** | `g6lc_apu_xbar`/`th_load` `dma_req_o`; `tb_g6lc_apu_dma_init.sv` | `DmaReadEn`; window excludes firmware RAM | `architecture/uncore/apu-testharness-bus.md`. Remote 10/19. FPGA `NrSlaves` unchanged. |
| APU OpenSBI domain / testharness map | **partial: opt-in DTS + 14-rule last-match + DRAM-lo CVA6 fetch + UART/CLINT/PLIC stub stores; not a real OpenSBI ELF** | overlay `g6lc-apu-domain.dtsi`; opt-in `ariane-g6lc-apu.dts`; testharness `+define+G6LC_APU` addr_map; `tb_g6lc_apu_th_osbi.sv`; `tb_g6lc_apu_cva6_osbi_boot.sv`; `tb_g6lc_apu_cva6_osbi_uart.sv`; `tb_g6lc_apu_cva6_osbi_clint.sv`; `tb_g6lc_apu_cva6_osbi_plic.sv` | `+define+G6LC_APU`; not SMT2 | `architecture/uncore/apu-firmware-domain.md`. Remote th_osbi 27/4; osbi-boot 13/286; osbi-uart 12/288 byte `0x41`; osbi-clint 12/288 word `0x1`; osbi-plic 12/290 word `0x1`; host `osbi_check`. Default DTBs unchanged. |
| APU AXI4 source retention | **partial: captured metadata; actual trusted routing still open** | `corev_apu/apu/g6lc_apu_th.sv`: separate AW/AR hart snapshots at accepted AXI4 address, held through AXI-Lite conversion | `ApuCfg.Enable`; two HartIdWidth banks, off path inert | `architecture/uncore/apu-testharness-bus.md`; directed 12 cases / 60 checks / 221 clocks. Main testharness constant tags are not authentication; epoch-through-adapter and RAM access grants remain open. |
| APU native execution / mailbox | **partial: local arithmetic/control prototype; not general shader or framebuffer** | `g6lc_apu_exec.sv`, `g6lc_apu_exec_bind.sv`, `g6lc_apu_fw.sv`; Fetch rejects shader privilege, undefined opcodes and high register bits before effects; FPnew plus four invocation contexts | `Enable && ExecEn`, `ApuHarness.ExecEn=0`; actual R=8 and 16-word IMEM; arrays are not tc_sram | `architecture/uncore/apu-native-exec.md`, `apu-fw-exec.md`; review 29 cases / 61 checks / 2,646 clocks. Config truthfulness, program bounds, SRAM/DFT, cancellation, vec4/flow/sampler and combined Mem+Exec remain open. |
| APU service boot / BIOS health adapter | **designed, not implemented: independent service with optional BIOS provisioning** | Design in `architecture/uncore/apu-firmware-domain.md` / `apu-resident-fw.md`; existing `software/apu-fw` images are diagnostics and target TGSI uses frozen MOV, not semantic compiler parity | Default-off; production service intended S-mode; current overlay next-mode=3 is M-mode bring-up | Platform or BIOS supervisor adapter loads the same versioned artifact; Linux stays unchanged. No BIOS runtime dependency, APU journal namespace or shared ownership inferred; service health is separate from Linux attempt and BIOS candidate health. |
| APU CVA6 fetch of firmware RAM | **partial: cluster PerCoreBoot through compositor DRAM hole + cookies; not a real OpenSBI ELF** | `tb_g6lc_apu_cva6_fetch.sv`, dual/cluster/th_fetch, `tb_g6lc_apu_cva6_cookie.sv`, `tb_g6lc_apu_cva6_th_cookie.sv`, `tb_g6lc_apu_cva6_tgsi.sv`, `tb_g6lc_apu_cva6_osbi_boot.sv` + `g6lc_cluster` + `g6lc_apu_th_load` `gen_exec` | `TARGET_CFG=g6lc64_stream8`; directed `ExecEn=1` | `architecture/uncore/apu-cva6-fetch.md`. Remote 5/279 one-core; 4/279 dual; 4/283 cluster; 14/283 compositor xbar; cookie 14/1,835 sidecar and compositor; pre-encoded TGSI 14/2,081; resident compile 14/10,511 cookie `0x600D000B`; DRAM-lo OpenSBI load-addr fetch `run-cva6-osbi-boot.sh` 13/286. |
| APU native exec | **partial: LDC + ST + DPEEK + scanline-fill microprogram; not TEX/triangle** | `g6lc_apu_exec.sv` `BR`/`CMPLT`/`ST`; `APU_MEM_EXEC_DPEEK` | `ExecEn` default-off | `architecture/uncore/apu-native-exec.md`, `apu-fw-exec.md`. Remote th_exec 64/513/3,071; DMEM[0..3]=`1.0f`. Screening synth 155,978 / 40,114. |
| APU TGSI subset compiler | **partial: IMM[n]/{0,0.5,1,2}; TEX still rejected** | `software/apu-fw/src/g6lc_apu_tgsi.c`; host `tgsi_check`; CVA6 `apu_tgsi_cc.elf` links compiler+job; not linked into `apu_fw.elf` | host gcc; `run-exec.sh`; `run-cva6-tgsi.sh`; `run-cva6-tgsi-cc.sh` | `architecture/uncore/apu-tgsi.md`. PASS tgsi_check / tgsi_fw_check; mini-hart pre-encoded MOV; CVA6 resident compile 14/10,511 cookie `0x600D000B`. |
| HDMI scanout / simple-framebuffer (not ISA-visible) | **partial: default-off scanner through the 10× shift, plus an opt-in simple-framebuffer byte model; no booted guest, board PHY, or 3D surface** | `corev_apu/hdmi/g6lc_hdmi_{scanout,linebuf,tmds,ser}.sv`, `g6lc-simplefb.dtsi`. 640×480 `r5g6b5` at `0x8ef00000` / `0x96000`. Bit 0 first. | `HdmiEn` default 0, independent of `ApuOff`, `ExecEn`, and `MatrixEn`. The node is not included by a board DTS. Disabled elaboration holds the scanout pins at zero. | `architecture/uncore/hdmi-display.md`. Remote `run-hdmi-scanout.sh` rc=0: scanout 8/307200, line buffer 4/307200, TMDS 6/307200, shift 4/307200 words 384044, simplefb 16/307200. `HdmiEn=1` scanout 328/42, line buffer 67133/32846, TMDS 1597/324, shift 60/30 flip-flops, no latches. |
| V/A-Turbo bounded recipe selection + exact resident-B consumer (not ISA-visible) | **partial: corrected selection arithmetic; one exact execution consumer (recipe 16) verified in harness; production runtime requests tied off** | `include/g6lc_ai_policy_pkg.sv`: `va_turbo_select`, request/plan types; 32-ID namespace, byte-capacity grouping, integer-zero/reuse predicates and guarded precision-conversion plans. Unsupported IDs and unauthorised plans fall back to native execution. | Existing `AiCfg.VaTurboEn`; runtime level, provisioned capacities, compiled-consumer/approved-profile masks and fresh-window input. No production call site or new descriptor/MMIO/DTS encoding. | `architecture/ai-matrix/va-turbo.md` §8-§9: all 32 IDs carry specified arithmetic with a declared bound kind (EXACT/REL/FULL/NONE) and derived ppm error bounds; bound = eps*kappa with kappa a required input. 3,685 generic combinational cells, no state/latches. Two FULL constants were found understated (unsound) and corrected; the FULL bound is now flatness-parameterised (measured fa+fb=0.920 tightens it 2.17x) and an explicit auditable worst_case_waived path records empirical rather than proven admission. Measured validation holds 12/12 with 3.3x-16.8x slack, but a per-element kappa makes any bound vacuous and the level ladder is now geometric so every declared eps is expressible. Arithmetic corrections: RNE ceilings fixed (E4M3 128907, not 128906), separate toward-zero truncation bound for recipes 21/25/30/31, recipe 26 analytically unavailable, `20'hfffff` invalid/overflow sentinel that a waiver cannot override, upward-rounded `(eps*kappa+255)>>8`, and a new `relative_domain_valid` prerequisite for REL. First exact execution consumers: `g6lc_ai_gemm_seq.ReuseBEn` resident-B tile reuse keyed on ptr_b/n/k/ldb/numfmt/epoch, and its mirror `ReuseAEn` keyed on ptr_a/m/k/lda/numfmt/epoch as an INDEPENDENT second key of the same recipe 16, each published only after successful completion, refused on error, invalidation, wrapped range or operand/C overlap, observable via `pmu_reuse_b_hit_o` / `pmu_reuse_a_hit_o`. Both resident drives operand read beats to zero (only C writes remain) for 1.359x INT8 and 1.279x FP32 on ONE engine at +2.44% cells / +22 FF, zero latches: 14.7x return per %area versus 0.8x for 8->16 lanes. Measured eng={1,2,4}: reuse 1.15x -> 1.26x -> 1.36x (INT8) because it removes the contended beats, concurrency 2.08x -> 2.45x with reuse at four engines, combined 2.82x-3.30x; existing `ai-island-dma` (170 cycles) and the GEMM backend nch={1,2,4,8} dpf={0,1} remain PASS after the bank-sizing change. Also fixes a real byte-bank alias: operand banks now size by `ceil(MaxElementBytes*MaxDim/PeLanes)` (island picks 1 integer-only, 4 with `IslandFpEn`) with a runtime width reject, so FP16/FP32 rows no longer overlap. Isolated GEMM synthesis 7,526 -> 7,631 generic cells and 62 -> 74 sequential with reuse on, zero latches both ways; the full `--ai` core synth gate fails in untouched `alu.sv`/`issue_stage.sv`/`commit_stage.sv`. No approximate arithmetic consumer, no runtime ABI, no STA/mapped area, no model-quality claim. |
| AI per-group topology subcode (not ISA-visible) | **partial: implemented advisory selector and gated exact-result cache; no live PE consumer** | `corev_apu/ai_island/g6lc_ai_policy_subcode.sv`, `g6lc_ai_policy_steer.sv`; separate 3-bit index over eight bounded candidates per bulk/decode/routed/sparse group, native-row/K-tail cost, format issue/reduction parameters, 32-cycle staged evaluation and strict net-saving margin. New accepted metadata cancels the shadow search; primary outputs remain identical. | The AR-cap consumer was removed after measurement: `gemm_ar_max` is unconditionally `IslandCfg.MaxAROut`, since `prefetch_depth` could only lower a bound and measured throughput rises monotonically with AR depth. `policy_dot_lanes_log2`/`policy_lane_groups_log2` encode the measured format-to-lane-grouping decision (8/16/32/64 lanes for INT4 / INT8+FP8 / FP16+BF16 / FP32) and have no consumer yet. The `g6lc_ai_gemm_seq` operand loop now carries a constant `PeLanes` bound so the datapath elaborates under an open synthesis frontend. `AiCfg.PolicySubcodeEn` requires benefit steering; `AiCfg.PolicySubcodeCacheEn` requires subcode selection; both production off. Exact completed-result cache reuses existing retained registers (32-cycle miss / one-cycle hit), flushes at batch/format epochs and exposes a hit observation port; no policy mux changes. Group shapes, minimum savings, switching tax and per-format service parameters | `architecture/ai-matrix/README.md` §11.6; standalone observation ports only, no new MMIO/descriptor/DTS/format grants. Synthetic named fixtures show no improvement over the existing allocator; do not promote to traversal. |
| AI workload policy codec (not ISA-visible) | **partial: standalone control/steering + first safe traversal consumer (prefetch depth -> GEMM AR max)** | `corev_apu/ai_island/g6lc_ai_policy_codec.sv`, `g6lc_ai_policy_steer.sv`, `include/g6lc_ai_policy_pkg.sv`; frozen 3-bit encoder, work-count hysteresis, native-format metadata, balanced same-budget topology, full 16-bit `m/n/k` retention, `(m+n)*rowbytes(active_k) >= read_bytes` benefit guard and hint-only warm path. Now instantiated in `g6lc_ai_island_top`, fed from descriptor/GEMM job metadata (m/n/k/numfmt) with `gemm_err` flush and format-known gating, and exposes sticky policy code/word/topology/event PMU words at `0x0190..0x019C` | `AiCfg.PolicyCodecEn`, `AiCfg.PolicyBenefitEn` (production off; codec requires MatrixEn + T2 queue, benefit requires codec) | `architecture/ai-matrix/README.md` §10–§11; first safe traversal consumer is the GEMM `ar_max_i` prefetch-depth cap (gated by `AiCfg.PolicyCodecEn`, disabled by default, dense numerical path unchanged); live DMA smoke `verif/regress/ai-island-dma.sh` exercises the PMU at runtime with a v2 GEMM descriptor and non-zero sticky words at `0x0190..0x019C`; tile/bank/tail consumer and dense-fallback proof precede any traversal change; I3 before I2 unchanged |
| AI scalar floating / dot arithmetic (not ISA F/D) | **implemented (config): standalone scalar + pipelined FP8/FP16/BF16/FP32 dot-product PE integrated into the GEMM backend** | `corev_apu/ai_island/g6lc_ai_fp_mac.sv`, `g6lc_ai_pe_dot_float.sv`, `g6lc_ai_pe_dot_float_pipe.sv`, `g6lc_ai_gemm_seq.sv`, `include/g6lc_ai_fp_pkg.sv`; scalar: exact FP8 E4M3/E5M2, FP16/BF16 widening, serial FP32 RNE multiply then add via `core/cvfpu/src/fpnew_fma.sv`, flags, backpressure and reset/flush/disable cancellation; Dot (combinational `g6lc_ai_pe_dot_float` and pipelined `g6lc_ai_pe_dot_float_pipe`): FP8/FP16/BF16/FP32 decode/product, block-floating 640-bit reduction tree with RNE FP32 conversion, NaN/Inf/zero/subnormal/signed-zero propagation; GEMM selects the pipelined dot product via `DotPipeFloat`, registers stage-2 product and block-exp/flag metadata and feeds a stage-3 block-exp/flag register into the reduction-tree metadata pipeline so consecutive starts with different `numfmt`/data stay aligned; tracks outstanding dot transactions (`dot_pending_q`) to prevent C-flush from overtaking in-flight results, and drains the final result before leaving `ST_MAC` | `AiCfg.IslandFpEn` (production off; requires MatrixEn + queues), `FpPipeRegs`, `DotPipeFloat` test/parameter; dot product integrated into `g6lc_ai_gemm_seq` | `architecture/ai-matrix/numeric-formats-datapath.md`; live island grant/PE masks still `16'h0003` (INT8/INT4) by default; `ai-fp-mac.py` (FpPipeRegs 1/2/3/5, ~40k scalar transactions) PASS, `run-pe-dot-float.sh` Lanes=4 PASS, `run-pe-dot-float-pipe.sh` Lanes=4/8 PASS with 1-ULP tolerance for finite BFP-vs-float rounding, GEMM backend nch={1,2,4,8} `dpf=0,1` across FP8/FP16/BF16/FP32/INT4/INT8 PASS; Yosys `synth -noabc -top g6lc_ai_pe_dot_float -flatten` and `synth -noabc -top g6lc_ai_pe_dot_float_pipe -flatten` both report zero errors/warnings; mantissa product narrowed to explicit 24×24, reducing pipelined dot-pipe generic cells from ~128k to ~115k (Lanes=4); not an ISA F/D extension |
| AI descriptor-v2 native-mode legality and handoff | **implemented; directed helper + actual engine verification** | `corev_apu/ai_island/include/g6lc_ai_desc_pkg.sv`: `desc_compute_mode_legal`, `desc_compute_numfmt`, `desc_numfmt_granted`; `g6lc_ai_desc_engine.sv`: reject in `ST_PARSE` before operand fetch, hand effective format to `gemm_numfmt_o`; legacy INT + EW=1 resolves to INT4 for both grant and execution | `AiIslandDtypeMask` and `AiIslandPeImplMask` = 3 live; unsupported dtype/accmode/EW/SP24 combinations fail closed | `architecture/ai-matrix/numeric-formats-datapath.md`; small combinational parse guard, no added state/clock/reset/DTS/capability; fused requantization and non-GEMM operations remain separate unsupported work |
| Branch prediction (BHT/PH_BHT/BTB/RAS + U1 fabric) | **implemented (config); response-PC/corrector repair retained 2026-09-16; per-slot context ownership 2026-09-17** | `core/fetch_B/frontend.sv`: asynchronous selector paths follow the realigned response, FPGA selectors unchanged; PH_BHT's separate registered port is not changed. `core/frontend/g6lc_bp_statcor.sv`: absolute-trained 3-bit counters select absolute directions at strong bias, not inversion. `g6lc_bp_tage.sv`/`g6lc_bp_ittage.sv`: per-slot PC lookups (base row/column + tagged index/tag per slot, no per-window broadcast) and `folded_update_i` training fold of the resolving branch's prediction-time GHR snapshot (`g6lc_bp_ghist.folded_src_o` over `fold_src_i` = checkpoint head, or the live train-hart bank when no checkpoint is valid); `g6lc_bp_tage_table.sv` lookup ports are `NR_LOOKUPS` arrays. `g6lc_bp_ckpt.sv`: prediction-time per-CF-slot push FIFO (`push_cf_i`/`cf_resolve_i`/`push_hart_i`/`pop_hart_i`), restore consumes the head and drops younger wrong-path entries, `desync_o` gates restore on overflow. Existing `bht*`, `btb`, `ras`, `g6lc_bp_*` and `branch_unit.sv` retain resolution contracts | Existing `BPType`, `BPStatCorEn`, `BP*`, `FpgaEn`, `RASDepth`; no new ISA/DTS/config field | Independent leaf/negative tests, symbolic selector proof, SMT2 references and stream8 controls pass. Corrector leaf 1,261→1,360 generic cells; 192 state bits unchanged. Context ownership: `review-tage-ctx-v2` 10/10 (per-slot provider, update-fold, unaligned base+ITTAGE, banked-GHR fold) with live negatives; decay 6/6. Checkpoints: `review-ckpt-v2` 8/8; integration `review-int-ckpt-v3` 24/24 (smt2 cycle-identical; stream8 timing-legible deltas classified). Full-core synthesis smoke passes; physical and full-ISA qualification remain open. See `agents/guides/AGENTS-branch-prediction.md` |
| Decoupled front-end (U2) | **implemented (config)** | `cva6_ftq.sv`, `cva6_fdip.sv`, `cva6_loop_buffer.sv`, `frontend.sv` | `FtqDepth`, `FdipEn`, `LoopBufEn` | `architecture/speculative-execution/` |
| Speculative execution (in-order, precise) | implemented | `scoreboard.sv`, `issue_read_operands.sv`, `ex_stage.sv`, `commit_stage.sv`, `controller.sv` | `NrScoreboardEntries`, `NrLoadBufEntries`, `MaxOutstandingStores` | `agents/guides/AGENTS-speculation.md` |
| Multi-issue width (superscalar precursor) | **implemented (config)** | `build_config_pkg` (NrIssuePorts 1\|2–8), `id_stage` (G1be same-line dest-before-Branch; G1cy leftover-Jump before later-slot fallthrough; G1em older CSR-to-a0 before a0-Branch; G1ev older ALU-to-a0 before a0-Branch; G1id mid-line 01 Branch on same line as aligned compressed Branch is JALR; G1ij mid-line 01 Branch whose 16-bit is not a Branch encoding follows that 16-bit; G1ik ID-visible aligned Branch arms same-line 01 recover; G1il aligned-Branch recover latch survives flush_i; G1io aligned npc + same-line I$ slot0 is I$[15:0]; G1ip leftover slot0 stays slot1 is I$[15:0] at aligned npc; G1iq stash aligned I$[15:0] compressed Branch present at aligned npc; G1ir G1ie arms from G1iq stash; G1it G1iq capture [15:0] Branch when I$ vaddr is mid-line 01; G1iu G1iq capture [15:0] Branch when npc is mid-line 01 on same I$ line; G1iw same-cycle sibling-half [15:0] Branch recovers mid-line 01; G1ix bp_valid must not kill_s2 while npc is mid-line 01), `frontend.sv` (G1ct dest-only mispredict beat; G1cz leftover-Jump slot0-only; G1ep consumed mid-line sequential-next I$ hold; G1fu fetch pc+2 after slot0-only compressed Branch consume; G1fv npc +2 when aligned compressed Branch presented slot0-only; G1fw npc +2 when IQ view is slot0-only compressed Branch; G1fy npc +2 when IQ view is slot0-only rvc_branch; G1ga npc +2 when IQ slot0 Branch and slot1 JumpR; G1gb npc +2 when frontend slot0 Branch and slot1 JumpR; G1gc npc +2 frontend Branch|JumpR even when leftover; G1gd npc +2 frontend Branch|JumpR even when bp_valid; G1ge after JumpR commit accept target I$ even if leftover jal unconsumed; G1gg jalr prefer usable RF over unusable forward; G1gp jalr resolve uses usable RF when operand_a is unusable; G1gq committed JALR redirects to RF[rs1] after unusable JumpR resolve; G1gs JALR resolve is JumpR even if RAS tagged Return; G1gu recover high-half c.jalr only when low is RVI BRANCH; G1gw mid-line exact c.jalr encoding forces JALR; G1gx mid-line slot0 is the 16-bit at that PC not leftover-complete; G1gy mid-line either-half exact c.jalr forces JALR; G1ha I$ +2 halfword only when exact c.jalr; G1hb slot1 from I$ +2 exact c.jalr even if valid; G1hc leftover-complete beat still presents I$ +2 c.jalr as slot1; G1hd issued op is JALR when mid-line fetch has exact c.jalr; G1hf mid-line !Branch usable-RF is JumpR; G1hg mid-line Branch orig 16-bit exact c.jalr is JumpR; G1hh any mid-line 01 slot from I$ +2 exact c.jalr; G1hi mid-line 01 from live I$ +2 exact c.jalr without same-line; G1hj stash aligned I$ +2 exact c.jalr fill mid-line 01; G1hk present slot0 at npc from stash when npc mid-line 01; G1jk G1hj/G1hk/G1hl present only at the captured +2 PC; G1jl sibling pair Branch+[31:16] c.jalr into PC-matched G1hj; G1jm keep registered aligned compressed-Branch I$ until +2 presented; G1jn spare kill_s2 when returning I$ is npc-00 same-line compressed Branch; G1jo replay must not kill_s1 while npc is aligned 00; G1jq leftover Jump must not flush/mispredict-kill s1 while npc is aligned 00; G1jt is_mispredict must not kill_s1 while npc is aligned 00; G1ju G1hj +2 c.jalr stash survives leftover Jump flush_i; G1jv G1hj capture beats flush_i clear; G1jx IDLE sibling-pair capture only when npc is the sibling +2 PC; G1jy latch IDLE aligned-00 sibling pair present only at npc +2 01; G1jz IDLE sibling latch +2 PC from last I$ return vaddr; G1ka present live user[33] pair at npc == last-return +2; G1kb slot0-only aligned compressed keeps +2 c.jalr even if slot0 is not Branch; G1kc leftover slot1 present of G1jy stash at npc-matched +2; G1kd G1jy capture without last-return +2 PC from current I$ sibling; G1ke same-line IDLE pair into G1jy; G1kf registered I$ same-line pair into G1jy; G1kg same-line pair on kill_s2 into G1jy; G1kh kill_s2 sibling user[33] pair into G1jy; G1kj npc-matched sibling pair into G1jy with full +2 PC; G1kk aligned-00 RVI LOAD rd recovers sibling 01 Branch as c.jalr; G1kl present G1kk c.jalr at npc 01 of the LOAD's sibling 8-byte half; G1km leftover slot1 present of G1kk c.jalr at npc sibling 01; G1kn aligned-00 RVI LOAD from I$ data into G1kk; G1ko G1kk survives leftover Jump flush_i; G1kp G1kk capture beats flush_i; G1kq G1kk survives leftover Jump is_mispredict; G1kr G1kk survives is_mispredict at npc 00; G1ks G1kk consume only at sibling 01; G1kt G1kk keep-until-sibling-01; G1ku G1kk I$ capture only when npc is on the same 16-byte line; G1kv present-path G1kk capture only when npc is on the same 16-byte line; G1kw G1kk from registered I$ aligned-00 RVI LOAD when npc is on the same 16-byte line; G1kx npc-line LOAD recapture may replace a held different-line LOAD; G1ky leftover slot1 G1kk present from same-cycle I$ LOAD cap at npc sibling 01; G1kz G1kl slot0 present from same-cycle I$ LOAD cap at npc sibling 01; G1la G1kl does not skip leftover 11 when G1kk sibling 01 matches; G1lb I$ aligned-00 RVI LOAD may replace G1kk even when npc is off that line; G1lc I$ LOAD recapture only when G1kk is empty; G1ld restore G1ku npc-line on g1kn; G1le last I$ aligned-00 RVI LOAD side-stash present at sibling 01; G1lf g1le keep-until-sibling-01; G1lg npc-line recapture may replace a held different-line g1le; G1lh present-path aligned-00 RVI LOAD into g1le; G1li registered I$ aligned-00 RVI LOAD into g1le; G1lj leftover slot1 g1le present from same-cycle I$/registered LOAD cap; G1lk G1kl from no-npc-line g1lj_cap reverted (cookie t=206848); G1ll G1kl from same-cycle g1le I$/registered LOAD cap with npc-line; G1lm IQ aligned-00 RVI LOAD sibling 01 recover reverted (FDT 106); G1ln ID-visible aligned-00 RVI LOAD arms sibling 01 Branch recover; G1lo ID latch of aligned-00 RVI LOAD survives flush_i; G1lp g1lo keep-until sibling 01; G1lq IQ-visible aligned-00 RVI LOAD into g1lo_cap; G1lr g1lq keep-until sibling 01; G1ls present-path instruction_valid 00 LOAD into g1lq_cap; G1lt live I$ aligned-00 RVI LOAD into g1lq_cap; G1lu registered I$ aligned-00 RVI LOAD into g1lq_cap; G1lv leftover slot1 g1lq present at npc sibling 01; G1lw G1kl slot0 from g1lq_hit; G1lx g1lq overwrite of g1lo_cap gated to empty or fetch 01 line; G1ly same-line g1lq overwrite of held g1lo; G1lz per-hart g1lo LOAD latch (peer 00 LOAD must not occupy hart0); G1ma per-hart g1lq IQ LOAD latch + sideband; G1mb per-hart g1le I$ LOAD side-stash; G1mc per-hart G1kk LOAD recover latch; G1md commit-visible aligned-00 RVI LOAD into g1lo; G1me g1lo commit capture beats flush_i; G1mf SB result-valid aligned-00 RVI LOAD into g1lo; G1hl leftover-complete slot1 from stash at npc mid-line 01; G1hm leftover-complete slot1 at stashed +2 PC; G1hn capture I$ [31:16] exact c.jalr even if vaddr not aligned; G1ho capture [15:0] exact c.jalr when vaddr mid-line 01; G1hp capture exact c.jalr from g1gx_data either half; G1hq capture incoming I$ +2 exact c.jalr even if fill is not registered; G1hr capture incoming I$ +2 exact c.jalr on kill_s2 even if valid is muted; G1hs leftover-complete Jump must not replay-kill I$ s1; G1ht replay must not kill_s1 while npc is mid-line 01; G1hv leftover Jump must not flush_i-kill s1 while npc is mid-line 01; G1hw leftover Jump must not is_mispredict-kill s1 while npc is mid-line 01; G1hx same-line +2 duplicate compressed Branch is JALR; G1hy aligned packet high-half c.jalr recovers mid-line 01 Branch; G1hz slot0-only aligned Branch keeps +2 c.jalr in instruction[31:16]; G1ia compressed +2 slot is the 16-bit at that PC not {+4,+2} mash; G1ib slot0-only must not hide a live +2 exact c.jalr; G1ic leftover-PC I$ must not present while npc is mid-line 01; G1ie frontend latch of aligned compressed Branch recovers same-line 01 Branch as c.jalr; G1ir G1ie arms from G1iq stash; G1it G1iq capture [15:0] Branch when I$ vaddr is mid-line 01; G1iu G1iq capture [15:0] Branch when npc is mid-line 01 on same I$ line; G1iw same-cycle sibling-half [15:0] Branch recovers mid-line 01; G1ji G1ie arms from G1iw sibling-half compressed Branch keep-until-01; G1ix bp_valid must not kill_s2 while npc is mid-line 01; G1jb aligned-Branch recover stash/latch not replaced by a different 8-byte line until that line's mid-line 01 is presented; G1jc first leftover-RVI I$ steal at npc 01 still issues npc 8-byte line once; G1jg first sequential-next 8-byte I$ at npc 01 still issues npc 8-byte line once; G1ih IQ output recovers same-line 01 Branch as c.jalr; G1ii IQ input latches aligned Branch for later +2 recover; G1gh leftover jal x0 waits for same-hart jalr commit; G1gi do not present leftover jal x0 while jalr in flight; G1gj do not present leftover jal x0 while npc is mid-line 01; G1gk hold leftover jal x0 hide 3 cycles after mid-line 01; G1gl do not reseed npc to leftover-PC replay after mid-line 01; G1gm do not reseed npc to leftover-PC replay while jalr has been seen; G1eq aligned I|I CSR not hidden; G1fr dest-only beat keeps later-slot JumpR; G1ft leftover-Jump slot0-only keeps later-slot JumpR; G1et fill missing aligned I|I CSR from I$; G1fq fill missing aligned compressed slot1 c.jalr from I$; G1ex dest-FIFO CSR-to-a0 different-line I$ hold; G1ez leftover-complete NoCF dest I$ hold; G1fa reject I$ ahead of npc), `instr_queue` (G1da leftover-Jump `idx_is` first push; G1dc leftover-Jump IQ head; G1em older CSR-to-a0 over rotate head; G1en leftover jal x0 vs queued CSR-to-a0; G1er aligned I|I CSR through branch_mask; G1fs Branch\|JumpR through branch_mask; G1ey dest-FIFO a0-Branch vs queued CSR-to-a0; G1fd mid-line consume wait before later a0-Branch; G1fe aligned I|I CSR-to-a0 data hides dest-FIFO a0-Branch; G1ff registered I$ I|I CSR-to-a0 hides later dest-FIFO a0-Branch; G1fi mid-line presentation wait before later a0-Branch; G1fj hold mid-line wait through sequential next; G1fl hide later a0-Branch until next line consumed; G1fo leftover jal x0 waits for dest-FIFO JumpR; G1fp leftover jal x0 waits for presented JumpR), `issue_read_operands`, `ex_stage`, `scoreboard` free-slot full, `g6lc_issue_barrier` (G1bh prefix through unresolved Branch; G1em a0-Branch vs ID CSR-to-a0; G1fh a0-Branch until seen CSR-to-a0 commits) | `SuperscalarEn`, `NrIssuePorts` | `architecture/out-of-order/` |
| Slice-OoO (U4) | **implemented (off by default)** | `cva6_slice_{ist,steer,iq,rmt,dispatch}.sv`, `issue_stage.sv` | `SliceOoOEn`, `Slice*` | `architecture/out-of-order/` |
| Full OoO (U5) | **partial (gated; integration blocked)** | `core/ooo/*`; IQ now uses WB-qualified readiness, catches dispatch/WB coincidence and accepts exactly fitting groups. Live dispatch store self-block remains reproduced; rename/LSQ/recovery/hart/FP/wide-retirement contracts are open. `cv64a6_ooo` / `cv64a6_ooo_server` | `OoOEn`, `NrIssuePorts≤8` | `architecture/out-of-order/` |
| L1 caches (I$ + D$: WT / HPDCACHE / std) | implemented | `core/cache_subsystem/*`; selection `core/cva6.sv`; **SL-W:** `wt_dcache_wbuffer.sv` (post-ACK fixup queue, `WtDcacheFixupDepth`, `VoidKeepEn`/`VoidKeepTag` containment, `fixup_wbuffer_o` to cache memory), `wt_dcache.sv` (inv_req port + PMU pass-through), `wt_dcache_mem.sv` (explicit way invalidation + fixup-queue forwarding + **fixed `wbuffer_rdata`/`wbuffer_ruser`/`wbuffer_be` to use `wbuffer_all[wbuffer_hit_idx]` instead of `wbuffer_data_i[wbuffer_hit_idx]` so fixup entries forward correctly), `wt_dcache_missunit.sv` (`load_tx_collision` + `store_pending` masking/replay for in-flight store-TX vs load misses), `perf_counters.sv` (group 5 events); remote `g6lc64_smt2` B-flavour build warning/error-free. DI suite: `mini_fdt_next_tag_lbu` now **PASS** (was the L1-stale store-to-load signature); `mini_fdt_lenp_sw`, `mini_csr_pmp_probe`, `mini_amoadd_w_spin`, `mini_csr_expected_trap`, `mini_dual_cmv_s3` also pass. `mini_stq_flush_fwd` still **FAIL** (exit-code). A per-word `wbuffer_collision` mask in the miss unit was tried and reverted: it stalls `mini_fdt_next_tag_lbu` and other FDT paths, so the remaining SL-W residual is either in `wt_dcache_mem` hit-mux ordering or in the `cva6_fifo_v3` / issue path, not the in-flight TX path. **`g6lc_icache.sv` active-region convergence fix**: use registered `vaddr_q` for tag/index/MMU request/response address, remove same-cycle `dreq_o.ready` in `READ` hit, and gate hit/refill output with `kill_s1` to break the frontend→I$→branch-predictor combinational loop (Verilator build warning-free, DI 16/16 PASS on `work-ver-smt2-fw64-B`) | `DCacheType`, `Icache*`, `Dcache*`, `WayPredEn`, `ReplPolicy`, `WtDcacheFixupDepth` | `agents/guides/AGENTS-l2l3-cache.md`, `architecture/dcache-ack-before-check.md` |
| L2 cache (U6.0) | **RTL present/config-gated; serialized top; not release-qualified** | `corev_apu/l2_cache/*`, `corev_apu/src/g6lc_cluster.sv`; default-off RR uses one-cycle `tc_sram` metadata, invalid-first and successful-install advancement | `L2En`, `L2ByteSize`, `L2SetAssoc`, `L2LineWidth`, `L2MshrDepth`, `L2DataBanks`, `L2RoundRobinEn` (all production defaults off; requires enabled L2 and power-of-two ways ≥2) | `architecture/l2-l3-cache/`: paired local/remote leaf diagnostics and generic synthesis pass in bounded fixtures; protected-hot workload regresses. Bypass R-hold defect repaired independently: preserve slave ready in S_BYPASS_R and clear outstanding only on final R handshake; no new state/stage, existing fill-drain guard retained. Synthetic ATOP forwarding remains; `+amo-arith` now computes ADD/SWAP/CAS.W and LR/SC at the leaf memory model (not cluster `g6lc_axi_lrsc`). Independent policy checks pass remotely; small 256 B/two-way and 512 B/four-way RR-off **mapped** equivalence fixtures pass against a pinned bypass-corrected legacy engine, with a failing hit-output mutation. Larger geometries use `memory_collect` (4 KiB/16 KiB ladder; 256 KiB opt-in). Isolated overlays may flip only `L2RoundRobinEn`. MSHR sizing has a measured depth-two area candidate: equal leaf cycles/transaction traces versus 16/8/4, 874 fewer sequential cells versus 16, and a one-live invariant proved in a 512 B fixture. Subsequent 256 KiB/8-way/4-bank and matched-package checks preserve cycles/transactions and the SMT2 integer reference gate; `g6lc64_smt2` and `g6lc64_stream8` now explicitly select L2MshrDepth=2. Generic inference/other packages stay unchanged; this is scoped area promotion, not physical or coherence release qualification. MSHR concurrency, production-geometry mapped equivalence, broader formal, bound isolated Mdir core runs and physical qualification remain open. No DTS/ISA geometry change. |
| L3 / multi-core snoop (U6.2) | partial; invalidation leaf admission/departure repair verified, full coherence open | `corev_apu/coherence/g6lc_{coherence_pkg,snoop_filter,inval_bus,coherence_hub}.sv`; `g6lc_inval_bus` shares per-target merge eligibility between global admission and update, excluding a sole entry consumed this cycle | Existing `NrCores`, `CohPolicy`, `CohInvalDepth`, `SnoopFilter*`; no new field/port/state | `architecture/multi-core/`: original mixed-target and coalesce/pop failures reproduced, five leaf geometries + negatives pass, N3/D2 eight-step local formal/covers pass. N1 identity unchanged; no full SMT2/MC/physical or platform-verify closure. Held AR/AW owner/slot reservation and phantom-read credit are subsequently repaired (N2 OT1/4 directed + eight-step checks); new hold metadata is conditional on N>1. N2/OT4 generic cells 2760→2808, state cells 326→342; no physical claim. Inclusive ready is subsequently masked by actual mux selection (N1/N3/N4 controls and combinational formal); eviction-producer retention and hub write visibility remain open. |
| Multi-threading SMT (U6.1) | implemented (config; OpenSBI R3a) | `core/smt/*` (`g6lc_lj_hide` leftover jal-x0 squash + G1gi–gm hide/replay; `g6lc_leftover` leftover-RVI classify; `g6lc_present` E9 mid-line 16-bit + hc/hh npc 01 + hm Jump-only (lo11_npc00 MINI-FAIL; lo_pc_npc00 HOLD-FAIL; lo_ld_stay HOLD-FAIL; hi8_lo11 MINI-FAIL G1jd; ljx0_off/ljx0_pc/ljx0_bp/lo_ld_lo11/leftover_off_npc00/leftover_nx8_npc00 hygiene; leftover_slot0_off_npc00 MINI-FAIL); `g6lc_lj_hide` leftover jal x0 PC latch; `g6lc_fe_kill` sib_lo_s2 MINI-FAIL G1jp; leftover_hi8_s2 MINI-FAIL G1hu; leftover_lo8_s2 hygiene; load00_lo8_s2 hygiene; `g6lc_sib_cjalr` load_flush_next16 hygiene; `g6lc_fe_keep` ld_until_01 MINI-FAIL G1lm; load00_vs_off16 hygiene; load00_vs_lj hygiene; `g6lc_sib_cjalr` E4 sibling-01 leftover_blocks_01; `g6lc_iq_hide` E8 IQ hide; `g6lc_fe_kill` E7 I$ kill spares; FSM/mux in `instr_realign.sv` / `frontend.sv` / `id_stage.sv` / `instr_queue.sv` — `core/fetch_B/instr_queue.sv` now honors `g6lc_fetch_pkg::fetch_en_t.order` by selecting oldest-PC FIFO heads for the two issue ports, closing the out-of-program-order issue that let younger control flow bypass older producers in the B fetch queue); `core/cache_subsystem/g6lc_icache.sv` active-region convergence: registered `vaddr_q` for tag/index/MMU/response, no `dreq_o.ready` in READ hit, `kill_s1` gating; **`core/commit_stage.sv` carries no commit value filter and no cancelled-writeback force** — the `G1lc`/`I4as`/`I4cc` FDT-compensation clauses and the `G1s`/`G1an` cancelled CTRL_FLOW/LOAD write-forces were reverted (2026-08-31) as `firmware-boot-principles.md` §E red lines: both decide an architectural write from a data value or resurrect a squashed one, and the config gate did not launder either. The only surviving guard is Zacas port ownership (`casq_hi_pending_q && !instr_0_is_amo`), anchored on `RVZacas` because Zacas is what retargets `waddr_o[0]` (I28). Enforced mechanically by `diag-isa-red-lines`; `verif/regress/remote/testharness_proxy.py` runs DI consecutively with a `_no_overlap_guard` plus an H3 oracle preflight. | `NrHarts`≤2, `SmtPolicy`, … | `architecture/multi-threading/` + `smt-linux-boot-path` + `smt-linux-rootfs` + `software/smt2-linux/` |
| CVXIF coprocessor / accelerator seam | implemented | `core/cvxif_fu.sv`, `core/acc_dispatcher.sv`, ports `core/cva6.sv` | `CvxifEn`, `EnableAccelerator` (mutually exclusive) | `AGENTS.md` §0.1.5 |
| RVFI trace / debug / PMU (observability) | implemented | `cva6_rvfi*.sv`, `trigger_module.sv`, `perf_counters.sv` (8-bit events U8ᵃ) | `DebugEn`, `PerfCounterEn`, `SscofpmfEn` | `AGENTS.md` §0.1.6 |

---

## Maintenance contract

When an RTL change lands:
1. Update the affected row(s) here — status and/or primary loci (keep `file:line` only where stable).
2. If it changes what is exercised, update `AGENTS-specs-to-tests.md`.
3. Re-derive the affected row(s) of `AGENTS-specs-coverage.md`.
4. If a spec sub-file is missing for the touched chapter, add it and flip its `agents/spec/INDEX.md` row.
5. Follow `AGENTS-coding-philosophy.md` (timing note, review checklist) and `AGENTS-licensing.md` for the
   code itself.
