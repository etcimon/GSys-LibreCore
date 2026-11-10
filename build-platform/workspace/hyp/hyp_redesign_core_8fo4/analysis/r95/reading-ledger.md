# r95 methodology reading ledger

Scope: the comprehensive Hyp retirement/FO4 redesign request following r94.
This file records reading progress, not implementation or boot qualification.

The requested names resolve as follows; absent aliases will not be created:

- `AGENTS-code-philosophy.md` -> `AGENTS-coding-philosophy.md`
- `AGENTS-rt-learning-philosophy.md` -> `AGENTS-rt-learning-philosophy-AGI.md`
- SMT2 reasoning workflow -> `architecture/multi-threading/AGENTS-SMT2-opensbi-reasoning-pattern-workflow.md`
- OpenSBI heuristics -> `architecture/AGENTS-g6lc-opensbi-dev-heuristics.md`

Read ranges so far (inclusive):

| Source | Read | Total |
|---|---:|---:|
| Coding philosophy | 1-639, complete | 639 |
| Runtime-learning philosophy | 1-625, complete | 625 |
| SMT2 reasoning workflow | 1-693, complete | 693 |
| OpenSBI heuristics | 1-867, complete | 867 |
| ALGORITHMS-EXPERTS | 1-9687, complete | 9687 |
| Root AGENTS | 1-608, complete | 608 |
| Build-platform AGENTS | 1-929, complete | 929 |
| SMT2 development logics | 1-688, complete | 688 |
| Firmware boot principles | 1-314, complete | 314 |
| Pipeline runtime-learning | 1-503, complete | 503 |
| Fetch SPEC | 1-351, complete | 351 |
| Fetch VALUES | 1-382, complete | 382 |
| Fetch NEGATIVE | 1-367, complete | 367 |
| Uncore AGENTS | 1-156, complete | 156 |
| OoO/SMT2 architecture contract | 1-265, complete | 265 |
| Configuration guide | 1-395, complete | 395 |
| Licensing guide | 1-380, complete | 380 |
| SoC readiness guide | 1-255, complete | 255 |
| Top-level build-platform guide | 1-473, complete | 473 |

The identified methodology companions are complete. The complete package
AGENTS guide was also supplied in context and read. Module-specific guides
discovered during the source/caller inventory remain subject to review.

Initial scope observations:

- Current worktree contains unrelated edits in the production APU vnfront,
  xfer, and xfer bench; preserve them and do not treat those bytes as a frozen oracle.
- The previous accepted Hyp commit is `cea7c94ed`. Its report separates
  representational reductions from mapped timing and rejects the private
  coherence counter cone as a performance win.
- Existing `analysis/retirement-plan.md`, caller inventories, and execution
  plans are historical inputs. Findings must be checked against current source;
  their presence does not establish that an old defect remains unfixed.
- Long logical depth alone does not cause failure in untimed Verilator.
  Architectural failures require an identified ownership, ordering, gating,
  lifetime or protocol mechanism; timing and functional claims remain separate.

## Method constraints extracted from the completed documents

- Treat firmware as a workload witness, not a controller or patch target.
  Contracts must apply to arbitrary legal instruction sequences.
- Map promises and every owner before choosing module edits. Use hart,
  transaction ID, allocation generation and lifetime, not temporal proximity,
  addresses or a field name such as "issued", to join events.
- Qualify the observation and completion endpoint first. A timeout, a cap,
  missing error text or one elected publisher's unconnected completion is
  not a successful boot or a valid reason to loosen a classifier.
- Prefer definition/elaboration constraints and local stateful assertions to
  repeated long soaks. The final firmware run checks integration sufficiency.
- Walk all six speculation visibility channels, including lost required
  writes, stale state after kill, premature kill, value-based control and
  cross-hart ordering. Configuration gating cannot legalize a red-line behavior.
- Preserve causal co-factors: issue width, harts, RVC/fetch geometry, queue
  occupancy, accepted-but-not-yet-stored work, reset schedule and memory state.
- Inspect useful work and contention end-to-end: a lower module-local FO4
  or warm-hit latency can coexist with worse total checked work.
- Package/measurement defects are corrected before changing RTL to fit a
  report. Representation, emitted RTL timing and physical STA are distinct.
- Keep aggregate changes contract-coherent rather than bundling unrelated
  hypotheses. For each segment record the rival explanation, discriminator,
  rejection condition, next residual and remaining applicability boundary.
- Retain negatives and supersession. Historical passing controls do not
  establish current qualification after runtime, source or oracle changes.

Recent production-side case studies in the runtime-learning document identify
carry-over **audit candidates**, not yet established Hyp defects: suppressed
FU acceptance during recovery; cancellation before a queued load receives a
cache grant; reset-event delivery to gated secondary state; CSR credit for
accepted work still in the issue pipeline; and completion notification from
every legitimately elected producer. Current source and callers must decide
which mechanisms are already present in the Hyp copy.

