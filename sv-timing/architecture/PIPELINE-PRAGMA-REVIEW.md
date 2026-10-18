# Pipeline pragma applicability and physical validation (A132)

The 10 adjusted-FO4 objective is **0.214 ns** at the recorded Nangate45
calibration of 21.398 ps/FO4. A pragma, a projected cut count, and a successful
reparse do not establish that delay. The required comparison is source RTL
versus emitted RTL with matching specialization, functional observations,
mapping recipe, loading and timing constraints.

The A128 annotations mostly prohibit unsafe cuts. They do not specify
implementable pipelines. `require-contract` plus `no-cut` is a guard;
`protocol` without an accepted cut and consumer alignment is also not a
pipeline implementation.

## Findings corrected in this pass

* An explicit `cut-ok absent` could resolve to `Allowed(None)`, permitting an
  uncarried register. Rejected contract facts now forbid cuts, and a required
  contract needs a resolved, unambiguous domain.
* A vector valid could be truncated into the emitter's scalar valid flop.
  Admission now requires resolved one-bit input/result valids and resolved
  carried widths. This matters to the LSQ's multi-port AGU declaration:
  `addr_valid_i` is a vector, not one operation. No cut is enabled there.
  `ready=` is rejected explicitly; it is not silently ignored.
* `latency Cfg.Stages base=Cfg.Stages` has no spare stage under any value.
  Increasing the parameter increases both sides. The old suggestion to
  “set the parameter to base+1” could never authorize that contract.
  Diagnostics now say an RTL boundary and consumer-depth change are needed.
  Qualified names require exact parameter-map keys, without a final-member
  fallback to an unrelated parameter.
* Safe conditional integer localparams now participate in generate
  reachability. For example, `SB = Cfg.Stages > 2 ? 8 : 16` can prove which
  sum branch is live. Both arms must remain in the bounded nonnegative int
  subset; unresolved conditions, truncation and overflow still refuse pruning.
  This is measurement correction (`delay-v42`), not hardware timing credit.
* The old board's `start_net`, `end_net` and trace describe **reg→reg**,
  while `worst_any_ns` can describe another boundary. Those fields cannot
  identify the worst input cone. The isolated review now reports each of
  in→reg, reg→reg and reg→out separately, with full path reports.
* Three `no-cut` targets were not signals: `gen_cmo_local` is a scope label,
  and `wt_dcache_mem` has no `wbuffer_data_o`. The comments now identify
  `cmo_req_done` and `rd_data_o`; `fpu_gen` is replaced by `result_o`.
  The write-buffer comment distinguishes
  its exported registered entries from the load-byte merge in dcache memory.

Analyze JSON now includes `pipeline_contracts` regardless of whether the
worklist attempts InsertReg. It reports the resolved facts, bundle-shape
issues, and unbound `no-cut` targets. Counting refusal events was not a valid
coverage census: several annotated modules had no attempted cut and were
incorrectly shown as having no contract.

The audit finds **53 annotated modules among the 56 measured over budget,
12 declared domains, and zero enabled cut anchors**. The three unannotated
modules are `exp_backoff`, `rr_arb_tree` and `fpnew_top`. The LSQ AGU,
checkpoint-stack pushes and instruction-queue input valids are vector
bundles; their current declarations do not qualify for scalar-stage emission.
The remaining queue and execution changes in the table are implementation
work, not latent improvements waiting for a flag.

## Highest measured cones: the implementation each boundary requires

These are the historical A130/A131 live module study readings, not new
paired measurements or post-route closure. They prioritize work; comments
alone do not change the readings.

