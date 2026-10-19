# Frequency closure (startpoint / endpoint)

Structural (not STA) frequency closure for the precompiler loop.

## Current objective and evidence rules (A118)

The objective is **10 FO4 at 20 ps/FO4**, margin 0.2: a 200 ps logic
budget under a 250 ps clock. The empirical 13-cell and 0.7 ns comparisons
in older records are not alternative closure thresholds.

The current source and boundary audit is
[`CONTROL-CONE-CLOSURE.md`](CONTROL-CONE-CLOSURE.md). Paired snapshots use
map-v2 (`booth`, `&syn2`) and record both the uncut OpenSTA timing graph and
the historical module study with fanout cuts. Children black-boxed in a
module board, unplaced nets, and disabled timing arcs cannot certify
whole-core closure. A successful OpenSTA process with negative WNS means
the analysis ran, not that timing passed.

Live mapping (`--fo4 0`) now leaves structural columns empty instead of
joining an older emitted report. Fresh structural numbers must be paired
with the exact live source snapshot and its elaborated widths.

**A119:** delay-v40 removes only proven-inactive if-generate branches.
On the same A118 source this corrects the maximum 72 → 55.078 FO4;
it is a measurement correction. The new IQ parallel grants and LSQ stable
tournaments leave the whole-design maximum at 55.078; LSQ's own maximum
falls 50.751 → 42.5. Paired module studies and the subsequent IQ
placement/buffering discriminator are recorded in ALGORITHMS-EXPERTS A119.
That discriminator supports the IQ candidate: 3.606→2.806 ns worst-any,
3.144→2.525 ns reg→reg at +3.0% repaired area, 79 fewer repair buffers,
and zero reported electrical violations for both variants. No timing arcs
were disabled. These pre-CTS, unrouted module results still have negative
WNS and cannot establish whole-core 10-FO4 closure.

**A120:** retain the rename one-hot write masks (placed 3.375→2.964 ns,
−0.95% repaired area). Reject the IQ count bank and store payload gather:
both save area but worsen placed timing. The package gains typed +/- offset
emission, compound-update measurement, and context-sensitive module caching
(IR v2, delay-v41, correction-v1). The assertion-only scoreboard reference
count is now fenced from synthesis/timing. Fresh retained-source maximum is
55.078 FO4; the latency-neutral review emit remains at 55.664 FO4. Details
and the rejected-candidate evidence are in ALGORITHMS-EXPERTS A120.

## Adjusted FO4 — the physical reading of the budget (A121)

The structural FO4 is a screening estimate over source operators. The
**adjusted FO4** is the same budget read on the mapped netlist in the
platform's own unit:

```text
platform_fo4_ps  = stage delay of the liberty's minimum inverter driving
                   four copies of itself (chain of 8 minus chain of 4, / 4)
adjusted_fo4     = mapped_ns · 1000 / platform_fo4_ps
closes(10)       = every measured module's adjusted_fo4 ≤ 10
f_mhz(fo4_ps)    = 1e6 · (1 − margin) / (max adjusted_fo4 · fo4_ps)
```

`f_mhz` inverts the budget formula: it is the frequency at which the budget
equals the worst measured path on any process characterised by `fo4_ps`. It
is a **pre-layout library projection** — ideal module inputs, no wires, no
clock uncertainty — so it bounds what the logic can reach, not what a design
closes at. Modules without a mapped row receive an *estimated* value from the
median adjusted/structural ratio and never decide closure.

