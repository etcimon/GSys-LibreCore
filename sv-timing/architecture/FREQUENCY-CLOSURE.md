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

See `verif/README.md`, `FO4-ALGORITHM-UPGRADES.md`.
