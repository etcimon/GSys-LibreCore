# Pass strategy — recognizing patterns *before* spending passes

| | |
|---|---|
| **Status** | Measured analysis + proposed schedule. The recognizers and the schedule are **not implemented**; the measurements are real. |
| **Corpus** | `full_core` / `full_corev_apu`, strict (zero skipped files), 4000 MHz, `fo4_ps=20`, margin 0.2 → **budget 10.0 FO4**, `-O3`, `ir-v1` / `delay-v4`. Artifacts under `workspace/build/sv-timing/audit-strict-v4`. |
| **Related** | [`RELOCATION-ANALYSIS.md`](RELOCATION-ANALYSIS.md) (per-path option catalog), [`OPTIMIZATION-LEVELS.md`](OPTIMIZATION-LEVELS.md) (dials/presets), [`FREQUENCY-CLOSURE.md`](FREQUENCY-CLOSURE.md) (budget + current numbers), [`FO4-ALGORITHM-UPGRADES.md`](FO4-ALGORITHM-UPGRADES.md) |
| **Hard rule** | Structural FO4 is not STA. Nothing here is a frequency claim. |

---

## 1. Why plan ahead instead of iterating

The current corrector runs a generic worklist for `max_passes` and re-measures. The trace
logs show that is mostly idle motion, and that the motion it does make is not verified:

| Observation | `full_core` | `full_corev_apu` |
|---|---|---|
| `measure` events | 14 | 11 |
| Passes that changed `primary_fo4` | **1** (70.0 → 54.0) | **6** (304.5 → 96.5) |
| Passes flat afterwards | 13 | 4 |
| `worst_all_fo4` over the whole run | **176.0 → 176.0** | 304.5 → 131.0 |
| applies / refuses | 192 / **1** | 122 / **1** |
| Emitted `primary_fo4` delta | **0.0** | **0.0** |

Three separate problems are visible in that table alone:

1. **No fixpoint detection.** `full_core` reaches its best value in pass 1 and then burns
   13 more passes. A `Δ < min_gain` stop after 2 flat passes would end the run at pass 3.
2. **Almost nothing is refused** (1 of ~193). The worklist is not selecting; it is
   accepting whatever it is handed, which is why the pass count is the only limit.
3. **The IR gain is not real.** Both profiles report an emitted delta of 0.0 while the IR
   books 70.0→54.0 and 304.5→96.5. Proven on the APU's worst path: in
   `g6lc_ai_gemm_seq__svt.sv` the limiting statement
   `assign c_span = (32'(m_q[8:0]) * 32'(n_q[8:0])) << 2;` is **byte-identical** to the
   original, and the emitted file's +225 lines are 376 comment lines / 40 `sv-timing`
   markers with `always_ff` going 5 → 6. The IR credited a 3.2x cut that the output
   does not contain.

A planner cannot fix (3), but it can stop spending passes on work whose target is an
artifact — which, measured below, is **about half the hard FO4 mass**.

---

## 2. Reference distributions (what the corpus actually looks like)

### 2.1 Failing paths by class

| Class | core n | core Σ FO4 | APU n | APU Σ FO4 |
|---|---:|---:|---:|---:|
| `plain` | 289 | 4471.0 | 63 | 1750.0 |
| `multi_cycle_tagged` | 157 | 2570.2 | 1 | 12.0 |
| `independent_lhs_bundle` | 67 | 1133.2 | 32 | 527.4 |
| `exclusive_case_mux` | 46 | 836.2 | 28 | 518.2 |
| `atomic_over_budget` | 35 | 3158.5 | 10 | 783.0 |
| `dense_control_cone` | 27 | 464.5 | 10 | 244.8 |
| **total failing** | **621** / 5410 | | **144** / 4636 | |

### 2.2 Depth histogram — the mass is shallow

| `total_fo4` | core n | APU n | slices if perfectly divisible |
|---|---:|---:|---|
| [10, 20) | **469** | **87** | 2 |
| [20, 40) | 107 | 36 | 2–4 |
| [40, 80) | 30 | 14 | 4–8 |
| [80, 160) | 14 | 6 | 8–16 |
| [160, ∞) | 1 | 1 | 16+ |

