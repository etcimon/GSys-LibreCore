# Guide: Speculative Execution

Feature-addition playbook for speculation, flush/recovery, and memory ordering. Read `../../AGENTS.md`
first. Spec summaries live in `../spec/` (see `../spec/INDEX.md`).

## Table of contents
1. Spec grounding
2. Code map (`file:line`)
3. Config knobs
4. Feature-addition playbook
5. `.dts` linkage
6. Invariants and pitfalls

## 1. Spec grounding
Speculation is microarchitectural but strictly bounded by architecture: `specs/riscv-spec.html#memorymodel`
(3.1 RVWMO — preserved program order, fences, address/data/control dependencies), `#ext:ztso` (3.2),
`#ext:zifencei` (4.1 — instruction-fetch fence), the atomics `#ext:a` (5.1) and `#ext:zalrsc` (5.2 —
LR/SC reservations that misspeculation must not lose), `#ext:zawrs` (5.5 — wait-on-reservation
stalls), acquire/release `#ext:zalasr`, and precise-trap requirements in Privileged chapter 3.
Sub-files: `../spec/riscv-spec-I-3.1-rvwmo.html`, `-I-4.1-zifencei.html`, `-I-5.1-a.html`, `-I-5.5-zawrs.html`.

## 2. Code map
The speculation pipeline is a composition, not one module:
- Predict: `core/fetch_B/frontend.sv` (see `AGENTS-branch-prediction.md`).
- Track in-flight: `core/scoreboard.sv` (the speculative window; operands via `core/issue_read_operands.sv`).
- Execute: `core/ex_stage.sv`; branch resolution `core/branch_unit.sv` -> `resolved_branch_i`.
- Retire in order: `core/commit_stage.sv` (architectural state changes only here).
- Flush/redirect: `core/controller.sv` (`flush_i` sequencing) -> frontend redirect `core/fetch_B/frontend.sv`.
- Memory speculation: `core/load_unit.sv` (speculative loads / hazard checks), `core/store_buffer.sv` (speculative vs committed stores), `core/lsu_bypass.sv`, `core/amo_buffer.sv`.

### Result readiness is not commit readiness

AMO execution writeback prepares the scoreboard entry for commit; its architectural
result arrives through `amo_resp_i` at commit. The architectural forwarding path
must not advertise the earlier placeholder to a dependent branch or ALU operation.
`issue_read_operands.sv` gates both stored and same-cycle WB candidates by AMO class
under RVA, letting the consumer read the committed RF value after retirement.
No reservation/flush policy or ISA/DTS/default changes accompany that repair.
The opcode decode and readiness gate affect the issue cone; physical STA/power is
not qualified. Directed RVC/norvc, RS1/RS2/ALU consumer and negative controls are in
`../../AGENTS-specs-to-tests.md`. This is not general OoO/PRF qualification.

### Completion, usable data and architectural retirement

For OoO, an invalid/cancelled response must not clear rename busy or wake IQ merely
because a transaction completed. PRF writes and bypass must use the same qualification.
Likewise, acknowledging a cancelled scoreboard/ROB slot only drains it: it must not
update the committed map, free an architectural physical register, release a reused
checkpoint or authorize a store. The dispatch fixture now checks both commit lanes
and private restored-defect controls; ROB completion and retirement stay separate.
This adds combinational qualification, not state/clock/reset or software-visible
features. Generic cell evidence and remaining late-result/TID/hart/FP limits live in
`../../architecture/out-of-order/README.md`. Preserve the drained SMT2 boot baseline;
assess fairness only with independently checked, simultaneously runnable workers.

### Cancellation follows every owner, including pre-grant queues

A cancelled instruction's lifetime is not bounded by its scoreboard slot. The slot
can be dropped and reused while a queued request still waits for cache admission.
The post-grant load-buffer tombstone cannot protect that earlier interval.
`lsu_bypass` therefore retains exact cancelled-TID membership with queued loads
under OoOEn, and `load_unit` discards that head without fabricating a completion.
Older accepted tag/abort/response obligations remain owned until completion.
The firmware counterexample and live boundary/mutation tests are recorded in
`../../architecture/out-of-order/README.md`; all-FU and mixed-residency lifetime
claims remain separate.

Implementation issue-window lifetime is also distinct from architectural reservation
lifetime: a younger SC can succeed after its LR has retired. Nor does in-order issue
itself guarantee that an arbitrary LR will eventually be followed by SC or flush.
Retain only scoped progress evidence for the existing LR/SC issue-window repair.

