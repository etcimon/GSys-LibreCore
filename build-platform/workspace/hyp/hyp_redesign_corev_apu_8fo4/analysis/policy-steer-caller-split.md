# Policy steering: caller contracts and functional timing split

## Implemented in r17

The proposal is implemented in the hyp overlay. Request capture and the
codec/topology join remain separate owned blocks inside `g6lc_ai_policy_steer`;
pure topology is in `g6lc_ai_policy_topology.sv`, and the caller's completion/
telemetry join is in `g6lc_ai_policy_publish.sv`.

One outstanding request owns both computation branches. Shape facts and all
eight code candidates are prepared alongside the ordered codec. Fifteen
constant balanced candidates feed four registered tournament levels; shared
dimension alignment facts and four-bit slots replace the old searches and
truncation. Default service parameters eliminate the product. Custom parameters
use an exact threshold-saturating shift/add window of at most 17 steps.
The wrapper publishes code, events, format and topology together. Subcode
starts from that published record, and acceptance cancels its old work.

Island admission now observes both steering and PMU-owner readiness. This
retains the pulse-only GEMM request contract without an unbounded queue.
The PMU joins completion and result in either order, including one edge.
Engine completion itself is not delayed. Error flush is a failed-completion
pulse rather than the sticky engine error level, avoiding an admission deadlock.

Codec fixes necessary for this lifetime: flush/disable kills f1/f2 valid
tokens; idle f2 values cannot overwrite committed history; warm-address
pipeline fields retain all 64 bits. Assertions use the staged token.

Full board `analyze-ai-hyp-r17.json`:

| Module | Before | r17 structural FO4 |
|---|---:|---:|
| policy_steer | 165.0 | 27.25 |
| policy_topology (new) | included in steer | 27.8 |
| policy_publish (new) | included in top | 8.0 |
| policy_codec | 85.8 | 85.8 |
| policy_subcode | 80.3 | 80.3 |
| island_top | 43.9 | 43.9 |

Relevant broad stitches: top/steer 156.84→59.80, steer/codec
177.64→72.09, steer/subcode 181.18→84.14; new steer/topology 50.05.
These remain structural screens, not verified pin-to-pin STA or whole-island
8-FO4 closure. The codec/subcode cones remain the leading policy work.

Validation: strict Verilator width/latch/multiple-driver/combinational-loop
checks pass. `tb_g6lc_ai_policy_pipeline` passes 5,568 package-reference
topology comparisons, 23 publications, 29 flush/disable cases, all three PMU
completion/result orderings, hysteresis across idle windows and a 64-bit warm
address. It covers default service, 4096-byte service and a custom slot table.
The full hyp `tb_g6lc_ai_island_dma` smoke also passes GEMM and PMU snapshots.
No new formal or physical timing run is claimed.

Reproduce from the repository root under WSL with
`analysis/tools/run_policy_r17.sh lint`, `sim`, or `island` (full relative
path under this hyp overlay). The manifest beside the board records hashes.
Existing source-list seams and `Flist.hyp8_apu` include the new leaves;
the hyp-only bench is guarded by `G6LC_HYP8_POLICY_PIPELINE_TEST`.

## Original r16 analysis

The analysis below is retained as the design rationale and pre-edit evidence.
Its descriptions of defects and proposed files refer to the r16 sources.
All FO4 values are delay-v44 structural estimates, not STA.

## Evidence and scope

The requested `ALGORITHMS-TRANSFORMS` file is not present in the checked-out
`sv-timing` tree or its tracked file inventory. The applicable catalog is
`sv-timing/ALGORITHMS-EXPERTS.md`: A20/A26 (parallel dependency scheduling),
A33 (T0–T3 relocation), A104 (one-hot selection), A134 (registered facts),
and A148 (actual cuts versus projected stage counts). The representation and
lifetime rules in `architecture/PIPELINING-RT-LEARNING.md` also apply.

