# Optimization levels and dials (`-O` surface) — design delta

> Companion to [`DESIGN.md`](DESIGN.md) § Auto-correct and
> [`AUTO-CORRECT-CORE-API.md`](AUTO-CORRECT-CORE-API.md) §3.4–3.8.
> **Status:** §1 (P14 measurement truth) and §3–§6 (the `-O` surface, P15) are
> **implemented** — see §1.2 and §3.2 for the as-built maps. M7 (P19) and the reserved
> dials noted in §3.2 remain open. Phases in [`../AGENTS-todo.md`](../AGENTS-todo.md).
> **Scope:** package-internal policy surface only. No host coupling (KD0), no new
> cross-language contract beyond an additive `opt` block in `analyze-result`.

---

## 0. Why this delta exists

Auto-correct *had* exactly two strength controls — `--allow-latency` and `--max-passes` —
and one hard-coded heuristic per decision. A GCC-style level surface makes "how hard
should the precompiler try, and what may it trade away" an explicit, reproducible,
reportable parameter instead of a code constant.

Before that surface is worth anything, the **measurement** underneath it has to be a
delay estimate. It was not — section 1 records that gap and its fix (phase P14,
`measurement=delay-v1`); section 2 covers calibration; sections 3–6 define the level
surface itself (phase P15). Both phases are implemented; §1.2 and §3.2 map spec to code.

---

## 1. Measurement defects that gate this work (P14)

**Status: M1–M6 fixed** (`MEASUREMENT_VERSION = "delay-v1"`); **M7 remains** (P19).
The table records the original defect and where the fix now lives.

| # | Defect | Locus | Effect on the `-O` surface |
|---|---|---|---|
| M1 | IR nodes are chained in **source order**, one path per region; `total_fo4` = **sum of every op in the region** | `crates/sv-timing-core/src/lower.rs:512-554` | Ranking is an area proxy. Worst-slack worklist points transforms at the *largest* region, not the *deepest* path. |
| M2 | `Expr::fo4_cost` sums **all** operator nodes in the tree instead of the longest root-to-leaf chain | `crates/sv-timing-core/src/expr.rs:193-197` | A balanced `a+b+c+d` (depth 2) costs the same as a serial chain (depth 3). |
| M3 | Width scaling frozen in `DESIGN.md` §3 is **unimplemented**; `width: 1`, `width_defaulted: true` for every node | `crates/sv-timing-core/src/lower.rs:539`, `crates/sv-timing-core/src/measure.rs:86-111` | A 64-bit multiply costs the same as a 1-bit AND. `--assume-xlen` / `--param-map` affect port-dim strings only (`lower.rs:122-149`), never cost. |
| M4 | `split_assign` multiplies the node's cost by `0.5` with **no structural counterpart**, and is the fallback whenever `InsertReg` is refused | `crates/sv-timing-transform/src/pipeline.rs:337-347`, `crates/sv-timing-transform/src/pass.rs:211-243` | The correct loop can report convergence it did not cause. Must be removed or backed by a real intermediate-wire edit before any level claims a gain. |
| M5 | Cut site is `path.nodes.len()/2 - 1` (index midpoint, cost-blind) | `crates/sv-timing-core/src/measure.rs:382-386`, `crates/sv-timing-transform/src/pipeline.rs:128-132` | `-O2`/`-O3` cannot balance stages; a single `mul` (56) beside eight `logic_bit` (1) lands wholly on one side. |
| M6 | `rank_paths_deterministic` carries no `#[test]` (duplicate attribute on the preceding fn swallowed it) | `crates/sv-timing-core/src/measure.rs:501-502,543` | The determinism guarantee in `AUTO-CORRECT-CORE-API.md` §5.1 is unenforced. |
| M7 | Relocation claims a **source line** (±6-line scan) rather than the IR node's byte span | `crates/sv-timing-emit/src/rhs.rs:137-205` | On multi-line ternary / nested-NBA CVA6 style the rewritten site can differ from the measured cut. Byte spans already exist on `SourceLoc`. |

### 1.1 Required corrections (normative for P14)