### Simulation observation and complete build identity

Synthesis `translate_off` leaves simulation assertions and observers active. Absence of DUT outputs
from a probe is not a non-interference proof: generated evaluation order can change, and a
repeatable simulator defect can remain deterministic. Compare observer-off/on architectural effects
and verify the full build recipe, not only repository source hashes.

A read-only inspection found the protected passing SMT2 model compiled with the documented external
lzc split-variable compiler control while a failing comparison model omitted it. Both used the same
corrected runtime and firmware. This input was outside the source-map comparison; see the current
out-of-order reassessment for artifact identities. An unmatched recipe cannot attribute the PMP
stop to the frontend or rule out deterministic scheduling. Preserve PMP assertions and qualify the
existing tool recipe rather than weakening protection checks.

### Establish exit-path semantics from code, not diagnostic names

The harness post-run dumps are enabled by CVA6_TRAP_DUMP; they are not hang verdicts.
Its banner prints dtm/jtag/RTL exit status, not the raw tohost memory word. SIGTERM calls
`dtm->stop()` and may reach that banner without workload completion. Require the runner's strict
completion evidence, and retain process-control provenance. Routine proxy preflight must never
kill all matching harnesses: an observational shell query can otherwise terminate a live test.

A matching trace prefix followed by EOF is early termination, not by itself architectural
nondeterminism. Matching binary hashes or file sizes do not establish all runtime inputs. Preserve
individual outcomes without inventing a population flake rate, and do not convert incomplete into
pass by repetition. A same-model trace from another invocation checks replay, not ISA independence.

### Asserting a flush is not the same as proving what arrives after it

An architectural redirect must reach its required instruction, and cancelled pre-redirect work
must not produce architectural effects. Observe accepted request, owner/context, response, kill,
queue acceptance and eventual issue/retirement separately. Address equality and timing proximity
cannot distinguish an old response from a newly accepted same-address request. A replacement
request does not by itself discharge an older response obligation.

The frozen trap-layout pair showed different first post-flush deliveries, but the observed
three/eight-cycle gap is not a universal cache latency bound. The live I$ supports one-cycle warm
responses and response/request overlap. With FTQ enabled, npc_d may legitimately step past the
trap target while that target is queued, so npc_d alone does not expose redirect selection.
A flush wired to FIFOs is useful structural evidence, not a proof of cancellation across the cache,
realigner, replay and downstream owners. Check those contracts with a reference independent of
DUT cancellation state. The current address-based kill candidate has local evidence; same-address
refetch, overlapping kills and peer-context preservation still need qualification.

A failure reproduced with OoO disabled narrows the required conditions, not all possible causes.
The historical traces and scoped conclusions remain in `../../architecture/out-of-order/README.md`.

### Recovery must conserve surviving queued work

For OoO, scoreboard allocation is not FU issue. A redirect can be generated by a
younger ready branch while an older instruction is still waiting in the IQ.
`issue_read_operands` suppresses every outgoing FU-valid on `flush_unissued`; the
OoO dispatch seam must therefore suppress offers and qualify IQ consume by the
actual visible offer in that cycle. Otherwise a raw acknowledge removes older,
non-cancelled work that never executes. Keep its WB wakeup and replay it after the
redirect; cancelled younger entries are still removed by identity. A full flush
clears the structures rather than replaying them. Do not replace this distinction
with FU/register exemptions or a global IQ clear on every misprediction.

This repair adds no state, issue stage, clock/reset or software-visible capability.
Its flush/valid fanout needs structural and physical timing review separately.
Directed, mutation and bounded checks belong at the IQ/IRO promise boundary;
firmware completion alone is not proof of instruction conservation.

### Program order is not arrival order

Two store-buffer contracts survived in-order issue only because arrival order *was*
program order. Under OoO both must be re-established explicitly, keyed on the
circular trans_id distance from the oldest live instruction:

- **Observation.** An address match is not sufficient to forward. A store may only
  be seen by a load that follows it in program order. Entries already accepted for
  commit are the exception: they are architecturally older, and their trans_ids may
  have been recycled, so they must not be age-tested.
- **Visibility.** A queue written at AGU time records issue order. If the commit
  handoff pops that order, same-address stores reach memory reversed. Restore the
  oldest-at-head invariant at insertion rather than special-casing the pop, because
  the forward scan, RVFI address and the commit assertions all read the head.