ALGORITHMS 1-800 establishes the budget/version/class/lane distinction:
`fo4_ps` is a process input, not a tuning knob; hierarchy alone is not a
pipeline boundary; atomic-stage arithmetic is only a projection; real emitted
RTL, timing and whole-core legality are independent obligations. Historical
tables use multiple delay versions and source trees, so none is a fresh r95
baseline. The manual itself directs package-first correction of phantoms and
locks handshake/control paths against arbitrary register insertion.

ALGORITHMS 801-1600 adds the concrete SV obligations: generate/procedural
constant-loop scopes, module-local lowering, expression/operator widths,
NBA old-Q versus blocking temporaries, and composed launch/capture endpoints.
Legacy protective opaque-cast cases are historical limitations, not permission
to hide runtime operators in the current instrument. Resolve contradictory
historical descriptions against pinned current code and fixtures.

ALGORITHMS 1601-2400 supplies the routing distinction: independent writes
share a makespan; genuine data dependencies serialize; iterative and atomic
units need explicit microarchitectural decisions; same-edge pulse/index and
indexed-restore paths are P10-locked. A module's classification is neither an
architectural permission to add latency nor proof of a physical timing floor.

ALGORITHMS 2401-3400 distinguishes T0 measurement, T1 latency-neutral
representation, T2 temporal staging and T3 architectural redesign. Cleanliness
only routes tools. Splitting an expression/process/file is not itself timing
gain. Cuts require legal protocol windows and real carried feeds; emitted
source is reparsed and independently checked. Bounded module-diverse updates
avoid endless worst-number chasing and conflicting edits to source origins.

Later manual sections explicitly qualify cross-module stitching as triage,
not connected arrival evidence: summing a representative child and parent
maximum can both overstate unrelated cones and miss a real composed cone.
Use real pin/field connectivity, register boundaries and active elaborated
instances for caller bubble-up claims. The later width/cast/CSA chapters
supersede older protective parsing bans; arithmetic identities and measured
physical benefit remain separate questions.

The final algorithm chapters make the useful transfer patterns conditional:
registered event deltas need complete, disjoint accepted-event accounting;
one-hot reductions need the asserted invariant and its caller obligations;
cached predicates must travel with entries through permutations; legal
pipeline cuts carry the complete represented value and every downstream
merge companion. The current contract primitive does not infer general
ready/backpressure or cross-port retiming. A latency parameter already used
as its own source depth cannot supply an extra window merely by being raised.

Root governance requires all Verilator builds/regressions/soaks through the
configured remote gateway, with qualified runtime/compiler identity, explicit
reset-edge controls and independent completion semantics. Existing production
functional drafts and unrelated APU edits remain separate from this Hyp
carry-over analysis. No OpenROAD invocation or dependency installation is
authorized by this reading pass.

The linked pipeline guide also records rejection conditions worth preserving:
input capture can merely relocate an unsplit bottleneck; cached derived values
need update-edge invariants; absolute-order search only helps when the consumer
wants the slot, not a subsequently recomputed offset; widest-instance maps do
not qualify fixed-width emission for every instance. The firmware guide states
that CF-0 reverted the old ISA-invalid value filters. That is historical evidence
against assuming those filters remain in today's reference or Hyp source.

At completion of the reading phase, only this reading ledger had been authored.
No new RTL defect, current active-profile timing ranking, OpenSBI run or
Linux qualification is established by the reading pass. Source/caller inventory,
the per-high-FO4 work queue and contract-coherent implementation remain pending.

## Completed-methodology checkpoint

- Repository HEAD is `cea7c94edec8048d44ab04cdc1effbb1a11460ea`.
  The three unrelated tracked APU/bench edits remain present and untouched;
  scratch/untracked artifacts are not cleanup candidates for this task.
- `.active-contributor`, `.licensing-policy` and `.licensing-tiers` exist.
  The 59-line policy was read completely. Tier resolution and CLA checks for
  selected code paths must still precede code edits; no header is being changed.
- `rg` is not on this shell's PATH. Use scoped `git ls-files` and Python
  discovery rather than repeating a failed lookup. Local Python is
  `C:/Python314/python`; Bun is installed. No tool installation was attempted.
- Current configuration guidance names 8 FO4 / 5 GHz nameplate at
  `fo4_ps=20`, margin 0.2. Older 32-/10-FO4 tables in the contract/build
  guides are historical, not the new acceptance budget.
- The source guides contain superseded and conflicting descriptions.
  Accepted-stream order supersedes numerical-PC ordering; carry completion has
  a documented slot-zero/replay exception to whole-window admission; proof
  envelopes do not automatically generalize to separately elaborated widths.
  Use current source and the matching evidence, not an isolated historical row.
- The OoO contract already documents head-only CVXIF issue, pre-grant LSU
  tombstones, CSR age order, mixed-hart reclaim versus commit identities,
  writer acquisition, and L2 publication guarantees. These must be compared
  against Hyp before calling a missing carry-over a new defect.
- The uncore guide's old proprietary-header wording is superseded by the
  actual tier-directed licensing policy. No guide text authorizes deleting
  shared evidence or running destructive legacy smoke cleanup.

The subsequent inventory and validation-access state is recorded in
`r95/worklog.md`. Do not repeat this completed methodology reading phase.
