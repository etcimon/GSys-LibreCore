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

## Transform catalog (as built, 2026-10-16) — exactness and area

Planner order within a pass is latency-neutral first; it is also the area
order (ALGORITHMS-EXPERTS A102). Every structural rewrite is emitted into the
origin file; a transform that cannot emit safely stays **credit-only** and
the trace says so.

| Transform | Kind | Shape | Exactness | Area | Evidence |
|---|---|---|---|---|---|
| `LoopRewrite` (A101/A103/A104) | latency-neutral, ranked first with `SelectIncrement` | serial `for` walks: **FindFirst** (`if (v[i] && pick == 0) pick = i`, flag form), **CondCount** (`if (c) cnt = cnt + 1`), **RingWalk** (`cid = a; … if (cid == b) break; … cid++`), **StreamCompact** (`if (keep) { out[dst] = f(k); dst++ }`), **OneHotSelect** (`if (G[e]) { x = y(e) }` with the module asserting `$onehot0(G)`) → lowest-set-bit / `$countones` / interval membership / prefix popcounts + one-hot gather / AND-OR accumulate | exact under the shape's conditions (`fixtures/auto_correct/{loop_walks,stream_compact,onehot_select,find_first_equiv}.sv`; SAT at 16/32 bits, sequential miter N = 8); OneHotSelect is **invariant-tagged** — the design's assertion is the proof obligation; loops in functions/generate blocks skipped | **negative** (fixture −90 %; compaction −4.5 % at N = 8; AND-OR ≈ neutral) | A101 fixture 14.5 → 0.91 ns mapped |
| `SelectIncrement` (A88/A91) | latency-neutral | `LHS = REG + step` (k ≤ 4 step bits) → `2^k` precomputed increments + one select; the runtime index mux is billed (delay-v33) | exact (SAT 12-step from reset) | **positive, bounded** (`MAX_CANDIDATE_BITS` 512; ≈ +3 % of `instr_queue`) | slack 0.055 → 0.073 ns at 1 ns |
| `BalanceMux` (one-hot tree / hot-arm staging) | latency-neutral | exclusive `case` arms → AND-OR tree over the 16 deepest safe arms; **the tree's arm set and the rewritten labels are one set** (`onehot_usable_arms`); once per origin | exact under `unique case` | neutral to negative (alu `result_o`) | A102 |
| `RebalanceAssoc` | latency-neutral | reassociation, `\|a \|\| \|b \|\| \|c` → `\|{a,b,c}` (delay-v34) | exact | neutral | emitted RHS, reparse |
| `SplitAssign` | latency-neutral | split one assign into two nets | exact | neutral | |
| `InsertReg` (`--allow-latency`) | **changes latency** (S4, last) | register cut at the cost-chosen site; feed and origin are **one decision** (`cut_assigns_from_source`: a cut whose feed cannot be real keeps its origin; a feed reading a peer cut's LHS is real); enum/struct LHS samples through `type(lhs)'(…)` | protocol change — study only; validated by the host's `--allow-over-budget` label | **positive** (flops: 10–30 % of a small module for a 64-bit cut) | A102 |

Measurement truths the transforms depend on (versioned `MEASUREMENT_VERSION`,
`crates/sv-timing-core/src/version.rs`): delay-v29 widths, v31 N-operand
sums, v32 incrementers, v33 runtime index mux, v34 `\|\|`, v35 loop-carried
trips, v36 find-first guards, **v37 guards as reads + mux, field-granular
index-aware carry**. A version bump invalidates cached measurements.

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