Measured platform FO4 on the fork's test libraries (`timings fo4-probe --all
--remote`, OpenSTA on the builder, 2026-10-17):

| platform | corner liberty | inverter | FO4 (ps) |
|---|---|---|---:|
| asap7 | `AO_RVT_FF` + `INVBUF_RVT_TT` (gz) | `INVx1_ASAP7_75t_R` | 14.36 |
| nangate45 | `Nangate45_typ` | `INV_X1` | 21.40 |
| sky130hs | `sky130_fd_sc_hs__tt_025C_1v80` | `sky130_fd_sc_hs__inv_1` | 72.08 |
| sky130hd | `sky130_fd_sc_hd__tt_025C_1v80` | `sky130_fd_sc_hd__inv_1` | 80.91 |

Nangate45's 21.4 ps is within 7 % of the budget's assumed 20 ps, so on the
study platform a structural "10 FO4" and an adjusted "10 FO4" are the same
214 ps of logic. The two readings differ in *what* they count. Fresh full
route on the retained A120 tree (`timings sta-rtl --fo4 10 --remote
--map-recipe streamed`, 2026-10-17, corrected emit mapped; `adjusted-fo4.json`
is now written on every run):

| reading | value |
|---|---|
| structural worst live primary | 55.7 FO4 (1 209 live paths over 10; 126 uninstantiated modules excluded) |
| module board | 73 measured (8 linked modules folded to no path), 20 estimated |
| adjusted/structural ratio | median **2.91** (p25 1.77, p75 5.12) over 64 modules |
| worst measured | `g6lc_lsq` 3.766 ns = **176.0 adjusted FO4** (an in→reg boundary cone: its reg→reg path is 7 cells) |
| next | `g6lc_iq` 142.8, `frontend` 142.4, `store_buffer` 141.3, `multiplier` 131.8, `scoreboard` 127.9, `g6lc_rename` 125.9 |
| over budget | 56 of 73 measured modules |
| budget-equivalent | **212 MHz on nangate45, 227 MHz at fo4_ps = 20; 317 MHz on asap7, 63 MHz on sky130hs, 56 MHz on sky130hd** |

One structural FO4 of the delay model is about three inverter delays after
mapping, so the structural 55 FO4 maximum is ~165–176 adjusted FO4 and the
gap to the objective is ~17×, not 5.5×. The previous full board (before
A118–A120) read `store_buffer` 3.524 ns = 164.7 adjusted FO4 at a 3.05 median
ratio; `g6lc_rename` moved 3.499 → 2.693 ns and `store_buffer` 3.524 → 3.024
between the two boards, but both boards are of *corrected emits* with their
own cuts, so module-to-module deltas across them are not source deltas.

What a 10 adjusted-FO4 cycle means physically: ten inverter delays per
clock, including the flop overhead this reading excludes. No pipeline of
this depth reaches it by local rewrites; the honest levers are the
re-pipelining obligations listed in `CONTROL-CONE-CLOSURE.md`, and the
adjusted reading is what measures each one in cycle time rather than in
model credit. Quote `platform_fo4_ps` and the platform with every adjusted
number; a structural FO4 and an adjusted FO4 are not interchangeable.

Package: `sv-timing adjusted --board module-board.tsv --report correct.json
--platform-fo4-ps 21.4 [--budget-fo4 10 --budget-margin 0.2 --target-fo4-ps
20] --json-out adjusted-fo4.json` (`crates/sv-timing-core/src/adjusted.rs`,
schema `adjusted-fo4.v1`; the board is header-driven and host-agnostic).
Host: `timings platforms`, `timings fo4-probe`, `timings adjusted`, and the
`s3-adjusted-fo4` stage of `timings sta-rtl --remote --map-recipe streamed`.

### Structural toward adjusted (A146, delay-v43)

The A144 write buffer read **14.5 structural vs 137.1 adjusted FO4 (9.5×)**:
the next-state bundle billed a push → bypass-allocate → post-push supersede
chain as its widest single field, and the model priced no load. delay-v43
fixes the model, and a measured calibration maps it onto the platform unit:

* **Dependency floor.** The reference tree reads guards, keys dependencies
  by field (`q[*].be`), and knows branch exclusivity
  (`TimingModule::branch_arms`); its ASAP makespan is a floor under every
  path-class deflation. Short composed chains use it too.
* **Board-matching load** (`crates/sv-timing-core/src/load.rs`): a driver of
  `F` unit loads costs `0.35·(F−4)` FO4 up to the board's 64-load limit (above
  it the board drops the driver; a repaired tree costs log4 stages). Register
  outputs are launch *arrivals*, not latencies.
* **Compose and function costs.** A single-assign cone between flops is
  reg→reg (the multiplier's final add read in→out); field writes are capture
  sinks; function-body `case` tables and nested calls are billed (AES S-box).
* **Calibration** (`crates/sv-timing-core/src/calibration.rs`, schema
  `fo4-calibration.v1`): `sv-timing adjusted … --report analyze.json
  --calibration-out cal.json` fits `calibrated = slope·structural (+ launch
  for register-launched paths)` over the measured modules (median-ratio
  slope, launch ≤ 12 FO4, minimum median |log| residual).
  `analyze|correct --calibration cal.json` adds `calibrated_fo4` per path and
  `frequency_closure.calibrated`; a profile fitted under another `delay-vNN`
  is refused. Calibrated values are an estimate in platform FO4; measured
  rows still decide.

Same HEAD source as the A144 board, Nangate45 21.398 ps, 64 measured modules:

| reading | adjusted/structural median | sd(log) | Spearman | calibrated \|log\| median (IQR of cal/adj) |
|---|---:|---:|---:|---:|
| delay-v42 | 2.72 | 0.714 | 0.66 | 0.449 (0.65–1.61), slope 2.62 |
| **delay-v43** | **1.17** | **0.575** | **0.80** | **0.310 (0.82–1.38)**, slope 1.105, launch 4.25 |

`wt_dcache_wbuffer` now reads 160.6 structural (137.1 adjusted). Residuals
that remain and why: `id_stage` / `cva6_shared_tlb` over-read because the
board black-boxes child instances (decoder outputs, SRAM read data are not
startpoints there); `rename` / `lsq` / `iq` over-read where `int` / `32'()`
arithmetic and package helpers are billed at 32 bits; `ooo_dispatch` / `alu`
/ `loop_buffer` / `memdep` under-read wide table reads. The calibration is
fitted in-sample on one board; refit it per platform and per measurement
version.