1. **Expression delay** — `Expr::fo4_cost` returns `own_cost + max(child costs)`. Add
   `Expr::fo4_area` (the current sum) for reports that genuinely want area.
2. **Width inference + normalized scaling** — resolve node width from port/param
   declarations, then `--param-map` / `--assume-xlen`, else leave `width_defaulted`.
   Apply `DESIGN.md` §3 scaling **normalized to a reference width of 32**, i.e. the
   `fo4-v1` base values are the cost *at width 32*:

   | Class | Factor |
   |---|---|
   | `add_sub`, `compare`, `shift_var` | `log2(max(w,2)) / log2(32)` |
   | `mul` | `(w / 32)²` |
   | `div_rem` | `w / 32` |
   | `logic_bit`, `mux`, `priority_mux`, `concat`, `shift_const`, `other` | `1` (unscaled) |

   Every scaled cost is **floored at `logic_bit`** (so a 1-bit multiply cannot cost less
   than a gate), and a node with **no resolvable width is costed at the reference width**.
   Rationale for the normalization (a refinement of `DESIGN.md` §3, which states the raw
   un-normalized formula): the raw form makes `mul` at the current default width 1 collapse
   to `56·(1/32)² ≈ 0.05` FO4 and inflates a 32-bit `add_sub` to `10·log2(32) = 50` FO4.
   With the reference-width form, enabling scaling moves **no existing golden** until a
   width is genuinely inferred, and `--assume-xlen` finally affects cost instead of only
   port-dim strings.

   Golden inputs for this rule live in `fixtures/measure/width_sensitive.sv`.
3. **Real dataflow** — build a def-use map from the already-recovered `IrNode.lhs` /
   `rhs_expr` identifiers, add IR edges only where an RHS reads a definition, then
   compute **DAG longest path** in topological order (O(V+E)). Region-internal source
   order is no longer an edge source. Independent statements become independent paths.
4. **Cost-balanced cuts** — prefix-sum over the path's node costs; bisect at the first
   index reaching `total/2` (strategy `cost-balanced`), or greedily fill to
   `budget_fo4` (strategy `budget-fit`, enabling multi-cut).
5. **No phantom gains** — delete the `0.5` cost multiplier. `split_assign` either emits
   a named intermediate wire and re-measures the (unchanged) delay honestly, or reports
   `gain = 0`.
6. Re-register the dead determinism test; add goldens for 1–4. Input fixtures live under
   [`../fixtures/measure/`](../fixtures/measure/README.md) (one per defect:
   `independent_stmts`, `dep_chain_cross_region`, `seq_boundary`, `cut_imbalance`,
   `width_sensitive`).

### 1.2 As-built (P14 — implemented)

| Correction | Implementation | Tests |
|---|---|---|
| (1) expression delay | `Expr::fo4_delay` (own + `max` operand) + `Expr::fo4_area` (sum); `fo4_cost` now aliases delay | `expr::tests::fo4_delay_*` (5) |
| (2) width scaling | `measure::{REF_WIDTH, width_scale, effective_width}`, `CostModel::scaled_fo4`; widths from `build_width_map` (ports **verbatim from source** + local `logic/wire/reg` decls) resolved through `--param-map` / `--assume-xlen` / module parameter defaults (`eval_simple_int`, `width_from_dims_text`) | `measure::tests::{width_scale_is_unity_at_reference_width, scaled_fo4_orders_widths_and_floors_narrow_mul, effective_width_uses_reference_when_defaulted}`, `lower::tests::{declared_widths_scale_operator_cost, width_helpers_parse_dims_and_params}` |
| (3) real dataflow | `lower_file` builds def-use edges from `Expr::{read_symbols, written_symbol}` (module-scoped `defs` map, edges only through **combinational** defs; `IrNode::reads_reg` marks a register launch). Stage 5 moved to `measure::extract_paths` (DAG longest path in ascending-id topological order, one path per sink, `primary_loc` = hottest node) | `lower::tests::{independent_statements_are_independent_paths, dependency_chain_spans_regions_into_one_path, register_terminates_combinational_path}` |
| (4) cost-balanced cuts | `measure::cost_balanced_cut_index` (prefix-sum bisection, always leaves a node per side); used by `suggest_opportunities` and `pipeline::balanced_cut_for_path`; `estimated_fo4_after` = worst remaining segment | `measure::tests::{cut_index_isolates_the_expensive_node, cut_index_keeps_a_node_on_each_side}`, `lower::tests::cut_imbalance_opportunity_isolates_the_multiply` |
| (5) no phantom gains | `split_assign` no longer scales node cost; reports `fo4_before == fo4_after`; `run_correct_passes` stops after a split-only pass | `pipeline::tests::split_assign_claims_no_delay_gain` |
| (6) determinism test | duplicate `#[test]` removed; `rank_paths_deterministic` runs again | — |
| banner | `MEASUREMENT_VERSION` in `banner()`, `VersionBanner.measurement`, analyze JSON `versions.measurement`, schema + `js` DTO | regress suites assert the banner |

