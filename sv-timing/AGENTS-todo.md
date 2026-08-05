# sv-timing — AGENTS workflow todo / state

Live tracker for **this package only**. Read [`AGENTS.md`](AGENTS.md) and
[`architecture/DESIGN.md`](architecture/DESIGN.md) first. Update this file every pass.

## Current phase

**P14 measurement truth — DONE**, **P15 `-O` surface — DONE**,
**P16 — B1–B5 DONE** (parallel parse, path index, per-module CST scoping, dirty-only
remeasure + clone-free ranking, id maps), plus the **first whole-core monorepo FO4 reading**
(see next section) and the `--allow-parse-errors` fix it exposed.  
105 workspace tests, all four verif regress suites PASS. Whole CVA6 core (248 files,
3.47 MB) analyzes in **7.9 s** release: 229 modules, 14 767 paths.
On CVA6 `alu` @1.25 GHz: `-O2` 87.0→59.5 FO4 (2 edits), `-O3` →**52.6, closes** (4 edits),
`-Os` →**52.6, closes** with **2** edits. Parallel parse on the 9-file sparse set:
4.21 s → **2.34 s** (1.80x, Amdahl-capped by one 38 KB package), output byte-identical.  
**Next:** P17 `units` cache, or the remaining B8/B9 (CST-side expressions, relocation line
table — B9 folds naturally into P19). **B6/B7 need a dependency decision**
(`bincode`/`zstd`/`crc32c` — cargo currently runs offline here).

## Monorepo FO4 reading (2026-08-03, first whole-core run)

Real CVA6 core, target `cv64a6_imafdc_sv39`, flist via `timings flist` (248 files, 3.47 MB,
6 incdirs), **release** binary, `--all-modules --target-mhz 1250 --fo4-ps 12
--package-mode packages --param-map cv64a6_imafdc_xlen64.json --opt-jobs 8`:

```text
modules=229  paths=14767  opportunities=132  skipped_files=1   wall=7.9 s
closure: closes=false  max_freq=72.9 MHz  worst=914.5 FO4  failing=132  reg2reg=32
```

Artifacts: `build-platform/workspace/build/sv-timing/host-cv64a6_imafdc_sv39/monorepo-fo4.json`,
summarized by the new `tools/fo4_report.py`.

| Module | max FO4 | implied MHz | paths | where |
|---|---|---|---|---|
| `multiplier` | 914.5 | 73 | 27 | `multiplier.sv:115` |
| `SyncDpRam` | 720.0 | 93 | 14 | `SyncDpRam.sv:136` |
| `wt_dcache_missunit` | 255.5 | 261 | 161 | `wt_dcache_missunit.sv:333` |
| `cva6_mmu` | 247.0 | 270 | 150 | `cva6_mmu.sv:386` |
| `cva6_ptw` | 202.0 | 330 | 164 | `cva6_ptw.sv:189` |
| `cva6_shared_tlb` | 193.0 | 345 | 231 | `cva6_shared_tlb.sv:735` |
| `ct_vfdsu_srt_radix16_with_sqrt` | 191.0 | 349 | 88 (46 failing) | `...radix16_with_sqrt.v:839` |

**Findings from the run (each is a real defect or a real limitation):**

1. **Fixed — one file aborted 248.** `common/local/util/sram.sv` (a
   `// synthesis translate_off` region with bare `begin` blocks at generate scope: legal
   for synthesis, rejected by the strict IEEE grammar) failed the whole analyze. New
   `ParseOptions::allow_parse_errors` + CLI `--allow-parse-errors` skip and **report**
   (banner + `skipped_files` in JSON); integrity reparse of emitted SV stays strict.
   Golden: `fixtures/parse/unparsable.sv` +
   `allow_parse_errors_skips_and_reports_instead_of_aborting` (serial *and* parallel).
2. **Right path, pessimistic magnitude (→ P18 calibration).** The worst path is genuinely
   CVA6's single-stage 65x65 signed multiply (`mult_result_d`, `multiplier.sv:115`) — the
   correct answer for an unpipelined multiplier. But 914.5 FO4 ≈ 11 ns is far above a real
   Booth/Wallace 64x64 (~1.5-2.5 ns): `mul` width-scaling against `REF_WIDTH=32` is
   uncalibrated. **The ranking is usable today; the absolute MHz is not.**
