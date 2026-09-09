# sv-timing Algorithms — Expert Manual

**Audience.** A systems programmer who already designs algorithms, and who must maintain
`sv-timing` without walking the architecture-doc tree. Every claim below is grounded in
an implementation file under `crates/`. Architecture markdown is **not** a prerequisite.

**What this is.** A self-contained theory of the timing-optimization algorithms that
actually run. Each algorithm is a named block: summary, low-level basics, high-level
basis, purpose, mutations, and a behavioural study with commented SystemVerilog `+`/`-`
diffs. The architectural design is treated as first-class theory: the same objects
(budget, path, class, lane, cleanliness set, pass stage, emit origin) that the code
manipulates.

**What this is not.** STA. Structural FO4 is a screening model. A number of 15 FO4
does not mean a place-and-route path of 300 ps. It means: under `fo4-v1`, delay-v25,
path_class detector 24, and the current compose/classify/pass loop, this cone is the
worst remaining single-cycle primary.

**Standing numbers (current design state).**

| Quantity | Value | Where it is computed |
|---|---|---|
| Target | 4000 MHz | `TimingTarget::new` in `crates/sv-timing-core/src/ir.rs` |
| `fo4_ps` | 20 | process input, not a retune knob |
| margin | 0.2 | same |
| Budget \(B\) | **10 FO4** | \((1000/f_{\mathrm{MHz}})\times(1000/\mathrm{fo4\_ps})\times(1-m)\) |
| Measurement | `delay-v25` | `crates/sv-timing-core/src/version.rs` |
| Path-class detector | **24** | `PATH_CLASS_DETECTOR_VERSION` in `path_class.rs` |
| Quoted soak of record | `audit-remain-v50/` emit **15.0 P10 / 16.0 P10** | CLI `correct` + post_analyze; delay-v23 |
| Latest soak | `audit-remain-v52/` delay-v25 integrity green | core **15.0 P10**; APU **22.0** axi2mem WRAP-beyond — **do not quote 22** over v50 16 P10 |
| Historical | `audit-remain-v27/` 18.5 gemm span | VII.A/B/D/E later closed that headline |
| Failed experiments | v25 general `(W)'(v)` 40.5; v28 S4-continue 30.5; v49 2-arg Mux tax gemm 15 | all **reverted** |
| Remaining gap to \(B=10\) | **5 FO4** on core P10 trigger; APU floor 16 P10 inval_bus (or 22 wrap-beyond if quoted) | Part VII |

**How to read.** Read Part 0 once. Then read algorithms in pipeline order (I → VI) the
first time. After that, jump by name: the table of contents is the algorithm index.
When a leftover surprises you, start at **P1–P10**, then **cone lane**, then **S3/S4
fixpoint**, then **emit origin (M7)**. Those four explain almost every soak regression.
Campaign leftover letters in `AGENTS-todo.md` (A–R) map to **M20–M29** here;
they are not A1–A49.

---

## Table of contents