| Module | Adjusted FO4 | Required implementation before a new cut is meaningful |
|---|---:|---|
| `store_buffer` | 173.0 | Split accepted-request processing from queue permutation; reserve capacity on acceptance, retain pending stores in forwarding, and apply commit/cancel/flush to both pending and resident entries. |
| `wt_dcache_wbuffer` | 132.3 | Capture a complete deferred-write/forward bundle; preserve same-cycle byte supersession against younger stores before retiring a fixup. ACK, tag lookup, invalidation and response state must agree. |
| `frontend` | 128.2 | Separate prediction from fetch redirection with a predicted next-line request and later correction. Carry PC, hart, prediction metadata and redirect epoch; replay/kill must invalidate outstanding requests. |
| `g6lc_rename` | 125.9 | Reserve free tags/checkpoints when accepting a group; carry intra-group dependencies into map-write/bypass. Restore and committed-map updates must cover pending allocations. |
| `instr_realign` | 119.0 | Stage a complete output packet with hart, PCs, instruction/valid vectors and leftover state. The scalar input valid alone does not describe the vector output or its downstream acceptance. |
| `multiplier` | 118.3 | Split arithmetic inside the existing stages, including the CLMUL and operation/ID paths. Carry-save rows are one bundle; the last addition and output select remain separate physical limits. |
| `g6lc_iq` | 112.3 | Reserve selected entries while a registered issue packet awaits ACK. Wakeup, cancellation, slot reuse and count updates must operate on reserved as well as unselected entries. |
| `g6lc_ooo_dispatch` | 100.8 | Capture accepted lane records including struct-member transaction IDs and register tags; side-table installation must precede any consumer that reads them. |
| `wt_dcache_mem` | 96.6 | Stage per-byte forwarding selection together with the matching cache response, address, validity and exceptions. A late fixup cannot overwrite bytes superseded by a younger store. |
| `scoreboard` | 93.7 | Stage complete writeback events or issue packets while preserving ownership through cancel/flush and ID reuse. Delaying the owner's state array alone is unsafe. |
| `g6lc_lsq` | 91.6 | Independent AGU lane bundles and capacity reservations; pending addresses must participate in forwarding, violation/replay, completion and commit decisions. |
| `issue_read_operands` | 90.8 | Capture the accepted FU bundle and reserve its resource/writeback slot; operand bypass and ACK must use the same instruction age. |
| `alu` / `aes` / `branch_unit` | 90.5 / 83.7 / 67.7 | Pipeline at the owning execute-stage protocol, with writeback arbitration and branch-resolution latency represented explicitly. These datapaths do not expose an independent result handshake. |

The remaining counters, predictor tables, FIFOs, TLBs and cache state machines
need the same distinction between an operation boundary and a recurrence.
`stage-input` remains reserved, not implemented. Renaming `no-cut` to
`cut-ok` cannot supply reservation, backpressure or replay semantics.

## Arithmetic experiment and acceptance criteria

The multiplier experiment keeps the public three-cycle interface. It
registers smaller unsigned product tiles, compresses the aligned rows plus
the two's-complement correction in the middle stage, and performs one final
carry-propagate addition. The companion operation, valid, ID and carry-less
results retain their existing stages.

The compressor identity is
`a+b+c = (a^b^c) + (((a&b)|(a&c)|(b&c)) << 1)` modulo the result width.
The existing sign correction is included as `~corr_sh + 1`, avoiding a
second wide carry-propagate operation after the register.

The isolated runner compares `b7e9615a0` and the candidate on the **same**
configuration and recipe. It also accepts `multiplier__svt.sv` as a third
variant, measuring and simulating the actual emitted file. Tests compare
all supported operations against the one-stage multiplier and exercise
cancellation at every pipeline age, mask removal and transaction-ID reuse.
Source-only surface variants cover RV32, RVB disabled, and two stages.

Final validation is `fo4-a132-emitted`, pulled to
`build-platform/workspace/build/sv-timing/precompute-a132/emitted/`.
The intermediate `pair-c`, `pair-d` and `tile-place` records retain the
rejected candidates and the initial placement discriminator.

| Paired Nangate45 placement/repair | Original three-stage | Tiled RTL | Actual corrected SV |
|---|---:|---:|---:|
| Worst data arrival (ns) | 2.634 | **2.215** | **2.298** |
| Adjusted FO4, recorded 21.398 ps calibration | 123.1 | **103.5** | **107.4** |
| Worst reg→reg arrival (ns) | 2.139 | 2.145 | 2.125 |
| Repaired area (µm²) | 52,164.730 | 52,886.117 | 52,884.793 |
| Repair buffers | 2,385 | 2,404 | 2,400 |
| Disabled arcs | 0 | 0 | 0 |

