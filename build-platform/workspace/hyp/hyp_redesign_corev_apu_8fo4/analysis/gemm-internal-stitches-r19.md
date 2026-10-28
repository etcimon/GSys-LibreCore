# GEMM internal caller audit and next reduction strategy

This is analysis of the implemented r19 design, not another RTL change.
The fresh `analyze-ai-hyp-r19-stitch-audit` report and full IR reproduce all
r19 path costs and IDs. The analyzer binary and every source/input listed in
the r19 manifest retain their hashes. These checks establish the analysis
basis; they are not a full-build qualification identity.

Artifacts are under
`build-platform/workspace/build/sv-timing/hyp8-src/boards/ai-island/`:

- `analyze-ai-hyp-r19-stitch-audit.{json,ir.json,log}`
- `gemm-internal-stitches-r19-audit.json`

Reproduction uses the r19 `.cmd` arguments, with distinct output names and
`--ir-out boards/ai-island/analyze-ai-hyp-r19-stitch-audit.ir.json`.
The screen remains delay-v44, 5,000 MHz, 20 ps/FO4, 0.2 margin: 8 FO4.

## 1. The stitch numbers are not connected timing paths

Every new internal stitch selects parent path **1297**, a 92.95-FO4 operand
assembly region at `g6lc_ai_gemm_seq.sv:2325–2430`. Its assignments are
`pe_a`, `pe_b`, `pe_a_float`, `pe_b_float`, `pe_v` and indexing temporaries.
None of the listed child-output bridge nets occurs in its RHS expressions.
Source inspection also finds register boundaries between these computations.

| Reported instance | Stitch | Selected child contribution | Why it is not that connected cone |
|---|---:|---|---|
| `i_store_plan` | 132.75 | path 1197, 39.80, ending at the planner's register D | Stripe/beat limits are registered before publication; outputs feed AW/W control, not PE operand assembly |
| `i_span` | 111.25 | path 1183, 18.30, ending at `product_q` D | Products, ends and disjoint facts cross several registers; the returned facts feed reuse/admission state |
| `i_seed_add` | 114.50 | path 1182, 21.55, result exception mux | Result feeds accumulation and C writing, not operand assembly |
| `i_acc_add` | 114.50 | same path 1182 | Same mismatch; this is a feedback/commit consumer |

The cause is visible in
`sv-timing/crates/sv-timing-core/src/lower.rs:181–335`.
`stitch_cross_module_paths` selects representative worst paths per module,
finds child output connections, then adds the selected costs. It does not
prove that the selected parent region reads those outputs, or stop the sum
at an intervening register. `port_bridged` establishes recovered connections,
not end-to-end reachability.

Selection occurs before `compose_reg_to_reg_paths` at `lower.rs:118–122`.
The subsequently composed FP path **2587** is **94.93**, but the stitch still
uses **21.55** from path 1182. Thus these sums are not reliable upper bounds
either. Simply summing the latest module maxima would not repair connectivity.
The external dispatch/top stitch comparisons use the same mechanism and
need the same qualification.

The earlier r19 note calling the 92.95 cone “AR presentation” was incorrect:
it is the operand-format gather. The independent **98.00** path, ID 2690,
does contain AR acceptance, issued-row completion and load-state feedback.
Even that composed region contains several `read_req` fields, so field-level
dependencies and mutually exclusive load modes need checking before treating
its numeric sum as a pin-specific arrival.

The measurement fix should resolve direction and actual bit/field connectivity,
including generate instances, and compose parent→child→parent paths only
through combinational dependencies. A registered output starts a new Q→D
path; it does not append the computation that produced its D input.
Unresolved regions should retain an explicit unqualified status.
Useful package fixtures are an unrelated parent cone, a registered child
output, a real combinational bridge, a parent-input→child-register path, and
a composed path that overtakes the initially selected representative.

## 2. Actual boundaries to optimize