- **Liveness.** Stalling an older load on a younger store deadlocks under in-order
  commit: that store cannot retire until the load does. An age filter on the hazard
  term is therefore a progress requirement, not an optimisation.
- **Commit-held resources.** A unit that stays occupied from issue until the
  instruction *commits* encodes an in-order assumption: that the occupant is
  effectively the oldest instruction. Out-of-order issue breaks it — the occupant
  can be stranded behind older work that needs the very resource it holds. Either
  make the resource deep enough to be non-blocking, or issue its occupant only
  when it is the oldest live instruction. Do not simply widen who may hold it.
- **Window lifetime.** A guard that opens on one instruction and closes on another
  is bounded only if the closing instruction is guaranteed to arrive. In order,
  the next memory op or a flush always does; out of order it need not, and the
  program is under no obligation to supply it — an LR with no SC is legal. Bound
  such a window by the lifetime of the instruction that opened it, not by the
  hoped-for arrival of its partner.
- **Capacity.** A queue that drains only on in-order commit must never be fillable
  by work younger than something that still has to enter it. Admission has to be
  decided where the work is *selected*, not where it arrives: refusing it on arrival
  simply moves the blockage into the stage in front. Gate on older **unissued**
  entries — the oldest such entry has none, so the rule cannot deadlock, unlike a
  gate on older *live* entries which includes work that only issuing can retire.

### Parking and store lifetime under OoO

WFI is a retirement boundary, not permission to leave younger allocated work behind
a halted commit stage. The OoO commit path requests the existing precise flush and
next-PC restart before parking; dropped, faulting, invalid and stalled instructions
do not generate that request. Coarse handoff can then drain committed stores and
switch contexts without requiring the parked hart to retire younger instructions.

Full flush and younger-branch cancellation are different promises. A full flush
discards uncommitted stores; a selective cancel discards the named identities.
Historical in-order SMT store keep/replay rules are not transferable to OoO. Keeping
a speculative store while discarding its scoreboard allocation leaves an orphan
which can consume another instruction's later FIFO commit. `LEGACY_SMT_KEEP` excludes
OoO while preserving the existing in-order anchor. The committed store queue retains
its accepted obligations. Broader out-of-order store issue/forwarding and mixed-hart
memory ownership require separate verification; the startup test is not that proof.

## 3. Config knobs (`core/include/config_pkg.sv`)
- `NrScoreboardEntries` `241` (size of the in-flight/speculative window).
- `NrLoadBufEntries` `243`, `MaxOutstandingStores` `245` (memory-speculation depth).
- `WtDcacheWbufDepth` `219` (write-through drain depth interacting with store retirement).

## 4. Feature-addition playbook
Deepening speculation is primarily a sizing change: raise `NrScoreboardEntries` and the LSU buffer
depths in the target package, then verify the flush path still clears every speculative structure.
The correctness contract is that a flush from `core/controller.sv` must invalidate the scoreboard
entries, the frontend prediction in flight, and any un-committed LSU state simultaneously; adding a
new speculative buffer means adding it to that flush fan-out. Architectural writes happen only at
`core/commit_stage.sv`, and stores must not leave `core/store_buffer.sv` toward memory until they are
non-speculative. LR/SC reservations tracked in the D$/LSU must survive intervening speculation and be
cleared on the events RVWMO/`Zalrsc` require. If you add a new ordering primitive, encode it against
RVWMO preserved-program-order rules rather than ad hoc stalls.

## 5. `.dts` linkage
Speculation is not device-tree visible. Its only DT-facing footprint is the extension string
`riscv,isa` (the `A`, `Zawrs`, `Ztso`, `Zalasr` letters must match the config) and, where errata
mitigations are exposed, CPU-node `compatible` handling in software — not a DT property to add.

## 6. Invariants and pitfalls
Precise traps are non-negotiable: no exception, store, CSR side effect, or reservation change may
become architecturally visible before in-order commit. Store-to-load forwarding in the LSU must obey
RVWMO (`#memorymodel`); a forwarding path that ignores address dependencies is a memory-model bug,
not just a performance issue. Misspeculation must fully restore the reservation and store-buffer
state. Modern designs also consider transient-execution side channels; the spec does not mandate
mitigation, so treat it as a design decision documented alongside any widening of the window.
