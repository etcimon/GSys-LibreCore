# `fixtures/measure/` — measurement / lowering goldens

Input fixtures that pin the corrections in
[`../../architecture/OPTIMIZATION-LEVELS.md`](../../architecture/OPTIMIZATION-LEVELS.md) §1.1
(P14 measurement truth) and [`../../architecture/PERF-CACHE.md`](../../architecture/PERF-CACHE.md)
§1.1 (P16 lowering scope). Each file's header states the property it exists to enforce.
**Status: implemented and asserted** — see the test column.

| Fixture | Defect pinned | Expected (post-P14) | Legacy behavior (pre-P14) |
|---|---|---|---|
| `independent_stmts.sv` | M1 dataflow vs source order | 6 independent sinks ⇒ 6 shallow paths; worst ≈ **one** `add_sub` | 1 path, ≈6× the FO4 |
| `dep_chain_cross_region.sv` | M1 cross-region chaining | 1 worst path over all 4 chained adds | 3 per-region paths ⇒ under-estimate |
| `seq_boundary.sv` | M1 register terminates a path | pre-flop path ends at `RegData`; post-flop path starts at the reg; kinds `in→reg` / `reg→out` | risk of chaining through the flop |
| `cut_imbalance.sv` | M5 cost-balanced cut | cut immediately **after** the multiply (≈56 / ≈8) | index midpoint (≈59 / ≈5) — buys nothing |
| `width_sensitive.sv` | M3 width scaling (ref width 32) | `add64 > add8 > add1`, floored at `logic_bit`; unresolved width ⇒ `width_defaulted`, cost == base | width always 1, all widths equal |
| `two_modules.sv` | **B3** per-module CST scoping (P16) | each module sees only its own ports / params / regions; the instance belongs to `holder_b` alone | every module inherited the *union* of both, all instances went to the first module |

## Asserting tests

| Fixture | Test |
|---|---|
| `independent_stmts.sv` | `lower::tests::independent_statements_are_independent_paths` |
| `dep_chain_cross_region.sv` | `lower::tests::dependency_chain_spans_regions_into_one_path` |
| `seq_boundary.sv` | `lower::tests::register_terminates_combinational_path` |
| `cut_imbalance.sv` | `lower::tests::cut_imbalance_opportunity_isolates_the_multiply` |
| `width_sensitive.sv` | `lower::tests::declared_widths_scale_operator_cost` |
| `two_modules.sv` | `lower::tests::multi_module_file_scopes_ports_regions_and_instances` |

```bash
python tools/svt.py test -p sv-timing-core --lib
```

## Running them by hand

```bash
# from sv-timing/
python tools/svt.py run -- analyze \
  --files-from fixtures/measure/measure.f \
  --all-modules --target-mhz 1250 --fo4-ps 12 \
  --assume-xlen 64 --json-out .sv-timing-out/measure.json

python tools/svt.py run -- correct \
  --files-from fixtures/measure/measure.f \
  --modules cut_imbalance --target-mhz 2500 \
  --allow-latency --assume-clk --dry-run
```

## Reference-width convention (M3)

`fo4-v1` base values are read as the cost at **reference width 32**. Scaling is therefore
normalized (`add_sub`/`compare`/`shift_var` ∝ `log2(w)/log2(32)`, `mul` ∝ `(w/32)²`,
`div_rem` ∝ `w/32`, bit/mux/concat unscaled), every scaled cost is floored at
`min(base, logic_bit)` — so a 1-bit multiply costs one gate while `concat` (cheaper than a
gate by design) is not raised — and a node with no resolvable width is costed at the
reference width. Consequence: turning
scaling on does **not** move any existing golden until a width is actually inferred — which
is why these fixtures declare their widths explicitly.

Observed on `dep_chain_cross_region` at `--fo4-ps 12`: the four chained adds are
9/10/11/12 bits wide, so the worst path is `6.34 + 6.64 + 6.92 + 7.17 ≈ 27.07` FO4 — a
single path spanning both `always_comb` blocks and the continuous assign.
