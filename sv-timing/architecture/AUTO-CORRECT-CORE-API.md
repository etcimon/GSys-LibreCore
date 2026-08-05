# Auto-correct multi-pass core API

> Companion to [`DESIGN.md`](DESIGN.md) § Auto-correct.  
> **Status:** **Implemented** in `sv-timing-core` / `transform` / `emit` (latency-neutral BalanceMux +
> rebalance + path_class; InsertReg gated). Living surface — prefer this catalog over ad-hoc CLI flags.  
> **Discipline:** measure → transform conservatively → re-measure → integrity → emit.  
> **Never** rewrite by regex on source text as the primary path; operate on timing IR + symbol tables.
> Emit trees are **review-only** (never auto-merge into host `core/`).


---

## 1. Why a multi-pass function library

Auto-correct is not a single rewrite. It is a **pipeline of pure-ish library functions** reused across:

| Pass family | Uses |
|---|---|
| **Analyze** | parse, lower, measure, rank (valgrind-style cost order) |
| **Correct** | expand/name, pipeline, rearrange, mangle, annotate traces, re-measure |
| **Emit** | synthesize files/modules, comment origins, write tree |
| **Integrity** | reparse, structural checks, optional lint/sim harness |
| **Debug** | export IR/AST snapshots, edit traces, path rankings |

Every function below is designed to be **called more than once** (outer loop + inner local rewrites).

---

## 2. Shared types (conceptual)

```text
DesignId, ModuleId, SignalId, NodeId, PathId, RegionId, FileId
SourceLoc { file, start_line, start_col, end_line, end_col, origin }
GateInfo { clock?, edge?, enable?, reset?, is_comb }
TimingDesign          // modules + paths + opportunities + target + versions
SymbolTable           // scope → bindings
NameTable             // unique name allocator + mangling policy
EditTrace             // ordered list of EditRecord (why/where/what)
EmitTree              // logical files to write (path → text + metadata)
PassContext           // design + symbols + names + trace + policy + budget
IntegrityReport       // reparse_ok, lint, sim, structural findings
DebugExport           // IR/AST/json dumps for diagnosis
```

**PassContext** is the bag every multi-pass algorithm takes and returns (or mutates under `&mut`).

---

## 3. Core function catalog

Grouped by concern. Signatures are **library surface** (Rust names may use `snake_case`).

### 3.1 Ingest & lower (analyze foundation)

| Function | Args | Description |
|---|---|---|
| `parse_paths` | `paths, ParseOptions` | Vendored sv-parser CST + line index (exists). |
| `build_symbol_table` | `&ParsedUnit` → `SymbolTable` | Bind modules, ports, locals, packages (progressive P1→P1.5). |
| `lower_to_ir` | `&ParsedUnit, &SymbolTable, LowerOptions` → `TimingDesign` | always_ff/comb, assigns, ops, gates, endpoints. |
| `attach_origins` | `&mut TimingDesign, &ParsedUnit` | Ensure every IR node has `SourceLoc` / origin kind. |

### 3.2 Measure & rank (“timing valgrind”)

Analogous to a **profiler**: attribute structural cost, order worst first, never claim STA numbers.

| Function | Args | Description |
|---|---|---|
| `attribute_costs` | `&mut TimingDesign, &CostModel` | FO4 (or future models) on each op/region. |
| `extract_paths` | `&TimingDesign` → `Vec<TimingPath>` | reg→reg / in→reg / reg→out / in→out within modules (v1). |
| `rank_paths_by_slack` | `paths, TimingTarget` → `RankedPaths` | Sort by ascending slack (worst first); multi-cycle segregated. |
| `rank_regions_by_cost` | `&TimingDesign, top_n` → `Vec<RegionReport>` | Hottest combinational clouds. |
| `line_cost_map` | `&TimingDesign` → `BTreeMap<(FileId,line), f64>` | Line-by-line cost for reports. |
| `suggest_opportunities` | `&TimingDesign, Policy` → `Vec<Opportunity>` | InsertReg / SplitAssign candidates. |
| `remeasure` | `&mut PassContext` | After a transform: re-cost + re-extract + re-rank only dirty modules. |

### 3.3 Naming & expansion conventions

Unique, traceable names for expanded hierarchy, new regs, and split wires.

| Function | Args | Description |
|---|---|---|
| `NamePolicy::default_sv_timing` | — | Prefixes: `svt_`, pipe: `_pN_`, split: `_w`, file: `__svt`. |
| `NameTable::alloc_signal` | `&mut self, scope, stem, SourceLoc` → `SignalId` | Unique signal in scope; records origin. |
| `NameTable::alloc_module` | `&mut self, stem, SourceLoc` → `ModuleId` | Unique module name (flattened/expanded). |
| `NameTable::alloc_file` | `&mut self, stem, role` → `PathBuf` | Logical emit path under emit root. |
| `expand_name_definitions` | `&mut PassContext, ExpandOptions` | Materialize pending name defs into IR decls (wires/regs/modules). |
| `mangle_identifier` | `raw, MangleStyle` → `String` | Safe SV identifier (escape, length, keywords). |
| `demangle_trace` | `mangled` → `Option<OriginRef>` | Reverse map for debug comments. |

