# r27 — g6lc_ai_exec paths over 8 FO4

Frozen r20 analyzer (delay-v45 / ir-v6). Board:
`boards/ai-island/analyze-ai-hyp-r27.{json,ir.json,log,manifest.json}`.
Edits: `analysis/tools/r27_exec_edit.py` (dot4 part retained; requant part
reverted in place with the countercase comment).

| Path family | Before | After | Status |
|---|---:|---:|---|
| dot4 byte products (`dot4_s_p/u_p`) | 56.00 (atomic Mul ×8) | **22.40** | landed: eight conditional shifted rows per product in a balanced tree (signed: sign-extended operand, row 7 subtracted); exact in 16 bits, asserted against the product |
| requant product `rq_prod` (48×16) | 62.55 | 62.55 | carry-save shift-add over four phases (rows selected per phase, +1 as the accumulator's initial value; model-checked on 100,000 pairs) measured **80.5** (first form 85.0) because the analyzer bills each genvar constant shift and the row select; reverted to the three-phase atomic multiply |
| module maximum | 62.55 | 62.55 | unchanged (requant multiply) |
| paths over 8 FO4 | 201 / 302 | 204 / 310 | the row trees add nodes; the count is the real remaining work |

Gates: `tb_g6lc_ai_exec_dot` on the hyp exec passes (216 checks, local
Verilator 5.020). `tb_g6lc_ai_enq_ready` stops at time 0 on the hyp exec's
own geometry assertion (hyp8 `AiCfgOff` normalisation): a bench/config
mismatch that predates r27 and does not exercise the change. The requant
path has no leaf in this loop; the reverted form is the pre-r27 RTL.

What remains for exec's 204 over-budget paths, in order of leverage:
1. The requant multiply needs a form the structural model credits: a
   registered 4×(48×4) partial-product tile per phase written as explicit
   `aval << const` rows in separate generate scopes (the `pe_dot_pipe`
   pattern), or an accumulate loop of one row per cycle (16 phases) if the
   coprocessor latency is acceptable. The carry-save algebra is proven.
2. The requant select chain (`rq_adj` 31.6): both polarities in parallel,
   negate folded into the rounding carry-in.
3. Accumulator-bank update bundles (P6 per family) and prepared bank-index
   decode — the bulk of the count.
4. `dot4` sums (two 32-bit adder levels) can be registered one cycle behind
   the products if the ISA result latency for that class may grow by one.

Structural maxima on a frozen analyzer, not STA; no 8-FO4 closure.