0. [Architectural design as first-class theory](#part-0--architectural-design-as-first-class-theory)
1. [A1 Budget FO4](#a1--budget-fo4)
2. [A2 Cost table `fo4-v1`](#a2--cost-table-fo4-v1)
3. [A3 Inverse: max frequency from a path](#a3--inverse-max-frequency-from-a-path)
4. [A4 Measurement versioning](#a4--measurement-versioning-delay-v25)
5. [A5 Parse](#a5--parse)
6. [A6 Lower to timing IR](#a6--lower-to-timing-ir)
7. [A7 Expression AST](#a7--expression-ast)
8. [A8 Constant lattice (P1)](#a8--constant-lattice-p1)
9. [A9 Billed binary class](#a9--billed-binary-class)
10. [A10 Narrow width-cast (delay-v19/v21)](#a10--narrow-width-cast-delay-v19v21)
11. [A11 Comment interiors (P2)](#a11--comment-interiors-p2)
12. [A12 Genvar / generate lattice](#a12--genvar--generate-lattice)
13. [A13 Comb-for unroll](#a13--comb-for-unroll)
14. [A14 NBA-as-Q (delay-v17)](#a14--nba-as-q-delay-v17)
15. [A15 Attribute costs](#a15--attribute-costs)
16. [A16 Compose launch→capture (P5)](#a16--compose-launchcapture-p5)
17. [A17 Primary locus = hottest node](#a17--primary-locus--hottest-node)
18. [A18 Multi-cycle tagging](#a18--multi-cycle-tagging)
19. [A19 Reference-order tree](#a19--reference-order-tree)
20. [A20 Parallel-timing scratchboard](#a20--parallel-timing-scratchboard)
21. [A21 Path classification (detector 24)](#a21--path-classification-detector-24)
22. [A22 Exclusive-case / exclusive-if](#a22--exclusive-case--exclusive-if)
23. [A23 Independent-LHS bundle](#a23--independent-lhs-bundle)
24. [A24 Dense control cone](#a24--dense-control-cone)
25. [A25 Atomic-over-budget](#a25--atomic-over-budget)
26. [A26 Parallel-timing deflation](#a26--parallel-timing-deflation)
27. [A27 Handshake lock (P10)](#a27--handshake-lock-p10)
28. [A28 Indexed restore](#a28--indexed-restore)
29. [A29 Pattern catalog P1–P10](#a29--pattern-catalog-p1p10)
30. [A30 Cone lanes](#a30--cone-lanes)
31. [A31 Cleanliness catalog](#a31--cleanliness-catalog)
32. [A32 Exception policy](#a32--exception-policy)
33. [A33 Relocation T0–T3](#a33--relocation-t0t3)
34. [A34 Optimization levels and dials](#a34--optimization-levels-and-dials)
35. [A35 Worklist](#a35--worklist)
36. [A36 Clock-aware `always_ff` factorize](#a36--clock-aware-always_ff-factorize)
37. [A37 BalanceMux](#a37--balancemux)
38. [A38 SplitAssign](#a38--splitassign)
39. [A39 Associative rebalance](#a39--associative-rebalance)
40. [A40 InsertReg and Leiserson–Saxe cuts](#a40--insertreg-and-leisersonsaxe-cuts)
41. [A41 Cut strategies](#a41--cut-strategies)
42. [A42 Expression-spine expand](#a42--expression-spine-expand)
43. [A43 Emit / origin rewrite (M7)](#a43--emit--origin-rewrite-m7)
44. [A44 Twin generate rewrite](#a44--twin-generate-rewrite)
45. [A45 Integrity reparse](#a45--integrity-reparse)
46. [A46 Multi-pass S0–S5](#a46--multi-pass-s0s5)
47. [A47 Module-diverse batch](#a47--module-diverse-batch)
48. [A48 Fixpoint and the primary-flat stop](#a48--fixpoint-and-the-primary-flat-stop)
49. [A49 Failed experiment: S4-continue (v28)](#a49--failed-experiment-s4-continue-v28)
50. [M20 Named `fmt_row_bytes` (delay-v20)](#m20--named-fmt_row_bytes-delay-v20)
51. [M21 Const-select offset add](#m21--const-select-offset-add)
52. [M22 Const-condition mux](#m22--const-condition-mux)
53. [M23 Zero-detect](#m23--zero-detect)
54. [M24 Const-then mux chain](#m24--const-then-mux-chain)
55. [M25 Module auto-const](#m25--module-auto-const)
56. [M26 One-hot stride add](#m26--one-hot-stride-add)
57. [M27 Aligned field insert](#m27--aligned-field-insert)
58. [M28 Signed compare vs 0](#m28--signed-compare-vs-0)
59. [M29 Remaining leftover catalog H–R](#m29--remaining-leftover-catalog-hr)
60. [Part VII Remaining gap to 10 FO4](#part-vii--remaining-gap-to-10-fo4)
61. [Part VIII Maintenance playbook](#part-viii--maintenance-playbook)
62. [Appendix. File map, glossary, anti-patterns](#appendix--file-map-glossary-anti-patterns)
63. [Part IX Supporting algorithms](#part-ix--supporting-algorithms-the-pass-loop-actually-calls)
64. [Part X Formal invariants](#part-x--formal-invariants-the-type-system)
65. [Part XI Laboratory walkthroughs](#part-xi--laboratory-walkthroughs)
66. [Part XII Decision trees](#part-xii--decision-trees-for-a-maintainer)
67. [Part XIII Operator billing atlas](#part-xiii--operator-billing-atlas)
68. [Part XIV Pass loop state machine](#part-xiv--pass-loop-state-machine-full)
69. [Part XV Emit pipeline](#part-xv--emit-pipeline-full)
70. [Part XVI 4 GHz campaign](#part-xvi--strategic-reading-of-the-4-ghz-campaign)
71. [Part XVII Worked numeric examples](#part-xvii--worked-numeric-examples-keep-a-pencil-here)
72. [Part XVIII Mutation catalog](#part-xviii--mutation-catalog-what-each-algorithm-may-rewrite)
73. [Part XIX Study order](#part-xix--suggested-study-order-for-a-systems-programmer)
74. [Part XX FAQ](#part-xx--faq-the-soaks-already-answered)
75. [Part XXI Future-detector fixtures](#part-xxi--copy-paste-fixtures-for-future-detectors)
76. [Part XXII Trace glossary](#part-xxii--glossary-expansion-terms-you-will-see-in-traces)
77. [Part XXIII SoC dual](#part-xxiii--dual-of-the-soc-prime-directive-inside-this-package)
78. [Part XXIV Test index](#part-xxiv--index-of-tests-that-pin-theory)
79. [Part XXV Closing](#part-xxv--closing-what-maintain-the-codebase-himself-means)
80. [Part XXVI Detector internals](#part-xxvi--detector-internals-the-first-patch-will-hit)
81. [Part XXVII P1–P10 labs](#part-xxvii--pattern-catalog-one-lab-each-p1p10)
82. [Part XXVIII Soak chronicle](#part-xxviii--soak-chronicle-why-the-code-is-this-shape)
83. [Part XXIX Lowering details](#part-xxix--lowering-details-that-timing-depends-on)
84. [Part XXX Parallel timing worked schedule](#part-xxx--parallel-timing-worked-schedule)
85. [Part XXXI InsertReg allow matrix](#part-xxxi--insertreg-apply-vs-refuse-a-complete-matrix)
86. [Part XXXII SV mutation atlas](#part-xxxii--systemverilog-mutation-atlas-copybook)
87. [Part XXXIII Algo-trace reading](#part-xxxiii--how-to-read-a-refuseapply-algo_trace-event)
88. [Part XXXIV Relocation scoring](#part-xxxiv--relocation-scoring-why-t1-is-first)
89. [Part XXXV Naming collisions](#part-xxxv--naming-collisions-and-file-suffix)
90. [Part XXXVI Near-10 numbers](#part-xxxvi--what-near-10-fo4-means-numerically)
91. [Part XXXVII Anti-pattern patches](#part-xxxvii--anti-pattern-catalog-with-the-patch-that-would-do-it)
92. [Part XXXVIII Gemm debug transcript](#part-xxxviii--a-day-in-the-life-debug-of-gemm-185)
93. [Part XXXIX Function map](#part-xxxix--function-level-map-grep-anchors)
94. [Part XL Night-before-S4 recap](#part-xl--final-recap-the-night-before-you-patch-s4)
95. [Part XLI Apply-work-item](#part-xli--apply_work_item-the-inner-interpreter)
96. [Part XLII Dense sidecar](#part-xlii--dense-sidecar-lean-vs-real-feeds)
97. [Part XLIII Worklist ordering](#part-xliii--worklist-ordering-in-full)
98. [Part XLIV Clock domains](#part-xliv--clock-domains-and-cycle-bars)
99. [Part XLV Cache key](#part-xlv--cache-key-composition)
100. [Part XLVI Remaining-gap proof](#part-xlvi--remaining-gap-proof-from-the-invariants)
101. [Part XLVII insert_register IR](#part-xlvii--insert_register-ir-mutation-what-remeasure-sees)
102. [Part XLVIII Allowlist](#part-xlviii--allowlist-refuse-prefixes-module_allowed)
103. [Part XLIX Ranking leftover counts](#part-xlix--ranking-primary-vs-all-kinds-leftover-counts)
104. [Part L Maintenance contract](#part-l--maintenance-contract-sign-here)

---

# Part 0 — Architectural design as first-class theory

The package is a **compiler of delay**, not a synthesizer of RTL. It reads SystemVerilog,
builds a timing IR, attributes a structural FO4 number to every operator, composes those
operators into launch→capture cones, *reinterprets* statement-order sums as exclusive /
parallel / atomic classes, then optionally mutates source under a staged pass policy.

Five objects are the design. Everything else is a detector, a gate, or an emit tactic.

### Object 1 — Budget \(B\)

\[
B = \frac{1000}{f_{\mathrm{MHz}}} \cdot \frac{1000}{\mathrm{fo4\_ps}} \cdot (1-m)
\]

At \(f=4000\), \(\mathrm{fo4\_ps}=20\), \(m=0.2\): \(B=10\). One 32-bit carry-propagate
add (`AddSub = 10` in `resources/fo4-v1.toml`) **is the entire period**. That single
fact drives every later algorithm: you cannot InsertReg a lone add into two cheaper
adds; you can only (a) prove it is not a CPA, (b) prove it is exclusive with something
else, or (c) pipeline a *chain* of adds.

### Object 2 — Path

A path is an ordered list of IR node ids plus endpoints (reg clock, reg data, input,
output). Raw FO4 is the **sum of node critical costs**. That sum is a lie for exclusive
muxes, independent LHS bundles, dense FSMs, and composed fragments. Classification
replaces the lie with an adjusted number. The adjusted number is what ranking, slack,
and the pass loop see.

### Object 3 — Class

`PathClassKind` in `path_class.rs` is the measurement's type system:

| Kind | What the number means | InsertReg? |
|---|---|---|
| `Plain` | Sum (or parallel makespan if that detector fired) is trusted | maybe |
| `UnderBudget` | Already \(\le B\); skip expensive detectors | no |
| `ExclusiveCaseMux` / `ExclusiveIfChain` | \(\max(\mathrm{arm}) + \mathrm{mux}\) | no (BalanceMux) |
| `IndependentLhsBundle` | \(\max(\mathrm{field}) + \mathrm{wire}\) | no |
| `DenseControlCone` | \(\mathrm{makespan} + \mathrm{select/wire}\) | no |
| `AtomicOverBudget` | A single Mul/DivRem \(> B\) | no (T3) |
| `MultiCycleTagged` | Iterative / already-piped | no |

`discourages_insert_reg()` is the boolean the cut scheduler reads.

### Object 4 — Lane

`ConeLane` in `cone_lane.rs` is **not** a second measurement. It is a transform router
over class + module-name heuristics + handshake facts. Only `CombDatapath` may
InsertReg. Exclusive, next-state, atomic, iterative, pipelined, and screening lanes
keep their own tools.

### Object 5 — Pass stage

`run_correct_passes` in `crates/sv-timing-transform/src/pass.rs` is a two-stage loop:

1. **S3** — latency-neutral (`BalanceMux`, `SplitAssign`) to a fixpoint of two flat
   primary measurements.
2. **S4** — `InsertReg` on admitted Plain `RegToReg` (plus the resilient exception),
   module-diverse, one successful apply per module per pass, then remeasure.

S0 aborts on P1/P2 artifacts. S5 reports T3 asks. There is no S4-until-10. The v28
soak proved that continuing S4 after a flat primary **raises** emit FO4, because emit
origins are line-based and extra edits steal the next rewrite.

### The strategic invariant

> Measurement truth before optimization gain.

P1 (const lattice) and P2 (comment interiors) are **not** optimizations. They remove
phantom delay. If they remain, `plan_from_design` sets `abort_correct` and the pass
loop returns without spending edits (`pass.rs`, the `artifacts_p1_p2` stop). Every
soaked “win” that came from retuning `fo4-v1.toml` or from parsing more of a width
cast is a measurement lie until proven otherwise — delay-v19 general `(W)'(v)`
collapsed gemm to Mul 67.5 and **regressed** emit 18.5 → 40.5; it was reverted.

### The emit invariant (M7)

IR mutation and source mutation are coupled by **line number**, not by SSA name. The
origin of an InsertReg or BalanceMux rewrite is `primary_loc` (hottest node) or the
cut node's `loc`. A later comment or a sibling rewrite that shifts that line steals
the next origin. This is why:

- BalanceMux RHS rewrite runs **before** InsertReg comments.
- Continuous BalanceMux rewrite **keeps** the `assign` keyword.
- Twin generate copies only when **LHS and RHS** match.
- Blind extra S4 InsertRegs on other Plain cones in the same file moved
  `policy_subcode` from 10 back to 30.5 (v28).

### The remaining-gap invariant

The current primary leftover is **not** “the algorithms are incomplete so keep
InsertReg’ing.” It is a specific geometry: two generate-if span assigns
(`a_span` / `b_span`) that the twin rewriter cannot copy because their RHS differ,
left as Plain 18.5 after S4 spent its two gemm cuts on `c_span` and `c_end` and then
hit `flat_streak ≥ 2`. Closing 18.5 → 10 is a **named-block span pair** problem plus
a **bounded sibling-cut**, not a third S4 loop. The floor under that is T3 mul 56,
P10 handshake 16, wrap FSM 14. Part VII derives this from the algorithms, not from
hope.

### Implementation file map (the only map you need)

| Concern | File |
|---|---|
| Budget, IR types, opportunities | `crates/sv-timing-core/src/ir.rs` |
| Versions | `crates/sv-timing-core/src/version.rs` |
| Cost table load | `crates/sv-timing-core/src/cost_table.rs`, `resources/fo4-v1.toml` |
| Parse adapter | `crates/sv-timing-core/src/parse.rs` |
| Lower | `crates/sv-timing-core/src/lower.rs` |
| Expr AST, lattice, billed class | `crates/sv-timing-core/src/expr.rs` |
| Attribute, compose, rank, tag MC | `crates/sv-timing-core/src/measure.rs` |
| Path class v24 | `crates/sv-timing-core/src/path_class.rs` |
| Ref-order tree | `crates/sv-timing-core/src/ref_order.rs` |
| Parallel timing | `crates/sv-timing-core/src/parallel_timing.rs` |
| P1–P10, exception, S4 helper | `crates/sv-timing-core/src/pass_strategy.rs` |
| Lanes | `crates/sv-timing-core/src/cone_lane.rs` |
| Cleanliness | `crates/sv-timing-core/src/cleanliness.rs` |
| Relocation cards | `crates/sv-timing-core/src/relocation.rs` |
| Opt dials | `crates/sv-timing-core/src/opt.rs` |
| Pass loop S0–S5 | `crates/sv-timing-transform/src/pass.rs` |
| Cuts, BalanceMux, InsertReg, SplitAssign | `crates/sv-timing-transform/src/pipeline.rs` |
| Worklist | `crates/sv-timing-transform/src/worklist.rs` |
| `always_ff` factorize | `crates/sv-timing-transform/src/factor_always_ff.rs` |
| Edits | `crates/sv-timing-transform/src/edit.rs` |
| Emit, inject, integrity | `crates/sv-timing-emit/src/lib.rs` |
| Origin RHS rewrite | `crates/sv-timing-emit/src/rhs.rs` |
| Dense sidecar block | `crates/sv-timing-emit/src/dense.rs` |
| CLI | `crates/sv-timing-cli/src/main.rs` |
| Cost numbers | `resources/fo4-v1.toml` |

Vendored `crates/sv-parser/` is the IEEE grammar frontend. Timing algorithms do not
live there. Do not “fix FO4” by editing the parser unless a CST token is being
mis-attributed as an operator (P1 packed-dim / case-label / part-select history).

---

# Part I — Timing basis

## A1 — Budget FO4

**Implementation.** `TimingTarget::new` in `crates/sv-timing-core/src/ir.rs`.

### Summary

The only period the rest of the package knows. Every slack is \(B - \mathrm{FO4}\).
Every “over budget” predicate is `fo4 > budget + 1e-9`. Changing \(B\) changes
which detectors fire, which paths are `UnderBudget`, and whether S4 has work.
Changing `fo4_ps` is a **process** change, not an optimization.

### Low-level basics

A FO4 (fanout-of-4 inverter delay) is the technology unit. The cost table is
normalized to that unit at 32-bit. The period in nanoseconds is \(1000 / f_{\mathrm{MHz}}\).
Dividing by `fo4_ps / 1000` converts the period into FO4 counts. Margin \(m\)
shrinks the usable fraction: at \(m=0.2\) you keep 80 % of the period for logic.

```text
period_ns     = 1000 / target_mhz
gross_fo4     = period_ns * 1000 / fo4_ps
budget_fo4    = gross_fo4 * (1 - budget_margin)
```

Worked values:

| \(f\) MHz | period ns | gross FO4 @ 20 ps | \(B\) @ \(m=0.2\) |
|---:|---:|---:|---:|
| 1250 | 0.800 | 40 | **32** |
| 2000 | 0.500 | 25 | **20** |
| 4000 | 0.250 | 12.5 | **10** |

Host of record historically quoted 1.25 GHz / 12 nm. The 4 GHz campaign is the
same model with a tighter \(B\). The algorithms did not change identity; their
admission thresholds did, because `AddSub=10` went from “a third of a 32-FO4
period” to “the whole period.”

### High-level basis

\(B\) is a **hard constraint** in cleanliness (`timing_fail` penalty 0.50) and a
**soft stop** in the pass loop (primary slack ≥ 0). It is not a synthesizer clock
constraint. Parallel timing uses the same \(B\) as the cycle bar:
\(\mathrm{ready\_cycle} = \lceil C(s) / B \rceil\). JIT InsertReg is justified
only on a zero-slack op whose completion crosses a multiple of \(B\)
(`parallel_timing.rs` header comment).

### Purpose

Give every later algorithm a single scalar against which to decide “this is a
problem” vs “this is closed.” Without \(B\), exclusive deflation has no
short-circuit, S4 has no stop, and T3 has no “atomic means needs \(N=\lceil
\mathrm{mul}/B \rceil\) cycles” reading.

### Mutations

None to RTL. `TimingTarget` is an input. Do not retune `fo4_ps` to make a soak
green. Do not lower `AddSub` in the cost table to make \(B=10\) “fit” an adder —
that is lying about silicon.

### Behavioural study

```systemverilog
// Same netlist, two budgets. Nothing in the RTL changed.
logic [31:0] s;
assign s = a + b;          // billed AddSub = 10 FO4 (A2, A9)

// At 1250 MHz, B=32: path is UnderBudget. classify short-circuits.
// At 4000 MHz, B=10: path is exactly B. slack = 0. "closes".
// At 4000 MHz if a second LogicBit rides along: 11 FO4, P6 shallow, S4 candidate
// IFF the path is Plain RegToReg with nodes>1 and not handshake/wrap/atomic.
```

### Maintenance

If a new target frequency is requested, recompute \(B\) and re-soak with a **new**
out-dir. Never reuse the SQLite analyze cache across \(B\) changes (cache key
includes target). `opt.analysis_digest` does **not** include transform dials, but
it does include `effort` and `cache_mode` (`opt.rs`).

---

## A2 — Cost table `fo4-v1`

**Implementation.** `resources/fo4-v1.toml`; loaders in
`crates/sv-timing-core/src/cost_table.rs`; `CostModel::base_fo4` in `measure.rs`.

### Summary

A closed set of operator classes with deterministic unit-width costs. The table
is a golden. Tests pin `mul=56` and `add_sub=10`. Width scaling, when applied, is
in measure — the table itself is 32-bit-normalized.

### Low-level basics

```toml
logic_bit = 1.0
compare = 4.0
shift_const = 2.0
shift_var = 12.0
add_sub = 10.0
mul = 56.0
div_rem = 120.0
mux = 2.5
priority_mux_per_level = 3.0
concat = 0.5
other = 1.0
```

`OperatorClass` in `ir.rs` is the key. `classify_binary_op` in `expr.rs` maps
spellings: `+`/`-` → AddSub, `*` → Mul, `**` → ShiftConst (decoder, not mul),
`/`/`%` → DivRem, shifts → ShiftConst, compares → Compare, bitwise/logic →
LogicBit. Unary `~`/`!` reductions are LogicBit; unary `-` is AddSub.

Critical-path cost of an expression is **not** the sum of every operator. It is
the maximum over parallel arms plus the root (`Expr::fo4_critical_cost_latticed`).
A ternary costs `mux + max(cond, then, else)` in spirit (cond and arms are
max'd, then mux is added at the Ternary node). Const∘Const short-circuits to 0
before any table lookup (A8).

### High-level basis

The table encodes a **technology opinion** about relative difficulty, not a
liberty file. Mul 56 vs Add 10 vs Mux 2.5 is why:

- A lone 32-bit mul cannot close 4 GHz in one cycle (\(56 > 10\)). That is T3
  (`AtomicOverBudget`, `ConeLane::AtomicMul`).
- A unique-case of 7 arms is **not** \(7 \times\) the arm. Detector v24 bills
  `max_arm + model.mux` (one-hot AND-OR), not \(\log_2(7)\times 2.5\).
- Priority if/else still bills `priority_mux_per_level * n` because a chain of
  compares **is** serial.

### Purpose

Make goldens stable and make “what would silicon think” a function, not a
prompt. Downstream algorithms never invent a FO4 number; they combine table
lookups.

### Mutations

None to RTL. Changing a table entry changes **every** golden and every soak.
The standing rule: only retune from real STA + host `timings retune-propose`,
never from a synthetic fixture that failed to parse.

### Behavioural study

```systemverilog
// Three operators, three worlds.
assign y = a & b;                 // LogicBit 1
assign y = a + b;                 // AddSub 10  — the whole 4 GHz period
assign y = a * b;                 // Mul 56     — 5.6 cycles at B=10; T3

// Unique case: NOT 7 * max_arm.
unique case (sel)
  3'd0: q <= x0;
  3'd1: q <= x1;
  // ...
  3'd6: q <= x6;
endcase
// Class ExclusiveCaseMux: max_arm + mux(2.5). If q is *_q / *_d, mux=0 (A22).
```

### Maintenance

`parse_fo4_toml` is a hand parser (no toml crate). Keep the file a flat `k = n`
list. `default_fo4_v1_embedded` includes the file at compile time so a missing
`resources/` still runs.

---

## A3 — Inverse: max frequency from a path

**Implementation.** `max_freq_mhz_for_path`, `frequency_closure` in `measure.rs`.

### Summary

Given a path FO4, invert A1. Reports quote both slack and MHz. Soak summaries
use **post_analyze** emit FO4, not IR `max_path_fo4`.

### Low-level basics

```text
period_ns = total_fo4 * fo4_ps / 1000 / (1 - margin)
f_mhz     = 1000 / period_ns
```

Worked: 18.5 FO4, 20 ps, m=0.2 → period = 18.5 × 20 / 1000 / 0.8 = 0.4625 ns →
**2162 MHz**. 10 FO4 → 4000 MHz. 30.5 FO4 → 1311 MHz (the v28 regression).
56 FO4 (mul) → 714 MHz if treated as a single-cycle primary — which is why
atomic paths are tagged T3 / multi-cycle and excluded from `closes`.

`frequency_closure` ranks by slack, counts `RegToReg` vs `InToOut` failures
separately, and sets `closes` from non-multi-cycle primary slack. **P5:**
`intoout` fragments are not period paths. A failing `InToOut` does not mean
the clock does not close.

### High-level basis

MHz is a **derived report**, not a control. The pass loop stops on slack, not
on MHz. Quoting 2162 MHz without saying “structural, delay-v19, class v24,
emit primary gemm 18.5” is a category error.

### Purpose

Give humans a clock they recognize. Give soaks a single headline number.

### Mutations

None.

### Behavioural study

```systemverilog
// Two paths in one module. Closure is the worse RegToReg.
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) q <= '0;
  else         q <= a + b;     // 10 FO4 — closes 4 GHz
end
assign y_o = acc * k;          // 56 FO4 InToOut fragment — P5, not primary
// frequency_closure.regtoreg_failing == 0
// frequency_closure.intoout_failing  >= 1
// design.closes for core frequency uses RegToReg
```

---

## A4 — Measurement versioning (delay-v25)

**Implementation.** `MEASUREMENT_VERSION` in `crates/sv-timing-core/src/version.rs`.

### Summary

A linear log of **how** delay is computed. Reports and cache keys must carry
this string. Comparing a delay-v17 number to a delay-v25 number is invalid.
Each bump is a measurement correction unless the comment says otherwise.

### Low-level basics (the chain, condensed)

| Ver | What changed |
|---|---|
| legacy-sum | source-order chaining, width-blind |
| delay-v1 | def-use DAG, expression critical chain, width-scaled |
| delay-v2 | CST origins; runtime `*`/`/` no longer discounted by name |
| delay-v3 | `// synthesis translate_off` excluded |
| delay-v4 | `[msb:lsb]` bounds are LRM-constant (not a divider) |
| delay-v5 | P1 lattice + P2 comments |
| delay-v6 | P5 compose launch→capture |
| delay-v7 | indexed `+:`/`-:` parsed |
| delay-v8 | packed/unpacked dims and case-item labels are elab-constant |
| delay-v9 | `Expr::PartSelect` instead of fake `Binary ":"` |
| delay-v10 | parsed RHS authoritative at 0 FO4; no string-heuristic Mul fallback |
| delay-v11 | seed localparams / param-map / imported package names |
| delay-v12 | module-scoped lowering (multi-module files) |
| delay-v13 | genvar Const only inside its generate-loop span |
| delay-v14 | runtime `/` `%` with Const divisor is a shift, not SRT |
| delay-v15 | nested generate-for records **each** loop's genvar |
| delay-v16 | `always_comb for (int w=0; w<N; w++)` index is Const (unrolled) |
| delay-v17 | NBA write→later-read in one `always_ff` is Q, not combo |
| delay-v18 | `pkg::NAME` Const; `x+1` increment not CPA |
| delay-v19 | **only** `(W)'(1)` is an increment; general `(W)'(v)` is **not** parsed |
| delay-v20 | `fmt_row_bytes` / `ai_fmt_bytes` are mux-of-shifts, not Mul (M20) |
| delay-v21 | const-select offset add (M21); numeric/`PLEN`/`IDX_W` `W'(const\|ident\|ident±1)` collapse, **not** `int'(x)` (A10); const-condition `?:` (M22); `==`/`!=` vs 0 (M23) |
| delay-v22 | nested const-then mux chain is one mux (M24); encoding-then concat + `ident[CONST]` |
| delay-v23 | module auto-const (M25); `x+(1<<n)` mux of increments (M26); `{x,0}+(y<<K)` concat (M27); signed `x>0` sign bit (M28). Unknown calls stay Other (M29 N; 2-arg Mux tax **reverted**) |
| delay-v24 | exclusive `{x[MSB:K],{K{0}}}` seeds `ident+(y<<K)` as field insert (M27). Wrap ident from a Call is not aligned. `{{LOG}{1'b0}}` unwrap |
| delay-v25 | exclusive `t = y << K` temps: `aligned + t` is field insert (M27). `wrap + t` stays CPA |

### High-level basis

Versioning is how a measurement compiler avoids silent incomparability. The
cache (`sv-timing-cache`) keys on this. Detector version is a **second** axis
(`PATH_CLASS_DETECTOR_VERSION = 24`) because class can change without the
expression cost changing.

### Purpose

Stop a future maintainer from mixing goldens. Stop a soak from looking like a
gain when only the ruler changed.

### Mutations

None to RTL. Bumping the string is mandatory when `expr.rs` / `measure.rs` /
`lower.rs` change cost.

### Behavioural study — the delay-v19 lesson

```systemverilog
// l2_mshr: this IS an increment (narrow v19).
count_q - (IDX_W+1)'(1)

// gemm: this must NOT parse as (n-1)*row (general cast was delay-v19 failed experiment).
assign b_span = 32'(n_q[8:0] - 9'd1) * fmt_row_bytes({16'd0, ldb_q}) + k_bytes;
```

General `(W)'(v)` collapse billed gemm as Mul+add **67.5**, analyze max_adj
74.5→123.5, emit 20→40.5. Reverted. Narrow v19 keeps the increment for
`(IDX_W+1)'(1)` and leaves the gemm cast **opaque**, so the 18.5 leftover is
an incomplete parse **on purpose**. Fully parsing it would re-inflate the
primary, not close it.

Test: `plus_one_is_increment_not_carry_propagate_add` in `expr.rs`.

---

# Part II — Front end: parse, lower, expression, lattice

## A5 — Parse

**Implementation.** `crates/sv-timing-core/src/parse.rs`; vendored
`crates/sv-parser/`.

### Summary

IEEE SystemVerilog CST via the forked Rust `sv-parser` (dalance v0.13.5 +
Verilator chained-select, branch `g6lc`). Timing algorithms consume a
location-adapted tree, not tokens. Parse failure of a file is a **hard** miss:
no IR, no FO4, no correct.

### Low-level basics

`parse_one` / `parse_paths` wrap the vendor, map byte offsets to
`file:line:column` (`loc.rs`, `OriginKind`). Defines and include paths are
ingest options (`ParseOptions`). The package never reads a host flist at
compile time (KD0). CLI `--files` / `--files-from` is the ingest.

Preprocessor lives in `sv-parser-pp`. Timing does not interpret `ifdef` beyond
what the CST already dropped.

### High-level basis

A timing compiler that cannot parse a generate-if or a width-cast will **invent
delay** (string heuristics) or **drop delay** (Opaque → 0). delay-v10 made the
parsed tree authoritative, including 0 FO4, specifically to kill the
string-heuristic Mul on `v[HYP_EXT*2:0]`. The remaining Opaque cases are
**protective** (A10).

### Purpose

Get a CST with locations. Everything after this is lowering.

### Mutations

None. If parse fails, fix the fixture or the vendor pin, not the cost table.

### Behavioural study

```systemverilog
// Chained select must parse (vendor g6lc patch), else the index is Opaque.
assign w = arr[i][j];

// Packed dimension arithmetic is CST, not datapath (delay-v8).
logic [WIDTH*2-1:0] x;
// BinaryOperator tokens inside the range are elaboration-constant.
```

Fixtures: `fixtures/parse/chained_select.sv`, `packed_dim_lrm.sv`,
`part_select_const_arith.sv`, `comment_interiors.sv`, `genvar_lattice.sv`,
`param_lattice.sv`, `lzc_tree.sv`, `hpdcache_idx_mux.sv`, `comb_for_scale.sv`.

---

## A6 — Lower to timing IR

**Implementation.** `crates/sv-timing-core/src/lower.rs` (`analyze_files`,
`lower_unit`).

### Summary

Walk the CST, emit `TimingModule`s with nodes, regions (`always_ff` /
`always_comb` / continuous assign), ports, parameters, gen-loops, functions,
instances. Each assignment becomes an `IrNode` with optional `lhs_expr` /
`rhs_expr`, `assign_kind` (blocking / NBA / continuous), `op_class` guess, and
`SourceLoc`.

### Low-level basics

delay-v12: **module-scoped**. A file with two modules no longer unions their
ports/params/regions. Each module's CST slice owns its names. That stopped
cross-module const-seed contamination and cross-module path composition.

Regions group nodes that share a process. `GateInfo` on `always_ff` carries
clock/reset/edge for parallel-timing clock domains (`ClockDomain::from_gate`).

`AssignKind::Nonblocking` is the sequential def. Blocking inside `always_ff` is
a combo temp (compose treats it as comb, A16). Continuous `assign` is comb.

Instances are recorded for cross-module stitch at `OptEffort::Balanced` /
`Thorough` (`opt.rs`, `stitch_cross_module`). Fast effort skips stitch.

### High-level basis

Lowering is the last point at which IEEE meaning can be preserved cheaply.
After this, algorithms see graphs. If NBA vs blocking is lost, delay-v17 cannot
treat an NBA write as Q. If generate-loop spans are lost, genvars leak Const
across the module (delay-v13/v15). If module scope is lost, a localparam in
module A zeros an operator in module B.

### Purpose

A stable IR that measure and transform can share across passes. `fo4_locked`
on a node freezes residual segment cost after a spine split so remeasure does
not re-bill the whole original expression on both halves.

### Mutations

Lowering itself does not rewrite source. It may drop `translate_off` regions
(delay-v3).

### Behavioural study

```systemverilog
module twin;
  logic [31:0] a, b, q;
  always_ff @(posedge clk_i) q <= a;   // NBA: sequential def, Q for later reads
  always_comb begin
    logic t;
    t = a + b;                         // blocking temp: comb node
    unique case (sel)
      2'd0: y = t;
      2'd1: y = a;
      default: y = b;
    endcase
  end
endmodule
// Two regions. Compose (A16) may chain t → y as one launch-capture cone
// if q or an output reads y.
```

---

## A7 — Expression AST

**Implementation.** `crates/sv-timing-core/src/expr.rs` (`Expr`, recursive
descent `Parser`).

### Summary

A timing-oriented subset of SV expressions: ident, literal, unary, binary
(with `op_class`), ternary, concat, replicate, index, `PartSelect`
(`[msb:lsb]`, `+:`, `-:`), call, Opaque. Not a full elaborator. Unrecognized
residue is Opaque so emit can round-trip the original text.

### Low-level basics

Parse is Pratt-ish recursive descent: ternary → `||` → `&&` → bitwise → eq →
rel → shift → add → mul → unary → primary. Comments are skipped inside the
expression parser (P2 at this layer too). `PartSelectKind::from_op` maps
`:` / `+:` / `-:` so those tokens are **never** `Binary` AddSub/Other.

`fo4_critical_cost_latticed(base, seed)`:

- Literal / Const ident → 0
- Binary: if both sides Const → 0; else `billed_class` cost + max(left, right)
  (arrival-time, not sum)
- Ternary: mux + max of the three children
- Concat: concat + max of parts
- Replicate: **body only** (count is LRM-constant)
- Index: fixed range → base only; indexed part-select → max(base, index-base);
  dynamic index → max(base, index)
- Call: `$clog2`/`$bits`/… of Const args → 0; else Other + max(args)

`dominant_op_class_latticed` walks with the same Const short-circuit and billed
demotion so a path whose only `*` is `i*N` in a slice bound is not class Mul.

`critical_spine_ops` emits the leaf→root operator list for expr-level multi-cut
prep (A42): parallel arms contribute only the heavier child's spine.

### High-level basis

The AST is where **IEEE constant-expression contexts** are encoded as cost
rules rather than as a full constant evaluator. We do not compute `WIDTH*2-1`;
we prove the bounds are Const and bill 0. We do not fold `a+1`; we demote it
to LogicBit (A9). We do not evaluate `32'(n-1)` (A10).

### Purpose

Give measure a tree, give emit a round-trip, give spine-expand a cut list.

### Mutations

None to RTL. Opaque is the safe fallback.

### Behavioural study

```systemverilog
assign y = (a + b) + (c + d);
// Tree: Add(Add(a,b), Add(c,d))
// Critical cost: 10 + 10 = 20 if a,b,c,d runtime (root add + heavier child 10)
// NOT 40. Rebalance (A39) can make it 10 + 10 still — associative rebalance
// does not reduce a 2-level add tree below 20 without a register.

assign y = sel ? (a * b) : c;
// mux + max(sel, mul, c) = 2.5 + 56 = 58.5. Dominant = Mul. Atomic if single node.
```

---

## A8 — Constant lattice (P1)

**Implementation.** `ConstClass`, `ConstSeed`, `Expr::const_class` in `expr.rs`;
pattern P1 in `pass_strategy.rs`.

### Summary

Elaboration-time arithmetic is **zero delay**. `Const ∘ Const → Const → 0`.
This is a measurement correction. Residual P1 hits abort correct
(`plan_from_design.abort_correct`).

### Low-level basics

Join:

```text
Const  ∘ Const  → Const
any    ∘ Runtime → Runtime
else             → Unknown   (charged as hardware, conservative)
```

Seed (`ConstSeed::looks_const`):

1. Exact names from localparams, parameters, param-map, imported package names
   (`elaboration_const_names`).
2. Last segment after `::` **and** after `.` (`te_pkg::XLEN` → `XLEN`).
3. `*Cfg.` fields (`CVA6Cfg.XLEN`, `HPDcacheCfg.reqDataWidth`).
4. SCREAMING_CASE with ≥ 2 letters (`XLEN`, `PRIV_LEN`, `IDX_W`).
5. **delay-v23 auto-const (M25):** exclusive expression-less combo/continuous
   assign whose LHS is read. Copy-propagates ident aliases to a fixpoint
   (cap 32). NBA / indexed LHS / multi-writer / write-only `_d` stay runtime.
   Mixed-case **localparams** (`MaxBurstBeats`) are already step 1 — auto-const
   is for *nets*, not for `localparam` declarations.
6. **delay-v24/v25 aligned / shifted maps (M27):** exclusive
   `{x[MSB:K],{K{0}}}` seeds `ConstSeed.aligned`; exclusive `t = y << K`
   seeds `ConstSeed.shifted`. Not Const — they only demote matching adds.

delay-v18 split `::` as well as `.`. Before that, `te_pkg::XLEN` was Runtime
and `used_bits += te_pkg::XLEN` was a 10 FO4 add.

LRM-constant **contexts** (not just names): replication count, fixed `[msb:lsb]`
bounds, case-item labels, packed/unpacked dimension expressions, generate-for
headers, `$clog2`/`$bits` of Const args.

Genvar is Const **only inside its generate-loop span** (delay-v13), and nested
loops record **each** genvar (delay-v15). A module-wide `i` is not Const.

### High-level basis

P1 is the difference between “the RTL mentions multiplication” and “the
datapath contains a multiplier.” IEEE 1800 constant expressions are elaborated
to integers before gates exist. Billing them as Mul/Add is a category error
that historically produced 56 FO4 “atomics” on MMU slice bounds and 10 FO4
“CPAs” on package-width sums.

The lattice is **conservative on Unknown**. We would rather over-bill a
localparam we failed to seed than under-bill a runtime net named `DATA`.

### Purpose

Remove phantom delay so S4 does not InsertReg into a parameter sum, and so
`AtomicOverBudget` is reserved for real muls.

### Mutations

None to RTL. If a leftover is P1, **fix the seed or the parse**, then remeasure.
Do not pipeline it.

### Behavioural study

```systemverilog
// - billed as AddSub 10+10+… (pre delay-v18, `::` not split)
// + Const∘Const = 0  (delay-v18)
assign used_bits = 1 + te_pkg::PRIV_LEN + te_pkg::XLEN + 2 + te_pkg::TIME_LEN;

// Mixed: consts fold, runtime (address_off * 8) is PoT mul → Other, then
// const-offset add → LogicBit. Critical ≪ 15 (test package_scope_screaming_idents).
assign used_bits = 1 + te_pkg::PRIV_LEN + (address_off * 8) + te_pkg::TIME_LEN;

// Slice bound: not a divider (delay-v4/v9).
assign lo = vpn[VpnLen*2-1 : VpnLen];
```

Test: `package_scope_screaming_idents_are_elaboration_const`.

---

## A9 — Billed binary class

**Implementation.** `billed_binary_class` in `expr.rs`.

### Summary

After the lattice, some **runtime** operators are still not the table class.
Demote them before charging.

### Low-level basics

Order of demotion (after lattice; see also M20–M28):

1. `*` of a literal power of two → `Other` (shift / index scale). `8`, `1_024`,
   `'h8`, `8'sd8` all count (`positive_literal_value`).
2. `*` whose operand is `fmt_row_bytes` / `ai_fmt_bytes` → Mux (M20).
3. `/` or `%` whose **divisor** is Const (literal or seeded name) → `Other`.
   `8 / a` (runtime divisor) stays `DivRem`.
4. `+`/`-` with a unit operand `1` / `1'd1` / `(W)'(1)` → `LogicBit`
   (increment, not 10 FO4 CPA).
5. `+`/`-` with one Const operand → `LogicBit` (const offset folded onto the
   runtime spine).
6. `x + (c ? lit : lit)` → `LogicBit` (M21). Runtime mux arms stay AddSub.
7. `x + (1 << n)` with runtime `n` → `Mux` (M26). `x + (a << n)` stays AddSub.
8. `{x[MSB:K],{K{0}}} + (y << K)` / `aligned + (y<<K)` / `aligned + t` →
   `Concat` (M27). Wrap ident from a Call stays AddSub.
9. signed `x > 0` / `x >= 0` / `x < 0` → `LogicBit` (M28). `x > y` stays Compare.
10. `==` / `!=` vs 0 → `LogicBit` (M23).
11. Else the original `op_class`.

`**` is already `ShiftConst` at classify time (decoder). Unknown user `Call`
stays `Other` (M29 N). Do not bill 2-arg unknown calls as Mux (v49 gemm 12→15).

### High-level basis

Silicon: `x+1` is an incrementer; `addr + OFFSET` is the same adder with a
folded constant, not a second CPA; `idx * 8` is a wiring shift; `x / 8` is a
slice. The 10 FO4 / 56 FO4 / 120 FO4 numbers are for **general** add/mul/div.
Billing the special cases as general operators created fake primaries
(axi2mem `len+1` then `<< LOG` then wrap add stacked as 10+10+10; te_packet
`used_bits += XLEN`; l2_mshr waiter arithmetic).

Const-offset demotion is the reason `wrap_boundary + ((len+1)<<k)` bills as
inc + shift + **one** add, not three CPAs. The wrap add itself remains AddSub
10 — and `path_has_burst_wrap` then **refuses** to call that resilient (A32),
because InsertReg on a WRAP next-address is a protocol break.

### Purpose

Stop special-case arithmetic from consuming the entire 4 GHz period.

### Mutations

None. This is measurement.

### Behavioural study

```systemverilog
// - AddSub 10
// + LogicBit 1  (unit increment)
assign nxt = ax_req_q.len + 1;

// - AddSub 10 + AddSub 10 + Shift
// + LogicBit + ShiftConst + AddSub  ≈ inc+shift+add < 16
assign wrap = wrap_boundary + ((ax_req_q.len + 1) << 3);

// - Mul 56
// + Other (PoT)
assign byte_idx = i * 8;

// - DivRem 120
// + Other (const divisor)
assign word = addr / 4;

// Stays DivRem: runtime divisor
assign q = 8 / a;
```

Test: `plus_one_is_increment_not_carry_propagate_add`,
`literal_power_of_two_multiplication_is_cheap`,
`delay_v23_stride_add_aligned_insert_sign_and_call`.

---

## A10 — Narrow width-cast (delay-v19/v21)

**Implementation.** expression primary parser in `expr.rs`; tests
`delay_v21_const_select_mux_and_width_cast`.

### Summary

Postfix `'(` collapses when the **width token** is numeric or a seeded name
(`32`, `PLEN`, `IDX_W`) **and** the value is `const`, `ident`, or `ident±1`.
Type-name casts (`int'(x)`, `unsigned'(x)`) do **not** collapse. General
`32'(n-1)*row` is still unparsed. Protective incomplete parse plus a narrow
delay-v21 hole.

### Low-level basics

SV has `width'(value)` casts. A full parse of `32'(n-1)*row+k` exposes the
inner `n-1` add and the `*` mul, which `billed_binary_class` will then charge
as Mul 56 plus adds. Soak `audit-remain-v25/` did that: gemm 87.5/67.5, emit
primary **40.5**. Reverted.

delay-v21 reopened **only** `W'(const|ident|ident±1)` when `W` is a number or
`PLEN`/`IDX_W`. `PLEN'(LINE_B)` and `IDX_W'(int'(rr_q)+1)` collapse. Soak
`audit-remain-v43/` collapsed `int'(group_q)` and exposed `*6` as Mul 56
(policy_subcode); type-name `'(` was taken back out. Test covers
`int'(q)*6` ≁ Mul.

Narrow v19 still: `(IDX_W+1)'(1)` is the integer 1, so
`count_q - (IDX_W+1)'(1)` is an increment (A9).

### High-level basis

Completeness of the expression parser is **not** a monotonic good. At \(B=10\),
exposing a mul that is actually a format-dependent shift (`fmt_row_bytes`,
M20) creates a T3-looking primary. Type-name casts wrap runtime integers
(`int'(group_q)*6`); collapsing them is a measurement lie of the v25 class.

### Purpose

Keep increment detection and narrow `W'(ident)` without reopening gemm as Mul
or policy_subcode as Mul 56.

### Mutations

None. Do not finish the cast parser. Do not collapse type-name `'(` .

### Behavioural study

```systemverilog
// Narrow v19: increment.
assign nwait = count_q - (IDX_W+1)'(1);

// delay-v21: numeric / PLEN / IDX_W of ident±1 collapses.
assign nxt = IDX_W'(int'(rr_q) + 1);

// Type-name does NOT collapse (v43 Mul 56).
assign scaled = int'(group_q) * 6;   // stays Mul

// Must stay uncast. Incomplete parse, NOT 67.5 Mul.
assign b_span = 32'(n_q[8:0] - 9'd1) * fmt_row_bytes({16'd0, ldb_q}) + k_bytes;
```

---

## A11 — Comment interiors (P2)

**Implementation.** operator-token skip in lower/measure; `loc_looks_like_comment`
in `pass_strategy.rs` is a stub (P2 is applied at collect time via
`operator_token_in_comment` + `blank_sv_comments`).

### Summary

`//` and `/* */` text is not hardware. A `*` inside a comment is not a mul.
Residual P2 hits abort correct.

### Low-level basics

The expression parser skips `//` to newline and `/* */` (A7). Lowering must
not harvest `BinaryOperator` tokens from comment interiors of a statement
span. delay-v5 bundled this with the lattice as the first “measurement not
gain” pair.

### High-level basis

CST token scans that ignore lexical state will bill documentation. That
produced fake atomics on commented formulas. P2 is the lexical dual of P1.

### Purpose

Abort rather than optimize a comment.

### Mutations

None.

### Behavioural study

```systemverilog
assign y = a + b; // critical: y = a * b + c   ← the '*' must not be a node
/* datapath: accum += x * coeff */
assign accum = accum + x;
```

Fixture: `fixtures/parse/comment_interiors.sv`.

---

## A12 — Genvar / generate lattice

**Implementation.** gen-loop spans on `TimingModule` in lower; seed add in
`attribute_costs` (`measure.rs`); delay-v13/v15 in `version.rs`.

### Summary

A genvar is Const inside its generate-for span, not module-wide. Nested loops
each contribute their own genvar. Generate-for/if/case **headers** are
LRM-constant CST.

### Low-level basics

`attribute_costs` copies the module seed, then for each node whose
`byte_start` lies in a gen-loop `[byte_start, byte_end)` adds that loop's
`genvar` to the seed. Nested spans all match, so `gen_i * Cfg` in the outer
body is Const∘Const even if an inner `gen_j` is also live.

`i` as a module port or `always_comb` index is **not** this. Comb-for is A13.

### High-level basis

Generate unrolling is elaboration. `for (genvar i = 0; i < N; i++)` is a
compile-time loop. Billing `i*WIDTH` as Mul 56 created fake T3 on every
generate datapath (hpdcache muxes, gemm reuse generates).

**Keyword vs generate-if.** `line_inside_generate` in emit only counts
`generate` / `endgenerate` keywords. CVA6-style `if (ReuseBEn) begin :
gen_reuse_b` without the keyword is **not** inside generate for emit's
twin/lock helpers, and `lhs_is_module_level_net` only refuses `automatic`.
So `b_span` **is** a claimable origin. Twin copy still requires identical
RHS (A44). This interaction is why gemm `a_span`/`b_span` did not twin.

### Purpose

Const-seed generate indices; do not over-refuse emit on generate-if locals.

### Mutations

None at measure. Emit twin is A44.

### Behavioural study

```systemverilog
for (genvar i = 0; i < N; i++) begin : g
  // i is Const here. i*DATA_W is Const∘Const = 0, not Mul.
  assign slice[i] = word[i*DATA_W +: DATA_W];
end

if (ReuseBEn) begin : gen_reuse_b
  assign b_span = ...; // claimable origin; twin only if a matching assign
                       // with same LHS **and** RHS exists in the twin block
end
```

Fixtures: `fixtures/parse/genvar_lattice.sv`,
`fixtures/auto_correct/twin_generate_span.sv`, `gemm_span.sv`.

---

## A13 — Comb-for unroll

**Implementation.** delay-v16; comb-for handling in lower/expr seed.

### Summary

`always_comb for (int unsigned w = 0; w < N; w++)` is unrolled by synthesis.
The index is Const in the body. `w * SETS` is not a datapath Mul.

### Low-level basics

Unlike genvar, this is a procedural for with an automatic integer. Synthesis
unrolls when bounds are constant. The measurement treats the index as Const
in the body so the loop does not become `N` serial muls.

### High-level basis

A scale loop that builds a mux tree should be billed as the mux tree (exclusive
or dense), not as `N * 56`. LZC and hpdcache-style index muxes depend on this.

### Purpose

Stop unrolled loops from looking like iterative multipliers.

### Mutations

None.

### Behavioural study

```systemverilog
always_comb begin
  y = '0;
  for (int unsigned w = 0; w < N; w++) begin
    // w is Const. w*SETS is not Mul 56.
    if (sel == w) y = mem[w];
  end
end
// Prefer ExclusiveIfChain / dense: max arm + priority levels, not N muls.
```

Fixture: `fixtures/parse/comb_for_scale.sv`, `lzc_tree.sv`.

---

## A14 — NBA-as-Q (delay-v17)

**Implementation.** lowering / compose edges; IndependentLhsBundle can then
deflate sibling flops.

### Summary

In one `always_ff`, an NBA write sampled by a later read in the **same**
process is the Q of a flop (IEEE NBA schedule: writes take effect after the
process suspends). It is **not** a combinational edge.

### Low-level basics

IEEE: nonblocking assignments update in the NBA region, after the active
region. `q <= d; y <= q;` in one `always_ff` means `y` gets the **old** Q,
not the new D. There is no combo path D→y through that pair.

If the tool drew a combo edge NBA-write → later-read, sibling flops in one
process summed (20 FO4 of two 10 FO4 fields) instead of taking `max` as
IndependentLhsBundle / exclusive flop-D.

### High-level basis

This is the sequential dual of parallel timing. Parallel timing says
independent **combo** writes share a slot. NBA-as-Q says sequential writes
in one edge share a **clock**, not a wire. Bundle deflation is then legal.

### Purpose

Let 2-field flop captures (`mem_d.waiters`, `mem_d.nwait`) become exclusive
max-arm (path_class v24, 2 arms / 2 nodes) instead of Plain sum 20.

### Mutations

None. Measurement.

### Behavioural study

```systemverilog
always_ff @(posedge clk_i) begin
  mem_d[idx].waiters[w] <= mem_d[idx].waiters[w] >> 1; // shift
  mem_d[idx].nwait      <= mem_d[idx].nwait - (IDX_W+1)'(1);
end
// delay-v17: no combo edge between the two NBAs.
// v24 exclusive flop-D: 2 arms, mux=0, leftover=0 → max_arm ≤ 10, UnderBudget.
// Pre-v24: nodes<4 / arms<3 → Plain sum 20. Soak v24 primary became l2_mshr 20.
// v24 + v27 soak: l2_mshr 20 gone.
```

Fixture: `fixtures/measure/always_ff_nba_bundle.sv`, `nba_vs_blocking.sv`.
Test: `exclusive_flop_capture_two_arms_is_max_not_sum`.

---

# Part III — Path geometry and classification

## A15 — Attribute costs

**Implementation.** `attribute_costs` in `measure.rs`.

### Summary

The measure kernel. For every node: if `fo4_locked`, skip; else seed+genvar,
then parsed `rhs_expr` critical cost (authoritative even at 0), else
`op_class` base, with a guard that bare `*`/`/` without RHS/LHS (genvar
index math) is Other×2 not Mul/DivRem. Sum into regions and paths. Then tag
multi-cycle, classify, tag P10, fill parallel timing, fill cleanliness,
refresh primary locs, build `pass_plan`.

### Low-level basics

Order is load-bearing:

1. Node costs (lattice, billed class).
2. Path raw sums.
3. `tag_multi_cycle_paths`.
4. `classify_and_adjust_paths` (replaces `total_fo4` with adjusted).
5. `tag_handshake_locks` (class_note only).
6. `fill_design_parallel_timing`.
7. `fill_design_cleanliness`.
8. `refresh_primary_locs`.
9. `plan_from_design`.

A later pass that “just wants costs” and skips classify will see statement-order
ghosts and will InsertReg exclusive muxes.

`fo4_locked` exists so a spine split that created two nodes from one assign
does not get re-parsed as the original full expression on remeasure.

### High-level basis

Attribute is the **reduction** from trees to scalars. Classification is the
**reinterpretation** of those scalars. Cleanliness is the **choice of tools**.
The pass loop is the **application**. Mixing these layers (e.g. using raw
sums in S4) is the historical 645-InsertReg soak.

### Purpose

One function that leaves a design ready to rank and correct.

### Mutations

IR node `fo4_cost` / `op_class`; path `total_fo4` / slack / class; design
side tables. Not source.

### Behavioural study

```systemverilog
assign y = a * b + c;
// Node: parsed tree, billed Mul 56 + Add (max) → ~66, dominant Mul.
// If this is the only node and 66 > B: AtomicOverBudget, adjusted 56 (A25).
// InsertReg refused. T3 card. S5 reports it.
```

---

## A16 — Compose launch→capture (P5)

**Implementation.** `compose_reg_to_reg_paths` in `measure.rs`.

### Summary

Continuous-assign / `always_comb` regions are **fragments**. The period path
is flop → combo cloud → flop (or in→reg / reg→out). Compose walks comb defs,
seq LHS, seq reads, builds def-use edges, and emits new `TimingPath`s tagged
`P5 composed launch-capture`.

### Low-level basics

Per module:

- Seq defs: NBA (and seq) LHS bases in `always_ff`.
- Comb ids: `always_comb`, continuous, **and blocking temps in always_ff**.
- Comb defs: LHS → node id.
- Edges: comb read of a comb def → `(src, dst)`.
- `reads_reg` if a comb node reads a seq LHS.
- Sinks: comb LHS that a seq process reads, or that is an output.

For each sink, `longest_comb_path` backward through comb ids. Skip if that
node list already exists. Launch if any node `reads_reg`; capture if sink LHS
is seq-read. Else input/output endpoints.

**Intoout is not a 4 GHz flop primary.** `frequency_closure` splits
`intoout_failing` vs `regtoreg_failing`. S4 `admits_insert_reg` does not
care about path_kind directly, but `is_resilient_datapath` **requires**
`PathKind::RegToReg`. An intoout 56 FO4 mul is not resilient.

### High-level basis

Without compose, the tool optimizes `assign y = a+b` as if it were a clock
constraint. With compose, `q1 → (a+b) → q2` is the object S4 may cut.
P5 is measurement correction (delay-v6): it **adds** paths, it does not
reduce FO4. A soak that “gained” by dropping intoout from the headline is
P5 hygiene, not an algorithm win.

### Purpose

Rank the cones that have to fit \(B\).

### Mutations

New paths on the design. Fan-in/fan-out on comb nodes. `reads_reg` flags.

### Behavioural study

```systemverilog
always_ff @(posedge clk_i) q1 <= in_i;
assign t = q1 + k;          // fragment
assign y = t ^ m;           // fragment
always_ff @(posedge clk_i) q2 <= y;

// Composed RegToReg: nodes {t, y}, launch q1, capture q2.
// Raw: 10 + 1 = 11. P6 shallow. S4 may InsertReg after t:
//
// - assign t = q1 + k;
// - assign y = t ^ m;
// + logic [31:0] pipe;
// + always_ff @(posedge clk_i) pipe <= t;
// + assign y = pipe ^ m;     // if the cut is after t; latency +1
//
// Intoout in_i→y_o without flops is P5, not S4-resilient.
```

---

## A17 — Primary locus = hottest node

**Implementation.** `refresh_primary_locs` in `measure.rs`.

### Summary

`primary_loc` is the highest-FO4 node on the path, ties broken toward
Mul/DivRem. Not the last statement in the region.

### Low-level basics

Historical bug: soak traces blamed `default: state_d = ST_IDLE` for a 56 FO4
MMA multiply and `early_out_valid_o` for the fpnew FMA product, because lower
kept the last statement. Emit then rewrote the **wrong line** (M7).

Atomic tie-break: when two nodes share the max cost, prefer Mul/DivRem so
the origin comment points at the operator T3 cares about.

### High-level basis

Origin is a **resource**. Wrong origin + InsertReg = functional damage or a
no-op rewrite that leaves the hot operator in the period. BalanceMux injects
at the origin process for the same reason (gemm `stc_elem_q` comment shift,
v22).

### Purpose

Make emit and humans look at the same gate.

### Mutations

`path.primary_loc` only.

### Behavioural study

```systemverilog
always_comb begin
  unique case (state_q)
    ST_MUL: acc = a * b;     // 56 FO4 — must be primary_loc
    default: acc = '0;       // last statement — must NOT be primary_loc
  endcase
end
```

---

## A18 — Multi-cycle tagging

**Implementation.** `tag_multi_cycle_paths` in `measure.rs`; name heuristics
in `cone_lane.rs`; class `MultiCycleTagged`.

### Summary

Iterative dividers, SRT, already-pipelined FPU slices, and explicitly
multi-cycle paths are excluded from the single-cycle primary worklist.
Classification may still **deflate** exclusive/dense insides so reports show
max-arm FO4 rather than a 4560 statement-order sum (`control_mvp`).

### Low-level basics

`path.multi_cycle` is set by taggers (function names, region comments,
relocation soft-MC, module names `vfdsu` / `srt_radix` / `serdiv` / …).
Classify short-circuits to `MultiCycleTagged` (or `AtomicOverBudget` if a
lone mul still dominates). `discourages_insert_reg` is true.
`ConeLane::IterativeArith` / `PipelinedUnit` / `AtomicMul`.

S4 `admits_insert_reg` returns false. Cleanliness prefers
`MulticycleHonest`. S5 counts these as T3 asks.

### High-level basis

InsertReg on an SRT iteration is a functional lie (it changes the iteration
interval). InsertReg on fpnew that already has `NumPipeRegs` fights the
unit's own pipeline. The algorithm is: **measure honestly, do not cut,
report N = ceil(FO4 / B)**.

### Purpose

Stop the 181-InsertReg vfdsu spray.

### Mutations

Flags and class, not RTL. T3 is suggest-only.

### Behavioural study

```systemverilog
// serdiv: one iteration per cycle by construction. multi_cycle = true.
always_ff @(posedge clk_i) begin
  if (start) r <= {a, b};
  else       r <= {r_shift, q_bit};  // do NOT InsertReg this
end
```

---

## A19 — Reference-order tree

**Implementation.** `crates/sv-timing-core/src/ref_order.rs`.

### Summary

IR statement order is not silicon depth. The ref-order tree records, per
variable, writes, reads, forward-reads (true comb dep), and reads-before-write.
Write-only next-state and port assigns stay parallel. Only forward write→read
edges serialize.

### Low-level basics

`ident_base` strips `[...]` so `rdata[31:0]` and `rdata` share a name
(clint 114 FO4 split-LHS bug). `VarRefCount::is_write_only` iff writes > 0
and forward_reads == 0. `procedural_depth` and `write_only_lhs` feed lanes:
many write-only → `NextStateFsm`.

Calls get `CallRefCount` (name + param uses) so parallel timing can charge
callee makespan.

### High-level basis

This is the **use-def** analysis the rest of timing pretends it had. Exclusive
detectors group by LHS base. Independent-LHS counts distinct bases.
Handshake walks idents through this base. Compose uses the same `ident_base`.

If you add a detector that still sums statement order, you have ignored this
file.

### Purpose

Tell parallel timing and class detectors which edges are real.

### Mutations

None. Analysis structure.

### Behavioural study

```systemverilog
always_comb begin
  a_d = a_q + 1;     // write-only if nothing later reads a_d in this process
  b_d = b_q ^ in_i;  // write-only
  y   = a_d ^ b_d;   // forward reads a_d and b_d — serializes after both
end
// Tree: a_d, b_d independent; y waits max(C(a_d), C(b_d)).
```

---

## A20 — Parallel-timing scratchboard

**Implementation.** `crates/sv-timing-core/src/parallel_timing.rs`.

### Summary

ASAP/ALAP schedule on the ref-order tree. Independent ops share a time slot
(max). True deps serialize (sum). Makespan \(M = \max C(s)\). JIT cycles
\(N = \lceil M / B \rceil\). `always_ff` boards are clock-aware (`ClockDomain`).

### Low-level basics

\[
\begin{aligned}
L(s) &= \mathrm{fo4\_cost}(s) \quad\text{(callee makespan if known)} \\
S(s) &= \max \{\mathrm{ready}(v) \mid v \in \mathrm{reads}(s)\cup\mathrm{preds}(s)\} \\
C(s) &= S(s) + L(s) \\
\mathrm{ready}(v) &= C(\mathrm{writer}(v)) \\
M &= \max_s C(s) \\
N &= \lceil M / B \rceil
\end{aligned}
\]

ALAP from \(M\) exposes slack. A JIT cut is justified only on a critical
(\(\mathrm{slack}=0\)) op whose \(C(s)\) crosses \(kB\).

`classification_scratch` in `path_class.rs` builds this board for a path's
nodes and **invalidates** `procedural_ok` if a forward edge originates in an
`always_ff` sequential node (NBA-as-Q: do not treat Q as a combo producer).

Functions: every declared or called name gets `FunctionTiming` so `$clog2`
is not free and a user function adds callee delay.

### High-level basis

This is the theoretical core of “statement order is a ghost.” It is used
twice: (1) as a **detector** (`try_parallel_timing`) that may replace raw
sum with \(M\); (2) as a **report** on every module (`fill_design_parallel_timing`)
so cleanliness and humans see cycle counts.

It does **not** by itself InsertReg. S4 still needs a Plain resilient path
and an origin. A makespan of 18.5 with cycles=2 on gemm `b_span` is the
scratchboard saying “this cone is two budget-slots deep” — which is exactly
one InsertReg **if** the class is Plain and the origin is the span assign.

### Purpose

Replace serial ghosts with a schedule. Justify JIT cuts.

### Mutations

Fills `design.parallel_timing`. Does not rewrite RTL.

### Behavioural study

```systemverilog
always_comb begin
  t0 = a + b;     // L=10, S=0, C=10
  t1 = c + d;     // L=10, S=0, C=10   (parallel)
  y  = t0 ^ t1;   // L=1,  S=10, C=11
end
// Raw sum 21. Makespan 11. At B=10, N=2. One JIT cut before y closes.
//
// - assign y = t0 ^ t1;
// + always_ff @(posedge clk_i) p <= t0 ^ t1; // or cut t0/t1
// (only if Plain RegToReg, not exclusive, not handshake)
```

---

## A21 — Path classification (detector 24)

**Implementation.** `classify_and_adjust_paths` in `path_class.rs`.

### Summary

Post-emptive. Cheap exits first (multi-cycle, under-budget). Then expensive
detectors on the rest. First meaningful reduction wins (deflate_or_raw).
Hints from cache reuse a signature (`v24|module|r|n|lhs histogram`).

### Low-level basics

Signature includes **detector version**, so bumping 23→24 invalidates cache
hits (required: 2-arm exclusive flop-D).

Cheap exits:

- `multi_cycle`: keep Atomic if lone mul; else deflate exclusive/dense but
  **class stays MultiCycleTagged**.
- `raw ≤ B`: `UnderBudget`, no expensive scan.

Expensive (order matters inside `deflate_or_raw`): exclusive shared-LHS,
independent-LHS bundle, dense control, parallel-timing, atomic (atomic is
also a cheap-ish special: only `nodes==1`).

Adjusted FO4 **replaces** `path.total_fo4`. Raw is stored in
`total_fo4_raw` / exception. Slack is recomputed from adjusted.

### High-level basis

Classification is a **typed measurement**. Plain means “we could not prove a
better model.” Every other kind is a proof with confidence and evidence.
S4 trusts Plain. S3 trusts exclusive/bundle/dense. T3 trusts atomic.
If you weaken a detector to make a leftover Plain so S4 will cut it, you
are punching a hole in the type system — v28 did the dual (cut non-primary
Plain cones) and lost 12 FO4 on emit.

### Purpose

Make later algorithms simple: they switch on kind instead of re-deriving
mux vs chain.

### Mutations

Path class and FO4. Exception log.

### Behavioural study

See A22–A26. Detector version history that matters at 4 GHz:

- v22–v23: next-state wire=0, no log2 overwrite mux on `_d`.
- v24: exclusive flop-D allows **2 arms / 2 nodes** (l2_mshr). Unique-case
  mux tax = `model.mux` not \(\log_2 n \times\) mux. Leftover serial ghost
  dropped.

---

## A22 — Exclusive-case / exclusive-if

**Implementation.** `try_exclusive_shared_lhs` in `path_class.rs`.

### Summary

Many writes to one LHS are a mux, not a sum. Cost ≈ \(\max(\mathrm{arm}) +
\mathrm{mux}\). Unique-case mux = `model.mux` (2.5). Priority-if mux =
`priority_mux_per_level * n`. Flop D/Q (`*_d` / `*_q`) mux = 0 and leftover
= 0: the unique-case **is** the D pin.

### Low-level basics

Match:

- ≥ 3 arms on one LHS, **or** flop-capture with ≥ 2 arms (v24).
- Those arms ≥ 45 % of raw FO4.

Prep: sibling fields are parallel (flop-D: `other_field_max` only; else
`other_field_max + concat`). Uncategorized tax is tiny and **zero** on
flop-capture. Leftover `(raw − Σ arm)` is **always 0** as of v24 (it was a
serial ghost: dram_timing leftover 2.6 at dominance 0.48).

`lhs_is_flop_capture`: `_d` via `lhs_is_next_state` **or** `_q`. `_q` is
intentionally **not** in `lhs_is_next_state` globally — tagging gemm NBA
`_q` as a next-state bundle would skip IndependentLhsBundle-skip-on-compose
and starve S4 InsertReg on gemm. Exclusive of a single `_q` result is still
a flop D.

Refuse if adjusted ≥ 92 % of raw (no meaningful reduction).

### High-level basis

A `unique case` is one-hot AND-OR. The selected arm's delay plus one mux
level is the silicon path. Summing arms is counting **mutually exclusive**
gates as series. At \(B=10\), \(\log_2(7)\times 2.5 \approx 7\) of mux tax
on a max_arm that is already 10 left timer / l2_mshr at 18 FO4 **after**
the real logic closed. v24's `model.mux` (or 0 on flop-D) is the theory
correction.

Priority `if/else if` **is** a chain. It keeps per-level tax.

### Purpose

Deflate exclusive muxes so S3 BalanceMux sees residual select, not a fake
56 FO4 sum, and so S4 does not pipeline a case.

### Mutations

Adjusted FO4 only. BalanceMux (A37) may then rewrite the select tree.

### Behavioural study

```systemverilog
unique case (sel)
  2'd0: rdata_d = mem0;
  2'd1: rdata_d = mem1;
  2'd2: rdata_d = mem2;
  default: rdata_d = '0;
endcase
// *_d flop capture, 4 arms, mux=0, leftover=0 → max_arm.
// If max_arm ≤ 10, UnderBudget after classify.

// - raw = sum of arms (e.g. 4*10 = 40)  [statement order]
// + adj = max_arm + 0                  [v24 flop-D]
```

Tests: `exclusive_case_reduces_sum_of_arms`,
`exclusive_flop_capture_is_max_arm_not_mux_plus_leftover`,
`exclusive_flop_capture_two_arms_is_max_not_sum`,
`exclusive_parallel_prep_lhs_not_serial_residual`.

---

## A23 — Independent-LHS bundle

**Implementation.** `try_independent_lhs_bundle` in `path_class.rs`.

### Summary

Many distinct LHS in one process: silicon evaluates independent assigns in
parallel. Cost ≈ \(\max(\mathrm{field}) + \mathrm{wire}\). Next-state `_d`
bundles drop wire tax and log-mux overwrite tax (max_field only).

### Low-level basics

Match: `nodes ≥ 6`, `n_lhs ≥ 4`, writes cover ≥ 50 % of nodes, **not** a
pure exclusive result-mux (one LHS owns ≥ 50 % of writes and ≥ 3 writes).

Per-field: max write FO4; if **not** next-state and a field is written ≥ 3
times, add `mux * log2(writes)`. Next-state overwrites are exclusive flop-D
arms (prefetcher `pf_addr_d` was 10+log2(7)*2.5=17 before v22).

Wire: 0 if next-state; else `other * log2(n_lhs) * 2`. Core: `max_field` if
next-state (makespan through shared temps is **not** the capture delay —
coherence_hub 67-node 30 FO4 makespan vs max_field 10); else
`max(makespan, max_field)`.

Thresholds **miss 2-field FSMs** (`dm_sba` `state_d` + port, n_lhs=2,
nodes sometimes < 6). Those stay Plain 12 and look like S4 work; they are
usually next-state and should be max_field (Part VII addition C). Do **not**
add `_q` to global `lhs_is_next_state` to catch them — that starves gemm S4.

### High-level basis

An `always_comb` that assigns 12 `_d` fields of an FSM is 12 D pins, not a
12-stage pipeline. Statement order is the author's narrative. The bundle
detector is the compiler saying “these writes do not feed each other.”

### Purpose

Stop InsertReg spray on FSM next-state (axi_adapter, prefetcher, hub).

### Mutations

Adjusted FO4. Lane may become `NextStateFsm` if write-only ≥ 4.

### Behavioural study

```systemverilog
always_comb begin
  a_d = a_q;
  b_d = b_q;
  c_d = c_q;
  d_d = in_i;
  unique case (st)
    S0: a_d = in_i;
    S1: b_d = a_q + 1;
    default: ;
  endcase
end
// n_lhs ≥ 4, next_state: adj = max_field, wire=0.
// Do not InsertReg a_d.
```

Test: `next_state_multi_write_field_is_max_not_log_mux`.

---

## A24 — Dense control cone

**Implementation.** `try_dense_control_cone` in `path_class.rs`.

### Summary

≥ 16 modest nodes, no dominant exclusive LHS, no heavy mul. Delay ≈
makespan (or max_node if next-state) + select/wire tax (0 if next-state).

### Low-level basics

Refuse: n < 16; exclusive would match (≥3 arms on one LHS and those arms
≥ 45 % raw); max node ≥ 45 % raw (that's a heavy-op path); any Mul/DivRem
node ≥ 40 FO4; average node > 12; scratch not procedural_ok; adjusted ≥
88 % raw.

Next-state: select=0, wire=0, core=max_node. Else select = mux * log2(n)
(min 2), wire = other * log2(n), core = max(makespan, max_node).

### High-level basis

Fat FSMs (axi2mem WRITE, n=39) are dense control, not gemm datapath. Even
if classify leaves them Plain, `is_resilient_datapath` refuses `nodes ≥ 16`
without an over-budget Mul/DivRem on the cone (A32). InsertReg on a wrap
FSM is a protocol break; InsertReg on a 39-node control cone is a latency
bomb.

### Purpose

Deflate control; keep S4 off fat FSMs.

### Mutations

Adjusted FO4.

### Behavioural study

```systemverilog
always_comb begin
  st_d = st_q;
  // 20+ small compares and assigns, no single hot mul
  if (aw_valid) st_d = W;
  if (w_last)   st_d = I;
  // ...
end
// Dense: makespan + tax, or max_node if *_d next-state.
```

---

## A25 — Atomic-over-budget

**Implementation.** `try_atomic_over_budget` in `path_class.rs`.

### Summary

**Atomicity is a node property.** A lone Mul/DivRem node \(> B\) is
`AtomicOverBudget`. A 117-node path with one mul is **not** — branding the
whole path atomic suppressed remainder cuts (P4, cache_ctrl / wt_axi_adapter
in audit-strict-v4). Adjusted FO4 is the operator cost, not the enclosing
serial sum.

### Low-level basics

`hottest_over_budget_atomic` finds the worst Mul/DivRem \(> B\). If
`nodes.len() > 1`, return None (P4: do not brand). If `nodes.len() == 1`,
adjusted = that cost, confidence 0.95.

`schedule_pipeline_cuts` also refuses a **leading** Mul/DivRem \(> B\) even
on multi-node paths (cannot shorten a 56 FO4 first node by cutting after it
into the same period). Remainder adds **after** a mul that already fits can
still be cut if the path is Plain.

### High-level basis

T3: \(N = \lceil 56 / 10 \rceil = 6\) (or the unit's own `NumPipeRegs`).
Auto-correct must not pretend a register around a multiplier is a 10 FO4
mul. PrepStage (A42) may stage **operand prep** in front of the mul if the
prep itself is the leftover; it must not split the mul.

### Purpose

Honest mul/div. Enable remainder cuts on mixed paths (P4).

### Mutations

Class + adjusted FO4. Relocation `ArchMulticycle` / `SoftMulticycle`.

### Behavioural study

```systemverilog
assign p = a * b;          // 1 node, 56 > 10 → AtomicOverBudget. T3.

always_comb begin
  t = a * b;               // 56
  y = t + c;               // 10
end
// nodes>1 → NOT AtomicOverBudget (P4).
// Leading mul > B → schedule_pipeline_cuts refuses.
// Remainder +c cannot be pulled into the same cycle as the mul at B=10.
```

---

## A26 — Parallel-timing deflation

**Implementation.** `try_parallel_timing` in `path_class.rs`.

### Summary

If exclusive/bundle/dense did not match, but the scratchboard makespan is
meaningfully below the serial sum (`adj < 0.85 * raw`, nodes ≥ 4,
procedural_ok), replace FO4 with makespan.

### Low-level basics

This is the last deflator before Plain. Gemm leftover `n4|b_end:1,b_span:1,
disjoint:1,k_bytes:1` has makespan=18.5, cycles=2 — **not** below 0.85 of
a serial 18.5, so it stays Plain 18.5. That is correct: the span→end add
**is** serial.

### High-level basis

Use the schedule when we have no stronger type. Do not use it to hide a
real chain.

### Purpose

Catch parallel clouds that are not quite bundles (n_lhs < 4, etc.).

### Mutations

Adjusted FO4; class may remain Plain with a class_note.

### Behavioural study

```systemverilog
assign t0 = a ^ b;
assign t1 = c ^ d;
assign t2 = e ^ f;
assign y  = t0 | t1 | t2;
// Serial sum ~4. Makespan ~3 (two LogicBit levels). If raw is a long
// statement-order chain of independent xors, makespan wins.
```

---

## A27 — Handshake lock (P10)

**Implementation.** `path_is_handshake_locked`, `handshake_locked_names`,
`tag_handshake_locks` in `pass_strategy.rs`.

### Summary

Same-edge pulse + index/data handshake. Never InsertReg. Two or more
**distinct** output-driving NBAs in one `always_ff` with at least one
pulse-like RHS, plus consumer `assign out = mem[port]` of an indexed-NBA
base.

### Low-level basics

Producer: in each `always_ff`, collect NBAs whose LHS drives an output
(directly or via `assign out = q` alias). Pulse RHS = ident/literal, or
unary `!`/`~` of that, or LogicBit of pulses — **no** `+` `*` `/` `?`.
Lock if `distinct_lhs ≥ 2` **and** `has_pulse`. Reset+data of **one** Q
(`y_o <= 0` / `y_o <= c_span`) is two nodes, same LHS — **not** a handshake
(gemm_span capture flops).

Consumer: continuous/blocking `out = mem[port]` (ternary
`empty ? 0 : mem[port]` walks `?:` via `index_mem_base` /
`index_ident`). Indexed NBA bases from LHS containing `[` or index expr.

Locked names include pulse LHS, data/index LHS, their feeds, aliases, the
mem base, the port, the consumer LHS. A path that touches any locked name
is P10.

`tag_handshake_locks` only writes `class_note`. `admits_insert_reg` refuses
on that note. Exception policy: real P10 and indexed restore are
`HandshakeLock`. Incidental P10 **note** on a gemm-shaped cone yields to
resilient only at \(\ge 2B\) (A32).

### High-level basis

A valid pulse and the indexed data it qualifies are **same-cycle**. A
register on `fifo_q[head]` or on `switch_i` makes the consumer sample last
cycle's beat. SMT2 `g6lc_thread_select` / `g6lc_smt_pc_bank` one-cycle
switch is the same pattern: InsertReg is a functional break. The package
must not hardcode `g6lc_*`; the detector is structural.

### Purpose

Refuse S4 on handshakes. Keep SMT2 / FTQ / inval_bus correct.

### Mutations

class_note; lane `NextStateFsm` when locked and not resilient.

### Behavioural study

```systemverilog
// Producer handshake (distinct LHS, pulse + index).
always_ff @(posedge clk_i) begin
  valid_o <= valid_i;          // pulse-like
  idx_o   <= head;             // other output NBA
end
assign rdata_o = mem[idx_o];   // consumer restore

// - InsertReg on idx_o or on rdata_o  [functional break]
// + leave; P10; T3/microarch if 16 FO4 must close (g6lc_inval_bus leftover)

// NOT P10: same LHS reset+data.
always_ff @(posedge clk_i) begin
  if (!rst_ni) y_o <= '0;
  else         y_o <= c_span;
end
```

Fixtures: `fixtures/measure/handshake_switch.sv`,
`ternary_indexed_restore.sv`. Test:
`p10_ternary_indexed_restore_refuses_insert_reg`.

---

## A28 — Indexed restore

**Implementation.** `path_has_indexed_restore` in `pass_strategy.rs`.

### Summary

Comb `out = mem[port]` of a base that is also NBA-written indexed (FTQ head,
SMT2 pc_bank). Always `HandshakeLock`, even if the producer pulse detector
missed.

### Low-level basics

If any path node is continuous/blocking, has an index ident, and
`index_mem_base` is in `indexed_nba_bases`, the path is an indexed restore.
Ternary restore supported (A27).

Exception policy checks this **first**, before resilient.

### High-level basis

`mem[port]` in the same cycle as the NBA to `mem[i]` is a read-after-write
to a flop array **or** a same-edge bypass. A pipeline register on that
select adds a cycle to every dequeue. That is not 4 GHz closure; that is a
new protocol.

### Purpose

Hard refuse. Lane NextStateFsm.

### Mutations

None to RTL.

### Behavioural study

```systemverilog
always_ff @(posedge clk_i) begin
  if (push) fifo_q[tail] <= data_i;
  if (pop)  head <= head + 1;
end
assign rdata_o = empty ? '0 : fifo_q[head];
// index_mem_base walks ?: → fifo_q. Indexed NBA base fifo_q. Restore. P10.
```

---

## A29 — Pattern catalog P1–P10

**Implementation.** `PatternId`, `classify_path`, `plan_from_design` in
`pass_strategy.rs`.

### Summary

A pre-pass **diagnosis** of every path. Artifacts (P1, P2) abort correct.
Gaps (P3–P7, P10) choose tools. Real work (P8, P6 remainder) is S4. Iterative
(P9) is S5.

### Low-level basics

| Id | Meaning | Correct? |
|---|---|---|
| P1 | hottest expr is Const but billed as hardware | **abort** |
| P2 | comment billed as arithmetic | **abort** (collect-time) |
| P3 | `nodes ≤ 1` over budget, not MC | uncuttable; T3 if atomic |
| P4 | whole path labelled atomic because one node is | detector now refuses; remainder may cut |
| P5 | intoout fragment counted as period | compose; intoout ≠ primary |
| P6 | \(B < \mathrm{FO4} < 2B\), nodes>1, not atomic | one register or one rebalance |
| P7 | IndependentLhsBundle still over budget | do not serial-cut; S3 |
| P8 | genuine deep datapath (runtime, often atomic 1-node) | T3 or resilient S4 if Plain multi-node |
| P9 | multi-cycle tagged | do not cut |
| P10 | handshake / indexed restore | never InsertReg |

`classify_path` can return **multiple** ids. `is_shallow_over_budget` is the
P6 predicate used to sort S4 work (resilient first, then shallow, then
monsters).

`plan_from_design` only **aborts** on artifacts. Other counts are the
rationale string. S0 is “do not spend edits on logic that does not exist”
(audit-strict-v4 spent hundreds of edits for a 0.0 emitted delta).

### High-level basis

The catalog is a **triage protocol**. Maintainers should be able to look at
a leftover and name its P-id before touching S4. If you cannot name it, you
are about to spray.

P6 is 75 % of corpus failures at 4 GHz: one extra mux or one extra add over
\(B\). The right tool is **one** InsertReg or **one** BalanceMux, origin
re-anchored, then stop. P8-shaped gemm 161.5 was the deep exception that
needed several S4 cuts; after those, the 18.5 sibling is P6 again.

### Purpose

Abort on lies; schedule S1–S5 on truths.

### Mutations

None at plan time. The plan only gates the loop.

### Behavioural study

```systemverilog
// P1 artifact — abort, do not pipeline.
assign w = CVA6Cfg.XLEN + CVA6Cfg.VLEN;

// P6 shallow Plain RegToReg — one cut.
assign t = q1 + k;     // 10
assign y = t ^ m;      // 1  → 11, nodes=2, 10<11<20

// P10 — refuse.
assign rdata_o = fifo_q[head];
```

---

## A30 — Cone lanes

**Implementation.** `crates/sv-timing-core/src/cone_lane.rs`.

### Summary

A **view** over class + module + handshake. Only `CombDatapath` allows
InsertReg. Comb exploration (BalanceMux/split) stays on exclusive, next-state,
datapath, pipelined, even atomic (prep). Screening and iterative drop out of
the primary worklist.

### Low-level basics

Derivation order:

1. Module name `_sva` / `_bind` → Screening.
2. Class AtomicOverBudget → AtomicMul.
3. multi_cycle / MultiCycleTagged / iterative names → IterativeArith.
4. fpnew_* names → PipelinedUnit.
5. `lzc` prefix-tree names → ExclusiveMux (a flop here adds latency to every
   consumer).
6. Indexed restore, or handshake **and not** resilient → NextStateFsm.
7. ExclusiveCase/If → ExclusiveMux.
8. IndependentLhs / Dense: write-only ≥ 4 or procedural_depth 0 →
   NextStateFsm, else ExclusiveMux.
9. UnderBudget / Plain → CombDatapath.

`allows_insert_reg` is **only** CombDatapath. Exception policy can still
admit InsertReg on a path whose module cleanliness forbade it; the lane
must also be CombDatapath or the apply-time gate will refuse. Resilient
gemm is Plain → CombDatapath. Incidental-P10 gemm that is resilient stays
CombDatapath because step 6 requires `!is_resilient_datapath`.

Prefix-tree / FPU / lzc names are **string** heuristics on module name.
KD0: no host path hardcoding, but structural names like `lzc` are in-tree
IP. Do not add `g6lc_*` special cases; add structure.

### High-level basis

Lanes compartmentalize so one InsertReg cascade cannot starve comb /
exclusive / atomic / iterative cones. They are the 4 GHz worklist router.

### Purpose

Gate transforms without changing measurement.

### Mutations

None. Pure function of design+path.

### Behavioural study

```systemverilog
// lzc: ExclusiveMux lane even if Plain leftover. No InsertReg.
module lzc;
  // prefix OR tree
endmodule

// gemm span: Plain RegToReg > B, not handshake, not lzc → CombDatapath.
// Cleanliness may still pick seq_plus_comb; exception admits S4.
```

---

## A31 — Cleanliness catalog

**Implementation.** `crates/sv-timing-core/src/cleanliness.rs`.

### Summary

Per **module**, explore 8 algorithm sets, pick a working solution:
timing-passing sets first, then max cleanliness. Weights favour
`always_ff` / `always_comb` density; aggressiveness is a penalty; timing
fail is a larger penalty.

\[
C(s) = w_{\mathrm{ff}} D_{\mathrm{ff}} + w_{\mathrm{comb}} D_{\mathrm{comb}}
       - w_a A(s) - w_t \mathbf{1}[\neg\mathrm{pass}]
\]

Defaults: \(w_{\mathrm{ff}}=w_{\mathrm{comb}}=0.40\), \(w_a=0.20\),
\(w_t=0.50\).

### Low-level basics

Sets in aggressiveness order (stable tie-break prefers earlier / cleaner):

| Set | A | Tools |
|---|---:|---|
| ClassifyOnly | 0.00 | none |
| FfFactorClock | 0.10 | always_ff factorize |
| CombExclusive | 0.20 | BalanceMux |
| MulticycleHonest | 0.25 | MC tag |
| SeqPlusComb | 0.30 | factorize + BalanceMux |
| CombSplit | (next) | SplitAssign |
| JitDatapath | | InsertReg on CombDatapath |
| AggressivePipeline | 1-ish | multi-cut |

`allows_opportunity`: InsertReg only if `jit_reg || multi_cut`; SplitAssign
if comb_split/exclusive; BalanceMux if exclusive/ff_factor/comb_split.

**Module-global.** Mixed modules (exclusive leftover + gemm CombDatapath)
win `seq_plus_comb` and would refuse InsertReg on the datapath. That is
why exception policy exists (A32).

`explore_module` profiles region counts, exclusive/datapath/atomic flags,
failing primary count, “closes now.” Inapplicable sets score −∞.
Feasible = applicable ∧ timing_pass. Pool = feasible if nonempty else
applicable. Argmax C, then **lower** A, then set id.

### High-level basis

Cleanliness is an **optimization over tools**, not over FO4. It answers
“what style should this module keep?” A module that already closes should
stay ClassifyOnly. A muxy comb module should get BalanceMux, not
InsertReg. A failing datapath module should get JitDatapath. The solver
is allowed to pick a non-passing set if nothing passes; then S4 still
needs the path-level exception for gemm.

Because the winner is module-global, **do not** encode path-level nuance
here. Put it in exception policy. Do not lower cleanliness to “always
JitDatapath if any path fails” — that reintroduces InsertReg spray.

### Purpose

Pick the default tool set. Keep always_ff/always_comb as the aesthetic
(CVA6 style).

### Mutations

`design.module_cleanliness`. Pass loop reads `allows_opportunity`.

### Behavioural study

```systemverilog
// Module with unique-case only, already under budget after classify:
// winner ClassifyOnly or CombExclusive. No InsertReg.

// Module with always_ff FSM + always_comb exclusive + one gemm span:
// winner SeqPlusComb. Gemm path uses ResilientDatapath exception to
// InsertReg anyway. Exclusive paths stay S3.
```

---

## A32 — Exception policy

**Implementation.** `exception_policy`, `is_resilient_datapath`,
`path_has_burst_wrap`, `s4_has_pending_resilient` in `pass_strategy.rs`.

### Summary

Path-level override of the module cleanliness winner.

- Indexed restore → HandshakeLock, never InsertReg.
- Resilient datapath → admit InsertReg even if cleanliness is S3.
- Else real P10 / P10 note → HandshakeLock.

Resilient = Plain, RegToReg, nodes>1, FO4 > B, not MC, not atomic class,
not indexed restore, not real handshake, incidental P10 note only allowed
if FO4 ≥ 2B, not burst wrap, not fat FSM (nodes≥16 without over-budget
Mul/DivRem), not lzc/vfdsu/fpnew/fma/divsqrt/serdiv in the **module name**.

### Low-level basics

`path_has_burst_wrap`: RHS or LHS contains `wrap_boundary` or `WRAP`.
KD0: no host module name `axi2mem`; the token is the protocol.

Fat FSM: 16+ nodes and no Mul/DivRem node > B when module IR nodes are
present. Synthetic tests with empty `nodes` still match gemm-shaped
resilient (the wrap test uses a **separate** empty design for the 18.5
gemm assert so wrap node id 0 cannot poison gemm.nodes[0]).

`s4_has_pending_resilient` is **exported** and tested, but **not used** by
the S4 loop after the v28 revert. Using it to continue S4 while primary is
flat caused origin steal. See A49.

Incidental P10 class_note: a gemm cone that shares an `always_ff` with a
status pulse got tagged P10 (path 3131). At 161.5 FO4 (≥ 2B) it is still
resilient. At 15 FO4 it stays HandshakeLock. That split is load-bearing.

`admits_insert_reg` is the **default** gate (still refuses P10 notes).
S4 consults exception **first** for resilient, then admits_insert_reg.

### High-level basis

Exceptions are how a typed system admits a **known** hole without deleting
the type. Gemm is a CombDatapath living in a mixed module. Wrap is a Plain
cone that looks P6 but is protocol. Fat FSM is Plain by detector miss but
must not be pipelined. The predicates are structural; names are only the
lzc/FPU blocklist.

### Purpose

S4 gemm without S4 axi2mem / fifo restore / lzc.

### Mutations

None to RTL. Pass loop branching.

### Behavioural study

```systemverilog
// Resilient (gemm-shaped).
assign b_span = /* runtime span arithmetic, Plain, 4 nodes, 18.5 */;
assign b_end  = b_span + …;
// S4 may InsertReg despite SeqPlusComb winner.

// NOT resilient: WRAP.
assign nxt_addr = wrap_boundary + ((cnt_q - ax_req_q.len) << LOG);

// NOT resilient: fat FSM n=39 Plain.
// NOT resilient: fifo_q[head] restore.
```

Test: `resilient_skips_burst_wrap_and_fat_fsm`,
`resilient_exception_matches_gemm_shaped_plain_regtoreg`,
`resilient_exception_skips_p6_shallow_and_intoout` (note: P6 15 FO4 **is**
resilient unless P10-noted).

---

## A33 — Relocation T0–T3

**Implementation.** `crates/sv-timing-core/src/relocation.rs`.

### Summary

After classify, remaining failures get a **card** of scored options. Auto-correct
may attempt T0–T2. T3 is suggest-only.

| Tier | Meaning | Auto? |
|---|---|---|
| T0 | measure-only (class already relocated the number) | n/a |
| T1 | latency-neutral (BalanceMux, SplitAssign, rebalance, PrepStage) | yes |
| T2 | temporal pipeline (InsertReg, +latency) | if `--allow-latency` |
| T3 | architectural (NumPipeRegs, CVXIF offload, split process, arch MC) | no |

Patterns: ExclusiveSelect, AtomicOp, IndependentBundle, AssociativeChain,
PlainCone, MultiCycle, Closed, Unknown.

Worklist prefers `preferred_auto` on the card. Large atomic cards stay out
of InsertReg but still get PrepStage when that is the T1 option — otherwise
the biggest FO4 cards never participate.

### High-level basis

Relocation is the **strategy object** the pass loop used to lack. “InsertReg
everything over budget” is T2 applied to T0/T1/T3 problems. Cards make the
mismatch visible in JSON.

### Purpose

Order tools. Keep T3 human.

### Mutations

Plan JSON, not RTL.

### Behavioural study

```text
Card: gemm path 5048, Plain, 74.5 FO4
  T1 BalanceMux  — low score (not exclusive)
  T2 InsertReg   — preferred_auto if allow-latency
  T3 Arch MC     — if a node is Mul 56

Card: l2_mshr exclusive flop-D, 20 raw → 10 adj
  T0 MeasureRelocate — Closed after classify
```

---

## A34 — Optimization levels and dials

**Implementation.** `crates/sv-timing-core/src/opt.rs`.

### Summary

A level is **only** a preset over ten dials. It never relaxes a safety gate
(allowlist, refuse lists, `--allow-latency`, dry-run, emit containment).

| Level | passes | width | cut | stages | min_gain | slack_tgt | area | effort |
|---|---:|---:|---|---:|---:|---:|---:|---|
| O0 | 0 | 0 | cost-bal | 0 | 0 | 0 | 0 | fast |
| O1 | 2 | 1 | cost-bal | 0 | 1 | 0 | 0 | bal |
| O2 | 4 | 1 | cost-bal | 1 | 2 | 0 | 0 | bal |
| O3 | 16 | 4 | budget-fit | 8 | 1 | 0 | 0 | thorough |
| Os | 4 | 2 | budget-fit | 2 | 4 | −4 | 1 | bal |
| Oz | 2 | 1 | cost-bal | 0 | 1 | 0 | 0 | bal |

`allows_new_state` iff stages>0 and passes>0. `-O1`/`-Oz` are latency-neutral
by construction. `--allow-latency` remains a hard gate a level cannot relax.

Dial 4 > 1 implies BudgetFit unless the caller set a cut strategy. Multi-cut
cap in `select_pipeline_cuts` is `max_stages_per_region.clamp(1,16)` — soak
often sets 20 on the CLI which then clamps to 16.

`analysis_digest` includes only effort + cache_mode (what can change analyze).
Transform dials must not invalidate the analyze cache.

### High-level basis

Levels are **GCC-shaped** so a human can say `-O3` without listing dials.
The pass loop still interprets S3/S4 as `max(1, max_passes/2)` each. At
`-O3`, that is 8 + 8, not 16 of S4.

### Purpose

Presets. Soak of record uses `-O3` plus `--allow-latency` plus
`--real-cut-feeds` (implies BalanceMux RTL).

### Mutations

None to RTL.

---

## A35 — Worklist

**Implementation.** `crates/sv-timing-transform/src/worklist.rs`.

### Summary

Worst slack first, stable ties on file:line / path id. Optionally driven by
relocation cards. Skip multi-cycle by default.

S4 then **re-sorts**: resilient exceptions first, then P6 shallow, then
remaining, so a 144-node gemm is not starved by shallow-first (audit-gemm-rcf).
S4 also **re-attaches** resilient paths truncated off the T1-first card list.

### High-level basis

The worklist is a **priority queue over diagnosis**, not over raw FO4.
Atomic 56 should not crowd out P6 15 if the atomic cannot be cut. Resilient
18.5 should not lose to a 12 FO4 exclusive leftover.

### Purpose

Feed `apply_work_item` a deterministic sequence.

---

# Part IV — Transforms (what actually edits RTL)

## A36 — Clock-aware `always_ff` factorize

**Implementation.** `crates/sv-timing-transform/src/factor_always_ff.rs`.

### Summary

Review-only: comments + OpenSTA `report_timing` seeds from ParallelScratch
cycle bars on `clk_i`. Keeps sequential scratch. Does not change semantics.
Cleanliness `FfFactorClock` / `SeqPlusComb` enable the style; emit of
factorize is comments, not new flops.

### High-level basis

Factorizing `always_ff` by field groups is a **readability / STA seed**
transform. Putting those fields in separate processes does not reduce D-pin
FO4; it can help tools and humans. It is S1/S2 adjacent, not S4.

### Behavioural study

```systemverilog
// Review comment injected; NBA unchanged.
always_ff @(posedge clk_i or negedge rst_ni) begin
  // sv-timing: cycle bar clk_i period 0.25 ns, ops {state_q:1, acc_q:2}
  if (!rst_ni) begin
    state_q <= S0;
    acc_q   <= '0;
  end else begin
    state_q <= state_d;
    acc_q   <= acc_d;
  end
end
```

---

## A37 — BalanceMux

**Implementation.** `balance_mux_on_path` in
`crates/sv-timing-transform/src/pipeline.rs`; emit inject in
`crates/sv-timing-emit/src/lib.rs`.

### Summary

Latency-neutral exclusive/bundle rewrite: (A) stage a deep exclusive-arm
expression at the **origin process**, (B) hierarchical one-hot AND-OR select
tree, (C) sticky FO4 credit if RTL rewrite cannot land. Once per path.
`--real-cut-feeds` implies BalanceMux RTL (`PassPolicy.emit_structural`).

### Low-level basics

Refuse: already done on path; path not exclusive/bundle/dense (plain paths
try associative rebalance first and may return as BalanceMux); already under
budget.

Order: for **plain**, try `rebalance_associative_node` and return. For
exclusive shapes, skip early rebalance (it can shallow the tree so staging
refuses). Then hot-arm staging (origin RHS rewrite), then one-hot tree,
then credit.

**Origin process inject.** Snippets inject at the process that owns the
origin, not dumped at `endmodule`. Tests:
`balance_mux_snippet_injects_after_mid_module_decls`,
`balance_mux_snippet_injects_before_first_process`. Late decls use
`else begin` / own NBA line.

**Keep `assign`.** Continuous BM rewrite must not drop the keyword
(`te_packet_emitter` Parse fail, v21). Test:
`balance_mux_rhs_rewrite_keeps_assign_keyword`.

**BM before InsertReg.** InsertReg comments shift origin lines. v22 rewrote
`stc_elem_q` because a comment landed first. Test:
`balance_mux_rewrite_not_shifted_by_insertreg_comments`.

Sticky credit: if RTL cannot prove a win, record FO4 after on the path so
remeasure does not immediately re-queue the same mux.

### High-level basis

BalanceMux is T1: same-cycle, same protocol, shorter critical **arm**. It is
the correct tool for ExclusiveCaseMux leftovers, not InsertReg. At \(B=10\),
a 12.5 exclusive flop-D with mux tax was a detector bug (v24), not a missing
BalanceMux. Residual exclusive that is still > B after v24 is a hot **arm**
(prep add in the selected arm) — stage that arm, do not pipeline the case.

### Purpose

S3 default tool.

### Mutations

RHS rewrite and/or snippet wires + `always_comb` AND-OR. Credit on IR.

### Behavioural study

```systemverilog
// Hot arm staging (origin rewrite):
unique case (sel)
- 2'd0: y = a + b + c + d;     // arm 20+ FO4
+ 2'd0: y = y_hot;             // y_hot computed in parallel prep
  2'd1: y = x;
  default: y = '0;
endcase
+ // injected at origin process, not endmodule
+ logic [31:0] y_hot;
+ always_comb y_hot = a + b + c + d;  // still same cycle; tree balanced

// Continuous keep assign:
- assign y = sel ? a : b;
+ assign y = sel ? a_s : b;    // assign keyword preserved
```

---

## A38 — SplitAssign

**Implementation.** `split_assign` in `pipeline.rs`.

### Summary

Name an intermediate wire for a deep assign. Latency-neutral. Cleanliness
`CombSplit`. Useful when a single statement hides a chain that compose
already sees as multiple logical ops but emit cannot cut.

### Behavioural study

```systemverilog
- assign y = (a + b) ^ (c + d);
+ logic [31:0] t0, t1;
+ assign t0 = a + b;
+ assign t1 = c + d;
+ assign y  = t0 ^ t1;
// FO4 unchanged (still max+xor) unless a later InsertReg cuts t0/t1.
// Prepares A40.
```

---

## A39 — Associative rebalance

**Implementation.** `rebalance_associative_node` in `pipeline.rs`.

### Summary

Rewrite a left-deep `(((a+b)+c)+d)` into a balanced tree. Same operators,
shorter critical path in FO4 **levels**. `allow_reassoc` dial is **false**
on every preset (equivalence-unverified algebraic reshaping is opt-in).
BalanceMux may still rebalance **plain** hot nodes as a structured tree
change of the same operators.

### Behavioural study

```systemverilog
- assign s = a + b + c + d;          // left-deep: 10+10+10 = 30
+ assign s = (a + b) + (c + d);      // 10 + 10 = 20
// Still 20 > 10. Rebalance does not close a 4-add chain at B=10.
// S4 multi-cut would:
+ always_ff @(posedge clk_i) p <= a + b;
+ assign s = p + (c + d);            // +1 cycle, 10+10 with a register in between
```

---

## A40 — InsertReg and Leiserson–Saxe cuts

**Implementation.** `select_pipeline_cuts`, `schedule_pipeline_cuts`,
`insert_register` in `pipeline.rs`.

### Summary

The only transform that **adds state**. Requires `--allow-latency`. Walks
path nodes in order; when the open segment would exceed \(B\), cut after
the previous node (greedy budget-fit). Cap `max_cuts` from
`max_stages_per_region` clamped 1..16. Fallback: single mid-cut.

Refuse: multi_cycle; class `discourages_insert_reg` (except UnderBudget
which would not be here); empty path; total ≤ B; single-node atomic
Mul/DivRem; **leading** Mul/DivRem > B.

Per-module apply cap = `max_stages_per_region`. Module-diverse batch: one
InsertReg per module per pass, then remeasure (A47).

Residual capture keeps original `RegToReg` endpoints, not dummy
`OutputPort`.

### Low-level basics

Greedy fill (Leiserson–Saxe retiming **segmentation**, not full retiming):

```text
cum = 0
for i in nodes:
  if cum + cost[i] > B and i > seg_start:
    cut after i-1
    start new segment at i
  cum += cost[i]   # or reset to cost[i] after cut
stop at max_cuts
```

A path of `[8, 8, 8]` at B=10 yields cuts after node0 and node1 (segments
8 | 8 | 8), two registers, three cycles, each ≤ 10. A path of `[18.5]`
single-node non-atomic would take one capture cut (FO4 left 18.5, right 0)
— that **does not shrink** the operator; it only moves the sample. S4
still needs `nodes>1` for `admits_insert_reg` (P3). Gemm 18.5 has **4**
nodes: `k_bytes, b_span, b_end, disjoint`. `schedule_pipeline_cuts` **does**
place a cut when the **sum** > B even if no single node > B. The reason
S4 did not cut `b_span` is the **fixpoint**, not the scheduler (A48).

`insert_register` allocates a `pipe_*` name (`naming.rs`), records an
`EditRecord` with origin loc, new_name, kind InsertReg. Emit (A43) does
the source mutation.

### High-level basis

A register is a **time borrow**. It is legal iff the protocol can wait a
cycle. Handshake, WRAP next-address, SMT2 switch, indexed restore, and
prefix trees cannot. Plain gemm span math can (the C matrix tile is
already multi-cycle in the accelerator FSM). Cleanliness plus exception
plus lane plus P10 plus wrap lock are the **conjunction** that makes T2
safe.

Full Leiserson–Saxe retiming would move existing flops. This package does
**not** retime; it only **inserts**. That is why wrapping an adder that
feeds a same-edge handshake is illegal: there is no downstream flop to
borrow from.

### Purpose

S4 tool for P6/P8 Plain RegToReg.

### Mutations

New flop + origin LHS rewritten to sample the flop. Dense sidecar may
also hold a zero/lean feed.

### Behavioural study

```systemverilog
// Gemm c_end cut (v27 pass 4): 18.5 → 10
- assign c_end = c_span + …;
+ // origin rewrite
+ assign c_end = pipe_svt_p1_4;
+ always_ff @(posedge clk_i or negedge rst_ni) begin
+   if (!rst_ni) pipe_svt_p1_4 <= '0;
+   else         pipe_svt_p1_4 <= /* original c_end RHS */;
+ end
// Twin generate copied c_span onto gen_reuse_b when LHS+RHS matched.
// b_span RHS differs (n/ldb vs m/lda) — not copied. Left 18.5 primary.
```

---

## A41 — Cut strategies

**Implementation.** `CutStrategy` in `opt.rs`; used by `schedule_pipeline_cuts`
/ mid-cut fallback.

### Summary

| Strategy | Rule | Who uses it |
|---|---|---|
| MidNode | index midpoint, cost-blind | A/B only |
| CostBalanced | prefix-sum bisection, two segments | `-O1`/`-O2` |
| BudgetFit | greedy fill to \(B\) | `-O3`/`-Os`, multi-cut |

`-Os` uses BudgetFit because filling stages to the budget is **flop-minimal**.
What distinguishes `-Os` is high `min_gain`, tolerated residual overage
(`slack_target = -4`), and area-weighted ordering.

### Behavioural study

```text
nodes costs = [3, 3, 3, 3, 3], B=10, max_cuts=8
MidNode        → one cut after index 2
CostBalanced   → one cut where prefix ≈ total/2
BudgetFit      → cut after index 3 (3+3+3=9, next would be 12), one flop
                 leftover 6. Closes with 1 flop, not 2.
```

---

## A42 — Expression-spine expand

**Implementation.** `expand_expr_spine_for_path` in `pipeline.rs`;
`Expr::critical_spine_ops` in `expr.rs`.

### Summary

A single mega-assign IR node cannot be multi-cut (P3). Spine expand splits
the critical operator list into IR nodes (locked FO4) so budget-fit can
place registers between prep and a heavy root. PrepStage relocation uses
this even on soft-MC atomics **for the prep**, never to split the mul
itself into two muls.

### Behavioural study

```systemverilog
- assign y = (a + b) * c;
// Spine: AddSub 10, Mul 56. Expand:
+ assign t_add = a + b;     // node locked 10
+ assign y     = t_add * c; // node locked 56
// InsertReg after t_add is PrepStage: mul still 56 in the next cycle (T3).
// InsertReg cannot make the mul fit B=10.
```

---

## A43 — Emit / origin rewrite (M7)

**Implementation.** `crates/sv-timing-emit/src/lib.rs`, `rhs.rs`, `dense.rs`.

### Summary

Source mutation is **line-based**. Recover `lhs = rhs` / `lhs <= rhs` /
`assign lhs = rhs` at the cut line, feed `pipe_c` from the real RHS when
`--real-cut-feeds`, rewrite origin to `lhs = pipe` (or `lhs <= pipe`).
Keep `assign` on continuous. Procedural NBA rewrite uses `<=`. Multiline
empty-first-RHS and blank-before-assign have dedicated anchors
(`cut_rewrite_anchor`).

Integrity: reparse the emit tree (`integrity_reparse`). Fail closed.

### Low-level basics

`apply_edits_to_source_dense` order:

1. BalanceMux origin RHS rewrites **first**.
2. InsertReg origin assigns.
3. Inject BM snippets at origin process.
4. Inject dense sidecar block (parameters, pipe regs, optional lean zeros).

`parse_assign_line` strips case labels so `ADD, SUB: result_o = …` does not
emit illegal `assign ADD, SUB:`. Declarations `logic x =` are not origin
assigns. `line_inside_generate` is keyword-only (A12).

Twin copy (A44) runs as part of origin rewrite when a matching assign exists.

`--real-cut-feeds` off: lean emit may feed `svt_zero` and still report IR FO4
wins that **did not happen in RTL**. Soak of record uses real feeds.
`PassPolicy.emit_structural` is the boolean.

### High-level basis

M7 is the reason extra S4 is dangerous. The IR can host 16 InsertRegs; the
source has one line per origin. Two edits that share a file and a nearby
line **interfere**. v28's 191 edits / policy_subcode n=16 Plain 30.5 is
that interference made visible.

Treat emit as a **separate algorithm** with its own invariants, not as a
pretty-printer of IR.

### Purpose

Make IR cuts real RTL, reparable, reviewable under `corrected/`. Never
auto-merge into production.

### Mutations

The emit tree. Host must copy by hand.

### Behavioural study

```systemverilog
// Continuous origin (keep assign):
- assign c_span = 32'(…) * …;
+ assign c_span = pipe_svt_p1_4;

// Procedural NBA (keep <=, first NBA line):
-      q <= cloud;
+      q <= pipe_svt_p1_1;

// Comment shift (forbidden order):
+ // sv-timing insert_reg origin
  assign hot = a + b;     // line moved; next rewrite misses
```

Tests: `balance_mux_rhs_rewrite_keeps_assign_keyword`,
`balance_mux_rewrite_not_shifted_by_insertreg_comments`,
`multi_cut_insert_applies_multiple_regs` (set
`policy.opt.max_stages_per_region = 4`).

---

## A44 — Twin generate rewrite

**Implementation.** origin rewrite in `sv-timing-emit` (match identical
continuous-assign LHS **and** RHS across generate-if twins).

### Summary

If `gen_reuse_a` and `gen_reuse_b` both contain `assign c_span = <same rhs>`,
rewriting one copies onto the other so both generate configs stay equivalent.
If RHS differ (`m`/`lda` vs `n`/`ldb`), twins **do not** copy.

### High-level basis

Generate-if twins are elaborated one-of. Source still contains both. A
rewrite that only hits the line the hottest node pointed at leaves the twin
stale (elaboration of the other config would still have the long path, and
some tools parse both). Copy-by-identical-RHS is the conservative
equivalence. Copy-by-LHS-ident-in-named-block is the **missing** algorithm
(Part VII addition A) that would pair `a_span`/`b_span`.

### Behavioural study

```systemverilog
if (ReuseAEn) begin : gen_reuse_a
-   assign c_span = mul_like_rhs;
+   assign c_span = pipe_svt_p1_4;   // origin
    assign a_span = rhs_a;           // different RHS — not a twin of c_span
end
if (ReuseBEn) begin : gen_reuse_b
-   assign c_span = mul_like_rhs;
+   assign c_span = pipe_svt_p1_4;   // copied (LHS+RHS match)
    assign b_span = rhs_b;           // not copied from a_span
end
```

Fixture: `fixtures/auto_correct/twin_generate_span.sv`, `gemm_span.sv`.

---

## A45 — Integrity reparse

**Implementation.** `integrity_reparse`, `assert_valid_sv_bundle` in
`sv-timing-emit/src/lib.rs`.

### Summary

After emit, parse every emitted file with the same parser. Structural_ok
false → soak FAIL. This caught `te_packet_emitter` missing `assign` (v21)
and is the reason BM keep-assign exists.

External lint/sim hooks exist but are not the default gold.

### High-level basis

A timing compiler that emits unparsable SV has **negative** value: it
cannot be reviewed and it poisons diffs. Integrity is a **gate**, not a
metric.

### Behavioural study

```text
v21: rewrite dropped `assign` → Parse error → integrity FAIL → no soak number.
v21b: keep assign → integrity green → 26 FO4 headline.
```

---

# Part V — Multi-pass logic

## A46 — Multi-pass S0–S5

**Implementation.** `run_correct_passes` in
`crates/sv-timing-transform/src/pass.rs`.

### Summary

The strategic algorithm. All prior algorithms are its subroutines.

```text
S0  measure; plan_from_design; if artifacts: stop (P1/P2)
    cleanliness; factor_always_ff (review); scale worklist
S3  loop: latency-neutral work only
        module-diverse batch; apply; remeasure
        stop stage if 2× Δprimary < min_gain  OR  stage_budget  OR  empty
        if allow_latency && emit_structural: enter S4
S4  loop: InsertReg on admitted + resilient (re-attached, resilient-first)
        one successful apply per module per pass; cap per module
        remeasure; stop if primary slack≥0 OR 2× flat OR stage_budget
S5  report T3 / P8 / P9 counts; do not edit
```

`stage_budget = max(1, max_passes/2)`. `-O3` → 8 + 8. `min_gain` from
opt (1.0 at O3), floored at 0.5 for the flat test.

Lean emit (`!emit_structural`) skips every IR FO4 mutation and never
enters S4 (`lean_emit_skip_s4`).

### Low-level basics

Idle: a pass that applies nothing increments `idle_streak`; at `idle_limit`
(scaled) stop. Skipped set: paths that refused or hit apply cap. Refuse
reasons are counted (`cleanliness_set`, class, …) for traces.

`apply_work_item` honors relocation option kind, then latency-neutral, then
InsertReg. PrepStage once per path; others up to scaled `apply_cap`.

Primary for flat/close is `ranked.primary.first().total_fo4` — the **worst**
single-cycle path after classify. Sibling leftovers at the **same** FO4
do not move this number when one of them is cut (the other becomes the new
first at the same FO4). That is the 18.5 gemm geometry (A48).

### High-level basis

S3 before S4 is the architectural law: **do not add latency until
same-cycle structure is exhausted.** The two-flat stop is the architectural
law: **do not farm FO4 on a primary that is not moving** (audit-strict-v4
applied 192 edits while primary stayed flat). Together they are why the
package can run `-O3` on a full core without unbounded spray.

S5 exists so T3 work is **visible** without being auto-applied. A mul 56
will never leave S5 as an InsertReg.

### Purpose

Orchestrate A1–A45 toward \(B\) without lying and without breaking protocols.

### Mutations

Whatever S3/S4 apply. S0/S5 none.

### Behavioural study (v27 gemm, two InsertRegs not the cap)

```text
S3: exclusive/bundle BalanceMux on other modules; gemm Plain no BM match
S4 pass 3: path 5048  74.5 → 56   origin L608 (c_span mul-like)
S4 pass 4: path 5346  18.5 → 10   origin L610 (c_end)
           sibling b_span 18.5 remains → primary still 18.5
           Δprimary < min_gain → flat_streak 1, then 2 → fixpoint STOP
Emit: 186 edits, primary 18.5, integrity green
```

That is **correct S4**, not a bug in `schedule_pipeline_cuts`.

---

## A47 — Module-diverse batch

**Implementation.** batch construction in `pass.rs` (batch_mods set,
deferred_same_mod fill).

### Summary

Apply up to `batch_size` paths from **distinct** modules before remeasure.
Full-core coverage scales with √modules instead of 1-path-per-remeasure on
a single FPU tree. Same-module residual fills only if diversity is
exhausted. Combined with `insert_reg_by_module` cap = stages, one module
cannot eat the pass budget.

### High-level basis

A greedy worst-path loop is **local** and starves. Diversity is a covering
algorithm. The cost is stale IR inside a module for the rest of the batch
— hence **one InsertReg per module per pass** when kind is InsertReg, then
remeasure.

### Behavioural study

```text
Worklist: gemm 18.5, instr_queue 15.5, axi2mem 14, frontend 13
Batch: one each (four modules) if batch_size≥4
Remeasure: gemm maybe still 18.5 (sibling), instr_queue maybe 10, …
Next pass: gemm again if still admitted and cap not hit
```

---

## A48 — Fixpoint and the primary-flat stop

**Implementation.** `flat_streak` in `pass.rs`.

### Summary

After a successful apply+remeasure, if `|last_primary − now_primary| < min_gain`,
increment `flat_streak`. At 2: if S3, enter S4; if S4, **stop** (`fixpoint`).
Do **not** continue S4 because a resilient sibling still exists.

### Low-level basics

Primary is a **scalar** (worst path FO4). Two equal-FO4 Plain cones in one
module (gemm `a_span` and `b_span` both 18.5) mean cutting one leaves the
scalar unchanged. The scheduler would cut the sibling **next pass** if the
loop continued. The fixpoint law forbids that unbounded continue. The
bounded alternative is Part VII addition B: **one** extra same-module S4
only if primary still same FO4±ε **and** LHS is a sibling span, then return
to S3. Not “while `s4_has_pending_resilient`.”

### High-level basis

Fixpoint on the headline number is how you avoid v4's 192-edit flat run
and v28's 30.5 regression. Progress that does not move the headline can
still be real (sibling cuts), but it is **exactly** the progress that
steals origins. The architecture prefers a stable 18.5 with 2 gemm
InsertRegs over an unstable 30.5 with 16.

### Purpose

Stop. Leave a diagnosable leftover.

---

## A49 — Failed experiment: S4-continue (v28)

**Implementation.** Reverted in `pass.rs`. Helper `s4_has_pending_resilient`
kept in `pass_strategy.rs` and tested, **unused** by the loop. Wrap/fat-FSM
refuse **kept**.

### Summary

Hypothesis: if primary is flat but a resilient path still has slack < 0,
continue S4 so the gemm sibling 18.5 gets its cut.

Result: extra S4 after a flat 18.5 primary InsertReg'd **other** Plain
cones, stole `policy_subcode` origin rewrites, emit **18.5 → 30.5** /
1311 MHz, 191 edits, policy_subcode n=16 Plain 30.5 primary.

### High-level basis

The helper answered the wrong question. “Is there a resilient leftover?”
is true for many paths that are **not** the sibling span. The loop then
applied T2 where T0/T1/T3 belonged, and M7 interference undid a closed
origin. Same class as v22 `stc_elem_q`.

### Mutations (what v28 did, then reverted)

```systemverilog
// policy_subcode (illustrative): a closed 10 FO4 origin after v27
assign s = pipe_svt_pN;          // already cut
// v28 extra S4 rewrote a nearby Plain cone, comments shifted the line,
// the next origin rewrite hit the wrong assign, the 10 FO4 path became
// 30.5 serial again.

// Wrap lock (KEPT — not part of the revert):
// is_resilient_datapath == false when wrap_boundary / WRAP in RHS/LHS
// fat Plain FSM nodes≥16 without Mul/DivRem == false
```

### Maintenance

Never re-enable “while pending resilient” without a **LHS-sibling**
predicate and a **one-shot** bound. Rebuild `sv-timing-cli` release after
any pass.rs change; soaks prefer `target/release/sv-timing.exe`.

---

## M20 — Named `fmt_row_bytes` (delay-v20)

**Implementation.** `is_fmt_scale_call` / call class in `expr.rs`. Campaign
letter **D** in `AGENTS-todo.md` (VII.D landed).

### Summary

Calls named `fmt_row_bytes` / `ai_fmt_bytes` are a mux of shifts, not a
multiplier. `x * fmt_row_bytes(...)` demotes to Mux, not Mul 56.

### Low-level basics

INT4 is `(elems+1)>>1`. Other formats are `elems << log2(1|2|4)`. The
function name is the proof; the body is not inlined. Unknown calls stay
Other (M29 N). `$clog2(CONST)` stays 0.

### High-level basis

The honest alternative to parsing `32'(n-1)*fmt_row_bytes` (A10, v25 40.5)
is to name the scale function. Gemm 18.5 geometry used this call; after
delay-v20 the remaining leftover is the uncast `32'(n-1)` plus the add,
not a 56 FO4 mul.

### Purpose

Remove phantom Mul on format-dependent byte counts.

### Mutations

None.

### Behavioural study

```systemverilog
// - Mul 56 if the `*` is parsed as datapath
// + Mux of shifts
assign row = fmt_row_bytes({16'd0, ldb_q});
```

Test: `delay_v21_const_select_mux_and_width_cast` (fmt_row_bytes ≁ Mul).

---

## M21 — Const-select offset add

**Implementation.** `is_const_select_mux` in `billed_binary_class`
(`expr.rs`). Campaign letter **A**. delay-v21.

### Summary

`x + (c ? lit : lit)` is a mux of two const offsets: LogicBit, not CPA.
Runtime arms stay AddSub.

### Low-level basics

Both ternary arms must be Const. The condition may be runtime. RAS
`addr[i] + (rvc ? 2 : 4)` matches. Frontend
`addr[i] + (taken ? rvc_imm : rvi_imm)` does **not** (`[i]` scalar pipe
still forbidden, M29 R).

### High-level basis

A 2/4 byte increment is wiring + a mux, not a 10 FO4 adder. Billing it
as AddSub made RAS the period at \(B=10\).

### Purpose

Demote const-select PC/addr offsets.

### Mutations

None.

### Behavioural study

```systemverilog
// + LogicBit
ras_update = addr[i] + (rvc_call[i] ? 2 : 4);
// stays AddSub (runtime immediates)
predict_address = addr[i] + (taken_rvc_cf[i] ? rvc_imm[i] : rvi_imm[i]);
```

Test: `delay_v21_const_select_mux_and_width_cast`.

---

## M22 — Const-condition mux

**Implementation.** ternary arm in `fo4_critical_cost_latticed` (`expr.rs`).
Campaign letter **C**. delay-v21.

### Summary

A `?:` whose **condition** is Const is generate-if / param select: one arm
exists in the netlist, so there is no 2.5 FO4 mux. Runtime `en ?` stays Mux.

### Low-level basics

`cond.const_class(seed).is_const()` → return the live arm only. Seeded
genvar `i < CNT ? add : 0` is the add. A runtime flag is Mux + max(arms).

### High-level basis

IEEE 1800 constant conditions are elaborated away. Taxing them as muxes
invented delay on generate-shaped pe_dot `i < CNT`.

### Purpose

Elaboration muxes cost 0.

### Mutations

None.

---

## M23 — Zero-detect

**Implementation.** `billed_binary_class` for `==` / `!=` vs 0. Campaign
letter **D**. delay-v21.

### Summary

`x == 0` / `x != 0` is an OR-tree / zero-detect (LogicBit), not Compare 4.

### Low-level basics

One side must be a zero literal (`0`, `'0`, `32'd0`, `MAXW'(0)` after A10
collapse). Two runtime operands stay Compare.

### High-level basis

Soak v44 billed pe_dot `sum != MAXW'(0)` as Compare 4 on top of the mux
and made APU 17 the headline. Zero-detect is what silicon does.

### Purpose

Do not spend 4 FO4 on `!= 0`.

### Mutations

None.

### Behavioural study

```systemverilog
// + LogicBit (zero-detect), not Compare 4
assign nz = (sum != MAXW'(0));
```

---

## M24 — Const-then mux chain

**Implementation.** `const_then_chain` / `is_encoding_then` in `expr.rs`.
Campaign letter **E**. delay-v22.

### Summary

Nested `c ? Const : (c2 ? Const : … : datapath)` is **one** mux on the
runtime spine, not a serial mux chain. Encoding arms include concat of
flags+const fields and `ident[CONST]` / `ident[LEVELS]`. Bare ident and
`{a,b}` do **not** flatten.

### Low-level basics

Walk else-arms while then-arm is an encoding. Cost = Mux 2.5 + max(conds,
tail). Invert (`!red_fin`) beside the chain is a separate LogicBit (test
splits bare-flag 2.5 vs invert 3.5).

Inf `{sign, 8'hff, 0}` is encoding because a part is Const. `{a,b}` is
not. `sign[LEVELS]` is a const-index bit-select, treated as encoding.

### High-level basis

NaN/Inf/zero encodings in pe_dot are a priority mux onto one convert
tail, not three mux delays. Flattening a runtime then-arm would hide
real datapath.

### Purpose

One mux tax for encoding cascades.

### Mutations

None.

### Behavioural study

```systemverilog
// one mux + tail, not mux+mux+mux
assign fp = nan ? {1'b0, 8'hff, 23'd1}
          : inf ? {sign, 8'hff, 23'd0}
          :      mantissa_path;
```

Test: `delay_v22_const_then_mux_chain_is_one_mux`.

---

## M25 — Module auto-const

**Implementation.** `extend_seed_auto_const` in `ref_order.rs`; hooked from
`attribute_costs` after elaboration seed. delay-v23.

### Summary

First pass on a module using `RefOrderTree`. For each **expression-less**
combo/continuous assign (`x=4`, `x=WIDTH`, `x=y` of a const) whose LHS is
a **single exclusive writer** and is **read**, add the LHS to `ConstSeed`.
Copy-propagate ident aliases to a fixpoint (cap 32).

### Low-level basics

Skip: NBA, indexed LHS (`[i]`), writes≠1, reads=0 (write-only `_d`).
Empty expression-less list must still run aligned seed (M27); no early
return. Mixed-case **localparams** (`MaxBurstBeats`) are A8 step 1, not
this pass — there is no `assign MaxBurstBeats = 255`.

### High-level basis

IEEE blocking assign of a literal to an exclusive net is elaboration if
the net is never rewritten. Seeding it lets later `x + 1` / `== x` fold.
Seeding defaults that are later overwritten (`ready_o = 1'b0` then a
branch) would lie; the write-count guard is the proof.

### Purpose

Const-propagate exclusive combo literals/aliases without rewriting RTL.
Auto-const **does not emit** a `const` keyword into `corrected/**`.

### Mutations

None to RTL.

### Behavioural study

```systemverilog
assign WIDTH_N = 32;          // exclusive, read → seed
assign nbeats  = pairs_rem;
if (nbeats > MaxBurstBeats)
  nbeats = MaxBurstBeats;     // multi-writer → not seeded
```

Tests: `auto_const_expression_less_exclusive_read`,
`auto_const_skips_nba_and_write_only_and_multi_writer`.

---

## M26 — One-hot stride add

**Implementation.** `is_one_hot_stride` / `is_const_pow2_shl` in `expr.rs`.
Campaign letter **F**. delay-v23.

### Summary

`x + (1 << n)` with runtime `n` is a mux of increments (decoder stride),
not CPA+shift. `x + (a << n)` with runtime `a` stays AddSub.
`x + (1 << CONST)` was already LogicBit (A9 offset).

### Low-level basics

The shifted operand must be a const power of two (`1`, `32'h1`). dm_sba
`sbaddress_i + (32'h1 << sbaccess_i)` matches. Soak v50: dm_sba 12 gone.

### High-level basis

`base + (1<<k)` is “set bit k of a one-hot and add into a sparse field”,
implementable as a mux of `base+1`, `base+2`, … not a 10 FO4 CPA.

### Purpose

Close decoder-stride leftovers.

### Mutations

None. InsertReg on that add is still a functional break if it is an
address.

### Behavioural study

```systemverilog
// + Mux of increments
assign nxt = sbaddress_i + (32'h1 << sbaccess_i);
// stays AddSub
assign nxt = addr + (offset << size);
```

Test: `delay_v23_stride_add_aligned_insert_sign_and_call`.

---

## M27 — Aligned field insert

**Implementation.** `is_aligned_field_insert`, `ConstSeed.aligned` /
`shifted`, `extend_seed_aligned` in `expr.rs` / `ref_order.rs`. Campaign
letter **G**. delay-v23 inline concat; delay-v24 named aligned net;
delay-v25 staged shift temp.

### Summary

`{x[MSB:K], {K{0}}} + (y << K)` is a field insert (Concat), not a CPA.
Exclusive combo of that pad seeds `aligned[name]=K`, so `ident + (y<<K)`
matches. Exclusive `t = y << K` (BalanceMux staging) seeds `shifted[t]=K`,
so `aligned + t` matches. Wrap ident from a **Call** is not assumed
aligned. `wrap + t` stays AddSub.

### Low-level basics

`zero_pad_align_key` requires a two-part concat whose low part is a
zero-fill replicate. `{{LOG}{1'b0}}` is a one-part concat wrapping the
replicate count (axi2mem); `zero_fill_count` / `alignment_key` /
`expr_align_leaf` unwrap it. K is ident or literal; matching is by key
string (`LOG_NR_BYTES` vs `3`).

InsertReg on wrap-add remains a functional break (A32).

### High-level basis

AXI beat alignment is `{addr[MSB:LOG], zeros} + (cnt<<LOG)`: wiring, not
a carry-propagate add. WRAP `get_wrap_boundary(...)` is a function of
runtime `len`; assuming that result is zero in the same K bits is a
false-positive that would hide a real CPA (`upper = wrap + ((len+1)<<LOG)`).

BalanceMux stages `t = cnt<<LOG; cons = aligned + t`. delay-v24 saw
`ident + ident` and billed AddSub. delay-v25 seeds `t`.

v51: cons_addr Concat so BM dropped that stage; WRAP-beyond
`addr + ((cnt-len)<<LOG)` composed flop→`req_addr_d` as Plain 22.
**Do not quote APU 22** over v50 16 P10. The 22 cone is real; v50 hid it
as intoout.

### Purpose

Bill aligned stride as concat; refuse wrap-from-call as concat.

### Mutations

None. Do not InsertReg wrap-add. Do not seed Call results as aligned.

### Behavioural study

```systemverilog
aligned_address = {ax_req_q.addr[AXI_ADDR_WIDTH-1:LOG_NR_BYTES],
                   {{LOG_NR_BYTES}{1'b0}}};
cons_addr = aligned_address + (cnt_q << LOG_NR_BYTES);   // Concat
wrap_boundary = get_wrap_boundary(ax_req_q.addr, ax_req_q.len);
upper = wrap_boundary + ((ax_req_q.len + 1) << LOG_NR_BYTES); // AddSub
```

Tests: `auto_const_aligned_zero_pad_names_field_insert`,
`auto_const_aligned_double_brace_ident_pad`,
`auto_const_aligned_plus_staged_shift_temp`.

---

## M28 — Signed compare vs 0

**Implementation.** `billed_binary_class` for `>`/`>=`/`<`/`<=` vs 0.
Campaign letter **I**. delay-v23.

### Summary

Signed `x > 0` / `x >= 0` / `x < 0` is the sign bit (LogicBit), not
Compare 4. `x > y` two runtime stays Compare. Does **not** close fpnew
12.5 (the subtract remains).

### Low-level basics

One operand must be a zero literal. Magnitude compares stay Compare.

### High-level basis

`exponent_difference > 0` is `~sign`. Billing Compare 4 next to a 10 FO4
sub invented 14.5-looking FMA cones; after I the sub is still 10+mux.

### Purpose

Sign-bit tests are LogicBit.

### Mutations

None.

Test: `delay_v23_stride_add_aligned_insert_sign_and_call`.

---

## M29 — Remaining leftover catalog H–R

**Implementation.** Deduced from v48/v50 unique leftovers. Not all landed.
Campaign letters in `AGENTS-todo.md`.

### Summary

Host-agnostic leftovers that are **policy**, **RTL**, or **unlanded
measure**. Do not implement them as InsertReg.

| Letter | Shape | Status |
|---|---|---|
| **H** | `get_wrap_boundary` is a mux of bit-clears (len 1/3/7/15) | unlanded; needs function-body inline. Other burst types stay datapath |
| **J** | exclusive leftover=0 (csr/bht/tlb 12.5–13) | S3 floor. max_arm 10 + mux 2.5. No extra InsertReg |
| **K–M** | P10: posted indexed CSR write; tail-line Q for coalesce; delay `{pulse,index}` together | RTL. Never InsertReg one net of the pair |
| **N** | unknown function body | **stays Other**. v49 billed 2-arg as Mux, gemm 12→15, **reverted**. `fmt_row_bytes` is M20; `$clog2` const is 0 |
| **O** | `mem[ptr_q]` of a flop array is a mux of Qs | combo bypass+EQ is real (refill_hit). Flopping the D-arm EQ misses same-cycle hit |
| **P** | next-state `q + cast(elem)` + hold mux | Mux+Add. IndependentLhsBundle: no InsertReg (gemm 12 / axi_adapter 11) |
| **Q** | saturating 2-bit `sat±1` with clamp | already increment (delay-v18 / A9) |
| **R** | PC+imm in a fetch-slot loop | parallel adders; `[i]` scalar pipe **forbidden**. Runtime-imm add stays 12.5. Const-select is M21 |

### High-level basis

H/N need a function-body measure that does not repeat v49. J is exclusive
deflation working. K–M are handshake protocol. P/R are IndependentLhsBundle
and `[i]` constraints already in A23/A30.

### Mutations

None of these may InsertReg a P10 pair, a wrap-add, or a `[i]` scalar.

---

# Part VI — Cross-cutting pass-failure modes

These are not extra algorithms. They are the failure modes of the ones
above, named so a maintainer can recognize them in a soak trace.

### F1 — Primary-flat vs equal-FO4 siblings

A48. Symptom: `flat_streak=2`, `primary_fo4` unchanged, `s4_has_pending_resilient`
would be true. Action: named sibling cut (VII.B), not S4-continue.

### F2 — Emit origin is line-based (M7)

A43. Symptom: integrity Parse; or FO4 up after more edits; origin comment
on the wrong assign. Action: BM-before-InsertReg, keep `assign`, re-anchor
`primary_loc`, do not spray.

### F3 — Generate-if twins require identical RHS

A44. Symptom: one generate config closed, twin leftover at same FO4,
different span names. Action: VII.A LHS-ident-in-named-block.

### F4 — Incomplete `32'(expr)` parse is protective

A10. Symptom: temptation to “fix parse” on gemm. Action: do not parse
general `(W)'(expr)`. Named-function demotion **landed** (M20). Do not
collapse type-name `'(` (`int'(q)*6` is v43 Mul 56).

### F5 — IndependentLhsBundle thresholds miss 2-field FSMs

A23. Symptom: was `dm_sba` 12; **dm_sba gone** (M26). Residual:
fpnew/frontend 12.5, gemm 12, axi_adapter 11 (M29 P). Action: do not
globalize `_q`. Do not InsertReg IndependentLhsBundle.

### F6 — Cleanliness is module-global

A31/A32. Symptom: gemm InsertReg refused with `cleanliness_set`. Action:
exception policy already admits; if still refused, check lane (P10) and
`admits_insert_reg`.

### F7 — P10 / wrap / T3 working as designed

A27/A32/A25. Symptom: leftover 16 P10 / wrap-add / 56. Action: S5, not
S4. These are the **floor**. InsertReg on wrap-add is still forbidden.

### F8 — Unknown-call Mux tax (v49)

M29 N. Symptom: billing 2-arg unknown `Call` as Mux made gemm 12→15.
Action: unknown calls stay Other. Reverted. Do not re-tax.

### F9 — BalanceMux wrap-beyond compose (v51)

M27 / A37. Symptom: delay-v24 made `cons_addr` Concat so BM dropped that
stage; WRAP-beyond `addr+((cnt-len)<<LOG)` composed flop→`req_addr_d` as
Plain 22. v50 hid the same 22 as **intoout**. Action: **do not quote 22**
over v50 16 P10. Do not InsertReg wrap-add. Do not revert M27 to hide it.

---

# Part VII — Remaining gap to 10 FO4

This section **determines** the remaining gap from the algorithms above.
It is not a wishlist. Each leftover is typed by class, P-id, lane, and
which algorithm is allowed to touch it.

## Soak of record

Quoted: `audit-remain-v50/` delay-v23. Integrity joint/reparse/structural
OK both. Core emit **15.0 P10** `trigger_module`; APU emit **16.0 P10**
`g6lc_inval_bus`. Path-class v24.

Latest: `audit-remain-v52/` delay-v25, same core 15.0 P10; APU emit 22.0
axi2mem WRAP-beyond (F9). **Do not quote 22** over v50 16 P10.

Historical v27 18.5 gemm span is **closed** (VII.A/B/D/E + M20). Do not
quote v25 40.5, v28 30.5, v43 40.5 `int'` Mul, v44 pe_dot 17, v49 gemm 15.

## Leftover unique RegToReg (budget 10, post_analyze v50; v52 notes)

| Module | FO4 | Class / note | Algorithm that owns it | Can auto close to 10? |
|---|---:|---|---|---|
| `trigger_module` L177 | **15.0** | Plain n=3 P10 indexed CSR pack | M29 K–M / A27 | no — S5 RTL |
| `csr_regfile` `csr_rdata` | 13.0 | Exclusive leftover=0, mux=2.5 max_arm=10 | M29 J | no — S3 floor |
| `fpnew_fma_multi` | 12.5 | IndependentLhsBundle mux+sub | A23 / M28 (sub remains) | no S4 |
| `bht` `bht_updated` | 12.5 | Exclusive leftover=0 | M29 J / M29 Q | no |
| frontend `predict_address` | 12.5 | IndependentLhsBundle `addr[i]+(imm:imm)` | M21 no; M29 R | no `[i]` pipe |
| `cva6_tlb` `gppn` | 12.5 | Exclusive leftover=0 | M29 J | no |
| `g6lc_thread_select` | 11.0 | Plain P10 | A27 | no |
| `axi_adapter` | 11.0 | IndependentLhsBundle next-state | M29 P | no InsertReg |
| hpdcache upsize/uncached | 11.0 | Plain | measure / FSM | maybe T1 |
| `wt_dcache_wbuffer` | 10.5 | Plain refill/fixup | M29 O | combo EQ is real |
| `g6lc_inval_bus` L150 | **16.0** | Plain n=3 P10 | M29 K–M | no — S5 RTL |
| axi2mem WRAP-beyond | 22.0 | v51/v52 Plain n=6 BM; v50 intoout 22 | M27 F9 | no wrap InsertReg |
| axi2mem wrap add | 13.0 | was 14; cons_addr Concat (M27) | A32 / M29 H | no |
| `g6lc_ai_pe_dot_float_pipe` | 13.0 | Plain P10 convert | M24 helped 14→13; M29 N | no |
| gemm next-state | 12.0 | IndependentLhsBundle `(n_q-stc_j_q)>>1` | M29 P | no |
| `g6lc_ai_island_top` | 10.5 | P10 | A27 | no |
| T3 mul (analyze max_adj) | **56** | Atomic | T3 `NumPipeRegs` | no auto |

Intoout leftovers are not flop primaries (P5). `MaxBurstBeats` is a
localparam on gemm (A8); auto-const (M25) does not stamp `const` in
corrected RTL.

## Why gemm 18.5 *was* the headline (v27, closed)

Signature `n4|b_end:1,b_span:1,disjoint:1,k_bytes:1`. Live assign:

```systemverilog
assign b_span = 32'(n_q[8:0] - 9'd1) * fmt_row_bytes({16'd0, ldb_q}) + k_bytes;
```

`fmt_row_bytes` = INT4 `(elems+1)>>1` else `elems * ai_fmt_bytes()` with
`ai_fmt_bytes ∈ {1,2,4}`. Fully parsing the width-cast would bill Mul
(F4). Incomplete parse + serial `b_span → b_end (add) → disjoint` = 18.5.

S4 applied **two** gemm InsertRegs (not the cap 8/16): `c_span` 74.5→56
and `c_end` 18.5→10. Twin copied `c_span` onto `gen_reuse_b`. Twin cannot
copy `a_span`→`b_span` (RHS differ). generate-if without `generate` keyword
is still a claimable net (`lhs_is_module_level_net` allows `b_span`).
`schedule_pipeline_cuts` would cut `b_span`. **Fixpoint stopped first**
(F1).

## Combinable small additions (A–F) — status after delay-v25

v27 listed these as unimplemented. Emit extras in commit `7e9f78197` plus
M20–M28 discharged the **18.5 headline**. Status:

### Addition A — Generate-if span pair by LHS ident in named block (landed)

**Theory.** A44 copies by identical RHS because that is a syntactic
equivalence proof. `a_span`/`b_span` are **role-equivalent** (row-span
byte address) in named blocks `gen_reuse_a` / `gen_reuse_b`, not
text-equivalent. A detector that pairs `ident_base(LHS)` inside
`begin : gen_*` blocks of a generate-if/else, and applies the same pipe
name / same cut depth, preserves both configs without parsing `32'(…)`.

```systemverilog
if (ReuseAEn) begin : gen_reuse_a
-   assign a_span = 32'(m_q[8:0]-9'd1) * fmt_row_bytes({16'd0, lda_q}) + k_bytes;
+   assign a_span = pipe_svt_span;   // same pipe as twin role
end
if (ReuseBEn) begin : gen_reuse_b
-   assign b_span = 32'(n_q[8:0]-9'd1) * fmt_row_bytes({16'd0, ldb_q}) + k_bytes;
+   assign b_span = pipe_svt_span;
end
+ always_ff @(posedge clk_i or negedge rst_ni) begin
+   if (!rst_ni) pipe_svt_span <= '0;
+   else         pipe_svt_span <= /* origin RHS of the cut span */;
+ end
```

Risk: the two RHS are not equal; feeding one pipe from one RHS is wrong
if **both** blocks can elaborate together (they cannot: generate-if).
If they are `if/else` mutually exclusive, one pipe is correct. If they
are two independent `if (En)` that can both be 1, they need **two** pipes
and two origin cuts (addition B), not one shared pipe.

### Addition B — One bounded sibling S4 (landed as uncut-span extra; no-op on APU)

**Theory.** A48/A49. After an accepted InsertReg, allow **one** more
same-module S4 **only if**:

1. primary FO4 still equals the pre-cut primary ±ε, and
2. the candidate LHS is a sibling span (same ident_base pattern
   `*_span` / same named-block pair as A), and
3. exception admits, lane CombDatapath, not P10, not wrap, and
4. then **return to S3** (do not keep looping).

This is a different algorithm from `s4_has_pending_resilient`.

```text
# v28 (forbidden)
while flat and any resilient: S4 next worst Plain   → origin steal

# B (bounded)
if just_applied_insertreg and primary_flat and sibling_span(candidate):
    apply one more InsertReg in that module
    remeasure
    resume S3 rules / stop
```

### Addition C — Next-state bundle `n_lhs≥2` + `_d`/`_q` → max_field

**Theory.** A23 thresholds (6 nodes, 4 LHS) miss 2-field FSMs. Lowering
**only** when every LHS is flop-capture (`_d`/`_q`) and n_lhs≥2 keeps
gemm NBA `_q` from becoming a global next-state bundle (gemm has many
non-`_d` spans). `dm_sba` 12 → 10 or honest 12. `g6lc_snoop_filter`
`mem_q<=mem_d` similarly.

```systemverilog
always_comb begin
  state_d = state_q;
  sb_d    = sb_q;
end
// - Plain sum 12 (thresholds miss)
// + max_field ≤ 10 (C)
```

### Addition D — `fmt_row_bytes` / `ai_fmt_bytes` as mux-of-shifts (landed, M20)

**Theory.** A10/A9. Only when a `*` operand is **that call**, demote to
shift/mux. Never general-parse `32'(expr)`.

```systemverilog
// Semantic of fmt_row_bytes(elems, fmt):
//   INT4:  (elems+1)>>1     ShiftConst
//   else:  elems << log2(1|2|4)   ShiftConst + Mux
// - Mul 56 if 32'(n-1)*fmt_row_bytes is parsed
// + Mux + ShiftConst  ≪ 10
```

This can **remove** the 18.5 primary without InsertReg if the remaining
add+disjoint fit \(B\). If disjoint still serial-adds past 10, combine
with A/B.

### Addition E — One budget-fit extra cut on `instr_queue` (landed; sandwich remainder)

**Theory.** P6 remainder after earlier cuts (L215 20→10 and 27→20).
nodes=9, Plain. Origin must be re-anchored (F2) so the extra cut does
not steal the closed L215 rewrite.

```systemverilog
// One more segment fill to B, not a spray.
// If class is actually exclusive/bundle, this is the wrong tool — re-check A21.
```

### Addition F — Leave P10 / wrap / T3 as S5

**Theory.** F7. `g6lc_inval_bus` 16, `axi2mem` 14, mul 56, plic 11,
island 10.5 P10. No auto-correct. Architectural: one-cycle handshake
must close in the RTL design (shallower index, registered RAM output
**already** at the array, or a wider period on that island). Not an
sv-timing InsertReg.

## Extrapolated headline

| If you implement | Expected emit primary | Why |
|---|---|---|
| v27 (historical) | **18.5** | gemm sibling span |
| VII.A/B/D/E + M20 (landed) | **15/16 P10** | v50 quoted |
| + M21–M28 (landed) | still **15/16 P10** | dm_sba 12 gone; wrap 14→13; pe_dot 14→13 |
| delay-v24/v25 (v52) | core 15 P10; APU 22 wrap-beyond | F9; do not quote 22 |
| M29 H function-body | wrap-boundary Mux, wrap **add** stays | will not close 13/22 |
| M29 K–M RTL | P10 15/16 may drop | handshake, not S4 |
| +F (do nothing on P10/wrap/T3) | floor **15–16 P10 / wrap / 56 T3** | not 10, by design |

**Closing the campaign to “every path ≤ 10” is not a property of S4.**
VII.A/B/D/E closed 18.5. The remaining floor is handshake (A27), wrap-add
(A32/M27), exclusive leftover=0 (M29 J), IndependentLhsBundle (M29 P/R),
and T3 mul. Human RTL on K–M; no InsertReg on those.

The architectural design, taken as first-class theory, therefore
**determines**:

1. The v27 state was 18.5 because S4's fixpoint + twin-RHS + protective
   parse left a P6 Plain sibling. That headline is **gone**.
2. The current quoted state is **15.0/16.0 P10** (v50). delay-v25 does
   not move it. v51/v52 APU 22 is F9, not a win.
3. The number 10 is reachable on **admitted** cones and **not** on
   handshake/wrap/mul without microarchitecture.
4. Any experiment that generalizes parse, generalizes S4-continue, or
   taxes unknown Calls as Mux has already been run (v25, v28, v49) and
   **raised** FO4.

---

# Part VIII — Maintenance playbook

## How to diagnose a leftover in one hour

1. Read soak `post_analyze` primary: module, FO4, class, `class_note`,
   node count, path_kind, loc.
2. Name the P-id (A29). If P1/P2: fix measure, do not correct.
3. Name the lane (A30). If not CombDatapath: name the tool (BM / T3 /
   none).
4. Check exception (A32): wrap token? fat n≥16? P10 real vs incidental?
5. Check emit origin (A43): did a rewrite land on that loc? Twin? Comment
   shift?
6. Check fixpoint (A48): did S4 stop with a sibling at the same FO4?
7. Only then consider a new detector or a bounded transform. Write a
   fixture under `fixtures/` and a `#[test]` next to the detector.

## How to add an algorithm (checklist)

1. Decide the **object** it mutates: seed, tree cost, class, lane,
   cleanliness, exception, S3 edit, S4 edit, emit origin, or report.
2. Put it in that file. Do not add a host module name. KD0.
3. Add a fixture that would have **regressed** v25 or v28 if your change
   is in parse or S4 control flow.
4. Bump `MEASUREMENT_VERSION` or `PATH_CLASS_DETECTOR_VERSION` if numbers
   change.
5. `cargo test --lib` from `sv-timing/` with **one** filter on Windows.
6. `cargo build --release -p sv-timing-cli`.
7. Soak to a **new** out-dir. Never reuse sqlite.
8. If emit FO4 **rises**, revert. Integrity FAIL is a fail, not a skip.
9. Update this manual's algorithm block and Part VII table. Do not open
   a new architecture file for a detector tweak.

## How to run tests (Windows)

```text
cd sv-timing
cargo test --lib <one_filter>
cargo build --release -p sv-timing-cli
python tools/monorepo_soak.py  # new out-dir; PATH must see release exe first
```

PowerShell mangles `python -c` with braces. Write a `.py` file.

## Standing bans (from this theory, not from folklore)

- Do not retune `fo4-v1.toml` to close a soak.
- Do not parse general `(W)'(expr)`.
- Do not S4-continue on flat primary.
- Do not InsertReg P10, WRAP, lzc, vfdsu, fpnew, leading Mul>B, intoout
  as if it were RegToReg, SMT2 switch nets.
- Do not add `_q` to global `lhs_is_next_state`.
- Do not drop `assign` on continuous rewrite.
- Do not inject BM at `endmodule` when the origin is mid-module.
- Do not BM after InsertReg comments.
- Do not treat analyze `max_path_fo4` as the soak headline; use
  post_analyze emit primary.
- Do not commit unless asked.

## Review checklist (coding philosophy, timing-impact)

- Timing-impact: state whether \(B\), class, or emit origin moved.
- Spec/config/DTS: N/A for this package (not ISA RTL). KD0 still holds.
- Dual of SoC readiness: synthesizable emit (always_ff async-low reset
  on inserted pipes), no new latch, no new clock.

---

# Appendix — File map, glossary, anti-patterns

## Algorithm → file (quick)

Already in Part 0. Repeat for grepability:

`ir.rs` A1; `cost_table.rs`+`fo4-v1.toml` A2; `measure.rs` A3 A15 A16 A17
A18; `version.rs` A4; `parse.rs` A5; `lower.rs` A6; `expr.rs` A7 A8 A9 A10
A11-partial; `pass_strategy.rs` A11-stub A27 A28 A29 A32; `ref_order.rs`
A19; `parallel_timing.rs` A20; `path_class.rs` A21–A26; `cone_lane.rs`
A30; `cleanliness.rs` A31; `relocation.rs` A33; `opt.rs` A34 A41;
`worklist.rs` A35; `factor_always_ff.rs` A36; `pipeline.rs` A37–A42;
`pass.rs` A46–A49; `lib.rs`+`rhs.rs`+`dense.rs` (emit) A43–A45.

## Glossary

| Term | Meaning |
|---|---|
| FO4 | Fanout-of-4 inverter delay unit |
| \(B\) | Budget FO4 at target |
| Plain | Class: sum/makespan trusted |
| Resilient | Exception: Plain RegToReg >B admitted to S4 |
| Primary | Worst single-cycle path after classify |
| Origin | Source line emit will rewrite |
| Lean emit | Structural FO4 in IR without origin RTL feeds |
| Real-cut-feeds | Origin RHS → pipe; implies BM RTL |
| KD0 | Crates never depend on monorepo paths |
| T3 | Architectural multi-cycle, suggest-only |
| P6 | Shallow over budget, one slice |
| P10 | Same-edge handshake lock |
| M7 | Emit origin is line-based |
| delay-v19 | Narrow `(W)'(1)` only; delay-v25 is current |
| detector 24 | 2-arm flop-D exclusive; mux=model.mux |

## Anti-patterns (cost drivers)

Hard-coding `g6lc_gemm` in a detector (breaks KD0 and every other APU).
Treating statement order as depth (ignores A19/A20). Branding a 100-node
path atomic because it contains a mul (P4). InsertReg on `fifo_q[head]`.
Closing 4 GHz by changing `fo4_ps` to 5. Comparing delay-v18 goldens to
delay-v19 soaks. Reusing sqlite. Running soaks on a stale debug CLI.

## Fixture index (behavioural study on disk)

| Fixture | Algorithm |
|---|---|
| `fixtures/auto_correct/gemm_span.sv` | A32 A40 A44 VII |
| `fixtures/auto_correct/twin_generate_span.sv` | A44 |
| `fixtures/auto_correct/mixed_resilient.sv` | A32 |
| `fixtures/auto_correct/proc_nba_span.sv` | A43 NBA origin |
| `fixtures/measure/handshake_switch.sv` | A27 |
| `fixtures/measure/ternary_indexed_restore.sv` | A28 |
| `fixtures/measure/always_ff_nba_bundle.sv` | A14 A22 |
| `fixtures/measure/nba_vs_blocking.sv` | A14 |
| `fixtures/parse/comment_interiors.sv` | A11 |
| `fixtures/parse/genvar_lattice.sv` | A12 |
| `fixtures/parse/param_lattice.sv` | A8 |
| `fixtures/parse/lzc_tree.sv` | A13 A30 |
| `fixtures/parse/hpdcache_idx_mux.sv` | A22 |
| `fixtures/parse/comb_for_scale.sv` | A13 |
| `fixtures/exclusive_case_mux.sv` | A22 |

## Closing sentence

The architectural design **is** the algorithm: a typed measurement of
structural FO4, a staged application of T1 then T2, a line-based emit, and
a refusal to lie about handshakes, wraps, and multipliers. The remaining
gap to 10 is a sibling span plus a queue remainder plus a floor that is
not 10. Maintain the types; do not lengthen S4.

---

# Part IX — Supporting algorithms the pass loop actually calls

The named blocks A1–A49 are the pass/classify/emit core. **M20–M29** (after
A49) are leftover-measurement algorithms (delay-v20…v25). **A50–A59 in this
part** are the supporting ring (opportunity, names, cache, CLI). A later
ring (A60+) covers reset convention, cheap exits, and cleanliness. The pass
loop depends on that supporting ring the first time a name collides, a cache
lies, or an opportunity is missing. Each is still a theory object.

## A50 — Opportunity suggestion

**Implementation.** `suggest_opportunities` in `crates/sv-timing-core/src/measure.rs`.

### Summary

Walk over-budget paths and emit `Opportunity` records in a fixed kind
order: BalanceMux, then SplitAssign, then InsertReg. Classification
short-circuits: UnderBudget / MultiCycleTagged / AtomicOverBudget emit
nothing; exclusive/bundle/dense emit T1 only; Plain emits T1+T2.

### Low-level basics

Skip: `multi_cycle`, slack ≥ 0, empty nodes, `nodes ≤ 1` (P3: no interior).
For exclusive shapes, attach BalanceMux at the hottest node loc and
SplitAssign if the RHS tree is deep. For Plain, also attach InsertReg
with `insert_after` at a mid/cost-balanced node and `changes_latency =
true`.

This function does **not** apply edits. It fills `design.opportunities`
so the worklist has something to hold. S3 filters to
`is_latency_neutral_kind`. S4 replaces non-InsertReg opportunities on
resilient paths with a synthetic InsertReg (`insert_reg_for_path` in
`pass.rs`).

### High-level basis

Suggestion is a **lower bound** on what the loop may try. Relocation
cards can add PrepStage. Exception policy can add InsertReg the
suggester refused (cleanliness) or that class discouraged (Plain is
required). If you expect S4 to fire and `suggest_opportunities` never
emitted InsertReg, check class first, then P3 node count, then
`discourages_insert_reg`.

### Purpose

Populate the worklist without the pass loop hard-coding FO4 arithmetic.

### Mutations

`Opportunity` list only.

### Behavioural study

```systemverilog
unique case (sel)          // ExclusiveCaseMux, slack < 0
  0: y = hot_arm;
  default: y = 0;
endcase
// opportunities: BalanceMux, maybe SplitAssign. NOT InsertReg.

assign t = a + b;          // Plain, 2 nodes, 11 FO4
assign y = t ^ m;
// opportunities: SplitAssign (maybe), InsertReg after t.
```

Tests at the bottom of `measure.rs` assert InsertReg is absent on
exclusive and present on Plain, and that multi_cycle is skipped.

---

## A51 — Name allocation

**Implementation.** `crates/sv-timing-core/src/naming.rs`.

### Summary

Every inserted identifier is allocated from a `NameTable` under
`NamePolicy`: prefix `svt_`, pipe infix `_p`, wire infix `_w`, expand
infix `_x`, file suffix `__svt`. Collision-safe against existing module
idents.

### Low-level basics

`mangle_identifier` with `MangleStyle::SafeIdent` prefixes illegal
starts and replaces bad characters with `_`. `NameOrigin` records the
source loc that justified the name so emit comments can demangle.
`NameKind` is Signal / Module / File.

Pipe names in practice look like `pipe_svt_p1_4`: tool-visible, grepable,
stable enough that twin generate can reuse the same ident when copying.

### High-level basis

Names are a **namespace algorithm**. A collision with an existing `pipe`
user net is a functional bug that integrity reparse will not always
catch (the file still parses). The table is the uniqueness proof. Do
not hand-build `"pipe_" + id` in emit; go through the table.

### Purpose

Make inserts legal SV and reviewable.

### Mutations

New idents in IR and source.

### Behavioural study

```systemverilog
// Existing user net:
logic [31:0] pipe;
assign pipe = a + b;

// InsertReg must NOT steal `pipe`.
+ logic [31:0] pipe_svt_p1_1;
+ always_ff @(posedge clk_i or negedge rst_ni) begin
+   if (!rst_ni) pipe_svt_p1_1 <= '0;
+   else         pipe_svt_p1_1 <= a + b;
+ end
```

---

## A52 — Edit trace

**Implementation.** `crates/sv-timing-transform/src/edit.rs`.

### Summary

Every automatic change is an `EditRecord`: id, kind, origin loc, path,
node, new_name, fo4 before/after, rationale, optional `emit_rhs`,
`emit_rhs_extras`, `emit_snippet`. Kinds: InsertReg, SplitAssign,
ReorderLocal, RebalanceAssoc, BalanceMux, ExpandName, Annotate.

### Low-level basics

`EditTrace` is ordered application history. Emit consumes it as the
**only** instruction stream for source mutation. If a record has
`emit_rhs` and origin, `rewrite_origin_assigns` / BM rewrite fires. If
it has `emit_snippet`, inject at origin process. If it is InsertReg,
`cut_assigns_from_source` recovers the origin assign.

`fo4_after` on the record is an estimate at apply time. Remeasure may
disagree. Soak headlines use remeasure, not the record.

### High-level basis

The trace is the **audit log** and the **emit IR**. Losing the distinction
(mutating source without a record, or recording without emitting) is how
lean-emit soaks quote FO4 that RTL does not have.

### Purpose

Replay, review, emit.

### Behavioural study

```text
Edit 12 kind=insert_reg origin=gemm.sv:610 new_name=pipe_svt_p1_4
  fo4_before=18.5 fo4_after=10.0
  rationale=budget-fit cut after c_end
Emit reads origin line 610, rewrites assign c_end = pipe_svt_p1_4,
injects always_ff with async-low reset.
```

---

## A53 — Rank by slack

**Implementation.** `rank_paths_by_slack`, `RankedPaths` in `measure.rs`.

### Summary

Timing-valgrind ordering: worst slack first. Split `primary` vs
`multi_cycle`. Ties are stable (path id). Frequency-closure and the
worklist both consume this ranking. The **headline primary** is
`ranked.primary.first()`.

### Low-level basics

Slack = \(B - \mathrm{total\_fo4}\) after classify. A path at exactly
\(B\) has slack 0 and is not failing. `rank_regions_by_cost` is the
region dual for reports. `line_cost_map` attributes FO4 to source lines
for traces.

### High-level basis

Ranking is how a 56 FO4 atomic and an 18.5 Plain sibling compete for
attention. After classify, the atomic may be MultiCycleTagged and
**leave** primary. That is why analyze `max_adj` 74.5 and emit primary
18.5 can coexist: they are different sets.

### Purpose

Define “worst.”

### Behavioural study

```text
Before classify: gemm mul 74.5, gemm span 18.5, l2_mshr 20, fifo 16
After v24 classify: l2_mshr UnderBudget 10, mul Atomic/MC, span Plain 18.5
primary.first = span 18.5
That is the soak headline. max_adj on analyze.json may still be 74.5.
```

---

## A54 — Analyze cache fingerprint

**Implementation.** `crates/sv-timing-cache/src/{fingerprint,crc,pathkey,store,analyze_cache}.rs`.

### Summary

IR-only SQLite cache. Hits skip re-parse/re-lower/re-classify when the
fingerprint matches. Detector version and measurement version are part
of the key. `OptOptions::analysis_digest` includes effort and cache_mode
only.

### Low-level basics

CRC of sources + defines + target + measurement version + path_class
detector version. Design-level and module-level tiers. `CacheMode::Off`
bypasses. `Unit`/`Full` are reserved (P17) and fall back to `Ir`.

**Do not reuse sqlite across soaks.** A hit with a stale detector
version should miss (version is in the key); a hit with a **code**
change that forgot to bump the version is a silent lie. When in doubt,
new out-dir.

### High-level basis

Cache is a **correctness hazard** that exists for throughput. The
algorithm is: over-approximate invalidation. Forgetting a version bump
is the bug; an extra miss is not.

### Purpose

Make full-core analyze affordable. Never make it the source of FO4
truth.

### Behavioural study

```text
v23 cache + v24 binary without version bump → l2_mshr still 20 in a
"new" soak. v24 DID bump PATH_CLASS_DETECTOR_VERSION. Always bump.
```

---

## A55 — Debug snapshot / algo trace

**Implementation.** `debug_export.rs`, `algo_trace.rs` in sv-timing-core;
`ctx.algo_trace.emit` in `pass.rs`.

### Summary

Pass-indexed JSON events: `run.start`, `pass_plan`, `cleanliness`,
`scale`, `pass.start`, `worklist`, `refuse`, `exception`, `apply`,
`measure` (primary_fo4, flat_streak, stage_s4), `stage.s4`, `run.stop`.
This is how v28 was diagnosed (191 applies, primary 30.5, reason
would have been pending-resilient continue).

### High-level basis

The trace is the **flight recorder**. If you change S3/S4 control flow
and do not emit a new event name, the next regression will be
undebuggable. Keep `measure.primary_fo4` and `run.stop.reason` stable.

### Behavioural study

```text
run.stop reason=fixpoint   # v27, correct
run.stop reason=artifacts_p1_p2
run.stop reason=primary_closed
run.stop reason=idle_limit
run.stop reason=stage_budget
run.stop reason=lean_emit_skip_s4
```

---

## A56 — Case-label recover

**Implementation.** `crates/sv-timing-transform/src/case_recover.rs`;
`parse_assign_line` case-label strip in `rhs.rs`.

### Summary

Origin lines inside `unique case` often look like `ADD, SUB: result_o =
adder_result;`. Emit must not write `assign ADD, SUB: …`. Recover the
LHS after the colon; keep labels on the case item; rewrite only the
assign.

### Behavioural study

```systemverilog
unique case (op)
-   ADD, SUB: result_o = adder_result;
+   ADD, SUB: result_o = pipe_svt_p1_1;
endcase
// NOT:
// +   assign ADD, SUB: result_o = pipe_svt_p1_1;  // illegal
```

---

## A57 — Cross-module stitch

**Implementation.** effort in `opt.rs`; stitch in lower/measure (balanced
and thorough).

### Summary

`OptEffort::Fast` is per-module only. `Balanced` (default O1/O2) and
`Thorough` (O3) stitch paths across instance ports so a combo cone that
leaves through an output and enters a child is one path. 4 GHz leftovers
quoted in Part VII are **intra-module** emit primaries; stitch does not
invent the gemm 18.5.

### High-level basis

Stitch is analysis depth, not a transform. It can make a path **longer**
(honest) and therefore more likely to fail. That is measurement
correction in the P5 family. Do not disable stitch to make a soak green.

---

## A58 — Scale correct budget

**Implementation.** `scale_correct_budget` in `relocation.rs`.

### Summary

Full-core soaks cannot use the fixture worklist width. Scale
`worklist_width`, `max_passes`, `idle_limit`, `apply_cap`, `batch_size`
with design size (√modules-style). S3/S4 still split `max_passes/2`.

### High-level basis

Without scale, a 4-pass O2 policy on 400 modules never leaves the FPU.
With scale, diversity (A47) has a budget. Scale must **not** relax
refuse lists.

---

## A59 — CLI surface (the dials you actually type)

**Implementation.** `crates/sv-timing-cli/src/main.rs`.

### Summary

`analyze` / `correct` / emit flags. The 4 GHz soak of record is
equivalent to:

```text
sv-timing correct \
  --target-mhz 4000 --fo4-ps 20 --margin 0.2 \
  --opt-level 3 --allow-latency --real-cut-feeds \
  --opt-max-stages-per-region 20 \
  --modules …   # allowlist; empty allowlist ⇒ correct is a no-op
```

`--real-cut-feeds` sets `PassPolicy.emit_structural` and implies
BalanceMux RTL. `--allow-latency` is the T2 gate. Allowlist empty
returns immediately (`run_correct_passes`).

### High-level basis

The CLI cannot express “S4 until 10.” It can express levels, dials, and
gates. If a soak script adds a flag that reintroduces S4-continue, that
flag is a new algorithm and needs a name in this manual **before** it
ships.

---

## A60 — Inserted-pipe reset / clock convention

**Implementation.** emit dense / insert_register templates in
`pipeline.rs` + `dense.rs`.

### Summary

Inserted flops follow the SoC single-reset strategy:
`always_ff @(posedge clk_i or negedge rst_ni)`, async-active-low, `'0`
reset. No new clock. No latch. Scan is not threaded (review-only emit;
host DFT is out of scope of the package).

### Behavioural study

```systemverilog
+ always_ff @(posedge clk_i or negedge rst_ni) begin
+   if (!rst_ni) pipe_svt_p1_4 <= '0;
+   else         pipe_svt_p1_4 <= c_end_rhs;
+ end
// Never:
// + always @(clk) pipe <= ...
// + always_latch
// + posedge rst
```

This is the coding-philosophy dual inside the package: emit must be
synth-clean even though it is review-only.

---

# Part X — Formal invariants (the type system)

A maintainer should be able to **prove** a change is legal against these
invariants without running a soak. The soak then confirms emit.

## I1 — Budget identity

\[
B = \frac{10^6}{f_{\mathrm{MHz}}\,\mathrm{fo4\_ps}}\,(1-m)
\]
At the campaign point, \(B=10\). Slack \(s = B - F\). Failing iff
\(s < 0\) with epsilon \(10^{-9}\).

## I2 — Critical-path, not sum, inside an expression

For a binary node with billed class cost \(c\) and children costs
\(L,R\): \(F = c + \max(L,R)\) if not Const∘Const, else \(0\). Ternary:
mux + max(cond,then,else). Parallel arms in a tree are max, not sum.

## I3 — Path raw sum, then class replace

Raw \(F_{\mathrm{raw}} = \sum_i F(n_i)\). Adjusted \(F \le F_{\mathrm{raw}}\).
Classification may not **increase** FO4. (If a detector would, it
returns None.)

## I4 — Exclusive mux inequality

For \(k\) mutually exclusive arms with costs \(a_1..a_k\):

\[
F_{\mathrm{silicon}} \le \max_i a_i + c_{\mathrm{mux}}
\]

Unique-case: \(c_{\mathrm{mux}} = \mathrm{model.mux}\) (or 0 if flop D/Q).
Priority: \(c_{\mathrm{mux}} = \mathrm{priority} \times k\). Statement-order
sum \(\sum a_i\) is an upper bound that is **not tight**.

## I5 — Bundle inequality

For independent fields \(f_1..f_n\) with no forward-read edges:

\[
F_{\mathrm{silicon}} \le \max_j f_j + c_{\mathrm{wire}}(n)
\]

Next-state: \(c_{\mathrm{wire}}=0\). Thresholds (n_lhs≥4, nodes≥6) are
**soundness-side** (we may over-bill small bundles), never unsound
(we must not under-bill a real chain).

## I6 — Atomic locality

AtomicOverBudget ⇒ `nodes == 1` and that node is Mul/DivRem > B.
Contrapositive: `nodes > 1` ⇒ not AtomicOverBudget (P4). Leading
Mul > B still refuses cuts (cannot shrink the operator).

## I7 — NBA non-combo

In one `always_ff`, NBA write at statement i and read at j>i do **not**
form a combo edge. IndependentLhsBundle / exclusive flop-D may max them.

## I8 — Handshake temporal identity

If pulse \(p\) and index \(x\) are NBA'd in the same edge and a comb
consumer reads `mem[x]` or `p`, then a register on \(p\), \(x\), or the
consumer changes the protocol cycle. InsertReg forbidden. Proof is
IEEE NBA + same-edge sample, not a module name.

## I9 — T1 preserves latency; T2 adds integer cycles

BalanceMux / SplitAssign / rebalance: cycle count of the cone unchanged.
InsertReg: +1 per cut on that path. N = ceil(M/B) on the scratchboard
is the **justification**, not a license to ignore I8.

## I10 — Emit origin well-typed

Each InsertReg/BM rewrite refers to exactly one source line that still
contains the origin assign after previous edits in the trace, **or**
the rewrite is a twin copy of an already-rewritten equivalent assign.
Violation ⇒ F2. S4-continue violates this in probability as edit count
grows (v28).

## I11 — Measurement versions are incomparable

delay-vK numbers may not be compared to delay-vJ, J≠K, nor detector 24
to 23, without a conversion note. A soak “gain” that is only a version
bump is not a gain.

## I12 — Artifacts abort

P1 ∪ P2 nonempty ⇒ no T1/T2 edits. Proof obligation: the FO4 is not
hardware.

## I13 — Cleanliness does not override I8/I6; exception does not override I8

Exception may override cleanliness (gemm in a mixed module). Exception
may **not** override handshake, wrap, fat FSM, lzc/FPU names, atomic
class, intoout, nodes≤1.

## I14 — Protective incompleteness

Opaque ≥ wrong Mul. An unparsed `32'(n-1)*f(.)` at 18.5 Plain is a
**better** measurement than a parsed Mul 67.5 Atomic, because the
former is S4-admissible P6 and the latter is a lie that also blocks
S4.

## I15 — Fixpoint on the headline

Let \(P_t\) be primary FO4 after pass t. S4 stops when
\(|P_t - P_{t-1}| < g\) twice. Progress on non-headline paths is not
an exception to I10.

---

# Part XI — Laboratory walkthroughs

These are behavioural studies at soak scale. Each is a complete story
from RTL shape through algorithms to the leftover.

## Lab 1 — Gemm span 18.5 (headline)

**Files.** APU gemm sequential tile; fixture
`fixtures/auto_correct/gemm_span.sv`.

**RTL shape.**

```systemverilog
if (ReuseAEn) begin : gen_reuse_a
  assign a_span = 32'(m_q[8:0] - 9'd1) * fmt_row_bytes({16'd0, lda_q}) + k_bytes;
  assign a_end  = a_span + …;
  assign c_span = /* original mul-like */;
  assign c_end  = c_span + …;
end
if (ReuseBEn) begin : gen_reuse_b
  assign b_span = 32'(n_q[8:0] - 9'd1) * fmt_row_bytes({16'd0, ldb_q}) + k_bytes;
  assign b_end  = b_span + …;
  assign c_span = /* identical to gen_reuse_a c_span */;
end
```

**Measure.** delay-v19 leaves `32'(…)` uncast (I14). Compose builds
RegToReg on the span chain. Class Plain (n=4, not exclusive, not
bundle thresholds). Parallel timing makespan=18.5, cycles=2. P6.
Lane CombDatapath. Cleanliness SeqPlusComb (mixed module). Exception
ResilientDatapath (Plain RegToReg >B, n=4<16, no wrap, no P10).

**S4.** Pass 3 cuts `c_span` 74.5→56 (still a mul-ish leftover on that
node — T3-ish 56 may remain as analyze max_adj). Pass 4 cuts `c_end`
18.5→10. Twin copies `c_span` to gen_reuse_b (LHS+RHS match). `a_span`
vs `b_span` RHS differ → no twin. Sibling 18.5 becomes primary.
Fixpoint (I15).

**Emit.** Two InsertRegs, 186 total edits design-wide, integrity green.
Headline 18.5.

**What not to do.** Parse the cast (Lab 5). Continue S4 (Lab 6).
InsertReg `c_span` mul into two muls.

**What to do.** VII.A+B or VII.D.

## Lab 2 — l2_mshr 20 → 10 (detector 24)

**RTL shape.**

```systemverilog
always_ff @(posedge clk_i) begin
  mem_d[idx].waiters[w] <= mem_d[idx].waiters[w] >> 1;
  mem_d[idx].nwait      <= mem_d[idx].nwait - (IDX_W+1)'(1);
end
```

**Measure.** delay-v17: no combo edge between NBAs. delay-v19:
`(IDX_W+1)'(1)` increment. Two nodes, two arms, LHS flop-D (`mem_d`).
Pre-v24 exclusive required 3 arms / 4 nodes → Plain sum 20. v24: 2
arms on flop-D, mux=0, leftover=0 → max_arm ≤ 10 → UnderBudget.

**S4.** Never runs. T0 only.

**Lesson.** A 20 FO4 primary that is two sibling flops is a **class
bug**, not a missing InsertReg. Soak v24 made l2_mshr the headline
until v24 exclusive landed; v27 removed it.

## Lab 3 — axi2mem wrap 14 (lock)

**RTL shape.**

```systemverilog
assign nxt = wrap_boundary + ((cnt_q - ax_req_q.len) << LOG);
```

**Measure.** A9 demotes `len+1` style increments; the WRAP add remains
AddSub 10 plus residual → ~14 Plain n=39 FSM cloud. `path_has_burst_wrap`
true. `is_resilient_datapath` false. Fat FSM n≥16 also false for
resilient. Lane may be CombDatapath; exception refuses.

**S4.** Must not InsertReg. AXI WRAP next-address in the same cycle as
the beat is protocol.

**Lesson.** Plain ∧ over-budget ⇏ S4.

## Lab 4 — Handshake fifo 16 (P10)

**RTL shape.**

```systemverilog
always_ff @(posedge clk_i) begin
  if (push) fifo_q[tail] <= d;
  if (pop)  head <= head + 1;   // increment, LogicBit
end
assign rdata_o = fifo_q[head];
```

**Measure.** Indexed NBA base `fifo_q`. Consumer index `head`.
`path_has_indexed_restore`. HandshakeLock. Lane NextStateFsm.
`g6lc_inval_bus` leftover 16.

**S4.** Refuse. SMT2 pc_bank is the same shape.

**Lesson.** 16 > 10 does not authorize a flop on `head` or on
`rdata_o`.

## Lab 5 — delay-v19 general cast (v25, reverted)

**Hypothesis.** Parse `32'(expr)` fully so gemm span is a real tree.

**Result.** `32'(n-1)*fmt_row_bytes+k` → Mul+add 67.5. Analyze max_adj
74.5→123.5. Emit 20→**40.5**. policy_subcode 40.5 P10 in one reading.
Failed.

**Invariant.** I14. Completeness of parse is not monotonic.

## Lab 6 — S4-continue (v28, reverted)

**Hypothesis.** `while s4_has_pending_resilient && flat: S4`.

**Result.** 18.5→**30.5**, 191 edits, policy_subcode n=16 Plain 30.5.
Origin steal (I10). Failed.

**Invariant.** I15 ∧ I10. Sibling progress is not a license.

## Lab 7 — te_packet missing `assign` (v21)

**Hypothesis.** BM continuous rewrite can drop the keyword if the RHS
is replaced in place.

**Result.** Integrity Parse FAIL. No headline.

**Fix.** Keep `assign`. Test
`balance_mux_rhs_rewrite_keeps_assign_keyword`.

**Invariant.** Integrity is a gate (A45).

## Lab 8 — BM vs InsertReg comment shift (v22)

**Hypothesis.** Order of emit jobs is free.

**Result.** InsertReg origin comment shifted a line; BM rewrote
`stc_elem_q` instead of the mux origin.

**Fix.** BM RHS rewrite before InsertReg. Test
`balance_mux_rewrite_not_shifted_by_insertreg_comments`.

**Invariant.** I10.

## Lab 9 — Exclusive log2 mux tax (timer / l2_mshr 18)

**Hypothesis.** Unique-case of n arms costs \(\log_2 n \times 2.5\) on
top of max_arm.

**Result.** max_arm already 10, tax ~7, leftover ~18, fake P6.

**Fix.** v24 `model.mux` once, 0 on flop-D.

**Invariant.** I4.

## Lab 10 — Package scope `::` (te_packet used_bits)

**Hypothesis.** Only `.` splits hierarchical Const names.

**Result.** `te_pkg::XLEN` Runtime, billed AddSub 10 per term.

**Fix.** delay-v18 `::` split + SCREAMING last segment.

**Invariant.** P1 / A8.

---

# Part XII — Decision trees for a maintainer

## Tree 1 — “This path is 18 FO4. What do I do?”

```text
Is hottest expr Const? ──yes──► P1: fix seed/parse. Abort correct.
Is loc a comment?      ──yes──► P2: fix collect. Abort.
Is path_kind InToOut?  ──yes──► P5: not a flop primary. Do not S4.
Is multi_cycle / MC class / lzc|vfdsu|fpnew|serdiv name?
                       ──yes──► S5 / T3. Do not S4.
Is P10 / indexed restore / pulse+index?
                       ──yes──► HandshakeLock. Do not S4.
Is wrap_boundary / WRAP in RHS/LHS?
                       ──yes──► lock. Do not S4.
Is class Exclusive/Bundle/Dense?
                       ──yes──► S3 BalanceMux only.
Is nodes≤1?
                       ──yes──► P3. If Mul/DivRem: T3. Else uncuttable.
Is nodes≥16 and no over-budget Mul/DivRem?
                       ──yes──► fat FSM. Do not S4.
Is Plain RegToReg nodes>1 FO4>B?
                       ──yes──► Resilient. S4 one cut, remeasure.
Did primary stay flat with a sibling span?
                       ──yes──► VII.B one-shot, not S4-continue.
Else                               ──► re-read class; you missed a type.
```

## Tree 2 — “Emit FO4 went up after my patch”

```text
Integrity Parse? ──yes──► dropped assign / illegal case label / inject site.
Did I parse more expression? ──yes──► compare to v25. Revert if Mul appeared.
Did I change S4 stop? ──yes──► compare to v28. Revert if primary rose.
Did I forget BM-before-InsertReg?
Did I inject at endmodule?
Did I twin-copy differing RHS onto a live net?
Did I reuse sqlite?
Did I soak debug CLI not release?
Else: class version bump without goldens — expected number change,
      not necessarily a regression. Compare **emit primary**, not edit count.
```

## Tree 3 — “Should I bump delay-v or detector v?”

```text
Did Expr cost or Const seed or NBA-edge or compose change? ──► MEASUREMENT_VERSION
Did exclusive/bundle/dense/atomic match or formula change? ──► PATH_CLASS_DETECTOR_VERSION
Did only S4 control flow / emit rewrite change?            ──► neither
                                                            (but new soak dir)
Both cost and class?                                       ──► both
```

## Tree 4 — “Is this a measurement lie or a real cone?”

```text
Would IEEE elaborate it to a constant? ──► lie (P1)
Is the operator in a comment/translate_off? ──► lie (P2/v3)
Are exclusive arms being summed? ──► lie (I4)
Are independent NBA fields being summed? ──► lie (I7)
Is a generate index billed as Mul? ──► lie (A12)
Is a PoT `* 8` billed as Mul? ──► lie (A9)
Is `x+1` billed as CPA? ──► lie (A9)
Is `32'(n-1)*fmt_row_bytes` billed as Mul 56? ──► lie (I14) — do not "fix"
Is a same-edge fifo head billed as a cuttable add? ──► real protocol, not a lie;
                                                       still not cuttable (I8)
Is a 32-bit add of two runtime nets billed 10? ──► real. At B=10 it IS the period.
```

---

# Part XIII — Operator billing atlas

A maintainer changing `expr.rs` should consult this atlas before adding
a demotion. Every row is “spelling → billed class → FO4 at 32-bit →
notes.”

| Spelling / shape | Class | FO4 | Notes |
|---|---|---:|---|
| `&` `\|` `^` `&&` `\|\|` `~` `!` | LogicBit | 1 | |
| `==` `<` … | Compare | 4 | |
| `<<` `>>` const / `**` | ShiftConst | 2 | `2**lvl` decoder |
| `<<` variable | ShiftVar | 12 | |
| `+` `-` two runtime | AddSub | 10 | whole period at 4 GHz |
| `x+1` `x-1'd1` `x-(W)'(1)` | LogicBit | 1 | A9 increment |
| `x + CONST` | LogicBit | 1 | A9 offset |
| `*` two runtime, not PoT | Mul | 56 | T3 if lone |
| `x * 8` PoT literal | Other | 1 | A9 shift |
| `/` `%` runtime divisor | DivRem | 120 | T3 |
| `x / CONST` | Other | 1 | A9 |
| `?:` | Mux | 2.5 + max | |
| unique-case n arms | Mux once | 2.5 + max_arm | v24; 0 if flop-D |
| priority if n | PriorityMux×n | 3n + max | |
| `{}` concat | Concat | 0.5 + max | |
| `{N{e}}` | body only | | N is LRM-const |
| `[msb:lsb]` | 0 on bounds | | delay-v4/v9 |
| `[i +: W]` | index base | | W const, i maybe runtime |
| `$clog2(CONST)` | 0 | | P1 |
| `$clog2(runtime)` | Other | 1 + max | |
| `fmt_row_bytes` / `ai_fmt_bytes` | Mux | 2.5 + shifts | M20; not Mul |
| unknown `f(a,b)` | Other | 1 | A69 N; **not** Mux (v49) |
| `pkg::SCREAM` | Const | 0 | delay-v18 |
| mixed-case localparam (`MaxBurstBeats`) | Const | 0 | A8 localparams, not M25 |
| exclusive `x = 4` combo | Const | 0 | M25 auto-const |
| `Cfg.field` | Const | 0 | |
| genvar in span | Const | 0 | delay-v13/15 |
| comb-for index | Const | 0 | delay-v16 |
| `32'(1)` | 1 | | narrow v19 |
| `32'(ident)` / `PLEN'(x)` | ident | | delay-v21 A10; not `int'(x)` |
| `32'(n-1)*row` | Opaque / uncast | | **do not parse** |
| `x + (c?lit:lit)` | LogicBit | 1 | M21 |
| const-condition `?:` | live arm | | A62; no mux |
| `x == 0` / `x != 0` | LogicBit | 1 | M23 |
| `c?Const:(c2?Const:tail)` | one Mux | 2.5 + tail | A64 |
| `x + (1<<n)` | Mux | 2.5 | M26 |
| `{x, {K{0}}} + (y<<K)` / `aligned+(y<<K)` / `aligned+t` | Concat | ~0.5 | M27 |
| wrap-from-Call `+ (y<<K)` | AddSub | 10 | A67; InsertReg forbidden |
| signed `x > 0` | LogicBit | 1 | A68 |
| comment `*` | none | 0 | P2 |
| translate_off | excluded | | delay-v3 |
| bare genvar `i*N` no RHS | Other×2 | 2 | not Mul |

Width: table is 32-bit-normalized. If a node has `width` and
`width_defaulted=false`, measure may scale; defaulted widths must not
invent a 64-bit mul from an unsized literal. Do not “fix” FO4 by
pretending every add is 8-bit.

---

# Part XIV — Pass loop state machine (full)

States and transitions as actually coded in `run_correct_passes`.

```text
[enter]
  if !correct_enabled or allowlist empty → halt (no-op)
  measure(); plan = plan_from_design
  if plan.abort_correct → halt (artifacts_p1_p2)
  factor_always_ff (review comments)
  scale budgets
  stage_s4 = false; flat_streak = 0; last_primary = primary FO4
  stage_budget = max(1, max_passes/2)
  stage_passes = 0

[loop] for pass in 1..max_passes
  pass_index++; stage_passes++
  work = order_worklist_with_plan(...)
  filter:
    if !emit_structural → drop all
    if stage_s4 → keep InsertReg or resilient (force InsertReg opp)
    else → keep latency-neutral
  if stage_s4:
    re-attach resilient missing from work
    sort resilient < shallow P6 < slack
  if work empty and !stage_s4 and allow_latency and emit_structural:
    stage_s4=true; stage_passes=0; flat_streak=0; continue  (s3_empty)
  if work empty and !stage_s4 and !emit_structural:
    halt (lean_emit_skip_s4)

  batch = first batch_size distinct modules, then fill same-mod
  for item in batch:
    cleanliness gate unless exception admit InsertReg
    apply_work_item
    if InsertReg: insert_reg_by_module[m]++
    if !applied: skip path, count refuse
    if applied_count[path] >= cap: skip path
  if no apply: idle_streak++; if idle_streak>=idle_limit halt (idle_limit); continue
  idle_streak = 0
  measure()
  now = primary FO4
  if |last-now| < min_gain: flat_streak++ else flat_streak=0
  last = now
  if primary slack≥0: halt (primary_closed)
  if flat_streak≥2:
    if !stage_s4 and allow_latency and emit_structural:
      stage_s4=true; stage_passes=0; flat_streak=0; continue (s3_fixpoint)
    else halt (fixpoint)   # NOT pending-resilient
  if stage_passes≥stage_budget:
    if !stage_s4 and allow_latency and emit_structural:
      enter S4 (stage_budget)
    else halt (stage_budget)

[after loop]
  S5: count T3 cards, P8, P9; report; no edits
```

**Forbidden transition (reverted):** `flat_streak≥2 && stage_s4 &&
s4_has_pending_resilient → continue S4`.

**Allowed future transition (VII.B):** `just_applied && stage_s4 &&
primary_flat && sibling_span(next) && extra_used==0 → apply once;
extra_used=1; do not generalize`.

---

# Part XV — Emit pipeline (full)

Order in `apply_edits_to_source_dense`:

1. Collect `CutAssign` from source + InsertReg records (`rhs.rs`).
2. Apply BalanceMux `emit_rhs` / `emit_rhs_extras` **first** (line rewrite,
   keep `assign`).
3. Rewrite InsertReg origins to `lhs = pipe` / `lhs <= pipe` / `assign lhs = pipe`.
4. Twin-copy identical LHS+RHS assigns in generate-if twins.
5. Inject BM snippets at the **origin process** (not first `endmodule`).
6. Inject dense sidecar: pipe declarations, `always_ff` async-low, optional
   lean `svt_zero` feeds if `!real-cut-feeds`.
7. Origin comments `// sv-timing …`.
8. Integrity reparse.

Failure modes mapped:

| Symptom | Step | Fix |
|---|---|---|
| dropped `assign` | 2 | keep keyword |
| `stc_elem_q` rewritten | 2 after 3 | BM first |
| twin stale | 4 | identical RHS only; VII.A for spans |
| snippet after decls in wrong process | 5 | origin process |
| lean FO4 ≠ RTL | 6 | `--real-cut-feeds` |
| Parse fail | 8 | fail soak |

Inserted pipe template (A60) must match CVA6 reset: `posedge clk or
negedge rst_ni`.

---

# Part XVI — Strategic reading of the 4 GHz campaign

This is the same campaign as Part VII, told as a **sequence of
algorithm identities**, so a new maintainer sees why the code looks
like it does.

1. **Statement-order sums** at 4 GHz produced hundreds of InsertRegs
   (645). Identity: A19/A20/A21 did not exist yet as types.
2. **Exclusive + bundle + dense + MC tag** removed FPU spray and
   FSM spray. Identity: I4, I5, A18. Residual: fake mux tax, 2-arm
   flop-D miss, `::` Const miss, `x+1` CPA miss.
3. **delay-v18 / detector 23–24** removed those measurement lies.
   Headline moved to gemm 18.5. Identity: A8 A9 A22 v24.
4. **P5 compose** made flop primaries the headline, not intoout.
5. **Exception policy** let gemm S4 live in a mixed module without
   unlocking wrap/P10/lzc.
6. **S3 then S4, two-flat stop** stopped 192-edit flat runs.
7. **Real-cut-feeds + BM-before-IR + keep assign + origin inject**
   made emit match IR enough to quote 18.5 honestly.
8. **Two failed monotonicities** (more parse, more S4) both **raised**
   FO4. Identity: I14, I10, I15.
9. **Current state:** typed leftover, sibling span, floor not 10.

The architectural design, as a first-class citizen, is therefore:

> A measurement compiler with a type system (class, lane, P-id,
> exception) and a staged rewrite system (S3 T1, S4 T2, emit M7)
> whose soundness conditions (I1–I15) forbid the two obvious ways
> to “just get to 10.”

Getting to 10 on **admitted** cones is VII.A+B (or D) + E + C.
Getting to 10 on **all** cones is a different project (microarch).

---

# Part XVII — Worked numeric examples (keep a pencil here)

## Ex 1 — Four independent LogicBits vs a chain

```systemverilog
assign t0 = a ^ b;  // 1
assign t1 = c ^ d;  // 1
assign t2 = e ^ f;  // 1
assign y  = t0 ^ t1 ^ t2; // 1 + max, tree: 1+1=2 critical if balanced
```

Raw if one region summed statement-order: 4. Makespan: 2. At B=10,
UnderBudget either way. No S4.

## Ex 2 — One CPA and a xor

```systemverilog
assign t = a + b;   // 10
assign y = t ^ m;   // 1
```

Raw 11. Compose RegToReg if t/y captured. P6. S4 cut after t:

```systemverilog
- assign y = t ^ m;
+ always_ff @(posedge clk_i or negedge rst_ni)
+   if (!rst_ni) p <= '0; else p <= t;
+ assign y = p ^ m;   // this cycle: 1. previous cycle: 10. Both ≤ B.
```

Latency +1. Legal iff y is not a same-edge handshake.

## Ex 3 — Unique case of seven 10 FO4 arms

Raw 70. v23 tax log2(7)*2.5≈7 → adj 17. v24 tax 2.5 → adj 12.5. Flop-D
tax 0 → adj 10. UnderBudget. The 18 FO4 “timer” leftover was Ex 3 with
the v23 tax.

## Ex 4 — `len+1` then shift then wrap add

```systemverilog
assign nxt = wrap_boundary + ((ax_req_q.len + 1) << 3);
```

Pre-A9: 10+10+2 = 22. A9: 1+2+10 = 13. Wrap lock: not resilient. S5.

## Ex 5 — Package const sum

```systemverilog
assign used_bits = 1 + te_pkg::PRIV_LEN + te_pkg::XLEN + 2 + te_pkg::TIME_LEN;
```

Pre-v18: ~50 AddSub. v18: 0. P1. If this is still hot in a soak, the
seed missed a name — abort correct, do not pipeline.

## Ex 6 — Gemm span arithmetic (protective)

Incomplete parse: suppose billed as Other+Add+Other ≈ 18.5 chain of 4
nodes. Cycles=2 at B=10. One InsertReg on `b_span` → 10. Twin A needed
for `a_span`. That is the headline.

Parsed as Mul: 56+10=66, Atomic or leading-mul refuse, emit 40.5 after
the rest of the cone still sums. Worse.

## Ex 7 — JIT scratchboard justification

Nodes: costs 6, 6, 6. Independent: M=6, N=1, no cut. Serial:
M=18, N=2, JIT cut after the first or second 6 (budget-fit: after two
6's = 12>10, so after first 6: segments 6 | 12, still not closed;
second cut: 6 | 6 | 6). max_cuts≥2. P6/P8 Plain only.

## Ex 8 — Cleanliness numbers

Module: 2 always_ff, 1 always_comb, 0 assign, exclusive yes, datapath
yes, failing 1/4 primaries. SeqPlusComb A=0.30, D_ff≈1, D_comb≈1,
pass=false (datapath still fails). C = 0.4+0.4-0.2*0.30-0.50 = 0.14.
JitDatapath A higher, pass=true (presumed). If pass(Jit)=true, pool is
feasible-only; Jit may win despite higher A because \(w_t\) is large.
Exception still needed if SeqPlusComb wins on a mixed profile that
**presumes** exclusive closes the module — the gemm path is the hole.

## Ex 9 — Frequency inversion

F=18.5, fo4_ps=20, m=0.2:
period = 18.5 * 20 / 1000 / 0.8 = 0.4625 ns → 2162 MHz.
F=10 → 4000 MHz.
F=30.5 → 1311 MHz.
F=56 → 714 MHz (mul as single-cycle — why T3 exists).

## Ex 10 — min_gain vs 18.5 sibling

last_primary=18.5, cut sibling, now_primary=18.5, min_gain=1.0,
|Δ|=0 < 1 → flat_streak++. Two such passes → fixpoint. This is Lab 1's
stop, not a scheduler miss.

---

# Part XVIII — Mutation catalog (what each algorithm may rewrite)

A change-control view. If your patch mutates a column it should not,
it is in the wrong file.

| Algorithm | Seed | Node FO4 | Path FO4/class | Lane | Clean | Opp | IR graph | Source |
|---|---|---|---|---|---|---|---|---|
| A1 budget | | | slack via B | | | | | |
| A2 table | | base | | | | | | |
| A8 lattice | yes | yes | | | | | | |
| A9 billed | | yes | | | | | | |
| A10 cast | | yes | | | | | | |
| A14 NBA-Q | | | via class | | | | edges | |
| A15 attribute | | yes | raw | | later | | | |
| A16 compose | | | new paths | | | | fans | |
| A17 primary loc | | | loc | | | | | origin |
| A18 MC tag | | | flag | | | | | |
| A21 class | | | adj+kind | | | | | |
| A27 P10 | | | note | NextState | | | | |
| A30 lane | | | | yes | | | | |
| A31 clean | | | | | yes | gate | | |
| A32 exception | | | | | override | S4 | | |
| A36 factorize | | | | | | | | comments |
| A37 BM | | credit | | | | | maybe | **yes** |
| A38 split | | | | | | | nodes | **yes** |
| A39 rebal | | | | | | | expr | **yes** |
| A40 InsertReg | | lock | | | | | nodes | **yes** |
| A42 spine | | lock | | | | | nodes | maybe |
| A43 emit | | | | | | | | **yes** |
| A46 S0–S5 | | | via measure | | | filter | | via apply |

Source column **yes** is why I10 exists. Everything else is analysis.

---

# Part XIX — Suggested study order for a systems programmer

Week-scale, assuming you already write compilers.

**Day 1.** A1–A4, I1, I11. Run `cargo test --lib` on
`plus_one_is_increment_not_carry_propagate_add` and
`package_scope_screaming_idents_are_elaboration_const`. Read
`resources/fo4-v1.toml`. Internalize \(B=10\) ⇒ add is the period.

**Day 2.** A7–A10, atlas Part XIII, Lab 5. Add a throwaway parse of
`32'(a+b)` locally, watch the test forbid it, revert.

**Day 3.** A15–A20, I2 I3 I7. Sketch ASAP on a 4-assign comb. Read
`ref_order.rs` `is_write_only`.

**Day 4.** A21–A26, I4 I5 I6, Labs 2 and 9. Read
`try_exclusive_shared_lhs` mux=0 flop-D branch.

**Day 5.** A27–A32, I8 I13, Labs 3 4. Read `handshake_locked_names`
distinct_lhs≥2.

**Day 6.** A34–A42, I9, Ex 2 7. Read `schedule_pipeline_cuts` leading-mul
refuse.

**Day 7.** A43–A49, I10 I15, Labs 1 6 7 8. Read `run_correct_passes`
flat_streak block. **Do not** patch it until you can recite v28.

**Day 8.** Part VII. Propose A or B or D on paper with a fixture. If
your proposal is “loop S4 harder,” throw it away.

After that you can maintain the codebase: every leftover names a row in
the Part VII table; every patch names an invariant.

---

# Part XX — FAQ the soaks already answered

**Q. Can we lower AddSub from 10 to 6 so 4 GHz has room?**
A. No. That is retuning the ruler. STA would disagree. I1.

**Q. Can we InsertReg the mul into two 28 FO4 halves?**
A. No. A multiplier is not a chain of two half-multiplies the package
knows how to emit. T3 NumPipeRegs. I6.

**Q. Can we InsertReg `fifo_q[head]` and add a ready delay?**
A. Not automatically. That is a protocol change. I8. SMT2 one-cycle
switch is the existence proof of damage.

**Q. Can we parse all width casts now that v19 is narrow?**
A. v25 already did. Emit 40.5. I14.

**Q. Can we keep S4 going for sibling 18.5?**
A. Only as VII.B (bounded, LHS sibling). v28 unbounded continue → 30.5.

**Q. Why is analyze max_adj 74.5 when emit is 18.5?**
A. T3 mul still exists; it is not the emit primary. A63.

**Q. Why did cleanliness refuse gemm InsertReg?**
A. Module-global SeqPlusComb. A32 exception is the hole. If still
refused, check P10 note < 2B and lane.

**Q. Why twin-copy `c_span` but not `b_span`?**
A. Identical RHS vs not. A44. VII.A is the generalization.

**Q. Is 18.5 a bug in schedule_pipeline_cuts?**
A. No. The scheduler would cut. Fixpoint stopped. A48 / Ex 10.

**Q. Is structural 10 FO4 tape-out?**
A. No. Screening. Host STA remains. This package never signs off.

**Q. Where is the architecture doc I should read next?**
A. You should not need one. This manual + the implementation files in
the Part 0 map are the maintenance surface. Architecture markdown is
historical design trail, not a second source of truth.

---

# Part XXI — Copy-paste fixtures for future detectors

When you add VII.A/B/C/D/E, start from these shapes (already on disk or
minimal deltas).

**Span pair (VII.A):** `fixtures/auto_correct/twin_generate_span.sv` plus
a sibling with **different** RHS, same LHS ident pattern `*_span` in
named blocks. Assert both origins rewrite.

**Bounded sibling (VII.B):** gemm_span after one InsertReg, primary still
18.5, second apply only on `b_span`, third apply must **not** fire on
`policy_subcode`-like Plain. Assert emit FO4 does not rise.

**Small FSM (VII.C):** two `_d` fields, 4 nodes. Assert class
IndependentLhsBundle or exclusive flop-D, adj ≤ 10, no InsertReg.

**fmt_row_bytes (VII.D):** `x * fmt_row_bytes(y)` demotes; `x * runtime`
does not; `32'(a+b)` still does not parse as AddSub.

**Queue remainder (VII.E):** 9-node Plain 15.5 with an already rewritten
origin nearby. Assert the new cut does not retarget the closed line.

**Wrap (must stay red):** `wrap_boundary + …` never resilient.

**P10 ternary:** `assign o = empty ? '0 : mem[port];` never InsertReg.

---

# Part XXII — Glossary expansion (terms you will see in traces)

| Trace token | Meaning |
|---|---|
| `total_fo4` | Adjusted after classify |
| `total_fo4_raw` | Statement-order sum |
| `class_note` | Evidence string; may contain `P10 handshake` |
| `primary_loc` | Hottest node loc (A17) |
| `flat_streak` | Consecutive measures with Δprimary < min_gain |
| `stage_s4` | Boolean in the pass loop |
| `cleanliness_set` | Refuse reason: module winner forbids this kind |
| `exception` | Path-level override fired |
| `emit_structural` | Real RTL mutation, not lean |
| `real-cut-feeds` | Pipe D from origin RHS |
| `policy_subcode` | A module whose origin was stolen in v22/v28 |
| `max_adj` | Max adjusted FO4 in analyze (may be T3) |
| `post_analyze` | Re-analyze of **emitted** sources — soak headline |
| `from_cache` | sqlite hit; treat as suspect if unexpected |
| `discourages_insert_reg` | Class boolean A21 |
| `allows_insert_reg` | Lane boolean A30 |
| `admit_insert_reg` | Exception boolean A32 |
| `min_gain_fo4` | Dial 5; O3 = 1.0 |
| `max_stages_per_region` | Dial 4; O3 = 8; cuts clamp 16 |
| `worklist_width` | Dial 2; scaled up on full core |

Conjunction for a legal S4 apply:

```text
emit_structural
AND allow_latency
AND stage_s4
AND (exception.admit OR admits_insert_reg)
AND (exception.admit OR cleanliness.allows InsertReg)
AND lane CombDatapath   # resilient gemm is this
AND not wrap, not fat-FSM, not P10-real, not MC, not nodes≤1
AND module allowlisted
AND insert_reg_by_module[m] < stages
AND path not in skipped
```

If any conjunct is false, do not “just apply.” Name it.

---

# Part XXIII — Dual of the SoC prime directive (inside this package)

LibreCore §0 says synthesizability and timing closure come first. This
package does not tape out, but its **emit** is SystemVerilog that a
partner might copy. Duals:

1. Inserted logic is `always_ff`/`always_comb`, async-low reset, no new
   clock, no latch (A60).
2. Parameterization of the **host** stays in `CVA6Cfg`; this package
   must not hardcode host names (KD0). Structural tokens
   (`wrap_boundary`, `_d`, `generate`) are allowed.
3. Verification dual: `cargo test --lib` + integrity reparse + soak.
   `./build.sh verify` is host-side; do not skip package tests because
   a host verify is green.
4. Observability dual: algo_trace + edit trace + origin comments.
5. Documentation dual: **this file**, updated when an algorithm
   changes identity. Not a new architecture markdown for a detector.

Timing-impact note for any patch: quote emit primary before/after, class
of the headline, and which invariant you relied on.

---

# Part XXIV — Index of tests that pin theory

Grep these names when you touch the corresponding algorithm. Windows:
one `--lib` filter per invocation.

| Test name | Pins |
|---|---|
| `plus_one_is_increment_not_carry_propagate_add` | A9 A10 I14 |
| `package_scope_screaming_idents_are_elaboration_const` | A8 |
| `literal_power_of_two_multiplication_is_cheap` | A9 |
| `exclusive_case_reduces_sum_of_arms` | A22 I4 |
| `exclusive_flop_capture_is_max_arm_not_mux_plus_leftover` | A22 v24 |
| `exclusive_flop_capture_two_arms_is_max_not_sum` | A14 A22 v24 |
| `exclusive_parallel_prep_lhs_not_serial_residual` | A22 leftover=0 |
| `next_state_multi_write_field_is_max_not_log_mux` | A23 |
| `p10_ternary_indexed_restore_refuses_insert_reg` | A27 A28 |
| `resilient_skips_burst_wrap_and_fat_fsm` | A32 |
| `resilient_exception_matches_gemm_shaped_plain_regtoreg` | A32 |
| `resilient_exception_skips_prefix_tree_names` | A32 lzc |
| `balance_mux_rhs_rewrite_keeps_assign_keyword` | A37 A43 |
| `balance_mux_rewrite_not_shifted_by_insertreg_comments` | A37 I10 |
| `balance_mux_snippet_injects_after_mid_module_decls` | A37 |
| `balance_mux_snippet_injects_before_first_process` | A37 |
| `multi_cut_insert_applies_multiple_regs` | A40 A41 (set stages=4) |
| `preset_matrix_matches_spec` | A34 |
| `lanes_gate_insert_reg` | A30 |
| `embedded_fo4_matches_mul` | A2 |
| `p6_shallow_is_one_slice_over_budget` | A29 |
| `empty_design_does_not_abort` | A29 S0 |
| `delay_v21_const_select_mux_and_width_cast` | A10 M20 M21 M22 M23 |
| `delay_v22_const_then_mux_chain_is_one_mux` | M24 |
| `delay_v23_stride_add_aligned_insert_sign_and_call` | M26 M27 M28 M29 N |
| `auto_const_expression_less_exclusive_read` | M25 |
| `auto_const_skips_nba_and_write_only_and_multi_writer` | M25 |
| `auto_const_aligned_zero_pad_names_field_insert` | M27 |
| `auto_const_aligned_double_brace_ident_pad` | M27 axi2mem `{{LOG}{0}}` |
| `auto_const_aligned_plus_staged_shift_temp` | M27 delay-v25 |

If you delete one of these to make a refactor green, you deleted a
piece of the 4 GHz theory. Restore it.

---

# Part XXV — Closing: what “maintain the codebase himself” means

You can maintain sv-timing when you can, without opening
`architecture/*.md`:

1. Compute \(B\) and invert FO4 to MHz (A1, A3).
2. Point at a SystemVerilog assign and name billed class + FO4 (atlas).
3. Point at a path and name class, P-id, lane, exception, and whether
   S3, S4, or S5 owns it (Trees 1–4).
4. Explain why gemm is 18.5 and why v25/v28 made it worse (Labs 1 5 6).
5. Recite I8, I10, I14, I15 from memory.
6. Add a detector or a bounded transform with a fixture and a version
   bump, soak a new dir, and stop if emit FO4 rises.
7. Leave P10, WRAP, and Mul 56 on the S5 floor without feeling that the
   tool is “incomplete.”

The remaining gap to ~10 is **determined**: sibling span (A+B or D),
queue remainder (E), small-FSM measure (C), floor not 10 (F). The
architectural design is not a backlog of architecture files. It is the
type system in `path_class.rs`, the staged loop in `pass.rs`, the
line-based emit in `sv-timing-emit`, and the refusal predicates in
`pass_strategy.rs`. Keep those four honest and the rest of the package
stays small.

The architectural design **is** the algorithm: a typed measurement of
structural FO4, a staged application of T1 then T2, a line-based emit, and
a refusal to lie about handshakes, wraps, and multipliers. The remaining
gap to 10 is a sibling span plus a queue remainder plus a floor that is
not 10. Maintain the types; do not lengthen S4.

---

# Part XXVI — Detector internals the first patch will hit

The A21 block named classification. This chapter is the **control flow
inside** `classify_and_adjust_paths` and `scan_deflate_detectors`, because
that is where a one-line patch silently changes every soak number.

## A61 — Cheap exits, cache hints, never freeze Plain

**Implementation.** `classify_and_adjust_paths` in `path_class.rs` after the
multi_cycle / under-budget branches.

### Summary

Cache hints may reuse a **non-Plain** class. Plain and UnderBudget hints
are **not** reusable: new detectors must re-scan. Atomic hints clamp to
raw (operator cost, not serial sum). Other hints scale by
`adjusted/raw` ratio if the node costs moved proportionally.

### Low-level basics

```text
if hint.class in {Plain, UnderBudget}: fall through to expensive scan
if hint.class == AtomicOverBudget: adj = hint.adj.clamp(0, raw)
else: adj = raw * (hint.adj / hint.raw)
confidence *= 0.95
evidence = "cache-hint: …"
```

Signature includes `PATH_CLASS_DETECTOR_VERSION`, so a bump invalidates
even non-Plain hints. Forgetting the bump is the only way a v24 exclusive
formula fails to run on a cached v23 exclusive path.

`classification_scratch(...).procedural_ok` must still hold on reuse;
otherwise the hint is dropped (NBA-as-Q invalidation).

### High-level basis

Caching a Plain result would **prevent** v24 from ever firing on l2_mshr.
The rule “never freeze Plain” is how the type system stays open to new
proofs without deleting the sqlite file by hand.

### Behavioural study

```text
v23 hint: l2_mshr ExclusiveCaseMux adj=18 (log2 mux tax)
v24 binary, version bumped: signature miss, re-scan, adj=10, UnderBudget
v24 binary, version NOT bumped: signature hit, adj scaled ~18, still headline
```

Always bump the detector version when a formula changes.

---

## A62 — P4 peel (atomic remainder)

**Implementation.** `p4_peel_amount` referenced from `classify_and_adjust_paths`.

### Summary

A multi-node path that contains an over-budget Mul/DivRem is **not**
AtomicOverBudget (I6). The atomic node's FO4 is **peeled** out of the
adjusted (or raw) total so the remainder is the cuttable cone. Evidence
string: `P4 remainder − atomic … is T3`.

### Low-level basics

If a deflator matched (exclusive/bundle/…): `adj = adj - peel`.
If nothing matched (Plain): `adj = raw - peel` when peel is known, else
raw with a T3 note.

This is why `pe_dot` 333 FO4 that included a 130 DivRem did not brand
the whole path atomic and suppress remainder cuts.

### High-level basis

P4 is the dual of P3. P3: one node, nothing to cut. P4: many nodes, one
of them T3 — **cut the others**, report the T3 separately. Branding the
union atomic was the cache_ctrl / wt_axi_adapter suppression in
audit-strict-v4.

### Behavioural study

```systemverilog
always_comb begin
  p = a * b;       // 56, T3 peel
  y = p ^ c ^ d;   // remainder ~2
end
// Class Plain (nodes>1). Adjusted ≈ raw - 56.
// schedule_pipeline_cuts still refuses a **leading** mul > B.
// Remainder after the mul can be PrepStage in the next cycle (T3 unit).
```

---

## A63 — PassPolicy gates (what a level cannot grant)

**Implementation.** `PassPolicy` in `crates/sv-timing-transform/src/pass.rs`.

### Summary

| Field | Default | Who sets it | Level can grant? |
|---|---|---|---|
| `correct_enabled` | false | allowlist nonempty ∧ max_passes>0 | no (needs allowlist) |
| `correct_allow_modules` | empty | caller | **no** |
| `allow_latency` | false | `--allow-latency` | **no** |
| `max_passes` | from opt | dial 1 | yes |
| `refuse_path_prefixes` | empty | caller | no |
| `worklist.max_items` | dial 2 | opt | yes |
| `emit_structural` | true in lib tests; CLI lean=false | `--real-cut-feeds` | **no** |

`from_opt` documents: “a level never grants allowlist or allow_latency.”
Library tests set `emit_structural: true` so IR rewires are exercised;
CLI soaks overwrite from flags. Lean soak without `--real-cut-feeds`
must not book 304.5→96.5 that the emitted SV does not contain.

### High-level basis

Safety gates are **not dials**. A maintainer who adds `--opt-level 3`
to a command without `--allow-latency` gets S3 only. That is intentional.
A maintainer who adds `--allow-latency` without `--real-cut-feeds` gets
IR FO4 that RTL does not have. That is the lean-emit lie.

### Behavioural study

```text
correct -O3 --modules gemm
  → S3 only (no allow_latency). No InsertReg. Gemm 18.5 stays 18.5.

correct -O3 --allow-latency --modules gemm
  → S4 IR cuts, lean emit unless real-cut-feeds. Headline may drop in
    IR and not in RTL.

correct -O3 --allow-latency --real-cut-feeds --modules gemm
  → v27 geometry. The only honest T2.
```

---

## A64 — Cleanliness catalog, complete

**Implementation.** `algo_set_catalog` in `cleanliness.rs`.

| Set | A | ff | excl | split | jit | multi | mc |
|---|---:|---|---|---|---|---|---|
| ClassifyOnly | 0.00 | | | | | | |
| FfFactorClock | 0.10 | ✓ | | | | | |
| CombExclusive | 0.20 | | ✓ | | | | |
| MulticycleHonest | 0.25 | | | | | | ✓ |
| SeqPlusComb | 0.30 | ✓ | ✓ | | | | |
| CombSplit | 0.40 | | ✓ | ✓ | | | |
| JitDatapath | 0.70 | | | ✓ | ✓ | | |
| AggressivePipeline | 0.95 | | | ✓ | ✓ | ✓ | |

`allows_opportunity(InsertReg)` iff jit ∨ multi. That is why SeqPlusComb
refuses InsertReg and gemm needs A32.

Worked score, defaults \(w_{ff}=w_{comb}=0.4\), \(w_a=0.2\), \(w_t=0.5\),
densities 1:

| Set | pass? | C |
|---|---|---:|
| ClassifyOnly | yes | 0.80 |
| ClassifyOnly | no | 0.30 |
| CombExclusive | yes | 0.76 |
| SeqPlusComb | no | 0.14 |
| JitDatapath | yes | 0.66 |
| AggressivePipeline | yes | 0.61 |

If **any** set passes, the feasible pool excludes SeqPlusComb-failing.
JitDatapath at 0.66 beats AggressivePipeline at 0.61 (lower A). If the
profile **presumes** CombExclusive passes (exclusive leftovers only),
Jit never enters the feasible pool and gemm is stuck — hence exception.

---

# Part XXVII — Pattern catalog, one lab each (P1–P10)

## P1 lab — Const billed as hardware

```systemverilog
localparam int W = 32;
assign y = W * 2;          // Const∘Const = 0, not Mul 56
assign z = te_pkg::XLEN + te_pkg::VLEN;  // 0 after delay-v18
```

If a soak still shows these hot: seed missed the name (`from_names` /
package import). `hottest_expr_is_const` → P1 → `abort_correct`.
**Do not** InsertReg. Add the name to the seed; bump delay-v.

## P2 lab — Comment billed as arithmetic

```systemverilog
assign y = a + b; // y = a * coeff + bias
```

The `*` must not be a node. If it is, collect-time
`operator_token_in_comment` failed. Abort. Fixture
`fixtures/parse/comment_interiors.sv`.

## P3 lab — One node over budget

```systemverilog
assign y = a * b;   // 1 node, 56 > 10
```

Uncuttable. AtomicOverBudget. T3. `suggest_opportunities` skips
`nodes≤1`. `admits_insert_reg` false.

```systemverilog
assign y = a + b;   // 1 node, 10 = B, slack 0, UnderBudget
assign y = a + b + c; // if parsed as ONE node left-deep 20, P3 if not spine-expanded
```

Spine expand (A42) is the legal way to make P3 into a cuttable chain
**when the node is a tree of adds**, not when it is a mul.

## P4 lab — Atomic node inside a long path

See A62. Remainder cuttable; leading mul > B still refuses
`schedule_pipeline_cuts`.

## P5 lab — Intoout is not a period path

```systemverilog
module m(input logic [31:0] a, b, output logic [31:0] y);
  assign y = a + b;
endmodule
```

InToOut 10 FO4. `frequency_closure.intoout_failing` may count it;
`closes` for core frequency uses RegToReg. `is_resilient_datapath`
requires RegToReg. Do not S4 a port-to-port add to “make 4 GHz”; that
add is the parent module's cone.

## P6 lab — Shallow over budget (75 % of corpus)

```systemverilog
always_ff @(posedge clk_i) q1 <= in_i;
assign t = q1 + k;          // 10
assign y = t ^ m;           // 1 → 11, 10<11<20, nodes>1
always_ff @(posedge clk_i) q2 <= y;
```

One InsertReg after `t`, or one xor folded, and it closes. Origin =
hottest (the add). Do not multi-cut 8 stages.

## P7 lab — Bundle still over budget

```systemverilog
always_comb begin
  a_d = f(a_q); // 12
  b_d = f(b_q);
  c_d = f(c_q);
  d_d = f(d_q);
end
```

IndependentLhsBundle, max_field 12, wire 0 if next-state. Still >B.
S3 BalanceMux / measure (VII.C), **not** four InsertRegs on four D pins.

## P8 lab — Genuine deep datapath

```systemverilog
assign acc = ((a * b) + (c * d)) ^ e;  // if parsed: two muls
```

If one node Mul 56: P3/P8 atomic. If many nodes of runtime adds after
prep: resilient S4. Gemm 161.5 144-node was P8-shaped; after two cuts
the sibling 18.5 is P6.

## P9 lab — Iterative

```systemverilog
module serdiv; /* one bit per cycle */ endmodule
module ct_vfdsu_srt_radix16_with_sqrt; endmodule
```

`tag_multi_cycle_paths` name list. 181 InsertRegs historically. Now 0.
S5.

## P10 lab — Distinct LHS pulse + index

```systemverilog
always_ff @(posedge clk_i) begin
  valid_o <= fire;     // pulse
  idx_o   <= head;     // distinct LHS, output
end
assign rdata_o = mem[idx_o];
```

Lock names: valid_o, idx_o, fire, head, rdata_o, mem. Any path touching
them is P10. Same-LHS reset+data is **not**:

```systemverilog
always_ff @(posedge clk_i) begin
  if (!rst_ni) y_o <= '0;
  else         y_o <= c_span;  // same LHS — gemm capture, resilient OK
end
```

---

# Part XXVIII — Soak chronicle (why the code is this shape)

Each row is an algorithm identity, not a diary.

| Soak | Emit primary | What the algorithms learned |
|---|---|---|
| audit-strict-v4 | edits≫gain | P1/P2 abort; S3-before-S4; two-flat stop; P4 not whole-path atomic |
| audit-pc-v21 | 30.5 / 1311 | hub 36→11 exclusive/bundle; policy_subcode 30.5 still Plain |
| audit-remain-v21 | FAIL integrity | BM dropped `assign` → A37 keep-assign |
| audit-remain-v21b | 26 / 1538 | policy_subcode three InsertRegs 30.5→10 |
| audit-remain-v23 | 22 / 1818 | gemm 26 gone (first span cuts) |
| audit-delay-v18 | 18.5 / 2162 | `::` Const, increment, unique-case mux=2.5; exclusive leftovers gone |
| audit-remain-v24 | 20.0 / 2000 | path_class v23; **new** primary l2_mshr 20 (2-arm miss) |
| audit-remain-v25 | **40.5 / 988** | general width-cast; **reverted** (I14) |
| audit-remain-v26 | 20.0 | narrow `(W)'(1)` does not move l2_mshr (not a cast-1 problem) |
| **audit-remain-v27** | **18.5 / 2162** | v24 2-arm exclusive; l2_mshr gone; historical soak of record |
| audit-remain-v28 | **30.5 / 1311** | S4-continue; **reverted** (I10, I15) |
| v29–v32 | 30.5 then 18.5 | sibling extra recut `c_span`; fat-FSM 16→24; extra-S4 no-op on APU |
| v33–v36 | gemm 18.5 gone | star-add / remainder sandwich (VII.A/E) |
| v37 | FAIL integrity | comma-assign list; **do not quote** |
| v38 | core 20 P10 | full_core GREEN; trigger 20 |
| v39–v42 | APU 16 / core 20 P10 | or-reduce; unique 12 wt_dcache gone |
| v40 | FAIL integrity | unary `\|` vs bitwise `\|`; **do not quote** |
| v43 | APU 40.5 | `int'(group_q)*6` Mul; type-name `'(` **not** collapsed |
| v44 | APU 17 pe_dot | `!= 0` Compare; A63 not yet |
| **v45** | core **15 P10** / APU 16 P10 | delay-v21 A–D; store_unit/snoop 11 gone |
| v46–v47 | pe_dot 14 | Inf concat / `sign[LEVELS]` not encoding yet |
| **v48** | delay-v22 | pe_dot 14→13; headlines 15/16 |
| v49 | gemm 15 | 2-arg Mux tax; **reverted** (F8) |
| **v50** | **15.0/16.0 P10** | delay-v23; dm_sba 12 gone (A66); **quoted soak of record** |
| v51 | APU 22 axi2mem | delay-v24; F9 WRAP-beyond compose; **do not quote 22** |
| **v52** | delay-v25 | same 15 / 22; staged shift (A67) does not close `addr+t` |

Read this table **before** proposing a patch that “just parses more” or
“just loops S4 more.” Both are already in the table as regressions.

v24 vs v27 is the existence proof that a **detector** (2-arm flop-D)
removed a 20 FO4 headline without a single InsertReg. That is the
preferred move at \(B=10\).

---

# Part XXIX — Lowering details that timing depends on

**Implementation.** `crates/sv-timing-core/src/lower.rs`.

## Module scope (delay-v12)

A file:

```systemverilog
module a;
  localparam int W = 8;
  assign y = W * n;
endmodule
module b;
  assign y = i * n;  // i is a port, not a's localparam
endmodule
```

Pre-v12 the file union could seed `W` into `b` or merge regions. Now
each CST slice owns ports/params/regions/instances. Multi-module files
in CVA6 packages depend on this.

## Assign kinds

| Syntax | AssignKind | compose role |
|---|---|---|
| `assign y = e;` | Continuous | comb def |
| `y = e;` in always_comb | Blocking | comb def |
| `y = e;` in always_ff | Blocking | comb temp (not a flop) |
| `y <= e;` | Nonblocking | seq def (Q) |

Mixing blocking and NBA in `always_ff` is legal SV and common for temps.
Compose must not treat the blocking temp as a flop (false launch) and
must not treat the NBA as combo (delay-v17).

## Gen-loop records

Each generate-for records `genvar` name + byte span. Nested loops push
**each** genvar (delay-v15). `attribute_costs` adds every covering
genvar to the node seed. A genvar used **outside** its span is Runtime
(often a bug in the RTL or a missed span).

## Case labels as Const (delay-v8)

```systemverilog
unique case (op)
  (XLEN-1): y = a;   // XLEN-1 is elab-constant, not AddSub in the datapath
endcase
```

BinaryOperator tokens in the **label** CST are not datapath. The arm
body still is.

## Packed dimensions (delay-v8)

```systemverilog
logic [WIDTH*2-1:0] x;
```

The range is LRM-constant. A detector that walks the whole module for
`*` tokens will invent a Mul. Lowering must not emit an IrNode for the
dimension expression as datapath.

---

# Part XXX — Parallel timing, worked schedule

Take this process:

```systemverilog
always_comb begin
  t0 = a + b;          // n0 L=10
  t1 = c + d;          // n1 L=10
  t2 = t0 ^ e;         // n2 L=1  reads t0
  y  = t1 ^ t2;        // n3 L=1  reads t1, t2
  u  = f + g;          // n4 L=10 write-only if unused
end
```

Ref-order forward edges: n0→n2, n2→n3, n1→n3. n4 write-only.

ASAP:

```text
n0: S=0  C=10  ready(t0)=10
n1: S=0  C=10  ready(t1)=10
n4: S=0  C=10  ready(u)=10
n2: S=10 C=11  ready(t2)=11
n3: S=max(10,11)=11 C=12
M = 12
N = ceil(12/10) = 2
```

ALAP from M=12:

```text
n3: must finish 12, L=1 → alap_start=11, slack=0 (critical)
n2: must finish 11, L=1 → alap_start=10, slack=0
n1: must finish 11, L=10 → alap_start=1, slack=1  (can wait)
n0: must finish 10, L=10 → alap_start=0, slack=0
n4: must finish 12, L=10 → alap_start=2, slack=2
```

JIT cut justified on n0 or n2 (zero slack, C crosses kB=10). n4 must
**not** get a flop because slack>0 and write-only — that is FSM spray.
`schedule_pipeline_cuts` on a Plain RegToReg of {n0,n2,n3} at B=10:
cum 10, next 1 would be 11>10, cut after n0 if n0 is not the start of
an empty segment — actually cum=10 ≤10, +1=11>10, cut after n0
(seg_start 0, i=1). Segment 10 | 2. Closes.

If class is IndependentLhsBundle because y/u/t* look like many LHS,
S4 never sees this. Check class before expecting the cut.

---

# Part XXXI — InsertReg apply vs refuse, a complete matrix

Rows are path facts. Columns are gates. A legal apply needs every
**allow** cell.

| Fact | admits_insert_reg | exception.admit | lane.allows | clean.allows | schedule_cuts |
|---|---|---|---|---|---|
| Plain RegToReg P6 gemm span | ✓ | ✓ | CombDatapath ✓ | often ✗ SeqPlusComb | ✓ (sum>B) |
| same + incidental P10 note ≥2B | ✗ (note) | ✓ (≥2B) | CombDatapath ✓ | exception overrides clean | ✓ |
| same + incidental P10 note <2B | ✗ | HandshakeLock ✗ | NextState ✗ | n/a | n/a |
| ExclusiveCaseMux 12 | ✗ class | ✗ not Plain | ExclusiveMux ✗ | BM only | ✗ discourages |
| IndependentLhs 12 `_d` | ✗ class | ✗ | NextState ✗ | BM | ✗ |
| Atomic 56 1-node | ✗ P3 | ✗ | AtomicMul ✗ | MC | ✗ atomic |
| P4 remainder after mul | maybe Plain | maybe | maybe | maybe | ✗ if **leading** mul>B |
| fifo restore | ✗ P10 | HandshakeLock | NextState | n/a | n/a |
| wrap_boundary add | ✓ default | ✗ wrap | maybe Comb | maybe | would cut — **must not apply** |
| fat FSM n=39 | ✓ default | ✗ fat | maybe | maybe | would cut — **must not apply** |
| lzc prefix | ✓ default | ✗ name | ExclusiveMux | n/a | n/a |
| intoout add | ✓ default (kind not checked) | ✗ not RegToReg | maybe | maybe | possible — **must not** treat as primary |
| UnderBudget | ✗ | ✗ | Comb | n/a | ✗ total≤B |
| multi_cycle | ✗ | ✗ | Iterative | MC | ✗ |

The wrap/fat rows are why exception is not “Plain ⇒ S4.” Default
`admits_insert_reg` is **weaker** than exception. S4 uses exception
first, then admits. Apply-time still has lane and cleanliness.

---

# Part XXXII — SystemVerilog mutation atlas (copybook)

These diffs are the **only** shapes emit should produce. If you invent
a new shape, add a test next to A43.

### NBA origin, first line of a multi-line assign

```systemverilog
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni) q <= '0;
  else begin
-   q <= long
-        + expression;
+   q <= pipe_svt_p1_1;
  end
end
+ always_ff @(posedge clk_i or negedge rst_ni) begin
+   if (!rst_ni) pipe_svt_p1_1 <= '0;
+   else         pipe_svt_p1_1 <= long + expression;
+ end
```

`cut_rewrite_anchor` / multiline empty-first-RHS exist because the first
line may be `q <=` with the expression on the next lines.

### Continuous origin

```systemverilog
- assign c_end = c_span + k;
+ assign c_end = pipe_svt_p1_4;
```

Never drop `assign`. Never `c_end = pipe` at module scope without
`assign` (implicit net may parse, then fail lint).

### Case-item origin

```systemverilog
unique case (op)
-  ADD: result_o = adder_result;
+  ADD: result_o = pipe_svt_p1_2;
endcase
```

### BalanceMux one-hot (exclusive)

```systemverilog
unique case (sel)
-  2'd0: y = a;
-  2'd1: y = b;
-  default: y = c;
+  2'd0: y = y_oh0;
+  2'd1: y = y_oh1;
+  default: y = y_ohd;
endcase
+ always_comb begin
+   y_oh0 = ({sel==2'd0} & a);
+   y_oh1 = ({sel==2'd1} & b);
+   y_ohd = ({sel!=2'd0 && sel!=2'd1} & c);
+   // OR-reduction is the select; critical = max(arm)+mux
+ end
```

Injected at the origin process, not after `endmodule`.

### SplitAssign

```systemverilog
- assign y = (a + b) ^ (c + d);
+ wire [31:0] svt_w0, svt_w1;
+ assign svt_w0 = a + b;
+ assign svt_w1 = c + d;
+ assign y = svt_w0 ^ svt_w1;
```

### Rebalance

```systemverilog
- assign s = a + b + c + d;          // 30 left-deep
+ assign s = (a + b) + (c + d);      // 20
```

Still not ≤10. S4 after this if Plain RegToReg.

### Twin generate (identical RHS)

```systemverilog
if (EnA) begin : g_a
-   assign c_span = RHS;
+   assign c_span = pipe_svt_p1_4;
end
if (EnB) begin : g_b
-   assign c_span = RHS;
+   assign c_span = pipe_svt_p1_4;   // copied
end
```

### Twin generate (different RHS) — current, leftover

```systemverilog
if (ReuseAEn) begin : gen_reuse_a
  assign a_span = RHS_A;            // not copied from b
end
if (ReuseBEn) begin : gen_reuse_b
  assign b_span = RHS_B;            // 18.5 live
end
```

VII.A would pair by ident `*_span` in named blocks.

---

# Part XXXIII — How to read a refuse/apply algo_trace event

Example apply:

```json
{
  "event": "apply",
  "pass": 4,
  "path_id": 5346,
  "module": "g6lc_ai_gemm_seq",
  "applied": true,
  "reloc": "t2_insert_reg",
  "class": "Plain",
  "fo4_before": 18.5,
  "fo4_after": 10.0,
  "edit_kind": "insertreg",
  "opp": "InsertReg"
}
```

This is v27 pass 4 `c_end`. Headline may still be 18.5 (sibling).
`fo4_after` on the **path** is not the soak headline.

Example refuse:

```json
{
  "event": "refuse",
  "reason": "cleanliness_set",
  "set": "seq_plus_comb",
  "class": "Plain",
  "opp": "InsertReg"
}
```

Look for a following `exception` event on the same path. If present,
S4 should still apply. If not, check P10 note and wrap.

Example stop:

```json
{ "event": "run.stop", "reason": "fixpoint" }
```

If `stage_s4` was true and primary 18.5, this is Lab 1, not a crash.
If primary 30.5 after many applies, this is Lab 6 — you reintroduced
S4-continue.

---

# Part XXXIV — Relocation scoring (why T1 is first)

**Implementation.** `build_relocation_plan` in `relocation.rs`.

Cards score options. Typical order for a Plain P6: T1 Split/BM (if
applicable) score high when expected_fo4_after ≤ B and latency_delta=0;
T2 InsertReg scores high when T1 cannot close and `--allow-latency`
will be on; T3 ArchMulticycle scores high on AtomicOp but
`auto_correct=false`.

Worklist `use_relocation_plan` enqueues `preferred_auto`. S4 may
**override** by re-attaching resilient as InsertReg. That override is
how gemm 161.5 was not starved by T1-first truncation.

For ExclusiveSelect pattern, preferred_auto is BalanceMux. InsertReg
is low score / not auto. That is I4 as a policy.

For AtomicOp, preferred_auto is PrepStage or SoftMulticycle, never
InsertReg. That is I6 as a policy.

---

# Part XXXV — Naming collisions and file suffix

Emit files may be written as `foo__svt.sv` (`NamePolicy.file_suffix`).
Generated idents must not collide with IEEE keywords (`assign`, `unique`,
`priority`, `begin`) or with existing user nets. `NameTable` is the
allocator. Twin copy **reuses** a name on purpose (same pipe, two
origins). VII.A must decide: one pipe (mutually exclusive generate-if)
vs two pipes (both `if (En)` can be true). Wrong choice is a functional
mux of two spans onto one flop.

```systemverilog
// Mutually exclusive generate-if / generate-else: ONE pipe is correct.
if (ReuseAEn) begin : gen_reuse_a
  assign a_span = pipe_svt_span;
end else begin : gen_reuse_b
  assign b_span = pipe_svt_span;
end

// Independent enables: TWO pipes.
if (ReuseAEn) begin : gen_reuse_a
  assign a_span = pipe_svt_span_a;
end
if (ReuseBEn) begin : gen_reuse_b
  assign b_span = pipe_svt_span_b;
end
```

CVA6 gemm uses two independent `if (ReuseXEn)` blocks. VII.A therefore
needs **two** pipes (and VII.B's second cut), not one shared pipe.
The v27 twin of `c_span` is safe only because both blocks contain the
**same** RHS — if both enables are 1, both assign the same value. `a_span`
vs `b_span` are **not** the same value.

---

# Part XXXVI — What “near-10 FO4” means numerically

Let \(F^\star\) be emit primary after a proposed patch.

| \(F^\star\) | MHz (20 ps, m=0.2) | Interpretation |
|---:|---:|---|
| 10.0 | 4000 | campaign closed on admitted cones |
| 10.5 | 3810 | island P10 — S5 |
| 11–12 | 3333–3636 | small FSM / bundle leftover — VII.C |
| 13–15.5 | 2581–3077 | frontend / queue — VII.E |
| **15.0** | **2667** | **quoted core headline (v50 P10 trigger)** |
| **16.0** | **2500** | **quoted APU headline (v50 P10 inval_bus)** |
| 18.5 | 2162 | historical v27 gemm span (closed) |
| 20.0 | 2000 | v24 l2_mshr class miss |
| 22.0 | 1818 | v51/v52 axi2mem WRAP-beyond — do not quote |
| 26–30.5 | 1538–1311 | origin steal / pre-v18 exclusive tax |
| 40.5 | 988 | v25 parse Mul / v43 `int'` |
| 56 | 714 | T3 mul as primary (should never be emit headline) |

“Near-10” in the user request is \(F^\star \le 10\) on **S4-admitted**
cones, with P10/wrap/T3 named as floor. It is **not** “average FO4 10”
and not “edit until analyze max_adj is 10.”

VII.A/B/D/E landed: gemm spans ≤10, queue/frontend remainder closed or
deflated. Quoted headline is the P10 floor (15/16). That is success of
the **package**. Closing 16/15 handshake is success of the **RTL**
(A69 K–M). v52 APU 22 is F9, not a new package win.

---

# Part XXXVII — Anti-pattern catalog with the patch that would do it

| Anti-pattern | The patch that looks tempting | What happens | Invariant |
|---|---|---|---|
| Retune table | `add_sub = 6.0` | goldens lie, STA disagrees | I1 |
| Split mul | spine-expand Mul into two Muls | illegal arithmetic | I6 |
| Parse all casts | `32'(expr)` full parse | v25 40.5 | I14 |
| S4 while resilient | `s4_has_pending_resilient` in loop | v28 30.5 | I10 I15 |
| Global `_q` next-state | `lhs_is_next_state` ends_with `_q` | gemm S4 starved | A22 note |
| Host name `g6lc_gemm` | `if name.contains("gemm")` | KD0; misses next APU | A30 |
| InsertReg P10 | allowlist fifo | SMT2 break | I8 |
| InsertReg WRAP | resilient on axi2mem | protocol break | A32 |
| Drop `assign` | in-place RHS replace | v21 Parse | A45 |
| BM after comments | emit order swap | v22 wrong origin | I10 |
| Reuse sqlite | same out-dir | from_cache lie | Part XLV |
| Debug CLI soak | skip release rebuild | stale numbers | playbook |
| Compare delay-v18 to v19 | quote 18.5 vs 20 without versions | incomparable | I11 |
| S4 intoout | treat P5 as primary | wrong cone | P5 |
| Brand 100-node atomic | `if any mul { Atomic }` | P4 suppression | I6 |
| Freeze Plain in cache | reusable Plain hints | v24 never fires | A61 |

---

# Part XXXVIII — A day-in-the-life debug of gemm 18.5

This is the transcript a maintainer should be able to produce unaided.

1. Soak headline `g6lc_ai_gemm_seq` 18.5 Plain n=4 loc L951.
2. Open emitted SV at L951: `assign b_span = 32'(n_q[8:0]-9'd1)*fmt_row_bytes(...)+k_bytes;`
3. Class Plain ⇒ detectors did not deflate. Makespan 18.5 = raw ⇒ serial chain, not bundle.
4. P6 (18.5 < 20). Resilient (Plain RegToReg >B, n=4, no P10, no wrap).
5. Lane CombDatapath. Cleanliness SeqPlusComb — exception must have fired (edits on c_span/c_end exist).
6. Why not b_span? Trace: S4 pass 3 path 5048 74.5→56 L608; pass 4 path 5346 18.5→10 L610; then measure primary still 18.5; flat_streak=2; `run.stop fixpoint`.
7. Twin: `c_span` copied; `b_span` RHS ≠ `a_span` RHS.
8. `line_inside_generate` false (no keyword); `lhs_is_module_level_net` true (`b_span` claimable). Scheduler would cut. Fixpoint stopped.
9. Proposal: VII.B one sibling cut on `*_span` in same module, or VII.A pair, or VII.D demote `fmt_row_bytes`.
10. Not a proposal: parse `32'`, loop S4, InsertReg disjoint as well unbounded.

That transcript **is** maintaining the codebase.

---

# Part XXXIX — Function-level map (grep anchors)

When a stack trace or a review comment names a function, this is the
algorithm.

| Function | File | Algorithm |
|---|---|---|
| `TimingTarget::new` | ir.rs | A1 |
| `CostModel::base_fo4` | measure.rs | A2 |
| `max_freq_mhz_for_path` | measure.rs | A3 |
| `Expr::parse` | expr.rs | A7 |
| `Expr::const_class` | expr.rs | A8 |
| `ConstSeed::looks_const` | expr.rs | A8 |
| `billed_binary_class` | expr.rs | A9 |
| `attribute_costs` | measure.rs | A15 |
| `compose_reg_to_reg_paths` | measure.rs | A16 |
| `refresh_primary_locs` | measure.rs | A17 |
| `tag_multi_cycle_paths` | measure.rs | A18 |
| `suggest_opportunities` | measure.rs | A60 |
| `RefOrderTree::from_nodes` | ref_order.rs | A19 |
| `ParallelScratch::schedule` | parallel_timing.rs | A20 |
| `classify_and_adjust_paths` | path_class.rs | A21 A61 A62 |
| `try_exclusive_shared_lhs` | path_class.rs | A22 |
| `try_independent_lhs_bundle` | path_class.rs | A23 |
| `try_dense_control_cone` | path_class.rs | A24 |
| `try_atomic_over_budget` | path_class.rs | A25 |
| `try_parallel_timing` | path_class.rs | A26 |
| `path_is_handshake_locked` | pass_strategy.rs | A27 |
| `path_has_indexed_restore` | pass_strategy.rs | A28 |
| `plan_from_design` | pass_strategy.rs | A29 |
| `is_resilient_datapath` | pass_strategy.rs | A32 |
| `exception_policy` | pass_strategy.rs | A32 |
| `cone_lane` | cone_lane.rs | A30 |
| `explore_module` | cleanliness.rs | A31 A64 |
| `build_relocation_plan` | relocation.rs | A33 A34 |
| `OptOptions::preset` | opt.rs | A34 |
| `order_worklist_with_plan` | worklist.rs | A35 |
| `run_correct_passes` | pass.rs | A46–A49 A63 |
| `balance_mux_on_path` | pipeline.rs | A37 |
| `split_assign` | pipeline.rs | A38 |
| `rebalance_associative_node` | pipeline.rs | A39 |
| `schedule_pipeline_cuts` | pipeline.rs | A40 A41 |
| `insert_register` | pipeline.rs | A40 |
| `expand_expr_spine_for_path` | pipeline.rs | A42 |
| `rewrite_origin_assigns` | emit rhs.rs | A43 |
| `apply_edits_to_source_dense` | emit lib.rs | A43 A45 |
| `integrity_reparse` | emit lib.rs | A45 |
| `mangle_identifier` | naming.rs | A61 |

---

# Part XL — Final recap the night before you patch S4

Memorize this page.

- \(B=10\). One CPA is the period. One mul is 5.6 periods.
- Measurement lies (P1 P2 exclusive-sum bundle-sum comment-mul genvar-mul
  `x+1` `::` 2-arm flop-D log2-mux-tax) are **fixed by detectors**, not
  by InsertReg.
- Real cones that cannot take a flop (P10 WRAP lzc FPU leading-mul
  intoout) are **S5**.
- Real cones that can (Plain RegToReg P6/P8, resilient exception) take
  **one** T2 cut per apply, module-diverse, then remeasure.
- Stop when the headline does not move twice. Sibling 18.5 is VII.B,
  not a while-loop.
- Emit is line-based. Extra edits steal origins. BM first. Keep
  `assign`. Twin only identical RHS.
- Do not parse `32'(expr)`. Do not retune `fo4-v1.toml`. Do not reuse
  sqlite. Rebuild release.
- Soak of record: **v27 / 18.5 / 2162 MHz**. v25 and v28 are
  counterexamples in this manual, not targets.
- Near-10 is A+B (or D) + E + C on admitted cones. Floor is 16/14/56.

If your patch still looks good after this page, write the fixture, bump
the version string that I11 requires, and soak a new directory.

---

# Part XLI — `apply_work_item`: the inner interpreter

**Implementation.** `apply_work_item` in `crates/sv-timing-transform/src/pass.rs`
(called from the batch loop).

### Summary

The pass loop does not call `insert_register` directly. It interprets a
`WorkItem`: honor `relocation_option_id` when present, else opportunity
kind, else skip. Each kind is a function in `pipeline.rs` plus a refuse
string on failure.

### Low-level basics

Typical dispatch:

1. If reloc id contains `prep_stage` / `t1_prep` → spine expand + maybe
   one prep flop; cap 1 per path later.
2. If kind BalanceMux → `balance_mux_on_path`.
3. If kind SplitAssign → `split_assign`.
4. If kind InsertReg → `select_pipeline_cuts` then `insert_register`.
5. Rebalance may be folded into BalanceMux for plain paths.

Refuse strings you will grep: `LatencyNotAllowed`, `ModuleNotAllowlisted`,
`path class … discourages InsertReg`, `atomic over-budget`, `already under
budget`, `balance_mux already applied`, `multi_cycle path`.

`fo4_before` / `fo4_after` in the algo_trace are **path totals at apply
time**. Remeasure at the end of the batch can change them (classification
after a cut). Do not treat apply-time 10.0 as soak headline.

### High-level basis

This is a **bytecode interpreter** for relocation kinds. Adding a new
`OpportunityKind` without a dispatch arm is a silent skip. Adding a
dispatch arm without a refuse path is how Wrap got InsertReg'd before
`path_has_burst_wrap`. Every new kind needs: suggester, cleanliness
allow, lane allow, exception (if it bypasses cleanliness), dispatch,
emit, test, this manual.

### Behavioural study

```text
WorkItem { path 5346, opp InsertReg, reloc t2_insert_reg }
  → select_pipeline_cuts(budget=10, max_cuts=min(stages,16))
  → CutPoint after c_end node, fo4_left=8.5, fo4_right=10
  → insert_register: NameTable pipe_svt_p1_4, EditRecord, IR split
  → emit later rewrites L610
```

If `select_pipeline_cuts` errors `discourages InsertReg`, the item is
refused, path skipped, S4 continues with the next batch member. That is
how exclusive leftovers do not crash the loop.

---

# Part XLII — Dense sidecar: lean vs real feeds

**Implementation.** `crates/sv-timing-emit/src/dense.rs`.

### Summary

A generated `always_ff` / `always_comb` block that holds pipe registers
and optional feeds. **Lean** feeds `svt_zero`. **Real-cut-feeds** feeds
the origin RHS (`assign pipe_c = (origin_rhs)`). FO4 closure of the
**IR** is independent of feed fidelity; FO4 closure of the **RTL** is
not. Soak headlines must use post_analyze of emitted sources.

### Low-level basics

Density counters exist so the sidecar stays Verilator-parseable (begin/end
pairs, assigns, ternaries). Cut feeds:

```systemverilog
// real
assign pipe_svt_p1_4_c = (c_span + k); // cut feed (origin rhs)
// lean
assign pipe_svt_p1_4_c = svt_zero;     // cut feed (lean zero / unsafe rhs)
```

Unsafe RHS (free genvar index, unsynthesizable) falls back to zero even
in real mode (`has_free_gen_index`). That is a **silent functional**
hole: the pipe samples 0, origin still rewritten to the pipe, the cloud
sees 0. Integrity reparse still passes. Review the `_c = svt_zero`
comments in emit.

`dense_autocorrect_block` concatenates `bm_at_origin` so BM snippets are
not dropped when the dense helper is the only inject path.

### High-level basis

Lean emit is a **throughput** device for IR-only experiments. It is not
evidence of 4 GHz. The standing soak rule `--real-cut-feeds` exists
because someone booked 304.5→96.5 that the SV did not contain.

### Behavioural study

```systemverilog
// Honest T2 (real feeds):
+ assign pipe_svt_p1_4_c = (c_span + k);
+ always_ff @(posedge clk_i or negedge rst_ni)
+   if (!rst_ni) pipe_svt_p1_4 <= '0;
+   else         pipe_svt_p1_4 <= pipe_svt_p1_4_c;
+ assign c_end = pipe_svt_p1_4;

// Lean lie:
+ assign pipe_svt_p1_4_c = svt_zero;
+ assign c_end = pipe_svt_p1_4;   // cloud sees 0, IR still claims 10 FO4
```

---

# Part XLIII — Worklist ordering in full

**Implementation.** `order_worklist_with_plan` in `worklist.rs`.

### Summary

1. If a relocation plan exists, walk **cards in plan order** (already
   worst-FO4 first). Enqueue primary single-cycle cards with
   `preferred_auto` opportunity. Soft-MC atomics enqueue PrepStage /
   Split / Rebalance only, **appended after** primary.
2. Remaining primary paths not in the plan get default opportunities.
3. Cap at `max_items`.
4. S4 then re-sorts and re-attaches resilient (A35, A46).

### Low-level basics

`seen` prevents duplicates. A card with no opportunity and no
preferred_auto and slack<0 still tries `pick_opportunity_default`. If
that is also None, the path is **dropped from the worklist** — this is
how AtomicOverBudget 56 disappears from S3/S4 (good) and how a Plain
path with `nodes≤1` disappears (P3, also good).

Soft atomic prep is **after** primary so a 56 FO4 mul prep cannot
starve an 18.5 P6 in S3. S4's resilient-first sort is the dual for T2.

### High-level basis

Two orderings exist on purpose: relocation-card order (T1-first, large
FO4-first) for S3; resilient-then-shallow for S4. Using only the first
in S4 starved gemm 144-node (audit-gemm-rcf). Using only slack-first
in S3 InsertReg-sprayed exclusives before BM existed as a kind.

### Behavioural study

```text
Cards: mul 56 Atomic (PrepStage), exclusive 12 (BM), gemm 18.5 Plain (InsertReg)
S3 worklist: BM on exclusive, maybe Split on gemm, PrepStage appended
S4 worklist: gemm InsertReg first (resilient), exclusive dropped (not InsertReg)
```

---

# Part XLIV — Clock domains and cycle bars

**Implementation.** `ClockDomain` in `parallel_timing.rs`;
`factor_always_ff_regions` in `factor_always_ff.rs`.

### Summary

Comb boards have empty `clock_name` and still use design \(B\).
`always_ff` boards bind `clk_i` / `posedge` / `rst_ni` from `GateInfo`.
`sequential` is true even if the clock net is unresolved, so a
factorizer never treats NBA as combinational. Cycle \(k\) is the k-th
capturing edge after reset, not a free-running FO4 counter.

### Low-level basics

`ClockDomain::from_gate`:

```text
period_ns = 1000 / target_mhz
budget_fo4 = design B
sequential = true
map_key = clock_name or "#ff{region_id}"
```

Factorize writes review comments:

```systemverilog
// sv-timing: cycle bar clk_i posedge period 0.25 ns budget 10 FO4
```

and can emit OpenSTA `report_timing -from … -to …` seeds. It does not
split the process unless cleanliness `ff_factor` is on **and** the
emit path for factorize is enabled (today: comments-first).

### High-level basis

4 GHz is a **clock** problem. Parallel timing that ignored the capturing
edge would JIT-cut combo as if it had a free counter. Binding the
scratchboard to `clk_i` makes \(N=\lceil M/B \rceil\) mean “cycles of
that clock.” SMT2 one-cycle switch is one cycle of `clk_i`; a JIT cut
there is a second cycle.

### Behavioural study

```systemverilog
always_ff @(posedge clk_i or negedge rst_ni) begin
  q <= d;
end
// ClockDomain { clock_name: clk_i, edge: posedge, reset_name: rst_ni,
//               period_ns: 0.25, budget_fo4: 10, sequential: true }
```

---

# Part XLV — Cache key composition

**Implementation.** `sv-timing-cache` fingerprint + `OptOptions::analysis_digest`
+ `MEASUREMENT_VERSION` + `PATH_CLASS_DETECTOR_VERSION` + `IR_VERSION`.

### Summary

A cache hit is legal iff **all** of these match: source CRC, defines,
include paths, target (\(f\), fo4_ps, margin), IR version, measurement
version, detector version, analysis_digest (`effort:cache_mode`).
Transform dials (passes, stages, min_gain, cut strategy, allow_reassoc,
jobs) must **not** be in the analyze key.

### Low-level basics

`analysis_digest` = `e{effort}:k{cache_mode}`. `-O2` vs `-O3` differ
because effort is balanced vs thorough (stitch). `-O3` vs `-O3
--opt-max-stages 20` must **hit** the same analyze cache (stages are
transform-only). A soak that changes stages and sees `from_cache=true`
is expected. A soak that changes detector 23→24 and sees
`from_cache=true` is a **bug** (version not in key, or sqlite reused
from a key collision).

Practical rule: **new out-dir per experiment.** Do not debug keys when
a new directory is cheaper.

### High-level basis

I11 as engineering: incomparable measurements must miss. Transform
dials as non-keys: otherwise every `-O` tweak rebuilds a 10-minute
analyze.

---

# Part XLVI — Remaining-gap proof from the invariants

Claim (discharged): under delay-v19, detector 24, S3-then-S4 two-flat,
BM-before-IR, real-cut-feeds, wrap/P10/fat/lzc locks, the emit primary
of a full-core soak **was** **18.5 FO4** (v27). VII.A/B/D/E + A60 moved
it. The current quoted claim: under delay-v25, detector 24, the emit
primary is **15.0 P10** (core) / **16.0 P10** (APU v50). Auto-correct
cannot move those without violating I8 (P10) / wrap lock. v52 APU 22 is
F9, not a counterexample to the P10 floor.

### Proof sketch

1. **Headline identity (v27).** post_analyze worst RegToReg is gemm
   `b_span` Plain n=4 18.5, not T3 mul 56 (MC/atomic excluded from
   primary), not l2_mshr 20 (v24 I4 flop-D), not te_packet consts
   (I P1 v18). Observation.
2. **Admissibility.** The path is Plain RegToReg nodes>1 FO4>B, not
   P10, not wrap, n<16, not lzc/FPU names ⇒ resilient (A32) ⇒ S4
   **may** cut (I9 T2 legal if protocol allows; gemm tile already
   multi-cycle in the accelerator FSM).
3. **Why S4 did not.** Two gemm cuts already applied (`c_span`,
   `c_end`). Twin copied identical-RHS `c_span` only (A44). Sibling
   `b_span` same FO4 ⇒ Δprimary=0 ⇒ I15 stop. Scheduler would cut
   (A40: sum>B, nodes>1, not leading mul). Therefore the miss is
   **control-flow**, not geometry.
4. **Unblocking without I15/I10.** A while-resilient loop is v28
   (contradicts I10). A one-shot sibling-span cut (VII.B) or a twin
   by LHS ident (VII.A) changes **one** additional origin in the
   same named-block family, bounded, then stop. That is a new
   algorithm, not a relaxation of I15.
5. **Unblocking without T2.** If `*` of `fmt_row_bytes` is mux-of-shifts
   (VII.D), I14 stays (no general cast parse), billed class drops,
   chain may fit \(B\) (T1). If disjoint still serial-adds past 10,
   combine with A/B.
6. **After gemm ≤10.** Rank (A63) promotes the next worst: instr_queue
   15.5 Plain n=9 (VII.E, P6, origin re-anchor I10), or frontend 13,
   or P10 16 (I8, cannot auto), or wrap 14 (A32, cannot auto).
7. **Floor.** I6 (mul 56), I8 (handshake 16), wrap 14 are not 10.
   QED: “near-10” is reachable on **admitted** cones by A/B/D+E+C
   and **not** reachable on the floor by any legal S4.

This is the determination the user asked the document to make. It does
not require a new soak to be true of the **current** design; a soak is
required only after A/B/D is implemented.

---

# Part XLVII — `insert_register` IR mutation (what remeasure sees)

**Implementation.** `insert_register` in `pipeline.rs`.

### Summary

For each `CutPoint`, allocate a signal, create a sequential node
(the flop) and rewire the path so nodes after the cut read the new Q.
`fo4_locked` on residual segments prevents remeasure from re-parsing
the original mega-assign onto both halves. Capture endpoints stay
`RegToReg`.

### Low-level basics

If the origin assign is `assign y = a + b + c` and the cut is after
the first add in a spine-expanded path:

```text
before: nodes [add1, add2] costs [10, 10] path y
after:  nodes [add1] → flop → [add2]
        path1: launch → add1 → new flop D   cost 10
        path2: new flop Q → add2 → capture  cost 10
```

Without `fo4_locked`, remeasure parses `y = a+b+c` still sitting in
the source (until emit) and bills 20 again on both segments. The IR
must lock.

Emit is a **later** pass over the edit trace. If the process crashes
between insert_register and emit, the IR claims a flop the SV does
not have. Correct runs are not crash-safe mid-batch; that is acceptable
because the host copies emit only after integrity.

### Behavioural study

```systemverilog
// Source still original until emit:
assign y = a + b + c;
// IR after insert_register already split. Remeasure uses locked node
// costs, not the still-unrewritten source text.
```

This is why lean IR FO4 can drop without source changes, and why
`emit_structural` must gate the IR mutation in the soak of record.

---

# Part XLVIII — Allowlist, refuse prefixes, module_allowed

**Implementation.** `PassPolicy::module_allowed`; batch skip in `pass.rs`.

### Summary

Empty allowlist ⇒ `correct_enabled` false (from_opt) or early return
in `run_correct_passes`. Nonempty allowlist is the **only** way T2
touches a module. Refuse prefixes (normalized `/`) skip paths by file.
A full-core soak allowlists every module it intends to edit; a
surgical soak allowlists `g6lc_ai_gemm_seq` only.

### High-level basis

Allowlist is the **blast radius**. The v28 regression was design-wide
because the soak allowlisted the core. VII.B's same-module bound is a
second radius inside S4. Do not widen allowlist to “fix” a leftover
that is S5.

### Behavioural study

```text
--modules g6lc_ai_gemm_seq
  → only gemm S3/S4. instr_queue 15.5 untouched. Headline may stay
    18.5 even if you wanted E. Surgical soaks need the module of the
    leftover you are targeting.
```

---

# Part XLIX — Ranking primary vs all-kinds leftover counts

v27 leftover unique **RegToReg** over budget (the table in Part VII)
is not the same as “186 total over all kinds.” Intoout, MC, exclusive
residuals, and screening SVA paths inflate counts. When a dashboard
says “84 over-budget,” ask: **RegToReg after classify, slack<0,
not MC?** That is the campaign set. Everything else is either P5,
S5, or a class that S3 owns.

```text
closes            ⇔ every non-MC primary slack ≥ 0
campaign closes   ⇔ every S4-admitted RegToReg slack ≥ 0
tape-out closes   ⇔ STA + S5 floor addressed in RTL
```

This package can achieve “campaign closes.” It cannot achieve
“tape-out closes.” Part VII's 18.5 is campaign-not-closed. The floor
16/14/56 is tape-out-not-closed even after A–E.

---

# Part L — Maintenance contract (sign here)

If you change an algorithm, you owe:

1. A named block in **this** file (summary, basics, basis, purpose,
   mutations, SV ± diff, implementation path).
2. A fixture under `sv-timing/fixtures/` and a `#[test]` that fails
   without your change.
3. A version bump if I11 applies.
4. A soak in a **new** directory if emit can change, with integrity
   green, quoting post_analyze primary not IR max.
5. A Part VII table update if the headline or the floor moved.
6. No architecture-doc exploration required of the next reader.

If you cannot write the SV ± diff, you do not yet understand the
mutation and you must not land the patch.

The remaining gap to ~10 FO4, determined from this theory:

| After | Emit primary | Owner |
|---|---|---|
| current (v27) | 18.5 | sibling span, I15 |
| VII.A and/or B, rewrite lands | ~10 then next leftover | E or S5 |
| + VII.E | ~10–13 | frontend / C |
| + VII.C | ~10–12 | measure |
| + VII.D | maybe 10 without T2 on gemm | T1 |
| + VII.F (do nothing on floor) | 16 P10 / 14 wrap / 56 T3 | RTL / T3 |

**Campaign near-10 is VII.A+B+E(+C/D). Floor is not 10. Do not lengthen S4.**
