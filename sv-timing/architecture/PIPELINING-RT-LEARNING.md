# Pipelining: evidence, representation and initial-IR preprocessing

**Status:** a development method plus an implemented deterministic pragma
preprocessor. It is not an autonomous learner, a trained timing model, or a
claim that the core meets 10 adjusted FO4.

This specializes the analysis segments and conditional pattern transfer in
[`AGENTS-rt-learning-philosophy-AGI.md`](../../AGENTS-rt-learning-philosophy-AGI.md)
for RTL pipelining. The governing development guide is
[`AGENTS-coding-philosophy.md`](../../AGENTS-coding-philosophy.md), the actual
repository filename. Specification, authorization, licensing and verification
requirements retain their existing precedence.

“Reflection” here means inspecting RTL changes, contracts, emitted files,
counterexamples and measurements. The retained artifact is an inspectable
engineering justification, not a reconstruction of private reasoning.

## 1. What the multiplier experiments actually established

The useful abstraction is **partition computation and move the complete
representation of one operation through each boundary**.

| Observation from the multiplier campaign | Mechanism that transfers | Boundary on the claim |
|---|---|---|
| Capturing only the integer product misaligned CLMUL with it by one cycle at the output select. | Follow every reconverging data/control path, including alternatives selected by the operation. | Correct valid/ID alone does not establish correct data. |
| The signed product was expressed through unsigned pieces and an explicit correction. | Separate mathematical identity from its hardware representation; preserve modular width and signed interpretation. | The identity depends on operand extension and the retained result width. |
| Narrowing only one operand left a long product cone. | Reduce the size of work *inside* a stage; a register at an interface may only move the bottleneck. | An extra stage is not proof of lower maximum delay. |
| Smaller tiles plus carry-save rows moved accumulation out of partial-product generation. | Delay carry propagation until the final addition; sum and carry are one represented value. | Two rows must cross the same number of edges and reach the same consumer. |
| A fourth-cycle operand-capture trial worsened reg→reg delay. | Test whether a proposed boundary divides work or merely renames in→reg as reg→reg. | Keep the failed candidate as a counterexample, not a future “expected gain.” |
| Unbuffered timing worsened while paired placement improved. | Fanout, mapping and physical repair are part of the experiment. | Do not generalize an unplaced or filtered result to routed timing. |
| The source improved more than its corrected emit. | Validate the emitted artifact as a separate implementation. | Syntactic reparse is not equivalence or timing qualification. |

The retained A132 RTL registers small unsigned product tiles, reduces their
aligned rows together with the sign correction, then performs one final
carry-propagate addition. Existing valid, ID, operation and CLMUL paths remain
aligned at three cycles.

The concrete inspection points are
[`core/multiplier.sv`](../../core/multiplier.sv):
`gen_two_stage.gen_pp` (tile widths and partial products),
`gen_three_stage.gen_reduce` (3:2 reduction),
`prod_sum_q`/`prod_carry_q` (paired capture), and `mult_result_d` (final add).
The `clmul_*`, `operator_*`, `trans_id_*` and `mult_valid_*` paths expose the
parallel-path obligations. [`core/mult.sv`](../../core/mult.sv)'s
`gen_mul_lifetime` owns cancellation through ID reuse; `CVA6Cfg.MultStages`
is the published depth. Inspect both sides before changing that boundary.
Commit `a88c12e7a` and the A132 review preserve the retained implementation.

For an `N=XLEN+1` two's-complement pattern:

```text
A = Au - a_top * 2^N
B = Bu - b_top * 2^N
A*B = Au*Bu - 2^N*(a_top*Bu + b_top*Au)   modulo 2^(2*XLEN)
```

The discarded cross term is outside the retained result width. Each 3:2
compressor preserves `a+b+c = sum+carry` modulo that same width:

```text
sum   = a ^ b ^ c
carry = ((a & b) | (a & c) | (b & c)) << 1
```

The carry row here is **already shifted**. Introducing an implicit extra shift,
narrowing a row, or reconstructing it from a later operation changes the value.

