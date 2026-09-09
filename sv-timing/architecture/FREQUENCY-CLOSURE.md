# Frequency closure (startpoint / endpoint)

Structural (not STA) frequency closure for the precompiler loop.

Handoff to real STA tools (SDC seeds, artifact mapping, workflow): [`STA-HANDOFF.md`](STA-HANDOFF.md).

## Model

| Quantity | Formula |
|---|---|
| Period (ns) | \(T = 1000 / f_{\mathrm{MHz}}\) |
| FO4 budget | \(B = T \cdot 1000 / t_{\mathrm{FO4,ps}} \cdot (1-m)\) |
| Path slack | \(B - C_{\mathrm{path}}\) |
| Max freq for path | \(f_{\max} = 1000 / (C \cdot t_{\mathrm{FO4}} / 1000 / (1-m))\) |
| **Closes** | all single-cycle paths have slack ≥ 0 at target |

## Startpoint / endpoint

| Region | Startpoint | Endpoint | `path_kind` |
|---|---|---|---|
| `always_comb` / `assign` | `{mod}.in0` (PI) | `{mod}.out0` (PO) | `in_to_out` |
| `always_ff` | `{mod}.reg0/CP` | `{mod}.reg1/D` | `reg_to_reg` |
| After InsertReg cut | prior launch | pipe `regN/D` | `in_to_reg` / `reg_to_reg` |
| Residual after cut | pipe Q | original capture | same as parent (`RegToReg` stays `RegToReg`) |

JSON (`analyze --json-out`) includes per-path:

- `startpoint`, `endpoint`, `path_kind`
- `total_fo4`, `slack_fo4`, `max_freq_mhz`, `closes`
- design-level `frequency_closure` summary

## Precompiler response

1. Rank paths worst slack first (primary FO4 excludes soft multi-cycle / atomic-over-budget where tagged)  
2. Prefer **latency-neutral** first: `path_class` deflate → rebalance → **BalanceMux**
   (stage_hot_arm → residual onehot → sticky credit) → SplitAssign  
3. **InsertReg** only with `--allow-latency` (+ GateInfo / `--assume-clk` when needed)  
4. Emit optimized SV (review-only) → integrity reparse → optional **pyslang** lint in `verif/regress`  

Default budget knobs: `fo4_ps=20`, `margin=0.2` → **~32 FO4 @ 1250 MHz**, **~20 FO4 @ 2000 MHz**, **~16 FO4 @ 2500 MHz**.
Scale with monorepo-soak `--target-mhz`. See `MONOREPO-SOAK.md` §9 for validated soak numbers.

---

## Current evidence rules (ir-v1 / delay-v2)

A 4 GHz target is 0.250 ns. At 20 ps/FO4 and 20% margin the structural budget is
10 FO4; this is an assumption, not process calibration. Inverting reported frequency
must include the margin: `C = 1e6 * (1-margin) / (f_MHz * fo4_ps)`.
The historical 503.1 MHz / 20 ps conversion below omitted that margin: it corresponds
to about 79.5 FO4, not 99.4, under that formula. Neither value proves a silicon limit.

Use original analysis, proposed IR result, emitted re-analysis, integrity and actual
STA as separate evidence. Both `frequency_closure` summaries filter inferred
multi-cycle paths; read all-path costs and coverage too. A successful parse is not
an equivalence proof. Macro/include source locations, unresolved assignment semantics,
and skipped files prevent production claims even if a filtered structural budget passes.

Host dashboards now select emitted evidence instead of falling back to optimistic IR.
`post_analyze_valid=false`, missing/empty post-analysis, and skipped files are
INCONCLUSIVE. OpenSTA parsing accepts native numeric-before-slack reports; partial or
stale files cannot turn failed tool execution into success. Missing tools are SKIP,
not STA closure. The reference report tests do not calibrate `fo4-v1.toml`.

## Current strict measurement (ir-v1 / delay-v4)

First reading taken with a **closed input set**: both profiles parse every file, with no
`--allow-parse-errors` and zero skips. 4000 MHz / 20 ps / margin 0.2 → 10.0 FO4, `-O3`.
Closure is read from emitted `post_analyze`, not from IR `post_closure`.

| Profile | Files | Modules | Paths | Closure | Structural max | Worst path | FO4 | Failing |
|---|---:|---:|---:|---|---:|---|---:|---:|
| `full_core` | 258 | 233 | 5557 | MISS | ~571.4 MHz | `g6lc_ftq.reg0/CP → .reg1/D` | 70.0 | 427 |
| `full_corev_apu` | 181 | 167 | 4794 | MISS | ~131.4 MHz | `g6lc_ai_gemm_seq.reg0/CP → .reg1/D` | 304.5 | 133 |

Worst **raw** (multi-cycle-inclusive) path is 176.0 FO4 `fpnew_opgroup_block` on the core
and 304.5 FO4 `g6lc_ai_gemm_seq` on the APU. Under `delay-v3` the core's raw worst was a
202.0 FO4 "divider" in `cva6_ptw` that turned out to be a constant part-select bound; see
`AGENTS-todo.md` for the before/after counts.

Three things this changes:

1. **Earlier readings covered less design than they appeared to.** Closing the inputs
   moved `full_core` from 184 to 233 modules and `full_corev_apu` from 1888 to 4636
   paths. Any frequency taken before this described a subset, silently.
2. **The worst core path is not an AI cone.** With comment artifacts, `translate_off`
   regions and name-based arithmetic discounts removed, it is `g6lc_ftq` at 70.0 FO4.
   `SyncDpRam` 720.0 and `g6lc_ai_exec` 545.5 do not reproduce.
3. **Auto-correct moved primary FO4 by 0.0** on both profiles despite 462 and 308
   applied edits. The emitted tree is valid and re-analysable; it does not improve this
   target. Do not present the transform worklist as a path to a higher clock.
4. **`post_closure` is not reportable under lean emit.** The same `full_core` run books IR
   **56.0 FO4 / 714.3 MHz / 344 failing** while re-analysis of its own emitted SV gives
   **70.0 FO4 / 571.4 MHz / 556 failing**, with integrity clean. Lean emit does not
   rewrite origin; `PassPolicy.emit_structural` now refuses InsertReg/BalanceMux IR
   credit in that mode and sets `post_closure.reportable=false`. Read `post_analyze`,
   which is what the host and soak use. Richer emit (`--real-cut-feeds`) may book IR
   because origin is actually rewritten.

Both profiles are `structure OK` under host `timings validate --require-emit` while
reporting MISS. That combination — a valid package that does not close — is the
intended outcome, and it is still a structural estimate, not STA.

## Historical high-frequency targets (2026-09-10 measurements)

These pre-audit findings are retained as history, not current critical-path rankings.
They were taken on an incomplete input set (see above) and do not establish that a
particular source module limits the physical processor.

Everything below is `full_core` with `+define+G6LC_FETCH_B` carried and the g1\* recover
set retired. Read it before quoting any multi-GHz number.

### `fo4_ps` is a process input, not a tuning knob

The budget at 4000 MHz is **10.0 FO4 at 20 ps**, **16.7 at 12 ps**, **33.3 at 6 ps**, so
"closes at 4 GHz" can be manufactured by choosing the node. The host's
`AGENTS-configuration.md` puts the target of record at **1.25 GHz / 12 nm**, with a
reference shelf of 1.25-2.2 GHz on 12-14 nm and no 12 nm part above 2.0 GHz. Quote the
`fo4_ps` with every frequency claim.

### Aggressivity is not the lever - measured

`-O3` (`max_passes=16 worklist_width=4 cut=budget-fit stages=8 min_gain=1 thorough`)
against `-O2` (`4 / 1 / cost-balanced / 1 / 2 / balanced`) at the same operating point:

| | edits | IR closure | emitted MHz | emitted FO4 |
|---|--:|---|--:|--:|
| 4000 MHz, 20 ps, `-O2` | 928 | false 2086.6 | 503.1 | 99.4 |
| 4000 MHz, 20 ps, **`-O3`** | **1091** | false 2086.6 | 503.1 | **99.4** |

163 extra edits, identical outcome. **Raising passes / worklist width / multi-cut does not
move the emitted critical path**, because the limiting cones are `AtomicOverBudget` and no
cut strategy reaches inside an indivisible operator.

### The actionable output for a high target is the T3 stage count

`t3_arch_multicycle_mul` reports `ceil(atomic_cost / budget)` internal stages for the
dominant `Mul`/`DivRem` on the path (`dominant_atomic_op`, mirroring
`try_atomic_over_budget`'s selection), so it scales with the target: a 56 FO4 multiply
needs 2 stages at 1250 MHz/20 ps and **6 at 4000 MHz/20 ps**. `full_core` at 4000 MHz/20 ps
yields 24 `atomic_op` cards -- `fpnew_cast_multi` DivRem 120 FO4 -> 12 stages, `cva6_ptw`
Mul 102 -> 11, `cva6_tlb` Mul 78 -> 8, **`g6lc_ai_exec` Mul 56 -> 6**.

### Two caveats that invalidate naive readings

1. **`primary_fo4` excludes `atomic_over_budget` and multi-cycle classes**, so
   `post_closure` can report `closes=true` while the design does not close. Always read
   `post_analyze_sv` -- the re-analysis of the *emitted* RTL -- beside it. Measured
   divergence: `full_corev_apu` IR `closes=true 4000.0` vs emitted **350.9 MHz**.
2. **A known lowering bug attributes FO4 to comment lines.** Comment slashes are lowered as
   `DivRem` nodes: `SyncDpRam.out0` reports 720.0 FO4 (`nodes=1`, `primary_loc
   SyncDpRam.sv:136` = a row of slashes) in a file with **zero** `/` operators outside
   comments, and 720 is 6 x the `div_rem` base of 120. Scope: 3 of 24 atomic paths, 1,577
   of 29,925 FO4 (5.3%) -- **but it owns the worst path**. Treat any path whose
   `primary_loc` is a comment line as invalid until this is fixed; with those removed the
   genuine worst path is **545.5 FO4 `g6lc_ai_exec`**.

See `verif/README.md`, `FO4-ALGORITHM-UPGRADES.md`.
AI island: `../../architecture/ai-matrix/AI-ISLAND-TIMING.md`.
