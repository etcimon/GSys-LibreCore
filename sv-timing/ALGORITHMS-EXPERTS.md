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

**Current qualification note (A118).** The historical tables below mix live
and emitted trees and several mapping recipes. They are retained as observations,
not interchangeable baselines. The 10 FO4 objective at `fo4_ps=20` remains a
200 ps logic budget within a 250 ps clock with 20% margin. The earlier
13-cell / approximately 0.7 ns comparisons are correlations, **not conversions
of that budget or closure criteria**. A118 pairs immutable source snapshots,
uses the same map-v2 recipe, and reports the uncut timing graph beside the
fanout-filtered module study. See
[`CONTROL-CONE-CLOSURE.md`](architecture/CONTROL-CONE-CLOSURE.md).

**A119 update:** delay-v40 source maximum is 55.078 FO4 and the fresh
latency-neutral emit is 55.664 FO4; 10 FO4 remains open. The IQ now has
paired placement/repair evidence without disabled arcs: 3.606→2.806 ns
worst arrival at +3.0% area. See A119 for scope, proofs and residuals.

**A144 update:** write-buffer fixup queue read in slot order (parallel match,
first-in-FIFO-order via split prefix isolates): selection SAT-equal at four
depths, placed 5.344 → 4.853 ns, area -18%. Path reports show the
frontend and IQ cones are broadcast-net dominated; protocol designs for both
are specified with the core-level validation route (harness build, DI, soak).

**A143 update:** rename free-list isolates → prefix OR (placed 3.131 → 2.833 ns,
board 2.954 → 2.462); the same in the IQ measured worse (off its
critical cone) and was dropped. A142 8×8 tiles rejected (+15% placed). Core
budget-equivalent 283 MHz.

**A141 update:** store-buffer speculative queue as stationary slots with an
insertion-time age matrix (one-hot head, per-byte youngest-writer merge, no
permutation). Cycle-exact vs the ring 4 × 400k; placed 4.159 → 2.811 ns
worst, 4.159 → 2.148 ns reg→reg, area -36%; board
3.958 → 1.929 ns. Precondition (monotonic age anchor) asserted.

**A140 board/noise note:** the per-module board is deterministic only for
cache hits; re-mapped modules moved up to ±26% with no source change, so
acceptance rests on the isolated pair (reproducible across sessions). The
scoreboard head scan needed the explicit prefix-OR isolate (as the ROB) — the
`x & (~x+1)` form mapped as a carry chain. Branch-unit carry-free target check
proven but board-neutral → trial patch only.

**A140 update:** step 1 of the A139 plans landed: D$ per-byte forwarding as a
balanced first-valid tree (placed 3.154 → 2.333 ns,
area +31.0% of the module's logic; the
AND-OR alternative 3.154 → 2.937 ns at
-4.5%), loop-predictor row-local training in the shipped
RTL (1.911 → 1.459 ns, area -12.3%), loop-buffer bounded
address add (1.824 → 1.507 ns, area +5.3%). All
equivalence-proven; board re-read pending.

**A138 update:** store-buffer input stage (gated `StqInputStage`) built as a
uniform one-cycle shift with register-derived current-cycle views; shift
witness 4 × 300k cycles clean, gate-off cycle-exact 2 × 400k, mutant caught —
and rejected on placement (3.964 → 4.316 ns, +8.1% area): the placed worst path
was the permutation itself, not the input cone. RTL/config reverted; trial kept
as `architecture/trials/a138-store-buffer-input-stage.patch`.

**A137 update (board):** live board after A134–A136: realign 119 → 50.8,
statcor 83.7 → 33.7, ROB 82.4 → 69.8, multiplier 118 → 97.3 adjusted FO4;
top four unchanged. The loop-buffer registered expectation read worse on the
unbuffered board (72.3 → 94.9) despite the placed gain and is reverted.

**A137 update:** the ROB slot-order search carried to the checkpoint stack
was functionally proven (equivalence ×3, directed + randomized model, mutant)
but placed reg→reg worsened 2.334 → 2.715 ns because that consumer also needs
the ring offset — rejected and restored. Live-board flow fix: yosys `t:$aldff`
selectors are escaped in the remote bash word, shell paths still expand.

**A136 update:** two further latency-neutral changes on the measured list.
Loop buffer registered expectation: placed 1.824 → 1.493 ns at +12.1% area,
six cycle-exact runs + 6-step output miter. ROB absolute-order re-anchor:
placed reg→reg 2.049 → 1.568 ns at −2.0% area, equivalence ×3. The top three
cones still need the §A132 stateful boundaries. Record: `PIPELINE-PRAGMA-REVIEW.md` (A136).

**A135 update:** `row-local` is the second pragma the tool executes end to
end: statement span retained at parse, checked plan in initial IR, prepared
source reparsed before correction, emit mapped to the original path. Loop
predictor: placed 1.911 → 1.410 ns at −6.9% area, equivalence + model witness
pass. Record: `architecture/PIPELINE-PRAGMA-REVIEW.md` (A135).