| Boundary traced in RTL | Current evidence | Useful mechanism |
|---|---|---|
| AR/R accepted events → load completion → `state_q` | reported local path 2690: 98.00 | Prepare terminal facts with descriptors; retain completion events |
| Operand-bank bytes + format/group facts → PE inputs | path 1297: 92.95; dynamic gathers cost up to 54.50 per node | Constant wiring and prepared format/group masks |
| `acc_q` / `sum_q` → FP arithmetic → `acc_q` | FP path 2587: 94.93 | Parallel rounded polarities; later, move decode across existing capture edges |
| FP result → C write selection → SRAM write port | Real connection; C-bank steering region 1208 is 16.05 locally | Publish the final word from the existing accumulator register |
| Parent retirement decision → planner cursor update | Parent row-end arithmetic feeds child address-update selection | Prepare the successor descriptor before B |
| Planner credit/stripe → published descriptor | local paths 1197/1198: 39.80/34.60 | Narrow bounded arithmetic; constant transfer-size alternatives |
| Span facts → reuse/admission | Returned disjoint bits are already registered | Do not add another output flop to chase the artificial 111.25 sum |

These are contributing regions, not additive pin-level timing totals.

## 3. First target: prepare load-terminal facts

At `gemm_seq:2631–2658,2710–2750`, completion currently depends on AR offer,
same-edge acceptance, an issued-row increment/compare, and next outstanding
count. The r18 completion latch already solved event loss; keep that ownership
and shorten the predicate feeding it.

Prepare `last_panel_burst` with the existing AR descriptor, alongside its
lane, row/column and row-last fields. Set a retained `all_issued` fact only
when that descriptor is accepted. Reset it at the actual panel transition,
including LA→LB, rather than losing it while a completed load waits for the
seed-product join.

For outstanding count `q`, AR acceptance `a`, and accepted last R beat `r`,
the zero-after-event predicate can be evaluated without an incrementer:

```text
empty_after = (q == 0 && a == r) || (q == 1 && r && !a)
```

This matches `q + a - r == 0` over legal non-overflowing counts, including
simultaneous issue/return: **148 cases** checked for limits 1/2/3/4/8/16.
Combine it with the retained/all-issued-now fact and preserve the sticky
completion join. For the ordered single-ID path, carry the terminal bit
with the existing lane FIFO entry; for split IDs, attach it to the owned slot.

Use scalar `ar_offer`, `r_accept` and completion signals independently of
the packed AXI payload. That also prevents a whole-struct dependency analysis
from pulling AR address/length preparation into a control-only path.
The scalar rewrite alone is not evidence of a hardware timing improvement;
preparing the terminal arithmetic is the substantive change.

If receive writes are subsequently pipelined, completion must wait for the
last bank write, not merely R acceptance. A new receive packet must snapshot
all slot metadata before an ID can be reused. This is the same accepted-event
ownership pattern used for r19's independent W fetch/retire cursors.

## 4. Second target: constant operand packing

The hot nodes at `gemm_seq:2400–2416` compute `off = e << format_shift`,
then dynamically index bytes and B groups. The formats only need fixed
1-, 2- and 4-byte layouts.

Generate the layouts with constant indices `e`, `2*e` and `4*e`, with
elaboration guards preventing out-of-range references. Select the completed
layouts with format facts captured for the job. Keep INT4's two-nibble
packing and partial-element masks intact.

In normal MAC mode, `j_q` advances by `OutCols` and resets at each row.
With the existing power-of-two legality assertion:

```text
((j_q + g) & (OutCols - 1)) == g
```

The group selector can therefore be direct wiring in that mode. A bounded
walk checked **41,280 active lane cases** (OutCols=1/2/4/8/16, N=1..128).
This does **not** transfer blindly to accumulate mode: with OutCols=8,
`j=3,g=0` must read group 3. Keep that selected-group path, preferably
selecting a byte vector once before format packing.

A combinational `g6lc_ai_gemm_operands` leaf would expose this role clearly.
Start with the wiring rewrite. If a register is still needed, stage the
whole operand packet: values, element/column masks, format, first/last and
coordinates. Update integer and floating tag/valid paths together, and count
the new packet as in flight before advancing the issue cursor. The earlier
R8 failures show why changing a latency constant alone is insufficient.

## 5. FP: separate commit, and move rounding before the carry chain

### C publication can reuse an existing register

