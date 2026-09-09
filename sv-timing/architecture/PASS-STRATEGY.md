# Pass strategy — recognizing patterns *before* spending passes

| | |
|---|---|
| **Status** | Measured analysis + **implemented** recognizers / S0–S5 + **P10** handshake lock (`pass_strategy.rs`, `delay-v19`, path_class **v24**) + IR/emit credit gate + P5 compose + **resilient-datapath exception policy** (§8). InsertReg last. Residual InsertReg paths keep the original capture. `--real-cut-feeds` also emits BalanceMux RTL. |
| **Corpus** | `full_core` / `full_corev_apu`, 4000 MHz, `fo4_ps=20`, margin 0.2 → **budget 10.0 FO4**, `-O3`. **delay-v4 baseline:** `…/audit-strict-v4/`. **delay-v17:** gemm always_ff 144-node **161.5→26**. **path_class v21:** APU hub **36→11**. **remain-v23:** emit **22**. **delay-v18:** emit **18.5**. **path_class v23 / remain-v24:** emit **20**. **delay-v19:** only `(W)'(1)` is increment. **path_class v24:** 2-arm flop-D exclusive. |
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

(3) is now refused at apply time when emit is lean (`PassPolicy.emit_structural`,
§6 item 3): InsertReg / BalanceMux do not book IR FO4 the sidecar will not contain.
The planner still aborts on artifacts (P1/P2) rather than optimizing around them —
which, measured below, is **about half the hard FO4 mass**.

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
packed dimensions, `+:`/`-:` widths, case-item labels. `delay-v4` did `[msb:lsb]` bounds;
**`delay-v7` parses `+:` / `-:`** (width Const by rule, runtime base index still charged —
previously Opaque and billed as 0). **`delay-v8` skips BinaryOperator tokens inside
packed/unpacked dimensions and case-item labels** (elaboration-constant CST spans).
**`delay-v9`** is `Expr::PartSelect` (`[msb:lsb]` / `+:` / `-:`) instead of fake
`Binary ":"` / `"+:"`. **`delay-v10`** trusts a parsed RHS tree at 0 FO4 (no
string-heuristic Mul fallback on `v[HYP_EXT*2:0]`) and skips CST `ConstantRange`,
indexed-select width, and replication-count spans. The six residual `cva6_*` MMU
`atomic_over_budget` paths in `audit-strict-v4` (`delay-v4` logs) were this hole:
`:219` `HYP_EXT*2` slice, `:260`/`:740` `VpnLen%PtLevels` pad, plus P4 multi-node
remainders at `cva6_ptw.sv:580` / `cva6_tlb.sv:211` / `cva6_shared_tlb.sv:378`.
**`delay-v11`** seeds the lattice from the module's localparam / parameter /
param-map / imported-package names, so mixed-case params (`VpnLen`, `PtLevels`)
are Const, not only SCREAMING_CASE / `*Cfg.*`. Runtime nets stay Runtime.
**`delay-v12`** restores per-module CST scoping (`ModuleScope`) so that seed,
ports, regions and instances are not the union of every module in the file.
**`delay-v13`** treats a genvar as Const only inside its generate-loop span
(runtime `idx` in the same module stays Runtime) and skips CST operators in
generate-for/if/case headers.
**`delay-v14`** treats runtime `/` or `%` whose **divisor** is Const (`8`,
`WIDTH`, `HPDcacheCfg.u.dataWaysPerRamWord`) as a shift or bit-select, not a
120 FO4 SRT divider. `8 / a` (runtime divisor) stays `DivRem`. This is the
`hpdcache_memctrl` :472 / :980 leftover (`way % dataWaysPerRamWord`) and the
P1 instance `cnt = (cnt + 1) / 2`.

### P2 — Comment text billed as arithmetic  *(artifact, tier A)*

**Signature:** the dominant operator's column on `primary_loc` lies at or after a `//` or
`/*` on that line.

**Instances:** `te_priority.sv:139` **56.0 FO4** on `tc_privchange_i /*|| (...` (block
comment interior); `cva6_shared_tlb.sv:260` **136.0 FO4** on a statement whose line ends
in a trailing `//` continuation comment.