The tiled RTL is retained: **15.9% lower worst arrival at +1.4% area**,
with unchanged cycle count and interface. Corrected SV preserves behavior
and retains a **12.8%** placed gain over the same baseline; it is 3.7% slower
than the direct source in this placement. The tool made one latency-neutral
SplitAssign and no InsertReg. Reparse, joint elaboration, mapping and both
runtime witnesses pass. This validates the emitted file, not a predicted
IR gain. Source and emit both still estimate 59.0 structural FO4 in the
isolated analysis; neither metric closes 10.

All three placement runs report no slew/capacitance/fanout violations.
They are pre-CTS, unrouted module studies and still have negative WNS at
the requested clock. Unbuffered timing was worse for the tiled candidate
(3.343 versus 2.655 ns worst); the favorable decision depends on the paired
placement/repair evidence. This is not a whole-core timing improvement.

The final run covers six arithmetic configurations/variants at 300,000
cycles each, all with nonzero output counts and zero errors. The baseline,
tiled source and emitted multiplier each pass 39 lifetime checks, including
cancellation at every pipeline age and subsequent TID reuse. Package tests:
373 pass. The independence scanner still reports existing host references
in unchanged test/tool content.

The host's live-RTL run refreshed widths but left `MultStages=2` in the old
parameter map. The isolated review explicitly binds the measured three-stage
configuration and peels the known `dut` prefix from elaborated wrapper widths.
Reusing a stale global parameter map is not valid pipeline evidence.

An operand-capture fourth-stage trial was rejected: it moved the product
cone behind a register without partitioning it, increasing the filtered
reg→reg delay to 2.532 ns. It is not exposed as a supported configuration.

Timing/SoC note: the retained RTL uses the existing `MultStages=3` option,
same clock and asynchronous active-low reset, and carries the same operation
identity and CLMUL state. There are no ISA, DTS, port, trace-latency or PMU-event
changes. The extra arithmetic state and buffers cost area and clock activity;
power, full-core regression and routed sign-off were not measured in this
surface review. Upstream notices and contributor attribution are preserved.

## Reproduction

From the host repository:

```text
python verif/regress/remote/run_fo4_control_review.py --snapshot <snapshot> --baseline b7e9615a0 --profile multiplier
```

Run that snapshot through the existing testharness proxy with
`CONTROL_MODE=mult-pipeline`; `CONTROL_PLACE=1` adds paired Nangate45
placement/repair with no disabled timing arcs. The runner preserves source
hashes, mapping recipes, separate path reports, mapped area and witnesses.

Then run `--analyze-results <pulled-result-directory>`. This corrects the
captured multiplier using its elaborated widths, exact three-stage parameter,
and the normal package parser. Upload the emitted multiplier along with the
same source snapshot for the third comparison. An emitted reparse or a
structural reduction alone is not the acceptance condition.

## A140 — step 1 of the A139 plans: three latency-neutral rewrites landed

The first rung of `architecture/RTL-PIPELINE-PLANS.md` (remove avoidable logic
depth before adding protocols). Three `svt-plan: reshape` items became RTL,
each proven against the previous revision and measured in one paired run
(`fo4-a140-step1h`; the forwarding alternative in `fo4-a140-step1g`):

* **`core/cache_subsystem/wt_dcache_mem.sv`** — the per-byte "lowest matching
  entry wins" forwarding scan over `WbufferAllDepth` entries is a balanced
  tree of the same associative merge; data and user bytes travel in the leaf
  tuple. Proof: the live block is extracted by text into a standalone module
  and proven combinationally equivalent to the previous serial scan (SAT
  miter) at five geometries (depth 16/8/4/2/1, 8- and 4-byte lanes, 8/4/1
  user bytes). The prefix-one-hot + AND-OR form was measured as well; it is
  area-neutral but gains far less, so the tree is retained with its area cost
  recorded.
* **`core/frontend/g6lc_bp_loop.sv`** — the row-local training the A135 emit
  proved is now the shipped RTL (`row-local-applied`). Matched-state
  equivalence with the indexed form at 16×4, 8×1 and 32×2; the independent
  per-row model passes (2 seeds, 240k checks each) and its negative control
  still fails.