`mac_acc_next` currently drives both `acc_d` and the terminal C write
(`gemm_seq:1639–1651,3007–3053`). The bank router at `1211–1223` follows the
FP result on the terminal path.

On the last partial, capture a commit token `{valid,row,column,column_mask}`
alongside the existing update of `acc_q`. On the following edge, write C
from that registered `acc_q` and token. The next accumulation may update
`acc_q` on the same edge: the SRAM samples the preceding registered value.
This can cut FP→C-bank routing without adding a cycle to the FP recurrence
or duplicating the result register.

The token must own publication even if issue state has advanced. Move
`c_rows_done_q`, `c_cols_row_q` and `c_cols_done_q` updates
(`4091–4097`) to the actual bank-write event, and include pending commit
tokens in completion/drain decisions. Otherwise stores can see credit before
the corresponding C words exist. This is the seed-read retiming pattern
from r18 applied to the opposite side of the accumulator, with the publication
ownership learned from policy's completion/result join.

The bank router is another independent candidate: consecutive columns and
`OutCols <= PeLanes` imply at most one writer per bank. An asserted one-hot
writer mask can replace its priority loop with masked-OR selection. Compare
data only on an enabled write, and measure the result: earlier cap-window
experiments showed that an explicit OR tree can worsen the reported cost.

### Parallel rounded polarities avoid sum→magnitude→increment

The actual FP critical path includes `sum` (18.15), signed mantissa formation
(14.40), alignment (12.60), `rounded` (10.29), candidate selection and reduction.
The 26-bit width reduction was useful; inserting another interface register
would leave these serial operations inside the next stage.

For aligned signed 26-bit operands A/B, let `s=A+B`, and define:

```text
c0 = A[0] & B[0]
s0 = A[0] ^ B[0]
s1 = A[1] ^ B[1] ^ c0
c  = c0 | (s0 & s1)
H_A = A[25:1]                 // signed high part, represented in 25 bits
H_B = B[25:1]
Q+ = H_A + H_B + c            // round-to-nearest-even(s/2), modulo 2^25
Q- = ~H_A + ~H_B + (2-c)      // -Q+, modulo 2^25
```

`c0` and `s0` cannot both be one. Thus the extra carry plus round-up is
only one bit, and it is known from the low two operand bits before the wide
sum completes. Express each three-term addition as a carry-save pair followed
by one carry-propagate add, as r19 already does for the negative raw sum.
`2-c` is simply the two-bit pattern `{!c,c}`.

For the MSB=24 normalization candidate, select Q+ or Q- using the original
sum sign. Other candidates still use the exact unrounded magnitude.
Keep the existing inexact flag and exception/zero handling.
This moves rounding work beside the raw sum instead of after it.

An independent integer check matched **315,657 cases**, including **31,554**
with MSB=24: exhaustive signed eight-bit pairs, 121 boundary pairs, and
250,000 deterministic random/shifted pairs (seed `0x61920`). Operands were
bounded to the actual decoded-significand range ±(2^24−1). This validates
the identity, not an RTL rewrite or its timing.

For reproducibility, the boundary set was
`{-M,-M+1,-2^23,-3,-1,0,1,3,2^23,M-1,M}`, with M=2^24−1.
Python `random.Random(0x61920)` drew A then B uniformly from [-M,M] in each
iteration; odd iterations additionally arithmetic-shifted A then B by
independent `randrange(32)` amounts. Q+/Q− were masked to 25 bits and compared
with `(abs(A+B)>>1) + ((abs(A+B)&3)==3)`.

If that is insufficient, prepare operand classification/effective exponent
at the existing `sum_q`/seed capture boundaries. A cached accumulator decode
must describe the **rounded canonical FP32 value** committed on that edge.
Retaining extra precision or rounding only at final C storage changes the
ordered FP results.

Deeper FP pipelining needs scheduling: interleave independent output contexts
while preserving each context's K order. Reserve ingress capacity, carry
seed/first/last/format/tags through all alternatives, and preserve contiguous
C publication credit when completions can arrive out of order. Small shapes
with too few independent contexts must stall. A lone output flop cannot
preserve a dependent one-result-per-cycle recurrence.