**Action:** skip **every** CST operator whose byte offset is inside `//` / `/*`, not
only `/` and `*`, and blank comment interiors out of recovered assign RHS before
Expr parse. **Implemented** (`operator_token_in_comment`, `blank_sv_comments`,
fixture `parse/comment_interiors.sv`). The `//`-prefix / banner case was already
handled. Planner `loc_looks_like_comment` stays loc-only (no file bytes on the path).

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
normal cuttable remainder for the rest of the cone. **Implemented:** `try_atomic_over_budget`
returns None when `nodes.len() > 1`; the path stays `plain` / cuttable and `class_note`
records `P4 remainder; atomic … is T3`. Single-node cones stay `AtomicOverBudget` (P3/P8).
**v19:** subtract the T3 node's FO4 from the remainder when it **owns** the cone
(`cost / adj ≥ 0.90`), when leftover ≥ the atomic, or when `nodes ≥ 8`.
Qualified remainders also peel **every** over-budget DivRem (twin
`way / Cfg` + `way % Cfg`), not only the hottest. `gemm_span` (56/68, leftover 12)
is kept.

### P5 — `intoout` fragments counted as whole paths  *(model gap, tier B — intra-module compose implemented)*

**Signature:** `path_kind == intoout` with no flop at either end.

**Measured:** 423/621 core, 118/144 APU (pre-compose corpus).

**Action:** compose fragments into flop-to-flop paths, or label them as fragments
excluded from `closes`. **Implemented intra-module** (`compose_reg_to_reg_paths`,
`delay-v6`): def-use over continuous-assign / always_comb lhs, terminated at
`always_ff` NBA. Fixture `gemm_span.sv` becomes a `RegToReg` cone (mul+adds,
`nodes>1`) so InsertReg + `--real-cut-feeds` drops re-analyzed FO4. Cross-module
instance stitching remains the existing `stitch_cross_module_paths` upper bound.
Fragments stay labeled `intoout` and are still excluded from `closes`.

### P6 — Shallow-over-budget bulk  *(real, tier C — the actual leverage)*

**Signature:** `closes == false`, `budget < total_fo4 < 2·budget`, `node_count > 1`.

**Measured:** **469** core, **87** APU — 75% / 60% of all failures.

**Action:** one latency-neutral rebalance or split **first**. A register is the
P6 last resort, not the default: 75% of failures sit in [10,20), and a stolen
cycle on a handshake (P10) is a functional bug, not a 2 FO4 win. **S4 still
prefers this bucket** over monsters so the shallow mass sets the schedule, but
only after S3 (including low-cleanliness comb) is empty. See §8.

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

### P10 — Cycle-identity / same-edge handshake  *(contract, tier B — implemented)*

**Signature (structural, no host module names):** in one `always_ff`, a 1-bit NBA
samples a combinational pulse (`p_q <= p_comb`) **and** a wider NBA samples a
next-state index (`i_q <= i_d`). Both Qs (or assigns of those Qs) leave the
module. A fanout uses `mem[i_q]` combinationally in the same cycle `p_q` is an
enable. That is a **locked pair**: the pulse is specified to fire when the
index already names the incoming occupant.

**Existence proof (host, not a crate dependency):** SMT2
`g6lc_thread_select` NBA `switch_q <= do_switch` and `active_q <= active_d` in
the same flop block; `switch_o` / `active_hart_o` are those Qs.
`g6lc_smt_pc_bank` snapshots the *outgoing* hart on `switch_i` into
`prev_hart_q` and restores `npc_bank_q[active_hart_i]` combinationally. One
extra cycle on `do_switch`, `active_hart_o`, or `switch_o` indexes the wrong
bank; the peer boots with the wrong PC / stack. Comments at
`g6lc_thread_select.sv:17-20` and `g6lc_smt_pc_bank.sv:53-74` state the
contract; the recognizer must not depend on those names (KD0).

The package already protects `always_ff` scratch and refuses reductions on
*ambiguous* sequential dependencies, and `ConeLane::NextStateFsm` /
`ExclusiveMux` already forbid InsertReg. That is not enough. P5 compose can
stitch the pulse, the registered index, and the consumer mux into one
**Plain CombDatapath** cone — the one lane InsertReg is allowed to cut.