* **`core/frontend/g6lc_loop_buffer.sv`** — `base + (cursor << ALIGN)` only
  carries into the high slice as +0/+1, so the +1 alternative is registered at
  arm and both high compares run beside a `IDX_W+ALIGN`-bit add; the carry
  picks the compare. Exact modulo 2^VLEN (wrap included), two invariant
  assertions (registered increment; split compare == reference) on in the
  witness. Six cycle-exact side-by-side runs (3 geometries × 2 seeds, 300k
  cycles) and the 6-step output miter pass. Unlike A136, no wide select is
  added to the hit path — the registered value feeds a compare, not a mux.

| Module (isolated, Nangate45, paired placement/repair, no disabled arcs) | Worst arrival | Reg→reg | Repaired area | Buffers |
|---|---:|---:|---:|---:|
| `wt_dcache_mem` forwarding tree (retained) | 3.154 → **2.333 ns** (-26.0%) | 0.425 → 0.660 ns | 8861 → 11610 µm² (+31.0%) | 994 → 1057 |
| `wt_dcache_mem` prefix one-hot + AND-OR (alternative, not retained) | 3.154 → **2.937 ns** (-6.9%) | 0.425 → 0.490 ns | 8861 → 8458 µm² (-4.5%) | 994 → 1012 |
| `g6lc_bp_loop` row-local training | 1.911 → **1.459 ns** (-23.7%) | 1.353 → 0.961 ns | 17777 → 15595 µm² (-12.3%) | 759 → 499 |
| `g6lc_loop_buffer` bounded address add | 1.824 → **1.507 ns** (-17.4%) | 1.824 → 1.507 ns | 7412 → 7807 µm² (+5.3%) | 185 → 197 |

* **`core/scoreboard.sv`** (`fo4-a140-sbhead3`) — the per-hart head scan
  takes the A136 ROB form: candidates in absolute slot order split by a
  thermometer mask at the commit pointer, two lowest-set isolations, direct
  slot encode; the rotation crossbar and the pointer add are gone (hdist still
  subtracts, as before). The scan block is extracted by text from both
  revisions into standalone modules and proven combinationally equivalent on
  (slot under head_valid, validity, PC) at 32×2, 16×1, 8×2, 64×4 and 32×1
  entries×harts (the 64×4 problem: 14 M variables). The serial T6b-1
  reference assertion stays on. Isolated placement is not available for this
  module (type-parameter heavy); it is read on the whole-core board.

* **`core/branch_unit.sv`** (`fo4-a140-sumeq`) — the JAL/JALR target check
  `jump_base + imm != predict_address` is a carry-free test: `a + b == c`
  iff `a ^ b ^ c == ((a & b) | ((a ^ b) & ~c)) << 1` (the carry each bit
  would need must reproduce the majority recurrence), with the JALR LSB
  clear handled by comparing bits [VLEN-1:1] with the real carry `a0 & b0`
  into bit 1 and requiring `c[0] == 0`. The adder still produces the
  redirect address; only the mispredict decision loses the carry chain.
  SAT-proven against the adder compare at 64 and 32 bits, both LSB modes;
  a translate_off witness compares both forms every cycle.

Proof record: `dmem-fwd-eq-16-8-8`, `dmem-fwd-eq-8-8-4`, `dmem-fwd-eq-4-4-1`, `dmem-fwd-eq-2-8-8`, `dmem-fwd-eq-1-8-8`, `loop-eq-16-4-1`, `loop-eq-8-1-0`, `loop-eq-32-2-1`, `loop-model-candidate-1`, `loop-model-candidate-17`, `loop-negative`, `lbuf-sbs-8x64-1`, `lbuf-sbs-8x64-17`, `lbuf-sbs-4x32-1`, `lbuf-sbs-4x32-17`, `lbuf-sbs-6x128-1`, `lbuf-sbs-6x128-17`, `lbuf-miter-6`. Whole-core board after
landing: re-measured below when the route completes (the A136 loop-buffer
candidate improved in isolation and lost on the board; this one must be read
there before the gain is claimed for the core).