3. **Memory arrays are costed as logic (new).** `SyncDpRam` shows **720 FO4 in a single
   node** — a behavioral RAM array read priced as a combinational cone. Per section 0 of
   the root guide, memories belong behind the `tc_sram` macro boundary and must be excluded
   from (or modeled separately in) the FO4 cost model. Needs a memory-construct rule or
   module-exclusion surface.
4. **Endpoint labels are placeholders.** Distinct paths print identically
   (`ct_vfdsu... in0 -> out0` twice at the same line, ids 2270/2272) because start/endpoint
   naming is synthesized, not derived from real signals. Not double counting — but it makes
   the worst-path table hard to act on. Folds into the endpoint-naming gap.

## Standing disciplines (every pass)

1. Keep this file current (checkboxes + “Current phase”).
2. Prefer **Python** under `tools/` over growing `svt.sh` / `svt.ps1`.
3. Preserve **independence** (`check_independence.py`).
4. First-party code: licensing per `AGENTS-licensing.md`.
5. Design deltas → architecture docs + note here if deferred.
6. Do not put host/monorepo logic into crates.
7. Default `svt.py test` / `build` = first-party packages only.

---

## Phase checklist

### P0–P5
- [x] Scaffold, toolchain, vendor parser, parse/loc, CLI, crates

### P6 — Timing IR / correct / TS / closure / verif / project / SV surface
- [x] Multi-pass auto-correct, TS, emit, closure, verif, dense, project multi-file
- [x] Packages / scopes / hierarchical ports / genvar / RHS rewrite / multi-cut feeds
- [x] Cross-module path extraction (instance graph + series upper-bound stitch)
- [x] Full `synthesize_module` from IR (ports/params/regions/always shells)
- [x] `schemas/analyze-result.v1.json`

### P7 — Cache
- [x] SQLite IR-only + CRC-32C + design hit
- [x] **Module-granular re-lower** (hit blobs + miss-file reparse + merge)
- [x] Test: `partial_module_miss_only_recomputes_changed`

### P8 — Host
- [x] Package `tools/flist_expand.py` + `svt.py flist` (env + nested → portable `.f`)
- [x] build-platform `timings.ts` adapter (`writePortableTimingsFlist`, argv helpers)
- [x] Docs: `AGENTS-host.md` host/package boundary

### P9 — Synthesize + instance graph
- [x] `ModuleInstance` / `PortConnection` / `CrossModulePath` IR
- [x] lower: collect instantiations + resolve child ids + stitch series paths
- [x] `sv-timing-emit::synth::synthesize_module` (ports, always_ff/comb, cont assign)
- [x] analyze JSON: `instances`, `cross_module_paths`
- [x] Tests: `project_mini_instance_graph_and_cross_paths`, `synthesize_leaf_has_ports_and_always`
- [x] Port-bridged stitch (`stitch_kind`, `via_ports`, `bridge_nets`) when child output formals connect

### P10 — Host CLI + expression synthesize
- [x] `build-platform` command `timings` (status / flist / analyze / correct)
- [x] `IrNode.lhs` / `rhs` recovered from blocking/NBA/net assigns
- [x] `synthesize_module` prefers recovered expressions

### P11 — Expression AST + STA handoff
- [x] `expr::Expr` (ident/literal/unary/binary/ternary/concat/index/call/opaque)
- [x] `IrNode.lhs_expr` / `rhs_expr`; `attribute_costs` sums tree FO4
- [x] Tests: parse chains, leaf multi-op FO4, synthesize uses tree emit
- [x] `architecture/STA-HANDOFF.md` + index/cross-links

### P12 — sta_hints + monorepo verif gates
- [x] `sta_hints_from_design` + analyze JSON `sta_hints` / `sdc_comment`
- [x] Richer scoped idents `pkg::name` + call/index chain tests
- [x] `verif/sv-timing-tests/` sparse flists + README
- [x] Regress: `sv-timing-smoke|core-sparse|autocorrect|advanced` (.sh + .ps1)
- [x] build-platform `tests.suites` entries; out under workspace `build/sv-timing/verif-tests`

### P13 — Param map (no CI)
- [x] `ParamMap` load/substitute + `--param-map` / `--cfg-snapshot` / `--assume-xlen` / `--package-mode`
- [x] Cache design key includes param-map keys
- [x] Host `writeHostParamMap` + timings auto-pass (unless `--no-param-map`)
- [x] `verif/sv-timing-tests/param-maps/cv64a6_imafdc_xlen64.json` + core-sparse wiring