**Removed:** `lower::endpoints_for_region` — endpoints are now derived per *path*, not per region.

**Known v1 approximations** (documented, not defects): node width is taken from the
assignment **LHS** declaration, so `mul64_o` declared `[127:0]` costs a 128-bit multiply;
a definition that appears *after* its reader inside one `always_comb` is not linked (ids
are the topological order); concat-LHS (`{a,b} = …`) is not tracked as a definition.

With (1)–(6) in place, `-O2`/`-O3` are unblocked for P15. Any report produced by an older
build carries `measurement=legacy-sum` and **must not** be compared numerically with
`delay-v1` output.

---

## 2. Model calibration is part of the contract

`B_FO4 = (1000 / f_MHz) · 1000 / t_FO4,ps · (1 − margin)`

| f | `--fo4-ps` | margin | Logic budget |
|---|---|---|---|
| 1250 MHz (SoC target of record, root `AGENTS-configuration.md` §1.1) | 20 (package default) | 0.2 | 32.0 FO4 |
| 1250 MHz | 12 (12 nm FFC class) | 0.2 | 53.3 FO4 |
| 2500 MHz | 12 | 0.2 | 26.7 FO4 |
| 3500 MHz | 20 | 0.2 | **11.4 FO4** |
| 3500 MHz | 12 | 0.2 | **19.0 FO4** |

With the shipped table a single `mul` node is 56 FO4, so at ≥2.5 GHz essentially every
arithmetic cloud reports as unfixable and the correct loop will emit registers that buy
nothing. Consequences fixed by design:

- `--fo4-ps` **must** be set per process class before high-frequency runs; add named
  presets (`--fo4-preset 12nm|7nm|generic`) in P18 rather than letting 20 ps stand in.
- A `--freq-sweep` report (P18) answers "what blocks 2.0 / 2.5 / 3.0 / 3.5 GHz" per
  module instead of implying that a level can reach a frequency.
- **Honesty rule (binds every level):** an `-O` level changes *structural FO4 and the
  emitted review tree*. It never asserts silicon frequency. Root `AGENTS.md` §0.1 and
  `AGENTS-configuration.md` §1.1 fix the target of record at 1.25 GHz / 12 nm / 4 W
  fanless with a 1.5 GHz stretch; reaching multi-GHz is a micro-architecture program,
  and per `AGENTS-configuration.md` §1.0 no "closes timing" claim may cite an inferred
  row. `NG1` / `KD18` / [`STA-HANDOFF.md`](STA-HANDOFF.md) remain in force.

---

## 3. Presets

One `--opt-level` (alias `-O<n>`) selects a preset. A preset **only** sets the ten dials
in §4; it has no behavior of its own. Explicit dials always win over the preset, and the
resolved dial set is printed in the banner, emitted in the JSON `opt` block, and folded
into the cache `design_key`.

