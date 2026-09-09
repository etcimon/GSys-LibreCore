# sv-timing — AGENTS workflow todo / state

Live tracker for **this package only**. Read [`AGENTS.md`](AGENTS.md) and
[`architecture/DESIGN.md`](architecture/DESIGN.md) first. Update this file every pass.








## 2026-09-09 — near-10 from original vs corrected (v27)

Inferred from `audit-remain-v27` original RTL vs `corrected/**__svt.sv`
(not a new soak):

- **gemm 18.5:** original `c_span`/`c_end` at L608/L610 were cut and
  twin-copied onto `gen_reuse_b` (`assign c_span = pipe_svt_p1_4`).
  `a_span`/`b_span` stay live (`32'(m/n-1)*fmt_row_bytes+k_bytes`) because
  twin requires identical RHS and S4 stopped on a flat 18.5 primary.
- **instr_queue 15.5 / frontend 13:** S4 never reached them — global
  fixpoint on the gemm headline.
- **inval_bus 16 / axi2mem 14 / T3 mul 56:** P10 / wrap / atomic — S5.

Implemented then soaked:

- [x] **D** delay-v20: `fmt_row_bytes` / `ai_fmt_bytes` mux-of-shifts
      (**kept**). General `(W)'(v)` still unparsed.
- [x] **Soak `audit-remain-v29/` FAILED:** emit **18.5→30.5** / 1311 MHz,
      191 edits. Sibling extra re-cut gemm `c_span`/`c_end` (same lines,
      paths 5049/5377) instead of `a_span`/`b_span`. `policy_subcode`
      InsertRegs 3→0, primary 30.5 n=16 Plain. Same class as v28.
- [x] **B reverted** (S4 sibling extra in `pass.rs`). Helper
      `s4_sibling_span_pending` stays unused, like `s4_has_pending_resilient`.
- [x] **C reverted** (path_class back to v24). Flop-bundle threshold
      change flipped cleanliness / skipped policy_subcode T2.

Soak of record remains **`audit-remain-v27/` 18.5**. Do not quote v29.
- [x] **B retry (uncut LHS):** extra S4 after 2-flat InsertReg **only**
      span/end nets not already cut this run (`cut_span_lhs`). Extra
      worklist is span-only (policy_subcode T2 already ran diverse).
      Cap 2, batch 1. Fixture test `sibling_span_extra_cuts_uncut_spans_not_recut`.
- [x] Soak **`audit-remain-v30/` FAILED:** emit **30.5** again. Extra did
      **not** fire (primary was policy_subcode, not gemm span). gemm still
      2 InsertRegs (`c_span`/`c_end`); `a_span`/`b_span` live. policy_subcode
      BM-credit only; S4 InsertReg refused `cleanliness_set` because n=16
      was treated as fat FSM (not resilient). v27 had exception+InsertReg.
- [x] Fat-FSM floor **16→24** so policy_subcode n=16 is resilient again;
      axi2mem n=39 still locked. Extra uncut-span kept for after 30.5 closes.
- [x] Soak **`audit-remain-v31/` / `v32/`** match v27: emit **18.5**, 186
      edits. Extra-S4 (B) is a no-op on `full_corev_apu` — `a_span`/`b_span`
      are **not** over-budget IR paths during correct (only post_analyze of
      emitted SV). Do not quote v29/v30 30.5.
- [x] **A (emit-side):** `sibling_span_extra_cuts` in `sv-timing-emit`.
      When a span-family InsertReg sits in a named generate-if, rewrite
      uncut sibling `*_span`/`*_end` with **own** `pipe_svt_sib_*` names
      (in-place, not twin-copy). Tests
      `sibling_span_extra_cuts_uncut_spans_own_pipes` +
      `sibling_span_extra_pipes_emit_own_decls`. Twin `c_span` unchanged.
- [x] Soak **`audit-remain-v33/`** GREEN. Integrity joint/reparse/structural
      OK. IR edits **186** (same as v27 — no origin steal). Emit primary
      **74.5→16.0** / 2500 MHz (was 18.5 / 2162). gemm `a_span`/`b_span`/
      `a_end`/`b_end` rewritten to `pipe_svt_sib_*`. Headline is now
      **inval_bus 16.0 P10** (S5). New gemm leftover: sibling **feeds**
      12.5 n=2 at L2539/L2540 (fmt mux 2.5 + AddSub 10). instr_queue 15.5
      / axi2mem wrap 14 / frontend 13 still sit under that P10 headline.
- [x] **A follow-on:** sibling extra `fat * … + tail` feed split (`_p` prep
      pipe then add pipe). gemm 12.5 Mux+AddSub becomes 2.5 then 10.
      Test `sibling_span_star_add_feed_splits_prep_pipe`. `{1'b0,pa}+span`
      has no `*` on the left and stays a single add.
- [x] Soak **`audit-remain-v34/`** GREEN. Split landed (`_p` prep + add)
      but leftover stayed **12.5** at `prep_Q + k_bytes` because
      `k_bytes = fmt_row_bytes(k_q)` is Mux 2.5. Integrity OK. Headline 16.0.
- [x] Combo tail sample: simple non-`_q/_i/_d` ident on the add tail gets
      its own `_t` flop so the add is Q+Q = 10.
- [x] Soak **`audit-remain-v35/`** GREEN. Integrity OK. IR edits 186.
      gemm sibling feeds **gone** (was 12.5). Emit primary still **16.0**
      P10 inval_bus (S5). Next S4-admitted leftover: instr_queue 15.5 (E).
- [x] **E (emit-side sandwich remainder):** uncut combo assign whose ident
      sits in a cut feed and whose RHS uses a cut LHS (`push_instr`
      between `lo_partial` and `push_instr_fifo`), plus one hop of combo
      producers. Own `pipe_svt_rem_*`, in-place, no recut of claimed
      lines (F2). Fixture `queue_remainder.sv`.
- [x] Soak **`audit-remain-v36/`** GREEN. Integrity OK. IR edits 186
      (no origin steal). Remainder extras only on `instr_queue`
      (`fifo_pos`/`instr_overflow`/`slot0_pos`/`push_instr`).
      **instr_queue 15.5 gone.** Emit primary still **16.0** P10.
      Next S4-admitted leftover: frontend 13.0 Plain L1026.
- [x] Soak **`audit-remain-v37-full-core/`** emitted the full core tree
      (258 RTL, 10 fetch_A excluded, fetch_B live) but **integrity FAIL**:
      `hpdcache_amo` comma-list `assign ugt, sgt, sum` rewritten as
      procedural `sgt = pipe` + illegal feed. `cva6__svt` RVFI define is
      context-only.
- [x] Refuse cut claim when RHS is a comma-assign list
      (`rhs_is_comma_assign_list`). Test `comma_assign_list_is_not_rewritten`.
- [x] Soak **`audit-remain-v38-full-core/`** GREEN. Integrity joint/reparse/
      structural OK. 10 fetch_A excluded, 0 in emit. `corrected/core` **230**
      files (fetch_B 6). Emit primary **30.0→20.0** / 2000 MHz, 501 edits.
      Headline `trigger_module` 20.0 P10. Do not quote v37 parse FAIL.
- [x] **Or-reduce preps** on `_d` assigns with ≥2 unary `|ident` (frontend
      `speculative_d` 13 FO4 on both soaks). 1-bit pipes, origin keeps
      `assign spec_d = … pipe_red …`. Test `or_reduce_preps_on_next_state_d`.
- [x] Soak **`audit-remain-v39/`** GREEN both profiles. Integrity
      joint/reparse/structural OK. frontend **13.0 gone** (`pipe_svt_red_is_*`).
      Headlines unchanged (S5): APU **16.0 P10** inval_bus, core **20.0 P10**
      trigger_module. IR edits 186 / 501. Next S4: frontend 12.5 next-state
      add+mux `[i]` (do not scalar-pipe), core wt_dcache 12.0 mixed `|tocheck`,
      APU pe_dot/dm_sba 12 atomic or generate.
- [x] Mixed or-reduce: one `|ident` in a ≥2 `&&`/`||` cone, no `_d` required,
      skip `_o` ports. Test `or_reduce_preps_mixed_single_reduce` (wt_dcache
      `fixup_rd_req`).
- [x] Soak **`audit-remain-v40/` FAILED** integrity: `unary_or_reduces`
      treated bitwise `cache_wren | inv_en` as unary (space after `|`).
      frontend `if_ready` / icache `vld_we` lost `|`. Do not quote v40 FO4.
- [x] Unary `|` only when previous non-ws is not ident/`)`/`]`. `|| |ident`
      stays unary. Test `binary_or_is_not_unary_reduce`.
- [x] Soak **`audit-remain-v41/`** GREEN both profiles. Integrity
      joint/reparse/structural OK. bitwise `|` kept (`if_ready`, `vld_we`).
      frontend 13 still gone. Headlines still S5: APU **16.0 P10**, core
      **20.0 P10**. Mixed or-reduce did **not** close wt_dcache 12.0: S4
      InsertReg claimed `fixup_rd_req` L389 but emit kept the origin
      (named generate-if), extras skipped claimed lines. Fired instead on
      `check_wr` `(|wbuffer_q[i].valid)` / `(|rd_hit_oh_q)`. Do not quote v40.
      Soak of record: **`audit-remain-v41/`** (frontend 13) + v39 same 13-close.

## 2026-09-09 — ALGORITHMS-EXPERTS.md (expert manual)

- [x] Wrote `sv-timing/ALGORITHMS-EXPERTS.md`: per-algorithm theory (A1–A64 +
      labs, invariants I1–I15, remaining-gap proof). Cites implementation
      files, not architecture-doc exploration. Soak of record remains
      `audit-remain-v27/` 18.5 FO4; v28 S4-continue stays reverted.
      Campaign near-10 = VII.A+B(+D)+E+C; floor P10/wrap/T3 is not 10.

## 2026-09-08 — trace-driven algorithms (path_class v10, 4 GHz)

Soak traces (`full_core` 645 InsertReg / 192 BalanceMux; residual `axi_adapter` 19.2 FO4;
`g6lc_ai_exec` 545.5 last-statement loc; `ct_vfdsu` 181 InsertRegs; APU `g6lc_ai_gemm_seq`
1317.5 serial-sum atomic) showed the inferred fixes were measurement artefacts.
Algorithms added so the tool reports structure instead of spraying registers:

