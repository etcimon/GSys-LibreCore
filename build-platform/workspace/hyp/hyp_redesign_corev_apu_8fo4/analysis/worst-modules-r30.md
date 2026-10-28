# r30 — subcode shared sequential multiplier

Frozen r20 analyzer (delay-v45 / ir-v6). Board:
`boards/ai-island/analyze-ai-hyp-r30.{json,ir.json,log,manifest.json}`.

| Module | r29 | r30 |
|---|---:|---:|
| `g6lc_ai_policy_subcode` | 60.34 | **49.74** |

The three candidate-cost products (`groups_q`, `service_q`, `cost_q`) now
share one `g6lc_ai_mul_seq` (32-cycle shift-add, 20 FO4): each product
state launches on entry and advances on the multiplier's done pulse, so the
atomic 17×17 / 25×25 / 28×28 multipliers are gone. Cost: ~96 extra cycles
per candidate, hidden by the evaluator's 32-cycle tax from any steering
decision; results are bit-identical (asserted on the final product). The
remaining maximum is the COMPARE chain (`better` → `choose` → winner
select, 49.74), then the service clamps (45.44); 41 of 61 paths remain over
8 FO4 (state bundles).

Gate: policy pipeline bench on the hyp tree — `PASS policy_pipeline
topology=5568 publications=23 cancels=29 pmu_orders=3` (local Verilator
5.020). The policy bench script now lists `g6lc_ai_mul_seq.sv`; the island
DMA and policy-walk scripts already did.

Island ranking after r30: pe_dot_float_pipe 50.77, subcode 49.74,
gemm_seq 48.70, pe_dot_float 47.14, inval_queue 46.54, fp32_norm 46.25,
pe_dot 45.80, codec 39.40, desc_engine 39.00, exec 26.07 — from r19's
128.37 / 98.00 / 94.93.

Next on subcode (plan items 2–5): registered `better_q` (COMPARE split),
prepared alignment facts, literal constant tables, per-register clamps.
Structural maxima, not STA; no 8-FO4 closure.