| Preset | Intent | Latency | Reassoc | New state |
|---|---|---|---|---|
| `-O0` | Analyze only; transforms hard-off (current default behavior) | none | no | none |
| `-O1` | Latency-neutral restructuring only (named intermediate wires) | unchanged | no | none |
| `-O2` | **Default when correct is enabled.** One cost-balanced `InsertReg` per over-budget path | changes (requires `--allow-latency`) | no | ≤1 stage/path |
| `-O3` | Multi-cut `pipeline_region` to budget + local statement reordering, wider worklist | changes | opt-in | many |
| `-Os` | Maximize FO4 gain **per added flop** (area/power-first, router-class SoC bias) | changes | no | minimal |
| `-Oz` | Zero new state: comb restructuring only; protocol- and latency-identical | unchanged | no | none |

`-Os` is the level that matches the target of record (4 W fanless, ~250 mW/core): it
accepts residual negative slack rather than spending flops, and orders candidates by
`Δfo4 / new_flops` instead of `Δfo4`. It uses **`budget-fit`** cuts because filling each
stage to the budget is the *flop-minimal* way to reach closure — measured on CVA6 `alu`
(1.25 GHz, `--fo4-ps 12`), `-Os` reaches the same 52.6 FO4 closure as `-O3` with **2**
inserted registers instead of 4. What separates it from `-O3` is the high `min_gain`, the
tolerated residual overage, and area-weighted ordering — not a weaker cut strategy.

> This was corrected during implementation: the first draft gave `-Os` `cost-balanced`
> cuts, which on real RTL spent the *same* flops as `-O3` for a *worse* result. Presets
> are only credible when measured.

There is deliberately **no `-Ofast`**. Equivalence-risky reshaping is a single explicit
dial (`--opt-allow-reassoc`), never a preset side effect, because `NG7` gives us no
formal equivalence check.

### 3.1 Preset → dial matrix

| Dial | `-O0` | `-O1` | `-O2` | `-O3` | `-Os` | `-Oz` |
|---|---|---|---|---|---|---|
| `opt_max_passes` | 0 | 2 | 4 | 16 | 4 | 2 |
| `opt_worklist_width` | 0 | 1 | 1 | 4 | 2 | 1 |
| `opt_cut_strategy` | — | — | `cost-balanced` | `budget-fit` | `budget-fit` | — |
| `opt_max_stages_per_region` | 0 | 0 | 1 | 8 | 2 | 0 |
| `opt_min_gain_fo4` | — | 1.0 | 2.0 | 1.0 | 4.0 | 1.0 |
| `opt_slack_target_fo4` | — | 0.0 | 0.0 | 0.0 | −4.0 | 0.0 |
| `opt_area_weight` | — | 0.0 | 0.0 | 0.0 | 1.0 | 0.0 |
| `opt_allow_reassoc` | false | false | false | opt-in | false | false |
| `opt_effort` | `fast` | `balanced` | `balanced` | `thorough` | `balanced` | `balanced` |
| `opt_jobs` / `opt_cache_mode` | auto / `unit` | auto / `unit` | auto / `unit` | auto / `unit` | auto / `unit` | auto / `unit` |

---

### 3.2 As-built (P15 — implemented)

| Piece | Implementation |
|---|---|
| Level + dials | `crates/sv-timing-core/src/opt.rs`: `OptLevel`, `CutStrategy`, `OptEffort`, `CacheMode`, `OptOptions::preset` (the §3.1 matrix **is** the code), `OptOverrides`, `resolve`, `digest`, `summary`, `allows_new_state` |
| Policy | `PassPolicy::{from_opt, with_opt}` + `PassPolicy.opt`; `WorklistPolicy::{candidate_pool, width}` (the pool/width split fixes "build 32, use 1") |
| Driver | `run_correct_passes` honors dials 1, 2, 4, 5, 6, 7 (+ `worklist::order_by_area_weight`); `-O0` returns after `measure()` |
| Cuts | `pipeline::balanced_cut_for_path` dispatches dial 3; `budget_fit_cut_index` added |
| Analysis | `LowerOptions.opt`; dial 9 `fast` skips `stitch_cross_module_paths`; dial 10b `off` bypasses SQLite |
| Cache | design key folds `#measurement=…` + `#opt=<digest>` (namespaced tokens) |
| CLI | flattened `OptArgs` on `analyze` + `correct`: `-O/--opt-level` + ten `--opt-*` flags; resolved set echoed as `opt=…`; `--max-passes` kept as a deprecated alias; a note is printed when a level *would* pipeline but `--allow-latency` is absent |
| Contract | `opt` block in analyze/correct JSON, `schemas/analyze-result.v1.json`, `js/src/types.ts` (`OptResultDto`/`OptDialsDto`) |