- [x] **v9** sequential next-state `_d`/`_n` drops IndependentLhsBundle log-mux wire tax
  (`axi_adapter` FSM). Iterative FPU names (`vfdsu`/`srt_radix`/`control_mvp`) tagged
  multi-cycle. `t1_prep_stage` auto only if stages≤1. InsertReg cap = `max_stages_per_region`.
- [x] **v10** `primary_loc` = hottest node (not last statement). Atomic adjusted FO4 =
  operator cost (merged with exclusive/dense companion), **not** the enclosing
  always_comb serial sum. `mantissa_a * mantissa_b` is datapath Mul; `CVA6Cfg.*` /
  `2 ** lvl` / `*'` casts are not. Design-key includes `PATH_CLASS_DETECTOR_VERSION`.
- [x] Re-soak after v10 @ 4000 MHz / 20 ps / `-O3`: InsertReg **645→280**, vfdsu
  applies **181→0**, APU gemm_seq **1317.5→59.5** (operator, loc on the mul). Residual:
  axi_adapter still 19.2 (`next_state=false` because 8 `_d` vs 50 `axi_req_o.*` ports),
  control_mvp **4560** kept serial because MultiCycleTagged skipped exclusive/dense,
  clint 114 FO4 `rdata` vs `rdata[31:0]` split LHS, fpnew_fma 95/30 leftover after
  InsertReg cap=8.
- [x] **v11** mixed next-state (`>=4` `_d` fields, not 60% frac); MultiCycleTagged still
  deflates exclusive/dense; sliced LHS (`rdata[31:0]`) groups as one exclusive mux.
- [x] Re-soak v11 @ 4000/20/`-O3`: InsertReg **645→281**, vfdsu **0**, worst_all
  **545.5→187.5** (control_mvp 4560 deflated), APU gemm **1317→59.5** loc on mul,
  clint 114 FO4 gone (sliced `rdata` exclusive). axi_adapter refuse **19.2→17.1**
  DenseControlCone (not IndependentLhs). Residual primary is fpnew_fma 95→30
  after InsertReg cap=8 — T3 `NumPipeRegs`, not more spray.

4 GHz at 20 ps is a **10 FO4** budget. What produces it is T3 pipelining of real
56 FO4 muls (FMA mantissa, AI MMA, PE dot, integer `multiplier`) to 6 stages /
`NumPipeRegs`, plus exclusive/bundle costing of FSMs — not `-O3` InsertReg.

## 2026-09-08 — cone lanes + procedural ref-order tree (v12)

Compartmentalize the five 4 GHz concerns so comb exploration, atomics, iterative
FPU, next-state FSMs, and process budget do not share one InsertReg cascade.

- [x] `RefOrderTree`: per-variable write/read/forward-read counters, per-call
  counts with **parameter-use** counters, write→read edges in statement order,
  `procedural_ok` (call args not produced only after the call).
- [x] Comb: serialize only forward write→read edges; write-only `_d` / ports stay
  parallel (`procedural_depth == 0`).
- [x] `ConeLane` view: AtomicMul / IterativeArith / ExclusiveMux / NextStateFsm /
  CombDatapath / PipelinedUnit / Screening. InsertReg only on CombDatapath;
  comb algos (exclusive/dense/bundle/BalanceMux) still run where `explore_comb`.
- [x] Part-select `*`/`/` demoted (PTW VPN slice). SVA (`*_sva`) tagged multi-cycle.
- [x] Re-soak v12 @ 4000/20/`-O3`: InsertReg **645→241** (fpnew FMA/cast **refused** as
  PipelinedUnit — primary stays 95 FO4 honest FMA comb, T3 `NumPipeRegs` not spray).
  APU primary **46→11**; `dm_top_sva` no longer headline. Comb BalanceMux still runs
  (124 applies). `procedural_ok` + write-only depth on IndependentLhsBundle notes.

## 2026-09-08 — parallel-timing scratchboard (v13)

Timing basis (FO4, not STA): `S(s)=max producer C`, `C(s)=S(s)+L(s)`, `M=max C`,
`N=ceil(M/B)` cycles to reference-ready. Independent ops share a slot; only
ref-tree write→read edges serialize. Just-in-time InsertReg sits on critical
ops whose ASAP end crosses `k·B`.

- [x] `ParallelScratch` + `ModuleParallelTiming` for **every module** and
  `FunctionTiming` for **every function** (declared stubs + call/param counts).
- [x] Classifiers use makespan (bundle/dense/plain parallel-timing detector).
- [x] `suggest_opportunities` JIT cuts from the scratchboard, not mid-path index.
- [x] Re-soak v13 @ 4000/20/`-O3`: core primary **95→52 FO4** (FMA valid-OR serial
  ghost gone), InsertReg **241→186**, IndependentLhsBundle **72→144** (parallel
  schedule), APU InsertReg **125→76**, APU analyze primary **46→35.6**. Comb
  BalanceMux still runs (138). fpnew FMA 52 FO4 remains PipelinedUnit T3
  (`NumPipeRegs`), not spray.

## 2026-09-08 — clock-aware always_ff scratch + OpenSTA seeds

`always_ff` must **keep** a sequential `ParallelScratch` (clock name, edge,
period_ns, budget \(B\)). Fill walks IR regions first so NBA-only processes
are not dropped; path overlay must not demote them to combinational
`schedule(path.nodes)`. Factorize comments + JIT cuts read that board.

- [x] `ClockDomain.sequential` so unresolved clock names still stay sequential.
- [x] `ModuleParallelTiming.regions` stores the full `ParallelScratch` (not ops-only).
- [x] `keep_region_scratch` / `bind_always_ff_clock` / `jit_cuts_on_clock`.
- [x] `factor_always_ff_regions` reuses the kept board and writes it back.
- [x] Review-only OpenSTA workflow: `architecture/OPENSTA-CORRECTION-WORKFLOW.md`.
- [x] Host clone of OpenSTA into `build-platform/workspace/tooling/opensta`
  (`python tools/svt.py fetch-opensta`); gitignored workspace, not a crate dep.
- [ ] Optional STA smoke once `sta` + liberty are present (KD0: not a crate dep).

## 2026-09-08 — per-module cleanliness optimization

Modules explore a catalog of **logical** algorithm sets and pick a working
solution by cleanliness, weighted toward `always_ff` / `always_comb` density,
with timing pass/fail as a constraint and aggressiveness as a penalty.

- [x] Catalog: classify, ff_factor_clock, comb_exclusive, comb_split,
  seq_plus_comb, jit_datapath, multicycle_honest, aggressive_pipeline.
- [x] Applicability from region kind + cone lane (never InsertReg on exclusive /
  atomic / always_ff-only).
- [x] Objective \(C = w_{ff} D_{ff} + w_{comb} D_{comb} - w_a A - w_t 1[\neg pass]\)
  (defaults 0.40 / 0.40 / 0.20 / 0.50). Feasible = timing-pass sets if any.
- [x] `fill_design_cleanliness` after parallel-timing; correct loop skips
  opportunities the winner forbids; analyze JSON `module_cleanliness`.

## 2026-09-08 — algorithm `--trace-log` JSONL

- [x] `sv-timing-core::AlgoTrace` (disabled no-op; `--trace-log` JSONL).
- [x] Correct loop emits `run.start` / `scale` / `pass.start` / `worklist` / `apply` / `refuse` / `measure` / `run.end`.
- [x] Analyze emits class histogram + top relocation cards.
- [x] Soak writes `algo-trace.jsonl`; `tools/algo_trace_report.py` summarizes.
- [x] `full_corev_apu.f` now lists the live `corev_apu/ai_island/` RTL (not only
  `g6lc_ai_dram_timing.sv`). `full_core` still takes `Flist.cva6` (CVXIF AI exec).
- [x] Both profiles carry `+define+G6LC_FETCH_B` and exclude `/core/fetch_A/`
  (retired frontend + g1* recover). `full_corev_apu.f` also lists `Flist.fetch_B`
  supply files. Predictors stay in `core/frontend`.
- [x] Soak portable writer: if `core/fetch_B/<name>` is present, drop shadowed
  twins under `core/` or `core/frontend/` with the same basename
  (`frontend.sv`, `instr_queue.sv`, `instr_scan.sv`, `instr_realign.sv`,
  `g6lc_fetch_{pkg,dbg}.sv`). Unique predictors (btb/ras/FTQ) are kept.
- [x] Soak `full_core` + `full_corev_apu` @ 4000 MHz / 20 ps / `-O3` with `--trace-log`.
  `full_core`: 184 modules, 4255 paths, primary 95→19.2 FO4, worst_all 545.5
  (`g6lc_ai_exec`; SyncDpRam 720 comment artefact gone), 1114 edits, 837 apply /
  2 refuse (`axi_adapter` IndependentLhsBundle 19.2 FO4 is residual primary).
  `full_corev_apu`: island+fetch_B in portable.f, primary 114→10 IR-closes, emitted
  350.9 MHz, worst_all 1317.5 unchanged (atomic). Traces under
  `build-platform/workspace/build/sv-timing/monorepo-soak/<profile>/algo-trace.jsonl`.

## 2026-09-08 — Rust sv-parser fork (not Python) as submodule

