# r25 — policy subcode COST stage

Frozen r20 analyzer (delay-v45 / ir-v6). Board:
`boards/ai-island/analyze-ai-hyp-r25.{json,ir.json,log,manifest.json}`.

| Module | r24 | r25 |
|---|---:|---:|
| `g6lc_ai_policy_subcode` | 78.92 | **62.24 FO4** |

The candidate evaluator's PREP state now registers its shape facts (`r`, `c`,
`tail`, row bytes for the full and tail depths, group counts), and a new
COST state forms the byte/service terms and the group product from those
registers. One cycle is added per candidate evaluation; the reported
baseline/selected cycle estimates are unchanged (they are cost model
outputs, not the evaluator's wall time). The policy pipeline bench passes
(topology 5568, publications 23, cancels 29, PMU orders 3).

Island ranking after r25: desc_engine 63.35, exec 62.55, subcode 62.24,
codec 59.30, inval_queue 52.25, pe_dot_float_pipe 50.77, gemm_seq 48.70,
pe_dot_float 47.14, fp32_norm 46.25, pe_dot 45.80 — from r19's 128.37 /
98.00 / 94.93 at the top.

Remaining owners and the mechanism each needs:

- `g6lc_ai_desc_engine` 63.35: `ai_bus_len` on the check pointer. Register
  per-pointer lengths during ST_SPAN (span registers settle one cycle before
  ST_CHK_A); needs the desc-island bench, not run in this pass.
- `g6lc_ai_exec` 62.55: the 48-bit scale multiply in its three-phase RQ
  window; a sequential multiplier (as `g6lc_ai_mul_seq`) fits if the phase
  count grows. Needs the cvxif bench.
- subcode 62.24: the remaining bundle is service clamps and the 17x17 group
  product; the product can move to a sequential multiplier.
- `g6lc_ai_inval_queue` 52.25: AW last-byte/line arithmetic to `aw_hold_o`;
  a two-entry skid (not a hold) is the recorded remedy.
- `g6lc_ai_pe_dot_float_pipe` 50.77: decode stage ahead of the product
  (R8), whose two leaf issues are recorded in the r13 log.

Structural maxima on a frozen analyzer, not STA; generic remote lint/synth
still fail the production-path hyp config lookup. No 8-FO4 closure.
