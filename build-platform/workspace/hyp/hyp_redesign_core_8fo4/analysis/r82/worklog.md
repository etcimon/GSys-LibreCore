# r82 worklog — sv-timing E6 measurement fixes (diagnosis complete, implementation pending)

## Fixtures
- `sv-timing/fixtures/fn_zero_len_range.sv` (r79): reproduces defect A — ~20 FO4 on the consumer arm of a dead `is_inside_*` call.
- `sv-timing/fixtures/localparam_gate_fold.sv` (r82): reproduces defect B — `REC = (Stages==2)` gating `y = REC ? r_q : f(a)` + a generate-if pair.

## Defect A root cause (verified in source)
`crates/sv-timing-core/src/expr.rs` `const_class` — `Expr::Call` returns `Const` only for `is_elab_system_fn` with all-const args; a package function like `is_inside_nonidempotent_regions` is opaque → `Unknown`/`Runtime` → billed. Package function bodies are "kept off the delay graph" (`lower.rs:498`) — the IR stores function names only (`ir.rs:697/973`), not evaluable bodies. Folding it needs either (i) a package-function evaluator (loop-unrolled `for` over const rule arrays + expr evaluation), or (ii) expression simplification reaching inside the call — neither exists.

## Defect B root cause (verified in source)
`expr.rs:530` — `if cond.const_class(seed).is_const() { return max(then, else) }`: on a constant condition the ternary bills BOTH arms instead of evaluating WHICH is live. Same shape at `expr.rs:941` (critical_spine). The lattice (`ConstClass`) tracks constness, not values; `ConstSeed` has names only (`names: BTreeSet<String>`) though `Design.param_map_ints: BTreeMap<String,i64>` (ir.rs:1014) already holds bound parameter values — and localparam defaults are stored as expression text per module (`ir.rs:708`).

## Implementation plan (next session)
1. `ConstSeed.values: BTreeMap<String,i64>` — seeded at `measure.rs:133` + `pass_strategy.rs:194` from `param_map_ints` + iteratively-evaluated localparam defaults (parse `param_defaults` text → eval with the param values; topological passes until fixpoint).
2. `Expr::const_value(seed) -> Option<i64>`: literal parse (`positive_literal_value` exists), ident→`seed.values`, unary/binary eval when both sides valued, `&&`/`||` short-circuit on a const operand, unsigned `x<0 → 0`/`x>=0 → 1`, `$clog2`/`$bits`/inside over valued args, ternary→arm pick.
3. `expr.rs:530`/`:941` — `if let Some(v) = cond.const_value(seed) { return live_arm }` replacing the `max(then,else)` — fixes B.
4. Defect A needs package-function body evaluation (bodies are in the package IR's `functions` — check whether `lower.rs` retains statement lists for them; if not, add them under `ir.rs` Package). Evaluator: unrolled `for` loops over const arrays, statement-level assigns to a local env, `return expr.const_value`.
5. Bump `ir`/`delay` version per `correction-v5` precedent; goldens for both fixtures; `python tools/svt.py test` + `check`.

## (B) implementation — delay-v45 / ir-v6

expr.rs: `ConstSeed.values: BTreeMap<String,i64>`;
`Expr::const_value(seed)` (literal/ident/unary/binary/short-circuit
`&&`/`||`/`$clog2`/ternary-arm); folds at `fo4_critical_cost_latticed`
and `critical_spine_ops_latticed` pick the live arm when the cond
resolves (else today's max fallback). `Expr::walk_read_idents(seed,f)`
= fold-aware read walk (dead-arm idents are not dependencies).

ir.rs: `Design::elaboration_const_seed(module)` — seed names+values
via `WidthResolver` over `elaboration_const_names` + module
`const_exprs` + `TypedParameter` defaults (header `#(parameter)`).
Called at measure.rs:133 + pass_strategy.rs:194.

lower.rs: `collect_const_exprs_in` extended to
`LocalParameterDeclaration::Param` + `ParamAssignment` nested in
lists — `const_exprs` now actually populates (was a top-level-only
scan that silently produced `{}` — the header `parameter` and module
`localparam` defaults were never captured).

ref_order.rs: `dep_fold_seed` (module-local `WidthResolver` over
`const_exprs`) + `collect_dep_reads_fold` → `walk_read_idents` in
`RefOrderTree::from_nodes` — dead-arm reads no longer create dep
edges.

version.rs: `IR_VERSION` ir-v6 (`const_exprs` fill invalidates
cached IR); `MEASUREMENT_VERSION` delay-v45.

Fixture `fixtures/localparam_gate_fold.sv` (registered in
fixtures/filelist.txt — needs checking): `Stages=1` → `REC=0` →
`y_o = REC ? g_a : r_q` folds to `r_q` — the `g_a` multiply arm is
dead. Verified: seed `values={REC:0, Stages:1}`, fold fires
`value=Some(0)`.

Residual (documented): `g_a`'s own node still appears on the
`in0→out0` path — the region's path enumeration at lower.rs:712
lists region nodes; a dead-arm-only assign remains a region node
with its own billed cost until the node itself is pruned at
lowering (a structural change beyond this measurement fold).

## Verification (r82 (B))

- `cargo test -p sv-timing-core`: 270 passed / 0 failed.
- `python tools/svt.py test`: fails at `sv-timing-transform` TEST
  build — `TimingModule`/`TimingPath` literals at
  `pipeline.rs:4290`, `worklist.rs:485`, `worklist.rs:561` miss
  `stage_decls`/`stage_start`/`stage_end` — fields added by
  `63ff80b61` (stage-aware FO4), NOT this pass; the literals are
  unchanged by r82. Pre-existing test drift; core crate green.
- `python tools/check_independence.py`: FAILED listing only
  pre-existing `sv-timing-emit` fixture literals
  (`ariane_pkg`/`CVA6Cfg` in rhs.rs test strings) and `tools/`
  soak paths — no r82 file appears.
- Boards (release binary, `ir-v6`/`delay-v45` banner):
  `analyze-r82-lu.json` 37.2 unchanged (into-L5); `analyze-r82-all`
  diff vs `analyze-r81-all` = every row +0.0 — the fold is a
  measurement-semantics correction with no net core-path move on
  this design's gated-ternary population.
- Fixture `localparam_gate_fold`: before = `g_a` multiply billed
  through both arms (~22 FO4 single-node on out0); after =
  `cond.const_value` resolves `REC=0`, the ternary bills `r_q`
  only — fold verified firing.