Corrected the misleading “Python parser” claim: production frontend is
**Rust** [etcimon/sv-parser](https://github.com/etcimon/sv-parser) `g6lc`
(dalance/sv-parser v0.13.5). pyslang remains emit-lint only.

- [x] Validated in-tree copy was **byte-identical** to dalance v0.13.5 (only `VENDOR_STAMP` + dropped `.github/`).
- [x] Forked to `github.com/etcimon/sv-parser` (did not exist).
- [x] `g6lc` branch: Verilator chained select (`SelectSuffix`) + comment-aware `/`.
- [x] Replaced `sv-timing/crates/sv-parser` vendor copy with submodule `branch = g6lc` @ `977cb3f`.
- [x] Host-side: `expr.rs` skips `//` / `/*` in the homemade RHS parser; `lower.rs` drops comment-slash `BinaryOperator`s.
- [x] Fixtures `parse/chained_select.sv`, `parse/comment_slashes.sv`.
- [ ] `--allow-parse-errors` **kept** for truly unparsable files (`sram.sv` translate_off / `unparsable.sv`). `core/alu.sv` xperm8 should no longer need it.
- [ ] Re-run `full_core` soak without `--allow-parse-errors` and confirm `SyncDpRam` is not the 720 FO4 comment artefact.

## Current correctness audit — ir-v1 / delay-v2

This section supersedes the older frequency headlines below. They are historical
structural estimates, not measured processor clock limits. A 4 GHz target remains
0.250 ns; no technology/PVT-specific closure or full-core equivalence is established.

### Implemented and regression-tested

- [x] Source-coordinate repair: expressions/case text come from the preprocessed CST;
  anchors map through `get_origin`, not raw offsets into original bytes. Conditional
  preprocessing and macro expansion have directed tests. Macro/include/unknown origins
  cannot authorize automatic source edits. Same-basename files in distinct directories
  no longer share edits; post-analysis uses the manifest's source mapping in input order.
- [x] Runtime `*`, `/`, `%` cannot be discounted based on short/uppercase/config-like
  names or index position. Proven literal power-of-two multiplication remains cheap;
  unresolved constants are conservatively charged. The cost table was not retuned.
- [x] Cleanliness coverage: JIT or multi-cycle candidates must cover **every failing
  path**, not merely have a matching lane somewhere in the module. Density weights
  cannot manufacture coverage. Feasibility remains a proposal, not emitted closure.
- [x] Sequential safety: IR currently loses blocking versus NBA assignment kind.
  Dependency-bearing sequential scratches remain unverified, retaining clocks and costs.
  They cannot produce scratch-based deflation, midpoint fallback cuts, or staged
  factorization comments. Comment-only annotations claim zero FO4 improvement.
- [x] Emitter insertion: comments, quoted text and escaped identifiers cannot supply
  process/endmodule anchors. The partial APU run reproduced an injection inside
  `//always_ff` that uncommented the line; unit regressions now preserve it unchanged.
- [x] Host validity: emitted measurements replace optimistic IR in dashboards. Missing,
  partial or invalid evidence is INCONCLUSIVE. `correct --emit`, soak status/stamps and
  host `--require-emit` validation fail rather than reporting invalid output as success.
- [x] OpenSTA handoff: native numeric-first slack lines, signed/exponent values and
  incomplete reports are tested. Only fresh successful S2 evidence is accepted; stale
  files and synthetic fixtures cannot rescue failed execution. Missing tools are SKIP.
- [x] IR/measurement identifiers bumped to invalidate old cached lowering and costs.
  No production RTL, budgets, weight defaults, licensing policies or user staging changed.

### Validation results for this audit

- `python tools/svt.py test`: **193 passed** (core 118, cache 16, emit 35,
  transform 24). Regression tests were first observed failing for the repaired cases.
- Host `bun test test/clean.test.ts test/fo4-inventory.test.ts`: **95 passed**;
  `bun run typecheck` passed. Includes real OpenSTA golden-text parsing and mocked
  stage failures; it does not execute real processor STA.
- Soak metric/stamp selection: seven mocked Python cases passed (emitted versus IR,
  missing evidence, dry-run, and analysis/correction exit-status combinations).
- **The input contract is now closed.** Both profiles run strict — no
  `--allow-parse-errors`, **zero skipped files** — after four input/parse fixes:
  `TARGET_CFG` + `HPDCACHE_DIR` are exported to filelist expansion (repo `Makefile`
  §114/§125); the APU flist gained the apb / register-interface / ITI include dirs;
  unexpanded `${VAR}` is now a hard error instead of a soft "missing file"; and
  `// synthesis translate_off` regions are honoured.
- **Coverage was materially understated before.** Closing the inputs did not shift a
  frequency, it revealed design that was never analysed:

  | Profile | Modules (was → now) | Paths (was → now) | Files |
  |---|---|---|---:|
  | `full_core` | 184 → **233** | 4594 → **5410** | 258 |
  | `full_corev_apu` | 145 → **167** | 1888 → **4636** | 181 |

  The APU path count grew ~2.5x. Every frequency statement taken before this — including
  all pre-audit entries below — described an incomplete design.
- Strict run, 4000 MHz / 20 ps / -O3, closure read from emitted `post_analyze`:

  | Profile | Closure | Structural max | Worst path | FO4 | Slack | Failing | Edits | primary ΔFO4 |
  |---|---|---:|---|---:|---:|---:|---:|---:|
  | `full_core` | MISS | ~571.4 MHz | `g6lc_ftq.reg0/CP → .reg1/D` | 70.0 | -60.0 | 556 | 462 | **0.0** |
  | `full_corev_apu` | MISS | ~131.4 MHz | `g6lc_ai_gemm_seq.reg0/CP → .reg1/D` | 304.5 | -294.5 | 172 | 308 | **0.0** |

  Host `timings validate --require-emit` reports **structure OK** for both with
  `stamp exitCode=0`, and closure **MISS** — a valid package that does not close, which
  is the distinction the audit existed to make possible.
- **Auto-correct is not moving the limiting paths.** 462 and 308 applied edits changed
  primary FO4 by **0.0** on both profiles. The emitted tree is structurally valid and
  re-analysable, and it buys nothing at this target. Treat the transform worklist as
  unproven for high-frequency work rather than as a closure mechanism.
- **Root cause of the 0.0 delta: IR credit that the emitted RTL does not realise.**
  On `full_core` the same run reports `post_closure` (IR) **56.0 FO4 / 714.3 MHz /
  344 failing** against `post_analyze` (re-analysis of its own emitted SV) **70.0 FO4 /
  571.4 MHz / 556 failing**. Integrity is clean (`joint reparse ok: 258 files`,
  `structural_ok`), so this is not an emit failure — the IR books BalanceMux-style credit
  for structure that the review-only output does not actually contain. The host and soak
  now report the emitted number, so the optimism is contained rather than published, but
  **the transform's own accounting is still wrong** and is the next thing to fix.
- **`delay-v4`: fixed part-select bounds were being billed as dividers.** IEEE 1800
  §11.5.1 makes both bounds of `[msb:lsb]` constant expressions, so parameter arithmetic
  there is elaboration-time. Removing the name heuristics had left
  `vaddr_q[12+((CVA6Cfg.VpnLen/CVA6Cfg.PtLevels)*(...))-1 : 12+(...)]`
  (`core/cva6_mmu/cva6_ptw.sv:189`) charged as a 202.0 FO4 `DivRem` with `node_count=1` —
  the worst raw path in `full_core`, for a slice that synthesises to wires. The rule is
  now language-grounded, not name-based: only the `:` form is trusted, and `+:` / `-:`
  parse to `Opaque` so an indexed part-select base can never be excused by it. Measured:

  | | `full_core` v3 → v4 | `full_corev_apu` v3 → v4 |
  |---|---|---|
  | worst raw path | 202.0 `cva6_ptw` → **176.0** `fpnew_opgroup_block` | 304.5 → 304.5 (real) |
  | `atomic_over_budget` | 45 → **35** | 12 → **10** |
  | MMU atomic paths | 12 → **6** | 0 → 0 |
  | opportunities | 630 → **442** | 246 → **191** |
  | failing (emitted) | 556 → **427** | 172 → **133** |

  The surviving AI-island atomics are real multipliers (`g6lc_ai_gemm_seq` 304.5/131.0,
  `g6lc_ai_pe_dot` 130.0), and 6 MMU atomics remain unexplained — treat those as open.
- The worst core path is no longer an AI-island cone. With comment/`translate_off`
  artifacts and name-based arithmetic discounts removed it is `g6lc_ftq` (fetch target
  queue) at 70.0 FO4; `SyncDpRam` 720.0 and `g6lc_ai_exec` 545.5 do not reproduce.
- Actual host `sta-handoff --try-tools --no-sta-fixture`: S0 generated seeds; S1
  found Yosys 0.67+92 but failed on missing common_cells includes/macros. S2 did not
  run; S3/S4 skipped. Overall exit is now 1, not success from S0 alone.
- Fixture integration `verif/regress/run_regress.py`: **six cases still fail**;
  density/syntax-shape requirements and some incomplete emitted measurements remain.
  Four emitted fixture groups pass pyslang syntax, which is not functional equivalence.
- Independence check still fails on existing monorepo-symbol rules; it was not relaxed.
  The documented host `diag run licensing` command is unavailable (`Unknown: licensing`);
  edited first-party files retain existing MIT/Etienne Cimon headers and tier T.

### Pattern analysis → planned pass strategy

Trace-log and path-distribution analysis of the strict corpus is written up in
[`architecture/PASS-STRATEGY.md`](architecture/PASS-STRATEGY.md): nine measured pattern
signatures (P1–P9), a pre-pass planner that triages artifact-vs-real before spending
edits, and an ordered S0–S5 schedule. Recognizers, constant lattice (P1 / `delay-v5`),
comment-interior skip (P2), P4 remainder cuts, P5 `closes` on flop-to-flop, S3-before-S4
and Δprimary fixpoint are **implemented**. Indicative logs:
`E:/cva6/build-platform/workspace/build/sv-timing/audit-strict-v4/full_core/analyze.json`
and `…/full_corev_apu/analyze.json`.
The load-bearing measurements:

- **~half the hard FO4 mass is still artifact.** Of `full_core`'s 35 failing
  `atomic_over_budget` paths, **17 (1601.0 of 3158.5 FO4, 51%)** are arithmetic between
  elaboration constants — `3 * PRECISION_BITS + 4`, `NUM_LANES/INTERNAL_LANES`,
  `$clog2(CVA6Cfg.AxiDataWidth / 8)`, and two **replication counts**
  (`{HPDcacheCfg.reqDataWidth/64{...}}`, `{{(DataWidth/8-4){1'b0}}, 4'hF}`) that the LRM
  requires to be constant. `delay-v4` fixed this for `[msb:lsb]` bounds only; P1 is that
  fix generalized via a constant lattice seeded by the param-map.
- **Comment lowering (P2):** banner `//` was already skipped; block interiors and
  trailing `//` still billed `||` / `*` as hardware because the skip only looked at
  `/` and `*`. `operator_token_in_comment` now skips every CST operator inside a
  comment; assign RHS is blanked before Expr parse (`parse/comment_interiors.sv`).
- **The workload is shallow, not monstrous.** 469 of 621 core failures (75%) and 87 of 144
  APU failures sit in [10,20) FO4 — one rebalance or one register each. Only 15 core paths
  exceed 80 FO4. Schedule from the bulk, not from the worst path.
- **204 core paths (Σ 4692.5 FO4) have `node_count<=1`** and so cannot be cut by any
  strategy; that is why `worst_all` stayed 176.0 across the entire run.
- **`atomic` is applied to whole paths on the strength of one node** — `cache_ctrl` 125.0
  FO4 has **117 nodes**, `wt_axi_adapter` 121.5 has **71**. The path-level verdict
  suppresses cutting the ordinary remainder.
- **423 of 621 core failures are `intoout` fragments**, not flop-to-flop paths, so the
  failing count is inflated and cuts are misdirected.
- **Passes are mostly idle**: `full_core` reached its best `primary_fo4` in **pass 1** and
  spent 13 more passes flat; **1 refusal in ~193 applies** on each profile. A fixpoint stop
  would end the core run at pass 3.
- **The APU's worst path is cuttable and the plan already exists**: 304.5 FO4,
  `nodes=144`, `plain`, `regtoreg`, and the IR found a 3.2x cut (304.5 → 96.5) that the
  emitted SV does not contain. Highest-value fix remains the IR/emit credit contract.

### Remaining gates

Fresh full-soak artifacts are under host `workspace/build/sv-timing/audit-delay-v2-*`.
Both profiles carry `G6LC_FETCH_B`, exclude `core/fetch_A`, retain the live SMT2 helpers,
and include their respective CVXIF/SoC island source sets. File presence is **not** proof
that all SMT2/8-issue/8-core/RVV/H/AI features are enabled in one elaborated target.

- [x] Strict profile input closure — done; both profiles parse every file.
- [ ] Two FPGA **board tops** are excluded, not measured, and both are honest gaps:
  `altera/src/cva6_altera*.sv` include `src/agilex7.svh`, which is absent from the tree;
  `fpga/src/ariane_xilinx.sv` calls `` `AXI_TYPEDEF_ALL `` while including only
  `axi/assign.svh`, so it builds solely on single-unit macro leakage. The latter is a
  **real self-containment defect** in board RTL — fixing it is an RTL change owed the
  root `AGENTS.md` §0.2 checklist, so it is filed here, not patched from a timing run.
- [ ] Full emitted elaboration and equivalence still unproven: the emitted tree
  re-parses and re-analyses, which is neither elaboration of a top nor an equivalence
  check. Nothing here shows the corrected RTL is functionally identical.
- [x] **IR/emitted accounting split:** lean emit (soak default) does not rewrite
  origin assigns. `PassPolicy.emit_structural` is set from `--real-cut-feeds` /
  `--emit-balance-mux-rtl`; without it every IR FO4 mutation (InsertReg, BalanceMux,
  SplitAssign, rebalance, prep) refuses credit and S4 is skipped so
  `post_closure` cannot claim 304.5→96.5 that
  `audit-strict-v4/full_corev_apu` emit does not contain. `post_closure.reportable`
  is false in lean mode; soak/host use `post_analyze`.
- [x] Richer emit origin rewrite on a gemm-shaped continuous assign:
  fixture `fixtures/auto_correct/gemm_span.sv` + emit test
  `real_cut_feeds_rewrites_gemm_span_origin` — lean keeps live `assign c_span`;
  `--real-cut-feeds` comments it out and sinks `c_span` from the pipe (reparses).
- [x] **P5 intra-module compose (`delay-v6`):** `compose_reg_to_reg_paths` chains
  assign/comb fragments into launch→capture cones. `gemm_span` is a `RegToReg`
  mul+add path (`nodes>1`, not `intoout`/`atomic`). End-to-end test
  `gemm_span_correct_emit_reanalyze_drops_fo4`: analyze → correct →
  `--real-cut-feeds` emit → re-analyze FO4 drops. Detector v15 does not deflate
  multi-region composed cones as independent-LHS bundles.
- [x] **P4 remainder + refuse codes:** multi-node paths with one over-budget mul/div
  stay `plain` and note `P4 remainder; atomic … is T3`. Apply-time refuses log a
  reason (`lean_emit_no_origin_rewrite`, `cleanliness_set`, `lane_forbids_insert_reg`,
  …) and `run.end` counts `refuse_by_reason` / `refuse_by_class` (PASS-STRATEGY §6.4).
- [x] **P6 S4 preference + per-stage budget:** S3/S4 each get `max(1, max_passes/2)`.
  S4 sorts `is_shallow_over_budget` (one-register [budget, 2·budget) slices) ahead of
  monsters so the 75% [10,20) bulk sets the InsertReg schedule.
- [x] **P2 comment interiors:** skip every CST operator inside `//` / `/*` (not only
  `/` and `*`) and blank comment text out of assign RHS. Fixture
  `parse/comment_interiors.sv` covers the te_priority `/*|| (a * b)` and trailing
  `// c / d * e` shapes.
