# Auto-correct runtime stability plan

| Field | Value |
|---|---|
| **Status** | Active plan + implementation |
| **Goal** | Make package emit **Verilator-legal** and **host-consumable** without weakening FO4 screening honesty |
| **Drivers** | SPO `--from-timing` soaks (2026-08-03); direct Verilator on `corrected/` |
| **Related** | [`SPO analysis`](../../build-platform/workspace/build/sv-timing/monorepo-soak/SPO-FROM-TIMING-ANALYSIS.md), [`FO4-ALGORITHM-UPGRADES.md`](FO4-ALGORITHM-UPGRADES.md), [`RELOCATION-ANALYSIS.md`](RELOCATION-ANALYSIS.md) |

---

## 1. Principles (rank order)

1. **Emit must parse** under the same front-end as integrity (and preferably Verilator lint-only) before claiming `--use-emit` readiness.  
2. **Prefer real structural rewrites** (BalanceMux stage/onehot, complete multi-line cuts) over sticky FO4 credit.  
3. **No decorative SV** that changes connectivity or introduces illegal constructs just for density score.  
4. **One file’s edits densify only that file** (no basename suffix false positives).  
5. **Host must not false-green** `--use-emit` when lint still uses live RTL.

FO4 close @ 2.5 GHz remains a **screening** metric; runtime stability is a **separate** gate.

---

## 2. Workstream map

| ID | Workstream | Owner | Status |
|----|------------|-------|--------|
| **R1** | Dense emit: `generate` wrap for genvar | package | **done** |
| **R2** | Dense emit: reject free loop-index cut feeds | package | **done** |
| **R3** | Incomplete multi-line RHS (empty ternary arm, trailing op) | package | **done** |
| **R4** | Case-label span safety (don’t swallow next case) | package | **done** |
| **R5** | Lean dense: optional density scaffold off by default | package | **done** |
| **R6** | `edits_for_source`: exact basename (fix `copro_alu`⊃`alu`) | package | **done** |
| **R7** | Reduce FO4 sticky snap when no structural rewrite | package | **done** (2.5× cap) |
| **R8** | Host: `--use-emit` flist overlay in `writeFlatManifest` | host | **done** (basename `__svt` remap) |
| **R8b** | Atomic preferred over dense deflation (`te_reg` soft multi_cycle) | package | **done** (detector v8) |
| **R11** | Dual inject: BalanceMux early, InsertReg dense before `endmodule`; unique BalanceMux begin labels | package | **done** |
| **R12** | Generate-scope safety + dual inject (R11) | package | **done** |
| **R12e** | Lean emit default: zero feeds, no origin rewrite, no BalanceMux RTL (FO4 sidecar only) | package | **done** — `mc-spo-soak --use-emit` full_core **PASS** |
| **R9** | Residual hard emit files (e.g. `rv_plic_target`) | package | next |
| **R10** | Live config `RVZacas` / adapter range-select | monorepo RTL | out of band |

---

## 3. R5 — Lean dense emit

**Problem:** InsertReg densify injects always_comb “theater”, empty genvar loops, hold aliases, and dummy ternaries that confuse Verilator and reviewers.

**Policy:**

| Mode | When | Content |
|------|------|---------|
| **Credit-only** | No InsertReg/Split | Comments or real BalanceMux snippets only (already) |
| **Lean pipe** (default) | InsertReg present | Decls + feeds + real always_ff/comb stage + sinks; **no** decorative genvar, nested density always_comb, hold aliases, unused mux nets |
| **Scaffold** | `DenseEmitOptions.density_scaffold = true` | Full historical density for regress score tests |

Density tests set `density_scaffold: true` or keep checking lean block still scores enough via real always_ff.

---

## 4. R6 — Exact file match

**Bug:** `of.ends_with("alu.sv")` matches `…/copro_alu.sv`.

**Fix:** Basename match = exact `file_name()` equality only; full path uses normalize equality / suffix of full path components, not bare basename ends_with.

---

## 5. R7 — Sticky FO4 vs structural rewrite

**Problem:** 5× budget credit snap closes FO4 without emit-safe structure.

**Policy for this pass:**

- Keep near-miss / modest proportional credit for exclusive residual.  
- Cap empty credit snap at **2.5× budget** (was 5×) so only near-band residuals close without stage/onehot.  
- Paths that still need larger dissolve stay multi-cycle soft or T3 suggest.

