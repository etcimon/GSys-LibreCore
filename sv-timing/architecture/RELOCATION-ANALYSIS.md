# Relocation analysis — FO4 bottleneck strategy

| Field | Value |
|---|---|
| **Status** | Architecture + package implementation (`path_class` + `relocation` plan) |
| **Goal** | Map failing FO4 paths to **relocation options** that mirror logical patterns, not blind mid-cuts |
| **Scope** | Package IR / JSON suggestions only — **never** auto-merge into host `core/**` |
| **Related** | [`OPTIMIZATION-LEVELS.md`](OPTIMIZATION-LEVELS.md) (L0–L5), [`FO4-ALGORITHM-UPGRADES.md`](FO4-ALGORITHM-UPGRADES.md), [`AUTO-CORRECT-CORE-API.md`](AUTO-CORRECT-CORE-API.md), [`FREQUENCY-CLOSURE.md`](FREQUENCY-CLOSURE.md), monorepo §0 SoC |

---

## 1. Problem

Structural FO4 screening ranks paths and drives auto-correct. After path classification
(exclusive-case, independent-LHS, atomic), remaining **primary** failures are often
**real cones** (hot exclusive arm, atomic mul). InsertReg mid-cuts on original line
numbers do not “relocate” logic—they add latency around the wrong structure.

**Relocation** means moving work in **space** (which cone/unit) and **time** (which cycle)
while preserving the architectural contract.

---

## 2. Architecture under `sv-timing`

```text
                    ┌──────────────────────────────┐
                    │ analyze / lower / measure     │
                    │ attribute_costs → classify    │
                    └──────────────┬───────────────┘
                                   ▼
                    ┌──────────────────────────────┐
                    │ path_class (pattern layer)    │
                    │ exclusive | atomic | bundle   │
                    │ plain | under_budget | MC     │
                    └──────────────┬───────────────┘
                                   ▼
                    ┌──────────────────────────────┐
                    │ relocation plan (this doc)    │
                    │ cards per failing path        │
                    │ options ranked by leverage    │
                    └──────────────┬───────────────┘
                                   ▼
              ┌────────────────────┼────────────────────┐
              ▼                    ▼                    ▼
     suggest_opportunities   correct passes      host / human
     BalanceMux/Split/…      (gated transforms)  microarch (CVA6Cfg)
```

| Layer | Crate / artifact | Role |
|-------|------------------|------|
| IR + FO4 | `sv-timing-core` measure | Node/path costs |
| Pattern | `path_class` | Post-emptive exceptions; cache signatures |
| **Relocation** | `relocation` | Options catalog + scored plan JSON |
| Transforms | `sv-timing-transform` | Apply only package-safe options |
| Emit | `sv-timing-emit` | Review-only SV; integrity reparse |
| Cache | `sv-timing-cache` | design + path_class (+ plan lives in analyze JSON) |
| Host | monorepo build-platform | Optional `--from-timing`; never in crates |

---

## 3. Logical patterns → relocation families