## Historical campaign (2026-10-16, A104–A106)

Latest: with the structural board calibrated (delay-v38) the campaign
moved to the module board's own ranking and removed the serial
dependences the microarchitecture does not need — one-hot selects under
the design's assertions, counts as registered deltas (asserted
invariants), both allocation picks from one snapshot (lowest/highest),
dispatch freeing from the registered valid set, the three-operand branch
target sum, the store-buffer squash in StreamCompact form. Module board
worst (cells, Nangate45): **54 → 38**; rename 52 → 25, scoreboard 54 →
22, iq 47 → 38, frontend 43 → 34, rob 35 → 26 (A107), store_buffer 49 →
38 (A108/A109: verdicts travel with entries; insertion + squash as one
permutation), realign 23 → 15 (A110: the cursor walk as a boolean prefix),
iq 6.21 → 3.04 ns (A104–A112: one-hot select, count delta, dispatch from
the registered valid set, the cancel verdict registered after an ablation
showed the wake/select split worth ≈ 1 %), rob 35 → 23. Worst module delay
6.21 → 4.35 ns (the frontend's 64-bit target sum). OoO sim qualification of
A104–A112 is owed (harness built; DI suite queued behind the owner's runs). At ≈ 1.3 cells/FO4, 10 FO4 is ≈ 13 cells: not closed; the
residual is iq 38, store_buffer 38, frontend 34 (the 64-bit wall), then
the band at 22–27.
Structural live board: worst 55.1 (`g6lc_iq`, dense-cone class), 693 of
1626 reg→reg. Details: ALGORITHMS-EXPERTS A104–A106.

**Route of record (A113):** `timings sta-rtl … --fo4 10 --allow-over-budget
--remote --map-recipe streamed` refreshes the elaborated width map before
the pre-pass, plans and verdicts the instantiated modules only, maps,
runs the STA, then writes `calibration.tsv` (structural FO4 per module
beside mapped ns / cells, worst path of any kind first). First run under
it: 22 of 28 reg→reg cones ≥ 8 cells track at 0.6–2.0 cells/FO4; the
design's worst physical path is the multiplier's product (5.34 ns,
in→reg — invisible to a reg→reg ranking); delay-v39 made the structural
board agree with the mapped one on the top five (iq 55.1, lsq 50.8,
multiplier 50.0, rename 49.3, frontend 47.0 ↔ 3.2–3.8 ns).

## Earlier (2026-10-16, delay-v37, guards — the board sees the OoO cones)

Latest: the per-module mapped board (A100) calibrated the structural model
module by module and found it blind where the OoO depth is — `g6lc_iq` and
`g6lc_lsq` had no register-to-register path at all (0.0 FO4 against 47 and
13 mapped cells), `scoreboard`/`rename`/`store_buffer` read 3–5× fewer FO4
than cells — because the lowerer never represented the `if` an assignment
sits under nor the index of a dynamically indexed LHS. delay-v37 records
both as the node's guards (reads + a mux), with field-granular, index-aware
loop carry (A103). Live `g6lc64_ooo` at 10 FO4 / 20 ps:

| | worst reg→reg | failing primary / reg→reg |
|---|---|---|
| delay-v36 (blind) | 23.0 `frontend speculative_d` | 435 / 160 of 1377 |
| **delay-v37 (truth)** | **38.5 `store_buffer` cancel squash** | **1204 / 673 of 1628** |

Calibration (structural FO4 / mapped cells): iq 16.5 / 47, store_buffer
38.5 / 49, wbuffer 18.6 / 21, instr_queue 17.0 / 16, instr_realign 26 / 23,
frontend 23 / 43, rename 19 / 52, scoreboard 15.6 / 54, perf_counters 34.7 /
13 — within ±30 % where the board used to be blind; rename/scoreboard still
under-read (dynamic struct-array reads behind rotated indices),
perf_counters/TLBs over-read (dense control cones).

The emitted −O3 allow-latency tree (A102) maps end to end: total area
+0.35 % (flops of InsertReg where it rises: branch_unit +29 %, alu +12–15 %,
missunit +12 %; one-hot BalanceMux neutral, LoopRewrite negative); depth
bought on the module board (scoreboard 5.16 → 3.98 ns, frontend 43 → 37
cells, csr 2.02 → 1.36 ns). Three logic-dropping emit defects were found by
that area delta and fixed with tests (zero-fed stage + rewritten origin;
one-hot tree labels ≠ arms; stale width map).

What stands between the board and 10 FO4 is now legible and ranked: the
OoO *control* cones — iq select (47 cells), store_buffer squash (49), rename
allocation (52), scoreboard commit select (54), frontend branch-target add
(43) — then the single-cycle 64-bit add/compare wall. Those are
microarchitecture (precomputed selects, one-cycle-later counts, stationary
queues), not latency-neutral rewrites; the automatic toolbox (BalanceMux,
RebalanceAssoc, SelectIncrement, LoopRewrite with FindFirst / CondCount /
RingWalk / StreamCompact) is exact and area-neutral-or-better, and the
planner's latency-neutral-first order is also the area order.

### Earlier on 2026-10-16 (delay-v35, loop-carried chains)

Latest: the fanout-insensitive whole-core mapped report (A97/A98) showed the
netlist's worst path is a 436-cell loop-carried chain through
`scoreboard`/`g6lc_rob` that the structural model billed as one iteration.
delay-v35 bills procedural loop-carried accumulators by trip count; the two
production walks (scoreboard younger-cancel window, ROB free/re-anchor) are
rewritten exactly (A98/A99; fixture 14.7 ns → 0.78 ns) and the live board is
back to worst **23.0** (`frontend speculative_d`), 160/1377 reg-to-reg
failing, with scoreboard 13.6 and rob 11.3.

### Earlier on 2026-10-16 (delay-v34, planner reaches plain cones)

Latest: with `||`/`&&` parsed correctly (delay-v34), the reduction fold, and
the planner fixes (A95–A96), the emitted latency-neutral tree reports worst
live RegToReg **20.0** (`frontend speculative_d`, rebalanced in RTL),
147/1381 reg-to-reg failing, structural 2.0 GHz; live RTL 23.0. The first
whole-core mapped OpenSTA run completed (1.2 M instances) but is dominated by
unbuffered broadcast fanout (A97) and is not yet a datapath number.

### Earlier on 2026-10-16 (delay-v33, manifest defines, SelectIncrement)

Latest: the portable flist now carries `+define+G6LC_FETCH_B` and the
synthesis defines (A93) — earlier boards measured the A-path code. Under the
right preprocessing, with the `SelectIncrement` transform (A91) and the
`instr_queue` production edit (A92): live RTL worst RegToReg **24.0**
(`frontend speculative_d`), 191/1371 failing; emitted latency-neutral tree
24.0, 194/1383; `instr_queue` 24.3 → 15.8. Details: `ALGORITHMS-EXPERTS.md`
Part LIII (A91–A94).

### Earlier on 2026-10-16 (delay-v32 + cfg snapshot + elaborated widths)

Latest: with incrementers billed as Compare (delay-v32), the elaborated
width map (`--width-map`) and only instantiated modules counted, the review
tree reports worst live RegToReg **17.0** (`g6lc_bp_ckpt`), 155 of 1390
reg-to-reg paths failing, structural maximum ≈ 2353 MHz; the live baseline
reports 26.8 (`instr_queue`). Details: `ALGORITHMS-EXPERTS.md` Part LIII
(A88–A90).

### Earlier on 2026-10-16 (delay-v31 + cfg snapshot)

Measurement semantics moved four times on 2026-10-16 (`ALGORITHMS-EXPERTS.md`
Part LIII): origin-coordinate constant spans (v28), width-scaled costs (v29),
transparent casts and shift-add constant multiplies (v30), carry-save
multi-operand sums (v31), plus the host's elaborated `CVA6Cfg` snapshot. On
`g6lc64_ooo` at 10 FO4 / 20 ps the live RTL now reports worst RegToReg
**22.0** (`fpnew_fma_multi`, exponent widths unresolved) with 700 failing
primary paths; the Part LII review tree reports **21.0** / 696. The failing
count rose because a 64-bit add is 12 FO4 at this table — the honest shape of
the XLEN=64 gap at 4 GHz / 20 ps. Every figure below this heading predates
those corrections and is kept for provenance only.

## Earlier campaign (2026-10-15, delay-v26)

Follow-up: see `ALGORITHMS-EXPERTS.md` Part LII. The refusal-rollback repair changes
fresh correction output; lexical binding correction is now delay-v27. Fresh emit
reports 31.0 FO4, while reviewed admission-count/FIFO-delta candidates report
16.5 RegToReg and 30.0 all-primary. None closes 10. The 21.5 figure below remains
specific to the older frozen emitted tree.

The frozen scope-safe emitted core has 264 files, 234 modules and 11,008 paths.
The same SV measures 23.5 FO4 under delay-v25 and **21.5 FO4 under delay-v26**,
with 351 → 349 failing primary paths. The old scoreboard headline used mismatched
preprocessed loop bounds and original-source assignment offsets; correcting the
genvar scope lowers that cone to 14.5. This is not a hardware timing improvement.

The remaining worst is `instr_queue` (push popcount → pointer/sequence update).
Same-cycle, two-port scoreboard selection and width-4 FIFO delta candidates have
SAT proofs and better small-cone Nangate45 mapped timing, but neither establishes
whole-core equivalence or closure. Carry-save and balanced-popcount variants also
produced mapped regressions despite their attractive source-level structure.
Exact evidence and reproduction commands: `../ALGORITHMS-EXPERTS.md` Part LI.
Earlier tables below are historical measurements on other input sets.

Handoff to real STA tools (SDC seeds, artifact mapping, workflow): [`STA-HANDOFF.md`](STA-HANDOFF.md).

## Model

| Quantity | Formula |
|---|---|
| Period (ns) | \(T = 1000 / f_{\mathrm{MHz}}\) |
| FO4 budget | \(B = T \cdot 1000 / t_{\mathrm{FO4,ps}} \cdot (1-m)\) |
| Path slack | \(B - C_{\mathrm{path}}\) |
| Max freq for path | \(f_{\max} = 1000 / (C \cdot t_{\mathrm{FO4}} / 1000 / (1-m))\) |
| **Closes** | all single-cycle paths have slack ≥ 0 at target |

## Startpoint / endpoint

| Region | Startpoint | Endpoint | `path_kind` |
|---|---|---|---|
| `always_comb` / `assign` | `{mod}.in0` (PI) | `{mod}.out0` (PO) | `in_to_out` |
| `always_ff` | `{mod}.reg0/CP` | `{mod}.reg1/D` | `reg_to_reg` |
| After InsertReg cut | prior launch | pipe `regN/D` | `in_to_reg` / `reg_to_reg` |
| Residual after cut | pipe Q | original capture | same as parent (`RegToReg` stays `RegToReg`) |

JSON (`analyze --json-out`) includes per-path:

- `startpoint`, `endpoint`, `path_kind`
- `total_fo4`, `slack_fo4`, `max_freq_mhz`, `closes`
- design-level `frequency_closure` summary

## Precompiler response

1. Rank paths worst slack first (primary FO4 excludes soft multi-cycle / atomic-over-budget where tagged)  
2. Prefer **latency-neutral** first: `path_class` deflate → rebalance → **BalanceMux**
   (stage_hot_arm → residual onehot → sticky credit) → SplitAssign  
3. **InsertReg** only with `--allow-latency` (+ GateInfo / `--assume-clk` when needed)  
4. Emit optimized SV (review-only) → integrity reparse → optional **pyslang** lint in `verif/regress`  

Default budget knobs: `fo4_ps=20`, `margin=0.2` → **~32 FO4 @ 1250 MHz**, **~20 FO4 @ 2000 MHz**, **~16 FO4 @ 2500 MHz**.
Scale with monorepo-soak `--target-mhz`. See `MONOREPO-SOAK.md` §9 for validated soak numbers.

---

## Current evidence rules (ir-v1 / delay-v2)

A 4 GHz target is 0.250 ns. At 20 ps/FO4 and 20% margin the structural budget is
10 FO4; this is an assumption, not process calibration. Inverting reported frequency
must include the margin: `C = 1e6 * (1-margin) / (f_MHz * fo4_ps)`.
The historical 503.1 MHz / 20 ps conversion below omitted that margin: it corresponds
to about 79.5 FO4, not 99.4, under that formula. Neither value proves a silicon limit.

Use original analysis, proposed IR result, emitted re-analysis, integrity and actual
STA as separate evidence. Both `frequency_closure` summaries filter inferred
multi-cycle paths; read all-path costs and coverage too. A successful parse is not
an equivalence proof. Macro/include source locations, unresolved assignment semantics,
and skipped files prevent production claims even if a filtered structural budget passes.

Host dashboards now select emitted evidence instead of falling back to optimistic IR.
`post_analyze_valid=false`, missing/empty post-analysis, and skipped files are
INCONCLUSIVE. OpenSTA parsing accepts native numeric-before-slack reports; partial or
stale files cannot turn failed tool execution into success. Missing tools are SKIP,
not STA closure. The reference report tests do not calibrate `fo4-v1.toml`.

## Current strict measurement (ir-v1 / delay-v4)

First reading taken with a **closed input set**: both profiles parse every file, with no
`--allow-parse-errors` and zero skips. 4000 MHz / 20 ps / margin 0.2 → 10.0 FO4, `-O3`.
Closure is read from emitted `post_analyze`, not from IR `post_closure`.

| Profile | Files | Modules | Paths | Closure | Structural max | Worst path | FO4 | Failing |
|---|---:|---:|---:|---|---:|---|---:|---:|
| `full_core` | 258 | 233 | 5557 | MISS | ~571.4 MHz | `g6lc_ftq.reg0/CP → .reg1/D` | 70.0 | 427 |
| `full_corev_apu` | 181 | 167 | 4794 | MISS | ~131.4 MHz | `g6lc_ai_gemm_seq.reg0/CP → .reg1/D` | 304.5 | 133 |

Worst **raw** (multi-cycle-inclusive) path is 176.0 FO4 `fpnew_opgroup_block` on the core
and 304.5 FO4 `g6lc_ai_gemm_seq` on the APU. Under `delay-v3` the core's raw worst was a
202.0 FO4 "divider" in `cva6_ptw` that turned out to be a constant part-select bound; see
`AGENTS-todo.md` for the before/after counts.

Three things this changes:

1. **Earlier readings covered less design than they appeared to.** Closing the inputs
   moved `full_core` from 184 to 233 modules and `full_corev_apu` from 1888 to 4636
   paths. Any frequency taken before this described a subset, silently.
2. **The worst core path is not an AI cone.** With comment artifacts, `translate_off`
   regions and name-based arithmetic discounts removed, it is `g6lc_ftq` at 70.0 FO4.
   `SyncDpRam` 720.0 and `g6lc_ai_exec` 545.5 do not reproduce.
3. **Auto-correct moved primary FO4 by 0.0** on both profiles despite 462 and 308
   applied edits. The emitted tree is valid and re-analysable; it does not improve this
   target. Do not present the transform worklist as a path to a higher clock.
4. **`post_closure` is not reportable under lean emit.** The same `full_core` run books IR
   **56.0 FO4 / 714.3 MHz / 344 failing** while re-analysis of its own emitted SV gives
   **70.0 FO4 / 571.4 MHz / 556 failing**, with integrity clean. Lean emit does not
   rewrite origin; `PassPolicy.emit_structural` now refuses InsertReg/BalanceMux IR
   credit in that mode and sets `post_closure.reportable=false`. Read `post_analyze`,
   which is what the host and soak use. Richer emit (`--real-cut-feeds`) may book IR
   because origin is actually rewritten.

Both profiles are `structure OK` under host `timings validate --require-emit` while
reporting MISS. That combination — a valid package that does not close — is the
intended outcome, and it is still a structural estimate, not STA.

## Historical high-frequency targets (2026-09-10 measurements)

These pre-audit findings are retained as history, not current critical-path rankings.
They were taken on an incomplete input set (see above) and do not establish that a
particular source module limits the physical processor.

Everything below is `full_core` with `+define+G6LC_FETCH_B` carried and the g1\* recover
set retired. Read it before quoting any multi-GHz number.

### `fo4_ps` is a process input, not a tuning knob

The budget at 4000 MHz is **10.0 FO4 at 20 ps**, **16.7 at 12 ps**, **33.3 at 6 ps**, so
"closes at 4 GHz" can be manufactured by choosing the node. The host's
`AGENTS-configuration.md` puts the target of record at **1.25 GHz / 12 nm**, with a
reference shelf of 1.25-2.2 GHz on 12-14 nm and no 12 nm part above 2.0 GHz. Quote the
`fo4_ps` with every frequency claim.

### Aggressivity is not the lever - measured

`-O3` (`max_passes=16 worklist_width=4 cut=budget-fit stages=8 min_gain=1 thorough`)
against `-O2` (`4 / 1 / cost-balanced / 1 / 2 / balanced`) at the same operating point:

| | edits | IR closure | emitted MHz | emitted FO4 |
|---|--:|---|--:|--:|
| 4000 MHz, 20 ps, `-O2` | 928 | false 2086.6 | 503.1 | 99.4 |
| 4000 MHz, 20 ps, **`-O3`** | **1091** | false 2086.6 | 503.1 | **99.4** |

163 extra edits, identical outcome. **Raising passes / worklist width / multi-cut does not
move the emitted critical path**, because the limiting cones are `AtomicOverBudget` and no
cut strategy reaches inside an indivisible operator.

### The actionable output for a high target is the T3 stage count

`t3_arch_multicycle_mul` reports `ceil(atomic_cost / budget)` internal stages for the
dominant `Mul`/`DivRem` on the path (`dominant_atomic_op`, mirroring
`try_atomic_over_budget`'s selection), so it scales with the target: a 56 FO4 multiply
needs 2 stages at 1250 MHz/20 ps and **6 at 4000 MHz/20 ps**. `full_core` at 4000 MHz/20 ps
yields 24 `atomic_op` cards -- `fpnew_cast_multi` DivRem 120 FO4 -> 12 stages, `cva6_ptw`
Mul 102 -> 11, `cva6_tlb` Mul 78 -> 8, **`g6lc_ai_exec` Mul 56 -> 6**.

### Two caveats that invalidate naive readings

1. **`primary_fo4` excludes `atomic_over_budget` and multi-cycle classes**, so
   `post_closure` can report `closes=true` while the design does not close. Always read
   `post_analyze_sv` -- the re-analysis of the *emitted* RTL -- beside it. Measured
   divergence: `full_corev_apu` IR `closes=true 4000.0` vs emitted **350.9 MHz**.
2. **A known lowering bug attributes FO4 to comment lines.** Comment slashes are lowered as
   `DivRem` nodes: `SyncDpRam.out0` reports 720.0 FO4 (`nodes=1`, `primary_loc
   SyncDpRam.sv:136` = a row of slashes) in a file with **zero** `/` operators outside
   comments, and 720 is 6 x the `div_rem` base of 120. Scope: 3 of 24 atomic paths, 1,577
   of 29,925 FO4 (5.3%) -- **but it owns the worst path**. Treat any path whose
   `primary_loc` is a comment line as invalid until this is fixed; with those removed the
   genuine worst path is **545.5 FO4 `g6lc_ai_exec`**.

See `verif/README.md`, `FO4-ALGORITHM-UPGRADES.md`.
AI island: `../../architecture/ai-matrix/AI-ISLAND-TIMING.md`.
