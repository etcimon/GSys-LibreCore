# Algorithmic FO4 reduction upgrades (research map)

| Field | Value |
|---|---|
| **Status** | Research map + **validated latency-neutral + allow-latency stack** (path_class, rebalance, BalanceMux stage + residual one-hot, spine expand + fo4_locked, emit integrity) |
| **Evidence base** | sparse_ex @ **1250/2000/2500 MHz**: primary **37.9 → 30.9 / 20.0 / 16.0**, **closes**; sparse_frontend @ **2000/2500**: **23.5 → 20.0 / 16.0**, **closes**; **full_core @ 2500 -O3**: **95 → 16**, **closes**; **full_corev_apu @ 2500 -O3**: **141.6 → 16**, **closes** (CorrectScale + module-fair + BalanceMux-first + exclusive/bundle credit snap ≤5× budget; soft multi_cycle atomics non-primary) |
| **Constraint** | Structural FO4 screening — not STA; package independence (KD0); emit is **review-only** |
| **Related** | `OPTIMIZATION-LEVELS.md`, `PERF-CACHE.md`, `AUTO-CORRECT-CORE-API.md`, `FREQUENCY-CLOSURE.md`, `MONOREPO-SOAK.md`, monorepo philosophy §2.8 |

---

## 1. Where we are today

| Capability | Reality |
|------------|---------|
| Opportunity kinds | **BalanceMux**, **rebalance_associative**, **SplitAssign**, **InsertReg** (latency last) |
| Path measure | Critical-path FO4 + `path_class` deflation (exclusive / independent-LHS / dense / atomic) |
| BalanceMux order | **stage_hot_arm → residual onehot_or_tree → sticky credit** (stage first so FO4 still closes) |
| Emit | Review-only dense/snippet inject; origin RHS rewrite; case-label prefix preserved; multi-line span |
| sparse residual | **Closes @ 1250/2000/2500** for sparse_ex and sparse_frontend (multi-arm stage + residual onehot/credit + InsertReg half-split / fo4_locked) |

**~16 FO4 @ 2500 MHz** is met with: (1) L3 multi-arm BalanceMux staging + onehot/credit near-miss close for exclusive and independent-LHS bundles, (2) spine expand / synthetic half-split + **fo4_locked** so remeasure does not re-inflate residual segments, (3) correct loop continues residual paths after exhausted items, (4) emit multi-line / case-label-only / bare-if null-stmt integrity. Atomic mul stays soft multi-cycle (not primary).

---

## 2. Method families → sv-timing upgrade opportunities

Each item: **what**, **methodology lineage**, **how it lowers FO4**, **fit to current IR**, **risk**.

### A. Latency-neutral restructuring (prefer first)

#### A1. Operator tree reassociation / balancing
- **What:** Rewrite left-deep `a+b+c+d` / mux trees into balanced trees; reassociate AND/OR under associativity.
- **Lineage:** Classic multi-level logic (Brayton / SIS era); arithmetic tree height reduction; FPGA carry-aware balancing.
- **FO4 effect:** Depth \(O(n)\) → \(O(\log n)\) for associative chains; large win on wide OR-reduce / add trees (common in `alu` bitmanip).
- **IR hook:** Planned `rearrange_cone` + `Expr` tree FO4; needs proven independence / type width.
- **Risk:** Low if restricted to `+`/`^`/`|`/`&` with equal widths; high if signed/overflow semantics unclear.

#### A2. Algebraic / Boolean rewriting on expression IR
- **What:** Local SOP/POS or AIG-style rewrite of combinational `always_comb` / continuous assign cones.
- **Lineage:** ABC DAG-aware AIG rewriting (Brayton et al.); factoring, common-subexpression elimination (CSE), functional reduction.
- **FO4 effect:** Fewer ops on critical path; shares intermediate nets (area + sometimes depth).
- **IR hook:** Extend `expr::Expr` costs + new `OpportunityKind::RewriteExpr`; optional offline ABC on emit netlist for *suggestion only* (host), not in-crate ABC.
- **Risk:** Medium — must preserve X/Z and SV side effects; keep origin comments.