## 6. Store planner: narrow facts, then prepare the B successor

The current stripe formula is 32-bit subtraction → variable shift → clamps.
Let `C=ChanShift`, `o=address mod 2^C`, and transfer log-size
`s=3` for pairs or `log2(DataWidth/8)` for wide beats.
For C>s:

```text
stripe_beats = 2^(C-s) - (o >> s) - (low_s_bits(o) != 0)
```

Then apply the existing [1,255] clamp. For C≤s the clamped result is one;
for NrChannels≤1 the stripe limit remains the existing constant 255.
The low-bit term preserves unaligned offsets; assuming beat alignment would
change the function.

The identity matched **1,048,512 cases**: every stripe byte offset for C=3..16,
64/128/256/512-bit buses, pair and wide modes. Under the common C=6 profile,
the pair count needs only four bits before clamping. Use constant pair/wide
shifts, bounded counters and explicit generate specialization. Retain an
exact fallback outside the proven parameter envelope.

Path 1197 contains **both** `beat_limit_q` and `stripe_limit_q` at 39.80:
optimizing stripe alone may leave the region maximum unchanged. Pass the
actual caller's `LimN` bound into the helper and narrow captured credit/count
state accordingly, with validated request invariants for N, column and
committed prefix. Do not truncate unvalidated input values. Preserve the
row-complete case, where the live committed-column count can belong to a
different row and its unused subtraction may underflow. Keep the chosen
instance specialization explicit in measurement.

These facts can prepare during CREDIT while credit selection runs in
parallel; address and captured mode remain stable until retirement.
Keep final beat-limit/minimum decisions in separate windows.

The more interesting actual return seam is
`stc_j + retire_words >= n` → `retire_row_i` → child address add/select.
Prepare a successor token containing next address, row base, column and
last-row information while the current burst is active. On B, select the
prepared values rather than performing arithmetic. Explicitly hold B ready
until successor preparation completes; do not assume a minimum response
latency or advance the cursor before B.

Related low-risk follow-ups are preparing AW length/size with the descriptor
and using proven word alignment to narrow the raw W lane selector. Preserve
the independent fetch/retire cursors and full-rate refill: r19's first
raw-buffer version demonstrated the duplicate/refill hazard.

## 7. Execution order and discriminating checks

Recommended order is load-terminal facts, constant operand packing, FP
parallel rounding plus the separate C-commit experiment, then bounded store
planning/successors. Span is lower priority: its returned bits already cross
registers. The shared 20.00-FO4 iterative multiplier and local 18.30 span
stage can be revisited after the larger cones.

Keep each transformation attributable and record the before/after local cone
and genuinely connected consumer. No numerical gain or stage count is
predicted here. A smaller parent module after extraction alone is not success.
The A20 parallel schedule, A33 relocation tiers, A104 constant/one-hot
selection, A134 prepared facts, and the representation/lifetime obligations
in `PIPELINING-RT-LEARNING.md` are the transferable mechanisms.

| Change | Cheapest useful discriminator before broad integration |
|---|---|
| Load flags | Simultaneous AR/R, one-beat final burst, both seed/load completion orders; no early bank-complete or ID reuse |
| Operand wiring | Format/byte-layout miter with valid masks; partial K, INT4 tails and accumulate-group counterexample |
| FP rounding | Existing 37-bit FP reference miter plus large-significand rounding/cancellation boundaries |
| C commit | Back-to-back terminal results, last-job drain, C write/credit conservation and first seeded result; all DPF modes |
| Store successor | Nonzero column slices, original LDC, odd N, lane/stripe boundaries, fast/stalled/error B, stable AW/W and refill witnesses |

Use the established backend/accumulate, cluster, wide, stripe and reuse
gate content through the required isolated remote proxy for new Verilator
work. The uploaded closure must explicitly include the gitignored hyp RTL
and its helpers; a production-only source upload is not this experiment.
Pin the full resolved source closure, parameters and tools.

This pass ran structural re-analysis and the arithmetic probes only.
RTL, configuration, clocks/resets, ABI and functional evidence remain as r19.
No new synthesis/STA or 8-FO4 closure is established.