**75% of core failures and 60% of APU failures are in [10,20)** — one register or one
rebalance each. The monsters are a rounding error by count and should not set the schedule.

### 2.3 Path kind

`intoout` **423** vs `regtoreg` 198 (core); `intoout` **118** vs `regtoreg` 26 (APU).
An `intoout` cone is a *fragment* of a real launch→capture path, not a path that must
independently fit the period. Treating fragments as independent failures both inflates the
failing count and misdirects cuts. See §4 P5.

---

## 3. Pattern catalog

Each pattern has a **signature computable from `analyze.json` + source, before any
transform runs**, so the plan can be chosen up front.

### P1 — Elaboration-constant arithmetic billed as hardware  *(artifact, tier A)*

**Signature:** `path_class == atomic_over_budget` and every operand adjacent to the
dominant operator is a literal, a SCREAMING_CASE parameter, a `*Cfg.*` struct field, a
genvar-ish loop variable, or a `$clog2`/`$bits` call.

**Measured share of the atomic mass:**

| | atomic paths | of which P1 | P1 Σ FO4 | share of atomic Σ |
|---|---:|---:|---:|---:|
| `full_core` | 35 | **17** | 1601.0 | **51%** |
| `full_corev_apu` | 10 | 2 | 196.0 | 25% |

**Instances** (all charged as real dividers/multipliers):

| FO4 | Site | Expression |
|---:|---|---|
| 176.0 | `fpnew_opgroup_block.sv:106` | `simd_mask_i[(NUM_LANES/INTERNAL_LANES)*b]` |
| 132.5 | `cva6_icache_axi_wrapper.sv:90` | `CVA6Cfg.ICACHE_LINE_WIDTH / 64 - 1` |
| 131.0 | `g6lc_ai_gemm_seq.sv:1695` | `{{(DataWidth/8-4){1'b0}}, 4'hF}` — replication count |
| 130.0 | `g6lc_ai_pe_dot.sv:144` | `cnt = (cnt + 1) / 2` |
| 121.0 | `cva6_icache_axi_wrapper.sv:91` | `$clog2(CVA6Cfg.AxiDataWidth / 8)` |
| 120.5 ×2 | `hpdcache_uncached.sv:692,913` | `{HPDcacheCfg.reqDataWidth/64{...}}` — replication count |
| 121.0 | `hpdcache_wbuf.sv:665` | `get_hpdcache_mem_size(HPDcacheCfg.wbufDataWidth/8)` |
| 66.0 ×4 | `fpnew_fma{,_multi}.sv:316,382,408,510` | `3 * PRECISION_BITS + 4` |
| 66.0 | `g6lc_server_prefetcher.sv:108` | `LINE_BYTES * PF_DISTANCE` |

**Action:** a constant lattice (`Const | Unknown | Runtime`) propagated over the
expression tree, seeded by literals, the param-map, localparams, genvars and
`$clog2`/`$bits` of constants; `Const ∘ Const → Const → zero delay`. Plus the LRM
contexts that are constant *by rule* regardless of operand resolution: replication counts,
packed dimensions, `+:`/`-:` widths, case-item labels. `delay-v4` already did exactly this
for fixed `[msb:lsb]` bounds and removed the 202.0 FO4 `cva6_ptw` path, 10 of 45 atomic
classifications and 188 false opportunities — P1 is the same fix generalized.

### P2 — Comment text billed as arithmetic  *(artifact, tier A)*

**Signature:** the dominant operator's column on `primary_loc` lies at or after a `//` or
`/*` on that line.

**Instances:** `te_priority.sv:139` **56.0 FO4** on `tc_privchange_i /*|| (...` (block
comment interior); `cva6_shared_tlb.sv:260` **136.0 FO4** on a statement whose line ends
in a trailing `//` continuation comment.

**Action:** finish comment lowering for block-comment interiors and trailing `//` on
continued statements. The `//`-prefix case is already handled; these two forms are not.

### P3 — Uncuttable-by-construction  *(model gap, tier B)*

**Signature:** `node_count <= 1` and `total_fo4 > budget`.

**Measured:** core **204** paths, Σ **4692.5 FO4**; APU **42**, Σ **837.5**.