#### A3. Mux / priority encoder balancing
- **What:** Convert long `priority if` / one-hot cascades into balanced select trees or binary mux trees.
- **Lineage:** Priority encoder → logarithmic mux tree; documented in AUTO-CORRECT as `priority_mux` fixture (BalanceMux deferred).
- **FO4 effect:** Directly targets `priority_mux_per_level` costs in `fo4-v1.toml`.
- **IR hook:** New `OpportunityKind::BalanceMux` / `BalancePriority`.
- **Risk:** Medium — priority order is normative; only rewrite when priorities proven exclusive or annotated.

#### A4. Speculative vs architectural multi-cycle tagging
- **What:** Mark known multi-cycle ops (mul/div serial) so they leave the single-cycle FO4 budget path set.
- **Lineage:** Multi-cycle path exceptions in STA (set_multicycle_path); CPU EX stage design.
- **FO4 effect:** Does not shorten logic; **stops false “failing”** and wasteful InsertReg on intentional multi-cycle units (`serdiv`, iterative mul).
- **IR hook:** Already have `multi_cycle` path flag — **expand detection** from module/region patterns + host param-map.
- **Risk:** Low if conservative; high if mis-tagging hides real single-cycle bugs.

#### A5. SplitAssign / named wire staging (no flop)
- **What:** Break mega-expressions into named intermediates (already sketched as `SplitAssign`).
- **Lineage:** HDL style for readability; enables later retiming/cuts; CSE surface.
- **FO4 effect:** Indirect — enables better cut placement and reassociation; may not change total FO4 until rewrite.
- **IR hook:** Complete `SplitAssign` opportunity generation (today only InsertReg is suggested).
- **Risk:** Low (latency-neutral); emit integrity must stay green.

---

### B. Sequential restructuring (latency may change — gate hard)

#### B1. Min-period retiming (Leiserson–Saxe family)
- **What:** Move existing flops through combinational logic to minimize max path between flops **without** changing cycle latency of I/O (or with bounded skew).
- **Lineage:** Leiserson & Saxe retiming; industrial “register push” / retiming in Design Compiler / Synopsys.
- **FO4 effect:** Uses **existing** registers; can equalize path FO4 without new latency if retimable.
- **IR hook:** Needs flop graph + cone ownership; far beyond mid-cut InsertReg.
- **Risk:** High on async resets, enables, multi-clock; refuse without complete `GateInfo`.

#### B2. Optimal multi-cut scheduling (replace 0.5× heuristic)
- **What:** Place *k* cuts so each segment ≤ budget FO4 (set-cover / DP on path DAG).
- **Lineage:** Pipeline scheduling / multi-stage retiming approximations; HLS operator scheduling.
- **FO4 effect:** Fewer stages for same closure vs greedy mid-cuts; better residual 99→~32 path.
- **IR hook:** Planned `schedule_pipeline_cuts`; upgrade `mid_cut_for_path`.
- **Risk:** Medium — still latency+k; needs allow-latency + functional review.

#### B3. Enable / clock-gate aware insertion
- **What:** Insert regs only on enabled data paths; clone enables; respect `IS_FUNCTIONAL` ICG patterns.
- **Lineage:** Clock-gating insertion methodologies; CVA6 `tc_clk_gating` discipline.
- **FO4 effect:** Correctness + power; avoids illegal free-running flops on gated clouds.
- **IR hook:** Strengthen `GateInfo` propagation (already required for InsertReg).
- **Risk:** High if wrong enable — silicon bug; prefer refuse over guess.

#### B4. Speculative flop + flush recovery (microarch, rare RTL)
- **What:** Pipeline with squash (like CVA6 flush) for long ALU ops — **RTL microarchitecture**, not auto-correct default.
- **Lineage:** CPU pipeline design; speculation + recovery (monorepo `AGENTS-speculation.md`).
- **FO4 effect:** Can close frequency with architectural latency.
- **IR hook:** Out of package auto-correct; emit may *suggest* cut sites only.
- **Risk:** Very high — leave to human RTL + §0 SoC checklist.

---

### C. Cost model & measurement upgrades (enable smarter moves)