**Action:** never InsertReg (or any +k-cycle cut) on the comb feeding `p_comb` /
`i_d`, on the Q-to-port assigns, on the consumer index/enable cone, or on any
composed path that contains those nodes. S3 may still rebalance / split /
BalanceMux those cones. Residual over-budget is an S5 T3 card ("cannot add
latency; pipeline *upstream* of the lock or raise the budget"), not an S4
candidate. Hosts may also `--refuse-path-prefixes`. See §8.
**Implemented:** `handshake_locked_names` + `tag_handshake_locks` (after classify
and after P5 remeasure). Same-`always_ff` bundle of **2+ distinct output LHS**
with at least one pulse-like RHS (reset+data of one Q is not a handshake);
consumer `assign out = mem[port]` of an indexed-NBA base.
`admits_insert_reg` / `ConeLane::NextStateFsm` refuse.
Fixture `measure/handshake_switch.sv`. KD0: no `g6lc_*` names.

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

  B = paths matching P3 | P4 | P5 | P10      # model gaps / contracts
  route P3 -> T3 report          (never to a cut worklist)
  route P4 -> split node/remainder
  route P5 -> compose or label fragment
  route P10 -> latency-locked    (S3 ok; S4 InsertReg refuse)

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
| **S3** | C2 + C3 rebalance / BalanceMux / **low-cleanliness comb** | **no** | S2 fixpoint | no Δlatency=0 candidate left, including CombSplit / onehot / CSE |
| **S4** | C4 register insertion | **yes** | S3 fixpoint **and** `--allow-latency` **and** not P10 | budget met or no unlocked CombDatapath left |
| **S5** | C5 + C6 + P10 residual | no (asks) | always last | cards emitted (`stage.s5`: T3 / P8 / P9 / P10) |

Rationale for the non-obvious edges:

- **S3 strictly before S4.** State-adding cuts change the scratchboard and invalidate
  cheaper latency-neutral opportunities that were legal a moment earlier. Doing them last
  preserves the flop-minimal solution — the same reasoning that made `-Os` beat `-O3` on
  `alu` with 2 inserted registers instead of 4 (`OPTIMIZATION-LEVELS.md` §3). Extra
  `always_comb` processes and named wires (CombSplit, onehot OR-tree) are *low
  cleanliness* and still belong in S3: they do not steal a cycle.
- **S2 before S3.** P7 changes *which* paths are failing, so running it first shrinks the
  candidate set the structural stages have to consider.
- **S4 is last resort, not the shallow-path default.** P6's [10,20) mass looks like
  "one register each", but a register on a P10-locked net (or on `lzc`, a tree used as
  a function) is a protocol/latency change. S4 runs only on unlocked CombDatapath
  after S3 is empty. After any accepted InsertReg, **return to S2/S3** on the new
  board (the inner multi-pass): a cut can create a new exclusive/bundle that BalanceMux
  should take before the next flop.
- **P10 is a hard refuse, not a cleanliness penalty.** The cleanliness solver can
  pick `jit_datapath` / `aggressive_pipeline` when `w_t` on a timing fail beats
  `w_a`. A board that "closes" by retiming `switch_o` is not feasible.

---

## 6. Pass scheduling policy

Derived from the trace behaviour in §1:

1. **Fixpoint stop.** End a stage after 2 consecutive passes with
   `Δprimary_fo4 < min_gain`. Measured effect: `full_core` stops at pass 3 rather than 19.
2. **Per-stage pass budget (implemented).** S3 and S4 each get `max(1, max_passes/2)`
   passes. A stage that keeps shaving FO4 without emptying must not consume S4's
   InsertReg budget (audit-strict-v4 S3-style motion on `full_core`). S4 also
   **prefers P6** shallow paths (`budget < FO4 < 2·budget`, `nodes>1`) over monsters
   so the [10,20) bulk sets the schedule.
3. **Emitted-delta admission (implemented).** A pass is only credited when emit will
   actually rewrite origin. Lean soak emit (`--real-cut-feeds` / `--emit-balance-mux-rtl`
   off) sets `PassPolicy.emit_structural=false`; every IR FO4 mutation (InsertReg,
   BalanceMux, SplitAssign, rebalance, prep) then refuses credit and S4 is skipped, so
   `post_closure` cannot claim 70.0→54.0 / 304.5→96.5 that the sidecar does not contain.
   `post_closure.reportable` is false in that mode; soak/host read `post_analyze`.
   Richer emit (`--real-cut-feeds`) comments out a continuous origin and sinks lhs from
   the pipe, and rewrites simple procedural NBA/blocking origins to sample the pipe.
   Fixture `gemm_span.sv` proves compose → InsertReg → origin rewrite → FO4 drop.
   `audit-gemm-expol7` is the APU soak: emit post_analyze **161.5→149.0** (IR 129);
   the leftover 144-node cone is an InsertReg loc-mapping miss, not a missing flag.
4. **Refusal is information (implemented).** Every apply-time miss carries a reason
   code (`lean_emit_no_origin_rewrite`, `cleanliness_set`, `lane_forbids_insert_reg`,
   `cut_schedule`, `no_transform_matched`, …). `run.end` emits `refuse_by_reason` and
   `refuse_by_class` so a stage with a high refusal rate is visibly the wrong algorithm
   for that bucket. The audit-strict-v4 1-in-~193 refuse rate was uninformative because
   almost every miss was a silent `Ok(false)`.

---

## 7. What this does not do

- It does not make a frequency claim. Every number here is structural FO4 at an assumed
  20 ps, screening only.
- It does not establish that any path is *the* critical path: P5 composes intra-module
  assign chains, but `intoout` fragments that never reach a flop are still not a
  launch→capture path.
- It does not prove equivalence. Emitted SV re-parses; that is not elaboration and not a
  functional check.
- Removing an artifact **lowers a reported FO4 without improving any hardware.** P1/P2
  work must be reported as a measurement correction, never as an optimization gain.

---

## 8. Aggressive FO4 on a multi-pass basis (InsertReg last)

"Aggressive" at a 10 FO4 budget does **not** mean spraying InsertReg until the
number drops. That already failed as a strategy: the emitted core floored near
99 FO4 with `-O3` buying nothing over `-O2`, lean emit booked IR cuts the
sidecar did not contain, and a single extra flop on the SMT2 switch contract
would be a silent functional break. Aggressive here means **exhaust every
Δlatency=0 degree of freedom, including low-cleanliness comb, on every
re-measured board**, and only then consider a flop on an *unlocked*
CombDatapath.

### 8.1 Three kinds of FO4, three kinds of pass

| Kind | What the number is | Aggressive move | Adds a cycle? |
|---|---|---|---|
| Artifact | P1/P2/P4-twin/`% Cfg` billed as DivRem | S0/S1 re-measure (delay-v14, v19 peel) | no |
| Parallelism mis-ranked | P7 bundle, exclusive sum-of-arms, dense serial | S2 classify + S3 BalanceMux | no |
| Real depth | tree, mux, or datapath longer than *B* | S3 rebalance / split / onehot; S4 InsertReg last | S4 only |

A pass that only cuts artifacts is a measurement correction. A pass that only
InsertRegs a handshake is a bug. The inner loop is: re-measure → S3 including
ugly comb → S4 at most one unlocked cut → re-measure again.

### 8.2 What the package already knows (and the hole)

| Gate | Protects | Misses |
|---|---|---|
| `always_ff` sequential scratch | NBA-only regions, clock-aware factorize | comb *feeding* those NBAs |
| Ambiguous sequential refuse | unverified write→read in one process | verified 1-cycle pulse/index *pairs* |
| `ConeLane::NextStateFsm` | write-only `_d` bundles, no InsertReg | a composed path that is Plain after P5 |
| `ExclusiveMux` / atomic / MC lanes | InsertReg on those classes | consumer mux of a registered index |
| Cleanliness \(C = w_{ff}D_{ff}+w_{comb}D_{comb}-w_a A-w_t 1[\neg pass]\) | prefers density over spray | mixed exclusive+datapath wins S3 and **module-gates** gemm InsertReg |
| **Exception policy** (`exception_policy`) | S4 InsertReg on a resilient Plain `RegToReg` >B despite the S3 winner | real P10, exclusive, atomic, `lzc` / FPU names; incidental P10 class_note still locked below 2·B |
| `PassPolicy.emit_structural` | lean emit cannot book a flop | richer emit can still flop a lock |

P5 compose is the InsertReg footgun: `do_switch` comb → `switch_q` → `switch_o`
→ `pc_bank` restore looks like one CombDatapath. Lane gating on the *producer*
module does not protect the *composed* cone.

### 8.3 Low-cleanliness algorithms that are still S3

Cleanliness penalises aggressiveness. That penalty must **not** push the solver
into InsertReg while Δlatency=0 work remains. Ranked by rising \(A(s)\), all
legal in S3 (and on P10-locked cones):

| Set / algorithm | \(A(s)\) | What it spends | When it is the right ugly |
|---|---|---|---|
| `comb_exclusive` / BalanceMux | low | mux tree, onehot residual | exclusive / dense / next-state |
| `rebalance_associative` | low | different parenthesization | `lzc`, adder/OR clouds |
| CSE / common-prep | low | extra named nets | shared subtrees in a case |
| `comb_split` / SplitAssign | mid | extra `always_comb` + wires | P6 shallow, independent fields |
| onehot OR-tree after hot-arm | mid | extra comb after a mux | exclusive leftover, not a flop |
| `seq_plus_comb` | mid | factorize ff **and** split comb | mixed modules; still Δlatency=0 |
| `jit_datapath` InsertReg | high | **+1 cycle** | unlocked CombDatapath, S3 empty |
| `aggressive_pipeline` multi-cut | highest | **+k cycles** | gemm-shaped P8 after S3; never P10 |

`factor_always_ff` is high-cleanliness sequential commentary. It does not
reduce FO4 and is not a substitute for S3.

### 8.4 Inner multi-pass (fixpoint, not `max_passes` of InsertReg)

```text
loop until Δprimary < min_gain for 2 passes or S4 empty:
  S0/S1/S2   re-measure, abort if new P1/P2 artifacts
  S3         while a Δlatency=0 candidate exists
               (exclusive, bundle, rebalance, CombSplit, onehot, CSE)
               including on P10-locked cones
  if primary still > B:
    S4         at most one InsertReg on a path that is
               CombDatapath AND not P10-locked AND emit_structural
               AND (cleanliness allows jit/aggressive
                    OR resilient-datapath exception)
               prefer resilient (gemm-shaped ≥2·B) then P6 shallow
    continue   # the flop changed the board; S3 may now fire
  S5         T3 / P8 / P9 / P10 cards for whatever remains
```

Two consecutive InsertRegs without an S3 in between is the anti-pattern
(the old `-O3` 16-pass spray). Two S3 passes that each drop FO4 with no
flop is the intended aggressiveness.

### 8.5 Mapping on the delay-v14 / v19 board (budget 10 FO4)

| Residual | Class | First tool | InsertReg? |
|---|---|---|---|
| `lzc` 90, 3-node | Plain intoout | T1 priority-encoder / associative tree (it is a function) | **no** — a flop here adds latency to every consumer |
| `hpdcache_mshr` 86 | P4 remainder after 66 Mul | T1 on the remainder; T3 for the mul | remainder only if unlocked CombDatapath |
| `hpdcache_memctrl:980` 120 | P3 Atomic DivRem | recover generate-mux RHS (P1 hole) | never |
| `g6lc_ai_gemm_seq` 181.5, 144-node Plain | P8 CombDatapath | S3 will not empty a serial makespan; S4 `--real-cut-feeds` | **yes, last**, behind valid/ready; `-O3` cap 8 stages floors ~20 FO4 |
| `g6lc_thread_select` / `g6lc_smt_pc_bank` | next-state + locked pair | S3 exclusive/bundle only | **never** (P10) |
| FMA / `multiplier` / `wt_dcache_mem` 56–66 | P3/P8 atomic | T3 `NumPipeRegs` / stage count | never as InsertReg |

gemm is the legitimate S4 exception in this corpus: composed, Plain on
purpose (IndependentLhsBundle skipped so CombDatapath remains), runtime
muls, no same-edge index handshake. Even there, InsertReg is last after
S3, needs `--real-cut-feeds --allow-latency`, and is not a way to sneak
past the 56 FO4 mul (that stays T3).

**`exception_policy` (implemented):** a path-level override so a mixed
module that won `seq_plus_comb` / `comb_exclusive` cannot starve the gemm
cone. Signature: Plain `RegToReg`, FO4 > budget, not `lzc` / FPU. Real
P10 / indexed `mem[port]` stay HandshakeLock. Incidental P10 class_note
only yields at ≥ 2·budget (deep gemm). P6 remainders (gemm 18.5) admit
one InsertReg.
Indexed `mem[port]` restores (FTQ / SMT2 pc_bank) stay HandshakeLock.
A P10 *class_note* from sharing an `always_ff` with a status pulse does
not win over a gemm-shaped cone. `cone_lane` stays CombDatapath for those
paths so `apply_work_item` does not `lane_forbids_insert_reg`.
`audit-gemm-expol3`: path 3131 InsertReg **161.5→10** IR; IR primary
**129**. `audit-gemm-expol4` twins `gen_reuse_b` `c_span` onto the same
pipe. `--real-cut-feeds` now rewrites simple procedural NBA/blocking
origins (`proc_nba_span.sv`); blank-before-`assign` stays continuous
(`audit-gemm-expol5`) and multi-line NBA first lines still sample the
pipe (`audit-gemm-expol6`). `audit-gemm-expol7`: integrity green; emit
post_analyze **161.5→149.0** / 268.5 MHz (IR **129**). Residual 149 was
the 144-node `always_ff` serial-sum (NBA Q-on-RHS treated as combo).
**delay-v17** (`audit-delay-v17/`): NBA write→later-read is Q, not a
combo edge. Path 3131 is IndependentLhsBundle **26 FO4** (max_field≈25).
**path_class v21** (`audit-pc-v21/`): next-state `_d` capture is
**max_field**, not scratchboard makespan; IndependentLhsBundle still
runs on composed next-state FSMs (gemm serial temps stay skipped).
`g6lc_coherence_hub` **36→11** (max_node 10 + wire). Emit RegToReg
primary **30.5** (`g6lc_ai_policy_subcode` Plain). Analyze max_adj
**74.5** is gemm P4 remainder (56 Mul T3). `te_packet_emitter` intoout
**61** (max_node 60).
**remain-v21b** (`audit-remain-v21b/`): residual InsertReg keeps the
original capture so S4 can cut the 20.5 remainder (`policy_subcode`
three InsertRegs 30.5→10). Multi-node spine expand + `max_cuts` from
`--opt-max-stages-per-region`. `--real-cut-feeds` implies BalanceMux
RTL; continuous rewrite keeps `assign` (`te_packet_emitter`
`address_off`). Integrity green. Emit RegToReg **74.5→26** / 1538 MHz
(189 edits). IR 74.5→56 (T3 mul floor).
**remain-v23** (`audit-remain-v23/`): BalanceMux RTL injects at the
origin process (gemm `pe_float_en` is declared after the first
`always_comb`). BM origin rewrite runs **before** InsertReg so comment
lines do not steal the next NBA (`stc_elem_q` vs `dot_pending_q`).
Integrity green. Emit RegToReg **74.5→22** / 1818 MHz. Gemm 26 gone.
**delay-v18** (`audit-delay-v18/`, path_class **v22**): `pkg::NAME` is
Const (IEEE `::`, not `.`-only); `x+1` / const-offset add is increment
not a 10 FO4 CPA; unique-case mux tax is one `model.mux` (2.5), not
`log2(n)×2.5`. Integrity green. Emit **74.5→18.5** / 2162 MHz. Analyze
max_adj still **74.5** (gemm P4 T3). `te_packet_emitter` 61 intoout gone.
axi2mem 22 / timer 20 / l2_mshr exclusive 18.8 gone from RegToReg
primary.
**path_class v23** (`audit-remain-v24/`): next-state IndependentLhsBundle /
dense drop the 1 FO4 wire tax and the log2 overwrite mux (prefetcher
max_field 17 was `10 + log2(7)×2.5`). Exclusive flop D/Q (`aw_wait_q`,
`rdata_d`) is max_arm, not mux+leftover (dram_timing 15.6). Ternary
`empty ? 0 : mem[port]` is an indexed restore (inval_bus). Plain
RegToReg > budget may S4 InsertReg (gemm 18.5 / instr_queue 16.5); real
P10 and AXI wrap-add bundles stay locked. T3 muls 56 stay T3.
**remain-v24** (`audit-remain-v24/`): integrity green. Emit **18.5→20.0**
/ 2000 MHz (184 edits). Over-budget 401→192, RegToReg 205→86.
Prefetcher 17 / dram_timing 15.6 / 11-cluster gone. New primary
`g6lc_l2_mshr` 20 Plain P10. Gemm geometry 18.5 remains. AXI wrap not
InsertReg'd. **remain-v25** general `(W)'(v)` collapse inflated gemm mul+add
to 67.5 / emit 40.5; **reverted**. **delay-v19** (narrow): only
`(W)'(1)` is an increment; `32'(n-1)*row` is not parsed as Mul.
**remain-v26:** l2_mshr 20 unchanged (2-node `mem_d` sum, not the
cast). **path_class v24 / remain-v27:** 2-arm flop-D exclusive;
l2_mshr 20 gone. Emit **20→18.5** / 2162 MHz. Primary is gemm
geometry `b_span` 18.5. **remain-v28** extra S4-on-flat-primary
regressed to **30.5** (`policy_subcode`); that loop change was
reverted. AXI `wrap_boundary` / fat Plain FSM are not resilient.
S4 rewrites a T1-first relocation card to InsertReg and prepends the cone
if the worklist truncated it. Fixture `auto_correct/mixed_resilient.sv`.