**A134 update:** further RTL files improve with unchanged cycle interfaces.
Realigner continuation caching: placed worst 2.977 → 2.257 ns at −17.2% area.
Statcor row-local training: 1.622 → 1.095 ns at +12.6% area. Rename and store
snapshot bypasses were restored after placed regressions. Evidence and limits:
[`PIPELINE-PRAGMA-REVIEW.md`](architecture/PIPELINE-PRAGMA-REVIEW.md#a134--further-controlstate-files).

**A133 update:** representation directives are compiled into initial IR before
costs and on remeasurement. A declared carry-save pair becomes one atomic cut
boundary with either row as the critical anchor; the other row travels through
the existing bundle machinery. Source/emit witnesses and a misaligned-companion
negative control qualify the implementation. Method and limits:
[`PIPELINING-RT-LEARNING.md`](architecture/PIPELINING-RT-LEARNING.md).

**A132 update:** split both multiplier operands into product tiles and carry
sum/carry rows across the existing middle boundary. Paired placement/repair
without disabled arcs: 2.634 → 2.215 ns worst arrival (+1.4% area);
actual corrected SV 2.298 ns, behavior and latency verified. The pragma
audit finds 53 guarded modules but zero enabled cuts; it now reports vector
valids, unbound targets and invalid domains explicitly. See
[`PIPELINE-PRAGMA-REVIEW.md`](architecture/PIPELINE-PRAGMA-REVIEW.md).

**A131 update:** hand rung on the multiplier — 8-bit operand slices under
`MultStages = 3`: reg→reg 1.817 → 1.623 ns on the live board, boundary
cone 2.581 → 2.531 ns (118.3 adjusted FO4); witnesses pass; the contract
still fences the module.

**A130 update:** live-RTL board after adoption — multiplier 2.820 → 2.581
ns (131.8 → 120.6 adjusted FO4), worst now the stage-1 product; the
board's top is `store_buffer` 173.0 with the concurrent write-buffer fixes
in the tree; 56 of 65 over budget.

**A129 update:** `latency <dom> <param> base=…` binds a domain's stage
count to the parameter its consumers track; a plan is admitted only when
`base + k` equals the parameter's value, otherwise refused with the value
to set. Declared on the multiplier; the adoption's fourth-stage hazard is
closed.

**A128 update:** every editable file of the over-budget list now carries a
fail-closed contract; the multiplier's third stage is adopted in RTL under
`MultStages = 3` (`g6lc64_ooo`), with the side-by-side and reference-model
lifetime witnesses passing and whole-core elaboration clean. The live
route for its adjusted reading is running.

**A127 update:** id-less domains (valid + global kill) join the
vocabulary; a sweep of all 56 listed modules under `correct
--allow-latency` yields one carried stage (the multiplier), seven bare
registers in contract-less modules (review items), and refusals that name
the next decisions per file. The remaining rungs are designer decisions
(FLU redesign, input staging, read retiming), written as contracts.

**A126 update:** the multiplier merge is resolved from both ends — the
carry-less stage-1 nets lifted to module scope and carried by the
contract, the bundle priced at real widths — and the emitted three-stage
multiplier passes the side-by-side witness at `lag=2` (3 seeds × 300 k,
0 errors, all eight operations). Adoption waits on `MultStages = 3`.

**A125 update:** stages inside named generate blocks are emitted in place
with module-level exports for the other configurations; the multiplier's
third stage emitted correctly and the side-by-side witness caught a
parallel-datapath merge (CLMUL one operation late) — now a contract rule
(`merge_violation`) that refuses the stage until the carry-less pipeline
takes the same depth.

**A124 update:** the core's 56 over-budget files are listed in order with
their rung arithmetic; contracts are declared on the first nine (one
admissible `cut-ok`, the rest `no-cut` with the architecture that would
move them); the planner is driven by the contract. The multiplier's third
stage is blocked on generate-scope emission; the queues on input staging.

**A123 update:** re-pipelining is now *declarable*: `// svt-pipe:` pragmas
(protocol valid/id/kill/flush, carry, result, cut-ok, no-cut,
require-contract) are collected like the `$onehot` facts and turn a
register cut into a carried stage — valid killed at every stage and at use,
id and side-band in lockstep, flush clearing all stages, consumers rewired
onto the last stage — with age consistency enforced and misaligned plans
refused. Fixture twin: protocol witness 6 × 200 k cycles, 0 errors.

**A122 update:** the A118–A120 hand rewrites are abstracted to their
mechanisms. Three are exact expression identities and are now passes
(`CircularCompare`, `ZeroDetectEquality`, `PushSelect`), firing on RHS and
on `if` predicates (IR v3 guard sites), proven on a fixture (−22.6 % delay,
+7.6 % area). Two are statement-level mechanisms reported as sites
(`IndexedWriteReadBypass`, `OneHotEncodeDecode`): 6 real sites on the live
core, the rename map writes among them. The identities find no remaining
direct site on this tree — the campaign already applied them by hand.

**A121 update:** the budget now has a physical reading. `sv-timing adjusted`
divides each module's mapped delay by the platform's measured FO4 (probe:
minimum inverter driving four copies; nangate45 21.40 ps, asap7 14.36,
sky130hs 72.08, sky130hd 80.91). On the last full board one structural FO4
is ~3.05 inverter delays: the 55-FO4 maximum is ~165 adjusted FO4, 227 MHz
budget-equivalent on nangate45. Platforms are auto-detected from the fork's
`test/<p>/<p>.vars`; the study Tcl is mirrored in `tools/openroad/g6lc/`.

**A120 update:** retain the rename write-mask fusion (placed 3.375→2.964 ns,
−0.95% area), and reject the slower IQ/store candidates. IR v2, delay-v41
and correction-v1 add compound-dependency accounting, typed +/- candidates
and lowering-context cache identity. Fresh retained source/emit still read
55.078/55.664 FO4. See A120 for the separate hardware and measurement results.

**Historical state (2026-10-16, delay-v37 — A97–A103).**

| Quantity | Value | Where |
|---|---|---|
| Measurement | `delay-v37` (guards as reads + mux; field-granular, index-aware loop carry) | `crates/sv-timing-core/src/version.rs`, A103 |
| Live `g6lc64_ooo` at 10 FO4 / 20 ps | **worst 38.5** (`store_buffer` cancel squash); 1204 failing primary, 673 of 1628 reg→reg | `timings sta-rtl --fo4 10` pre-pass; `baseline-v37.json` |
| Same tree under delay-v36 | 23.0 / 435 / 160 — the model was blind to guarded writes in the OoO modules | A103 |
| Calibration vs netlist (structural FO4 / mapped cells) | iq 16.5 / 47, store_buffer 38.5 / 49, wbuffer 18.6 / 21, instr_queue 17 / 16, realign 26 / 23, frontend 23 / 43; rename 19 / 52 and scoreboard 15.6 / 54 under-read, perf_counters 34.7 / 13 over-read | module board, run C (A100, A103) |
| Emitted −O3 allow-latency tree | elaborates and maps end to end; area +0.35 % (InsertReg flops), depth bought on the board (scoreboard 5.16 → 3.98 ns, frontend 43 → 37 cells) | A102 |
| Automatic transforms | `LoopRewrite` (FindFirst, CondCount, RingWalk, StreamCompact), `SelectIncrement`, `BalanceMux` (one-hot, arm set = rewrite set), `RebalanceAssoc`, `SplitAssign`, `InsertReg` — exact or latency-labelled, area-neutral-or-better except InsertReg | A88–A103, `AGENTS-auto-correct.md` catalog |
| Production RTL rewrites | instr_queue admission count (A92), scoreboard cancel window (A98), ROB free/re-anchor (A99), rename/iq/store_buffer find-first and popcount (A100) — SAT at fixture sizes; 8/32-entry miters inconclusive on budget | A92–A100 |
| Mapping noise floor | ±1 % area, ±6 cells on identical RTLIL (autoidx-dependent ABC order) | A102 |
| 10 FO4 | **not closed**. Module board (Nangate45) across A104–A112: worst reg→reg delay 6.21 → **4.35 ns** (frontend, the 64-bit target sum), worst cells 54 → **38–41**; the design's worst path of any kind is the **multiplier's product, 5.34 ns in→reg** (A113; 3.12 ns in the emitted tree with its admitted cut). Structural (delay-v39, live, fresh width map): worst 55.1, 694 of 1 630 reg→reg over 10 FO4; the two boards agree on ranking and scale (≈ 0.07 ns per structural FO4). The route refreshes the width map first, plans and verdicts the live design only, gates area by Dial 11 with the previous run's measured cells/FO4 (A114: −0.10 % area, worst paths unchanged or better), and writes `calibration.tsv` + the trade-off ledger every run | A103–A114 |

The route that produces these numbers is one host command (`AGENTS-build-platform.md` §7.1):
`timings sta-rtl --target g6lc64_ooo --platform nangate45 --fo4 10 --allow-over-budget --remote --map-recipe streamed`,
followed by `scripts/openroad-module-board.tcl` and `scripts/sta_module_delta.py` on the run's artifacts.

**Frozen-snapshot numbers (2026-10-15; fresh development results in Part LII).**

| Quantity | Value | Where it is computed |
|---|---|---|
| Target | 4000 MHz | `TimingTarget::new` in `crates/sv-timing-core/src/ir.rs` |
| `fo4_ps` | 20 | process input, not a retune knob |
| margin | 0.2 | same |
| Budget \(B\) | **10 FO4** | \((1000/f_{\mathrm{MHz}})\times(1000/\mathrm{fo4\_ps})\times(1-m)\) |
| Measurement | `delay-v26` | original-source loop scopes; `crates/sv-timing-core/src/version.rs` |
| Path-class detector | **24** | `PATH_CLASS_DETECTOR_VERSION` in `path_class.rs` |
| Current frozen emitted core | `pointer-trial-20261015/baseline-v26.json`: **21.5 FO4**, `instr_queue` | 264 files, 234 modules, 11,008 paths; 349 failing primary paths |
| Previous reading of identical RTL | **23.5 FO4**, `scoreboard`, `delay-v25` | loop scope coordinate defect; a measurement correction, not a hardware speedup |
| Historical soak of record | `audit-remain-v50/` emit **15.0 P10 / 16.0 P10** | older source closure, delay-v23; not the current core |
| Historical later soak | `audit-remain-v52/` delay-v25 integrity green | older core **15.0 P10**; APU **22.0** axi2mem WRAP-beyond |
| Historical | `audit-remain-v27/` 18.5 gemm span | VII.A/B/D/E later closed that headline |
| Failed experiments | v25 general `(W)'(v)` 40.5; v28 S4-continue 30.5; v49 2-arg Mux tax gemm 15 | all **reverted** |
| Remaining gap to \(B=10\) | **11.5 FO4** on current emitted core | Part LI; whole-core equivalence and mapped STA are not established |

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
105. [Part LI Current 10-FO4 campaign](#part-li--current-10-fo4-campaign-2026-10-15)
106. [Part LII Refusal rollback, lexical bindings and admission factoring](#part-lii--refusal-rollback-lexical-bindings-and-admission-factoring)
107. [Part LIII Measurement truth: coordinates, widths, casts, multi-operand sums](#part-liii--measurement-truth-coordinates-widths-casts-multi-operand-sums)

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

**Historical campaign:** the tables in this part describe v27–v52 artifacts.
Use Part LI for the current source closure. A path class or a successful reparse
does not prove a physical lower bound, equivalence, or readiness for RTL integration.

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

Historical campaign projection (audit-remain-v27, not measurement delay-v27):

| After | Emit primary | Owner |
|---|---|---|
| current (v27) | 18.5 | sibling span, I15 |
| VII.A and/or B, rewrite lands | ~10 then next leftover | E or S5 |
| + VII.E | ~10–13 | frontend / C |
| + VII.C | ~10–12 | measure |
| + VII.D | maybe 10 without T2 on gemm | T1 |
| + VII.F (do nothing on floor) | 16 P10 / 14 wrap / 56 T3 | RTL / T3 |

**Campaign near-10 is VII.A+B+E(+C/D). Floor is not 10. Do not lengthen S4.**

---

# Part LI — Current 10-FO4 campaign (2026-10-15)

## Evidence boundary and baseline

The host runs `correct --all-modules --allow-latency --emit -O3
--opt-max-stages-per-region 13 --real-cut-feeds --assume-clk` before mapping.
`physicalDesign.structural.fo4Budget=10`, `fo4Ps=20`, `budgetMargin=0.2` encode
4000 MHz **for structural analysis**; the STA clock is an independent constraint.
The source of record for this comparison is the frozen emitted tree under
`build-platform/workspace/build/sv-timing/pointer-trial-20261015/baseline/`.
Its original `correct.json` SHA-256 is
`144ec533ef5c2191fb6c4370d9bdd053cdb81e7225f6888e3f6d2629d669f322`.
It contains 451 annotations, 33 InsertReg records and 32 BalanceMux records.
The earlier 82-register/333-failing-path reading predates the generate-local cut
refusals; it must not describe this snapshot.

| Exact source | Measurement | Worst primary | Failing primary / RegToReg | Coverage |
|---|---|---|---|---|
| frozen baseline | delay-v25 | 23.5, scoreboard | 351 / 115 | 264 files, 234 modules, 11,008 paths |
| same bytes | delay-v26 | 21.5, instr_queue | 349 / 114 | identical |
| two-port pointer-selection candidate | delay-v26 | 21.5, instr_queue | 349 / 114 | identical |

These are failing **paths**, not unique endpoints. Synthetic names such as
`scoreboard.reg1/D` do not identify a physical STA pin.
`production_validated=false` remains authoritative: reparse and Yosys elaboration
do not verify data/control alignment after register insertion. In particular, the
existing emit-side sibling/remainder/reduction extras must be checked against the
same-cycle contract; generating a register outside the IR worklist is not proof of
legal retiming.

## A76 — Original-source loop containment (delay-v26)

**Mechanism.** `collect_genvar_loops_in` recorded `Locate.offset` intervals from
preprocessed text as `UserFile` positions. Assignment nodes already used
`SyntaxTree::get_origin`. Removed conditional text or an expanded macro shifted
one coordinate system relative to the other. The scoreboard's `k` could therefore
be billed as a runtime operand in:

```systemverilog
for (genvar k = 1; k < NrCommitPorts; k++) begin
  assign next[k] = flush ? '0 : pointer + W'(count) + W'(k);
end
```

**Fix.** `lower.rs::loop_source_span` maps both loop boundary tokens back to the
original file. Unresolved or include boundaries produce an empty, unknown span.
`TimingModule::genvar_names_at` and `measure::attribute_costs` compare only
same-file, original-source coordinates. Runtime identifiers outside the loop
remain runtime, including a same-named input outside the loop's lexical scope.

**Result.** With unchanged `fo4-v1`, the scoreboard cone falls from 23.5 to 14.5
FO4 because `k` is recognized as an elaboration constant. No SV changes and no
physical speedup are implied. The model still prices constant offsets coarsely;
this fix is not a calibration of a constant adder to one physical gate.
In the frozen 11,008-path comparison, 102 path costs change in either direction;
some FPU paths rise by 1 FO4 when accidental constant attribution is removed.
This is why measurement-version changes require re-analysis of the whole input
closure, rather than adjusting only the headline path.

**Tests.** `loop_constant_scope_uses_original_coordinates_after_preprocessing`
covers a removed 80-line conditional prefix, inside/outside scope, and unresolved
and different-file locations. `procedural_loop_scope_survives_macro_expansion_before_loop`
covers an expanding macro before a procedural loop. The 170 core, 29 transform
and 58 emit tests pass. `delay-v26` invalidates old measurement cache keys.

## A77 — Bounded arithmetic selection versus carry-save compression

**Concept.** A sum of three arbitrary words can use a 3:2 compressor:

```systemverilog
// All operands/results have the same unsigned width W.
sum = (a ^ b ^ c) + (((a & b) | (a & c) | (b & c)) << 1);
```

The identity is modulo `2**W`. It replaces two carry-propagate additions with
bitwise compression and one carry-propagate addition. It is not uniformly faster
after mapping. The actual scoreboard has a much stronger constraint: `count` is
0..2 in `g6lc64_ooo` and `k` is constant. Precomputing the three constant
increments lets the count select the result in the same cycle:

```systemverilog
// Two-commit-port specialization, not a replacement for arbitrary port counts.
// Offset0/1/2 are W-bit localparams k, k+1, k+2.
- assign next[k] = flush ? '0 : pointer + W'(count) + W'(k);
+ assign next[k] = flush ? '0 :
+                  count == 0 ? pointer + Offset0 :
+                  count == 1 ? pointer + Offset1 :
+                               pointer + Offset2;
```

**Verification.** `fixtures/auto_correct/sum3_carry_save.sv` contains generic sums,
the bounded commit-pointer shape, FIFO push/pop delta, and serial/tree popcount.
`tools/sum3_trial.py` runs Yosys SAT on all binary inputs and then maps both sides
with the same Liberty. It records source/library/binary hashes, proof logs,
netlists, area and fresh STA reports. It uses the PGO OpenSTA binary installed
from `tools/openroad`; no host project is imported into a package crate.
The proof covers modular overflow and flush, but not X/Z equivalence or a
sequentially transformed core.

Mapped study: Nangate45 typical, virtual 1 ns clock, 0 ns input/output delays,
0.01 ns input transition and 0.005 pF output load. No placement/parasitics.
Yosys `c30457480`; fork STA binary SHA-256
`e01ed911ddc6ef377c24777075c29918a9188ff3f6056f42c808685bee0ee5fa`.
Artifacts: `/opt/testharness/work/svt-sum3-20261015/`.

| Shape | Serial delay → candidate (ns) | Area before → after (µm²) | Decision |
|---|---:|---:|---|
| arbitrary 5-bit sum, carry-save | 0.321747 → 0.275936 | 45.220 → 46.550 | candidate only |
| arbitrary 16-bit sum, carry-save | 0.713755 → 0.752442 | 174.230 → 184.604 | reject blanket rule |
| 5-bit pointer, 2 commits, carry-save | 0.247047 → 0.292188 | 23.674 → 24.738 | reject for this shape |
| 5-bit pointer, 2 commits, parallel increments | 0.247047 → 0.168715 | 23.674 → 25.536 | promising narrow specialization |
| 6-bit pointer, 2 commits, parallel increments | 0.292386 → 0.230775 | 27.398 → 33.782 | area tradeoff |
| 5-bit pointer, 4 commits, parallel increments | 0.372703 → 0.417343 | 34.846 → 64.106 | reject generalization |
| 4-bit count + push − pop, decoded delta | 0.236688 → 0.197105 | 19.418 → 23.940 | candidate for depth-8 fixup queue |
| 4 pushes + 16-bit pointer, balanced popcount | 0.540763 → 0.586791 | 55.594 → 59.850 | reject here |
| 4 pushes + 16-bit pointer, carry-select upper increment | 0.540763 → 0.545673 | 55.594 → 55.594 | no timing win |
| 8 pushes + 16-bit pointer, carry-select upper increment | 0.774759 → 0.886330 | 81.928 → 79.534 | reject for timing |

SAT passed at widths 1/2/5/6/8/16 for generic sums, widths 5/6 and commit
ports 1/2/4/8 for pointer selection, widths 1..6/8/16 for count delta,
and widths 2/16 with 2/3/4/8 inputs for popcount. The carry-select follow-up also
passed widths 2/16 with 1/3/4/8 inputs, including the narrow-width fallback.
It splits the pointer at `ceil(log2(N))`, computes the low sum and both upper
increments in parallel, then selects by the low carry. Correct algebra alone
did not yield better mapped delay; the fixture retains this negative result.
The four-input mapped reports explain why: both serial and carry-select have
`push[0] → y[15]` as the critical chain through 11 cells
(`XOR2, XNOR2, NOR2, AOI21, OAI21, NAND4, NOR2, AND4, AND4, NAND4, XNOR2`).
The source-level carry-select structure was absorbed into nearly the same
mapped carry chain. Mapping delay objectives, drive strengths and actual loads
must be examined before assigning this rewrite a timing benefit.
No trial changes production
RTL, the cost table, inferred multi-cycle tags or SDC exceptions.

**Full-source cross-check.** Replacing only the pointer expression in a review
copy moves that cone from 14.5 to 12.5 FO4 in delay-v26; another scoreboard cone
is 13.5. `instr_queue` remains the global worst at 21.5. Reading only delay-v25
would incorrectly attribute the global 23.5→21.5 movement entirely to this
rewrite. The physical leaf timing improvement above is independent evidence.
Keep width casts and constant evaluation explicit: an opaque expression's
fallback cost must never be accepted as an optimization win.

## What requires further SystemVerilog work

| Current emitted primary | Live source/concept | Next admissible work |
|---|---|---|
| instr_queue 21.5 / 20.5 | `core/fetch_B/instr_queue.sv:257–264`: popcount(push_instr_fifo) → sequence/ring pointer addition | resolve actual widths and model loop accumulation; tree popcount and carry-select trials did not improve mapped timing; inspect the mapped critical chain before another rewrite |
| wt_dcache_wbuffer 20.0 | `core/cache_subsystem/wt_dcache_wbuffer.sv:651`: count + allocate − pop | decoded delta can preserve simultaneous push/pop; measured width-4 leaf is promising, but reset/queue invariants and whole-block equivalence remain |
| wt_dcache_wbuffer 19.5 | same file, `fixup_rd_req` around line 452: state/valid/dead/refill checks plus tocheck reduction and check enables | combinational factoring/shared decode; do not independently register a request predicate |
| trigger_module 15.0 | indexed CSR trigger access | preserve index/write-enable alignment; evaluate decoder/read mux structure |
| scoreboard 14.5 / 13.5 | `core/scoreboard.sv:783–808`: commit count and pointer offsets | bounded parallel increments for two-port configurations, with a retained generic fallback and integration verification |

The "fat operator, handshake, or multi-cycle tag" conclusion is not exhaustive.
Missing gate information, scope/origin refusal, field-balance residuals, incomplete
width/elaboration knowledge and measurement defects are additional outcomes.
`--assume-clk` supplies names; it does not prove a clock/reset domain or legal latency.
P10 refuses automatic register insertion; it does not forbid an independently
proved same-cycle arithmetic rewrite.
The current `trial_allows(RefuseRegister, kind)` conservatively rejects **all**
existing opportunity kinds. A future automatic constant-increment specialization
needs its own width/domain/equivalence admission; simply enabling existing
BalanceMux or InsertReg on P10 would bypass that distinction.

## Reproduction and reporting

```bash
python tools/fo4_report.py /path/to/correct.json --residuals --top 12
python tools/algo_trace_report.py /path/to/algo-trace.jsonl --json
python tools/sum3_trial.py --yosys /prefix/bin/yosys --sta /prefix/bin/sta \
  --liberty /pdk/typ.lib --out /workspace/pointer --commit-ports 2 --widths 5 6
python tools/sum3_trial.py --yosys /prefix/bin/yosys --sta /prefix/bin/sta \
  --liberty /pdk/typ.lib --out /workspace/delta --count-delta --widths 4
```

`fo4_report` now selects validated emitted re-analysis from `correct.json`;
failed/incomplete emit is INCONCLUSIVE and cannot fall back to `post_closure`.
The residual table keeps I/O and multi-cycle counts visible and ranks RegToReg
loci first. `algo_trace_report` prints actual refusal reasons. Integer path ids
from transform IR must not be joined to post-emit ids.

At the 2026-10-15 22:46 UTC observation the full-core remote job had elaborated and
reached ABC mapping (about 51 GiB Yosys RSS, 10 GiB ABC RSS). No completed full-core
STA report existed. Its eventual result must be bound to that run's input snapshot;
the small-cone STA results above do not substitute for it.

---

# Part LII — Refusal rollback, lexical bindings and admission factoring

## Current status: 10 FO4 is not closed

The 21.5 FO4 frozen emit in Part LI is still a valid measurement of those bytes.
It is not the output of the corrected planner below. Fresh correction and review
candidates at the unchanged **10 FO4 / 20 ps / margin 0.2** target give:

| Input/output | Measurement | Worst RegToReg | All-primary worst | Failing primary |
|---|---|---:|---:|---:|
| fresh correction after rollback repair | delay-v26 | 31.0 | 31.0 | 369 |
| fresh correction after lexical binding repair | delay-v27 | 31.0 | 31.0 | 413 |
| review copy, admission-count factoring | delay-v27 | 20.0 | 30.0 | 412 |
| plus FIFO delta decode and balanced request conjunction | delay-v27 | **16.5** | **30.0** | 411 |

The fresh delay-v27 emit has 451 annotations, 32 BalanceMux records and 19
InsertReg records; joint reparse and structural checks pass on 264 files.
Artifacts are `build-platform/workspace/build/sv-timing/scope-trial-20261015/`
and `queue-factoring-20261015/`. The latter contains **review copies**, not live
RTL changes. There is no whole-core functional-equivalence or timing-closure claim.
The all-primary maximum includes the `stream_arbiter` I/O cone; do not describe
the RegToReg headline as the maximum over every single-cycle path.

## A78 — A refused cut trial must not mutate the design

`apply_work_item` previously expanded an expression spine before checking whether
the register plan was admissible. Expansion changes the original node's cost/RHS,
adds synthetic nodes and changes a path. A later gate/scope refusal left those
mutations behind, influencing other paths sharing the node and subsequent cut
selection despite there being no corresponding emitted edit.

`pipeline::prepare_pipeline_cuts` now checks latency, allowlist and gate first,
then saves only the selected path's existing nodes. A rejected plan restores the
nodes, path and prior dirty flag and removes newly allocated ids. It does not clone
the whole design. Accepted plans retain their expanded nodes for insertion.
Tests cover an early missing-gate refusal, a later block-local refusal, preservation
of already-pending work, and a successful plan. `cut.refuse_detail` trace events
retain the actual failure text.

The fresh `instr_queue` refusal is now explicit:
`rank <- rank + 1'b1` is block-local. Hoisting a pipe feed from that point to
module scope would be invalid. Do not work around the refusal by leaving its
speculative IR in place or booking an unimplemented half-split.

## A79 — Lexically distinct declarations are distinct timing signals

The module-wide P5 definition map previously keyed locals by source spelling.
Two independent `rank` variables in `instr_queue`'s slot-compaction and FIFO-data
processes were connected. `DeclSite::scope` now stores the nearest mapped
original-source scope; `ref_order::BindingIndex` constructs private keys for P5
and procedural dependency edges. Module nets still connect processes, and a local
shadow no longer replaces the module binding. IR source strings and emitted SV
names do not change. Unresolved scopes remain conservative.

The regression constructs two local `tmp` variables plus a global `tmp` multiply.
Neither local consumer may inherit the global multiply or the other block's
definition, while the intended global consumer must still see it. The cost/cache
semantics are **delay-v27**. The scope guard also distinguishes `record.member`
and `pkg::member` from a block-local variable named `member`.

This repairs binding identity, not all dataflow modeling. Region lowering still
creates conservative source-order fan-in edges, and loop elaboration/control
dependencies need further work. Do not infer an immutable physical floor from
the remaining report.

## A80 — Move population counting before admission

The actual queue cone contains more than `pointer + popcount(push)`. It compacts
valid slots into circular FIFO positions, checks space, permits a leftover slot-zero
exception, gates all pushes on address-space availability, and only then counts.
For a power-of-two FIFO bank, compaction is injective and preserves population
count. A partial admission accepts exactly one slot:

```systemverilog
// Original: count after compaction, overflow and partial-admission selection.
step = popcount(pushed_mask);

// Review candidate: precompute count and select after admission.
count = popcount(valid);
step = address_overflow ? 0 : partial ? 1 : overflow ? 0 : count;
```

`queue_count_trial` / `queue_count_miter` in
`fixtures/auto_correct/sum3_carry_save.sv` prove both the count and next pointer
for all binary masks, heads, full flags, leftover flags and address-overflow flags
at **2/4/8 slots**. Helpers mirror the contract, not project package imports.
No stage or architectural state is added. Four-state X/Z equivalence, one-slot
geometry and full host integration remain separate gates.

Nangate45 typical, identical STA constraints and timing-constrained ABC (`BUF_X1`,
5 fF mapping load, `-D 250`); combinational study:

| Slots, pointer width | Original → factored delay (ns) | Area (µm²) |
|---|---:|---:|
| 2, 16 | 0.644000 → 0.488837 | 84.854 → 76.608 |
| 4, 16 | 1.059211 → **0.787434** | 183.274 → **152.950** |
| 8, 16 | 1.631561 → 1.184044 | 427.728 → 387.296 |

The four-slot result is a measured improvement in the relevant cone, rather than
another isolated adder rewrite. It still misses 250 ps. The companion review
change decodes `{allocate,pop}` into hold/increment/decrement for the write-buffer
count (the Part LI width-4 proof), preserving simultaneous push/pop. Balancing
the pure request conjunction changes its structural expression depth; no standalone
physical gain is claimed for parentheses that a mapper may already balance.

## A81 — Cached carry predicates: faster counters with explicit state cost

`fixtures/auto_correct/bounded_step_counter.sv` implements a bounded-step counter
transition, an inductive witness and a registered wrapper. For each segment
boundary `b`, cached bit `F[b,d]` means:

```text
low_b(pointer) >= 2**b - d, for 1 <= d <= maximum_step.
```

It supplies the carry into a segment without propagating the new carry through
the whole word. Next predicates use constant, possibly wrapping intervals:
`(old_low + e) mod 2**b >= 2**b-d` iff old_low belongs to
`[(-d-e) mod 2**b, (-1-e) mod 2**b]`.
The proof assumes the current invariant and proves the next visible pointer and
all next predicates for arbitrary pointer values, including wraparound. Flush
proves the zero-reset base. The wrapper registers both states on the same
`posedge clk_i` / `negedge rst_ni`; it introduces no visible cycle of latency.

A four-input thermometer network avoids serial binary count decoding in predicate
selection. Parameter-edge proofs cover widths 1/4/5/16/17 with 1/3/4/8 inputs,
the wrapping case of 15 inputs at width 5, and 8-bit segment partial-word cases.

| Registered 16-bit counter, 4 inputs | Required period (ns) | Total mapped area (µm²) | Extra state bits |
|---|---:|---:|---:|
| ordinary binary counter | 0.596693 | 179.284 | 0 |
| cached thermometer, 4-bit segments | **0.450162** | **362.824** | 12 |
| cached thermometer, 8-bit segments | 0.486596 | 254.562 | 4 |

These include mapped register timing and area, but not placement/routing.
Both candidates fail 250 ps. They are research implementations, not an automatic
replacement for a core counter: reset, enables, scan observability and configuration
integration remain obligations. A lower transition-only delay must not hide the
cost or paths of predicate registers.

## Efficient search and the completion gate

`tools/sum3_trial.py` now supports named `--variants`, `--proof-only` parameter
checks, `--abc-delay-ps`, `--abc-driving-cell`, `--cached-counter`,
`--block-bits`, `--registered` and `--queue-count`. Every run retains inputs,
driver, hashes, proofs and fresh reports. Screening is per width within the same
run and keeps delay, area and redundant state as separate costs. Unknown area
cannot establish dominance. Successful tool execution is separate from meeting
the requested delay target.

Do not repeat rejected source-only structures on the full core. Explicit late-carry
and parallel-prefix adders did not beat the original; merely setting ABC `-D 250`
without its constrained-mapping recipe had no effect. With that recipe, the original
four-input popcount/counter cone improved 0.540763 → 0.438857 ns, at higher area.

The host now stops `timings sta-rtl` before synthesis when a valid emitted report
still misses the requested budget. `--allow-over-budget` or
`physicalDesign.structural.allowOverBudget=true` explicitly requests a study and
labels it as such. Missing/partial emitted evidence cannot use this bypass.
Reusing a package checks the same gate. Dry runs preserve prior emitted artifacts.

Next targets are the remaining queue/write-buffer 16.5 FO4 cones, indexed trigger
access at 15, scoreboard count/select at 14.5, and the 12.5–13 FO4 selection cones.
The current callback cannot legally pipeline a block-local loop accumulator on its
own; packet data, admission, replay and consumed-mask alignment require a real
interface-level transformation. Completion is still pending.

The previous flat full-core mapping did **not** finish: the kernel OOM log records
Yosys PID 3446654 killed at 2026-10-15 23:41:42 UTC, after roughly 6945 seconds
with about 51 GiB resident memory. Its orphaned ABC process was cleaned up.
No full-core STA result exists from that run. The host now offers
`--map-recipe hierarchical`, using slang `--best-effort-hierarchy` and omitting
flattening; a registered two-module fixture mapped successfully with both modules
retained. Full-core use remains an explicit study, not evidence of 10 FO4 closure.

The hierarchical smoke exposed another real handoff defect: the lean recipe did
not run `opt_dff`, leaving slang's constant-asynchronous-load flops as
`$_ALDFF_PN_`. STA treated those as black boxes and could print a finite-looking
`1e39` slack with **no paths**. The recipe now normalizes flops before techmap;
standalone STA links with `-no_black_boxes`, the timing Tcl requires a constrained
maximum-delay path, and the host/trial parsers reject no-path infinity sentinels.
The repaired hierarchical fixture produced real max/min timing reports. This is
a flow-correctness repair, not a clock-frequency optimization.

A new live-RTL hierarchical baseline study was launched under an explicit
16 GiB maximum virtual-memory cap (also bounded by available host memory), in
`~/.cache/g6lc-sta/g6lc64_ooo-hierarchical-20261016/`. It uses the PGO fork and
cleans its own mapper process group on exit. It is separate from the 10 FO4
candidate; neither a successful mapping nor a positive setup slack alone proves
whole-core completion.

---

# Part LIII — Measurement truth: coordinates, widths, casts, multi-operand sums

## Current status (2026-10-16): 10 FO4 is not closed; the board is now trustworthy

Four measurement corrections (delay-v28 … delay-v31) and one host input (the
elaborated `CVA6Cfg` snapshot) changed the report more than any transform did.
All numbers below are structural FO4 at **10 FO4 / 20 ps / margin 0.2** on
`g6lc64_ooo`; `baseline` is the live RTL, `review` the Part LII review copies
(`instr_queue` admission factoring, `wt_dcache_wbuffer` delta decode).

| Measurement | Worst RegToReg | Failing primary | Note |
|---|---:|---:|---|
| delay-v27 baseline | 31.0 (`instr_queue`) | 413 | three `rank` chain nodes at reference width |
| delay-v28 baseline | 31.0 | 394 | `stream_arbiter` 30 FO4 wrapper artifact gone (A82) |
| delay-v29 baseline | 22.0 | 771 | width scaling: narrow counters fall, 64-bit datapath rises to 12 (A83) |
| delay-v30 baseline | 75.0 (`fpnew_fma_multi`) | 677 | casts parsed: hidden fpnew exponent sums exposed (A84) |
| delay-v31 baseline | 27.0 (`g6lc_bp_ckpt`) | 677 | multi-operand sums are CSA + one CPA (A85) |
| delay-v31 + cfg snapshot, baseline | **22.0** | 700 | `TRANS_ID_BITS`/`NrHarts`/`INSTR_PER_FETCH` resolved (A86) |
| delay-v31 + cfg snapshot, review | 21.0 (`fpnew_fma_multi`) | 696 | `fpnew_fma_multi` is not instantiated in this config |
| delay-v32 + cfg + elaborated widths, baseline (live modules) | **26.8** (`instr_queue`) | 521 | 126 file-list modules not in the elaborated design excluded (A89) |
| delay-v32 + cfg + elaborated widths, review | 17.0 (`g6lc_bp_ckpt`) | 515 | precomputed step increments added to the review copy (A88) |
| delay-v33 + cfg + widths + manifest defines, live RTL (A92 edit) | **24.0** (`frontend`) | 564 | the B-path code is now what is measured (A93); runtime indexed selects cost a mux |
| delay-v33 …, emitted latency-neutral (31 BalanceMux + 1 SelectIncrement) | 24.0 (`frontend`) | 528 | `instr_queue` 24.3 → 15.8 (A92 + A91) |
| delay-v34 (`\|\|`/`&&` parsed as joins), live RTL | **23.0** (`frontend`) | 505 | every logical join had been billed as `\|` + a reduction (A95) |
| delay-v34, emitted latency-neutral (303 BalanceMux + 29 RebalanceAssoc + 1 SelectIncrement, 22 passes) | **20.0** (`frontend`) | 465 | planner reaches plain cones in S3, rebalances write RTL (A96); joint reparse of 264 files ok |
| delay-v35 (loop-carried chains), live RTL before A98/A99 | 78.9 (`scoreboard` cancel walk), 63.2 (`g6lc_rob` free walk) | 681 | the chains the mapped netlist's 436-cell path is made of, visible structurally for the first time |
| delay-v35, live RTL with A98 + A99 | **23.0** (`frontend`) | 435 | scoreboard worst 13.6, rob 11.3; the frontend cone is again the board's head |

The failing-path count went **up** with width scaling: a 64-bit add is 12 FO4
at this table, so every single-cycle 64-bit adder path now misses a 10 FO4
budget. That is the physics of XLEN=64 at 4 GHz / 20 ps, not a regression, and
it is the honest shape of the remaining gap: AGENTS.md §3.2.1 — `fo4_ps` is a
process input (10 FO4 at 20 ps, 16.7 at 12 ps).

Top remaining live RegToReg cones (review tree, delay-v32 + cfg snapshot +
elaborated widths; 1390 reg-to-reg paths, 155 failing, structural maximum
≈ 2353 MHz): `g6lc_bp_ckpt` L345 17.0 (a real 4-bit chain pop_diff →
pop_dist → alloc_free → head_d, 5.5+1+4+6.5), `fpnew_fma` L303 14.9 (exponent
datapath, `EXP_WIDTH` from a package function — sized by the width map where
the net survives), `frontend` L727/L614 14.5 (64-bit branch-target adder behind
a mux — a fat-operator leaf at XLEN=64; and the slot-live chain),
`wt_dcache_wbuffer` L623 13.5, `instr_queue` L658 13.0 (push-address select),
then a wall of 12.0–12.5 entries that are one 64-bit add or compare plus a
mux. The live baseline without the review edits reports 26.8 (`instr_queue`).

## A82 — Constant-span exclusion in origin coordinates (delay-v28)

`lrm_constant_spans` (packed/unpacked dimensions, case labels, replication
counts, generate headers, now also parameter/localparam/typedef declarations)
compared raw parser offsets against operator locations already mapped to the
original source. The two frames drift: the preprocessor shifts its output by
22 bytes after `parameter ARBITER = "rr" // "rr" or "prio"` (a string default
followed by a quoting comment), so every `[N_INP-1:0]` port range in
`stream_arbiter` escaped the exclusion and the instance-only wrapper reported a
30 FO4 "path" of three 10 FO4 adders. Spans are now mapped through
`SyntaxTree::get_origin` like the operators (`origin_byte_span`), and every
declaration text extraction (`packed_dimension_text`, parameter defaults,
function bodies) reads `SyntaxTree::get_str` — the frame the offsets address —
instead of slicing the original bytes. Regression:
`lower::tests::port_dims_and_parameters_are_not_datapath_after_a_header_comment`
(fails with raw spans: five phantom nodes).

## A83 — Width inference and normalized scaling (delay-v29)

`crate::width` implements OPTIMIZATION-LEVELS §1.1(2), which had been
documented as built and was not: every node carried `width: 1,
width_defaulted: true`, so a 3-bit FIFO pointer increment cost the whole 10 FO4
budget and a 64-bit datapath add cost the same 10.

Widths come from declarations (`DeclSite.packed_text`/`type_name`, ports'
`dimension_text`), module and package typedefs (`typedef_texts`, enum base
vectors), parameters/localparams (`const_exprs`, evaluated with the `Expr`
parser: `+ - * / % ** << >> ?: $clog2`), imported-package constants and the
host param-map (`param_map_ints`). Context (IEEE 1800 §11.6/§11.8): arithmetic
at `max(LHS, operands)`, relational/equality at their operands (never the 1-bit
LHS); constants and unrolled loop variables (`DeclSite.loop_var`) do not set a
width. Unresolved stays at the reference width — an unknown is never cheaper.

Scaling laws were **measured** on Nangate45 with the fork's `sta` and the
structure-preserving ABC script (ratios to the 32-bit cell):

| Class | Law | Measured w = 4 / 8 / 16 / 32 / 64 |
|---|---|---|
| `add_sub`, `compare`, `shift_var` | `log2(max(w,2)) / 5` | `<` 0.41/0.52/0.92/1.0/1.09; `<<` 0.45/0.68/0.81/1.0/1.19; law 0.4/0.6/0.8/1.0/1.2 |
| `mul`, `div_rem` | `w / 32` | `*` 0.15/0.37/0.62/1.0 — the plan's `(w/32)²` is area-like, rejected |
| everything else | 1 | `&` flat |

Adders are log-depth only under the delay-oriented script (0.617/0.770 ns at
32/64 bits); Yosys's default liberty script collapses the Brent–Kung `$lcu` to
ripple (0.905/1.786 ns). The model assumes the former; a flow that produces
ripple carries misses it — that is the flow's defect, fixed in the host (A87).

## A84 — Casts are wiring; constant coefficients are shift-adds (delay-v30)

`W'(e)`, `int'(e)`, `pkg::t'(e)`, `type(x)'(e)` and unsized `'(e)` are
transparent: the inner expression is the datapath. The old parser only
collapsed `W'(const|ident|ident±1)` and left every other cast unparsed, so the
whole RHS fell to the string heuristic — which billed the `-` of a part-select
bound inside `XLEN'({pmpaddr_q[i][PLEN-3:1], 1'b1})` as a 64-bit adder
(csr_regfile 12 FO4 arms) and hid fpnew's exponent arithmetic entirely. The Mul
worry that motivated the restriction (`int'(group_q)*6`) is handled where it
belongs: `x * Const` is a shift-add CPA (`AddSub`), never free, never the
56 FO4 array; `x * y` stays `Mul`. `x == '0` / `'1` fill-literal compares are
reduce-detects. The exposed fpnew sums were real — and over-counted (A85).

## A85 — Multi-operand sums are carry-save plus one CPA (delay-v31)

`a + b + c - d + e` was billed as four serial CPAs (fpnew `exponent_product`:
52.5 FO4). Synthesis (`alumacc`/`maccmap`) builds a 3:2 compressor tree and one
final adder. Measured (nf script, Nangate45): 2/3/5 operands at 32 bits =
0.617/0.726/0.901 ns — about 0.095 ns (~1.5 FO4) per extra operand,
width-independent. `Expr::fo4_critical_cost_latticed` and the cut spine now
flatten `+`/`-` trees: `AddSub(w) + 1.5 × (N − 2) + worst leaf`, constants
folding into one operand, trees of two operands unchanged (`x + 1` is still an
increment). `CSA_LEVEL_LOGIC_BITS` is the constant.

## A86 — Elaborated `CVA6Cfg` snapshot (host)

The host param-map carried XLEN only. `build_config_pkg::build_config` is a
500-line function; rather than re-implement it, `tooling/cfgSnapshot.ts` has
yosys-slang evaluate it: it parses `cva6_cfg_t` for its 222 `int`/`bit`
fields, generates a probe module with one output per field declared
`logic [CVA6Cfg.<Field>:0]`, elaborates the three config packages plus the
probe, and reads each port's bit count from `write_json` (value = width − 1).
`sta-rtl` merges the result into `svt/param-map.json` as `CVA6Cfg.<Field>` /
`cva6_cfg.<Field>` (`svt/cfg-snapshot.json` keeps provenance). With it the
scoreboard commit-pointer adds (5 bits) and `g6lc_bp_ckpt`'s span arithmetic
(4 bits) resolve; `g6lc_fetch_pkg::geo(CVA6Cfg).slots`-style function-derived
localparams and fpnew's `exp_bits()` widths do not. For those the elaborator's
own net widths are the input: `tools/rtlil_width_map.py` turns the `write_rtlil`
dump the streamed recipe's phase A produces (after `read_slang; hierarchy;
proc; …`) into `{module: {net: bits}}` keyed by base module name (slang's
`name$hier.path` specializations merged, widest wins — the conservative
direction); `analyze`/`correct --width-map` attach it (`ParamMap::width_map`,
fingerprinted as `__width_map` for the cache) and `WidthResolver` consults it
only for signals the source could not size and whose declaration is packed
(unpacked arrays are memories or flattened wires there). The remote `sta-rtl`
streamed run parks the map under the proxy's `runs/<tag>/output/`, the host
pulls it to `svt/width-map.json`, and the next pre-pass passes `--width-map`.
Tests: `width::tests` (elaborated fixture entry fills `two_d`, refused for the
unpacked `mem`, ignored where source sizing wins), `verif/regress/
test_rtlil_width_map.py`.

## A87 — Whole-core mapping on the builder: what it took, what is still open

Three whole-core mappings died before STA: flat `lean` (OOM-killed in ABC at
51 GiB RSS), hierarchical (bad_alloc in `techmap` at 44 GiB under a 48 GiB cap),
hierarchical with the SRAM study stub (bad_alloc in `opt_clean` at 48 GiB).
The gate-level representation of this core does not fit the builder's free
memory in one process; the word-level design is ~12 GiB. Host changes:

- `scripts/tc_sram_timing_stub.sv` replaces the behavioural `tc_sram`
  (`--no-sram-stub` keeps it): the macro boundary stays registered, no
  flop-per-bit array. A study netlist, not a functional model.
- `--map-recipe streamed`: phase A lowers to word level and dumps RTLIL plus the
  module list; phase B maps one module at a time (`techmap; dfflibmap; abc;
  write_verilog -selected; delete`) so only one gate-level module exists at a
  time; OpenSTA links the per-module netlists hierarchically.
- ABC runs the delay-oriented structure-preserving script with the clock period
  (A83); the lean recipe runs `opt_dff` so slang's constant-async-load flops do
  not reach STA as black boxes; `openroad-timing.tcl` links `-no_black_boxes`
  for standalone `sta` and refuses a design without a constrained max path; the
  result parser rejects `1e39` no-path sentinels; a dry run is SKIP, not STA.

The streamed live-RTL study is running under a 48 GiB cap in
`~/.cache/g6lc-sta/g6lc64_ooo-streamed-20261016/`: phase A (word level) took
699 s and 17.8 GiB and produced 461 specialized modules; phase B maps them one
at a time (a large module can hold ABC for 20 minutes). No whole-core mapped
STA number exists yet; when one does it anchors the model, it does not certify
10 FO4.

## A88 — Precomputed step increments (review candidate, instr_queue)

`push_seq_d = push_seq_q + 16'(shamt)` and `idx_is_d = (idx_is_q + shamt) &
IdxMask` sat at the end of the admission cone (cf-type compare → mask → valid →
slot0 rotate → overflow → partial → `shamt` mux, 10.3 FO4) followed by a 16-bit
add (8): 18.3 FO4, the live worst once widths were known. `shamt` is 0..NrFifo,
so every candidate sum is a constant-offset increment of the *register* alone:

```systemverilog
for (genvar k = 0; k <= NrFifo; k++) begin : gen_step_cand
  assign push_seq_cand[k] = push_seq_q + 16'(k);
  assign idx_is_cand[k]   = (idx_is_q + fifo_idx_t'(k)) & IdxMask;
end
assign push_seq_d = push_seq_cand[shamt];
assign idx_is_d   = idx_is_cand[shamt];
```

The increments leave the admission cone (they start at the clock edge); the
cone ends in a 5:1 select. Exact modulo 2^W, same cycle, no state added; the
cost is NrFifo+1 incrementers of W bits. This is the Part LI two-port pointer
specialization (mapped 0.247 → 0.169 ns) applied to the sequence counter; it
was first a review copy; it is now the `SelectIncrement` transform (A91).

## A89 — Only instantiated modules decide a target's period

A file list carries every module a *family* of configurations can use. With
an elaborated width map present, `frequency_closure` counts only the modules
the elaborator instantiated and lists the others as `uninstantiated_modules`
(126 on `g6lc64_ooo`: `fpnew_fma_multi`, the C910 `pa_fdsu_*` divider, the
generic RAM models, …). `fpnew_fma_multi`'s 21.0 was the headline for a module
this target does not build. Paths of dead modules are still analyzed and
listed; they no longer set `worst_path_fo4`, `closes` or the failing counts.

## A91 — `SelectIncrement`: the transform, end to end

`sv-timing-core::select_increment` recognizes `LHS = REG + step` and
`LHS = (REG + step) & MASK` on a continuous or `always_comb` assignment where
`REG` is a register root (an `always_ff` non-blocking LHS, optionally
`REG[CONST]`), `step` a bare module-scope identifier of resolved width
`k ≤ 4` that is not itself a register, and the result is cheaper as a select:
`fo4_after = ceil(k/2) × mux (+ logic_bit for the mask)` against the node's
adder cost, with an area guard `2^k × W ≤ 512` bits. `suggest_opportunities`
emits `OpportunityKind::SelectIncrement` on any failing path carrying the
shape; the planner ranks it first (`pick_opportunity_for_card`, worklist
order), and it is the one kind a `RefuseRegister` (P10 handshake) trial
still allows — an exact same-cycle rewrite of one arithmetic node changes
neither protocol nor select structure.

The transform (`pipeline::select_increment_on_node`) is a real IR rewrite,
not a credit: `2^k` candidate nodes `cand[j] = (REG + j) [& MASK]` join the
node's region (register-fed, parallel), the origin node becomes the select
(`cand[step]` for k ≤ 2, `step[k-1] ? cand[{1'b1, lo}] : cand[{1'b0, lo}]`
for k = 3..4 so the structural model and the netlist agree on two levels),
and the remeasure recomputes the def-use paths. Emission reuses the BalanceMux
origin-rewrite machinery (`EditKind::SelectIncrement`): a module-scope
`var type(LHS) cand [0:2^k-1]` plus `for (genvar …) assign cand[j] =
type(LHS)'(…)`, injected before the origin process, and the origin RHS
replaced — gated by the same structural-emit switch as BalanceMux RTL.

Because an `arr[idx]` read was free in the model, the transform could have
booked the whole adder as gain; delay-v33 bills a runtime indexed select as
one mux level (constant indices stay wiring), which also corrects every
`mem[idx]` in the core.

Evidence: `fixtures/auto_correct/select_increment.sv` (a 16-bit sequence
counter and a 2-bit ring index behind an admission cone) goes 15.0 → 12.5
structural, the 2-bit index is correctly left alone; the emitted pair was
proved equivalent with Yosys SAT (12-step miter from reset and 6-step from
free state, both `SUCCESS`) and mapped on Nangate45 with the delay script:
gold slack 0.0552 ns → gate 0.0726 ns at a 1 ns clock. Regression:
`sv-timing-emit::tests::select_increment_fixture_emits_candidates_and_select`,
`select_increment::tests`. On `g6lc64_ooo` the pre-pass applies it once
(`instr_queue` `push_seq_d`, 8 candidates after A92 narrowed `shamt`).

## A92 — Production edit: `instr_queue` counts before admission

The live worst after A88–A90 was `instr_queue`'s `gen_shamt` — a serial
popcount of `push_instr_fifo` at the *end* of the admission cone (cf-type
compare → mask → valid → slot compaction → overflow → partial → push) feeding
the 16-bit sequence add: 24.3 FO4. `popcount(push_instr_fifo)` equals
`address_overflow ? 0 : lo_partial ? 1 : instr_overflow ? 0 :
popcount(valid)` because `fifo_pos` sets one distinct bit per valid slot
(ranks are distinct modulo NrFifo), `slot0_pos` is one-hot exactly when
`valid[0]`, and `lo_partial` implies `valid[0]` (`leftover_slot0_push`).
`core/fetch_B/instr_queue.sv` now counts `valid` at the head of the cone and
lets the three admission outcomes select; `shamt` is sized `$clog2(NrFifo+1)`
(3 bits for NrFifo = 4, so SelectIncrement builds 8 candidates, not 16).
Exhaustively proved equal with `sat -verify` for NrFifo = 2, 4, 8
(`fixtures/auto_correct/instr_queue_shamt_equiv.sv`, which copies the
production cone verbatim); the whole core still elaborates (`hierarchy
-check -top cva6`, 57 s). Live `instr_queue` RegToReg: 24.3 → 18.3; with the
automatic SelectIncrement on the emitted tree: 15.8 (the admission cone
itself is 10.3, the floor for anything that depends on `shamt`).

## A93 — The measured design was not the synthesized design

`writePortableTimingsFlist` dropped the manifest's `+define+` lines, so
sv-timing read `core/Flist.cva6` without `G6LC_FETCH_B` (and without the
synthesis defines) — the A-path code under `ifndef G6LC_FETCH_B` was measured
and the B-path code was not. The portable flist now carries the manifest's
defines plus `verify.synthDefines`. Board under the right preprocessing
(delay-v33, cfg snapshot, elaborated widths, live modules): live RTL worst
RegToReg **24.0** (`frontend` L1033 `speculative_d`), 191/1371 failing;
emitted latency-neutral tree **24.0**, 194/1383 (the BalanceMux `pipe_svt_red_*`
feed flops it emits are write-only — dead after synthesis, but they create
phantom endpoints in the structural report; see AGENTS-todo).

Remaining live RegToReg leaders, all real RTL: `frontend` `speculative_d`
24.0 (`slot_live` 7.5 + `is_return`/`is_jalr` chain + an 8-op and/or spine
whose `|is_branch || |is_return || |is_jalr` folds exactly to one 12-bit
reduce), `csr_regfile` `guest_time`/`vstimecmp_hit_d` 16.8 (64-bit add then
64-bit compare in one cycle — a timer compare that tolerates one cycle of
latency, a decision for the owner), `frontend` `kill_drop`/`icache_take`
16.5, `instr_queue` 15.8/15.3, `g6lc_bp_ckpt` 15.0, `fpnew_fma` 14.9.

## A94 — Parallel per-module mapping on the builder

The single-process phase B (map one module, `delete`, next) grew to 34 GiB
RSS after 375 modules and spent 58 minutes in one ABC run (`g6lc_iq`, then
`scoreboard`), blocking the rest. Phase B is now one yosys process per
module: `rtlil_width_map.py --split-dir` writes every module of the phase-A
RTLIL as its own file (header replicated, attributes travel with their
module) and `xargs -P nproc/2` runs `map_one.sh` — `read_rtlil; techmap;
dfflibmap; abc` with the delay script under `timeout`, falling back to the
plain liberty script and then `abc -fast`, each module logging which script
it got (`SYNTH_STREAM_FALLBACK`). 458 of 461 modules mapped in three minutes;
the three large ones run concurrently under the 30-minute per-script timeout.

## A95 — The grammar split `||` into `|` plus a reduction (delay-v34)

`match_op` at the bitwise-or precedence level listed only `|`, so `a || b`
parsed as `a | (|b)` — every logical join in the core was a bitwise op plus a
unary reduction (two LogicBit instead of one), and a rebalance emitted from
such a tree would have printed `a | |b`, which is **not** `a || b` for a
multi-bit `a`. `match_op` now refuses a shorter operator when a longer one of
the grammar (`||`, `&&`, `<<`, `==`, …) begins at the cursor and belongs to
another level. Live board 24.0 → 23.0, failing 564 → 505 on identical RTL.
`rebalance_associative` also folds `|a || |b || |c` into `|{a, b, c}` and
`&a && &b` into `&{a, b}` (exact: one-bit operands, one wide reduce tree
instead of a reduce per operand plus a join chain); frontend `speculative_d`
23.0 → 20.0.

## A96 — Three planner defects that hid plain cones from S3

1. **Fixpoint on an untouchable leaf.** The stop rule measured Δ of the
   global worst primary path — a 226 FO4 multiplier nothing may touch — so
   every pass was "flat" and S3 ended after two passes with one worklist page
   done (32 edits). Progress is now measured on the worst *actionable* path
   and the actionable negative-slack sum (`actionable_progress`): 22 passes,
   333 edits on the same design.
2. **Register-preferring cards dropped in S3.** A plain cone's card prefers
   `t2_insert_reg`; the S3 filter kept only latency-neutral kinds, so plain
   cones never got rebalance/split/select tries unless an S4 (which a
   no-latency run never enters) came. S3 now substitutes the best
   latency-neutral opportunity of the path, or synthesizes a trial on the
   hottest user-source node (`t1_neutral_trial`).
3. **Origin outside user source refused the whole path.** The hottest node
   of frontend's cone (`slot_live`) sits in a conditional-compilation region;
   `origin_not_user_file` refused the item. A latency-neutral rewrite now
   falls back to the hottest user-source node of the path (a register cut
   still must sit exactly where its opportunity says), and the associative
   rebalance is tried on every node of the path by FO4, not only the hot one.

`RebalanceAssoc` records carried `emit_rhs` but no snippet, and the origin
rewrite required a safe snippet — so rebalances booked IR FO4 the emitted
file never had. A pure RHS rebalance now rewrites its origin when the assign
is outside any generate and the new RHS names exactly the identifiers of the
old one (`ident_set`); the emitted `speculative_d` reads
`((speculative_q && !resolution_for_active) || |{is_branch, is_return, is_jalr}) && (!flush_i && !smt_restore_flush)`.

## A97 — First whole-core mapped STA (fanout-dominated; not a logic-depth number)

The parallel phase B mapped all 461 modules (`g6lc_iq` and `scoreboard` took
the plain-script fallback after the 30-minute delay-script timeout; 37 GiB
peak across six jobs, 56 minutes): 1,201,204 instances, 1.98 mm² Nangate45,
and OpenSTA linked the hierarchical netlist (38 s, 3.8 GiB) after the icache's
`$aldff` (a reset to a non-constant value) was made synchronous for the study
(`async2sync t:$aldff`). The reported `wns_max` is **−1446 ns** at a 0.8 ns
clock — meaningless as logic depth: the worst path is a flush broadcast
(`controller` NAND4 → 54 nF net → ROB flops) whose unbuffered 50k-fanout nets
contribute 222 and 917 ns. Excluding the broadcast drivers found in the top
300 paths iteratively (`set_false_path -through`, 11 nets) still leaves
−678 ns: a mapped netlist needs `repair_design` buffering (OpenROAD, placed or
per module) before its STA says anything about the datapath. Next: run the
top modules' netlists through OpenROAD `repair_design` individually, or a
fanout-insensitive report; the host flow now gets this far in one command.

## A98 — Loop-carried chains: the model was blind to what the netlist is made of (delay-v35)

The first whole-core mapped STA (A97) with broadcast nets excluded
(`OR_IGNORE_FANOUT_ABOVE=256`: 873 driver cells disabled) reported a
**436-cell** path `issue_read_operands → scoreboard → rob` (−79.7 ns at a
0.8 ns clock): alternating NOR4/NAND4 each driving ~200 loads — the shape of
an unrolled `for` whose body steps a pointer and decodes it. The structural
model billed every such loop as **one** iteration: a procedural `for (int k…)`
is elaboration-constant in `k`, and a body variable it also reads
(`cid = cid + 1` under `if (cid == ip) break`) was costed once.

Fixture measurement, Nangate45, delay-oriented ABC, 32 entries
(`sb_walk`/`sb_window` in `fixtures/auto_correct/scoreboard_window_equiv.sv`):

| shape | cells on path | path | area |
|---|---:|---:|---:|
| pointer walk with break (production before) | 144 | **14.7 ns** | 6773 µm² |
| same, plain ABC script | 133 | 15.2 ns | 6914 µm² |
| per-slot ring-interval membership (production after) | 12 | **0.78 ns** | 613 µm² |

Synthesis does **not** fold `cid = cid + 1` across iterations (each step's
carry waits for the previous sum) and does not re-associate the break chain.

delay-v35 therefore bills loop-carried accumulators of procedural loops with
a resolvable header (`k = A; k < N` through the width resolver's constant
lattice — `CVA6Cfg.NR_SB_ENTRIES` from the cfg snapshot): a variable **read
before any write of the same iteration**, or whose first write reads itself,
is a chain; a temp written then read inside one iteration (`rslot = base +
i; … mem_q[rslot]`) is not. Bitwise/logical self-accumulates (`any |= hit[k]`)
are AND/OR trees ABC balances — `⌈log₂ N⌉` copies; arithmetic and
compare/mux updates (`cid = cid + 1`, `idx = hit[k] ? k : idx`) cost `N`
copies (cap 64). Unknown bounds leave the node alone. `if (cond) x = const`
still carries its cost in the condition, which the lowerer does not bill
(todo). Two production walks fell out of the board at once:

- **scoreboard** — both younger-cancel walks (`mem_n[..].cancelled`, the
  `cancelled_mask_o` mask) now test each slot's membership in the ring
  interval `[after_flu_wb, issue_pointer[0])` from one `bmiss_window`
  vector (two compares and a mux per slot). Exact for `NR_SB_ENTRIES ==
  2**TRANS_ID_BITS`; empty interval ⇒ nothing, as the immediate break did.
  Yosys SAT over all inputs for N = 4, 8, 16 (`sb_walk ≡ sb_window`); the
  32-entry miter (1.5 M variables) runs with a time budget. Structural
  78.9 → 13.6.

## A99 — ROB free-by-tid and head re-anchor (delay-v35, exact)

`g6lc_rob`: `for r: if ack[r]: for i: if (valid && tid match) {valid = 0;
count_d = count_d - 1}` is a `NR_RETIRE × ROB_ENTRIES` chain of conditional
decrements (structural 63.2 at 2 × 32); the head re-anchor `for i: if (head
!= tail && !valid[head]) head++` is a 32-step walk with a dynamic index per
step. After: per-port hit vectors (`free_hit[r]`, taken on the state port
r−1 left so two ports naming one tid still free and count one) with `count_d
-= $countones(free_hit[r])`; the re-anchor computes `stop[j] = valid[head +
j] || (j == tail − head)`, isolates the lowest set bit (`stop & (~stop + 1)`,
never empty) and OR-encodes it — a find-first without a priority chain.
Exact for `ROB_ENTRIES == 2**ROB_W`. Proof: **whole-module sequential miter**
of the pre-change RTL against the new one (Yosys SAT, 6 steps from reset) at
`ROB_ENTRIES = 4`; the 8-entry miter (304 k variables) exceeded a 40-minute
budget — inconclusive, not a counterexample. Structural
63.2 → 11.3. The whole core elaborates with both edits (slang, remote).

Host: `openroad-timing.tcl` gained `OR_IGNORE_FANOUT_ABOVE=N` — the flat
fanout checker (`set_max_fanout` + `report_check_types -max_fanout
-violators`) names the broadcast nets, their leaf drivers are
`set_disable_timing`'d, and the result is labelled a study
(`STA_IGNORED_FANOUT …`). It is what let the chain show through; it is not a
sign-off number.

## A100 — Module-level mapped board; find-first and popcount walks (exact)

`build-platform/scripts/openroad-module-board.tcl` turns the streamed run's
per-module netlists into a **module board**: one `sta` process per module
(461 in parallel, ~40 s), the module linked as its own top with children as
black boxes, inputs ideal, leaf drivers of nets with more than 64 loads
disabled (`OR_IGNORE_FANOUT_ABOVE`), and the worst register-to-register path
reported in ns with its cell count. Inputs ideal at a module boundary means
the whole-core report's broadcast artifacts (A97) do not reach these rows;
the cell count is the depth metric that survives any fanout model. Nangate45
typ, 0.25 ns clock, before A98/A99 → after:

| module | before (ns / cells) | after (ns / cells) | note |
|---|---:|---:|---|
| g6lc_rename | 26.2 / 255 | 23.2 / 257 → **4.4 / 52** (run C) | `pick_free` scan ×2 ports → lowest-set-bit (A100) |
| g6lc_rob | 15.4 / 211 | **2.6 / 35** | A99 free walk → hit vectors + find-first |
| scoreboard | 10.9 / 125 | **5.2 / 54** | A98 cancel walk → window; next: the 54-cell commit-select cone |
| g6lc_iq | 5.1 / 57 | 6.2 / 47 (run C, plain-script fallback) | slot-allocation scan → lowest-set-bit (A100); cells 57 → 47 |
| store_buffer | 5.1 / 50 | 5.4 / 49 (run C) | the insertion count was not its worst path; the dense rewrite's dynamic indexes are |
| frontend | 4.1 / 43 | 4.1 / 43 | next: the `speculative_d` cone (20 structural in the emitted tree) |
| instr_realign | 2.8 / 23 | 2.8 / 23 | the `cur` walk is a small-support cone synthesis flattens; 23 cells |

Run C = the streamed mapping of the A98–A100 tree (`…-streamed-20261016c`);
its whole-core fanout-insensitive `wns` is −45.0 ns (870 broadcast drivers
disabled), the same order as run B: with rename's chain gone the remaining
−45 ns is the composition of several modules' 40–55-cell cones across
hierarchy, not one walk. The module board is the ranking to work from.

Whole-core fanout-insensitive `wns` moved −79.7 → **−44.1 ns** with A98/A99
alone (the remaining broadcast-free chain is rename's).

Three more walks rewritten exactly (A100), all `fixtures/auto_correct/
find_first_equiv.sv` shapes proved by exhaustive SAT at 16 and 32 bits:

- `g6lc_rename` `pick_free`/`pick_ffree`: `for i: if (fr[i] && pick == 0)
  pick = i` → `lowest = fr & (~fr + 1)` (one incrementer) and an OR-encode
  of the one-hot. The scan was 72 deep per port, twice in series.
- `g6lc_iq` slot allocation: the same `free[e] && !alloc[p]` scan per port →
  lowest-set-bit isolate, `alloc = |lowest`, `free &= ~lowest`.
- `store_buffer` insertion index: `if (older) ins = ins + 1` over
  `DEPTH_SPEC` → `$countones(older_vec)`; `g6lc_iq` live count likewise
  `$countones` over the valid vector instead of a running sum.

Model note: yosys turns an *unconditional* `acc = acc + x` chain into a
`$macc` compressor tree, so only conditional/compare-gated arithmetic walks
are serial; delay-v35 bills both as serial because the lowerer does not yet
record the `if` a node sits under (todo). The RTL forms above make the
distinction moot where it mattered. Whole core elaborates (slang) with all
A98–A100 edits; functional validation deferred per campaign policy — the
proofs cover the rewritten functions, not their callers' invariants.

## A101 — From hand rewrites to a pass: `LoopRewrite` (delay-v36)

### Why the walks were Pareto-dominated (area *and* depth)

A98–A100 were written by hand; the question was whether what made them
win generalises. It does, and the reason is structural, not lucky:

- A serial walk unrolls into **N copies of its body**. The body of a
  pointer walk is a decoder (`mem[cid]`, `mask[cid] = 1`) plus an increment
  and a compare; the body of a find-first scan is a compare on the carried
  value and a gate; the body of a running count is an incrementer. All N
  copies are *live hardware* — synthesis cannot share them because each
  depends on the previous — so area is N × body and depth is N × body.
- The parallel form computes **one** verdict per element (a compare, an
  AND, a bit of a one-hot) and combines them with a tree (OR-reduce,
  popcount, lowest-set-bit isolate = one incrementer). Area is N × verdict
  + tree, depth is verdict + log₂N. Verdict < body always (the body
  *contains* the verdict), so both axes improve at once — there is no
  area/delay trade to make.

Measured on the fixture `fixtures/auto_correct/loop_walks.sv` (all four
shapes in one module), Nangate45 typ, delay-oriented ABC, inputs ideal:

| | gold (walks) | emitted by the pass | ratio |
|---|---:|---:|---:|
| worst path | **14.52 ns**, 142 cells | **0.91 ns**, 18 cells | 16× |
| area | 7129 µm² | 723 µm² | 9.9× |

and on the production modules (module board, A100): rob 211 → 35 cells,
scoreboard 125 → 54 cells after the hand versions of the same forms.

### The pass

`sv-timing-core::loop_walk` detects three shapes on the loop's own source
text (`GenerateLoop::text`/`pre_text`, captured at lowering; the lowerer
does not represent `if` guards or `break`, and these are idioms with a
regular surface), each with an exactness condition and a replacement:

| shape | before | after | exact when |
|---|---|---|---|
| **FindFirst** | `for i: if (v[i] && pick == '0) pick = X'(i)`; or `if (v[i] && !found) begin found = 1; [pick = X'(i);] end` | `low = v & (~v + 1)` (bits below `lo` masked), `pick \|= X'(i)` for the one-hot, `found = \|low`, all under the original guard | `lo ≥ 1` for the `== 0` form (bit 0 would re-arm the scan); `v` at least N bits |
| **CondCount** | `for i: if (COND) cnt = cnt + 1` | `vec[i] = COND; cnt = cnt + W'($countones(vec))` | `cnt` declared ≥ log₂(N+1) bits; COND reads `i`, not `cnt` |
| **RingWalk** | `cid = a; for k < N: if (cid == b) break; BODY; cid = cid + 1` | `win[j] = (a != b) && (b > a ? j ∈ [a,b) : j ∉ [b,a))`; `if (win[j]) BODY[cid := W'(j)]`; `cid = b` | `N == 2**width(cid)`; BODY assigns neither `cid` nor anything `b` reads; no `break` in BODY |

Each replacement is one statement fitted to the loop's line span (other
edits in the file keep their line numbers) and declares its vector at
module scope through the existing snippet path, injected before the
enclosing process. Loops inside functions/tasks and inside generate blocks
are left alone (a module-scope vector cannot serve them). The transform
(`loop_rewrite_on_node`) credits the IR by locking the loop's nodes at the
parallel cost; the planner ranks `LoopRewrite` with `SelectIncrement`
(first, latency-neutral, allowed under `RefuseRegister`); emission is
`rewrite_loop_spans` before the origin RHS rewrites.

**Measurement (delay-v36).** A find-first's chain lives in its guard, which
the IR does not bill (the picked constant costs 0) — the two scans in the
fixture were under budget and invisible to the planner. The carried nodes of
a detected FindFirst now carry a per-iteration floor of a compare and a gate,
and a variable read only in a loop's `if` guard counts as loop-carried.

**Low FO4 is not lost.** `loop_walks_parallel` (already in the parallel
forms) is emitted byte-identical and re-analyses to the same cost; the
emitted fixture offers no `LoopRewrite` opportunity (idempotent); the
whole-core emitted board moved 394 → 393 failing with the worst unchanged
(the production walks were already A98–A100; the pass found the one left,
`gen_commit_count`). Whole-fixture sequential miter (gold vs emitted, 4
steps from reset) runs on the builder with a 30-minute budget — the ring
body's dynamic index makes it 1.5 M variables; the find-first/popcount
forms are proved exhaustively at 32 bits (A100) and the window at 4/8/16
(A98).

### What it does not cover yet (next shapes, in order of evidence)

1. **Composed walks** — the ROB free-by-tid (`for r: for i: if (match)
   {valid[i] = 0; cnt--}`): hit vector per port + `$countones`, i.e.
   CondCount with a body. Detect: inner loop assigns under a condition and
   decrements the carried count.
2. **Walk-until-valid with a dynamic index** (`while head != tail && !valid
   [head]: head++`): a FindFirst over the rotated vector stopped at a
   distance; the A99 re-anchor form.
3. **One-hot `if` chains used as muxes** (`for e: if (grant[e]) out =
   q[e]`): exact only under the one-hot invariant the design asserts; an
   AND-OR mux with an assertion-tagged rationale.
4. **Loops inside functions** (`pick_free`): a module-scope vector cannot
   serve a function; the rewrite must stay inside the function body
   (block-local vector — needs the slang scoping check the builder's slang
   rejected for `rob_reanchor`).
5. **Conditions as nodes** (the todo of A100): billing `if` guards generally
   would make every scan visible without the shape-specific floor.

## A102 — Performance/area of the emitted tree, measured; what the area delta exposed

The question: where does the sv-timing emit *pay* area for depth, and is it
worth it. The answer needed the whole emitted tree mapped the same way as
the live one (`timings sta-rtl --fo4 10 --allow-over-budget --remote
--map-recipe streamed`: pre-pass → sync → streamed yosys map → module board)
and a per-module join of area (yosys `stat -liberty`) with depth (module
board): `build-platform/scripts/sta_module_delta.py <live run> <emitted
run>`, largest area increase first.

### Noise floor first

Two mappings of **logically identical** RTLIL differ. `wt_dcache_wbuffer`
is byte-identical (comments aside) between the live and the emitted tree,
yet mapped 61140 vs 61594 µm² (+0.7 %) and 21 vs 27 cells / 2.04 vs 3.19 ns
on its worst register-to-register path. The two RTLIL files differ only in
`autoidx` — the numbers in `$auto$…$N` names — and ABC's result follows
yosys's name-dependent ordering. `rename -enumerate` does not converge them
(62724 vs 62246). So at module level: **area ±1 %, worst path ±6 cells /
±1 ns are noise**; whole-tree totals average it out; cell counts beat ns.
Between two live trees (run B → run C) only the three edited modules moved
— the noise appears when a tree's *other* files change the global numbering.

### What the first delta exposed (and fixed): three ways the emit dropped logic

The first emitted-tree delta showed `pmp_entry` −26 %, `alu` −35/−44 %,
`multiplier` −12.5 %. None was optimization:

1. **Zero-fed stage with a rewritten origin.** The dense block judged a cut's
   feed on its own (peer cut LHS, automatic, free loop index, generate-local
   param) and emitted `svt_zero` or the previous stage ("lean chain") while
   the origin was rewritten to sample the stage — `base = pipe` with the pipe
   fed zero. RTLIL miter gold vs gate on `pmp_entry`: **FAIL**. Ten modules
   carried the pattern. Now one decision in `cut_assigns_from_source`: a cut
   whose feed cannot be real keeps its origin; and a feed that reads a peer
   cut's LHS *is* real — that LHS samples its own stage, which is what a
   multi-stage cut of one cone means (`t0 = reg(a+b); t1 = reg(t0+c)`).
2. **One-hot tree with more labels than arms.** `emit_onehot_or_tree` kept
   the 16 deepest safe arms; `onehot_lhs_rewrites` put `_top` on every safe
   label: alu `result_o` had 27 labels on a 13-arm tree, so `ADDW` read 0.
   One `onehot_usable_arms` set drives both; labels outside it keep their
   RHS. Dedupe per origin on top (19 trees for one `result_o` before).
3. **Stale elaborated widths.** The width map from an older tree made
   `shamt` 4 bits (it is `$clog2(NrFifo+1)` = 3) and SelectIncrement
   indexed `shamt[3]`. The map now records a sha256 of the portable flist's
   sources; the pre-pass passes `--width-map` only while they hash the same.

Plus two that only failed elaboration (block-local names in hoisted feeds;
enum LHS sampling a `logic` pipe without a cast) and a resume cache that
served another tree's netlists (`-s "$out"` → keyed on the RTLIL's sha).
Every one of these is pinned by a unit test; the emitted tree now
elaborates in slang and maps end to end.

### The measured delta (live A100 tree → emitted −O3 allow-latency tree, Nangate45 typ)

Per module, yosys `stat -liberty` area and the module board's worst
register-to-register path (cells / ns; children black-boxed, inputs ideal,
broadcast drivers disabled). Edits per module from the pre-pass's
`correct.json` (73 InsertReg, 77 BalanceMux, 10 SplitAssign, 9
RebalanceAssoc, 1 LoopRewrite over 264 files).

| module | area live → emitted | Δ | path live → emitted | edits |
|---|---:|---:|---|---|
| branch_unit | 1178 → 1522 µm² | **+29.2 %** | — (no reg→reg) | 3 InsertReg (64-bit target add) |
| exp_backoff | 414 → 500 | +20.8 % | 6 → 6 cells, 0.46 → 0.46 ns | 1 InsertReg |
| alu (×2) | 9213 → 10610, 9462 → 10620 | +15.2 / +12.2 % | — → 13 cells, 0.70 ns | one-hot tree (13 arms) + cuts |
| wt_dcache_missunit | 5951 → 6665 | +12.0 % | 12 → 13 cells, 0.74 → 1.64 ns | 7 InsertReg, one origin |
| aes | 7536 → 8215 | +9.0 % | — | 13 InsertReg |
| g6lc_loop_buffer | 7329 → 7760 | +5.9 % | 15 → 11 cells, 2.46 → 1.63 ns | 4 InsertReg |
| cva6_shared_tlb | 1346 → 1420 | +5.5 % | 5 → 5, 0.32 → 0.28 ns | cuts |
| wt_dcache_mem | 15257 → 15992 | +4.8 % | — | 3 InsertReg |
| pmp_entry (×24) | 594 → 618 | +4.1 % | — | 4 InsertReg (was −26 % with the defect) |
| csr_regfile | 23091 → 23439 | +1.5 % | 11 → 14 cells, 2.02 → 1.36 ns | 2 InsertReg (timer compare) |
| scoreboard | 244120 → 244731 | +0.3 % | 54 → 53 cells, 5.16 → 3.98 ns | 1 LoopRewrite |
| g6lc_bp_ckpt | 28151 → 28164 | +0.0 % | 12 → 11, 1.23 → 0.97 ns | 7 InsertReg, one origin |
| frontend | 15928 → 15879 | −0.3 % | 43 → 37 cells, 4.09 → 3.45 ns | 8 BalanceMux, 3 Rebalance, 1 InsertReg |
| g6lc_rob | 101316 → 101433 | +0.1 % | 35 → 35, 2.63 → 2.46 ns | BalanceMux |
| instr_queue | 5111 → 5005 | −2.1 % | 16 → 12 cells, 1.14 → 1.60 ns | SelectIncrement (A91) — fewer cells, slower mux |
| multiplier | 37461 → 37694 | +0.6 % | — → **110 cells, 6.84 ns** | InsertReg inside the multiply: the cut is not where the mapped depth splits |
| **total (130 modules ≥ 300 µm²)** | **1 960 449 → 1 967 340** | **+0.35 %** | 43 up / 3 down | |

Whole-core unbuffered STA of the emitted tree: `wns_max` −1154 ns vs −1446 ns
live (broadcast fanout, not logic depth — A97). The first, defective emit
had read −0.73 % total with `pmp_entry` −26 %, `alu` −35/−44 %,
`multiplier` −12.5 %: the area that "went away" was dropped logic.

### Reading it as policy

- **Area goes up only where registers go in.** Every module with +5 % or
  more carries InsertReg cuts; the flops of a 64-bit cut on a small module
  are 10–30 % of it (`branch_unit`, `exp_backoff`). This is the price of
  latency, and it is the one transform that changes latency; it stays last
  in the planner (S4) and off for latency-neutral runs.
- **BalanceMux one-hot trees are area-neutral or negative** once exact
  (AND-OR replaces a chain of 64-bit MUX2 arms); **LoopRewrite is strongly
  negative** (A101); **RebalanceAssoc/SplitAssign neutral**;
  **SelectIncrement positive and bounded** (`2^k` candidate incrementers,
  `MAX_STEP_BITS` 4, `MAX_CANDIDATE_BITS` 512) — on `instr_queue` ≈ +3 %
  of a 5 kµm² module. The planner's latency-neutral-first order is also the
  area order, so no new dial is needed; what was needed was exactness.
- **Whole-tree area is flat within noise** for the −O3 study tree; the
  depth it buys is on the module board (scoreboard 54 → 53 cells / 5.2 →
  4.0 ns, frontend 43 → 37 / 4.1 → 3.4, csr_regfile 2.0 → 1.4 ns, rob 2.6 →
  2.5), the rest is the 64-bit arithmetic and the broadcast nets the
  structural board already named.

Open: the whole-fixture sequential miter for A101 and the 32-entry
scoreboard window both exceeded their budgets (1.5 M variables; OOM at 32
entries) — recorded as inconclusive; the shapes are proved at 16/32 bits
and 4/8/16 entries respectively. Module-level exactness of the allow-
latency tree cannot be stated as a cycle-exact miter (latency moved);
its evidence is the fixture proofs, the single-decision emit rules, and
the area no longer dropping where logic was lost.

## A103 — Guards (delay-v37): the structural board learns to see the OoO cones; StreamCompact

### The blind spot the module board exposed

With netlist cells per module in hand (A100/A102), the structural board could
be calibrated module by module. It was not merely imprecise in the OoO
modules — it was blind: `g6lc_iq` and `g6lc_lsq` had **no register-to-
register path at all** (0.0 FO4) against 47 and 13 mapped cells;
`scoreboard`, `g6lc_rename`, `store_buffer` read 3–5× fewer FO4 than cells.
The lowerer never represented two things every OoO structure is made of:

1. the **`if` an assignment sits under** — `if (issue_valid_o[g] && ack)
   q_after[slot_entry[g]].valid = 0` reads the whole select cone (`grant`,
   `slot_entry`) and the node had no fan-in from it;
2. the **index of a dynamically indexed LHS** — `q[slot].f = …` decodes
   `slot`.

delay-v37 records both as the node's *guards* (`TimingModule.guards`,
collected from the CST's `ConditionalStatement` body spans and the LHS
bracket expressions). They are reads for the dataflow link and cost
`max(rhs, guard) + mux` (one select level, `log2` per extra guard). A guard
whose identifiers are all elaboration-time (a genvar index `row[k]`, a
parameter `if (CVA6Cfg.RVA)`) costs nothing; a guard decided *above* the
node's loop (`^`) is one select for all unrolled copies and is added after
the trip multiplier.

The first run then over-read by as much as it had under-read (iq 422,
scoreboard 274), which named two more truths about unrolled loops:

- **Field granularity.** `q_wake[e].rs1_rdy = 1` under `if (q_wake[e].rs1
  == wb)` writes one member and reads another of the same struct array:
  no dependence between iterations (yosys sees per-bit nets). Carry keys
  are root + member chain with indices stripped.
- **Index awareness.** `x[i].f` written and `x[i].g` read in one iteration
  with the loop variable in both indices is one element: no carry.
- **Carry through the guard alone** (`if (!placed && !v[i]) placed = 1`)
  is one gate per copy (the `!placed` AND chain) with the body paid once;
  through the RHS (`cid = cid + 1`) it repeats the body (A98).
- A **function name is not a net**: `is_amo = … && ariane_pkg::is_amo(op)`
  had read itself and become a 16-copy chain.

### Calibration (live A100 tree, delay-v37 structural reg→reg worst vs run-C mapped cells)

| module | structural FO4 | mapped cells | cells/FO4 |
|---|---:|---:|---:|
| g6lc_iq | 16.5 (select cone; 48.0 before the function-name fix) | 47 | 2.8 |
| store_buffer | 38.5 (cancel squash compaction) | 49 | 1.3 |
| instr_realign | 26.0 | 23 | 0.9 |
| frontend | 23.0 | 43 | 1.9 |
| wt_dcache_wbuffer | 18.6 | 21 | 1.1 |
| instr_queue | 17.0 | 16 | 0.9 |
| g6lc_rename | 19.0 | 52 | 2.7 |
| scoreboard | 15.6 | 54 | 3.5 |
| perf_counters | 34.7 | 13 | 0.4 |

Where the board was blind it now reads within ±30 % (iq before the
function fix, store_buffer, wbuffer, instr_queue, realign). rename and
scoreboard still under-read (dynamic struct-array reads behind
`commit_sel_slot`/`head_slot` rotations); perf_counters and the TLBs
over-read (dense control cones the class model deflates in the netlist but
not here). The live board under delay-v37: **worst 38.5 FO4
(`store_buffer`), 1204 failing primary paths, 673 of 1628 reg→reg** —
against 23.0 / 435 / 160 under delay-v36. The earlier number was the
model's blindness, not the design's depth.

### StreamCompact (fourth LoopRewrite shape)

The store buffer's cancel squash — `for k: if (k < cnt) begin src = ptr + k;
if (keep(src)) begin a[dst] = q[src]; …; dst++; live++; end end` — is a
stream compaction: a conditional running count and a write at a running
index, N incrementers and N demuxes in series. The exact parallel form:
`keep[k]` (outer guard ∧ condition, with the per-iteration temps
recomputed), `pos[k] = $countones(keep[k-1:0])` (independent popcounts, not
a running sum), a one-hot gather `a[j] = q(k)` for the `k` with `keep[k] &&
pos[k] == j`, and every count advanced by `$countones(keep)`. Exact when
`dst` enters at zero (the statement before the loop), the counts and outputs
are not read in the loop. Fixture `fixtures/auto_correct/stream_compact.sv`
(N = 8): **SAT-proved** gold ≡ emitted (sequential miter, 2 steps, defined
inputs); mapped Nangate45 1.91 → 1.84 ns, 15 → 15 cells, area 3456 → 3300
µm² (−4.5 %). At N = 8 ABC already keeps the serial form at 15 cells — the
structural 68.6 for it was an over-read (`dst + 1` billed as a full
incrementer per copy); the shape pays off with N, and is Pareto at 8.

What the honest board says about 10 FO4 now: the OoO cones (select,
squash, rename allocation, scoreboard commit select) are 15–40 FO4 of
*control* — guards and dynamic indexing — not arithmetic. They are not
closable by the latency-neutral toolbox at 20 ps; they are microarchitecture
(stationary queues, precomputed selects, one-cycle-later counts), and the
board can now rank them truthfully.

## A104 — Large passes on the truthful board: OneHotSelect, StreamCompact in production, function bodies (delay-v38)

### What the board asked for

With delay-v37 the ranked residual was the OoO control cones. Three moves,
each a pass or a model truth rather than a hand edit, and one production
edit that mirrors a pass:

1. **OneHotSelect** (fifth `LoopRewrite` shape, invariant-tagged). `for e:
   if (G[e]) begin x = y(e); … end` is a DEPTH-deep priority chain to
   synthesis. When the module **asserts** `$onehot0(G)` (`TimingModule.
   onehot_facts`, scanned from the source) and every output is zero before
   the loop, the chain is the AND-OR accumulate `x = x | (G[e] ? y(e) :
   '0)` — log₂N deep, exact whenever the assertion holds; the rationale
   names the assertion, so the proof obligation is the design's own.
   Fixture: the asserted grant select fires, the unasserted priority select
   does not (`fixtures/auto_correct/onehot_select.sv`).
2. **StreamCompact reaches the production store buffer.** Two defects stood
   in the way: the count's resolved width (a block-local `automatic`) was
   narrower than the popcount — the cast is now at least the bits of
   `0..=n` and truncates on assignment exactly as the repeated `+ 1'b1`
   did; and the emitter's span replacement stopped short of the loop's
   `end` when the body crosses an `` `ifdef `` (the preprocessor's origin
   map for the tail is off by the dropped branch — the tail was left
   behind, a parse error). The span now ends at the balanced `begin`/`end`
   scanned from the `for` line. `store_buffer` structural 38.5 → 23.3 in
   the emitted module; reparse and joint integrity pass.
3. **Function bodies cost at the call site** (delay-v38). A user function
   was one gate: `pick_free(free_d)` — an incrementer over 64 entries and a
   one-hot encode — cost 1 FO4, and `g6lc_rename` read 19 against 52 mapped
   cells. `FunctionBody.body_text` is kept; the call pays an ASAP schedule
   of the body's statements (independent statements overlap — the 64
   `out[Perm[k]] = in[k]` of the LFSR permutation are wiring, which the
   first serial-sum version billed at 41), loops by trip count: × 1 when
   every write is indexed by the loop variable, × log₂ for a linear update
   (`x = x | …`, `x = x ^ …`, a flag set under a guard, a shift-xor), ×
   trips for an arithmetic carry; `case` bodies cost nothing. Also: a
   runtime index selects among 2^k entries (⌈k/2⌉ 4:1 levels, not one), a
   zero-trip loop is dead, a guard on a bitwise self-accumulate is one
   gate.
4. **`core/ooo/g6lc_iq.sv`** mirrors OneHotSelect on the issue select
   (`ooo_iq_rank_unique` asserts the grant one-hot), clears the acked
   entry straight from the grant (no `slot_entry` encode → decode), and
   allocates port 1 at the **highest** free slot from the same `free`
   vector as port 0's lowest — the second pick no longer waits for the
   first (one incrementer off the chain; which free slot a newcomer lands
   in is not architecturally visible: the queue is stationary and age is
   the explicit matrix; ports beyond two stay serial). The whole core
   elaborates.

### What the netlist said (live remap, module board, Nangate45)

| module | before (run C) | after A104 | reading |
|---|---|---|---|
| g6lc_iq | 6.21 ns / 47 cells | **4.40 ns / 46 cells** | the select cone was not the deepest: the worst path is now the wake → `q_d` → count cone at the same cell depth; the ns gain is largely fanout |
| store_buffer, scoreboard, rename, frontend | 49 / 54 / 52 / 43 cells | unchanged (live tree) | the compaction is in the emitted tree only (in flight) |

Calibration after delay-v38 (structural / cells): rename 34 / 52 (1.5),
iq 54.9 / 46 (the dense-cone class sums a 63-node block; 0.9), frontend
70.5 / 43 (the `accepted_target` compare loop still ~2× over), store_buffer
38.5 / 49, scoreboard 15.6 / 54 (still under-read: the commit select).
Live board: **worst 70.5 (`frontend`, a function-cost over-read), 1244
failing primary, 692 of 1628 reg→reg.** The under-read list shrank to the
scoreboard; the over-reads are now the model's, not the design's.

### Reading it

- A pass that is exact only under an invariant must carry the invariant's
  proof obligation visibly: `onehot_facts` makes the design's assertion the
  gate, and the rationale repeats it. Without the assertion the chain stays.
- "Which cone is deepest" is the netlist's verdict, not the model's: the iq
  select cone measured first on the structural board, and the netlist's
  worst was the wake/count cone one cell shorter. The honest move after a
  rewrite is the module board, every time.
- Function-call costing was the last large blind spot of the OoO modules;
  what remains is class deflation (dense cones summing whole blocks) and
  the scoreboard's commit select.

Open: emitted-tree remap with StreamCompact in the store buffer (in flight);
the iq count cone (`count_d = $countones(q_d.valid)` depends on the full
next state — `count_q + alloc − issued − cancelled` would not); the
scoreboard commit select; `frontend` `accepted_target` (eight 64-bit
compares under a window guard — a 6-bit tag compare would do).

## A105 — Aggressive and exact: re-association across module boundaries, counts as deltas

Two production restructures aimed at the netlist's own worst paths rather
than the structural board's, each exact by arithmetic or by a stated
invariant, each latency-neutral:

1. **Frontend target add as one three-operand sum.** The module board's
   worst `frontend` path (43 cells) ends at `bp_tgt_q` through
   `predict_address = addr[i] + imm`, and `addr[i]` is itself the
   realigner's `address_i + {cur, 1'b0}` — two 64-bit adders in series
   across a module boundary. `instr_realign` now also exposes each slot's
   address as `{base, byte offset}` (`addr_o == base_o + off_o` by
   construction; the carried slot has `base = carry_addr_q, off = 0`), and
   the frontend forms `base + off + imm` (and the RAS link `base + off +
   2|4`) as one sum: yosys's `alumacc` builds a carry-save layer and one
   adder — ~1.5 FO4 per extra operand (delay-v31) instead of a second
   12 FO4 adder. Equal modulo 2^VLEN.
2. **Issue-queue live count as a delta.** `count_d = $countones(q_d.valid)`
   sat behind the whole wake → select → dispatch cone (the module's deepest
   path after A104: `count_d → q_d → q_after_issue`). The next valid set is
   `(valid & ~cancelled) − acked grants + allocations`, three sets disjoint
   by construction (a grant needs a valid uncancelled entry; an allocation
   needs a slot free after issue), so `count_d = count_q − popcount(cancel)
   − popcount(acked) + popcount(alloc)`, every operand early; the
   invariant `count_q == $countones(valid)` holds from reset and is
   asserted in simulation (`ooo_iq_count_is_popcount`).

3. **CSR guest time registered before the VS timer compare.**
   `vstimecmp_hit_d = (rtc_time_i + htimedelta_q) >= vstimecmp_q` was a
   64-bit add and a 64-bit compare in one cycle (16.8, the csr board
   worst). The guest time is registered and compared a cycle later; the
   hit was already registered and the RTC ticks far below the core clock,
   so the extra core cycle is invisible to the timer contract. (The
   algebraic alternative `rtc >= vstimecmp − htimedelta` is **not** exact:
   the architectural sum wraps modulo 2^64 — `a = 0, d = 2, c = 1`
   separates them.)
4. **Scoreboard commit pointer as a selected increment bank** (A88 in
   production): `cp + num_commit + k` (popcount → adder → flush mux) is a
   bank of `cp + c` incrementers, c = k..k+NrCommitPorts, selected by the
   ack count — SAT-exact, mapped 0.247 → 0.169 ns at 5 bits.

All four elaborate in the whole core (slang, remote). Their netlist
evidence is the next live remap; the structural board can show only the
csr one (16.8 → 14.5, the next csr cone) — at this depth the board ranks
and the netlist decides.

Model: a function loop that is a linear update (a flag set under a guard,
an OR/XOR accumulate) costs its body once plus a gate per tree level — the
eight 64-bit compares of a window hit test run side by side; `frontend`
70.5 → 47.0 against 43 cells. Live board under delay-v38 with A105:
**worst 55.0 (`g6lc_iq`, the dense-cone class of the dispatch block; 47
cells), 1247 failing primary, 689 of 1625 reg→reg**; calibration ratios
of the real cones 0.9–1.7 cells/FO4 (iq 0.9, frontend 0.9, store_buffer
1.3, rename 1.7, realign 0.9, wbuffer 1.1).

### What the netlist said (emitted −O3 tree with A104/A105 iq + frontend, module board, Nangate45)

| module | live run C | emitted A105 | reading |
|---|---|---|---|
| store_buffer | 5.38 ns / 49 cells | **3.81 ns / 42 cells** | StreamCompact in the squash: −7 cells, −29 % |
| frontend | 4.09 / 43 | **3.15 / 38** | the three-operand target sum: −5 cells |
| scoreboard | 5.16 / 54 | 3.86 / 51 | emitted BalanceMux/LoopRewrite; the commit bank is not in this tree yet |
| g6lc_iq | 6.21 / 47 | 3.83 / 49 | mapped by the plain ABC fallback (the delay script timed out on the emitted iq) — cells not comparable |
| rename | 4.41 / 52 | 4.41 / 52 | untouched |
| rob | 2.63 / 35 | 2.46 / 35 | |

The emitted tree elaborates and maps end to end again after the emit
fixes below (its earlier run failed on `svt_bm_top_…` and `p`).

**Live remap with A104/A105 in production (module board):** `g6lc_iq`
6.21 ns / 47 cells → **4.60 / 37** (the count delta took the popcount off
the dispatch cone), `frontend` 4.09 / 43 → **4.35 / 34** (the three-operand
sum; the ns is fanout noise), `scoreboard` 5.16 / 54 → 3.98 / 51 (the
commit bank is small; the `sb_full_o` chain remains — A106), `csr_regfile`
2.02 / 11 → 1.49 / 14 (the timer chain is gone from the top; the worst is
now `instret`), rename and store_buffer unchanged (A106).

Emit (same round): origin RHS rewrites are all-or-nothing per record (a
first rewrite that cannot land — an `if (c) x = y;` one-liner, a generate
line — while an extra does left the extra reading an undeclared `_top`,
and the emitted tree failed elaboration), and `for (int p …)` header
variables are block-local, so a hoisted cut feed never reads them.

## A106 — Decoupling: snapshots, registered counts, a parallel squash

The module board after A105 named the next three cones by their cells:
rename 52, scoreboard 51, store_buffer 49, and iq's remaining 37. Each
is a serial dependence that the microarchitecture does not need, removed
exactly or by a stated, architecturally invisible policy:

1. **Rename picks both ports from one free-list snapshot.** The two-port
   allocation was `pick_free(free_d) → clear → pick_free(free_d) → clear`.
   Port 0 now takes the lowest free entry and port 1 the highest (the same
   lowest-set-bit isolate on the bit-reversed vector), both from one
   snapshot; the single-free case, where both picks name one entry, is
   caught by the `free_d[picked]` gate at port 1. The capacity block
   counts instead of picking: at least one free is `|cand`, at least two
   is `|(cand & (cand − 1))` — one subtractor beside the pick, not after
   it. Ports beyond two keep the serial pick. Same for the FP pool. Which
   physical register a destination gets is not architecturally visible.
2. **Scoreboard issued count as a register.** With RTL names kept in a
   diagnostic map, the worst scoreboard path reads `mem_q → mem_n →
   sb_full_o → mem_q`: the popcount over the 32 `issued` flags fed the free
   count, the full flags and the issue enable. `issued` is set only by an
   issue and cleared only by a commit ack or a flush, so the count is a
   register advanced by `num_issue − num_commit`, cleared on flush;
   `sb_issued_cnt_is_popcount` asserts the equality in simulation.
3. **Issue-queue dispatch allocates among the slots free at the start of
   the cycle.** `free = ~valid_after` put the wake → select → ack cone in
   front of the allocation. `free = ~valid_q`: a slot an issue frees this
   cycle becomes allocatable next cycle. `full_o` already counts from the
   registered state (`count_q == popcount(valid_q)`), so a non-full queue
   always has the slots the ports need, and the age matrix still ranks the
   newcomer against `valid_after`.
4. **Store-buffer cancel squash in its parallel form, in production.** The
   StreamCompact shape (A103/A104), written parameterized: `keep[k]` per
   slot, `pos[k] = popcount(keep[k−1:0])`, a one-hot gather, counts
   advanced by the popcount; `dst`'s cast wraps modulo its width exactly
   as the walk did. SAT-proved on the fixture, 49 → 42 cells in the
   emitted tree.

### What the netlist said (live remap with A104–A106, module board, Nangate45, every module under the delay-oriented script)

| module | run C (A100) | A105 | **A106** |
|---|---|---|---|
| g6lc_rename | 4.41 ns / 52 cells | 4.41 / 52 | **3.77 / 25** |
| scoreboard | 5.16 / 54 | 3.98 / 51 | **2.76 / 22** |
| store_buffer | 5.38 / 49 | 5.38 / 49 | **4.85 / 44** |
| g6lc_iq | 6.21 / 47 | 4.60 / 37 | 3.51 / 38 |
| frontend | 4.09 / 43 | 4.35 / 34 | 4.35 / 34 |
| g6lc_rob | 2.63 / 35 | 2.63 / 35 | 2.50 / 35 |
| wt_dcache_wbuffer | 2.04 / 21 | 2.26 / 20 | 3.12 / 27 (noise band) |

The worst module on the board went from 54 cells (scoreboard) to 44
(store_buffer: the compaction's result into the status count), with the
OoO control cones at 22–38. The next ranked: store_buffer 44, iq 38, rob
35 (`count_d → count_q`, the free-by-tid popcount and add), frontend 34
(the 64-bit target sum — the wall), wbuffer 27, rename 25, scoreboard 22,
realign 22.

All four elaborate in the whole core (slang, remote). The structural board sees only the squash
(store_buffer 38.5 → 23.3); the rest are dependence removals the
node-latency model does not express — the netlist decides. Live
structural board: worst 55.1 (`g6lc_iq`, the dense-cone class), 693 of
1626 reg→reg over 10 FO4.

How to read the diagnostic map: `setattr -set keep 1 w:mem_n w:mem_q …`
before `abc` keeps those wires' RTL names through mapping, so the board's
`trace` column names the cone (`sb_full_o` on the way to `mem_q`) — a
legibility run, not a measurement run (the kept nets fence ABC's
restructuring).

## A107 — The ROB count, and what the board says 10 FO4 needs

### ROB retire hits from the registered state

The module board's rob worst (35 cells, `count_d → count_q`) was the
count chain: alloc `+1`, `+1` → port 0 hits on `rob_d` → popcount →
subtract → port 1 hits "on the state port 0 left" → popcount → subtract.
Two facts make it parallel and exact: an entry allocated this cycle
cannot retire this cycle (the scoreboard frees a tid at commit and
re-issues it later), so `rob_q` and the pre-free `rob_d` agree on what a
retire tid can hit; and "the state port r−1 left" is the mask by the
earlier ports' hits. Every port's hits come from `rob_q` at once, masked
by the union of the earlier ports' hits; the vectors are then disjoint, so
one popcount of their union is the decrement; tail and count advance by
the popcount of the allocations. Two ports naming one tid still free one
slot and count one. The head re-anchor (A99) is unchanged and keeps its
own cone. **Netlist (live remap, module board): rob 2.50 ns / 35 cells →
2.11 / 26.**

### Where the campaign stands against 10 FO4

Module board (cells, Nangate45, delay-oriented ABC) from run C to A107:
scoreboard 54 → 22, rename 52 → 25, store_buffer 49 → 44, iq 47 → 38,
frontend 43 → 34, rob 35 → 26, realign 23 → 22, wbuffer 21 → 27 (noise
band). Board worst 54 → 44. At ≈ 1.3 cells/FO4 the budget is ≈ 13 cells. What is
left, cone by cone, and why it is no longer a transform:

| cone | cells | what it is | what 10 FO4 would take |
|---|---:|---|---|
| store_buffer squash → status count | 44 | the cancel squash runs on the **next-state** queue (this cycle's push and pop applied), then its popcount is the next count: push demux → next-state read → `cancelled_mask[tid]` lookup → compare → popcount | run the squash on the registered queue with the push and pop folded in algebraically — an exactness proof over three same-cycle events, or a one-cycle-later squash (the cancelled stores are already masked at the forwarding path) |
| iq wake → select → ack clear | 38 | tag compares against the writeback ports, the age-matrix grant per port (port 1 after port 0's grant), the acked clear | a **wake/select pipeline split** (speculative wakeup, select one cycle later) — the standard high-frequency OoO structure; an IPC change, an owner decision |
| frontend target sum → `bp_tgt_q` | 34 | one 64-bit three-operand add behind the realigner's slot select and the predictor's `taken` decision | **the 64-bit wall**: 12 FO4 for the add alone at 20 ps; a pipelined target (predict one cycle later, redirect-on-taken) or a narrower target datapath |
| realign cursor walk | 22 | the `cur` recurrence over compressed flags (a two-state linear recurrence) and the slot compaction | parallel prefix over 2×2 boolean matrices + the StreamCompact gather — exact, worth one more pass; ≈ 2× |
| rename / scoreboard | 25 / 22 | the 64-entry isolate + encode (12 + 6) and the issue write demux | a registered free-list head (pick one cycle early, bypass on free) — exact by invariant, ≈ 2× |
| the 12.0–12.5 structural band (ex_stage, issue_read_operands, loop_buffer, tlb, ptw, lsq) | — | a single 64-bit add or compare plus one mux | the wall again |

The exact, latency-neutral toolbox — one-hot selects under the design's
assertions, counts as registered deltas, snapshots for multi-port picks,
three-operand sums, the LoopRewrite shapes — took the OoO control cones
from 3–4× the budget to ≈ 2×. The rest is the microarchitecture's
single-cycle contracts at XLEN = 64 and 20 ps: pipelining them is the
remaining lever, and it changes IPC, which is not a transform's decision.

## A108 — Verdicts travel with entries: the store-buffer squash, and the two cones that share the realigner

### The store-buffer squash's cancel lookup

A107 left store_buffer at 44 cells with "the squash runs on the next-state
queue". Reading the block in statement order shows what that is under
`OoOEn`: a push triggers a **program-order insertion** (snapshot the live
window, compare the arrival's tid against each entry — `older_vec` — count,
and rewrite the window dense with the arrival at its rank), and the cancel
squash then runs on that rewritten queue: `cancelled_mask_i[
speculative_queue_n[ks].trans_id]` — a 32-way lookup behind the insertion's
trans_id muxes behind the push write, then a compare, then the popcount
into the status count. Two dense rewrites in series.

The cancel verdict is a property of the **entry**, not of the slot. It is
looked up once per registered entry (`cancelled_mask_i[q_q[i].trans_id]`),
the arrival's verdict is known (`!cancelled_mask_i[trans_id_i]` is the push
guard), and the insertion permutes the verdict bit alongside the entry
(`cancel_hit_n[k] = a_cancel[dst]`). The squash's keep bits read that bit.
The data still flows through the insertion muxes into the gather; the keep
→ popcount → count path no longer waits for it. Exact: same function of
the same inputs, evaluated before the permutation instead of after it.

### What the frontend and the realigner share

The frontend's remaining 34 cells end at `bp_tgt_q` through the
three-operand target sum — whose `off[i]` operand is the realigner's
cursor `{cur_i, 1'b0}`, the 22-cell serial walk over the compressed flags.
The two cones share their first half. Two ways out, both evaluated and
not taken in this round:

- **The cursor as a parallel prefix.** `start[h]` ("an instruction starts
  at halfword h") is a two-term boolean recurrence `start[h] = start[h−1]
  ∧ c[h−1] ∨ start[h−2] ∧ ¬c[h−2]`; as 2×2 boolean matrices it is a
  log-depth prefix (3 levels of 2×2 products for 8 halfwords ≈ 7 gate
  levels against ≈ 12–16 serial), and the slot assignment is a
  StreamCompact gather over `start` with the slot cap `rank < IPF` and the
  carry as the last visited split RVI. Exact, ≈ 5–7 cells off both cones;
  intricate (carry, tail, the `k ≠ 0 ∨ ¬carry_ok` skip) for a second-tier
  gain — recorded, not written.
- **Pre-decode per halfword position.** Compute the target `address_i +
  2h + imm(hw[h], hw[h+1])` for every position h in parallel and let the
  slot's one-hot select the sum: the add no longer waits for the cursor
  at all. That is the conventional high-frequency fetch structure (scan
  and target per position, not per slot); it doubles the `instr_scan`
  instances and the target adders (≈ +6 % of the frontend's area) and
  reshapes the predictor indexing — an owner-level restructure, listed
  with the pipeline splits of A107.

Netlist: the verdict change alone took store_buffer 4.85 → 4.26 ns at
45 cells (the delay moved, the depth did not — the insertion's data
permutation still fed the squash's).

## A109 — One permutation for two rewrites (store_buffer 45 → 38 cells)

Under `OoOEn` a push runs the **program-order insertion** (snapshot the
window, rank the arrival by `ooo_older`, rewrite dense) and a cancel runs
the **squash** on that rewritten queue — two dense permutations in series.
Both map the window `[read_ptr_n, read_ptr_n + n)` onto `[0, live)`; the
composition is one permutation: each snapshot entry gets its position
after the insertion (`pos_ins`: the arrival at `ins`, younger entries
shifted, the identity when nothing arrives) and its keep verdict (`keep`:
all when nothing is cancelled, else the squash's rule on the registered
tid), its final slot is `popcount(keep[j] && pos_ins[j] < pos_ins[k])`,
and one gather writes the window; `live = popcount(keep)`. The LEGACY
`fwd_keep` marking moves before the rewrite (it marks entries; the
permutation carries the mark).

**Evidence.** The bounded yosys miter (both revisions elaborated under the
real `g6lc64_ooo` config, `miter -equiv`, `sat -seq 8 -set-assumes`) first
produced two counterexamples that were the *environment's*, not the
design's: a commit on an empty queue (the module's own assertion at
`store_buffer.sv:1023` forbids it; the count underflows and both revisions
read garbage differently) and the head address of an empty queue (stale
data of an invalid slot — the two revisions leave different stale data,
which nothing reads). With the environment assumed and the don't-care
masked, 8 steps at XLEN = 64 / PLEN = 56 (16 M variables) did not finish in
50 min, and 5- and 7-step runs timed out at 2 h each — recorded as
inconclusive. The evidence of record is the
side-by-side harness `verif/tb/core/store_buffer_sbs/` (Verilator, random
stimulus under the legal environment: no commit on an empty queue or an
invalid head, no push into a full queue, unique live tids): **4 seeds ×
400 k cycles, 0 mismatches** on every output every cycle (≈ 215 k pushes,
146 k commits, 78 k cancel cycles, 9 k flushes per seed). Two of the
harness's own early "mismatches" were again illegal stimulus (duplicate
live tids, a push into a full queue), under which the reference revision
itself leaves its invariants — the harness asserts the reference's count
stays legal so that cannot recur silently.

**Netlist (live remap, module board):** store_buffer 4.26 ns / 45 cells →
**2.77 / 38**. Board after A109 (cells): iq 38, store_buffer 38, frontend
34 (4.35 ns, the ns-worst), wbuffer 27, rob 26, rename 25, realign 22,
scoreboard 22. **Campaign: module-board worst 54 → 38 cells.**

Lesson of the round, for the method: a bounded miter's first
counterexamples are usually the environment's — read them before
believing them, and encode the module's own assertions as assumptions;
when the SAT instance is too wide, a side-by-side harness under the same
environment contract is the honest fallback, and it must assert the
reference's invariants so illegal stimulus is a harness failure, not a
"mismatch".

## A110 — The realigner as a boolean prefix (the cone the frontend shares)

A108 noted that the frontend's target sum and the realigner's cursor walk
share their first half: `off[i] = {cur_i, 1'b0}` is the serial walk's
output. The walk — a cursor stepping 1 or 2 halfwords depending on what it
finds — is the recurrence `vis[h] = vis[h−1] ∧ c'[h−1] ∨ vis[h−2] ∧
¬c'[h−2]` ("an instruction is visited at halfword h"), with `c'` the
compressed flags and position 0 counted compressed when a carried lower
half completes there (so the carried slot falls out of the same
numbering). A two-term linear recurrence over the boolean semiring is a
product of 2×2 matrices; the module takes it as a Kogge-Stone prefix
(`pfx[l][h] = pfx[l−1][h] ⊙ pfx[l−1][h − 2^(l−1)]`, `vis[h] = pfx[h][0][0]
∧ vis0`, masked past `hw_avail`). A visit's slot is the popcount of the
visits before it; a visited RVI whose upper half is past the block is the
split that carries; each slot takes the one visited position whose ordinal
it is. Same values as the walk, position by position, including the
compressed-at-tail zero upper half and the carried slot's address.

Evidence: `verif/tb/core/instr_realign_sbs/` — random halfword streams with
mostly sequential fetch blocks (so split RVIs carry into the next block),
every output compared each cycle: **3 seeds × 500 k cycles, ≈ 162 k carries
per seed, 0 mismatches.** Whole core elaborates. **Netlist (live remap,
module board): instr_realign 3.27 ns / 22 cells → 2.31 / 15.** The
frontend's own row stays 4.35 / 34: the per-module board measures each
module's own logic, so the cross-module path realigner → target adder is
shorter by the realigner's seven cells in the flat core, while the
frontend's intra-module worst (the 64-bit three-operand sum behind the
slot select into `bp_tgt_q`) is unchanged — the wall.

## A111 — ROB decrement by ports, not by entries

A tid names at most one valid ROB entry (a live instruction has one slot),
so each retire port's hit vector is one-hot-or-zero and the count's
decrement is `Σ_r |free_hit[r]` — an OR-reduce per port instead of the
32-entry popcount (A107 had already made the hit vectors disjoint across
ports). Asserted (`ooo_rob_hit_onehot`); whole core elaborates; netlist in
the next remap.

### Board after A110 (cells, Nangate45, every module under the delay-oriented script)

iq 38, store_buffer 38, frontend 34 (4.35 ns, the ns-worst), wbuffer 27,
rob 26 (A111 pending), rename 25, scoreboard 22, realign 15, loop_buffer
15, lsq 15. **Campaign: module-board worst 54 → 38 cells**; the OoO control
cones went from 47–54 to 22–38, the realigner from 23 to 15. At ≈ 1.3
cells/FO4 the 10 FO4 budget is ≈ 13 cells: the remaining cones are the
single-cycle contracts A107 lists (wake/select, the 64-bit target and
ALU adds, the same-cycle squash), and the next lever is pipelining them —
an IPC decision.

## A112 — Ablation before architecture: the issue queue's cones, measured

The owner chose the wake/select split as the next lever for `g6lc_iq`
(38 cells). Before changing issue latency, the module's cones were
**ablated on the mapped netlist**: each named cone is replaced by a free
input (`add -input X_cut W; connect -set X X_cut` on the module's RTLIL,
then the same ABC script and the module board), so the board reports the
worst path *without* that cone:

| cut | worst reg→reg | Δ | reading |
|---|---:|---:|---|
| none | 3.506 ns | — | |
| `cancel_hit` (the 32-way `cancelled_mask_i[tid]` lookup per entry) | 3.110 | **−11 %** | on every longest path: wake → select → ack, the count delta, the dispatch-age clears |
| `grant` (both ports' cascade) | 3.247 | −7 % | the select itself |
| `q_wake` (the tag-compare wakeup) | 3.466 | −1 % | **the split's whole gain** |
| `ready` (wake + cancel + all issue gates) | 3.588 | 0 % | other paths of equal length remain (dispatch, age) |
| `older_t` (the age matrix) | 3.506 | 0 % | |

The wakeup is already shallow (6-bit tag compares in parallel): a
wake/select pipeline split would buy ≈ 1 % and cost one cycle of
wake-to-issue latency on every dependent pair. The measured term is the
cancel lookup, and it pipelines **without** an issue-latency cost:

**A112 — the cancel verdict registered.** `cancel_hit_q[e]` is last
cycle's mask test for the entry in slot e (a newcomer is tested the cycle
it lands, on its next-state tid); the squash, the count delta and the
dispatch-age clears read the register. A wrong-path entry can therefore
issue in the cancel cycle itself — the same case as a wrong-path op issued
the cycle *before* the cancel arrived, which the pipeline already squashes
downstream (the scoreboard's cancelled flag drops its writeback, the store
buffer's push guard tests the mask, head-only ops are never cancelled at
the head); the mask is level-held per scoreboard slot, so a one-cycle-late
read loses nothing. Not cycle-exact (one more wrong-path issue slot per
cancel), so the evidence is the OoO Verilator harness and the directed
mini suite on A104–A112, not a miter; whole core elaborates. **Netlist
(live remap, module board): g6lc_iq 3.506 ns / 38 cells → 3.042 / 41** —
the −13 % the ablation predicted (the +3 cells are the band); **g6lc_rob
2.107 / 26 → 1.931 / 23** (A111). The OoO Verilator harness built in 407 s
on the builder; the directed mini suite is queued behind the owner's
Linux-boot workloads (the proxy refuses a second workload) — owed before
A112 is called validated.

### Board after A112 (cells / ns, Nangate45)

frontend 34 / 4.35 (the 64-bit target sum — the wall), rename 25 / 3.77,
wbuffer 27 / 3.12, iq 41 / 3.04, store_buffer 38 / 2.77, scoreboard 22 /
2.76, loop_buffer 15, realign 15, lsq 15, rob 23 / 1.93. By delay the
worst module is now the frontend; by cells the iq's 41 and store_buffer's
38 are two permutation/select cones of ≈ 2× the 13-cell budget.

Method note: ablation is cheap (minutes per cut on one module) and it
ranks the *measured* contributors before an architecture change is made
on a model's say-so — here it turned a latency-costing split into a
latency-free pipeline stage.

## A141 — Stationary slots and an age matrix (store buffer)

Replace the program-ordered ring by stationary slots plus a DEPTH×DEPTH age
matrix `older[i][j]`, written at insertion from the arrival's age against the
live set (arrival order when in-order) and cleared with the entry. Head =
`valid[i] & ~|(valid & older[:,i])`; forwarding per byte = candidate with no
younger candidate (`~|(older[i][:] & cand[:,b])`), AND-OR of the winner's
byte; cancel/flush clear valid bits; count = popcount. Invariants asserted:
irreflexive, total between live pairs, cleared with the entry, one head,
agreement with the live anchor. Placed 4.159 → 2.811 ns /
4.159 → 2.148 ns reg→reg, area -36%. Evidence:
`architecture/PIPELINE-PRAGMA-REVIEW.md` (A141).

## A138 — Input staging as a uniform shift (store buffer; rejected)

Stage the request, commit, flush, cancel mask and age anchor; run the
unchanged permutation on the registers. State(t) == previous State(t−1) by
construction (checked white-box every cycle). Current-cycle outputs derived:
the staged store as a forwarding source at its program-age slot (two passes
split by `ooo_older(entry, staged)`), the head a staged commit pops treated as
committed, entries the staged mask / flush remove masked from forwarding,
`ready_o` as a register sum, the commit-port head as the older of the slot
after the staged pop and the staged store (skipping squashed entries). Placed:
3.964 → 4.316 ns worst, area +8.1% — the placed worst path was already
reg→reg inside the permutation. Reverted; evidence and the lesson in
`architecture/PIPELINE-PRAGMA-REVIEW.md` (A138).

## A136 — Registered derived addresses; absolute-order ring search

Two exact, latency-neutral forms measured on the next modules of the list.

*Loop buffer.* `expect = base_q + (cursor_q << ALIGN)` sat in front of the
64-bit equality that decides a hit or a fill. The sum is a function of state
only, so a register holds it: reset to `base` whenever a cursor resets
(flush, arm, close, wrap), advanced by one block when a cursor advances. The
candidate `base_q + ((cursor_q + 1) << ALIGN)` is formed off registers in
parallel with the compare and selected late. Capturing and armed are
exclusive and every return to armed passes through the close, so one register
serves both cursors; the arm wins an arm+consume cycle because only the fill
compare can observe the next state. Invariants (`armed_q → expect == base +
replay<<ALIGN`, `capturing_q → expect == base + fill<<ALIGN`) are asserted.

*ROB.* `first stop in ring order from head` was computed as rotate(stops,
head) → `x & (~x + 1)` → encode → `head + steps`. In slot order it is the
lowest stop at or above `head_q`, else the lowest stop below it; `lowest_set`
is a log-depth prefix OR (`x & ~prefix_or(x << 1)`), and the found slot is the
new head. The tail stop (`j == tail_d`) reproduces the empty-ring and
full-ring cases exactly. Matched-state equivalence holds at 8/16/32 entries
because the identity is combinational for power-of-two depth.

Evidence and physical pairs: `architecture/PIPELINE-PRAGMA-REVIEW.md` (A136).

## A135 — Execute the row-local pattern from a pragma

The A134 hand pattern (compute each table row's update before the late row
select) is now compiled from `// svt-pipe: row-local …`. The rule is a
source-preparation stage, not an IR credit: the conditional statement's exact
original bytes are retained at parse; the plan checks index stability and
signedness, bank type/dimension agreement, the write footprint against the
lowered IR, token-level hazards (calls, macros, locals, compound assignment,
enclosing terminators) and the authored replication bound; `correct --emit`
writes the prepared file, reparses it under the same configuration, and the
ordinary passes run on that program. The consumed directive becomes
`row-local-applied`, so a second run cannot re-expand it.

Loop predictor evidence: three equivalence geometries, an independent model
with a negative control on source and emit, and paired placement 1.911 →
1.410 ns at −6.9% area. The structural headline did not change (18.6 FO4);
the emitted program and the physical pair are the evidence, per PL-P4.

## A134 — Cache a state predicate; localize table feedback

The realigner's split PC is the last available halfword of its fetch window.
Expressing that geometry directly and recording its 64-bit successor with the
same hart's carry state removes a PC increment from the next-window feedback
cone. Kill/flush retention and narrow-VLEN overflow are preserved. Five
500k-cycle comparisons cover width/hart/RVC/slot variants; the interface
witness samples before and after the update edge and detects a deliberately
truncated successor.

The statistical corrector prepares each row's next counter/tag/valid locally,
then selects the update row. It preserves the tagged-owner saturation,
takeover/decay, lookup and flush rules while removing a shared indexed read
before the write decode. Three matched-state equivalence configurations and
the existing independent predictor model with negative controls pass.

Paired Nangate45 placement without disabled arcs retains realign
(2.977→2.257 ns, −17.2% area) and statcor (1.622→1.095 ns, +12.6% area).
Rename map-read bypass and store snapshot bypass improved filtered mapping
but worsened placement (2.964→3.105 and 4.086→4.801 ns); both are restored.
These are pre-CTS module results, not 10 adjusted-FO4 or whole-core closure.
The retained RTL patterns are candidates for future preprocessing rules;
the carry-save rule does not silently claim support for them.

## A133 — Compile representation obligations before timing

The multiplier's transferable mechanism is a complete represented value and
operation moving through a boundary. The first generic compiler rule accepts
`representation <domain> carry-save sum=… carry=… result=…`, validates equal
widths, independent row cones, exact consumer shape and explicit protocol
roles, then derives carry/result facts. One authored cut permits either row
as the critical anchor, always with its companion; no-cut on either forbids
the pair. Applied boundaries stay closed in mutable IR and emitted comments.
Raw facts and original locations are retained; preprocessing is idempotent,
cache/context-aware, and assigns no timing credit.

The fixture demonstrated why aliases are necessary: the carry row, not the
authored sum anchor, lies on the longest path. The emitted cut captures it
and carries the sum. Six runs of 200,032 cycles pass including drain,
cancellation and flush; reconnecting the unstaged companion fails on values.
Mapped Nangate45 worst arrival falls 0.808 → 0.699 ns at +27.9% area.
Structural 15 → 10 is approximately 32.7 adjusted FO4 after mapping, not
physical closure. This is a tested compiler primitive, not automatic tiling
or a generic state-machine/ready protocol.

The evidence-based reasoning method, pattern families, rejection conditions
and extension requirements are in `architecture/PIPELINING-RT-LEARNING.md`,
linked from the root development guides.

## A132 — Validate the boundary, the emitted file and the physical result

The pragma census was counting worklist events instead of declarations.
Analyze JSON now reports `pipeline_contracts` for every annotated module:
53 of the 56 measured over-budget modules have guards, 12 domains are
declared, and none currently authorizes an added stage. Three vector-valid
domains need lane/packet semantics before they can use a scalar stage.
Three `no-cut` names were scope labels or nonexistent ports and are corrected.
Rejected contracts and unresolved domains no longer permit an uncarried cut.
Latency checks use exact parameter keys and no longer suggest increasing
the same parameter that also determines the source's existing depth.

The physical experiment partitions the multiplier's arithmetic at its
existing three-cycle boundaries: 16-bit A tiles by 8-bit B slices (partial
top slices retained), a 3:2 compressor tree including `~corr_sh + 1`,
then one final carry-propagate add. CLMUL, valid, ID and operation stay
aligned. An operand-capture fourth-cycle candidate was rejected because
it moved the long product cone rather than dividing it.

Paired Nangate45 placement/repair, no disabled arcs: worst arrival
**2.634 → 2.215 ns**, repaired area **52,164.730 → 52,886.117 µm²**.
Reg→reg is essentially flat (2.139 → 2.145 ns). The actual corrected SV
passes the same arithmetic/lifetime checks and places at **2.298 ns**;
one latency-neutral SplitAssign preserves most, not all, of the source gain.
Unbuffered timing worsens, so the placement comparison is essential.
This is a pre-CTS module result, still 103.5 adjusted FO4 on source and
107.4 on emit at 21.398 ps, not 10-FO4 closure.

The runner pins source snapshots, obtains elaborated widths, binds the
measured latency and reports in→reg/reg→reg/reg→out independently.
The historical board's trace belongs to reg→reg and cannot explain its
worst-any column. Conditional int localparam pruning (`delay-v42`) removes
another source of reporting error; it earns no hardware timing credit.
Evidence and remaining state-machine implementations are recorded in
`architecture/PIPELINE-PRAGMA-REVIEW.md`; 373 Rust tests and the focused
source/emitted witnesses pass.

## A131 — Hand re-pipelining with contracts as the check: the multiplier's slices

Under `MultStages = 3` the multiplier's second operand is sliced into
8-bit pieces (eight (XLEN+1)×9 products, an 8-term sum in the third
stage's cycle); two-stage configurations keep 16-bit slices. Live board:
reg→reg 1.817 → **1.623 ns** (−10.7 %), worst any 2.581 → 2.531 ns
(120.6 → 118.3 adjusted FO4) — the boundary cone is the operand
conditioning ahead of the product, whose real start is the issue stage's
operand mux. Witnesses: `tb_mul_sbs` at 2 and 3 stages (3 seeds × 300 k
each, 0 errors), `tb_mul_lifetime` at 3 stages, whole-core map + STA.
The contract is unchanged and still admits nothing further under
`MultStages = 3`.

## A130 — The live-RTL board after the multiplier's adoption

The route on the live `g6lc64_ooo` tree (`MultStages = 3`, contracts
declared, streamed recipe): the multiplier reads **2.581 ns = 120.6
adjusted FO4** (was 2.820 / 131.8 on the previous board), reg→reg 1.817
(was 2.013); its worst is now the stage-1 Booth product from the inputs
into `pp_q`. The board's top is `store_buffer` 173.0 (3.702 ns) and
`wt_dcache_wbuffer` 132.3 — both up from the previous board, with the
concurrent fixup-queue fixes (T46/T47) in the tree; `g6lc_lsq` / `g6lc_iq`
/ `scoreboard` read lower on the live RTL than on the old corrected emit,
whose own cuts had created the boundary cones. 56 of 65 measured modules
remain over budget; budget-equivalent 216 MHz. The multiplier's next rung
is narrower partial-product slices under the existing third stage — an
arithmetic restructure, not a cut. Flow fix: whole-core recipes run
`async2sync t:$aldff t:$aldffe` before mapping.

## A129 — The `latency` word

`latency <dom> <param> base=<n|param>` binds a domain's stage count to the
parameter its consumers read (the wrapper's liveness depth, a latency
table). A plan of k stages is admitted only when `base + k` equals the
parameter's elaborated value; otherwise the refusal names the value to
set. On the multiplier (`base=CVA6Cfg.MultStages`, the source follows the
parameter since A128): under `MultStages = 2` the `prod_sum` stage is
proposed and refused — "set `CVA6Cfg.MultStages` = 3 to admit the stage";
under 3 the module meets the structural budget and no further stage is
proposed. The adoption hazard (a fourth stage the wrapper cannot track)
is closed by contract.

## A128 — Contracts on the whole list; the multiplier's third stage adopted

**Declarations.** The 44 editable files of the over-budget list that had
no contract now carry one in the fail-closed form (`require-contract`;
port-level protocol roles where unambiguous, id-less for the fetch
streams; `no-cut` on the measured worst cone with its reason). Vendored
tier-U files are not edited. Every contract resolves; the sweep's only
remaining bare register is in vendored `exp_backoff`.

**Adoption.** The multiplier's emitted third stage is written into the RTL
as `gen_three_stage` (`MultStages == 3`): `prod_sum` registered with the
correction, operator, valid, trans_id and the carry-less stage-1 results;
the output and carry-less registers read last-stage nets both branches
drive. `check_cfg` admits 3; `g6lc64_ooo` sets 3; `mult.sv`'s liveness
follows the parameter. Witnesses: `tb_mul_sbs` at `MultStages = 3`,
`+lag=2`, 4 seeds × 300 k, 0 errors; `tb_mul_lifetime` rewritten as a
reference-model script, PASS at 2 and 3 stages (18 checks), negative
control intact; whole-core slang elaboration PASS. The adjusted reading
is owed to the live route started on the builder.

## A127 — Id-less domains and the sweep of the list

**Mechanism.** A domain may omit `id=` when its kill is global
(`kill=kill_i`, no `$id`): fetch-side streams travel with a valid and a
kill but no transaction id. Stage nets, exports, consumer rewires and the
fenced assertions omit the id accordingly.

**The sweep.** All 56 modules of the list under one `correct
--allow-latency` at -O3 (dial 11 at 48): **one carried stage** — the
multiplier's; seven **bare** registers in modules that declare no
contract (review items, not pipelines); the rest latency-neutral credits
and refusals that name the next `cut-ok` / `no-cut` decisions
(`PIPELINE-PRAGMAS.md` §9). The structural headline did not move (78.2
FO4), and no adjusted reading changed: the sweep is the campaign's work
order, stated per file, not its progress.

**What the list needs, by class.** Operation pipelines with a local
protocol (multiplier done; FPU wrappers, `serdiv` next) — declare, emit,
witness, adopt with the latency parameter. Fixed-latency units through
`ex_stage`'s one FLU port (ALU, branch, CSR, AES) — an FLU redesign with
IPC on the table, recorded as `no-cut` until decided. State machines
(most of the list) — input staging or read retiming, mechanisms the
vocabulary reserves and this round did not build, each with a
module-specific correctness argument.

## A126 — The merge resolved from both ends

The A125 rule named the hazard (`result_o` reads `clmul_q`, one stage
short). The RTL end made the carry-less stage-1 results module-level nets
(`clmul_s1`/`clmulr_s1` out of the unnamed `if (RVB)` block, zero in
`gen_no_clmul`) and the contract carried them and rewired their output
registers (`carry … clmul_s1,clmulr_s1`, `result … clmul_q clmulr_q`); the
mechanism end priced the bundle at its resolved widths — 336 cells for
10 FO4, 33.6 cells/FO4, admitted explicitly over the -O3 limit — and
emitted the stage inside `gen_two_stage` with exports whose defaults read
the now-visible nets. Witness: the emitted three-stage multiplier at
`+lag=2`, 3 seeds × 300 k cycles, ≈ 234 k results each, **0 errors**, all
eight operations; the refactored stock RTL at `lag=1` unchanged. Adoption
needs `MultStages = 3` (the wrapper's liveness) and a three-cycle
`tb_mul_lifetime`; the mapped reading comes from the full route.

## A125 — Generate-scope emission, exports, and the merge rule the witness taught

**Mechanism.** A contract-admitted cut on a net declared in a named
generate block is staged *inside* the block (declarations after its
`begin : label`, feed / capture / sinks before its `end`), at the net's
measured width. Consumers outside the block read module-level exports
driven by a generate-if on the block's own condition — the staged
expression when the branch exists, the original signal otherwise — so the
module's other configurations keep elaborating. Only signals a consumer
reads are rewired or exported.

**What the witness found.** The emitted three-stage multiplier
(`prod_sum` staged, `operator_s1`/`corr_q` carried, `corr_sh` re-derived,
`mult_valid_q`/`trans_id_q`/`operator_d` rewired through exports)
elaborated for `MultStages` 1 and 2 and aligned valid / trans_id on every
cycle at `+lag=2`, yet produced **77 313 wrong results of 234 155** — every
CLMUL-class op: the carry-less products keep their own two-stage pipeline
and merge with the product at `result_o` one operation late. The alignment
rules (chain, tail, foreign reads) had covered the path; they had not
covered a *parallel datapath merging downstream*. `merge_violation` now
closes everything downstream of the stage's consumers — including every
other writer of a reached LHS, the other arms of the result select — and
refuses a register read there that is not staged with the domain. On the
multiplier it names `clmul_q` at `result_o`; the stage is refused until the
carry-less pipeline takes the same depth (and `mult.sv`'s liveness with
it), which is the designer's change.

**Status.** The stock multiplier passes the widened witness unchanged
(3 seeds × 300 k, `lag=1`, 0 errors). Adjusted FO4 did not move; the
round's product is a mechanism that would have emitted a wrong pipeline and
now refuses it with the cause. 369 Rust tests.

## A124 — The core's list, and the first contracts on it

**The list.** Fifty-six modules measure over 10 adjusted FO4 on the
retained tree (Nangate45): `g6lc_lsq` 176.0 (3.766 ns), `g6lc_iq` 142.8,
`frontend` 142.4, `store_buffer` 141.3, `multiplier` 131.8, `scoreboard`
127.9, `g6lc_rename` 125.9, `instr_realign` 119.0, `wt_dcache_wbuffer`
105.6, `g6lc_ooo_dispatch` 97.9, `alu` 96.4, … down to `g6lc_fdip` 10.1.
The full ordered table with files is `architecture/PIPELINE-PRAGMAS.md` §6.
The rung arithmetic (`ceil(adj/10)`: 18 stages for the LSQ cone, 15 for
the IQ, 10 for the ALU) says what 10 adjusted FO4 means physically: a
214 ps cycle is below one 64-bit adder on this library, so the lower rungs
split operators, not only cones.

**The pattern.** Worst file first: declare its contract, run `correct
--allow-latency`, keep what the witness and the board confirm, re-measure,
move on. The contract's verdicts name the next mechanism when the rung is
not yet mechanizable.

**Round one.** Contracts on nine files (multiplier, lsq, frontend,
store_buffer, scoreboard, iq, rename, alu, dispatch) — protocol roles from
the ports, `no-cut` where a stage would split one transaction's view (the
many-writer next-state functions, the fetch and issue loops, the rename
map) with the architecture that would move each written beside it, one
`cut-ok` where a stage is admissible (the multiplier's shifted-product
sum). Verdicts: the multiplier's bare cuts on `operand_a`/`sign_a`/`sign_b`
are refused (they would have desynchronised valid/id — exactly the hazard
the contract exists for); the planner, now driven by permission, snaps the
stage-2 cut to `prod_sum`; the emitter refuses it because `prod_sum` lives
in `gen_two_stage` — generate-scope emission is the next emitter
mechanism. The state machines ask for input staging (`stage-input`,
reserved in the vocabulary); rename and realign for id-less domains;
dispatch for struct-member ids.

**Mechanism changes.** A declared protocol implies `require-contract`;
`kill=` optional (a kill without `$id` is global); `result` takes further
consumer assignments; user-typed carries read back through `type()'()`;
names declared with package-imported types bind through their
assignments; `schedule_pipeline_cuts` snaps to permitted anchors.

## A123 — Re-pipelining contracts declared in the RTL (`svt-pipe` pragmas)

**Mechanism.** A register cut is exact for a pure datapath and wrong for an
operation in flight: the staged value loses its valid, its id, the
cancellation raised in later cycles, the flush and its side-band — which is
why the two-stage multiplier (A115) carried all of these by hand and why
the P10 heuristic refuses `InsertReg` on a same-edge pulse + index. The IR
cannot infer those roles; the designer can declare them where the logic
is, as comment pragmas the parser never sees — the mechanism of the
`translate_off` fences and the `$onehot0` facts (collected over the module
span, treated as the design's own proof obligation) applied to pipelining:

```systemverilog
// svt-pipe: protocol ex valid=valid_q id=tid_q kill=cancel_i[$id] flush=flush_i
// svt-pipe: carry ex op_q,a_q,c_q
// svt-pipe: result ex valid=res_valid_d id=res_tid_d
// svt-pipe: cut-ok ex        ← next assignment may be a stage boundary
// svt-pipe: no-cut           ← next assignment never is
// svt-pipe: require-contract ← only cut-ok anchors may be cut in this module
```

**What the transform does with it.** `InsertReg` consults the resolved
contract: a `no-cut` anchor (or a `require-contract` module without
`cut-ok`) refuses the cut; a cut inside a declared domain carries the
domain's bundle — per stage, in data order,
`v <= flush ? 0 : (valid_prev & ~kill(id_prev))`, `id <= id_prev`, every
carried signal in lockstep — and the consumer side named by `result` reads
the last stage's valid (killed again at use), id and carried copies. The
P10 lock yields exactly on paths that contain an allowed anchor. Age
consistency is enforced, not assumed: a stage's feed may read only its
chain predecessor, carried copies, protocol signals and constants; the
tail after the last cut likewise; a plan whose stages read an earlier
stage's value or an uncarried input is refused with the signal named
(“side path needs *n* balance register(s)”, “declare `svt-pipe: carry …`”).
The area gate prices a carried stage (data + 1 + 8 + 8·|carry| flops) per
stage *before* alignment. Serialization: hoisted plain-vector declarations
of resolved widths, a `// svt-pipe: stage k of <dom>` comment stating what
the stage samples, `edits[*].pipe_stage` in the JSON, and two fenced
assertions per stage (`*_killed_stays_dead`, `*_flush_clears`).

**Evidence.** `fixtures/auto_correct/pipe_contract.sv`, two modules. The
straight chain: two carried stages (the gate refused two low-gain ones),
structural 34 → 14 FO4, stage 2's feed reading `pipe_svt_p1_c_c_q`, the
tail reading `pipe_svt_p2_c_op_q`/`_a_q`, the result side
`pipe_svt_p2_v & ~cancel_i[pipe_svt_p2_id]`. Latency-agnostic witness
(`tb_pipe_contract`: every emerging result belongs to an issued,
never-cancelled, never-flushed operation, with its id and value, exactly
once) — gold and twin, 3 seeds × 200 000 cycles, **0 errors** (twin: 103.9 k
issued, 86.9 k emerged, 11.1 k killed in flight, 3.9 k flushed). Mapped on
Nangate45: gold 1.123 ns / 1593 µm², twin 1.103 ns / 2652 µm² — the
mapped gain is small because ABC builds the three-operand sum as one
carry-save adder (the structural 34 over-reads a ≈ 52 adjusted-FO4 cone)
and the stage the gate kept out is the tail's remaining depth; the area is
the contract's honest price plus 64-wide pipes for 32-bit nets
(`SVT_DATA_W`, to narrow). The side-path module is refused: “stage 4 reads
`s1` (cut 1) past stage 2: side path needs 2 balance register(s)”.

**Defects the fixture exposed (fixed).** The twin-assign rewrite crossed
module boundaries in a multi-module file; every injection targeted the
first header / last `endmodule` of the file rather than the owning module
(the stage block landed in the wrong design, and the witness passed
vacuously with `emerged=0` until the trace showed `p1_v` never rising);
`type(<signal>)` declarations hoisted above the signal's own declaration
elaborate in Verilator and not in slang.

**Not done, by design.** No protocol inference; no balance registers on
side paths (refused instead); no ready/back-pressure; no cross-port
retiming; the planner's cut points are admitted, carried or refused, not
chosen by the contract. Design: `architecture/PIPELINE-PRAGMAS.md`.

## A122 — From hand tunings to generic transforms: what each rewrite really did

The A104–A120 campaign rewrote eleven modules by hand. Each rewrite worked
for a *mechanism*, not for the module; this entry names the mechanism,
states the exact generic form, and records which forms are now passes of
the package, which are reported as sites, and which remain manual.

| hand rewrite (entry) | mechanism it removed | generic form | status in sv-timing |
|---|---|---|---|
| IQ / LSQ / store-buffer age tests (A118) | two modular subtractions before a comparator | **`CircularCompare`**: `(a − h) < (b − h)` → `(a < b) ^ (a < h) ^ (b < h)` | pass (`expr_rewrite`), RHS and `if` guards, proven |
| ALU EQ/NE from the shared subtractor (A118) | zero detect of a difference | **`ZeroDetectEquality`**: `(a − b) == 0`, `!(a − b)`, `~\|(a − b)` → `a == b` | pass, proven |
| frontend both targets before the taken select (A118) | arithmetic serialized behind a late select | **`PushSelect`**: `z + (c ? x : y)` → `c ? (z + x) : (z + y)` | pass, arrival-gated, area-gated (Dial 11), proven |
| rename busy bits read registered + bypass (A118) | same-cycle indexed write → indexed read through an array | **`IndexedWriteReadBypass`**: `r = (ri == wi && we) ? v : X_q[ri]` | reported site (`structural_patterns`); emitter pending |
| rename one-hot write masks (A120) | one-hot → encoder → decoder round trip | **`OneHotEncodeDecode`**: `for i: if (sel[i]) X[i] <= v` | reported site; emitter pending |
| IQ first-two grants in parallel (A119) | serial priority cascade | k-th-set selection by prefix popcount | manual (next `LoopRewrite` shape) |
| LSQ oldest/youngest tournaments (A119) | loop-carried argmin/argmax | tournament tree | manual (next `LoopRewrite` shape) |
| realign cursor walk → prefix (A110) | serial walk | `LoopRewrite` (A101) | pass since A101 |
| scoreboard / IQ registered counts (A106, A112) | popcount of a state vector | incremental counter + invariant | manual: exact only when the event vectors are early; adds state |
| two-stage multiplier with carried lifetime (A115) | one 65×65 product per cycle | re-pipelining with valid/TID/cancel carried | architectural; no generic form |

**Exactness, as code.** `crates/sv-timing-core/src/expr_rewrite.rs`
refuses whatever it cannot prove: `CircularCompare` needs every leaf of
`a`, `b`, `h` declared unsigned (`logic`/`bit`, unsigned typedefs; signed
operands rotate the ring differently — refused) and equal widths or
extension-stable operands (no arithmetic inside, so a narrower compare
cannot wrap differently); `ZeroDetectEquality` needs extension-stable
operands (`(a + c − b) == 0` is refused: the unsized `0` widens the
context the sum wraps in); `PushSelect` is exact for any width and sign
(the whole expression's context decides both forms alike) and fires only
when the condition's structural arrival exceeds the data's, costing one
adder per extra arm, priced by the area gate. Every rewrite re-emits the
whole RHS from the tree, so casts, comments, strings and macros in the
origin refuse the node (the tree does not keep them), and the result must
round-trip through the parser. The 4-bit circular identity is checked
exhaustively in the unit tests.

**Guards.** The codebase's comparisons mostly guard assignments
(`if ((a − h) < (b − h)) …`) rather than feed an RHS. IR v3 records every
`if` / `else if` predicate with its source span (`TimingModule::guard_sites`);
an identity on a predicate of a node on a failing path is an `ExprRewrite`
opportunity whose locus is the predicate, and the emitter replaces exactly
that byte span, in place, one line, before any line-based stage — so every
other edit keeps its numbering. The module's `guards` texts follow the
rewrite so re-measurement sees the new form.

**Proof and board.** `fixtures/auto_correct/expr_identities.sv` carries
the three shapes in RHS and guard position plus the two refused shapes
(signed, self-wrapping). The emitted file (6 rewrites, 2 in guards) is
proved equivalent to the fixture under matched state (`async2sync`, 345
cells, 0 unproven) and mapped on Nangate45: gold **2.167 ns / 30 cells**,
gate **1.678 ns / 17 cells** (−22.6 %), area 3310 → 3563 µm² (+7.6 %, the
pushed 64-bit adder). Fixture-scale evidence, not a core result.

**Applicability on the live core — the honest reading.** With the fresh
width map, the three identities find **no** site on the failing paths of
the 108 live modules: the campaign already applied them by hand where they
mattered, and a textual census of the live sources confirms the direct
shapes no longer exist (the age tests go through `age_older`, the ALU
through the direct compare). The passes now guard those spots against
regression and serve new RTL; they are not a reservoir of FO4 on this
tree. The statement-level census is where the remaining generic work is:
`structural_patterns` in the analyze report lists, after recognising loop
variables and genvars as static selects (76 raw → 6 real),
**5 `IndexedWriteReadBypass` sites** — `g6lc_rename` `map_d` (L537→568),
`fmap_d` (L515→569), `favail` (two writes, L349→364), `id_stage`
`fetch_entry_ready_o`, `perf_counters` `event_group` (32 writes) — and
**1 `OneHotEncodeDecode`** (`g6lc_iq` `older_d`, L464→550). The rename map
writes are the same mechanism the A118 busy-bit bypass removed, left in
the map and FP map paths; they are the next concrete targets, now found by
the detector rather than by reading.

**Where it lives.** `expr_rewrite.rs` (identities, arrivals, 5 tests),
`patterns.rs` (sites, 4 tests), `OpportunityKind::ExprRewrite`,
`EditKind::{CircularCompare, ZeroDetectEquality, PushSelect}`,
`EditRecord::{emit_predicate, emit_predicate_from}`, emitter
`rewrite_guard_predicates` + the identity branch of the pure-RHS rewrite
(allowed inside generates: no names are added), `correction-v2`, `ir-v3`.

## A121 — Adjusted FO4: the budget read in the platform's own inverter delay

**Contract.** The structural FO4 is a model unit; a mapped delay is physical
but library-bound. The budget formula already carries the bridge —
`budget_fo4 = (1e6 / f_mhz / fo4_ps) · (1 − margin)` — if `fo4_ps` is the
*measured* FO4 of the liberty the netlist was timed with. A121 measures it
and reads every mapped path in that unit:

```text
adjusted_fo4  = mapped_ns · 1000 / platform_fo4_ps
f_mhz(fo4_ps) = 1e6 · (1 − margin) / (max adjusted_fo4 · fo4_ps)
```

**Probe (`openroad-fo4-probe.tcl`, `fo4Probe.ts`).** The host scans the
platform's liberty text for leaf cells with one input pin and an output
whose function is `!A`, `(!A)`, `!(A)` or `A'` (any pin name), drops
`dont_use` cells, and takes the smallest area — ties broken by the plainest
name, which separates `inv_1` from `clkinv_1` and `INVx1` from `INVxp33`.
It writes a netlist of two chains of that cell, 8 and 4 stages long, with
every stage output loaded by exactly four copies (next stage + three
dummies). OpenSTA times both chains from the same input slew; `(t8 − t4) / 4`
cancels the first stage, the output stage and the slew, leaving the
steady-state FO4. Gzip'd liberties are inflated for the scan and read
natively by OpenSTA, so asap7 — unmappable by yosys — still yields its FO4.
Windows checkouts store the fork's `*_tt.lib` symlinks as one-line files
naming their target; the scanner follows them.

**Measured platform FO4 (builder, 2026-10-17).** asap7 `INVx1_ASAP7_75t_R`
14.36 ps; nangate45 `INV_X1` 21.40 ps; sky130hs `inv_1` 72.08 ps; sky130hd
`inv_1` 80.91 ps. Nangate45 lands within 7 % of the model's assumed 20 ps:
the structural and adjusted "10 FO4" are the same ~214 ps on the study
platform.

**Reading (`sv-timing adjusted`).** The package joins a header-driven
per-module board (`module`, `worst_any_ns|worst_ns`, optional reg→reg and
cell count; derived-parameter suffixes `name$…` stripped) with the report's
structural worst per live module. Measured modules decide closure; modules
without a mapped row receive an *estimated* value from the median
adjusted/structural ratio, labelled, never decisive. The frequency is quoted
on the mapped platform, at the configured process `fo4_ps`, and — from the
shared `platform-fo4.json` table — on every other probed platform at its
own unit: one logic depth, four cycle times.

**What it revealed.** Previous full board (pre-A118): median
adjusted/structural **3.05** over 64 modules (p25 1.63, p75 5.18); worst
measured `store_buffer` 3.524 ns = 164.7 adjusted FO4; 227 MHz
budget-equivalent on nangate45. Fresh full route on the retained A120 tree
(the `s3-adjusted-fo4` stage, 2026-10-17): median **2.91** (p25 1.77, p75
5.12); worst measured `g6lc_lsq` 3.766 ns = **176.0 adjusted FO4** — an
in→reg boundary cone (7-cell reg→reg) the module board times with ideal
inputs; then `g6lc_iq` 142.8, `frontend` 142.4, `store_buffer` 141.3,
`multiplier` 131.8, `scoreboard` 127.9, `g6lc_rename` 125.9; 56/73 measured
over budget, 8 linked modules folded to no path (measured 0, never
estimated — `g6lc_thread_select` at `NrHarts = 1` among them);
budget-equivalent **212 MHz on nangate45, 227 MHz at fo4_ps = 20, 317 MHz on
asap7, 63/56 MHz on sky130hs/hd**. One structural FO4 is about three
inverter delays after mapping, so the 55.7-FO4 structural maximum is ~176
adjusted FO4 and the distance to 10 is ~17×. The spread of the ratio is a
calibration map: `scoreboard` 6.5, `store_buffer` 6.1 and `frontend` 5.0
are where the delay model reads lightest against the netlist; `g6lc_rename`
2.55, `g6lc_iq` 2.56 and `multiplier` 2.9 are where it tracks. Ideal-input,
unplaced module paths: upper bounds on logic speed, not sign-off.

**Where it lives.** `crates/sv-timing-core/src/adjusted.rs` (schema
`adjusted-fo4.v1`, four unit tests), CLI `adjusted`; host
`build-platform/src/tooling/fo4Probe.ts`, `openroadPlatforms.ts`
(platforms auto-detected from the fork's `test/<p>/<p>.vars`: liberty,
extra liberties, LEFs, site, tracks, RC; `yosysMappable` vs `staReadable`),
`timings platforms | fo4-probe | adjusted`, and the `s3-adjusted-fo4` stage
of the remote route. The Tcl is mirrored into the fork at
`tools/openroad/g6lc/` beside the platforms it reads; a host test pins the
mirror byte-identical to the canonical `build-platform/scripts/` copies.

## A120 — Preserve predecoded choices and move late count inputs off adders

Three production candidates retain existing ports, reset behavior and cycle
latency: IQ precomputes all legal count decrements before selecting with the
late issue/ack popcount; rename reuses one-hot free-register masks for
free/busy/checkpoint updates while retaining binary architectural tags; store
compaction gathers payload with AND/OR selection and explicitly preserves
the old invalid-slot payload on an empty match.

The IQ identity is modular:
`(count - cancelled - issued + allocated) == (count - cancelled + allocated) - issued`.
`issued` is a popcount of P bits, so the candidate bank covers 0..P, including
non-prefix acknowledgments. The base is combinational, not a newly inserted
pipeline register; timing remains a measured question.

Rename's bit-mask update requires tag widths that represent the pool. The
first proof attempts exposed a harness error: `FPRF_ENTRIES=40` retained the
module's disabled-FP default `FPRF_W=1`. That configuration truncates chosen
indices and is not a valid FP allocation configuration. A120 explicitly sets
both tag widths for 40/80-entry, one/two-hart and two/three-port proofs and
adds a local legality guard. The earlier A118 matched-state result must not
be cited as coverage of correctly sized FP allocation. Hiding all internal
proof correspondences then exhausted the two-hart budget; the retained proof
uses normal matching with valid dimensions.

**Generic typed offset correction.** `SelectIncrement` supports `REG-step`
as well as `REG+step`. Each candidate substitutes `type(step)'(K'(j))`
into the original RHS; widening/narrowing casts and mixed signedness survive.
Small signed selectors index through `$unsigned(step)`, so negative bit
patterns do not become negative array indices. Subtraction is not commuted.
Unknown result widths, unresolved masks/indices, unsupported tokens and
overwritten procedural selectors are refused.

The standalone `select_offsets.sv` fixture exercises signed negative steps,
mixed signedness and explicit truncation. Its actual emitted SV passes
matched-state equivalence. With the area gate explicitly disabled for this
feature test, mapped worst-any is 0.456→0.439 ns and area 213.066→329.308 µm².
That small gain costs 54.6% more area: it supports preserving the default
area gate, not universally enabling candidate banks.

**Measurement and cache safety.** The gather exposed compound assignments
being parsed as malformed LHS names (`acc |`) without their read dependency.
`delay-v41` normalizes them for measurement and records `BlockingCompound`
in IR v2. Automatic correction refuses paths containing compound updates;
emission refuses to treat them as plain `=`. `correction-v1` separately
versions opportunity/emission semantics. Module cache identities now include
the lowering context as well as file hashes, preventing reuse of a module
whose generate branches were pruned using different parameter facts.

**Placement decides retention.** The three trials were mapped with the same
map-v2 recipe, then independently placed/repaired with identical constraints,
900×900 µm die and no disabled timing arcs. All six placed variants have
zero reported electrical violations:

| Trial | Worst placed arrival before → after (ns) | Repaired area before → after (µm²) | Decision |
|---|---:|---:|---|
| IQ decrement bank | 2.806 → 2.958 | 194,951.125 → 188,339.172 | Rejected: saves area but worsens the timing objective |
| Rename mask reuse | 3.375 → 2.964 | 243,366.062 → 241,050.000 | Retained: −12.2% delay and −0.95% area |
| Store parallel gather | 4.125 → 4.474 | 75,096.055 → 69,820.211 | Rejected: area saving does not justify the critical-path regression |

The IQ and store trials remain in the immutable `precompute-a120c` input
archive and measurement outputs; production keeps their A119/A118 logic.
Rename repair buffers are 16,200→16,250; WNS is −3.223→−2.803 ns at
250 ps with 50 ps uncertainty. This is a pre-CTS, unrouted module
comparison, not whole-core closure.

**Oracle corrections.** The store-buffer side-by-side harness was stale:
it randomized the committing TID, checked assumptions after state changed,
used next-state `ready_o` as current capacity, and assumed depth four.
It now obeys the reference's clocked input assertions, drives legal CBO
metadata, sizes its TID/queue tracking from configuration, and requires full
occupancy coverage. With the trial source it passes 400,000 cycles,
210,505 pushes, 84,775 commits, 77,838 cancel cycles and 9,275 flushes,
zero mismatches, reaching the actual depth eight. Core assertions stay on.

**Debug logic is not a timing optimization.** delay-v41 exposes a 170.413
FO4 path through `scoreboard.sb_issued_popcnt`. Its only consumer is the
simulation assertion; synthesis had already removed it. The reference
calculation is now in the same `translate_off` scope as that assertion,
separate from functional capacity logic. This repairs its coding/measurement
boundary and must not be reported as a physical speedup.

Evidence: `build-platform/workspace/build/sv-timing/precompute-a120c/`
(`result-d`, `placed-iq`, `placed-rename`, `placed-store`, `store-test-d`);
typed-emission proof in `precompute-a120/offset-proof`.

The retained source was elaborated again into a fresh width map
(`retained-a120/result/`, elaboration-only widths). Under IR v2 /
delay-v41 / correction-v1 its maximum is 55.078 FO4 (IQ); scoreboard is
19.634 FO4 after the simulation-only calculation is fenced. The fresh
latency-neutral review emit has 587 records, complete joint integrity and
a 55.664-FO4 maximum, with 720/1591 reg→reg paths over budget. Neither
source nor emit closes 10 FO4. The placed numbers above refer to the
production trial snapshots, not to this review emit.
The retained emitted tree also passes full-core slang elaboration and
hierarchy checking (`retained-a120/emitted-check/`, 31 seconds).

Validation: 352 Rust tests, the target lint gate, and all five TypeScript
connection tests pass. The client now exposes `realCutFeeds` explicitly;
the old dry-run connection test requested pipeline edits without enabling
structural planning. Package independence scanning has the previously
recorded failures in unchanged host-name references; it is not reported green.

## A119 — Parallel issue grants, stable LSQ tournaments, and generate reachability

The 10-FO4 objective remains unchanged. This round replaces serial control
dependencies inside IQ and LSQ without new ports, state or latency:

* **IQ rank-zero/rank-one:** each entry reduces its older-ready vector to
  `(any, many)`, where `many` means at least two. The associative combine is
  `(a.any|b.any, a.many|b.many|(a.any&b.any))`. Root predicates `!any` and
  `any&&!many` select the first two ready instructions independently; the
  second grant no longer waits for first-grant removal. Later ports use the
  original cascade. The existing strict-total-age-order and one-hot
  assertions remain the contract; acknowledgments remain removal-only.
* **LSQ stable tournaments:** fully covering store candidates compete by
  maximum circular distance (youngest older store); violation candidates
  compete by minimum distance (oldest replay). Balanced trees preserve
  earliest-slot ties with strict comparisons and left preference. Empty
  masks remain empty; the original 32-bit minimum sentinel is preserved.
  Eligibility, hart isolation, byte overlap, address-update priority and
  stall behavior are unchanged. Only winner reduction and selection move.

These are source implementations, not yet generic sv-timing transform kinds.
A future `StableSelect` detector must prove that the scan only accumulates a
winner, identify its strict/non-strict tie policy, preserve default outputs,
and reject loops with other side effects. A future `SaturatingRank` rewrite
must retain the age-order invariant and all remaining-port behavior.

**Evidence strategy.** The isolated selection profile of
`verif/regress/remote/run_fo4_control_review.py` extracts the production
trees. SAT proves the IQ against the preceding cascade at small depths,
including three ports; at 24 entries it proves the zero/one-older-ready
specification for arbitrary matrices. The original 24-entry cascade miter
exhausted its 600-second budget and is inconclusive. That timeout is not
substituted with a claim of whole-module equivalence. LSQ min/max trees are
checked at 1/3/8/16 entries with unconstrained keys, ties and masks. Existing
IQ store-order and LSQ hart-isolation leaf checks pass with negative controls
on stock Verilator. Paired mapping uses the same recipe and library.

**delay-v40: generate reachability.** The A118 72-FO4 multiplier maximum
included a fallback branch that slang did not instantiate. Lowering now
excludes known-inactive if-generate ranges before constructing regions,
loops and instances; fallback discovery cannot resurrect them. The evaluator
uses exact host keys or unique visible `localparam int` definitions, with
bounded nonnegative int32 arithmetic. Parameter defaults, width-truncating
locals, unknown values, overflow, shadowed names and unresolved scope origins
do not authorize exclusion. Unknown branches remain measured. This changes
measurement and planning scope; it is not a hardware improvement.

**Same-source measurement control:** the frozen A118 source and width map
report 72.0 FO4 under delay-v39 and 55.078 FO4 under delay-v40. The
multiplier's maximum falls 72 → 50 when the dead fallback is excluded;
IQ becomes the reported maximum. There was no RTL or mapping change in
that comparison.

**A119 hardware comparison under delay-v40:** source maximum remains
55.078 FO4; LSQ's maximum falls 50.751 → 42.5. With identical map-v2
options, IQ's filtered delay falls 2.922 → 2.403 ns at area
173,701.458 → 180,062.050 µm². LSQ worst-any falls 3.141 → 1.958 ns
at area 33,931.758 → 34,423.326 µm²; its reg→reg path becomes the
new local bottleneck at 1.820 ns (formerly 1.501).

Uncut IQ worst-any rises 31.987 → 37.850 ns, despite reg→reg falling
31.756 → 30.878. Uncut LSQ worst-any falls 8.607 → 6.202. Therefore
the IQ candidate needs a buffering/placement discriminator. The host
`openroad-module-place-study.tcl` uses the same 900×900 µm die, 880×880
µm core, pin layers, density 0.40, 250 ps clock and 50 ps uncertainty
for both variants. It places, estimates RC, repairs electrical violations
and legalizes without disabling fanout drivers. This is a pre-CTS,
unrouted module study, not whole-core sign-off.

**Placed IQ discriminator completed.** With 10% slew/capacitance repair
margin before legalization, both variants finish with zero reported
electrical violations and no disabled timing arcs:

| IQ metric | A118 baseline | A119 parallel ranks |
|---|---:|---:|
| Worst data arrival, any path (ns) | 3.606 | 2.806 |
| Worst reg→reg arrival (ns) | 3.144 | 2.525 |
| Cell area after repair (µm²) | 189,319.922 | 194,951.125 |
| Repair buffers inserted | 15,174 | 15,095 |
| WNS at 250 ps / 50 ps uncertainty (ns) | −3.443671 | −2.641909 |

The candidate buys 22.2% lower worst delay at +3.0% area, with 79 fewer
repair buffers. This supports retaining the parallel grants despite the
uncut, unplaced regression. It still misses the target and does not include
CTS or routing. The zero-margin trial is retained separately: it left
13/9 post-legalization electrical violations. The first script trial also
exposed a host-script lifetime defect: PathEnd objects from one timing
search were retained across another search/report. GDB localized the stale
handle access; extracting numerical arrivals immediately fixes the script
without changing OpenSTA.

Evidence directory: `build-platform/workspace/build/sv-timing/selection-a119/`
(`result-b/`, `leaf/`, `placed-margin/`, `emitted-check/`).
The fresh -O3 latency-neutral review emit has 623 records, passes joint
integrity and full-core slang elaboration, and remains at 55.664 FO4
(704/1594 reg→reg paths over budget). No automatic register cuts were
enabled or credited. Mapped/placed numbers above refer to the production
source snapshots, not that review emit.

Validation: 348 Rust tests and the target lint gate pass. The package
independence scanner still flags pre-existing host-name references in
unchanged files (`expr.rs`, `param_map.rs`, `relocation.rs`, `width.rs`,
emit fixtures and host soak tools). No new host dependency was introduced;
that separate scanner failure is not a passing independence gate.

## A118 — Remove serial control dependencies before adding pipeline cycles

The target remains 10 FO4; neither a change of measurement version nor a
cell-count correlation establishes closure. The eleven-module contract audit
is in `architecture/CONTROL-CONE-CLOSURE.md`. This round changes internal
expressions and uses the existing multiplier latency configuration; it adds
no caller ports or global configuration fields.

| Candidate | Exact relation and applicability | Implementation |
|---|---|---|
| Circular order | After masking all operands, circular order consists of `[cp, 2^w)` followed by `[0, cp)`. Equal sides compare `a<b`; different sides select the side containing `b`. Masks must precede the comparison. | `g6lc_ooo_pkg::ooo_age_older`; shared IQ/LSQ/ROB/store consumers |
| Compaction predecessor | Existing entries keep index order. Only comparisons involving the arriving last entry depend on the insertion rank. Keep the original rank, compute predecessors directly, then count kept predecessors. | `store_buffer::spec_rewrite` |
| Busy-table bypass | Before writeback/free/recovery, `busy_d` equals `busy_q` with older ports' allocations set. A read is `busy_q[tag] OR any(older allocation == tag)`. This also holds for aliasing maps; preserve integer x0 and FP physical zero. | `g6lc_rename` readiness |
| Equality | For equal-width bitvectors, subtraction is zero iff the operands are equal. EQ/NE use equality directly while arithmetic results retain their adder. | `alu::branch_resolve` |
| Late-select arithmetic | `base+off+(sel?c:b)` equals `sel?(base+off+c):(base+off+b)` modulo the result width. Duplicated arithmetic can trade area for removing the late control input from the add path. | frontend direct-target candidate |

These are production-source candidates with explicit proofs, **not new
generic automatic passes**. To generalize them into sv-timing, the detector
must establish the mask/width and truncation context, vector write order,
scope, and lack of side effects before authorizing emission. The existing
LoopRewrite/SelectIncrement/BalanceMux ordering and area ledger do not by
themselves prove those conditions. In particular, a zero area estimate for
an unmeasured rewrite must not stand for measured area neutrality.

Minimal discriminators are implemented in
`verif/regress/remote/run_fo4_control_review.py`: SAT on the actual age helper,
SAT on extracted old/new compaction-control code, subtraction-zero and
selected-target identities, and matched-state rename equivalence with FP
enabled for one and two harts. The runner captures source hashes, elaborates
the complete `g6lc64_ooo` hierarchy, then maps the requested modules with
identical recipe and liberty in isolated output directories. A run does not
overwrite the shared builder checkout or its mapping cache.

### Multiplier lifetime is part of the pipeline boundary

The earlier A115 text relied on the scoreboard's current `issued` bit to
reject late results. That does not establish allocation-generation identity
after TID reuse. For `MultStages>1`, `mult.sv` now carries a small live/TID
pipeline alongside the existing arithmetic pipeline. Flush clears it;
cancellation kills the corresponding entry permanently as it advances.
Current-cycle cancellation also masks output before multiply/divide
arbitration. A new use of the same TID cannot revive the killed result.

`tb_mul_lifetime` checks back-to-back results, flush, cancellation at entry
and in flight, mask removal and TID reuse. The preceding wrapper fails on a
result emitted during flush; the new wrapper passes that directed witness.
This qualifies the stated boundary cases, not all OoO firmware behavior.
The first installed A-fork simulator failed the test's input-drive check;
the semantic witness uses stock Verilator 5.008 and retains the negative
RTL control. No hardware change was made to accommodate that simulator.

### Report identity

The host previously joined a `--fo4 0` live mapping with a leftover
`svt/correct.json` from an emitted design. `SvtPrepass.reportPath` now names
only the report paired with the package actually mapped. Live mapping has
no such report and produces missing structural columns rather than stale
FO4/feedback ratios. Fresh live structural analysis is a separate artifact.

### Paired results (map-v2, Nangate45, g6lc64_ooo)

Evidence: `build-platform/workspace/build/sv-timing/control-cones-a118-final/result/`.
`sources.json` and `result.json` retain identities, recipe, proof results,
module areas and both board modes. The table's ns columns are the worst
module path of any kind with the historical fanout-64 filter; FO4 is the
fresh **source** analyzer's worst single-cycle path of any kind. The
source FO4 values shown are unchanged between the paired snapshots.

| Module | Structural FO4 | Study ns before → after | Area change | Interpretation |
|---|---:|---:|---:|---|
| g6lc_rename | 49.3 | 3.499 → 3.232 | +0.42% | Reg→reg improves 3.499 → 2.725 ns, 32 → 29 cells; the remaining worst is a boundary path |
| store_buffer | 24.0 | 3.524 → 3.277 | −2.28% | Reg→reg improves 3.302 → 2.455 ns, 34 cells both |
| frontend | 47.0 | 3.344 → 2.744 | +11.54% | Early target alternatives trade duplicated arithmetic for later control selection |
| g6lc_iq | 55.1 | 2.690 → 2.922 | −3.94% | Shared age change saves area but worsens this filtered path; do not call it a uniform timing win |
| multiplier | 72.0 | 2.441 → 2.441 | 0% | Datapath unchanged; structural maximum is an unpruned constant-generate fallback |
| g6lc_lsq | 50.8 | 1.777 → 3.141 | +1.96% | Reg→reg improves 1.722 → 1.501; boundary timing worsens and remains a follow-up |
| scoreboard | 19.6 | 2.245 → 2.245 | 0% | No RTL edit this aggregate |
| instr_realign | 32.1 | 2.547 → 2.547 | 0% | Existing prefix implementation retained |
| wt_dcache_wbuffer | 18.6 | 2.476 → 2.203 | −2.71% | No RTL edit; mapping variation after upstream changes, not credit to a new wbuffer algorithm |
| issue_read_operands | 12.5 | 1.757 → 1.717 | +0.70% | No RTL edit; mapping variation, not a new operand pipeline |
| primary alu | 31.2 | 2.160 → 1.936 | +0.31% | EQ/NE use direct equality; branchless secondary ALU is unchanged |

The sum of these specialized modules plus `mult` is 945,166.096 →
938,935.312 µm² (−0.66%); this is **not whole-chip area**. The wrapper's
lifetime guard adds 148.960 µm². The largest filtered module delay is
3.524 → 3.277 ns, still far outside 200 ps.

The uncut graph gives a less favorable and necessary counterpoint:
frontend 5.734 → 6.292 ns, IQ 49.482 → 31.987 ns, rename 77.140 →
64.854 ns, store buffer 92.929 → 86.288 ns, and unedited wbuffer
89.232 → 98.747 ns. These are unbuffered, unplaced nets. This round does
**not** establish a whole-design timing improvement or physical closure;
buffering/placement and the boundary regressions must be assessed next.

Fresh delay-v39 source closure is **72.0 FO4 before and after**, with
695/1634 reg→reg paths over budget. The recorded worst is the multiplier's
`gen_sum_n` fallback, which is uninstantiated for `NS=4`; see the lowering
limitation in `CONTROL-CONE-CLOSURE.md`. That does not license ignoring
other real failing paths. The old 55 FO4 and emitted-tree numbers describe
different source/measurement scopes.

The same snapshot was regenerated with `correct -O3 --emit --real-cut-feeds`,
fresh elaborated widths and **without `--allow-latency`**. Its 632 records
are 342 BalanceMux, 58 SplitAssign, 3 RebalanceAssoc, 1 LoopRewrite and
228 annotations; no InsertReg. Joint reparse and structural integrity
passed, emitted re-analysis remains 72 FO4 with 714 failing reg→reg paths.
The generated tree also passed whole-core slang elaboration and hierarchy
checking (`control-cones-a118-final/emitted-check/`, 31 seconds).
The generated package is `result/review-corrected/svt_corrected.f`; it is
review output, not whole-package functional-equivalence evidence. The
mapped table above belongs to the production-source snapshot, not this emit.

Stock-Verilator revalidation also passed 300,000 arithmetic comparison
cycles (234,215 valid results, zero mismatches), alongside the 15 directed
multiplier lifetime checks and the failing preceding-wrapper control.

## A115 — The two-stage multiplier (`CVA6Cfg.MultStages`)

A113's calibration put the design's worst physical path where no reg→reg
ranking had looked: the multiplier's (XLEN+1)×(XLEN+1) product, 5.34 ns
in→reg on the Nangate45 study against 3.8 ns for the next cone. The
original comment says "relies on retiming features of the synthesizer";
the study flow has none, and neither does a flow that wants a verifiable
RTL. With `MultStages = 2` the B operand is cut into XLEN/16 slices (16
unsigned bits each, the top one 17 bits carrying the sign); the XLEN/16
partial products A × B_k are registered; the second stage sums the shifted
products once, as a balanced tree. `Σ_k (A × B_k) << 16k == A × B` for
every signedness the operation selects (the sign bits live in the
(XLEN+1)-bit operands), so the split is exact; the carry-less results take
the same two stages so the operator select sees them together. One more
cycle of MUL latency; nothing else in the contract moves — the result
travels with its trans_id, `mult.sv` arbitrates on the valid, and a late
result after a flush is dropped by the scoreboard's `issued` guard as it
is today for memory operations. Config-gated (user + derived field;
`check_cfg`: `{1,2}`, `XLEN % 16 == 0`); every target package keeps the
one-register multiplier except `g6lc64_ooo`. Whole core elaborates;
side-by-side harness `verif/tb/core/multiplier_sbs` (the two builds of the
same source, every MUL/CLMUL op, corner operands): 3 seeds × 300 k cycles,
≈ 234 k valid results per seed, 0 mismatches. **Netlist (module board):
multiplier 5.34 ns in→reg (live) / 3.12–3.36 (emitted, with a cut) → 1.95
ns any-kind, 1.54 ns / 37 cells reg→reg** — the design's worst physical
path is no longer the multiplier.

## A116 — The branch target as a narrow sum

The frontend's worst cone (3.25 ns / 38 cells) is the 64-bit three-operand
target sum behind the slot select. `base + off + imm` only ever adds a
small signed step to the block base — `off < FETCH_WIDTH/8`, `imm` at most
21 bits — so the sum is `{base_hi + {+1, 0, −1}, lo}`: one 24-bit add gives
`lo` and its carry, the high part is the base's high part, its increment or
its decrement, selected by (carry, sign of the step); the two incrementers
run from the registered base in parallel with the low add. SAT-proved equal
to the three-operand sum for every base, offset and immediate shape (jal
21-bit, branch 13-bit, rvc 12-bit, the link step 2/4) at VLEN 64 and 32.
Same cycle, no state; the slot's `ras_update` link address used the same
form. Whole core elaborated. **Measured worse and reverted**: frontend
3.25 ns / 38 cells → 4.05 ns / 49 cells on the module board. The reason is
instructive: under the delay-oriented script a 64-bit three-operand add is
one CSA level plus a *prefix* adder (≈ 8 levels), while the narrow form as
written was two serial 24-bit adds (`off + imm`, then `base_lo + step`)
plus the select — deeper, not shallower. A three-operand narrow add would
save two or three levels at most: the 64-bit carry chain was never the
log-depth adder's cost. Recorded so the "NarrowAdd" idea is not tried
again without the board; the multiplier's A115 result in the same run
stands (below).

## A114 — Area selectivity: Dial 11, the trade-off ledger, and the measured feedback loop

**What the width map did and did not tune.** The elaborated width map
(A102/A113) enters the plan in two ways only: it scales every operator's
cost by its real width (so a 5-bit counter is not a 32-bit one) and it
names the instantiated modules. It did **not** choose or order
transformations. The order was fixed: the latency-neutral kinds first
(LoopRewrite, SelectIncrement, BalanceMux, RebalanceAssoc, SplitAssign —
the planner's worklist by slack, `min_gain` the only filter), then
InsertReg under `--allow-latency` with the per-module cap. Dial 7
(`area_weight`, "penalty per added flop") was declared in every preset and
read by nothing; no edit carried an area estimate; and the OpenSTA numbers
of A113's calibration were reported, never consumed. Area was controlled
only by the *kind order* — which is the right first-order policy (A102
measured the latency-neutral kinds area-neutral or negative and every
module ≥ +5 % area carrying InsertReg) — but it had no second order: a
64-flop cut that buys 2 FO4 and a 1-flop cut that buys 12 were treated
alike.

**Dial 11 — `max_cells_per_fo4`.** Each gated edit now carries a
preliminary cell estimate and the structural FO4 it removes:

| kind | est_cells | fo4_gain |
|---|---|---|
| InsertReg (one stage) | width of the cut net (one flop per bit) | the shorter of the two segments the stage separates |
| SelectIncrement | `(2·2^k − 1) × width` (candidate adders + the select) | `fo4_before − fo4_after` of the node |
| BalanceMux, RebalanceAssoc, SplitAssign, LoopRewrite | 0 (area-neutral or negative by A101/A102) | — |

An edit is refused when `est_cells / fo4_gain` exceeds the limit (presets
16 at -O1…-O3, 8 at -Os, 4 at -Oz; `--opt-max-cells-per-fo4 0` disables
it). A refusal is a worklist verdict (`area_gate`), not an abort: the plan
moves to the next candidate. At 16, a 64-bit cut must buy ≥ 4 FO4 of
depth, a 32-bit SelectIncrement with 4 candidates (224 cells) ≥ 14, and a
1-bit control cut is always admitted. The fixture's 5-bit step (32
candidates, 1 008 cells) is above the default on purpose — it is the
shape A102's `instr_queue` paid for with 1.14 → 1.60 ns.

**The feedback loop.** `--feedback calibration.tsv` (or JSON
`{module: ratio}`) loads the **measured** cells per structural FO4 per
module from the previous gate-level run (A113's `s3-calibration`) and
scales the limit per module by `ratio / 1.3`, clamped to ¼ … 4×: where a
structural FO4 is worth more mapped cells (an under-read cone such as the
store buffer at 1.6) the gain is real and larger and more area is
admitted; where the model over-reads (perf_counters at 0.4) the same cut
must buy more. The host passes the previous run's `calibration.tsv`
automatically, so the OpenSTA numbers of run *n* select the edits of run
*n+1* — preliminary estimates first, measured ratios second.

**The ledger.** Every gated edit, applied or refused — module, origin
line, kind, est_cells, fo4_gain, cells/FO4, the limit in force, the
verdict — is in `correct.json` (`tradeoffs[]`, `area_gate{}`,
`edits[*].est_cells / fo4_gain / cells_per_fo4`), summarised on one line
(`area gate: max 16.0 cells/FO4; applied N (+M est. cells), refused K
(would add L cells for G FO4)`), and listed by `sv-timing correct
--tradeoffs N` / `timings sta-rtl --tradeoffs N`, largest preliminary cell
estimate first — the place to read what the plan bought, what it refused,
and which refusals are worth moving the dial or the design for.

**How to regenerate toward budget at lower area.** Run the route; read the
ledger's refused rows (the depth left on the table, with its cell price)
and the applied rows with the highest est_cells (what the depth cost);
move Dial 11 per run (or per module, through the feedback file's ratio)
and compare `SYNTH_STREAM_AREA total` and the module board between runs
— the two numbers the route already prints.

### First gated run (route of record, feedback from the previous run's calibration)

`feedback: 50 module cells/FO4 ratios`; `area gate: max 16.0 cells/FO4
(scaled per module); applied 60 gated edits (+645 est. cells), refused 10
(would add 1 137 cells)`. The ledger's head:

| verdict | kind | module : line | est_cells | fo4_gain | cells/FO4 | limit |
|---|---|---|---:|---:|---:|---:|
| refused | InsertReg | lsu_bypass : 142 | 385 | 7.5 | 51.3 | 11.7 |
| refused | SelectIncrement | instr_queue : 281 | 240 | 3.0 | 80.0 | 9.7 |
| applied | InsertReg | multiplier : 61 | 64 | 4.5 | 14.2 | 63.3 (under-read module, 4× band) |
| applied | InsertReg ×3 | g6lc_loop_buffer : 79 | 64 each | 6.8–7.8 | 8.2–9.4 | 11.0 |
| applied | InsertReg | frontend : 744 | 64 | 5.5 | 11.6 | 15.9 |
| refused | InsertReg ×6 | cva6 : 70–1342 | 64 each | 3.5–9.5 | 6.7–18.3 | 4.0 (over-read module, ¼ band) |
| refused / applied | InsertReg | instr_queue : 85 | 64 | 2.5–9.0 | 7.1–25.6 | 9.7 (the 2.5 and 5.0 FO4 stages refused, the 7.5–9.0 ones kept) |

Against the ungated run of the same tree: **total mapped area 1 929 421 →
1 927 537 µm² (−0.10 %)**, the module board's worst paths unchanged or
better (rename 3.77, store_buffer 3.60, frontend 3.25, iq 3.18 ns as
before; **multiplier 3.36 → 3.12** from the admitted cut; **instr_queue
1.22 → 1.14 ns** with the 240-cell SelectIncrement refused — the A102
regression, now a ledger row instead of a surprise; lsu_bypass's refused
385-flop cut was buying 7.5 structural FO4 on a 9-cell path). The gate's
first effect is the expected one: the area it declines is area that bought
no mapped depth. Dial 11 is the knob; the ledger is where to read what the
next turn of it would buy or cost.

## A113 — The route plans, verdicts and calibrates the live design

Auditing what the integrated route actually ran (the command line and
`correct.log` of the A105 emitted run) found the configuration right — 10.0
FO4 = 250 ps / 20 ps × (1 − 0.2), `-O3` with 13 stages, `--allow-latency`,
`--real-cut-feeds --assume-clk`, the 222-field cfg snapshot — and three
mechanisms wrong, each of which made the headline the wrong number or the
emitted tree the wrong tree:

1. **The width map arrived one run late.** The map was written by the
   streamed mapping's phase A, *after* the pre-pass, so every run that
   followed an RTL edit planned (and emitted) on heuristic widths; the
   fresh map served only the next run on an unchanged tree, and the
   freshness guard (A102) could only refuse the stale one. The remote route
   now runs phase A of the live tree first (`s0-width-map`, own run dir,
   ≈ 6 min) and pulls the map before the pre-pass; the pre-pass stage says
   which widths it planned on.
2. **Dead modules decided the plan and the headline.** The file list carries
   every module a family of configs can use; `correct --all-modules` planned
   all 234 and its `post_closure` / `max_path_fo4` were `g6lc_ai_exec`'s
   280.5 FO4 — a module `g6lc64_ooo` does not instantiate. The width map
   names the instantiated set (`frequency_closure.uninstantiated_modules`,
   A89); `correct` now plans only those (`--include-uninstantiated` to
   restore), prints the live count and the dead modules' worst separately,
   and the host's completion gate reads the emitted re-analysis over the
   live modules (a dead cone cannot miss the budget, its worst is reported
   beside the verdict).
3. **A misleading log line.** `emit richer: … emit_balance_mux_rtl=false`
   printed the raw flag while `--real-cut-feeds` implies the structural
   emit; it prints the effective value now.

And one mechanism missing: the structural ↔ mapped comparison that every
A-record since A100 was built by hand is now a stage. `s3-calibration` runs
the per-module board after the STA and joins it with the pre-pass's emitted
re-analysis into `calibration.tsv` — structural worst reg→reg FO4 per live
module, mapped ns and cells, `cells_per_fo4`, and a reading (`tracks` at
0.6–2.0 cells/FO4, `over-read`, `under-read`; cones under 8 cells are not
classified). The model is validated against OpenSTA on every run, and the
reading column is the model's own worklist (the dense-cone class, the
function class and parameter-dead code are the over-reads; dynamic
struct-array demuxes the under-reads, A103–A107).

### The first run of the corrected route

`timings sta-rtl --target g6lc64_ooo --platform nangate45 --fo4 10
--allow-over-budget --remote --map-recipe streamed`, current tree:

| stage | result |
|---|---|
| s0-width-map | elaborated net widths of this tree (327 s, 3.7 GiB; 108 live modules) |
| s0-svt-correct | `live modules=108 uninstantiated=126 (skipped)`; 690 edits; integrity passes after one emitter fix the elaborated widths exposed (comma-list `assign a = x, b = y;` — one statement per line now); verdict `STUDY: worst live primary 416.0 FO4, 1182 live paths exceed 10 (126 uninstantiated modules excluded, their worst 280.5)` |
| s1-yosys-map | 348 s, 3.7 GiB, every module under the delay-oriented script |
| s2-openroad-sta | whole-core STA (unbuffered fanout `wns`, as before) |
| s3-calibration | 69 modules; of the 28 reg→reg cones ≥ 8 cells **22 track** (0.6–2.0 cells/FO4), 4 over-read (iq's dense class 0.45, perf_counters 0.40, lsq 0.43, ptw 0.55), 2 under-read |

Two findings from the first `calibration.tsv`:

- **The design's worst physical path is the multiplier, and no reg→reg
  ranking could show it.** `multiplier`'s 65×65 product runs from its
  ports (the issue stage's operand registers, in the flat core) into
  `mult_result_q`: 5.34 ns on Nangate45 — above the frontend's 4.35 — but
  it is an in→reg path of the module, so the per-module reg→reg board
  listed it as `-`. The calibration now leads with the worst mapped path
  of **any** kind per module (`worst_any_ns`) and labels boundary-dominated
  modules; the pipelined multiplier joins the A107 list of single-cycle
  contracts (one more cycle of MUL latency).
- **The structural model over-read that multiplier 8×.** `Mul` scaled
  linearly with width (56 × 130/32 = 227 FO4; 416 on the path), so the
  live headline was the multiplier at 416 against a mapped depth ≈ 1.2× the
  frontend's. A tree multiplier is a CSA tree of depth ~log w and one
  adder: **delay-v39** scales `Mul` like `AddSub` (log₂ w / log₂ 32; the
  iterative divider keeps the linear law). The remaining 416 was the
  carry-less multiply's loop, `clmul_d = b[i] ? clmul_d ^ (a << i) :
  clmul_d` — a guarded XOR accumulate written as a select, billed as 64
  mux copies; `c ? x ^ t : x` is `x ^ (t & {c})`, an XOR tree, and
  delay-v39 recognises the select form in both the IR carry and the
  function-body scan (log₂ 64 = 6 copies).

### The live board under delay-v39 (fresh width map), against the mapped board

| structural FO4 (kind) | module | mapped ns (reg→reg / any) | cells | reading |
|---:|---|---|---:|---|
| 55.1 reg→reg | g6lc_iq | 3.16 / 3.18 | 25 | dense-cone class still ≈ 2× (the one remaining artefact in the top) |
| 50.8 reg→out | g6lc_lsq | 1.92 / 3.10 | 14 | boundary path; tracks on `any` |
| 50.0 in→reg | multiplier | 1.08 / 3.36 | 18 | **was 416**; tracks on `any` |
| 49.3 reg→out | g6lc_rename | 3.77 / 3.77 | 25 | tracks |
| 47.0 reg→reg | frontend | 3.15 / 3.25 | 38 | tracks (the 64-bit target sum) |
| 41.3 in→reg | fpnew_cast_multi | — | — | not on the board (black-boxed cast) |
| 37.2 reg→reg | g6lc_thread_select | — | 1 | parameter-dead at one hart (model) |
| 34.7 reg→reg | perf_counters | 1.05 / 1.07 | 14 | over-read (model) |
| 32.1 reg→out | instr_realign | 2.31 / 2.38 | 15 | tracks |
| 31.2 in→out | alu | — / 2.25 | — | the 64-bit ALU, combinational module |
| 24.0 in→out | store_buffer | 3.32 / 3.60 | 38 | under-read (the one permutation + gather) |

Across the five largest real cones the two boards agree on the ranking
and on the scale (≈ 0.07 ns of Nangate45 per structural FO4; 10 FO4 ≈
0.7 ns here): the structural metric is now an instrument that can be
read beside the netlist, with three named artefacts left (the dense-cone
class, parameter-dead code, the perf-counter select) and one named
under-read (the store buffer's permutation). Live board: worst 55.1,
694 of 1 630 reg→reg over 10 FO4, 126 dead modules excluded.

Why the structural worst read "below 20" in October's first week and 55
now is not a regression of the design; it is the instrument learning to
see — delay-v35 (loop carry), v37 (guards and indexed writes: `g6lc_iq`
had no reg→reg path at all), v38 (function bodies, runtime index depth) —
while the comparable series, the netlist, went 54 → 38 cells. Measurement
versions are not comparable across each other; the banner's
`measurement=delay-vNN` and the calibration column travel with every number
from here on.

## A90 — Incrementers are not gates (delay-v32)

`x + 1` and `x + CONST` were billed 1 FO4 at every width since delay-v18
("folding the constant inserts no CPA"). A constant addend still leaves a
prefix-AND carry chain — structurally the comparator's: measured 16-bit
`x + 1` 0.281 ns against 16-bit `<` 0.296 ns (nf script). They are now billed
as Compare (4 at 32 bits, log2 width-scaled, context width when no relational
operand exists). The 64-bit counters in the core moved from 1 to 4.8 FO4.