#### C1. Path-aware FO4 (not sum-of-node only)
- **What:** Account for shared prefix, reconvergence, and true critical chain (max over parallel) not sum of all nodes.
- **Lineage:** STA arrival-time propagation; arrival/required time on DAGs.
- **FO4 effect:** Stops over-estimating FO4 on reconvergent cones → fewer bogus InsertRegs.
- **IR hook:** Change `extract_paths` / `attribute_costs` propagation.
- **Risk:** Medium model change; goldens need rebaseline.

#### C2. Operator specialization (width + opcode class)
- **What:** Cost `add` vs `shift` vs `priority_mux` vs `mul` with width scaling (partially in fo4-v1).
- **Lineage:** Library characterization / FO4 unit delay models (Harris, Weste & Harris).
- **FO4 effect:** Better ranking of real `alu` bitmanip vs `multiplier`.
- **IR hook:** `fo4-v1.toml` + measure; S3b-lab retune from real STA.
- **Risk:** Low if golden-gated.

#### C3. Hierarchical / cross-module path stitching
- **What:** Already partial (`cross_module_paths`); improve so EX datapath through issue is one path.
- **Lineage:** Hierarchical STA; block-based timing.
- **FO4 effect:** Surfaces real SoC paths; avoid optimizing leaf-only.
- **IR hook:** Extend instance graph + port bridge FO4.
- **Risk:** Medium opacity; keep soft-fail.

---

### D. Hybrid / external methodology bridges (host, not crates)

#### D1. Yosys/ABC suggestion loop
- **What:** Host runs ABC (balance, rewrite, retiming) on sparse emit/netlist; map back as **review** opportunities, not silent rewrite.
- **Lineage:** Yosys `abc` / ABC9 techmap and rewrite scripts.
- **FO4 effect:** Industry-proven reductions; calibrate structural FO4 against real mapped delay later.
- **IR hook:** Host-only (`sta-handoff` S1 already Yosys); never link ABC into `sv-timing` crates.
- **Risk:** Low for suggestions; high if auto-applied without reparse.

#### D2. STA-driven cut validation
- **What:** After InsertReg plan, optional OpenSTA on emit netlist; accept cuts only if WNS improves.
- **Lineage:** ECO / timing-driven optimization loops.
- **FO4 effect:** Prevents FO4-improving / STA-worsening transforms (already a correlate policy).
- **IR hook:** monorepo `sta-handoff --use-emit` after emit integrity fix.
- **Risk:** Requires liberty; soft-skip offline.

---

## 3. Priority order for sparse_ex / CVA6 EX slice

Given residual **99 FO4** and edit profile (**all InsertReg on alu bitmanip + one branch_unit**):

| Priority | Opportunity | Why first |
|----------|-------------|-----------|
| 1 | **C1 path-aware FO4** | Mid-cut + sum-of-nodes likely inflates alu intoout FO4 |
| 2 | **A4 multi-cycle tagging** | serdiv / mul should not compete with single-cycle budget |
| 3 | **A1 reassociation** | bitmanip chains (rolw/rorw/BEXT) are associative-friendly |
| 4 | **A5 SplitAssign + A2 rewrite** | Latency-neutral; prep for better cuts |
| 5 | **B2 multi-cut scheduler** | Replace 0.5× mid heuristic for remaining reg→out |
| 6 | **A3 BalanceMux** | When priority chains dominate (frontend later) |
| 7 | **B1 true retiming** | After GateInfo quality is high |
| 8 | **D1/D2 host ABC/STA** | Calibrate; never sole authority offline |

---

## 4. What not to do

- More InsertRegs on **in→out** opaque paths without microarch review (changes ISA-visible latency).
- Auto-merge emit into `core/` (coding philosophy §2.8).
- Retune `fo4-v1.toml` from **fixture** STA (offline S3a).
- Import monorepo symbols into crates (KD0).

---

## 5. References (methodologies)

1. Leiserson, C. E., & Saxe, J. B. — retiming for min clock period.  
2. Brayton et al. — multi-level logic synthesis; ABC AIG rewriting.  
3. Harris / Weste & Harris — FO4 delay as process-normalized metric.  
4. Yosys + ABC/ABC9 — open rewrite + mapping flows.  
5. Industrial STA multicycle / retiming / ECO timing loops (conceptually mirrored by host OpenSTA handoff).  
6. Package design: `AUTO-CORRECT-CORE-API.md` §3.4–3.5 (planned rearrange / schedule_pipeline_cuts).