- [x] Soak with `--real-cut-feeds` on `full_corev_apu` (`audit-gemm-expol7/`):
  origin rewrite lands; integrity `reparse_ok`/`joint_ok`. Emitted
  post_analyze **161.5→149.0** / 268.5 MHz (IR **161.5→129.0**, 188 edits).
  Residual 149 is still the 144-node gemm capture `dot_pending_q` (InsertReg
  origins were sequential NBAs in the same `always_ff`, not that capture).
- [x] **6 residual `cva6_*` MMU atomics explained (`delay-v10`):** not `+:` Opaque.
  `cva6_shared_tlb.sv:219` is `v_st_enbl[…][HYP_EXT*2:0]` (0-FO4 slice, string
  `*` fallback → 56 Mul); `:260`/`:740` are `VpnLen/PtLevels` and `VpnLen%PtLevels`
  in replication counts and `[msb:lsb]` (plus trailing `//`); `cva6_ptw.sv:580`,
  `cva6_tlb.sv:211`, `:378` are the same `HYP_EXT*2` bound on multi-node cones
  (P4 remainder once the Mul node is gone). Runtime `a * b` still charged.
- [x] **P1 `+:` / `-:` indexed part-select (`delay-v7`):** parser no longer eats `+:`
  as add, so `mem[(a / b) +: 8]` is an Index with `+:` (width LRM-constant, base
  index charged). Replication counts were already zero-cost.
- [x] **P1 packed dims / case labels (`delay-v8`):** BinaryOperator tokens whose
  loc sits in a `PackedDimension` / `UnpackedDimension` / `CaseItemExpression`
  span are skipped (`lrm_constant_spans`). Fixture `parse/packed_dim_lrm.sv`.
- [x] **P1 select-kind AST (`delay-v9`):** `Expr::PartSelect { kind: FixedRange |
  IndexedPlus | IndexedMinus }` instead of fake `Binary ":"` / `"+:"` / `"-:"`.
  Cost / lattice / emit / spine walk the node; `[msb:lsb]` bounds and `+:`/`-:`
  widths stay LRM-constant, runtime `+:` base still charged.
- [x] **P1 parsed-tree 0 FO4 is authoritative (`delay-v10`):** `attribute_costs`
  no longer falls back to a string-heuristic `Mul`/`DivRem` when the Expr tree
  costs 0. CST skip extended to `ConstantRange` / indexed-select width /
  replication count. Fixture `parse/part_select_const_arith.sv`. Explains the
  six residual `cva6_*` MMU `atomic_over_budget` paths in `audit-strict-v4`
  (`:219` `HYP_EXT*2` slice, `:260`/`:740` `VpnLen%PtLevels` pad, plus P4
  multi-node remainders). **Confirmed delay-v13 soak:** MMU atomic count **6 → 0**.
- [x] **P1 module-localparam seed (`delay-v11`):** `attribute_costs` / spine /
  planner seed `ConstSeed` from module localparams, parameters, host param-map
  keys, and imported package names. Mixed-case `VpnLen` / `PtLevels` are Const
  (heuristic-only still treats them as runtime). Fixture `parse/param_lattice.sv`.
  Genvars are per-span in delay-v13.
- [x] **Module-scoped lowering restored (`delay-v12` / B3):** `ModuleScope` CST
  slice per `module` so ports / params / localparams / regions / instances are
  not the file union. Golden `fixtures/measure/two_modules.sv` +
  `multi_module_file_scopes_ports_regions_and_instances`. Makes the v11 seed
  actually per-module. Function-body/call timing remains open.
- [x] **P1 genvar-scoped seed (`delay-v13`):** genvar names are Const only for
  nodes whose loc sits in that `LoopGenerateConstruct` span
  (`TimingModule::genvar_names_at`). Generate-for init/condition/step and
  if/case-generate conditions are LRM-constant CST. Fixture
  `parse/genvar_lattice.sv` (`WIDTH * i` inside `g` is not Mul; `a * idx` is).
- [x] **Assignment kind in IR:** `IrNode.assign_kind` is Blocking / Nonblocking /
  Continuous from the CST. Compose treats NBA lhs as flops and blocking
  `always_ff` temps as combo (`fixtures/measure/nba_vs_blocking.sv`). Do not infer
  extra clock edges from `ceil(FO4/budget)`.
- [x] **S5 T3 report:** `run_correct_passes` emits `stage.s5` with `t3_only_cards`,
  P8 remainder, and P9 iterative counts (asks, not cuts).
- [x] **delay-v13 4 GHz analyze soak** (`audit-delay-v13/`, 4000 MHz / 20 ps /
  margin 0.2 / `-O3`, analyze-only): P1/P2 closed the artifact atomic mass.
- [x] **Detector v16 — composed exclusive/parallel (`audit-delay-v16/`):** P5
  compose no longer skips exclusive/dense/parallel-timing. Independent-LHS
  bundle stays skipped on multi-region cones (gemm InsertReg). Parallel-timing
  on composed paths stays `plain` (CombDatapath). P4 remainder subtracts a T3
  atomic from cones with `nodes>=8`. Re-soak primary **428.5→125** (core) and
  **333→181.5** (APU gemm).
- [x] **delay-v14 Const-divisor `/` `%` + detector v19 P4 remainder.** Runtime
  `/` or `%` whose divisor is Const (`8`, `WIDTH`, `*Cfg.*`) is a shift /
  bit-select, not a 120 FO4 SRT divider (`8 / a` stays DivRem). P4 remainder
  subtracts a T3 atomic that owns ≥90% of cone FO4, or whose leftover is at
  least as large as the atomic (twin `%`/`/` 120+120+1), or `nodes≥8`.
  `gemm_span` 56/68 is kept. v16 primary 125 was `hpdcache_memctrl.sv:472`.
