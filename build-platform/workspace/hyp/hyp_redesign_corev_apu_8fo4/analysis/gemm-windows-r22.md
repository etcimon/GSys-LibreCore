# GEMM r22 — two-set interleaved accumulator, two-stage FP adder

Same frozen analyzer as r20/r21 (`hyp8-src/inputs/r20-sv-timing.exe`,
delay-v45 / ir-v6). Matched module maxima:

| Module | r19 | r21 | r22 |
|---|---:|---:|---:|
| `g6lc_ai_gemm_seq` | 98.00 | 61.50 | **55.80 FO4** |
| FP32 adder (one cycle) | 94.93 | 75.00 | — |
| `g6lc_ai_gemm_fp32_align` (stage 1) | — | — | **37.70 FO4** |
| `g6lc_ai_gemm_fp32_norm` (stage 2) | — | — | **46.25 FO4** |
| `g6lc_ai_gemm_fp32_add_p2` (register) | — | — | 8.00 |
| `g6lc_ai_gemm_store_plan` | 39.80 | 28.50 | 28.50 |
| `g6lc_ai_gemm_span` | 18.30 | 18.30 | 18.30 |

Board: `boards/ai-island/analyze-ai-hyp-r22.{json,ir.json,log,manifest.json}`;
source archive `analysis/tools/zips/gemm-r22-first-closure.zip`
(65 files, all hashes in the manifest). Edits applied by
`analysis/tools/r22_edit.py` on top of r21.

## Design

**Interleaved issue.** The MAC issues the column group at `j_q` (set 0) and
the group at `j_q + cols_eff` (set 1) in alternating slots for the same
(row, t). The reduction cursor advances after slot 1, so each set sees a
dependent partial at most every other cycle. When no second group exists
(n ≤ cols_eff, or the row's odd trailing group) slot 1 is a bubble, which
keeps the two-edge spacing; such shapes run at half rate. The set index
travels with the dot tags (`dot_ph_pipe`), the registered sum (`sum_ph_q`),
stage 1 (`s1_ph_q`) and the commit token (`commit_ph_q`). B-group selection,
column validity, operand-bank addresses and the seed read use the issued
column `j_issue`. `j_pair_q` refreshes every cycle and is only consumed in
slot 1, where `j_q` is stable.

**Two-stage FP accumulation.** `g6lc_ai_gemm_fp32_add` is split at the
aligned-operand boundary into `g6lc_ai_gemm_fp32_align` and
`g6lc_ai_gemm_fp32_norm` (struct `fp32_align_t` in the hyp `g6lc_ai_fp_pkg`).
The combinational composition keeps the module name for the reference miter;
`g6lc_ai_gemm_fp32_add_p2` registers the aligned operands. Per column: stage 1
forms the base (set accumulator; on the first partial the seed for
accumulate-mode column 0, else zero) and registers the integer sum and the
raw first partial; stage 2 selects the normalized FP result, the raw first
partial (the reference publishes it unadded) or the integer sum. One adder
per column replaces the previous seed adder plus accumulate adder. Seeds are
captured per set. The commit token fires from stage 1's last flag and writes
the set's accumulator one edge later.

MAC recurrence per set is now two cycles; issue rate is unchanged for
n ≥ 2·cols_eff. Drain conditions include the stage-1 valid. The ablation arm
`G6LC_AI_GEMM_LEGACY_CONTROL` no longer tracks the accumulator shape and is
retired from compile compatibility.

## Evidence

| Remote tag | Result |
|---|---|
| `ai-gemm-r22-first-r1` | 15 cases pass: DPF=0/NCH=1 and DPF=2/NCH=2 (OutCols=4, reuse) golden, accumulate 112×2, signed 56×2, protocol, slots 16×2, FP32 miter 100k×2; stripe NCH=1/2; cluster 1/2/4 |
| `ai-gemm-r22-first-wide-r1` | 128/512-bit and streaming store bench passes |

Shadow comparisons: 77,920 lane samples, 22,502 load cycles. New assertion:
consecutive stage-1/sum partials belong to different sets. Local Verilator
5.020 lint of the backend bench shows only the pre-existing PE latch
warnings. Golden cycle counts: DPF=0 1365 → 1394 (stage and bubbles),
DPF=2 2122 → 2164, stripe 82/116 → 83/117.

## Limits and next

Structural maxima on a frozen analyzer, not connected arrivals or STA. The
sequencer's remaining owner is the R decode (`receive_count` from
`k_bytes - receive_col`, 55.80): carrying the remaining byte count in the
AR slot would remove the subtraction. A registered operand-bank read stage
(tile latency 1 with cursors one cycle ahead) is the next pipelining step.
Generic remote lint/synth still fail the production-path hyp config lookup.
No 8-FO4 closure is claimed.
