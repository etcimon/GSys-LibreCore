# g6lc_ai_policy_subcode — execution paths, callers and 8-FO4 strategy

Basis: `boards/ai-island/analyze-ai-hyp-r29.ir.json` (frozen r20 analyzer,
delay-v45 / ir-v6, 8-FO4 budget). 58 paths, **41 over budget**, maximum
60.34. Sole caller: `g6lc_ai_policy_steer.i_subcode` (the r17 split); the
evaluator starts from the published baseline token, runs eight candidate
evaluations off the GEMM path, and publishes `subcode/topology/cycles`
through the steer's completion join. Its outputs are steering telemetry:
extra evaluator cycles delay a steering decision, not a job. Analysis only;
nothing here is landed or measured.

## Execution paths (reg→reg unless noted)

| # | FO4 | Owner | Mechanism needed |
|---|---:|---|---|
| 1 | 60.34 | `cost_q = groups_q * service_q` (28×28), `service_q = full_q*full_service_q + tail_service_q` (25×25), `groups_q = mgroups_q*ngroups_q` (17×17) — three atomic products in SERVICE/TOTAL/COST | wired-row carry-save trees (the r28 exec form) across one extra state each, or one sequential shift-add accumulator shared by the three products |
| 2 | 49.74 | `better = ok && cost_q < best_cost_q` (25.8) → `choose` (16.0) → winner selects | registered `better_q` one state later (COMPARE split); compare width 28 |
| 3 | 45.44 | service clamp bundle (`full_service`/`tail_service` with `step_cycles` floor, `tail == 0`) | split per register (P6), precompute the floor compare from registered bytes |
| 4 | 42.00 | `reuse_gain_tab[gr][gc]` elaboration entries (in→out, dead at run time — the analyzer bills the genvar function call) | replace the function call in the table by literal constants (a 25-entry `localparam` vector) so no runtime node remains |
| 5 | 40.81 | `candidate_ok` (16.4: alignment masks `(m & ((1<<r)-1)) == 0`, range tests) → `candidate_d` | prepared per-r/per-c alignment facts at job capture (`m_align_ok[0..4]`, `n_align_ok[0..4]`), select by r/c |
| 6 | 39.72 | `full_bytes/tail_bytes` shift-add from registered row bytes | fold into the COST state's registered products (becomes rows of the carry-save tree) |
| 7 | 31.90 | `rb_full_q/rb_tail_q <= row_bytes(depth, fmt)` (function: shift by element bits, +7, >>3) | constant-shift table by `fmt` (five formats), one add |
| 8 | 26.83 | `group_shape` part-select by `group_q`, `d = slots - r - c` | 6-bit subtract pair; register `d` with r/c in PREP (already a fact) |
| 9 | 25.30 | `cache_match = CacheEn && valid && eligible && baseline == …` (wide struct compare on inputs) | register the baseline compare one cycle behind `start_i` (the steer tolerates it: it waits on `valid_o`) |

## Strategy, in landing order (value per policy-bench run)

1. **Products as wired-row carry-save trees (paths 1, 6).** `groups_q`:
   17 rows of `mgroups_q` gated by `ngroups_q[i]` as concatenations,
   17→2 by 3:2 stages, registered pair, CPA next state. `service_q`:
   15 rows of `full_q` gated by `full_service_q` bits plus `tail_service_q`
   as an extra operand. `cost_q`: 28 rows — or, since nothing consumes
   `cost_q` for the 32-cycle evaluation tax, a **shared sequential
   accumulator** (one row per cycle, ~20 FO4) across COST/SERVICE/TOTAL:
   +17/+15/+28 cycles per candidate, no area for three trees. The tree form
   keeps the state count (+1 each) and matches the r28 exec measurement
   (62.55 → 26.07). Expected maxima: tree ~26–30; sequential ~20.
2. **COMPARE split (path 2).** Register `better_q = ok && cost_q <
   best_cost_q` in TOTAL's successor and let COMPARE do only the winner
   select and `choose` (already a single compare against `threshold_q`).
   +1 state per candidate.
3. **Prepared alignment facts (path 5).** At job capture compute
   `m_align_ok[r]`/`n_align_ok[c]` for r,c ∈ 0..4 (constant masks) and the
   `r + c <= 4` / `<= slots_log2` tests per index as a constant table
   indexed by `index_q`; `candidate_ok` becomes a 2-level select.
4. **Constant tables without runtime function nodes (paths 4, 7).**
   `reuse_gain_tab` as a literal `localparam` built from a constant function
   evaluated at elaboration (the analyzer billed the genvar call at 42.0 —
   same lesson as the slot-base table in r21), `row_bytes` as five
   constant-shift arms selected by `fmt_q`.
5. **Service clamps per register (path 3)** and `cache_match` registered
   behind `start_i` (path 9).

## Implementation impact

- All changes add evaluator cycles (1–3 states per candidate with trees,
  tens with the sequential accumulator) and never touch the GEMM path; the
  published `baseline_cycles_o/selected_cycles_o` are cost-model values and
  stay bit-identical. The steer's join waits on `valid_o`, so no interface
  change.
- Each arithmetic rewrite is an identity (products mod 2^N, alignment masks,
  gain table) and carries a translate_off assertion; the policy pipeline
  bench (`run_policy_r17.sh`: 5,568 topology comparisons, 23 publications,
  29 cancellations, 3 PMU orders) is the gate and runs locally in ~2 min.
- After 1–5 the module maximum should sit near the registered compare/select
  level (~20); the 41 over-budget paths then reduce to the state-machine
  bundles, which need the P6 per-register split of the IDLE/PREP/COMPARE
  writes (mechanical) to approach 8.
- Measurement caveats: frozen analyzer, module maxima, not STA; the
  cross-module figures to `policy_steer` remain unvalidated sums (r19 audit).