- [x] **delay-v14 / v19 4 GHz analyze soak** (`audit-delay-v14/`, 4000 MHz /
  20 ps / `-O3`). Core primary **125→90** (`lzc`); APU **181.5** gemm
  unchanged. `pe_dot` 153 gone (`(cnt+1)/2`). slack<0 **2342→2257** core,
  **676→552** APU.
- [x] **delay-v15 nested genvar + P10 handshake.** Nested generate-for keeps
  each loop's own genvar. P10 locks same-edge pulse+index output bundles and
  consumer bank restores; InsertReg refuse. `lzc` is a prefix-tree lane.
- [x] **delay-v15 4 GHz analyze soak** (`audit-delay-v15/`). Core primary
  **90→86** (`hpdcache_mshr`); `worst_all` **120→97.5** (FMA MC). `lzc` 90
  and `hpdcache :980` 120 gone. Core atomics **9→5**. APU primary still
  **181.5** gemm (InsertReg/`--real-cut-feeds` remaining).
- [x] **delay-v16 comb-for index Const.** `for (int unsigned w = 0; w < N; w++)`
  in always_comb unrolls; `w * SETS` is not a Mul. Fixture
  `parse/comb_for_scale.sv`. Core soak `audit-delay-v16/`: primary **86→51**
  (`g6lc_ftq`); `hpdcache_mshr` 86 gone; atomics **5→4**; `worst_all` 97.5 FMA.

### delay-v13 soak — remaining ordered by measured leverage

Logs: `E:/cva6/build-platform/workspace/build/sv-timing/audit-delay-v13/{full_core,full_corev_apu}/analyze.json`.
Budget 10 FO4. Compared to `audit-strict-v4` (delay-v4).

| | delay-v4 core | delay-v13 core | delay-v4 APU | delay-v13 APU |
|---|---:|---:|---:|---:|
| paths | 5410 | **10041** | 4636 | **5340** |
| slack<0 | 621 | **2495** | 144 | **702** |
| atomic_over_budget | 35 / 3158.5 | **9 / 588.0** | 10 / 783.0 | **3 / 168.0** |
| P4 atomic nodes>1 | 16 | **0** | 6 | **0** |
| MMU atomic | 6 | **0** | 0 | 0 |
| primary FO4 | 70 (`g6lc_ftq`) | **428.5** (`macro_decoder` regtoout) | 304.5 (gemm) | **333** (`g6lc_ai_pe_dot` intoout) |

P1/P2 worked: `fpnew_opgroup_block` 176 DivRem → 56 Mul; shared-TLB 136/131 gone;
icache wrapper 132.5 gone; gemm replication 131 gone; `te_priority` 56 gone.

The new ceiling is **not leftover constant arithmetic**. Detector v15 skips exclusive /
bundle / parallel-timing deflation on P5 composed multi-region cones
(`path_class.rs` `p5_composed_cone`). That kept gemm from being an independent-LHS
bundle, and it also left exclusive CSR/case cones as raw serial sums:

1. **[x] Composed-path exclusive / parallel (detector v16).**
   `csr_regfile` 370 and `macro_decoder` 428 dropped off primary. APU primary is
   the gemm cone (181.5). `te_packet_emitter` 326→78 dense. Independent-LHS
   bundle still skipped on multi-region (gemm stays InsertReg-able).
2. **[x] P4 remainder FO4 on wide cones (`nodes>=8`).** Short serial mul chains
   keep the operator in the period (`gemm_span` e2e). `pe_dot` 333→153 exclusive.
   **v17:** subtract when the T3 node owns ≥90% of cone FO4 (any `nodes>1`).
3. **[x] P8 gemm `--real-cut-feeds` on `full_corev_apu`.** Soak
   `audit-gemm-rcf/` (delay-v16, `-O3`, `--allow-latency`, stages=20).
   Analyze primary **181.5→161.5** from comb-for Const (not InsertReg).
   Correct **152 edits**, primary **161.5→161.5**, emitted post_analyze
   still 161.5 FO4 / 247.7 MHz. S4 did not cut the 144-node Plain cone
   (cleanliness / worklist — not a missing emit flag). Fixture e2e remains
   green.
- [x] **Exception policy for resilient datapath (gemm).** Mixed modules
   win `seq_plus_comb` and T1-first relocation cards never attach
   InsertReg. `exception_policy` admits S4 InsertReg on Plain `RegToReg`
   ≥ 2·budget. Indexed `mem[port]` restores (FTQ / pc_bank) stay
   HandshakeLock. Incidental P10 class_note from sharing an `always_ff`
   with a status pulse does **not** starve a gemm-shaped cone (path 3131).
   S4 rewrites T1-first cards, prepends missing resilient cones, and
   sorts them ahead of P6 shallow. Fixture `mixed_resilient.sv`.
- [x] **Soak `audit-gemm-expol/`** (delay-v16 CLI, `-O3`, `--real-cut-feeds`,
   stages=20) *before* the incidental-P10 override: exception fired
   (gemm 74.5→56 InsertReg, `policy_subcode` 30.5→10, 164 edits vs 152).
   Primary **161.5→161.5** because path 3131 (144-node) was tagged P10.
- [x] **Soak `audit-gemm-expol2/`:** exception admitted 3131, then
   `apply_work_item` refused `lane_forbids_insert_reg` (P10 → NextStateFsm).
- [x] **Lane bypass:** `cone_lane` keeps CombDatapath for resilient cones;
   `apply_work_item` InsertReg if the exception admits. Indexed restores
   stay NextStateFsm. Handshake fixture still refuses.
- [x] **Soak `audit-gemm-expol3/`** (after lane bypass): path 3131
   InsertReg **161.5→10** IR. Correct IR primary **161.5→129.0** (new
   gemm cone path 5340). 188 edits. Emitted `post_analyze` still **161.5**
   / 247.7 MHz — `gen_reuse_b` `assign c_span` left live; `gen_reuse_a`
   was commented + piped. Residual is emit origin-rewrite on the twin
   generate, not admission.
- [x] **Twin generate origin rewrite.** `rewrite_origin_assigns` now pipes
   every other continuous `assign lhs = rhs` with the same text as a
   claimed cut (`gen_reuse_a` / `gen_reuse_b` both `c_span`). Fixture
   `twin_generate_span.sv`. Claimed line still uses module sink; twins
   get in-place `assign lhs = pipe`.
- [x] **Soak `audit-gemm-expol4/`** after twin rewrite: emit now has
   `twin moved c_span` + `assign c_span = pipe_svt_p1_15` in `gen_reuse_b`.
   IR still **161.5→129.0** (path 3131 InsertReg 161.5→10). Emitted
   `post_analyze` still **161.5** / 247.7 MHz — the 144-node cone's
   origin is procedural (`always_ff` :1859, R12d keeps it).
- [x] **Procedural origin rewrite** under `--real-cut-feeds`: simple
   `lhs <= rhs` / `lhs = rhs` → sample the pipe (no continuous sink).
   Fixture `proc_nba_span.sv`. Blank-before-`assign` stays continuous
   (`cut_rewrite_anchor`; `instr_queue` `idx_is_d`, `te_branch_map`
   `map_o` — `audit-gemm-expol5` emitted illegal module-scope
   `lhs = pipe`). Multi-line NBA with empty first-line RHS still emits
   `lhs <= pipe` (`audit-gemm-expol6` left `row <=` dangling).
- [x] **Soak `audit-gemm-expol7/`** (delay-v16 release CLI, `-O3`,
   `--real-cut-feeds`, stages=20): integrity green. IR **161.5→129.0**.
   Emitted post_analyze **161.5→149.0** / 268.5 MHz, 188 edits. Path
   3131 InsertReg origins are `sum_i_q` / `ar_slot_q[…].col` /
   `ar_slot_q[…].row` / `stc_elem_q`; `dot_pending_q` :1859 stays live
   (still the 144-node hottest loc).
- [x] **delay-v17 / path_class v20:** NBA write→later-read in one
   `always_ff` is Q (IEEE NBA schedule), not a combo edge. That was
   poisoning `procedural_ok` so IndependentLhsBundle never deflated the
   144-node gemm always_ff (161.5 serial sum of sibling flops). Fixture
   `measure/always_ff_nba_bundle.sv`. Blocking temps still chain.
- [x] **Soak `audit-delay-v17/`** APU `-O3` `--real-cut-feeds` stages=20:
   integrity green. Analyze max_adj **78** (`te_packet_emitter` intoout
   dense). Path 3131 **IndependentLhsBundle 26**. RegToReg after correct
   **36** (`g6lc_coherence_hub` dense, max_node=10). Gemm P4 remainder
   74.5 (56 Mul T3) / bundles 34.
- [x] **path_class v21:** next-state `_d` FO4 is **max_field**, not
   scratchboard makespan (hub 30 FO4 chain of sibling fields). Composed
   next-state FSMs still get IndependentLhsBundle; gemm named-temp
   chains stay skipped. Fixture-level test
   `composed_next_state_fsm_bundles_to_max_field_not_makespan`.
- [x] **Soak `audit-pc-v21/`:** hub **36→11**. Analyze max_adj **74.5**
   (gemm P4 remainder, 56 Mul T3). Emit RegToReg **30.5**
   (`g6lc_ai_policy_subcode` Plain). Emitter intoout **61** (max_node 60).
- [x] **Residual InsertReg keeps capture.** Dummy `OutputPort` made
   residuals `RegToOut`, so `exception_policy` dropped the 20.5 FO4
   `policy_subcode` remainder after the first `d = pipe` cut. Spine
   expand now splices a fat non-atomic node on multi-node paths.
   `max_cuts` follows `--opt-max-stages-per-region` (clamp 1–16).
   `--real-cut-feeds` also sets `emit_balance_mux_rtl`. Continuous
   BalanceMux rewrite keeps `assign` (`audit-remain-v21` Parse on
   `te_packet_emitter` `address_off`).
- [x] **Soak `audit-remain-v21b/`:** integrity green. Emit RegToReg
   **74.5→26** / 1538 MHz (189 edits). `policy_subcode` three InsertRegs
   30.5→10 (gone from post ≥20). IR 74.5→56 T3.