| Pattern ID | Logical meaning | Typical residual | Relocation family |
|------------|-----------------|------------------|-------------------|
| **P1 ExclusiveSelect** | One-hot / unique case | max(arm,prep)+mux | Measure deflate (prep max'd, not residual sum); sticky BalanceMux; **stage_hot_arm** then residual **onehot_or_tree** + exclusive LHS wire; early opcode enables |
| **P2 AtomicOp** | Indivisible mul/div | base mul/div > budget | Soft multi_cycle; multi-cycle EX; prep-only stage; CVXIF |
| **P3 IndependentBundle** | Multi-LHS always_comb | sum of fields | Parallel max; split comb process; field schedule |
| **P4 AssociativeChain** | Left-deep trees | O(n) depth | rebalance_associative; width-aware reassoc |
| **P5 RetimableCone** | Flops + cloud | uneven segments | Register push/pull (future GateInfo) |
| **P6 ArchMultiCycle** | ISA-visible multi-cycle | intentional | Config latency table; scoreboard; PMU |

---

## 4. Relocation option tiers (implementation policy)

| Tier | Name | Latency Δ | Auto-correct? | Example algorithms |
|------|------|-----------|---------------|--------------------|
| **T0** | Measure relocate | 0 | Always (classify) | exclusive max, independent bundle, soft multi_cycle |
| **T1** | Latency-neutral | 0 | Yes if gain | rebalance, BalanceMux, SplitAssign, CSE |
| **T2** | Temporal pipeline | +k cycles | Only `--allow-latency` + Plain | InsertReg multi-cut |
| **T3** | Architectural | contract change | **Suggest only** | multi-cycle mul, stage split, CVXIF |

Rules:

1. Never auto-apply **T3** to host RTL.  
2. Prefer **T0 → T1 → T2**; refuse T2 on exclusive/atomic/bundle classes.  
3. Cache T0 results by path signature + detector version.  
4. Emit remains review-only (KD0 + monorepo philosophy §2.8).  
5. **Full-core / large bottlenecks:** correct worklist is driven by relocation **cards**. Soft multi-cycle atomics stay out of InsertReg thrash but still receive **T1 PrepStage** when preferred. Exclusive/bundle keep **BalanceMux** before InsertReg.  
6. **Scale with codebase size:** `scale_correct_budget` → [`CorrectScale`] grows worklist ≈ base+2√(failing)+f(modules,paths), passes ≈ base+3·log₂(failing), **idle_limit** ≈ 8+2·log₂(failing), **batch_size** ≈ 1+0.75√modules (clamped width≤256, passes≤192, idle≤64, batch≤16). Large plans **stratify cards by pattern then module** (round-robin exclusive / bundle / plain / atomic, and within each pattern round-robin modules) so one hot FPU tree cannot bury residual exclusive cones on other modules. Correct loop **batch-applies** distinct-module work items before each remeasure. Soft-atomic prep slots scale as √n_atomic.  
7. **Emit integrity vs FO4 close:** joint reparse uses **source order** (not alphabetical). When joint fails, integrity falls back to **edited-only** syntax checks; pure `DefineNotFound`/include gaps set `context_soft` without failing `reparse_ok`. Host macros (`FFLARNC`, etc.) no longer hard-fail emit when edited SV is clean. `--allow-parse-errors` still softens remaining hard syntax fails. FO4 close remains dry-run primary metric; emit is review-only.

---

## 5. Relocation card schema (JSON)

Emitted under analyze / correct as `relocation_plan`:

```json
{
  "schema_version": "relocation-plan-v0",
  "target_mhz": 1250,
  "budget_fo4": 32,
  "disclaimer": "structural FO4 screening — not STA; suggestions only",
  "summary": {
    "failing_primary": 2,
    "cards": 2,
    "by_pattern": { "exclusive_select": 2 }
  },
  "cards": [
    {
      "path_id": 67,
      "module": "multiplier",
      "startpoint": "multiplier.in0",
      "endpoint": "multiplier.out0",
      "path_class": "exclusive_case_mux",
      "pattern": "exclusive_select",
      "total_fo4": 73.5,
      "total_fo4_raw": 84.0,
      "slack_fo4": -41.5,
      "primary_loc": { "file": "...", "start_line": 128 },
      "function_hint": "exclusive result mux / hot arm",
      "options": [
        {
          "id": "t0_measure",
          "tier": "T0",
          "kind": "measure_relocate",
          "title": "Keep exclusive max-arm costing",
          "expected_fo4_after": 73.5,
          "latency_delta": 0,
          "auto_correct": true,
          "confidence": 0.9,
          "risk": "low",
          "algorithms": ["path_class.exclusive_case_mux"],
          "rationale": "..."
        },
        {
          "id": "t1_balance_mux",
          "tier": "T1",
          "kind": "balance_mux",
          "title": "Balance exclusive select / rebalance hot arm",
          "expected_fo4_after": 60.0,
          "latency_delta": 0,
          "auto_correct": true,
          "confidence": 0.65,
          "risk": "medium",
          "algorithms": ["balance_mux_on_path", "rebalance_associative"],
          "rationale": "..."
        },
        {
          "id": "t3_multicycle_hot_arm",
          "tier": "T3",
          "kind": "arch_multicycle",
          "title": "Config multi-cycle for hot opcode class",
          "expected_fo4_after": 32.0,
          "latency_delta": 1,
          "auto_correct": false,
          "confidence": 0.5,
          "risk": "high",
          "algorithms": ["CVA6Cfg latency table", "scoreboard multi-cycle"],
          "rationale": "..."
        }
      ]
    }
  ]
}
```

Scoring (package-internal, screening only):

```text
leverage = clamp((fo4_before - expected_after) / max(fo4_before, 1), 0, 1)
score    = leverage * confidence / (1 + risk_weight + latency_penalty)
```

Options sorted by `score` descending within each card.

---

## 6. Algorithm mapping (relocate → transform)

| Option kind | Pattern | Package API | Notes |
|-------------|---------|-------------|--------|
| `measure_relocate` | P1–P3 | `classify_and_adjust_paths` | Already applied before plan |
| `balance_mux` | P1 | `balance_mux_on_path` | T1 |
| `rebalance_assoc` | P4 | `rebalance_associative_node` | T1 |
| `split_assign` | P4/P1 arm | `split_assign` | T1 |
| `insert_reg` | P5 plain only | `schedule_pipeline_cuts` + `insert_register` | T2; refuse exclusive/atomic |
| `prep_stage` | P2 | expr spine expand | T1/T2 boundary |
| `soft_multicycle` | P2 | atomic → multi_cycle flag | T0 screening |
| `arch_multicycle` | P2/P6 | suggestion only | T3 |
| `split_comb_process` | P3 | suggestion only | T3 RTL style |
| `cvxif_offload` | P2 | suggestion only | T3 |

---

## 7. Pass integration

### Analyze
1. Lower + `attribute_costs` + classify  
2. `suggest_opportunities`  
3. **`build_relocation_plan(design)`** → `relocation_plan` in JSON  

### Correct
1. Each measure builds `relocation_plan`  
2. Worklist **prioritizes plan cards** (worst first) and selects opportunity from
   first **actionable** auto option (`preferred_actionable_kind` → BalanceMux /
   SplitAssign / InsertReg); T0 measure-only options are skipped  
3. Residual plan re-emitted on correct JSON  
4. No T3 auto-apply  

### Cache
- T0 path_class signatures already cached  
- Relocation plan is **derived** (not separately versioned); rebuild on analyze  

---

## 8. Exploration playbook (agents)

1. Run analyze with path_class + relocation_plan.  
2. For each card: pick highest-score **auto_correct=true** option first.  
3. If only T3 remains: document latency/config impact; do not invent InsertRegs.  
4. Host STA (`sta-handoff --use-emit`) calibrates FO4 model—never sole authority offline.  
5. Promote RTL only under monorepo SoC §0.2 + licensing when T3 is accepted by humans.

---

## 9. Non-goals

- Automatic edit of host monorepo RTL  
- Claiming STA closure from structural FO4  
- Retiming without GateInfo  
- Retuning `fo4-v1` from synthetic fixtures  

---

## 10. Evolution

| Slice | Status |
|-------|--------|
| Width-aware reassoc | **done** |
| BalanceMux hot-arm + residual one-hot emit + exclusive LHS wire | **done** (review-only; reparse-gated) |
| CaseItem labels in lower IR | **done** (prefer over source scan) |
| Relocation plan → correct worklist | **done** (actionable card options) |
| Host “relocation report” UI | open (build-platform timings dashboard) |
| S1 Yosys on emit packages | open (host tooling) |
| T3 multi-cycle / microarch for ~20 FO4 @ 2 GHz | open (human RTL / config; not auto-merge) |

---

*Last updated: 2026-08-03 — P1 exclusive BalanceMux emit stack validated on sparse_ex.*