Board configuration: ir-v5, delay-v44, correction-v5, parser v0.13.5,
5000 MHz, 20 ps/FO4, margin 0.2, budget 8 FO4; full hyp AI source list,
APU parameter map. This matches `analyze-ai-hyp-final8`.

| Locus in `g6lc_ai_policy_steer.sv` | Measured FO4 | Work |
|---|---:|---|
| 335–366 | 165.0 | Stage-3 service-byte calculation and topology publication |
| 277–306 | 119.3 | Serial native clamp, balanced allocation, gain, winner |
| 222 | 92.5 | Column alignment calculation feeding its register |
| 221, 223–224 | 50.5 | Other alignment calculations |
| 335, separate residual path | 40.1 | Non-multiply residue; **not** the module maximum |

The 165.0 cone contains a 64-bit product with a reported atomic cost of about
147.7 FO4. Moving that product into another file or placing a register only
after it does not divide it. The 119.3 cone has real dependencies:
clamp row → clamp column → gain, and group limit → balanced row → balanced
column correction → balanced gain → winner. Independent output blocks alone
cannot remove those chains.

The board's instance records locate:

- `g6lc_ai_island_top.i_policy_steer` at top:1404;
- `g6lc_ai_policy_steer.i_codec` at steer:129;
- `g6lc_ai_policy_steer.i_subcode` at steer:163.

The actual stitched totals, both in final8 and the fresh board, are
156.84 for top/steer, 177.64 for steer/codec, and 181.18 for steer/subcode.
Earlier prose saying these seams were all at most 40 FO4 is not supported by
those JSON artifacts. These stitches are broad module-level structural
estimates: their bridge lists even include unconnected output formals. They
must not be treated as verified pin-to-pin timing arcs. Source inspection
below determines the real consumers.

## What each caller needs

### Island top: a per-job telemetry record

At `g6lc_ai_island_top.sv:1381–1509`, `gemm_start` supplies a one-cycle request.
Both batch-first and batch-last equal that pulse. Opcode is GEMM, balance is
1, samples/zero hints/next-address/prediction inputs are constant zero.
The caller does not use warm addresses or any subcode outputs.

`policy_ready` is only consumed by the unused-signal sink at line 2430:
it does not stall GEMM or keep the request valid. A longer evaluator must
therefore retain that pulse, or change the descriptor handoff. It cannot
silently rely on the caller observing a new busy interval.

On `policy_work_valid`, the top captures code, policy, format, events and
topology together into PMU hold registers. On `gemm_done`, it copies those
holds into sticky MMIO state. Policy no longer controls `gemm_ar_max`; that
register is fixed to `IslandCfg.MaxAROut`.

Consequence: topology evaluation can overlap GEMM execution, but it needs an
atomic publication event for the same job, before or explicitly joined with
job completion. If completion and publication coincide, the present NBA
copy sees the old hold value. A rewritten publisher should handle that join
explicitly rather than assume every legal GEMM lasts longer than the pipeline.
Do not solve late telemetry by delaying architectural GEMM completion.

### Codec: ordered batch history

At `g6lc_ai_policy_codec.sv:129–153,167–212,336–388`, acceptance drives a
three-edge feature/vote/publication window. Hysteresis, dwell, votes,
cooldown, prediction and format boundaries are stateful across requests.
They belong in one ordered owner. Normalization and per-job shape facts
can be computed before or alongside that owner.

The generic steering benches also exercise samples, warm addresses and
format changes. The island's constant inputs justify specialization of that
instance; they do not justify deleting those capabilities from the generic
steering module.

### Subcode: a coherent baseline transaction

At steer:163–181 and `g6lc_ai_policy_subcode.sv:331–344,438–455`, subcode
consumes code, format, dimensions and the complete baseline topology on
`start_i`. It checks eligibility and can cache that record. A new accepted
request cancels previous work. Its ready/busy outputs currently are ignored.