## A138 — store buffer input stage: functionally proven, rejected on timing

The first true pipeline stage attempted on the board's worst cone
(`core/store_buffer.sv`, 173.0 adjusted FO4), as a config gate
(`CVA6Cfg.StqInputStage`, default 0): the store request, the commit pulse, the
flush, the cancel mask and the program-age anchor captured one cycle before the
speculative-queue permutation, which then reads registers only. The core state
is the unstaged design's state delayed by one cycle; the current cycle's
outputs are derived from the registers — the staged store forwards at its
program-age position, the head a staged commit pops is architectural, entries
the staged flush / cancel remove are masked, `ready_o` / `commit_ready_o` /
`no_st_pending_o` / `store_buffer_empty_o` count the staged items, the RVFI
address and the commit-head assertion follow the head the commit port sees
(the slot after a staged pop or the staged store, whichever is older, skipping
entries the staged mask squashes).

**Functional evidence (`fo4-a138-stq18`)** — a three-instance shift witness
(`tb_sb_stage`: staged RTL; previous RTL fed the staged inputs one cycle late;
previous RTL live), g6lc64_ooo geometry, 300k cycles each:

| run | pushes | commits | cancel cycles | flushes | forwarded bytes | errors |
|---|---:|---:|---:|---:|---:|---:|
| plain seed 1 | 172,439 | 74,442 | 40,308 | 7,005 | 88,348 | **0** |
| plain seed 17 | 172,373 | 74,354 | 40,143 | 6,988 | 89,588 | **0** |
| cbo seed 1 / 5 | 166k | 54k | 41k | 7k | 118k | **0** |

Checked every cycle: queue / pointer / count / commit-queue state equal to the
delayed reference; `req_port_o` identical; every reference-forwarded byte
forwarded with the same value (plain mode: no stall substitution at all);
extra bytes only from the committing head, a commit-queue entry the reference
had already drained, or the cycle after a cancel / flush; the live page-offset
match a superset; readiness and pending flags conservative; the RVFI address
names the entry popped next cycle. A mutant that drops the staged store from
forwarding is caught. With the gate off the live RTL is cycle-exact against the
previous revision (`tb_sb_sbs`, 2 × 400k cycles, 0 mismatches). Six witness
and head-view defects were found and fixed on the way (the commit port can
retire a store that is still staged; squashed entries must not be the head; a
shared random memory handshake let a CBO response coincide with a grant; the
R3a sticky terms are not comparable across the two timings).

**Physical evidence (same Nangate45 flow, no disabled arcs) — rejected:**

| Store buffer (g6lc64_ooo, isolated) | Stage off | Stage on |
|---|---:|---:|
| Placed worst arrival | 3.964 ns | **4.316 ns** (+8.9%) |
| Placed reg→reg | 3.964 ns | 4.316 ns |
| Repaired area | 75340.5 µm² | 81456.1 µm² (+8.1%) |
| Filtered module study | 3.242 ns | 3.655 ns |

The isolated placed baseline shows the worst path was already register-to-
register (the permutation itself), not the input cone the module board's
`any` figure pointed at. Input staging cannot shorten that, and the derived
current-cycle views (two-pass forwarding with age compares against the staged
store, the squash-aware head) add to the paths that remain. The RTL and the
config field are reverted; the complete trial (RTL, config plumbing, witness)
is kept as `trials/a138-store-buffer-input-stage.patch`, and the `stq` review
profile remains in the runner. Lesson recorded in PIPELINING-RT-LEARNING §4a:
measure the *placed* split of the target before choosing an input stage.

## A137 — checkpoint stack: slot-order search rejected; live board flow fix

**Live board after A134–A136 (`timings sta-rtl --remote --map-recipe
streamed`, Nangate45, fanout-filtered unplaced module study, per-module map
content-hashed):** `instr_realign` 119.0 → **50.8** adjusted FO4 (2.547 →
1.088 ns), `g6lc_bp_statcor` 83.7 → **33.7** (1.791 → 0.721 ns), `g6lc_rob`
82.4 → **69.8** (1.764 → 1.493 ns), `multiplier` 118.3 → **97.3** (2.531 →
2.081 ns). The top of the list is unchanged (`store_buffer` 173.0,
`wt_dcache_wbuffer` 132.3, `frontend` 128.2, `g6lc_rename` 125.9); 56 of 73
measured modules remain over budget; budget-equivalent 216 MHz.