- [x] **BalanceMux origin-process inject.** Snippets that reference
   decls after the first `always_comb` (gemm `pe_float_en`) were demoted
   as late locals. Inject at the origin process; late-decl check uses
   that line. BM RHS rewrite runs **before** InsertReg so added comment
   lines do not retarget the next NBA (`audit-remain-v22` wrote
   `stc_elem_q <= svt_bm_top` instead of `dot_pending_q`). Fixture
   `balance_mux_snippet_injects_after_mid_module_decls` +
   `balance_mux_rewrite_not_shifted_by_insertreg_comments`.
- [x] **Soak `audit-remain-v23/`:** integrity green. Emit RegToReg
   **74.5→22** / 1818 MHz (189 edits). Gemm 26 gone (`dot_pending_q <=
   svt_bm_top_p3131_n8174`).
- [x] **delay-v18 / path_class v22.** P1: `pkg::NAME` is Const (`::`
   split; `te_packet_emitter` `used_bits += te_pkg::XLEN+…` was 61 FO4
   of 10-FO4 adds). `x+1` and const-offset `+` are increment (LogicBit),
   not CPA. Unique-case mux tax is `model.mux` (2.5), not `log2(n)×2.5`.
   Fixtures: `package_scope_screaming_idents_are_elaboration_const`,
   `plus_one_is_increment_not_carry_propagate_add`.
- [x] **Soak `audit-delay-v18/`:** integrity green. Emit **74.5→18.5** /
   2162 MHz (181 edits). Analyze max_adj **74.5** (gemm P4 T3).
   te_packet 61 / axi2mem 22 / timer 20 / l2_mshr exclusive 18.8 gone
   from the flop primary.
- [x] **path_class v23 + P6 resilient.** Next-state bundle/dense: no wire
   tax, no log2 overwrite mux on `_d` fields (prefetcher 17). Exclusive
   flop D/Q is max_arm (dram_timing 15.6 leftover). Ternary `mem[port]`
   restore walks `?:` (inval_bus). Plain `RegToReg` > budget admits S4
   InsertReg; real P10 / indexed restore / AXI wrap bundle stay locked.
   Fixtures: `next_state_multi_write_field_is_max_not_log_mux`,
   `exclusive_flop_capture_is_max_arm_not_mux_plus_leftover`,
   `measure/ternary_indexed_restore.sv`.
- [x] **Soak `audit-remain-v24/`:** integrity green. Emit **74.5→20.0** /
   2000 MHz (184 edits, 37 InsertReg). Over-budget 401→192, RegToReg
   205→86. Prefetcher 17 / dram_timing 15.6 / cluster-of-11 gone.
   New primary: `g6lc_l2_mshr` **20** Plain P10 (`(IDX_W+1)'(1)` billed
   as CPA). Gemm 18.5 geometry `b_span` remains. AXI wrap not InsertReg'd.
- [x] **Soak `audit-remain-v25/` (reverted).** General `(W)'(v)` collapse
   made gemm `32'(n-1)*row+k` a 67.5 Mul+add; analyze max_adj **74.5→123.5**,
   emit **20→40.5**.
- [x] **delay-v19 narrow `(W)'(1)`.** Only a width-cast of literal 1 is an
   increment (`count_q - (IDX_W+1)'(1)`). Other `(W)'(v)` backtracks so
   gemm `32'(n-1)*row` does not become Mul. Guard in
   `plus_one_is_increment_not_carry_propagate_add`.
- [x] **Soak `audit-remain-v26/`:** delay-v19 narrow did **not** move l2_mshr
   20 (2-node `mem_d` waiter-shift + nwait, P10). Emit still **20.0**.
   Analyze max_adj stayed **74.5** (gemm not inflated).
- [x] **path_class v24.** Exclusive flop-D allows 2 arms / 2 nodes
   (`mem_d.waiters` + `mem_d.nwait` Plain-sum 20). Fixture
   `exclusive_flop_capture_two_arms_is_max_not_sum`.
- [x] **Soak `audit-remain-v27/`:** integrity green. Emit **74.5→18.5** /
   2162 MHz (186 edits). `g6lc_l2_mshr` 20 gone (2-arm `mem_d` exclusive).
   Primary is gemm geometry **18.5**. AXI wrap not InsertReg'd. Analyze
   max_adj **74.5** T3.
- [x] **S4 pending resilient (reverted).** Extra S4 after a flat 18.5
   primary made `policy_subcode` **30.5** (`audit-remain-v28/`). Loop
   change reverted. Wrap-boundary / fat Plain FSM (≥16, no Mul) still
   not resilient. Soak of record remains **`audit-remain-v27/` 18.5**.
4. **[x] P1 Const-divisor `/` `%` (`delay-v14`) + P4 twin DivRem peel (v19).**
   `hpdcache_memctrl` :472 dropped off primary (125→peeled). `:980` is still
   a 1-node 120 DivRem (RHS not recovered on the generate mux — P3).
   `(cnt + 1) / 2` un-ranked `pe_dot` 153. Remaining single-node atomics are
   runtime muls (`fpnew_fma*`, `multiplier.sv:115`, gemm 459/519/608,
   `wt_dcache_mem`, `issue_read_operands.sv:1479`) plus `:980`.
5. **[x] P9 `control_mvp` 719** stays multi-cycle; v19 `worst_all` is 120
   (`:980` atomic) / 181.5 (APU gemm).
6. **[x] `te_packet_emitter` dense 78** (was 326 plain).
7. **[x] `lzc` is a function tree.** `ConeLane` maps `lzc` / `lzc_*` /
   `*_lzc` to ExclusiveMux (comb ok, no InsertReg). Fixture `parse/lzc_tree.sv`
   primary < 40 FO4. Soak `lzc` 90 may still be a WIDTH-elaborated instance;
   do not InsertReg it.
8. **[x] P10 cycle-identity / same-edge handshake.** Implemented:
   `path_is_handshake_locked` / `tag_handshake_locks`. Same-`always_ff` 2+
   output-driving NBAs with a pulse-like RHS; consumer comb `mem[port]` of
   an indexed-NBA base. InsertReg refuse + NextStateFsm lane. Fixture
   `measure/handshake_switch.sv`. No `g6lc_*` names in crates.
9. **[x] Nested generate-for genvar (`delay-v15`).** Outer loops no longer
   inherit the innermost genvar name, so `gen_i * Cfg` / `gen_j % Cfg` in
   `hpdcache_memctrl` generate muxes are Const∘Const (fixture
   `parse/hpdcache_idx_mux.sv`). That was the `:980` 120 DivRem leftover.
- [ ] Complete function-body/call timing and genuine register/clock-domain path
  boundaries need further work. Module-scoped lowering is `delay-v12`; genvar
  seed is `delay-v13`; Const-divisor scale is `delay-v14`. Recovered RHS on
  generate-mux `%` (`hpdcache` :980) is the leftover P1 hole.
- [ ] Compare legal transformed netlists with constrained OpenSTA setup/hold analysis.
  S1 currently fails on missing include/macro context; no S2 processor timing exists.
  Reference report parsing and mocked stages are not a real STA run.
- [ ] Feature-max production Flist/config/legality and RTL/formal/functional validation
  remain open. QEMU validates software/device contracts, not timing or emitted SV.
- [ ] Keep core CVXIF and SoC island arithmetic/area evidence separate. T3 stage counts
  are idealized estimates; datapath changes must include valid/ready, reset/flush,
  exceptions, numerical behavior and measured throughput/area/STA evidence.

See `architecture/DESIGN.md`, `FREQUENCY-CLOSURE.md`, and
`OPENSTA-CORRECTION-WORKFLOW.md` for the updated algorithm/evidence contracts.

## 2026-09-10 (f) — 4 GHz support: the T3 requirement now scales, and the worst path is a comment

- [x] **`t3_arch_multicycle_mul` hardcoded its own answer.** `latency_delta: 2` and
  `expected_fo4_after: budget`, regardless of how far over budget the operator was. That
  is right at ~1.25 GHz -- a 56 FO4 `mul` against a 32 FO4 budget needs `ceil(56/32) = 2`
  stages -- and it under-reports as the target rises: at 4 GHz the budget is 10 FO4 and
  the same multiply needs 6. Since `AtomicOverBudget` is exactly the class no cut strategy
  can touch, this card is the ONLY actionable output for the paths that set the
  high-frequency ceiling, so describing one operating point made the tool useless above
  it. Stage count is now `ceil(atomic_cost / budget)` from `dominant_atomic_op` -- the
  same most-expensive `Mul`/`DivRem` node `try_atomic_over_budget` selects, so the
  requirement is derived from the operator that caused the classification rather than from
  the path sum. Test `arch_multicycle_stage_count_scales_with_the_target` pins
  1250/2000/4000 MHz at 20 ps and 4000 at 12 ps (2/3/6/4 stages).
- [x] It works on the real core. At 4000 MHz / 20 ps, `full_core` yields 24 `atomic_op`
  cards with per-path requirements: `fpnew_cast_multi` DivRem 120 FO4 -> 12 stages,
  `cva6_ptw` Mul 102 -> 11, `cva6_tlb` Mul 78 -> 8, `g6lc_ai_exec` Mul 56 -> 6. That is a
  microarchitectural work list instead of a dead end.

### And it exposed a measurement defect that corrupts the headline

- [ ] **The worst path in the whole core is a COMMENT.** `SyncDpRam.out0`, 720.0 FO4,
  `atomic_over_budget`, `nodes=1`, `primary_loc SyncDpRam.sv:136` -- and line 136 is
  `   ////////////////////////////`. The file contains **zero** `/` or `%` operators
  outside comments (348 `/` characters, all in comments), and 720 = 6 x the model's
  `div_rem` base of 120. Comment slashes are being lowered as `DivRem` nodes.
- [ ] Scope, measured rather than assumed: **3 of 24** atomic paths sit on comment lines,
  and comment lines carry **1,577 of 29,925 FO4 (5.3%)**. So the defect is narrow -- but
  it owns the single worst path, which is what every reported ceiling is derived from.
  With comment-line paths removed the worst becomes **545.5 FO4 `g6lc_ai_exec`**, which is
  real code.