Evidence of record: A132's paired Nangate45 placement/repair measured
2.634 → 2.215 ns worst arrival at +1.4% repaired area, with no disabled
timing arcs. Actual corrected SV measured 2.298 ns. Reg→reg was essentially
flat; this is an unrouted, pre-CTS module result, not whole-core closure.
See [PIPELINE-PRAGMA-REVIEW.md](PIPELINE-PRAGMA-REVIEW.md) for the immutable
run identities, source/emit witnesses, rejected candidates and limits.

## 2. Propositions for a new pipeline strategy

```text
PROPOSITION PL-P1 — Name the observed boundary
  REQUIRE   Source/configuration identity, path class, cell trace, constraints,
            library/PVT, mapping/repair recipe and area.
  REJECT    Explaining worst-any delay using a different reg→reg path's trace.

PROPOSITION PL-P2 — Preserve an operation, not just a wire
  REQUIRE   Accepted-event definition, valid, identity/generation, cancellation,
            flush, side-band, all result alternatives and consumer behavior.
  REJECT    Data-only cuts, stale ID reuse, delayed ACK without a reservation,
            or a producer-only pipeline change.

PROPOSITION PL-P3 — Representation is part of the boundary
  REQUIRE   Widths, signedness, arithmetic identity and every component needed
            to reconstruct the value at the consumer.
  REJECT    Staging one carry-save row, canonicalizing early without measuring,
            or treating a type/width estimate as elaborated fact.

PROPOSITION PL-P4 — Timing credit follows implementation and evidence
  REQUIRE   Actual emitted registers/logic, nonvacuous functional checks,
            then a paired physical measurement appropriate to the claim.
  REJECT    Budget closure from a pragma, a synthetic stage count, or a cost
            reduction with no structural counterpart.

PROPOSITION PL-P5 — Transfer conditions, not headlines
  REQUIRE   A reusable mechanism with explicit preconditions and countercases.
  REJECT    Copying a multiplier pipeline into a queue feedback loop, or
            assuming that a winning stage count is portable across libraries.
```

## 3. Development loop and discriminators

Use a bounded segment rather than an open-ended optimization narrative:

1. **Observe:** freeze source, specialization, instrument and baseline. Identify
   the actual worst path and its protocol owner.
2. **Represent:** write the value/identity/lifetime equations. Enumerate parallel
   results, control predicates, queue reservations and feedback recurrences.
3. **Propose:** choose a mechanism and predict what moves between boundaries.
   Name a competing explanation and a result that would reject the proposal.
4. **Compile intent:** express supported obligations as pragmas; lower them into
   initial IR. Unsupported obligations remain explicit refusals.
5. **Implement:** use an existing safe transform or implement a new RTL/pass
   primitive. Never use a comment to waive a missing mechanism.
6. **Discriminate:** start with the cheapest faithful check, then test the actual
   emitted implementation and the physical effect. Use a negative control when
   the checker could pass a broken or inactive pipeline.
7. **Retain:** preserve the winning source and evidence together with failed
   alternatives, scope limits and invalidation conditions.

```text
SEGMENT CARD
  QUESTION       Which stage dominates, and why?
  OBJECTIVE      10 adjusted FO4, correct operation identity, acceptable area/IPC.
  ENVELOPE       Parameters, library, path boundary, loading and implementation recipe.
  CONTRACT       Mathematical value + accepted event + lifetime + consumer obligation.
  HYPOTHESES     Operator depth; fanout/repair; early canonicalization; control recurrence.
  DISCRIMINATOR  Predicted per-boundary change and the measurement that distinguishes it.
  RESULT         Observed data, counterexample, retained/rejected/inconclusive decision.
  NEXT ARTIFACT  Regression, normalized IR fact, implementation primitive or revised card.
```

The budget is a physical objective, not a permission rule. At 21.398 ps/FO4,
10 adjusted FO4 corresponds to 0.21398 ns of the *reported delay quantity*.
Keep that quantity consistent: data arrival may already include clock-to-Q;
setup, uncertainty and routing need their own accounting. Do not double-count
overheads, equate an inferred multi-cycle class to an SDC exception, or convert
`ceil(delay/budget)` into an implemented stage plan.

## 4. Reusable pattern families