Measured (`correct --dry-run`, worst path FO4 before → after):

| Level | `deep_add_chain` @3 GHz, budget 13.3 | CVA6 `alu` @1.25 GHz `--fo4-ps 12`, budget 53.3 |
|---|---|---|
| `-O0` | 0 edits, 26.0 → 26.0 | — (analyze only) |
| `-O1` | 1 edit, 26.0 → 26.0 | latency-neutral |
| `-O2` | 2 edits, 26.0 → 16.7 | 2 edits, 87.0 → 59.5 |
| `-O3` | 3 edits, 26.0 → **9.3, closes** | 4 edits, 87.0 → **52.6, closes** |
| `-Os` | 3 edits, 26.0 → **9.3, closes** | **2** edits, 87.0 → **52.6, closes** |
| `-Oz` | 1 edit, 26.0 → 26.0 | latency-neutral |

On the small fixture every candidate clears `min_gain`, so `-Os` and `-O3` coincide; on real
RTL the area weighting shows up as **half the flops for the same closure**.

**Not yet consumed:** dial 8 `allow_reassoc` is plumbed and reported but no transform reads
it (`rearrange_cone` / `reorder_statements_local` are still stubs), and dial 10a `jobs` /
`cache_mode ∈ {unit, full}` are reserved for P16/P17 (`unit` behaves as `ir` until the
units tier exists).

---

## 4. The ten dials (authoritative)

| # | Dial | CLI | Type / default | Meaning |
|---|---|---|---|---|
| 1 | `max_passes` | `--opt-max-passes` | u32, 4 | Transform iterations. Supersedes `--max-passes` (kept as a deprecated alias). |
| 2 | `worklist_width` | `--opt-worklist-width` | usize, 1 | Work items **applied** per pass. Fixed the old waste where `order_worklist` built 32 candidates and the driver consumed exactly one; the pool is now `WorklistPolicy::candidate_pool` and this dial is `WorklistPolicy::width`. |
| 3 | `cut_strategy` | `--opt-cut-strategy` | enum, `cost-balanced` | `mid-node` (legacy index midpoint), `cost-balanced` (prefix-sum bisection), `budget-fit` (greedy fill to `budget_fo4`, prerequisite for multi-cut). |
| 4 | `max_stages_per_region` | `--opt-max-stages-per-region` | u32, 1 | Multi-cut depth for `pipeline_region`. `>1` implies `budget-fit`. |
| 5 | `min_gain_fo4` | `--opt-min-gain-fo4` | f64, 2.0 | Reject any edit whose predicted `fo4_before − fo4_after` is below this. Terminates futile passes and is the guard that makes M4 impossible to reintroduce. |
| 6 | `slack_target_fo4` | `--opt-slack-target-fo4` | f64, 0.0 | Stop condition. `0.0` = just close; `> 0` = keep positive margin; `< 0` = accept residual overage (`-Os`). Replaces the hard-coded `slack >= 0.0` break. |
| 7 | `area_weight` | `--opt-area-weight` | f64, 0.0 | Candidate ordering key becomes `Δfo4 − area_weight · (new_flops·W_flop + new_wires·W_wire)`. `0.0` = pure timing; `1.0` = `-Os`. |
| 8 | `allow_reassoc` | `--opt-allow-reassoc` | bool, false | Enables `rearrange_cone` / `reorder_statements_local` algebraic reshaping. Every such edit carries `equivalence=unverified` in the `EditTrace` and a banner warning. |
| 9 | `effort` | `--opt-effort` | enum, `balanced` | Analysis depth (independent of transform strength): `fast` = per-module paths only, expression depth cap, no cross-module stitch; `balanced` = today's behavior + stitch; `thorough` = full endpoint enumeration, no depth cap, cross-module stitch with bridge nets. |
| 10 | `jobs` / `cache_mode` | `--opt-jobs`, `--opt-cache-mode` | usize `auto`; enum `unit` | Parallel parse/digest degree, and cache tier: `off` \| `ir` (today) \| `unit` (pre-compiled per-file units) \| `full` (units + design blob). See [`PERF-CACHE.md`](PERF-CACHE.md). |

