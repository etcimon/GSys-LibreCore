# r28 — g6lc_ai_exec: wired-row carry-save requant, parallel polarities

Frozen r20 analyzer (delay-v45 / ir-v6). Board:
`boards/ai-island/analyze-ai-hyp-r28.{json,ir.json,log,manifest.json}`.

| exec path family | r27 | r28 |
|---|---:|---:|
| requant product `rq_prod` (48×16) | 62.55 (atomic) | reduction tree in phase 2, carry-propagate in phase 3 |
| requant select chain `rq_adj` | 31.57 | parallel polarities, one-hot select |
| module maximum | **62.55** | **26.07** (magnitude of the registered product) |
| paths over 8 FO4 | 204 / 310 | 209 / 327 |

Mechanisms: the sixteen scale rows are wired concatenations (no shifter;
row 15 inverted, its +1 a seventeenth operand), reduced 17→12→8→6→4→3→2 by
3:2 carry-save stages as separate generate assigns, registered as a
sum/carry pair at phase 2 and added at phase 3 — one extra requant phase
per element. The rounded negate is `~t + !bump`, so both polarities form in
parallel and `rq_adj` is a one-hot select. Both identities are model-checked
on 100,000 pairs each and carried as translate_off assertions.

Gates: `tb_g6lc_ai_exec_dot` passes (216 checks) on the hyp exec; the
requant path has no simulation leaf in this loop (the enq-ready bench stops
at the pre-existing hyp8 geometry assertion), so its evidence is the model
checks and the in-RTL identities, not a simulation run.

Island maximum is now desc_engine 63.35, then subcode 60.34; exec's
remaining count (209) is the accumulator-bank/requant state bundles (P6 per
family, prepared bank-index decode). Structural maxima, not STA; no 8-FO4
closure.