**Loop buffer reverted.** The A136 registered-expectation form improved the
placed/repaired pair (1.824 → 1.493 ns) but read **worse on the live board**:
72.3 → 94.9 adjusted FO4 (1.548 → 2.030 ns, 9 cells, ending at the new
expectation register). The new form moves the critical path onto late mux
selects with 64-bit fanout; `repair_design` buffers them in the placed flow,
the unbuffered board does not. The two views disagree, the board is the
acceptance metric, so the RTL is restored to its A135 state and the result
is recorded as a flow-disagreement counterexample: retention needs both the
paired placement and the live board to improve.

The A136 ROB form was carried to `g6lc_bp_ckpt`'s oldest-live search (the
same rotate → lzc → `head + off` shape). Functionally it held: matched-state
equivalence at 1×32×4 (shipped), 2×8×2 and 2×16×4 (2×64×4 did not finish in
15 minutes — inconclusive), the seven directed scenarios and seven randomized
model runs (20k cycles each) with the rotated-reference assertion on, and a
reference mutant reported. Equivalence first exposed that the lzc-based form
reads `head + DEPTH-1` on an empty bank; the candidate reproduced that so the
unused clear-side payload ports stayed identical.

Placement rejected it (`fo4-a137-ckpt5`, same flow, no disabled arcs):

| Checkpoint stack (1×32×4) | Baseline | Candidate |
|---|---:|---:|
| Placed worst arrival | 3.410 ns | 3.348 ns |
| Placed reg→reg | 2.334 ns | **2.715 ns** (+16.3%) |
| Repaired area | 29262.7 µm² | 29070.3 µm² |
| Filtered module study | 2.356 ns | 2.241 ns |

The consumer here needs both the slot (clear-side read) and the ring offset
(`head_d = head_q + off`), so the slot-order form adds a subtraction before
the pointer add and gives back what the removed rotate saved. The ROB only
needed the slot. The file is restored; the profile stays as the counterexample.

The whole-core live board re-measure after A134–A136 first failed in the
flow: the remote yosys script is a bash double-quoted word, and the lean and
hierarchical recipes' `async2sync t:$aldff t:$aldffe` was expanded by the
shell (`set -u`: "aldff: unbound variable"). `bashDoubleQuoted` now escapes
only `<attr>:$<type>` selectors (shell paths such as `$RUN` must still
expand); `test/bash-quoted.test.ts` pins both directions.

## A136 — further worst-arrival modules without interface cycles

The three highest measured cones (`store_buffer` 3.702 ns, `wt_dcache_wbuffer`
2.831 ns, `frontend` 2.744 ns) still need the stateful boundaries of §A132
(input staging with acceptance accounting; a next-line prediction change).
Their earlier bypass trials lost placed timing and remain rejected. This batch
continues down the list with two latency-neutral changes, paired against
`2a5ee192b` on the same Nangate45 flow with no disabled arcs
(`fo4-a136-pair3`, `fo4-a136-rob3`).

**`g6lc_loop_buffer`: registered expectation address.** The lookup and fill
compares read `base_q + cursor<<ALIGN` through a 64-bit adder every cycle.
One register now tracks that sum for the active cursor (capturing and armed
are mutually exclusive; every return to armed passes through the close, which
resets replay), updated from one candidate sum formed off registers in
parallel with the compares. Evidence: six cycle-exact side-by-side runs
(8×64, 4×32, 6×128; 300k cycles each; hits, fills, arms, wraps and flushes
all exercised; the new invariant assertions on), a 6-step output miter from
reset (a 12-step bound did not finish in 25 minutes and is recorded as
inconclusive, not as a pass). A first two-register form failed the fill
invariant in the arm+consume corner and was corrected before measurement.

| Loop buffer | Baseline | Candidate |
|---|---:|---:|
| Placed worst arrival | 1.824 ns | **1.493 ns** (−18.1%) |
| Repaired area | 7411.6 µm² | 8309.6 µm² (+12.1%) |
| Buffers | 185 | 251 |