Existing safety gates are **orthogonal and unchanged**: `--correct-enabled`,
`--correct-allow` / `--modules-allow`, `--allow-latency`, `--refuse-path-prefix`,
`--refuse-instance-types`, `--emit` (dry-run default), `--out-dir` containment. A level
never relaxes a gate: `-O3` without `--allow-latency` still refuses `InsertReg` — it
degrades to `-O1` behavior and says so.

---

## 5. Where the dials live

| Layer | Change |
|---|---|
| `sv-timing-core` | `OptOptions` struct + `OptLevel` enum + `resolve(level, overrides) -> OptOptions`; re-exported. `LowerOptions` gains `effort` (dial 9) since it governs path extraction. |
| `sv-timing-transform` | `PassPolicy` absorbs dials 1–8 (`max_passes` moves, `worklist` policy gains `width`); `WorklistPolicy.max_items` becomes `candidate_pool` and `width` is what the driver applies. |
| `sv-timing-cli` | `-O` / `--opt-*` flags on `analyze` (dials 9–10) and `correct` (all ten); resolved set echoed in the banner. |
| `sv-timing-cache` | `design_key` includes the resolved dial digest + `measurement` version, so an `-O` change cannot serve a stale blob. `cache_mode` selects the tier. |
| `schemas/analyze-result.v1.json` | Additive `opt` object: `{ level, dials{…}, measurement, warnings[] }`. Additive-only ⇒ no schema major bump (KD16). |
| `js/timings-types.ts` | Mirror the `opt` object. |
| Host (`build-platform`) | Optional `timings.optLevel` + `timings.optDials` passthrough. Outside this package (KD0/KD10); no default change. |

---

## 6. Testing (must ship with P15)

| Layer | Test |
|---|---|
| Unit | `opt_level_presets_resolve_to_matrix` (§3.1 table is the fixture); `explicit_dial_overrides_preset`; `o3_without_allow_latency_degrades_not_errors`. |
| Unit | `cut_strategy_cost_balanced_splits_by_cost` (mul+8×logic_bit fixture ⇒ cut after the mul, not at the index midpoint). |
| Unit | `min_gain_fo4_blocks_futile_edit`; `slack_target_positive_keeps_pipelining`; `area_weight_prefers_fewer_flops` (`-Os` vs `-O2` on the same fixture ⇒ ≤ flops, ≥ residual overage). |
| Determinism | `rank_paths_deterministic` re-registered; `worklist_width_gt_1_is_order_stable`. |
| Golden | `fixtures/auto_correct/*` per level: edit count, flops added, FO4 before/after, reparse integrity. |
| Cache | `opt_level_change_invalidates_design_key`. |
| Integrity | Every level still satisfies `integrity_reparse` + `integrity_structural`; `-Oz` asserts **zero** new `always_ff` in the emit tree. |

---

## 7. Non-goals

- No `-Ofast`; no implicit equivalence risk (see §3).
- No level auto-enables `--emit`, widens an allowlist, or bypasses a refuse list.
- No absolute FO4 CI gate (`KD18` stands), including per level.
- No claim that a level reaches a target frequency (§2 honesty rule).

## Validated monorepo soak (merged FO4 stack)

- sparse_ex @ 2000/2500 MHz closes with `--allow-latency --emit` (primary → ~20 / ~16 FO4).
- sparse_frontend @ 2000/2500 MHz closes similarly.
- See [MONOREPO-SOAK.md](MONOREPO-SOAK.md) and [FO4-ALGORITHM-UPGRADES.md](FO4-ALGORITHM-UPGRADES.md).
