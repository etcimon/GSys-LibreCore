# AGENTS-auto-correct — Multi-pass timing precompiler

> Companion to [`AGENTS.md`](AGENTS.md).  
> **Design detail:** [`architecture/AUTO-CORRECT-CORE-API.md`](architecture/AUTO-CORRECT-CORE-API.md)  
> **Gates / policy:** [`architecture/DESIGN.md`](architecture/DESIGN.md) § Auto-correct  
> **Strength / levels:** [`architecture/OPTIMIZATION-LEVELS.md`](architecture/OPTIMIZATION-LEVELS.md) (`-O` presets + ten dials, and the measurement defects M1–M7 that gate them)

## Agent rules

1. Implement transforms **on IR + NameTable**, not primary-path text regex.
2. Every automatic edit must call `record_edit` with `SourceLoc` (original file:line).
3. Inserted registers always require **allow-latency** + complete `GateInfo`.
4. After each successful correct pass: `remeasure`; before write: `integrity_reparse` + structural.
5. Emit only under `--emit-dir`; never overwrite sources by default.
6. Prefer extending functions listed in AUTO-CORRECT-CORE-API over inventing parallel APIs.
7. Update `AGENTS-todo.md` when a catalog function moves from stub → real.
8. **Never report a gain a transform did not cause.** Cost adjustments without a structural
   counterpart are forbidden (see `OPTIMIZATION-LEVELS.md` M4); an edge case with no real
   improvement reports `gain = 0` and is rejected by `opt_min_gain_fo4`.
9. Cut sites are chosen by **cost**, not by node index (M5); relocation targets the IR node's
   byte span, not a nearby source line (M7).
10. **`always_ff` keeps a clock-aware scratch.** `ParallelScratch::schedule_for_region`
    binds `ClockDomain` from `GateInfo`; `fill_design_parallel_timing` stores the
    full board on `ModuleParallelTiming.regions[id]`. Never replace that with a
    combinational `schedule` of `path.nodes`. Factorize / JIT / OpenSTA seeds
    read `scratch.clock` (name, edge, period, \(B\)).
11. **Per-module cleanliness.** Explore only logically applicable algorithm sets
    (region kind + cone lane). Pick a timing-passing set when one exists, else
    max \(C\) with the fail penalty. Weight \(C\) toward `always_ff` /
    `always_comb` density; more aggressive sets (InsertReg, multi-cut) score
    less clean. The winner’s \(C\) is the module’s final cleanliness.

## Pass loop (copy for PR descriptions)

```text
measure → order_worklist (worst slack first) → one bounded transform
  → expand_name_definitions → remeasure → record_edit
  → (repeat until budget or max_passes)
  → synthesize_design → annotate_origin_comments
  → integrity_reparse + integrity_structural → write_emit_tree
```

## Tests agents must keep green

| Layer | Command / location |
|---|---|
| Unit naming/rank | `crates/sv-timing-core` / `transform` tests |
| Reparse integrity | `transform` / `emit` integrity tests |
| Fixtures | `fixtures/auto_correct/*` |
| Optional lint/sim | `SV_TIMING_LINT=1` / `SV_TIMING_SIM=1` |

## Debug exports

When diagnosing a bad rewrite, call / CLI-export:

- `debug_dump_ir_json`
- `debug_dump_paths_csv`
- `debug_dump_edit_trace`
- `debug_snapshot_pass` (per-pass directory)
- `--trace-log PATH` JSONL algorithm trace (`measure` / `scale` / `worklist` / `apply` / `refuse`)

Never ship auto-correct without origin comments on new constructs.