### P14 — Measurement truth (prerequisite for every level/frequency claim) — **DONE**
> Spec: `architecture/OPTIMIZATION-LEVELS.md` §1–§1.1; as-built table in §1.2.
- [x] Design delta documented (defects M1–M7 + required corrections)
- [x] Golden **inputs** in place: `fixtures/measure/` (+ `measure.f`, `README.md`) — one fixture
      per defect (`independent_stmts`, `dep_chain_cross_region`, `seq_boundary`,
      `cut_imbalance`, `width_sensitive`); reference-width-32 normalization recorded in
      `OPTIMIZATION-LEVELS.md` §1.1(2)
- [x] M2 `Expr::fo4_delay` (own + max operand) + `Expr::fo4_area` (sum); `fo4_cost` = delay
- [x] M3 width inference (port dims **verbatim from source** + local `logic/wire/reg` decls
      → `--param-map`/`--assume-xlen`/module param defaults → reference width 32) +
      normalized scaling floored at `min(base, logic_bit)`
- [x] M1 def-use graph from `Expr::{read_symbols, written_symbol}` (edges only through comb
      defs; `IrNode.reads_reg` for register launch) + `measure::extract_paths` DAG longest
      path (one path per sink; `endpoints_for_region` removed)
- [x] M5 `cost_balanced_cut_index` prefix-sum bisection in `suggest_opportunities` +
      `pipeline::balanced_cut_for_path`; `estimated_fo4_after` = worst segment
      *(budget-fit / multi-cut deferred to P15 dial 3/4)*
- [x] M4 `split_assign` no longer scales cost; reports `fo4_before == fo4_after`;
      split-only pass ends the correct loop
- [x] M6 re-register `rank_paths_deterministic` (duplicate `#[test]` swallowed it)
- [x] Goldens for each (5 fixture tests + 10 unit tests); `measurement=` in `banner()`,
      `VersionBanner`, analyze JSON, `schemas/analyze-result.v1.json`, `js` DTO
- [x] *(landed in P15)* `budget-fit` strategy + `min_gain_fo4` guard

#### Fixed en route (pre-existing defects, unrelated to P14 scope)
- [x] `fixtures/filelist.txt` + `fixtures/auto_correct/filelist_deep.txt` carried
      package-root-relative paths while the loader resolves against the **listing file's**
      directory ⇒ 3 `js` connection tests and `DESIGN.md` acceptance test 2 were failing
- [x] `crates/sv-timing-cli/src/main.rs` `let mut policy = policy;` — deny-level
      `clippy::redundant_locals` broke `clippy --all-targets`

### P15 — `-O` surface (presets + ten dials) — **DONE**
> Spec: `architecture/OPTIMIZATION-LEVELS.md` §3–§6; as-built table in §3.2.
- [x] `crates/sv-timing-core/src/opt.rs`: `OptLevel` / `CutStrategy` / `OptEffort` /
      `CacheMode` / `OptOptions` / `OptOverrides` / `resolve` / `digest` / `summary`;
      §3.1 matrix encoded as the `preset_matrix_matches_spec` fixture (8 unit tests)
- [x] `PassPolicy::{from_opt, with_opt}` + `PassPolicy.opt`; `WorklistPolicy` split into
      `candidate_pool` + `width`, and the driver now **applies** `width` items per pass
- [x] Driver honors dials 1/2/4/5/6/7 (`stages_per_region` cap, `min_gain` veto,
      `slack_target` stop, `order_by_area_weight`); `-O0` = analyze only
- [x] Dial 3 in `pipeline::balanced_cut_for_path` + new `budget_fit_cut_index`
- [x] Dial 9 in `LowerOptions.opt` (skips cross-module stitch at `fast`); dial 10b `off`
      bypasses SQLite
- [x] CLI flattened `OptArgs` on `analyze` + `correct` (`-O` + ten `--opt-*`), resolved
      dials echoed as `opt=…`, `--max-passes` demoted to a deprecated alias, degrade note
      when a level would pipeline without `--allow-latency`
- [x] Additive `opt` block in analyze/correct JSON + `schemas/analyze-result.v1.json` +
      `js/src/types.ts` (`OptResultDto` / `OptDialsDto`)