- [ ] **Consequence for the earlier conclusions.** The "emitted core floors at ~99.4 FO4 /
  ~503 MHz at 20 ps" result from (e) is contaminated: it was measured against a design
  whose worst path is a comment artefact, and `SyncDpRam` was cited in (b), (c) and (e) as
  a real (if suspect) behavioural-model cone. It is not a model artefact -- it is a
  lowering bug. The AI-island finding survives, since `g6lc_ai_exec` at 545.5 FO4 is on
  real code and is now the genuine worst path.
- [ ] Fix belongs in parse/lower: comment content must never reach operator extraction.
  Until then, treat any path whose `primary_loc` is a comment line as invalid, and re-run
  the frequency frontier afterwards -- the numbers in (e) should be expected to move.

## 2026-09-10 (e) — the -O surface measured, and where the emitted core actually floors

Every 4 GHz run before this used **-O2** (`max_passes=4 worklist_width=1
cut=cost-balanced stages=1 min_gain=2 balanced`) at the package default `fo4_ps=20`.
**-O3** is the aggressivity/reordering surface the request was aiming at
(`max_passes=16 worklist_width=4 cut=budget-fit stages=8 min_gain=1 thorough`,
per `architecture/OPTIMIZATION-LEVELS.md` §3.1). Both were run on `full_core`, and the
emitted-RTL figure is converted to FO4 so rows at different `fo4_ps` are comparable.

| target | fo4_ps | opt | budget FO4 | edits | IR closure | emitted | emitted FO4 |
|--:|--:|---|--:|--:|---|--:|--:|
| 4000 | 20 | -O2 | 10.0 | 928 | false 2086.6 | 503.1 | **99.4** |
| 4000 | 20 | **-O3** | 10.0 | **1091** | false 2086.6 | 503.1 | **99.4** |
| 4000 | 12 | -O3 | 16.7 | 443 | **true 4000.0** | 838.6 | **99.4** |
| 2500 | 12 | -O3 | 26.7 | 156 | false 1833.3 | 701.8 | 118.7 |
| 2000 | 12 | -O3 | 33.3 | 48 | false 1833.3 | 701.8 | 118.7 |
| 1250 | 12 | -O3 | 53.3 | 4 | true 1257.9 | 701.8 | 118.7 |

- [x] **-O3 buys nothing over -O2 here, measured.** Same operating point, +163 edits
  (928 -> 1091), and an **identical** emitted result (99.4 FO4) and identical IR figure
  (2086.6 MHz). Sixteen passes, worklist 4, budget-fit multi-cut to 8 stages/region and
  thorough effort do not move the emitted critical path. So "increase passes / raise
  aggressivity" is not the lever; that is now a measurement rather than an expectation.
- [x] **The emitted design floors at ~99.4 FO4** and will not go below it at any target or
  opt level. Aiming at 4 GHz rather than 2 GHz does buy a real 118.7 -> 99.4 FO4 (16%)
  improvement, and then stops. The limit is the `atomic_over_budget` classification on the
  worst cones (`SyncDpRam` 720, `g6lc_ai_exec` 545.5, `axi_adapter`): indivisible, so no
  cut strategy applies however many passes it is given.
- [x] **What 99.4 FO4 means for 4 GHz.** 4 GHz is a 250 ps period, so 99.4 FO4 needs
  `FO4 <= 2.5 ps` — below any current or announced node. Per node the emitted core is
  ~503 MHz at 20 ps, ~839 MHz at 12 ps, ~1.68 GHz at 6 ps. Reaching 4 GHz needs the
  emitted depth down to ~41 FO4 at 7 nm, a 2.4x reduction, which is microarchitectural
  pipelining of those specific cones and not an `-O` dial.
- [x] **`fo4_ps` is a process input, not a tuning knob.** At 4000 MHz the budget is 10.0
  FO4 at 20 ps, 16.7 at 12 ps, 33.3 at 6 ps, so "closing at 4 GHz" can be manufactured by
  choosing the node. The row that does report `closes=true 4000.0` (4000/12) has an
  emitted figure of 838.6 MHz — the IR closure is the `primary_fo4` artefact from (c),
  not a result. `AGENTS-configuration.md` puts the target of record at **1.25 GHz /
  12 nm**, with the reference shelf at 1.25-2.2 GHz on 12-14 nm and no 12 nm part above
  2.0 GHz.
- [ ] **Feature-max production Flist not built.** Deliberately deferred: the tuning result
  above says the ceiling is set by a handful of atomic cones, so a wider flist would add
  modules without moving the frontier, and 8-core / 8-issue / hypervisor are
  `cva6_cfg_t` + `check_cfg` feature enablement rather than a file list. The useful
  sequence is: pipeline `g6lc_ai_exec`, decide the `SyncDpRam` behavioural-model question,
  and settle whether the vendored `rv_tracer` belongs in the package -- then widen.

## 2026-09-10 (d) — the analysis was screening the WRONG core; SMT2/fetch_B retired correctly

- [x] **`+define+` was silently dropped from every soak package, so the wrong
  configuration was analysed.** `flist_expand` collects defines and
  `write_filtered_portable` wrote only `+incdir+` and file paths. For this repo that is
  not cosmetic: `core/Flist.cva6` sets `+define+G6LC_FETCH_B` to select the fetch_B
  instruction supply, so without it every `ifdef G6LC_FETCH_B` body was skipped while the
  `ifndef` A-path / g1* recover bodies were analysed as if live. Every full_core number
  before this entry describes a core that is not built. The CLI already accepts
  `+define+` from a filelist, so the writer now emits them and the soak logs them
  (`profile full_core defines: G6LC_FETCH_B`).
- [x] **The previous blanket `/core/smt_legacy/` exclude was wrong and removed live SMT2
  RTL.** `architecture/core-fetch/SMT-LEGACY.md` is authoritative: the directory is three
  things, and `Flist.cva6` compiles 19 of 23 files individually. Of those 19, **9 are
  LIVE on fetch_B** — `g6lc_thread_select`, `g6lc_hart_state`, `g6lc_smt_regfile`,
  `g6lc_smt_pc_bank`, `g6lc_smt_csr_bank`, `g6lc_issue_barrier` (SMT2 banks and
  scheduler) plus the `g6lc_ex_id` / `g6lc_sb_keep` / `g6lc_cf_pc` packages — and **10
  are g1\* recover** whose call sites are skipped under `G6LC_FETCH_B`. Excluding all 19
  deleted exactly the SMT2 infrastructure the profile exists to measure. The exclude now
  names the 10 recover files and nothing else.
- [x] **SMT2 / fetch_B configuration verified, not assumed.** With the define carried and
  the recover set retired, `full_core` reports `modules=183 paths=4208`:
  all six SMT2 bank/scheduler modules present; all ten recover modules absent; and the
  instruction supply is **exclusively `core/fetch_B/`** — `frontend`, `instr_queue`,
  `instr_scan` and `instr_realign` all resolve to `core/fetch_B/*`, so there is exactly
  one `module frontend`, which is the invariant SMT-LEGACY.md §2 insists on.
  `g6lc_ex_id` / `g6lc_sb_keep` / `g6lc_cf_pc` are **packages**, so their absence from
  the module list is correct rather than a gap.
- [x] **`sparse_frontend.f` was screening retired RTL.** It listed
  `core/frontend/instr_queue.sv` and `core/frontend/instr_scan.sv`, which `Flist.cva6`
  has commented out (L249-251) in favour of the fetch_B copies. It now uses
  `core/fetch_B/{g6lc_fetch_pkg,instr_queue,instr_scan}.sv` with
  `+define+G6LC_FETCH_B`, keeps the predictors in `core/frontend`, and carries a note
  against ever adding a second `module frontend`.

### The three instruction supplies, for the record

| Path | Role | Selected by |
|---|---|---|
| `core/fetch_B/` (6 files) | **LIVE** supply | `+define+G6LC_FETCH_B` + `-f Flist.fetch_B` |
| `core/smt_legacy/{frontend,instr_queue,instr_scan,instr_realign}.sv` | oracle alternative | `-f Flist.smt_legacy` only, never with fetch_B |
| `core/frontend/{frontend,instr_queue,instr_scan}.sv` | **retired** | commented out in `Flist.cva6` |

`core/frontend` otherwise holds the predictors, which are live. `core/smt/` holds an
older `g6lc_fetch_{pkg,dbg}` pair reachable only through `Flist.fetch`; `Flist.cva6`
comments out `core/smt/g6lc_fetch_dbg.sv` and takes fetch_B's copies instead.

### full_core at 4 GHz on the CORRECTED configuration

`analyze paths=4208 primary_fo4=134.0 worst_all=720.0`;
`correct 134.0 -> 19.17 (1091 edits)`; `post_closure 2086.6 MHz` (worst `axi_adapter`,
slack -9.2); **`post_analyze_sv 503.1 MHz`** over 6,102 paths / 206 modules / 230 files.
The gap between the last two is the same reporting artefact recorded in (c): the IR
figure excludes `atomic_over_budget` and multi-cycle classes, the emitted-RTL figure does
not.

- [ ] Not yet done from this request: a single production Flist covering SMT2 OoO
  8-core / 8-issue stream plane + ai_island + RVV + hypervisor + APU while excluding
  `rv_tracer-main`, and validation through `g6lc_qemu`. The retirement and define work
  above is the prerequisite, since a feature-max flist built on the wrong define set
  would have inherited the same defect.

## 2026-09-10 (c) — the emit validity gate was vacuous, and fixing it falsifies the closure claims

- [x] **`post_analyze_sv` measured nothing and reported it as a verdict.** It re-analysed
  only the FIRST rewritten file, with `ParamMap::new()` (empty, so no `CVA6Cfg.*`
  resolved) and `package_mode: false`, then printed `closes=false` from the resulting
  empty design. Every part of that is wrong for a project: one file cannot see its
  packages, and `paths=0` is *inconclusive*, not *failing*. It now re-analyses the whole
  emitted project with the same param map and package mode as the real run (built once
  and shared), substitutes emitted files for the originals they replace, and prints
  `INCONCLUSIVE` with a reason when it cannot measure. Verified it reads what it claims:
  `full_corev_apu` post-analysis shows `files=157 containing __svt=157`,
  `modules=123 from emitted=123`, and the worst path's owner resolves to the emitted
  `te_packet_emitter__svt.sv`.