**Conventions (v1 defaults):**

| Entity | Pattern | Example |
|---|---|---|
| Inserted reg | `{stem}_svt_p{stage}` | `sum_svt_p1` |
| Split wire | `{stem}_svt_w{n}` | `prod_svt_w0` |
| Expanded module clone | `{mod}_svt_x{n}` | `alu_svt_x0` (if hierarchy expand) |
| Emit file | `{stem}__svt.sv` or keep original + sidecar | `comb_adder_cloud__svt.sv` |
| Debug comment | `// sv-timing: origin {file}:{line}:{col} edit={id}` | |

### 3.4 Ordering, reordering, rearranging

| Function | Args | Description |
|---|---|---|
| `order_worklist` | `RankedPaths, WorklistPolicy` → `Vec<WorkItem>` | Convert ranked paths into a stable worklist (deterministic tie-break: file, line, path_id). |
| `reorder_statements_local` | `&mut Region, ReorderHeuristic` | Commute independent ops to shorten critical chain when proven independent (v1: conservative no-op if unsure). |
| `rearrange_cone` | `&mut TimingDesign, RegionId, Shape` | Local algebraic reshape (e.g. reassociate adds) under equivalence flags. |
| `schedule_pipeline_cuts` | `&RankedPaths, budget_fo4` → `Vec<CutPoint>` | Choose cut sites so no cloud exceeds budget. Strategy comes from dial 3 (`mid-node` \| `cost-balanced` \| `budget-fit`); prefix-sum bisection, not index midpoint. |

### 3.5 Pipelining

| Function | Args | Description |
|---|---|---|
| `select_pipeline_cuts` | `&PassContext, Opportunity` → `Result<CutPlan>` | Validate clock/enable in scope; refuse incomplete `GateInfo`. |
| `insert_register` | `&mut PassContext, CutPlan` → `EditRecord` | Insert seq cell + wire rename; **always** latency-changing; requires allow-latency. |
| `split_assign` | `&mut PassContext, NodeId` → `EditRecord` | Break deep assign into named wires (no latency change). |
| `pipeline_region` | `&mut PassContext, RegionId, stages` → `Vec<EditRecord>` | Multi-cut pipeline of one region using `schedule_pipeline_cuts` + `insert_register`. |

### 3.6 Debug traces & comments

| Function | Args | Description |
|---|---|---|
| `annotate_origin_comments` | `&mut EmitTree, &EditTrace` | Inject `// sv-timing: origin file:line` above new/changed constructs. |
| `record_edit` | `&mut EditTrace, EditRecord` | Append why/where/before/after FO4. |
| `format_edit_trace` | `&EditTrace` → `String` / JSON | Human + machine export. |
| `export_debug_bundle` | `&PassContext, DebugOptions` → `DebugExport` | IR snapshot, ranked paths, name table, edits, optional CST digests. |

### 3.7 File structure & synthesis (emit)

| Function | Args | Description |
|---|---|---|
| `plan_emit_tree` | `&TimingDesign, &NameTable, EmitPolicy` → `EmitTree` | Decide files/modules to write (in-place vs sidecar tree). |
| `add_file` | `&mut EmitTree, path, role` | Register a new logical file. |
| `synthesize_module` | `&TimingModule, SynthOptions` → `String` | SV text for one module (decls + always/assign). |
| `synthesize_design` | `&PassContext, EmitPolicy` → `EmitTree` | Full design text with headers + origin comments. |
| `write_emit_tree` | `&EmitTree, root_dir` → `Vec<PathBuf>` | Atomic-ish write under emit root only. |
| `load_filelist` | `path, FileListOptions` → `FileList` | Portable `.f` (paths, +incdir+, +define+, nested `-f`). |
| `Expr::parse` / `emit` / `fo4_cost` / `dominant_op_class` | text ↔ expression tree | Denser assign RHS/LHS IR; FO4 = sum of op nodes. |
| STA handoff | (docs) | [`STA-HANDOFF.md`](STA-HANDOFF.md) — FO4 is not WNS. |
| `edits_for_source` | `&EditTrace, source_path` → `EditTrace` | Per-file edit isolation for multi-module projects. |
| `synthesize_project` / `emit_project_autocorrect` | sources, trace, policy, `ProjectEmitOptions` | Multi-file emit under **out_dir**; new modules; `svt_corrected.f` + manifest. |

See [`PROJECT-AUTOCORRECT.md`](PROJECT-AUTOCORRECT.md) for CLI `--out-dir` / `--all-modules` and host vs package flist boundary.

### 3.8 Multi-pass driver