- [x] `design_key` folds `#measurement=…` + `#opt=<digest>`
      (`opt_level_change_invalidates_design_key`)
- [x] `-Oz` / `-O1` insert zero registers even with `--allow-latency`
      (`oz_and_o1_insert_no_registers`) ⇒ no new `always_ff` reaches the emit tree;
      `level_never_overrides_the_allow_latency_gate` pins KD20
- [x] **Spec corrected by measurement:** `-Os` now uses `budget-fit` cuts + `stages=2`
      (was `cost-balanced`/1), because budget-fit is the flop-minimal route to closure —
      real `alu` went from "4 flops, no closure" to "2 flops, closes"
- [ ] *(deferred)* dial 8 `allow_reassoc` has no consumer yet (`rearrange_cone` /
      `reorder_statements_local` remain stubs) — plumbed + reported only

### P16 — Analyze throughput (first tranche done)
> Spec: `architecture/PERF-CACHE.md` §1; as-built table in §1.1.
- [x] B2 canonical path keys once + hash lookup — new `cache::pathkey` (`CanonPath`,
      `PathIndex`); `paths_match` deleted; suffix matching is now **path-boundary aware**,
      so `alu.sv` can no longer match `my_alu.sv` (5 unit tests)
- [x] B1 parallel parse via scoped `std::thread` + **dynamic** work queue (`AtomicUsize` +
      `mpsc`), degree from `--opt-jobs`; no new dependency; `#![recursion_limit = "1024"]`
      needed for `Send` on `SyntaxTree`. Static striding was tried first and made 8 workers
      *slower* than 4 on skewed files — replaced.
- [x] B5 opportunity + path id index maps (worklist and driver)
- [x] Determinism: `parallel_parse_matches_serial_order_and_content`,
      `parallel_parse_reports_first_failure_in_input_order`, plus an end-to-end
      byte-identical JSON check for `--opt-jobs 1` vs `8`
- [x] **Cache-key fix found while measuring:** `--opt-jobs` no longer participates in the
      design key — dials split into `analysis_digest()` (cache) vs `digest()` (reporting);
      `opt_level_change_invalidates_design_key` now also asserts a jobs change still *hits*
- [x] B3 one walk per file + per-module subtree (`ModuleScope`); `collect_*_in` variants for
      params / ports / genvars / instances / regions / op fallback. **Correctness fix:** a
      multi-module file no longer gives every module the union of all ports/params/regions,
      and instances are attributed to their real parent — golden
      `fixtures/measure/two_modules.sv` +
      `multi_module_file_scopes_ports_regions_and_instances`
- [x] B4 dirty-module remeasure (`PassContext.dirty_modules` + `mark_active_dirty()` +
      `attribute_costs_modules` / `remeasure_path_slacks_modules`, with `measure_full`
      fallback) **and** clone-free ranking (`RankedOrder` / `rank_path_order` hold indices;
      `order_worklist` takes `&[TimingPath]` + order). Proven exact by
      `dirty_scoped_measure_matches_full_measure`; `-O` sweep byte-unchanged.
- [x] **Monorepo readiness fix (found by the whole-core run):**
      `ParseOptions::allow_parse_errors` + CLI `--allow-parse-errors` on `analyze`/`correct`,
      `ParsedUnit::skipped` → `AnalyzeOutput::skipped_files` → banner + JSON `skipped_files`;
      partial-cache path carries miss-side skips. Plus `tools/fo4_report.py` (closure /
      worst paths / worst modules from an analyze JSON).
- [ ] **Cost-model gap (from the reading):** exclude or separately model memory arrays —
      `SyncDpRam` prices one behavioral RAM read at 720 FO4. Belongs with P18 calibration.
- [ ] B8 lower expressions from CST subtrees (retire the per-node `Expr::parse` text pass)
- [ ] B9 line table / byte spans in relocation — folds into P19
- [ ] **B6/B7 blocked on a dependency decision:** `bincode`+`zstd` blobs and the `crc32c`
      crate need crates.io fetches (cargo currently runs `--offline` here)