| Family | Applies when | Candidate implementation | Reject or defer when |
|---|---|---|---|
| Tile → reduce → finalize | Large exact arithmetic with a known result width and an operation protocol | Smaller partial operators, row reduction, final canonical result | Truncation/sign correction is unclear; an atomic operator remains over budget |
| Coupled representation capture | A value is carried by multiple equal-age components | Capture all components with one protocol bundle | A companion is late, unbound, differently sized or not visible in the capture scope |
| Parallel-path alignment | Results reconverge under an operation/control select | Balance alternate datapaths and their selector/control | Only the nominal critical arm was staged |
| Late decision / early preparation | A selector arrives after cheap independent alternatives can be prepared | Precompute alternatives, then select; area gate the duplication | Placement or area outweighs the delay gain |
| Reservation before state update | A request can be accepted before its state mutation completes | Input capture plus reserved capacity and pending-entry visibility | ACK, forwarding, commit, flush or cancellation ignores pending work |
| Feedback/recurrence redesign | A loop itself exceeds the budget | Lookahead, speculative work with recovery, or a changed iteration protocol | A local register would change recurrence semantics without a recovery mechanism |

Only the coupled carry-save representation compiler below is newly implemented
by this pass. The table is a transfer guide, not a list of implemented passes.
Queue staging, automatic multiplier tiling, automatic compressor synthesis,
generic ready/backpressure and cross-module retiming are not implied.

