# Control-cone closure — g6lc64_ooo

The objective remains **10 structural FO4**, with `fo4_ps=20`, margin 0.2,
and a 4000 MHz structural target. The logic budget is 200 ps; the clock is
250 ps. Nangate45 module studies are separate observations. Neither a
cell-count ratio nor a fitted ns/FO4 ratio changes this budget.

## A119 candidates

* IQ: compute the first two grants from independent zero/one-older-ready
  predicates using a balanced saturating count tree. Higher issue widths
  retain the existing cascade for later ports. Exactness requires the
  already asserted strict age order; arbitrary ack patterns remain valid.
* LSQ: replace serial youngest-store and oldest-violation scans with stable
  tournament trees over the same distance keys. Keep earliest-index ties,
  invalid/default behavior, byte coverage and same-cycle address updates.
  These transformations add no state, ports or configuration fields.
* Analyzer: exclude a constant-generate branch only when its condition is
  proved from explicit host facts or unambiguous visible localparams.
  Parameter defaults, unknown values and unresolved source origins are not
  sufficient evidence. This corrects measurement; it earns no hardware gain.

Focused proof precedes the paired map-v2 measurement. The A118 area/uncut
timing regressions are part of the baseline; successful elaboration or
filtered timing alone must not select a winner.

## Current boundaries and proposed changes

The map-v2 board uses `booth` and ABC `&syn2`; compare candidates with that
same recipe. Its module measurements exclude child logic and disable
high-fanout drivers by default. They rank experiments, not sign off closure.

| Module | Mechanism in the current source | Local change or required contract |
|---|---|---|
| `g6lc_rename` | Older ports write `busy_d`, then younger ports dynamically read it | Read registered busy bits and bypass earlier allocation tags directly; preserve priority, FP-zero handling and writeback ordering |
| `store_buffer` | Insertion rank → inserted positions → pairwise position comparisons → compacted slots | Compute the same predecessor relation directly; preserve the existing insertion rank and arbitrary keep masks |
| `frontend` | Prefix-valid test → branch classification → selected target → fetchability → NPC | Precompute target alternatives before selection; additional fetch latency must carry packet ownership, RAS/checkpoint updates and redirect precedence together |
| `g6lc_iq` | Circular age gates, wakeup, cascaded oldest-ready grants and ack removal | Shared exact circular-order reduction first; a wake/select register must preserve cancellation and ack identity |
| `multiplier` | Partial products → registered sum/correction, aligned operation/TID/valid | Existing two-stage mode needs whole-unit flush/cancel and TID-reuse validation, beyond arithmetic comparison |
| `g6lc_lsq` | Circular age comparisons in unresolved-store and replay gates; youngest matching store scan | Shared circular-order reduction; forwarding/replay pipelining must retain byte masks and load/store ownership |
| `scoreboard` | Dynamic multiport writes with ordered allocation, writeback and commit | Decode ports in parallel and retain explicit collision priority; do not delay architectural visibility independently |
| `instr_realign` | Prefix visits, ordinals, payload gather and carry | Existing prefix rewrite retained; added staging must capture carry address/data/valid and flush together |
| `wt_dcache_wbuffer` | Tag/check/return arbitration updating byte validity and transaction state | Separate per-entry verdicts from payload selection; response and invalidation timing are part of the contract |
| `issue_read_operands` | Register-file read, bypass and resource/ack steering | Any operand register must reserve FU credit and carry exception/TID/valid; cannot independently register result data |
| `alu` | EQ/NE currently use subtraction followed by zero reduction | Direct equality comparator for EQ/NE, leaving arithmetic result behavior intact |

The first aggregate implements the four exact reductions above (rename busy
bypass, store-buffer predecessor relation, shared circular age, ALU equality).
A frontend candidate computes both direct targets before the late taken
selection; mapping must assess its duplicated arithmetic against delay saved.
No new port, configuration field, clock, reset or pipeline cycle is required.
No ISA, DTS, PMU or DFT interface changes result. Existing attributes and
licenses are retained. These are timing candidates until measured.

## Discriminating checks

* Prove circular order against masked subtraction, including equal operands,
  wraparound, width zero and width 32.
* Prove predecessor relations against the original inserted-position formula
  for every insertion position, live count and keep mask. Preserve stable
  order and exclude no input needed by the original formula.
* Compare renamed outputs and next state, especially same-cycle dependencies,
  FP physical zero, allocation/writeback collisions and multiple harts.
* Prove EQ/NE against subtraction-zero and measure branch comparison separately
  from the ALU's overall worst path.
* Use one aggregate elaboration and mapping after these checks; retain before
  and after source identities, recipe, mapped area and timing. Never pair a
  live netlist with an older emitted structural report.

Register insertion in `sv-timing` remains a review candidate. A smaller
structural estimate does not establish control/data alignment or functional
equivalence. Re-pipelining requires an executable boundary contract before
it may be counted toward the 10 FO4 objective.

The existing `MultStages=2` path also requires a liveness companion in `mult`:
flush clears outstanding multiply identities; cancellation follows each
transaction and cannot be undone by clearing a mask or reusing the TID.
The wrapper already has the necessary input ports. Its directed check must
fail on the preceding implementation before it qualifies the correction.

## Internal partitions still needed to pursue 10 FO4

These are candidate boundaries, not estimated stages credited as implemented:

* **Rename:** reserve free tags and checkpoint credit together before admitting
  a group; carry the owning hart, old mapping and group dependencies into the
  map-read/bypass stage. Registering a picked tag alone does not reserve it.
* **Store buffer:** a stationary entry representation can replace payload
  permutation with age selection. Commit must still select the oldest live
  store, forwarding the youngest older matching bytes. Cancellation cannot
  be delayed independently of forwarding eligibility.
* **Frontend/realigner:** a registered packet boundary must carry instruction
  data, base/offset, carry state and prediction metadata together. RAS changes
  and checkpoint allocation follow acceptance, while redirects invalidate
  stale packets. Computing target candidates early is a smaller first step.
* **IQ/operand read:** a registered selection reserves entries until the exact
  acknowledged ports consume them. Acks must not feed selection; cancellation
  and FU credit must be checked for the same transaction. Registering wake
  bits alone changes dependent-issue latency without necessarily cutting the
  age/ack/next-state path.
* **LSQ/write buffer:** preserve per-byte validity, transaction ownership,
  same-cycle updates and youngest-store priority. A pipeline must retain
  invalidation/response collisions and replay obligations, not only addresses.
* **Scoreboard:** local per-entry write decoding can retain existing latency.
  A new writeback stage also needs delayed completion identity and exception
  precedence through commit; an `issued` bit alone is not a generation check.
* **ALU/multiplier:** pipelined arithmetic is admissible only with matching
  operation, result selection, valid and TID lifetime. The multiplier already
  has the fixed-latency seam; the ALU's branch and port-to-port bypass paths
  require an explicit acceptance/forwarding design before adding cycles.

The purpose of these partitions is to reduce serial work while containing
interfaces. Stage counts will be determined from actual stage timing, not
`ceil(structural_cost/10)` alone. They also need an area/IPC comparison:
shortening a path while adding bubbles or reservations is not free throughput.

## Measurement limitation found in the paired run

Historical delay-v39 analysis reports a 72 FO4 multiplier path at the `acc +=
term[k]` fallback. In this target `NS=XLEN/16=4`, so `gen_sum4` is selected
and the fallback `gen_sum_n` is not elaborated. The source analyzer still
includes that generate alternative; the width map identifies live module
types, not live statements within them. Do not remove its cost by retuning a
coefficient or claim hardware improved because of a model-only correction.
A general fix needs constant-generate branch reachability in lowering,
including nested `else if`, unknown conditions, and source-origin tests.
That report remains part of the record. A119's delay-v40 implements the
conservative reachability subset described in `DESIGN.md` and tests unknown,
shadowed, truncated and overflowing cases. On the identical A118 snapshot,
the multiplier maximum becomes 50 FO4 and the design maximum becomes
55.078 FO4 (IQ), with no hardware change.

## A119 initial selection result

Paired map-v2 module studies: IQ 2.922 → 2.403 ns with +3.66% area;
LSQ worst-any 3.141 → 1.958 ns with +1.45% area. LSQ uncut timing also
improves 8.607 → 6.202 ns, while IQ uncut worst-any rises 31.987 →
37.850 ns. IQ reg→reg uncut slightly improves. These distinct path classes
must not be merged into a blanket improvement claim.

The IQ fanout tradeoff motivates a paired OpenROAD placement/repair study
with a common floorplan, constraints and RC, without disabled timing arcs.
The source structural result under delay-v40 remains 55.078 FO4 overall;
LSQ's own worst-any falls 50.751 → 42.5 FO4. These remain budget misses.

The placed discriminator now supports retaining the IQ candidate: worst-any
3.606 → 2.806 ns, reg→reg 3.144 → 2.525 ns, area +3.0%, and repair
buffers 15,174 → 15,095. Both variants have zero reported slew/capacitance/
fanout violations after legalization using a 10% repair margin. Negative
WNS remains; this is pre-CTS and unrouted, not a closed core.

Next high-value boundaries are the IQ count/ack tail, LSQ next-state
updates, and the remaining rename/store/frontend paths. A delayed
acknowledgment or count cannot be introduced independently of capacity and
ownership. The source rewrites here demonstrate that parallel selection
can buy timing without new pipeline latency before those larger changes.

## Retained evidence and tradeoffs

`control-cones-a118-final/result/result.json` records the paired mapping.
Rename and store-buffer reg→reg improve to 2.725 and 2.455 ns, respectively.
The frontend's early targets reach 2.744 ns in the fanout-filtered study at
+11.54% module area, while its uncut graph worsens to 6.292 ns. IQ area
falls 3.94% but its filtered path rises to 2.922 ns. LSQ reg→reg improves
while its boundary path rises to 3.141 ns. These are retained, explicit
tradeoffs needing buffered physical assessment, not Pareto-optimal or
10-FO4-complete results.

The review emit in `result/review-corrected/` uses fresh widths, -O3 and
latency-neutral transforms only. It passes source integrity checks and
whole-core slang elaboration/hierarchy checking, and
does not close the structural budget. Physical numbers in A118 refer to
the production-source snapshot; the emit is a separate review artifact.

The target lint gate passes; the host timing tests and TypeScript type check
pass. Existing upstream notices are preserved, LibreCore edits retain their
declared licenses, and the new verification runner is MIT tooling attributed
to the active contributor. No production compile/link set or ISA/DTS contract
changes were introduced.
