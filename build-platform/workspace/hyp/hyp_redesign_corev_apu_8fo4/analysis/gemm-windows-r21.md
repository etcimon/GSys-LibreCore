# GEMM r21 — sign-magnitude FP, commit token, registered facts

Continuation of r20 on the same frozen analyzer
(`hyp8-src/inputs/r20-sv-timing.exe`, delay-v45 / ir-v6). Matched measurements:

| Module | r19 | r20 | r21 |
|---|---:|---:|---:|
| `g6lc_ai_gemm_seq` | 98.00 | 73.50 | **61.50 FO4** |
| `g6lc_ai_gemm_fp32_add` | 94.93 | 94.93 | **75.00 FO4** |
| `g6lc_ai_gemm_store_plan` | 39.80 | 39.80 | **28.50 FO4** |
| `g6lc_ai_gemm_span` | 18.30 | 18.30 | 18.30 |

Final board: `boards/ai-island/analyze-ai-hyp-r21.{json,ir.json,log,manifest.json}`.
The manifest records the analyzer, all 65 closure files, remote results and
runtime identities. Source archive `analysis/tools/zips/gemm-r21-final2-closure.zip`.

## Transforms

**FP32 adder — sign-magnitude arithmetic.** The reference floors a negative
significand's arithmetic right shift, which equals `-(magnitude >> d) - sticky`.
Three magnitude sums run in parallel (`X + Y + corr`, `X - Y - corr`, and its
negation as a carry-save pair) with the corrections folded into carry-ins; a
borrow selects the magnitude and sign. The overflow rounding is computed from
the operand halves beside the main sum. The sticky uses constant-width prefix
ORs selected by the shift amount. Exponent-range candidate selects are
masked ORs. An independent Python model of the reference and this formulation
agreed on 596,864 structured pairs (all 65,536 exponent pairs ×3, specials,
near-cancellation, large shifts) before the RTL was written. The bench's
reference miter gained four corner classes (near cancellation one ulp apart,
negative shifted operand with sticky, zero against tiny, opposite-sign
subnormals) and passes 100,000 vectors in both DPF profiles.

**C commit token.** The completed element is written from the retained
accumulator register one edge after its last partial; the token owns the bank
write, the C credit (`c_rows_done_q`, `c_cols_row_q`, `c_cols_done_q`) and the
drain/ST_DONE decisions, so the FP result no longer feeds the bank router
combinationally. MAC recurrence latency is unchanged; the job tail gains
one to two cycles.

**Registered facts on the sequencer.** Load completion is consumed by the
FSM from the recorded flag; issue cursors reset on phase facts rather than
`bad_job`; AR issue addresses use incrementally maintained 32-bit row offsets
(asserted equal to `a_addr`/`b_addr`); the group stride is a constant shift;
the last-partial fact (`mac_last_q`) follows the reduction cursor one edge
ahead (asserted); operand-bank reads use one word address per cycle (lane
alignment asserted); the store-side read column is a running register with
precomputed bank/word coordinates and flat one-hot request classes; the
accumulator is held clear outside ST_MAC instead of being cleared from the
next-state cone; the reuse slot base is a constant table. Store planning
converts credit to beats and forms the stripe count in CREDIT, with
constant-shift stripe arithmetic (asserted against the original formula),
leaving LIMITS/PUBLISH as clamps in separate processes.

Rejected variant: taking the B-skip decision from ST_LB one cycle later
removed the same-cycle response term but spent one LB cycle on a hit, which
the slots bench's PMU phase contract rejects (`ai-gemm-r21-first-r1`); the
retained form reads the raw response error directly in ST_LA.

## Evidence

| Remote tag | Result |
|---|---|
| `ai-gemm-r21-final-r2` | 15 cases pass: DPF=0/NCH=1 and DPF=2/NCH=2 (OutCols=4, reuse) golden, accumulate 112×2, signed 56×2, protocol (672/869 stalls), slots 16×2, FP32 100k×2; stripe NCH=1/2; cluster 1/2/4 |
| `ai-gemm-r21-final-wide-r2` | 128/512-bit and streaming store bench passes |

Shadow comparisons against the r19 operand and completion expressions remain
compiled in (`G6LC_AI_HYP_R20_CHECK`): 62,576 lane samples and 22,502 load
cycles. New assertions cover the AR offsets, the lane-aligned word address,
`mac_last_q`, the running store column, stripe identities, the slot base and
the commit token's state. Matched DPF=0 golden latency: 1344 → 1365 cycles
(registered completion ×2 loads, token drain). Raw artifacts under
`C:/Users/etcim/AppData/Local/Temp/cva6-artifacts/<tag>/`.

## Limits and next

These are structural module maxima on a frozen analyzer, not connected
end-to-end arrivals (see `gemm-internal-stitches-r19.md`) and not STA. The
remaining FP recurrence (75.00) is a single-cycle add→normalize loop; the
next step is a two-stage accumulator fed by interleaved independent output
groups, together with a registered operand-bank read stage. Both change the
issue schedule and are recorded as the r22 plan. Generic remote lint/synth
still fail the production-path hyp config lookup. No 8-FO4 closure is claimed.