The A134 follow-up provides two further tested RTL patterns
([evidence](PIPELINE-PRAGMA-REVIEW.md#a134--further-controlstate-files)):

* **Cache the state-only side of a predicate at its update edge.** The realigner
  records the continuation address with its carry PC, then compares the live
  request against it. The proof is validity-qualified, per owner/hart, and
  includes reset, retention and width overflow. Geometry makes the cached value
  available before the late split decision. Simply registering the whole
  predicate would use the previous request and be wrong.
* **Compute small table updates before the late row selection.** The statistical
  corrector computes each row's update from that row's registered state and
  selects one write. This avoids a shared read-mux/train/write-decode chain.
  It applies to this small flop-based table, not automatically to SRAMs with
  limited read ports, and it trades area for timing.

A136 adds two more, with the same discipline
([evidence](PIPELINE-PRAGMA-REVIEW.md#a136--further-worst-arrival-modules-without-interface-cycles)):

* **Register a derived address instead of recomputing it — then check the
  unbuffered view.** (A137 outcome: reverted.) The loop buffer's
  compares read `base + cursor<<ALIGN`; a register tracks the sum for the active
  cursor and is updated from register-formed candidates on exactly the cursor
  events. The proof obligation is a per-state invariant asserted every cycle,
  and the first attempt showed why: a same-cycle arm+consume corner made a
  two-register form inconsistent; the corrected form chooses the side the next
  cycle can observe. The placed pair improved, the live unbuffered board got
  worse (late 64-bit mux selects that only buffer repair absorbs) and the
  change was reverted: a candidate must improve in both views.
* **Search in absolute order; do not rotate — when the consumer wants the
  slot.** The checkpoint stack (A137) needs the ring offset as well as the
  slot: the slot-order form then re-derives the offset with a subtraction
  ahead of the pointer add, and placed reg→reg worsened 2.334 → 2.715 ns
  while the filtered study still improved. Applicability condition: the
  found slot must be the consumer's value, not an operand of further
  pointer arithmetic.
* **Search in absolute order; do not rotate.** A ring find-first "from head"
  equals the lowest hit at or above head, else the lowest hit below it. Two
  log-depth lowest-set searches on the unrotated vector and a late select
  replace a dynamic rotate, a carry-chain isolate and a final add; the result
  is the slot itself. Keep the rotated form as a reference assertion.

Both retain cycle latency. Neither is implemented as an automatic initial-IR
rule yet. The rejected rename/store-buffer bypasses show why an exact algebraic
rewrite still needs a physical discriminator: filtered mapping improved, but
placement worsened.

## 4a. Input staging as a uniform shift — and when it cannot pay (A138)

The store buffer's permutation reads every input the module has; the stage
the contract admits is input staging of the whole input set. The method that
makes it checkable is the **uniform shift**: stage every input the permutation
consumes so the core state equals the previous design's state one cycle later,
then derive the current-cycle outputs from the registers and prove each
derivation by implication against the previous semantics (state identity with
a delayed reference; forwarding, stall and readiness bounded by a live
reference). Obligations the witness surfaced: the commit port may retire a
store that is still staged; squashed entries are neither head nor forwarding
sources; a committed-but-staged head is architectural yet still pending for
serialising consumers; a shared random memory handshake must be protocol-legal
per instance once phases differ.

The trial passed every functional check and was **rejected on placement**
(3.964 → 4.316 ns, +8.1% area). The decisive error was in target selection: the
module board's `any` figure (3.70 ns unplaced) suggested an input cone, but the
isolated *placed* baseline put the worst path inside the permutation
(reg→reg 3.96 ns), which an input stage cannot shorten, while the derived
views add logic to the remaining paths. Applicability condition for input
staging: the placed in→reg cone must exceed the placed reg→reg cone by more
than the derived-view cost; measure that split first. The next rung for this
module is a stage *inside* the permutation (insert, then compact), which the
uniform-shift witness can also judge.

## 5. Implemented preprocessor: source intent to initial IR

Example:

```systemverilog
// svt-pipe: protocol ex valid=valid_q id=tid_q kill=cancel_i[$id] flush=flush_i
// svt-pipe: result ex valid=res_valid_d id=res_tid_d
// svt-pipe: representation ex carry-save sum=sum_row carry=carry_row result=res_d
// svt-pipe: cut-ok ex on=sum_row
assign sum_row   = (a_q ^ b_q) ^ c_q;
assign carry_row = ((a_q & b_q) | (a_q & c_q) | (b_q & c_q)) << 1;
assign res_d = sum_row + carry_row;
```

The representation directive asserts a role; it does not prove the source's
compressor identity. The compiler checks the binding and consumer shape, then
ensures that a permitted cut preserves both source rows.

The real pipeline is:

```text
parse comments/CST → lower declarations, expressions and original source spans
  → pipeline_preprocess::prepare_design
      validate representation and protocol
      add derived carry/result/no-cut facts; retain original directive
  → attribute costs → compose/classify paths → opportunities
  → existing InsertReg (ordinary permission, width, latency, area and alignment gates)
  → capture sum + companion carry + protocol → rewire result → emit/reparse
  → functional witness → paired STA/placement as required by the claim
```

`prepare_design` is called at the start of cost attribution, before the initial
timing/opportunity analysis. It also runs on remeasurement so cache-rehydrated
modules and changed parameter/width contexts rebuild their derived facts.
The raw source pragmas remain in `TimingModule.pipe_pragmas`;
`PipePragma.derived` distinguishes compiler facts from source declarations.
Initial-IR preprocessing does not edit executable nodes or award FO4.

For the example it derives the equivalent of:

```text
carry ex carry_row
result ex <existing valid/id roles> res_d
cut-ok ex on=carry_row  (alias of the author's atomic-pair boundary)
representation-ready <source identity, domain, rows, consumer, width>
```

The planner can reach this boundary through either row's critical path.
Whichever row is selected as data, the other is its carried companion; the
data net must not also capture itself through a delayed feedback copy.
The ordinary transform rewires `res_d` to the staged companion and prices
both rows at their resolved widths. The directive grants **no boundary without
an authored `cut-ok`**. With one, it adds the equivalent other-row anchor.
A `no-cut` on either row forbids the whole pair.
The `latency` contract still applies whenever a depth is published to consumers.

On an accepted cut, applied-boundary facts prevent another cut in the same
correction run. Emission replaces the consumed representation directive with
`no-cut on=sum_row,carry_row`, preserving line count and preventing an unbalanced repeat
when the emitted source is processed again. Other source instructions and the
edit trace retain provenance.

### Supported envelope and refusals

The first compiler supports one representation per named domain and a module-local, equal-width
packed sum/carry pair with distinct simple identifiers. Each row and the named
consumer must have one unguarded continuous writer, and the consumer must be
exactly `sum + carry` (either operand order). Result valid/ID roles must exist;
bundle widths must resolve and valids must be scalar.
Valid, ID, flush and result roles use simple signal names in this compiler.
An ID-less input cannot declare an ID-bearing result, or vice versa.

The row cones must be independent up to existing ports/registers. Their
parsed arithmetic fan-in cannot read the other row or the consumer; ambiguous
writers, feedback and hidden reads through calls refuse this lowering.
Data rows must not alias valid, ID, kill, flush, clock or reset roles.
These conditions prevent a rewritten data assignment from feeding a delayed
copy back into its own companion or control capture.
The forward dependency check also crosses registers: a result feeding back
into an input register, protocol control or pre-existing carried source is
a recurrence and is refused. Modules with local functions are deferred
because this compiler does not prove their hidden-read effects.

Selections, unpacked arrays, generate/procedural locals, multiple writers,
unknown widths, unsupported representation kinds, invalid base contracts and
different consumer expressions refuse normalization. Representation directives
must be standalone source comments. A failed compile contributes an explicit
contract rejection; it does not leave a partially installed companion bundle.

This conservative envelope is deliberate: extend it by adding an implementation,
an exactness argument and discriminating tests, not by weakening its checks.
The caller's parameter/width facts must match the specialization being emitted;
a widest-net map merged across different instances does not qualify a fixed-width
emit for all of them. The authored protocol must describe accepted operations,
not merely presented requests. This compiler does not infer backpressure or make
a stalled sink elastic.

### Implementation loci

* `crates/sv-timing-core/src/pipeline_preprocess.rs`: representation validation,
  canonical facts, typed plan queries, idempotent rebuild and applied boundaries.
* `lower.rs` / `ir.rs`: source collection, spans and derived-fact provenance.
* `measure.rs`: mandatory preprocessing before timing and on remeasurement.
* `pipe_contract.rs` / `sv-timing-transform/src/pipeline.rs`: consume the
  normalized bundle through existing cut/latency/width/alignment checks.
* `sv-timing-emit/src/{lib,rhs}.rs`: consume applied directives without shifting
  source line anchors; the existing dense emitter captures the companion row.
* Analyze JSON's `pipeline_contracts[].representations`: typed preprocessing
  results alongside contract diagnostics. “Prepared” is not “validated timing.”

The IR/correction versions invalidate older cache assumptions. Tests cover
initial-IR normalization, unchanged executable costs, repeated preparation,
serialization/cache round trips, refusal cases, actual paired emission and
protection against recutting the consumed boundary.

## 5a. Second implemented rule: `row-local` source preparation (A135)

The A134 statistical-corrector pattern is now a pragma the tool executes:

```systemverilog
always_comb begin
  mem_d = mem_q;
  // svt-pipe: row-local train index=uidx rows=NR_ENTRIES banks=mem_q:mem_d max-rows=32
  if (bht_update_i.valid) begin
    ... reads mem_q[uidx], writes mem_d[uidx] fields ...
  end
end
```

Pipeline position: parsing retains the conditional statement's original
source span and bytes; `prepare_design` compiles the directive into a
`row-local-ready` plan (no IR cost change); `correct --emit` with structural
emission writes a prepared copy under `<out>/_prepared/`, reparses it under
its own path and configuration, and only then runs the ordinary worklist.
Emission maps the prepared file back to the original logical path and keeps
the consumed directive as `row-local-applied`. `svt_pragma_preprocess.json`
and the JSON `pragma_preprocessing` block record the source-level edits.

The generated form is `for (int unsigned r = 0; r < rows; r++) if (index == r)
<statement with bank[index] -> bank[r]>`. It is exact when the index is a
stable, unsigned, registered/input-derived selector, every bank reference in the
statement uses that index, the only writes are `destination[index]` fields,
and the statement has no calls, macros, strings, loops, locals, compound
assignments or enclosing-block terminators. The lowered IR write footprint
must match the statement text. Row counts come from declared elaboration
constants and must fit the authored `max-rows`. Anything else is a contract
rejection, not a partial rewrite.

Evidence for `g6lc_bp_loop` (`fo4-a135-loop-emit`): equivalence of source vs
emitted for 16x4/RVC, 8x1/no-RVC and 32x2 geometries; an independent per-row
model passes both seeds on both variants and detects a forced-wrong override;
paired Nangate45 placement/repair with no disabled arcs improves worst arrival
**1.911 → 1.410 ns** (−26.2%) at **−6.9% area**. The structural estimate did
not move (18.6 FO4), which confirms that this rule must be judged by the
reparsed emit and physical result, not by the IR headline.

## 6. Validation and evidence retention

The fixture is `fixtures/auto_correct/pipe_representation.sv`; its independent
reference in `tb_pipe_contract.sv` evaluates `(a+b)+c`, not the compressor
implementation. `SVT_REPRESENTATION` selects it, `SVT_TWIN` selects emitted RTL.
The witness checks IDs and values through randomized cancellation/flush, requires
nonzero results and cancellation activity, and drains the pipeline to detect loss.
The negative control reconnects the unstaged companion row and must fail by a value
mismatch. `CONTROL_MODE=pipe-representation` in the host's isolated review runner
also maps both variants with the same Nangate45 recipe. Hosts remain optional;
package unit/emission tests depend only on this package and its fixtures.

Minimal package invocation (the explicit area dial is part of this experiment):

```text
python tools/svt.py run -- correct --file fixtures/auto_correct/pipe_representation.sv --modules-allow pipe_representation --target-mhz 4000 --fo4-ps 20 --budget-margin 0.2 --opt-level 3 --opt-max-cells-per-fo4 128 --allow-latency --real-cut-feeds --assume-clk --emit --out-dir .sv-timing-out/representation --json-out .sv-timing-out/representation.json
```

The emitted file must contain a real paired stage, not only comments.
Reanalyzing it must expose both consumed-row `no-cut` guards; correction at
a tighter budget must not insert another stage at that boundary.

The A133 run `fo4-a133-representation` confirms that the initial-IR compiler
drives a real cut through the carry row, the longer path in this fixture,
while carrying the sum row. The structural estimate is **15 → 10 FO4**.
Gold and emitted variants each pass seeds 7/19/23 for 200,032 cycles
(including drain), with nonzero output/cancel/flush counts and no errors.
The unstaged-companion negative control fails on data mismatches.

Paired, unplaced Nangate45 STA with no disabled arcs reports the following.
Both variants use the existing fixture mapping recipe, including `async2sync`;
the functional witness simulates the original asynchronous-reset RTL.

| Fixture metric | Source | Emitted |
|---|---:|---:|
| Worst arrival | 0.808 ns | 0.699 ns |
| Reg→reg | 0.808 ns | 0.696 ns |
| Cell area | 1,291.962 µm² | 1,652.658 µm² |

That is 13.5% lower worst delay at 27.9% more area and one additional cycle.
At the recorded 21.398 ps calibration, the emitted reading is about
**32.7 adjusted FO4**, despite the structural 10. This is a compiler/witness
qualification, not an area acceptance decision or physical 10-FO4 closure.
The longer lifetime also changes cancellation opportunities and tag occupancy;
the randomized witness is not an IPC benchmark. Host records:
`build-platform/workspace/build/sv-timing/precompute-a133/`.
The workspace suite passes **380 tests**. The final compiler reproduces the
measured emitted file byte-for-byte, and a second correction at a tighter
budget inserts no additional register at the consumed boundary. The package
independence scanner still reports pre-existing host references in unchanged
test/tool content; this pass adds no host dependency to the preprocessor.
The existing A123 source/twin contract witness also passes all three seeds
with the strengthened drain checks (`fo4-a133-legacy`).

Retain a pattern as a versioned claim:

```text
PATTERN PL-REP-1 / v1
  MECHANISM        Components of one representation cross an authorized edge together.
  APPLIES WHEN     Exact bindings/widths/consumer shape and a complete operation protocol.
  PREDICTS         Staging only one row corrupts values; capturing both preserves identity/value.
  COUNTERCASES     CLMUL merge failure; source-depth mismatch; a relocated unsplit bottleneck.
  EVIDENCE         A132 source/emit review plus the generic representation fixture.
  STATUS           Locally tested compiler primitive; other pipeline families are candidates.
  CONFIDENCE BASIS Paired witnesses and a failing negative control, not a calibrated score.
  EXCLUDES         Automatic tiling, state-machine protocols, routed closure or general learning.
  INVALIDATE WHEN  Source specialization, row encoding, consumer, emitter, library or constraints change.
  CHECK / OWNER    Maintainer review: compiler tests → emitted witness → physical comparison.
```

A new normalization rule must state its input shape, semantic invariant, derived
facts, permitted effects, rejection conditions, area/latency obligations and
evidence of the emitted implementation. Update the rule registry and versions,
not only this document. Preserve counterexamples and keep source, emitted and
physical outcomes distinct. This is L1/L2 engineering learning in the companion
philosophy: better reviewed patterns and executable checks, not model-weight
training or a self-authorizing optimization system.