A single-node path has no interior to cut, so *every* cut strategy is guaranteed to fail
on it — which is precisely what the flat `worst_all 176.0` line shows. After P1/P2 remove
the artifacts, the residue is real indivisible operators (a 24×24 mantissa multiply is one
`Mul` node at 56 FO4).

**Action:** model wide operators as structure (partial-product array → reduction tree →
final adder) so a cut can land *inside* one, which is what pipelining a multiplier
physically is. Until then, report them as T3 architectural asks and **never** let them
enter a cut worklist.

### P4 — Path labelled atomic because *one* node is atomic  *(ranking defect, tier B)*

**Signature:** `path_class == atomic_over_budget` and `node_count >> 1`.

**Measured:** `cache_ctrl` 125.0 FO4 **nodes=117**; `wt_axi_adapter` 121.5 **nodes=71**;
`fpnew_opgroup_multifmt_slice` 132.0 **nodes=5**; `g6lc_bp_ghist` 121.0 **nodes=2**.
(`hpdcache_memctrl` has *two* failing paths at 120.0 FO4, one `nodes=6` and one
`nodes=1` — a reminder that FO4 alone does not identify a path, so P3/P4 must be
separated by `node_count`, not by cost.)

Atomicity is a property of a **node**, not of a path. A 117-node path containing one
over-budget operator is mostly ordinary logic, but the path-level `atomic` verdict
discourages insertion across the whole path (`atomic_mul_flags_discourages_insert`), so the
other 116 nodes are never scheduled.

**Action:** split the verdict — `atomic_node_over_budget` (T3 ask for that node) plus a
normal cuttable remainder for the rest of the cone.

### P5 — `intoout` fragments counted as whole paths  *(model gap, tier B)*

**Signature:** `path_kind == intoout` with no flop at either end.

**Measured:** 423/621 core, 118/144 APU.

**Action:** compose fragments across the instance graph into flop-to-flop paths, or label
them explicitly as fragments excluded from `closes`. A fragment wider than the entire
budget is still a genuine finding; a fragment narrower than the budget says nothing.

### P6 — Shallow-over-budget bulk  *(real, tier C — the actual leverage)*

**Signature:** `closes == false`, `budget < total_fo4 < 2·budget`, `node_count > 1`.

**Measured:** **469** core, **87** APU — 75% / 60% of all failures.

**Action:** one latency-neutral rebalance, or one register. Highest slack recovered per
edit in the corpus, and the class the current run is *least* differentiated about.

### P7 — Already-parallel bundles ranked as serial  *(measurement, tier C-first)*

**Signature:** `independent_lhs_bundle` (67 core / 32 APU, Σ 1133.2 / 527.4 FO4).

These are independent assignments whose statement order was summed. Fixing the *measure*
costs no RTL and no latency. It should precede every structural pass, because it changes
which paths are failing at all.

### P8 — Genuine deep datapath  *(real, tier C-last)*

**Signature:** `atomic` after P1/P2 with runtime operands on both sides.

**Measured:** core 17 paths Σ 1421.5 FO4; APU 7 Σ 531.0. Examples:
`product = mantissa_a * mantissa_b` (56.0, `fpnew_fma{,_multi}`),
`(32'(m_q[8:0]) * 32'(n_q[8:0])) << 2` (56.0 ×2, `g6lc_ai_gemm_seq`),
`multiplier.sv:115` (68.5).

**Action:** the only class that legitimately needs an RTL change. Stage count from
`ceil(cost/budget)` **after** P3 gives a defensible internal structure — and it owes the
root `AGENTS.md` §0.2 checklist.

### P9 — Iterative / multi-cycle  *(real, tier C — do not cut)*

**Signature:** `multi_cycle_tagged` (157 core, Σ 2570.2 FO4 — `serdiv`, `fpnew_divsqrt_*`,
`ct_vfdsu_*`).

**Action:** assert multicycle with real SDC and a protocol check. Never insert registers.

---

## 4. The pre-pass planner

Recognizers run on `analyze.json` once, before any transform:

```text
plan(analyze, budget):
  A = paths matching P1 | P2                  # artifacts: cost is wrong
  if A non-empty:
      ABORT the correct run.
      Artifacts are a measurement bug, not a workload. Optimizing around them
      spends edits on logic that does not exist. Report and fix the model.

  B = paths matching P3 | P4 | P5             # model gaps: verdict is unusable
  route P3 -> T3 report          (never to a cut worklist)
  route P4 -> split node/remainder
  route P5 -> compose or label fragment

  C = remaining real failures, bucketed:
      C1 = P7  (measurement-only, latency-neutral)
      C2 = P6 shallow, latency-neutral rebalance candidates
      C3 = exclusive_case_mux | dense_control_cone   (BalanceMux, latency-neutral)
      C4 = P6 shallow needing one register           (adds state)
      C5 = P8 deep datapath                          (T3 ask, RTL change)
      C6 = P9 iterative                              (SDC, no edit)
  emit an ordered schedule over the non-empty buckets only
```

The **abort on artifacts** is the point of planning ahead. In this corpus the planner
would have refused both profiles and named 19 specific expressions, instead of applying
314 edits for a 0.0 emitted delta.

---

## 5. Ordered schedule

Ordering is chosen so that cheaper, reversible, latency-neutral work is exhausted before
anything that adds state or changes an interface, and so that each stage re-measures on a
board the previous stage actually changed.

| Stage | Bucket | Adds state? | Entry condition | Exit condition |
|---|---|---|---|---|
| **S0** | P1, P2 fixes | no (model) | always | zero artifact-signature paths |
| **S1** | P3, P4, P5 routing | no (model) | S0 clean | every failing path has a usable verdict |
| **S2** | C1 (P7 re-measure) | no | S1 clean | bundle costs stable |
| **S3** | C2 + C3 rebalance / BalanceMux | **no** | S2 fixpoint | no latency-neutral candidate left |
| **S4** | C4 register insertion | **yes** | S3 fixpoint **and** `--allow-latency` | budget met or no candidate |
| **S5** | C5 + C6 reports | no (asks) | always last | cards emitted |

Rationale for the two non-obvious edges:

- **S3 strictly before S4.** State-adding cuts change the scratchboard and invalidate
  cheaper latency-neutral opportunities that were legal a moment earlier. Doing them last
  preserves the flop-minimal solution — the same reasoning that made `-Os` beat `-O3` on
  `alu` with 2 inserted registers instead of 4 (`OPTIMIZATION-LEVELS.md` §3).
- **S2 before S3.** P7 changes *which* paths are failing, so running it first shrinks the
  candidate set the structural stages have to consider.

---

## 6. Pass scheduling policy

Derived from the trace behaviour in §1:

1. **Fixpoint stop.** End a stage after 2 consecutive passes with
   `Δprimary_fo4 < min_gain`. Measured effect: `full_core` stops at pass 3 rather than 19.
2. **Per-stage pass budget**, not one global `max_passes`. A stage that cannot move its own
   bucket must not consume the budget of later stages.
3. **Emitted-delta admission.** A pass is only credited if re-analysis of the **emitted**
   output improves. With that rule both profiles in this corpus would have reported "no
   progress" after pass 1 instead of an IR gain of 70.0→54.0 / 304.5→96.5. This depends on
   the IR/emit credit fix (§1 item 3) and is the single highest-value change here: the
   APU's worst path is `nodes=144`, `plain`, `regtoreg` — **genuinely cuttable**, and the
   IR already found a 3.2x plan that emit failed to produce.
4. **Refusal is information.** 1 refusal in ~193 applies means the ranking is not
   discriminating. Every refusal should carry a reason code and be counted per class, so a
   stage with a high refusal rate is visibly the wrong algorithm for that bucket.

---

## 7. What this does not do

- It does not make a frequency claim. Every number here is structural FO4 at an assumed
  20 ps, screening only.
- It does not establish that any path is *the* critical path: P5 is unresolved, so
  `intoout` fragments are not composed into real launch→capture paths.
- It does not prove equivalence. Emitted SV re-parses; that is not elaboration and not a
  functional check.
- Removing an artifact **lowers a reported FO4 without improving any hardware.** P1/P2
  work must be reported as a measurement correction, never as an optimization gain.