### P17 — Pre-compiled `units` cache tier
> Spec: `architecture/PERF-CACHE.md` §3. Depends on P16 (canonical keys, blob format).
- [ ] `units` table + `UnitIr` (per-file lowered, no costs, no cross-file resolution)
- [ ] Link-from-units on module IR miss (replaces KD15 full-set reparse ⇒ record **KD19**)
- [ ] C1 `crc_set(m)` over the dependency closure `F(m)` — stale-hit fix
- [ ] C2 unmapped/package paths no longer force a full miss; C3 design-blob write amplification
- [ ] `--opt-cache-mode off|ir|unit|full`; schema bump + `clean` gate
- [ ] Tests: `package_edit_invalidates_dependent_module`, `single_file_edit_parses_one_file`,
      `target_mhz_change_relinks_without_parse`

### P18 — Calibration + frequency sweep
> Spec: `architecture/PERF-CACHE.md` §4, `architecture/OPTIMIZATION-LEVELS.md` §2.
- [ ] `--fo4-preset generic|12nm|7nm` (generic = 20 ps, keeps goldens)
- [ ] `--freq-sweep a,b,c` per-module max MHz + blocking-path counts (one analyze, N rankings)
- [ ] Banner `cost_model` / `fo4_ps` / `calibrated=false`; rows above the 1.5 GHz stretch tagged `inferred`
- [ ] Optional offline Yosys/OpenSTA fit (calibration input only, never a runtime dep)

### P19 — Relocation on IR byte spans
> Spec: `architecture/OPTIMIZATION-LEVELS.md` M7. Restores `AGENTS-auto-correct.md` rule 1.
- [ ] Drive relocation from `SourceLoc.byte_start/byte_end` + CST subtree
- [ ] Retire the ±6-line "nearby unclaimed assign" heuristic in `emit/rhs.rs`
- [ ] Fixture: multi-line ternary / nested NBA rewritten at the measured cut site

---

## Host toolchain note (resolved 2026-08-03)

The workstation could not **link** Rust: the contained toolchain is
`1.85.0-x86_64-pc-windows-msvc`, and Visual Studio 18 Community was installed **without**
the C++ workload (`VC\Tools\MSVC` absent; no `link`/`cl`/`gcc`/`clang` on PATH).
Resolved by installing VS 2022 **Build Tools** with `VCTools` + Windows 11 SDK:

```powershell
winget install --id Microsoft.VisualStudio.2022.BuildTools --override "--quiet --wait --norestart \
  --add Microsoft.VisualStudio.Workload.VCTools \
  --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 \
  --add Microsoft.VisualStudio.Component.Windows11SDK.22621"
```

This closes the gap `build-platform` tracks as “VS Build Tools provisioning”. WSL
`Ubuntu-24.04` remains available as an alternative build host.

## Known-red gates (pre-existing; NOT introduced by P14)

| Gate | Status | Cause / follow-up |
|---|---|---|
| `svt.py check` → `cargo fmt --all -- --check` | **red** | `--all` walks the **vendored** `crates/sv-parser` (must never be reformatted) *and* first-party crates carry ~121 pre-existing diffs. Follow-up: scope fmt to `_pkg_args()` like clippy, then format first-party once in a dedicated pass. |
| `svt.py check` → `clippy -D warnings` | **red** | Pre-existing style warnings (`field_reassign_with_default` in tests/CLI, elidable lifetime in `expr::Parser`, collapsible `if` in `lower`). Deny-level **errors** are now clean. |
| `check_independence.py` | **red** | Pre-existing **P13** KD0 violation: `param_map.rs` hard-codes `CVA6Cfg.XLEN` convenience keys inside the crate (`with_assume_xlen`). Follow-up: move project key injection to the host / `--param-map` and update `verif/sv-timing-tests/param-maps/*`. |

## Verified (this pass, 2026-08-03)

```text
cargo test --workspace                     # 104 pass / 0 fail (core 59, emit 16, cache 15, transform 14)
cargo clippy --workspace --all-targets     # 0 errors (warnings pre-existing only)
bun run typecheck ; bun test  (js/)        # clean ; 5 pass / 0 fail (3 were failing before)
cargo run -p sv-timing-cli -- analyze --files-from fixtures/measure/measure.f --all-modules \
    --target-mhz 1250 --fo4-ps 12 --assume-xlen 64 --package-mode packages
# level sweep on a fixture and on real CVA6 RTL
sv-timing correct --files-from fixtures/auto_correct/filelist_deep.txt --modules deep_add_chain \
    --target-mhz 3000 --allow-latency --assume-clk -O {0,1,2,3,s,z} --dry-run
sv-timing correct --files-from <advanced portable.f> --modules alu --target-mhz 1250 --fo4-ps 12 \
    --package-mode packages --param-map verif/sv-timing-tests/param-maps/cv64a6_imafdc_xlen64.json \
    --allow-latency --assume-clk -O {2,3,s} --dry-run
pwsh -File verif\regress\sv-timing-smoke.ps1          # PASS
pwsh -File verif\regress\sv-timing-core-sparse.ps1    # PASS
pwsh -File verif\regress\sv-timing-autocorrect.ps1    # PASS
pwsh -File verif\regress\sv-timing-advanced.ps1       # PASS
```