**`g6lc_rob`: head re-anchor in absolute slot order.** The post-free valid
vector was rotated by the head (a dynamic barrel shift) before an
incrementer-based find-first and a final add. The stops are now formed in slot
order, split at the registered head into two log-depth lowest-set searches,
and the found slot is the head. Exact for power-of-two depth; the rotated walk
stays under `translate_off` as a per-cycle reference assertion. Evidence:
matched-state equivalence at 8/16/32 entries, both directed `tb_g6lc_rob`
scenarios with the reference assertion quiet, and a textual mutant of the
reference that the assertion reports.

| ROB (32 entries, isolated) | Baseline | Candidate |
|---|---:|---:|
| Placed reg→reg | 2.049 ns | **1.568 ns** (−23.5%) |
| Placed worst arrival | 2.049 ns | 1.994 ns (−2.7%; input tid-compare cone remains) |
| Repaired area | 33524.0 µm² | **32855.8 µm²** (−2.0%) |
| Filtered module study | 1.852 ns | 1.301 ns |

Whole-core slang elaboration of the retained RTL passes
(`fo4-a136-final-elab`); both modules' pragma audits have no rejected or
unbound targets. These are pre-CTS module results on an isolated flow; the
whole-core board is not re-measured here and 10 adjusted FO4 remains open.

## A135 — pragma-driven row-local emission on the loop predictor

`core/frontend/g6lc_bp_loop.sv` now carries only a comment:
`// svt-pipe: row-local train index=uidx rows=NR_ENTRIES banks=mem_q:mem_d max-rows=32`.
`sv-timing correct --emit --real-cut-feeds` prepares the per-row form,
reparses it and emits it as `g6lc_bp_loop__svt.sv`; production RTL is unchanged.

| Loop predictor, Nangate45 | Source | sv-timing emitted |
|---|---:|---:|
| Placed worst arrival | 1.911 ns | **1.410 ns** (−26.2%) |
| Placed reg→reg | 1.353 ns | **1.066 ns** |
| Repaired area | 17776.779 µm² | **16551.320 µm²** (−6.9%) |
| Filtered module study | 1.743 ns | 0.856 ns |

Three matched-state equivalence geometries pass; the new independent model
(`verif/tb/core/tb_g6lc_bp_loop_emit.sv`) passes seeds 1/17 on both variants
with identical coverage counts and fails under `+oracle_negative`. Placement
reports no electrical violations and no disabled arcs. At 21.398 ps/FO4 the
emitted placed worst is ~65.9 adjusted FO4: better, not closed. The structural
IR headline stayed at 18.6 FO4 — the gain is visible only in the reparsed emit
and the physical comparison, which is why the tool reports the prepared source
separately from the correction ledger.

## A134 — further control/state files

This batch compares immutable snapshots against `62c00081a`. It retains two
implementations and rejects two others after placement. Interfaces and cycle
latencies are unchanged; the new realigner state is a redundant representation
of an existing carry entry.

### Retained: realigner continuation state

In `core/fetch_B/instr_realign.sv`, an accepted split instruction can start
only at the last available halfword. For the supported power-of-two RVC
geometry its PC is the incoming window's upper address bits concatenated
with the last-halfword offset and the original bit 0. This replaces a late
selected address sum at carry capture.

The same accepted event records `carry_pc + 2` in a per-hart continuation
bank. The next window compares its address against this registered value,
removing the increment from the carry-state feedback path. The invariant is:

```text
carry_valid[h] => carry_next[h] == uint64(carry_pc[h]) + uint64(2)
```

Kill and flush remain inert on both banks. The 64-bit successor preserves the
old distinction between full-width wrap and VLEN<64 overflow; it must not be
truncated back to VLEN. Other geometries and RVC-off use the original path.
The companion bank has a no-cut guard and a simulation-only invariant.

Five surface configurations cover 32/64/128-bit fetch windows, 1/2/4 harts,
32/64-bit virtual addresses, reduced output-slot capacity and RVC disabled.
Each runs 500,000 cycles with no mismatches. The witness now compares the
packet **at the consuming edge**, as well as settled outputs after the edge.
A deliberately truncated successor fails that interface witness even with
RTL assertions disabled (`fo4-a134-realign-final`).