- [x] **With the gate working, the IR closure claims do not survive re-measurement.**

  | profile | target | `post_closure` (IR, filtered) | `post_analyze_sv` (emitted RTL) |
  |---|--:|---|---|
  | `sparse_g6lc` | 2000 MHz | closes, 2000 MHz | **1594.3 MHz**, 85 paths |
  | `full_corev_apu` | 4000 MHz | closes, 4000 MHz | **350.9 MHz**, 1566 paths |

  The emitted designs still carry their original worst paths: `sparse_g6lc` retains
  `g6lc_rename.out0` at 25.1 FO4 — exactly the pre-correction `primary_fo4` of 25.0888 —
  and `full_corev_apu` retains `te_packet_emitter.out0` at 380.5 FO4, which the run's own
  `max_path_fo4 380.5->380.5` already admitted. `full_corev_apu`'s 350.9 MHz is the same
  figure the uncorrected baseline reported (350.877).
- [x] **Why, and it is not a bug in the corrector so much as in how the gain is reported.**
  Every top path in the re-analysed APU is `atomic_over_budget` — classified indivisible,
  so no latency-neutral or latency-allowing rewrite applies. `primary_fo4` is taken from
  `post_closure`, which excludes exactly those classes. So `primary_fo4 114.0 -> 10.0,
  closes=true` is a true statement about the *actionable subset* and a false impression
  about the design. The headline should carry both numbers.
- [ ] **Consequence for the 4 GHz question.** On the emitted evidence the APU is limited
  to ~350 MHz by the VENDORED RISC-V trace encoder (`te_packet_emitter`, `te_reg`,
  `rv_tracer`, `framing_top` — `corev_apu/instr_tracing/rv_tracer-main`), not by core
  logic. That subsystem is a candidate for the same treatment `smt_legacy` just got (a
  profile `exclude`, or a multi-cycle/`atomic` declaration), because as long as it is in
  the package it sets the reported ceiling for everything else. Deciding that is a host
  call, not a package one.
- [ ] Still open from (b): the `g6lc_ai_exec` 545.5 FO4 cone, and `core/alu.sv`'s non-LRM
  chained select.

## 2026-09-10 (b) — full_core / full_corev_apu at 4 GHz, and a cache defect that hid the AI island

Two more package defects, both found by pushing the whole design rather than a slice.

- [x] **`path_class` write aborted any multi-pass design.** `put_path_classes` DELETEs
  by `design_key` then plain-INSERTs one row per exception, but `path_exceptions` is a
  push-only log and `correct` re-classifies on every pass (`--max-passes 16`), so repeat
  `path_id`s are normal. The result was
  `UNIQUE constraint failed: path_class.design_key, path_class.path_id`, which killed
  `full_core` and `full_corev_apu` outright. The table is the denormalised CURRENT view
  (`PRIMARY KEY (design_key, path_id)`), so the write is now an UPSERT and the last
  classification wins. Small profiles converge in one pass, which is why only the full
  designs ever hit it. Regression test: `repeat_path_ids_upsert_instead_of_failing`.
- [x] **`design_key` omitted options that change the result — it silently served a
  wrong, smaller design.** The key digests file content, incdirs, defines, cost model,
  module filter and param keys, but NOT `allow_parse_errors` or `package_mode`. Both
  change the analyze output: the first decides whether a rejected file is skipped (its
  modules absent) or the run aborts, the second changes the lowering surface. Measured on
  `full_core`: a cache hit returned **139 modules / 3,608 paths** where a cold run over
  byte-identical inputs produced **177 modules / 4,130 paths** — same `design_key`,
  `design_hit=true`, `files_changed=0`. Both are now `#`-prefixed tokens in the key
  (the existing mechanism for "this must evict"), and cold/warm now agree at 177/4,130.
- [x] **What the stale design was hiding: every OoO and ai_island module.** The 139-module
  report contained *zero* `g6lc_*` modules. With the key fixed, `full_core` covers all 10
  OoO blocks (`g6lc_rob`, `g6lc_rename`, `g6lc_freelist`, `g6lc_rat`, `g6lc_prf`,
  `g6lc_iq`, `g6lc_lsq`, `g6lc_memdep`, `g6lc_ooo_dispatch`, `g6lc_ooo_backend`) and the
  3 AI-island modules. This is the whole reason the defect mattered: the blocks under
  active development were the ones missing from the timing report.
- [x] **`full_core` no longer analyses `core/smt_legacy`.** `full_core.f` is
  `-F core/Flist.cva6`, and that flist is the real build input, so the subset is expressed
  as a new declarative `exclude` on the soak profile (`["/core/smt_legacy/"]`, reported
  not silent) rather than by forking the flist or enumerating ~200 files that would drift.
  19 files excluded; 198 remain.

### Measured at `--target-mhz 4000 --correct --emit --allow-latency`

| profile | primary FO4 | edits | post_closure | blocker |
|---|---|--:|---|---|
| `full_corev_apu` | 114.0 -> **10.0** | 267 | **closes, 4000 MHz** | — |
| `full_core` | 134.0 -> **19.17** | 1096 | 2086.6 MHz | `axi_adapter` (slack -9.2) |
| `sparse_issue_lsu` | 31.67 -> 26.0 | 18 | 1538.5 MHz | `store_buffer` |

- [ ] **The raw worst cones do not move and are the real 4 GHz story.**
  `max_path_fo4` is unchanged by correction in every full run: 720.0 (`SyncDpRam`,
  vendored FPGA behavioural memory — likely a model artefact, not logic), 545.5
  (**`g6lc_ai_exec`**, the AI island execute cone — 54x over a 10 FO4 budget and the
  second-worst path in the core), 380.5 (`te_packet_emitter`, APU trace). The OoO blocks
  are by contrast healthy at <= 25.1 FO4 (`g6lc_rename` 25.1, `g6lc_rob` 23.3,
  `g6lc_iq` 21.8). So the ai_island exec cone, not the OoO rename set, is what needs
  microarchitectural pipelining before 4 GHz is meaningful for the core.
- [ ] **Emit validity is only partly gated.** `full_core` reports
  `integrity: joint reparse failed` on `core/alu__svt.sv` (the non-LRM chained select,
  see the previous entry) and `full_corev_apu` reports a missing `src/agilex7.svh`
  include with `edited integrity ok (files=71 hard=0 context=2)`. Separately,
  `post_analyze_sv` re-analyses only the FIRST rewritten file with an EMPTY param map and
  `package_mode:false`, so it reports `paths=0` and a meaningless `closes=false` — a
  vacuous gate that should either analyse the emitted project properly or say
  "inconclusive". Not fixed here.

## 2026-09-10 — host-environment robustness + a real 4 GHz answer

Two tool defects fixed (package-first), then the tool run in anger.

- [x] **Stale venv was undetectable.** Every call site gated on `Path.is_file()`, which is
  true for a Windows venv shim whose base interpreter has been uninstalled. The venv here
  recorded `home = ...\Python39` and the host is now 3.14.3, so `doctor` exited 1 with the
  shim's own `No Python at '...'` and every other command silently selected a dead
  interpreter. Added `env_common.venv_python_works()` (runs the interpreter, not `stat`);
  `doctor` now reports **STALE** distinctly from **MISSING**, `install_venv` recreates a
  stale tree instead of reusing it, and the two interpreter-selection sites plus
  `svt.py py` route through the probe. `setup` then rebuilt cleanly on 3.14.3; 132 tests
  pass.
- [x] **A completed soak could die printing its own result.** `monorepo_soak.py` writes
  every file with `encoding="utf-8"` but never reconfigured stdout, so on a cp1252
  console the `->` arrows in the summary raised
  `UnicodeEncodeError: 'charmap' codec can't encode character '\u2192'` — *after* the
  correct+emit work had succeeded, turning a good run into `exit=1`. Added
  `env_common.force_utf8_stdio()` (`errors="replace"` as a backstop: a report should
  degrade to a question mark, never abort the run that produced it) and called it from
  the soak entry point.

### Auto-correct actually improves timing (measured)

| profile | target | primary FO4 | edits | closes | note |
|---|--:|---|--:|---|---|
| `sparse_g6lc` | 2000 MHz | 25.09 -> **20.0** | 4 | **yes** | worst after: `g6lc_bp_gshare` |
| `sparse_g6lc` | 4000 MHz | 25.09 -> **10.0** | 14 | **yes** | dens=91, latency-allowing |
| `sparse_issue_lsu` | 4000 MHz | 31.67 -> 26.0 | 18 | **no** | worst_all **78.0 -> 78.0** |

- [x] **The 4 GHz question has a measured answer, and §3.2 called it.** The g6lc
  frontend/OoO/SMT set re-pipelines to the 10 FO4 budget and closes at 4 GHz. The
  issue/LSU cluster does not: `worst_all` is unmoved by 18 edits (78.0 -> 78.0) and
  `post_closure` reports `closes=false worst=store_buffer.in0 -> store_buffer.out0
  slack=-16.0 **max_mhz=1538.5**`. That is squarely inside the "~1.4-1.7 GHz residual
  after latency-neutral rewrites" this guider already predicts, and it is the same
  conclusion by a different route: LSU/issue needs microarch or multi-cycle, not FO4
  credit. Host `timings validate --from-timing` ranks the cluster 26-32 FO4 —
  `store_unit`/`scoreboard`/`issue_read_operands` as `dense_control_cone`,
  `load_unit` as `exclusive_case_mux`, `store_buffer` as `independent_lhs_bundle`.
- [ ] **`sparse_ex` is blocked by non-LRM RTL, not by this package.** `core/alu.sv:276`
  chains a select onto the result of a range select
  (`operand_b[i << 3 +: 8][$clog2(CVA6Cfg.XLEN)-4:0]`), introduced by `d05660170` when the
  xperm8 line was rewritten for Verilator widths. sv-parser rejects it; **slang agrees**
  (`cannot chain select expressions after a range select`, error) while the
  named-temporary form compiles clean. So the vendored parser is correct and the RTL is
  relying on a Verilator extension — a portability risk for tier-R RTL under the host's
  own synthesizability rule. Fix belongs to the host with the SoC checklist, not here;
  the stored `full_core` package parsed this file at `byte_len=16147` before the change,
  so it is a regression.
- [ ] No real STA is reachable on this host: `timings doctor` reports
  `yosys: no  opensta: no  openroad: no` and `liberty (unset)`, so S1/S2 soft-skip and
  everything above stays structural screening. The only correlate on record is the
  `lab-run` fixture (`overlap_score=1`, 2/2), explicitly `not real STA`.

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

