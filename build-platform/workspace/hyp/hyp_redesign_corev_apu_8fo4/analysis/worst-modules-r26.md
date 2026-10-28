# r26 — implemented from the worst-five plan

Frozen r20 analyzer (delay-v45 / ir-v6). Board:
`boards/ai-island/analyze-ai-hyp-r26.{json,ir.json,log,manifest.json}`.
Edits: `analysis/tools/r26_edit.py` (subcode, inval_queue) plus the codec
stage move and the inval_queue partial revert described below.

| Module | r25 | r26 | Landed mechanism |
|---|---:|---:|---|
| `g6lc_ai_policy_codec` | 59.30 | **39.40** | evaluate/encode/miss moved from the accept cycle to the f1 stage (features and `mispredict_i` captured; the window gate keeps `state_q` stable across the two cycles) — no new latency, the f1 stage already existed |
| `g6lc_ai_inval_queue` | 52.25 | **46.54** | line difference narrowed to the low `8 + LineShift` bits (asserted); the one-hot constant-shift burst count measured 70.0 and was reverted |
| `g6lc_ai_policy_subcode` | 62.24 | 60.34 | `policy_reuse_gain` as an elaboration table indexed by (r, c) (asserted); the self-charging threshold as one registered fact per evaluation (asserted) — the maximum is now the atomic `cost_q`/`service_q`/`groups_q` products |

Island ranking after r26: desc_engine 63.35, exec 62.55, subcode 60.34,
pe_dot_float_pipe 50.77, gemm_seq 48.70, pe_dot_float 47.14,
inval_queue 46.54, fp32_norm 46.25, pe_dot 45.80, codec 39.40.

Gates: `run-inval-queue.sh` on the hyp tree (positive, oracle negative,
inval-at-AW mutation caught) and the policy pipeline bench (topology 5568,
publications 23, cancels 29, PMU orders 3), both on local Verilator 5.020.

Countercases recorded: the inval_queue one-hot shift form (70.0) — the
analyzer bills a shifter per loop arm; keep the single expression.

Still open from the plan, each needing its own bench: desc_engine prepared
`ai_bus_len` + probe request/verdict split (desc-island bench); exec
sequential/tiled multipliers (cvxif leaf); subcode's three products as a
sequential multiplier across extra states (policy bench, mechanical);
inval_queue two-entry AW skid (inval bench); pe_dot_float_pipe decode stage
(gemm-backend DPF=1/2). Structural maxima, not STA; no 8-FO4 closure.
