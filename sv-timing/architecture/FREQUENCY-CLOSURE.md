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
| Residual after cut | pipe Q | capture / PO | `reg_to_out` |

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

## High-frequency targets (2026-09-10 measurements)

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