Real-RTL sanity after P14 (`sv-timing-advanced`, `--target-mhz 1250`, `--fo4-ps 12`,
budget 53.3 FO4): `frontend/instr_queue` worst **21.0 FO4** (slack +11, max ≈1.9 GHz,
158 paths); `ex_units`: `multiplier` **914.5 FO4** (128-bit LHS multiply) and `alu`
**87.0 FO4** (≈460 MHz) as the blockers, 13 opportunities.

P15 level sweep on `alu` (same target): `-O2` 2 edits → 59.5 (no closure) · `-O3` 4 edits
→ **52.6 closes** · `-Os` **2** edits → **52.6 closes**. On `deep_add_chain` @3 GHz:
`-O0` 0/26.0 · `-O1` 1/26.0 · `-O2` 2/16.7 · `-O3` 3/**9.3 closes** · `-Os` 3/**9.3
closes** · `-Oz` 1/26.0.

P16 throughput (debug build, 8 CPUs, 9-file sparse set, best of 2):
`--opt-jobs 1` 4.21 s · `2` 2.79 s · `4` 2.51 s · `8` **2.34 s** (1.80x). Ceiling is Amdahl
on the 38 KB `riscv_pkg.sv` (~25 % of the bytes). Output byte-identical between `jobs=1`
and `jobs=8` (180 794 bytes compared, echoed dial excluded).

## Last pass

- **Date:** 2026-08-03  
- **Done (docs):** design deltas `architecture/OPTIMIZATION-LEVELS.md` (defects M1–M7,
  `-O` presets + ten dials, calibration honesty rule) and `architecture/PERF-CACHE.md`
  (bottlenecks B1–B9, cache defects C1–C3, pre-compiled `units` tier, freq sweep);
  indexed in `architecture/README.md`, `AGENTS.md`, `AGENTS-auto-correct.md`,
  `AUTO-CORRECT-CORE-API.md`, and the monorepo pointer; `DESIGN.md` delta banner +
  §2/§5/§6 as-built notes + **KD19/KD20**; phases P14–P19 opened.  
- **Done (code, P14):** measurement truth — M1–M6 per `OPTIMIZATION-LEVELS.md` §1.2,
  with 5 fixture goldens (`fixtures/measure/`) + 10 unit tests; `measurement=delay-v1`
  stamped through banner → IR → JSON → schema → `js` DTO. Licensing: edited files keep
  their existing `MIT` / Etienne Cimon headers; new `.sv` fixtures
  carry them (`.active-contributor` + `.licensing-policy` verified present).  
- **Also fixed:** two pre-existing defects (fixture filelist path resolution;
  `clippy::redundant_locals` in the CLI) — see P14 checklist.  
- **Done (code, P15):** the `-O` surface — `opt.rs` (levels + ten dials + digest),
  `PassPolicy::from_opt`, worklist pool/width split, driver support for dials 1/2/4/5/6/7,
  `budget-fit` cuts (dial 3), effort-gated stitch (dial 9), cache-mode bypass (dial 10b),
  CLI `-O`/`--opt-*` with banner echo, `opt` block in JSON + schema + `js` DTOs, dial
  digest in the cache design key. 15 new tests (8 core + 7 transform + 1 cache).
  **Spec correction from measurement:** `-Os` switched to `budget-fit`/`stages=2`.  
- **Done (code, P16 B1–B5):** B2 `cache::pathkey` (`CanonPath` + `PathIndex`;
  boundary-aware suffix match retires the `alu.sv`/`my_alu.sv` false positive), B1 parallel
  parse on scoped threads with a dynamic work queue behind `--opt-jobs` (4.21 s → 2.34 s on
  the 9-file sparse set; byte-identical output), B5 id index maps, and the
  `analysis_digest()`/`digest()` split so thread count stops evicting the cache,
  B3 per-module CST scoping (one walk per file; kills the cross-module ports/params/
  regions bleed and mis-attributed instances), and B4 dirty-only remeasure + index-based
  ranking. 10 new tests + 1 new fixture.  
- **Host:** MSVC C++ Build Tools installed; Rust now builds/tests on this workstation.  
- **Next:** P17 `units` cache (or B8); B6/B7 await a dependency call. Three pre-existing
  red gates are catalogued under “Known-red gates”.  
- **Open item (optional, carried from P13):** richer cfg field map from target packages.

## Merge note (2026-08-03)

Merged FO4 path_class / BalanceMux / monorepo-soak / 2.5 GHz residual closure from
full-bringup-cleanup onto architecture tip `Improve architecture in sv-timing`.
Sparse soak evidence: `MONOREPO-SOAK.md` / `FO4-ALGORITHM-UPGRADES.md`.

## Scale + full_core close (2026-08-03, fo4-o3-2500-soak)

- **CorrectScale**: worklist/passes + idle_limit + apply_cap + batch_size grow with
  √failing / √modules; cards stratify by **pattern then module**; correct loop
  batch-applies distinct modules before remeasure.
- **BalanceMux-first** on exclusive/bundle (rebalance no longer steals apply slot).
- **Exclusive credit snap** when credit-only residual ≤ 2× budget @ tight period.
- **full_core @ 2500 -O3**: primary **95 → 16**, **closes**, ~432 edits, reloc-driven.
- **full_corev_apu @ 2500 -O3**: primary **141.6 → 16**, **closes** (te_reg IndependentLhs;
  exclusive credit snap ≤5× budget).
- Emit integrity (progress): source-order joint reparse; edited-only fallback;
  empty ternary arm + trailing-op incomplete RHS rejected; procedural origin sample
  for case cuts; continuous origins comment-only. full_core emit hard syntax
  ~28→3 residual (ct_vfdsu / alu / load_unit); define context soft. FO4 still closes.
- SPO / `--from-timing` (2026-08-03): full_core + full_corev_apu packages close @2500;
  `timings validate` PASS; `mc-spo-soak --from-timing` PASS assemble+dual Verilator lint
  on **live** RTL; `--use-emit` does **not** feed lint (env only). Direct Verilator on
  emit: dense `genvar` needs `generate` (fixed); reject loop-index cut feeds (fixed).
  See `build-platform/workspace/build/sv-timing/monorepo-soak/SPO-FROM-TIMING-ANALYSIS.md`.
- **Runtime stability plan** (`architecture/RUNTIME-STABILITY-AUTOCORRECT.md`): R5 lean dense
  default; R6 exact basename (`copro_alu`≠`alu`); R7 credit snap ≤2.5× budget (apu te_reg
  reopens to ~70.8 FO4 — intentional); R8 host warn that `--use-emit` does not remap lint.
- **R8b** atomic-over-dense (detector v8): `te_reg` path 611 soft multi_cycle; apu
  primary **114→16** closes @2500. **R8** host `writeFlatManifest` overlays `__svt`
  when `CVA6_TIMINGS_USE_EMIT=1`.
- **R11** dual inject: BalanceMux early / InsertReg dense before `endmodule`; unique
  BalanceMux begin labels (`{top}_stage`).
- **R12e lean emit default:** zero cut feeds, no origin rewrite, no BalanceMux RTL
  (FO4 sidecar only). `mc-spo-soak --from-timing --use-emit` **PASS** for both
  `full_core` (95→16 FO4) and `full_corev_apu` (114→16 FO4) with dual Verilator
  lint via R8 overlay. Logs: `spo-r12f-use-emit-full_core.log`,
  `spo-r12f-use-emit-full_corev_apu.log`.
- **cv32a65x live:** all config packages missing `RVZacas` assignment-pattern
  field filled with `RVZacas: bit'(0)` (requires RVA to enable).
  `verify --lint --target cv32a65x` **PASS**.
- **Richer emit opt-in:** `--real-cut-feeds` / `--emit-balance-mux-rtl` on
  `sv-timing correct` and monorepo soak (default lean).
- Next: residual hard paths under richer emit if needed; live AMOCAS enable on
  configs that want Zacas (RVA + `RVZacas:1`).