Trade-off: full_corev_apu `te_reg` may reopen until stage/onehot or InsertReg lands — prefer re-open FO4 over illegal emit.

---

## 6. R8 — Host `--use-emit`

**Today:** env `CVA6_TIMINGS_EMIT_FLIST` set; lint ignores it.

**This pass:**

- Document clearly in `architecture/MONOREPO-SOAK.md` + SPO analysis.  
- Add host helper note in timings validate when emit present: “lint still live unless consumer remaps”.  
- Optional: when `useEmit`, log absolute emit flist + file count (already); add `warn` if sim/lint stages ignore it.

Full flist remapping is deferred (large; needs basename→corrected path map).

---

## 6b. R11 — Dual inject placement (use-before-declare)

**Problem:** Injecting the whole auto-correct block before the first process made cut feeds
(`assign pipe_c = (rounded_abs …)`) appear **before** mid-module net decls → slang/Verilator
`identifier used before its declaration` (e.g. `fpnew_cast_multi`). Multi-arm BalanceMux also
reused `begin : svt_balance_mux_stage` → `Duplicate declaration of block`.

**Fix:**

| Block | Placement | Why |
|-------|-----------|-----|
| BalanceMux `emit_snippet` / credit review | **Early** (before first always/assign) | Origin RHS rewrite references staged wires |
| InsertReg dense (decls, feeds, always_ff, sinks) | **Late** (before `endmodule`) | Feeds may use mid-module nets; sinks stay after pipe decls |
| Named always_comb for arm staging | Unique label from top wire (`{top}_stage`) | No multi-arm block collision |

API: `emit_blocks_for_trace` → `EmitBlocks { early, late }`; `apply_edits_to_source_dense` dual-injects.

---

## 6c. R12 / R12e — Generate-scope safety + lean emit

**Problem:** Dual inject (R11) fixed mid-module `logic` use-before-declare, but
Verilator still failed on generate-localparams, free genvars, automatic locals,
multi-driver continuous sinks, and BalanceMux early inject of mid-module nets.

**R12 guards** (still applied when opt-in real feeds are enabled):

| Guard | Action |
|-------|--------|
| Origin line inside `generate`…`endgenerate` | No cut claim / demote BalanceMux snippet |
| Free gen index (`i`,`fmt`,`q`,…) | Zero feed; skip gen-indexed sink |
| Generate-local param (`EXP_BITS`,…) | Zero feed |
| BalanceMux rewrite without safe snippet | No origin RHS rewrite |
| Unified `balance_mux_snippet_safe` | Inject and rewrite stay in lockstep |

**R12e lean default** (monorepo / Verilator-safe):

| `DenseEmitOptions` | Default | Effect |
|--------------------|---------|--------|
| `real_cut_feeds` | **false** | Zero/chain feeds; **no** origin rewrite; **no** continuous sinks |
| `emit_balance_mux_rtl` | **false** | BalanceMux credit-only (no early snippet RTL) |

Pipe stages still emit as a FO4 screening **sidecar** (always_ff + zero feeds).
FO4 close @ 2.5 GHz is independent of feed fidelity.

### Opt-in richer real-feed emit

| Surface | Flag |
|---------|------|
| CLI | `sv-timing correct --emit --real-cut-feeds [--emit-balance-mux-rtl]` |
| monorepo soak | `monorepo_soak.py --correct --emit --real-cut-feeds [--emit-balance-mux-rtl]` |
| API | `ProjectEmitOptions { real_cut_feeds, emit_balance_mux_rtl }` → `DenseEmitOptions` |

R12 guards still apply when richer mode is on (generate-local refuse, free gen index,
safe BalanceMux gate). Prefer lean for Verilator overlay soaks; enable richer for
human review of cut fidelity.

**Evidence (2026-08-03):** `mc-spo-soak --from-timing full_core --use-emit` **PASS**
(assemble 3×9 + dual Verilator lint on overlayed `__svt` sources).

---

## 7. Acceptance

| Gate | Pass criteria |
|------|----------------|
| Unit | `cargo test -p sv-timing-emit` |
| Sparse | `sparse_ex` @2500 correct+emit integrity OK |
| Full | FO4 primary may slightly regress if snap tightened; emit integrity not worse |
| Verilator smoke | Corrected module with InsertReg: no bare genvar; no free `i`/`j` feeds |

---

## 8. Non-goals

- Auto-merge emit into `core/`.  
- STA sign-off.  
- Full cosim of SPO streams through emit flist (needs R8 remapping).