| Function | Args | Description |
|---|---|---|
| `PassPolicy` | allowlist, max_passes, allow_latency, refuse_*, budget | Gates from DESIGN. |
| `run_correct_passes` | `PassContext, PassPolicy` → `Result<PassContext>` | Loop: measure → order_worklist → one transform → remeasure → stop. |
| `run_analyze_only` | `paths, options` → `TimingDesign` | No transforms. |

### 3.9 Integrity & validation (tests + runtime)

| Function | Args | Description |
|---|---|---|
| `integrity_reparse` | `&EmitTree, ParseOptions` → `IntegrityReport` | Every emitted file parses with same sv-parser. |
| `integrity_structural` | `&TimingDesign, &EmitTree` | No multi-driver; unique names; clock connectivity on new flops. |
| `integrity_lint_external` | `&EmitTree, LintBackend` | Optional: invoke host linter (slang/verilator -Wall); skip if absent. |
| `integrity_sim_external` | `&EmitTree, SimContract` | Optional: run TB with **stated latency**; skip if no TB. |
| `assert_valid_sv_bundle` | report | Fail test if reparse/structural fail (lint/sim soft unless enabled). |

### 3.10 AST / synthesis debug exports

| Function | Args | Description |
|---|---|---|
| `debug_dump_ir_json` | `&TimingDesign, path` | Machine IR for dashboards. |
| `debug_dump_paths_csv` | `&RankedPaths, path` | Worst-first path table. |
| `debug_dump_name_table` | `&NameTable, path` | Mangling / uniqueness audit. |
| `debug_dump_edit_trace` | `&EditTrace, path` | Auto-correct justification. |
| `debug_snapshot_pass` | `&PassContext, dir, tag` | Full bundle after pass *N* (for flaky transforms). |

---

## 4. Pass graph (normative loop)

```text
parse_paths → build_symbol_table → lower_to_ir → attribute_costs
     → extract_paths → rank_paths_by_slack → suggest_opportunities
     → [optional correct loop]
           order_worklist
           → select_pipeline_cuts / split_assign / reorder_statements_local
           → expand_name_definitions
           → remeasure
           → record_edit
     → synthesize_design → annotate_origin_comments
     → integrity_reparse + integrity_structural
     → write_emit_tree
     → export_debug_bundle (if --debug)
```

---

## 5. Test strategy (Rust)

### 5.1 Unit (always, no external tools)

| Test | Validates |
|---|---|
| `name_table_unique` | No collisions under alloc_* |
| `mangle_roundtrip_keywords` | Keywords/escaped ids safe |
| `rank_paths_deterministic` | Same IR → same order |
| `order_worklist_stable` | Tie-break stable |
| `noop_emit_reparse` | synthesize without transform still parses |
| `insert_reg_requires_gate` | Incomplete GateInfo refused |
| `edit_trace_has_origin` | Every edit carries SourceLoc |
| `integrity_reparse_on_fixtures` | All auto-correct fixtures emit → reparse |

### 5.2 Fixture families (`fixtures/auto_correct/`)

| Fixture | Intent |
|---|---|
| `deep_add_chain.sv` | Pipeline opportunity on add chain |
| `priority_mux.sv` / exclusive case fixtures | BalanceMux stage + residual one-hot; `exclusive_case_mux.sv`, `alu_nested_case.sv` |
| `enabled_mul.sv` | GateInfo enable separation |
| `multi_always.sv` | Scope-safe names across blocks |
| `keyword_ident.sv` | Mangling edge cases |

### 5.3 Integration (opt-in env)

| Env | Action |
|---|---|
| `SV_TIMING_LINT=1` | Run `integrity_lint_external` if `verilator`/`slang` on PATH |
| `SV_TIMING_SIM=1` | Run fixture TB with expected latency |
| Default CI | Unit + reparse only (package independence) |

### 5.4 Debug export tests

| Test | Validates |
|---|---|
| `debug_snapshot_creates_files` | export_debug_bundle writes ir.json, paths.csv, edits.json |
| `origin_comments_in_emit` | Emitted SV contains `// sv-timing: origin` |

---

## 6. Crate placement

| Crate | Owns |
|---|---|
| `sv-timing-core` | parse, loc, IR types, measure, rank, symbol table types, debug dump of IR |
| `sv-timing-transform` | PassContext, worklist, pipeline, reorder, rearrange, run_correct_passes |
| `sv-timing-emit` | EmitTree, synthesize_*, annotate_origin_comments, write_emit_tree |
| `sv-timing-cli` | Wire analyze/correct/export-debug subcommands |
| tests in each crate + `tests/integrity.rs` (crate or integration) | |

---

## 7. Implementation order

1. Types + NameTable + EditTrace + PassContext stubs (this pass)
2. rank/order pure functions on synthetic IR
3. emit synthesize of **unchanged** modules + reparse integrity
4. split_assign then insert_register
5. external lint/sim hooks
6. CLI `correct` + `debug-export`

---

## 8. Non-goals for these APIs

- Full elaborator / generate unroll in v1
- Formal equivalence
- Guaranteed MHz closure
- Silent latency change without `--allow-latency`