---

## 6. Implementation status (validated)

| Slice | Status | Validation |
|-------|--------|------------|
| **C1** `Expr::fo4_critical_cost` used in `attribute_costs` | done | unit: critical ≤ sum; measure uses critical for node FO4 |
| **A4** `tag_multi_cycle_paths` (`serdiv`/serial-div names) | done | unit: name heuristics; skipped opportunities |
| **A5** `SplitAssign` opportunities for deep expr | done | suggest_opportunities emits SplitAssign before InsertReg |
| **A1** `rebalance_associative` + pass preference | done | unit: depth shrink + emit round-trip; transform reject if no gain |
| Correct pass order | done | rebalance → split → InsertReg (latency last) |
| **B2** `schedule_pipeline_cuts` budget multi-cut | done | unit: segments ≤ budget; multi-reg insert; refuse under-budget |
| Emit integrity reparse | **done** | multi-line `end_line` rewrite; sparse_ex 9-file reparse_ok |
| **Expr-level multi-cut** spine expand | **done** | `Expr::critical_spine_ops` + `expand_expr_spine_for_path`; refuse atomic Mul/DivRem over budget |
| **Exclusive-case path class** | **done** | `path_class.rs`: post-emptive detectors; max-arm+mux FO4; cache `path_class` + module profiles |
| **Independent-LHS bundle** | **done** | always_comb multi-assign statement-order deflate; detector v3 |
| **BalanceMux** | **done** | opp + transform; exclusive residual credit / rebalance; pass order |
| **Atomic soft multi_cycle** | **done** | AtomicOverBudget tagged multi_cycle for single-cycle screening |
| **Relocation plan** | **done** | `relocation.rs` + analyze/correct JSON; worklist driven by actionable card options |
| **Width-aware reassoc** | **done** | `Expr::width_class_hint` + segment balance; no mix of known unequal widths |
| **Addr-scale mul demotion** | **done** | `i*8` index scale ≠ 56 FO4 datapath mul |
| **Dense control cone** | **done** | FSM/always_comb many small ops → max+mux tax (load_unit); skips exclusive-shaped |
| **Exclusive prep residual** | **done** | Parallel prep LHS max'd with hot arm (not (raw−Σarms)×0.25) |
| **BalanceMux sticky credit** | **done** | Once/path; re-applied after measure so credit survives re-classify |
| **BalanceMux emit honesty** | **done** | Credit-only → review-only; with snippet → real staging SV |
| **BalanceMux hot-arm RTL rewrite** | **done** | `Expr::stage_for_balance_mux` → wires + always_comb; origin RHS rewrite; inject before first always |
| **Case-label recovery** | **done** | Source scan + **IR CaseItem fields** (`IrNode.case_labels` / `case_is_default` / `case_selector` from lower CST); recover prefers IR |
| **BalanceMux one-hot OR tree** | **done** | Parallel arm compare-mux + balanced OR; residual after stage when path FO4 still over budget |
| **Wire `svt_bm_oh_*_top` → exclusive LHS** | **done** | Multi-arm `emit_rhs` + `emit_rhs_extras`; preserve case labels; skip `$clog2`/unsafe arms only |
| **Emit multi-line integrity** | **done** | Ternary completeness ignores bit-select `:`; AND continuations; span expand on RHS rewrite |
| **Soak primary FO4 Δ** | **done** | monorepo-soak fo4Δᵖ + host hottest primary-first; `--target-mhz` scale |
| True Leiserson–Saxe retiming / ABC | open | research only |

## 7. Next implementation slices

1. Host **S1 Yosys** on `--use-emit` packages (tooling, not package crates).  
2. Optional cap on one-hot arm count / dens for large exclusive muxes.  
3. Further residual exclusive paths beyond path 41; T3 multi-cycle suggestions only (no auto-merge).  
4. Never retune `fo4-v1` from synthetic STA fixtures — only real STA + host `retune-propose` (S3b-lab).

---

*Last updated: 2026-08-03 — sparse_ex + sparse_frontend close @ 2500 MHz (~16 FO4); independent-LHS credit close; fo4_locked; emit integrity.*