Start subcode on **baseline publication**, with that record's metadata,
not on the codec's earlier work pulse. Preserve cancellation/cache lifetime
through a job tag or a single-outstanding transaction. Cache invalidation
and cancellation must remain ordered with new acceptance.

## Contract defects to repair with the split

1. **Slot-width truncation.** `s1_slots_w`, `t1_slots_q`, and `t2_slots_q` are
   3 bits, while the package topology and `FormatSlotsLog2` entries are
   4 bits and legal through 9. Default INT8/FP8 values 8 become 0; INT4's 9
   becomes 1. All slot pipeline fields must be 4 bits. This is a definite
   source-width defect, not an inferred timing problem.
2. **Publication is earlier than the topology it claims.** `work_valid_o`
   comes directly from codec, while topology free-runs through three
   additional registers from codec code and current metadata. After codec
   changes code, correct-code topology arrives three edges later. Top PMU
   and subcode currently sample the early work pulse. They can capture an
   old/invalid topology or a topology computed with an older code.
3. **Metadata is live rather than carried with topology.** `numfmt_o` reads
   `metadata_q` immediately. A subsequent acceptance can change it while
   earlier topology is still in flight. Shape/format/code/event facts must
   travel with the same valid token.
4. **Flush is not a pipeline-wide cancellation.** Topology stages have reset
   but no flush/disable invalidation. Codec's f1/f2 valid registers also
   need review: flushing its visible state/window alone must not allow an
   older in-flight token to republish after flush deassertion.

The earlier policy-walk result is not evidence that these contracts hold.
These observations are from source and clock-edge analysis; no new policy
simulation verdict is claimed here.

## Recommended functional file boundaries

| Module | Owned function | Input/output contract |
|---|---|---|
| Existing `g6lc_ai_policy_steer.sv` | Small integration wrapper, feature gates, acceptance/flush ownership | One accepted job, one coherent result; disabled configuration inert |
| New `g6lc_ai_policy_request.sv` | Capture request pulse, format/batch boundary, normalized sample, shape facts | Registered request record, acceptance event, optional holding queue |
| Existing `g6lc_ai_policy_codec.sv` | Ordered hysteresis/prediction history | Accepted feature record → code/events tagged to that record |
| New `g6lc_ai_policy_topology.sv` | Pure shape/format topology computation | Request facts and chosen code → topology plus carried job identity |
| New `g6lc_ai_policy_publish.sv` | Join codec result, topology and caller completion; pack telemetry | One result-valid with stable code/policy/format/topology/events |
| Existing `g6lc_ai_policy_subcode.sv` | Optional candidate/cache evaluation | Start only with coherent baseline; cancel by owner generation |

These are proposed files, not empty RTL stubs. A small implementation can
keep request/publish as separately owned blocks in the wrapper initially.
Extract topology first: its pure computation, latency and validity contract
are independently reviewable. Do not move logic across an interface without
also moving the valid, format and job metadata that describe it.

## Highest-value transforms

### 1. Remove the service multiply when the actual parameter domain proves it redundant

The product is used only by:

```
underfilled || (m+n) * rowbytes(min(k, 2**slots), fmt) >= ReadBytesPerCycle
```

It is also guarded by nonzero m/n/k and `(m >= 8 || n >= 8)`.
Thus `m+n >= 9`. If `underfilled` is false, then
`active_k >= 2**(slots-1)+1`, so a format-specific lower bound is:

```
minimum_service_bytes =
    9 * rowbytes(2**(slots-1)+1, fmt)
```

For default `FormatSlotsLog2=0x67788098`:

| Format | Slots | Minimum service bytes |
|---|---:|---:|
| INT8, INT4, FP8 E4M3/E5M2 | 8,9,8,8 | 1161 |
| FP16, BF16 | 7,7 | 1170 |
| FP32 | 6 | 1188 |