### Retained: statistical-corrector row-local training

`core/frontend/g6lc_bp_statcor.sv` previously selected a counter/tag/valid row,
computed its update, then decoded a write back into the table. Each row now
prepares its own next value and is selected by the update index. This removes
the read-mux → train → write-decode feedback chain. Prediction lookup latency,
tag ownership, saturation, weak-row takeover, strong-owner decay and flush
priority are unchanged.

Matched-state equivalence passes for 64 entries/4 slots/RVC, 8 entries/1 slot/
no RVC, and 24 entries/4 slots (including out-of-range index encodings).
The existing independent counter model passes both slot/RVC variants and its
negative controls. The isolated timing wrapper uses the production geometry:
64 entries, four slots, eight tag bits, VLEN=64 and RVC enabled.

### Physical decisions

Nangate45 paired placement/repair, identical constraints per pair, no disabled
timing arcs, and no reported slew/capacitance/fanout violations:

| Candidate | Worst arrival, ns | Reg→reg, ns | Repaired area, µm² | Decision |
|---|---:|---:|---:|---|
| Realigner continuation state | **2.977 → 2.257** | **2.357 → 1.717** | **3348.940 → 2771.986** | Retain: −24.2% delay, −17.2% area |
| Statistical corrector row-local training | **1.622 → 1.095** | **1.178 → 0.578** | 9543.017 → 10749.061 | Retain: −32.5% delay, +12.6% area |
| Rename indexed map-read bypass | 2.964 → 3.105 | 2.964 → 3.105 | 241050.000 → 241028.453 | Rejected; RTL restored |
| Store-buffer snapshot bypass | 4.086 → 4.801 | 4.086 → 4.801 | 76140.633 → 76630.344 | Rejected; RTL restored |

Using the recorded 21.398 ps calibration, the retained **placed** worst delays
are approximately **105.5 adjusted FO4** for realign and **51.2** for statcor.
These remain pre-CTS, unrouted module studies with negative WNS at the requested
clock, not whole-core timing closure.

The historical fanout-filtered module reading also improves: realign
2.547 → 1.088 ns (119.0 → 50.8 adjusted FO4), and the isolated statcor wrapper
1.548 → 0.773 ns (72.3 → 36.1). Do not substitute those filtered figures for
the placed figures. Rename and store buffer looked better under that filter
but worsened after placement; four rename equivalence configurations and a
400,000-cycle store-buffer comparison passed, so they were rejected for
physical timing, not functionality.

Artifacts are under `build-platform/workspace/build/sv-timing/precompute-a134/`:
`map-a`, `surface-a`, `realign-final`, `place-realign`, `place-rename`,
`place-store`, and `statcor/result`. Replay the archived `inputs.tar.gz` for
the rejected trials; current production RTL intentionally no longer contains
them. The runner's `boundary` and `statcor` profiles capture sources, tests,
recipes, netlist hashes and results.

The pragma audit resolves all three initially changed modules with no unbound
targets. The new cached-state representation is implemented directly in RTL;
it is not a carry-save pair and is not falsely declared as one. The A133
preprocessor still requires a dedicated, validated rule before it can infer
this state transformation automatically.
Whole-core slang elaboration/hierarchy checking of the final retained RTL
passes (`fo4-a134-final-elab`).
The standard `verify --lint --target g6lc64_ooo` gate also passes both checks.
The broader local `verify --lint --synth` attempts (selected OoO target and
default targets) were stopped after their synthesis phase did not finish
within this surface review. They are incomplete, not passes. The configured
`opt -fast` smoke has documented scaling problems on large cores; the isolated
paired synthesis/STA/placement results above completed and are retained separately.

SoC/validation scope: retained behavior is gated by the existing RVC/geometry
and predictor configuration. No new interface, clock, reset, ISA, DTS,
trace-latency or PMU event is introduced. The continuation flops use the existing
clock and asynchronous active-low reset; no RAM was converted to flops.
Power and full-core software regression are outside this surface review.
