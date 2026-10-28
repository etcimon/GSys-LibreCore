# GEMM r23 — carried receive facts, static bank-write routing

Same frozen analyzer as r20–r22 (`hyp8-src/inputs/r20-sv-timing.exe`,
delay-v45 / ir-v6). Matched module maxima:

| Module | r22 | r23 |
|---|---:|---:|
| `g6lc_ai_gemm_seq` | 55.80 | **48.70 FO4** |
| `g6lc_ai_tile_sram` (operand banks, read latency 1) | — | 19.00 |
| `g6lc_ai_gemm_fp32_norm` / `_align` | 46.25 / 37.70 | 46.25 / 37.70 |
| `g6lc_ai_gemm_store_plan` | 28.50 | 28.50 |
| `g6lc_ai_gemm_span` | 18.30 | 18.30 |

Board: `boards/ai-island/analyze-ai-hyp-r23.{json,ir.json,log,manifest.json}`;
source archive `analysis/tools/zips/gemm-r23-third-closure.zip`. Edits applied
by `analysis/tools/r23_edit.py`, `r23b_edit.py` and `r23c_edit.py` on top of r22.

## Transforms

- **Remaining bytes as a carried fact.** The AR slot record gains `rem`
  (`k_bytes - col`, written at AR acceptance and decremented per beat); the
  ordered-ID path keeps `recv_rem_q`. The receive decode compares only the
  low `BeatAlignW+1` bits once the high bits are known zero, and the lane cap
  exists only when a beat is wider than the lane array. Asserted equal to
  `k_bytes - receive_col` on every accepted beat.
- **Static bank-write routing.** Beat byte `p` lands in bank
  `(col + p) mod PeLanes`; the write side now computes, per bank, the byte
  lane `b - col_lane`, a live bit, and the shared row word plus a one-bit
  wrap carry. No dynamic LHS index remains; a negedge shadow of the original
  per-byte formulation checks request, address and data on every beat.
- **AR stripe cap** with constant shifts (beat-aligned address, no sticky
  term), asserted against `cap_beats_to_stripe`.
- **Registered facts** `rows_left_q` (`i_q < m_q`) and `t_zero_q`
  (`t_q == 0`), both asserted in ST_MAC.
- **Registered operand read stage.** `g6lc_ai_tile_sram` gains a
  `ReadLatency` parameter (0 default; the C bank keeps its latency-0 read).
  The A/B banks use latency 1; the issue cursors advance on the read and a
  read-stage record (`rd_v/ph/first/last/t/i/j`) drives operand packing, the
  dot tags, the summed-partial stage and the accumulate-mode seed read one
  cycle later. The bank read requests keep the live cursor. Bank address
  arithmetic, the SRAM read and operand packing are now in separate cycles.
  Drain conditions include the read-stage valid.

## Evidence

| Remote tag | Result |
|---|---|
| `ai-gemm-r23-second-r1` / `-wide-r1` | carried facts and static routing: 15 cases + wide pass |
| `ai-gemm-r23-third-r1` / `-wide-r1` | with the read stage: 15 cases + wide pass |

A first r23 run (`ai-gemm-r23-first-r1`) failed on an over-broad assertion
that compared idle slots' reset values; it was narrowed to accepted beats and
the RTL was unchanged. Cycle counts: DPF=0 golden 1394 → 1401 with the read
stage (one cycle per MAC pass), DPF=2 2164 → 2172, stripe 83/117 → 84/118.
Shadow comparisons (now sampled from the read stage): 62,576 lane samples,
22,502 load cycles.

## Remaining owners and next

The sequencer's maximum is the accumulate-mode seed read (read-stage facts →
bank select → latency-0 C read → seed register, 48.70); the C bank read
itself could take the same latency-1 seam once the store W fetch and seed
capture are retimed by one cycle. Then the receive count select (47.65,
including an arm that is dead for beats no wider than the lane array) and the
FP normalize stage (46.25). These remain structural maxima on a frozen
analyzer, not STA, and generic remote lint/synth still fail the
production-path hyp config lookup. No 8-FO4 closure is claimed.