Consequently the service predicate is always true in this guarded domain for
every allowed power-of-two `ReadBytesPerCycle <= 1024`. The shipped island
profiles use NoC widths 64 or 512 bits (8 or 64 bytes/cycle); the module
default is 128 bytes/cycle. All qualify. The worst arithmetic can disappear
from those configurations, instead of becoming a many-cycle multiplier.

Implement a compile-time per-format mask derived from the actual parameters.
For other slot tables or read rates, keep an exact fallback. A threshold
table `ceil(ReadBytesPerCycle / rowbytes)` followed by a bounded `m+n`
comparison is another option; a ROM still needs its own measured decode
and output stages. A small sequential product is a slower but simpler fallback.
No dynamic divider should be introduced.

This identity assumes the intended four-bit slot values. Apply it with the
width repair, not as equivalence to the currently truncated implementation.
The lower-bound formula was checked for all 65,535 nonzero k values in each
of seven known formats: 458,745 arithmetic cases. This is mathematical
validation, not RTL equivalence or a measured post-transform FO4 value.

### 2. Replace repeated alignment searches with shared dimension facts

For nonzero unsigned `dim`, divisibility by `2**level` already implies
`dim >= 2**level`. Decode the low four bits once to obtain trailing-zero
count saturated at 4, with an explicit all-zero-dimension guard.
`policy_aligned_log2(dim, cap)` is then `min(saturated_ctz, cap)` for caps
0..4. Register the m/n facts at request capture; reuse them for native and
balanced candidates. This removes four repeated loop/shift/comparison paths.

### 3. Parallel constant candidates instead of the stage-2 correction chain

There are only 15 legal `(row_log,col_log)` pairs with nonnegative values
and sum <= 4. Their gain is constant. Each lane independently checks:

```
row_log <= row_max && col_log <= col_max &&
row_log + col_log <= slots
```

Choose by maximum gain, then maximum total log, then smaller row log.
The last tie rule preserves the existing balanced allocation's orientation.
This selection was exhaustively compared with the current balanced algorithm
for row_max/col_max 0..4 and slots 1..9: 225 combinations, no discrepancy.

After that, preserve the existing native-versus-balanced rule: select
balanced only for greater gain, or equal gain with a greater total log.
Use a constant gain table, independent eligibility lanes and a registered
balanced tournament. Each tree level is an actual potential timing cut;
the number of levels alone does not prove an 8-FO4 stage.

### 4. Relocate shape work before the code is known

Dimension alignment, format capacity, balanced candidate and service
eligibility do not depend on codec's committed code. Evaluate them in
parallel with codec's feature/vote window. For the small set of native
code caps, precompute candidates too; BULK/ATTENTION/SPARSE share one cap
pair. When codec finishes, select the appropriate registered candidate
with a one-hot decode and join its events.

This is useful speculation of a pure decision, not speculative mutation of
hysteresis. It shortens code-to-topology publication while keeping one owner
of history and job identity.

## Proposed schedule and measurement order

An initial schedule is capture → shared dimension/format facts →
candidate eligibility → tournament levels → coherent publication.
Codec runs in parallel; publication waits for both branches for the same
job. Subcode starts afterward. Either serialize whole jobs with retained
input requests, or carry tags through every stage and join queue; the live
pulse-only producer must be handled in either case.

1. Repair slot widths and add token/flush/publication ownership first.
2. Remove the provably redundant service product for the live parameter
   domain; retain and test the generic fallback.
3. Extract topology with shared alignment facts and constant candidates.
4. Register actual winner-tree levels only where the new board calls for it.
5. Re-measure wrapper, topology, codec, subcode and their true connected
   seams together. Do not report a lower wrapper maximum while hiding the
   moved computation in a new leaf.

Focused validation should pair each result token with the package
`policy_topology` reference, cover slot values 8/9, format changes and
flush during every stage, then check top PMU capture and subcode start
against that same token. One caller-level back-to-back/short-job test is
more valuable than another broad DMA smoke that never observes topology.
No sub-8-FO4 or physical timing result is claimed for this proposed design.
