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
